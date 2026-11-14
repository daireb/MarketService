--- A registered product or pass. `AssetId` is nil for an unlisted item, one with no Roblox asset yet.
export type PurchaseItem = {
	Type: "Product" | "Pass",
	AssetId: number?,
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
	--- Set by MarketService on mock receipts; Roblox never sends it.
	Simulated: boolean?,
}

export type ProductPurchaseCallback = (
	player: Player,
	receipt_info: MarketplaceServiceReceiptInfo
) -> Enum.ProductPurchaseDecision

export type PassOwnershipCallback = (player: Player, was_just_purchased: boolean, key: string) -> ()

--- The server's answer to `RequestPurchaseAsync`.
--- - `Prompted`: Roblox's purchase prompt was shown.
--- - `Simulated`: the purchase was simulated for a test buyer.
--- - `Unavailable`: the key is unknown, the item is unlisted and the player isn't a test buyer, the
---   player left mid-request, or the request failed.
--- - `Refused`: the purchase gate said no, the pass is already owned or a request is already in flight.
export type PurchaseAnswer = "Prompted" | "Simulated" | "Unavailable" | "Refused"

--- Returns whether `player` may buy `key`, and a reason when not.
export type PurchaseGate = (player: Player, key: string) -> (boolean, string?)

--- Returns true when `player`'s purchases of `key` should be simulated instead of charged.
export type TestBuyerCheck = (player: Player, key: string) -> boolean

--- Function that disconnects a callback when called
export type DisconnectFunction = () -> ()

return nil
