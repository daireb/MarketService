# MarketService

An opinionated [MarketplaceService](https://create.roblox.com/docs/reference/engine/classes/MarketplaceService) wrapper for Roblox that simplifies working with Developer Products and Game Passes.

## Features

- **Key-based registration** — Reference products and passes by string keys instead of raw asset IDs
- **Automatic pass ownership caching** — Pass ownership is preloaded and cached for instant lookups
- **OnPassOwned callbacks** — Register callbacks that fire once when a player owns a pass (whether pre-owned or just purchased)
- **Session passes** — Grant temporary pass ownership that lasts for the current session
- **Automatic retries** — API calls retry automatically on failure
- **Server & client support** — Works seamlessly on both server and client

## Installation

```bash
pesde add gh#daireb/marketservice#main
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
| `RegisterPass(key, passId)` | Register a pass before Init |
| `RegisterPasses(passes)` | Register multiple passes `{ [key] = passId }` |
| `OnPassOwned(key, callback) -> disconnect` | Callback fires once when player owns pass - either their ownership just loaded or they just purchased it. Returns disconnect function |
| `PlayerOwnsPass(key, player?) -> boolean` | Check ownership from cache. Player required on server, omit on client |
| `GetPassInfoAsync(key) -> ProductInfo` | Get pass info from Roblox (yields) |
| `PromptPassPurchase(key, player?)` | Prompt purchase. Player required on server, omit on client |
| `AwardSessionPass(player, key)` | Grant temporary ownership until player leaves (server only) |
| `GetAllPassKeys() -> { string }` | Get all registered pass keys |
| `IsPassRegistered(key) -> boolean` | Check if a pass is registered |

### Products

| Function | Description |
|----------|-------------|
| `RegisterProduct(key, productId)` | Register a product before Init |
| `RegisterProducts(products)` | Register multiple products `{ [key] = productId }` |
| `SetProductPurchaseCallback(key, callback)` | Set receipt handler for a product. Must return `Enum.ProductPurchaseDecision`. All products require a receipt handler! |
| `GetProductInfoAsync(key) -> ProductInfo` | Get product info from Roblox (yields) |
| `PromptProductPurchase(key, player?)` | Prompt purchase. Player required on server, omit on client |
| `SimulateProductPurchased(key, player)` | Simulate a purchase for testing. Fires callback and all side effects (server only) |
| `GetAllProductKeys() -> { string }` | Get all registered product keys |
| `IsProductRegistered(key) -> boolean` | Check if a product is registered |

### Events

| Event | Description |
|-------|-------------|
| `PassPurchaseFinished(player, key, wasPurchased)` | Fires when pass purchase prompt closes |
| `ProductPurchaseFinished(player, key, wasPurchased)` | Fires when product purchase prompt closes |

### General

| Function | Description |
|----------|-------------|
| `Init()` | Initialize MarketService. Call after registration on both server and client |