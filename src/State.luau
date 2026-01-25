--!strict

local Types = require(script.Parent.Types)

export type RegisteredPurchaseItems = { [string]: Types.PurchaseItem }

local State = {}

State.RegisteredPurchaseItems = {} :: RegisteredPurchaseItems
State.Initialised = false
State.MAX_RETRY_ATTEMPTS = 3

-- Purchase events (for side effects like sound effects, NOT for critical logic)
State.ProductPurchaseFinished = Instance.new("BindableEvent") -- (player: Player, key: string, wasPurchased: boolean)
State.PassPurchaseFinished = Instance.new("BindableEvent") -- (player: Player, key: string, wasPurchased: boolean)

return State
