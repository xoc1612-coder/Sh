--!strict
--[[
	InteractionSystem (ModuleScript, ServerScriptService/Server)

	Server-authoritative interaction, inventory, doors, hiding and peeking.

	Flow: the client streams its camera ray (AimUpdate, unreliable, ~10 Hz). The
	server raycasts it, resolves the interactable under the crosshair and stores
	it as that player's focus. Key presses (InputAction) carry only the key, so
	a client can never act on something the server did not see it looking at.
	The prompt list is rebuilt from that same focus and sent only when it
	changes.

	World objects opt in with the CollectionService tag "Interactable" plus a
	"Kind" attribute: Door, Container, Item, HidingSpot, PeekSpot, Note, Exit.
	See README.md for the per-kind attributes.
]]

local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local InteractionSystem = {}

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local TAG = "Interactable"

local CONFIG = table.freeze({
	ReachDistance = 9, -- length of the interaction ray
	MaxAimOriginOffset = 5, -- how far the claimed camera may be from the character
	AimInterval = 0.08,
	ActionCooldown = 0.2,
	MaxSlots = 6,

	DoorMoveTime = 0.45,
	DefaultOpenAngle = 95,
	AjarAngle = 14,
	DefaultSlideDistance = 1.5,
	DoorHealth = 100,
	FistDoorDamage = 6,
	BreakCooldown = 0.7,

	PeekLeashDistance = 3, -- walking this far from the peek start ends it
	HideFallbackDistance = 4,
})

export type ItemKind = "Food" | "Drink" | "Medical" | "Weapon" | "Key" | "Misc"
export type ItemDef = {
	name: string,
	kind: ItemKind,
	verb: string?, -- label of the F action while held
	hunger: number?,
	thirst: number?,
	heal: number?,
	damage: number?, -- read by the combat code in ZombieAI
	doorDamage: number?,
}

local ITEMS: { [string]: ItemDef } = {
	CannedBeans = { name = "Canned Beans", kind = "Food", verb = "Eat", hunger = 35 },
	CannedSoup = { name = "Canned Soup", kind = "Food", verb = "Eat", hunger = 25, thirst = 10 },
	Crackers = { name = "Stale Crackers", kind = "Food", verb = "Eat", hunger = 12, thirst = -5 },
	WaterBottle = { name = "Water Bottle", kind = "Drink", verb = "Drink", thirst = 45 },
	Soda = { name = "Warm Soda", kind = "Drink", verb = "Drink", thirst = 25, hunger = 5 },
	Bandage = { name = "Bandage", kind = "Medical", verb = "Use", heal = 25 },
	Medkit = { name = "First Aid Kit", kind = "Medical", verb = "Use", heal = 70 },
	KitchenKnife = { name = "Kitchen Knife", kind = "Weapon", damage = 22, doorDamage = 8 },
	BaseballBat = { name = "Baseball Bat", kind = "Weapon", damage = 30, doorDamage = 18 },
	Crowbar = { name = "Crowbar", kind = "Weapon", damage = 26, doorDamage = 34 },
	Flashlight = { name = "Flashlight", kind = "Misc" },
	ApartmentKey = { name = "Apartment Key", kind = "Key" },
	StairwellKey = { name = "Stairwell Key", kind = "Key" },
}

type LootRoll = { id: string, weight: number } -- id "" rolls nothing

local LOOT_TABLES: { [string]: { LootRoll } } = {
	Kitchen = {
		{ id = "", weight = 40 },
		{ id = "CannedBeans", weight = 18 },
		{ id = "CannedSoup", weight = 14 },
		{ id = "Crackers", weight = 10 },
		{ id = "WaterBottle", weight = 10 },
		{ id = "Soda", weight = 5 },
		{ id = "KitchenKnife", weight = 3 },
	},
	Bathroom = {
		{ id = "", weight = 55 },
		{ id = "Bandage", weight = 28 },
		{ id = "WaterBottle", weight = 10 },
		{ id = "Medkit", weight = 7 },
	},
	Bedroom = {
		{ id = "", weight = 60 },
		{ id = "Flashlight", weight = 12 },
		{ id = "BaseballBat", weight = 8 },
		{ id = "Bandage", weight = 10 },
		{ id = "Crackers", weight = 10 },
	},
	Utility = {
		{ id = "", weight = 60 },
		{ id = "Crowbar", weight = 15 },
		{ id = "Flashlight", weight = 15 },
		{ id = "WaterBottle", weight = 10 },
	},
}

--------------------------------------------------------------------------------
-- Types and state
--------------------------------------------------------------------------------

type DoorState = "Closed" | "Ajar" | "Open" | "Broken"

-- Drives a hinged or sliding part from a single tweened number, so swings
-- follow a true arc instead of a lerped chord.
type Mover = {
	part: BasePart,
	mode: "Swing" | "Slide",
	pivot: CFrame, -- hinge, in world space
	offset: CFrame, -- part relative to the hinge
	value: NumberValue,
	connection: RBXScriptConnection,
	tween: Tween?,
}

