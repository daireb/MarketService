# MarketService

An opinionated [MarketplaceService](https://create.roblox.com/docs/reference/engine/classes/MarketplaceService) wrapper for Roblox that simplifies working with Developer Products and Game Passes.

## Features

- **Key-based registration** — Reference products and passes by string keys instead of raw asset IDs
- **Automatic pass ownership caching** — Pass ownership is preloaded and cached for instant lookups
- **OnPassOwned callbacks** — Register callbacks that fire once when a player owns a pass (whether pre-owned or just purchased)
- **Session passes** — Grant temporary pass ownership that lasts for the current session
- **Server-answered purchase requests** — One client call that the server answers by prompting, simulating for test buyers or refusing
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

An item registered without an id is **unlisted**: it has no Roblox asset yet. Everything keyed on the item works (callbacks, `OnPassOwned`, `PlayerOwnsPass`, simulation, session passes), but `Prompt*Purchase` and `Get*InfoAsync` error on it, and players without the test buyer check get `"Unavailable"` from a purchase request.

```lua
MarketService.RegisterProduct("Gems500")  -- no product id yet
MarketService.RegisterPass("AutoSell")    -- no pass id yet

MarketService.IsListed("Gems500") --> false
```

`RegisterProducts` and `RegisterPasses` take `{ [key] = id }`, so register unlisted items one at a time. Every product still needs a purchase callback before `Init`, listed or not.

An unlisted pass is never looked up on Roblox: a player owns it only through `AwardSessionPass` (or a simulated purchase, which awards it the same way).

### Purchase requests

Route purchases through the server so it decides what each player gets:

```lua
-- Client
local answer, reason = MarketService.RequestPurchaseAsync("Gems500")
if answer == "Refused" then
    showMessage(reason)
end
```

The server answers, in order:

1. `"Unavailable"` if the key isn't a registered item.
2. `"Refused"` (with the gate's reason) if the purchase gate says no.
3. `"Refused"` (`"Already owned"`) if the item is a pass the player already owns. This reads the ownership cache, so in the moments after joining, before it has loaded, an owned pass can still be prompted or simulated.
4. `"Simulated"` if the test buyer check says yes: the product's callback runs with a mock receipt, or the pass is awarded for the session.
5. `"Prompted"` if the item is listed: Roblox's purchase prompt is shown from the server.
6. `"Unavailable"` otherwise (an unlisted item for a normal player).

A request from a player whose previous request is still being answered is `"Refused"` (`"Request already in progress"`); the guard ends when the answer returns, not when a simulated product's callback does. A player who leaves while a hook yields gets `"Unavailable"` and nothing happens. If the request itself fails, or the server never initialised MarketService, the client gets `"Unavailable"`.

A simulated purchase fires `ProductPurchaseFinished` or `PassPurchaseFinished` on the server and on the player's client, which MarketService replicates itself. For a simulated pass the event can arrive before `RequestPurchaseAsync` returns; for a simulated product it fires once the callback has finished, which can be well after. Don't rely on either order. For a `"Prompted"` purchase the events come from MarketplaceService as with any prompt; that they reach the client for a prompt the server started is not yet confirmed.

When a test buyer's product callback returns `NotProcessedYet`, MarketService redelivers the same receipt after 5, 15 and 45 seconds while the player stays, then gives up with a warning, much as Roblox redelivers real receipts. `ProductPurchaseFinished` fires once, after the first delivery, with `true`.

Both hooks are optional, server-only, and can be set before or after `Init`. Passing `nil` clears one. A hook that errors refuses the request (gate) or doesn't simulate (test buyer check), with a warning.

```lua
-- Server
MarketService.SetPurchaseGate(function(player, key)
    if isInTrade(player) then
        return false, "Finish your trade first"
    end
    return true
end)

MarketService.SetTestBuyerCheck(function(player, key)
    return RunService:IsStudio() or isTester(player)
end)
```

### Testing purchases

With a test buyer check set, testers buy through the same `RequestPurchaseAsync` path as players, with no Robux spent and no Roblox asset needed. To simulate directly on the server:

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

Mock receipts have `Simulated = true`, `CurrencySpent = 0`, the product's id as `ProductId` (0 when unlisted) and a `PurchaseId` of `"test-"` plus a GUID, so they never collide with real receipts. Calling `SimulateProductPurchaseAsync` directly redelivers nothing on its own; a redelivery (a `PurchaseId` passed back) fires no finished event. `AwardSessionPass(player, key, true)` alone grants the pass without firing `PassPurchaseFinished`.

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
MarketService.PassPurchaseFinished:Connect(function(player, key, wasPurchased)
    if wasPurchased then
        -- Play sound, show UI, etc.
    end
end)

MarketService.ProductPurchaseFinished:Connect(function(player, key, wasPurchased)
    -- ...
end)
```

## API Reference

### Passes

| Function | Description |
|----------|-------------|
| `RegisterPass(key, passId?)` | Register a pass before Init. Omit the id for an unlisted pass |
| `RegisterPasses(passes)` | Register multiple passes `{ [key] = passId }` |
| `OnPassOwned(key, callback) -> disconnect` | Callback fires once when player owns pass - either their ownership just loaded or they just purchased it. Returns disconnect function |
| `PlayerOwnsPass(key, player?) -> boolean` | Check ownership from cache. Player required on server, omit on client |
| `GetPassInfoAsync(key) -> ProductInfo` | Get pass info from Roblox (yields). Listed passes only |
| `PromptPassPurchase(key, player?)` | Prompt purchase. Player required on server, omit on client. Listed passes only |
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
| `PromptProductPurchase(key, player?)` | Prompt purchase. Player required on server, omit on client. Listed products only |
| `SimulateProductPurchaseAsync(key, player, purchaseId?) -> (ProductPurchaseDecision, purchaseId)` | Run the callback with a mock receipt and return its decision and the receipt's `PurchaseId` (yields, server only). A fresh purchase fires `ProductPurchaseFinished` on server and client; passing a `purchaseId` redelivers that receipt and fires nothing |
| `SimulateProductPurchased(key, player)` | Non-yielding `SimulateProductPurchaseAsync` (server only) |
| `GetAllProductKeys() -> { string }` | Get all registered product keys |
| `IsProductRegistered(key) -> boolean` | Check if a product is registered, listed or not |

### Purchase requests

| Function | Description |
|----------|-------------|
| `RequestPurchaseAsync(key) -> (PurchaseAnswer, string?)` | Ask the server to buy a product or pass (yields, client only). Answers `"Prompted"`, `"Simulated"`, `"Unavailable"` or `"Refused"` with a reason |
| `SetPurchaseGate(gate?)` | `(player, key) -> (boolean, string?)`; returning false refuses with the reason (server only) |
| `SetTestBuyerCheck(check?)` | `(player, key) -> boolean`; true simulates instead of prompting (server only) |

### Events

| Event | Description |
|-------|-------------|
| `PassPurchaseFinished(player, key, wasPurchased)` | Fires when pass purchase prompt closes, or a pass purchase is simulated |
| `ProductPurchaseFinished(player, key, wasPurchased)` | Fires when product purchase prompt closes, or after a simulated product purchase's callback |

### General

| Function | Description |
|----------|-------------|
| `Init()` | Initialize MarketService. Call after registration on both server and client |
| `IsListed(key) -> boolean` | Whether a registered item has a Roblox asset id. Errors on an unknown key |