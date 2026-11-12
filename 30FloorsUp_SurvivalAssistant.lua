--[[
    30 Floors Up - Survival Assistant (client-side, Lua 5.1 / Luau compatible syntax)

    Built from the reference clip (29.6 s, portrait). What the footage actually shows:
      0:00-0:04  Apartment corridor; barred double gate at the far end with zombies behind it.
      0:04-0:09  News intro ("LIVE", "ADVISED TO REMAIN INDOORS", hint "Enter  Skip").
      0:09-0:11  Apartment interior (kitchen, fridge), another player's avatar.
      0:12-0:15  Pantry shelf. Holding a green can shows the game's own key-hint list:
                   [E] Store in pantry   [F] Eat a portion (hold)   [Q] Put away   [X] Drop
                 Subtitle: "...ding intercom: Attention all residents, thi... building manage- [static]"
      0:16-0:18  Zombies (green skin, white eyes) pressed against the gate. Hint text on the gate:
                 "Chained and padlocked fr... bolt cutters would do it". Held item still shows
                 [Q] Put away / [X] Drop. The gate gets a white outline when looked at.
      0:19-0:20  Peephole view: "Mouse / A-D to lean a little  .  Click or E to step back".
      0:21-0:23  NPC in an orange sweater at the open door. Subtitle:
                 "...1: Please, I know someone's in there. I just ... somewhere to wait. (muffled)"
      0:24-0:26  Wall vent with its louvred cover pulled off.
      0:27-0:29  Game page card: "30 FLOORS UP".

    IMPORTANT - limits of a video reference:
      * A video never shows Explorer instance names, RemoteEvents or CollectionService tags.
        Everything marked VERIFIED below is on-screen text or a key shown in the clip.
        Everything marked ASSUMED is a tunable default you should confirm in-game.
      * No hunger/status bar is visible in the clip (the HUD is cropped on the right edge;
        only "TAB", an objectives list and "Kit... / Damag..." are partly visible).
        The hunger reader therefore auto-discovers a source and can be overridden.
      * The game uses its own key-hint UI, so actions are driven by the same keys the
        player presses. Sending keys needs an environment that allows input simulation;
        without it the script still runs as an alert-only advisor.
]]

