--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local State = require(script.Parent.State)
local Types = require(script.Parent.Types)

--- Holds a player's mode on their Player instance. An attribute is replicated state rather than
--- an event, so the client reads a mode set before it was listening. Every client can read it;
--- a client can only change its own copy, which the server never reads.
local MODE_ATTRIBUTE = "MarketServiceTestBuyerMode"

--- Studio tests unlisted items with no setup; a live server simulates nothing unless the game
--- sets a mode.
local DEFAULT_MODE: Types.TestBuyerMode = if RunService:IsStudio() then "Unlisted" else "None"

local is_mode = function(value: unknown): boolean
	return value == "None" or value == "Unlisted" or value == "All"
end

local resolve_player = function(player: Player?): Player
	if RunService:IsServer() then
		assert(player ~= nil, "[MarketService] Player must be provided on the server")
		return player
	end

	local local_player = Players.LocalPlayer
	assert(
		player == nil or player == local_player,
		"[MarketService] Only the local player's test buyer mode is known on the client"
	)
	return local_player
end

local assert_registered = function(key: string): Types.PurchaseItem
	local data = State.RegisteredPurchaseItems[key]
	assert(data ~= nil, `[MarketService] No purchase item registered with key '{key}'`)
	return data
end

local TestBuyers = {}

--[=[
	Returns a player's test buyer mode. On the client it is the server's mode for the local
	player as last replicated: a hint for UI, never trusted by the server.

	@param player Player? -- Required on the server; on the client nil or the local player
	@return TestBuyerMode
]=]
TestBuyers.GetTestBuyerMode = function(player: Player?): Types.TestBuyerMode
	local value = resolve_player(player):GetAttribute(MODE_ATTRIBUTE)
	if is_mode(value) then
		return value :: Types.TestBuyerMode
	end
	return DEFAULT_MODE
end

--[=[
	Sets which of a player's purchases the prompt helpers simulate, and replicates it to their
	client. nil returns the player to the default: "Unlisted" in Studio, "None" elsewhere.
	Server-only; can be called before or after Init.

	@param player Player
	@param mode TestBuyerMode?
]=]
TestBuyers.SetTestBuyerMode = function(player: Player, mode: Types.TestBuyerMode?)
	assert(RunService:IsServer(), "[MarketService] SetTestBuyerMode can only be called from the server")
	assert(typeof(player) == "Instance" and player:IsA("Player"), "[MarketService] SetTestBuyerMode expects a Player")
	assert(mode == nil or is_mode(mode), `[MarketService] Invalid test buyer mode '{mode}'`)

	player:SetAttribute(MODE_ATTRIBUTE, mode)
end

--[=[
	Returns whether the prompt helpers would simulate a player's purchase of `key` rather than
	show Roblox's prompt.

	@param key string -- A registered product or pass
	@param player Player? -- Required on the server; on the client nil or the local player
	@return boolean
]=]
TestBuyers.WillSimulate = function(key: string, player: Player?): boolean
	local data = assert_registered(key)
	local mode = TestBuyers.GetTestBuyerMode(player)
	return mode == "All" or (mode == "Unlisted" and data.AssetId == nil)
end

--[=[
	Returns whether a player can buy `key` at all: it is listed, or would be simulated. Says
	nothing about whether they already own a pass.

	@param key string -- A registered product or pass
	@param player Player? -- Required on the server; on the client nil or the local player
	@return boolean
]=]
TestBuyers.IsPurchasable = function(key: string, player: Player?): boolean
	local data = assert_registered(key)
	return data.AssetId ~= nil or TestBuyers.WillSimulate(key, player)
end

return TestBuyers
