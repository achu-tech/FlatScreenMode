# How to install FlatScreenMode

FlatScreenMode lets you play **PAYDAY: Aces High** with a keyboard and mouse, without a VR headset. It's a Lua mod that runs on **UE4SS**, a free mod loader for Unreal Engine games.

You only need to set this up once. It takes about 2 minutes.

## What you need

- PAYDAY: Aces High (the full game on Steam). The demo isn't supported.
- The download `FlatScreenMode_v1.0.zip` (from ModWorkshop or the GitHub releases). It already includes UE4SS, set up for this game.

## 1. Find the game's Win64 folder

In Steam, right-click **PAYDAY: Aces High** → **Manage** → **Browse local files**. Then open:

```
Calippo\Binaries\Win64
```

The default location is `C:\Program Files (x86)\Steam\steamapps\common\PAYDAY Aces High\Calippo\Binaries\Win64`. You should see `Calippo.exe` in it.

## 2. Extract the zip into it

Extract `FlatScreenMode_v1.0.zip` into `Win64`. When you're done, it should look like this:

```
Win64\
├─ Calippo.exe
├─ dwmapi.dll                     (from the zip)
└─ ue4ss\                         (from the zip)
   ├─ UE4SS.dll
   ├─ UE4SS-settings.ini
   ├─ MemberVariableLayout.ini
   └─ Mods\
      ├─ mods.txt
      └─ FlatScreenMode\
         └─ Scripts\
            ├─ main.lua
            ├─ flat.lua
            └─ config.lua
```

## 3. Start the game

Launch the game from Steam as usual.

- **No VR headset software installed:** the game starts in flat mode by itself, and the mod switches on.
- **SteamVR, Meta/Oculus or another VR runtime installed:** the game may try to start in VR. Close your VR software before launching, or open the game's **Properties** in Steam and enter `-nohmd` under **Launch options**.

Press **Space** to skip the intro. When you reach the safehouse, press **V** to put on your mask, then **1** or **2** to draw a gun. Start heists from the planning table, as in VR (see the controls in `README.md`).

## Check that it works

If nothing reacts to the mod's keys, open this file:

```
Win64\ue4ss\UE4SS.log
```

Search it for `[FlatScreenMode]`. You should find `logic loaded (v1.0)`.
- **If the line is missing:** the files are in the wrong folder. `dwmapi.dll` must be next to `Calippo.exe`.
- **If the game crashes on start:** `ue4ss\MemberVariableLayout.ini` is missing, or a game update changed the engine (see Known limitations).

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

## Settings

Mouse sensitivity is in **Esc > Settings > Comfort > Mouse Sensitivity**. Everything else is in `Win64\ue4ss\Mods\FlatScreenMode\Scripts\config.lua`: key bindings, invert Y, crosshair, HUD size and more. Edit it in Notepad. Your changes apply after a restart, or right away if you type `flatmode reload` in the console (F10).

Leave `fov = 0`. Other values crashed the game.

## Online play

The mod works offline and in online games on Fast Travel Games' servers (`allow_online = true` in `config.lua`; set it to `false` to have the mod switch itself off online). A modified game client could get your account flagged: play online at your own risk. README.md lists what has been tested online.

## Updating the mod

Replace the `Win64\ue4ss\Mods\FlatScreenMode` folder with the new one. If you changed `config.lua`, copy your changes into the new file instead of keeping the old one, because new versions add settings.

## Uninstall

From `Win64`, delete:
- `dwmapi.dll`
- the `ue4ss` folder

The game itself is unchanged. To play in VR without uninstalling, set `FlatScreenMode : 0` in `ue4ss\Mods\mods.txt`.

## Known limitations

- **Game updates can break the mod**, usually by crashing UE4SS on start. If that happens, uninstall it and wait for an updated `MemberVariableLayout.ini` or mod version.
