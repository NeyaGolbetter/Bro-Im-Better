--[==[
	TBV v4  ::  Library/Options/TextBox.lua
	----------------------------------------------------------------------------
	Free-text input row.

	Focus feedback: the stroke tweens from the neutral outline colour to the
	brand gradient's start colour (deep purple) on focus, and the background
	lightens. Text is committed on FocusLost with enterPressed, matching how
	Roblox users expect chat-style inputs to behave.

	Serialisation: string.
]==]

local import = ...
local Theme = import("Library/Theme")
local Utility = import("Library/Utility")
local Row = import("Library/Options/Row")

local TextBox = {}

function TextBox.new(api, data)
	local row = Row.new(api, data)

	local box = Utility:Create("TextBox", {
		Name = "Input",
		Size = UDim2.new(1, -2, 0, 22),
		Position = UDim2.new(0, 1, 0.5, -11),
		BackgroundColor3 = Theme.Colors.Background,
		PlaceholderColor3 = Theme.Colors.TextDim,
		Font = Theme.Fonts.Body,
		TextSize = Theme.TextSize.Small,
		TextColor3 = Theme.Colors.Text,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		PlaceholderText = data.Placeholder or "",
		Parent = row.Control,
	})
	Utility:AddCorner(box, Theme.Sizes.CornerSm)
	Utility:Create("UIPadding", { PaddingLeft = UDim.new(0, 6), Parent = box })
	local stroke = Utility:AddStroke(box, Theme.Colors.Outline, 1)

	local option = {
		Type = "TextBox",
		Name = data.Name,
		Flag = data.Flag or data.Name,
		Frame = row.Frame,
		Value = data.Default or "",
		Callback = data.Callback,
	}

	function option:SetValue(value, skipCallback)
		self.Value = tostring(value or "")
		box.Text = self.Value
		if not skipCallback then
			if self.Callback then self.Callback(self.Value) end
			if api.OnOptionChanged then api.OnOptionChanged(self) end
		end
	end

	function option:GetValue()
		return self.Value
	end

	box.FocusLost:Connect(function()
		option:SetValue(box.Text)
		Utility:Tween(stroke, Theme:Info("Fast"), { Color = Theme.Colors.Outline }, "color")
		Utility:Tween(box, Theme:Info("Fast"), { BackgroundColor3 = Theme.Colors.Background }, "color")
	end)

	box.Focused:Connect(function()
		Utility:Tween(stroke, Theme:Info("Fast"), { Color = Theme.Colors.AccentFrom }, "color")
		Utility:Tween(box, Theme:Info("Fast"), { BackgroundColor3 = Theme.Colors.SurfaceAlt }, "color")
	end)

	option:SetValue(option.Value, true)
	return option
end

function TextBox.Serialize(option)
	return option.Value
end

function TextBox.Deserialize(option, raw)
	if type(raw) == "string" then
		option:SetValue(raw, true)
	end
end

return TextBox
