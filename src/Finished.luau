--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local State = require(script.Parent.State)

--- Carries simulated purchase-finished events to the buyer's client, which never hears of
--- them from MarketplaceService.
local SimulatedFinishedRemote: RemoteEvent = nil :: any -- Initialized in Init

local Finished = {}

--[=[
	Fires `ProductPurchaseFinished` or `PassPurchaseFinished` on this side only.
]=]
Finished.FireLocal = function(
	player: Player,
	item_type: "Product" | "Pass",
	key: string,
	was_purchased: boolean,
	was_simulated: boolean
)
	if item_type == "Product" then
		State.ProductPurchaseFinished:Fire(player, key, was_purchased, was_simulated)
	else
		State.PassPurchaseFinished:Fire(player, key, was_purchased, was_simulated)
	end
end

--[=[
	Fires the finished event for a simulated purchase, with `wasPurchased` true, on the server
	and on `player`'s client, as a real purchase would. Server-only.
]=]
Finished.FireSimulated = function(player: Player, item_type: "Product" | "Pass", key: string)
	assert(RunService:IsServer(), "[MarketService] FireSimulated can only be called from the server")

	Finished.FireLocal(player, item_type, key, true, true)

	if player.Parent == Players then
		SimulatedFinishedRemote:FireClient(player, item_type, key, true)
	end
end

--[=[
	Tells `player`'s client its simulate request was declined, with `wasPurchased` false, so a
	UI waiting on the finished event clears. Fires nothing on the server, where no purchase was
	attempted. Server-only.
]=]
Finished.FireDeclined = function(player: Player, item_type: "Product" | "Pass", key: string)
	assert(RunService:IsServer(), "[MarketService] FireDeclined can only be called from the server")

	if player.Parent == Players then
		SimulatedFinishedRemote:FireClient(player, item_type, key, false)
	end
end

--[=[
	Creates the replication remote on the server and listens to it on the client.
	Called internally by MarketService.Init()
]=]
Finished.Init = function()
	if RunService:IsServer() then
		SimulatedFinishedRemote = Instance.new("RemoteEvent")
		SimulatedFinishedRemote.Name = "SimulatedPurchaseFinished"
		SimulatedFinishedRemote.Parent = script.Parent
	else
		task.spawn(function()
			SimulatedFinishedRemote = script.Parent:WaitForChild("SimulatedPurchaseFinished") :: RemoteEvent
			SimulatedFinishedRemote.OnClientEvent:Connect(
				function(item_type: "Product" | "Pass", key: string, was_purchased: boolean)
					local local_player = Players.LocalPlayer
					if local_player then
						Finished.FireLocal(local_player, item_type, key, was_purchased, true)
					end
				end
			)
		end)
	end
end

return Finished
