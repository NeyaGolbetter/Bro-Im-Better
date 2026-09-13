--[==[
	TBV v4  ::  Library/Options/Button.lua
	----------------------------------------------------------------------------
	Action button: gradient fill, press squash + ripple, no persisted value.
]==]

local import = ...
local Theme = import("Library/Theme")
local Utility = import("Library/Utility")
local Row = import("Library/Options/Row")

local Button = {}

function Button.new(api, data)
	local row = Row.new(api, data)

	local button = Utility:Create("TextButton", {
		Name = "Button",
		Size = UDim2.new(1, -2, 0, 24),
		Position = UDim2.new(0, 1, 0.5, -12),
		BackgroundColor3 = Theme.Colors.AccentFrom,
		AutoButtonColor = false,
		Font = Theme.Fonts.Title,
		TextSize = Theme.TextSize.Small,
		TextColor3 = Theme.Colors.Text,
		Text = data.Name or "Button",
		Parent = row.Frame, -- full width: a button is the whole row
	})
	Utility:AddCorner(button, Theme.Sizes.CornerSm)
	Utility:AddGradient(button, Theme:AccentSequence(), 0, "Accent")

	local option = {
		Type = "Button",
		Name = data.Name,
		Flag = data.Flag or data.Name,
		Frame = row.Frame,
		Value = nil,
		Callback = data.Callback,
	}

	-- Hide the label scaffold: the button replaces the row content entirely.
	row.Title.Visible = false
	row.Control.Visible = false

	Utility:Press(button, function()
		if option.Callback then option.Callback() end
	end, { RippleColor = Theme.Colors.Text })
	Utility:Hover(button, { HoverColor = Theme.Colors.Violet, Speed = "Instant" })

	return option
end

function Button.Serialize()
	return nil -- buttons hold no state
end

function Button.Deserialize() end

return Button
