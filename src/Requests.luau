--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Passes = require(script.Parent.Passes)
local Products = require(script.Parent.Products)
local State = require(script.Parent.State)
local Types = require(script.Parent.Types)

local REMOTE_NAME = "RequestPurchase"

--- Seconds the client waits for the server to create the request remote before answering
--- "Unavailable". Judgement.
local REMOTE_WAIT_TIMEOUT = 10

--- Seconds before each redelivery of a test buyer's receipt that the callback left
--- NotProcessedYet, standing in for Roblox's own redelivery. Judgement.
local REDELIVERY_DELAYS = { 5, 15, 45 }

local PurchaseGate: Types.PurchaseGate? = nil
local TestBuyerCheck: Types.TestBuyerCheck? = nil

--- Players whose previous request is still being answered; their new requests are refused.
local PendingRequests = {} :: { [Player]: true }

local passes_gate = function(player: Player, key: string): (boolean, string?)
	local gate = PurchaseGate
	if gate == nil then
		return true, nil
	end

	local success, allowed, reason = pcall(gate, player, key)
	if not success then
		warn(`[MarketService] Purchase gate errored for '{key}' and {player.Name} ({player.UserId}): {allowed}`)
		return false, nil
	end

	-- Anything but an explicit true refuses, so a gate that forgets to return fails closed.
	return allowed == true, if typeof(reason) == "string" then reason else nil
end

local is_test_buyer = function(player: Player, key: string): boolean
	local check = TestBuyerCheck
	if check == nil then
		return false
	end

	local success, result = pcall(check, player, key)
	if not success then
		warn(`[MarketService] Test buyer check errored for '{key}' and {player.Name} ({player.UserId}): {result}`)
		return false
	end

	return result == true
end

--- Simulates a test buyer's product purchase, redelivering the receipt while the callback
--- answers NotProcessedYet and the player stays, as Roblox would for a real one.
local simulate_product = function(key: string, player: Player)
	local decision, purchase_id = Products.SimulateProductPurchaseAsync(key, player)
	for _, delay in REDELIVERY_DELAYS do
		if decision ~= Enum.ProductPurchaseDecision.NotProcessedYet then
			return
		end
		task.wait(delay)
		if player.Parent ~= Players then
			break
		end
		decision = Products.SimulateProductPurchaseAsync(key, player, purchase_id)
	end

	if decision == Enum.ProductPurchaseDecision.NotProcessedYet then
		warn(
			`[MarketService] Gave up redelivering simulated receipt {purchase_id} of '{key}' for {player.Name} ({player.UserId})`
		)
	end
end

local answer_request = function(player: Player, key: unknown): (Types.PurchaseAnswer, string?)
	if typeof(key) ~= "string" then
		return "Unavailable", nil
	end
	local data = State.RegisteredPurchaseItems[key]
	if data == nil then
		return "Unavailable", nil
	end

	local allowed, reason = passes_gate(player, key)
	if not allowed then
		return "Refused", reason
	end

	local simulate = is_test_buyer(player, key)

	-- Either hook may yield; acting for a player who left would rebuild their pass state after
	-- PlayerRemoving cleared it.
	if player.Parent ~= Players then
		return "Unavailable", nil
	end

	-- Checked before simulating as well as prompting, so a test buyer can't re-buy a pass either.
	if data.Type == "Pass" and Passes.PlayerOwnsPass(key, player) then
		return "Refused", "Already owned"
	end

	if simulate then
		if data.Type == "Product" then
			-- Not awaited: the callback may yield for a save, and the client shouldn't wait on it.
			task.spawn(simulate_product, key, player)
		else
			Passes.SimulatePassPurchase(key, player)
		end
		return "Simulated", nil
	end

	if data.AssetId == nil then
		return "Unavailable", nil
	end

	if data.Type == "Product" then
		Products.PromptProductPurchase(key, player)
	else
		Passes.PromptPassPurchase(key, player)
	end
	return "Prompted", nil
end

local on_server_invoke = function(player: Player, key: unknown): (Types.PurchaseAnswer, string?)
	if PendingRequests[player] then
		return "Refused", "Request already in progress"
	end

	PendingRequests[player] = true
	local success, answer, reason = pcall(answer_request, player, key)
	PendingRequests[player] = nil

	if not success then
		warn(`[MarketService] Failed to answer purchase request from {player.Name} ({player.UserId}): {answer}`)
		return "Unavailable", nil
	end
	return answer :: Types.PurchaseAnswer, reason -- pcall widens the literal union to string
end

local Requests = {}

--[=[
	Sets the check every purchase request must pass before anything is prompted or simulated.
	Returning false (or erroring) answers "Refused" with the returned reason. Server-only; can
	be set before or after Init, and nil clears it.

	@param gate PurchaseGate? -- (player, key) -> (allowed, reason?)
]=]
Requests.SetPurchaseGate = function(gate: Types.PurchaseGate?)
	assert(RunService:IsServer(), "[MarketService] SetPurchaseGate can only be called from the server")
	PurchaseGate = gate
end

--[=[
	Sets which players' purchase requests are simulated instead of prompted, for listed and
	unlisted items alike. With no check set nothing is ever simulated. Server-only; can be set
	before or after Init, and nil clears it.

	@param check TestBuyerCheck? -- (player, key) -> boolean
]=]
Requests.SetTestBuyerCheck = function(check: Types.TestBuyerCheck?)
	assert(RunService:IsServer(), "[MarketService] SetTestBuyerCheck can only be called from the server")
	TestBuyerCheck = check
end

--[=[
	Asks the server to buy a registered product or pass for the local player. The server shows
	Roblox's prompt, simulates the purchase for a test buyer, or refuses. Client-only.

	A simulated purchase fires `ProductPurchaseFinished` / `PassPurchaseFinished` on the client
	too, possibly before this returns.

	@yields
	@param key string -- The key the item was registered with
	@return PurchaseAnswer -- What the server did
	@return string? -- Why, when refused
]=]
Requests.RequestPurchaseAsync = function(key: string): (Types.PurchaseAnswer, string?)
	assert(State.Initialised, "[MarketService] MarketService must be initialised before requesting purchases")
	assert(RunService:IsClient(), "[MarketService] RequestPurchaseAsync can only be called from the client")

	local remote = script.Parent:WaitForChild(REMOTE_NAME, REMOTE_WAIT_TIMEOUT) :: RemoteFunction?
	if remote == nil then
		warn(`[MarketService] Purchase request for '{key}' failed: the server hasn't initialised MarketService`)
		return "Unavailable", nil
	end

	local success, answer, reason = pcall(remote.InvokeServer, remote, key)
	if not success then
		warn(`[MarketService] Purchase request for '{key}' failed: {answer}`)
		return "Unavailable", nil
	end
	return answer, reason
end

--[=[
	Creates the request remote on the server.
	Called internally by MarketService.Init()
]=]
Requests.Init = function()
	if RunService:IsServer() then
		local remote = Instance.new("RemoteFunction")
		remote.Name = REMOTE_NAME
		remote.OnServerInvoke = on_server_invoke
		remote.Parent = script.Parent

		-- A hook that never resumes would otherwise keep the departed player here.
		Players.PlayerRemoving:Connect(function(player)
			PendingRequests[player] = nil
		end)
	end
end

return Requests
