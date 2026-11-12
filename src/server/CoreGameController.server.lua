--[[
	CoreGameController (Script, ServerScriptService/Server)

	Owns the round loop and everything that outlives a single floor:
	  * state machine: Lobby -> IntroCutscene -> Gameplay -> RoundEnd -> Lobby
	  * floor generation: one room is built from Parts in Workspace at a time
	  * player profiles (DataStore) and the persistent inventory snapshot
	  * round timer, intermission and hunger/thirst drain

	Self-contained: no require() calls and nothing is read from ServerStorage.
	Written in plain Lua 5.1 syntax (no type annotations, compound assignment,
	continue, string interpolation or if-expressions).

	Other systems observe this script through:
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

local CONFIG = {
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
	MaxInventorySlots = 6,
}

local PROFILE_VERSION = 1

--------------------------------------------------------------------------------
-- Remotes and server signals
--------------------------------------------------------------------------------

local function getOrCreateFolder(parent, name)
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function createRemote(parent, name)
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function createSignal(parent, name)
	local signal = Instance.new("BindableEvent")
	signal.Name = name
	signal.Parent = parent
	return signal
end

local remoteFolder = getOrCreateFolder(ReplicatedStorage, "Remotes")
local remotes = {
	GameState = createRemote(remoteFolder, "GameState"), -- (state, payload)
	FloorChanged = createRemote(remoteFolder, "FloorChanged"), -- (floor, totalFloors)
	Announcement = createRemote(remoteFolder, "Announcement"), -- (text)
	CutsceneFinished = createRemote(remoteFolder, "CutsceneFinished"), -- client -> server
}

-- Created here, never read from: an empty ServerStorage is fine.
local signalFolder = getOrCreateFolder(ServerStorage, "ServerSignals")
local signals = {
	StateChanged = createSignal(signalFolder, "StateChanged"), -- (state, payload)
	FloorLoaded = createSignal(signalFolder, "FloorLoaded"), -- (floor, model or nil)
	PlayerDied = createSignal(signalFolder, "PlayerDied"), -- (player, floor)
	RoundEnded = createSignal(signalFolder, "RoundEnded"), -- (result)
	-- Input: any server script fires this with a participant to finish the floor.
	FloorExitRequested = createSignal(signalFolder, "FloorExitRequested"), -- (player)
}

--------------------------------------------------------------------------------
-- Inventory (inlined replacement for the InteractionSystem module)
--------------------------------------------------------------------------------

-- Only the backpack contents survive from the old module; they are what the
-- profile saves. Doors, items and prompts are not handled by this script.
local inventories = {} -- [Player] = { itemId, ... }

local function inventoryAddPlayer(player)
	if not inventories[player] then
		inventories[player] = {}
	end
end

local function inventoryRemovePlayer(player)
	inventories[player] = nil
end

local function inventoryLoad(player, itemIds)
	local list = {}
	if type(itemIds) == "table" then
		for _, id in ipairs(itemIds) do
			if type(id) == "string" and #list < CONFIG.MaxInventorySlots then
				table.insert(list, id)
			end
		end
	end
	inventories[player] = list
end

local function inventorySerialize(player)
	local copy = {}
	local list = inventories[player]
	if list then
		for index, id in ipairs(list) do
			copy[index] = id
		end
	end
	return copy
end

local function inventoryClear(player)
	if inventories[player] then
		inventories[player] = {}
	end
end

--------------------------------------------------------------------------------
-- Profiles (DataStore)
--------------------------------------------------------------------------------

local profiles = {} -- [Player] = profile table
-- Only profiles that loaded successfully are written back, so a failed read
-- can never overwrite real data with defaults.
local canSave = {} -- [Player] = boolean

local store = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(CONFIG.DataStoreName)
	end)
	if ok then
		store = result
	else
		warn("[Core] DataStore unavailable, progress will not persist: " .. tostring(result))
	end
end

local function withRetries(label, fn)
	for attempt = 1, CONFIG.DataRetries do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		warn("[Core] " .. label .. " failed (attempt " .. attempt .. "): " .. tostring(result))
		if attempt < CONFIG.DataRetries then
			task.wait(2 ^ attempt)
		end
	end
	return false, nil
end

local function readNumber(data, key, default)
	local value = data[key]
	-- value == value rejects NaN
	if type(value) == "number" and value == value then
		return value
	end
	return default
end

-- Builds a valid profile from whatever the DataStore returned.
local function reconcile(data)
	if type(data) ~= "table" then
		data = {}
	end
	local inventory = {}
	if type(data.inventory) == "table" then
		for _, id in ipairs(data.inventory) do
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

local function profileKey(player)
	return "u_" .. tostring(player.UserId)
end

local function updateLeaderstats(player)
	local profile = profiles[player]
	if not profile then
		return
	end
	local stats = player:FindFirstChild("leaderstats")
	if not stats then
		stats = Instance.new("Folder")
		stats.Name = "leaderstats"
		for _, name in ipairs({ "Floors", "Escapes" }) do
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

local function loadProfile(player)
	local loaded, data = false, nil
	if store then
		loaded, data = withRetries("Profile load", function()
			return store:GetAsync(profileKey(player))
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

local function saveProfile(player)
	local profile = profiles[player]
	if not profile or not store or not canSave[player] then
		return
	end
	profile.inventory = inventorySerialize(player)
	-- Snapshot so later mutations cannot leak into a retried write.
	local snapshot = {}
	for key, value in pairs(profile) do
		snapshot[key] = value
	end
	snapshot.inventory = inventorySerialize(player)
	withRetries("Profile save", function()
		store:UpdateAsync(profileKey(player), function()
			return snapshot
		end)
		return nil
	end)
end

--------------------------------------------------------------------------------
-- Round state
--------------------------------------------------------------------------------

local state = "Lobby" -- "Lobby" | "IntroCutscene" | "Gameplay" | "RoundEnd"
local currentFloor = 0
local activeFloor = nil -- the generated Model currently in Workspace
local participants = {} -- [Player] = true for players still alive in the run
local roundFloorsCleared = 0
local floorAdvanceRequested = false

local function setState(newState, payload)
	state = newState
	Workspace:SetAttribute("GameState", newState)
	remotes.GameState:FireAllClients(newState, payload)
	signals.StateChanged:Fire(newState, payload)
end

local function setTimer(label, seconds)
	Workspace:SetAttribute("TimerLabel", label)
	Workspace:SetAttribute("TimerRemaining", seconds)
end

-- Ticks once per second. Returns false if shouldAbort cut it short.
local function countdown(label, seconds, shouldAbort)
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

local function getHumanoid(player)
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

local function getNumberAttribute(instance, name, default)
	local value = instance:GetAttribute(name)
	if type(value) == "number" then
		return value
	end
	return default
end

local function setMovementLocked(player, locked)
	player:SetAttribute("MovementLocked", locked)
	local humanoid = getHumanoid(player)
	if humanoid then
		if locked then
			humanoid.WalkSpeed = 0
		else
			humanoid.WalkSpeed = CONFIG.DefaultWalkSpeed
		end
	end
end

-- Credits a player's run to their profile. Called once per player per round:
-- on death, or at round end for whoever is still standing.
local function settleRun(player, escaped)
	local profile = profiles[player]
	if not profile then
		return
	end
	profile.coins = profile.coins + roundFloorsCleared * CONFIG.CoinsPerFloor
	profile.bestFloorsCleared = math.max(profile.bestFloorsCleared, roundFloorsCleared)
	if escaped then
		profile.escapes = profile.escapes + 1
		profile.coins = profile.coins + CONFIG.EscapeBonus
	end
	updateLeaderstats(player)
end

local function eliminate(player)
	if not participants[player] then
		return
	end
	participants[player] = nil
	player:SetAttribute("InRun", false)
	player:SetAttribute("MovementLocked", false)
	local profile = profiles[player]
	if profile then
		profile.deaths = profile.deaths + 1
	end
	settleRun(player, false)
	-- Death costs the whole backpack.
	inventoryClear(player)
	signals.PlayerDied:Fire(player, currentFloor)
	remotes.Announcement:FireAllClients(player.DisplayName .. " didn't make it.")
end

--------------------------------------------------------------------------------
-- Floors (procedurally generated)
--------------------------------------------------------------------------------

local function teleport(player, target)
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
	if activeFloor then
		activeFloor:Destroy()
		activeFloor = nil
	end
end

local function loadFloor(floorNumber)
	----------------------------------------------------------------------------
	-- STEP 1: Validate the argument.
	----------------------------------------------------------------------------
	-- A non-number (or NaN, the only value not equal to itself) would poison
	-- the CurrentFloor attribute and the "currentFloor - 1" arithmetic in
	-- runGameplay, so fall back to the top floor instead of erroring mid-round.
	if type(floorNumber) ~= "number" or floorNumber ~= floorNumber then
		warn("[Core] loadFloor received an invalid floor number (" .. tostring(floorNumber) .. "); using the top floor.")
		floorNumber = CONFIG.TotalFloors
	end
	-- Floors are whole numbers; a fractional value would never hit "floor 1".
	floorNumber = math.floor(floorNumber)
	-- Clamp into 1..TotalFloors so a bad caller cannot create floor 0 or 31.
	if floorNumber < 1 then
		floorNumber = 1
	end
	if floorNumber > CONFIG.TotalFloors then
		floorNumber = CONFIG.TotalFloors
	end

	----------------------------------------------------------------------------
	-- STEP 2: Remove the previous floor.
	----------------------------------------------------------------------------
	-- Destroys the model tracked in activeFloor (and sets it to nil).
	unloadFloor()
	-- Also remove any untracked "ActiveFloor" left behind by an aborted round;
	-- two rooms at the same coordinates would z-fight and double the collisions.
	local stale = Workspace:FindFirstChild("ActiveFloor")
	while stale do
		stale:Destroy()
		stale = Workspace:FindFirstChild("ActiveFloor")
	end
	-- Recorded before building so death reports during the build name this floor.
	currentFloor = floorNumber

	----------------------------------------------------------------------------
	-- STEP 3: Room dimensions.
	----------------------------------------------------------------------------
	-- These are the INTERIOR (walkable air) dimensions required by the spec:
	-- 40 studs wide (X), 10 studs tall (Y), 40 studs deep (Z).
	local ROOM_WIDTH = 40
	local ROOM_HEIGHT = 10
	local ROOM_DEPTH = 40
	-- Every slab (floor, ceiling, walls) is 1 stud thick, per the spec.
	local WALL_THICKNESS = 1

	-- The room is centred on X = 0, Z = 0. FLOOR_SURFACE_Y is the height of the
	-- surface players stand on. 500 studs up keeps the room clear of a lobby
	-- built near the origin, and far below any height where physics degrades.
	local ORIGIN_X = 0
	local FLOOR_SURFACE_Y = 500
	local ORIGIN_Z = 0

	-- Half extents of the interior: the inner wall faces sit at X = +/-20 and
	-- Z = +/-20 relative to the origin.
	local HALF_WIDTH = ROOM_WIDTH / 2 -- 20
	local HALF_DEPTH = ROOM_DEPTH / 2 -- 20
	-- A part is positioned by its CENTRE, so a slab that must start exactly at
	-- a face is offset by half its own thickness.
	local HALF_THICKNESS = WALL_THICKNESS / 2 -- 0.5

	-- Outer footprint: the interior plus one wall thickness on both sides.
	-- 40 + 1 + 1 = 42. The floor and ceiling use this footprint so they cover
	-- the tops and bottoms of the walls and close the corners.
	local OUTER_WIDTH = ROOM_WIDTH + WALL_THICKNESS * 2 -- 42
	local OUTER_DEPTH = ROOM_DEPTH + WALL_THICKNESS * 2 -- 42

	-- Floor slab: its TOP face must be at FLOOR_SURFACE_Y, so its centre is
	-- half a thickness below. 500 - 0.5 = 499.5 (spans Y 499 .. 500).
	local FLOOR_CENTER_Y = FLOOR_SURFACE_Y - HALF_THICKNESS
	-- Ceiling slab: its BOTTOM face must be at 500 + 10 = 510, so its centre
	-- is half a thickness above. 510 + 0.5 = 510.5 (spans Y 510 .. 511).
	local CEILING_CENTER_Y = FLOOR_SURFACE_Y + ROOM_HEIGHT + HALF_THICKNESS
	-- Walls fill exactly the gap between floor top (500) and ceiling bottom
	-- (510): height 10, centre 500 + 5 = 505 (spans Y 500 .. 510). They touch
	-- both slabs face to face: no gap, and no overlap that would z-fight.
	local WALL_CENTER_Y = FLOOR_SURFACE_Y + ROOM_HEIGHT / 2

	-- Edge case: a zero or negative size makes Roblox clamp the part to its
	-- minimum size, which would silently open gaps. Refuse to build instead.
	local dimensionsValid = ROOM_WIDTH > 0 and ROOM_HEIGHT > 0 and ROOM_DEPTH > 0 and WALL_THICKNESS > 0

	----------------------------------------------------------------------------
	-- STEP 4: Build the model.
	----------------------------------------------------------------------------
	-- Declared outside the pcall so a half-built model can be destroyed if any
	-- step inside throws.
	local floorModel = nil
	local spawnParts = {}

	local buildOk, buildError = pcall(function()
		if not dimensionsValid then
			error("room dimensions must all be greater than zero")
		end

		-- Container for everything on this floor. It stays unparented until
		-- the end so the engine replicates one finished model, not 12 changes.
		floorModel = Instance.new("Model")
		-- unloadFloor and the stale check above find the floor by this name.
		floorModel.Name = "ActiveFloor"
		-- Lets other scripts tell which storey this geometry represents.
		floorModel:SetAttribute("FloorNumber", floorNumber)

		-- FLOOR ---------------------------------------------------------------
		local floorPart = Instance.new("Part")
		floorPart.Name = "Floor"
		-- 42 x 1 x 42: the outer footprint, so the four walls stand ON it.
		floorPart.Size = Vector3.new(OUTER_WIDTH, WALL_THICKNESS, OUTER_DEPTH)
		-- Centre (0, 499.5, 0): top face exactly at Y = 500.
		floorPart.Position = Vector3.new(ORIGIN_X, FLOOR_CENTER_Y, ORIGIN_Z)
		-- Anchored: unanchored geometry would fall out of the sky.
		floorPart.Anchored = true
		-- CanCollide: players and zombies must be able to stand on it.
		floorPart.CanCollide = true
		-- Worn apartment floorboards.
		floorPart.BrickColor = BrickColor.new("Reddish brown")
		floorPart.Material = Enum.Material.WoodPlanks
		-- Smooth faces: older environments default to studs and inlets.
		floorPart.TopSurface = Enum.SurfaceType.Smooth
		floorPart.BottomSurface = Enum.SurfaceType.Smooth
		floorPart.Parent = floorModel

		-- CEILING -------------------------------------------------------------
		local ceilingPart = Instance.new("Part")
		ceilingPart.Name = "Ceiling"
		-- Same 42 x 1 x 42 footprint as the floor, so it caps the wall tops.
		ceilingPart.Size = Vector3.new(OUTER_WIDTH, WALL_THICKNESS, OUTER_DEPTH)
		-- Centre (0, 510.5, 0): bottom face exactly at Y = 510.
		ceilingPart.Position = Vector3.new(ORIGIN_X, CEILING_CENTER_Y, ORIGIN_Z)
		ceilingPart.Anchored = true
		-- CanCollide: stops jumps and thrown objects leaving through the top.
		ceilingPart.CanCollide = true
		-- Dirty grey concrete keeps the room dim.
		ceilingPart.BrickColor = BrickColor.new("Dark stone grey")
		ceilingPart.Material = Enum.Material.Concrete
		ceilingPart.TopSurface = Enum.SurfaceType.Smooth
		ceilingPart.BottomSurface = Enum.SurfaceType.Smooth
		ceilingPart.Parent = floorModel

		-- NORTH WALL (the -Z side) --------------------------------------------
		local northWall = Instance.new("Part")
		northWall.Name = "WallNorth"
		-- 42 x 10 x 1: the FULL outer width, so this wall also fills both
		-- corner columns (X 20 .. 21 and X -21 .. -20).
		northWall.Size = Vector3.new(OUTER_WIDTH, ROOM_HEIGHT, WALL_THICKNESS)
		-- Centre Z = -(20 + 0.5) = -20.5: inner face exactly at Z = -20.
		northWall.Position = Vector3.new(ORIGIN_X, WALL_CENTER_Y, ORIGIN_Z - HALF_DEPTH - HALF_THICKNESS)
		northWall.Anchored = true
		northWall.CanCollide = true
		-- Yellowed plaster-coloured walls.
		northWall.BrickColor = BrickColor.new("Brick yellow")
		northWall.Material = Enum.Material.Concrete
		northWall.TopSurface = Enum.SurfaceType.Smooth
		northWall.BottomSurface = Enum.SurfaceType.Smooth
		northWall.Parent = floorModel

		-- SOUTH WALL (the +Z side) --------------------------------------------
		local southWall = Instance.new("Part")
		southWall.Name = "WallSouth"
		-- Mirror of the north wall: 42 x 10 x 1.
		southWall.Size = Vector3.new(OUTER_WIDTH, ROOM_HEIGHT, WALL_THICKNESS)
		-- Centre Z = +(20 + 0.5) = 20.5: inner face exactly at Z = 20.
		southWall.Position = Vector3.new(ORIGIN_X, WALL_CENTER_Y, ORIGIN_Z + HALF_DEPTH + HALF_THICKNESS)
		southWall.Anchored = true
		southWall.CanCollide = true
		southWall.BrickColor = BrickColor.new("Brick yellow")
		southWall.Material = Enum.Material.Concrete
		southWall.TopSurface = Enum.SurfaceType.Smooth
		southWall.BottomSurface = Enum.SurfaceType.Smooth
		southWall.Parent = floorModel

		-- WEST WALL (the -X side) ---------------------------------------------
		local westWall = Instance.new("Part")
		westWall.Name = "WallWest"
		-- 1 x 10 x 40: only the INTERIOR depth. The north and south walls
		-- already own the corners, so this one fits between their inner faces
		-- (Z -20 .. 20) and touches them without overlapping.
		westWall.Size = Vector3.new(WALL_THICKNESS, ROOM_HEIGHT, ROOM_DEPTH)
		-- Centre X = -(20 + 0.5) = -20.5: inner face exactly at X = -20.
		westWall.Position = Vector3.new(ORIGIN_X - HALF_WIDTH - HALF_THICKNESS, WALL_CENTER_Y, ORIGIN_Z)
		westWall.Anchored = true
		westWall.CanCollide = true
		westWall.BrickColor = BrickColor.new("Brick yellow")
		westWall.Material = Enum.Material.Concrete
		westWall.TopSurface = Enum.SurfaceType.Smooth
		westWall.BottomSurface = Enum.SurfaceType.Smooth
		westWall.Parent = floorModel

		-- EAST WALL (the +X side) ---------------------------------------------
		local eastWall = Instance.new("Part")
		eastWall.Name = "WallEast"
		-- Mirror of the west wall: 1 x 10 x 40.
		eastWall.Size = Vector3.new(WALL_THICKNESS, ROOM_HEIGHT, ROOM_DEPTH)
		-- Centre X = +(20 + 0.5) = 20.5: inner face exactly at X = 20.
		eastWall.Position = Vector3.new(ORIGIN_X + HALF_WIDTH + HALF_THICKNESS, WALL_CENTER_Y, ORIGIN_Z)
		eastWall.Anchored = true
		eastWall.CanCollide = true
		eastWall.BrickColor = BrickColor.new("Brick yellow")
		eastWall.Material = Enum.Material.Concrete
		eastWall.TopSurface = Enum.SurfaceType.Smooth
		eastWall.BottomSurface = Enum.SurfaceType.Smooth
		eastWall.Parent = floorModel

		-- SPAWNS --------------------------------------------------------------
		-- A Folder named "Spawns" inside the model, holding one pad per spawn.
		local spawnsFolder = Instance.new("Folder")
		spawnsFolder.Name = "Spawns"
		spawnsFolder.Parent = floorModel

		-- Pads are 6 x 0.2 x 6: wide enough to stand on, and only 0.2 studs
		-- tall so the collidable pad is a lip a Humanoid walks over, not a step.
		local SPAWN_PAD_WIDTH = 6
		local SPAWN_PAD_HEIGHT = 0.2
		-- The pad rests ON the floor: bottom face at Y = 500, so its centre is
		-- half its height above. 500 + 0.1 = 500.1.
		local SPAWN_CENTER_Y = FLOOR_SURFACE_Y + SPAWN_PAD_HEIGHT / 2

		-- Offsets from the room centre as { X, Z }. The first is the required
		-- centre spawn. The other four sit 8 studs out on each diagonal so a
		-- group does not arrive stacked inside each other; 8 + 3 (half a pad)
		-- = 11, well inside the 20 stud half extent.
		local spawnOffsets = {
			{ 0, 0 },
			{ 8, 8 },
			{ -8, 8 },
			{ 8, -8 },
			{ -8, -8 },
		}

		for index, offset in ipairs(spawnOffsets) do
			local offsetX = offset[1]
			local offsetZ = offset[2]
			-- Edge case: if the constants are edited so a pad would poke into
			-- a wall, skip it rather than spawn a player inside the wall.
			local fitsX = math.abs(offsetX) + SPAWN_PAD_WIDTH / 2 <= HALF_WIDTH
			local fitsZ = math.abs(offsetZ) + SPAWN_PAD_WIDTH / 2 <= HALF_DEPTH
			if fitsX and fitsZ then
				-- A plain Part, not a SpawnLocation: a SpawnLocation would also
				-- capture ordinary respawns and pull lobby players into the room.
				local spawnPart = Instance.new("Part")
				-- "Spawn1" is the centre pad; names are unique for debugging.
				spawnPart.Name = "Spawn" .. tostring(index)
				spawnPart.Size = Vector3.new(SPAWN_PAD_WIDTH, SPAWN_PAD_HEIGHT, SPAWN_PAD_WIDTH)
				-- Centre pad: (0, 500.1, 0).
				spawnPart.Position = Vector3.new(ORIGIN_X + offsetX, SPAWN_CENTER_Y, ORIGIN_Z + offsetZ)
				spawnPart.Anchored = true
				spawnPart.CanCollide = true
				-- Dark metal plate, visible but unobtrusive on the wood floor.
				spawnPart.BrickColor = BrickColor.new("Black")
				spawnPart.Material = Enum.Material.Metal
				spawnPart.TopSurface = Enum.SurfaceType.Smooth
				spawnPart.BottomSurface = Enum.SurfaceType.Smooth
				spawnPart.Parent = spawnsFolder
				table.insert(spawnParts, spawnPart)
			else
				warn("[Core] Spawn offset " .. tostring(index) .. " does not fit inside the room and was skipped.")
			end
		end

		-- The floor slab is the natural pivot for moving the whole room.
		floorModel.PrimaryPart = floorPart
		-- Parented last, once complete (see the note where the model is made).
		floorModel.Parent = Workspace
	end)

	if buildOk then
		activeFloor = floorModel
	else
		-- Edge case: creation failed part-way. Remove the fragment so nobody
		-- is teleported into a room that is missing a wall or its floor.
		warn("[Core] Floor " .. tostring(floorNumber) .. " could not be generated: " .. tostring(buildError))
		if floorModel then
			floorModel:Destroy()
		end
		floorModel = nil
		activeFloor = nil
		spawnParts = {}
	end

	----------------------------------------------------------------------------
	-- STEP 5: Move the players in.
	----------------------------------------------------------------------------
	if #spawnParts > 0 then
		local index = 0
		for player in pairs(participants) do
			index = index + 1
			-- Round-robin over the pads: with more players than pads the
			-- modulo wraps back to the first one instead of indexing nil.
			local spawnPart = spawnParts[(index - 1) % #spawnParts + 1]
			-- 3 studs above the pad puts the character's root at standing
			-- height, so it lands on its feet instead of clipping the floor.
			teleport(player, spawnPart.CFrame + Vector3.new(0, 3, 0))
		end
	elseif floorModel then
		warn("[Core] The generated floor has no spawn parts; players were not moved.")
	end

	----------------------------------------------------------------------------
	-- STEP 6: Announce the new floor.
	----------------------------------------------------------------------------
	-- Sent even if generation failed (floorModel is then nil) so the HUD and
	-- the round loop stay in step with currentFloor.
	Workspace:SetAttribute("CurrentFloor", floorNumber)
	remotes.FloorChanged:FireAllClients(floorNumber, CONFIG.TotalFloors)
	signals.FloorLoaded:Fire(floorNumber, floorModel)
end

signals.FloorExitRequested.Event:Connect(function(player)
	if state == "Gameplay" and player and participants[player] then
		floorAdvanceRequested = true
		remotes.Announcement:FireAllClients(player.DisplayName .. " opened the stairwell.")
	end
end)

--------------------------------------------------------------------------------
-- Phases
--------------------------------------------------------------------------------

local function runLobby()
	setState("Lobby")
	local function notEnoughPlayers()
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
local function runIntro()
	participants = {}
	for _, player in ipairs(Players:GetPlayers()) do
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

	local finished = {}
	local connection = remotes.CutsceneFinished.OnServerEvent:Connect(function(player)
		finished[player] = true
	end)
	countdown("", CONFIG.IntroDuration, function()
		for player in pairs(participants) do
			if not finished[player] then
				return false
			end
		end
		return true
	end)
	connection:Disconnect()

	for player in pairs(participants) do
		setMovementLocked(player, false)
	end
	return next(participants) ~= nil
end

local function tickSurvival(dt)
	for player in pairs(participants) do
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

local function runGameplay()
	roundFloorsCleared = 0
	floorAdvanceRequested = false
	for player in pairs(participants) do
		player:SetAttribute("Hunger", 100)
		player:SetAttribute("Thirst", 100)
		local profile = profiles[player]
		if profile then
			profile.roundsPlayed = profile.roundsPlayed + 1
		end
	end

	setState("Gameplay", { totalFloors = CONFIG.TotalFloors })
	loadFloor(CONFIG.TotalFloors)

	local remaining = CONFIG.RoundDuration
	while true do
		setTimer("Escape", remaining)
		task.wait(1)
		remaining = remaining - 1
		tickSurvival(1)

		if next(participants) == nil then
			return "AllDead"
		end
		if remaining <= 0 then
			return "TimeUp"
		end
		if floorAdvanceRequested then
			floorAdvanceRequested = false
			roundFloorsCleared = roundFloorsCleared + 1
			if currentFloor <= 1 then
				return "Escaped"
			end
			loadFloor(currentFloor - 1)
		end
	end
end

local function runRoundEnd(result)
	local escaped = result == "Escaped"
	local survivors = {}
	local survivorNames = {}
	for player in pairs(participants) do
		table.insert(survivors, player)
		table.insert(survivorNames, player.DisplayName)
		settleRun(player, escaped)
		if not escaped then
			inventoryClear(player)
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

	for player in pairs(profiles) do
		task.spawn(saveProfile, player)
	end

	countdown("Returning to lobby", CONFIG.RoundEndDuration)

	unloadFloor()
	currentFloor = 0
	Workspace:SetAttribute("CurrentFloor", 0)
	for _, player in ipairs(survivors) do
		if player.Parent == Players then
			task.spawn(function()
				pcall(function()
					player:LoadCharacter()
				end)
			end)
		end
	end
end

--------------------------------------------------------------------------------
-- Player lifecycle
--------------------------------------------------------------------------------

local function onCharacterAdded(player, character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			eliminate(player)
		end)
	end
end

local function onPlayerAdded(player)
	inventoryAddPlayer(player)
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
	inventoryLoad(player, profile.inventory)
	updateLeaderstats(player)
	remotes.GameState:FireClient(player, state, nil)
	remotes.FloorChanged:FireClient(player, currentFloor, CONFIG.TotalFloors)
end

local function onPlayerRemoving(player)
	-- Leaving mid-run counts as a death so the backpack cannot be banked.
	eliminate(player)
	saveProfile(player)
	profiles[player] = nil
	canSave[player] = nil
	inventoryRemovePlayer(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

task.spawn(function()
	while true do
		task.wait(CONFIG.AutosaveInterval)
		local snapshot = {}
		for player in pairs(profiles) do
			table.insert(snapshot, player)
		end
		for _, player in ipairs(snapshot) do
			saveProfile(player)
			task.wait(1) -- spread writes across the request budget
		end
	end
end)

game:BindToClose(function()
	local pending = 0
	for player in pairs(profiles) do
		pending = pending + 1
		task.spawn(function()
			saveProfile(player)
			pending = pending - 1
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
			warn("[Core] Round aborted: " .. tostring(err))
			for player in pairs(participants) do
				player:SetAttribute("InRun", false)
				setMovementLocked(player, false)
			end
			participants = {}
			unloadFloor()
			task.wait(3)
		end
	end
end)