---------------------------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------------------------
local Config = {
    Enabled   = true,
    ToggleKey = Enum.KeyCode.RightControl, -- pause / resume everything
    Debug     = false,
    TapTime   = 0.08,                      -- seconds a normal key tap is held
    ShowOverlay = true,                    -- small status line (top-left)

    -- Key hints. `patterns` are matched against visible on-screen text (case-insensitive).
    -- `key` is the fallback if the key cap next to the text cannot be read.
    Hints = {
        -- VERIFIED (0:12) pantry shelf while holding a can
        Store    = { patterns = { "store in pantry" }, key = Enum.KeyCode.E },
        Eat      = { patterns = { "eat a portion" },   key = Enum.KeyCode.F },
        PutAway  = { patterns = { "put away" }, exact = true, key = Enum.KeyCode.Q },
        Drop     = { patterns = { "drop" },     exact = true, key = Enum.KeyCode.X },
        -- VERIFIED (0:19) peephole view
        StepBack = { patterns = { "to step back" }, key = Enum.KeyCode.E },
        -- VERIFIED (0:17) info text on the corridor gate (no key, used for alerts only)
        GateLocked = { patterns = { "chained and padlocked", "bolt cutters" } },
        -- VERIFIED (0:04) news intro
        SkipIntro = { patterns = { "skip", "enter skip" }, exact = true, key = Enum.KeyCode.Return },
        -- ASSUMED: wording of these prompts is not shown in the clip
        Pickup    = { patterns = { "pick up", "take", "grab" }, exact = true, key = Enum.KeyCode.E },
        DoorClose = { patterns = { "close door", "lock door", "barricade", "board up" }, key = Enum.KeyCode.E },
        DoorOpen  = { patterns = { "open door", "let in" }, key = Enum.KeyCode.E },
        Peephole  = { patterns = { "peephole", "look through" }, key = Enum.KeyCode.E },
    },

    Loot = {
        Enabled       = true,
        Interval      = 0.35,
        AutoStore     = true,   -- press [E] whenever "Store in pantry" is offered (0:12-0:15)
        StoreCooldown = 0.8,
        Radius        = 14,     -- studs; only items this close are considered
        WalkToLoot    = false,  -- Humanoid:MoveTo toward the nearest item
        PauseOnDanger = true,
        -- ASSUMED: the cans at 0:12-0:14 (green and yellow labels) are the only supplies shown;
        -- their instance names are not visible. Matched against prompt text and parent names.
        Keywords      = { "can", "canned", "food", "soup", "beans", "water" },
    },

    Hunger = {
        Enabled      = true,
        Interval     = 1.0,
        EatBelow     = 0.35,    -- eat when hunger fraction drops to this
        EatUntil     = 0.80,    -- stop once it is back above this
        EatHoldTime  = 1.6,     -- "(hold)" is printed next to [F] Eat a portion
        EatCooldown  = 1.0,
        MaxValue     = 100,     -- used when the source reports 0..100 instead of 0..1
        HigherIsHungrier = false,
        -- ASSUMED: no bar is visible in the clip. Names tried on attributes, value objects
        -- and GUI elements. Set Source to a function returning 0..1 to override discovery.
        Names        = { "hunger", "food", "satiety" },
        Source       = nil,
        FallbackInterval = 0,   -- seconds between timed meals if nothing is found (0 = off)
    },

    Doors = {
        Enabled     = true,
        Cooldown    = 1.5,
        KeepClosed  = true,     -- act on any visible "close/lock/barricade" hint
        Radius      = 12,
        -- ASSUMED keywords for ProximityPrompt-based doors, should the game use them
        CloseKeywords = { "close", "lock", "barricade", "board" },
        GateAlertCooldown = 30, -- "Chained and padlocked... bolt cutters would do it"
    },

    Threat = {
        Enabled      = true,
        Interval     = 0.3,
        TrackRadius  = 150,
        AlertRadius  = 60,      -- notify
        DangerRadius = 25,      -- notify + close doors (+ retreat if enabled)
        Reclassify   = 3,       -- seconds between appearance re-checks per NPC
        Highlight    = true,    -- outline zombies (the game outlines the gate the same way)
        AutoRetreat  = false,
        RetreatDistance = 30,
        -- VERIFIED appearance (0:16-0:18): green head and arms. ASSUMED: model names.
        NameKeywords = { "zombie", "infected" },
        GreenRatio   = 1.3,     -- G must exceed R and B by this factor
        GreenMin     = 0.22,
    },

    Knock = {
        Enabled   = true,
        Cooldown  = 20,
        -- VERIFIED subtitle fragments (0:21-0:23)
        Phrases   = { "i know someone's in there", "somewhere to wait" },
        VisitorRadius = 30,     -- nearest non-zombie NPC inside this is treated as the visitor
        ZombieUnsafeRadius = 70,-- any zombie this close makes the visit unsafe
        AutoPeephole  = true,   -- use the peephole if a matching hint/prompt is offered
        PeepholeLookTime = 2.0,
        AutoStepBack  = true,   -- press [E] on "Click or E to step back"
        AutoOpenIfSafe = false, -- never opens the door unless you turn this on
    },

    Subtitles = {
        IntercomPhrases = { "intercom:" }, -- VERIFIED (0:12) building intercom broadcast
        Cooldown = 30,
    },

    AutoSkipIntro = false,

    -- Optional CollectionService tags. Tags cannot be seen in a video, so these are empty;
    -- fill them in if you know the game's tags and they will be used instead of heuristics.
    Tags = { Zombie = {}, Loot = {} },
}

---------------------------------------------------------------------------------------
-- SERVICES
---------------------------------------------------------------------------------------
local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local StarterGui        = game:GetService("StarterGui")
local UserInputService  = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local VIM = nil
pcall(function() VIM = game:GetService("VirtualInputManager") end)

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

-- Stop a previous copy before starting a new one.
if _G.FloorsUpAssistant and type(_G.FloorsUpAssistant.Stop) == "function" then
    pcall(_G.FloorsUpAssistant.Stop)
end

