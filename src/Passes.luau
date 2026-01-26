--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local State = require(script.Parent.State)
local Types = require(script.Parent.Types)

local PassOwnershipCache = {} :: { [number]: { [number]: boolean } } -- userId -> passId -> owned
local PassOwnershipCallbacks = {} :: { [string]: { Types.PassOwnershipCallback } } -- key -> callbacks array
local PassOwnershipCallbacksFired = {} :: { [number]: { [number]: boolean } } -- userId -> passId -> fired

local SyncPassOwnershipRemote: RemoteEvent = nil :: any -- Initialized in Init

--- Internal function to attempt firing pass ownership callbacks for a player
--- Only fires if not already fired for this player/pass combination
local attempt_fire_pass_ownership_callbacks = function(
	player: Player,
	key: string,
	pass_id: number,
	was_just_purchased: boolean
)
	local user_id = player.UserId
	PassOwnershipCallbacksFired[user_id] = PassOwnershipCallbacksFired[user_id] or {}

	if PassOwnershipCallbacksFired[user_id][pass_id] then
		return -- Already fired
	end

	PassOwnershipCallbacksFired[user_id][pass_id] = true

	local callbacks = PassOwnershipCallbacks[key]
	if callbacks then
		for _, callback in callbacks do
			task.spawn(callback, player, was_just_purchased, key)
		end
	end
end

--- Internal function to grant pass ownership to a player
--- Updates cache and fires callbacks
local grant_pass_ownership = function(player: Player, key: string, was_just_purchased: boolean)
	local data = State.RegisteredPurchaseItems[key]
	if not data or data.Type ~= "Pass" then
		warn(`[MarketService] Cannot grant pass ownership: invalid key '{key}'`)
		return
	end

	local user_id = player.UserId
	local pass_id = data.AssetId

	PassOwnershipCache[user_id] = PassOwnershipCache[user_id] or {}
	PassOwnershipCache[user_id][pass_id] = true

	attempt_fire_pass_ownership_callbacks(player, key, pass_id, was_just_purchased)
end

--- Internal function to preload pass ownership for a player
local preload_player_passes = function(player: Player)
	local user_id = player.UserId
	PassOwnershipCache[user_id] = PassOwnershipCache[user_id] or {}

	for key, data in State.RegisteredPurchaseItems do
		if data.Type == "Pass" then
			local pass_id = data.AssetId
			local owned = false

			for attempt = 1, State.MAX_RETRY_ATTEMPTS do
				local success, result = pcall(function()
					return MarketplaceService:UserOwnsGamePassAsync(user_id, pass_id)
				end)

				if success then
					owned = result
					break
				else
					warn(
						`[MarketService] Failed to check pass {pass_id} ownership for {player.Name} ({user_id}), attempt {attempt}/{State.MAX_RETRY_ATTEMPTS}: {result}`
					)
					if attempt < State.MAX_RETRY_ATTEMPTS then
						task.wait(1) -- Brief delay before retry
					end
				end
			end

			-- Only update cache if not already marked as owned (preserves session passes)
			if PassOwnershipCache[user_id][pass_id] == nil then
				PassOwnershipCache[user_id][pass_id] = owned
			end

			if PassOwnershipCache[user_id][pass_id] then
				attempt_fire_pass_ownership_callbacks(player, key, pass_id, false)
			end
		end
	end
end

local Passes = {}

--[=[
	Returns an array of all registered pass keys

	@return { string } -- Array of pass keys
]=]
Passes.GetAllPassKeys = function(): { string }
	local keys = {}
	for key, data in State.RegisteredPurchaseItems do
		if data.Type == "Pass" then
			table.insert(keys, key)
		end
	end
	return keys
end

--[=[
	Checks if a pass is registered with the given key

	@param key string -- The key to check
	@return boolean -- Whether a pass is registered with this key
]=]
Passes.IsPassRegistered = function(key: string): boolean
	local data = State.RegisteredPurchaseItems[key]
	return data ~= nil and data.Type == "Pass"
end

-- Pre-initialisation

--[=[
	Registers a purchase item of type "Pass"

	@param key string -- The key to register the pass under
	@param pass_id number -- The Roblox pass ID
]=]
Passes.RegisterPass = function(key: string, pass_id: number)
	assert(
		not State.Initialised,
		"[MarketService] Cannot register new purchase items after MarketService has been initialised"
	)
	assert(
		State.RegisteredPurchaseItems[key] == nil,
		"[MarketService] Pass with key '" .. key .. "' is already registered"
	)

	-- Check for duplicate asset IDs
	for existingKey, existingData in State.RegisteredPurchaseItems do
		assert(
			existingData.AssetId ~= pass_id,
			`[MarketService] Asset ID {pass_id} is already registered under key '{existingKey}'`
		)
	end

	State.RegisteredPurchaseItems[key] = {
		Type = "Pass",
		AssetId = pass_id,
	}
