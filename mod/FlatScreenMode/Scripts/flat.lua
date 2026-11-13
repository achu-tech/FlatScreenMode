-- FlatScreenMode: keyboard + mouse play for PAYDAY: Aces High (UE 5.6 + AngelScript) without a headset.
-- How it works:
--   * The game already supports "untracked" hands: it places them relative to the camera using
--     MPHandTransformRules.HandUntrackedDefault[0/1]. We rewrite those poses so the hands sit in front of you.
--   * Grabbing uses the MotionController components, which stay on the floor without a headset, so every frame
--     we move them onto the visible hands.
--   * Mouse X turns the character (RotateCharacter), mouse Y pitches the camera; the hands follow the camera.
--   * Grip / trigger / buttons are the game's own Enhanced Input actions (IA_Grip_R, IA_Trigger_R...), injected
--     through the local Enhanced Input subsystem. WASD, Shift, Ctrl, LMB and Q are already bound by the game.
local DIR = ...
local cfg = dofile(DIR .. "config.lua")

local function log(fmt, ...)
    local ok, s = pcall(string.format, tostring(fmt), ...)
    print("[FlatScreenMode] " .. (ok and s or tostring(fmt)) .. "\n")
end

------------------------------------------------------------------------------------------------ engine helpers
local KSL = nil
local function ksl()
    if not KSL or not KSL:IsValid() then KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    return KSL
end

local function localPC()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in ipairs(pcs) do
        if pc:IsValid() and pc:IsLocalController() then return pc end
    end
    return nil
end

local function console(cmd)
    local pc = localPC()
    if pc then ksl():ExecuteConsoleCommand(pc, cmd, pc); log("console: %s", cmd) end
end

-- The game puts the view back to 120 degrees (its untracked-VR default) every frame, so setting the camera's FOV
-- doesn't stick; the camera manager's locked FOV (PlayerController:FOV, what the "fov" command calls) does.
-- 0 = the game's own 120. Called directly, not through the console. Locking it crashed the game (inside UE4SS,
-- ~60 s after a map load) in 3 of 5 Small Bank loads, so with fov = 0 nothing is locked at all; the drill zoom
-- locks it only while a lever is held and unlocks on release.
local function setFov(deg)
    local pc = localPC()
    if pc then pcall(function() pc:FOV(deg) end) end
end
local function applyFov() if (cfg.fov or 0) > 0 then setFov(cfg.fov) end end

local function prop(obj, name)   -- plain (non-object) property, or nil when this kind of actor doesn't have it
    local ok, v = pcall(function() return obj[name] end)
    if ok and type(v) ~= "userdata" then return v end
    return nil
end

local keyCache = {}
local function key(name)
    local k = keyCache[name]
    if not k then k = { KeyName = FName(name) }; keyCache[name] = k end
    return k
end

local actionCache = {}
local function action(name)
    local a = actionCache[name]
    if a and a:IsValid() then return a end
    for _, dir in ipairs({ "/Game/Game/Input/InputActions/", "/Game/Game/Input/InputActions/Button_A/",
                           "/Game/Game/Input/InputActions/Button_B/" }) do
        a = StaticFindObject(dir .. name .. "." .. name)
        if a and a:IsValid() then actionCache[name] = a; return a end
    end
    return nil
end

local inputSub = nil
local function inject(name, value)
    if not inputSub or not inputSub:IsValid() then inputSub = FindFirstOf("EnhancedInputLocalPlayerSubsystem") end
    local a = action(name)
    if inputSub and a then inputSub:InjectInputVectorForAction(a, { X = value, Y = 0, Z = 0 }, {}, {}) end
end

-- FRotator (degrees) -> FQuat, same convention as FRotator::Quaternion()
local function quat(pitch, yaw, roll)
    local r = math.pi / 360
    local sp, cp = math.sin(pitch * r), math.cos(pitch * r)
    local sy, cy = math.sin(yaw * r), math.cos(yaw * r)
    local sr, cr = math.sin(roll * r), math.cos(roll * r)
    return cr * sp * sy - sr * cp * cy, -cr * sp * cy - sr * cp * sy, cr * cp * sy - sr * sp * cy, cr * cp * cy + sr * sp * sy
end

------------------------------------------------------------------------------------------------ hand poses
-- HandUntrackedDefault is a 2-element FTransform array (0 = left, 1 = right). Lua property access only reaches
-- element 0, so we write elements through reflection + ImportText.
local lastPose = { [0] = "", [1] = "" }
-- Hamilton product a * b (FQuat operator*: b's rotation first, then a's)
local function quatMul(ax, ay, az, aw, bx, by, bz, bw)
    return aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz
end
-- cant (optional): an extra tilt in degrees about the camera's forward axis (the line of sight), used by ADS to keep
-- the gun upright and to tilt it a little while it comes up
local function handQuat(pitch, yaw, roll, cant)
    local qx, qy, qz, qw = quat(pitch or 0, yaw or 0, roll or 0)
    if cant and cant ~= 0 then
        local h = math.rad(cant) / 2
        qx, qy, qz, qw = quatMul(math.sin(h), 0, 0, math.cos(h), qx, qy, qz, qw)
    end
    return qx, qy, qz, qw
end
local function writeHand(idx, x, y, z, qx, qy, qz, qw)
    local text = string.format("(Rotation=(X=%.5f,Y=%.5f,Z=%.5f,W=%.5f),Translation=(X=%.2f,Y=%.2f,Z=%.2f),Scale3D=(X=1,Y=1,Z=1))",
        qx, qy, qz, qw, x, y, z)
    if lastPose[idx] == text then return end
    lastPose[idx] = text
    for _, rules in ipairs(FindAllOf("MPHandTransformRules") or {}) do
        local prop = rules:Reflection():GetProperty("HandUntrackedDefault")
        prop:ImportText(text, prop:ContainerPtrToValuePtr(rules, idx), 0, rules)
    end
end

local function poseOf(p) return p.x, p.y, p.z, p.pitch, p.yaw or 0, p.roll or 0 end

------------------------------------------------------------------------------------------------ state
local S = _G.FlatScreenModeState or {}
_G.FlatScreenModeState = S
local S_defaults = {
    pawn = nil, pitch = 0.0, aim = 0.0,
    grip = { [0] = false, [1] = false },   -- latched grips, 0 = left, 1 = right
    override = { [0] = nil, [1] = nil },   -- temporary hand targets (camera space) used by macros
    steps = {},                             -- macro queue
    keysDown = {}, crosshair = nil, warnedOnline = false,
}

for k, v in pairs(S_defaults) do if S[k] == nil then S[k] = v end end
S.pawn = nil  -- force setup after a reload
S.keepGrip = true  -- ...but keep holding whatever the hands hold

local function now() return os.clock() end

