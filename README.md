# Standing Pose Tool Improved
This tool can pose a ragdoll to its model pose, which usually is a standing pose for ragdolls. It does not work properly with all ragdolls, but for most of them it does.

## FEATURES:
- Automatically set the pose when spawning a ragdoll (does not affect saves, duplicates, or advdupe2).
- Select a standard pose (default, idle pose, relaxed stance, crossed arms, hands in pockets).
- Adjust the angle at which the ragdoll is positioned.
- Choice between spawning exactly on the ground or based on the bounding box.
- Proper handling of the Strider and other synth ragdolls, as well as ragdolls with IK, like classic zombie.
- Mass pose every model in a folder at once, in a line, column, or grid formation.
- Rewritten network and security improvements.
- Other bug fixes and additional checks.

## Difference between Legacy Pose and Animation Pose:

Legacy pose - the model's own bind pose as specified during compilation. it's simply what the model looks like by default (A-pose or T-pose), just like in the previous version of the addon.

Animation pose - uses the actual animations defined for the model to lock the ragdoll into a specific, natural stance. If the model lacks citizen or other animations, the tool will automatically fall back to its idle pose. If it lacks animations entirely, it will default to an legacy pose.

## Original addon:

[Standing Pose Tool](https://steamcommunity.com/sharedfiles/filedetails/?id=104576786) - Winded & PenolAkushari

---

## FAQ

### The poses doesn't work.
Support is not guaranteed for every custom model.

Every model creator decides for themselves what standard pose to use, what hitboxes or skeleton to use, and what animations to assign. This is outside my scope.

But if suddenly the default pose and the idle pose don’t work, then send me this ragdoll, I'll see what can be done.

### The tool doesn't work at all.
It is incompatible with the original "Standing Pose Tool". They cannot work at the same time.

If the tool produces Lua errors or doesn't function in single-player, it is likely due to an incompatible addon. Check your subscriptions for other addons that affect ragdolls, bones, prop spawning, or overall physics.

If you're in multiplayer, you likely don't have permission to interact with ragdolls (due to FPP, or other prop protection addons). Try granting yourself admin access.

### There is no button in the C-menu.
Try disabling addons that make changes to the C-menu or UI elements.

### How i can change who's allowed to Mass Pose, or the spawn limit?
Those are server settings, so they can only be changed from the server console or server.cfg (ragdollstand_mass_access, ragdollstand_mass_limit).

### (Addon name) is incompatible with this.
Please report it in the appropriate discussion thread or in Github issues, and I'll see what can be done about it. But i cannot make any promises.

### Is there any way I can improve the addon code?
Of course, create a pull request on GitHub. Please test what you've changed before submitting.
