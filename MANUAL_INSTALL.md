## Manual install (UE4SS from elsewhere)

The mod needs **UE4SS v3.0.1 experimental, build 1181** (`UE4SS_v3.0.1-1181-g83330635.zip`). The main download includes it; `FlatScreenMode_v1.0_mod_only.zip` doesn't (it has just the mod and `MemberVariableLayout.ini`, at the right paths, so you can extract it into `Win64` too). Other versions aren't tested: release 3.0.1 "stable" doesn't support this engine, and **UE4SS 4.x** (GitHub's "experimental-latest" since 2026-11-12) hasn't been tried. If you set it up yourself:

1. Copy `dwmapi.dll` and the `ue4ss` folder into `Win64`.
2. Copy `MemberVariableLayout.ini` (in the mod-only zip, or `mod/` in this repository) into `Win64\ue4ss\`, next to `UE4SS.dll`. Without it, UE4SS crashes this game on start, because the game uses a modified Unreal Engine.
3. In `Win64\ue4ss\UE4SS-settings.ini`, set:

   ```ini
   EnableHotReloadSystem = 0
   MajorVersion = 5
   MinorVersion = 6
   ```

   `EnableHotReloadSystem = 0` matters: UE4SS's Ctrl+R hot reload crashes this game, and Ctrl is the crouch key.
4. Copy the `FlatScreenMode` folder into `Win64\ue4ss\Mods\` (the path must be `Mods\FlatScreenMode\Scripts\main.lua`).
5. In `Win64\ue4ss\Mods\mods.txt`, add `FlatScreenMode : 1` **above** the `Keybinds : 1` line. Keep `ConsoleEnablerMod : 1` (the F10 console) and `CheatManagerEnablerMod : 1` (the Space intro skip) on.
