--[==[
	TBV v4  ::  Modules/Utility/RaycastProbe.lua
	----------------------------------------------------------------------------
	Developer probe: reports what the centre of the camera is pointing at
	(part name, class, material, distance).

	This is the reference implementation for MODERN RAYCASTING in TBV v4.
	Everything here uses workspace:Raycast + RaycastParams; the deprecated
	FindPartOnRay family appears nowhere in the build. See the migration table in
	Library/Utility.lua for the old -> new mapping.

	Two performance notes that generalise to any raycasting code:
	  1. RaycastParams is built ONCE and reused. Rebuilding the params object (or
		 its filter list) every frame allocates and re-hashes the filter table.
	  2. The cast is throttled by the shared scheduler instead of running every
		 frame - visually identical results for a fraction of the cost.
]==]

local module = {
	Name = "Raycast Probe",
	Tab = "Utility",
	Section = "Developer",
	Side = "Right",
	Description = "Inspect what the camera is pointing at",
	Default = false,
}

function module:Options(ctx)
	self:AddSlider({
		Name = "Max distance",
		Flag = "Distance",
		Min = 10,
		Max = 1000,
		Default = 250,
	})

	self:AddSlider({
		Name = "Refresh rate",
		Flag = "Refresh",
		Min = 0.05,
		Max = 1,
		Default = 0.15,
		Decimals = 2,
		Suffix = "s",
	})

	self:AddToggle({
		Name = "Ignore own character",
		Flag = "IgnoreCharacter",
		Default = true,
	})

	self:AddToggle({
		Name = "Show material",
		Flag = "ShowMaterial",
		Default = true,
	})

	self:AddLabel({ Name = "Aim at a part to inspect it.", Flag = "Readout" })
end

function module:OnEnable(ctx)
	local params = nil
	local filter = {}

	--- (Re)build the cached RaycastParams for the current character.
	local function rebuildParams()
		filter = {}
		if self:GetOption("IgnoreCharacter").Value and ctx.LocalPlayer.Character then
			filter[1] = ctx.LocalPlayer.Character
		end
		-- Cached by filter contents, so repeated calls with the same character
		-- return the identical params object instead of allocating a new one.
		params = ctx:RaycastParams(filter, Enum.RaycastFilterType.Blacklist, true)
	end

	rebuildParams()

	-- A new character means a new ignore target.
	ctx:Connect(ctx.LocalPlayer.CharacterAdded, function()
		rebuildParams()
	end)

	self:GetOption("IgnoreCharacter").Callback = rebuildParams

	local readout = self:GetOption("Readout")
	local lastText = nil

	ctx:OnHeartbeat(function()
		local camera = workspace.CurrentCamera
		if not camera then return end

		local distance = self:GetOption("Distance").Value
		local result = ctx:Raycast(
			camera.CFrame.Position,
			camera.CFrame.LookVector * distance,
			params
		)

		local text
		if not result then
			text = "Nothing within " .. tostring(math.floor(distance)) .. " studs"
		else
			local instance = result.Instance
			local studs = math.floor((result.Position - camera.CFrame.Position).Magnitude * 10) / 10
			text = string.format("%s  (%s)", instance.Name, instance.ClassName)
			if self:GetOption("ShowMaterial").Value then
				text = text .. string.format("  [%s]", tostring(result.Material))
			end
			text = text .. string.format("  %.1f studs", studs)
		end

		if text ~= lastText and readout then
			lastText = text
			readout:SetText(text)
		end
	end, self:GetOption("Refresh").Value)
end

function module:OnDisable(ctx)
	local readout = self:GetOption("Readout")
	if readout then readout:SetText("Aim at a part to inspect it.") end
end

return module