end

--[=[
	Registers multiple purchase items of type "Pass"

	@param passes { [string]: number } -- A dictionary mapping keys to Roblox pass IDs
]=]
Passes.RegisterPasses = function(passes: { [string]: number })
	for key, pass_id in passes do
		Passes.RegisterPass(key, pass_id)
	end
end

--[=[
	Binds a callback to be invoked when a player owns a registered pass.
	The callback fires either when the pass is preloaded (player already owned it)
	or when they purchase it. It will only fire once per player per pass.
	Multiple callbacks can be bound to the same pass.

	Can be called before or after MarketService.Init().

	@param key string -- The key the pass was registered with
	@param callback PassOwnershipCallback -- The callback to invoke. Receives (player, was_just_purchased, key)
	@return () -> () -- A function that, when called, disconnects this callback
]=]
Passes.OnPassOwned = function(key: string, callback: Types.PassOwnershipCallback): () -> ()
	local data = State.RegisteredPurchaseItems[key]
	assert(data ~= nil, `[MarketService] No purchase item registered with key '{key}'`)
	assert(data.Type == "Pass", "[MarketService] Expected purchase item type to be 'Pass'")

	if not PassOwnershipCallbacks[key] then
		PassOwnershipCallbacks[key] = {}
	end
	table.insert(PassOwnershipCallbacks[key], callback)

	-- Fire callback for players whose ownership is already cached.
	-- Players still being checked will have callbacks fired by preload_player_passes.
	for user_id, user_cache in PassOwnershipCache do
		if user_cache[data.AssetId] then
			local player = Players:GetPlayerByUserId(user_id)
			if player then
				task.spawn(callback, player, false, key)
			end
		end
	end

	-- Return disconnect function
	return function()
		local callbacks = PassOwnershipCallbacks[key]
		if callbacks then
			local index = table.find(callbacks, callback)
			if index then
				table.remove(callbacks, index)
			end
		end
	end
end

-- Post-initialisation

--[=[
	Checks if a player owns a registered pass (from cache)

	@param key string -- The key the pass was registered with
	@param player Player? -- The player to check ownership for (server only). Must be nil when called from client.
	@return boolean -- Whether the player owns the pass (false if cache not yet populated)
]=]
Passes.PlayerOwnsPass = function(key: string, player: Player?): boolean
	assert(State.Initialised, "[MarketService] MarketService must be initialised before checking pass ownership")

	local resolved_player: Player
	if RunService:IsServer() then
		assert(player ~= nil, "[MarketService] Player must be provided when checking ownership from server")
		resolved_player = player
	else
		assert(player == nil, "[MarketService] Player must not be provided when checking ownership from client")
		resolved_player = Players.LocalPlayer :: Player
	end

	local data = State.RegisteredPurchaseItems[key]
	assert(data ~= nil, `[MarketService] No purchase item registered with key '{key}'`)
	assert(data.Type == "Pass", "[MarketService] Expected purchase item type to be 'Pass'")

	local user_cache = PassOwnershipCache[resolved_player.UserId]
	if user_cache == nil then
		return false
	end

	return user_cache[data.AssetId] or false
end

--[=[
	Returns the product info for a registered pass purchase item

	@yields
	@param key string -- The key the pass was registered with
	@return MarketplaceServiceProductInfo -- The pass info
]=]
Passes.GetPassInfoAsync = function(key: string): Types.MarketplaceServiceProductInfo
	assert(State.Initialised, "[MarketService] MarketService must be initialised before getting pass info")

	local data = State.RegisteredPurchaseItems[key]
	assert(data ~= nil, `[MarketService] No purchase item registered with key '{key}'`)
	assert(data.Type == "Pass", "[MarketService] Expected purchase item type to be 'Pass'")

	if RunService:IsServer() then
		warn(
			"[MarketService] GetGamePassInfoAsync called from server; this won't take into account player-specific pricing or other features. Consider calling from client instead."
		)
	end

	local lastError: string? = nil
	for attempt = 1, State.MAX_RETRY_ATTEMPTS do
		local success, result = pcall(function()
			return MarketplaceService:GetProductInfo(data.AssetId, Enum.InfoType.GamePass)
		end)

		if success then
			return result
		else
			lastError = result
			warn(
				`[MarketService] Failed to get pass info for '{key}', attempt {attempt}/{State.MAX_RETRY_ATTEMPTS}: {result}`
			)
			if attempt < State.MAX_RETRY_ATTEMPTS then
				task.wait(1)
			end
		end
	end

	error(`[MarketService] Failed to get pass info for '{key}' after {State.MAX_RETRY_ATTEMPTS} attempts: {lastError}`)
