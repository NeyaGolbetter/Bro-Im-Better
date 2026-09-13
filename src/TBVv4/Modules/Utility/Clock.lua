--[==[
	TBV v4  ::  Modules/Utility/Clock.lua
	----------------------------------------------------------------------------
	Small on-screen clock. Demonstrates dropdown + colour picker + toggle options
	and a throttled heartbeat that only touches the label when the displayed
	string actually changes.
]==]

local module = {
	Name = "Clock",
	Tab = "Utility",
	Section = "Display",
	Side = "Left",
	Description = "On-screen local / server clock",
	Default = false,
}

function module:Options(ctx)
	self:AddDropdown({
		Name = "Source",
		Flag = "Source",
		Options = { "Local", "Server" },
		Default = "Local",
	})

	self:AddToggle({
		Name = "24 hour",
		Flag = "TwentyFour",
		Default = true,
	})

	self:AddToggle({
		Name = "Show seconds",
		Flag = "Seconds",
		Default = true,
	})

	self:AddSlider({
		Name = "Text size",
		Flag = "TextSize",
		Min = 10,
		Max = 32,
		Default = 14,
	})

	self:AddColorPicker({
		Name = "Text colour",
		Flag = "TextColor",
		Default = ctx.Theme.Colors.TextMuted,
	})
end

function module:OnEnable(ctx)
	local label = ctx.Utility:Create("TextLabel", {
		Name = "TBV_Clock",
		Position = UDim2.new(0, 14, 0, 86),
		Size = UDim2.fromOffset(180, 22),
		BackgroundTransparency = 1,
		Font = ctx.Theme.Fonts.Mono,
		TextSize = self:GetOption("TextSize").Value,
		TextColor3 = self:GetOption("TextColor").Value,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "--:--",
		ZIndex = 31,
		Parent = ctx.Library.Hud,
	})
	self._Label = label

	local function value(flag)
		local option = self:GetOption(flag)
		return option and option.Value
	end

	self:GetOption("TextSize").Callback = function(v) label.TextSize = v end
	self:GetOption("TextColor").Callback = function(v) label.TextColor3 = v end

	local lastText = nil

	-- 1Hz is plenty for a clock; without the interval this would run 60x/s.
	ctx:OnHeartbeat(function()
		local useServer = value("Source") == "Server"
		local timestamp

		if useServer then
			-- GetServerTimeNow returns seconds since Unix epoch, server-side.
			local ok, serverTime = pcall(function() return workspace:GetServerTimeNow() end)
			timestamp = (ok and type(serverTime) == "number") and serverTime or os.time()
		else
			timestamp = os.time()
		end

		local format
		if value("TwentyFour") then
			format = value("Seconds") and "%H:%M:%S" or "%H:%M"
		else
			format = value("Seconds") and "%I:%M:%S %p" or "%I:%M %p"
		end

		local text = os.date(format, timestamp)
		if text ~= lastText then
			lastText = text
			label.Text = text
		end
	end, 0.25)
end

function module:OnDisable(ctx)
	if self._Label then
		self._Label:Destroy()
		self._Label = nil
	end
end

return module
