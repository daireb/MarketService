--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local State = require(script.Parent.State)

--- Carries simulated purchase-finished events to the buyer's client, which never hears of
--- them from MarketplaceService.
local SimulatedFinishedRemote: RemoteEvent = nil :: any -- Initialized in Init

local fire_local = function(player: Player, item_type: "Product" | "Pass", key: string)
	if item_type == "Product" then
		State.ProductPurchaseFinished:Fire(player, key, true)
	else
		State.PassPurchaseFinished:Fire(player, key, true)
	end
end

local Finished = {}

--[=[
	Fires `ProductPurchaseFinished` or `PassPurchaseFinished` with `wasPurchased` true on the
	server and on `player`'s client, as a real purchase would. Server-only.
]=]
Finished.FireSimulated = function(player: Player, item_type: "Product" | "Pass", key: string)
	assert(RunService:IsServer(), "[MarketService] FireSimulated can only be called from the server")

	fire_local(player, item_type, key)

	if player.Parent == Players then
		SimulatedFinishedRemote:FireClient(player, item_type, key)
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
			SimulatedFinishedRemote.OnClientEvent:Connect(function(item_type: "Product" | "Pass", key: string)
				local local_player = Players.LocalPlayer
				if local_player then
					fire_local(local_player, item_type, key)
				end
			end)
		end)
	end
end

return Finished
