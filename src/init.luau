--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Passes = require(script.Passes)
local Products = require(script.Products)
local State = require(script.State)
local Types = require(script.Types)

export type MarketServiceProductInfo = Types.MarketplaceServiceProductInfo

local MarketService = {}

-- Products (delegated to Products module)
MarketService.RegisterProduct = Products.RegisterProduct
MarketService.RegisterProducts = Products.RegisterProducts
MarketService.SetProductPurchaseCallback = Products.SetProductPurchaseCallback
MarketService.GetProductInfoAsync = Products.GetProductInfoAsync
MarketService.PromptProductPurchase = Products.PromptProductPurchase
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
MarketService.GetAllPassKeys = Passes.GetAllPassKeys
MarketService.IsPassRegistered = Passes.IsPassRegistered

-- Purchase events (for side effects like sound effects, NOT for critical logic)
-- Usage: MarketService.ProductPurchaseFinished:Connect(function(player, key, wasPurchased) end)
MarketService.ProductPurchaseFinished = State.ProductPurchaseFinished.Event
MarketService.PassPurchaseFinished = State.PassPurchaseFinished.Event

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
	Products.Init()
	Passes.Init()

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
