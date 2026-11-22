-- Evade v8 (Matcha + ZeroUI)
-- Emote Dash, Bhop, Auto Strafe, Bot ESP, Auto Revive, Event Farm, Safe Spots, Fullbright
-- Load with: loadstring(readfile("evade_v8.lua"))()
-- UI: ZeroUI. Put main.lua in the Matcha workspace folder, or let it download from GitHub.
-- Menu key: RSHIFT (change it in the settings tab). Every setting is saved to evade_v8.json.

----------------------------------------------------------------------
-- 1. load the UI library
----------------------------------------------------------------------
-- Several sources are tried so that one failed download cannot stop the script:
--  1) main.lua next to the script   2) your own copy on GitHub   3) the original repo   4) a CDN mirror
--  5) the copy saved by an earlier successful run (zeroui_cache.lua)
local LIB_URLS = {
    "https://raw.githubusercontent.com/jnoah7989-sketch/MatchaLatte/refs/heads/main/main.lua",
    "https://raw.githubusercontent.com/onlywraith/zero-inspired/refs/heads/main/main.lua",
    "https://cdn.jsdelivr.net/gh/onlywraith/zero-inspired@main/main.lua",
}
local LIB_CACHE = "zeroui_cache.lua"

local function usable(t) return type(t) == "table" and not t._dead and type(t.CreateWindow) == "function" end

local function looksLikeLib(s)
    return type(s) == "string" and #s > 1000 and string.find(s, "CreateWindow", 1, true) ~= nil
        and not string.find(string.sub(s, 1, 300), "<html", 1, true)
end

-- httpget is Matcha's documented function; game:HttpGet exists on some builds only
local function fetch(url)
    local ok, res = pcall(function() return httpget(url) end)
    if ok and type(res) == "string" and #res > 0 then return res end
    local why = tostring(res)
    local ok2, res2 = pcall(function() return game:HttpGet(url) end)
    if ok2 and type(res2) == "string" and #res2 > 0 then return res2 end
    return nil, string.sub(why, 1, 60)
end

