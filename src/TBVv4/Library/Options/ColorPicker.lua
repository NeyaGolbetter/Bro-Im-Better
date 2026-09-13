--[==[
	TBV v4  ::  Library/Options/ColorPicker.lua
	----------------------------------------------------------------------------
	HSV colour picker.

	The saturation/value square is built from three stacked layers rather than a
	texture (no asset dependencies, and it stays crisp at any size):
		layer 1  BackgroundColor3 = Color3.fromHSV(hue, 1, 1)
		layer 2  white overlay, UIGradient transparency 0 -> 1 left->right
				 (= saturation: left is washed out, right is pure hue)
		layer 3  black overlay, UIGradient transparency 0 -> 1 top->bottom
				 (= value: top is bright, bottom is black)
	Using the UIGradient.Transparency NumberSequence for the overlays is the
	trick that makes this work without a shader.

	Serialisation: "#RRGGBB" string (JSON has no Color3 type).
]==]

local import = ...
local Theme = import("Library/Theme")
local Utility = import("Library/Utility")
local Row = import("Library/Options/Row")

local UserInputService = game:GetService("UserInputService")

local ColorPicker = {}

local PANEL_W = 196
local SV_SIZE = Vector2.new(184, 108)
local BAR_H = 10

--- Build a hue bar (rainbow) as a ColorSequence.
local function hueSequence()
	local keys = {}
	for i = 0, 6 do
		keys[i + 1] = ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6, 1, 1))
	end
	return ColorSequence.new(keys)
end

--- Generic horizontal/vertical drag helper for the SV square and hue bar.
-- onDrag(progressX, progressY) receives 0..1 coordinates inside the surface.
local function makeDragSurface(surface, onDrag)
	local dragging = false
	local moveConn, releaseConn

	local function progressFrom(input)
		local position = Vector2.new(input.Position.X, input.Position.Y)
		local absolute = surface.AbsolutePosition
		local size = surface.AbsoluteSize
		return math.clamp((position.X - absolute.X) / math.max(size.X, 1), 0, 1),
			math.clamp((position.Y - absolute.Y) / math.max(size.Y, 1), 0, 1)
	end

	local function stop()
		dragging = false
		if moveConn then moveConn:Disconnect(); moveConn = nil end
		if releaseConn then releaseConn:Disconnect(); releaseConn = nil end
	end

	surface.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			onDrag(progressFrom(input))
			stop()
			moveConn = UserInputService.InputChanged:Connect(function(changed)
				if dragging and (changed.UserInputType == Enum.UserInputType.MouseMovement
					or changed.UserInputType == Enum.UserInputType.Touch) then
					onDrag(progressFrom(changed))
				end
			end)
			releaseConn = UserInputService.InputEnded:Connect(function(ended)
				if ended.UserInputType == Enum.UserInputType.MouseButton1
					or ended.UserInputType == Enum.UserInputType.Touch then
					stop()
				end
			end)
		end
	end)

	return stop
end

