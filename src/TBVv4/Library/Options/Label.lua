--[==[
	TBV v4  ::  Library/Options/Label.lua
	----------------------------------------------------------------------------
	Static (or module-updated) text row. Used for hints, credits and live status
	readouts - module code can call :SetText() at any time.

	Height is measured with TextService so wrapped text is never clipped, and
	the parent list layout re-flows automatically because the module card sizes
	itself with AutomaticSize.
]==]

local import = ...
local Theme = import("Library/Theme")
local Utility = import("Library/Utility")

local TextService = game:GetService("TextService")

local Label = {}

function Label.new(api, data)
	local width = data.Width or 300

	local frame = Utility:Create("Frame", {
		Name = "LabelRow",
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		LayoutOrder = data.LayoutOrder or 0,
		Parent = data.Parent,
	})

	local text = Utility:Create("TextLabel", {
		Name = "Text",
		Size = UDim2.new(1, -8, 0, 16),
		Position = UDim2.new(0, 4, 0, 2),
		BackgroundTransparency = 1,
		Font = data.Font or Theme.Fonts.Sub,
		TextSize = data.TextSize or Theme.TextSize.Small,
		TextColor3 = data.Color or Theme.Colors.TextMuted,
		TextXAlignment = data.Align or Enum.TextXAlignment.Left,
		TextWrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		Text = data.Name or "",
		Parent = frame,
	})

	local option = {
		Type = "Label",
		Name = data.Name,
		Flag = data.Flag or data.Name,
		Frame = frame,
		Value = data.Name,
	}

	--- Update text and grow the row to fit.
	function option:SetText(newText)
		newText = tostring(newText or "")
		self.Value = newText
		text.Text = newText

		local bounds = TextService:GetTextSize(
			newText,
			text.TextSize,
			text.Font,
			Vector2.new(width - 8, math.huge)
		)
		frame.Size = UDim2.new(1, 0, 0, math.max(22, bounds.Y + 6))
	end

	function option:SetColor(color)
		text.TextColor3 = color
	end

	-- Measure once so multi-line default text is laid out correctly.
	option:SetText(data.Name)

	return option
end

function Label.Serialize()
	return nil
end

function Label.Deserialize() end

return Label