------------------------------------------------------------------------------------------------ hand smoothing
-- v0.3.27. The game applies a hand target with about a frame of lag and adds no smoothing of its own, so every time a
-- hand switched to another pose source (a macro waypoint, back home, the watch, the foregrip...) it jumped in one
-- frame. Each frame the tick names the source that drives each hand (a key: "aim", "rest", "watch", "support"... or
-- the override table itself, so every new reachTo / reachFollow is a new source). When the key changes, the hand
-- starts from the pose it was really drawn at (and the speed it was moving at) and eases onto the new source over
-- T seconds: output = target(this frame) + an offset that decays to zero on a minimum-jerk curve (the curve the ADS
-- raise uses). The target is re-read every frame, so a moving source (a followed world point, the ADS raise) is
-- tracked the whole time, and once the offset is gone the output is exactly the source's own value: no lag in steady
-- state, and aiming, aim assist and the mouse-driven controls are untouched. A switch in the middle of a move starts
-- from the current pose and speed, so it curves on instead of stopping.
--   opts.instant: switch into this source with no blend (lever, rotary, the syringe stab, magazine insertion)
--   opts.raw:     write the target exactly this frame, ending any blend (the pump stroke)
--   opts.T:       a fixed blend time in seconds (the throw's swing)
local RAW, INSTANT = { raw = true }, { instant = true }
local function newBlend() return { has = false, active = false, ox = 0, oy = 0, oz = 0, oqx = 0, oqy = 0, oqz = 0, oqw = 1, ot = 0 } end
local function resetBlend() S.blend = { [0] = newBlend(), [1] = newBlend() } end
if not (S.blend and S.blend[0] and S.blend[1]) then resetBlend() end

local function keyName(k)
    if type(k) == "table" then return "override#" .. tostring(k.gen or "?") end
    return tostring(k)
end

local function smoothHand(idx, key, x, y, z, pitch, yaw, roll, cant, opts)
    local qx, qy, qz, qw = handQuat(pitch, yaw, roll, cant)
    local b = S.blend[idx]
    local t = now()
    if key ~= b.key then
        local from = b.key
        b.key, b.active = key, false
        local on = cfg.hand_smooth ~= false and not S.smoothOff and b.has and not (opts and (opts.instant or opts.raw))
        if on then
            local dx, dy, dz = b.ox - x, b.oy - y, b.oz - z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            -- rotation offset (camera space): q_off * target = the pose drawn last frame; shortest way round
            local cx, cy, cz, cw = quatMul(b.oqx, b.oqy, b.oqz, b.oqw, -qx, -qy, -qz, qw)
            if cw < 0 then cx, cy, cz, cw = -cx, -cy, -cz, -cw end
            local ang = 2 * math.acos(math.min(1, cw))
            local angDeg = math.deg(ang)
            if d > 0.3 or angDeg > 0.5 then
                -- longer moves take longer (rotation counts 0.3 cm per degree): about 0.1 s for a short move, 0.22 s
                -- over the shoulder
                local T = opts and opts.T
                if not T then
                    local mn, mx = cfg.hand_smooth_min or 0.08, cfg.hand_smooth_max or 0.22
                    T = math.max(mn, math.min(mx, 0.06 + math.max(d, angDeg * 0.3) / (cfg.hand_smooth_speed or 400)))
                end
                -- the speed the hand was moving at (from the last two poses drawn), carried into the new move so a
                -- switch mid-move curves on. Scaled by T (the curve works in units of the whole move) and limited
                -- so it can't overshoot the target (toward it: at most 2.5x the offset) or swing far out of the way
                local vx, vy, vz = 0, 0, 0
                local dt = b.ot - (b.pt or 0)
                if b.pt and dt > 0.001 and dt < 0.1 and t - b.ot < 0.1 and d > 0.01 then
                    vx, vy, vz = (b.ox - b.px) / dt * T, (b.oy - b.py) / dt * T, (b.oz - b.pz) / dt * T
                    local ux, uy, uz = dx / d, dy / d, dz / d
                    local along = vx * ux + vy * uy + vz * uz   -- + = away from the target
                    local px, py, pz = vx - along * ux, vy - along * uy, vz - along * uz
                    along = math.max(-2.5 * d, math.min(0.5 * d, along))
                    local pn = math.sqrt(px * px + py * py + pz * pz)
                    if pn > 1.5 * d then local k = 1.5 * d / pn; px, py, pz = px * k, py * k, pz * k end
                    vx, vy, vz = along * ux + px, along * uy + py, along * uz + pz
                end
                b.x0, b.y0, b.z0, b.vx, b.vy, b.vz = dx, dy, dz, vx, vy, vz
                local sh = math.sqrt(cx * cx + cy * cy + cz * cz)
                if ang > 1e-4 and sh > 1e-6 then b.ax, b.ay, b.az, b.ang = cx / sh, cy / sh, cz / sh, ang
                else b.ang = 0 end
                b.t0, b.T, b.active = t, T, true
                if S.smoothDebug then
                    log("smooth: %s hand %s -> %s: %.1f cm, %.0f deg, %.0f cm/s carried, T %.2f s", idx == 1 and "right" or "left",
                        keyName(from), keyName(key), d, angDeg, math.sqrt(vx * vx + vy * vy + vz * vz) / T, T)
                end
            elseif S.smoothDebug then
                log("smooth: %s hand %s -> %s: already there", idx == 1 and "right" or "left", keyName(from), keyName(key))
            end
        elseif S.smoothDebug then
            log("smooth: %s hand %s -> %s: no blend%s", idx == 1 and "right" or "left", keyName(from), keyName(key),
                (opts and (opts.instant or opts.raw)) and " (exact source)" or "")
        end
    end
    if opts and opts.raw then b.active = false end
    local ox, oy, oz, oqx, oqy, oqz, oqw = x, y, z, qx, qy, qz, qw
    if b.active then
        local s = (t - b.t0) / b.T
        if s >= 1 then
            b.active = false
        else
            local s3 = s * s * s
            local s4, s5 = s3 * s, s3 * s * s
            local P = 1 - 10 * s3 + 15 * s4 - 6 * s5   -- the offset left (1 -> 0, minimum jerk)
            local Q = s - 6 * s3 + 8 * s4 - 3 * s5     -- the carried speed's share (0 -> 0, starts at the old speed)
            ox, oy, oz = x + b.x0 * P + b.vx * Q, y + b.y0 * P + b.vy * Q, z + b.z0 * P + b.vz * Q
            if b.ang > 0 then
                local h = b.ang * P / 2
                local sn = math.sin(h)
                oqx, oqy, oqz, oqw = quatMul(b.ax * sn, b.ay * sn, b.az * sn, math.cos(h), qx, qy, qz, qw)
            end
        end
    end
    b.px, b.py, b.pz, b.pt = b.ox, b.oy, b.oz, b.has and b.ot or nil
    b.ox, b.oy, b.oz, b.oqx, b.oqy, b.oqz, b.oqw, b.ot, b.has = ox, oy, oz, oqx, oqy, oqz, oqw, t, true
    writeHand(idx, ox, oy, oz, oqx, oqy, oqz, oqw)
end

-- the hand has finished easing onto its current source (and that source is the override set last, if any)
local function arrived(hand)
    local b = S.blend[hand]
    if b.active then return false end
    local o = S.override[hand]
    return o == nil or b.key == o
end

local function camera() return S.pawn and S.pawn.Camera end

-- world location -> camera space (x forward, y right, z up)
local function toCam(w)
    local cam = camera()
    local o = cam:K2_GetComponentLocation()
    local f, r, u = cam:GetForwardVector(), cam:GetRightVector(), cam:GetUpVector()
    local dx, dy, dz = w.X - o.X, w.Y - o.Y, w.Z - o.Z
    return dx * f.X + dy * f.Y + dz * f.Z, dx * r.X + dy * r.Y + dz * r.Z, dx * u.X + dy * u.Y + dz * u.Z
end

local function slotItem(slot)
    local lc = S.pawn.LoadoutComponent
    if not lc or not lc:IsValid() then return nil end
    local it = lc:GetStoredItemInSlot(slot)
    if it and it:IsValid() then return it end
    return nil
end

local function heldBy(hand)   -- actor currently attached to the character near that hand (best effort)
    local ic = hand == 1 and S.pawn.RightInteractionComponent or S.pawn.LeftInteractionComponent
    if not ic or not ic:IsValid() then return nil end
    local hl = ic:GetHandPrimitiveLocation()
    local best, bestD = nil, 35 * 35
    for _, cls in ipairs({ "CLPInteractableActor" }) do
        for _, a in ipairs(FindAllOf(cls) or {}) do
            if a:IsValid() then
                local par = a:GetAttachParentActor()
                if par and par:IsValid() and par == S.pawn then
                    local l = a:K2_GetActorLocation()
                    local d = (l.X - hl.X) ^ 2 + (l.Y - hl.Y) ^ 2 + (l.Z - hl.Z) ^ 2
                    if d < bestD then best, bestD = a, d end
                end
            end
        end
    end
    return best
end

------------------------------------------------------------------------------------------------ macros
local function after(delay, fn) table.insert(S.steps, { t = now() + delay, fn = fn }) end
local function busy() return #S.steps > 0 end

local function setGrip(hand, on)
    if S.grip[hand] == on then return end
    S.grip[hand] = on
    if not on then
        local name = hand == 1 and "IA_Grip_R" or "IA_Grip_L"
        inject(name, 0); after(0.03, function() inject(name, 0) end)
    end
end

-- every override is a new table, so the hand smoother sees each one as a new source and eases into it; opts: instant,
-- T (see smoothHand)
local function setOverride(hand, o, opts)
    S.overrideGen = (S.overrideGen or 0) + 1
    o.gen = S.overrideGen
    if opts then o.instant, o.T = opts.instant, opts.T end
    S.override[hand] = o
end
local function reachTo(hand, x, y, z, opts) setOverride(hand, { x = x, y = y, z = z }, opts) end
-- keep a hand on a moving world point (re-evaluated every frame), e.g. a socket on the gun
local function reachFollow(hand, worldFn, opts) setOverride(hand, { fn = worldFn }, opts) end
local function handHome(hand) S.override[hand] = nil end
-- stop following and keep the hand where its follow point was last frame (same source, so no new blend). Used when
-- a grip closes on the followed item: it then hangs on the hand, and following it would make the hand chase itself.
local function freeze(hand)
    local o = S.override[hand]
    if not (o and o.fn) then return end
    if not o.x then   -- not evaluated by a tick yet
        local ok, w = pcall(o.fn)
        if not (ok and w) then return end
        o.x, o.y, o.z = toCam(w)
    end
    o.fn = nil
end
-- run fn once the hand has eased onto its target (at least minD s from now, at most maxD), plus a moment for the game's
-- one frame of lag. Steps run in the order they were queued, so queue what comes next from inside fn.
local function afterArrive(hand, minD, maxD, fn)
    local t0 = now()
    local function poll()
        if now() - t0 < maxD and not arrived(hand) then after(0.02, poll); return end
        after(0.04, fn)
    end
    after(minD, poll)
end

-- reach for something on the body: swing the hand out to the side first so it does not pass the chest
-- (the mask hangs there and would be grabbed instead), then settle on the item before gripping
local function handLoc(hand)
    local ic = hand == 1 and S.pawn.RightInteractionComponent or S.pawn.LeftInteractionComponent
    return ic:GetHandPrimitiveLocation()
end
local function dist(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end

-- reach for something on the body: swing the hand out to the side first so it does not pass the chest
-- (the mask hangs there and would be grabbed instead), settle on the item, grip once the hand is there
-- Online (a client of the server), a holstered item is never handed out by the game's own grab: on our PC the loadout's
-- slot hover (what the hand's grab asks for holstered items) found nothing even with the hand 2 cm from the pistol
-- (ReceiveGetHoveredSlotIndex -1 online, 2 offline), while world objects grabbed fine. What works (measured in a
-- closed online session): ask the server to take the item into the hand (InteractionBroker:ServerBeginInteraction,
-- the call a VR client's grab sends; the server attaches it to the hand within ~0.4 s, with collision on), then close
-- the grip, so our own hand grabs it like any item in reach and binds it (IsBoundToLocalPlayer true).
local holding   -- (defined below, with the grab code)
local function serverTake(hand, item)
    local ok = pcall(function()
        local sock = FName("s_grip")
        pcall(function()
            local pts = item.InteractionProperties.InteractionPoints
            if #pts > 0 then sock = pts[1].SocketName end
        end)
        S.pawn.InteractionBroker:ServerBeginInteraction(item:K2_GetRootComponent(), hand, sock)
    end)
    return ok
end
-- an item's own grab point (its first interaction point's socket, e.g. a gun's s_grip), else its origin: a rifle's
-- origin is far from its grip, and a hand near the origin grabbed a loose magazine lying closer instead
local function itemGripPoint(item)
    local ok, loc = pcall(function()
        local root = item:K2_GetRootComponent()
        local sock = FName("s_grip")
        pcall(function()
            local pts = item.InteractionProperties.InteractionPoints
            if #pts > 0 then sock = pts[1].SocketName end
        end)
        if root:DoesSocketExist(sock) then return root:GetSocketLocation(sock) end
        return item:K2_GetActorLocation()
    end)
    if ok and loc then return { X = loc.X, Y = loc.Y, Z = loc.Z } end
    return nil
end
local function attachedToUs(item)
    local ok, yes = pcall(function()
        local par = item:GetAttachParentActor()
        return par and par:IsValid() and par:GetFullName() == S.pawn:GetFullName()
    end)
    return ok and yes
end

-- take: the loadout item being drawn (online it's taken out of its slot by the server first, see serverTake)
local function grabAtWorld(hand, getLoc, thenFn, take)
    local side = hand == 1 and 1 or -1
    reachTo(hand, 25, 25 * side, -30)
    local tries = 0
    local following = false
    local function grip(d)
        log("grip at %.0f cm from target", d)
        setGrip(hand, true)
        -- (v0.3.28: out past the side point and on without stopping there; was 0.25 s, then 0.2 s at the side point)
        after(0.2, function() reachTo(hand, 25, 25 * side, -30) end)
        after(0.3, function() if thenFn then thenFn() else handHome(hand) end end)
    end
    local function settle()
        local loc = getLoc(); if not loc then handHome(hand); return end
        -- (v0.3.27: followed every frame; it used to be re-aimed every 40 ms, and each re-aim would restart the
        -- hand's ease onto it)
        if not following then following = true; reachFollow(hand, getLoc) end
        local d = dist(handLoc(hand), loc)
        tries = tries + 1
        if d > 8 and tries < 25 then after(0.04, settle); return end
        -- there (or out of tries): hold this point. A grabbed item hangs on the hand, and online the server moves the
        -- item to the body's hand anchor by the hip: following it would drag the hand along
        freeze(hand)
        if take and S.wasOnline and take:IsValid() then
            -- the server attaches it to the body mesh's hand anchor (InteractionPointAnchor_R), which only roughly
            -- follows our hand (10 cm off, more when the hand moves): keep the hand on the item itself, close the
            -- grip once it's there, and stay until our hand holds it (gripping the moment it attached and pulling
            -- away 0.25 s later left it hanging on the anchor)
            if not attachedToUs(take) and not serverTake(hand, take) then log("draw: the server call failed"); grip(d); return end
            local waited = 0
            local decoys = {}   -- actors whose collision we switched off on our PC for this grab
            local regripped = false
            local function heldIsTake()
                local ok, same = pcall(function() local h = holding(hand); return h and h:GetOwner():GetFullName() == take:GetFullName() end)
                return ok and same
            end
            local function holdOn()
                waited = waited + 0.05
                if not holding(hand) and waited < 1.2 then after(0.05, holdOn); return end
                if holding(hand) and not heldIsTake() and not regripped then
                    -- it closed on something else (a shell clip from the pouch's stored item, seen online with the
                    -- Broadhurst): let go and grip once more
                    regripped = true
                    local n = "?"; pcall(function() n = holding(hand):GetOwner():GetFName():ToString() end)
                    log("online: the hand took %s instead, gripping again", n)
                    setGrip(hand, false)
                    after(0.25, function() setGrip(hand, true); waited = 0; after(0.05, holdOn) end)
                    return
                end
                for _, a in ipairs(decoys) do pcall(function() if a:IsValid() then a:SetActorEnableCollision(true) end end) end
                if not holding(hand) then log("online: couldn't take it into the hand")
                elseif not heldIsTake() then log("online: the hand holds something else, not %s", take:GetFName():ToString()) end
                -- (v0.3.28: the hand is already home, in front of the chest: carry on from there. It used to swing
                -- out to the side point and back first, a leftover of the offline draw)
                after(0.05, function() if thenFn then thenFn() else handHome(hand) end end)
            end
            -- (checked every frame, v0.3.28: polled every 0.05 s, the item hung at the body's anchor by the hip for up
            -- to 4 frames before it went onto the hand)
            local takeT0 = now()
            local function waitTake()
                waited = now() - takeT0
                if not attachedToUs(take) and waited < 1.5 then after(0.0, waitTake); return end
                if not attachedToUs(take) then log("online: the server didn't hand it over (%.1f s)", waited); handHome(hand); return end
                -- The server hangs the item on the character mesh's hand anchor (CharacterMesh0, socket
                -- InteractionPointAnchor_R/L), and on our PC that mesh's arm just hangs: the anchor is by the hip, 60 cm
                -- below the eye, and stays there when our hand moves (measured 2026-11-10 with the Broadhurst; the
                -- v0.3.17 note that it "roughly follows our hand" didn't hold). Gripping it there put the hand in other
                -- grab areas, which won: the holstered pistol's (13 cm away; the hand took the pistol, twice in a row,
                -- and holstered items ignore collision, so switching theirs off didn't help), a shell clip from the
                -- ammo pouch's stored item, and (v0.3.17) the pouch itself. So bring the hand to the resting pose in
                -- front of the chest, move the item there on our PC (still attached; the server doesn't move it back:
                -- measured, it stayed 0 cm from the hand), and grip there. Our grab then takes it like any item in reach.
                handHome(hand)
                local function snap()
                    pcall(function()
                        if not take:IsValid() then return end
                        local gp, h = itemGripPoint(take), handLoc(hand)
                        if not (gp and h) then return end
                        local a = take:K2_GetActorLocation()
                        take:K2_SetActorLocation({ X = a.X + h.X - gp.X, Y = a.Y + h.Y - gp.Y, Z = a.Z + h.Z - gp.Z }, false, {}, true)
                    end)
                end
                -- (v0.3.28) the item rides on the hand all the way home (moved onto it every frame), and the grip closes
                -- as soon as the hand is there. Before, the hand came home empty, waited 0.4 s, and then the item popped
                -- into it (0.7 s from attach to grip).
                -- (one chain of steps: the queue runs in order, so a separate poll queued beside it would hold it up)
                local rideT0, thereAt = now(), nil
                local gripNow
                local function ride()
                    snap()
                    local t = now() - rideT0
                    if t >= 0.1 and not thereAt and arrived(hand) then thereAt = t end
                    -- once home plus a moment for the game's frame of lag (at most 0.5 s)
                    if (thereAt and t >= thereAt + 0.04) or t >= 0.5 then return gripNow() end
                    after(0.0, ride)
                end
                -- Grabbables that can still be taken instead of the item, switched off on our PC for the grab, back on
                -- after: the magazine in a gun's grip (the hand took the pistol's magazine instead of the pistol, twice)
                -- and the ammo pouch's stored item (slot 1, which online lies hidden but grabbable where the server
                -- spawned it, see the reload). Whole actors: the clip was held by a non-root mesh.
                local cands = {}
                pcall(function() cands[#cands + 1] = take.FirearmComponent.AttachedMagazine end)
                pcall(function() cands[#cands + 1] = S.pawn.LoadoutComponent:GetStoredItemInSlot(1) end)
                for _, a in ipairs(cands) do
                    pcall(function()
                        if a and a:IsValid() and a:GetFullName() ~= take:GetFullName() and a:GetActorEnableCollision() then
                            a:SetActorEnableCollision(false); decoys[#decoys + 1] = a
                        end
                    end)
                end
                gripNow = function()
                    local dn = {}; for _, a in ipairs(decoys) do pcall(function() dn[#dn + 1] = a:GetFName():ToString() end) end
                    log("grip (online, the server took it out of the slot)%s", S.grabDebug and (", collision off: " .. table.concat(dn, " ")) or "")
                    setGrip(hand, true); waited = 0
                    after(0.05, holdOn)
                end
                ride()
            end
            after(0.05, waitTake)
            return
        end
        grip(d)
    end
    -- (v0.3.28: head for the item while the hand is still on its way out to the side point, so it curves through that
    -- point instead of stopping at it; was 0.15 s, when the hand had already stopped there)
    after(0.08, settle)
end

-- inside one of the game's hide-loadout areas (CLPHideLoadoutVolume: where it hides your weapons), by the box itself
-- (IsOverlappingActor said no even at a box's centre)
local function inHideLoadoutArea()
    local pl = S.pawn:K2_GetActorLocation()
    for _, v in ipairs(FindAllOf("CLPHideLoadoutVolume") or {}) do
        local box = v:IsValid() and v.CollisionComponent
        if box and box:IsValid() then
            local c, e = box:K2_GetComponentLocation(), box:GetScaledBoxExtent()
            local d = { X = pl.X - c.X, Y = pl.Y - c.Y, Z = pl.Z - c.Z }
            local function along(a) return math.abs(d.X * a.X + d.Y * a.Y + d.Z * a.Z) end
            if along(box:GetForwardVector()) <= e.X and along(box:GetRightVector()) <= e.Y and along(box:GetUpVector()) <= e.Z then return true end
        end
    end
    return false
end
-- The game's rule: no weapons until you're masked (the casing phase) and none inside its hide-loadout areas; it hides
-- the pistol and primary until then. Offline the game enforces it itself (a hidden holstered gun can't be grabbed).
-- Online the mod draws through the server (serverTake), and the server handed a gun over unmasked (user report,
-- 2026-11-10: pistol and rifle drawn and fired in the online lobby before the mask was on). So check it ourselves.
local function weaponsAllowed()
    if not slotItem(15) then return false, "put your mask on first (V)" end
    local ok, inside = pcall(inHideLoadoutArea)
    if ok and inside then return false, "weapons are put away here" end
    return true
end

-- loadout slots in the collapsible inventory (ECLPLoadoutSlot): syringe, deployable, gadget
local INVENTORY_SLOTS = { [2] = true, [5] = true, [6] = true }

local toggleSlot
local slotWorld   -- defined with the reload code below; the holster step uses it
toggleSlot = function(slot, label)
    if busy() then return end
    if S.grip[1] then          -- already holding something in the right hand: put it away
        local current = S.heldSlot
        if S.supporting then setGrip(0, false); S.supporting = false end
        local function letGo()
            setGrip(1, false)
            S.heldSlot = nil; S.syringe = nil
            -- (steps run in the order they were queued: the hand goes home before the next draw starts, or the draw
            -- would see the macro still busy and give up)
            local switching = current ~= slot
            if S.override[1] and not switching then after(0.15, function() handHome(1) end) end
            after(0.25, function()
                -- the server's call: offline it puts the item back at once; online (a client) it may do nothing, but
                -- a gun let go of at its holster is taken back by the game anyway (below)
                local lc = S.pawn.LoadoutComponent
                if lc and lc:IsValid() then pcall(function() lc:ReturnDroppedItemsToLoadoutImmediately() end) end
            end)
            log("holster")
            if switching then
                -- (v0.3.28) a switch goes from this holster straight on to the other item: it used to go home (in front
                -- of the chest), stop, and go out again 0.4 s later. If the draw doesn't start (say, no weapons allowed
                -- here), the hand goes home
                after(0.3, function()
                    toggleSlot(slot, label)
                    if not busy() and S.override[1] then handHome(1) end
                end)
            end
        end
        if current == 3 or current == 4 then
            -- guns: let go at the holster like a VR hand, so the game itself holsters it (measured: pistol let go 4 cm
            -- from the holster -> back in slot 4 at once, without ReturnDroppedItemsToLoadoutImmediately, which is
            -- server-side and wouldn't help an online client)
            reachFollow(1, function() return slotWorld(current) end)
            -- let go once the hand is at the holster (v0.3.27: it eases there now; was a fixed 0.35 s)
            afterArrive(1, 0.2, 0.7, letGo)
        else
            letGo()
        end
        return
    end
    if (slot == 3 or slot == 4) and (S.wasOnline or S.onlineTest) and not S.unmaskedTest then
        local ok, why = weaponsAllowed()
        if not ok then log("%s: %s", label, why); return end
    end
    local item = slotItem(slot)
    -- the syringe, deployable and gadget sit in the collapsible inventory in front of the chest: open it first
    if item and INVENTORY_SLOTS[slot] and item.bHidden then
        pcall(function() S.pawn.LoadoutComponent:ToggleInventory() end)
    end
    if item then
        S.slotMemory = S.slotMemory or {}
        S.slotMemory[slot] = item
    elseif slot == 3 or slot == 4 then
        -- holster empty: if our own weapon is lying around within reach, pick it back up
        local lost = S.slotMemory and S.slotMemory[slot]
        if not (lost and lost:IsValid()) then
            local cam, best = camera():K2_GetComponentLocation(), 230
            for _, a in ipairs(FindAllOf("CLPFirearm") or {}) do
                local par = a:IsValid() and a:GetAttachParentActor()
                -- (online also one stuck on our body's hand anchor: see the draw in grabAtWorld; holstered guns hang on
                -- the loadout pivot actor, not on us, so they don't count)
                if a:IsValid() and (not (par and par:IsValid()) or (S.wasOnline and attachedToUs(a))) then
                    local d = dist(a:K2_GetActorLocation(), cam)
                    if d < best then best, lost = d, a end
                end
            end
        end
        if lost and lost:IsValid() and not (lost:GetAttachParentActor() and lost:GetAttachParentActor():IsValid()) then
            local d = dist(lost:K2_GetActorLocation(), camera():K2_GetComponentLocation())
            if d < 230 then item = lost; log("%s: picking it back up (%.0f cm)", label, d) end
        elseif S.wasOnline and lost and lost:IsValid() and attachedToUs(lost) then
            -- online: the server already gave it to the body's hand but our hand didn't close on it (an interrupted
            -- draw): take it from there
            item = lost; log("%s: taking it from the hand anchor", label)
        end
    end
    if not item then log("%s: slot empty", label); return end
    S.heldSlot = slot
    S.syringe = slot == 2 and item or nil
    -- (an item still in its slot: online the server takes it out first, see serverTake; one the server already
    -- put on the body's hand anchor is taken from there the same way)
    local inSlot = slotItem(slot) ~= nil or (S.wasOnline and attachedToUs(item))
    grabAtWorld(1, function() return item:IsValid() and item:K2_GetActorLocation() or nil end, nil, inSlot and item or nil)
    log("draw %s", label)
end

-- what's under the crosshair: the first blocking hit (visibility channel) within maxd cm of the eye, ignoring ourselves
-- and what we hold. Returns { loc, dist, dir } or nil.
-- ignore ourselves and everything attached to us: the mask on the chest, holstered guns, the inventory, held items
-- (GetAttachedActors' out array comes back empty in Lua, so take the loadout's slots: ammo, syringe, guns,
-- deployable, gadget, mask, worn mask)
local function viewIgnore()
    local ignore = { S.pawn }
    for _, slot in ipairs({ 1, 2, 3, 4, 5, 6, 7, 15 }) do
        local it = slotItem(slot)
        if it then table.insert(ignore, it) end
    end
    for h = 0, 1 do
        local okC, c = pcall(function() return (h == 1 and S.pawn.RightInteractionComponent or S.pawn.LeftInteractionComponent):GetCurrentInteraction() end)
        if okC and c and c:IsValid() then table.insert(ignore, c:GetOwner()) end
    end
    return ignore
end

local function traceView(maxd)
    local cam = camera()
    local o, f = cam:K2_GetComponentLocation(), cam:GetForwardVector()
    local e = { X = o.X + f.X * maxd, Y = o.Y + f.Y * maxd, Z = o.Z + f.Z * maxd }
    local ignore = viewIgnore()
    local hit = {}
    local ok, r = pcall(function()
        return ksl():LineTraceSingle(S.pawn, o, e, 0, false, ignore, 0, hit, true, { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
    end)
    if not (ok and r and hit.Location) then return nil end
    return { loc = { X = hit.Location.X, Y = hit.Location.Y, Z = hit.Location.Z }, dist = hit.Distance, dir = { X = f.X, Y = f.Y, Z = f.Z } }
end

-- the object a hand is holding (the game's own record), or nil
holding = function(hand)
    local ok, c = pcall(function() return (hand == 1 and S.pawn.RightInteractionComponent or S.pawn.LeftInteractionComponent):GetCurrentInteraction() end)
    if ok and c and c:IsValid() then return c end
    return nil
end

-- The grabbable object nearest the crosshair (v0.3.4): every pick-up (loot piles, candy, gold, loot bags, C4, the
-- spray gun, a dropped gun) is an ACLPInteractableActor. A bag on the floor a step ahead is 1.9-2.5 m from the eye,
-- past the line trace's reach, so G used to fall back to "straight ahead" and often missed. Picks the one closest to
-- the crosshair within grab_angle degrees and grab_reach cm, not attached to anyone, with nothing in the way; the
-- point is its own grab socket (InteractionProperties) or its location.
local NOT_GRABBED = { "CLPLever", "CLPKnob", "CLPWheel", "CLPCombinationLock", "CLPSwitch" }   -- F turns those
local PAWN_CLASS, SKIP_CLS = nil, {}
local function grabPointOf(a)
    local ok, p = pcall(function()
        local pts = a.InteractionProperties.InteractionPoints
        local sock = #pts > 0 and pts[1].SocketName or nil
        if sock then
            -- loot bag spawners (the Bunker's data disk box) carry the grab socket on GrabbableMesh
            for _, k in ipairs({ "Mesh", "GrabbableMesh" }) do
                local okC, c = pcall(function() return a[k] end)
                if okC and c and c.IsValid and c:IsValid() and c:DoesSocketExist(sock) then return c:GetSocketLocation(sock) end
            end
            local c = a:K2_GetRootComponent()
            if c and c:IsValid() and c:DoesSocketExist(sock) then return c:GetSocketLocation(sock) end
        end
        return nil
    end)
    if ok and p then return p end
    -- no socket: a loot bag spawner's grab volume is GrabbableMesh. The Bunker's data disk box is 16x20x20 cm and its
    -- actor origin is a corner of it; a hand there (19 cm from the middle) caught nothing, the middle works
    local okG, g = pcall(function()
        local c = a.GrabbableMesh
        if not (c and c.IsValid and c:IsValid()) then return nil end
        local o, e, r = {}, {}, {}
        ksl():GetComponentBounds(c, o, e, r)
        return o.X and { X = o.X, Y = o.Y, Z = o.Z } or nil
    end)
    if okG and g then return g end
    return a:K2_GetActorLocation()
end

local function grabTarget(hand)
    local cam = camera()
    local o = cam:K2_GetComponentLocation()
    local reach, best, bestA = cfg.grab_reach or 280, nil, math.rad(cfg.grab_angle or 10)
    PAWN_CLASS = PAWN_CLASS or StaticFindObject("/Script/Engine.Pawn")
    for _, a in ipairs(FindAllOf("CLPInteractableActor") or {}) do
        if a:IsValid() and not a.bHidden then
            local par = a:GetAttachParentActor()
            local onSomeone = par and par:IsValid() and PAWN_CLASS and par:IsA(PAWN_CLASS)
            local skip = onSomeone
            if not skip then
                for _, n in ipairs(NOT_GRABBED) do
                    if SKIP_CLS[n] == nil then SKIP_CLS[n] = StaticFindObject("/Script/Angelscript." .. n) or false end
                    if SKIP_CLS[n] and a:IsA(SKIP_CLS[n]) then skip = true; break end
                end
            end
            if not skip then
                local p = grabPointOf(a)
                local x, y, z = toCam(p)
                local d = math.sqrt(x * x + y * y + z * z)
                local ang = math.atan(math.sqrt(y * y + z * z), x)
                if S.grabDebug and x > 0 and ang < math.rad(25) then log("grab dbg: %s d=%.0f ang=%.1f", a:GetFName():ToString(), d, math.deg(ang)) end
                if x > 0 and d < reach and ang < bestA then best, bestA = { a = a, p = p, d = d }, ang end
            end
        end
    end
    if not best then return nil end
    -- nothing solid between the eye and it (walls, shelves); ignore ourselves, our gear and the target itself
    local ignore = { S.pawn, best.a }
    for _, slot in ipairs({ 1, 2, 3, 4, 5, 6, 7, 15 }) do local it = slotItem(slot); if it then table.insert(ignore, it) end end
    for h = 0, 1 do local c = holding(h); if c then table.insert(ignore, c:GetOwner()) end end
    -- start 60 cm out: our own hands, gun and its magazine are all closer than that (the held rifle's magazine blocked
    -- the line to a bag on the floor)
    local start = 60
    if best.d > start + 25 then
        local dir = { X = (best.p.X - o.X) / best.d, Y = (best.p.Y - o.Y) / best.d, Z = (best.p.Z - o.Z) / best.d }
        local s0 = { X = o.X + dir.X * start, Y = o.Y + dir.Y * start, Z = o.Z + dir.Z * start }
        local hit = {}
        local ok, r = pcall(function()
            return ksl():LineTraceSingle(S.pawn, s0, best.p, 0, false, ignore, 0, hit, true, { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
        end)
        if S.grabDebug then
            local hc = ""
            pcall(function() hc = hit.Component:Get():GetFullName() end)
            log("grab dbg: line of sight hit %s at %.0f (target %.0f) %s", tostring(r), hit.Distance or -1, best.d - start, hc)
        end
        -- blocked only if the hit is well short of it: whatever an object sits in (a shelf: the Bunker's data disk box
        -- is 20 cm behind the shelf's frame) doesn't count
        if ok and r and hit.Distance and hit.Distance < best.d - start - (cfg.grab_through or 35) then return nil end
    end
    return best
end

-- once a grab closes: say what was caught, open an empty hand again, and mark a left-hand catch (not a gun) as carried:
-- the left hand then stays at the side, off the gun's foregrip
local function afterGrab(hand, how)
    local c = holding(hand)
    log("grab%s: %s", how, c and (c:GetOwner():GetFName():ToString() .. "." .. c:GetFName():ToString()) or "nothing")
    if not c then setGrip(hand, false) end
    if c and hand == 0 then
        local okF, fa = pcall(function() return c:GetOwner().FirearmComponent end)
        if not (okF and fa and fa.IsValid and fa:IsValid()) then S.carry = c:GetOwner() end
    end
    handHome(hand)
end

-- F / G. Empty hand: reach to the point under the crosshair (within reach_distance) and grab what's there; nothing in
-- reach = reach straight ahead. Holding something: put it where you look (onto a C4 receiver, into a loot chute, onto a
-- drop-off) and let go.
local function toggleGrab(hand)
    if busy() then return end
    local d = cfg.reach_distance
    local side = hand == 1 and 1 or -1
    if S.grip[hand] and not holding(hand) then
        -- the grip is closed on nothing (a reach that missed): open it, then grab
        setGrip(hand, false)
        after(0.1, function() toggleGrab(hand) end)
        return
    end
    if S.grip[hand] then
        -- a gun stays in the hand (1 / 2 holster it); only other items are put down
        local held = holding(hand)
        local okF, fa = pcall(function() return held:GetOwner().FirearmComponent end)
        if okF and fa and fa.IsValid and fa:IsValid() then log("holding a gun: 1 / 2 holsters it"); return end
        local hit = traceView(d + 40)
        if not hit then setGrip(hand, false); if hand == 0 then S.carry = nil end; return end
        -- the item hangs a few cm from the hand; stop 10 cm short of the surface and let go there
        local k = math.max(20, hit.dist - 10)
        local cam = camera():K2_GetComponentLocation()
        local p = { X = cam.X + hit.dir.X * k, Y = cam.Y + hit.dir.Y * k, Z = cam.Z + hit.dir.Z * k }
        reachFollow(hand, function() return p end)
        -- let go once the hand is there (v0.3.27; was a fixed 0.35 s)
        afterArrive(hand, 0.2, 0.7, function()
            setGrip(hand, false); if hand == 0 then S.carry = nil end
            after(0.2, function() handHome(hand) end)
        end)
        log("put down at %.0f cm", hit.dist)
        return
    end
    -- a grabbable object near the crosshair: reach for its own grab point (follows it if it moves) and grip once there
    local tgt = grabTarget(hand)
    if tgt then
        local a = tgt.a
        local function pt() return a:IsValid() and grabPointOf(a) or tgt.p end
        reachFollow(hand, pt)
        local tries = 0
        local function settle()
            tries = tries + 1
            if dist(handLoc(hand), pt()) > 6 and tries < 25 then after(0.04, settle); return end
            setGrip(hand, true)
            freeze(hand)   -- the item now hangs on the hand: don't follow it
            after(0.25, function() afterGrab(hand, string.format(" (%.0f cm)", tgt.d)) end)
        end
        after(0.1, settle)
        return
    end
    local hit = traceView(d)
    if hit then
        -- reach to the surface point (3 cm short), grip once the hand is there
        local k = math.max(20, hit.dist - 3)
        local cam = camera():K2_GetComponentLocation()
        local p = { X = cam.X + hit.dir.X * k, Y = cam.Y + hit.dir.Y * k, Z = cam.Z + hit.dir.Z * k }
        reachFollow(hand, function() return p end)
        local tries = 0
        local function settle()
            tries = tries + 1
            if dist(handLoc(hand), p) > 6 and tries < 15 then after(0.04, settle); return end
            setGrip(hand, true)
            after(0.25, function() afterGrab(hand, "") end)
        end
        after(0.1, settle)
        return
    end
    -- nothing within reach: reach forward along the view, grip, come back holding whatever was there
    reachTo(hand, d * 0.55, 6 * side, -8)
    after(0.15, function()
        reachTo(hand, d, 4 * side, -6)
        -- grip once the hand is out there (v0.3.27; was a fixed 0.25 s after this)
        afterArrive(hand, 0.1, 0.5, function()
            setGrip(hand, true)
            after(0.25, function() afterGrab(hand, " (straight ahead)") end)
        end)
    end)
end

-- right hand holding a gun (or anything from a loadout slot): put it away, then run thenFn (F on a lever, dial, switch...)
local function holsterRightThen(thenFn)
    setGrip(1, false)
    if S.supporting then setGrip(0, false); S.supporting = false end
    S.heldSlot = nil; S.syringe = nil
    after(0.25, function()
        local lc = S.pawn.LoadoutComponent
        if lc and lc:IsValid() then pcall(function() lc:ReturnDroppedItemsToLoadoutImmediately() end) end
    end)
    after(0.55, thenFn)
    log("holster")
end

-- is the object held by `hand` one of these script classes (e.g. "CLPLootBag")?
local classCache = {}
local function holdingA(hand, names)
    local c = holding(hand)
    local o = c and c:GetOwner()
    if not (o and o:IsValid()) then return false end
    for _, n in ipairs(names) do
        local cls = classCache[n]
        if not (cls and cls:IsValid()) then cls = StaticFindObject("/Script/Angelscript." .. n); classCache[n] = cls end
        if cls and cls:IsValid() and o:IsA(cls) then return true end
    end
    return false
end
local THROWABLE = { "CLPLootBag", "CLPThrowableProp" }
local THROW_SWING = 0.1   -- seconds the throw's forward swing takes (v0.3.27; it was a one-frame jump)
local GRENADE = { "CLPGrenade" }
-- items the game fires with the right trigger but doesn't map LMB to (that only happens with a gun in hand)
local TRIGGER_ITEMS = { "CLPGrapplingHook", "CLPPlaceableInteractable" }

-- Throw what a hand holds (LMB for a bag in the right hand, T for a bag carried in the left). The hand draws back, swings
-- forward and up fast and lets go mid-swing; the game throws with the controller's velocity. The left hand mirrors it.
local function throwItem(hand)
    hand = hand or 1
    if busy() or not S.grip[hand] then return end
    local s = cfg.throw or { back = { 10, 25, -10 }, release = { 75, 10, 15 } }
    local m = hand == 1 and 1 or -1
    reachTo(hand, s.back[1], s.back[2] * m, s.back[3])
    -- v0.3.27: the hand eases back, then the swing is a fixed quick move (THROW_SWING) and it lets go as the swing ends.
    -- Before, the swing was a one-frame jump and it let go 0.06 s later; the game throws with the hand's speed.
    afterArrive(hand, 0.2, 0.4, function()
        reachTo(hand, s.release[1], s.release[2] * m, s.release[3], { T = THROW_SWING })
        afterArrive(hand, 0.03, 0.25, function()
            setGrip(hand, false)
            if hand == 1 then S.heldSlot = nil else S.carry = nil end
            after(0.29, function() handHome(hand) end)
        end)
    end)
    log("throw")
end

-- Grenades (v0.3.11; gadget slot, CLPGrenade): the trigger pulls the pin (UCLPGrenadeComponent), letting go arms it.
-- LMB (or the throw key) with a grenade in hand: pull the pin, swing, let go, and give it a throw toward the crosshair:
-- the hand-swing throw alone (made for loot bags) dropped it about 1 m away.
local function throwGrenade()
    if busy() or not S.grip[1] then return end
    local c = holding(1)
    local g = c and c:GetOwner()
    if not (g and g:IsValid()) then return end
    S.trigger = true   -- pull the pin
    after(0.15, function() S.trigger = false; inject("IA_Trigger_R", 0) end)
    -- (v0.3.34) The hand winds up behind the eye and swings straight along the throw line (camera space: forward,
    -- `grenade_lift` up) at a steady speed, lets go mid-swing and follows through a little. Before, it let go only once
    -- an eased swing had stopped (afterArrive), so the hand's speed at release was 0 (measured offline: the grenade sat
    -- still in the open hand for 4 frames, then the mod's SetPhysicsLinearVelocity threw it). Offline that worked.
    -- Online the server throws with the hand's own velocity estimate (ServerEndInteraction's VelocityEstimates) and the
    -- client's velocity doesn't count, so the grenade dropped from the still hand, the hand came back down through it,
    -- and it landed at the player's feet (the user's report).
    -- Measured offline with the mod's velocity off (dev: grenaderaw), the game's own throw from this swing:
    --   * an eased 70 cm / 0.1 s swing let go at 1150 cm/s gave only 500 cm/s (the game averages the hand's speed), and
    --     the hand overtook the grenade;
    --   * steady 1300 cm/s: 1664 cm/s (the grenade's cap, MaxThrowingVelocity 1700 x ThrowingVelocityModifier 0.98);
    --   * steady 1000 cm/s: 1300 cm/s, let go 30 cm in front of the eye: the same as the offline `grenade_speed`.
    -- The hand stops 57 cm out, behind the grenade.
    -- Online (closed lobby, then closed Small Bank): the server threw it at 1662-1664 cm/s (the cap) with both a 1000 and
    -- a 780 cm/s swing, so online it flies a bit further than offline (about 12 m in the lobby).
    -- back = the wind-up point; release / stop = cm along the line from it where the hand lets go / stops;
    -- speed (online: speed_online) = cm/s of the hand along the line
    local sw = cfg.grenade_swing or { back = { -25, 20, -18 }, speed = 1000, speed_online = 1000, release = 60, stop = 90 }
    local vH = (S.wasOnline and sw.speed_online) or sw.speed
    local lift = math.rad(cfg.grenade_lift or 10)
    local dx, dz = math.cos(lift), math.sin(lift)
    local b = sw.back
    local function release()
        setGrip(1, false); S.heldSlot = nil
        local cam = camera()
        local f, u = cam:GetForwardVector(), cam:GetUpVector()
        local speed = cfg.grenade_speed or 1300
        local d = { X = f.X * dx + u.X * dz, Y = f.Y * dx + u.Y * dz, Z = f.Z * dx + u.Z * dz }
        -- offline (we're the server) set the exact throw a frame later, once it simulates physics; online the server
        -- owns it, and a client-side velocity only made the local copy fly off and snap back
        if not S.wasOnline and not S.grenadeRaw then   -- dev: grenaderaw = offline too, only the hand's own throw
            after(0.03, function()
                if not g:IsValid() then return end
                local okV, err = pcall(function()
                    g:K2_GetRootComponent():SetPhysicsLinearVelocity({ X = d.X * speed, Y = d.Y * speed, Z = d.Z * speed }, false, FName("None"))
                end)
                if not okV then log("grenade: %s", tostring(err)) end
            end)
        end
        -- the hand finishes the swing (it's ahead of the hand by then), then goes home
        after(0.35, function() handHome(1) end)
    end
    after(0.20, function()
        reachTo(1, b[1], b[2], b[3])
        afterArrive(1, 0.2, 0.4, function()
            -- straight along the throw line at a steady speed, written exactly each frame
            local t0 = now()
            setOverride(1, { cfn = function()
                local s = math.min((now() - t0) * vH, sw.stop)
                return b[1] + dx * s, b[2], b[3] + dz * s
            end }, INSTANT)
            after(sw.release / vH, release)
        end)
    end)
    log("grenade: pin out, throw%s", S.wasOnline and " (online: thrown by the hand's swing)" or "")
end

-- Carrying with the left hand (a loot bag while the right hand holds a gun): G grabs, the left hand then hangs at the
-- side (cfg.carry_hand) instead of going back to the gun's foregrip, so the gun is held one-handed. R drops the bag,
-- reloads and picks it back up; G puts it down where you look; T throws it.
local function carryGrabPoint(bag)
    local ok, l = pcall(function()
        local m = bag.Mesh
        if m and m:IsValid() and m:DoesSocketExist(FName("s_grip")) then return m:GetSocketLocation(FName("s_grip")) end
        return bag:K2_GetActorLocation()
    end)
    return ok and l or nil
end

local function regrabCarry(try)
    try = try or 1
    local bag = S.regrab
    S.regrab = nil
    if not (bag and bag:IsValid()) then return end
    grabAtWorld(0, function() return bag:IsValid() and carryGrabPoint(bag) or nil end, function()
        -- (compare by name: two Lua handles of the same object aren't always equal)
        local c = holding(0)
        local o = c and c:GetOwner()
        if o and o:GetFullName() == bag:GetFullName() then S.carry = o; log("carry: picked the bag back up")
        else
            setGrip(0, false)
            if try < 2 then
                -- missed (the bag rolled, or the hand stopped short): reach for it once more
                S.regrab = bag
                after(0.2, function() regrabCarry(2) end)
                return
            end
            log("carry: couldn't pick the bag back up (holding %s; G grabs it)", o and o:GetFName():ToString() or "nothing")
        end
        handHome(0)
    end)
end

local function maskOn()
    if busy() then return end
    if S.carry then log("mask: put the bag down first (G)"); return end
    local lc = S.pawn.LoadoutComponent
    local m = slotItem(7)
    if not m then log("mask: not in its slot (already wearing it?)"); return end
    grabAtWorld(0, function() return m:IsValid() and m:K2_GetActorLocation() or nil end, function()
        reachTo(0, 18, 0, -4)
        after(0.30, function() reachTo(0, 8, 0, -2) end)
        after(0.50, function()
            -- (letting go of it at the face doesn't put it on in flat mode: tried at the face slot and with the mask
            -- itself 3 cm from the eye; the mask's own EquipDistanceToHead check is script-only and isn't met)
            pcall(function() lc:ServerEquipMask(m) end)
            setGrip(0, false)
        end)
        after(0.70, function() handHome(0) end)
    end)
    log("mask on")
end

-- world position of a loadout slot area (slot transforms are relative to the character, rotated by its yaw)
slotWorld = function(slot)
    local t = S.pawn.LoadoutComponent:GetTransformsForSlotByType(slot).Transform.Translation
    local a, yaw = S.pawn:K2_GetActorLocation(), math.rad(S.pawn:K2_GetActorRotation().Yaw)
    local c, s2 = math.cos(yaw), math.sin(yaw)
    return { X = a.X + t.X * c - t.Y * s2, Y = a.Y + t.X * s2 + t.Y * c, Z = a.Z + t.Z }
end

local function socketCam(gun, name)
    local ok, l = pcall(function() return gun.SkeletalMeshComponent:GetSocketLocation(FName(name)) end)
    if ok and l then return toCam(l) end
    return nil
end

-- magazine swap: release the mag, reach over the shoulder to the ammo pouch (it hands you a fresh mag),
-- slide it into the magwell along the gun's insertion line, let go, release the slide
local function socketWorld(gun, name)
    local m = gun.SkeletalMeshComponent
    local okE, e = pcall(function() return m:DoesSocketExist(FName(name)) end)
    if not (okE and e) then return nil end
    return m:GetSocketLocation(FName(name))
end

-- a point fixed to the body (actor yaw frame, cm): forward, right, up from the actor origin
local function bodyPoint(x, y, z)
    local a, yaw = S.pawn:K2_GetActorLocation(), math.rad(S.pawn:K2_GetActorRotation().Yaw)
    local c, s2 = math.cos(yaw), math.sin(yaw)
    return { X = a.X + x * c - y * s2, Y = a.Y + x * s2 + y * c, Z = a.Z + z }
end

local reload
reload = function(attempt)
    attempt = attempt or 1
    -- R again while loading shells: stop after the shell in the hand (v0.3.8). Checked before busy(): between two
    -- shells the hands can be momentarily idle, and R then started a second reload instead
    if attempt == 1 and S.shellLoad then
        if not S.shellStop then S.shellStop = true; log("reload: stopping after this shell") end
        return
    end
    if busy() then
        -- another hand action is still finishing (a draw, a grab...): reload as soon as it's done (v0.3.3; it used to
        -- ignore the key silently)
        if attempt == 1 and not S.reloading then S.reloadQueued = now() + 2.0 end
        return
    end
    -- the gun is what the game says the right hand holds (the old "actor attached near the hand" guess missed the pistol
    -- and cancelled a retry: "reload: no gun in the right hand")
    local gun = nil
    local held = holding(1)
    local o = held and held:GetOwner()
    local okF, faH = pcall(function() return o.FirearmComponent end)
    if okF and faH and faH.IsValid and faH:IsValid() then gun = o end
    gun = gun or (S.grip[1] and heldBy(1)) or nil
    -- heldBy can return a non-gun (online the right hand once held a shell clip instead of the shotgun, and the
    -- reload then failed with a Lua error on its FirearmComponent)
    if gun then
        local okG, faG = pcall(function() return gun.FirearmComponent end)
        if not (okG and faG and faG.IsValid and faG:IsValid()) then gun = nil end
    end
    if not gun then
        local n = nil
        pcall(function() n = held:GetOwner():GetFName():ToString() end)
        log("reload: no gun in the right hand%s", n and (" (it holds " .. n .. ")") or ""); return
    end
    S.grip[1] = true
    local fa = gun.FirearmComponent
    -- no spare magazines (EAmmoType: 0 sidearm, 1 primary): say so and keep the current one in the gun
    local isPistol = gun:GetClass():GetFName():ToString():find("Pistol") ~= nil
    -- Shotguns (v0.3.8): the gun keeps an internal tube "magazine" (DataAsset.AmmoType 2 = Shells, e.g. the Sanbury
    -- 790's DA_InternalMagazine_Shotgun_Sanbury790, 7 shells) and the pouch hands out one shell per grab, pushed into
    -- the loading port like a magazine. One R used to load a single shell; now it loads shell after shell until the
    -- tube is full, the shells run out, or R / LMB is pressed.
    local ammoType = isPistol and 0 or 1
    local tube, tubeMax = nil, nil
    pcall(function()
        local m = fa.AttachedMagazine
        if m and m:IsValid() and m.DataAsset.AmmoType == 2 then tube, tubeMax, ammoType = m, m.DataAsset.MaxAmmo, 2 end
    end)
    local function tubeAmmo() local ok, v = pcall(function() return tube.CurrentAmmo end); return ok and v or 0 end
    -- Revolvers (v0.3.35; the ES364 Mammoth): the cylinder is an internal magazine that stays in the gun (its DataAsset is
    -- the firearm's InternalMagazine, DA_InternalMagazine_Pistol_ES364Mammoth, 8 rounds), it can swing out
    -- (bCanInternalMagazineOpen) and only takes ammo while out (receiver bCanOnlyBeReloadedWhenOpen; bIsBlocked = closed).
    -- The pouch hands out a speedloader (a Magazine, DA_Magazine_Pistol_ES364Mammoth). A swings the cylinder out, B
    -- swings it back; the insertion sockets (s_MagSlideStart -> s_magazine, 2.5 cm, behind the drum) move with it.
    -- Before, the reload pressed A, saw the "magazine" still in and gave up: "the magazine didn't come out (full?)",
    -- leaving the cylinder open.
    local rev, revMax = nil, 0
    if not tube then
        pcall(function()
            local m, da = fa.AttachedMagazine, fa.DataAsset
            if m and m:IsValid() and da.bCanInternalMagazineOpen and fa.MagazineReceiverComponent.bCanOnlyBeReloadedWhenOpen
                and da.InternalMagazine and da.InternalMagazine:IsValid()
                and m.DataAsset:GetFullName() == da.InternalMagazine:GetFullName() then
                rev, revMax = m, m.DataAsset.MaxAmmo
            end
        end)
    end
    local function revAmmo() local ok, v = pcall(function() return rev.CurrentAmmo end); return ok and v or 0 end
    local function revClosed() local ok, v = pcall(function() return fa.MagazineReceiverComponent.bIsBlocked end); return ok and v == true end
    local okM, mags = pcall(function() return S.pawn.LoadoutComponent:GetMagazinesCount(ammoType) end)
    if attempt == 1 and okM and type(mags) == "number" and mags <= 0 then
        log("reload: no %s left", ({ [0] = "pistol magazines", [1] = "primary magazines", [2] = "shells" })[ammoType]); return
    end
    if rev and attempt == 1 and revAmmo() >= revMax then
        log("reload: it's full (%d rounds)", revMax)
        if not revClosed() then inject("IA_Button_B_R_Pressed", 1); after(0.06, function() inject("IA_Button_B_R_Pressed", 0) end) end
        return
    end
    if tube and attempt == 1 and tubeAmmo() >= tubeMax then
        log("reload: it's full (%d shells)", tubeMax)
        -- a full break-action may have been left open: close it (B; nothing happens if it's closed)
        local okB, bo = pcall(function() return fa.MagazineReceiverComponent.bCanOnlyBeReloadedWhenOpen end)
        if okB and bo == true then inject("IA_Button_B_R_Pressed", 1); after(0.06, function() inject("IA_Button_B_R_Pressed", 0) end) end
        return
    end
    if S.supporting then setGrip(0, false); S.supporting = false; S.supportSince = nil end
    if attempt == 1 and S.carry then
        -- the left hand carries a bag: drop it at your feet, reload, then pick it back up
        S.regrab = S.carry; S.carry = nil
        setGrip(0, false)
        log("reload: dropping the bag to reload")
    end
    local tubeStart = tube and tubeAmmo() or 0
    if tube and attempt == 1 then S.shellLoad, S.shellStop, S.shellsLoaded, S.shellMiss, S.shellFrom = true, false, 0, 0, tubeStart end
    local revStart = rev and revAmmo() or 0
    -- magazine guns: A drops the magazine. Revolvers: A swings the cylinder out (A toggles it, so only while closed;
    -- a retry finds it closed again, finish closes it)
    if (attempt == 1 and not tube and not rev) or (rev and revClosed()) then
        inject("IA_Button_A_R_Pressed", 1); inject("IA_Button_A_R_Tap", 1)
        after(0.05, function() inject("IA_Button_A_R_Pressed", 0); inject("IA_Button_A_R_Released", 1) end)
    end
    -- insertion line: from below the magwell entry (s_MagSlideStart) up to where the mag sits
    local seat = socketWorld(gun, "s_magazine") and "s_magazine" or "s_grip"
    -- Break-action shotguns (the Broadhurst Redeemer: 4 barrels, sockets s_AmmoSocket1..4, no magwell; its receiver
    -- only takes shells while open, bCanOnlyBeReloadedWhenOpen): open it, push each shell into the next chamber from
    -- behind, along the line to the muzzle, and close it at the end.
    -- The chamber list is the receiver's own (CLPBreakActionSupplyReceiverTransformOverride.AmmoSockets). The
    -- Fredericks M411 lists s_AmmoSocket1/2 but its mesh has neither; it takes shells at its "Cylinder" bone (tried:
    -- the mesh origin, Zatvor: not taken; Cylinder: 2/2).
    local chambers = nil
    if tube and not socketWorld(gun, "s_MagSlideStart") then
        chambers = {}
        pcall(function()
            fa.MagazineReceiverComponent.SupplyRecieverTransformOverride.AmmoSockets:ForEach(function(_, e)
                chambers[#chambers + 1] = e:get():ToString()
            end)
        end)
        if #chambers == 0 then for i = 1, 8 do if socketWorld(gun, "s_AmmoSocket" .. i) then chambers[#chambers + 1] = "s_AmmoSocket" .. i end end end
        if #chambers == 0 then chambers = nil end
    end
    local breakOpen = false
    pcall(function() breakOpen = fa.MagazineReceiverComponent.bCanOnlyBeReloadedWhenOpen == true end)
    -- A opens it, B closes it (measured with the gun's anim instance, UFirearmAnimInstance.bMagazineOpen;
    -- ServerOpenMagazine and a fast flick didn't open it). Shells pushed in while it's still opening aren't taken, so
    -- the first one waits until 0.6 s after A. (The mod doesn't read bMagazineOpen itself: GetAnimInstance on the
    -- Fredericks M411 crashed the game.)
    local openedAt = now()
    if tube and breakOpen and attempt == 1 then
        inject("IA_Button_A_R_Pressed", 1); inject("IA_Button_A_R_Tap", 1)
        after(0.05, function() inject("IA_Button_A_R_Pressed", 0); inject("IA_Button_A_R_Released", 1) end)
    end
    local function along(k)   -- k = 0 at the entry, 1 at the seat, negative = below the entry
        if chambers then
            local b = (S.sgTarget and socketWorld(gun, S.sgTarget)) or socketWorld(gun, chambers[math.min(#chambers, tubeStart + 1)])
                or socketWorld(gun, "Cylinder") or gun.SkeletalMeshComponent:K2_GetComponentLocation()
            local mz = socketWorld(gun, "s_muzzle")
            if not (b and mz) then return b end
            local d = dist(mz, b); if d < 1 then return b end
            local u = { X = (mz.X - b.X) / d, Y = (mz.Y - b.Y) / d, Z = (mz.Z - b.Z) / d }
            local e = 8   -- the entry: 8 cm behind the chamber
            return { X = b.X - u.X * e * (1 - k), Y = b.Y - u.Y * e * (1 - k), Z = b.Z - u.Z * e * (1 - k) }
        end
        local a, b = socketWorld(gun, "s_MagSlideStart"), socketWorld(gun, seat)
        if not a then return nil end
        if not b then return a end
        return { X = a.X + (b.X - a.X) * k, Y = a.Y + (b.Y - a.Y) * k, Z = a.Z + (b.Z - a.Z) * k }
    end
    -- The hand holds the magazine a few cm off its grip point, and how depends on the angle it was taken from the
    -- pouch at (standing and crouched differ), so steer the magazine itself onto the line: hand target = point -
    -- (magazine - hand mesh) - (hand mesh - hand target). The last part is fixed for the left hand's rotation; measure
    -- it now, while the hand rests on the foregrip.
    local lm = S.pawn.LeftInteractionComponent.HandPrimitive
    local mt, tt = lm:K2_GetComponentLocation(), S.pawn:GetHandTransformTarget(0).Translation
    local meshOff = { X = mt.X - tt.X, Y = mt.Y - tt.Y, Z = mt.Z - tt.Z }
    local function heldMag()
        local hl, best, bd = handLoc(0), nil, 25
        for _, a in ipairs(FindAllOf("Magazine") or {}) do
            local par = a:IsValid() and a:GetAttachParentActor()
            if par and par:IsValid() and par == S.pawn then
                local d = dist(a:K2_GetActorLocation(), hl)
                if d < bd then best, bd = a, d end
            end
        end
        return best
    end
    local function magAt(k)   -- hand target that puts the held magazine at along(k)
        local w = along(k)
        local mag = w and heldMag()
        if not mag then return w end
        local ml, mm = mag:K2_GetActorLocation(), lm:K2_GetComponentLocation()
        return { X = w.X - (ml.X - mm.X) - meshOff.X, Y = w.Y - (ml.Y - mm.Y) - meshOff.Y, Z = w.Z - (ml.Z - mm.Z) - meshOff.Z }
    end
    -- the pouch rides with the head: when you crouch the camera drops 50 cm but the actor centre only 30 cm, so
    -- take the horizontal position from the body and the height from the eyes
    local p = cfg.ammo_pouch or { x = -5, y = -15, z = 17 }
    -- Online, the pouch's magazine is a real actor that doesn't follow you (measured 2026-11-10, closed online Small
    -- Bank): the ammo slot's stored magazine (LoadoutComponent:GetStoredItemInSlot(1), hidden, attached to nothing)
    -- stays where the server spawned it, at the floor-based head (VR origin + about 90 cm) of where you stood at the
    -- last reload. A grip at the pouch only gives a magazine near that actor, so after walking every grip came up empty
    -- (the user's "reloads fail online"; a 63-point grid around the body found nothing, the magazine lay 31 m back).
    -- v0.3.19's two-places guess only matched while you stood still. Now online the reload asks the server for that
    -- magazine (ServerBeginInteraction, like online draws, see grabAtWorld): it attaches it to the left hand at once,
    -- wherever it lay, and spawns the next one in the slot. The grip at the floor-based point stays as the fallback
    -- for when the slot reads empty.
    local function pouchPoint(floor)
        if floor then
            -- the floor-based head: the game's own slot transform (body-relative, rotated by yaw) taken from the VR
            -- origin instead of the body
            local ok, w = pcall(function()
                local t = S.pawn.LoadoutComponent:GetTransformsForSlotByType(1).Transform.Translation
                local v = S.pawn.VROrigin:K2_GetComponentLocation()
                local yaw = math.rad(S.pawn:K2_GetActorRotation().Yaw)
                local c, s2 = math.cos(yaw), math.sin(yaw)
                return { X = v.X + t.X * c - t.Y * s2, Y = v.Y + t.X * s2 + t.Y * c, Z = v.Z + t.Z }
            end)
            if ok and w then return w end
        end
        local w = bodyPoint(p.x, p.y, 0)
        w.Z = camera():K2_GetComponentLocation().Z + p.z
        return w
    end
    local function seated()
        if tube then return tubeAmmo() > tubeStart end
        if rev then return revAmmo() > revStart end
        local ok, mag = pcall(function() return fa.AttachedMagazine end)
        return ok and mag and mag:IsValid()
    end
    local jabs, seatT = 0, nil   -- extra pushes of a stuck magazine, time from the last push to the seat (see stage)
    local function finish(how)
        if tube then
            local ok = seated()
            if ok then S.shellsLoaded, S.shellMiss = S.shellsLoaded + 1, 0 else S.shellMiss = S.shellMiss + 1 end
            local left = 0
            pcall(function() left = S.pawn.LoadoutComponent:GetMagazinesCount(2) end)
            local stop = S.shellMiss >= 2 or S.shellStop or tubeAmmo() >= tubeMax or left <= 0
            if not stop then
                -- next shell: a fresh call (new start count); two misses in a row stop it
                setGrip(0, false)
                after(0.12, function() S.reloading = false; reload(2) end)
                return
            end
            S.shellLoad = false
            setGrip(0, false)   -- a part-used shell clip left in the hand is let go, not carried
            if breakOpen then
                -- close it (B)
                after(0.30, function() inject("IA_Button_B_R_Pressed", 1) end)
                after(0.36, function() inject("IA_Button_B_R_Pressed", 0) end)
            end
            local n = tubeAmmo() - (S.shellFrom or 0)   -- the pouch hands out clips of 1-2 shells
            log("reload: %d shell%s in, %d/%d%s%s", n, n == 1 and "" or "s", tubeAmmo(), tubeMax,
                left <= 0 and ", out of shells" or "", ok and "" or " (" .. how .. ")")
            -- an empty gun locks open: let the slide go to chamber a shell
            after(0.10, function() if fa.bSlideLocked then inject("IA_Button_B_R_Pressed", 1) end end)
            after(0.15, function() inject("IA_Button_B_R_Pressed", 0); handHome(0) end)
            after(0.35, function()
                S.reloading = false
                if S.regrab then after(0.15, regrabCarry) end
            end)
            return
        end
        -- slide release (revolvers: B swings the cylinder back in), then check
        if rev then setGrip(0, false) end   -- the empty speedloader is let go
        after(0.10, function() inject("IA_Button_B_R_Pressed", 1) end)
        after(0.15, function() inject("IA_Button_B_R_Pressed", 0); handHome(0) end)
        after(0.35, function()
            local ok = seated()
            log("reload %s (attempt %d, ammo %s%s%s%s)", ok and "done" or "FAILED", attempt, tostring(fa:GetAmmo()),
                (ok and seatT) and string.format(", seated %.2f s after the push", seatT) or "",
                jabs > 0 and string.format(", %d extra push%s", jabs, jabs == 1 and "" or "es") or "", ok and "" or ", " .. how)
            if not ok and attempt < 3 then   -- (v0.3.31: 3 attempts, was 2)
                -- whatever the left hand still holds, drop it and try once more
                setGrip(0, false)
                after(0.2, function() S.reloading = false; reload(attempt + 1) end)
            else
                S.reloading = false
                if S.regrab then after(0.15, regrabCarry) end
            end
        end)
    end
    -- Closed loop (v0.3.1): each stage waits until the magazine itself is on its mark (the hand lags behind its target,
    -- more so crouched or walking, and the old fixed 0.3 / 0.5 / 0.75 s timing let go too early), and the last stage
    -- pushes until the gun reports the magazine attached. Targets are recomputed every frame from the gun's sockets, so
    -- they follow the gun while you move.
    -- (v0.3.27: the hand eases from the pouch to below the magwell and up to its entry.)
    -- (v0.3.28: the point below the magwell is passed through (5 cm, was 3: the hand curves on into the entry instead of
    -- stopping). The insertion itself stays a one-frame jump (exact): eased over 0.07 s the magazine stuck about 2 cm
    -- short of the seat in 2 of 6 reloads online, and in 6 of 8 when the hand first came to rest at the entry; the jump
    -- seated 6 of 6. The magwell seems to need the magazine to arrive fast.)
    local STAGES = { { k = -1.5, tol = 5, time = 0.7 }, { k = 0, tol = 2, time = 0.3 }, { k = 1.15, time = 0.9, exact = true } }   -- (v0.3.34: stage 2 0.3 s, was 0.5)
    local reinserted = false
    -- (v0.3.31) Stuck magazines. About 1 in 4 rifle reloads in the user's online play stopped 2-5 cm short of the seat;
    -- the mod then waited the full 0.9 s and redid the whole slide from below the magwell (14 of 15 then seated, 1 needed a
    -- second reload). Now, once the magazine is still in the hand, short of the seat and has stopped moving, the hand
    -- pulls it back to the magwell entry and pushes it in again at once, a little deeper each time (up to JAB_MAX).
    -- The full re-slide and the second attempt stay as the fallbacks. Magazines only (shell loading is unchanged).
    -- (v0.3.33 tuning, from the user's online logs: a good push seats in 0.03-0.04 s, online too; stalls sat 0.9-2.8 cm
    -- short and needed 1-3 pushes of +0.1 each, about 0.6 s per push)
    -- 4 pushes, each 0.12 deeper (k 1.27, 1.39, 1.51, 1.63; was 3 x 0.1, up to 1.45 tested): the hand lands short while
    -- walking, so aim further past the seat
    local JAB_MAX, JAB_DEEPER = 4, 0.12
    -- s after a push before calling it stuck (was 0.35 online / 0.25): still 4-5x the 0.04 s seat time
    local STUCK_MIN = S.wasOnline and 0.20 or 0.15
    local STUCK_STILL = 0.08                         -- ...no 0.3 cm progress for this long (was 0.12)
    -- ...and at least this far from the seat (0.5, was 1.5: the user's log had a stall 0.9 cm short that got no push and
    -- waited for the full re-slide)
    local STUCK_CM = cfg.reload_stuck_cm or 0.5
    local BACK_MAX = 0.15                            -- s at most to pull back to the entry before the next push (was 0.25)
    -- (v0.3.34, the user's "reload animation is bugged"; measured offline, AV56, per-frame hand track:)
    -- * stage 2 (line up at the magwell entry) often settled 3.3 cm off its 2 cm mark and sat there still until its
    --   0.5 s timeout, a visible freeze under the gun. Now it also moves on once the magazine is within SETTLE_CM and
    --   hasn't come 0.3 cm closer for SETTLE_T.
    -- * the pull-back before an extra push was a one-frame jump; it now eases (BACK_T).
    -- * the push itself stays a one-frame jump of about 27 cm. Tried a steady 0.05 s slide instead (cfg.reload_push_time,
    --   s; 0 = the jump): standing 7/7 seated first push, but walking only 2 of 6 (stalls 1.2-1.3 cm short, then 0.3 cm
    --   from the seat and not taken); the jump walking 5 of 5. The gun catches the magazine partway in and snaps it
    --   home itself, so the jump shows as the magazine going in fast.
    local SETTLE_CM, SETTLE_T = 7, 0.06   -- (the Kogl 19 settles 6.6 cm off its mark standing, and seats from there)
    local PUSH_T = cfg.reload_push_time or 0
    local BACK_T = 0.06
    local setD, setT = nil, nil
    local jabK, lastD, lastMoveT, pushT, minD = nil, nil, nil, nil, nil
    -- how far the magazine reads from the seat point once really seated, learned per gun (guns without s_magazine measure
    -- to s_grip, so a seated magazine can read several cm "short"); unknown and no s_magazine = no extra pushes
    S.seatD = S.seatD or {}
    local gcls = gun:GetClass():GetFName():ToString()
    local function seatedAt()
        if rev then seatT = pushT and now() - pushT; return end   -- the cylinder isn't a magazine to measure
        -- measured on the magazine the gun now holds (not minD: the first reading is taken at the entry, before it moves)
        pcall(function()
            local am, w = fa.AttachedMagazine, along(1)
            if am and am:IsValid() and w then
                local d = dist(am:K2_GetActorLocation(), w)
                S.seatD[gcls] = math.min(d, 6)
                if S.reloadDebug then log("reload dbg: seated magazine reads %.1f cm from the seat point", d) end
            end
        end)
        seatT = pushT and now() - pushT
    end
    local function stage(i, t0, tries)
        local st = STAGES[i]
        if not t0 then
            local k = (i == 3 and jabK) or (i == 3 and S.reloadShallow and 0.7) or st.k   -- dev: reloadshallow stops the first push short
            t0 = now()
            if i == 3 and PUSH_T > 0 then
                -- from the entry (k 0) to k in a straight line at a steady speed
                local ts = t0
                reachFollow(0, function() return magAt(k * math.min(1, (now() - ts) / PUSH_T)) end, INSTANT)
            else
                reachFollow(0, function() return magAt(k) end, st.exact and INSTANT or nil)
            end
            if i == 3 then lastD, lastMoveT, pushT, minD = nil, t0, t0, nil end
            setD, setT = nil, t0
        end
        local mag = heldMag()
        if not mag then
            -- the gun took it. Open the hand too: left closed on nothing, the support hand never took the foregrip again
            -- after this reload (v0.3.6, the user's "left hand doesn't hold the gun while aiming")
            if seated() then setGrip(0, false); seatedAt(); return finish("") end
            setGrip(0, false)
            return finish(i == 1 and "no magazine came out of the pouch" or "the magazine slipped out of the hand")
        end
        if not st.tol then
            if seated() then setGrip(0, false); seatedAt(); return finish("") end
            local w1 = along(1)
            local md = w1 and dist(mag:K2_GetActorLocation(), w1) or 0
            local tn = now()
            if lastD == nil or md < lastD - 0.3 then lastD, lastMoveT = md, tn end
            if minD == nil or md < minD then minD = md end
            local base = S.seatD[gcls] or (seat == "s_magazine" and 0) or nil
            if not tube and not rev and base and jabs < JAB_MAX and md >= base + STUCK_CM and tn - t0 > STUCK_MIN and tn - lastMoveT > STUCK_STILL then
                -- stuck short: back to the entry, then straight in again, deeper
                jabs = jabs + 1
                jabK = STAGES[3].k + JAB_DEEPER * jabs
                if S.reloadDebug then log("reload dbg: stuck %.1f cm short after %.2f s, push %d to k=%.2f", md, tn - t0, jabs, jabK) end
                reachFollow(0, function() return magAt(0) end, { T = BACK_T })
                local tb = now()
                local function back()
                    local m2 = heldMag()
                    if not m2 then return stage(3, now()) end   -- the gun took it after all (or it fell): finish there
                    local we = along(0)
                    local de = we and dist(m2:K2_GetActorLocation(), we) or 0
                    if de <= 2.5 or now() - tb > BACK_MAX then return stage(3) end
                    after(0.03, back)
                end
                return after(0.03, back)
            end
            if now() - t0 > st.time then
                local w = along(1)
                if not reinserted then
                    -- stuck short of the seat (snagged on the gun, or the gun moved): back off and slide it in again
                    reinserted = true
                    log("reload: not seated (magazine %.1f cm from the seat), sliding it in again", w and dist(mag:K2_GetActorLocation(), w) or -1)
                    return after(0.0, function() stage(1) end)
                end
                setGrip(0, false)
                return finish(string.format("not seated: magazine %.1f cm from the seat", w and dist(mag:K2_GetActorLocation(), w) or -1))
            end
        else
            local w = along(st.k)
            local d = w and dist(mag:K2_GetActorLocation(), w) or 0
            local tn = now()
            if setD == nil or d < setD - 0.3 then setD, setT = d, tn end
            local settled = i == 2 and d <= SETTLE_CM and tn - setT > SETTLE_T
            if d <= st.tol or settled or tn - t0 > st.time then
                if S.reloadDebug then log("reload dbg: stage %d -> %d after %.2f s, magazine %.1f cm from its mark%s", i, i + 1, tn - t0, d,
                    d <= st.tol and "" or settled and " (settled)" or " (timed out)") end
                return after(0.0, function() stage(i + 1) end)
            end
        end
        after(0.03, function() stage(i, t0) end)
    end
    local function pouchMag()   -- the ammo slot's stored magazine (or shell clip)
        local ok, m = pcall(function() return S.pawn.LoadoutComponent:GetStoredItemInSlot(1) end)
        if ok and m and m.IsValid and m:IsValid() then return m end
        return nil
    end
    local pouchTries = 0
    local function fromPouch()
        pouchTries = pouchTries + 1
        -- online: a magazine already hanging on the left hand's anchor (an interrupted take) first, else the slot's own
        local take = nil
        if S.wasOnline then take = heldMag() or pouchMag() end
        local floor = S.wasOnline and not take
        grabAtWorld(0, function() return pouchPoint(floor) end, function()
            if not heldMag() and pouchTries < 2 then
                -- came back empty (missed the pouch area, e.g. walking): open the hand and reach again
                if S.wasOnline then log("online: no magazine from the pouch (%s), trying again", take and "server take" or "slot empty, grip at the floor-based pouch") end
                setGrip(0, false)
                after(0.15, fromPouch)
                return
            end
            if breakOpen then
                -- not before the gun is open (up to 1 s)
                local wait = 0.6 - (now() - openedAt)
                if wait > 0 then return after(wait, function() stage(1) end) end
            end
            stage(1)
        end, take)
    end
    S.reloading = true
    -- the magazine must have come out before the left hand takes a new one: at full ammo (pistol 18/18, seen online
    -- and in the online lobby) the release left it in, the hand brought a fresh magazine, couldn't seat it, dropped it
    -- and the reload said "done" (a wasted magazine). Press the release once more; if it's still in, stop.
    local oldMag = nil
    if attempt == 1 and not tube and not rev then pcall(function() oldMag = fa.AttachedMagazine end) end
    local function stillIn()
        local ok, m = pcall(function() return fa.AttachedMagazine end)
        return oldMag and oldMag:IsValid() and ok and m and m:IsValid() and m:GetFullName() == oldMag:GetFullName()
    end
    if oldMag and oldMag:IsValid() then
        after(0.12, function()
            if not stillIn() then return fromPouch() end
            inject("IA_Button_A_R_Pressed", 1); inject("IA_Button_A_R_Tap", 1)
            after(0.05, function() inject("IA_Button_A_R_Pressed", 0); inject("IA_Button_A_R_Released", 1) end)
            after(0.25, function()
                if not stillIn() then return fromPouch() end
                log("reload: the magazine didn't come out (ammo %s, full?)", tostring(fa:GetAmmo()))
                S.reloading = false
                handHome(0)
                if S.regrab then after(0.15, regrabCarry) end
            end)
        end)
    else
        after(0.10, fromPouch)
    end
    log("reload")
end

------------------------------------------------------------------------------------------------ camera jammer
-- The camera jammer (v0.3.10) is a pistol mod (CameraTempJammer / CameraPermJammer, CLPCameraJammerModComponent), enabled
-- only when the pistol's loadout includes it (unlocks handgun_N_jammer / handgun_N_jammer_1). In VR you switch the mod
-- on and the trigger fires a dart at a camera; the switch input wasn't found (it only reacts when the mod is really
-- fitted). Flat: the jammer key fires the dart at the camera / fuse box under the crosshair (UCLPJammerTargetComponent,
-- within the mod's MaxRange, line of sight), through the mod's own ServerShootJammer. Measured: that jammed a Small Bank
-- camera (Server_JammedStartTime set, UsedAmmo 1). Does nothing on a pistol without a fitted jammer.
local JAM_ANGLE = 3   -- degrees from the crosshair
local function fittedJammer(gun)
    local found = nil
    for _, name in ipairs({ "CameraTempJammer", "CameraPermJammer" }) do
        local ok, c = pcall(function() return gun[name] end)
        if ok and c and c.IsValid and c:IsValid() and c.bEnabled == true then found = c; break end
    end
    return found
end
local function fireJammer()
    local held = holding(1)
    local gun = held and held:GetOwner()
    if not (gun and gun:IsValid()) then log("jammer: hold your pistol first"); return end
    local jam = fittedJammer(gun)
    if not jam then log("jammer: no camera jammer fitted on this gun (unlock one and equip it in the loadout)"); return end
    if jam.bIsOnCooldown == true then log("jammer: recharging"); return end
    local okD, data = pcall(function() return jam.Data end)
    local range = (okD and data and data.MaxRange) or 5000
    -- the target nearest the crosshair
    local cam = camera():K2_GetComponentLocation()
    local best, bestA = nil, math.rad(cfg.jammer_angle or JAM_ANGLE)
    for _, t in ipairs(FindAllOf("CLPJammerTargetComponent") or {}) do
        if t:IsValid() then
            local o = t:GetOwner()
            if o and o:IsValid() then
                local okB, c = pcall(function()
                    local origin, ext = {}, {}
                    o:GetActorBounds(true, origin, ext, false)
                    return origin.X and { X = origin.X, Y = origin.Y, Z = origin.Z } or o:K2_GetActorLocation()
                end)
                local p = okB and c or o:K2_GetActorLocation()
                local x, y, z = toCam(p)
                local d = math.sqrt(x * x + y * y + z * z)
                local ang = math.atan(math.sqrt(y * y + z * z), x)
                if x > 0 and d < range and ang < bestA then best, bestA = { t = t, o = o, p = p, d = d }, ang end
            end
        end
    end
    if not best then log("jammer: no camera under the crosshair (within %.0f m)", range / 100); return end
    -- line of sight: the first thing hit should be the target (or within 30 cm of its middle)
    local hit = {}
    local ignore = { S.pawn, gun }
    local okT, r = pcall(function()
        return ksl():LineTraceSingle(S.pawn, cam, best.p, 0, false, ignore, 0, hit, true, { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
    end)
    local hitP, hitN = best.p, nil
    if okT and r and hit.Distance then
        local okA, ha = pcall(function() return hit.HitObjectHandle.Actor:Get() end)
        local onTarget = okA and ha and ha:IsValid() and ha:GetFullName() == best.o:GetFullName()
        if not onTarget and hit.Distance < best.d - 30 then log("jammer: something is in the way"); return end
        pcall(function() hitP = { X = hit.ImpactPoint.X, Y = hit.ImpactPoint.Y, Z = hit.ImpactPoint.Z } end)
        pcall(function() hitN = { X = hit.ImpactNormal.X, Y = hit.ImpactNormal.Y, Z = hit.ImpactNormal.Z } end)
    end
    if not hitN then
        local dd = math.max(1, dist(cam, hitP))
        hitN = { X = (cam.X - hitP.X) / dd, Y = (cam.Y - hitP.Y) / dd, Z = (cam.Z - hitP.Z) / dd }
    end
    local okS, err = pcall(function() jam:ServerShootJammer(best.t, hitP, hitN) end)
    if okS then log("jammer: fired at %s (%.0f m)", best.o:GetFName():ToString(), best.d / 100)
    else log("jammer: %s", tostring(err)) end
end

------------------------------------------------------------------------------------------------ syringe
-- The revive syringe (slot 2) lives in the collapsible inventory. In hand, holding the trigger primes it, and a stab
-- (the needle, socket s_muzzle, moving at >= 40 cm/s into a syringe target: downed teammate, bot, tutorial dummy)
-- attaches it for 3 s and heals / revives. LMB with the syringe in hand, FPS style: prime, then stab the target under
-- the crosshair; the syringe stays in the target and the hand lets go.
local SHAPE, SKEL = nil, nil
local function jabPoints(a)   -- where a target can be stabbed: chest/pelvis bones, else its collision shapes
    local pts = {}
    -- by class: bots don't expose their Mesh property to Lua
    SKEL = SKEL or StaticFindObject("/Script/Engine.SkeletalMeshComponent")
    local okM, mesh = pcall(function() return a:GetComponentByClass(SKEL) end)
    if okM and mesh and mesh:IsValid() then
        for _, b in ipairs({ "spine_03", "spine_02", "pelvis" }) do
            local ok, l = pcall(function() return mesh:DoesSocketExist(FName(b)) and mesh:GetSocketLocation(FName(b)) or nil end)
            if ok and l then table.insert(pts, l) end
        end
    end
    if #pts == 0 then
        SHAPE = SHAPE or StaticFindObject("/Script/Engine.ShapeComponent")
        for _, x in ipairs(a:K2_GetComponentsByClass(SHAPE) or {}) do
            local c = x.get and x:get() or x
            if c:IsValid() then table.insert(pts, c:K2_GetComponentLocation()) end
        end
    end
    return pts
end

-- the jab point closest to the crosshair (within 25 degrees and syringe_reach of the eye), in world space
local function syringeAim()
    local reach, best, bestA = cfg.syringe_reach or 160, nil, math.rad(25)
    for _, c in ipairs(FindAllOf("CLPSyringeTargetComponent") or {}) do
        local o = c:IsValid() and c:GetOwner()
        if o and o:IsValid() and o ~= S.pawn then
            for _, w in ipairs(jabPoints(o)) do
                local x, y, z = toCam(w)
                local d = math.sqrt(x * x + y * y + z * z)
                local ang = math.atan(math.sqrt(y * y + z * z), x)
                if x > 0 and d < reach and ang < bestA then best, bestA = { w = w, owner = o }, ang end
            end
        end
    end
    return best
end

local function syringeState(s)
    local ok, v = pcall(function() return s.SyringeReplicationData.State end)   -- 0 idle, 1 primed, 2 attached, 3 released
    return ok and v or -1
end

local KMATH = nil
local function needle(s)   -- needle tip (world) and the direction it points (world, unit)
    local m = s:GetComponentByClass(StaticFindObject("/Script/Engine.StaticMeshComponent"))
    KMATH = KMATH or StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local f = KMATH:GetForwardVector(m:GetSocketRotation(FName("s_muzzle")))
    return m:GetSocketLocation(FName("s_muzzle")), { X = f.X, Y = f.Y, Z = f.Z }
end

local function syringeJab()
    if busy() then return end
    local s = S.syringe
    if not (s and s:IsValid() and S.grip[1]) then return end
    local aim = syringeAim()
    if not aim then log("syringe: no teammate under the crosshair (within %d cm)", cfg.syringe_reach or 160); return end
    -- needle tip from the hand target; the hand keeps its rotation while holding the syringe, so this stays put
    local tipW, dir = needle(s)
    local nx, ny, nz = toCam(tipW)
    local hx, hy, hz = toCam(S.pawn:GetHandTransformTarget(1).Translation)
    local off = { nx - hx, ny - hy, nz - hz }
    local w, name = aim.w, aim.owner:GetFName():ToString()
    local function at(k)   -- k cm along the needle's own axis from the target point (negative = before it)
        return { X = w.X + dir.X * k, Y = w.Y + dir.Y * k, Z = w.Z + dir.Z * k }
    end
    local function finish(ok, msg)
        S.trigger = false; inject("IA_Trigger_R", 0)
        if ok then setGrip(1, false); S.heldSlot = nil; S.syringe = nil end
        log("syringe: %s", msg)
        after(0.2, function() handHome(1) end)
    end
    -- prime (hold the trigger) and line the needle up 20 cm short of the target, pointing at it
    S.trigger = true
    setOverride(1, { fn = function() return at(-20) end, off = off })
    local tries = 0
    local function lineUp()
        tries = tries + 1
        if dist(needle(s), at(-20)) > 4 and tries < 50 then after(0.04, lineUp); return end
        -- stab: drive the needle 8 cm past the point along its axis; the game attaches it on contact (at 40 cm/s or
        -- more: an exact jump, not smoothed)
        setOverride(1, { fn = function() return at(8) end, off = off }, INSTANT)
        local checks = 0
        local function check()
            checks = checks + 1
            local st = syringeState(s)
            if st == 2 or st == 3 then return finish(true, "injected " .. name) end
            if checks < 20 then after(0.04, check) else finish(false, string.format("missed %s (state %d)", name, st)) end
        end
        after(0.04, check)
    end
    after(0.1, lineUp)
    log("syringe: stab %s", name)
end

------------------------------------------------------------------------------------------------ levers (drill)
-- Levers (CLPLever: the thermal lance drill's activation and calibration lever) swing about their handle base. In VR
-- you grab the handle and move it along its arc. Here: F with the crosshair on a lever grabs its grip; while held, the
-- mouse sets the lever angle (the camera stays still) and the hand is placed exactly on the arc. F again lets go.
local function rotateAbout(v, k, a)   -- rotate vector v about unit axis k by a radians (Rodrigues)
    local c, s = math.cos(a), math.sin(a)
    local d = k.X * v.X + k.Y * v.Y + k.Z * v.Z
    return { X = v.X * c + (k.Y * v.Z - k.Z * v.Y) * s + k.X * d * (1 - c),
             Y = v.Y * c + (k.Z * v.X - k.X * v.Z) * s + k.Y * d * (1 - c),
             Z = v.Z * c + (k.X * v.Y - k.Y * v.X) * s + k.Z * d * (1 - c) }
end

local function leverGrip(l) return l.LeverHandle:GetSocketLocation(FName("s_grip")) end
local function leverAngle(l) local ok, v = pcall(function() return l.TargetRotation end); return (ok and type(v) == "number") and v or 0 end

-- Optional assist: the drill screen's peak drifts toward TargetBellCurvePeakValue at BellCurveMovementSpeed per second
-- (the current peak itself isn't readable from Lua), so follow an estimate of it. Returns 0..1, or nil if not calibrating.
local function drillPeak(lv)
    local best, bestD = nil, 400
    for _, d in ipairs(FindAllOf("CLPDrill") or {}) do
        if d:IsValid() then
            local dd = dist(d:K2_GetActorLocation(), lv.pivot)
            if dd < bestD then best, bestD = d, dd end
        end
    end
    if not best or best.bCalibratingDrill ~= true then return nil end
    local sc = best.DrillScreen
    local target, speed = sc.TargetBellCurvePeakValue, sc.BellCurveMovementSpeed
    local t = now()
    lv.peak = lv.peak or target
    local step = speed * math.min(0.1, t - (lv.peakT or t))
    lv.peak = lv.peak + math.max(-step, math.min(step, target - lv.peak))
    lv.peakT = t
    return lv.peak
end

local function leverUnderCrosshair()
    local best, bestA = nil, math.rad(20)
    for _, l in ipairs(FindAllOf("CLPLever") or {}) do
        local ok, g = pcall(leverGrip, l)
        if ok and g then
            local x, y, z = toCam(g)
            local d = math.sqrt(x * x + y * y + z * z)
            local ang = math.atan(math.sqrt(y * y + z * z), x)
            if x > 0 and d < (cfg.lever_reach or 150) and ang < bestA then best, bestA = l, ang end
        end
    end
    return best
end

-- a point grabbed at the lever's grab angle, swung about the pivot to lever angle `a` (degrees)
local function leverPoint(lv, off, a)
    local o = rotateAbout(off, lv.axis, math.rad((a - lv.a0) * (cfg.lever_direction or 1)))
    return { X = lv.pivot.X + o.X, Y = lv.pivot.Y + o.Y, Z = lv.pivot.Z + o.Z }
end

local function releaseLever(msg)
    if not S.lever then return end
    local wasDrill = S.lever.drill
    setGrip(1, false); S.lever = nil
    if wasDrill and (cfg.lever_fov or 0) > 0 then setFov(cfg.fov or 0) end   -- back to the normal field of view (0 = unlock)
    after(0.15, function() handHome(1) end)
    log("lever: %s", msg or "let go")
end

local function grabLever(l, attempt, pulls)
    attempt = attempt or 1
    if busy() then return end
    if S.grip[1] then log("lever: put away what's in your right hand first"); return end
    reachFollow(1, function() return leverGrip(l) end)
    local tries = 0
    local function settle()
        tries = tries + 1
        if dist(handLoc(1), leverGrip(l)) > 6 and tries < 40 then after(0.04, settle); return end
        -- where the controller is when the grip closes: the lever measures its angle from the controller, so swinging
        -- this point about the pivot turns the lever by exactly the same angle
        local mc0 = S.pawn.RightInteractionComponent.MotionSource:K2_GetComponentLocation()
        setGrip(1, true)
        local base = l.LeverHandleBase
        KMATH = KMATH or StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
        local pivot, g = base:K2_GetComponentLocation(), leverGrip(l)
        local a0 = leverAngle(l)
        S.lever = { l = l, pivot = pivot, axis = KMATH:GetRightVector(base:K2_GetComponentRotation()),
                    off = { X = g.X - pivot.X, Y = g.Y - pivot.Y, Z = g.Z - pivot.Z },
                    mcOff = { X = mc0.X - pivot.X, Y = mc0.Y - pivot.Y, Z = mc0.Z - pivot.Z },
                    a0 = a0, angle = a0, max = l.MaxRotationAngle or 60 }
        local lv = S.lever
        lv.bias = 0
        lv.pulls = pulls or 1
        lv.wasActive = prop(l, "bLeverActivated") == true
        lv.act = prop(l, "AngleInDegreesToConsiderActivated")
        lv.drill = l:GetClass():GetFName():ToString():find("Drill") ~= nil   -- BP_Drill_Lever_01_C (calibration lever)
        if prop(l, "bLeverEnabled") == false then log("lever: %s isn't enabled yet (it only moves a little)", l:GetFName():ToString()) end
        setOverride(1, { fn = function() return leverPoint(lv, lv.off, lv.angle) end }, INSTANT)   -- mouse-driven: exact
        -- the grip closed but the game didn't take the lever (the hand stopped short): the mouse would move the hand and
        -- nothing else. Let go and grab once more, then say so.
        after(0.3, function()
            if S.lever ~= lv or holding(1) then return end
            releaseLever("missed the handle")
            if attempt < 2 then after(0.3, function() grabLever(l, 2, pulls) end)
            else log("lever: couldn't get hold of it: step closer and press F again") end
        end)
        -- the lever settles a fixed number of degrees off once gripped; measure it and take it out
        after(0.35, function()
            local g2 = leverAngle(l)
            if S.lever == lv and g2 > 1 and g2 < lv.max - 1 then lv.bias = g2 - lv.angle end
        end)
        -- zoom in so the drill screen is readable (the game resets the camera's own FOV every frame; the camera
        -- manager's locked FOV, set by the "fov" command, sticks)
        if lv.drill and (cfg.lever_fov or 0) > 0 then setFov(cfg.lever_fov) end
        if (pulls or 1) > 1 then after(0.45, function() if S.lever == lv then lv.ramp = { to = lv.max, speed = 150 } end end) end
        log("lever: grabbed %s at %.0f deg (max %.0f)", l:GetFName():ToString(), a0, lv.max)
    end
    after(0.1, settle)
end

------------------------------------------------------------------------------------------------ rotary controls
-- Twist switches (ACLPSwitch), knobs (ACLPKnob: the pocket drill's activation knob), combination dials (ACLPCombinationLock
-- on safes and deposit boxes) and wheels (ACLPWheel: vault wheels). In VR you grab them and turn your hand. Here: F with
-- the crosshair on one grabs it, then mouse X turns it (right = clockwise as you look at it) and F lets go. While held,
-- the mod turns the motion controller (position and orientation) about the control's axis through its centre, which is
-- what the game reads, and keeps the visible hand on the turned grab point.
-- comp = the part the hand grabs; axis = which local axis of `axisComp` (default comp) it turns about, or "twist": the
-- control reads the twist of the controller about its own X axis (safe dials, the pocket drill knob). For those the
-- controller is first turned so its X axis points into the dial, the way a real hand holds it, then spun about that
-- axis in place on the grab point. (v0.3.0 spun it about whatever X was, which pointed up with our hand pose: the hand
-- swung sideways and the dial reset after a few numbers.)
-- rim = grab this many cm out from the axis (wheels are turned by the rim), else at the object's grab socket;
-- step = degrees per number (the mouse wheel turns one number per notch); zoom = narrow the view while holding it;
-- doneProp = a property that turns true when it has done its job (the mod lets go then).
local ROTARY = {
    { cls = "CLPSwitch", comp = "SwitchMesh", axisComp = "SwitchMeshHolder", axis = "X", doneProp = "bDone" },
    { cls = "CLPKnob", comp = "KnobMesh", axis = "twist", zoom = true },
    { cls = "CLPCombinationLock", comp = "CombinationLock", axis = "twist", step = 30, zoom = true, doneProp = "bDone" },
    -- valves / vault wheels: the mod sets the wheel's angle itself (drive), see the rotary branch in tick()
    { cls = "CLPWheel", comp = "Wheel", axis = "X", rim = 22, doneProp = "bActivated", drive = true },
}

local function axisOf(c, which)
    if which == "Y" then return c:GetRightVector() elseif which == "Z" then return c:GetUpVector() end
    return c:GetForwardVector()
end

local function rotaryUnderCrosshair()
    local best, bestA = nil, math.rad(15)
    for _, kind in ipairs(ROTARY) do
        for _, a in ipairs(FindAllOf(kind.cls) or {}) do
            local ok, c = pcall(function() return a[kind.comp] end)
            if ok and c and c:IsValid() then
                local x, y, z = toCam(c:K2_GetComponentLocation())
                local d, ang = math.sqrt(x * x + y * y + z * z), math.atan(math.sqrt(y * y + z * z), x)
                if x > 0 and d < (cfg.lever_reach or 150) and ang < bestA then best, bestA = { a = a, kind = kind, c = c }, ang end
            end
        end
    end
    return best
end

local function releaseRotary(msg)
    if not S.rotary then return end
    local zoomed = S.rotary.kind.zoom
    setGrip(1, false); S.rotary = nil
    if zoomed and (cfg.dial_fov or 0) > 0 then setFov(cfg.fov or 0) end   -- back to the normal view (0 = unlock)
    after(0.15, function() handHome(1) end)
    log("turn: %s", msg or "let go")
end

local function rotaryDone(r)
    local p = r.kind.doneProp
    return p and prop(r.a, p) == true
end

-- world position/rotation of the motion controller for turn angle `deg` (rotating the grab-time pose about the axis)
local function rotaryPose(r, deg)
    local o = rotateAbout(r.mcOff, r.axis, math.rad(deg))
    local loc = { X = r.pivot.X + o.X, Y = r.pivot.Y + o.Y, Z = r.pivot.Z + o.Z }
    KMATH = KMATH or StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local rot = KMATH:ComposeRotators(r.mcRot, KMATH:RotatorFromAxisAndAngle(r.axis, deg))
    return loc, rot
end

-- where the hand grabs: the centre, or for wheels the top of the rim (as seen from the camera)
local function rotaryGrabPoint(t)
    local c = t.c
    local p = c:K2_GetComponentLocation()
    if not t.kind.rim then
        -- the object's own grab point: InteractionProperties.InteractionPoints[1].SocketName (s_grip: e.g. 8.5 cm in
        -- front of a safe dial). The game drops a stationary grab when the controller is too far from it.
        local ok, sock = pcall(function()
            local pts = t.a.InteractionProperties.InteractionPoints
            return #pts > 0 and pts[1].SocketName or nil
        end)
        if ok and sock and c:DoesSocketExist(sock) then return c:GetSocketLocation(sock) end
        return p
    end
    local axisComp = t.kind.axisComp and t.a[t.kind.axisComp] or c
    local k = axisOf(axisComp, t.kind.axis)
    local u = camera():GetUpVector()
    local d = u.X * k.X + u.Y * k.Y + u.Z * k.Z
    local v = { X = u.X - k.X * d, Y = u.Y - k.Y * d, Z = u.Z - k.Z * d }
    local n = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
    if n < 1e-3 then return p end
    return { X = p.X + v.X / n * t.kind.rim, Y = p.Y + v.Y / n * t.kind.rim, Z = p.Z + v.Z / n * t.kind.rim }
end

local function grabRotary(t)
    if busy() then return end
    if S.grip[1] then log("turn: put away what's in your right hand first"); return end
    local c = t.c
    local gp = rotaryGrabPoint(t)
    reachFollow(1, function() return gp end)
    local tries = 0
    local function settle()
        tries = tries + 1
        if dist(handLoc(1), gp) > 5 and tries < 25 then after(0.04, settle); return end
        -- the visible hand can stop a few cm short (its collision touches the safe door around a dial), so the grab
        -- happens with the motion controller placed exactly on the grab point; the hand is drawn where it got to
        local mc = S.pawn.RightInteractionComponent.MotionSource
        local hl, mcRot = handLoc(1), mc:K2_GetComponentRotation()
        local mcLoc = gp
        local axis, pivot
        KMATH = KMATH or StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
        if t.kind.axis == "twist" then
            -- hold it like a hand would: controller X from the grab point into the dial's centre, Z = the camera's up
            -- (so the palm faces the dial the same way at any height); then spin about that X in place
            local ctr = c:K2_GetComponentLocation()
            local into = { X = ctr.X - gp.X, Y = ctr.Y - gp.Y, Z = ctr.Z - gp.Z }
            local n = math.sqrt(into.X ^ 2 + into.Y ^ 2 + into.Z ^ 2)
            if n < 1 then   -- no grab socket in front of it: from the eye to the dial
                local cam = camera():K2_GetComponentLocation()
                into = { X = ctr.X - cam.X, Y = ctr.Y - cam.Y, Z = ctr.Z - cam.Z }
                n = math.sqrt(into.X ^ 2 + into.Y ^ 2 + into.Z ^ 2)
            end
            into = { X = into.X / n, Y = into.Y / n, Z = into.Z / n }
            local up = camera():GetUpVector()
            mcRot = KMATH:MakeRotFromXZ(into, { X = up.X, Y = up.Y, Z = up.Z })
            axis, pivot = into, mcLoc
        else
            local axisComp = t.kind.axisComp and t.a[t.kind.axisComp] or c
            axis = axisOf(axisComp, t.kind.axis)
            -- the axis points out of the control's face or into it; flip it so it points at us, then a positive angle
            -- is counter-clockwise as seen by the player and mouse right (clockwise) is negative
            local cam = camera():K2_GetComponentLocation()
            pivot = c:K2_GetComponentLocation()
            if (cam.X - pivot.X) * axis.X + (cam.Y - pivot.Y) * axis.Y + (cam.Z - pivot.Z) * axis.Z < 0 then
                axis = { X = -axis.X, Y = -axis.Y, Z = -axis.Z }
            end
        end
        local r = { a = t.a, kind = t.kind, c = c, pivot = pivot, axis = { X = axis.X, Y = axis.Y, Z = axis.Z },
                    mcOff = { X = mcLoc.X - pivot.X, Y = mcLoc.Y - pivot.Y, Z = mcLoc.Z - pivot.Z },
                    mcRot = { Pitch = mcRot.Pitch, Yaw = mcRot.Yaw, Roll = mcRot.Roll },
                    hOff = { X = hl.X - pivot.X, Y = hl.Y - pivot.Y, Z = hl.Z - pivot.Z },
                    angle = 0, target = 0, t0 = now(),
                    wasDone = rotaryDone({ a = t.a, kind = t.kind }) }
        if t.kind.drive then
            -- the game's angle (WorldTargetDegrees) turns about the wheel's own X axis; ours points at the player
            local wx = c:GetForwardVector()
            r.s = (axis.X * wx.X + axis.Y * wx.Y + axis.Z * wx.Z) >= 0 and 1 or -1
            r.base = prop(t.a, "WorldTargetDegrees") or 0
            r.sent = r.base
        end
        S.rotary = r
        after(0.05, function() if S.rotary == r then setGrip(1, true) end end)   -- once the controller is on the point
        setOverride(1, { fn = function()   -- mouse-driven: exact (INSTANT)
            if t.kind.axis == "twist" then return hl end   -- the game draws the hand on the dial anyway
            local o = rotateAbout(r.hOff, r.axis, math.rad(r.angle))
            return { X = r.pivot.X + o.X, Y = r.pivot.Y + o.Y, Z = r.pivot.Z + o.Z }
        end }, INSTANT)
        if t.kind.zoom and (cfg.dial_fov or 0) > 0 then setFov(cfg.dial_fov) end
        log("turn: grabbed %s (%s, F lets go)", t.a:GetFName():ToString(),
            t.kind.step and "mouse wheel = one number, mouse X = free turn"
                or t.kind.drive and "mouse right or wheel down = clockwise" or "mouse X turns it")
    end
    after(0.1, settle)
end

------------------------------------------------------------------------------------------------ crosshair
local function makeCrosshair()
    if not cfg.show_crosshair or (S.crosshair and S.crosshair:IsValid()) then return end
    local mesh = StaticFindObject("/Engine/EngineMeshes/Sphere.Sphere")
    local mat = StaticFindObject("/Engine/EngineMaterials/EmissiveMeshMaterial.EmissiveMeshMaterial")
    local cls = StaticFindObject("/Script/Engine.StaticMeshComponent")
    if not (mesh and mesh:IsValid() and cls) then log("crosshair mesh not loaded"); return end
    local c = S.pawn:AddComponentByClass(cls, true, { Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false)
    if not c or not c:IsValid() then return end
    c:SetStaticMesh(mesh)
    if mat and mat:IsValid() then c:SetMaterial(0, mat) end
    c:SetCollisionEnabled(0)
    c:SetCastShadow(false)
    c:K2_AttachToComponent(camera(), FName("None"), 0, 0, 0, false)
    c:K2_SetRelativeLocation({ X = 100.0, Y = 0.0, Z = 0.0 }, false, {}, true)
    c:SetRelativeScale3D({ X = 0.0035, Y = 0.0035, Z = 0.0035 })
    S.crosshair = c
end

------------------------------------------------------------------------------------------------ HUD scale
-- The message feed (area indicator, objective pop-ups, subtitles, secondary messages, stacked top to bottom) is one
-- world-space panel the game keeps at OffsetToCameraLocation (123 cm ahead, 63.5 cm down) with the widget 45 cm above
-- that point. Bringing both closer by hud_scale magnifies the panel by that factor around its centre. The watch
-- objectives panel is scaled in place and pushed out from the watch by the same factor so it doesn't cover the face.
local function original(obj, name, read)   -- the game's own value, remembered per object
    S.hudOrig = S.hudOrig or {}
    local key = obj:GetFullName() .. ":" .. name
    if not S.hudOrig[key] then S.hudOrig[key] = read() end
    return S.hudOrig[key]
end
local function vec(v) return { X = v.X, Y = v.Y, Z = v.Z } end
local function near(a, b) return math.abs(a.X - b.X) + math.abs(a.Y - b.Y) + math.abs(a.Z - b.Z) < 0.01 end

local function applyHudScale()
    local t = now()
    if (S.hudCheck or 0) > t then return end
    S.hudCheck = t + 0.5
    local k = cfg.hud_scale or 1
    for _, c in ipairs(FindAllOf("CLPMessageFeedPlayerComponent") or {}) do
        if c:IsValid() then
            local o = original(c, "offset", function() return vec(c.OffsetToCameraLocation) end)
            local want = { X = o.X / k, Y = o.Y / k, Z = o.Z / k + (cfg.hud_raise or 0) }
            if not near(c.OffsetToCameraLocation, want) then c.OffsetToCameraLocation = want end
        end
    end
    for _, a in ipairs(FindAllOf("CLPMessageFeedActor") or {}) do
        local w = a:IsValid() and a.MessageFeedWidgetComponent
        if w and w:IsValid() then
            local o = original(w, "location", function() return vec(w.RelativeLocation) end)
            local want = { X = o.X / k, Y = o.Y / k, Z = o.Z / k }
            if not near(w.RelativeLocation, want) then w:K2_SetRelativeLocation(want, false, {}, true) end
        end
    end
    local s = cfg.watch_ui_scale or 1
    for _, a in ipairs(FindAllOf("CLPWatchObjectivesActor") or {}) do
        local w = a:IsValid() and a.WidgetComponent
        if w and w:IsValid() then
            local o = original(w, "scale", function() return { scale = w.RelativeScale3D.X, offset = a.WatchXOffset } end)
            if math.abs(w.RelativeScale3D.X - o.scale * s) > 1e-5 then
                w:SetRelativeScale3D({ X = o.scale * s, Y = o.scale * s, Z = o.scale * s })
                a.WatchXOffset = o.offset * s
            end
        end
    end
end

------------------------------------------------------------------------------------------------ per-character setup
-- "online" = a client of someone else's server (the game's matchmaking puts you on dedicated servers). Standalone (the
-- game's Solo serverless mode, "open") and hosting are local.
local function online(pc)
    local ok, server = pcall(function() return ksl():IsServer(pc) end)
    return ok and not server
end

local function setupPawn(p)
    if S.crosshair and S.crosshair:IsValid() then pcall(function() S.crosshair:K2_DestroyComponent(S.crosshair) end) end
    S.pawn, S.pitch, S.crosshair, S.xhHidden = p, 0.0, nil, nil
    if not S.keepGrip then S.grip[0], S.grip[1] = false, false end
    S.keepGrip = false
    S.override[0], S.override[1], S.steps = nil, nil, {}
    S.trigger, S.hack, S.lever, S.poke, S.rotary = false, nil, nil, nil, nil
    S.carry, S.regrab, S.reloadQueued, S.reloading = nil, nil, nil, false
    S.shellLoad, S.shellStop, S.pump, S.pumpSeen, S.pumpMC = false, false, nil, nil, nil
    S.rayWI, S.cursor, S.menuOpen, S.menuCheck = nil, { x = 0, y = 0 }, false, 0
    lastPose[0], lastPose[1] = "", ""
    resetBlend()   -- a new character's hands start at their poses, no blend from the old one
    after(1.0, applyFov)   -- not in the frame the map finishes loading
    if cfg.hide_own_body then
        for _, n in ipairs({ "CostumeMesh", "SkelMesh" }) do
            local m = p[n]; if m and m:IsValid() then m:SetOwnerNoSee(true) end
        end
    end
    S.slotMemory = { [3] = slotItem(3), [4] = slotItem(4) }
    pcall(makeCrosshair)
    log("ready on %s", p:GetFName():ToString())
end

------------------------------------------------------------------------------------------------ aim calibration
-- every gun is held at a slightly different angle, so we measure its sight line (sight bones, or muzzle/chamber)
-- in camera space and steer the right hand until the sights point at the crosshair. Corrections are kept per gun.
S.calib = {}  -- recalibrate after a reload

local function gunInRightHand()
    if not S.grip[1] then S.gun = nil; return nil end
    local t = now()
    if S.gun and S.gun:IsValid() and (S.gunCheck or 0) > t then return S.gun end
    S.gunCheck = t + 0.5
    -- what the game says the right hand holds (v0.3.5). The old guess (an actor attached to us within 35 cm of the hand)
    -- missed every gun whose origin is further from the grip (rack rifles, shotguns, SMGs): no foregrip hand while
    -- aiming and no aim assist with those
    local c = holding(1)
    local g = c and c:GetOwner() or nil
    if not g then g = heldBy(1) end
    if g then local ok, fa = pcall(function() return g.FirearmComponent end); if not (ok and fa and fa.IsValid and fa:IsValid()) then g = nil end end
    S.gun = g
    return g
end

-- {rear sight socket, height of the sight picture above it (cm)}: the pre-v0.3.22 way to find the sights, still used
-- for items without an ADS profile (the grappling hook)
local SIGHTS = { { "s_backsight", 5.5 }, { "IronSightRear_Bone", 0 }, { "s_Chamber", 4 } }

local function hasSocket(m, name)
    local ok, e = pcall(function() return m:DoesSocketExist(FName(name)) end)
    return ok and e
end

-- barrel axis (where the bullets go) and rear sight position, both in camera space. The bore direction is the
-- muzzle socket's forward axis; s_Chamber is not on the bore on every gun (the pistol's sits ~6 degrees off).
local KML = nil
-- the mesh that carries the muzzle socket: guns are skeletal, the grappling hook is a static mesh actor
local function aimMesh(item)
    local ok, m = pcall(function() return item.SkeletalMeshComponent end)
    if ok and m and m.IsValid and m:IsValid() then return m end
    ok, m = pcall(function() return item.StaticMeshComponent end)
    if ok and m and m.IsValid and m:IsValid() then return m end
    return nil
end

-- gun mesh space (+Y = forward along the barrel, +Z = up, as the weapon sockets are laid out) <-> world
local function meshSpace(m, w)
    local o = m:K2_GetComponentLocation()
    local f, r, u = m:GetForwardVector(), m:GetRightVector(), m:GetUpVector()
    local dx, dy, dz = w.X - o.X, w.Y - o.Y, w.Z - o.Z
    return dx * f.X + dy * f.Y + dz * f.Z, dx * r.X + dy * r.Y + dz * r.Z, dx * u.X + dy * u.Y + dz * u.Z
end
local function meshPoint(m, x, y, z)
    local o = m:K2_GetComponentLocation()
    local f, r, u = m:GetForwardVector(), m:GetRightVector(), m:GetUpVector()
    return { X = o.X + f.X * x + r.X * y + u.X * z, Y = o.Y + f.Y * x + r.Y * y + u.Y * z, Z = o.Z + f.Z * x + r.Z * y + u.Z * z }
end
-- world direction -> camera space
local function camDir(v)
    local cam = camera()
    local f, r, u = cam:GetForwardVector(), cam:GetRightVector(), cam:GetUpVector()
    return v.X * f.X + v.Y * f.Y + v.Z * f.Z, v.X * r.X + v.Y * r.Y + v.Z * r.Z, v.X * u.X + v.Y * u.Y + v.Z * u.Z
end

------------------------------------------------------------------------------------------------ ADS profiles
-- v0.3.22: each gun has its own aim-down-sights profile. Where the sight line is: a point {y, z} in the gun mesh's
-- space (the rear end of the line; the line runs parallel to the barrel), how far it sits from the eye (relief), how
-- long a full raise takes (time), and the motion on the way up: cant (degrees the gun tilts, mid-raise) and push (cm
-- it moves out, mid-raise, before it settles back to the cheek). Sources, first found wins:
--   1. an enabled red dot (CLPRedDotSightComponent, a loadout modification): its sight mesh's dot socket
--   2. cfg.ads_weapons[family] y/z (measured per gun in the safehouse armory, v0.3.22)
--   3. the gun's own iron sight posts (rifles: the meshes the game attaches at s_frontsight / s_backsight); the line
--      runs over the front post's tip
--   4. cfg.ads_classes[class].above_bore: that many cm above the muzzle (an unknown gun)
-- relief/time/cant/push come from ads_weapons[family], else ads_classes[class], else ads_classes.default.
local function gunFamily(item)
    local cn = item:GetClass():GetFName():ToString()
    local base = cn:gsub("^BP_WP_", ""):gsub("_C$", ""):gsub("_DC$", ""):gsub("_SE$", ""):gsub("_XA$", ""):gsub("_Enemy$", "")
    local class, name = base:match("^(%a+)_(.+)$")
    return name or base, class or "?"
end

local SMC = nil
local function attachedMeshes(gun)
    SMC = (SMC and SMC:IsValid()) and SMC or StaticFindObject("/Script/Engine.StaticMeshComponent")
    local out = {}
    local arr = gun:K2_GetComponentsByClass(SMC)
    for i = 1, #arr do
        local c = arr[i]
        if c and c.get then c = c:get() end
        if c and c:IsValid() then out[#out + 1] = c end
    end
    return out
end
local function attachSocket(c)
    local ok, s = pcall(function() return c:GetAttachSocketName():ToString() end)
    return ok and s or ""
end
-- the highest point of a static mesh component, in gun mesh space (z)
local function meshTop(m, c)
    local bb = c.StaticMesh:GetBoundingBox()
    local cl = c:K2_GetComponentLocation()
    local f, r, u = c:GetForwardVector(), c:GetRightVector(), c:GetUpVector()
    local sc = c:K2_GetComponentScale()
    local top = -1e9
    for _, ax in ipairs({ bb.Min.X, bb.Max.X }) do for _, ay in ipairs({ bb.Min.Y, bb.Max.Y }) do for _, az in ipairs({ bb.Min.Z, bb.Max.Z }) do
        local x, y, z = ax * sc.X, ay * sc.Y, az * sc.Z
        local _, _, mz = meshSpace(m, { X = cl.X + f.X * x + r.X * y + u.X * z, Y = cl.Y + f.Y * x + r.Y * y + u.Y * z, Z = cl.Z + f.Z * x + r.Z * y + u.Z * z })
        if mz > top then top = mz end
    end end end
    return top
end
-- iron sight posts (rifles): y of the rear sight, z of the front post's tip
local function ironSightLine(gun, m)
    if not (hasSocket(m, "s_frontsight") and hasSocket(m, "s_backsight")) then return nil end
    local front = nil
    for _, c in ipairs(attachedMeshes(gun)) do
        if attachSocket(c) == "s_frontsight" and c:IsVisible() then
            local ok, t = pcall(meshTop, m, c)
            if ok then front = t end
        end
    end
    if not front then return nil end
    local _, ry = meshSpace(m, m:GetSocketLocation(FName("s_backsight")))
    return ry, front
end
-- an enabled red dot: its sight mesh component and the dot socket
local RDC = nil
local function redDot(gun)
    RDC = (RDC and RDC:IsValid()) and RDC or StaticFindObject("/Script/Angelscript.CLPRedDotSightComponent")
    if not (RDC and RDC:IsValid()) then return nil end
    local rd = gun:GetComponentByClass(RDC)
    if not (rd and rd:IsValid() and rd.bEnabled == true) then return nil end
    local d = rd.Data
    local att, sock = d.SightAttachment_SocketName:ToString(), d.Sight_SocketName
    for _, c in ipairs(attachedMeshes(gun)) do
        if attachSocket(c) == att and c:IsVisible() and c:DoesSocketExist(sock) then return c, sock end
    end
    return nil
end

local function adsProfile(gun)
    S.adsCache = S.adsCache or {}
    local key = gun:GetFullName()
    local e = S.adsCache[key]
    if e and e.t > now() and (not e.p.dot or e.p.dot:IsValid()) then return e.p end
    local fam, class = gunFamily(gun)
    local classes = cfg.ads_classes or {}
    local cl = classes[class] or classes.default or {}
    local w = (cfg.ads_weapons or {})[fam] or {}
    local tune = (S.adsTune or {})[fam] or {}
    local function pick(k, d) if tune[k] ~= nil then return tune[k] elseif w[k] ~= nil then return w[k] elseif cl[k] ~= nil then return cl[k] end; return d end
    local p = { fam = fam, class = class, src = "?",
        relief = pick("relief", cfg.ads_sight_distance or 22), time = pick("time", cfg.ads_time or 0.25),
        cant = pick("cant", 0), push = pick("push", 0) }
    local m = aimMesh(gun)
    if not m then return nil end
    local okD, dc, ds = pcall(redDot, gun)
    if okD and dc then
        p.dot, p.dotSock, p.src = dc, ds, "red dot"
        -- (v0.3.30) Where the gun sits with a dot: the relief values are tuned to the iron sights' rear point, so
        -- measured to the dot they put the gun somewhere else (the AV56's dot sits behind its mid-gun rear sight, so the
        -- gun went further out). Now: the gun where its iron sights hold it, then dot_closer cm closer (never nearer
        -- than ads_dot_min to the dot). An explicit dot_relief (eye to the dot) still wins.
        local explicit = pick("dot_relief")
        if explicit then p.relief = explicit
        else
            local _, dy = meshSpace(m, dc:GetSocketLocation(ds))
            local iy = pick("y")
            if not iy then
                local sk = hasSocket(m, "s_backsight") and "s_backsight" or hasSocket(m, "IronSightRear_Bone") and "IronSightRear_Bone"
                    or hasSocket(m, "s_grip") and "s_grip" or "s_muzzle"
                local _, sy = meshSpace(m, m:GetSocketLocation(FName(sk)))
                iy = sy
            end
            p.dotShift = dy - iy
            p.relief = math.max(cfg.ads_dot_min or 10, p.relief + p.dotShift - pick("dot_closer", cfg.ads_dot_closer or 8))
        end
    else
        p.y, p.z = pick("y"), pick("z")
        if p.z then p.src = "table"
        else
            local okI, iy, iz = pcall(ironSightLine, gun, m)
            if okI and iz then p.y, p.z, p.src = p.y or iy, iz, "iron sights"
            else
                local _, _, mz = meshSpace(m, m:GetSocketLocation(FName("s_muzzle")))
                p.z, p.src = mz + (cl.above_bore or 2), "class"
            end
        end
        if not p.y then
            local _, gy = meshSpace(m, m:GetSocketLocation(FName(hasSocket(m, "s_grip") and "s_grip" or "s_muzzle")))
            p.y = gy
        end
    end
    S.adsCache[key] = { t = now() + 2, p = p }   -- re-read every 2 s: sight attachments can change
    return p
end

local function gunGeometry(gun, prof)
    local m = aimMesh(gun)
    if not m then return nil end
    if not hasSocket(m, "s_muzzle") then return nil end
    if not KML or not KML:IsValid() then KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary") end
    local mw = m:GetSocketLocation(FName("s_muzzle"))
    local fwd = KML:GetForwardVector(m:GetSocketRotation(FName("s_muzzle")))
    local mx, my, mz = toCam(mw)
    local tx, ty, tz = toCam({ X = mw.X + fwd.X * 100, Y = mw.Y + fwd.Y * 100, Z = mw.Z + fwd.Z * 100 })
    local rx, ry, rz, roll = nil, nil, nil, 0
    if prof and (prof.dot or prof.z) then
        -- the sight line's rear point (or the red dot), and how far the gun is tilted about the line of sight
        local w = prof.dot and prof.dot:GetSocketLocation(prof.dotSock) or meshPoint(m, 0, prof.y, prof.z)
        rx, ry, rz = toCam(w)
        local _, uy, uz = camDir(m:GetUpVector())
        roll = math.deg(math.atan(uy, uz))
    else
        rx, ry, rz = mx - (tx - mx) * 0.2, my - (ty - my) * 0.2, mz - (tz - mz) * 0.2 + 4
        for _, sgt in ipairs(SIGHTS) do
            if hasSocket(m, sgt[1]) then rx, ry, rz = toCam(m:GetSocketLocation(FName(sgt[1]))); rz = rz + sgt[2]; break end
        end
    end
    return { bx = mx - (tx - mx), by = my - (ty - my), bz = mz - (tz - mz), mx = mx, my = my, mz = mz, rx = rx, ry = ry, rz = rz, roll = roll }
end

-- returns pose corrections {pitch, yaw, x, y, z} for the gun, updating them a little every frame:
-- rotation makes the barrel cross the crosshair at the zero distance, translation (ADS) centres the sights
-- Grappling hook (v0.3.9; BP_GrapplingHook_01, gadget slot 6): held in the right hand it gets the same aim
-- correction as a gun, so its muzzle line (s_muzzle) crosses the crosshair. Measured: without it the barrel pointed
-- 14 deg off the view, and the game picks a grapple point within 2 m (GrapplePointSearchRadius) of where it points.
local HOOK_CLS = nil
local function hookInRightHand()
    if not S.grip[1] then return nil end
    local c = holding(1)
    local o = c and c:GetOwner()
    if not (o and o:IsValid()) then return nil end
    HOOK_CLS = (HOOK_CLS and HOOK_CLS:IsValid()) and HOOK_CLS or StaticFindObject("/Script/Angelscript.CLPGrapplingHook")
    if HOOK_CLS and HOOK_CLS:IsValid() and o:IsA(HOOK_CLS) then return o end
    return nil
end

-- corrections are kept per gun and per pose (hip / ads); v0.3.22 keeps both and blends them while the gun comes up,
-- and only learns each one while the hand is at that pose (before, the hip/ads switch at the halfway point made the
-- gun jump)
local CALIB_KEYS = { "pitch", "yaw", "roll", "x", "y", "z" }
local function calibOf(gun, mode)
    local key = gun:GetFName():ToString() .. "#" .. mode
    local c = S.calib[key]
    if not c then c = { pitch = 0, yaw = 0, roll = 0, x = 0, y = 0, z = 0, n = 0 }; S.calib[key] = c end
    return c
end

local function calibrate(gun, ads, prof)
    if type(ads) == "number" then ads = ads > 0.5 end
    local c = calibOf(gun, ads and "ads" or "hip")
    local g3 = gunGeometry(gun, prof)
    if not g3 then return c end
    local dx, dy, dz = g3.mx - g3.bx, g3.my - g3.by, g3.mz - g3.bz
    local pitchNow, yawNow = math.deg(math.atan(dz, dx)), math.deg(math.atan(dy, dx))
    local zero = ads and (cfg.ads_zero_distance or 2000) or (cfg.hip_zero_distance or 1000)
    local wantPitch = math.deg(math.atan(-g3.mz, zero - g3.mx))
    local wantYaw = math.deg(math.atan(-g3.my, zero - g3.mx))
    local g = cfg.aim_assist_gain or 0.2
    c.pitch = c.pitch - g * (pitchNow - wantPitch)
    c.yaw = c.yaw - g * (yawNow - wantYaw)
    if ads then
        if prof and cfg.ads_level ~= false then c.roll = c.roll + g * g3.roll end   -- sights upright
        c.x = c.x - g * (g3.rx - (prof and prof.relief or cfg.ads_sight_distance or 22))
        c.y = c.y - g * g3.ry
        c.z = c.z - g * (g3.rz - (cfg.ads_sight_height or 0))
        c.n = (c.n or 0) + 1
    end
    local lim = 60
    c.pitch = math.max(-lim, math.min(lim, c.pitch)); c.yaw = math.max(-lim, math.min(lim, c.yaw))
    c.roll = math.max(-30, math.min(30, c.roll or 0))
    return c, g3
end

-- first raise of a gun: start the ADS corrections from what the hip pose shows (the grip is rigid, so the sights move
-- with the hand), instead of from zero and drifting into place over the first half second
local function seedAds(gun, prof, r, a)
    local ca = calibOf(gun, "ads")
    if ca.seeded then return end
    ca.seeded = true
    local g3 = gunGeometry(gun, prof)
    if not g3 then return end
    local ch = calibOf(gun, "hip")
    ca.pitch = ch.pitch + (r.pitch or 0) - (a.pitch or 0)
    ca.yaw = ch.yaw + (r.yaw or 0) - (a.yaw or 0)
    ca.x = prof.relief - (g3.rx + (a.x - r.x))
    ca.y = -(g3.ry + (a.y - r.y))
    ca.z = (cfg.ads_sight_height or 0) - (g3.rz + (a.z - r.z))
end

local function supportPoint(gun)
    local m = gun.SkeletalMeshComponent
    local ok, e = pcall(function() return m:DoesSocketExist(FName("s_support")) end)
    if ok and e then return toCam(m:GetSocketLocation(FName("s_support"))) end
    return nil
end

-- Pump shotguns (v0.3.8; Sanbury 790: CLPPhysicalChamberInteractionPumpAction). After a shot the action stays open
-- (FirearmComponent.bSlideLocked) and the next pull of the trigger does nothing until the fore-end is pumped: grip it
-- (the s_support socket sits on the Handguard bone) and move it 10 cm (DistanceToTwoHandChamber) back along
-- ChamberAxis (0,-1,0: the mesh's -Y, toward you), then forward. The mod does that stroke by itself, aimed or at the
-- hip: the left hand goes to the fore-end, grips, pulls back 12 cm, pushes forward, and lets go again at the hip.
-- If the action is still open after the stroke, it presses the slide release (B), which also chambers a shell.
local PUMP_BACK, PUMP_T = 12, { reach = 0.6, back = 0.10, hold = 0.06, fwd = 0.10 }
local function isPump(gun)
    local ok, c = pcall(function() return gun.CLPPhysicalChamberInteractionPumpAction end)
    return ok and c and c.IsValid and c:IsValid()
end
local function pumpRelease()
    inject("IA_Button_B_R_Pressed", 1)
    after(0.05, function() inject("IA_Button_B_R_Pressed", 0) end)
end
-- returns the left hand's camera-space target while a pump stroke runs, else nil
local function pumpTick(gun, o, watching)
    local P = S.pump
    if not gun or not isPump(gun) or cfg.shotgun_auto_pump == false then S.pump = nil; return nil end
    local fa = gun.FirearmComponent
    local locked = fa.bSlideLocked == true
    if not P then
        -- start when the action is open with a shell to chamber (not mid-reload: the reload closes it itself)
        if not locked or S.reloading or S.shellLoad or busy() or o then S.pumpSeen = nil; return nil end
        local tubeLeft = 0
        pcall(function() tubeLeft = fa.AttachedMagazine.CurrentAmmo end)
        if tubeLeft <= 0 then return nil end
        S.pumpSeen = S.pumpSeen or now()
        if now() - S.pumpSeen < 0.12 then return nil end   -- let the recoil settle
        S.pumpSeen = nil
        if watching or S.carry then pumpRelease(); log("pump: hand busy, used the slide release"); return nil end
        P = { t0 = now(), phase = "reach", hadGrip = S.grip[0] and S.supporting }
        S.pump = P
    end
    local m = gun.SkeletalMeshComponent
    local sp = m:GetSocketLocation(FName("s_support"))
    local back = m:GetRightVector()   -- the mesh's +Y is the barrel's forward direction
    local k = 0
    local t = now() - P.t0
    if P.phase == "reach" then
        if not S.grip[0] then
            local hx, hy, hz = toCam(handLoc(0))
            local x, y, z = toCam(sp)
            -- (supportCheck: give the grip 0.3 s to take hold before the support hand's "closed on nothing" check;
            -- left stale, that check ran the next frame, and online, where the hold registers a moment later, it
            -- opened the hand and regripped on every pump: "support hand: missed the foregrip")
            if (hx - x) ^ 2 + (hy - y) ^ 2 + (hz - z) ^ 2 < 25 or t > PUMP_T.reach then setGrip(0, true); S.supporting = true; S.supportCheck = now() + 0.3 end
        elseif t > 0.05 then
            -- anchor the stroke to the gun body (the fore-end socket moves with the pump): controller and socket
            -- offsets from the mesh origin, taken now
            local ml = m:K2_GetComponentLocation()
            local mc = S.pawn.LeftInteractionComponent.MotionSource:K2_GetComponentLocation()
            P.mcOff = { X = mc.X - ml.X, Y = mc.Y - ml.Y, Z = mc.Z - ml.Z }
            P.spOff = { X = sp.X - ml.X, Y = sp.Y - ml.Y, Z = sp.Z - ml.Z }
            P.phase, P.t0, t = "stroke", now(), 0
        end
    end
    if P.phase == "stroke" then
        local a, h, f = S.pumpT and S.pumpT.back or PUMP_T.back, PUMP_T.hold, S.pumpT and S.pumpT.fwd or PUMP_T.fwd
        local B = S.pumpBack or PUMP_BACK
        if t < a then k = B * t / a
        elseif t < a + h then k = B
        elseif t < a + h + f then k = B * (1 - (t - a - h) / f)
        else
            S.pump = nil; S.pumpMC = nil
            S.supportCheck = now() + 0.3
            if fa.bSlideLocked == true then pumpRelease(); log("pump: the stroke didn't close it, used the slide release")
            elseif S.pumpDebug then log("pump: chambered") end
            return nil
        end
    end
    local w = { X = sp.X - back.X * k, Y = sp.Y - back.Y * k, Z = sp.Z - back.Z * k }
    if P.phase == "stroke" then
        -- the game holds the visible hand on the fore-end and the pump reads the controller: move the controller
        local ml = m:K2_GetComponentLocation()
        S.pumpMC = { X = ml.X + P.mcOff.X - back.X * k, Y = ml.Y + P.mcOff.Y - back.Y * k, Z = ml.Z + P.mcOff.Z - back.Z * k }
        w = { X = ml.X + P.spOff.X - back.X * k, Y = ml.Y + P.spOff.Y - back.Y * k, Z = ml.Z + P.spOff.Z - back.Z * k }
        if S.pumpDebug then
            local mc = S.pawn.LeftInteractionComponent.MotionSource:K2_GetComponentLocation()
            local d = -((mc.X - ml.X - P.mcOff.X) * back.X + (mc.Y - ml.Y - P.mcOff.Y) * back.Y + (mc.Z - ml.Z - P.mcOff.Z) * back.Z)
            log("pump dbg: t %.2f target %.1f mc %.1f locked %s held %s", t, k, -d, tostring(fa.bSlideLocked), tostring(holding(0) ~= nil))
        end
    end
    local x, y, z = toCam(w)
    return { x, y, z }
end

------------------------------------------------------------------------------------------------ watch hack
-- Hack spots (laptops, keycard readers, the drill call zone: CLPWatchHackVolumeBase) work when the watch is inside
-- the spot's sphere (40 cm for laptops and readers, 2 m for the drill call) and the other hand's index fingertip
-- touches the watch face (within ~1 cm). Tab + F, FPS style: both hands stay fixed to the view, the watch pushed out in
-- front of you with the right fingertip on its face. You aim with the camera and walk up; the game starts the hack
-- as soon as the watch is in the zone and pauses it if you look away. Hold Tab until it's done; letting go or F cancels.
-- Offsets measured in game, in each hand's own frame, so they still line up if the poses in config.lua are edited.
local WATCH_IN_HAND = { -2.29, 0.16, 6.65 }   -- watch_location socket from the left hand target
local MESH_IN_HAND = { -1.5, 3.4, 6.3 }       -- right hand mesh origin from the right hand target

local function inPose(pose, k)   -- hand-frame offset -> camera space, for that pose's rotation (FRotationMatrix axes)
    local p, y, r = math.rad(pose.pitch or 0), math.rad(pose.yaw or 0), math.rad(pose.roll or 0)
    local SP, CP, SY, CY, SR, CR = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
    local X = { CP * CY, CP * SY, SP }
    local Y = { SR * SP * CY - CR * SY, SR * SP * SY + CR * CY, -SR * CP }
    local Z = { -(CR * SP * CY + SR * SY), CY * SR - CR * SP * SY, CR * CP }
    return X[1] * k[1] + Y[1] * k[2] + Z[1] * k[3], X[2] * k[1] + Y[2] * k[2] + Z[2] * k[3], X[3] * k[1] + Y[3] * k[2] + Z[3] * k[3]
end

local function hackComponent()
    local c = S.pawn.WatchHackComponent
    if c and c:IsValid() then return c end
    c = FindFirstOf("CLPWatchHackComponent")
    return c and c:IsValid() and c or nil
end

-- the spot the game says we're at (it fills this in once we're near one)
local function currentSpot(c)
    local ok, v = pcall(function() return c.Data.HackVolume end)
    if ok and v and v:IsValid() then return v end
    return nil
end

-- nearest enabled spot within 3 m, only for the "didn't start" hint
local function nearestSpot()
    local cam, best, bestD = camera():K2_GetComponentLocation(), nil, 300
    for _, a in ipairs(FindAllOf("CLPWatchHackVolumeBase") or {}) do
        if a:IsValid() and prop(a, "bEnabled") ~= false then
            local d = dist(a:K2_GetActorLocation(), cam)
            if d < bestD then best, bestD = a, d end
        end
    end
    return best
end

local function spotDone(spot)
    return prop(spot, "bEnabled") == false or prop(spot, "bHackIsCompleted") == true or prop(spot, "bIsUnlocked") == true
        or prop(spot, "bDrillHasBeenCalled") == true
end

local function spotRadius(spot)
    local ok, r = pcall(function() return spot.CollisionComponent:GetScaledSphereRadius() end)
    return ok and r or 40
end

local function stopHack(msg)
    if S.hack then log("hack: %s", msg) end
    S.hack = nil
end

local function startHack()
    if S.hack then stopHack("cancelled"); return end
    if busy() then return end
    local c = hackComponent(); if not c then log("hack: no watch hack component"); return end
    S.hack = { c = c, t0 = now(), seen = {} }
    log("hack: watch out, aim at the hack spot")
end

-- every frame while Tab + F is on: camera-fixed hand targets, and watching the game's hack state
local function hackStep()
    local h = S.hack
    -- watch: the Tab pose pushed straight out (same spot on screen, further away), so it reaches what you look at
    local w = cfg.watch_hand
    local ox, oy, oz = inPose(w, WATCH_IN_HAND)
    local wx, wy, wz = w.x + ox, w.y + oy, w.z + oz
    local s = (cfg.hack_reach or 55) / math.sqrt(wx * wx + wy * wy + wz * wz)
    wx, wy, wz = wx * s, wy * s, wz * s
    h.left = { wx - ox, wy - oy, wz - oz }
    -- fingertip onto the watch face where the watch is right now, so the finger follows it. The tip comes from the
    -- finger bones (open hand, or curled on a gun's trigger), and is placed relative to the hand mesh, which sits at a
    -- fixed offset from the hand target
    local m = S.pawn.LeftInteractionComponent.HandPrimitive
    local fx, fy, fz = toCam(m:GetSocketLocation(FName("watch_location")))
    local rm = S.pawn.RightInteractionComponent.HandPrimitive
    local ax, ay, az = toCam(rm:GetSocketLocation(FName("index_02_r")))
    local bx, by, bz = toCam(rm:GetSocketLocation(FName("index_03_r")))
    local tx, ty, tz = bx + (bx - ax) * 0.9, by + (by - ay) * 0.9, bz + (bz - az) * 0.9
    local cx2, cy2, cz2 = toCam(rm:K2_GetComponentLocation())
    local mx, my, mz = inPose(cfg.right_hand, MESH_IN_HAND)
    h.right = { fx - (tx - cx2) - mx, fy - (ty - cy2) - my, fz - (tz - cz2) - mz }
    h.leftKey = "hack"
    -- (v0.3.29) once the hack runs, the left hand holds the watch where it is in the world (on the spot), and the right
    -- hand goes back to normal: aim, shoot, look around. While the game pauses the hack, the fingertip comes back to the
    -- watch where it's held. Out of reach (walked off, turned away) the watch comes back in front of you.
    if h.anchor then
        local ax, ay, az = toCam(h.anchor)
        local reach = cfg.hack_hold_reach or 75
        if ax < 15 or ax * ax + ay * ay + az * az > reach * reach then
            h.anchor = nil
            log("hack: the watch is out of reach of the spot, back in front of you")
        else
            h.left, h.leftKey = { ax - ox, ay - oy, az - oz }, "hackhold"
            if h.hacking then h.right = nil end
        end
    end

    local t = now()
    -- remember each spot we meet and whether it was already done; one finishing ends the macro (the game clears its
    -- current spot when a hack completes, so check every spot seen during this press)
    local spot = currentSpot(h.c)
    if spot then
        local key = spot:GetFName():ToString()
        if not h.seen[key] then h.seen[key] = { obj = spot, wasDone = spotDone(spot) } end
    end
    for key, e in pairs(h.seen) do
        if not e.wasDone and e.obj:IsValid() and spotDone(e.obj) then
            h.doneAt = h.doneAt or t
            if t - h.doneAt > 0.4 then stopHack(string.format("%s done (%.1f s)", key, t - h.t0)) end
            return
        end
    end
    local okD, hacking = pcall(function() return h.c.Data.bIsCurrentlyHacking end)
    if okD and hacking and not h.hacking then
        if cfg.hack_hold ~= false and not h.anchor then
            local ok, wl = pcall(function() return m:GetSocketLocation(FName("watch_location")) end)
            if ok and wl then h.anchor = { X = wl.X, Y = wl.Y, Z = wl.Z } end
        end
        log(h.anchor and "hack: started (the watch stays on the spot, the right hand is free)" or "hack: started")
    end
    if okD and not hacking and h.hacking then log("hack: paused (keep the watch on the spot)") end
    h.hacking = okD and hacking
    if not h.hacking and not h.hinted and t - h.t0 > 3 then
        h.hinted = true
        local near = spot or nearestSpot()
        if near then
            local cx, cy, cz = toCam(near:K2_GetActorLocation())
            log("hack: not in the zone yet: the watch is %.0f cm from %s (needs < %.0f); walk up and aim at it",
                math.sqrt((cx - wx) ^ 2 + (cy - wy) ^ 2 + (cz - wz) ^ 2), near:GetFName():ToString(), spotRadius(near))
        else
            log("hack: no hack spot within 3 m")
        end
    end
end

------------------------------------------------------------------------------------------------ keypad poke
-- Keypads (CLPKeypad: door codes; CLPDrillControll: the drill's press-in-order panel) register a key when the index
-- fingertip pushes into it. F with the crosshair on a key: line the right fingertip up 6 cm in front of it, press
-- 1.5 cm in, pull back. The fingertip comes from the finger bones, so the forced pointing pose near keypads (or a gun
-- in hand) doesn't throw it off.
local KEY_NAMES = { "Key0", "Key1", "Key2", "Key3", "Key4", "Key5", "Key6", "Key7", "Key8", "Key9", "KeyOk", "KeyReset" }

-- Everything pressed with the fingertip: keypad keys, the drill's control panel, and buttons (ACLPButton: door,
-- elevator, wall, PC and cannon buttons in the full game; `FingerTipDistanceToButtonToConsiderItPressed` 0.6 cm).
-- `ang` = how far off the crosshair (degrees) it can be, `depth` = how far past the component origin the fingertip goes.
local POKEABLE = {
    { cls = "CLPKeypad", comps = KEY_NAMES, ang = 6, depth = 1.5 },
    { cls = "CLPDrillControll", comps = KEY_NAMES, ang = 6, depth = 1.5 },
    { cls = "CLPButton", comps = { "ButtonMesh" }, ang = 12, depth = 1.5, enabled = "bEnabled" },
}

local function keyUnderCrosshair()
    local cam = camera():K2_GetComponentLocation()
    local best, bestA = nil, math.rad(20)
    for _, kind in ipairs(POKEABLE) do
        for _, pad in ipairs(FindAllOf(kind.cls) or {}) do
            if pad:IsValid() and dist(pad:K2_GetActorLocation(), cam) < 250
                and not (kind.enabled and prop(pad, kind.enabled) == false) then
                for _, n in ipairs(kind.comps) do
                    local ok, x, y, z = pcall(function()
                        local c = pad[n]
                        if not (c and c:IsValid()) then return nil end
                        return toCam(c:K2_GetComponentLocation())
                    end)
                    if ok and x and x > 0 then
                        local d, ang = math.sqrt(x * x + y * y + z * z), math.atan(math.sqrt(y * y + z * z), x)
                        if d < (cfg.poke_reach or 100) and ang < math.rad(kind.ang) and ang < bestA then
                            best, bestA = { pad = pad, name = n, depth = kind.depth }, ang
                        end
                    end
                end
            end
        end
    end
    return best
end

local function startPoke(k)
    if busy() or S.poke then return end
    S.poke = { pad = k.pad, name = k.name, depth = k.depth, t0 = now() }
end

-- every frame while poking: right hand placed so the fingertip is `depth` cm along the eye-to-key line (- = in front)
local function pokeStep()
    local pk = S.poke
    local c = pk.pad:IsValid() and pk.pad[pk.name]
    if not (c and c:IsValid()) then S.poke = nil; return end
    local t = now() - pk.t0
    local depth = -6
    if pk.pressAt and t >= pk.pressAt and t < pk.pressAt + 0.2 then depth = pk.depth or 1.5 end
    local w, cam = c:K2_GetComponentLocation(), camera():K2_GetComponentLocation()
    local dx, dy, dz = w.X - cam.X, w.Y - cam.Y, w.Z - cam.Z
    local n = math.sqrt(dx * dx + dy * dy + dz * dz)
    local px, py, pz = toCam({ X = w.X + dx / n * depth, Y = w.Y + dy / n * depth, Z = w.Z + dz / n * depth })
    local rm = S.pawn.RightInteractionComponent.HandPrimitive
    local ax, ay, az = toCam(rm:GetSocketLocation(FName("index_02_r")))
    local bx, by, bz = toCam(rm:GetSocketLocation(FName("index_03_r")))
    local tx, ty, tz = bx + (bx - ax) * 0.9, by + (by - ay) * 0.9, bz + (bz - az) * 0.9
    local cx, cy, cz = toCam(rm:K2_GetComponentLocation())
    local mx, my, mz = inPose(cfg.right_hand, MESH_IN_HAND)
    pk.right = { px - (tx - cx) - mx, py - (ty - cy) - my, pz - (tz - cz) - mz }
    -- press once the fingertip has arrived in front of the key (or after a second regardless)
    if not pk.pressAt and (math.sqrt((tx - px) ^ 2 + (ty - py) ^ 2 + (tz - pz) ^ 2) < 1.5 or t > 1.0) then pk.pressAt = t + 0.05 end
    if pk.pressAt and t > pk.pressAt + 0.45 then S.poke = nil; log("poke %s", pk.name) end
end

------------------------------------------------------------------------------------------------ UI pointer
-- Menus are clicked with the right hand's laser: BPC_RayPointer's WidgetInteractionComponent, attached to the right motion
-- controller at a fixed angle (-80, -30 deg), so it points wherever the resting hand points (up past everything).
-- Instead the mod puts the laser at the eye and aims it through the crosshair, so world screens (planning table, loadout,
-- progression) work by looking at them and clicking (LMB is the game's own laser click). The pause menu (Esc; the game's Q) is placed in
-- front of the head and follows it (measured: it moved 88 cm after a 30-degree turn at 1.7 m), so while it's open the
-- mouse doesn't turn the view: it moves a cursor (the crosshair dot) and the laser goes through the cursor.
local function rayPointer()
    local wi = S.rayWI
    if wi and wi:IsValid() then return wi end
    for _, rp in ipairs(FindAllOf("CLPRayPointerComponent") or {}) do
        if rp:IsValid() and rp:GetOwner() == S.pawn then
            local ok, c = pcall(function() return rp.WidgetInteractionComponent end)
            if ok and c and c:IsValid() then S.rayWI = c; return c end
        end
    end
    return nil
end

local function pauseMenuOpen()
    local t = now()
    if (S.menuCheck or 0) > t then return S.menuOpen end
    S.menuCheck = t + 0.1
    local m = FindFirstOf("CLPPauseMenuActor")
    S.menuOpen = m ~= nil and m:IsValid() and m.bHidden == false
    return S.menuOpen
end

-- crosshair dot at the cursor (degrees right / up of the view centre)
local function placeCrosshair(cx, cy)
    local c = S.crosshair
    if not (c and c:IsValid()) then return end
    c:K2_SetRelativeLocation({ X = 100.0, Y = math.tan(math.rad(cx)) * 100, Z = math.tan(math.rad(cy)) * 100 }, false, {}, true)
end

-- every frame, after the motion controllers are placed: laser from the eye through the crosshair / cursor
local function aimUIPointer(menu)
    if cfg.ui_pointer == false then return end
    -- only with the right hand free; a held gun or a macro keeps the game's own laser
    if not menu and (S.grip[1] or S.override[1] or S.hack or S.poke) then return end
    local wi = rayPointer(); if not wi then return end
    local cam = camera()
    KMATH = KMATH or StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local rot = cam:K2_GetComponentRotation()
    if menu then
        -- cursor offset: yaw right, pitch up, in the camera's frame
        rot = KMATH:ComposeRotators({ Pitch = S.cursor.y, Yaw = S.cursor.x, Roll = 0 }, rot)
    end
    local o = cam:K2_GetComponentLocation()
    wi:K2_SetWorldLocationAndRotation({ X = o.X, Y = o.Y, Z = o.Z - 2 }, rot, false, {}, true)
end

------------------------------------------------------------------------------------------------ ping
-- Ping: the game's own marker. BPC_PingMarker (CLPPingMarkerComponent) sits on the character; in VR you hold A, aim the
-- hand's laser and let go. The mod drops it itself where the crosshair is: ServerOnPingMarkerDropped(location, actor).
-- The game picks the icon from the actor's CLPPingMarkerTargetComponent (enemy, loot, camera, first aid, ammo...),
-- follows moving targets and hides the marker after 7 s (HideMarkerAfterSeconds). Offline the rep-notify that shows the
-- marker never runs (it's for clients), so the mod calls OnRep_PingMarkerDrop itself: without it the marker moved but
-- stayed invisible.
local PING_TYPES = { [0] = "default", "enemy", "danger", "attention", "loot", "security", "first aid", "ammo", "heister" }

local function pingPick()
    local cam = camera()
    local o, f = cam:K2_GetComponentLocation(), cam:GetForwardVector()
    local reach = cfg.ping_reach or 5000
    local ignore = viewIgnore()
    local function trace(e)
        local hit = {}
        local ok, r = pcall(function()
            return ksl():LineTraceSingle(S.pawn, o, e, 0, false, ignore, 0, hit, true, { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
        end)
        if not (ok and r and hit.Location) then return nil end
        -- (hit.HitObjectHandle.Actor isn't readable from Lua on this build; the component's owner is)
        local okA, a = pcall(function() return hit.Component:Get():GetOwner() end)
        return { loc = { X = hit.Location.X, Y = hit.Location.Y, Z = hit.Location.Z }, dist = hit.Distance,
                 actor = (okA and a and a:IsValid()) and a or nil }
    end
    local hit = trace({ X = o.X + f.X * reach, Y = o.Y + f.Y * reach, Z = o.Z + f.Z * reach })
    -- something pingable (enemy, loot, camera...) within ping_angle of the crosshair and in sight beats the surface
    -- under the crosshair, so a running guard doesn't need a pixel-perfect click
    local me = S.pawn:GetFullName()
    local best, bestCos, bestD, bestL = nil, math.cos(math.rad(cfg.ping_angle or 3)), 0, nil
    for _, c in ipairs(FindAllOf("CLPPingMarkerTargetComponent") or {}) do
        local a = c:IsValid() and c:GetOwner()
        if a and a:IsValid() then
            local par = a:GetAttachParentActor()
            if not (par and par:IsValid()) and a:GetFullName() ~= me then
                local l = a:K2_GetActorLocation()
                local dx, dy, dz = l.X - o.X, l.Y - o.Y, l.Z - o.Z
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if d > 50 and d < reach then
                    local cs = (dx * f.X + dy * f.Y + dz * f.Z) / d
                    if cs > bestCos then best, bestCos, bestD, bestL = a, cs, d, l end
                end
            end
        end
    end
    if best then
        local name = best:GetFullName()
        if hit and hit.actor and hit.actor:GetFullName() == name then return best, hit.loc, hit.dist end
        local t = trace(bestL)
        if not t or t.dist >= bestD - 60 or (t.actor and t.actor:GetFullName() == name) then return best, bestL, bestD end
    end
    if hit and hit.actor then return hit.actor, hit.loc, hit.dist end
    return nil
end

local function ping()
    local c = S.pawn.PingMarkerComponent
    if not (c and c:IsValid()) then log("ping: this character has no ping marker"); return end
    local a, loc, d = pingPick()
    if not a then log("ping: nothing under the crosshair (within %.0f m)", (cfg.ping_reach or 5000) / 100); return end
    -- never pass nil for the actor: a nil object argument to a script function crashed the game before
    c:ServerOnPingMarkerDropped(loc, a)
    -- offline / hosting the rep-notify doesn't run for our own change, so show it ourselves; online the server's update
    -- arrives and runs it (calling it now would show the marker where the last ping was)
    if not online(localPC()) then pcall(function() c:OnRep_PingMarkerDrop() end) end
    local okT, ty = pcall(function() return c.PingMarkerDrop.PingMarkerHitType end)
    log("ping: %s, %.1f m (%s)", a:GetFName():ToString(), (d or 0) / 100, okT and PING_TYPES[ty] or "?")
end

------------------------------------------------------------------------------------------------ per-frame
local function pressed(name)
    local pc = localPC(); if not pc then return false end
    local d = pc:IsInputKeyDown(key(name))
    local was = S.keysDown[name]
    S.keysDown[name] = d
    return d and not was
end
local function held(name)
    local pc = localPC(); return pc and pc:IsInputKeyDown(key(name)) or false
end

-- The game's own keyboard key for the pause menu is Q (IMC_PauseMenu: Q -> IA_OpenMenu). keys.menu moves it (default
-- Escape) by editing that loaded mapping context, then has Enhanced Input rebuild its key map. Checked every 2 s, so it
-- also holds after the asset gets reloaded.
local function remapMenuKey()
    local want = cfg.keys and cfg.keys.menu
    if not want or want == "" then return end
    local t = now()
    if (S.menuKeyCheck or 0) > t then return end
    S.menuKeyCheck = t + 2
    local imc = StaticFindObject("/Game/Game/Input/InputMappingContexts/IMC_PauseMenu.IMC_PauseMenu")
    if not imc or not imc:IsValid() then return end
    local changed = 0
    imc.Mappings:ForEach(function(_, e)
        local m = e:get()
        local okA, a = pcall(function() return m.Action:GetFName():ToString() end)
        local k = m.Key.KeyName:ToString()
        if okA and a == "IA_OpenMenu" and k ~= want and (k == "Q" or k == S.menuKeyIs) then
            m.Key.KeyName = FName(want)
            changed = changed + 1
        end
    end)
    S.menuKeyIs = want
    if changed > 0 then
        if not inputSub or not inputSub:IsValid() then inputSub = FindFirstOf("EnhancedInputLocalPlayerSubsystem") end
        if inputSub then
            inputSub:RequestRebuildControlMappings({ bIgnoreAllPressedKeysUntilRelease = false, bForceImmediately = true,
                bNotifyUserSettings = false }, 1)
        end
        log("pause menu key -> %s", want)
    end
end

------------------------------------------------------------------------------------------------ mouse sensitivity slider
-- (v0.3.31) The game's own settings menu (Esc > Settings > Comfort) has a "Smooth turning speed" slider for VR stick
-- turning, which flat mode doesn't use (the arrow keys snap-turn). Its value lives on the game's user settings object
-- (CLPGameUserSettings.SmoothTurningSpeed, saved by the game in GameUserSettings.ini; default 3). The mod reads it as a
-- multiplier on mouse_sensitivity: at the game's default nothing changes, twice the value turns twice as fast. While the
-- settings menu is open the row's label is renamed "Mouse Sensitivity" (and shown even in snap-turn mode).
local sensCache = { t = -1, v = 1 }
local function userSettings()
    for _, o in ipairs(FindAllOf("CLPGameUserSettings") or {}) do
        if o:IsValid() and not o:GetFName():ToString():find("^Default__") then return o end
    end
    return nil
end
local function gameSensitivity()
    if cfg.sensitivity_slider == false then return 1 end
    local t = now()
    if t < sensCache.t then return sensCache.v end
    sensCache.t = t + 0.5
    local ok, v = pcall(function() return userSettings().SmoothTurningSpeed end)
    local ref = cfg.sensitivity_slider_default or 3
    if ok and type(v) == "number" and v > 0 and ref > 0 then
        local m = math.max(0.05, math.min(20, v / ref))
        if math.abs(m - sensCache.v) > 1e-4 then
            if sensCache.seen then log("mouse sensitivity: %.2fx (settings slider %.2f)", m, v) end
            sensCache.v = m
        end
        sensCache.seen = true
    end
    return sensCache.v
end
-- rename the slider's label in the open settings menu (and make sure its row shows); once per menu widget
local function relabelSensitivity()
    -- (the pause menu and its settings tabs are built at start and stay hidden, so this works with the menu closed)
    if cfg.sensitivity_slider == false then return end
    local t = now()
    if t < (S.sensLabelT or 0) then return end
    S.sensLabelT = t + 2
    local comfort = nil
    for _, w in ipairs(FindAllOf("CLPSettingsComfortWidget") or {}) do
        -- the live one sits under the game instance (/Engine/Transient...); the first one listed is the widget class's template
        if w:IsValid() and w:GetFullName():find("/Engine/Transient", 1, true) then comfort = w; break end
    end
    if not comfort then return end
    local key = comfort:GetFullName()
    local path = (key:match("^%S+%s+(.+)$") or key) .. "."   -- object path (no class prefix); its TextBlocks live under it
    if S.sensLabelDone == key then return end
    -- the row may be hidden while the turning mode is Snap: show it (ESlateVisibility 1 Collapsed / 2 Hidden -> 4 SelfHitTestInvisible)
    pcall(function()
        local row = comfort.WBP_SDFPanel_Turning_SmoothSpeed
        local v = row:GetVisibility()
        if v == 1 or v == 2 then row:SetVisibility(4); log("settings: showing the slider row (it was hidden in snap-turn mode)") end
    end)
    local n = 0
    for _, tb in ipairs(FindAllOf("TextBlock") or {}) do
        if tb:IsValid() then
            local okN, full = pcall(function() return tb:GetFullName() end)
            if okN and full:find(path, 1, true) then
                local okT, s = pcall(function() return tb:GetText():ToString() end)
                local low = okT and s and s:lower() or ""
                if low:find("turn") and (low:find("speed") or low:find("smooth turning")) and not low:find("^smooth$") then
                    pcall(function() tb:SetText(FText(cfg.sensitivity_label or "Mouse Sensitivity")) end)
                    n = n + 1
                    log("settings: renamed \"%s\" to \"%s\" (Comfort tab)", s, cfg.sensitivity_label or "Mouse Sensitivity")
                end
            end
        end
    end
    if n > 0 then S.sensLabelDone = key
    elseif not S.sensLabelWarned then S.sensLabelWarned = true; log("settings: didn't find the smooth turning speed label to rename yet (the slider still sets the mouse sensitivity)") end
end

local function tick()
    local pc = localPC(); if not pc then return end
    local p = pc.Pawn
    if not p or not p:IsValid() then return end
    local cls = p:GetClass():GetFName():ToString()

    -- global keys work everywhere
    local k = cfg.keys
    local okM, errM = pcall(remapMenuKey)
    if not okM and not S.menuKeyWarned then S.menuKeyWarned = true; log("menu key: %s", tostring(errM)) end

    -- intro (startup map): the skip key goes to the safehouse
    if cls == "BP_StartupPawn_C" then
        if k.skip_intro and k.skip_intro ~= "" and pressed(k.skip_intro) and not S.introSkipped then
            S.introSkipped = true
            console("GoToLobby")
        end
        return
    end
    S.introSkipped = nil
    if cls ~= "BP_PlayerCharacter_C" then return end
    local isOnline = online(pc)
    if isOnline and not cfg.allow_online then
        if not S.warnedOnline then S.warnedOnline = true; log("online session detected: mod paused (allow_online = false)") end
        return
    end
    if isOnline ~= S.wasOnline then
        S.wasOnline = isOnline
        if isOnline then log("online session (a client of the server): mod active, allow_online = true") end
    end
    S.warnedOnline = false
    if S.pawn ~= p then setupPawn(p) end
    local okH, errH = pcall(applyHudScale)
    if not okH and not S.hudWarned then S.hudWarned = true; log("hud scale: %s", tostring(errH)) end

    -- mouse look
    local dx = pc:GetInputAnalogKeyState(key("MouseX")) or 0
    local dy = pc:GetInputAnalogKeyState(key("MouseY")) or 0
    -- yaw through the controller: MQCharacter:RotateCharacter (the VR turn function) silently drops small per-frame
    -- amounts (0.3 deg/frame -> nothing), which felt like a deadzone on the X axis
    if S.lever then
        -- holding a lever: the mouse moves the lever, not the view
        local lv = S.lever
        -- mouse right or forward pulls the lever (the drill screen line moves right). Sensitivity is per 60 degrees of
        -- travel, so a 180-degree lever (one-shot, puzzle) takes the same mouse movement end to end as the drill's
        -- drill_invert (default on, the user's request): on the drill's lever, mouse left / back pulls instead
        local sgn = (lv.drill and cfg.drill_invert ~= false) and -1 or 1
        lv.angle = math.max(0, math.min(lv.max, lv.angle + sgn * (dx + dy) * (cfg.lever_sensitivity or 0.15) * lv.max / 60))
        -- Finish the pull (v0.3.6). Black Market's BP_Lever_01 (rest 60, activates at 100, end 110), measured frame by
        -- frame: the game lets go of the hand the moment the lever passes its activation angle, and the lever only stays
        -- activated if by then it has snapped to its end and the hand catches it there. A mouse drag crosses 100 slowly:
        -- activated at ~101, dropped, back to 60 the next frame (the user's 60 grabs without a result). What works: from
        -- just short of the activation angle, step the hand straight to the end in one frame (96 -> 110: the lever
        -- snaps to 110), keep gripping a moment so the game catches the activated lever, then let go (below).
        if not lv.drill and lv.act and lv.act < lv.max and not lv.wasActive and not lv.finishing and lv.angle >= lv.act - 4 then
            lv.finishing = true
            lv.ramp = nil
            -- not past act + 10 in one frame: the Bunker's one-shot levers (activate 120, end 180) read 0 after a
            -- 116 -> 180 step (the hand ends up too far round the pivot), every time
            lv.angle = math.min(lv.max, lv.act + (S.leverStep or 10))
        end
        if lv.ramp then   -- the finishing pull, or dev: "flatmode lever <deg>@<deg/s>"
            local step = lv.ramp.speed * math.min(0.1, now() - (lv.rampT or now())); lv.rampT = now()
            if math.abs(lv.ramp.to - lv.angle) <= step then lv.angle = lv.ramp.to; lv.ramp = nil; lv.rampT = nil
            else lv.angle = lv.angle + (lv.ramp.to > lv.angle and step or -step) end
        end
        local assist = lv.drill and cfg.drill_assist and drillPeak(lv)
        if assist then lv.angle = assist * lv.max end
        -- the lever stops following the hand when it activates (it snaps to its end: a drill starts drilling, a one-shot
        -- lever stays down) and when the game resets it (a drilling stage ended, a puzzle was reset); notice and let go
        local game = leverAngle(lv.l)
        local active = prop(lv.l, "bLeverActivated") == true
        if S.leverDebug then
            local h = holding(1)
            log("lever dbg: hand %.1f game %.1f active %s held %s drill %s mouse %.1f,%.1f", lv.angle, game, tostring(active), tostring(h ~= nil), tostring(lv.drill), dx, dy)
        end
        if not active then lv.wasActive = false; lv.activatedAt = nil end   -- grabbed while activated: only a new activation counts
        if lv.finishing and not active and game < lv.act - 10 then
            -- the pull was finished but the lever sprang back (a one-frame race inside the game's lever script: about
            -- half of identical pulls stay activated, measured on all five Black Market levers). Grab it again and pull
            -- it through by itself, a few times, so one F + drag does it.
            local l, pulls = lv.l, lv.pulls or 1
            local most = cfg.lever_retries or 4
            if pulls < most then
                releaseLever(string.format("sprang back, pulling it again (%d/%d)", pulls + 1, most))
                after(0.35, function() if l:IsValid() then grabLever(l, 1, pulls + 1) end end)
            else
                releaseLever("sprang back every time: grab it again (F)")
            end
            lv = nil
        end
        if lv and not lv.drill and active and not lv.wasActive then
            -- activated: keep the grip 0.6 s (the game catches the activated lever at its end; let go at once and it
            -- sprang back even at 110), then let go
            lv.activatedAt = lv.activatedAt or now()
            if now() - lv.activatedAt > (S.leverHold or 0.6) then releaseLever("activated"); lv = nil end
        end
        if lv and not lv.activatedAt and math.abs(game - lv.angle) > 12 then
            lv.offSince = lv.offSince or now()
            if now() - lv.offSince > 1.0 then
                if lv.drill then
                    releaseLever(game >= lv.max - 1 and "calibrated, the drill is running (grab the lever again when it stops)"
                        or "the drill reset the lever: grab it again (F) to recalibrate")
                else
                    releaseLever(prop(lv.l, "bLeverActivated") and "activated" or "the lever sprang back (not activated): grab it again (F)")
                end
            end
        elseif lv then
            lv.offSince = nil
        end
        if lv and not lv.l:IsValid() then releaseLever("lever gone") end
        dx, dy = 0, 0
    end
    if S.rotary then
        -- holding a switch / knob / dial / wheel: mouse X turns it (right = clockwise), the view stays still
        -- The mouse wheel turns a dial one number per notch (down = clockwise). The controller follows at a limited
        -- speed (turn_speed), so a fast flick can't skip numbers.
        local r = S.rotary
        local st = r.kind.step
        local dt = math.min(0.1, now() - (r.lastT or now())); r.lastT = now()
        dt = math.max(dt, 1 / 120)
        if st then
            -- Safe dials (12 numbers, 30 degrees each): the game's reading (FinalRotationDegrees) follows the wrist
            -- twist roughly 2:1 but not linearly (coarse steps looked uneven), and turning past the code's
            -- number resets the lock. So a wheel notch asks for the next number and the mod turns slowly until the
            -- game's reading gets there, then holds. Down / mouse right = R (the reading goes negative), up = L.
            -- Measured slowly: one number per ~12.2 degrees of twist. The number at the pointer is (reading/30) mod 12,
            -- so R counts down from 0 (11, 10, ...) and L counts up. Verified: safehouse safe R6 L4 R7 = R 6 numbers,
            -- L 10, R 9 -> bDone, the safe opened.
            local reading = prop(r.a, "FinalRotationDegrees") or 0
            if S.dialDebug and reading ~= r.dbgReading then r.dbgReading = reading; log("dial dbg: twist %.1f -> reading %.0f", r.angle, reading) end
            local notch = (pc:WasInputKeyJustPressed(key("MouseScrollDown")) and 1 or 0) - (pc:WasInputKeyJustPressed(key("MouseScrollUp")) and 1 or 0)
            r.acc = (r.acc or 0) + dx * (cfg.turn_sensitivity or 0.5)   -- mouse X: one number per `st` degrees of movement
            while r.acc >= st do r.acc = r.acc - st; notch = notch + 1 end
            while r.acc <= -st do r.acc = r.acc + st; notch = notch - 1 end
            if notch ~= 0 then r.want = (r.want or reading) - notch * st end
            if r.want and reading ~= r.want then
                -- R (reading going down) = negative twist; slow enough to stop on the number
                r.dir = r.want < reading and -1 or 1
                r.angle = r.angle + r.dir * (cfg.dial_speed or 40) * dt
                r.target, r.settle = r.angle, now()
            elseif r.want and r.settle then
                -- just arrived: a little further into the number so it doesn't sit on the edge, then hold
                if now() - r.settle < 0.1 then
                    r.angle = r.angle + (r.dir or 0) * (cfg.dial_speed or 40) * dt * 0.5
                else
                    r.settle = nil
                    -- the number at the pointer is (reading / 30) mod 12: R counts down (0, 11, 10...), L counts up
                    log("dial: at %d (turned %s)", math.floor(reading / 30 + 0.5) % 12, (r.dir or -1) < 0 and "R" or "L")
                end
            end
        else
            -- twist knobs: the axis points into the knob, so + is clockwise; other controls' axis points at you
            -- drill_invert also flips the pocket drill's knob (CLPKnob is only on pocket drills): mouse left = clockwise
            local inv = (r.kind.cls == "CLPKnob" and cfg.drill_invert ~= false) and -1 or 1
            local sens = r.kind.drive and (cfg.valve_sensitivity or 2.0) or (cfg.turn_sensitivity or 0.5)
            r.target = r.target + inv * dx * sens * (r.kind.axis == "twist" and 1 or -1)
            if r.kind.drive then
                -- Valves / vault wheels (ACLPWheel; the red valves in the Bunker). The wheel only turns with the hand when
                -- the hand's measured angular velocity passes MinVelocityToEngage, and the character's velocity
                -- estimators read 0 for our moved controllers, so it never turned (measured: controller swung 150
                -- degrees round the rim, WorldTargetDegrees stayed 0). The mod sets the angle with the wheel's own
                -- ServerSetTargetRotationDegrees, the call the game's turning code makes; while held the wheel is owned
                -- by our character, so it also goes through from an online client. Mouse right / wheel down =
                -- clockwise; near a locking end it finishes the turn by itself.
                local w = r.a
                local mn, mx = prop(w, "MinRotationAngle") or -180, prop(w, "MaxRotationAngle") or 0
                local notch = (pc:WasInputKeyJustPressed(key("MouseScrollDown")) and 1 or 0) - (pc:WasInputKeyJustPressed(key("MouseScrollUp")) and 1 or 0)
                r.target = r.target - notch * (cfg.valve_notch or 45)
                -- keep the wanted angle inside the wheel's range, so the mouse doesn't wind up past a stop
                local function game(a) return r.base + r.s * a end
                local function ours(g) return (g - r.base) * r.s end
                local lo, hi = math.min(ours(mn), ours(mx)), math.max(ours(mn), ours(mx))
                r.target = math.max(lo, math.min(hi, r.target))
                local fin = cfg.valve_autofinish or 45
                if fin > 0 and not r.finishing then
                    local g = game(r.target)
                    if prop(w, "bLockAndTriggerOnMin") and g < r.sent and g - mn <= fin then r.finishing = mn
                    elseif prop(w, "bLockAndTriggerOnMax") and g > r.sent and mx - g <= fin then r.finishing = mx end
                    if r.finishing then log("turn: almost there, finishing the turn") end
                end
                if r.finishing then r.target = ours(r.finishing) end
                local maxStep = (cfg.valve_speed or 240) * dt
                r.angle = r.angle + math.max(-maxStep, math.min(maxStep, r.target - r.angle))
                local want = game(r.angle)
                if S.turnDebug and (dx ~= 0 or notch ~= 0 or math.abs(want - r.sent) >= 0.5) then
                    log("turn dbg: dx %.2f notch %d target %.1f angle %.1f want %.1f sent %.1f game %.1f", dx, notch, r.target, r.angle, want, r.sent, prop(w, "WorldTargetDegrees") or 0)
                end
                if math.abs(want - r.sent) >= 0.5 and now() - (r.sentT or 0) >= 0.03 then
                    local okS, errS = pcall(function() w:ServerSetTargetRotationDegrees(want) end)
                    if okS then r.sent, r.sentT = want, now()
                    elseif not r.warned then r.warned = true; log("turn: couldn't turn it (%s)", tostring(errS)) end
                end
            else
                local maxStep = (cfg.turn_speed or 180) * dt
                r.angle = r.angle + math.max(-maxStep, math.min(maxStep, r.target - r.angle))
            end
        end
        if not r.a:IsValid() then releaseRotary("gone")
        elseif not r.wasDone and rotaryDone(r) then releaseRotary("done")
        elseif now() - r.t0 > 0.5 and not holding(1) then
            -- the game ended the grab: a dial resets when turned past the code's number or let go of
            releaseRotary(st and "the dial reset (turned past the number?): grab it again (F)" or "the game let go of it")
        end
        dx, dy = 0, 0
    end
    -- ping (keys.ping, middle mouse): drop the game's ping marker where you look
    if k.ping and pressed(k.ping) and not (S.lever or S.rotary or pauseMenuOpen()) then
        local okP, errP = pcall(ping); if not okP then log("ping: %s", tostring(errP)) end
    end
    -- pause menu open: the mouse moves a cursor over it instead of turning the view (the menu follows the view)
    local menu = pauseMenuOpen()
    S.cursor = S.cursor or { x = 0, y = 0 }
    if menu then
        local ms = cfg.menu_sensitivity or 0.06
        S.cursor.x = math.max(-40, math.min(40, S.cursor.x + dx * ms))
        S.cursor.y = math.max(-30, math.min(30, S.cursor.y + dy * ms * (cfg.invert_y and -1 or 1)))
        placeCrosshair(S.cursor.x, S.cursor.y)
        dx, dy = 0, 0
    elseif S.cursor.x ~= 0 or S.cursor.y ~= 0 then
        S.cursor.x, S.cursor.y = 0, 0
        placeCrosshair(0, 0)
    end
    local sens = cfg.mouse_sensitivity * gameSensitivity()
    if dx ~= 0 then pc:AddYawInput(dx * sens) end
    if dy ~= 0 then
        S.pitch = S.pitch + dy * sens * (cfg.invert_y and -1 or 1)
        S.pitch = math.max(-cfg.max_pitch, math.min(cfg.max_pitch, S.pitch))
    end
    p.Camera:K2_SetRelativeRotation({ Pitch = S.pitch, Yaw = 0.0, Roll = 0.0 }, false, {}, true)

    -- keys
    if pressed(k.grab_right) then
        if S.lever then releaseLever()
        elseif S.rotary then releaseRotary()
        elseif S.hack or held(k.watch) or S.watchLock then startHack()
        else
            -- what's under the crosshair, nearest first in this order: lever, fingertip button/key, rotary control.
            -- A grip closed on nothing counts as an empty hand; a gun (or the syringe) is holstered first.
            local heldR = S.grip[1] and holding(1) or nil
            if S.grip[1] and not heldR and not busy() then setGrip(1, false) end
            local fromSlot = heldR and S.heldSlot ~= nil
            local free = not heldR or fromSlot
            local l = free and leverUnderCrosshair() or nil
            local key = (not l) and keyUnderCrosshair() or nil
            local rot = (not l and not key and free) and rotaryUnderCrosshair() or nil
            -- a gun in hand and loot / a bag / C4 under the crosshair: holster, then grab it (in the user's log F at loot
            -- with a gun out only said "holding a gun")
            local loot = (not l and not key and not rot and fromSlot) and grabTarget(1) or nil
            if (l or rot or loot) and fromSlot and not busy() then
                holsterRightThen(function()
                    if l then grabLever(l) elseif rot then grabRotary(rot) else toggleGrab(1) end
                end)
            elseif l then grabLever(l) elseif key then startPoke(key) elseif rot then grabRotary(rot) else toggleGrab(1) end
        end
    end
    if pressed(k.grab_left) then
        if S.supporting and not busy() then
            log("carry: letting go of the foregrip")
            -- the left hand is on the gun's foregrip: let go of it, then grab with the left hand (carry)
            setGrip(0, false); S.supporting = false; S.supportSince = nil
            after(0.15, function() toggleGrab(0) end)
        else
            toggleGrab(0)
        end
    end
    if k.throw and pressed(k.throw) then
        if S.carry then throwItem(0)
        elseif S.grip[1] and holdingA(1, GRENADE) then throwGrenade()
        elseif S.grip[1] and holdingA(1, THROWABLE) then throwItem(1) end
    end
    -- Online: guns still hidden after masking up (user report from a private online lobby, v0.3.15). Until the mask is
    -- on, the game hides the weapon slots (pistol, primary: bHidden). Masking up shows them through the loadout's
    -- script ShowHideLoudSlots, run by the mask's own equip; the mod puts the mask on with ServerEquipMask, which on a
    -- client only runs on the server, so the server knows you're masked but your own game never showed the guns.
    -- ShowHideLoudSlots is script-only (not callable from Lua), so: while masked (slot 15 filled) and not inside one
    -- of the game's hide-loadout areas, show any hidden weapon in its holster ourselves. Only as a client; offline
    -- (and hosting) the game does it.
    if (isOnline or S.onlineTest) and (S.gunShowCheck or 0) < now() then
        S.gunShowCheck = now() + 0.25
        local okG, errG = pcall(function()
            if not slotItem(15) then return end
            -- inside a hide-loadout area: leave them
            if inHideLoadoutArea() then return end
            for _, slot in ipairs({ 3, 4 }) do
                local g = slotItem(slot)
                if g and g.bHidden then
                    g:SetActorHiddenInGame(false)
                    if not S.gunShowLogged then S.gunShowLogged = true; log("online: masked, showed the holstered guns (the game didn't)") end
                end
            end
        end)
        if not okG and not S.gunShowWarned then S.gunShowWarned = true; log("online guns: %s", tostring(errG)) end
    end
    -- keep the carry state true to what the left hand really holds (twice a second, not during macros: the reload's
    -- magazine isn't a carry): the bag can leave the hand without us (into a chute, taken by the game), and after
    -- "flatmode reload" or a respawn the hand may still be holding one
    if not busy() and (S.carryCheck or 0) < now() then
        S.carryCheck = now() + 0.5
        local c = S.grip[0] and holding(0) or nil
        local o = c and c:GetOwner()
        local okF, fa = pcall(function() return o.FirearmComponent end)
        local isGun = okF and fa and fa.IsValid and fa:IsValid()
        if o and not isGun then
            if S.carry ~= o then S.carry = o end
        else
            S.carry = nil
        end
        -- a left grip closed on nothing outside a macro (and not the support grip, which checks itself): open it
        if S.grip[0] and not c and not S.supporting then setGrip(0, false); log("left hand: grip was closed on nothing, opened it") end
    end
    if pressed(k.draw_pistol) then toggleSlot(4, "pistol") end
    if pressed(k.draw_primary) then toggleSlot(3, "primary") end
    if pressed(k.syringe) then toggleSlot(2, "syringe") end
    if k.deployable and pressed(k.deployable) then toggleSlot(5, "deployable") end
    if k.gadget and pressed(k.gadget) then toggleSlot(6, "gadget") end
    if pressed("LeftMouseButton") then
        if S.shellLoad and not S.shellStop then S.shellStop = true; log("reload: stopping after this shell") end
        if S.syringe and S.heldSlot == 2 then syringeJab()
        elseif S.grip[1] and not S.lever and not S.rotary and holdingA(1, GRENADE) then throwGrenade()
        elseif S.grip[1] and not S.lever and not S.rotary and holdingA(1, THROWABLE) then throwItem() end
    end
    if pressed(k.mask) then maskOn() end
    if k.jammer and pressed(k.jammer) then fireJammer() end
    if pressed(k.reload) then if S.reloadDebug then log("R pressed: shellLoad %s busy %s reloading %s", tostring(S.shellLoad), tostring(busy()), tostring(S.reloading)) end; reload() end
    if pressed(k.dismiss) then
        local c = FindFirstOf("BPC_ModalTutorialWindowController_C")
        if c and c:IsValid() then pcall(function() c:OnSkipButtonPressed() end) end
    end

    -- a reload pressed while another hand action was finishing runs as soon as the hands are free (within 2 s)
    if S.reloadQueued then
        if now() > S.reloadQueued then S.reloadQueued = nil
        elseif not busy() then S.reloadQueued = nil; reload() end
    end

    -- macro queue
    local t = now()
    while #S.steps > 0 and S.steps[1].t <= t do
        local step = table.remove(S.steps, 1)
        local ok, err = pcall(step.fn); if not ok then log("step error: %s", tostring(err)) end
    end
    if S.hack and not (held(k.watch) or S.watchLock) then stopHack("cancelled (Tab released)") end
    if S.hack then
        local okK, errK = pcall(hackStep)
        if not okK then stopHack("error: " .. tostring(errK)) end
    end
    if S.poke then
        local okP, errP = pcall(pokeStep)
        if not okP then S.poke = nil; log("poke: %s", tostring(errP)) end
    end
    local hk = S.hack

    -- hand poses: right = aim/ADS blend unless a macro overrides; left = rest or watch
    local target = (held(k.aim) or S.adsLock) and 1 or 0
    local r, a = cfg.right_hand, cfg.ads_hand
    local o = S.override[1]
    local gun = (not o) and gunInRightHand() or nil
    -- the held gun's ADS profile (sight line, eye relief, raise time; see adsProfile)
    local prof = nil
    if gun and cfg.aim_assist ~= false then
        local okPr, pr = pcall(adsProfile, gun)
        if okPr then prof = pr elseif not S.adsWarned then S.adsWarned = true; log("ads profile: %s", tostring(pr)) end
    end
    -- ADS progress (v0.3.22): time-based, per gun (a pistol comes up faster than a shotgun), shaped as a minimum-jerk
    -- reach (smooth start, smooth stop, the curve human arm movements follow). Lowering takes ads_out of the time.
    -- Before: 25 % of the remaining way per frame (frame-rate dependent, abrupt start).
    local tAim = now()
    local dtAim = math.max(0, math.min(0.1, tAim - (S.aimT or tAim)))
    S.aimT = tAim
    local T = math.max(0.05, (prof and prof.time) or cfg.ads_time or 0.25)
    if target == 1 then S.aimP = math.min(1, (S.aimP or 0) + dtAim / T)
    else S.aimP = math.max(0, (S.aimP or 0) - dtAim / (T * (cfg.ads_out or 0.8))) end
    local pAim = S.aimP
    S.aim = pAim * pAim * pAim * (10 + pAim * (6 * pAim - 15))
    if o and o.fn then
        local okW, w = pcall(o.fn)
        if okW and w then o.x, o.y, o.z = toCam(w) end
    elseif o and o.cfn then   -- a moving camera-space point (the grenade swing)
        local okC, cx, cy, cz = pcall(o.cfn)
        if okC and cx then o.x, o.y, o.z = cx, cy, cz end
    end
    -- (each source has a key for the hand smoother; an override's key is its own table)
    if hk and hk.right then smoothHand(1, "hack", hk.right[1], hk.right[2], hk.right[3], r.pitch, r.yaw or 0, r.roll or 0)
    elseif S.poke and S.poke.right then smoothHand(1, "poke", S.poke.right[1], S.poke.right[2], S.poke.right[3], r.pitch, r.yaw or 0, r.roll or 0)
    elseif o and not o.x then
        -- a follow target that returned nothing yet: leave the hand where it is (like the left hand below)
    elseif o then
        local off = o.off or { 0, 0, 0 }   -- e.g. syringe needle tip from the hand target
        smoothHand(1, o, o.x - off[1], o.y - off[2], o.z - off[3], r.pitch, r.yaw or 0, r.roll or 0, nil, o)
    else
        local m = S.aim
        -- aim assist learns from where the gun really is: not while the hand is still easing in from another pose
        -- (it would learn the blend's offset as aim error), nor on the frame it switches here
        local aimItem = gun or (not S.noHookAim and hookInRightHand()) or nil
        -- (v0.3.28) the pose with a gun in hand carries that gun's learned correction (up to ~11 deg off the empty
        -- hand's): its own source key, so taking hold of a gun (or letting go) eases instead of turning in one frame
        local aimKey = gun and "aim+gun" or aimItem and "aim+hook" or "aim"
        local bR = S.blend[1]
        local settled = bR.key == aimKey and not bR.active
        local function mix(k2, d) local v1, v2 = r[k2] or d, a[k2] or d; return v1 + (v2 - v1) * m end
        local c = { pitch = 0, yaw = 0, roll = 0, x = 0, y = 0, z = 0 }
        local tm = m          -- how much of c's translation applies
        local cant, push = 0, 0
        if aimItem and cfg.aim_assist ~= false and prof then
            -- learn the hip / ADS corrections only at those poses, blend them in between
            local okC, errC = pcall(function()
                if target == 1 and pAim < 0.05 and settled then seedAds(gun, prof, r, a) end
                if not settled then S.adsArrived = nil
                elseif m <= 0.001 then calibrate(gun, false, prof); S.adsArrived = nil
                elseif m >= 0.999 then
                    local ca0, g3 = calibrate(gun, true, prof)
                    if S.adsDebug and not S.adsArrived and g3 then
                        -- dev: how far the sights were from where they belong the moment the gun arrived
                        log("ads arrived (%s): sight off by x %.1f y %.1f z %.1f cm, roll %.1f, learned %d frames", prof.fam,
                            g3.rx - prof.relief, g3.ry, g3.rz - (cfg.ads_sight_height or 0), g3.roll, ca0.n or 0)
                    end
                    S.adsArrived = true
                else S.adsArrived = nil end
                local ch, ca = calibOf(gun, "hip"), calibOf(gun, "ads")
                for _, k2 in ipairs(CALIB_KEYS) do c[k2] = (ch[k2] or 0) + ((ca[k2] or 0) - (ch[k2] or 0)) * m end
            end)
            if not okC then
                if not S.adsCalWarned then S.adsCalWarned = true; log("ads: %s", tostring(errC)) end
                S.adsCache = {}
            end
            tm = 1
            -- on the way up and down: a little tilt and a push out, gone at both ends
            local bump = 4 * m * (1 - m)
            cant, push = (prof.cant or 0) * bump, (prof.push or 0) * bump
        elseif aimItem and cfg.aim_assist ~= false then
            -- the grappling hook: the pre-v0.3.22 behaviour
            c = settled and calibrate(aimItem, m) or calibOf(aimItem, m > 0.5 and "ads" or "hip")
        end
        smoothHand(1, aimKey, mix("x", 0) + c.x * tm + push, mix("y", 0) + c.y * tm, mix("z", 0) + c.z * tm,
            mix("pitch", 0) + c.pitch, mix("yaw", 0) + c.yaw, mix("roll", 0), cant + (c.roll or 0))
    end
    -- the crosshair dot hides while the sights are up (ads_crosshair = false), so the sight picture is what you aim with
    local hideX = cfg.ads_crosshair == false and prof ~= nil and S.aim > 0.6 and not menu
    if hideX ~= (S.xhHidden or false) and S.crosshair and S.crosshair:IsValid() then
        pcall(function() S.crosshair:SetVisibility(not hideX, false) end)
        S.xhHidden = hideX
    end
    local l = cfg.left_hand
    o = S.override[0]
    -- checking the watch takes the left hand off the foregrip; it grips again once Tab is released
    local watching = not o and (held(k.watch) or S.watchLock or hk ~= nil)
    -- the support hand: hip fire is one-handed; while aiming (right mouse) a free left hand takes the foregrip for steadier
    -- shots. A busy left hand (carrying a bag, the watch, a macro) leaves the gun one-handed in both styles.
    -- support_hand: "ads" (default; true means the same), "always" (the v0.3.2 behaviour), false (never)
    local sm = cfg.support_hand
    if sm == true or sm == nil then sm = "ads" end
    local wantSupport = sm == "always" or (sm == "ads" and target == 1)
    local sx, sy, sz = nil, nil, nil
    if wantSupport and not o and not watching and not S.carry and gun and not busy() then sx, sy, sz = supportPoint(gun) end
    -- pump shotguns: the left hand works the fore-end after each shot (hip or aimed); see pumpTick
    local okP, pumpPt = pcall(pumpTick, gun, o, watching)
    if not okP then if not S.pumpWarned then S.pumpWarned = true; log("pump: %s", tostring(pumpPt)) end; pumpPt = nil end
    if pumpPt then sx, sy, sz = pumpPt[1], pumpPt[2], pumpPt[3] end
    if o and o.fn then
        local okW, w = pcall(o.fn)
        if okW and w then o.x, o.y, o.z = toCam(w) end
    end
    if o and not o.x then o = nil end   -- a follow target that returned nothing yet (or ever): leave the hand where it is
    if o then smoothHand(0, o, o.x, o.y, o.z, l.pitch, 0, 0, nil, o)
    elseif watching and hk and hk.left then
        local w = cfg.watch_hand
        smoothHand(0, hk.leftKey or "hack", hk.left[1], hk.left[2], hk.left[3], w.pitch, w.yaw or 0, w.roll or 0)
    elseif watching then
        local wx, wy, wz, wp, wyaw, wr = poseOf(cfg.watch_hand)
        smoothHand(0, "watch", wx, wy, wz, wp, wyaw, wr)
    elseif S.carry then
        local cx, cy, cz, cp, cyaw, cr = poseOf(cfg.carry_hand or { x = 12, y = -34, z = -75, pitch = 70 })
        smoothHand(0, "carry", cx, cy, cz, cp, cyaw, cr)
    elseif sx then
        -- the pump stroke is written exactly (the game reads the controller, which the stroke moves itself)
        smoothHand(0, pumpPt and "pump" or "support", sx, sy, sz, l.pitch, 0, 0, nil,
            (pumpPt and S.pump and S.pump.phase == "stroke") and RAW or nil)
        if not S.grip[0] then
            -- grip once the hand has reached the foregrip (or after 0.8 s), so it doesn't close early on nothing
            S.supportSince = S.supportSince or now()
            local hx, hy, hz = toCam(handLoc(0))
            local near = (hx - sx) ^ 2 + (hy - sy) ^ 2 + (hz - sz) ^ 2 < 25
            if near or now() - S.supportSince > 0.8 then setGrip(0, true); S.supporting = true; S.supportCheck = now() + 0.3 end
        elseif not S.supporting then
            -- the left grip is closed but not by us (a macro that ended without opening it): the hand sat on the foregrip
            -- closed on nothing and never gripped again. Take it over; the check below opens it and regrips if it holds
            -- nothing. Something else in the hand (a bag) is a carry, not ours to drop.
            local c = holding(0)
            local okO, other = pcall(function() return c and c:GetOwner():GetFullName() ~= gun:GetFullName() end)
            if okO and other then S.carry = c:GetOwner()
            else S.supporting = true; S.supportCheck = now() end
        elseif now() > (S.supportCheck or 0) then
            -- a grip that closed on nothing (or slipped off) leaves the hand floating at the gun: open it and grip again
            S.supportCheck = now() + 0.3
            local c = holding(0)
            local okN, same = pcall(function() return c and c:GetOwner():GetFullName() == gun:GetFullName() end)
            if not (okN and same) then
                setGrip(0, false); S.supporting = false; S.supportSince = now()
                S.supportMisses = (S.supportMisses or 0) + 1
                if S.supportMisses <= 3 or S.supportMisses % 20 == 0 then log("support hand: missed the foregrip, gripping again") end
            else
                S.supportMisses = 0
            end
        end
    else
        local lx, ly, lz, lp, lyaw, lr = poseOf(l)
        smoothHand(0, "rest", lx, ly, lz, lp, lyaw, lr)
    end
    if not sx then
        S.supportSince = nil
        if S.supporting and not o then setGrip(0, false); S.supporting = false end
    end

    -- latched grips
    if S.grip[1] then inject("IA_Grip_R", 1) end
    if S.grip[0] then inject("IA_Grip_L", 1) end
    if S.trigger then inject("IA_Trigger_R", 1) end   -- held by macros (priming the syringe)
    -- The game maps LMB to the right trigger (IMC_Trigger_RH) only while a gun is held: with the grappling hook a click
    -- did nothing (measured: real click fired the pistol, not the hook). Forward it ourselves while the hook or a
    -- deployable (ammo / med bag, sentry gun, tripwire mine: the trigger places it) is held.
    local hookHeld = S.grip[1] and holdingA(1, TRIGGER_ITEMS) or false
    if S.lmbLog and now() < S.lmbLog then
        local st = string.format("hook %s lmb %s menu %s", tostring(hookHeld), tostring(held("LeftMouseButton")), tostring(S.menuOpen))
        if st ~= S.lmbLast then S.lmbLast = st; log("lmb dbg: %s", st) end
    end
    if hookHeld and held("LeftMouseButton") and not S.menuOpen then
        if not S.hookTrig then log("trigger: %s", holdingA(1, { "CLPGrapplingHook" }) and "grappling hook fire" or "deploy") end
        inject("IA_Trigger_R", 1); S.hookTrig = true
    elseif S.hookTrig then inject("IA_Trigger_R", 0); S.hookTrig = false end

    -- motion controllers follow the visible hands so grabbing happens where the hands are
    for _, side in ipairs({ "Left", "Right" }) do
        local ic = p[side .. "InteractionComponent"]
        if ic and ic:IsValid() then
            local hp, mc = ic.HandPrimitive, ic.MotionSource
            local lv = side == "Right" and S.lever or nil
            local rt = side == "Right" and S.rotary or nil
            if side == "Left" and S.pumpMC and S.pump and mc and mc:IsValid() then
                -- working a pump: the controller slides along the barrel (pumpTick)
                mc:K2_SetWorldLocation(S.pumpMC, false, {}, true)
            elseif rt and mc and mc:IsValid() then
                -- holding a rotary control: the controller turns about its axis (the game reads its pose)
                local loc, rot = rotaryPose(rt, rt.angle)
                mc:K2_SetWorldLocationAndRotation(loc, rot, false, {}, true)
            elseif lv and lv.mcOff and mc and mc:IsValid() then
                -- while gripping a lever the game snaps the visible hand onto the handle, and the lever turns with the
                -- controller; following the visible hand would make the lever chase itself, so swing the controller
                mc:K2_SetWorldLocation(leverPoint(lv, lv.mcOff, lv.angle - (lv.bias or 0)), false, {}, true)
            elseif hp and hp:IsValid() and mc and mc:IsValid() then
                mc:K2_SetWorldLocationAndRotation(hp:K2_GetComponentLocation(), hp:K2_GetComponentRotation(), false, {}, true)
            end
        end
    end
    local okL, errL = pcall(relabelSensitivity)
    if not okL and not S.sensWarned then S.sensWarned = true; log("settings label: %s", tostring(errL)) end
    local okU, errU = pcall(aimUIPointer, menu)
    if not okU and not S.uiWarned then S.uiWarned = true; log("ui pointer: %s", tostring(errU)) end
end


local M = { log = log, tick = tick }

function M.onClientRestart()
    if not cfg.skip_intro then return end
    local pc = localPC()
    if pc and pc.Pawn and pc.Pawn:IsValid() and pc.Pawn:GetClass():GetFName():ToString() == "BP_StartupPawn_C" then
        console("GoToLobby")
    end
end

local commands = {
    pistol = function() toggleSlot(4, "pistol") end,
    syringe = function() toggleSlot(2, "syringe") end,
    deployable = function() toggleSlot(5, "deployable") end,
    gadget = function() toggleSlot(6, "gadget") end,
    jab = function() syringeJab() end,
    poke = function() local key = keyUnderCrosshair(); if key then startPoke(key) else log("poke: no key under the crosshair") end end,
    lever = function(a)   -- grab/let go of the lever under the crosshair, or "lever <deg>" to set the held angle
        -- "lever <deg>" jumps there; "lever <deg>@<deg/s>" moves there at that speed, like a mouse would (dev)
        local to, sp = (a or ""):match("^([%d%.%-]+)@([%d%.]+)$")
        if to and S.lever then S.lever.ramp = { to = tonumber(to), speed = tonumber(sp) }; log("lever ramp -> %s at %s deg/s", to, sp); return end
        if a and S.lever then S.lever.angle = tonumber(a) or S.lever.angle; log("lever angle -> %s", a); return end
        if S.lever then releaseLever() else local l = leverUnderCrosshair(); if l then grabLever(l) else log("lever: none under the crosshair") end end
    end,
    primary = function() toggleSlot(3, "primary") end,
    -- dev: "reach x,y,z" puts the right hand at a camera-space point, "reach w:x,y,z" at a world point, "reach" = home
    reach = function(a)
        if not a then handHome(1); log("reach: home"); return end
        local world = a:sub(1, 2) == "w:"
        local x, y, z = (world and a:sub(3) or a):match("([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        if not z then log("reach: x,y,z or w:x,y,z"); return end
        if world then reachFollow(1, function() return { X = x, Y = y, Z = z } end) else reachTo(1, x, y, z) end
        log("reach %s(%.1f, %.1f, %.1f)", world and "world " or "", x, y, z)
    end,
    grip = function(a) setGrip(1, a == "1"); log("grip right %s", tostring(S.grip[1])) end,
    unmaskedtest = function() S.unmaskedTest = not S.unmaskedTest; log("online mask rule %s (dev)", S.unmaskedTest and "OFF" or "on") end,
    onlinetest = function() S.onlineTest = not S.onlineTest; S.gunShowLogged = nil; log("online gun check offline %s", tostring(S.onlineTest)) end,   -- dev
    lgrip = function(a) setGrip(0, a == "1"); log("grip left %s", tostring(S.grip[0])) end,   -- dev
    grabdebug = function() S.grabDebug = not S.grabDebug; log("grab debug %s", tostring(S.grabDebug)) end,   -- dev: online grab details
    -- dev: "pouchscan [col]" grips with the left hand at a grid of points (body yaw frame, x forward / y right, z above
    -- the VR origin) and logs which give a magazine: where the ammo pouch really is. "col" = only x=-10, y=0.
    pouchscan = function(a)
        local pts = {}
        local xs, ys = { -40, -10, 20 }, { -30, 0, 30 }
        if a == "col" then xs, ys = { -10 }, { 0 } end
        for _, x in ipairs(xs) do for _, y in ipairs(ys) do for z = 40, 220, 30 do pts[#pts + 1] = { x, y, z } end end end
        local hits = {}
        local function pt(q)
            local w = bodyPoint(q[1], q[2], 0)
            w.Z = S.pawn.VROrigin:K2_GetComponentLocation().Z + q[3]
            return w
        end
        local function step(i)
            if i > #pts then handHome(0); log("pouchscan: done, magazines at %s", #hits > 0 and table.concat(hits, " ") or "none"); return end
            local q = pts[i]
            reachFollow(0, function() return pt(q) end)
            after(0.45, function()
                setGrip(0, true)
                after(0.35, function()
                    local h = holding(0)
                    local n = ""
                    pcall(function() n = h:GetOwner():GetClass():GetFName():ToString() end)
                    local hl = handLoc(0)
                    local miss = dist(hl, pt(q))
                    if n:find("Magazine") or n:find("Shell") then hits[#hits + 1] = string.format("(%d,%d,%d)", q[1], q[2], q[3]) end
                    log("pouchscan (%d, %d, %d): %s (hand %.0f cm off)", q[1], q[2], q[3], n ~= "" and n or "-", miss)
                    setGrip(0, false)
                    after(0.25, function() step(i + 1) end)
                end)
            end)
        end
        step(1)
    end,
    -- dev: "fire <s>" holds the right trigger for s seconds (default 0.5)
    leverdebug = function() S.leverDebug = not S.leverDebug; log("lever debug %s", tostring(S.leverDebug)) end,
    fire = function(a)
        local s = tonumber(a) or 0.5
        S.trigger = true
        -- (game thread only: ExecuteWithDelay runs its callback on another thread, see main.lua)
        after(s, function() S.trigger = false; inject("IA_Trigger_R", 0) end)
    end,
    sgtarget = function(a) S.sgTarget = a; log("shell target %s", tostring(a)) end,   -- dev: chamber socket/bone override
    grenaderaw = function() S.grenadeRaw = not S.grenadeRaw; log("grenade: hand throw only (as online) %s (dev)", tostring(S.grenadeRaw)) end,
    reloaddebug = function() S.reloadDebug = not S.reloadDebug; log("reload debug %s", tostring(S.reloadDebug)) end,
    reloadshallow = function() S.reloadShallow = not S.reloadShallow; log("reload: first push short on purpose %s (dev, tests the stuck-magazine pushes)", tostring(S.reloadShallow)) end,
    lmbtest = function() S.lmbLog = now() + 8; S.lmbLast = nil; log("lmb debug for 8 s") end,   -- dev
    hookaim = function() S.noHookAim = not S.noHookAim; log("hook aim correction %s", S.noHookAim and "off" or "on") end,   -- dev
    -- the held gun's ADS profile and where its sights are (camera space: x forward, y right, z up)
    adsinfo = function()
        local g = gunInRightHand(); if not g then log("adsinfo: no gun in the right hand"); return end
        S.adsCache = {}
        local ok, p = pcall(adsProfile, g)
        if not (ok and p) then log("adsinfo: %s", tostring(p)); return end
        local g3 = gunGeometry(g, p)
        local ca = calibOf(g, "ads")
        local fam, class = gunFamily(g)
        local bore = g3 and string.format("muzzle (%.1f,%.1f,%.1f) bore dir (%.3f,%.3f,%.3f)", g3.mx, g3.my, g3.mz, g3.mx - g3.bx, g3.my - g3.by, g3.mz - g3.bz) or "?"
        if p.dot then log("adsinfo: red dot %.1f cm %s the iron sights' rear point (relief below is eye -> dot)", math.abs(p.dotShift or 0), (p.dotShift or 0) >= 0 and "ahead of" or "behind") end
        log("adsinfo %s [%s/%s] src=%s y=%s z=%s relief=%s time=%s cant=%s push=%s aim=%.2f | sight (%.1f,%.1f,%.1f) roll %.1f | %s | ads corr p%.1f y%.1f r%.1f x%.1f y%.1f z%.1f n=%d",
            g:GetClass():GetFName():ToString(), class, fam, p.src, tostring(p.y and string.format("%.1f", p.y)), tostring(p.z and string.format("%.1f", p.z)),
            tostring(p.relief), tostring(p.time), tostring(p.cant), tostring(p.push), S.aim,
            g3 and g3.rx or 0, g3 and g3.ry or 0, g3 and g3.rz or 0, g3 and g3.roll or 0, bore,
            ca.pitch, ca.yaw, ca.roll or 0, ca.x, ca.y, ca.z, ca.n or 0)
    end,
    adsdebug = function() S.adsDebug = not S.adsDebug; log("ads debug %s", tostring(S.adsDebug)) end,   -- dev
    -- hand smoothing (v0.3.27): "smooth" switches it off / on until restart (to compare), "smoothdebug" logs every
    -- pose-source switch (from, to, distance, angle, carried speed, blend time)
    smooth = function()
        S.smoothOff = not S.smoothOff
        log("hand smoothing %s%s", S.smoothOff and "OFF" or "on", (not S.smoothOff and cfg.hand_smooth == false) and " (but hand_smooth = false in config)" or "")
    end,
    smoothdebug = function() S.smoothDebug = not S.smoothDebug; log("smooth debug %s", tostring(S.smoothDebug)) end,
    -- the mouse sensitivity and where it comes from (config x the settings menu slider)
    sens = function()
        sensCache.t = -1
        local m = gameSensitivity()
        local ok, v = pcall(function() return userSettings().SmoothTurningSpeed end)
        log("mouse sensitivity %.3f deg/count = mouse_sensitivity %.3f x %.2f (settings slider %s, default %s)%s",
            cfg.mouse_sensitivity * m, cfg.mouse_sensitivity, m, ok and tostring(v) or "not found", tostring(cfg.sensitivity_slider_default or 3),
            cfg.sensitivity_slider == false and " [slider off in config]" or "")
    end,
    -- "adstune z=9.1": change one value of the held gun's profile for this session (y, z, relief, time, cant, push);
    -- "adstune clear" drops them all
    adstune = function(a)
        local g = gunInRightHand(); if not g then log("adstune: no gun in the right hand"); return end
        if a == "clear" then S.adsTune = {}; S.adsCache = {}; log("adstune: cleared (config values again)"); return end
        local kk, v = tostring(a):match("^([%a_]+)=([-%d%.]+)$")
        if not kk then log("adstune: use key=value (y, z, relief, time, cant, push, dot_closer, dot_relief)"); return end
        local fam = gunFamily(g)
        S.adsTune = S.adsTune or {}; S.adsTune[fam] = S.adsTune[fam] or {}
        S.adsTune[fam][kk] = tonumber(v); S.adsCache = {}
        log("adstune %s.%s = %s", fam, kk, v)
    end,
    jammer = function() fireJammer() end,
    ping = function() ping() end,
    pumpdebug = function() S.pumpDebug = not S.pumpDebug; log("pump debug %s", tostring(S.pumpDebug)) end,
    grabdebug = function() S.grabDebug = not S.grabDebug; log("grab debug %s", tostring(S.grabDebug)) end,
    throw = function() if S.carry then throwItem(0) elseif holdingA(1, GRENADE) then throwGrenade() else throwItem(1) end end,
    cursor = function(a)   -- dev: "cursor x,y" puts the pause-menu cursor x deg right, y deg up
        local x, y = tostring(a or "0,0"):match("([%-%d%.]+),([%-%d%.]+)")
        S.cursor = { x = tonumber(x) or 0, y = tonumber(y) or 0 }
        placeCrosshair(S.cursor.x, S.cursor.y)
        log("cursor %.1f, %.1f", S.cursor.x, S.cursor.y)
    end,
    -- dev: turn the held control about another axis: X/Y/Z of the control, or mcX/mcY/mcZ of the controller
    turnaxis = function(a)
        local r = S.rotary; if not r then log("turnaxis: hold something first"); return end
        local which = tostring(a or "X")
        local c = which:sub(1, 2) == "mc" and S.pawn.RightInteractionComponent.MotionSource or r.c
        if which:sub(1, 2) == "mc" then
            -- spin the controller in place: rebuild the pose so angle 0 = now
            local mc = c
            local l, rot = rotaryPose(r, r.angle)
            r.pivot, r.mcOff, r.mcRot, r.angle, r.target = l, { X = 0, Y = 0, Z = 0 }, rot, 0, 0
            KMATH = KMATH or StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
            local v = which == "mcY" and KMATH:GetRightVector(rot) or which == "mcZ" and KMATH:GetUpVector(rot) or KMATH:GetForwardVector(rot)
            r.axis = { X = v.X, Y = v.Y, Z = v.Z }
        else
            local v = axisOf(c, which)
            r.axis = { X = v.X, Y = v.Y, Z = v.Z }
        end
        log("turnaxis %s = (%.2f,%.2f,%.2f)", which, r.axis.X, r.axis.Y, r.axis.Z)
    end,
    -- grab/let go of the switch, knob, dial or wheel under the crosshair, or "turn <deg>" to set the held angle
    -- dev: with a safe dial held, "dial <n>" turns it n numbers R (negative n = L), closed-loop like the mouse wheel
    dialdebug = function() S.dialDebug = not S.dialDebug; log("dial debug %s", tostring(S.dialDebug)) end,
    -- dev: "lreach x,y,z" puts the left hand at a camera-space point (no argument: home)
    lreach = function(a)
        local x, y, z = tostring(a or ""):match("([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)")
        if not z then handHome(0); log("lreach: home"); return end
        reachTo(0, tonumber(x), tonumber(y), tonumber(z)); log("lreach (%s, %s, %s)", x, y, z)
    end,
    turndebug = function() S.turnDebug = not S.turnDebug; log("turn debug %s", tostring(S.turnDebug)) end,   -- valves
    dial = function(a)
        local r = S.rotary
        if not (r and r.kind.step) then log("dial: hold a safe dial first"); return end
        local reading = prop(r.a, "FinalRotationDegrees") or 0
        r.want = (r.want or reading) - (tonumber(a) or 1) * r.kind.step
        log("dial: going to %.0f", r.want)
    end,
    turn = function(a)
        if a and S.rotary then S.rotary.target = tonumber(a) or S.rotary.target; log("turn angle -> %s", a); return end
        if S.rotary then releaseRotary() else local r = rotaryUnderCrosshair(); if r then grabRotary(r) else log("turn: nothing under the crosshair") end end
    end,
    grab_r = function() toggleGrab(1) end,
    grab_l = function() toggleGrab(0) end,
    mask = maskOn,
    pitch = function(a) S.pitch = tonumber(a) or 0; log("pitch %.1f", S.pitch) end,
    debug = function()
        local cam = camera():K2_GetComponentLocation()
        for h = 0, 1 do
            local o = S.override[h]
            local t = S.pawn:GetHandTransformTarget(h).Translation
            local hl = handLoc(h)
            local tx, ty, tz = toCam(t); local vx, vy, vz = toCam(hl)
            log("hand %d override=%s target=(%.0f,%.0f,%.0f) visual=(%.0f,%.0f,%.0f) grip=%s pose=%s", h,
                o and (o.x and string.format("(%.0f,%.0f,%.0f)", o.x, o.y, o.z) or "(follow, no point yet)") or "nil",
                tx, ty, tz, vx, vy, vz, tostring(S.grip[h]), lastPose[h])
            local b = S.blend[h]
            log("hand %d source=%s blending=%s", h, keyName(b.key), b.active and string.format("yes (%.2f of %.2f s)", now() - b.t0, b.T) or "no")
        end
        log("steps=%d aim=%.2f supporting=%s adsLock=%s carry=%s", #S.steps, S.aim, tostring(S.supporting), tostring(S.adsLock), tostring(S.carry and S.carry:GetFName():ToString()))
        local g = gunInRightHand()
        local c = holding(1)
        log("gun=%s holding(1)=%s grip1=%s heldSlot=%s", g and g:GetFName():ToString() or "nil", c and c:GetOwner():GetFName():ToString() or "nil", tostring(S.grip[1]), tostring(S.heldSlot))
        if g then local ok, e = pcall(function() return g.SkeletalMeshComponent:DoesSocketExist(FName("s_support")) end); log("s_support on SkeletalMeshComponent: %s %s", tostring(ok), tostring(e)) end
        local lv = S.lever
        if lv then
            local pv, t, mc = lv.pivot, S.pawn:GetHandTransformTarget(1).Translation, S.pawn.RightInteractionComponent.MotionSource:K2_GetComponentLocation()
            log("lever angle=%.1f game=%.1f target-pivot=(%.1f,%.1f,%.1f) mc-pivot=(%.1f,%.1f,%.1f)", lv.angle,
                leverAngle(lv.l), t.X - pv.X, t.Y - pv.Y, t.Z - pv.Z, mc.X - pv.X, mc.Y - pv.Y, mc.Z - pv.Z)
        end
    end,
    ads = function(a)   -- toggle, or "ads 1" / "ads 0"
        if a == "1" then S.adsLock = true elseif a == "0" then S.adsLock = false else S.adsLock = not S.adsLock end
        log("ads lock %s", tostring(S.adsLock))
    end,
    watch = function() S.watchLock = not S.watchLock; log("watch lock %s", tostring(S.watchLock)) end,
    hack = function() startHack() end,
    reload = reload,
    dismiss = function()
        local c = FindFirstOf("BPC_ModalTutorialWindowController_C")
        if c and c:IsValid() then pcall(function() c:OnSkipButtonPressed() end) end
    end,
    status = function()
        log("pawn=%s pitch=%.1f gripL=%s gripR=%s steps=%d", S.pawn and S.pawn:IsValid() and S.pawn:GetFName():ToString() or "nil",
            S.pitch, tostring(S.grip[0]), tostring(S.grip[1]), #S.steps)
    end,
}
function M.command(name, arg)
    local fn = commands[name]
    if not fn then log("usage: flatmode reload|pistol|primary|grab_r|grab_l|mask|reload_gun|watch|dismiss|status"); return end
    local ok, e = pcall(fn, arg); if not ok then log("%s: %s", name, tostring(e)) end
end
commands.reload_gun = function() reload(1) end
commands.reload = nil

return M
