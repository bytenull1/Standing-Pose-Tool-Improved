-- Standing Pose Tool - Improved
-- Original Addon by Winded & PenolAkushari

StandPose = StandPose or {}

-- Server ConVars for Mass Pose
if SERVER then
    CreateConVar("ragdollstand_mass_limit", "36", {FCVAR_ARCHIVE, FCVAR_REPLICATED}, "Maximum number of models mass pose can spawn at once.")
    CreateConVar("ragdollstand_mass_access", "2", {FCVAR_ARCHIVE, FCVAR_REPLICATED}, "0 = Everyone, 1 = Admins, 2 = Superadmins Only")
end

-- Shared cache for the synth check
StandPose.HoverCache = StandPose.HoverCache or {}

function StandPose.IsHoveringModel(model)
    model = string.lower(model or "")
    local cached = StandPose.HoverCache[model]
    if cached == nil then
        cached = (string.match(model, "gunship") or string.match(model, "scanner") or string.match(model, "manhack")) and true or false
        StandPose.HoverCache[model] = cached
    end
    return cached
end

-- Per-model cache
StandPose.ModelCache = StandPose.ModelCache or {}

local function GetModelInfo(model)
    local cached = StandPose.ModelCache[model]
    if cached then return cached end

    local info = {
        isFemale = (string.match(model, "female") or string.match(model, "alyx") or string.match(model, "mossman") or string.match(model, "stalker")) and true or false,
        isPolice = string.match(model, "police") and true or false,
        -- Sequence index per requested poseMode, keyed on model
        seqCache = {},
    }

    StandPose.ModelCache[model] = info
    return info
end

-- Static lookup table instead of rebuilding a fresh table (with nested
-- ternaries) on every call
local ANIM_MAP_DEFAULT = {
    [4] = {"reference"},
    [5] = {"idle_subtle", "idle_unarmed", "idle_all_01", "idle01"},
    [6] = {"lineidle01", "competitive_winnerstate_idle"},
    [7] = {"lineidle02", "competitive_loserstate_idle"},
    [8] = {"lineidle04"},
}
local function MergeAnimMap(overrides)
    local merged = {}
    for k, v in pairs(ANIM_MAP_DEFAULT) do merged[k] = v end
    for k, v in pairs(overrides) do merged[k] = v end
    return merged
end

-- Precomputed once at load time
local ANIM_MAP_FEMALE = MergeAnimMap({
    [6] = {"lineidle02", "lineidle03", "competitive_winnerstate_idle"},
    [7] = {"lineidle01", "competitive_loserstate_idle"},
    [8] = {"lineidle03"},
})
local ANIM_MAP_POLICE = MergeAnimMap({
    [5] = {"batonidle1", "idle_subtle", "idle_unarmed", "idle_all_01", "idle01"},
    [7] = {"plazathreat2", "lineidle02", "competitive_loserstate_idle"},
})


function StandPose.ApplyPoseMode(ent, poseMode)
    if SERVER then return end
    if not IsValid(ent) then return end

    local model = string.lower(ent:GetModel() or "")
    local info = GetModelInfo(model)
    local isFemale, isPolice = info.isFemale, info.isPolice

    -- Animation pose
    if poseMode >= 4 then
        local cached = info.seqCache[poseMode]

        if cached == nil then
            local animMap = ANIM_MAP_DEFAULT
            if isPolice then animMap = ANIM_MAP_POLICE
            elseif isFemale then animMap = ANIM_MAP_FEMALE end

            -- Try requested mode first, if unsupported, try idle (5)
            local targetModes = {poseMode}
            if poseMode ~= 5 then table.insert(targetModes, 5) end

            cached = false -- resolved, but nothing found

            for _, mode in ipairs(targetModes) do
                if animMap[mode] then
                    for _, animName in ipairs(animMap[mode]) do
                        local seq = ent:LookupSequence(animName)
                        if seq and seq >= 0 then
                            local cycle = 0.1
                            -- Cycle adjusted to properly hold the crossed arms frame
                            if mode == 7 and animName == "plazathreat2" then
                                cycle = 0.80
                            end
                            cached = { seq = seq, cycle = cycle }
                            break
                        end
                    end
                end
                if cached then break end
            end

            -- Cache the outcome (success or failure) so repeated poses on
            -- this model never re-walk the anim map, call LookupSequence again
            info.seqCache[poseMode] = cached
        end

        if cached then
            ent:SetSequence(cached.seq)
            ent:SetCycle(cached.cycle)
            -- StandPose_Request handler does one InvalidateBoneCache()+SetupBones()
            -- pass next frame before reading bone matrices
            return
        end

        -- No matching animation on this model at all - fall through to the
        -- bind pose below
    end
