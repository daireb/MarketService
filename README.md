# MarketService

An opinionated [MarketplaceService](https://create.roblox.com/docs/reference/engine/classes/MarketplaceService) wrapper for Roblox that simplifies working with Developer Products and Game Passes.

## Features

- **Key-based registration** — Reference products and passes by string keys instead of raw asset IDs
- **Automatic pass ownership caching** — Pass ownership is preloaded and cached for instant lookups
- **OnPassOwned callbacks** — Register callbacks that fire once when a player owns a pass (whether pre-owned or just purchased)
- **Session passes** — Grant temporary pass ownership that lasts for the current session
- **Test buyers** — Per-player modes that make the usual prompt helpers simulate purchases, with no Robux or Roblox asset needed
- **Unlisted items** — Register products and passes before they have Roblox asset ids
- **Automatic retries** — API calls retry automatically on failure
- **Server & client support** — Works seamlessly on both server and client

## Installation

```bash
pesde add gh#daireb/MarketService#main
```

## Usage

### Setup

MarketService must be initialized on **both server and client**. The recommended approach is to create shared `Passes` and `Products` modules in ReplicatedStorage that define your asset IDs:

**ReplicatedStorage/Passes.luau:**

```lua
local Passes = {}

Passes.VIP = 123456789
Passes.DoubleCoins = 987654321

return Passes
```

**ReplicatedStorage/Products.luau:**

```lua
local Products = {}

Products.Coins100 = 111222333

return Products
```

Then register and initialize on both server and client:

**Server:**

```lua
local MarketService = require(path.to.MarketService)
local Passes = require(ReplicatedStorage.Passes)
local Products = require(ReplicatedStorage.Products)

MarketService.RegisterPasses(Passes)
MarketService.RegisterProducts(Products)

-- Set purchase callbacks for products
MarketService.SetProductPurchaseCallback("Coins100", function(player, receiptInfo)
    -- Award coins, save data, etc.
    return Enum.ProductPurchaseDecision.PurchaseGranted
end)

MarketService.Init()
```

**Client:**

```lua
local MarketService = require(path.to.MarketService)
local Passes = require(ReplicatedStorage.Passes)
local Products = require(ReplicatedStorage.Products)

MarketService.RegisterPasses(Passes)
MarketService.RegisterProducts(Products)
MarketService.Init()
```

### Unlisted items

An item registered without an id is **unlisted**: it has no Roblox asset yet. Everything keyed on the item works (callbacks, `OnPassOwned`, `PlayerOwnsPass`, session passes, simulated purchases), but it has no Roblox prompt and `Get*InfoAsync` errors on it. Only a test buyer can buy it (see [Test buyers](#test-buyers)).

```lua
MarketService.RegisterProduct("Gems500")  -- no product id yet
MarketService.RegisterPass("AutoSell")    -- no pass id yet

MarketService.IsListed("Gems500") --> false
```

`RegisterProducts` and `RegisterPasses` take `{ [key] = id }`, so register unlisted items one at a time. Every product still needs a purchase callback before `Init`, listed or not.

An unlisted pass is never looked up on Roblox: a player owns it only through `AwardSessionPass` (or a simulated purchase, which awards it the same way).

### Test buyers

Each player has a **test buyer mode**, which decides which of their purchases `PromptProductPurchase` and `PromptPassPurchase` simulate instead of charging:

| Mode | Simulated |
|------|-----------|
| `"None"` | Nothing: a normal player |
| `"Unlisted"` | Items without an asset id; listed items prompt for real |
| `"All"` | Every purchase |

The default is `"Unlisted"` in Studio and `"None"` everywhere else, so unlisted items can be bought in Studio with no setup and nothing is simulated on a live server unless your game says so. Only the server sets a mode, before or after `Init`; `nil` returns the player to the default:

```lua
-- Server
Players.PlayerAdded:Connect(function(player)
    if isTester(player) then
        MarketService.SetTestBuyerMode(player, "All")
    end
end)
```

The mode replicates to the player's client as an attribute on their `Player` (`MarketServiceTestBuyerMode`), so `GetTestBuyerMode()`, `WillSimulate(key)` and `IsPurchasable(key)` work there for the local player, even for a mode set before the client loaded. Like any attribute, every client can read it, so don't make a mode something players shouldn't learn about each other. The client's copy is only a hint for UI: the server checks its own mode before simulating anything a client asks for.

Game code calls the prompt helpers the same way for everyone:

```lua
-- Client
if MarketService.IsPurchasable("Gems500") then
    MarketService.PromptProductPurchase("Gems500")
end
```

- If the purchase will be simulated, the client asks the server, which simulates it after checking the key and its own mode for the player. A product's callback runs with a mock receipt; a pass is awarded for the session unless the player already owns it. Called on the server, the helper simulates directly.
- Otherwise a listed item opens Roblox's prompt on the side that called, with no round trip.
- Otherwise (unlisted, and not a test buyer) nothing can be bought: the helper warns and fires the finished event on the calling side with `wasPurchased` false. It doesn't error, so a button handler doesn't break.

A simulated purchase fires `ProductPurchaseFinished` or `PassPurchaseFinished` on the server and on the player's client, which MarketService replicates itself, with `wasSimulated` true. For a product it fires once the callback has first returned, which can take a while. When the server declines a client's simulate request (unknown key, its mode says no, or the pass is already owned), the client gets the finished event with `wasPurchased` false so a waiting UI clears; the server warns for all but the already-owned case, at most once every 10 seconds per player.

When a simulated product's callback returns `NotProcessedYet`, MarketService redelivers the same receipt after 5, 15 and 45 seconds while the player stays, then gives up with a warning, much as Roblox redelivers real receipts. `ProductPurchaseFinished` fires once, after the first delivery, with `wasPurchased` true.

Pre-purchase checks (can the player afford it, are they in a trade) belong in your UI before it calls the prompt helper. Nothing before the prompt is authoritative, since any client can open a Roblox prompt itself; the receipt is. Grant in the purchase callback.

### Testing purchases

For commands and tests, simulate directly on the server, whatever the player's mode:

```lua
-- Yields; returns the callback's Enum.ProductPurchaseDecision and the receipt's PurchaseId
local decision, purchaseId = MarketService.SimulateProductPurchaseAsync("Gems500", player)
if decision == Enum.ProductPurchaseDecision.NotProcessedYet then
    -- Redeliver the same receipt later
    MarketService.SimulateProductPurchaseAsync("Gems500", player, purchaseId)
end

-- Fire-and-forget form (no redelivery)
MarketService.SimulateProductPurchased("Gems500", player)

-- Passes: awards for the session and fires PassPurchaseFinished
MarketService.SimulatePassPurchase("AutoSell", player)
```

Mock receipts have `Simulated = true`, `CurrencySpent = 0`, the product's id as `ProductId` (0 when unlisted) and a `PurchaseId` of `"test-"` plus a GUID, so they never collide with real receipts. These functions don't check ownership or redeliver on their own; a redelivery (a `PurchaseId` passed back) fires no finished event. `AwardSessionPass(player, key, true)` alone grants the pass without firing `PassPurchaseFinished`.

### Passes

```lua
-- React when a player owns a pass (fires once per player)
MarketService.OnPassOwned("VIP", function(player, wasJustPurchased, key)
    print(player.Name, "owns VIP!", wasJustPurchased and "(just bought)" or "(already owned)")
end)

-- Check ownership (uses cache, instant)
local ownsVIP = MarketService.PlayerOwnsPass("VIP", player)

-- Prompt purchase
MarketService.PromptPassPurchase("VIP", player)

-- Grant pass to player until they leave the game
MarketService.AwardSessionPass(player, "VIP")
```

### Products

```lua
-- Prompt purchase
MarketService.PromptProductPurchase("100Coins", player)

-- Get product info
local info = MarketService.GetProductInfoAsync("100Coins")
print(info.Name, info.PriceInRobux)

-- Simulates a purchase for testing (server only)
MarketService.SimulateProductPurchased("100Coins", player)
```

See [Testing purchases](#testing-purchases) for the yielding form.

### Session Passes

Session passes grant temporary pass ownership that lasts until the player leaves. This is useful for:

- **Testing** — Quickly test pass ownership without purchasing
- **Free unlocks** — Grant "free" passes that last forever

When using session passes for permanent unlocks, you should store the unlock status somewhere, listen for data changes and award as appropriate:

```lua
-- Example: Grant VIP to players who unlocked it via premium currency
local function onPlayerData(player, data)
    if data.unlockedVIP then
        MarketService.AwardSessionPass(player, "VIP")
    end
end

-- Call when player joins and data loads
Players.PlayerAdded:Connect(function(player)
    local data = loadPlayerData(player)
    onPlayerData(player, data)
end)

-- Call when data changes mid-session
dataChangedSignal:Connect(onPlayerData)
```

### Purchase Events

For side effects like sound effects (not for critical logic):

```lua
MarketService.PassPurchaseFinished:Connect(function(player, key, wasPurchased, wasSimulated)
    if wasPurchased then
        -- Play sound, show UI, etc.
    end
end)

MarketService.ProductPurchaseFinished:Connect(function(player, key, wasPurchased, wasSimulated)
    -- ...
end)
```

`wasSimulated` is false for anything real, and true for a simulated purchase or a declined simulate request.

## API Reference

### Passes

| Function | Description |
|----------|-------------|
| `RegisterPass(key, passId?)` | Register a pass before Init. Omit the id for an unlisted pass |
| `RegisterPasses(passes)` | Register multiple passes `{ [key] = passId }` |
| `OnPassOwned(key, callback) -> disconnect` | Callback fires once when player owns pass - either their ownership just loaded or they just purchased it. Returns disconnect function |
| `PlayerOwnsPass(key, player?) -> boolean` | Check ownership from cache. Player required on server, omit on client |
| `GetPassInfoAsync(key) -> ProductInfo` | Get pass info from Roblox (yields). Listed passes only |
| `PromptPassPurchase(key, player?)` | Simulate for a test buyer (declined if already owned), else open Roblox's prompt for a listed pass, else warn and fire `PassPurchaseFinished` with `false`. Player required on server, omit on client |
| `AwardSessionPass(player, key, wasJustPurchased?)` | Grant temporary ownership until player leaves (server only) |
| `SimulatePassPurchase(key, player)` | `AwardSessionPass` as just purchased, then fire `PassPurchaseFinished` on server and client (server only). Doesn't check existing ownership |
| `GetAllPassKeys() -> { string }` | Get all registered pass keys |
| `IsPassRegistered(key) -> boolean` | Check if a pass is registered, listed or not |

### Products

| Function | Description |
|----------|-------------|
| `RegisterProduct(key, productId?)` | Register a product before Init. Omit the id for an unlisted product |
| `RegisterProducts(products)` | Register multiple products `{ [key] = productId }` |
| `SetProductPurchaseCallback(key, callback)` | Set receipt handler for a product. Must return `Enum.ProductPurchaseDecision`. All products require a receipt handler! |
| `GetProductInfoAsync(key) -> ProductInfo` | Get product info from Roblox (yields). Listed products only |
| `PromptProductPurchase(key, player?)` | Simulate for a test buyer (with redelivery), else open Roblox's prompt for a listed product, else warn and fire `ProductPurchaseFinished` with `false`. Player required on server, omit on client |
| `SimulateProductPurchaseAsync(key, player, purchaseId?) -> (ProductPurchaseDecision, purchaseId)` | Run the callback with a mock receipt and return its decision and the receipt's `PurchaseId` (yields, server only). A fresh purchase fires `ProductPurchaseFinished` on server and client; passing a `purchaseId` redelivers that receipt and fires nothing |
| `SimulateProductPurchased(key, player)` | Non-yielding `SimulateProductPurchaseAsync` (server only) |
| `GetAllProductKeys() -> { string }` | Get all registered product keys |
| `IsProductRegistered(key) -> boolean` | Check if a product is registered, listed or not |

### Test buyers

| Function | Description |
|----------|-------------|
| `SetTestBuyerMode(player, mode?)` | Set `"None"`, `"Unlisted"` or `"All"`; `nil` restores the default (`"Unlisted"` in Studio, `"None"` elsewhere). Replicates to the player's client (server only) |
| `GetTestBuyerMode(player?) -> TestBuyerMode` | The player's mode. Player required on server; on the client nil or the local player |
| `WillSimulate(key, player?) -> boolean` | Whether the prompt helpers would simulate this purchase: mode `"All"`, or `"Unlisted"` and the item is unlisted. Player as for `GetTestBuyerMode` |
| `IsPurchasable(key, player?) -> boolean` | Listed, or `WillSimulate`. Says nothing about pass ownership. Player as for `GetTestBuyerMode` |

### Events

| Event | Description |
|-------|-------------|
| `PassPurchaseFinished(player, key, wasPurchased, wasSimulated)` | Fires when a pass purchase prompt closes, a pass purchase is simulated, or a simulate request is declined |
| `ProductPurchaseFinished(player, key, wasPurchased, wasSimulated)` | Fires when a product purchase prompt closes, after a simulated product purchase's callback first returns, or when a simulate request is declined |

### General

| Function | Description |
|----------|-------------|
| `Init()` | Initialize MarketService. Call after registration on both server and client |
| `IsListed(key) -> boolean` | Whether a registered item has a Roblox asset id. Errors on an unknown key |