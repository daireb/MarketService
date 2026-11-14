--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Finished = require(script.Parent.Finished)
local State = require(script.Parent.State)
local Types = require(script.Parent.Types)

-- Keyed by pass key rather than pass id, since unlisted passes have no id.
local PassOwnershipCache = {} :: { [number]: { [string]: boolean } } -- userId -> key -> owned
local PassOwnershipCallbacks = {} :: { [string]: { Types.PassOwnershipCallback } } -- key -> callbacks array
local PassOwnershipCallbacksFired = {} :: { [number]: { [string]: boolean } } -- userId -> key -> fired

local SyncPassOwnershipRemote: RemoteEvent = nil :: any -- Initialized in Init

--- Internal function to attempt firing pass ownership callbacks for a player
--- Only fires if not already fired for this player/pass combination
local attempt_fire_pass_ownership_callbacks = function(player: Player, key: string, was_just_purchased: boolean)
	local user_id = player.UserId
	PassOwnershipCallbacksFired[user_id] = PassOwnershipCallbacksFired[user_id] or {}

	if PassOwnershipCallbacksFired[user_id][key] then
		return -- Already fired
	end

	PassOwnershipCallbacksFired[user_id][key] = true

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

	PassOwnershipCache[user_id] = PassOwnershipCache[user_id] or {}
	PassOwnershipCache[user_id][key] = true

	attempt_fire_pass_ownership_callbacks(player, key, was_just_purchased)
end

--- Internal function to preload pass ownership for a player.
--- Unlisted passes are skipped: only AwardSessionPass grants them.
local preload_player_passes = function(player: Player)
	local user_id = player.UserId
	PassOwnershipCache[user_id] = PassOwnershipCache[user_id] or {}

	for key, data in State.RegisteredPurchaseItems do
		local pass_id = data.AssetId
		if data.Type == "Pass" and pass_id ~= nil then
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
			if PassOwnershipCache[user_id][key] == nil then
				PassOwnershipCache[user_id][key] = owned
			end

			if PassOwnershipCache[user_id][key] then
				attempt_fire_pass_ownership_callbacks(player, key, false)
			end
		end
	end
end

local assert_pass = function(key: string): Types.PurchaseItem
	local data = State.RegisteredPurchaseItems[key]
	assert(data ~= nil, `[MarketService] No purchase item registered with key '{key}'`)
	assert(data.Type == "Pass", "[MarketService] Expected purchase item type to be 'Pass'")
	return data
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
	Checks if a pass is registered with the given key, listed or not

	@param key string -- The key to check
	@return boolean -- Whether a pass is registered with this key
]=]
Passes.IsPassRegistered = function(key: string): boolean
	local data = State.RegisteredPurchaseItems[key]
	return data ~= nil and data.Type == "Pass"
end

-- Pre-initialisation

--[=[
	Registers a purchase item of type "Pass". Without a pass id the pass is unlisted: it can't
	be prompted or looked up on Roblox, and a player owns it only through AwardSessionPass.

	@param key string -- The key to register the pass under
	@param pass_id number? -- The Roblox pass ID, or nil for an unlisted pass
]=]
Passes.RegisterPass = function(key: string, pass_id: number?)
	assert(
		not State.Initialised,
		"[MarketService] Cannot register new purchase items after MarketService has been initialised"
	)
	assert(
		State.RegisteredPurchaseItems[key] == nil,
		"[MarketService] Pass with key '" .. key .. "' is already registered"
	)

	if pass_id ~= nil then
		for existingKey, existingData in State.RegisteredPurchaseItems do
			assert(
				existingData.AssetId ~= pass_id,
				`[MarketService] Asset ID {pass_id} is already registered under key '{existingKey}'`
			)
		end
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
	assert_pass(key)

	if not PassOwnershipCallbacks[key] then
		PassOwnershipCallbacks[key] = {}
	end
	table.insert(PassOwnershipCallbacks[key], callback)

	-- Fire callback for players whose ownership is already cached.
	-- Players still being checked will have callbacks fired by preload_player_passes.
	for user_id, user_cache in PassOwnershipCache do
		if user_cache[key] then
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

	assert_pass(key)

	local user_cache = PassOwnershipCache[resolved_player.UserId]
	if user_cache == nil then
		return false
	end

	return user_cache[key] or false
end

--[=[
	Returns the product info for a registered, listed pass purchase item

	@yields
	@param key string -- The key the pass was registered with
	@return MarketplaceServiceProductInfo -- The pass info
]=]
Passes.GetPassInfoAsync = function(key: string): Types.MarketplaceServiceProductInfo
	assert(State.Initialised, "[MarketService] MarketService must be initialised before getting pass info")

	local pass_id = assert_pass(key).AssetId
	assert(pass_id ~= nil, `[MarketService] Pass '{key}' is unlisted and has no pass info`)

	if RunService:IsServer() then
		warn(
			"[MarketService] GetGamePassInfoAsync called from server; this won't take into account player-specific pricing or other features. Consider calling from client instead."
		)
	end

	local lastError: string? = nil
	for attempt = 1, State.MAX_RETRY_ATTEMPTS do
		local success, result = pcall(function()
			return MarketplaceService:GetProductInfo(pass_id, Enum.InfoType.GamePass)
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

	assert_pass(key)

	local was_purchased = was_just_purchased or false

	-- Grant ownership on server
	grant_pass_ownership(player, key, was_purchased)

	-- Sync to client
	SyncPassOwnershipRemote:FireClient(player, key, was_purchased)
end

--[=[
	Simulates a pass purchase: awards the pass for the session as just purchased, then fires
	`PassPurchaseFinished` on the server and the player's client. Works for unlisted passes.
	Server-only. Unlike `PromptPassPurchase` for a test buyer it doesn't check whether the
	player already owns the pass.

	@param key string -- The key the pass was registered with
	@param player Player -- The player to simulate the purchase for
]=]
Passes.SimulatePassPurchase = function(key: string, player: Player)
	assert(State.Initialised, "[MarketService] MarketService must be initialised before simulating purchases")
	assert(RunService:IsServer(), "[MarketService] SimulatePassPurchase can only be called from the server")

	Passes.AwardSessionPass(player, key, true)
	Finished.FireSimulated(player, "Pass", key)
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