---------------------------------------------------------------------------------------
-- SMALL HELPERS
---------------------------------------------------------------------------------------
local running = true
local conns = {}
local function track(conn)
    conns[#conns + 1] = conn
    return conn
end

local function normalize(text)
    local s = string.lower(text or "")
    s = string.gsub(s, "%s+", " ")
    s = string.gsub(s, "^ ", "")
    s = string.gsub(s, " $", "")
    return s
end

local function containsAny(lowerText, list)
    for _, word in ipairs(list) do
        if string.find(lowerText, string.lower(word), 1, true) then
            return true
        end
    end
    return false
end

local function dprint(...)
    if Config.Debug then
        print("[30FU]", ...)
    end
end

local function getRoot()
    local char = LocalPlayer.Character
    if not char then return nil, nil end
    return char:FindFirstChild("HumanoidRootPart"), char:FindFirstChildOfClass("Humanoid")
end

-- Overlay + notifications (the "alerting" part of threat detection).
local overlay, statusLabel = nil, nil
if Config.ShowOverlay then
    overlay = Instance.new("ScreenGui")
    overlay.Name = "FUA_Overlay"
    overlay.ResetOnSpawn = false
    overlay.DisplayOrder = 50
    statusLabel = Instance.new("TextLabel")
    statusLabel.Name = "Status"
    statusLabel.Size = UDim2.new(0, 420, 0, 20)
    statusLabel.Position = UDim2.new(0, 8, 0, 8)
    statusLabel.BackgroundColor3 = Color3.new(0, 0, 0)
    statusLabel.BackgroundTransparency = 0.45
    statusLabel.TextColor3 = Color3.fromRGB(120, 255, 170)
    statusLabel.Font = Enum.Font.Code
    statusLabel.TextSize = 13
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.Text = " 30FU assistant starting..."
    statusLabel.Parent = overlay
    overlay.Parent = PlayerGui
end

local lastNotify = {}
local function notify(key, title, text, cooldown)
    local now = os.clock()
    if lastNotify[key] and now - lastNotify[key] < (cooldown or 5) then
        return
    end
    lastNotify[key] = now
    dprint(title, text)
    pcall(function()
        StarterGui:SetCore("SendNotification", { Title = title, Text = text, Duration = 5 })
    end)
end

---------------------------------------------------------------------------------------
-- INPUT: the clip shows every action bound to a keyboard key (E / F / Q / X / Enter),
-- so the assistant presses those same keys.
---------------------------------------------------------------------------------------
local VK = {}
do
    local letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    for i = 1, #letters do
        local ch = string.sub(letters, i, i)
        VK[Enum.KeyCode[ch]] = string.byte(ch)
    end
    VK[Enum.KeyCode.Return] = 0x0D
    VK[Enum.KeyCode.Tab] = 0x09
    VK[Enum.KeyCode.Space] = 0x20
end

local inputAvailable = true
local keyBusy = false

local function sendKey(keyCode, down)
    if VIM then
        local ok = pcall(function()
            VIM:SendKeyEvent(down, keyCode, false, game)
        end)
        if ok then return true end
    end
    local fn = nil
    if down then fn = keypress else fn = keyrelease end -- only defined in some environments
    if fn and VK[keyCode] then
        local ok = pcall(fn, VK[keyCode])
        if ok then return true end
    end
    return false
end

local function pressKey(keyCode, holdTime)
    if not inputAvailable or keyBusy or not keyCode then return false end
    if UserInputService:GetFocusedTextBox() then return false end -- never type into chat
    keyBusy = true
    local ok = sendKey(keyCode, true)
    if ok then
        task.wait(holdTime or Config.TapTime)
        sendKey(keyCode, false)
    else
        inputAvailable = false
        notify("noinput", "30FU assistant", "Key simulation unavailable - running in alert-only mode.", 600)
    end
    keyBusy = false
    return ok
end

---------------------------------------------------------------------------------------
-- UI TEXT CACHE
-- Every TextLabel/TextButton in PlayerGui is indexed once and re-classified only when its
-- text changes, so hint look-ups never rescan the GUI tree.
---------------------------------------------------------------------------------------
local hintLabels = {} -- hintId -> { [label] = true }
local labelConns = {} -- label -> RBXScriptConnection
local hintNorm   = {} -- hintId -> normalized patterns
for id, def in pairs(Config.Hints) do
    hintLabels[id] = {}
    hintNorm[id] = {}
    for i, pat in ipairs(def.patterns) do
        hintNorm[id][i] = normalize(pat)
    end
end

local KEY_NAMES = { ENTER = Enum.KeyCode.Return, TAB = Enum.KeyCode.Tab, SPACE = Enum.KeyCode.Space }
for keyCode, byte in pairs(VK) do
    if byte >= 65 and byte <= 90 then
        KEY_NAMES[string.char(byte)] = keyCode
    end
end

local function labelText(label)
    local ok, content = pcall(function() return label.ContentText end) -- strips RichText tags
    if ok and content and content ~= "" then
        return content
    end
    return label.Text
end

local function isShown(gui)
    if gui.TextTransparency >= 0.95 then return false end
    local node = gui
    while node and node ~= PlayerGui do
        if node:IsA("GuiObject") then
            if not node.Visible then return false end
            if node:IsA("CanvasGroup") and node.GroupTransparency >= 0.95 then return false end
        elseif node:IsA("ScreenGui") then
            if not node.Enabled then return false end
        end
        node = node.Parent
    end
    return node == PlayerGui
end

local onSubtitle -- defined in the NPC section

local function classifyLabel(label)
    local norm = normalize(labelText(label))
    for id, def in pairs(Config.Hints) do
        local hit = false
        for _, pat in ipairs(hintNorm[id]) do
            if not hit then
                if def.exact then
                    hit = (norm == pat)
                else
                    hit = string.find(norm, pat, 1, true) ~= nil
                end
            end
        end
        if hit then
            hintLabels[id][label] = true
        else
            hintLabels[id][label] = nil
        end
    end
    if onSubtitle and norm ~= "" then
        onSubtitle(norm)
    end
end

local function onGuiAdded(inst)
    if (inst:IsA("TextLabel") or inst:IsA("TextButton")) and not labelConns[inst] then
        if not (overlay and inst:IsDescendantOf(overlay)) then
            labelConns[inst] = inst:GetPropertyChangedSignal("Text"):Connect(function()
                classifyLabel(inst)
            end)
            classifyLabel(inst)
        end
    end
end

local function onGuiRemoving(inst)
    local conn = labelConns[inst]
    if conn then
        conn:Disconnect()
        labelConns[inst] = nil
        for id in pairs(hintLabels) do
            hintLabels[id][inst] = nil
        end
    end
end

-- Returns a visible label for the hint, or nil.
local function findHint(id)
    local set = hintLabels[id]
    if not set then return nil end
    for label in pairs(set) do
        if label.Parent and isShown(label) then
            return label
        end
    end
    return nil
end

-- The hint rows at 0:12 are "[key cap] action text". Read the cap from the same row;
-- if the row holds zero or several caps, fall back to the key in Config.
local function keyForHint(id, label)
    local found, count = nil, 0
    local row = label.Parent
    if row and row ~= PlayerGui and not row:IsA("ScreenGui") then
        for _, d in ipairs(row:GetDescendants()) do
            if d ~= label and d:IsA("TextLabel") then
                local kc = KEY_NAMES[string.upper(normalize(d.Text))]
                if kc and kc ~= found then
                    found = kc
                    count = count + 1
                end
            end
        end
    end
    if count == 1 then
        return found
    end
    return Config.Hints[id].key
end

local function pressHint(id, holdTime)
    local label = findHint(id)
    if not label then return false end
    return pressKey(keyForHint(id, label), holdTime)
end

---------------------------------------------------------------------------------------
-- WORLD CACHE
-- One yielding pass over Workspace at start, then DescendantAdded/Removing keep the
-- prompt and NPC tables current. CollectionService tags are used when configured.
---------------------------------------------------------------------------------------
local prompts = {}      -- ProximityPrompt -> true
local npcs = {}         -- Model -> { hum, kind, nextCheck, hl }
local taggedZombie = {} -- Instance -> true
local taggedLoot = {}   -- Instance -> true

local function onWorldAdded(inst)
    if inst:IsA("ProximityPrompt") then
        prompts[inst] = true
    elseif inst:IsA("Humanoid") then
        local model = inst.Parent
        if model and model:IsA("Model") and model ~= LocalPlayer.Character then
            npcs[model] = { hum = inst, kind = nil, nextCheck = 0, hl = nil }
        end
    end
end

local function onWorldRemoving(inst)
    if prompts[inst] then
        prompts[inst] = nil
    elseif inst:IsA("Humanoid") and inst.Parent then
        local rec = npcs[inst.Parent]
        if rec then
            if rec.hl then rec.hl:Destroy() end
            npcs[inst.Parent] = nil
        end
    end
end

local function bindTags(list, store)
    for _, tag in ipairs(list) do
        for _, inst in ipairs(CollectionService:GetTagged(tag)) do
            store[inst] = true
        end
        track(CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst)
            store[inst] = true
        end))
        track(CollectionService:GetInstanceRemovedSignal(tag):Connect(function(inst)
            store[inst] = nil
        end))
    end