type Entry = {
	root: PVInstance,
	kind: string,
	name: string,
	mover: Mover?,
	doorState: DoorState, -- doors and containers
	swingSign: number,
	locked: boolean,
	health: number,
	occupant: Player?, -- hiding spots
	peekers: number,
	used: boolean, -- container looted / exit triggered
}

type Session = {
	player: Player,
	inventory: { string },
	equipped: number?,
	focus: PVInstance?,
	promptSignature: string,
	lastAim: number,
	lastAction: number,
	lastSwing: number,
	hidingIn: PVInstance?,
	hideReturn: CFrame?,
	peekingAt: PVInstance?,
	peekOrigin: Vector3,
	rayParams: RaycastParams,
	rayCharacter: Model?,
	connections: { RBXScriptConnection },
}

type Action = { key: string, label: string, id: string }
export type Prompt = { key: string, label: string }

local registry: { [Instance]: Entry } = {}
local sessions: { [Player]: Session } = {}
local initialized = false

local function newRemote(name: string): RemoteEvent
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	return remote
end

-- Server -> client
local promptRemote = newRemote("PromptUpdate") -- (title: string?, prompts: {Prompt})
local inventoryRemote = newRemote("InventoryUpdate") -- (slots: {{id, name, kind}}, equippedSlot: number)
local hideRemote = newRemote("HideState") -- (hidden: boolean, spot: Instance?, spotType: string?)
local peekRemote = newRemote("PeekState") -- (peeking: boolean, camera: CFrame?)
local notifyRemote = newRemote("Notify") -- (style: "Hint" | "Note", title: string, text: string)
-- Client -> server
local inputRemote = newRemote("InputAction") -- (key: "E" | "F" | "Q" | "X")
local equipRemote = newRemote("EquipSlot") -- (slot: number)
local aimRemote = Instance.new("UnreliableRemoteEvent") -- (origin: Vector3, direction: Vector3)
aimRemote.Name = "AimUpdate"

local exitEvent = Instance.new("BindableEvent")
local noiseEvent = Instance.new("BindableEvent")

-- Fires (player) when a floor exit is opened.
InteractionSystem.ExitUsed = exitEvent.Event
-- Fires (position: Vector3, radius: number, source: Player?) for ZombieAI hearing.
InteractionSystem.NoiseEmitted = noiseEvent.Event
InteractionSystem.Items = ITEMS

local droppedFolder = Instance.new("Folder")
droppedFolder.Name = "DroppedItems"

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function attrString(instance: Instance, name: string, default: string): string
	local value = instance:GetAttribute(name)
	return if type(value) == "string" then value else default
end

local function attrNumber(instance: Instance, name: string, default: number): number
	local value = instance:GetAttribute(name)
	return if type(value) == "number" then value else default
end

local function attrBool(instance: Instance, name: string, default: boolean): boolean
	local value = instance:GetAttribute(name)
	return if type(value) == "boolean" then value else default
end

