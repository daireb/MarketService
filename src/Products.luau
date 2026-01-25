--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local State = require(script.Parent.State)
local Types = require(script.Parent.Types)

local ProductPurchaseCallbacks = {} :: { [number]: Types.ProductPurchaseCallback }

--- Internal function to process receipts
local process_receipt_internal = function(
	receipt_info: Types.MarketplaceServiceReceiptInfo
): Enum.ProductPurchaseDecision
	local product_id = receipt_info.ProductId
	local callback = ProductPurchaseCallbacks[product_id]

	if callback ~= nil then
		local player = Players:GetPlayerByUserId(receipt_info.PlayerId)
		if player then
			local success, result = pcall(callback, player, receipt_info)
			if success then
				if typeof(result) == "EnumItem" and result.EnumType == Enum.ProductPurchaseDecision then
					return result
				else
					warn(
						`[MarketService] Invalid return value from purchase callback for receipt {receipt_info.PurchaseId} for player {player.Name} ({player.UserId})`
					)
					return Enum.ProductPurchaseDecision.NotProcessedYet
				end
			else
				warn(
					`[MarketService] Error processing receipt {receipt_info.PurchaseId} for player {player.Name} ({player.UserId}): {result}`
				)
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
		else
			warn(
				`[MarketService] Could not find player with UserId {receipt_info.PlayerId} for processing receipt {receipt_info.PurchaseId}`
			)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
	else
		warn(`[MarketService] No purchase callback registered for product ID {product_id}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
end

local Products = {}

-- Pre-initialisation

--[=[
	Registers a purchase item of type "Product"

	@param key string -- The key to register the product under
	@param product_id number -- The Roblox product ID
]=]
Products.RegisterProduct = function(key: string, product_id: number)
	assert(
		not State.Initialised,
		"[MarketService] Cannot register new purchase items after MarketService has been initialised"
	)
	assert(
		State.RegisteredPurchaseItems[key] == nil,
		"[MarketService] Product with key '" .. key .. "' is already registered"
	)

	-- Check for duplicate asset IDs
	for existingKey, existingData in State.RegisteredPurchaseItems do
		assert(
			existingData.AssetId ~= product_id,
			`[MarketService] Asset ID {product_id} is already registered under key '{existingKey}'`
		)
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

	local data = State.RegisteredPurchaseItems[key]
	assert(data ~= nil, `[MarketService] No purchase item registered with key '{key}'`)
	assert(data.Type == "Product", "[MarketService] Expected purchase item type to be 'Product'")

	ProductPurchaseCallbacks[data.AssetId] = callback
end

-- Post-initialisation

--[=[
	Returns the product info for a registered product purchase item

	@yields
	@param key The key the product was registered with
	@return MarketplaceServiceProductInfo The product info
]=]
Products.GetProductInfoAsync = function(key: string): Types.MarketplaceServiceProductInfo
	assert(State.Initialised, "[MarketService] MarketService must be initialised before getting product info")

	local data = State.RegisteredPurchaseItems[key]
	assert(data ~= nil, `[MarketService] No purchase item registered with key '{key}'`)
	assert(data.Type == "Product", "[MarketService] Expected purchase item type to be 'Product'")

	if RunService:IsServer() then
		warn(
			"[MarketService] GetProductInfoAsync called from server; this won't take into account player-specific pricing or other features. Consider calling from client instead."
		)
	end

	local lastError: string? = nil
	for attempt = 1, State.MAX_RETRY_ATTEMPTS do
		local success, result = pcall(function()
			return MarketplaceService:GetProductInfo(data.AssetId, Enum.InfoType.Product)
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
	Prompts the purchase prompt for a registered product purchase item

	@yields
	@param key string -- The key the product was registered with
	@param player Player? -- The player to prompt the purchase for (server only). Must be nil when called from client.
]=]
Products.PromptProductPurchaseAsync = function(key: string, player: Player?)
	assert(State.Initialised, "[MarketService] MarketService must be initialised before prompting purchases")

	if RunService:IsServer() then
		assert(player ~= nil, "[MarketService] Player must be provided when prompting purchase from server")
	else
		assert(player == nil, "[MarketService] Player must not be provided when prompting purchase from client")
		player = Players.LocalPlayer
	end

	local data = State.RegisteredPurchaseItems[key]
	assert(data ~= nil, `[MarketService] No purchase item registered with key '{key}'`)
	assert(data.Type == "Product", "[MarketService] Expected purchase item type to be 'Product'")

	MarketplaceService:PromptProductPurchase(player, data.AssetId)
end

-- Initialization

--[=[
	Initialises the Products module, setting up receipt processing.
	Called internally by MarketService.Init()
]=]
Products.Init = function()
	if RunService:IsServer() then
		-- Validate all products have callbacks registered
		for key, data in State.RegisteredPurchaseItems do
			if data.Type == "Product" then
				assert(
					ProductPurchaseCallbacks[data.AssetId] ~= nil,
					`[MarketService] Product '{key}' has no purchase callback registered. Use SetProductPurchaseCallback before Init.`
				)
			end
		end

		MarketplaceService.ProcessReceipt = process_receipt_internal
	end
end

return Products