end

local function promptPosition(prompt)
    local p = prompt.Parent
    if not p then return nil end
    if p:IsA("BasePart") then return p.Position end
    if p:IsA("Attachment") then return p.WorldPosition end
    if p:IsA("Model") then return p:GetPivot().Position end
    return nil
end

local function promptText(prompt)
    local parentName = ""
    local p = prompt.Parent
    if p then
        parentName = p.Name
        if p.Parent then parentName = parentName .. " " .. p.Parent.Name end
    end
    return string.lower(prompt.ActionText .. " " .. prompt.ObjectText .. " " .. prompt.Name .. " " .. parentName)
end

local function triggerPrompt(prompt)
    if fireproximityprompt then -- only defined in some environments
        local ok = pcall(fireproximityprompt, prompt)
        if ok then return true end
    end
    return pressKey(prompt.KeyboardKeyCode, prompt.HoldDuration + Config.TapTime)
end

-- Nearest enabled prompt within `radius` whose text matches `keywords`.
local function nearestPrompt(rootPos, radius, keywords, tagStore)
    local best, bestDist = nil, radius
    for prompt in pairs(prompts) do
        if prompt.Parent and prompt.Enabled then
            local pos = promptPosition(prompt)
            if pos then
                local d = (pos - rootPos).Magnitude
                if d <= bestDist then
                    local tagged = false
                    if tagStore then
                        local p = prompt.Parent
                        tagged = tagStore[p] or (p.Parent and tagStore[p.Parent]) or false
                    end
                    if tagged or containsAny(promptText(prompt), keywords) then
                        best, bestDist = prompt, d
                    end
                end
            end
        end
    end
    return best, bestDist