end

--[=[
	Prompts the purchase prompt for a registered pass purchase item.

	@param key string -- The key the pass was registered with
	@param player Player? -- The player to prompt the purchase for (server only). Must be nil when called from client.
]=]
Passes.PromptPassPurchase = function(key: string, player: Player?)
	assert(State.Initialised, "[MarketService] MarketService must be initialised before prompting purchases")

	if RunService:IsServer() then
		assert(player ~= nil, "[MarketService] Player must be provided when prompting purchase from server")
	else
		assert(player == nil, "[MarketService] Player must not be provided when prompting purchase from client")
		player = Players.LocalPlayer
	end

	local data = State.RegisteredPurchaseItems[key]
	assert(data ~= nil, `[MarketService] No purchase item registered with key '{key}'`)
	assert(data.Type == "Pass", "[MarketService] Expected purchase item type to be 'Pass'")

	MarketplaceService:PromptGamePassPurchase(player, data.AssetId)
end

--[=[
	Awards a player temporary ownership of a pass for the current session.
	This updates the local cache as if they purchased it and fires ownership callbacks.
	Server-only function that replicates to the client.

	@param player Player -- The player to award the pass to
	@param key string -- The key the pass was registered with
	@param was_just_purchased boolean? -- Whether to treat this as a fresh purchase (default: false)
]=]
Passes.AwardSessionPass = function(player: Player, key: string, was_just_purchased: boolean?)
	assert(State.Initialised, "[MarketService] MarketService must be initialised before awarding session passes")
	assert(RunService:IsServer(), "[MarketService] AwardSessionPass can only be called from the server")

	local data = State.RegisteredPurchaseItems[key]
	assert(data ~= nil, `[MarketService] No purchase item registered with key '{key}'`)
	assert(data.Type == "Pass", "[MarketService] Expected purchase item type to be 'Pass'")

	local was_purchased = was_just_purchased or false

	-- Grant ownership on server
	grant_pass_ownership(player, key, was_purchased)

	-- Sync to client
	SyncPassOwnershipRemote:FireClient(player, key, was_purchased)
end

-- Initialization

--[=[
	Initialises the Passes module, setting up ownership caching and purchase listening.
	Called internally by MarketService.Init()
]=]
Passes.Init = function()
	-- Setup sync remote
	if RunService:IsServer() then
		SyncPassOwnershipRemote = Instance.new("RemoteEvent")
		SyncPassOwnershipRemote.Name = "SyncPassOwnership"
		SyncPassOwnershipRemote.Parent = script.Parent
	else
		task.spawn(function()
			SyncPassOwnershipRemote = script.Parent:WaitForChild("SyncPassOwnership") :: RemoteEvent
			SyncPassOwnershipRemote.OnClientEvent:Connect(function(key: string, was_just_purchased: boolean)
				local local_player = Players.LocalPlayer
				if local_player then
					grant_pass_ownership(local_player, key, was_just_purchased)
				end
			end)
		end)
	end

	-- Preload pass ownership cache
	if RunService:IsServer() then
		-- Server: preload all current players and listen for new players
		for _, player in Players:GetPlayers() do
			task.spawn(preload_player_passes, player)
		end
		Players.PlayerAdded:Connect(function(player)
			task.spawn(preload_player_passes, player)
		end)
		Players.PlayerRemoving:Connect(function(player)
			PassOwnershipCache[player.UserId] = nil
			PassOwnershipCallbacksFired[player.UserId] = nil
		end)
	else
		-- Client: preload only LocalPlayer
		local local_player = Players.LocalPlayer
		if local_player then
			task.spawn(preload_player_passes, local_player)
		end
	end

	-- Listen for pass purchases to update cache
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, pass_id, was_purchased)
		if was_purchased then
			-- Find the key for this pass_id and grant ownership
			for key, data in State.RegisteredPurchaseItems do
				if data.Type == "Pass" and data.AssetId == pass_id then
					grant_pass_ownership(player, key, true)

					-- Server syncs to client
					if RunService:IsServer() then
						SyncPassOwnershipRemote:FireClient(player, key, true)
					end
					break
				end
			end
		end
	end)
end

return Passes