end

if SERVER then
    util.AddNetworkString("StandPose_Request")
    util.AddNetworkString("StandPose_Apply")
    util.AddNetworkString("StandPose_MassPose")

    -- Shared facing-angle resolution (custom angle > snap > raw eye yaw)
    local function GetFinalYaw(ply)
        local rawYaw = ply:EyeAngles().y - 180

        if ply:GetInfoNum("ragdollstand_use_custom_angle", 0) == 1 then
            return ply:GetInfoNum("ragdollstand_custom_angle", 0)
        elseif ply:GetInfoNum("ragdollstand_enable_snap", 0) == 1 then
            local snapVal = math.max(ply:GetInfoNum("ragdollstand_snap_val", 45), 1)
            return math.Round(rawYaw / snapVal) * snapVal
        end

        return rawYaw
    end

    function StandPose.GetFinalAngle(ply)
        return Angle(0, math.NormalizeAngle(GetFinalYaw(ply)), 0)
    end

    function StandPose.CalculatePlacement(ply, rag, basePos)
        local ang = StandPose.GetFinalAngle(ply)
        local hpos = basePos
        local mdl = string.lower(rag:GetModel() or "")

        -- Prevent raycast from throwing hover-type synth ragdolls straight into the ground
        if not StandPose.IsHoveringModel(mdl) then
            local tr = util.TraceLine({
                start = basePos + Vector(0, 0, 10),
                endpos = basePos - Vector(0, 0, 3000),
                filter = {rag, ply}
            })
            if tr.Hit and not tr.StartSolid then hpos = tr.HitPos end
        end

        return hpos, ang
    end

    -- Reduced from 60 (~6s) to 30 (~3s)
    local MAX_REQUEST_RETRIES = 30

    function StandPose.Request(rag, ply, targetPos, targetAng, poseMode, useBBox)
        if not IsValid(rag) or not IsValid(ply) then return end

        local ragIndex = rag:EntIndex()

        -- Retry loop ensures physics cache is loaded before querying client
        local function SendRequest(retries)
            local currentRag = Entity(ragIndex)
            if not IsValid(currentRag) or not IsValid(ply) then return end

            local physCount = currentRag:GetPhysicsObjectCount() or 0

            if physCount == 0 and retries < MAX_REQUEST_RETRIES then
                timer.Simple(0.1, function() SendRequest(retries + 1) end)
                return
            end

            net.Start("StandPose_Request")
            net.WriteUInt(ragIndex, 16)
            net.WriteVector(targetPos)
            net.WriteAngle(targetAng)
            net.WriteUInt(poseMode, 8)
            net.WriteBool(useBBox)
            net.WriteUInt(physCount, 8)
            net.Send(ply)
        end

        timer.Simple(0.05, function() SendRequest(0) end)
    end

    net.Receive("StandPose_Apply", function(len, ply)
        local ragIndex = net.ReadUInt(16)
        local rag = Entity(ragIndex)
        local count = net.ReadUInt(8)

        if not IsValid(rag) or rag:GetClass() ~= "prop_ragdoll" then return end
        if not hook.Run("CanProperty", ply, "standpose", rag) then return end

        -- Clamp the claimed bone count to what this ragdoll can actually have
        local physCount = rag:GetPhysicsObjectCount() or 0
        if count > physCount then count = physCount end

        local boneData = {}
        for i = 1, count do
            -- If the message is shorter than it claims to be,
            -- stop and apply whatever genuinely arrived instead of letting
            -- net.Read throw and abort the whole receiver
            local ok, physID, pos, ang = pcall(function()
                return net.ReadUInt(8), net.ReadVector(), net.ReadAngle()
            end)

            if not ok then break end

            -- Reject bone indices outside this ragdoll's actual physics
            if physID and physID >= 0 and physID < physCount then
                table.insert(boneData, { physID = physID, pos = pos, ang = ang })
            end
        end

        if #boneData > 0 then rag:SetPos(boneData[1].pos) end

        -- Apply structural positions to ragdoll bones and unconditionally freeze them
        for _, data in ipairs(boneData) do
            local phys = rag:GetPhysicsObjectNum(data.physID)
            if IsValid(phys) then
                phys:EnableMotion(true)
                phys:Wake()
                phys:SetPos(data.pos)
                phys:SetAngles(data.ang)
                phys:SetVelocity(vector_origin)
                phys:AddAngleVelocity(-phys:GetAngleVelocity())

                local b = rag:TranslatePhysBoneToBone(data.physID)
                local boneName = (b and b >= 0) and rag:GetBoneName(b) or ""

                -- Freeze all structural bones. prp_ bones (jigglebones/attachments) remain loose
                if not string.StartWith(boneName, "prp_") then
                    phys:EnableMotion(false)
                    phys:Sleep()
                end
            end
        end

        rag:PhysWake()
    end)

    hook.Add("OnEntityCreated", "StandPose_DuplicatorCheck", function(ent)
        if not IsValid(ent) or ent:GetClass() ~= "prop_ragdoll" then return end

        local oldOnDuplicated = ent.OnDuplicated
        ent.OnDuplicated = function(self, entTable)
            self.IsStandPoseDuplicated = true
            if oldOnDuplicated then oldOnDuplicated(self, entTable) end
        end
    end)

    hook.Add("PlayerSpawnedRagdoll", "StandPose_AutoTPose", function(ply, model, ent)
        if ply:GetInfoNum("ragdollstand_auto_tpose", 0) == 0 then return end

        -- Ignore saves, dupes, advdupe2, and internal mass pose
        if ent.IsStandPoseDuplicated or ent.IsStandPoseMassPosed then return end
        if type(AdvDupe2) == "table" and AdvDupe2.SpawningEntity then return end
        if type(ply.AdvDupe2) == "table" and ply.AdvDupe2.Pasting then return end

        local useAnim = ply:GetInfoNum("ragdollstand_use_anim_mode", 0) == 1
        local poseMode = useAnim and ply:GetInfoNum("ragdollstand_anim_mode", 4) or 0

        timer.Simple(0.05, function()
            if not IsValid(ent) or not IsValid(ply) or ent.IsStandPoseDuplicated then return end

            local hpos, ang = StandPose.CalculatePlacement(ply, ent, ent:GetPos())
            local useBBox  = ply:GetInfoNum("ragdollstand_use_bbox", 1) == 1

            StandPose.Request(ent, ply, hpos, ang, poseMode, useBBox)
        end)
    end)

    -- Mass Pose Handler
    -- Uses a single repeating timer.Create that processes one model per tick,
    -- instead of timer.Simple per model
    local massSpawnCounter = 0

    function StandPose.SpawnFormation(ply, modelList, startPos, formationType, spacing, poseMode, useBBox)
        if not IsValid(ply) or not istable(modelList) or #modelList == 0 then return end

        -- Lock the angle immediately so moving during the staggered spawn
        -- doesn't rotate the formation
        local baseAng = StandPose.GetFinalAngle(ply)
        local forward = baseAng:Forward()
        local right = baseAng:Right()
        local total = #modelList

        -- Collect spawned entities locally and commit the undo block
        -- synchronously at the end
        local spawnedEnts = {}

        massSpawnCounter = massSpawnCounter + 1
        local timerName = "StandPose_MassSpawn_" .. ply:EntIndex() .. "_" .. massSpawnCounter

        local index = 0
        timer.Create(timerName, 0.1, total, function()
            index = index + 1
            local i = index
            local mdl = modelList[i]

            if IsValid(ply) and util.IsValidRagdoll(mdl) then
                local offset = Vector(0, 0, 0)
                if formationType == "line" then
                    local shift = (i - 1) - ((total - 1) / 2)
                    offset = right * (shift * spacing)
                elseif formationType == "column" then
                    offset = -forward * ((i - 1) * spacing)
                elseif formationType == "grid" then
                    local cols = math.ceil(math.sqrt(total))
                    local row = math.floor((i - 1) / cols)
                    local col = (i - 1) % cols
                    local shiftX = col - ((cols - 1) / 2)
                    offset = (right * (shiftX * spacing)) - (forward * (row * spacing))
                end

                local targetPos = startPos + offset
                local rag = ents.Create("prop_ragdoll")
                rag.IsStandPoseMassPosed = true
                rag:SetModel(mdl)
                rag:SetPos(targetPos + Vector(0, 0, 10))
                rag:SetAngles(baseAng)
                rag:Spawn()
                rag:Activate()

                gamemode.Call("PlayerSpawnedRagdoll", ply, mdl, rag)
                if IsValid(ply) then ply:AddCleanup("ragdolls", rag) end

                table.insert(spawnedEnts, rag)

                local hpos, _ = StandPose.CalculatePlacement(ply, rag, targetPos)
                StandPose.Request(rag, ply, hpos, baseAng, poseMode, useBBox)
            end

            if index >= total then
                -- Build the single shared undo block atomically
                if #spawnedEnts > 0 then
                    undo.Create("Mass Pose Ragdolls")
                    undo.SetPlayer(ply)
                    for _, rag in ipairs(spawnedEnts) do
                        if IsValid(rag) then undo.AddEntity(rag) end
                    end
                    undo.Finish("Mass Pose Ragdolls (" .. #spawnedEnts .. ")")
                end
            end
        end)
    end

    net.Receive("StandPose_MassPose", function(len, ply)
        if not hook.Run("CanTool", ply, ply:GetEyeTrace(), "ragdollstand") then return end

        local accessLevel = GetConVar("ragdollstand_mass_access"):GetInt()
        if accessLevel == 2 and not ply:IsSuperAdmin() then
            ply:ChatPrint("[Standing Pose Tool] Only Superadmins can use the mass pose.")
            return
        elseif accessLevel == 1 and not (ply:IsAdmin() or ply:IsSuperAdmin()) then
            ply:ChatPrint("[Standing Pose Tool] Only Admins can use the mass pose.")
            return
        end

        local inputPath = net.ReadString()
        local formation = net.ReadString()
        local spacing = math.Clamp(net.ReadFloat(), 30, 300)
        local hitPos = net.ReadVector()

        -- Unify formatting and remove trailing whitespace
        inputPath = string.lower(string.Trim(inputPath))
        inputPath = string.Replace(inputPath, "\\", "/")

        -- Prevent directory traversal hacking
        if string.find(inputPath, "%.%.") then return end

        -- Ensure input targets the models directory
        if not string.StartWith(inputPath, "models/") then
            inputPath = string.TrimLeft(inputPath, "/")
            inputPath = "models/" .. inputPath
        end

        -- Prevent server crash by trying to parse the massive models folder
        if inputPath == "models/" or inputPath == "models/*" or inputPath == "models/*.mdl" then
            ply:ChatPrint("[Standing Pose Tool] You cannot mass-pose the entire models/ directory!")
            return
        end

        local modelList = {}
        local maxLimit = GetConVar("ragdollstand_mass_limit"):GetInt()

        -- Gather valid .mdl files
        if string.EndsWith(inputPath, ".mdl") and not string.find(inputPath, "%*") then
            table.insert(modelList, inputPath)
        else
            if not string.EndsWith(inputPath, ".mdl") then
                if not string.EndsWith(inputPath, "/") then inputPath = inputPath .. "/" end
                inputPath = inputPath .. "*.mdl"
            end

            local baseDir = string.GetPathFromFilename(inputPath)
            local files = file.Find(inputPath, "GAME")

            if files then
                for _, f in ipairs(files) do
                    table.insert(modelList, baseDir .. f)
                    if #modelList >= maxLimit then break end
                end
            end
        end

        if #modelList > 0 then
            local useAnim = ply:GetInfoNum("ragdollstand_use_anim_mode", 0) == 1
            local poseMode = useAnim and ply:GetInfoNum("ragdollstand_anim_mode", 4) or 0
            local useBBox = ply:GetInfoNum("ragdollstand_use_bbox", 0) == 1

            StandPose.SpawnFormation(ply, modelList, hitPos, formation, spacing, poseMode, useBBox)
        else
            ply:ChatPrint("[Standing Pose Tool] No valid models found in that path.")
        end
    end)
end

-- C-menu option
local propt = {}
propt.MenuLabel = "Stand Pose"
propt.Order = 5000

propt.Filter = function(self, ent, ply)
    if not IsValid(ent) or ent:GetClass() ~= "prop_ragdoll" then return false end
    return hook.Run("CanProperty", ply, "standpose", ent) ~= false
end

propt.Action = function(self, ent)
    self:MsgStart()
    net.WriteEntity(ent)
    self:MsgEnd()
end

if SERVER then
    propt.Receive = function(self, length, player)
        local rag = net.ReadEntity()
        if not IsValid(rag) or rag:GetClass() ~= "prop_ragdoll" then return end
        if not IsValid(player) or not properties.CanBeTargeted(rag, player) then return end
        if not self:Filter(rag, player) then return end

        local hpos, angle = StandPose.CalculatePlacement(player, rag, rag:GetPos())
        local useBBox  = player:GetInfoNum("ragdollstand_use_bbox", 1) == 1
        local useAnim = player:GetInfoNum("ragdollstand_use_anim_mode", 0) == 1
        local poseMode = useAnim and player:GetInfoNum("ragdollstand_anim_mode", 4) or 0

        StandPose.Request(rag, player, hpos, angle, poseMode, useBBox)
    end
end

properties.Add("standpose", propt)

if CLIENT then
    local color_invisible = Color(0, 0, 0, 0)
    local angle_zero = Angle(0, 0, 0)
    local DUMMY_PARK_POS = Vector(0, 0, -32000)

    -- Pool of reusable invisible dummy models
    StandPose.EntPool = StandPose.EntPool or {}
    local MAX_POOL_SIZE = 64

    -- Legacy pose
    function StandPose.AcquireDummy(model)
        local ent = table.remove(StandPose.EntPool)

        if IsValid(ent) then
            ent:SetModel(model)

            -- ManipulateBoneAngles() persists until cleared, so a reused dummy
            -- would keep old bone rotations from prior poses
            local boneCount = ent:GetBoneCount() or 0
            for i = 0, boneCount - 1 do
                ent:ManipulateBoneAngles(i, angle_zero)
            end

            -- Сlear whole-skeleton sequence from dummy for legacy pose
            ent:ResetSequence(0)
            ent:SetCycle(0)

            ent:SetNoDraw(true)
            ent:DrawShadow(false)

            return ent
        end

        ent = ClientsideModel(model, RENDERGROUP_TRANSLUCENT)
        if not IsValid(ent) then return nil end

        ent:SetRenderMode(RENDERMODE_TRANSALPHA)
        ent:SetColor(color_invisible)
        ent:SetNoDraw(true)
        ent:DrawShadow(false)
        if ent.SetIK then ent:SetIK(false) end

        return ent
    end

    function StandPose.ReleaseDummy(ent)
        if not IsValid(ent) then return end

        if #StandPose.EntPool >= MAX_POOL_SIZE then
            -- Pool is already at cap, discard the extra instead of holding it forever
            ent:Remove()
            return
        end

        ent:SetPos(DUMMY_PARK_POS)

        table.insert(StandPose.EntPool, ent)
    end

    -- Never carry pooled entities across a map change, disconnect
    hook.Add("ShutDown", "StandPose_ClearPool", function()
        for _, ent in ipairs(StandPose.EntPool) do
            if IsValid(ent) then ent:Remove() end
        end
        StandPose.EntPool = {}
    end)

    -- Reduced from 60 (~6s) to 30 (~3s)
    local MAX_POSE_RETRIES = 30

    net.Receive("StandPose_Request", function()
        local ragIndex = net.ReadUInt(16)
        local targetPos = net.ReadVector()
        local targetAng = net.ReadAngle()
        local poseMode = net.ReadUInt(8)
        local useBBox = net.ReadBool()
        local physCount = net.ReadUInt(8)

        local function AttemptPose(retries)
            local rag = Entity(ragIndex)

            -- Wait for the entity index to fully sync over the network
            if not IsValid(rag) then
                if retries < MAX_POSE_RETRIES then
                    timer.Simple(0.1, function() AttemptPose(retries + 1) end)
                end
                return
            end

            -- Ensure engine has streamed bone data and physics map
            local testPhysBone = rag:TranslatePhysBoneToBone(0)
            if rag:GetBoneCount() == 0 or not rag:GetBoneMatrix(0) or (physCount > 0 and (not testPhysBone or testPhysBone < 0)) then
                if retries < MAX_POSE_RETRIES then
                    timer.Simple(0.1, function() AttemptPose(retries + 1) end)
                end
                return
            end

            local model = string.lower(rag:GetModel() or "")
            local isHovering = StandPose.IsHoveringModel(model)

            -- Pull a dummy ghost model from the pool instead of
            -- ClientsideModel(), Remove() every single call
            local ent = StandPose.AcquireDummy(rag:GetModel())
            if not IsValid(ent) then return end
            ent:SetPos(targetPos)
            ent:SetAngles(targetAng)

            -- Apply the pose immediately upon creation
            StandPose.ApplyPoseMode(ent, poseMode)

            -- Wait for the next frame to initialize the bones
            timer.Simple(0, function()
                if not IsValid(rag) or not IsValid(ent) then
                    StandPose.ReleaseDummy(ent)
                    return
                end

                ent:InvalidateBoneCache()
                ent:SetupBones()

                -- Safety check in case the client-side model failed to initialize bones
                if ent:GetBoneCount() == 0 or not ent:GetBoneMatrix(0) then
                    -- Bone setup failed, discard to avoid reusing broken entity
                    ent:Remove()
                    if retries < MAX_POSE_RETRIES then
                        timer.Simple(0.1, function() AttemptPose(retries + 1) end)
                    end
                    return
                end

                -- Calculate absolute floor Z to prevent clipping
                -- if useBBox, use WorldSpaceAABB otherwise scan bones once
                -- and cache matrices for the validBones loop
                local minZOffset = 0
                local boneMatrixCache = nil

                if useBBox then
                    local min = ent:WorldSpaceAABB()
                    minZOffset = targetPos.z - min.z
                else
                    local lowestZ = math.huge
                    local numBones = ent:GetBoneCount() or 0

                    if numBones > 0 then
                        boneMatrixCache = {}
                        for b = 0, numBones - 1 do
                            local matrix = ent:GetBoneMatrix(b)
                            if matrix then
                                boneMatrixCache[b] = matrix
                                local z = matrix:GetTranslation().z
                                if z < lowestZ then lowestZ = z end
                            end
                        end
                    end

                    if lowestZ < math.huge then
                        minZOffset = targetPos.z - lowestZ
                    else
                        local min = ent:WorldSpaceAABB()
                        minZOffset = targetPos.z - min.z
                    end
                end

                local groundZ = targetPos.z

                if not isHovering then
                    local filterEnts = {ent, rag}
                    if IsValid(LocalPlayer()) then table.insert(filterEnts, LocalPlayer()) end

                    local tr = util.TraceLine({
                        start = targetPos + Vector(0, 0, 50),
                        endpos = targetPos - Vector(0, 0, 3000),
                        filter = filterEnts
                    })

                    if tr.Hit and not tr.StartSolid then groundZ = tr.HitPos.z end
                end

                local finalPos = Vector(targetPos.x, targetPos.y, groundZ + math.max(minZOffset, 0))
                local posOffset = finalPos - targetPos

                -- Extract requested bone positions from the dummy and push them back to the server.
                -- Reuses cached matrices from the scan above where available
                local validBones = {}
                for i = 0, physCount - 1 do
                    local b = rag:TranslatePhysBoneToBone(i)
                    if b and b >= 0 then
                        local matrix = (boneMatrixCache and boneMatrixCache[b]) or ent:GetBoneMatrix(b)
                        if matrix then
                            table.insert(validBones, {
                                physID = i,
                                pos = matrix:GetTranslation() + posOffset,
                                ang = matrix:GetAngles()
                            })
                        end
                    end
                end

                StandPose.ReleaseDummy(ent)

                net.Start("StandPose_Apply")
                net.WriteUInt(ragIndex, 16)
                net.WriteUInt(#validBones, 8)

                for _, v in ipairs(validBones) do
                    net.WriteUInt(v.physID, 8)
                    net.WriteVector(v.pos)
                    net.WriteAngle(v.ang)
                end

                net.SendToServer()
            end)
        end

        AttemptPose(0)
    end)
end
