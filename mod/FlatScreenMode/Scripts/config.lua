-- FlatScreenMode settings. Edit, then restart the game, or type "flatmode reload" in the console (F10).
-- Key names are Unreal key names: "F", "G", "One", "Two", "Tab", "LeftMouseButton", "RightMouseButton", "F5", ...
return {
    -- Online play: the game's matchmaking and lobbies run on Fast Travel Games' servers. true = the mod also works there
    -- (as a client of their server); false = it pauses itself in online sessions. Playing online with a modified client
    -- is at your own risk (it could get the account flagged).
    allow_online = true,

    -- Camera
    fov = 0,                    -- horizontal field of view in degrees; 0 = the game's own 120. Other values lock the
                                -- camera FOV, which crashed the game ~60 s after some map loads in testing: leave at 0
    mouse_sensitivity = 0.30,   -- degrees per mouse count (raise for faster turning)
    -- In game: Esc > Settings > Comfort > "Mouse Sensitivity" (the game's Smooth Turning Speed slider, renamed). It
    -- multiplies mouse_sensitivity: at the game's default (3) it's 1x, 6 = twice as fast, 1.5 = half. false = ignore it.
    sensitivity_slider = true,
    sensitivity_slider_default = 3,
    sensitivity_label = "Mouse Sensitivity",
    invert_y = false,
    max_pitch = 80.0,
    show_crosshair = true,
    ui_pointer = true,          -- menus: the laser goes through the crosshair (world screens: look and click with LMB)
    menu_sensitivity = 0.06,    -- pause menu (Esc): degrees per mouse count the cursor moves (the view stays still)
    hide_own_body = true,

    -- HUD text size. The game sizes its floating text for a VR headset, which is too small on a monitor.
    hud_scale = 1.8,            -- message feed: area indicator, objective pop-ups, subtitles (1 = game default, max ~2)
    hud_raise = 9,              -- lift the message feed (cm) so the right hand doesn't cover the subtitles
    watch_ui_scale = 1.6,       -- objectives panel next to the watch (1 = game default)

    -- Intro (logo/cutscene): press keys.skip_intro (Space) to skip it and go straight to the safehouse.
    -- true skips it automatically, without a key press.
    skip_intro = false,

    -- Hand poses relative to the camera (X forward, Y right, Z up, centimetres) and pitch in degrees
    right_hand = { x = 45, y = 14, z = -28, pitch = 91, yaw = 1.4 },
    left_hand  = { x = 35, y = -18, z = -40, pitch = 70 },
    ads_hand   = { x = 18.4, y = -1.4, z = -9.5, pitch = 91, yaw = 1.4 },  -- right hand while aiming (hold right mouse)
    -- left hand while checking the watch (hold Tab): wrist in front of you, watch face turned to the eyes, about
    -- 17 degrees below the crosshair so the game's look-at-watch check opens the objectives panel
    watch_hand = { x = 31, y = 3.9, z = -8.3, pitch = 69.7, yaw = 30.4, roll = -55.6 },
    -- left hand while carrying a bag (G grabs it; the gun stays in the right hand, one-handed)
    carry_hand = { x = 12, y = -34, z = -75, pitch = 70 },
    -- Hand smoothing: when a hand switches to another pose (drawing, holstering, reloading, grabbing, the watch, the
    -- foregrip...) it eases there instead of jumping in one frame. Aiming, aim assist, levers, dials and valves are
    -- not slowed down: they're exact as before.
    hand_smooth = true,         -- crossfade the hands between poses (false = the old instant moves)
    hand_smooth_min = 0.08,     -- seconds, shortest blend
    hand_smooth_max = 0.22,     -- seconds, longest blend (over the shoulder)
    hand_smooth_speed = 400,    -- cm/s: the blend time grows with the distance
    grab_reach = 280,           -- F/G pick up loot, bags, C4... nearest the crosshair up to this far (cm from the eyes)
    grab_angle = 10,            -- ...within this many degrees of the crosshair
    reach_distance = 170,       -- how far (cm from the eyes) F/G reach to grab what is under the crosshair (170 = the floor)
    hack_reach = 55,            -- how far (cm from the eyes) Tab + F holds the watch out in front of you
    hack_hold = true,           -- once a hack runs, the left hand keeps the watch on the spot and the right hand is free
    hack_hold_reach = 75,       -- ...until the watch is this far (cm) from the eyes: then it comes back in front of you
    syringe_reach = 160,        -- how far (cm from the eyes) LMB can stab a downed teammate with the syringe
    reload_stuck_cm = 0.5,      -- a magazine that stops this far (cm) or more short of the seat is pushed in again

    -- Levers (the drill's activation / calibration lever): F with the crosshair on the handle grabs it, then the mouse
    -- moves the lever (right or forward = pull; the drill's lever: left or back, see drill_invert) and the view stays
    -- still. Keep the red line inside the light band on the drill screen.
    lever_sensitivity = 0.15,   -- lever degrees per mouse count
    lever_fov = 50,             -- zoom while holding a lever so the drill screen is readable (0 = no zoom)
    lever_reach = 150,          -- how far (cm from the eyes) a lever can be grabbed
    lever_retries = 4,          -- a pulled lever that springs back (a race in the game) is grabbed and pulled again this many times in all
    drill_assist = false,       -- true: while you hold the lever, it follows the drill calibration target by itself
    drill_invert = true,        -- true: the drill's lever is pulled with mouse left / back, and the pocket drill's knob
                                -- turns clockwise with mouse left (false = mouse right / forward, like other levers)

    -- Switches, safe dials, the pocket drill knob and vault wheels: F with the crosshair on one grabs it, mouse X turns it
    -- (right = clockwise), F lets go. Safe dials: each mouse wheel notch turns one number, down = R, up = L (mouse X
    -- works too: right = R). The dial stops exactly on each number. For a code like "R6 L4 R7", turn R until 6 is at
    -- the pointer, then L until 4, then R until 7, without letting go.
    turn_sensitivity = 0.5,     -- degrees per mouse count
    turn_speed = 180,           -- the most it turns per second, so a fast flick can't skip a dial's numbers
    dial_speed = 40,            -- how fast (wrist degrees per second) a safe dial turns to the next number
    dial_fov = 45,              -- zoom while holding a safe dial or knob so the numbers are readable (0 = no zoom)
    -- Valves and vault wheels (the red valves in "...The Harder They Fall"): F grabs, mouse right or mouse wheel down
    -- turns clockwise (that opens them), F lets go
    valve_sensitivity = 2.0,    -- degrees per mouse unit (a half turn is about a hand's width of mouse travel)
    valve_notch = 45,           -- degrees per mouse wheel notch
    valve_speed = 240,          -- the most it turns per second
    valve_autofinish = 45,      -- within this many degrees of the end it finishes the turn by itself (0 = off)

    -- Throwing (LMB while holding a loot bag or a bottle/cup): where the hand pulls back to and swings to (camera space)
    throw = { back = { 10, 25, -10 }, release = { 75, 10, 15 } },

    -- Aim assist: measures each gun's sights and steers the hand so the gun points at the crosshair
    aim_assist = true,
    aim_assist_gain = 0.2,
    hip_zero_distance = 1000,   -- cm; hip-fire shots cross the crosshair at this distance
    ads_sight_distance = 22,    -- cm from the eye to the rear sight while aiming (guns without a relief below)
    ads_sight_height = 0,       -- raise/lower the sights in the view while aiming (cm)
    ads_dot_closer = 8,         -- red dot sights: the gun sits this much closer (cm) than with its iron sights (every gun;
                                -- per gun: dot_closer in ads_weapons, or dot_relief = cm from the eye to the dot itself)
    ads_dot_min = 10,           -- ...but the dot never comes nearer than this to the eye (cm)
    ads_zero_distance = 2000,   -- cm; aimed shots cross the crosshair at this distance
    ads_time = 0.25,            -- seconds to bring a gun up (guns without a time below)
    ads_out = 0.8,              -- lowering takes this much of the raise time
    ads_level = true,           -- keep the sights upright while aiming
    ads_crosshair = false,      -- false: the crosshair dot hides while the sights are up (aim with the sights)
    -- Aiming per gun. relief = cm from the eye to the rear sight, time = seconds for a full raise, cant = degrees the
    -- gun tilts halfway up, push = cm it moves out halfway up (both are gone once it's up). y / z = where the sight
    -- line runs, in the gun's own space (cm; y forward along the barrel, z up): the rear sight and the height of the
    -- line over the front sight. Rifles find their iron sights by themselves; an enabled red dot always wins.
    -- "flatmode adsinfo" shows the held gun's values, "flatmode adstune z=9.1" tries one out until the next restart.
    ads_classes = {
        Pistol  = { relief = 28, time = 0.18, cant = 4, push = 2 },   -- v0.3.24: closer, FPS-style (was 38)
        SMG     = { relief = 14, time = 0.22, cant = 6, push = 3 },   -- v0.3.24: closer, FPS-style (was 26, then 18)
        Rifle   = { relief = 20, time = 0.27, cant = 7, push = 4 },
        Shotgun = { relief = 15, time = 0.30, cant = 8, push = 4 },   -- v0.3.24: closer, FPS-style (was 26, then 20)
        default = { relief = 22, time = 0.25, cant = 5, push = 3, above_bore = 2 },
    },
    ads_weapons = {
        -- pistols (measured v0.3.22: the front sight's top level with the rear notch, on the crosshair)
        Kogl19         = { y = -0.1, z = 9.0 },
        CobraM2Compact = { y = -2, z = 8.9 },
        CrimsonHawk    = { y = -2, z = 9.7 },
        ES364Mammoth   = { y = 0, z = 10.3 },
        -- SMGs: the rear aperture's centre
        GygaxKentaur   = { y = 0.8, z = 13.0 },
        MR70           = { z = 14.25 },
        Yasha          = { y = -12, z = 12.45 },
        -- shotguns
        Sanbury790     = { z = 13.3, relief = 11 }, -- over the receiver to the front ring; v0.3.25: closer (15 = shotgun default)
        Broadhurst     = { z = 12.5 },              -- the three dots on the frame
        LanzettaPava   = { z = 5.8 },               -- along the rib to the bead
        -- rifles: the sight line comes from their iron sight posts; relief puts the eye about 14 cm in front of the
        -- butt (a cheek weld), so rifles with the rear sight halfway along (HPG05, AV56) hold it further out
        HPG05          = { relief = 32 },   -- v0.3.26: closer (was 40)
        AV56           = { relief = 31 },
        AmcarB4        = { relief = 18 },
        AMRClassic     = { relief = 18 },
        ["815WK"]      = { relief = 15 },
    },
    support_hand = "ads",       -- left hand on the foregrip: "ads" = only while aiming (hip fire is one-handed), "always", or false
    shotgun_auto_pump = true,   -- pump shotguns (Sanbury 790): the left hand works the pump by itself after each shot
    grenade_speed = 1300,       -- cm/s: how hard LMB / T throws a grenade (about 8-9 m on flat ground)
    grenade_lift = 10,          -- degrees above where you look

    -- Ping (keys.ping, middle mouse): drops the game's ping marker where you look. On an enemy, loot, a camera... the
    -- game shows its icon and follows it; it disappears after 7 s.
    ping_reach = 5000,          -- cm: how far a ping reaches
    ping_angle = 3,             -- degrees: an enemy / loot / camera this close to the crosshair is pinged instead of the wall behind it

    keys = {
        aim          = "RightMouseButton", -- hold: bring the gun up to the centre of the screen
        grab_right   = "F",     -- toggle: reach where you look with the right hand and grab / let go
                                -- (while holding the watch key: watch hack at the spot in front of you)
        grab_left    = "G",     -- toggle: same with the left hand
        draw_pistol  = "One",   -- grab the pistol from the holster (press again to put it back)
        draw_primary = "Two",   -- grab the primary weapon (press again to put it back)
        syringe      = "Three", -- take the syringe from the inventory (press again to put it back)
        deployable   = "Four",  -- take the deployable (ammo/med bag, sentry...) from the inventory, if you have one
        gadget       = "Five",  -- take the gadget (grappling hook, grenade...) from the inventory, if you have one
        throw        = "T",     -- throw the bag you carry (left hand), or the bag / bottle in your right hand
        mask         = "V",     -- put the mask on
        jammer       = "J",     -- pistol with a camera jammer fitted: fire it at the camera under the crosshair
        reload       = "R",     -- automatic magazine swap; shotguns: load shells until full (R again or LMB = stop)
        watch        = "Tab",   -- hold: raise the left wrist to read the smartwatch
        dismiss      = "Enter", -- close the tutorial / welcome pop-ups
        skip_intro   = "SpaceBar", -- skip the intro (logo/cutscene) and go to the safehouse
        menu         = "Escape", -- open / close the pause menu (the game's own key is Q; "" keeps Q)
        ping         = "MiddleMouseButton", -- ping where you look
    },
}