function ColorPicker.new(api, data)
	local row = Row.new(api, data)

	---------------------------------------------------------------- swatch
	local swatch = Utility:Create("TextButton", {
		Name = "Swatch",
		Size = UDim2.new(1, -2, 0, 20),
		Position = UDim2.new(0, 1, 0.5, -10),
		BackgroundColor3 = data.Default or Theme.Colors.AccentTo,
		AutoButtonColor = false,
		Font = Theme.Fonts.Mono,
		TextSize = Theme.TextSize.Micro,
		TextColor3 = Theme.Colors.Text,
		Text = "",
		Parent = row.Control,
	})
	Utility:AddCorner(swatch, Theme.Sizes.CornerSm)
	Utility:AddStroke(swatch, Theme.Colors.Outline, 1)

	local option = {
		Type = "ColorPicker",
		Name = data.Name,
		Flag = data.Flag or data.Name,
		Frame = row.Frame,
		Value = data.Default or Color3.fromRGB(255, 255, 255),
		Callback = data.Callback,
	}

	local panel = nil
	local isOpen = false
	local popupCloser = function() option:Close() end

	local hue, sat, val = option.Value:ToHSV()
	local hueGradient = nil
	local svKnob, hueKnob = nil, nil
	local hexBox = nil

	function option:Render()
		swatch.BackgroundColor3 = self.Value
		if hueGradient then
			-- Keep the SV square's base colour in sync with the current hue.
			hueGradient.BackgroundColor3 = Color3.fromHSV(hue, 1, 1)
		end
		if svKnob then
			svKnob.Position = UDim2.new(sat, 0, val, 0)
		end
		if hueKnob then
			hueKnob.Position = UDim2.new(hue, -BAR_H / 2, 0.5, 0)
		end
		if hexBox and not hexBox:IsFocused() then
			hexBox.Text = "#" .. self.Value:ToHex()
		end
	end

	function option:SetValue(color, skipCallback)
		if typeof(color) ~= "Color3" then return end
		self.Value = color
		hue, sat, val = color:ToHSV()
		self:Render()
		if not skipCallback then
			if self.Callback then self.Callback(color) end
			if api.OnOptionChanged then api.OnOptionChanged(self) end
		end
	end

	function option:GetValue()
		return self.Value
	end

	---------------------------------------------------------------- panel
	local function buildPanel()
		if panel then return panel end

		panel = Utility:Create("Frame", {
			Name = "ColorPanel",
			Size = UDim2.fromOffset(PANEL_W, 0),
			BackgroundColor3 = Theme.Colors.Surface,
			ClipsDescendants = true,
			ZIndex = 60,
			Visible = false,
			Parent = api.Overlay,
		})
		Utility:AddCorner(panel, Theme.Sizes.Corner)
		Utility:AddStroke(panel, Theme.Colors.Outline, 1)

		-- Layer 1: pure hue.
		hueGradient = Utility:Create("Frame", {
			Name = "SVBase",
			Size = UDim2.fromOffset(SV_SIZE.X, SV_SIZE.Y),
			Position = UDim2.fromOffset(6, 6),
			BackgroundColor3 = Color3.fromHSV(hue, 1, 1),
			ZIndex = 61,
			Parent = panel,
		})
		Utility:AddCorner(hueGradient, 4)

		-- Layer 2: white, transparent at the right (saturation).
		local satOverlay = Utility:Create("Frame", {
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundColor3 = Color3.new(1, 1, 1),
			ZIndex = 62,
			Parent = hueGradient,
		})
		Utility:AddCorner(satOverlay, 4)
		Utility:Create("UIGradient", {
			Color = ColorSequence.new(Color3.new(1, 1, 1)),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = satOverlay,
		})

		-- Layer 3: black, opaque at the bottom (value).
		local valOverlay = Utility:Create("Frame", {
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundColor3 = Color3.new(0, 0, 0),
			ZIndex = 63,
			Parent = hueGradient,
		})
		Utility:AddCorner(valOverlay, 4)
		Utility:Create("UIGradient", {
			Color = ColorSequence.new(Color3.new(0, 0, 0)),
			Rotation = 90,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = valOverlay,
		})

		svKnob = Utility:Create("Frame", {
			Name = "SVKnob",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(10, 10),
			BackgroundColor3 = Color3.new(1, 1, 1),
			ZIndex = 65,
			Parent = hueGradient,
		})
		Utility:AddCorner(svKnob, 5)
		Utility:AddStroke(svKnob, Theme.Colors.Shadow, 1, 0.3)

		-- Hue bar.
		local hueBar = Utility:Create("Frame", {
			Name = "HueBar",
			Size = UDim2.fromOffset(SV_SIZE.X, BAR_H),
			Position = UDim2.fromOffset(6, 6 + SV_SIZE.Y + 8),
			BackgroundColor3 = Color3.new(1, 1, 1),
			ZIndex = 61,
			Parent = panel,
		})
		Utility:AddCorner(hueBar, BAR_H / 2)
		Utility:Create("UIGradient", { Color = hueSequence(), Parent = hueBar })

		hueKnob = Utility:Create("Frame", {
			Name = "HueKnob",
			AnchorPoint = Vector2.new(0, 0.5),
			Size = UDim2.fromOffset(BAR_H, BAR_H + 6),
			BackgroundColor3 = Color3.new(1, 1, 1),
			ZIndex = 65,
			Parent = hueBar,
		})
		Utility:AddCorner(hueKnob, (BAR_H + 6) / 2)
		Utility:AddStroke(hueKnob, Theme.Colors.Shadow, 1, 0.3)

		-- Hex entry.
		hexBox = Utility:Create("TextBox", {
			Name = "Hex",
			Size = UDim2.fromOffset(PANEL_W - 12, 22),
			Position = UDim2.fromOffset(6, 6 + SV_SIZE.Y + 8 + BAR_H + 8),
			BackgroundColor3 = Theme.Colors.Background,
			Font = Theme.Fonts.Mono,
			TextSize = Theme.TextSize.Micro,
			TextColor3 = Theme.Colors.Text,
			ClearTextOnFocus = false,
			TextXAlignment = Enum.TextXAlignment.Center,
			ZIndex = 61,
			Parent = panel,
		})
		Utility:AddCorner(hexBox, Theme.Sizes.CornerSm)
		Utility:AddStroke(hexBox, Theme.Colors.Outline, 1)

		local doneButton = Utility:Create("TextButton", {
			Name = "Done",
			Size = UDim2.fromOffset(PANEL_W - 12, 22),
			Position = UDim2.fromOffset(6, 6 + SV_SIZE.Y + 8 + BAR_H + 8 + 22 + 6),
			BackgroundColor3 = Theme.Colors.SurfaceAlt,
			AutoButtonColor = false,
			Font = Theme.Fonts.Title,
			TextSize = Theme.TextSize.Small,
			TextColor3 = Theme.Colors.Text,
			Text = "DONE",
			ZIndex = 61,
			Parent = panel,
		})
		Utility:AddCorner(doneButton, Theme.Sizes.CornerSm)
		Utility:Press(doneButton, function() option:Close() end)
		Utility:Hover(doneButton, { Speed = "Instant" })

		option._PanelHeight = 6 + SV_SIZE.Y + 8 + BAR_H + 8 + 22 + 6 + 22 + 6

		---------------------------------------------------------- interaction
		makeDragSurface(hueGradient, function(px, py)
			sat, val = px, 1 - py
			option:SetValue(Color3.fromHSV(hue, sat, val))
		end)

		makeDragSurface(hueBar, function(px)
			hue = px
			option:SetValue(Color3.fromHSV(hue, sat, val))
		end)

		hexBox.FocusLost:Connect(function()
			local hex = (hexBox.Text or ""):gsub("#", "")
			if #hex == 6 and hex:match("^%x+$") then
				option:SetValue(Color3.fromHex(hex))
			else
				option:Render() -- restore a valid hex string
			end
		end)

		return panel
	end

	function option:Open()
		if isOpen then return end
		isOpen = true

		local popup = buildPanel()
		local height = option._PanelHeight or 200
		local screen = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
		local x = math.clamp(swatch.AbsolutePosition.X + swatch.AbsoluteSize.X - PANEL_W, 4, math.max(4, screen.X - PANEL_W - 4))
		local y = swatch.AbsolutePosition.Y + swatch.AbsoluteSize.Y + 4
		if y + height > screen.Y then
			y = math.max(4, swatch.AbsolutePosition.Y - height - 4)
		end

		popup.Position = UDim2.fromOffset(x, y)
		popup.Size = UDim2.fromOffset(PANEL_W, 0)
		popup.Visible = true
		self:Render()

		api:RegisterPopup(popupCloser)

		Utility:Tween(popup, Theme:Info("Normal", Theme.Easing.Emphasized), {
			Size = UDim2.fromOffset(PANEL_W, height),
		}, "size")
		Utility:Fade(popup, "In", Theme.Timing.Fast)
	end

	function option:Close()
		if not isOpen or not panel then return end
		isOpen = false
		api:UnregisterPopup(popupCloser)
		local popup = panel
		Utility:CancelTweens(popup)
		Utility:Tween(popup, Theme:Info("Fast", Theme.Easing.Emphasized), {
			Size = UDim2.fromOffset(PANEL_W, 0),
		}, "size")
		Utility:Fade(popup, "Out", Theme.Timing.Fast, function()
			popup.Visible = false
		end)
	end

	Utility:Press(swatch, function()
		if isOpen then option:Close() else option:Open() end
	end)

	option:Render()
	return option
end

function ColorPicker.Serialize(option)
	return "#" .. option.Value:ToHex()
end

function ColorPicker.Deserialize(option, raw)
	if type(raw) ~= "string" then return end
	local hex = raw:gsub("#", "")
	if #hex == 6 and hex:match("^%x+$") then
		-- fromHex is preferred; fall back to manual parsing on older clients.
		local ok, color = pcall(Color3.fromHex, hex)
		if ok and typeof(color) == "Color3" then
			option:SetValue(color, true)
		else
			option:SetValue(Theme.FromHex(hex), true)
		end
	end
end

return ColorPicker
