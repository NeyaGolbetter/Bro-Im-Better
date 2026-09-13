--[==[
	TBV v4  ::  Modules/Utility/FPSCounter.lua
	----------------------------------------------------------------------------
	Reference module. Shows a live FPS readout in the HUD layer.

	It exists to demonstrate the three things every TBV v4 module should do:

	  1. Build its options declaratively in Options() - no Instance.new here.
	  2. Do ALL background work through ctx:OnHeartbeat, which rides the shared
		 scheduler and is throttled to `interval` seconds. One module = zero new
		 connections to RunService.
	  3. Clean up after itself. Everything created in OnEnable is destroyed in
		 OnDisable, and every connection made via ctx:Connect / ctx:OnHeartbeat is
		 disconnected automatically.

	Performance detail worth copying: the text label is only updated when the
	rounded FPS value actually changes. Writing to TextLabel.Text forces a text
	re-layout, so doing it 60x a second for an unchanging "60" is pure waste.
]==]

local module = {
	Name = "FPS Counter",
	Tab = "Utility",
	Section = "Display",
	Side = "Left",
	Description = "Live frames-per-second readout",
	Default = false,
}

function module:Options(ctx)
	self:AddToggle({
		Name = "Show average",
		Flag = "ShowAverage",
		Default = false,
		Tooltip = "Average over the last second instead of instantaneous FPS",
	})

	self:AddSlider({
		Name = "Update rate",
		Flag = "UpdateRate",
		Min = 0.1,
		Max = 2,
		Default = 0.5,
		Decimals = 1,
		Suffix = "s",
	})

	self:AddSlider({
		Name = "Text size",
		Flag = "TextSize",
		Min = 10,
		Max = 32,
		Default = 16,
	})

	self:AddColorPicker({
		Name = "Text colour",
		Flag = "TextColor",
		Default = ctx.Theme.Colors.PinkLight,
	})

	self:AddLabel({
		Name = "FPS is sampled from the shared heartbeat scheduler, so this readout costs one extra accumulator check per frame.",
	})
end

function module:OnEnable(ctx)
	-- HUD element. Parented to the shared HUD layer, not to a new ScreenGui.
	local label = ctx.Utility:Create("TextLabel", {
		Name = "TBV_FPS",
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(0, 14, 0, 60),
		Size = UDim2.fromOffset(140, 22),
		BackgroundTransparency = 1,
		Font = ctx.Theme.Fonts.Mono,
		TextSize = self:GetOption("TextSize").Value,
		TextColor3 = self:GetOption("TextColor").Value,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "FPS: --",
		ZIndex = 31,
		Parent = ctx.Library.Hud,
	})
	self._Label = label

	local frames = 0
	local elapsed = 0
	local lastShown = nil

	-- Options are read through getters so live changes apply without a reboot.
	local function optionValue(flag)
		local option = self:GetOption(flag)
		return option and option.Value
	end

	self:GetOption("TextSize").Callback = function(value)
		label.TextSize = value
	end
	self:GetOption("TextColor").Callback = function(value)
		label.TextColor3 = value
	end

	-- Throttled: the interval comes from the slider and is read each tick.
	ctx:OnHeartbeat(function(dt)
		frames = frames + 1
		elapsed = elapsed + dt

		if elapsed < optionValue("UpdateRate") then return end

		local fps = math.floor(frames / elapsed + 0.5)
		frames = 0
		elapsed = 0

		-- Skip redundant text writes (text re-layout is not free).
		if fps ~= lastShown then
			lastShown = fps
			label.Text = string.format("FPS: %d", fps)
			-- Colour-code the readout: green > 50, amber > 30, red below.
			label.TextColor3 = fps >= 50 and ctx.Theme.Colors.Success
				or (fps >= 30 and ctx.Theme.Colors.Warning or ctx.Theme.Colors.Danger)
		end
	end, 0)

	label.Text = "FPS: --"
end

function module:OnDisable(ctx)
	-- ctx disconnects our heartbeat task; we only own the HUD label.
	if self._Label then
		self._Label:Destroy()
		self._Label = nil
	end
end

return module