end

---------------------------------------------------------------------------------------
-- THREAT DETECTION
-- 0:16-0:18: zombies have a green head and green arms. Human NPCs (0:21, orange sweater)
-- and players keep normal skin tones, so "green skin" is the visual discriminator.
---------------------------------------------------------------------------------------
local SKIN_ARMS = { "Left Arm", "Right Arm", "LeftUpperArm", "RightUpperArm", "LeftHand", "RightHand" }

local function isGreen(c)
    local T = Config.Threat
    return c.G >= T.GreenMin and c.G > c.R * T.GreenRatio and c.G > c.B * T.GreenRatio
end

local function classifyNpc(model, rec, now)
    if now < rec.nextCheck then
        return rec.kind
    end
    rec.nextCheck = now + Config.Threat.Reclassify
    local kind = "human"
    if taggedZombie[model] or containsAny(string.lower(model.Name), Config.Threat.NameKeywords) then
        kind = "zombie"
    else
        local head = model:FindFirstChild("Head")
        if head and head:IsA("BasePart") and isGreen(head.Color) then
            kind = "zombie"
        else
            local arms, green = 0, 0
            for _, name in ipairs(SKIN_ARMS) do
                local part = model:FindFirstChild(name)
                if part and part:IsA("BasePart") then
                    arms = arms + 1
                    if isGreen(part.Color) then green = green + 1 end
                end
            end
            if arms >= 2 and green == arms then
                kind = "zombie"
            end
        end
    end
    rec.kind = kind
    return kind
end

local threat = { level = "clear", count = 0, nearest = math.huge, nearestPos = nil,
                 visitor = nil, visitorDist = math.huge }

local function scanNpcs(rootPos)
    local now = os.clock()
    local T = Config.Threat
    local count, nearest, nearestPos = 0, math.huge, nil
    local visitor, visitorDist = nil, math.huge
    for model, rec in pairs(npcs) do
        if model.Parent == nil or rec.hum.Parent == nil or Players:GetPlayerFromCharacter(model) then
            if rec.hl then rec.hl:Destroy() end
            npcs[model] = nil
        elseif rec.hum.Health > 0 then
            local part = rec.hum.RootPart or model:FindFirstChild("Head")
            if part and part:IsA("BasePart") then
                local d = (part.Position - rootPos).Magnitude
                if d <= T.TrackRadius then
                    if classifyNpc(model, rec, now) == "zombie" then
                        count = count + 1
                        if d < nearest then
                            nearest, nearestPos = d, part.Position
                        end
                        if T.Highlight and not rec.hl then
                            local hl = Instance.new("Highlight")
                            hl.Name = "FUA_Threat"
                            hl.FillTransparency = 0.8
                            hl.FillColor = Color3.fromRGB(255, 60, 60)
                            hl.OutlineColor = Color3.fromRGB(255, 60, 60)
                            hl.Adornee = model
                            hl.Parent = model
                            rec.hl = hl
                        end
                    else
                        if rec.hl then
                            rec.hl:Destroy()
                            rec.hl = nil
                        end
                        if d < visitorDist then
                            visitor, visitorDist = model, d
                        end
                    end
                end
            end
        end
    end
    threat.count, threat.nearest, threat.nearestPos = count, nearest, nearestPos
    threat.visitor, threat.visitorDist = visitor, visitorDist
    if nearest <= T.DangerRadius then
        threat.level = "danger"
    elseif nearest <= T.AlertRadius then
        threat.level = "alert"
    else
        threat.level = "clear"
    end
end

