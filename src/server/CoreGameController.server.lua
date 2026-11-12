--!strict
--[[
	CoreGameController (Script, ServerScriptService/Server)

	Owns the round loop and everything that outlives a single floor:
	  * state machine: Lobby -> IntroCutscene -> Gameplay -> RoundEnd -> Lobby
	  * floor streaming: one floor template is cloned into Workspace at a time
	  * player profiles (DataStore) and the persistent inventory snapshot
	  * round timer, intermission and hunger/thirst drain

	Other systems never require this script. They observe it through:
	  * Workspace attributes: GameState, CurrentFloor, TimerLabel, TimerRemaining
	  * Player attributes:    InRun, Hunger, Thirst, MovementLocked
	  * ServerStorage.ServerSignals (BindableEvents) for server code
	  * ReplicatedStorage.Remotes (RemoteEvents) for clients
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local InteractionSystem = require(script.Parent.InteractionSystem)

type GameState = "Lobby" | "IntroCutscene" | "Gameplay" | "RoundEnd"
type RoundResult = "Escaped" | "AllDead" | "TimeUp"

type Profile = {
	version: number,
	bestFloorsCleared: number,
	escapes: number,
	deaths: number,
	roundsPlayed: number,
	coins: number,
	inventory: { string },
}

local CONFIG = table.freeze({
	MinPlayers = 1,
	IntermissionTime = 20,
	IntroDuration = 25, -- upper bound; ends early once every client reports done
	RoundDuration = 45 * 60,
	RoundEndDuration = 12,
	TotalFloors = 30, -- the run starts on this floor and descends to 1

	HungerDrainPerSecond = 100 / 600,
	ThirstDrainPerSecond = 100 / 420,
	StarvationDamagePerSecond = 2,

	CoinsPerFloor = 5,
	EscapeBonus = 100,

	DataStoreName = "PlayerProfiles_v1",
	DataRetries = 3,
	AutosaveInterval = 120,
	DefaultWalkSpeed = 16,
})

local PROFILE_VERSION = 1

--------------------------------------------------------------------------------
-- Remotes and server signals
--------------------------------------------------------------------------------

local function getOrCreateFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function createRemote(parent: Instance, name: string): RemoteEvent
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function createSignal(parent: Instance, name: string): BindableEvent
	local signal = Instance.new("BindableEvent")
	signal.Name = name
	signal.Parent = parent
	return signal
end

local remoteFolder = getOrCreateFolder(ReplicatedStorage, "Remotes")
local remotes = {
	GameState = createRemote(remoteFolder, "GameState"), -- (state, payload?)
	FloorChanged = createRemote(remoteFolder, "FloorChanged"), -- (floor, totalFloors)
	Announcement = createRemote(remoteFolder, "Announcement"), -- (text)
	CutsceneFinished = createRemote(remoteFolder, "CutsceneFinished"), -- client -> server
}

local signalFolder = getOrCreateFolder(ServerStorage, "ServerSignals")
local signals = {
	StateChanged = createSignal(signalFolder, "StateChanged"), -- (state, payload?)
	FloorLoaded = createSignal(signalFolder, "FloorLoaded"), -- (floor, model?)
	PlayerDied = createSignal(signalFolder, "PlayerDied"), -- (player, floor)
	RoundEnded = createSignal(signalFolder, "RoundEnded"), -- (result)
}

InteractionSystem.Init(remoteFolder)

--------------------------------------------------------------------------------
-- Profiles (DataStore)
--------------------------------------------------------------------------------

local profiles: { [Player]: Profile } = {}
-- Only profiles that loaded successfully are written back, so a failed read
-- can never overwrite real data with defaults.
local canSave: { [Player]: boolean } = {}

local store: DataStore? = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(CONFIG.DataStoreName)
	end)
	if ok then
		store = result
	else
		warn("[Core] DataStore unavailable, progress will not persist:", result)
	end
end

local function withRetries(label: string, fn: () -> any): (boolean, any)
	for attempt = 1, CONFIG.DataRetries do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		warn(`[Core] {label} failed (attempt {attempt}): {result}`)
		if attempt < CONFIG.DataRetries then
			task.wait(2 ^ attempt)
		end
	end
	return false, nil
end

local function readNumber(data: any, key: string, default: number): number
	local value = data[key]
	return if type(value) == "number" and value == value then value else default
end

-- Builds a valid profile from whatever the DataStore returned.
local function reconcile(data: any): Profile
	if type(data) ~= "table" then
		data = {}
	end
	local inventory: { string } = {}
	if type(data.inventory) == "table" then
		for _, id in data.inventory do
			if type(id) == "string" then
				table.insert(inventory, id)
			end
		end
	end
	return {
		version = PROFILE_VERSION,
		bestFloorsCleared = readNumber(data, "bestFloorsCleared", 0),
		escapes = readNumber(data, "escapes", 0),
		deaths = readNumber(data, "deaths", 0),
		roundsPlayed = readNumber(data, "roundsPlayed", 0),
		coins = readNumber(data, "coins", 0),
		inventory = inventory,
	}
end

local function profileKey(player: Player): string
	return "u_" .. player.UserId
end

local function updateLeaderstats(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end
	local stats: Instance
	local existing = player:FindFirstChild("leaderstats")
	if existing then
		stats = existing
	else
		stats = Instance.new("Folder")
		stats.Name = "leaderstats"
		for _, name in { "Floors", "Escapes" } do
			local value = Instance.new("IntValue")
			value.Name = name
			value.Parent = stats
		end
		stats.Parent = player
	end
	local floors = stats:FindFirstChild("Floors")
	local escapes = stats:FindFirstChild("Escapes")
	if floors and floors:IsA("IntValue") then
		floors.Value = profile.bestFloorsCleared
	end
	if escapes and escapes:IsA("IntValue") then
		escapes.Value = profile.escapes
	end
end

local function loadProfile(player: Player)
	local loaded, data = false, nil
	local dataStore = store
	if dataStore then
		loaded, data = withRetries("Profile load", function()
			return dataStore:GetAsync(profileKey(player))
		end)
	end
	if player.Parent ~= Players then
		return -- left while the request was in flight
	end
	profiles[player] = reconcile(data)
	canSave[player] = loaded
	if not loaded then
		remotes.Announcement:FireClient(player, "Progress could not be loaded and will not be saved this session.")
	end
end

local function saveProfile(player: Player)
	local profile = profiles[player]
	local dataStore = store
	if not profile or not dataStore or not canSave[player] then
		return
	end
	profile.inventory = InteractionSystem.SerializeInventory(player)
	-- Snapshot so later mutations cannot leak into a retried write.
	local snapshot = table.clone(profile)
	snapshot.inventory = table.clone(profile.inventory)
	withRetries("Profile save", function()
		dataStore:UpdateAsync(profileKey(player), function()
			return snapshot
		end)
		return nil
	end)
end

--------------------------------------------------------------------------------
-- Round state
--------------------------------------------------------------------------------

local state: GameState = "Lobby"
local currentFloor = 0
local activeFloor: Model? = nil
local participants: { [Player]: boolean } = {} -- players still alive in the run
local roundFloorsCleared = 0
local floorAdvanceRequested = false

local function setState(newState: GameState, payload: any?)
	state = newState
	Workspace:SetAttribute("GameState", newState)
	remotes.GameState:FireAllClients(newState, payload)
	signals.StateChanged:Fire(newState, payload)
end

local function setTimer(label: string, seconds: number)
	Workspace:SetAttribute("TimerLabel", label)
	Workspace:SetAttribute("TimerRemaining", seconds)
end

-- Ticks once per second. Returns false if `shouldAbort` cut it short.
local function countdown(label: string, seconds: number, shouldAbort: (() -> boolean)?): boolean
	for remaining = seconds, 1, -1 do
		setTimer(label, remaining)
		task.wait(1)
		if shouldAbort and shouldAbort() then
			setTimer("", 0)
			return false
		end
	end
	setTimer("", 0)
	return true
end

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return if humanoid and humanoid.Health > 0 then humanoid else nil
end

local function getNumberAttribute(instance: Instance, name: string, default: number): number
	local value = instance:GetAttribute(name)
	return if type(value) == "number" then value else default
end

local function setMovementLocked(player: Player, locked: boolean)
	player:SetAttribute("MovementLocked", locked)
	local humanoid = getHumanoid(player)
	if humanoid then
		humanoid.WalkSpeed = if locked then 0 else CONFIG.DefaultWalkSpeed
	end
end

-- Credits a player's run to their profile. Called once per player per round:
-- on death, or at round end for whoever is still standing.
local function settleRun(player: Player, escaped: boolean)
	local profile = profiles[player]
	if not profile then
		return
	end
	profile.coins += roundFloorsCleared * CONFIG.CoinsPerFloor
	profile.bestFloorsCleared = math.max(profile.bestFloorsCleared, roundFloorsCleared)
	if escaped then
		profile.escapes += 1
		profile.coins += CONFIG.EscapeBonus
	end
	updateLeaderstats(player)
end

local function eliminate(player: Player)
	if not participants[player] then
		return
	end
	participants[player] = nil
	player:SetAttribute("InRun", false)
	player:SetAttribute("MovementLocked", false)
	local profile = profiles[player]
	if profile then
		profile.deaths += 1
	end
	settleRun(player, false)
	-- Death costs the whole backpack; it is left on the floor for teammates.
	InteractionSystem.ClearInventory(player, true)
	signals.PlayerDied:Fire(player, currentFloor)
	remotes.Announcement:FireAllClients(`{player.DisplayName} didn't make it.`)
end

--------------------------------------------------------------------------------
-- Floors
--------------------------------------------------------------------------------

local floorTemplates: { Model } = {}
do
	local folder = ServerStorage:FindFirstChild("Floors")
	if folder then
		for _, child in folder:GetChildren() do
			if child:IsA("Model") then
				table.insert(floorTemplates, child)
			end
		end
		table.sort(floorTemplates, function(a, b)
			return a.Name < b.Name
		end)
	end
	if #floorTemplates == 0 then
		warn("[Core] ServerStorage.Floors has no Model templates; rounds will run without geometry.")
	end
end

-- Prefers a hand-built "Floor_NN" template and otherwise cycles the pool, so a
-- 30 floor run works with only a handful of layouts.
local function getFloorTemplate(floorNumber: number): Model?
	local folder = ServerStorage:FindFirstChild("Floors")
	local exact = folder and folder:FindFirstChild(string.format("Floor_%02d", floorNumber))
	if exact and exact:IsA("Model") then
		return exact
	end
	if #floorTemplates == 0 then
		return nil
	end
	return floorTemplates[(CONFIG.TotalFloors - floorNumber) % #floorTemplates + 1]
end

local function teleport(player: Player, target: CFrame)
	local character = player.Character
	if not character then
		return
	end
	task.spawn(function()
		if Workspace.StreamingEnabled then
			pcall(function()
				player:RequestStreamAroundAsync(target.Position)
			end)
		end
		if character.Parent then
			character:PivotTo(target)
		end
	end)
end

local function unloadFloor()
	-- Must run first: releases hidden players and clears dropped items.
	InteractionSystem.ResetWorldState()
	if activeFloor then
		activeFloor:Destroy()
		activeFloor = nil
	end
end

local function loadFloor(floorNumber: number)
	unloadFloor()
	currentFloor = floorNumber

	local template = getFloorTemplate(floorNumber)
	local floor: Model? = nil
	if template then
		local clone = template:Clone()
		clone.Name = "ActiveFloor"
		clone:SetAttribute("FloorNumber", floorNumber)
		clone.Parent = Workspace
		activeFloor = clone
		floor = clone

		local spawns: { BasePart } = {}
		local spawnFolder = clone:FindFirstChild("Spawns")
		if spawnFolder then
			for _, child in spawnFolder:GetChildren() do
				if child:IsA("BasePart") then
					table.insert(spawns, child)
				end
			end
		end
		if #spawns > 0 then
			local index = 0
			for player in participants do
				index += 1
				local spawn = spawns[(index - 1) % #spawns + 1]
				teleport(player, spawn.CFrame + Vector3.new(0, 3, 0))
			end
		else
			warn(`[Core] {template.Name} has no Spawns folder with parts; players were not moved.`)
		end
	end

	Workspace:SetAttribute("CurrentFloor", floorNumber)
	remotes.FloorChanged:FireAllClients(floorNumber, CONFIG.TotalFloors)
	signals.FloorLoaded:Fire(floorNumber, floor)
end

InteractionSystem.ExitUsed:Connect(function(player: Player)
	if state == "Gameplay" and participants[player] then
		floorAdvanceRequested = true
		remotes.Announcement:FireAllClients(`{player.DisplayName} opened the stairwell.`)
	end
end)

--------------------------------------------------------------------------------
-- Phases
--------------------------------------------------------------------------------

local function runLobby()
	setState("Lobby")
	local function notEnoughPlayers(): boolean
		return #Players:GetPlayers() < CONFIG.MinPlayers
	end
	while true do
		if notEnoughPlayers() then
			setTimer("Waiting for players", 0)
			task.wait(1)
		elseif countdown("Intermission", CONFIG.IntermissionTime, notEnoughPlayers) then
			return
		end
	end
end

-- Returns false when nobody is left to play the round.
local function runIntro(): boolean
	participants = {}
	for _, player in Players:GetPlayers() do
		if profiles[player] and getHumanoid(player) then
			participants[player] = true
			player:SetAttribute("InRun", true)
			setMovementLocked(player, true)
		end
	end
	if next(participants) == nil then
		return false
	end

	setState("IntroCutscene", { duration = CONFIG.IntroDuration })

	local finished: { [Player]: boolean } = {}
	local connection = remotes.CutsceneFinished.OnServerEvent:Connect(function(player)
		finished[player] = true
	end)
	countdown("", CONFIG.IntroDuration, function()
		for player in participants do
			if not finished[player] then
				return false
			end
		end
		return true
	end)
	connection:Disconnect()

	for player in participants do
		setMovementLocked(player, false)
	end
	return next(participants) ~= nil
end

local function tickSurvival(dt: number)
	for player in participants do
		local hunger = math.max(0, getNumberAttribute(player, "Hunger", 100) - CONFIG.HungerDrainPerSecond * dt)
		local thirst = math.max(0, getNumberAttribute(player, "Thirst", 100) - CONFIG.ThirstDrainPerSecond * dt)
		player:SetAttribute("Hunger", hunger)
		player:SetAttribute("Thirst", thirst)
		if hunger <= 0 or thirst <= 0 then
			local humanoid = getHumanoid(player)
			if humanoid then
				humanoid:TakeDamage(CONFIG.StarvationDamagePerSecond * dt)
			end
		end
	end
end

local function runGameplay(): RoundResult
	roundFloorsCleared = 0
	floorAdvanceRequested = false
	for player in participants do
		player:SetAttribute("Hunger", 100)
		player:SetAttribute("Thirst", 100)
		local profile = profiles[player]
		if profile then
			profile.roundsPlayed += 1
		end
	end

	setState("Gameplay", { totalFloors = CONFIG.TotalFloors })
	loadFloor(CONFIG.TotalFloors)

	local remaining = CONFIG.RoundDuration
	while true do
		setTimer("Escape", remaining)
		task.wait(1)
		remaining -= 1
		tickSurvival(1)

		if next(participants) == nil then
			return "AllDead"
		end
		if remaining <= 0 then
			return "TimeUp"
		end
		if floorAdvanceRequested then
			floorAdvanceRequested = false
			roundFloorsCleared += 1
			if currentFloor <= 1 then
				return "Escaped"
			end
			loadFloor(currentFloor - 1)
		end
	end
end

local function runRoundEnd(result: RoundResult)
	local escaped = result == "Escaped"
	local survivors: { Player } = {}
	local survivorNames: { string } = {}
	for player in participants do
		table.insert(survivors, player)
		table.insert(survivorNames, player.DisplayName)
		settleRun(player, escaped)
		if not escaped then
			InteractionSystem.ClearInventory(player, false)
		end
		player:SetAttribute("InRun", false)
	end
	participants = {}

	setTimer("", 0)
	setState("RoundEnd", {
		result = result,
		floorsCleared = roundFloorsCleared,
		survivors = survivorNames,
	})
	signals.RoundEnded:Fire(result)

	for player in profiles do
		task.spawn(saveProfile, player)
	end

	countdown("Returning to lobby", CONFIG.RoundEndDuration)

	unloadFloor()
	currentFloor = 0
	Workspace:SetAttribute("CurrentFloor", 0)
	for _, player in survivors do
		if player.Parent == Players then
			task.spawn(function()
				pcall(player.LoadCharacterAsync, player)
			end)
		end
	end
end

--------------------------------------------------------------------------------
-- Player lifecycle
--------------------------------------------------------------------------------

local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Once(function()
			eliminate(player)
		end)
	end
end

local function onPlayerAdded(player: Player)
	InteractionSystem.AddPlayer(player)
	player:SetAttribute("InRun", false)
	player:SetAttribute("Hunger", 100)
	player:SetAttribute("Thirst", 100)

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end

	loadProfile(player)
	local profile = profiles[player]
	if not profile then
		return
	end
	InteractionSystem.LoadInventory(player, profile.inventory)
	updateLeaderstats(player)
	remotes.GameState:FireClient(player, state, nil)
	remotes.FloorChanged:FireClient(player, currentFloor, CONFIG.TotalFloors)
end

local function onPlayerRemoving(player: Player)
	-- Leaving mid-run counts as a death so the backpack cannot be banked.
	eliminate(player)
	saveProfile(player)
	profiles[player] = nil
	canSave[player] = nil
	InteractionSystem.RemovePlayer(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

task.spawn(function()
	while true do
		task.wait(CONFIG.AutosaveInterval)
		local snapshot: { Player } = {}
		for player in profiles do
			table.insert(snapshot, player)
		end
		for _, player in snapshot do
			saveProfile(player)
			task.wait(1) -- spread writes across the request budget
		end
	end
end)

game:BindToClose(function()
	local pending = 0
	for player in profiles do
		pending += 1
		task.spawn(function()
			saveProfile(player)
			pending -= 1
		end)
	end
	local deadline = os.clock() + 25
	while pending > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end)

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------

Workspace:SetAttribute("GameState", state)
Workspace:SetAttribute("CurrentFloor", 0)
setTimer("", 0)

task.spawn(function()
	while true do
		local ok, err = xpcall(function()
			runLobby()
			if runIntro() then
				runRoundEnd(runGameplay())
			end
		end, debug.traceback)
		if not ok then
			-- A broken round must not take the server down with it.
			warn("[Core] Round aborted:", err)
			for player in participants do
				player:SetAttribute("InRun", false)
				setMovementLocked(player, false)
			end
			participants = {}
			unloadFloor()
			task.wait(3)
		end
	end
end)
