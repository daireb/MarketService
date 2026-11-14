--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Finished = require(script.Parent.Finished)
local Passes = require(script.Parent.Passes)
local Products = require(script.Parent.Products)
local State = require(script.Parent.State)
local TestBuyers = require(script.Parent.TestBuyers)

type ItemType = "Product" | "Pass"

local REMOTE_NAME = "SimulatePurchase"

--- Seconds before each redelivery of a simulated receipt that the callback left
--- NotProcessedYet, standing in for Roblox's own redelivery. Judgement.
local REDELIVERY_DELAYS = { 5, 15, 45 }

--- Seconds between warnings about one player's rejected simulate requests, so a client firing
--- the remote in a loop can't flood the server's log. Judgement.
local REQUEST_WARN_INTERVAL = 10

--- Client to server: (item_type, key). The server checks everything itself.
local SimulateRemote: RemoteEvent? = nil -- Set in Init; on the client once it has replicated

local last_request_warning: { [Player]: number } = {}

local warn_request = function(player: Player, message: string)
	local now = os.clock()
	local last = last_request_warning[player]
	if last ~= nil and now - last < REQUEST_WARN_INTERVAL then
		return
	end
	last_request_warning[player] = now
	warn(message)
end

--- Simulates a product purchase, redelivering the receipt while the callback answers
--- NotProcessedYet and the player stays, as Roblox would for a real one.
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

--- Simulates a purchase the server has already validated. `from_client` says where a decline
--- is reported: the asking client, or this server.
local simulate = function(player: Player, item_type: ItemType, key: string, from_client: boolean)
	if item_type == "Product" then
		-- Not awaited: the callback may yield for a save.
		task.spawn(simulate_product, key, player)
		return
	end

	if Passes.PlayerOwnsPass(key, player) then
		if from_client then
			Finished.FireDeclined(player, item_type, key)
		else
			Finished.FireLocal(player, item_type, key, false, true)
		end
		return
	end

	Passes.SimulatePassPurchase(key, player)
end

local on_simulate_request = function(player: Player, item_type: unknown, key: unknown)
	local valid_type: ItemType? = nil
	if item_type == "Product" then
		valid_type = "Product"
	elseif item_type == "Pass" then
		valid_type = "Pass"
	end
	if valid_type == nil or typeof(key) ~= "string" then
		warn_request(player, `[MarketService] Malformed simulate request from {player.Name} ({player.UserId})`)
		return
	end

	local data = State.RegisteredPurchaseItems[key]
	if data == nil or data.Type ~= valid_type then
		warn_request(
			player,
			`[MarketService] {player.Name} ({player.UserId}) asked to simulate unknown {valid_type} '{key}'`
		)
		Finished.FireDeclined(player, valid_type, key)
		return
	end

	if not TestBuyers.WillSimulate(key, player) then
		local mode = TestBuyers.GetTestBuyerMode(player)
		warn_request(
			player,
			`[MarketService] Declined to simulate '{key}' for {player.Name} ({player.UserId}): test buyer mode is {mode}`
		)
		Finished.FireDeclined(player, valid_type, key)
		return
	end

	simulate(player, valid_type, key, true)
end

--- Simulates for a test buyer, opens Roblox's prompt for a listed item, or reports that nothing
--- can be bought.
local prompt = function(item_type: ItemType, key: string, player: Player?)
	assert(State.Initialised, "[MarketService] MarketService must be initialised before prompting purchases")

	local is_server = RunService:IsServer()
	local resolved_player: Player
	if is_server then
		assert(player ~= nil, "[MarketService] Player must be provided when prompting purchase from server")
		resolved_player = player
	else
		assert(player == nil, "[MarketService] Player must not be provided when prompting purchase from client")
		resolved_player = Players.LocalPlayer
	end

	local data = State.RegisteredPurchaseItems[key]
	assert(data ~= nil, `[MarketService] No purchase item registered with key '{key}'`)
	assert(data.Type == item_type, `[MarketService] Expected purchase item type to be '{item_type}'`)

	if TestBuyers.WillSimulate(key, player) then
		if is_server then
			simulate(resolved_player, item_type, key, false)
			return
		end

		local remote = SimulateRemote
		if remote == nil then
			warn(`[MarketService] Can't simulate '{key}' yet: the server's MarketService hasn't replicated`)
			Finished.FireLocal(resolved_player, item_type, key, false, true)
			return
		end
		remote:FireServer(item_type, key)
		return
	end

	local asset_id = data.AssetId
	if asset_id == nil then
		warn(`[MarketService] '{key}' is unlisted and {resolved_player.Name} isn't a test buyer, so it can't be bought`)
		Finished.FireLocal(resolved_player, item_type, key, false, false)
		return
	end

	if item_type == "Product" then
		MarketplaceService:PromptProductPurchase(resolved_player, asset_id)
	else
		MarketplaceService:PromptGamePassPurchase(resolved_player, asset_id)
	end
end

local Prompts = {}

--[=[
	Buys a registered product for a player. A test buyer's purchase is simulated: the server
	runs the purchase callback with a mock receipt, redelivering it after 5, 15 and 45 seconds
	while the callback answers NotProcessedYet. Otherwise a listed product opens Roblox's prompt
	on the calling side. An unlisted product for anyone else warns and fires
	`ProductPurchaseFinished` here with `wasPurchased` false.

	@param key string -- The key the product was registered with
	@param player Player? -- The player to prompt the purchase for (server only). Must be nil when called from client.
]=]
Prompts.PromptProductPurchase = function(key: string, player: Player?)
	prompt("Product", key, player)
end

--[=[
	Buys a registered pass for a player. A test buyer's purchase is simulated: the server
	awards the pass for the session, or declines when the player already owns it. Otherwise a
	listed pass opens Roblox's prompt on the calling side. An unlisted pass for anyone else
	warns and fires `PassPurchaseFinished` here with `wasPurchased` false.

	@param key string -- The key the pass was registered with
	@param player Player? -- The player to prompt the purchase for (server only). Must be nil when called from client.
]=]
Prompts.PromptPassPurchase = function(key: string, player: Player?)
	prompt("Pass", key, player)
end

--[=[
	Creates the simulate remote on the server and finds it on the client.
	Called internally by MarketService.Init()
]=]
Prompts.Init = function()
	if RunService:IsServer() then
		local remote = Instance.new("RemoteEvent")
		remote.Name = REMOTE_NAME
		remote.OnServerEvent:Connect(on_simulate_request)
		remote.Parent = script.Parent
		SimulateRemote = remote

		Players.PlayerRemoving:Connect(function(player)
			last_request_warning[player] = nil
		end)
	else
		task.spawn(function()
			SimulateRemote = script.Parent:WaitForChild(REMOTE_NAME) :: RemoteEvent
		end)
	end
end

return Prompts