---------------------------------------------------------------------------------------
-- DOORS / BARRICADES / GATE
-- The clip shows three barriers: the apartment door (0:21), the chained corridor gate
-- (0:16, cannot be operated without bolt cutters) and the wall vent (0:24). No "close"
-- prompt is visible, so closing relies on the ASSUMED hint/prompt wording in Config.
---------------------------------------------------------------------------------------
local lastDoorAction = 0

local function closeDoors(reason)
    local D = Config.Doors
    if not D.Enabled then return false end
    local now = os.clock()
    if now - lastDoorAction < D.Cooldown then return false end
    local done = pressHint("DoorClose")
    if not done then
        local root = getRoot()
        if root then
            local prompt = nearestPrompt(root.Position, D.Radius, D.CloseKeywords, nil)
            if prompt then
                done = triggerPrompt(prompt)
            end
        end
    end
    if done then
        lastDoorAction = now
        dprint("door closed:", reason)
    end
    return done
end

local function doorTick()
    -- 0:17 "Chained and padlocked fr... bolt cutters would do it": the gate is the barrier
    -- holding the zombies back, so just report its state instead of interacting.
    if findHint("GateLocked") then
        notify("gate", "Corridor gate", "Chained and padlocked - needs bolt cutters. Leave it shut.",
            Config.Doors.GateAlertCooldown)
    end
    if Config.Doors.KeepClosed and findHint("DoorClose") then
        closeDoors("keep closed")
    end
end

---------------------------------------------------------------------------------------
-- AUTO-LOOT (0:12-0:15)
-- Holding a can in front of the pantry shelf offers [E] Store in pantry. Picking the can
-- up is not shown, so pickup uses the ASSUMED hint wording or a nearby ProximityPrompt.
---------------------------------------------------------------------------------------
local lastStore = 0
local eating = false

local function lootTick()
    local L = Config.Loot
    if not L.Enabled or eating then return end
    if L.PauseOnDanger and threat.level == "danger" then return end
    local now = os.clock()

    if L.AutoStore and now - lastStore >= L.StoreCooldown and findHint("Store") then
        if pressHint("Store") then
            lastStore = now
            dprint("stored item in pantry")
        end
        return
    end

    if findHint("Pickup") then
        pressHint("Pickup")
        return
    end

    local root, hum = getRoot()
    if not root then return end
    local prompt = nearestPrompt(root.Position, L.Radius, L.Keywords, taggedLoot)
    if prompt then
        local pos = promptPosition(prompt)
        local dist = (pos - root.Position).Magnitude
        if dist <= prompt.MaxActivationDistance then
            triggerPrompt(prompt)
        elseif L.WalkToLoot and hum then
            hum:MoveTo(pos)
        end
    end
end

---------------------------------------------------------------------------------------
-- HUNGER (0:12: "[F] Eat a portion (hold)")
-- The eat action is VERIFIED; the meter it should react to is not visible in the clip,
-- so the source is discovered once and cached (attribute -> value object -> GUI element).
---------------------------------------------------------------------------------------
local hungerSource = nil
local nextDiscover = 0
local lastEat = 0
local lastMeal = os.clock()
local hungerNow = nil

local function readGuiValue(gui)
    if gui:IsA("TextLabel") then
        return tonumber(string.match(gui.Text, "%d+%.?%d*"))
    end
    local fill = gui:FindFirstChild("Fill") or gui:FindFirstChild("Bar") or gui:FindFirstChild("Progress")
    if fill and fill:IsA("GuiObject") then
        return fill.Size.X.Scale
    end
    return nil
end

local function discoverHunger()
    local names = Config.Hunger.Names
    local holders = { LocalPlayer }
    if LocalPlayer.Character then holders[2] = LocalPlayer.Character end
    for _, holder in ipairs(holders) do
        for attr, value in pairs(holder:GetAttributes()) do
            if type(value) == "number" and containsAny(string.lower(attr), names) then
                return { kind = "attr", holder = holder, name = attr }
            end
        end
    end
    local guiHit = nil
    for _, holder in ipairs(holders) do
        for _, d in ipairs(holder:GetDescendants()) do
            if containsAny(string.lower(d.Name), names) then
                if d:IsA("NumberValue") or d:IsA("IntValue") then
                    return { kind = "value", inst = d }
                elseif not guiHit and d:IsA("GuiObject") and readGuiValue(d) then
                    if not (overlay and d:IsDescendantOf(overlay)) then
                        guiHit = { kind = "gui", inst = d }
                    end
                end
            end
        end
    end
    return guiHit
end

