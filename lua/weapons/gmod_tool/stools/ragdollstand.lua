TOOL.Category    = "Poser"
TOOL.Name        = "Stand Pose"
TOOL.Command     = nil
TOOL.ConfigName  = nil

-- General Settings
TOOL.ClientConVar["use_bbox"]          = "0"
TOOL.ClientConVar["enable_snap"]       = "0"
TOOL.ClientConVar["snap_val"]          = "45"
TOOL.ClientConVar["use_custom_angle"]  = "0"
TOOL.ClientConVar["custom_angle"]      = "0"

-- Unified Pose ConVars
TOOL.ClientConVar["use_anim_mode"]     = "0"
TOOL.ClientConVar["anim_mode"]         = "4"
TOOL.ClientConVar["auto_tpose"]        = "0"

-- Mass Pose ConVars
TOOL.ClientConVar["mass_path"]         = "models/humans/group01/"
TOOL.ClientConVar["mass_formation"]    = "line"
TOOL.ClientConVar["mass_spacing"]      = "65"

function TOOL:LeftClick(tr)
    if self:GetStage() == 0 then
        if not IsValid(tr.Entity) or tr.Entity:GetClass() ~= "prop_ragdoll" then return false end
        if CLIENT then return true end

        self.SelectedEnt = tr.Entity
        self:SetStage(1)
        return true
    else
        local rag = self.SelectedEnt
        if not IsValid(rag) then
            self:SetStage(0)
            return true
        end

        if CLIENT then return true end

        local owner = self:GetOwner()
        local hpos, targetAng = StandPose.CalculatePlacement(owner, rag, tr.HitPos)
        local useBBox  = self:GetClientNumber("use_bbox") == 1
        local useAnim = self:GetClientNumber("use_anim_mode") == 1
        local poseMode = useAnim and self:GetClientNumber("anim_mode") or 0

        if StandPose and StandPose.Request then
            StandPose.Request(rag, owner, hpos, targetAng, poseMode, useBBox)
        end

        self:SetStage(0)
        return true
    end
end

function TOOL:RightClick(tr)
    if self:GetStage() == 1 then
        self:SetStage(0)
        return true
    end
    return false
end

function TOOL:Reload(tr)
    if IsValid(tr.Entity) and tr.Entity:GetClass() == "prop_ragdoll" then
        if CLIENT then return true end

        local owner = self:GetOwner()
        local rag = tr.Entity
        local hpos, targetAng = StandPose.CalculatePlacement(owner, rag, rag:GetPos())
        local useBBox  = self:GetClientNumber("use_bbox") == 1
        local useAnim = self:GetClientNumber("use_anim_mode") == 1
        local poseMode = useAnim and self:GetClientNumber("anim_mode") or 0

        if StandPose and StandPose.Request then
            StandPose.Request(rag, owner, hpos, targetAng, poseMode, useBBox)
        end
        return true
    end
    return false
end

if CLIENT then
    language.Add("tool.ragdollstand.name", "Stand Pose Tool")
    language.Add("tool.ragdollstand.desc", "Pose ragdolls into default or animated pose.")
    language.Add("tool.ragdollstand.0", "Left Click a ragdoll to select it. Reload to pose in place.")
    language.Add("tool.ragdollstand.1", "Click on the ground where you want the ragdoll to stand, or Right Click to cancel.")

    local animOptions = {
        ["4 - Reference"]                  = { ragdollstand_anim_mode = "4" },
        ["5 - Idle"]                       = { ragdollstand_anim_mode = "5" },
        ["6 - Relaxed Stance"]             = { ragdollstand_anim_mode = "6" },
        ["7 - Crossed Arms"]               = { ragdollstand_anim_mode = "7" },
        ["8 - Hands in Pockets"]           = { ragdollstand_anim_mode = "8" }
    }

    function TOOL.BuildCPanel(CPanel)
        CPanel:AddControl("Header", { Description = "Select a ragdoll and place it in standard or custom poses with ground alignment and precise rotation snapping." })

        CPanel:Help("Unchecked 'Use Anim Poses' always uses the default Legacy pose (A-Pose or T-Pose), which works on any ragdoll.\n\nChecked, it pulls physics data straight from native engine sequences per the Anim Pose dropdown below. If a model doesn't support the exact animation requested, it will gracefully fall back to the idle animation. If the model has no standard animations at all, it will safely default to the Legacy Pose.")

        -- Unified Pose Selection Group
        CPanel:AddControl("Label", { Text = "\n--- Pose Selection ---" })
        CPanel:AddControl("CheckBox", { Label = "Auto-Pose on Spawn", Command = "ragdollstand_auto_tpose" })
        CPanel:AddControl("CheckBox", { Label = "Use Anim Poses", Command = "ragdollstand_use_anim_mode" })
        CPanel:AddControl("CheckBox", { Label = "Use Bounding Box", Command = "ragdollstand_use_bbox" })
        CPanel:AddControl("ComboBox", { Label = "Anim Pose", Options = animOptions })

        -- General Options
        -- CPanel:AddControl("Label", { Text = "\n--- General Options ---" })

        -- Snapping Group
        CPanel:AddControl("Label", { Text = "\n--- Rotation & Angle Alignment ---" })
        CPanel:AddControl("CheckBox", { Label = "Enable Angle Snapping", Command = "ragdollstand_enable_snap" })
        CPanel:AddControl("Slider", { Label = "Snap Interval (°)", Command = "ragdollstand_snap_val", Type = "Float", Min = 5, Max = 90 })
        CPanel:AddControl("CheckBox", { Label = "Use Exact Custom Facing Angle", Command = "ragdollstand_use_custom_angle" })
        CPanel:AddControl("Slider", { Label = "Custom Angle (°)", Command = "ragdollstand_custom_angle", Type = "Float", Min = -180, Max = 180 })

        -- Mass Pose Group
        CPanel:AddControl("Label", { Text = "\n--- Mass Pose ---" })
        CPanel:Help("Paste a folder path (e.g., 'models/humans/group01/') to spawn all models inside it.")

        local txt = CPanel:TextEntry("Model Folder / Path", "ragdollstand_mass_path")
        txt:SetUpdateOnType(true)

        local formationOptions = {
            ["Line (Side-by-Side)"] = { ragdollstand_mass_formation = "line" },
            ["Column (File)"]       = { ragdollstand_mass_formation = "column" },
            ["Grid (Rank & File)"]  = { ragdollstand_mass_formation = "grid" }
        }

        CPanel:AddControl("ComboBox", { Label = "Formation Style", Options = formationOptions })
        CPanel:AddControl("Slider", { Label = "Spacing (Units)", Command = "ragdollstand_mass_spacing", Type = "Float", Min = 35, Max = 200 })

        local btnSpawn = CPanel:Button("Spawn Formation at Aim Pos", "")
        btnSpawn.DoClick = function()
            local tr = LocalPlayer():GetEyeTrace()
            if not tr.Hit then return end

            net.Start("StandPose_MassPose")
                net.WriteString(GetConVar("ragdollstand_mass_path"):GetString())
                net.WriteString(GetConVar("ragdollstand_mass_formation"):GetString())
                net.WriteFloat(GetConVar("ragdollstand_mass_spacing"):GetFloat())
                net.WriteVector(tr.HitPos)
            net.SendToServer()
        end

        -- Padding Spacer at the bottom
        local spacer = vgui.Create("DPanel")
        spacer:SetHeight(30)
        spacer.Paint = function() end
        CPanel:AddPanel(spacer)
    end
end