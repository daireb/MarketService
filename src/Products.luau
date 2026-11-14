--!strict

local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Finished = require(script.Parent.Finished)
local State = require(script.Parent.State)
local Types = require(script.Parent.Types)

local ProductPurchaseCallbacks = {} :: { [string]: Types.ProductPurchaseCallback } -- key -> callback

--- Runs a product's purchase callback, turning an error or a non-decision return into NotProcessedYet.
local invoke_purchase_callback = function(
	key: string,
	player: Player,
	receipt_info: Types.MarketplaceServiceReceiptInfo
): Enum.ProductPurchaseDecision
	local callback = ProductPurchaseCallbacks[key]
	if callback == nil then
		warn(`[MarketService] No purchase callback registered for product '{key}'`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local success, result = pcall(callback, player, receipt_info)
	if not success then
		warn(
			`[MarketService] Error processing receipt {receipt_info.PurchaseId} of '{key}' for player {player.Name} ({player.UserId}): {result}`
		)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if typeof(result) == "EnumItem" and result.EnumType == Enum.ProductPurchaseDecision then
		return result
	end

	warn(
		`[MarketService] Invalid return value from purchase callback of '{key}' for receipt {receipt_info.PurchaseId} for player {player.Name} ({player.UserId}): {result}`
	)
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

--- Internal function to process receipts
local process_receipt_internal = function(
	receipt_info: Types.MarketplaceServiceReceiptInfo
): Enum.ProductPurchaseDecision
	local product_id = receipt_info.ProductId

	local key: string? = nil
	for item_key, data in State.RegisteredPurchaseItems do
		if data.Type == "Product" and data.AssetId == product_id then
			key = item_key
			break
		end
	end

	if key == nil then
		warn(`[MarketService] No product registered for product ID {product_id}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local player = Players:GetPlayerByUserId(receipt_info.PlayerId)
	if not player then
		warn(
			`[MarketService] Could not find player with UserId {receipt_info.PlayerId} for processing receipt {receipt_info.PurchaseId}`
		)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	return invoke_purchase_callback(key, player, receipt_info)
end

local assert_product = function(key: string): Types.PurchaseItem
	local data = State.RegisteredPurchaseItems[key]
	assert(data ~= nil, `[MarketService] No purchase item registered with key '{key}'`)
	assert(data.Type == "Product", "[MarketService] Expected purchase item type to be 'Product'")
	return data
end

local Products = {}

--[=[
	Returns an array of all registered product keys

	@return { string } -- Array of product keys
]=]
Products.GetAllProductKeys = function(): { string }
	local keys = {}
	for key, data in State.RegisteredPurchaseItems do
		if data.Type == "Product" then
			table.insert(keys, key)
		end
	end
	return keys
end

--[=[
	Checks if a product is registered with the given key, listed or not

	@param key string -- The key to check
	@return boolean -- Whether a product is registered with this key
]=]
Products.IsProductRegistered = function(key: string): boolean
	local data = State.RegisteredPurchaseItems[key]
	return data ~= nil and data.Type == "Product"
end

-- Pre-initialisation

--[=[
	Registers a purchase item of type "Product". Without a product id the product is unlisted:
	it can't be prompted or looked up on Roblox, only simulated.

	@param key string -- The key to register the product under
	@param product_id number? -- The Roblox product ID, or nil for an unlisted product
]=]
Products.RegisterProduct = function(key: string, product_id: number?)
	assert(
		not State.Initialised,
		"[MarketService] Cannot register new purchase items after MarketService has been initialised"
	)
	assert(
		State.RegisteredPurchaseItems[key] == nil,
		"[MarketService] Product with key '" .. key .. "' is already registered"
	)

	if product_id ~= nil then
		for existingKey, existingData in State.RegisteredPurchaseItems do
			assert(
				existingData.AssetId ~= product_id,
				`[MarketService] Asset ID {product_id} is already registered under key '{existingKey}'`
			)
		end
	end

	State.RegisteredPurchaseItems[key] = {
		Type = "Product",
		AssetId = product_id,
	}
end

--[=[
	Registers multiple purchase items of type "Product"

	@param products { [string]: number } -- A dictionary mapping keys to Roblox product IDs
]=]
Products.RegisterProducts = function(products: { [string]: number })
	for key, product_id in products do
		Products.RegisterProduct(key, product_id)
	end
end

--[=[
	Sets the purchase callback for a registered product purchase item

	@param key string -- The key the product was registered with
	@param callback ProductPurchaseCallback -- The callback to invoke when processing a purchase. Must return an `Enum.ProductPurchaseDecision`
]=]
Products.SetProductPurchaseCallback = function(key: string, callback: Types.ProductPurchaseCallback)
	assert(RunService:IsServer(), "[MarketService] Purchase callbacks can only be set on the server")
	assert(
		not State.Initialised,
		"[MarketService] Cannot set purchase callbacks after MarketService has been initialised"
	)

	assert_product(key)

	ProductPurchaseCallbacks[key] = callback
end

-- Post-initialisation

--[=[
	Returns the product info for a registered, listed product purchase item

	@yields
	@param key The key the product was registered with
	@return MarketplaceServiceProductInfo The product info
]=]
Products.GetProductInfoAsync = function(key: string): Types.MarketplaceServiceProductInfo
	assert(State.Initialised, "[MarketService] MarketService must be initialised before getting product info")

	local product_id = assert_product(key).AssetId
	assert(product_id ~= nil, `[MarketService] Product '{key}' is unlisted and has no product info`)

	if RunService:IsServer() then
		warn(
			"[MarketService] GetProductInfoAsync called from server; this won't take into account player-specific pricing or other features. Consider calling from client instead."
		)
	end

	local lastError: string? = nil
	for attempt = 1, State.MAX_RETRY_ATTEMPTS do
		local success, result = pcall(function()
			return MarketplaceService:GetProductInfo(product_id, Enum.InfoType.Product)
		end)

		if success then
			return result
		else
			lastError = result
			warn(
				`[MarketService] Failed to get product info for '{key}', attempt {attempt}/{State.MAX_RETRY_ATTEMPTS}: {result}`
			)
			if attempt < State.MAX_RETRY_ATTEMPTS then
				task.wait(1)
			end
		end
	end

	error(
		`[MarketService] Failed to get product info for '{key}' after {State.MAX_RETRY_ATTEMPTS} attempts: {lastError}`
	)
end

--[=[
	Simulates a product purchase: runs the purchase callback with a mock receipt and returns
	its decision (NotProcessedYet if it errors or returns something else). Works for unlisted
	products. Server-only.

	The mock receipt has `Simulated = true`, `CurrencySpent = 0`, the product's id as
	`ProductId` (0 when unlisted) and a `PurchaseId` of "test-" followed by a GUID, which no
	real Roblox receipt uses.

	A fresh purchase (no `purchase_id`) then fires `ProductPurchaseFinished` on the server and
	the player's client. Passing the `PurchaseId` this returned redelivers that receipt, as
	Roblox does after NotProcessedYet, and fires no finished event. Nothing redelivers on its
	own: a caller that gets NotProcessedYet retries if it wants the purchase to land.

	@yields
	@param key string -- The key the product was registered with
	@param player Player -- The player to simulate the purchase for
	@param purchase_id string? -- An earlier simulated receipt's `PurchaseId`, to redeliver it
	@return Enum.ProductPurchaseDecision -- The callback's decision
	@return string -- The receipt's `PurchaseId`, to pass back for a redelivery
]=]
Products.SimulateProductPurchaseAsync = function(
	key: string,
	player: Player,
	purchase_id: string?
): (Enum.ProductPurchaseDecision, string)
	assert(State.Initialised, "[MarketService] MarketService must be initialised before simulating purchases")
	assert(RunService:IsServer(), "[MarketService] SimulateProductPurchaseAsync can only be called from the server")

	local data = assert_product(key)

	local mock_receipt: Types.MarketplaceServiceReceiptInfo = {
		PurchaseId = purchase_id or `test-{HttpService:GenerateGUID(false)}`,
		PlayerId = player.UserId,
		ProductId = data.AssetId or 0,
		PlaceIdWherePurchased = game.PlaceId,
		CurrencySpent = 0,
		CurrencyType = Enum.CurrencyType.Robux,
		ProductPurchaseChannel = Enum.ProductPurchaseChannel.InExperience,
		Simulated = true,
	}

	local decision = invoke_purchase_callback(key, player, mock_receipt)
	if decision ~= Enum.ProductPurchaseDecision.PurchaseGranted then
		warn(
			`[MarketService] Simulated receipt {mock_receipt.PurchaseId} of '{key}' returned {decision.Name} instead of PurchaseGranted`
		)
	end

	if purchase_id == nil then
		Finished.FireSimulated(player, "Product", key)
	end

	return decision, mock_receipt.PurchaseId
end

--[=[
	Simulates a product purchase without yielding; see `SimulateProductPurchaseAsync`.
	Server-only.

	@param key string -- The key the product was registered with
	@param player Player -- The player to simulate the purchase for
]=]
Products.SimulateProductPurchased = function(key: string, player: Player)
	assert(State.Initialised, "[MarketService] MarketService must be initialised before simulating purchases")
	assert(RunService:IsServer(), "[MarketService] SimulateProductPurchased can only be called from the server")
	assert_product(key)

	task.spawn(Products.SimulateProductPurchaseAsync, key, player)
end

-- Initialization

--[=[
	Initialises the Products module, setting up receipt processing.
	Called internally by MarketService.Init()
]=]
Products.Init = function()
	if RunService:IsServer() then
		-- Unlisted products need callbacks too: simulated purchases run them.
		for key, data in State.RegisteredPurchaseItems do
			if data.Type == "Product" then
				assert(
					ProductPurchaseCallbacks[key] ~= nil,
					`[MarketService] Product '{key}' has no purchase callback registered. Use SetProductPurchaseCallback before Init.`
				)
			end
		end

		MarketplaceService.ProcessReceipt = process_receipt_internal
	end
end

return Products
