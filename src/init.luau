--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Finished = require(script.Finished)
local Passes = require(script.Passes)
local Products = require(script.Products)
local Requests = require(script.Requests)
local State = require(script.State)
local Types = require(script.Types)

export type MarketServiceProductInfo = Types.MarketplaceServiceProductInfo
export type MarketServiceReceiptInfo = Types.MarketplaceServiceReceiptInfo
export type PurchaseAnswer = Types.PurchaseAnswer
export type PurchaseGate = Types.PurchaseGate
export type TestBuyerCheck = Types.TestBuyerCheck

local MarketService = {}

-- Products (delegated to Products module)
MarketService.RegisterProduct = Products.RegisterProduct
MarketService.RegisterProducts = Products.RegisterProducts
MarketService.SetProductPurchaseCallback = Products.SetProductPurchaseCallback
MarketService.GetProductInfoAsync = Products.GetProductInfoAsync
MarketService.PromptProductPurchase = Products.PromptProductPurchase
MarketService.SimulateProductPurchased = Products.SimulateProductPurchased
MarketService.SimulateProductPurchaseAsync = Products.SimulateProductPurchaseAsync
MarketService.GetAllProductKeys = Products.GetAllProductKeys
MarketService.IsProductRegistered = Products.IsProductRegistered

-- Passes (delegated to Passes module)
MarketService.RegisterPass = Passes.RegisterPass
MarketService.RegisterPasses = Passes.RegisterPasses
MarketService.OnPassOwned = Passes.OnPassOwned
MarketService.PlayerOwnsPass = Passes.PlayerOwnsPass
MarketService.GetPassInfoAsync = Passes.GetPassInfoAsync
MarketService.PromptPassPurchase = Passes.PromptPassPurchase
MarketService.AwardSessionPass = Passes.AwardSessionPass
MarketService.SimulatePassPurchase = Passes.SimulatePassPurchase
MarketService.GetAllPassKeys = Passes.GetAllPassKeys
MarketService.IsPassRegistered = Passes.IsPassRegistered

-- Purchase requests (delegated to Requests module)
MarketService.RequestPurchaseAsync = Requests.RequestPurchaseAsync
MarketService.SetPurchaseGate = Requests.SetPurchaseGate
MarketService.SetTestBuyerCheck = Requests.SetTestBuyerCheck

-- Purchase events (for side effects like sound effects, NOT for critical logic)
-- Usage: MarketService.ProductPurchaseFinished:Connect(function(player, key, wasPurchased) end)
MarketService.ProductPurchaseFinished = State.ProductPurchaseFinished.Event
MarketService.PassPurchaseFinished = State.PassPurchaseFinished.Event

--[=[
	Returns whether a registered product or pass has a Roblox asset id. Unlisted items can't be
	prompted or looked up, only simulated (products) or awarded (passes).

	@param key string -- The key the item was registered with
	@return boolean -- Whether the item is listed
]=]
MarketService.IsListed = function(key: string): boolean
	local data = State.RegisteredPurchaseItems[key]
	assert(data ~= nil, `[MarketService] No purchase item registered with key '{key}'`)
	return data.AssetId ~= nil
end

-- Helper to find key by asset ID and type
local function getKeyByAssetId(assetId: number, itemType: "Product" | "Pass"): string?
	for key, data in State.RegisteredPurchaseItems do
		if data.Type == itemType and data.AssetId == assetId then
			return key
		end
	end
	return nil
end

--[=[
	Initialises the MarketService, setting up receipt processing and other internal systems.

	Must be called before using other MarketService functions.
]=]
MarketService.Init = function()
	if State.Initialised then
		error("[MarketService] Already initialised")
	end

	-- Initialize submodules
	Finished.Init()
	Products.Init()
	Passes.Init()
	Requests.Init()

	-- Wrap MarketplaceService events
	MarketplaceService.PromptProductPurchaseFinished:Connect(
		function(userId: number, productId: number, wasPurchased: boolean)
			local player = Players:GetPlayerByUserId(userId)
			if not player then
				return
			end

			local key = getKeyByAssetId(productId, "Product")
			if not key then
				warn(`[MarketService] ProductPurchaseFinished: No registered product found for ID {productId}`)
				return
			end

			State.ProductPurchaseFinished:Fire(player, key, wasPurchased)
		end
	)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, wasPurchased: boolean)
			local key = getKeyByAssetId(passId, "Pass")
			if not key then
				warn(`[MarketService] PassPurchaseFinished: No registered pass found for ID {passId}`)
				return
			end

			State.PassPurchaseFinished:Fire(player, key, wasPurchased)
		end
	)

	-- Mark as initialised
	State.Initialised = true

	-- Log registered items
	local num_items = 0
	for _key, _data in State.RegisteredPurchaseItems do
		num_items += 1
	end
	print(`[MarketService] Registered {num_items} purchase items`)
end

return MarketService