local function readHunger()
    local H = Config.Hunger
    local raw = nil
    if type(H.Source) == "function" then
        local ok, v = pcall(H.Source)
        if ok then raw = tonumber(v) end
    else
        local now = os.clock()
        if hungerSource then
            local s = hungerSource
            if s.kind == "attr" then
                if s.holder.Parent then raw = s.holder:GetAttribute(s.name) end
            elseif s.inst.Parent then
                if s.kind == "value" then raw = s.inst.Value else raw = readGuiValue(s.inst) end
            end
            if type(raw) ~= "number" then
                raw = nil
                hungerSource = nil
            end
        elseif now >= nextDiscover then
            nextDiscover = now + 10
            hungerSource = discoverHunger()
            if hungerSource then dprint("hunger source:", hungerSource.kind) end
        end
    end
    if not raw then return nil end
    if raw > 1 then raw = raw / H.MaxValue end
    if H.HigherIsHungrier then raw = 1 - raw end
    return math.clamp(raw, 0, 1)
end

local function eatPortion()
    local H = Config.Hunger
    local now = os.clock()
    if now - lastEat < H.EatCooldown then return false end
    if not findHint("Eat") then
        notify("nofood", "Hungry", "Hold a food item to show [F] Eat a portion.", 30)
        return false
    end
    lastEat = now
    eating = true
    local ok = pressHint("Eat", H.EatHoldTime) -- held, because the hint says "(hold)"
    eating = false
    if ok then lastMeal = os.clock() end
    return ok
end

local hungry = false
local function hungerTick()
    local H = Config.Hunger
    if not H.Enabled then return end
    hungerNow = readHunger()
    if hungerNow then
        if hungerNow <= H.EatBelow then
            hungry = true
        elseif hungerNow >= H.EatUntil then
            hungry = false
        end
        if hungry then eatPortion() end
    elseif H.FallbackInterval > 0 and os.clock() - lastMeal >= H.FallbackInterval then
        if eatPortion() then lastMeal = os.clock() end
    end
end

