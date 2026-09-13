--[==[
	TBV v4  ::  Library/Options/Toggle.lua
	----------------------------------------------------------------------------
	Animated switch.

	UI adjustments over the stock look:
	  * The knob is driven by a SPRING (Utility:Spring) rather than a tween. A
		tween always takes the same time regardless of distance travelled, which
		feels "rubbery" for a 20px switch; a spring accelerates and settles with
		a tiny overshoot that reads as physical. It also interrupts correctly:
		spam-clicking re-targets the spring instead of restarting a tween.
	  * The rail fill is a purple->pink gradient that fades in with the state.
	  * Optional keybind chip on the right; click it, press a key, done.

	Serialisation: booleans are stored as-is.
]==]

local import = ...
local Theme = import("Library/Theme")
local Utility = import("Library/Utility")
local Row = import("Library/Options/Row")

local UserInputService = game:GetService("UserInputService")

local RAIL_W, RAIL_H = 40, 20
local KNOB = 16
local TRAVEL = RAIL_W - KNOB - 4 -- usable slide distance inside the rail

local Toggle = {}

function Toggle.new(api, data)
	local row = Row.new(api, data)

	---------------------------------------------------------------- rail
	local rail = Utility:Create("TextButton", {
		Name = "Rail",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, data.CanBind == false and 0 or -46, 0.5, 0),
		Size = UDim2.fromOffset(RAIL_W, RAIL_H),
		BackgroundColor3 = Theme.Colors.Outline,
		Text = "",
		Parent = row.Control,
	})
	Utility:AddCorner(rail, RAIL_H / 2)

	-- Gradient fill: starts fully transparent and fades in when enabled.
	local fill = Utility:Create("Frame", {
		Name = "Fill",
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Theme.Colors.AccentFrom,
		BackgroundTransparency = 1,
		Parent = rail,
	})
	Utility:AddCorner(fill, RAIL_H / 2)
	Utility:AddGradient(fill, Theme:AccentSequence(), 0, "Accent")

	local knob = Utility:Create("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 2, 0.5, 0),
		Size = UDim2.fromOffset(KNOB, KNOB),
		BackgroundColor3 = Theme.Colors.Text,
		Parent = rail,
	})
	Utility:AddCorner(knob, KNOB / 2)
	Utility:Create("UIStroke", {
		Color = Theme.Colors.Shadow,
		Transparency = 0.6,
		Thickness = 1,
		Parent = knob,
	})

	---------------------------------------------------------------- keybind
	local bindButton
	if data.CanBind ~= false then
		bindButton = Utility:Create("TextButton", {
			Name = "Bind",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, 0, 0.5, 0),
			Size = UDim2.fromOffset(40, 18),
			BackgroundColor3 = Theme.Colors.Background,
			AutoButtonColor = false,
			Font = Theme.Fonts.Mono,
			TextSize = Theme.TextSize.Micro,
			TextColor3 = Theme.Colors.TextDim,
			Text = "NONE",
			Parent = row.Control,
		})
		Utility:AddCorner(bindButton, Theme.Sizes.CornerSm)
		Utility:AddStroke(bindButton, Theme.Colors.Outline, 1)
	end

	---------------------------------------------------------------- state
	local option = {
		Type = "Toggle",
		Name = data.Name,
		Flag = data.Flag or data.Name,
		Frame = row.Frame,
		Value = data.Default == true,
		Bind = data.Bind, -- Enum.KeyCode or nil
		Callback = data.Callback,
		_Object = row,
	}

	-- Spring drives knob X position (0 -> 1 progress along the rail).
	local knobSpring = Utility:Spring(option.Value and 1 or 0, 210, 24)
	knobSpring.Value = option.Value and 1 or 0

	-- One shared UI-updater task: only runs while the spring is moving, then
	-- disconnects itself. This is why a screen with 40 toggles costs nothing
	-- when the user is not interacting with it.
	local updater = nil
	local function ensureUpdater()
		if updater then return end
		updater = Utility:OnHeartbeat(function()
			knob.Position = UDim2.new(0, 2 + TRAVEL * knobSpring.Value, 0.5, 0)
			if knobSpring:IsSettled() then
				knob.Position = UDim2.new(0, 2 + TRAVEL * knobSpring.Target, 0.5, 0)
				if updater then
					updater:Disconnect()
					updater = nil
				end
			end
		end)
	end

	local function render()
		knobSpring:Set(option.Value and 1 or 0)
		ensureUpdater()

		Utility:Tween(fill, Theme:Info("Fast"), {
			BackgroundTransparency = option.Value and 0 or 1,
		}, "transparency")

		Utility:Tween(knob, Theme:Info("Fast"), {
			BackgroundColor3 = option.Value and Theme.Colors.Text or Theme.Colors.TextMuted,
		}, "color")

		Utility:Tween(row.Title, Theme:Info("Fast"), {
			TextColor3 = option.Value and Theme.Colors.Text or Theme.Colors.TextMuted,
		}, "color")
	end

	function option:SetValue(value, skipCallback)
		value = value == true
		if self.Value == value and skipCallback then return end
		self.Value = value
		render()
		if not skipCallback then
			if self.Callback then self.Callback(value) end
			if api.OnOptionChanged then api.OnOptionChanged(self) end
		end
	end

	function option:GetValue()
		return self.Value
	end

	function option:Toggle()
		self:SetValue(not self.Value)
	end

	-- Assigned below if the toggle is bindable; lets :SetBind() refresh the chip
	-- regardless of whether the bind UI exists.
	local refreshBind = nil

	---------------------------------------------------------------- input
	Utility:Press(rail, function()
		option:Toggle()
	end, { RippleColor = Theme.Colors.PinkLight })

	--- Programmatically set (or clear, with nil) the keybind.
	function option:SetBind(keyCode)
		self.Bind = keyCode
		if refreshBind then
			refreshBind()
		else
			warn("[TBV v4] attempt to bind a non-bindable toggle: " .. tostring(self.Name))
		end
	end

	-- Right-click the row clears a bind; left-click on the chip sets one.
	if bindButton then
		local listening = false

		refreshBind = function()
			listening = false
			bindButton.Text = option.Bind and option.Bind.Name or "NONE"
			bindButton.TextColor3 = option.Bind and Theme.Colors.PinkLight or Theme.Colors.TextDim
		end

		local inputConnection
		bindButton.MouseButton1Click:Connect(function()
			if listening then
				refreshBind()
				if inputConnection then inputConnection:Disconnect(); inputConnection = nil end
				return
			end
			listening = true
			bindButton.Text = "..."
			bindButton.TextColor3 = Theme.Colors.AccentTo

			-- Capture the next key press.
			inputConnection = UserInputService.InputBegan:Connect(function(input, processed)
				if processed then return end
				if input.UserInputType == Enum.UserInputType.Keyboard then
					-- Escape clears rather than binding Escape itself.
					option.Bind = (input.KeyCode == Enum.KeyCode.Escape) and nil or input.KeyCode
					refreshBind()
					inputConnection:Disconnect()
					inputConnection = nil
					if api.OnOptionChanged then api.OnOptionChanged(option) end
				end
			end)
		end)

		bindButton.MouseButton2Click:Connect(function()
			option.Bind = nil
			refreshBind()
			if api.OnOptionChanged then api.OnOptionChanged(option) end
		end)

		Utility:Hover(bindButton, { Speed = "Fast" })
		refreshBind()
	end

	-- Initial paint (skips callbacks so enabling a profile does not fire logic).
	render()

	return option
end

--- Config <-> object conversion.
-- Binds are serialised by the module card (not here) so every option type
-- shares one bind format.
function Toggle.Serialize(option)
	return option.Value
end

function Toggle.Deserialize(option, raw)
	if type(raw) == "boolean" then
		option:SetValue(raw, true)
	end
end

return Toggle