local Library = rawget(_G, "main")
if not usable(Library) then
    _G.main = nil -- drop a stale / half-loaded copy
    local src, problems = nil, {}

    pcall(function()
        if isfile("main.lua") then
            local s = readfile("main.lua")
            if looksLikeLib(s) then src = s end
        end
    end)

    if not src then
        for round = 1, 2 do
            for _, url in ipairs(LIB_URLS) do
                local s, why = fetch(url)
                if s and looksLikeLib(s) then
                    src = s
                    pcall(function() writefile(LIB_CACHE, s) end) -- keep a copy for next time
                    break
                end
                problems[#problems + 1] = url .. " -> " .. (why or "answered, but it is not the UI library")
            end
            if src then break end
            wait(1)
        end
    end

    if not src then
        pcall(function()
            if isfile(LIB_CACHE) then
                local s = readfile(LIB_CACHE)
                if looksLikeLib(s) then src = s end
            end
        end)
    end

    if not src then
        for _, p in ipairs(problems) do warn(p) end
        warn("Evade: UI library not found - every download failed (details above)")
        pcall(function() notify("UI library not found - see the console for details", "Evade", 8) end)
        return
    end

    local ok, lerr = pcall(function() local f = loadstring(src); f() end) -- Matcha drops loadstring's return
    Library = rawget(_G, "main")
    if not usable(Library) then
        warn("Evade: the UI library was found but did not start" .. (ok and "" or (": " .. tostring(lerr))))
        pcall(function() notify("UI library did not start - see the console", "Evade", 8) end)
        return
    end
end

----------------------------------------------------------------------
-- 2. services, clean-up of a previous run
----------------------------------------------------------------------
local Players    = game:GetService("Players") or game.Players
local RunService = game:GetService("RunService") or game.RunService
local Lighting   = game:GetService("Lighting") or game.Lighting
local LocalPlayer = Players.LocalPlayer

local DIAG_FILE = "evade_diag.txt"
local VK_G, VK_SPACE, VK_A, VK_D, VK_W, VK_S = 0x47, 0x20, 0x41, 0x44, 0x57, 0x53

if rawget(_G, "EvadeV8") then pcall(function() _G.EvadeV8.stop() end) end
local RUN = { on = true, pool = {}, arrows = {}, conn = nil }
_G.EvadeV8 = RUN

----------------------------------------------------------------------
-- 3. shared state
----------------------------------------------------------------------
local state = { dash = false, bhop = false, strafe = false, revive = false, farm = false, safe = false,
    esp = false }
local TOGGLES = { dash = "dash_on", bhop = "bhop_on", strafe = "strafe_on", revive = "revive_on",
    farm = "farm_on", safe = "safe_on", esp = "esp_on" }
-- a feature only responds to its key / toggle when its "enable" switch (main tab) is on
local EN = { dash = "en_dash", bhop = "en_bhop", strafe = "en_strafe", revive = "en_revive",
    farm = "en_farm", safe = "en_safe", esp = "en_esp" }
local LABELS = { dash = "emote dash", bhop = "bhop", strafe = "auto strafe", revive = "auto revive",
    farm = "event farm", safe = "safe spots", esp = "bot esp" }
local H, DEF = {}, {} -- flag -> control handle / default value
local rerun = false
local lastErr = "none"
local espInfo, rvStatus, farmStatus, safeStatus = "ESP: off", "revive: off", "farm: off", "safe: off"
local seqCount, seqTime = 0, nil
local dashBusy = false
local dashPeak, dashPeakUntil = 0, 0
local speed, airborne = 0, false
local panic, runDiagnostic, espTest, runNear -- defined further down, used by menu buttons

local function cfg(id)
    local h = H[id]
    if h then return h:Get() end
    return DEF[id]
end

local function say(msg)
    pcall(function() Library:Notify({ text = msg, duration = 2 }) end)
end

local function splitList(str)
    local list = {}
    for w in string.gmatch(tostring(str or ""), "[^,]+") do
        w = w:gsub("^%s+", "")
        w = w:gsub("%s+$", "")
        if w ~= "" then list[#list + 1] = w end
    end
    return list
end

local function anyFeatureOn()
    return state.dash or state.bhop or state.strafe or state.revive or state.farm
end

local function requireEnabled(id, label)
    if cfg(id) == true then return true end
    say(label .. " is not enabled (main tab > enable features)")
    return false
end

----------------------------------------------------------------------
-- 4. the menu
----------------------------------------------------------------------
local win, statusLabels -- created inside the menu block below, used by later sections
do -- [section block]: keeps this part's local variables from piling up (Lua limit: 200)
win = Library:CreateWindow({
    id = "evade_v8", title = "evade", subtitle = "v8", size = { 800, 620 }, columns = 2,
    toggleKey = "RSHIFT",
    config = "evade_v8.json", folder = "UI/evade_v8",
    -- while a feature is running, don't block game input while you hover the menu
    captureInput = function() return not anyFeatureOn() end,
})

local function tog(g, flag, text, default, save)
    DEF[flag] = default
    H[flag] = g:AddToggle({ text = text, flag = flag, default = default, save = save })
    return H[flag]
end
local function sld(g, flag, text, mn, mx, default, suffix)
    DEF[flag] = default
    H[flag] = g:AddSlider({ text = text, flag = flag, min = mn, max = mx, step = 1, default = default,
        suffix = suffix or "" })
    return H[flag]
end
local function txt(g, flag, text, default, placeholder, maxLen)
    DEF[flag] = default
    H[flag] = g:AddTextbox({ text = text, flag = flag, default = default, placeholder = placeholder or "",
        maxLength = maxLen or 80 })
    return H[flag]
end
local function colr(g, flag, text, rgb)
    DEF[flag] = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
    H[flag] = g:AddColor({ text = text, flag = flag, default = rgb })
    return H[flag]
end

-- ---- main tab ----
local tabMain = win:AddTab("main", "evade")
local gEn = tabMain:AddGroup("enable features", 1)
gEn:AddLabel({ text = "a feature's key and toggle only work if it is enabled here.", dim = true })
tog(gEn, "en_dash", "emote dash", false)
tog(gEn, "en_bhop", "bhop", false)
tog(gEn, "en_strafe", "auto strafe", false)
tog(gEn, "en_revive", "auto revive", false)
tog(gEn, "en_farm", "event autofarm", false)
tog(gEn, "en_safe", "safe spots", false)
tog(gEn, "en_esp", "bot esp", false)

local gF = tabMain:AddGroup("features", 1)
gF:AddLabel({ text = "start / stop with these toggles or their keys (they always start off).", dim = true })
tog(gF, "dash_on", "auto emote dash", false, false):AddKeybind({ flag = "kb_dash", default = "K", mode = "toggle", notify = false })
tog(gF, "bhop_on", "auto bhop (always)", false, false):AddKeybind({ flag = "kb_bhop", default = "J", mode = "toggle", notify = false })
tog(gF, "strafe_on", "auto strafe", false, false):AddKeybind({ flag = "kb_strafe", default = "L", mode = "toggle", notify = false })
tog(gF, "revive_on", "auto revive", false, false):AddKeybind({ flag = "kb_revive", default = "H", mode = "toggle", notify = false })
tog(gF, "farm_on", "event autofarm", false, false):AddKeybind({ flag = "kb_farm", default = "I", mode = "toggle", notify = false })
tog(gF, "safe_on", "safe spots", false, false):AddKeybind({ flag = "kb_safe", default = "U", mode = "toggle", notify = false })
tog(gF, "esp_on", "bot esp", false, false):AddKeybind({ flag = "kb_esp", default = "Y", mode = "toggle", notify = false })
tog(gF, "fullbright", "fullbright / no fog", false)

local gC = tabMain:AddGroup("controls", 2)
gC:AddKeybind({ text = "re-run emote now", flag = "kb_redash", default = "B", mode = "toggle", notify = false,
    onClick = function() if requireEnabled("en_dash", "emote dash") then rerun = true end end })
gC:AddKeybind({ text = "panic (all off)", flag = "kb_panic", default = "END", mode = "toggle", notify = false,
    onClick = function() panic() end })
gC:AddButton({ text = "run emote sequence", callback = function() if requireEnabled("en_dash", "emote dash") then rerun = true end end })
gC:AddButton({ text = "panic (all off)", callback = function() panic() end })
tog(gC, "ignore_focus", "ignore window-focus check", false)
sld(gC, "fb_bright", "fullbright brightness", 1, 5, 2)
sld(gC, "fb_overlay", "fullbright overlay", 0, 60, 15, " %")
gC:AddButton({ text = "run full diagnostic", callback = function() runDiagnostic() end })
sld(gC, "near_radius", "near-scan radius", 5, 100, 20, " studs")
gC:AddButton({ text = "scan objects near me (stand next to a wisp)", callback = function() runNear() end })
gC:AddLabel({ text = "diagnostic saves evade_diag.txt in the Matcha workspace folder.", dim = true })

local gS = tabMain:AddGroup("status", 2)
statusLabels = {}
for i = 1, 6 do statusLabels[i] = gS:AddLabel({ text = "...", dim = true }) end

-- ---- emote dash / bhop tab ----
local tabDash = win:AddTab("dash + bhop", "evade")
local gD = tabDash:AddGroup("emote dash", 1)
sld(gD, "dash_slot", "emote slot", 1, 9, 1)
tog(gD, "ctrl_hold", "hold ctrl (unsafe)", false)
sld(gD, "ctrl_down", "ctrl down time per tap", 1, 20, 3, " ms")
sld(gD, "ctrl_ms", "gap between ctrl taps", 1, 50, 10, " ms")
tog(gD, "ctrl_moving", "ctrl only while moving", false)
tog(gD, "ctrl_left", "use left ctrl code", false)
sld(gD, "dash_cd", "ctrl -> g delay", 0, 600, 100, " ms")
sld(gD, "dash_hold", "key hold time", 10, 250, 60, " ms")
sld(gD, "dash_gap", "g -> slot gap", 0, 600, 100, " ms")
sld(gD, "dash_end", "keep ctrl after slot", 0, 500, 80, " ms")
sld(gD, "dash_passes", "sequence attempts", 1, 3, 1)
sld(gD, "dash_passgap", "gap between attempts", 100, 1500, 300, " ms")
tog(gD, "dash_refocus", "re-run when tabbing in", true)
sld(gD, "dash_respawn", "wait after respawn", 100, 3000, 700, " ms")
sld(gD, "dash_repeat", "re-run every N sec", 0, 60, 0, " s")

local gB = tabDash:AddGroup("bhop", 2)
tog(gB, "bhop_dash", "bhop while emote dashing", true)
tog(gB, "bhop_pause", "pause bhop during emote", true)
sld(gB, "bhop_hold", "space press time", 5, 80, 15, " ms")
sld(gB, "bhop_gap", "delay between jumps", 1, 100, 15, " ms")
tog(gB, "bhop_moving", "only while holding w/a/s/d", false)

-- ---- strafe tab ----
local tabStrafe = win:AddTab("auto strafe", "evade")
local gA = tabStrafe:AddGroup("auto strafe", 1)
tog(gA, "strafe_m2k", "mouse -> keys mode", false)
sld(gA, "strafe_px", "keys->mouse strength", 1, 60, 5, " px")
sld(gA, "strafe_thresh", "turn sensitivity", 5, 200, 25, " deg/s")
sld(gA, "strafe_hold", "mouse->keys key hold", 20, 300, 80, " ms")
tog(gA, "strafe_w", "mouse->keys also presses w", true)
tog(gA, "strafe_invert", "invert direction", false)
tog(gA, "strafe_air", "only while in the air", false)
tog(gA, "strafe_ramp", "ramp up while held", true)
tog(gA, "strafe_menu_pause", "pause when menu is open", true)
local gA2 = tabStrafe:AddGroup("how it works", 2)
gA2:AddLabel({ text = "keys -> mouse: hold A and the mouse moves left, hold D and it moves right.", dim = true })
gA2:AddLabel({ text = "mouse -> keys: turn the camera left and it holds A + W, turn right and it holds D + W.", dim = true })

-- ---- esp tab ----
local tabEsp = win:AddTab("bot esp", "visuals")
local gE = tabEsp:AddGroup("bot esp", 1)
tog(gE, "esp_box", "boxes", true)
tog(gE, "esp_name", "names + distance", true)
tog(gE, "esp_tracer", "tracers", false)
tog(gE, "esp_warn_text", "nearby-bot warning text", true)
tog(gE, "esp_loose", "loose detection", false)
tog(gE, "esp_arrows", "off-screen arrows", true)
tog(gE, "esp_eta", "show time until contact", true)
txt(gE, "esp_path", "bot folder (blank = auto)", "", "e.g. Game.Players")
txt(gE, "esp_filter", "name contains", "", "")
sld(gE, "esp_height", "box height", 2, 30, 6, " studs")
sld(gE, "esp_warn", "warn distance", 10, 300, 60, " studs")
sld(gE, "esp_maxdist", "max distance", 50, 3000, 1500, " studs")
local gE2 = tabEsp:AddGroup("look", 2)
colr(gE2, "esp_col", "bot color", { 255, 40, 40 })
colr(gE2, "esp_warncol", "warning color", { 255, 170, 0 })
gE2:AddButton({ text = "esp self-test (box for 3s)", callback = function() espTest() end })

-- ---- revive tab ----
local tabRv = win:AddTab("auto revive", "evade")
local gR = tabRv:AddGroup("auto revive", 1)
txt(gR, "rv_attr", "downed names (comma list)", "Downed,Down,Knocked", "")
txt(gR, "rv_key", "revive key", "E", "", 1)
sld(gR, "rv_range", "revive range", 3, 40, 10, " studs")
sld(gR, "rv_maxhold", "max hold time per try", 500, 10000, 4000, " ms")
sld(gR, "rv_botclear", "skip if bot within", 0, 150, 30, " studs")
sld(gR, "rv_cooldown", "retry skipped after", 1, 30, 6, " s")
local gR2 = tabRv:AddGroup("detection", 2)
tog(gR2, "rv_use_attr", "attribute with those names", true)
tog(gR2, "rv_auto", "attr containing down/knock", true)
tog(gR2, "rv_use_value", "child value object", true)
tog(gR2, "rv_use_names", "child named down/revive", true)
tog(gR2, "rv_use_ragdoll", "ragdolling (experimental)", false)
tog(gR2, "rv_use_health", "low health", false)
sld(gR2, "rv_hp", "low health threshold", 0, 50, 1)
tog(gR2, "rv_blind", "blind mode (any teammate)", false)
tog(gR2, "rv_tp", "teleport to downed", false)
tog(gR2, "rv_return", "teleport back after", true)
sld(gR2, "rv_tpmax", "max teleport distance", 20, 2000, 400, " studs")

-- ---- farm tab ----
local tabFarm = win:AddTab("farm + safe", "evade")
local gM = tabFarm:AddGroup("event farm", 1)
txt(gM, "farm_keys", "item names (comma list)", "Wisp", "")
txt(gM, "farm_path", "item folder (blank = auto)", "", "e.g. Effects.Tickets")
sld(gM, "farm_depth", "search depth", 1, 8, 5)
sld(gM, "farm_ms", "minimum stay per item", 30, 1500, 150, " ms")
tog(gM, "farm_waitgone", "leave when item is gone", true)
sld(gM, "farm_maxstay", "max stay per item", 100, 3000, 1500, " ms")
sld(gM, "farm_yoff", "teleport height offset", 0, 10, 2, " studs")
sld(gM, "farm_revisit", "no revisit for", 3, 120, 20, " s")
tog(gM, "farm_flee", "hide when a bot is close", true)
tog(gM, "farm_sky", "hide at old sky point", true)
sld(gM, "farm_flee_dist", "flee when bot within", 10, 300, 50, " studs")
sld(gM, "farm_flee_hold", "stay hidden for", 1, 20, 3, " s")
sld(gM, "farm_botclear", "skip items near bot", 0, 200, 40, " studs")
local gSf = tabFarm:AddGroup("safe spots", 2)
sld(gSf, "sf_dist", "distance from map", 1000, 50000, 10000, " studs")
sld(gSf, "sf_height", "height", 500, 20000, 5000, " studs")
sld(gSf, "sf_ms", "time per spot", 300, 3000, 1000, " ms")
tog(gSf, "sf_return", "teleport back on off", true)
tog(gSf, "sf_anchor", "anchor in air (test)", false)
tog(gSf, "sf_auto", "auto: hide only near bots", false)
sld(gSf, "sf_auto_dist", "auto hide distance", 20, 300, 80, " studs")
sld(gSf, "sf_auto_hold", "auto: stay hidden for", 1, 20, 4, " s")
tog(gSf, "sf_sky", "use the old sky point", false)

win:AddSettingsTab() -- themes, configs, menu key, watermark, unload ...

end -- [section block]
----------------------------------------------------------------------
-- 5. key helpers
----------------------------------------------------------------------
-- Everything is tapped. Only the strafe A/D (and an injected W) are held briefly, and they are
-- released on every state change, on unfocus, on panic and on unload.
-- ZeroUI exposes whether a textbox / search / keybind-rebind is active: never inject keys then
local function typing()
    return Library._focus ~= nil or Library._listen ~= nil
end
local function menuOpen()
    local ok, v = pcall(function() return win:IsVisible() end)
    return ok and v == true
end

local strafeKey, wInjected = nil, false
local function press(vk)
    if typing() then return end
    pcall(keypress, vk)
end
local function rel(vk) pcall(keyrelease, vk) end
local function tap(vk, ms) press(vk); wait(ms / 1000); rel(vk) end
local function ctrlVK() return cfg("ctrl_left") and 0xA2 or 0x11 end
local function releaseCtrl() rel(0x11); rel(0xA2) end

local function rvKeyCode()
    local s = string.upper(tostring(cfg("rv_key") or "E"))
    local b = string.byte(s, 1)
    if b and ((b >= 65 and b <= 90) or (b >= 48 and b <= 57)) then return b end
    return 0x45 -- E
end

local function releaseAll()
    releaseCtrl()
    rel(rvKeyCode()); rel(VK_SPACE); rel(VK_A); rel(VK_D); rel(VK_G)
    if wInjected then rel(VK_W); wInjected = false end
    for vk = 0x31, 0x39 do rel(vk) end
    strafeKey = nil
end

local function strafeRelease()
    if strafeKey then rel(strafeKey); strafeKey = nil end
    if wInjected then rel(VK_W); wInjected = false end
end

-- Crash-safe loop: an error is shown in Status instead of silently killing the feature
local function loop(name, fn)
    task.spawn(function()
        while RUN.on do
            local ok, err = pcall(fn)
            if not ok then
                lastErr = name .. ": " .. tostring(err)
                wait(0.2)
            end
        end
    end)
end

-- Roblox must be running (LocalPlayer readable) AND focused. Any error = NOT active.
-- The check runs in one small background loop; everything else reads the cached result.
local aliveCache, activeCache = true, true
local function alive() return aliveCache end
local function active() return activeCache end

loop("focus", function()
    local ok, r = pcall(function() return LocalPlayer.Name end)
    aliveCache = ok and type(r) == "string" and r ~= ""
    if not aliveCache then
        activeCache = false
    elseif cfg("ignore_focus") then
        activeCache = true
    else
        local ok2, r2 = pcall(isrbxactive)
        activeCache = ok2 and r2 == true
    end
    wait(0.04)
end)

-- menu toggles -> script state (reads plain Lua values, so it is cheap)
local startT, lastWarn, prevState = tick(), {}, {}
loop("sync", function()
    for k, id in pairs(TOGGLES) do
        local h = H[id]
        local want = (h and h:Get() == true) or false
        if cfg(EN[k]) == true then
            state[k] = want
            if prevState[k] ~= nil and prevState[k] ~= want then
                say(LABELS[k] .. (want and " ON" or " OFF"))
            end
            prevState[k] = want
        else
            -- not enabled: it cannot be switched on, not even with its key
            state[k] = false
            prevState[k] = false
            if want then
                pcall(function() h:Set(false) end)
                local t = tick()
                if t - startT > 3 and t - (lastWarn[k] or 0) > 1.5 then
                    lastWarn[k] = t
                    say(LABELS[k] .. " is not enabled (main tab > enable features)")
                end
            end
        end
    end
    wait(0.03)
end)

panic = function()
    for k in pairs(state) do state[k] = false end
    for _, id in pairs(TOGGLES) do
        pcall(function() H[id]:Set(false) end)
    end
    pcall(function() H.esp_on:Set(false) end)
    pcall(function() H.fullbright:Set(false) end)
    releaseAll()
    say("PANIC: everything off, keys released")
end

----------------------------------------------------------------------
-- 6. Matcha quirks: Player.Character can be nil, and instances do not compare equal
--    (so players are matched by NAME and nothing uses an instance as a table key)
----------------------------------------------------------------------
local charFolder = nil -- the folder that holds character models (found automatically)
local slowLookup = {}

-- IsA() over-matches in Matcha (folders pass IsA("BasePart")), so classes are checked by ClassName
local PART_CLASSES = { Part = true, MeshPart = true, UnionOperation = true, WedgePart = true,
    CornerWedgePart = true, TrussPart = true, SpawnLocation = true }
local function classOf(o)
    local ok, c = pcall(function() return o.ClassName end)
    if ok and type(c) == "string" then return c end
    return ""
end
local function isPartObj(o) return PART_CLASSES[classOf(o)] == true end
local function isModelObj(o) return classOf(o) == "Model" end

-- Evade: workspace.Players holds in-round characters AND the bots; Rigs / PlayerCache only hold
-- templates and cached copies (they must never be treated as bots or searched for items)
local SKIP_BOTS = { Rigs = true, PlayerCache = true, Map = true, Effects = true, StreamFoci = true,
    Vehicles = true, Soundscape = true, MenuScene = true, Camera = true, Terrain = true }
local SKIP_ITEMS = { Rigs = true, PlayerCache = true, Players = true, StreamFoci = true,
    Vehicles = true, Soundscape = true, MenuScene = true, Camera = true, Terrain = true }

local function deepFind(root, name, depth, budget)
    local direct = root:FindFirstChild(name)
    if direct then return direct end
    if depth <= 0 then return nil end
    for _, c in ipairs(root:GetChildren()) do
        budget.n = budget.n - 1
        if budget.n <= 0 then return nil end
        if not isPartObj(c) and not SKIP_BOTS[c.Name] and not c:FindFirstChild("Humanoid") then
            local f = deepFind(c, name, depth - 1, budget)
            if f then return f end
        end
    end
    return nil
end

local function lookupIn(folder, name)
    if not folder then return nil end
    local ok, f = pcall(function() return folder:FindFirstChild(name) end)
    if ok and f and f:FindFirstChild("HumanoidRootPart") then return f end
    return nil
end

local function charOf(plr)
    local ok, ch = pcall(function() return plr.Character end)
    if ok and ch then return ch end
    local name = plr.Name
    local f = lookupIn(charFolder, name)
        or lookupIn(workspace:FindFirstChild("Players"), name)
        or lookupIn(workspace, name)
    if f then
        pcall(function() charFolder = f.Parent end)
        return f
    end
    local t = tick()
    if slowLookup[name] and t - slowLookup[name] < 3 then return nil end
    slowLookup[name] = t
    local found = deepFind(workspace, name, 3, { n = 400 })
    if found and found:FindFirstChild("HumanoidRootPart") then
        pcall(function() charFolder = found.Parent end)
        return found
    end
    return nil
end

local gcT, gcHrp, gcChar = 0, nil, nil
local function getChar()
    local t = tick()
    if t - gcT < 0.1 then
        if gcHrp then return gcHrp, gcChar end
        return nil
    end
    gcT = t
    gcHrp, gcChar = nil, nil
    local ch = charOf(LocalPlayer)
    if ch then
        local hrp = ch:FindFirstChild("HumanoidRootPart")
        if hrp then gcHrp, gcChar = hrp, ch end
    end
    if gcHrp then return gcHrp, gcChar end
    return nil
end

local function rootOf(model)
    local r = model:FindFirstChild("HumanoidRootPart")
    if r then return r end
    local ok, p = pcall(function() return model.PrimaryPart end)
    if ok and p then return p end
    for _, c in ipairs(model:GetChildren()) do
        if isPartObj(c) then return c end
    end
end

local function resolvePath(path)
    local cur = workspace
    for part in string.gmatch(path, "[^%.]+") do
        cur = cur:FindFirstChild(part)
        if not cur then return nil end
    end
    return cur
end

-- Drawing property names differ between Matcha builds, so everything goes through pcall
local function set(object, key, value)
    return pcall(function() object[key] = value end)
end
local sizeKey = nil
local function setTextSize(text, size)
    if sizeKey then return set(text, sizeKey, size) end
    if set(text, "Size", size) then sizeKey = "Size" return true end
    if set(text, "FontSize", size) then sizeKey = "FontSize" return true end
    return false
end

local function project(pos)
    local ok, screen, onScreen = pcall(WorldToScreen, pos)
    if ok and screen and onScreen then return screen end
    return nil
end

----------------------------------------------------------------------
-- 7. motion tracking (speed readout, "only in air")
----------------------------------------------------------------------
local mPos, mT, mAir = nil, tick(), tick()
local mVel = Vector3.new(0, 0, 0)
loop("motion", function()
    if not (state.dash or (state.strafe and cfg("strafe_air"))) then
        mPos, speed, airborne = nil, 0, false
        wait(0.25)
        return
    end
    local hrp = getChar()
    if hrp then
        local pos, now = hrp.Position, tick()
        if mPos then
            local dt = now - mT
            if dt > 0 then
                local raw = Vector3.new((pos.X - mPos.X) / dt, 0, (pos.Z - mPos.Z) / dt)
                mVel = Vector3.new(mVel.X * 0.5 + raw.X * 0.5, 0, mVel.Z * 0.5 + raw.Z * 0.5)
                speed = mVel.Magnitude
                if now < dashPeakUntil and speed > dashPeak then dashPeak = speed end
                if math.abs(pos.Y - mPos.Y) > 0.05 then
                    airborne, mAir = true, now
                elseif now - mAir > 0.1 then
                    airborne = false
                end
            end
        end
        mPos, mT = pos, now
    else
        mPos, speed, airborne = nil, 0, false
        mVel = Vector3.new(0, 0, 0)
    end
    wait(0.04)
end)

----------------------------------------------------------------------
-- 8. emote dash
----------------------------------------------------------------------
do -- [section block]: keeps this part's local variables from piling up (Lua limit: 200)
-- Ctrl is held only for the short G -> slot sequence, then released.
-- While the dash is ON, a separate loop taps Ctrl (or re-sends it in hold mode).
local function runDash()
    if dashBusy then return end
    dashBusy = true
    local vk = ctrlVK()
    pcall(function()
        press(vk)
        wait(cfg("dash_cd") / 1000)
        local h = cfg("dash_hold")
        local slot = math.clamp(math.floor(cfg("dash_slot")), 1, 9)
        for i = 1, math.clamp(math.floor(cfg("dash_passes")), 1, 3) do
            if i > 1 then wait(cfg("dash_passgap") / 1000) end
            tap(VK_G, h)
            wait(cfg("dash_gap") / 1000)
            tap(0x30 + slot, h)
        end
        wait(cfg("dash_end") / 1000)
    end)
    releaseCtrl() -- always released, even if something above errored
    seqCount, seqTime = seqCount + 1, tick()
    dashPeak, dashPeakUntil = 0, tick() + 2.5
    dashBusy = false
end

local ctrlActive = false
loop("ctrl", function()
    local go = state.dash and active() and not dashBusy
    if go and cfg("ctrl_moving") then
        go = iskeypressed(VK_W) or iskeypressed(VK_A) or iskeypressed(VK_D) or iskeypressed(VK_S)
    end
    if go then
        local vk = ctrlVK()
        if cfg("ctrl_hold") then
            press(vk) -- re-sent every 100 ms; released the moment you turn off / unfocus
            wait(0.1)
        else
            -- Ctrl is only ever down inside this tight loop: the script never sleeps (yields) while it is
            -- pressed. If the script is stopped at any sleep point (e.g. Roblox closing), Ctrl is up.
            press(vk)
            local untilT = os.clock() + cfg("ctrl_down") / 1000
            while os.clock() < untilT do end
            rel(vk)
            wait(cfg("ctrl_ms") / 1000)
        end
        ctrlActive = true
    else
        if ctrlActive and not dashBusy then
            releaseCtrl()
            ctrlActive = false
        end
        wait(0.1)
    end
end)

local wasOn, lastRun, wasFocused, charGone = false, tick(), true, nil
loop("dash", function()
    local on = state.dash
    local focused = active()

    -- respawn detection without comparing instances: the root part disappears, then comes back
    local respawned = false
    if getChar() then
        if charGone and tick() - charGone > 0.4 then respawned = true end
        charGone = nil
    elseif not charGone then
        charGone = tick()
    end

    if rerun then
        rerun = false
        if focused then runDash(); lastRun = tick() end
    end

    if on and not wasOn then
        wasOn, lastRun = true, tick()
        if focused then runDash() end
    elseif not on and wasOn then
        wasOn = false
        releaseCtrl()
    elseif on then
        if respawned then
            wait(cfg("dash_respawn") / 1000)
            if state.dash and active() then runDash(); lastRun = tick() end
        elseif focused and not wasFocused and cfg("dash_refocus") then -- tabbed back in
            runDash(); lastRun = tick()
        end
        local rp = cfg("dash_repeat")
        if rp > 0 and tick() - lastRun >= rp and focused then
            runDash(); lastRun = tick()
        end
    end
    wasFocused = focused
    wait(0.05)
end)

----------------------------------------------------------------------
-- 9. bhop (tap-spam, never held)
----------------------------------------------------------------------
loop("bhop", function()
    local want = state.bhop or (state.dash and cfg("bhop_dash"))
    if want and cfg("bhop_moving") then
        want = iskeypressed(VK_W) or iskeypressed(VK_A) or iskeypressed(VK_D) or iskeypressed(VK_S)
    end
    if want and active() and not (cfg("bhop_pause") and dashBusy) then
        press(VK_SPACE)
        wait(cfg("bhop_hold") / 1000)
        rel(VK_SPACE)
        wait(cfg("bhop_gap") / 1000)
    else
        wait(0.1)
    end
end)

----------------------------------------------------------------------
-- 10. auto strafe
----------------------------------------------------------------------
-- Keys -> Mouse: you hold A, the mouse moves left; you hold D, the mouse moves right.
-- Mouse -> Keys: you turn the camera left, it holds A (+W); you turn right, it holds D (+W).
local lLx, lLz, lRx, lRz, lT = nil, nil, nil, nil, tick()
local lastTurnT, lastTurnDir = 0, 0
local heldDir, heldSince = 0, nil

loop("strafe", function()
    local on = state.strafe and active() and getChar() ~= nil
    if on and cfg("strafe_air") and not airborne then on = false end

    if not on then
        strafeRelease()
        lLx = nil
        wait(0.1)
        return
    end

    local inv = cfg("strafe_invert")

    if not cfg("strafe_m2k") then
        -- KEYS -> MOUSE (no keys are injected in this mode)
        strafeRelease()
        if typing() or (cfg("strafe_menu_pause") and menuOpen()) then
            heldDir, heldSince = 0, nil
            wait(0.05)
            return
        end
        local left, right = iskeypressed(VK_A), iskeypressed(VK_D)
        local dirKey = 0
        if left and not right then dirKey = -1 elseif right and not left then dirKey = 1 end
        if dirKey ~= 0 then
            local now = tick()
            if heldDir ~= dirKey then heldDir, heldSince = dirKey, now end
            local px = cfg("strafe_px")
            if cfg("strafe_ramp") then
                -- starts gentle and reaches full strength after 0.3 s of holding
                px = px * (0.35 + 0.65 * math.min((now - heldSince) / 0.3, 1))
            end
            local mv = dirKey * px
            if inv then mv = -mv end
            if mv >= 0 then mv = math.floor(mv + 0.5) else mv = -math.floor(-mv + 0.5) end
            if mv ~= 0 then mousemoverel(mv, 0) end
        else
            heldDir, heldSince = 0, nil
        end
        wait(0.016)
        return
    end

    -- MOUSE -> KEYS: read camera yaw rate (works whether the cursor is locked or not)
    local ok, lx, lz, rx, rz = pcall(function()
        local cf = workspace.CurrentCamera.CFrame
        local l, r = cf.LookVector, cf.RightVector
        return l.X, l.Z, r.X, r.Z
    end)
    if not ok or not lx then
        wait(0.02)
        return
    end

    local now = tick()
    local turn = 0
    if lLx then
        local dt = now - lT
        if dt > 0 then
            -- how far the look direction moved toward the right vector, per second (rad/s)
            local rate = ((lx - lLx) * lRx + (lz - lLz) * lRz) / dt
            local thr = math.rad(cfg("strafe_thresh"))
            if rate > thr then turn = 1 elseif rate < -thr then turn = -1 end
        end
    end
    lLx, lLz, lRx, lRz, lT = lx, lz, rx, rz, now

    if inv then turn = -turn end
    if turn ~= 0 then
        lastTurnT, lastTurnDir = now, turn
    end

    local want = nil
    if now - lastTurnT <= cfg("strafe_hold") / 1000 then
        if lastTurnDir == 1 then want = VK_D elseif lastTurnDir == -1 then want = VK_A end
    end

    if want then
        if strafeKey ~= want then
            if strafeKey then rel(strafeKey) end
            press(want)
            strafeKey = want
        end
        -- only inject W if you aren't already holding it yourself
        if cfg("strafe_w") and not wInjected and not iskeypressed(VK_W) then
            press(VK_W)
            wInjected = true
        end
    else
        strafeRelease()
    end
    wait(0.016)
end)

end -- [section block]
----------------------------------------------------------------------
-- 11. bot esp (Drawing API + WorldToScreen), scanned by NAME
----------------------------------------------------------------------
local botList = {} -- { { m = model, root = part, name = "...", key = "Name#1" }, ... }

local function scanBots()
    local found, seen = {}, 0
    local filter = string.lower(tostring(cfg("esp_filter") or ""))
    local path = tostring(cfg("esp_path") or "")
    local lname = LocalPlayer.Name
    local names = {}
    for _, p in ipairs(Players:GetPlayers()) do names[p.Name] = true end
    local looseAll = cfg("esp_loose")
    local looseNow = false
    local counts, dupe = {}, {}

    local function consider(m)
        local nm = m.Name
        if nm == lname or names[nm] then return end -- player characters, matched by name
        if filter ~= "" then
            if not string.find(string.lower(nm), filter, 1, true) then return end
        elseif not (looseNow or looseAll or m:FindFirstChild("Humanoid") or m:FindFirstChild("HumanoidRootPart")
                or m:FindFirstChild("Hitbox")) then
            return
        end
        local hb = m:FindFirstChild("Hitbox")
        local r = (hb and isPartObj(hb)) and hb or rootOf(m)
        if not r then return end
        local okp, p = pcall(function() return r.Position end)
        if not okp or not p then return end
        local pk = nm .. "@" .. math.floor(p.X / 2) .. "," .. math.floor(p.Z / 2)
        if dupe[pk] then return end
        dupe[pk] = true
        counts[nm] = (counts[nm] or 0) + 1
        found[#found + 1] = { m = m, root = r, name = nm, key = nm .. "#" .. counts[nm] }
    end

    local function walk(parent, depth)
        for _, c in ipairs(parent:GetChildren()) do
            seen = seen + 1
            if seen > 800 then return end
            if seen % 150 == 0 then wait(0.01) end
            if isModelObj(c) then
                consider(c)
            elseif depth > 0 and not SKIP_BOTS[c.Name] then
                walk(c, depth - 1)
            end
        end
    end

    if path ~= "" then
        local base = resolvePath(path)
        if base then walk(base, 1) end
    else
        walk(workspace, 2)
    end

    -- bots usually live in the same container as player characters, so scan that folder loosely
    pcall(function()
        local mine = charOf(LocalPlayer)
        local sib = mine and mine.Parent
        if sib and sib.Name ~= workspace.Name then
            looseNow = true
            walk(sib, 0)
            looseNow = false
        end
    end)
    return found
end

loop("espscan", function()
    if (state.esp or state.farm or state.revive or (state.safe and cfg("sf_auto"))) and alive() then
        botList = scanBots()
    else
        botList = {}
    end
    wait(state.farm and 0.5 or 2.5)
end)

-- drawing slots are built once and re-used by index every frame
local warnText = nil
local function slot(i)
    local s = RUN.pool[i]
    if s then return s end
    local box = Drawing.new("Square"); set(box, "Filled", false); set(box, "Visible", false)
    local label = Drawing.new("Text"); set(label, "Center", true); set(label, "Outline", true); set(label, "Visible", false)
    local line = Drawing.new("Line"); set(line, "Visible", false)
    s = { box = box, label = label, line = line }
    RUN.pool[i] = s
    return s
end

local function hideFrom(n)
    for i = n, #RUN.pool do
        local s = RUN.pool[i]
        set(s.box, "Visible", false); set(s.label, "Visible", false); set(s.line, "Visible", false)
    end
end

local espLast, espHidden = 0, false
local track = {} -- [bot key] = { dist, t, closing } (string keys, so no instance comparison)

local function arrowSlot(i)
    local a = RUN.arrows[i]
    if a then return a end
    local line = Drawing.new("Line"); set(line, "Thickness", 3); set(line, "Visible", false)
    local label = Drawing.new("Text"); set(label, "Center", true); set(label, "Outline", true); set(label, "Visible", false)
    a = { line = line, label = label }
    RUN.arrows[i] = a
    return a
end

local function hideArrows(n)
    for i = n, #RUN.arrows do
        local a = RUN.arrows[i]
        set(a.line, "Visible", false); set(a.label, "Visible", false)
    end
end

local function espStep()
    if not (state.esp and active()) then
        if not espHidden then
            hideFrom(1)
            hideArrows(1)
            if warnText then set(warnText, "Visible", false) end
            espHidden = true
        end
        espInfo = "ESP: off"
        return
    end
    espHidden = false
    local t = os.clock()
    if t - espLast < 0.025 then return end
    espLast = t

    local cam = workspace.CurrentCamera
    local cf = cam.CFrame
    local camPos = cf.Position
    local look, right = cf.LookVector, cf.RightVector
    local vw, vh = 1920, 1080
    pcall(function() vw, vh = Library:_viewport() end)

    local half = cfg("esp_height") / 2
    local warn, maxd = cfg("esp_warn"), cfg("esp_maxdist")
    local col, warnCol = cfg("esp_col"), cfg("esp_warncol")
    local showBox, showName, showLine = cfg("esp_box"), cfg("esp_name"), cfg("esp_tracer")
    local showArrows, showEta = cfg("esp_arrows"), cfg("esp_eta")
    local used, arrows = 0, 0
    local nearest, nearestName = math.huge, nil
    local seenKeys = {}

    for _, b in ipairs(botList) do
        pcall(function()
            local pos = b.root.Position
            local dist = (camPos - pos).Magnitude
            if dist > maxd then return end
            if dist < nearest then nearest, nearestName = dist, b.name end

            -- closing speed (studs/s) from the change in distance between frames
            local now = os.clock()
            local tr = track[b.key]
            local eta = nil
            if tr then
                local dt = now - tr.t
                if dt > 0.02 then
                    tr.closing = tr.closing * 0.7 + ((tr.dist - dist) / dt) * 0.3
                    tr.dist, tr.t = dist, now
                end
                if tr.closing > 4 then eta = dist / tr.closing end
            else
                track[b.key] = { dist = dist, t = now, closing = 0 }
            end
            seenKeys[b.key] = true

            local threat = dist <= warn or (eta ~= nil and eta <= 4)
            local c = threat and warnCol or col
            local tail = ""
            if showEta and eta and eta < 15 then tail = string.format(" %.1fs", eta) end

            local ctr = project(pos)
            if ctr then
                local top = project(pos + Vector3.new(0, half, 0))
                local bot = project(pos - Vector3.new(0, half, 0))
                if top and bot then
                    used = used + 1
                    local s = slot(used)
                    local minY, maxY = math.min(top.Y, bot.Y), math.max(top.Y, bot.Y)
                    local h = math.max(maxY - minY, 4)
                    local w = h * 0.6

                    set(s.box, "Color", c)
                    set(s.box, "Position", Vector2.new(ctr.X - w / 2, minY))
                    set(s.box, "Size", Vector2.new(w, h))
                    set(s.box, "Visible", showBox)

                    set(s.label, "Text", b.name .. " [" .. math.floor(dist) .. "]" .. tail)
                    set(s.label, "Color", c)
                    setTextSize(s.label, 14)
                    set(s.label, "Position", Vector2.new(ctr.X, minY - 17))
                    set(s.label, "Visible", showName)

                    set(s.line, "Color", c)
                    set(s.line, "From", Vector2.new(vw / 2, vh))
                    set(s.line, "To", Vector2.new(ctr.X, maxY))
                    set(s.line, "Visible", showLine)
                end
            elseif showArrows and arrows < 6 then
                -- off-screen (to the side or behind you): an arrow at the screen edge points toward it
                local rel = pos - camPos
                local fwd = rel.X * look.X + rel.Y * look.Y + rel.Z * look.Z
                local side = rel.X * right.X + rel.Y * right.Y + rel.Z * right.Z
                local ang = math.atan2(side, fwd) -- 0 = straight ahead
                local dx, dy = math.sin(ang), -math.cos(ang)
                local cx, cy = vw / 2, vh / 2
                local small = math.min(vw, vh)
                local r1, r2 = small * 0.38, small * 0.45
                arrows = arrows + 1
                local ar = arrowSlot(arrows)
                set(ar.line, "From", Vector2.new(cx + dx * r1, cy + dy * r1))
                set(ar.line, "To", Vector2.new(cx + dx * r2, cy + dy * r2))
                set(ar.line, "Color", c)
                set(ar.line, "Visible", true)
                setTextSize(ar.label, 13)
                set(ar.label, "Text", b.name .. " [" .. math.floor(dist) .. "]" .. tail)
                set(ar.label, "Position", Vector2.new(cx + dx * (r2 + 16), cy + dy * (r2 + 16) - 6))
                set(ar.label, "Color", c)
                set(ar.label, "Visible", true)
            end
        end)
    end
    hideFrom(used + 1)
    hideArrows(arrows + 1)
    for k in pairs(track) do
        if not seenKeys[k] then track[k] = nil end
    end

    if cfg("esp_warn_text") then
        if not warnText then
            warnText = Drawing.new("Text")
            set(warnText, "Center", true)
            set(warnText, "Outline", true)
            setTextSize(warnText, 20)
        end
        if nearestName and nearest <= warn then
            set(warnText, "Text", "BOT NEAR: " .. nearestName .. " [" .. math.floor(nearest) .. "]")
            set(warnText, "Position", Vector2.new(vw / 2, 70))
            set(warnText, "Color", warnCol)
            set(warnText, "Visible", true)
        else
            set(warnText, "Visible", false)
        end
    elseif warnText then
        set(warnText, "Visible", false)
    end

    espInfo = string.format("ESP: %d bots, %d drawn, %d arrows, nearest %s", #botList, used, arrows,
        nearest < math.huge and tostring(math.floor(nearest)) or "-")
end

RUN.conn = RunService.Heartbeat:Connect(function()
    local ok, err = pcall(espStep)
    if not ok then lastErr = "esp: " .. tostring(err) end
end)

espTest = function()
    task.spawn(function()
        local vw, vh = 1920, 1080
        pcall(function() vw, vh = Library:_viewport() end)
        local sq = Drawing.new("Square")
        set(sq, "Filled", false)
        set(sq, "Thickness", 2)
        set(sq, "Position", Vector2.new(vw / 2 - 60, vh / 2 - 100))
        set(sq, "Size", Vector2.new(120, 200))
        set(sq, "Color", Color3.fromRGB(255, 40, 40))
        set(sq, "Visible", true)
        local tx = Drawing.new("Text")
        set(tx, "Center", true)
        set(tx, "Outline", true)
        setTextSize(tx, 18)
        set(tx, "Text", "ESP TEST")
        set(tx, "Position", Vector2.new(vw / 2, vh / 2 - 125))
        set(tx, "Color", Color3.fromRGB(255, 255, 255))
        set(tx, "Visible", true)
        wait(3)
        pcall(function() sq:Remove() end)
        pcall(function() tx:Remove() end)
    end)
end

----------------------------------------------------------------------
-- 12. teleport helper + safe spots
----------------------------------------------------------------------
local tpErr = nil
local function teleportTo(pos)
    local hrp = getChar()
    if not hrp then return false end
    local ok, err = pcall(function() hrp.CFrame = CFrame.new(pos) end)
    if not ok then ok, err = pcall(function() hrp.Position = pos end) end
    pcall(function() hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
    tpErr = (not ok) and tostring(err) or nil
    return ok
end

local function botPositions()
    local list = {}
    for _, b in ipairs(botList) do
        local ok, p = pcall(function() return b.root.Position end)
        if ok and p then list[#list + 1] = p end
    end
    return list
end

local function nearestOf(list, pos)
    local bestD = math.huge
    for i = 1, #list do
        local d = (list[i] - pos).Magnitude
        if d < bestD then bestD = d end
    end
    return bestD
end

local safeUntil = 0 -- farm / auto mode set this to hide temporarily
local safeReturn, wasSafe, safeIdx, weAnchored = nil, false, 1, false

local SKY_POSITION = Vector3.new(-7.570, 380.103, 86.898) -- from the old autofarm script
local function safeSpots(useSky)
    if useSky then return { SKY_POSITION } end
    local d, h = cfg("sf_dist"), cfg("sf_height")
    return {
        Vector3.new(d, h, d),
        Vector3.new(d + 120, h, d),
        Vector3.new(d + 120, h + 60, d + 120),
        Vector3.new(d, h + 60, d + 120),
    }
end

loop("safe", function()
    local autoMode = state.safe and cfg("sf_auto")
    if autoMode and tick() >= safeUntil and not wasSafe then
        -- armed: stay where you are, hide only when a bot gets close
        safeStatus = "safe: armed (waiting for a bot)"
        local hrp = getChar()
        if hrp then
            local bots = botPositions()
            if #bots > 0 then
                local okp, p = pcall(function() return hrp.Position end)
                if okp and p and nearestOf(bots, p) <= cfg("sf_auto_dist") then
                    safeUntil = tick() + cfg("sf_auto_hold")
                    say("bot close - hiding in the safe spots")
                end
            end
        end
    end
    local want = (state.safe and not cfg("sf_auto")) or tick() < safeUntil
    -- the farm hides at the old script's sky point (re-teleported every 0.1 s), unless you chose otherwise
    local useSky = cfg("sf_sky") or (state.farm and not state.safe and cfg("farm_sky"))
    if want and alive() then
        local hrp = getChar()
        if hrp then
            if not wasSafe then
                wasSafe, safeIdx = true, 1
                local okp, p = pcall(function() return hrp.Position end)
                if okp then safeReturn = p end
            end
            local spots = safeSpots(useSky)
            if safeIdx > #spots then safeIdx = 1 end
            teleportTo(spots[safeIdx])
            if cfg("sf_anchor") then
                if pcall(function() hrp.Anchored = true end) then weAnchored = true end
            end
            safeStatus = string.format("safe: spot %d/%d%s", safeIdx, #spots,
                tpErr and (" (teleport error: " .. tpErr .. ")") or "")
            safeIdx = safeIdx % #spots + 1
        end
        wait(useSky and 0.1 or cfg("sf_ms") / 1000)
    else
        if wasSafe then
            wasSafe = false
            local hrp = getChar()
            if hrp and weAnchored then pcall(function() hrp.Anchored = false end) end
            weAnchored = false
            if cfg("sf_return") and safeReturn then
                teleportTo(safeReturn + Vector3.new(0, 3, 0))
            end
            safeReturn = nil
            safeStatus = "safe: off"
        end
        if not state.safe and not wasSafe then safeStatus = "safe: off" end
        wait(autoMode and 0.15 or 0.1)
    end
end)

----------------------------------------------------------------------
-- 13. auto revive
----------------------------------------------------------------------
do -- [section block]: keeps this part's local variables from piling up (Lua limit: 200)
-- A teammate counts as downed when ANY enabled check matches:
--  attribute (names from the list) | any attribute containing "down"/"knock" | child value object | low health
local rvNames, rvNamesSrc = {}, nil
local function getRvNames()
    local s = tostring(cfg("rv_attr") or "")
    if s ~= rvNamesSrc then
        rvNamesSrc = s
        rvNames = splitList(s)
    end
    return rvNames
end

local function truthy(v) return v ~= nil and v ~= false and v ~= 0 and v ~= "" end

local function anyNamedAttr(obj, names)
    for _, n in ipairs(names) do
        local ok, v = pcall(function() return obj:GetAttribute(n) end)
        if ok and truthy(v) then return true end
    end
    return false
end

local function anyDownLikeAttr(obj)
    local found = false
    pcall(function()
        for k, v in pairs(obj:GetAttributes()) do
            -- Matcha returns either { name = value } or a plain list of attribute names
            local nm, val
            if type(k) == "number" and type(v) == "string" then
                nm = v
                val = obj:GetAttribute(v)
            else
                nm, val = tostring(k), v
            end
            local lk = string.lower(nm)
            if (string.find(lk, "down", 1, true) or string.find(lk, "knock", 1, true)) and truthy(val) then
                found = true
            end
        end
    end)
    return found
end

-- Names that suggest "this player is downed". A child with such a name only counts if YOUR own character does
-- not have it too (so generic components that every character carries never count as "downed").
local RV_KEYWORDS = { "down", "knock", "revive", "bleed", "incap" }
local myNames, myNamesAt = {}, 0

local function childNames(obj)
    local list = {}
    pcall(function()
        for i, c in ipairs(obj:GetChildren()) do
            if i > 40 then break end
            list[#list + 1] = c.Name
        end
    end)
    return list
end

local function refreshMyNames()
    local t = tick()
    if t - myNamesAt < 3 then return end
    myNamesAt = t
    local set = {}
    local hrp, ch = getChar()
    if ch then
        for _, n in ipairs(childNames(ch)) do set[n] = true end
        if hrp then
            for _, n in ipairs(childNames(hrp)) do set[n] = true end
        end
    end
    myNames = set
end

local function hasKeyword(name)
    local ln = string.lower(name)
    for _, kw in ipairs(RV_KEYWORDS) do
        if string.find(ln, kw, 1, true) then return true end
    end
    return false
end

local function childNameHit(char)
    refreshMyNames()
    local lists = { childNames(char) }
    local r = nil
    pcall(function() r = char:FindFirstChild("HumanoidRootPart") end)
    if r then lists[2] = childNames(r) end
    for _, list in ipairs(lists) do
        for _, n in ipairs(list) do
            if hasKeyword(n) and not myNames[n] then return n end
        end
    end
    return nil
end

-- returns true plus the REASON, so the status panel can say how someone was recognised as downed
local function isDowned(char, plr)
    local names = getRvNames()
    if cfg("rv_use_attr") then
        if anyNamedAttr(char, names) then return true, "attribute" end
        if plr and anyNamedAttr(plr, names) then return true, "player attribute" end
    end
    if cfg("rv_auto") then
        if anyDownLikeAttr(char) then return true, "down-like attribute" end
        if plr and anyDownLikeAttr(plr) then return true, "down-like player attribute" end
    end
    if cfg("rv_use_value") then
        for _, n in ipairs(names) do
            local ok, v = pcall(function()
                local c = char:FindFirstChild(n)
                return c and c.Value
            end)
            if ok and truthy(v) then return true, "value " .. n end
        end
    end
    if cfg("rv_use_names") then
        local hit = childNameHit(char)
        if hit then return true, "child " .. hit end
    end
    if cfg("rv_use_ragdoll") then
        local ok, v = pcall(function() return char:GetAttribute("Ragdolling") end)
        if ok and truthy(v) then return true, "ragdolling" end
    end
    if cfg("rv_use_health") then
        local ok, h = pcall(function() return char:FindFirstChild("Humanoid").Health end)
        if ok and h and h <= cfg("rv_hp") then return true, "low health" end
    end
    return false
end

local rvCool, rvHome = {}, nil -- per-player retry cooldown / where to go back to after a teleport revive

-- returns character, distance, player name (players matched by NAME, characters found even if .Character is nil)
local rvScanned, rvMaxScan = 0, 0
local rvFarAt, rvFarText = 0, ""

local function nearestPlayer(onlyDowned)
    local myRoot = getChar()
    if not myRoot then return nil end
    local myPos = myRoot.Position
    local myName = LocalPlayer.Name
    -- only players close enough to matter are checked (keeps this cheap)
    local maxScan = cfg("rv_range") + 6
    if cfg("rv_tp") then maxScan = math.max(maxScan, cfg("rv_tpmax")) end
    rvMaxScan, rvScanned = maxScan, 0
    local best, bestD, bestName, bestPlr, bestWhy = nil, math.huge, nil, nil, nil
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name ~= myName and (rvCool[p.Name] or 0) <= tick() then
            local ch = charOf(p)
            local r = ch and ch:FindFirstChild("HumanoidRootPart")
            if r then
                local d = (r.Position - myPos).Magnitude
                if d <= maxScan then
                    rvScanned = rvScanned + 1
                    if d < bestD then
                        local dn, why = true, nil
                        if onlyDowned then dn, why = isDowned(ch, p) end
                        if dn then best, bestD, bestName, bestPlr, bestWhy = ch, d, p.Name, p, why end
                    end
                end
            end
        end
    end
    return best, bestD, bestName, bestPlr, bestWhy
end

-- when nobody is downed close by: is somebody downed FAR away? (tells you whether detection works at all)
local function updateFarDowned()
    local t = tick()
    if t - rvFarAt < 1.5 then return end
    rvFarAt = t
    rvFarText = ""
    local myRoot = getChar()
    if not myRoot then return end
    local myPos = myRoot.Position
    local myName = LocalPlayer.Name
    local bestD, bestName, bestWhy = math.huge, nil, nil
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name ~= myName then
            local ch = charOf(p)
            local r = ch and ch:FindFirstChild("HumanoidRootPart")
            if r then
                local d = (r.Position - myPos).Magnitude
                if d < bestD then
                    local dn, why = isDowned(ch, p)
                    if dn then bestD, bestName, bestWhy = d, p.Name, why end
                end
            end
        end
    end
    if bestName then
        rvFarText = string.format("%s is downed (%s), %.0f studs away", bestName, tostring(bestWhy), bestD)
    end
end

loop("revive", function()
    if not (state.revive and active()) then
        rvStatus = "revive: off"
        wait(0.1)
        return
    end
    if dashBusy then
        wait(0.05)
        return
    end

    local ch, d, name, plr, why = nearestPlayer(true)
    if not ch then
        if rvHome then -- the teammate is up (or gone): go back where we were
            if cfg("rv_return") then teleportTo(rvHome + Vector3.new(0, 3, 0)) end
            rvHome = nil
        end
        if cfg("rv_blind") then
            local bch, bd, bname = nearestPlayer(false)
            if bch and bd <= cfg("rv_range") then
                rvStatus = "revive: blind press near " .. tostring(bname)
                local vk = rvKeyCode()
                press(vk)
                wait(0.35)
                rel(vk)
                wait(0.15)
                return
            end
        end
        updateFarDowned()
        if rvFarText ~= "" then
            rvStatus = "revive: " .. rvFarText .. " - get closer or turn on teleport"
        else
            rvStatus = string.format("revive: nobody downed (checked %d players within %d studs)", rvScanned, rvMaxScan)
        end
        wait(0.4)
        return
    end

    -- don't walk into a bot to revive someone
    if cfg("rv_botclear") > 0 then
        local rr = ch:FindFirstChild("HumanoidRootPart")
        local okd, dpos = pcall(function() return rr.Position end)
        if okd and dpos then
            local bots = botPositions()
            if #bots > 0 and nearestOf(bots, dpos) <= cfg("rv_botclear") then
                rvCool[name] = tick() + cfg("rv_cooldown")
                rvStatus = "revive: bot near " .. name .. ", skipping"
                wait(0.4)
                return
            end
        end
    end

    if d > cfg("rv_range") then
        if cfg("rv_tp") and d <= cfg("rv_tpmax") then
            local r = ch:FindFirstChild("HumanoidRootPart")
            if r then
                if not rvHome then
                    local me = getChar()
                    if me then
                        local okh, hp = pcall(function() return me.Position end)
                        if okh then rvHome = hp end
                    end
                end
                teleportTo(r.Position + Vector3.new(0, 0, 3))
                rvStatus = "revive: teleported to " .. name
                wait(0.15)
                return
            end
        end
        rvStatus = string.format("revive: %s downed, %.0f studs away (range %d)", name, d, cfg("rv_range"))
        wait(0.1)
        return
    end

    -- in range: hold the revive key until they're up, out of range, timed out, or turned off
    local vk = rvKeyCode()
    local start = tick()
    local reason = "done"
    rvStatus = "revive: reviving " .. name .. " (" .. tostring(why) .. ")"
    press(vk)
    local okRv, errRv = pcall(function()
        while true do
            wait(0.1)
            if not (state.revive and active()) then
                reason = "stopped"
                break
            end
            if tick() - start > cfg("rv_maxhold") / 1000 then
                reason = "timeout"
                break
            end
            if not isDowned(ch, plr) then
                break
            end
            local myRoot = getChar()
            local r = ch:FindFirstChild("HumanoidRootPart")
            if not myRoot or not r or (r.Position - myRoot.Position).Magnitude > cfg("rv_range") + 3 then
                reason = "out of range"
                break
            end
        end
    end)
    rel(vk) -- always released, even if something above errored
    if not okRv then lastErr = "revive: " .. tostring(errRv) end
    if reason == "timeout" or reason == "out of range" then
        rvCool[name] = tick() + cfg("rv_cooldown")
    end
    rvStatus = "revive: " .. reason .. " (" .. name .. ")"
    if rvHome then
        if cfg("rv_return") then teleportTo(rvHome + Vector3.new(0, 3, 0)) end
        rvHome = nil
    end
    wait(0.3)
end)

----------------------------------------------------------------------
-- 14. event autofarm (teleports onto matching items)
----------------------------------------------------------------------
-- Item positions are read once per scan (not every tick) to keep CPU use low.
local farmItems, farmScanned = {}, 0 -- { { inst, name, pos, key }, ... }
local farmVisited = {}
local farmCount, farmPrune = 0, tick()

local function itemPos(inst)
    local ok, p = pcall(function()
        if isPartObj(inst) then return inst.Position end
        local r = rootOf(inst)
        return r and r.Position
    end)
    if ok then return p end
end

-- The old autofarm script collected from workspace.Game.Effects.Tickets. Newer Evade keeps Effects at the
-- top level, so both are tried. Everything in that folder is a collectible (no name matching needed).
local TICKET_PATHS = { "Game.Effects.Tickets", "Effects.Tickets" }
local farmSource = "name search"

local function findTicketFolder()
    local custom = tostring(cfg("farm_path") or "")
    if custom ~= "" then
        return resolvePath(custom), custom, true
    end
    for _, p in ipairs(TICKET_PATHS) do
        local f = resolvePath(p)
        if f then return f, p, false end
    end
    return nil
end

local function scanItems()
    local found, seen = {}, 0

    local folder, fpath, custom = findTicketFolder()
    if folder then
        for _, c in ipairs(folder:GetChildren()) do
            seen = seen + 1
            local cls = classOf(c)
            if PART_CLASSES[cls] or cls == "Model" then
                local p = itemPos(c)
                if p then
                    found[#found + 1] = {
                        inst = c, name = c.Name, pos = p,
                        key = string.format("%s@%d,%d,%d", c.Name, math.floor(p.X), math.floor(p.Y), math.floor(p.Z)),
                    }
                end
            end
        end
        if #found > 0 or custom then
            farmSource = fpath
            return found, seen
        end
    end
    farmSource = "name search"

    local kws = {}
    for _, w in ipairs(splitList(cfg("farm_keys"))) do kws[#kws + 1] = string.lower(w) end
    if #kws == 0 then return found, 0 end

    local base = workspace
    local path = tostring(cfg("farm_path") or "")
    if path ~= "" then base = resolvePath(path) end
    if not base then return found, 0 end

    local function matches(name)
        local ln = string.lower(name)
        for _, kw in ipairs(kws) do
            if string.find(ln, kw, 1, true) then return true end
        end
        return false
    end

    local function walk(parent, depth)
        for _, c in ipairs(parent:GetChildren()) do
            seen = seen + 1
            if seen > 4500 then return end
            if seen % 150 == 0 then wait(0.01) end
            local cls = classOf(c)
            local isPart = PART_CLASSES[cls] == true
            local isModel = cls == "Model"
            if (isPart or isModel) and matches(c.Name) then
                local p = itemPos(c)
                if p then
                    found[#found + 1] = {
                        inst = c, name = c.Name, pos = p,
                        key = string.format("%s@%d,%d,%d", c.Name, math.floor(p.X), math.floor(p.Y), math.floor(p.Z)),
                    }
                end
            elseif depth > 0 and not isPart and not SKIP_ITEMS[c.Name] and not c:FindFirstChild("Humanoid") then
                walk(c, depth - 1)
            end
        end
    end
    walk(base, cfg("farm_depth"))
    return found, seen
end

loop("farmscan", function()
    if state.farm and alive() then
        farmItems, farmScanned = scanItems()
    else
        farmItems = {}
    end
    wait(3)
end)

loop("farm", function()
    if not (state.farm and alive()) then
        farmStatus = "farm: off"
        wait(0.3)
        return
    end
    if state.safe or tick() < safeUntil then
        farmStatus = "farm: paused (safe spots)"
        wait(0.2)
        return
    end
    local hrp = getChar()
    if not hrp then
        farmStatus = "farm: no character"
        wait(0.3)
        return
    end
    local myPos = hrp.Position
    local bots = botPositions()

    if cfg("farm_flee") and #bots > 0 then
        local bd = nearestOf(bots, myPos)
        if bd <= cfg("farm_flee_dist") then
            safeUntil = tick() + cfg("farm_flee_hold")
            farmStatus = string.format("farm: bot %.0f studs away, hiding", bd)
            wait(0.2)
            return
        end
    end

    local now = tick()
    if now - farmPrune > 60 then -- forget old visited keys so the table never grows
        farmPrune = now
        for k, t0 in pairs(farmVisited) do
            if now - t0 > 120 then farmVisited[k] = nil end
        end
    end
    local revisit, clear = cfg("farm_revisit"), cfg("farm_botclear")
    local best, bestD = nil, math.huge
    for _, it in ipairs(farmItems) do
        local last = farmVisited[it.key]
        if not last or now - last > revisit then
            local d = (it.pos - myPos).Magnitude
            if d < bestD and (clear <= 0 or #bots == 0 or nearestOf(bots, it.pos) > clear) then
                best, bestD = it, d
            end
        end
    end

    if not best then
        farmStatus = string.format("farm: nothing to collect (%d matched, %d objects scanned)", #farmItems, farmScanned)
        wait(0.5)
        return
    end

    farmVisited[best.key] = now
    local p = itemPos(best.inst) -- fresh position; nil means it is already gone
    if not p then
        farmStatus = "farm: " .. best.name .. " already gone"
        wait(0.05)
        return
    end
    local here = p + Vector3.new(0, cfg("farm_yoff"), 0)
    teleportTo(here)
    farmStatus = string.format("farm: collecting %s (%d matched, %d collected) [%s]", best.name, #farmItems, farmCount, farmSource)
    if cfg("farm_waitgone") then
        -- stay until the item disappears (picked up), but never longer than the max stay;
        -- keep checking for bots every 0.1 s while standing here
        local t0 = tick()
        local lastCheck = t0
        local minStay, maxStay = cfg("farm_ms") / 1000, cfg("farm_maxstay") / 1000
        while state.farm and tick() - t0 < maxStay do
            wait(0.03)
            local nowT = tick()
            if cfg("farm_flee") and nowT - lastCheck >= 0.1 then
                lastCheck = nowT
                local bots2 = botPositions()
                if #bots2 > 0 and nearestOf(bots2, here) <= cfg("farm_flee_dist") then
                    safeUntil = nowT + cfg("farm_flee_hold")
                    break
                end
            end
            if nowT - t0 >= minStay and not itemPos(best.inst) then
                farmCount = farmCount + 1
                break
            end
        end
    else
        wait(cfg("farm_ms") / 1000)
    end
end)

----------------------------------------------------------------------
-- 15. full diagnostic: prints to the console AND saves evade_diag.txt
----------------------------------------------------------------------
local VALUE_CLASSES = { BoolValue = true, IntValue = true, NumberValue = true, StringValue = true,
    ObjectValue = true, Color3Value = true, Vector3Value = true, CFrameValue = true }

local function diagBody()
    local out = {}
    local function log(s)
        out[#out + 1] = s
        print(s)
    end

    log("==== Evade diagnostic (v2) ====")
    pcall(function()
        local n, v = identifyexecutor()
        log("Executor: " .. tostring(n) .. " " .. tostring(v))
    end)
    pcall(function() log("Game: " .. tostring(getgamename())) end)

    local pnames = {}
    for _, p in ipairs(Players:GetPlayers()) do pnames[p.Name] = true end

    log("---- my character ----")
    local rawChar = nil
    pcall(function() rawChar = LocalPlayer.Character end)
    log("LocalPlayer.Character is " .. (rawChar and "set" or "NIL"))
    local mine = charOf(LocalPlayer)
    if mine then
        pcall(function()
            local par = mine.Parent
            log("character model: " .. mine.Name .. " inside " .. par.Name .. " [" .. classOf(par) .. "]")
        end)
    else
        log("character model NOT found (you are probably in the lobby / not spawned in a round)")
    end

    log("---- workspace.Players (characters AND bots live here) ----")
    pcall(function()
        local folder = workspace:FindFirstChild("Players")
        if not folder then log("   no workspace.Players folder") return end
        for i, c in ipairs(folder:GetChildren()) do
            if i > 60 then break end
            local tag = pnames[c.Name] and "(player)" or "(NOT a player -> bot)"
            log(string.format("   %s [%s] humanoid=%s root=%s hitbox=%s %s", c.Name, classOf(c),
                tostring(c:FindFirstChild("Humanoid") ~= nil), tostring(c:FindFirstChild("HumanoidRootPart") ~= nil),
                tostring(c:FindFirstChild("Hitbox") ~= nil), tag))
        end
    end)

    log("---- players (attribute names=values / value objects / health / distance) ----")
    local myRoot = getChar()
    for _, p in ipairs(Players:GetPlayers()) do
        local ch = charOf(p)
        local line = p.Name .. (p.Name == LocalPlayer.Name and " (you)" or "")
        if ch then
            pcall(function()
                for k, v in pairs(ch:GetAttributes()) do
                    if type(k) == "number" and type(v) == "string" then
                        line = line .. " | @" .. v .. "=" .. tostring(ch:GetAttribute(v))
                    else
                        line = line .. " | @" .. tostring(k) .. "=" .. tostring(v)
                    end
                end
            end)
            pcall(function()
                for _, c in ipairs(ch:GetChildren()) do
                    if VALUE_CLASSES[classOf(c)] then line = line .. " | " .. c.Name .. "=" .. tostring(c.Value) end
                end
            end)
            pcall(function()
                local h = ch:FindFirstChild("Humanoid")
                if h then line = line .. " | health " .. tostring(h.Health) end
            end)
            pcall(function()
                local r = ch:FindFirstChild("HumanoidRootPart")
                if r and myRoot then
                    line = line .. string.format(" | %.0f studs", (r.Position - myRoot.Position).Magnitude)
                end
            end)
            line = line .. " | downed-check: " .. tostring(isDowned(ch, p))
        else
            line = line .. " | no character model found"
        end
        log(line)
    end
    log("(player-level attributes were left out on purpose; they are just game flags)")

    log("---- anything whose name contains: " .. tostring(cfg("farm_keys")) .. " / wisp / candy / pumpkin / orb ----")
    local kws = { "wisp", "candy", "pumpkin", "orb" }
    for _, w in ipairs(splitList(cfg("farm_keys"))) do kws[#kws + 1] = string.lower(w) end
    local hits, seenH = 0, 0
    local function walkHunt(parent, depth, path)
        for _, c in ipairs(parent:GetChildren()) do
            seenH = seenH + 1
            if seenH > 30000 or hits >= 50 then return end
            if seenH % 200 == 0 then wait(0.01) end
            local ln = string.lower(c.Name)
            for _, kw in ipairs(kws) do
                if string.find(ln, kw, 1, true) then
                    hits = hits + 1
                    log("   " .. path .. "." .. c.Name .. " [" .. classOf(c) .. "]")
                    break
                end
            end
            if depth > 0 and not isPartObj(c) and c.Name ~= "PlayerCache" and c.Name ~= "Rigs" then
                walkHunt(c, depth - 1, path .. "." .. c.Name)
            end
        end
    end
    walkHunt(workspace, 8, "workspace")
    log("scanned " .. seenH .. " objects, " .. hits .. " hits" .. (hits == 0 and " (none exist right now - run this again while wisps are on the map)" or ""))

    log("---- most repeated names in the map (event items are usually here) ----")
    local counts, seen2 = {}, 0
    local function walkCount(parent, depth)
        for _, c in ipairs(parent:GetChildren()) do
            seen2 = seen2 + 1
            if seen2 > 20000 then return end
            if seen2 % 200 == 0 then wait(0.01) end
            local cls = classOf(c)
            if PART_CLASSES[cls] or cls == "Model" then
                counts[c.Name] = (counts[c.Name] or 0) + 1
            end
            if depth > 0 and not PART_CLASSES[cls] and c.Name ~= "PlayerCache" and c.Name ~= "Rigs" and c.Name ~= "Players" then
                walkCount(c, depth - 1)
            end
        end
    end
    walkCount(workspace, 6)
    local arr = {}
    for n, k in pairs(counts) do
        if k >= 3 then arr[#arr + 1] = { n = n, k = k } end
    end
    table.sort(arr, function(a, b) return a.k > b.k end)
    for i = 1, math.min(#arr, 40) do
        log(string.format("   %s x%d", arr[i].n, arr[i].k))
    end
    log("scanned " .. seen2 .. " objects")

    log("---- farm: items matching '" .. tostring(cfg("farm_keys")) .. "' ----")
    local items, seen3 = scanItems()
    log("scanned " .. seen3 .. " objects, matched " .. #items)
    for i, it in ipairs(items) do
        if i > 25 then
            log("... (more not shown)")
            break
        end
        local p = it.pos
        log("   " .. it.name .. " [" .. classOf(it.inst) .. "]" ..
            (p and string.format(" at %.0f, %.0f, %.0f", p.X, p.Y, p.Z) or ""))
    end

    log("---- what the bot ESP would track right now ----")
    local okb, bl = pcall(scanBots)
    if okb then
        log("scanBots found " .. #bl .. " bots")
        for i, b in ipairs(bl) do
            if i > 20 then break end
            log("   " .. b.name)
        end
    else
        log("scanBots error: " .. tostring(bl))
    end

    log("---- ticket folders (the old farm script used Game.Effects.Tickets) ----")
    for _, tp in ipairs(TICKET_PATHS) do
        local f = resolvePath(tp)
        if f then
            local kids = f:GetChildren()
            log("   " .. tp .. ": " .. #kids .. " children")
            for i, c in ipairs(kids) do
                if i > 15 then break end
                local pos = itemPos(c)
                log("      " .. c.Name .. " [" .. classOf(c) .. "]" ..
                    (pos and string.format(" at %.0f, %.0f, %.0f", pos.X, pos.Y, pos.Z) or ""))
            end
        else
            log("   " .. tp .. ": not found")
        end
    end
    log("   farm would use: " .. farmSource)

    log("---- Effects / StreamFoci children ----")
    for _, fname in ipairs({ "Effects", "StreamFoci" }) do
        local f = workspace:FindFirstChild(fname)
        if f then
            log("   " .. fname .. ":")
            for i, c in ipairs(f:GetChildren()) do
                if i > 20 then break end
                log("      " .. c.Name .. " [" .. classOf(c) .. "]")
            end
        end
    end

    log("---- ItemSpawn objects (collectibles may spawn here) ----")
    local nSpawn, shownSp, seenSp = 0, 0, 0
    local function walkSp(parent, depth, path)
        for _, c in ipairs(parent:GetChildren()) do
            seenSp = seenSp + 1
            if seenSp > 20000 then return end
            if seenSp % 200 == 0 then wait(0.01) end
            if c.Name == "ItemSpawn" then
                nSpawn = nSpawn + 1
                if shownSp < 6 then
                    shownSp = shownSp + 1
                    local kids = {}
                    pcall(function()
                        for i, k in ipairs(c:GetChildren()) do
                            if i > 8 then break end
                            kids[#kids + 1] = k.Name .. "[" .. classOf(k) .. "]"
                        end
                    end)
                    local p = itemPos(c)
                    log("   " .. path .. ".ItemSpawn [" .. classOf(c) .. "]" ..
                        (p and string.format(" at %.0f, %.0f, %.0f", p.X, p.Y, p.Z) or "") ..
                        " children: " .. (#kids > 0 and table.concat(kids, ", ") or "none"))
                end
            end
            local nm = c.Name
            if depth > 0 and not isPartObj(c) and nm ~= "PlayerCache" and nm ~= "Rigs" and nm ~= "Players" then
                walkSp(c, depth - 1, path .. "." .. nm)
            end
        end
    end
    walkSp(workspace, 6, "workspace")
    log("   total ItemSpawn objects: " .. nSpawn)

    log("---- workspace top level ----")
    for i, c in ipairs(workspace:GetChildren()) do
        if i > 80 then
            log("... (more not shown)")
            break
        end
        local n = 0
        pcall(function() n = #c:GetChildren() end)
        log("   " .. c.Name .. " [" .. classOf(c) .. "] (" .. n .. " children)")
    end

    pcall(function() writefile(DIAG_FILE, table.concat(out, "\n")) end)
    say("Diagnostic saved to " .. DIAG_FILE .. " (also in console)")
end

-- lists every part within a radius of you (stand right next to a wisp, then click the button):
-- this finds collectibles by position, so it works even if I don't know their name
local function nearBody()
    local out = {}
    local function log(s)
        out[#out + 1] = s
        print(s)
    end
    local hrp = getChar()
    if not hrp then
        log("no character found - spawn into a round first")
        pcall(function() writefile("evade_near.txt", table.concat(out, "\n")) end)
        return
    end
    local me = hrp.Position
    local radius = cfg("near_radius")
    log(string.format("==== parts within %d studs of you (at %.0f, %.0f, %.0f) ====", radius, me.X, me.Y, me.Z))

    local hits, seen = {}, 0
    local skip = { PlayerCache = true, Rigs = true, Players = true, Camera = true }
    local function walk(parent, depth, path)
        for _, c in ipairs(parent:GetChildren()) do
            seen = seen + 1
            if seen > 25000 then return end
            if seen % 200 == 0 then wait(0.01) end
            local nm = c.Name
            if not skip[nm] then
                if isPartObj(c) then
                    local ok, p = pcall(function() return c.Position end)
                    if ok and p then
                        local d = (p - me).Magnitude
                        if d <= radius then
                            local size = ""
                            pcall(function()
                                local s = c.Size
                                size = string.format(" size %.1f,%.1f,%.1f", s.X, s.Y, s.Z)
                            end)
                            hits[#hits + 1] = { d = d, text = string.format("%5.1f  %s.%s [%s]%s", d, path, nm, classOf(c), size) }
                        end
                    end
                elseif depth > 0 then
                    walk(c, depth - 1, path .. "." .. nm)
                end
            end
        end
    end
    walk(workspace, 9, "workspace")
    table.sort(hits, function(a, b) return a.d < b.d end)
    for i = 1, math.min(#hits, 60) do log(hits[i].text) end
    log("scanned " .. seen .. " objects, " .. #hits .. " parts in range" .. (#hits > 60 and " (nearest 60 shown)" or ""))
    pcall(function() writefile("evade_near.txt", table.concat(out, "\n")) end)
    say("Near-scan saved to evade_near.txt (also in console)")
end

runNear = function()
    task.spawn(nearBody)
    say("Scanning near you, takes a few seconds...")
end

runDiagnostic = function()
    task.spawn(diagBody)
    say("Diagnostic running, takes a few seconds...")
end

end -- [section block]
----------------------------------------------------------------------
-- 16. fullbright, watchdog, status
----------------------------------------------------------------------
do -- [section block]: keeps this part's local variables from piling up (Lua limit: 200)
-- Fullbright. Two parts:
--  1) real lighting writes (re-applied every frame because Evade keeps changing the lighting). Each property is
--     written separately and the first error text is shown in the status panel.
--  2) a screen overlay: a translucent white layer drawn over the game with the Drawing API. It is used because
--     Matcha refuses to write lighting properties in some builds (the status panel tells you).
local fbStatus = "fullbright: off"
local FB_WHITE = Color3.fromRGB(255, 255, 255)
local FB_PROPS = {
    { name = "Ambient", value = FB_WHITE },
    { name = "OutdoorAmbient", value = FB_WHITE },
    { name = "Brightness", value = 2 },
    { name = "ClockTime", value = 14 },
    { name = "FogStart", value = 100000 },
    { name = "FogEnd", value = 100000 },
    { name = "GlobalShadows", value = false },
}
local EFFECT_CLASSES = { BloomEffect = true, BlurEffect = true, ColorCorrectionEffect = true,
    SunRaysEffect = true, DepthOfFieldEffect = true }
local fbOrig, fbOn, fbFailed, fbFailCount = nil, false, {}, 0
local fbEffects, fbSeen, fbLastScan = {}, {}, 0
local fbOverlay, fbLastView, fbLastPct = nil, 0, -1

local function fbCapture()
    fbOrig = {}
    for _, p in ipairs(FB_PROPS) do
        local ok, v = pcall(function() return Lighting[p.name] end)
        if ok and v ~= nil then fbOrig[p.name] = v end
    end
end

local function fbRestore()
    if fbOrig then
        for name, v in pairs(fbOrig) do
            pcall(function() Lighting[name] = v end)
        end
    end
    for _, e in ipairs(fbEffects) do
        pcall(function() e.inst.Enabled = e.enabled end)
    end
    if fbOverlay then set(fbOverlay, "Visible", false) end
    fbOrig, fbEffects, fbSeen, fbFailed, fbFailCount = nil, {}, {}, {}, 0
    fbLastPct = -1
    fbOn = false
end

local function fbApply()
    if fbFailCount >= #FB_PROPS then return end -- every write was refused: stop trying
    for i = 1, #FB_PROPS do
        local p = FB_PROPS[i]
        if not fbFailed[p.name] then
            local v = p.value
            if p.name == "Brightness" then v = cfg("fb_bright") end
            local ok, err = pcall(function() Lighting[p.name] = v end)
            if not ok then
                fbFailed[p.name] = tostring(err or "write rejected")
                fbFailCount = fbFailCount + 1
            end
        end
    end
end

-- blur / bloom / color-correction effects darken or tint the screen: switch them off (and remember them)
local function fbScanEffects()
    local ok, kids = pcall(function() return Lighting:GetChildren() end)
    if ok then
        for _, c in ipairs(kids) do
            if EFFECT_CLASSES[classOf(c)] then
                local key = c.Name .. "|" .. classOf(c)
                if not fbSeen[key] then
                    fbSeen[key] = true
                    local okE, en = pcall(function() return c.Enabled end)
                    local was = true
                    if okE and en ~= nil then was = en end
                    fbEffects[#fbEffects + 1] = { inst = c, enabled = was }
                end
            end
        end
    end
    for _, e in ipairs(fbEffects) do
        pcall(function() e.inst.Enabled = false end)
    end
end

-- the translucent white layer over the game (strength = how opaque the white is)
local function fbOverlayStep()
    local pct = cfg("fb_overlay")
    if pct > 0 then
        if not fbOverlay then
            local sq = Drawing.new("Square")
            set(sq, "Filled", true)
            set(sq, "Color", FB_WHITE)
            set(sq, "ZIndex", 0)
            set(sq, "Position", Vector2.new(0, 0))
            set(sq, "Visible", false)
            fbOverlay = sq
        end
        local t = os.clock()
        if t - fbLastView > 0.5 then -- keep it covering the whole window if it is resized
            fbLastView = t
            local vw, vh = 1920, 1080
            pcall(function() vw, vh = Library:_viewport() end)
            set(fbOverlay, "Size", Vector2.new(vw, vh))
        end
        if pct ~= fbLastPct then
            fbLastPct = pct
            set(fbOverlay, "Transparency", math.clamp(pct, 0, 80) / 100)
            set(fbOverlay, "Visible", true)
        end
    elseif fbOverlay and fbLastPct ~= 0 then
        fbLastPct = 0
        set(fbOverlay, "Visible", false)
    end
end

local function fbStep()
    if not cfg("fullbright") then
        if fbOn then
            fbRestore()
            fbStatus = "fullbright: off"
        end
        return
    end
    if not fbOn then
        fbOn = true
        fbCapture()
    end
    fbApply()
    fbOverlayStep()
    local t = os.clock()
    if t - fbLastScan > 1 then
        fbLastScan = t
        fbScanEffects()
        local bad, firstErr = {}, nil
        for name, e in pairs(fbFailed) do
            bad[#bad + 1] = name
            firstErr = firstErr or e
        end
        local overlay = cfg("fb_overlay")
        if #bad >= #FB_PROPS then
            fbStatus = string.format("fullbright: lighting writes REFUSED (%s) - screen overlay %d%%",
                string.sub(tostring(firstErr), 1, 70), overlay)
        else
            fbStatus = string.format("fullbright: ON, %d/%d lighting props ok%s, overlay %d%%",
                #FB_PROPS - #bad, #FB_PROPS,
                #bad > 0 and (" (refused: " .. table.concat(bad, ", ") .. ")") or "", overlay)
        end
    end
end

RUN.fbConns = {}
local function fbConnect(signal)
    local ok, c = pcall(function()
        return signal:Connect(function()
            local okk, err = pcall(fbStep)
            if not okk then lastErr = "fullbright: " .. tostring(err) end
        end)
    end)
    if ok and c then RUN.fbConns[#RUN.fbConns + 1] = c end
end
fbConnect(RunService.RenderStepped)
fbConnect(RunService.Heartbeat)

-- called by stop(): disconnect, restore the lighting, remove the overlay
RUN.fbShutdown = function()
    for _, c in ipairs(RUN.fbConns or {}) do pcall(function() c:Disconnect() end) end
    pcall(fbRestore)
    if fbOverlay then pcall(function() fbOverlay:Remove() end); fbOverlay = nil end
end

-- when Roblox loses focus / closes, release every key we might hold
local wasActive = true
loop("watchdog", function()
    local a = active()
    if wasActive and not a then releaseAll() end
    wasActive = a
    wait(0.1)
end)

local lastStatus = {}
loop("status", function()
    local function yn(b) return b and "yes" or "NO" end
    local t = {}
    local en = {}
    for _, k in ipairs({ "dash", "bhop", "strafe", "revive", "farm", "safe", "esp" }) do
        if cfg(EN[k]) == true then en[#en + 1] = k end
    end
    t[1] = string.format("enabled: %s | focused: %s | character: %s | airborne: %s | speed: %.0f",
        #en > 0 and table.concat(en, ",") or "none", yn(active()), yn(getChar() ~= nil), yn(airborne), speed)
    local ago = seqTime and string.format("%.0fs ago", tick() - seqTime) or "never"
    t[2] = string.format("emote runs: %d (%s) | last dash peak: %.0f", seqCount, ago, dashPeak)
    t[3] = "last error: " .. lastErr .. " | " .. fbStatus
    t[4] = espInfo
    t[5] = rvStatus
    t[6] = farmStatus .. " | " .. safeStatus
    for i = 1, 6 do
        if lastStatus[i] ~= t[i] then
            lastStatus[i] = t[i]
            pcall(function() statusLabels[i]:SetText(t[i]) end)
        end
    end
    wait(0.5)
end)

end -- [section block]
----------------------------------------------------------------------
-- 17. start / stop
----------------------------------------------------------------------
function RUN.stop()
    RUN.on = false
    if RUN.conn then pcall(function() RUN.conn:Disconnect() end); RUN.conn = nil end
    releaseAll()
    for _, s in ipairs(RUN.pool) do
        pcall(function() s.box:Remove() end)
        pcall(function() s.label:Remove() end)
        pcall(function() s.line:Remove() end)
    end
    RUN.pool = {}
    for _, ar in ipairs(RUN.arrows) do
        pcall(function() ar.line:Remove() end)
        pcall(function() ar.label:Remove() end)
    end
    RUN.arrows = {}
    if warnText then pcall(function() warnText:Remove() end); warnText = nil end
    if wasSafe then
        pcall(function()
            local hrp = getChar()
            if hrp and weAnchored then hrp.Anchored = false end
        end)
    end
    if RUN.fbShutdown then pcall(RUN.fbShutdown) end
end

Library:OnUnload(RUN.stop) -- unloading the menu also stops every loop and removes every drawing

-- older saved configs still hold the old guess for the item names: switch them to Wisp
task.spawn(function()
    wait(2)
    pcall(function()
        if cfg("farm_keys") == "Candy,Pumpkin,Halloween" then H.farm_keys:Set("Wisp") end
        if cfg("farm_maxstay") == 600 then H.farm_maxstay:Set(1500) end
        if cfg("farm_flee_dist") == 60 then H.farm_flee_dist:Set(50) end
    end)
end)

releaseAll() -- clears any keys left stuck by an older run
Library:Notify({ title = "evade", text = "loaded - RSHIFT opens the menu. Enable the features you want in the main tab.", duration = 5 })