---------------------------------------------------------------------------------------
-- NPC DOOR-KNOCK EVENT (0:19-0:23)
-- Sequence in the clip: peephole view of someone outside ("Mouse / A-D to lean a little .
-- Click or E to step back"), then the muffled plea "Please, I know someone's in there.
-- I just ... somewhere to wait." No dialogue choices are shown, so the assistant runs
-- safety checks and reports a verdict; opening the door stays opt-in.
---------------------------------------------------------------------------------------
local lastKnock = -math.huge
local knockBusy = false

local function assessVisitor()
    local K = Config.Knock
    if threat.nearest <= K.ZombieUnsafeRadius then
        return false, "zombie " .. math.floor(threat.nearest) .. " studs away"
    end
    local visitor = threat.visitor
    if not visitor or threat.visitorDist > K.VisitorRadius then
        return false, "visitor not identified"
    end
    if visitor:FindFirstChildOfClass("Tool") then
        return false, "visitor is carrying an item"
    end
    return true, "no zombies near, visitor looks human"
end

local function handleKnock()
    local K = Config.Knock
    if knockBusy then return end
    knockBusy = true
    notify("knock", "Someone at the door", "Running safety checks - door stays shut.", 3)
    closeDoors("knock")

    if K.AutoPeephole and not findHint("StepBack") then
        local used = pressHint("Peephole")
        if not used then
            local root = getRoot()
            if root then
                local prompt = nearestPrompt(root.Position, Config.Doors.Radius, Config.Hints.Peephole.patterns, nil)
                if prompt then used = triggerPrompt(prompt) end
            end
        end
        if used then task.wait(K.PeepholeLookTime) end
    end

    local root = getRoot()
    if root then scanNpcs(root.Position) end
    local safe, why = assessVisitor()

    -- VERIFIED: "Click or E to step back" leaves the peephole view.
    if K.AutoStepBack and findHint("StepBack") then
        pressHint("StepBack")
        task.wait(0.3)
    end

    if safe then
        notify("verdict", "Visitor: looks safe", why, 3)
        if K.AutoOpenIfSafe then pressHint("DoorOpen") end
    else
        notify("verdict", "Visitor: do NOT open", why, 3)
        closeDoors("unsafe visitor")
    end
    knockBusy = false
end

-- Called for every changed on-screen text (already normalized to lower case).
onSubtitle = function(norm)
    if not running or not Config.Enabled then return end
    local now = os.clock()
    if Config.Knock.Enabled and now - lastKnock >= Config.Knock.Cooldown
        and containsAny(norm, Config.Knock.Phrases) then
        lastKnock = now
        task.spawn(handleKnock)
    elseif containsAny(norm, Config.Subtitles.IntercomPhrases) then
        -- 0:12 "...ding intercom: Attention all residents..."
        notify("intercom", "Building intercom", "Broadcast in progress - check objectives (TAB).",
            Config.Subtitles.Cooldown)
    end
end

---------------------------------------------------------------------------------------
-- THREAT REACTION
---------------------------------------------------------------------------------------
local lastLevel = "clear"

local function threatTick()
    local T = Config.Threat
    local root, hum = getRoot()
    if not root then return end
    if T.Enabled then
        scanNpcs(root.Position)
        if threat.level ~= lastLevel then
            if threat.level == "alert" then
                notify("alert", "Zombies nearby", threat.count .. " tracked, nearest "
                    .. math.floor(threat.nearest) .. " studs.", 8)
            elseif threat.level == "danger" then
                notify("danger", "ZOMBIE CLOSE", "Nearest " .. math.floor(threat.nearest)
                    .. " studs - closing doors.", 4)
            end
            lastLevel = threat.level
        end
        if threat.level == "danger" then
            closeDoors("zombie close") -- block the path between the zombie and the flat
            if T.AutoRetreat and hum and threat.nearestPos then
                local away = root.Position - threat.nearestPos
                if away.Magnitude > 0.1 then
                    hum:MoveTo(root.Position + away.Unit * T.RetreatDistance)
                end
            end
            -- never stay glued to the peephole with a zombie this close
            if Config.Knock.AutoStepBack and not knockBusy and findHint("StepBack") then
                pressHint("StepBack")
            end
        end
    end
    if statusLabel then
        local near = "-"
        if threat.nearest < math.huge then near = tostring(math.floor(threat.nearest)) end
        local hunger = "?"
        if hungerNow then hunger = math.floor(hungerNow * 100) .. "%" end
        local keys = "ok"
        if not inputAvailable then keys = "alert-only" end
        statusLabel.Text = " 30FU | " .. threat.level .. " | zombies " .. threat.count
            .. " (nearest " .. near .. ") | hunger " .. hunger .. " | keys " .. keys
    end
end

---------------------------------------------------------------------------------------
-- STARTUP / LOOPS / CLEANUP
---------------------------------------------------------------------------------------
track(PlayerGui.DescendantAdded:Connect(onGuiAdded))
track(PlayerGui.DescendantRemoving:Connect(onGuiRemoving))
for _, inst in ipairs(PlayerGui:GetDescendants()) do
    onGuiAdded(inst)
end

track(Workspace.DescendantAdded:Connect(onWorldAdded))
track(Workspace.DescendantRemoving:Connect(onWorldRemoving))
bindTags(Config.Tags.Zombie, taggedZombie)
bindTags(Config.Tags.Loot, taggedLoot)
task.spawn(function()
    -- single cached pass; yields so a large map never stalls a frame
    for i, inst in ipairs(Workspace:GetDescendants()) do
        onWorldAdded(inst)
        if i % 2000 == 0 then task.wait() end
    end
end)

track(UserInputService.InputBegan:Connect(function(input, processed)
    if not processed and input.KeyCode == Config.ToggleKey then
        Config.Enabled = not Config.Enabled
        if statusLabel and not Config.Enabled then statusLabel.Text = " 30FU | paused" end
        notify("toggle" .. tostring(Config.Enabled), "30FU assistant",
            Config.Enabled and "Resumed" or "Paused", 0)
    end
end))

local function loop(interval, fn)
    task.spawn(function()
        while running do
            if Config.Enabled then
                local ok, err = pcall(fn)
                if not ok then dprint("error:", err) end
            end
            task.wait(interval)
        end
    end)
end

loop(Config.Threat.Interval, threatTick)
loop(Config.Loot.Interval, function()
    doorTick()
    lootTick()
    -- 0:04-0:09 news intro: "Enter  Skip"
    if Config.AutoSkipIntro and findHint("SkipIntro") then
        pressHint("SkipIntro")
    end
end)
loop(Config.Hunger.Interval, hungerTick)

local function stop()
    running = false
    for _, conn in ipairs(conns) do conn:Disconnect() end
    for _, conn in pairs(labelConns) do conn:Disconnect() end
    for _, rec in pairs(npcs) do
        if rec.hl then rec.hl:Destroy() end
    end
    if overlay then overlay:Destroy() end
end

_G.FloorsUpAssistant = {
    Config = Config,
    Stop = stop,
    Press = pressHint, -- e.g. _G.FloorsUpAssistant.Press("PutAway") / ("Drop")
    Threat = threat,
}

notify("start", "30FU assistant", "Running. Right Ctrl pauses/resumes.", 0)
