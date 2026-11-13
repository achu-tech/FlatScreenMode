# FlatScreenMode: PAYDAY: Aces High with keyboard + mouse

**v1.0.** A UE4SS Lua mod that makes the VR game **PAYDAY: Aces High** (Steam app 3456660) playable without a headset.

**Install:** download `FlatScreenMode_v1.0.zip` (UE4SS included and set up), extract it into `...\steamapps\common\PAYDAY Aces High\Calippo\Binaries\Win64\`, and launch the game from Steam as normal. Step by step: **[INSTALL.md](INSTALL.md)**.
With no VR runtime installed, the game starts in flat mode and the mod switches on by itself.

## Controls

| Key | Action |
|---|---|
| Mouse | Look (turn and look up/down; the hands follow the camera) |
| W A S D | Move (the game's own binding) |
| Shift / Ctrl | Sprint / crouch (game binding) |
| Left mouse | Trigger: fire, spray the spray gun; click menus and screens (the laser follows the crosshair while your right hand is empty) |
| Left mouse (holding a loot bag, bottle or cup in the right hand) | **Throw** it |
| G with a gun out | **Carry a bag in the left hand**: the left hand lets go of the foregrip and grabs the bag under the crosshair; the gun stays in the right hand (one-handed) and the bag hangs at your left side. G again puts the bag down where you look, **T throws it**. R while carrying drops the bag, reloads and picks it back up |
| T | Throw the bag you carry in the left hand (or the bag / bottle in your right hand) |
| Right mouse (hold) | Aim down sights: the gun comes up to your eye and you look along its own sights (front sight on the crosshair; the crosshair dot hides while aiming). Each gun has its own sight line, eye distance and speed: pistols at arm's length and quick, rifles to the cheek, shotguns slowest. **Hip fire is one-handed; while aiming, a free left hand takes the foregrip** for steadier shots. Carrying a bag in the left hand, aiming stays one-handed (`support_hand` in config: "ads", "always" or false) |
| 1 / 2 | Draw the pistol / primary weapon. Press again to holster; press the other number to switch weapons |
| 3 | Take the revive syringe from the inventory (it opens the chest inventory for you). Press again to put it back |
| 4 / 5 | Take the deployable / gadget from the inventory, if your loadout has one *(untested: no loadout with them yet)* |
| Left mouse (syringe in hand) | **Revive**: look at a downed teammate's chest and click. Get within about 1.5 m |
| R | Reload (eject, take a magazine from the over-the-shoulder pouch, insert it, release the slide; revolvers: swing the cylinder out, push a speedloader in, swing it back). Works while aiming and while carrying a bag; pressed during another hand action (e.g. right after drawing) it waits and then reloads |
| V | Put on the mask. **You can't draw weapons until you're masked**: that's the game's casing rule |
| F / G | Right / left hand. **Empty hand: grab the loot, bag, C4 or spray gun nearest the crosshair** (within 10 degrees, up to 2.8 m from your eyes, so bags on the floor a couple of steps ahead work; not through walls), else whatever surface is under the crosshair. **Holding something: put it where you look and let go** (C4 onto its receiver, a bag into a chute or drop-off). A gun is never put down: 1 / 2 holster it, and F on a lever, dial, switch or loot holsters it for you first |
| F (crosshair on a button or keypad key) | **Press it** with your fingertip: door and elevator buttons, wall buttons, door code keypads, the drill's control panel |
| F (crosshair on a lever) | **Lever**: grab it; while held, the mouse moves the lever (right or forward = pull). Drill levers also zoom in: keep the red line inside the light band until calibration finishes. Puzzle, chute and one-shot levers let go by themselves once activated. F again lets go |
| F (crosshair on a switch, knob or wheel) | **Turn it**: grab it, mouse X turns it (right = clockwise), F lets go. Twist switches flip after about 45° (try the other way if one doesn't move) |
| F (crosshair on a valve / vault wheel) | **Valve** (the red handwheels in "...The Harder They Fall"): grab it, then **mouse right or mouse wheel down turns it clockwise** (that opens it; 45° per wheel notch). Within 45° of the end it finishes the turn by itself, the door opens and the hand lets go |
| F (crosshair on a safe dial) | **Safe / deposit box dial**: grab it (the view zooms in). **Mouse wheel: one number per notch, down = R, up = L** (mouse X works too, right = R). The dial stops exactly on each number. For a code like "R6 L4 R7": R until 6 is at the pointer, then L until 4, then R until 7, without letting go. Going past a number or the wrong way resets the lock (the mod lets go and says so); grab it again and start over. The code is written somewhere in the level |
| Tab (hold) | Raise the left wrist to read the smartwatch: ammo/health on the face, heist objectives beside it |
| Tab + F | **Watch hack**: holding Tab, press F to push the watch out in front of you and tap its face. Walk up to a hack laptop, keycard reader or drill-call zone and look at it; the hack runs while the watch is there. **Once it starts, your left hand holds the watch on the spot and the right hand is free**: look around, aim and shoot while it finishes (walk off or turn away and the watch comes back). Keep holding Tab; letting go or F again cancels |
| Middle mouse (tap) | **Ping** where you look: the game's own marker. An enemy, loot, a camera or a teammate near the crosshair gets its own icon and the marker follows it; it fades after 7 s |
| Space (intro) | Skip the intro and go straight to the safehouse (`skip_intro = true` in config skips it without a key press) |
| Enter | Close the welcome/tutorial pop-ups |
| Esc | Game menu (the game's own key is Q; the mod moves it to Esc, `keys.menu` in config). While it's open the view stays still and **the mouse moves a cursor** (the crosshair dot) over it; left mouse clicks, Esc closes |

The game also has its own keys: J/K = left/right grip, U/M = right-hand A/B buttons, arrow keys = snap turn.

The console (F10) command `flatmode <action>` also works: `pistol`, `primary`, `syringe`, `deployable`, `gadget`, `reload_gun`, `mask`, `grab_r`, `grab_l`, `throw`, `ads`, `watch`, `hack`, `jab`, `lever [deg]`, `turn [deg]`, `poke`, `ping`, `status`, `debug`.
`flatmode reload` re-reads `flat.lua` and `config.lua` without restarting. (UE4SS's own Ctrl+R hot reload is disabled because it crashes this game.)

## Status

For the full progress notes, the port to the full game, the roadmap and the changelog, see **PROGRESS.md**.

Verified in the full game (offline / solo): masking up, drawing/holstering/switching, firing, ADS, reloads on both guns, the watch and its objectives panel, buttons, a one-shot lever, twist switches, a vault wheel, carrying C4 onto its receiver, picking up and throwing a loot bag, the spray gun (target progress), and grabbing a safe dial (it turns with the mouse).
v0.3.1 (after the first real test): safe codes entered with the mouse wheel and the safes opened (safehouse safe, two different codes; deposit boxes use the same lock), the pause menu, rifle and pistol reloads 15/15 first time standing, crouched and walking.

## Settings

Edit `Calippo\Binaries\Win64\ue4ss\Mods\FlatScreenMode\Scripts\config.lua`. You can change mouse sensitivity, invert Y, FOV, crosshair, HUD text size, key bindings, hand poses, reach, lever/turn sensitivity, aim assist, and the support hand.

Mouse sensitivity in game (v0.3.31): **Esc > Settings > Comfort > Mouse Sensitivity**. That's the game's own "Smooth turning speed" slider, renamed by the mod, which flat mode doesn't otherwise use. It multiplies `mouse_sensitivity`: at the game's default (3) nothing changes, 6 is twice as fast (the slider runs 1-10). The game saves it. `flatmode sens` in the console shows the current value; `sensitivity_slider = false` in config ignores the slider.

Grenades (v0.3.34): LMB / T winds the hand up behind your head and throws in a straight swing toward the crosshair, letting go mid-swing. Online the server throws with the hand's speed, so this is what makes the grenade fly instead of dropping at your feet.

Reloads (v0.3.33): if a magazine stops short of the magwell's end (mostly while walking), the hand pulls it back and pushes it in again, deeper each time (up to 4 times), before falling back to a full re-slide. `reload_stuck_cm` in config.lua sets how short counts as stuck.

Hand smoothing (v0.3.27): the hands ease from pose to pose (drawing, holstering, reloading, grabbing, the watch, the foregrip) instead of jumping. `hand_smooth = false` turns it off; `hand_smooth_min` / `hand_smooth_max` (seconds) and `hand_smooth_speed` (cm/s) set how long a move takes. Aiming, levers, dials and valves aren't slowed down. In the console, `flatmode smooth` switches it off and on to compare.

Aiming: `ads_weapons` holds each gun's values (sight line height `z`, eye distance `relief` in cm, raise `time` in seconds, the tilt `cant` and the push out `push` on the way up), `ads_classes` the defaults per gun type. `ads_crosshair = true` keeps the crosshair dot while aiming, `ads_level = false` stops levelling the gun. With a red dot sight the gun sits `ads_dot_closer` cm (default 8) closer to your eye than with its iron sights, on every gun (`ads_dot_min` keeps the dot at least 10 cm away; per gun `dot_closer` or `dot_relief`). In the console, `flatmode adsinfo` shows the held gun's values and `flatmode adstune z=9.1` tries one out until the game restarts.

Field of view: `fov` (default 0 = the game's own 120°). **Leave it at 0**: forcing another value crashed the game about a minute after some map loads. HUD text size: `hud_scale` (default 1.8) enlarges the floating message feed (area indicator, objective pop-ups, subtitles); `hud_raise` lifts it clear of the right hand; `watch_ui_scale` (default 1.6) enlarges the objectives panel next to the watch.

## Online play

Matchmaking (quick play, lobbies) puts you on Fast Travel Games' dedicated servers. Since v0.3.14 **the mod also works there** (`allow_online = true`; set it to false and the mod pauses itself in online sessions).

- What the mod does online goes through the same calls the game makes for a VR player: hands and controllers, button presses, and functions on things your character owns (the ping, putting the mask on, the jammer, a valve while you hold it). Guns are holstered by letting go of them at the holster, like a VR hand. After masking up, the mod makes sure your holstered guns are visible: online the game itself didn't show them (v0.3.15).
- **Drawing and reloading work online** (v0.3.18). On an online client the game never hands a gun out of its holster to the mod's hand, so the mod asks the server to take it out into the hand, lifts it to the chest and grabs it there. Online the pouch's next magazine stays wherever you last reloaded instead of following you, so the mod asks the server for it directly: reloads work while walking and after moving around (v0.3.20), crouched, and with shotguns (v0.3.21). Like offline, you can't draw a gun before you've put the mask on (V). If a gun suddenly won't fire or release its magazine, take a step or turn: the game seems to block a gun that's poking into something.

## How it works (reverse-engineering notes)

- **Engine:** Unreal Engine 5.6.1 with an AngelScript fork (Fast Travel Games, codename "Calippo"). The pak files are unencrypted (v11), compressed with Oodle.
- **UE4SS** needed a custom `ue4ss\MemberVariableLayout.ini`, because AngelScript changes engine structs. `UClass` gets a `GenericFuncPtrMap`, `ScriptTypePtr` and `bIsScriptClass` (CDO at 0x170), and `FProperty` is 0x78 bytes (`Offset_Internal` at 0x48, every subclass field +8). The full game kept the same layout.
- **Hands:** without tracking, the game places the hands with `MPHandTransformRules.HandUntrackedDefault[0/1]` relative to the camera. The mod rewrites those poses through UE4SS reflection.
- **Grabbing** uses the MotionController components, which sit on the floor when untracked. The mod moves them onto the visible hands every frame, so the game's own grab, holster, magazine and mask logic all work. `PlayerInteractionComponent:GetCurrentInteraction()` tells what a hand holds.
- **Turning things:** while a lever, switch, dial, knob or wheel is held, the mod turns the motion controller itself (about the control's axis, or about the controller's own X axis for dials and knobs, which read the wrist twist) and grabs at the object's own interaction point (`InteractionProperties.InteractionPoints[].SocketName`).
- **Input:** grip, trigger and buttons are the game's own Enhanced Input actions (`IA_Grip_R`, `IA_Trigger_R`, `IA_Button_A_R_*`...), injected through `EnhancedInputLocalPlayerSubsystem`.
- **Ping:** the ping calls the game's own `CLPPingMarkerComponent:ServerOnPingMarkerDropped` with what's under the crosshair.
- **Aim assist:** each frame the mod measures the held gun's barrel and sights in camera space and steers the hand so the barrel crosses the crosshair. While aiming it also puts the gun's sight line on the view axis at the gun's eye distance and keeps it upright.

## Files

- `mod/FlatScreenMode/Scripts/`: the mod (`main.lua` bootstrap and version, `flat.lua` logic, `config.lua` settings)
- `mod/MemberVariableLayout.ini`: the UE4SS offset fix for this engine build

## Install / uninstall

Step-by-step player instructions are in **INSTALL.md**.
Uninstall: delete `dwmapi.dll`, `steam_appid.txt` and the `ue4ss` folder from `Calippo\Binaries\Win64`. A Steam "verify files" won't remove them, but it also doesn't touch the game itself.

## License

MIT (see `LICENSE`). UE4SS is by the UE4SS team, MIT licensed; its license ships in the release zip as `ue4ss/LICENSE`.