-- Root part of a living character, or nil.
local function getRootPart(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function getEntryPosition(entry: Entry): Vector3
	local mover = entry.mover
	return if mover then mover.part.Position else entry.root:GetPivot().Position
end

local function forEachPart(root: Instance, callback: (BasePart) -> ())
	if root:IsA("BasePart") then
		callback(root)
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			callback(descendant)
		end
	end
end

-- Plays an optional designer-supplied Sound (e.g. "Open", "Locked", "Break").
local function playSound(root: Instance, name: string)
	local sound = root:FindFirstChild(name, true)
	if sound and sound:IsA("Sound") then
		sound:Play()
	end
end

local function emitNoise(position: Vector3, radius: number, source: Player?)
	noiseEvent:Fire(position, radius, source)
end

local function notify(player: Player, style: string, title: string, text: string)
	notifyRemote:FireClient(player, style, title, text)
end

local function findAttachment(root: Instance, name: string): Attachment?
	local found = root:FindFirstChild(name, true)
	return if found and found:IsA("Attachment") then found else nil
end

--------------------------------------------------------------------------------
-- Movers (door / cabinet / drawer animation)
--------------------------------------------------------------------------------

local function createMover(root: PVInstance, mode: "Swing" | "Slide"): Mover?
	local part: BasePart? = nil
	local pivot = root:GetPivot()
	if root:IsA("Model") then
		part = root.PrimaryPart
	elseif root:IsA("BasePart") then
		part = root
		if root.PivotOffset == CFrame.identity then
			-- No authored pivot: hinge on the part's -X edge.
			pivot = root.CFrame * CFrame.new(-root.Size.X / 2, 0, 0)
		end
	end
	if not part then
		warn(`[Interaction] {root:GetFullName()} needs a PrimaryPart to move.`)
		return nil
	end

	local movingPart: BasePart = part
	local closed = movingPart.CFrame
	local offset = pivot:ToObjectSpace(closed)
	local value = Instance.new("NumberValue")
	local connection = value.Changed:Connect(function(amount: number)
		if mode == "Swing" then
			movingPart.CFrame = pivot * CFrame.Angles(0, math.rad(amount), 0) * offset
		else
			movingPart.CFrame = closed * CFrame.new(0, 0, -amount)
		end
	end)

	return {
		part = movingPart,
		mode = mode,
		pivot = pivot,
		offset = offset,
		value = value,
		connection = connection,
		tween = nil,
	}
end

local function moveTo(mover: Mover, target: number, duration: number)
	if mover.tween then
		mover.tween:Cancel()
	end
	local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(mover.value, info, { Value = target })
	mover.tween = tween
	tween:Play()
end

local function destroyMover(mover: Mover)
	if mover.tween then
		mover.tween:Cancel()
	end
	mover.connection:Disconnect()
	mover.value:Destroy()
end

-- +1 or -1 so that the door swings away from `from`.
local function swingSignFor(mover: Mover, from: Vector3): number
	local side = mover.pivot:PointToObjectSpace(from).Z > 0
	local extendsPositiveX = mover.offset.Position.X >= 0
	return if side == extendsPositiveX then 1 else -1
end

--------------------------------------------------------------------------------
-- Inventory
--------------------------------------------------------------------------------

local function sendInventory(session: Session)
	local slots = table.create(#session.inventory)
	for index, id in session.inventory do
		local def = ITEMS[id]
		slots[index] = { id = id, name = def.name, kind = def.kind }
	end
	local equippedId = if session.equipped then session.inventory[session.equipped] else nil
	-- Replicated so other systems (and other clients) can see what is held.
	session.player:SetAttribute("EquippedItem", equippedId or "")
	inventoryRemote:FireClient(session.player, slots, session.equipped or 0)
end

local function getEquipped(session: Session): (string?, ItemDef?)
	local slot = session.equipped
	local id = if slot then session.inventory[slot] else nil
	if not id then
		return nil, nil
	end
	return id, ITEMS[id]
end

local function hasItem(session: Session, id: string): number?
	return table.find(session.inventory, id)
end

local function addItem(session: Session, id: string): boolean
	if not ITEMS[id] or #session.inventory >= CONFIG.MaxSlots then
		return false
	end
	table.insert(session.inventory, id)
	sendInventory(session)
	return true
end

local function removeSlot(session: Session, slot: number): string?
	local id = session.inventory[slot]
	if not id then
		return nil
	end
	table.remove(session.inventory, slot)
	local equipped = session.equipped
	if equipped == slot then
		session.equipped = nil
	elseif equipped and equipped > slot then
		session.equipped = equipped - 1
	end
	sendInventory(session)
	return id
end

-- Creates a pickup in the world. Uses ServerStorage.ItemModels[itemId] when it
-- exists, otherwise a placeholder block.
local function spawnWorldItem(itemId: string, cframe: CFrame): PVInstance?
	local def = ITEMS[itemId]
	if not def then
		return nil
	end
	local models = ServerStorage:FindFirstChild("ItemModels")
	local template = models and models:FindFirstChild(itemId)
	local instance: PVInstance
	if template and template:IsA("PVInstance") then
		instance = template:Clone()
	else
		local part = Instance.new("Part")
		part.Size = Vector3.new(0.8, 0.8, 0.8)
		part.Anchored = true
		part.Color = Color3.fromRGB(150, 140, 120)
		instance = part
	end
	instance.Name = itemId
	instance:SetAttribute("Kind", "Item")
	instance:SetAttribute("ItemId", itemId)
	instance:SetAttribute("DisplayName", def.name)
	instance:PivotTo(cframe)
	instance.Parent = droppedFolder
	CollectionService:AddTag(instance, TAG)
	return instance
end

-- Finds the floor in front of the player so drops do not hang in the air.
local function getDropCFrame(session: Session, rootPart: BasePart, spread: number): CFrame
	local angle = math.random() * math.pi * 2
	local scatter = Vector3.new(math.cos(angle), 0, math.sin(angle)) * spread
	local origin = rootPart.Position + rootPart.CFrame.LookVector * 2.5 + scatter
	local hit = Workspace:Raycast(origin, Vector3.new(0, -12, 0), session.rayParams)
	local position = if hit then hit.Position + Vector3.new(0, 0.4, 0) else rootPart.Position
	return CFrame.new(position) * CFrame.Angles(0, angle, 0)
end

--------------------------------------------------------------------------------
-- Prompts
--------------------------------------------------------------------------------

local function canOperateLock(session: Session, entry: Entry): boolean
	if attrBool(entry.root, "Deadbolt", false) then
		return true
	end
	local keyId = attrString(entry.root, "KeyId", "")
	return keyId ~= "" and hasItem(session, keyId) ~= nil
end

-- Single source of truth for what each key does on the focused object. Both
-- the prompt list and the input handler read it, so they cannot disagree.
local function getFocusActions(session: Session, entry: Entry): { Action }
	local actions: { Action } = {}
	local function add(key: string, label: string, id: string)
		table.insert(actions, { key = key, label = label, id = id })
	end

	local kind = entry.kind
	if kind == "Door" then
		if entry.doorState == "Broken" then
			return actions
		elseif entry.locked then
			add("E", if canOperateLock(session, entry) then "Unlock" else "Locked", "Unlock")
			add("X", "Break Down", "Break")
		elseif entry.doorState == "Closed" then
			add("E", "Open", "Open")
			add("F", "Peek", "Peek")
			if canOperateLock(session, entry) then
				add("X", "Lock", "Lock")
			end
		elseif entry.doorState == "Ajar" then
			add("E", "Open", "Open")
			add("F", "Close", "Close")
		else
			add("E", "Close", "Close")
		end
	elseif kind == "Container" then
		add("E", if entry.doorState == "Open" then "Close" else "Open", "Toggle")
	elseif kind == "Item" then
		add("E", if #session.inventory >= CONFIG.MaxSlots then "Inventory Full" else "Pick Up", "PickUp")
	elseif kind == "HidingSpot" then
		add("E", if entry.occupant then "Occupied" else "Hide", "Hide")
	elseif kind == "PeekSpot" then
		add("E", "Peek", "Peek")
	elseif kind == "Note" then
		add("E", "Read", "Read")
	elseif kind == "Exit" then
		add("E", attrString(entry.root, "PromptLabel", "Enter Stairwell"), "Exit")
	end
	return actions
end

local function getFocusEntry(session: Session): Entry?
	local focus = session.focus
	return if focus then registry[focus] else nil
end

local function buildPrompts(session: Session): (string?, { Prompt })
	local prompts: { Prompt } = {}
	if session.hidingIn then
		table.insert(prompts, { key = "E", label = "Leave Hiding Spot" })
		return nil, prompts
	end
	if session.peekingAt then
		table.insert(prompts, { key = "E", label = "Stop Peeking" })
		return nil, prompts
	end

	local title: string? = nil
	local taken: { [string]: boolean } = {}
	local entry = getFocusEntry(session)
	if entry then
		title = entry.name
		for _, action in getFocusActions(session, entry) do
			taken[action.key] = true
			table.insert(prompts, { key = action.key, label = action.label })
		end
	end

	-- Held-item actions fill whichever keys the focused object left free.
	local _, def = getEquipped(session)
	if def then
		if def.verb and not taken.F then
			table.insert(prompts, { key = "F", label = def.verb })
		end
		if not taken.Q then
			table.insert(prompts, { key = "Q", label = "Put Away" })
		end
		if not taken.X then
			table.insert(prompts, { key = "X", label = "Drop" })
		end
	end
	return title, prompts
end

local function sendPrompts(session: Session)
	local title, prompts = buildPrompts(session)
	local parts = table.create(#prompts + 1)
	parts[1] = title or ""
	for index, prompt in prompts do
		parts[index + 1] = prompt.key .. ":" .. prompt.label
	end
	local signature = table.concat(parts, "|")
	if signature ~= session.promptSignature then
		session.promptSignature = signature
		promptRemote:FireClient(session.player, title, prompts)
	end
end

-- World state is shared, so one player's action can change another's prompts.
-- The signature check keeps this from sending anything that did not change.
local function refreshAllPrompts()
	for _, session in sessions do
		sendPrompts(session)
	end
end

--------------------------------------------------------------------------------
-- Hiding and peeking
--------------------------------------------------------------------------------

local function stopPeeking(session: Session)
	local target = session.peekingAt
	if not target then
		return
	end
	session.peekingAt = nil
	local entry = registry[target]
	if entry then
		entry.peekers = math.max(0, entry.peekers - 1)
		-- The crack only stays open while someone is looking through it.
		if entry.kind == "Door" and entry.doorState == "Ajar" and entry.peekers == 0 then
			entry.doorState = "Closed"
			entry.root:SetAttribute("State", "Closed")
			if entry.mover then
				moveTo(entry.mover, 0, CONFIG.DoorMoveTime * 0.5)
			end
		end
	end
	peekRemote:FireClient(session.player, false, nil)
end

local function getPeekCFrame(entry: Entry, from: Vector3): CFrame
	local attachment = if entry.kind == "PeekSpot" then findAttachment(entry.root, "PeekPoint") else nil
	if attachment then
		return attachment.WorldCFrame
	end
	local mover = entry.mover
	local eyeHeight = from.Y + 1.5
	if mover then
		-- Eye sits just outside the latch edge, looking through the gap.
		local side = if mover.pivot:PointToObjectSpace(from).Z > 0 then 1 else -1
		local latchX = mover.offset.Position.X * 2
		local eye = mover.pivot:PointToWorldSpace(Vector3.new(latchX, 0, side * 1.25))
		local target = mover.pivot:PointToWorldSpace(Vector3.new(latchX * 0.5, 0, -side * 6))
		return CFrame.lookAt(Vector3.new(eye.X, eyeHeight, eye.Z), Vector3.new(target.X, eyeHeight, target.Z))
	end
	return CFrame.lookAt(Vector3.new(from.X, eyeHeight, from.Z), getEntryPosition(entry))
end

local function startPeeking(session: Session, entry: Entry, rootPart: BasePart)
	if entry.kind == "Door" then
		local mover = entry.mover
		if not mover then
			return
		end
		if entry.doorState == "Closed" then
			entry.swingSign = swingSignFor(mover, rootPart.Position)
			entry.doorState = "Ajar"
			entry.root:SetAttribute("State", "Ajar")
			moveTo(mover, entry.swingSign * CONFIG.AjarAngle, CONFIG.DoorMoveTime)
			playSound(entry.root, "Creak")
			emitNoise(mover.part.Position, 10, session.player)
		end
	end
	entry.peekers += 1
	session.peekingAt = entry.root
	session.peekOrigin = rootPart.Position
	peekRemote:FireClient(session.player, true, getPeekCFrame(entry, rootPart.Position))
end

local function exitHiding(session: Session)
	local spot = session.hidingIn
	if not spot then
		return
	end
	session.hidingIn = nil
	local player = session.player
	local entry = registry[spot]
	if entry and entry.occupant == player then
		entry.occupant = nil
	end

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if character and rootPart and rootPart:IsA("BasePart") then
		local exitPoint = findAttachment(spot, "ExitPoint")
		local target = if exitPoint then exitPoint.WorldCFrame else session.hideReturn
		if target then
			character:PivotTo(target)
		end
		rootPart.Anchored = false
	end
	session.hideReturn = nil
	player:SetAttribute("Hidden", false)
	hideRemote:FireClient(player, false, nil, nil)
	playSound(spot, "Exit")
end

local function enterHiding(session: Session, entry: Entry, rootPart: BasePart)
	local player = session.player
	local character = player.Character
	if entry.occupant or not character then
		return
	end
	entry.occupant = player
	session.hidingIn = entry.root
	session.hideReturn = rootPart.CFrame

	local hidePoint = findAttachment(entry.root, "HidePoint")
	-- Anchored so physics and zombies cannot shove the player back out.
	rootPart.Anchored = true
	character:PivotTo(if hidePoint then hidePoint.WorldCFrame else entry.root:GetPivot())

	-- ZombieAI reads this attribute to drop the player from its vision checks.
	player:SetAttribute("Hidden", true)
	hideRemote:FireClient(player, true, entry.root, attrString(entry.root, "SpotType", "Closet"))
	playSound(entry.root, "Enter")
	emitNoise(rootPart.Position, 12, player)
end

-- Releases hide/peek state without touching the character (dead or gone).
local function clearStates(session: Session)
	stopPeeking(session)
	local spot = session.hidingIn
	if spot then
		session.hidingIn = nil
		session.hideReturn = nil
		local entry = registry[spot]
		if entry and entry.occupant == session.player then
			entry.occupant = nil
		end
		session.player:SetAttribute("Hidden", false)
		hideRemote:FireClient(session.player, false, nil, nil)
	end
end

--------------------------------------------------------------------------------
-- Doors and containers
--------------------------------------------------------------------------------

local function setLocked(entry: Entry, locked: boolean)
	entry.locked = locked
	entry.root:SetAttribute("Locked", locked)
end

local function openDoor(entry: Entry, from: Vector3?)
	local mover = entry.mover
	if entry.doorState == "Closed" and mover and from then
		entry.swingSign = swingSignFor(mover, from)
	end
	entry.doorState = "Open"
	entry.root:SetAttribute("State", "Open")
	if mover then
		moveTo(mover, entry.swingSign * attrNumber(entry.root, "OpenAngle", CONFIG.DefaultOpenAngle), CONFIG.DoorMoveTime)
	end
	playSound(entry.root, "Open")
end

local function closeDoor(entry: Entry)
	-- Shutting a door ends every peek through it.
	if entry.peekers > 0 then
		for _, session in sessions do
			if session.peekingAt == entry.root then
				stopPeeking(session)
			end
		end
	end
	entry.doorState = "Closed"
	entry.root:SetAttribute("State", "Closed")
	if entry.mover then
		moveTo(entry.mover, 0, CONFIG.DoorMoveTime)
	end
	playSound(entry.root, "Close")
end

local function breakDoor(entry: Entry)
	local position = getEntryPosition(entry)
	entry.doorState = "Broken"
	entry.root:SetAttribute("State", "Broken")
	setLocked(entry, false)
	for _, session in sessions do
		if session.peekingAt == entry.root then
			stopPeeking(session)
		end
		if session.focus == entry.root then
			session.focus = nil
		end
	end
	if entry.mover then
		destroyMover(entry.mover)
		entry.mover = nil
	end
	-- The slab stops blocking movement, rays and pathfinding, then fades out.
	local fade = TweenInfo.new(0.35)
	forEachPart(entry.root, function(part)
		part.CanCollide = false
		part.CanQuery = false
		TweenService:Create(part, fade, { Transparency = 1 }):Play()
	end)
	playSound(entry.root, "Break")
	emitNoise(position, 90, nil)
end

local function rollLoot(tableName: string): string?
	local rolls = LOOT_TABLES[tableName]
	if not rolls then
		return nil
	end
	local total = 0
	for _, roll in rolls do
		total += roll.weight
	end
	local pick = math.random() * total
	for _, roll in rolls do
		pick -= roll.weight
		if pick <= 0 then
			return if roll.id ~= "" then roll.id else nil
		end
	end
	return nil
end

-- Random loot appears once, at each "LootPoint" attachment, after the first open.
local function spawnContainerLoot(entry: Entry)
	local tableName = attrString(entry.root, "LootTable", "")
	if entry.used or tableName == "" then
		return
	end
	entry.used = true
	task.delay(CONFIG.DoorMoveTime, function()
		if registry[entry.root] ~= entry then
			return -- floor unloaded in the meantime
		end
		for _, descendant in entry.root:GetDescendants() do
			if descendant:IsA("Attachment") and descendant.Name == "LootPoint" then
				local itemId = rollLoot(tableName)
				if itemId then
					spawnWorldItem(itemId, descendant.WorldCFrame)
				end
			end
		end
	end)
end

local function toggleContainer(entry: Entry)
	local mover = entry.mover
	local opening = entry.doorState ~= "Open"
	entry.doorState = if opening then "Open" else "Closed"
	entry.root:SetAttribute("State", entry.doorState)
	if mover then
		local target = 0
		if opening then
			target = if mover.mode == "Slide"
				then attrNumber(entry.root, "SlideDistance", CONFIG.DefaultSlideDistance)
				else attrNumber(entry.root, "OpenAngle", CONFIG.DefaultOpenAngle)
		end
		moveTo(mover, target, CONFIG.DoorMoveTime)
	end
	playSound(entry.root, if opening then "Open" else "Close")
	if opening then
		spawnContainerLoot(entry)
	end
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

local function performFocusAction(session: Session, entry: Entry, actionId: string, rootPart: BasePart)
	local player = session.player
	local root = entry.root
	local position = getEntryPosition(entry)

	if actionId == "Open" then
		openDoor(entry, rootPart.Position)
		emitNoise(position, 25, player)
	elseif actionId == "Close" then
		closeDoor(entry)
		emitNoise(position, 20, player)
	elseif actionId == "Peek" then
		startPeeking(session, entry, rootPart)
	elseif actionId == "Lock" then
		setLocked(entry, true)
		playSound(root, "Lock")
	elseif actionId == "Unlock" then
		if canOperateLock(session, entry) then
			setLocked(entry, false)
			playSound(root, "Unlock")
			local keyId = attrString(root, "KeyId", "")
			local slot = hasItem(session, keyId)
			if slot and attrBool(root, "ConsumeKey", false) then
				removeSlot(session, slot)
			end
		else
			playSound(root, "Locked")
			notify(player, "Hint", "", "It's locked.")
			emitNoise(position, 15, player) -- rattling the handle is audible
		end
	elseif actionId == "Break" then
		local now = os.clock()
		if now - session.lastSwing < CONFIG.BreakCooldown then
			return
		end
		session.lastSwing = now
		local _, def = getEquipped(session)
		local damage = if def and def.kind == "Weapon" then def.doorDamage or CONFIG.FistDoorDamage else CONFIG.FistDoorDamage
		InteractionSystem.DamageDoor(root, damage)
	elseif actionId == "Toggle" then
		toggleContainer(entry)
		emitNoise(position, 18, player)
	elseif actionId == "PickUp" then
		local itemId = attrString(root, "ItemId", "")
		if not ITEMS[itemId] then
			warn(`[Interaction] {root:GetFullName()} has unknown ItemId "{itemId}".`)
		elseif addItem(session, itemId) then
			playSound(root, "PickUp")
			root:Destroy() -- the tag-removed signal unregisters it
		else
			notify(player, "Hint", "", "You can't carry any more.")
		end
	elseif actionId == "Hide" then
		enterHiding(session, entry, rootPart)
	elseif actionId == "Read" then
		notify(player, "Note", entry.name, attrString(root, "Text", "..."))
	elseif actionId == "Exit" then
		if entry.used then
			return
		end
		local required = attrString(root, "RequiredItem", "")
		if required ~= "" then
			local slot = hasItem(session, required)
			if not slot then
				local def = ITEMS[required]
				notify(player, "Hint", "", `You need the {if def then def.name else required}.`)
				playSound(root, "Locked")
				return
			end
			removeSlot(session, slot)
		end
		entry.used = true
		playSound(root, "Open")
		exitEvent:Fire(player)
	end
end

local function performHeldAction(session: Session, key: string, rootPart: BasePart)
	local slot = session.equipped
	local id, def = getEquipped(session)
	if not slot or not id or not def then
		return
	end
	local player = session.player

	if key == "Q" then
		session.equipped = nil
		sendInventory(session)
	elseif key == "X" then
		removeSlot(session, slot)
		spawnWorldItem(id, getDropCFrame(session, rootPart, 0))
		emitNoise(rootPart.Position, 14, player)
	elseif key == "F" and def.verb then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if def.hunger then
			player:SetAttribute("Hunger", math.clamp(attrNumber(player, "Hunger", 100) + def.hunger, 0, 100))
		end
		if def.thirst then
			player:SetAttribute("Thirst", math.clamp(attrNumber(player, "Thirst", 100) + def.thirst, 0, 100))
		end
		if def.heal and humanoid then
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + def.heal)
		end
		removeSlot(session, slot)
		emitNoise(rootPart.Position, 8, player)
	end
end

--------------------------------------------------------------------------------
-- Remote handlers
--------------------------------------------------------------------------------

local function resolveEntry(hit: Instance): Entry?
	local current: Instance? = hit
	while current and current ~= Workspace do
		local entry = registry[current]
		if entry then
			return entry
		end
		current = current.Parent
	end
	return nil
end

local function onAimUpdate(player: Player, origin: any, direction: any)
	local session = sessions[player]
	if not session or typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		return
	end
	local now = os.clock()
	if now - session.lastAim < CONFIG.AimInterval then
		return
	end
	session.lastAim = now

	local rootPart = getRootPart(player)
	if not rootPart then
		if session.focus then
			session.focus = nil
			sendPrompts(session)
		end
		return
	end
	if session.hidingIn then
		return
	end
	if session.peekingAt then
		if (rootPart.Position - session.peekOrigin).Magnitude > CONFIG.PeekLeashDistance then
			stopPeeking(session)
			sendPrompts(session)
		end
		return
	end

	-- Written as `not (a <= b)` so NaN components fail the checks.
	local length = direction.Magnitude
	if not (length > 0.5 and length < 2) then
		return
	end
	if not ((origin - rootPart.Position).Magnitude <= CONFIG.MaxAimOriginOffset) then
		return
	end

	local character = player.Character
	if character ~= session.rayCharacter then
		session.rayCharacter = character
		session.rayParams.FilterDescendantsInstances = if character then { character } else {}
	end

	local result = Workspace:Raycast(origin, direction.Unit * CONFIG.ReachDistance, session.rayParams)
	local entry = if result then resolveEntry(result.Instance) else nil
	local focus = if entry then entry.root else nil
	if focus ~= session.focus then
		session.focus = focus
		sendPrompts(session)
	end
end

local function onInputAction(player: Player, key: any)
	local session = sessions[player]
	if not session or type(key) ~= "string" then
		return
	end
	local now = os.clock()
	if now - session.lastAction < CONFIG.ActionCooldown then
		return
	end
	session.lastAction = now

	local rootPart = getRootPart(player)
	if not rootPart then
		return
	end

	if session.hidingIn then
		if key == "E" then
			exitHiding(session)
		end
	elseif session.peekingAt then
		if key == "E" then
			stopPeeking(session)
		end
	else
		local handled = false
		local entry = getFocusEntry(session)
		-- Focus can be up to one aim tick stale, so re-check the distance.
		if entry and (getEntryPosition(entry) - rootPart.Position).Magnitude <= CONFIG.ReachDistance + 6 then
			for _, action in getFocusActions(session, entry) do
				if action.key == key then
					handled = true
					performFocusAction(session, entry, action.id, rootPart)
					break
				end
			end
		end
		if not handled then
			performHeldAction(session, key, rootPart)
		end
	end
	refreshAllPrompts()
end

local function onEquipSlot(player: Player, slot: any)
	local session = sessions[player]
	if not session or type(slot) ~= "number" or slot % 1 ~= 0 then
		return
	end
	if session.hidingIn or not session.inventory[slot] then
		return
	end
	session.equipped = if session.equipped == slot then nil else slot
	sendInventory(session)
	sendPrompts(session)
end

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

local VALID_KINDS = table.freeze({
	Door = true,
	Container = true,
	Item = true,
	HidingSpot = true,
	PeekSpot = true,
	Note = true,
	Exit = true,
})

local function register(root: Instance)
	-- Templates in ServerStorage carry the tag too; only live objects count.
	if registry[root] or not root:IsDescendantOf(Workspace) then
		return
	end
	if not root:IsA("PVInstance") then
		warn(`[Interaction] {root:GetFullName()} must be a Model or BasePart.`)
		return
	end
	local kind = attrString(root, "Kind", "")
	if not VALID_KINDS[kind] then
		warn(`[Interaction] {root:GetFullName()} has invalid Kind "{kind}".`)
		return
	end

	local entry: Entry = {
		root = root,
		kind = kind,
		name = attrString(root, "DisplayName", root.Name),
		mover = nil,
		doorState = "Closed",
		swingSign = 1,
		locked = false,
		health = 0,
		occupant = nil,
		peekers = 0,
		used = false,
	}
	if kind == "Door" then
		entry.mover = createMover(root, "Swing")
		entry.locked = attrBool(root, "Locked", false)
		entry.health = attrNumber(root, "Health", CONFIG.DoorHealth)
		root:SetAttribute("State", "Closed")
		root:SetAttribute("Locked", entry.locked)
		root:SetAttribute("Health", entry.health)
	elseif kind == "Container" then
		local mode: "Swing" | "Slide" = if attrString(root, "Motion", "Swing") == "Slide" then "Slide" else "Swing"
		entry.mover = createMover(root, mode)
		root:SetAttribute("State", "Closed")
	end
	registry[root] = entry
end

local function unregister(root: Instance)
	local entry = registry[root]
	if not entry then
		return
	end
	registry[root] = nil
	if entry.mover then
		destroyMover(entry.mover)
		entry.mover = nil
	end
	for _, session in sessions do
		if session.hidingIn == root then
			exitHiding(session)
		end
		if session.peekingAt == root then
			stopPeeking(session)
		end
		if session.focus == root then
			session.focus = nil
		end
		sendPrompts(session)
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Parents the remotes into `remoteFolder` and starts listening. Call once.
function InteractionSystem.Init(remoteFolder: Instance)
	if initialized then
		return
	end
	initialized = true

	for _, remote in { promptRemote, inventoryRemote, hideRemote, peekRemote, notifyRemote, inputRemote, equipRemote } do
		remote.Parent = remoteFolder
	end
	aimRemote.Parent = remoteFolder
	droppedFolder.Parent = Workspace

	aimRemote.OnServerEvent:Connect(onAimUpdate)
	inputRemote.OnServerEvent:Connect(onInputAction)
	equipRemote.OnServerEvent:Connect(onEquipSlot)

	CollectionService:GetInstanceAddedSignal(TAG):Connect(register)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unregister)
	for _, instance in CollectionService:GetTagged(TAG) do
		register(instance)
	end
end

function InteractionSystem.AddPlayer(player: Player)
	if sessions[player] then
		return
	end
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local session: Session = {
		player = player,
		inventory = {},
		equipped = nil,
		focus = nil,
		promptSignature = "",
		lastAim = 0,
		lastAction = 0,
		lastSwing = 0,
		hidingIn = nil,
		hideReturn = nil,
		peekingAt = nil,
		peekOrigin = Vector3.zero,
		rayParams = rayParams,
		rayCharacter = nil,
		connections = {},
	}
	sessions[player] = session
	player:SetAttribute("Hidden", false)
	player:SetAttribute("EquippedItem", "")

	-- Dying or respawning must free the hiding spot and close the peek.
	table.insert(
		session.connections,
		player.CharacterRemoving:Connect(function()
			clearStates(session)
			session.focus = nil
			sendPrompts(session)
		end)
	)
end

function InteractionSystem.RemovePlayer(player: Player)
	local session = sessions[player]
	if not session then
		return
	end
	clearStates(session)
	for _, connection in session.connections do
		connection:Disconnect()
	end
	sessions[player] = nil
end

-- Replaces the player's backpack with saved item ids, dropping unknown ones.
function InteractionSystem.LoadInventory(player: Player, itemIds: { string })
	local session = sessions[player]
	if not session then
		return
	end
	local inventory: { string } = {}
	for _, id in itemIds do
		if ITEMS[id] and #inventory < CONFIG.MaxSlots then
			table.insert(inventory, id)
		end
	end
	session.inventory = inventory
	session.equipped = nil
	sendInventory(session)
	sendPrompts(session)
end

function InteractionSystem.SerializeInventory(player: Player): { string }
	local session = sessions[player]
	return if session then table.clone(session.inventory) else {}
end

-- Empties the backpack. With `dropItems`, the contents are scattered at the
-- player's feet (used on death).
function InteractionSystem.ClearInventory(player: Player, dropItems: boolean)
	local session = sessions[player]
	if not session then
		return
	end
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if dropItems and rootPart and rootPart:IsA("BasePart") then
		for _, id in session.inventory do
			spawnWorldItem(id, getDropCFrame(session, rootPart, 2))
		end
	end
	session.inventory = {}
	session.equipped = nil
	sendInventory(session)
	sendPrompts(session)
end

function InteractionSystem.GiveItem(player: Player, itemId: string): boolean
	local session = sessions[player]
	if not session or not addItem(session, itemId) then
		return false
	end
	sendPrompts(session)
	return true
end

function InteractionSystem.GetEquippedItem(player: Player): (string?, ItemDef?)
	local session = sessions[player]
	if not session then
		return nil, nil
	end
	return getEquipped(session)
end

function InteractionSystem.IsHidden(player: Player): boolean
	local session = sessions[player]
	return session ~= nil and session.hidingIn ~= nil
end

-- Pulls a player out of their hiding spot (a zombie found them).
function InteractionSystem.EjectFromHiding(player: Player)
	local session = sessions[player]
	if session and session.hidingIn then
		exitHiding(session)
		sendPrompts(session)
	end
end

-- Damages a door; it breaks at zero health. Shared by players and zombies.
-- Returns true once the door is broken.
function InteractionSystem.DamageDoor(door: Instance, amount: number): boolean
	local entry = registry[door]
	if not entry or entry.kind ~= "Door" then
		return false
	end
	if entry.doorState == "Broken" then
		return true
	end
	entry.health = math.max(0, entry.health - amount)
	entry.root:SetAttribute("Health", entry.health)
	if entry.health <= 0 then
		breakDoor(entry)
		refreshAllPrompts()
		return true
	end
	playSound(entry.root, "Hit")
	emitNoise(getEntryPosition(entry), 60, nil)
	return false
end

-- Lets zombies push through unlocked doors. Returns false if it stays shut.
function InteractionSystem.ForceOpenDoor(door: Instance, from: Vector3): boolean
	local entry = registry[door]
	if not entry or entry.kind ~= "Door" then
		return false
	end
	if entry.doorState == "Open" or entry.doorState == "Broken" then
		return true
	end
	if entry.locked then
		return false
	end
	openDoor(entry, from)
	refreshAllPrompts()
	return true
end

-- Called before a floor is unloaded: frees every player and removes drops.
function InteractionSystem.ResetWorldState()
	for _, session in sessions do
		if session.hidingIn then
			exitHiding(session)
		end
		stopPeeking(session)
		session.focus = nil
		sendPrompts(session)
	end
	droppedFolder:ClearAllChildren()
end

return InteractionSystem
