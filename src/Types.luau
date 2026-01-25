export type PurchaseItem = {
	Type: "Product" | "Pass",
	AssetId: number,
}

--- Datatype returned by MarketplaceService:GetProductInfo()
---
--- https://create.roblox.com/docs/reference/engine/classes/MarketplaceService#GetProductInfo
export type MarketplaceServiceProductInfo = {
	-- Basic information
	Name: string,
	Description: string,
	PriceInRobux: number,
	ProductId: number,
	ProductType: string,
	Created: string,
	Updated: string,
	ContentRatingTypeId: number,
	MinimumMembershipLevel: number,
	IsPublicDomain: boolean,
	TargetId: number,

	-- Creator information
	Creator: {
		CreatorType: Enum.CreatorType,
		CreatorTargetId: number,
		HasVerifiedBadge: boolean,
		Name: string,
	},

	-- Asset information
	AssetId: number,
	AssetTypeId: number,
	IconImageAssetId: number,
	IsForSale: boolean,
	IsLimited: boolean,
	IsLimitedUnique: boolean,
	IsNew: boolean,
	Remaining: number,
	Sales: number,

	-- Collectibles information
	CollectibleItemId: string,
	CollectibleProductId: string,
	CollectiblesItemDetails: {
		CollectibleLowestAvailableResaleItemInstanceId: string,
		CollectibleLowestAvailableResaleProductId: number,
		CollectibleLowestAvailableResalePrice: number,
		IsForSale: boolean,
		IsLimited: boolean,
		TotalQuantity: number,
	},
}

--- Datatype passed to MarketplaceService.ProcessReceipt callback
---
--- https://create.roblox.com/docs/reference/engine/classes/MarketplaceService#ProcessReceipt
export type MarketplaceServiceReceiptInfo = {
	PurchaseId: string,
	PlayerId: number,
	ProductId: number,
	PlaceIdWherePurchased: number,
	CurrencySpent: number,
	CurrencyType: Enum.CurrencyType,
	ProductPurchaseChannel: Enum.ProductPurchaseChannel,
}

export type ProductPurchaseCallback = (
	player: Player,
	receipt_info: MarketplaceServiceReceiptInfo
) -> Enum.ProductPurchaseDecision

export type PassOwnershipCallback = (player: Player, was_just_purchased: boolean, key: string) -> ()

return nil
