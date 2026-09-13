--[==[
	TBV v4  ::  Library/Options/Slider.lua
	----------------------------------------------------------------------------
	Numeric slider with a type-in value box.

	Implementation notes:
	  * Dragging is tracked with UserInputService.InputChanged against the
		track's ABSOLUTE position, so the knob keeps following the cursor even
		when it leaves the track (or the window) - the usual failure mode with
		MouseButton1Down-only implementations.
	  * While dragging we skip the tween and write Size/Position directly;
		tweens are only used for click-to-set and keyboard-style value changes.
	  * Value text is only re-rendered when the rounded value actually changes,
		which avoids spamming TextLabel updates (text re-layout is expensive).

	Serialisation: stored as a number.
]==]

local import = ...
local Theme = import("Library/Theme")
local Utility = import("Library/Utility")
local Row = import("Library/Options/Row")

local UserInputService = game:GetService("UserInputService")

local Slider = {}

function Slider.new(api, data)
	local row = Row.new(api, data)
	local min = data.Min or 0
	local max = data.Max or 100
	local decimals = data.Decimals or 0
	local suffix = data.Suffix or ""

	local track = Utility:Create("TextButton", {
		Name = "Track",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(1, -54, 0, 4),
		BackgroundColor3 = Theme.Colors.Outline,
		Text = "",
		Parent = row.Control,
	})
	Utility:AddCorner(track, 2)

	-- Filled portion: width = progress, coloured with the brand gradient.
	local fill = Utility:Create("Frame", {
		Name = "Fill",
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = Theme.Colors.AccentFrom,
		Parent = track,
	})
	Utility:AddCorner(fill, 2)
	Utility:AddGradient(fill, Theme:AccentSequence(), 0, "Accent")

	local knob = Utility:Create("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.fromOffset(12, 12),
		BackgroundColor3 = Theme.Colors.Text,
		ZIndex = 3,
		Parent = track,
	})
	Utility:AddCorner(knob, 6)
	Utility:AddStroke(knob, Theme.Colors.Shadow, 1, 0.5)

	local valueBox = Utility:Create("TextBox", {
		Name = "Value",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(46, 20),
		BackgroundColor3 = Theme.Colors.Background,
		Font = Theme.Fonts.Mono,
		TextSize = Theme.TextSize.Micro,
		TextColor3 = Theme.Colors.Text,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = row.Control,
	})
	Utility:AddCorner(valueBox, Theme.Sizes.CornerSm)
	Utility:AddStroke(valueBox, Theme.Colors.Outline, 1)

	local option = {
		Type = "Slider",
		Name = data.Name,
		Flag = data.Flag or data.Name,
		Frame = row.Frame,
		Value = data.Default or min,
		Min = min,
		Max = max,
		Decimals = decimals,
		Suffix = suffix,
		Callback = data.Callback,
	}

	local lastRendered = nil

	local function clampValue(value)
		if value ~= value or value == math.huge or value == -math.huge then -- NaN guard
			return min
		end
		return math.clamp(Utility:Round(value, decimals), min, max)
	end

	--- Visual update. instant = true skips the tween (used while dragging).
	function option:Render(instant)
		local progress = (self.Min == self.Max) and 0 or ((self.Value - self.Min) / (self.Max - self.Min))
		progress = math.clamp(progress, 0, 1)

		local fillSize = UDim2.new(progress, 0, 1, 0)
		local knobPos = UDim2.new(progress, 0, 0.5, 0)

		if instant then
			fill.Size = fillSize
			knob.Position = knobPos
		else
			Utility:Tween(fill, Theme:Info("Fast"), { Size = fillSize }, "size")
			Utility:Tween(knob, Theme:Info("Fast"), { Position = knobPos }, "position")
		end

		local text = tostring(Utility:Round(self.Value, decimals))
		if suffix ~= "" then text = text .. suffix end
		if text ~= lastRendered then
			lastRendered = text
			valueBox.Text = text
		end
	end

	function option:SetValue(value, skipCallback)
		value = clampValue(tonumber(value) or min)
		if self.Value == value and skipCallback then return end
		self.Value = value
		self:Render(true)
		if not skipCallback then
			if self.Callback then self.Callback(value) end
			if api.OnOptionChanged then api.OnOptionChanged(self) end
		end
	end

	function option:GetValue()
		return self.Value
	end

	---------------------------------------------------------------- dragging
	local dragging = false

	local function valueFromMouse()
		local absolute = track.AbsolutePosition
		local width = track.AbsoluteSize.X
		if width <= 0 then return option.Value end
		local mouse = UserInputService:GetMouseLocation()
		local progress = math.clamp((mouse.X - absolute.X) / width, 0, 1)
		return min + (max - min) * progress
	end

	local moveConnection, releaseConnection

	local function stopDrag()
		dragging = false
		if moveConnection then moveConnection:Disconnect(); moveConnection = nil end
		if releaseConnection then releaseConnection:Disconnect(); releaseConnection = nil end
	end

	local function startDrag()
		dragging = true
		stopDrag() -- idempotent: clears any stale connections first

		moveConnection = UserInputService.InputChanged:Connect(function(input)
			if not dragging then return end
			if input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch then
				option:SetValue(valueFromMouse())
			end
		end)

		releaseConnection = UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				stopDrag()
				if api.OnOptionChanged then api.OnOptionChanged(option) end
			end
		end)
	end

	track.MouseButton1Down:Connect(function()
		Utility:CancelTweens(fill)
		Utility:CancelTweens(knob)
		option:SetValue(valueFromMouse())
		startDrag()
	end)

	---------------------------------------------------------------- typing
	valueBox.FocusLost:Connect(function(enterPressed)
		local parsed = tonumber((valueBox.Text or ""):gsub("[^%d%.%-]", ""))
		if parsed == nil then
			option:Render(true) -- restore the displayed value
		else
			option:SetValue(parsed)
		end
	end)

	valueBox.Focused:Connect(function()
		Utility:Tween(valueBox, Theme:Info("Fast"), { BackgroundColor3 = Theme.Colors.SurfaceAlt }, "color")
	end)

	option:SetValue(option.Value, true)
	return option
end

function Slider.Serialize(option)
	return option.Value
end

function Slider.Deserialize(option, raw)
	if type(raw) == "number" then
		option:SetValue(raw, true)
	elseif type(raw) == "string" then
		option:SetValue(tonumber(raw) or option.Value, true)
	end
end

return Slider
