--[==[
	TBV v4  ::  Library/Options/Row.lua
	----------------------------------------------------------------------------
	Shared scaffold for every option widget: one horizontal row with a label on
	the left and a control area on the right.

	Centralising the row means every option has identical padding, label
	typography and height - which is what makes the module cards look tidy even
	when options from different widgets are stacked together.

	Layout (relative to the row width):
		[ Title .................... 0.00 -> 0.46 ]
		[ Control area ............. 0.48 -> 1.00 ]
]==]

local import = ...
local Theme = import("Library/Theme")
local Utility = import("Library/Utility")

local Row = {}

--- data: { Name, Height, LayoutOrder, Parent, Tooltip }
-- Returns a table with .Frame, .Title and .Control (a right-aligned container).
function Row.new(api, data)
	local height = data.Height or Theme.Sizes.Option

	local frame = Utility:Create("Frame", {
		Name = data.Name or "Row",
		Size = UDim2.new(1, 0, 0, height),
		BackgroundTransparency = 1,
		LayoutOrder = data.LayoutOrder or 0,
		Parent = data.Parent,
	})

	local title = Utility:Create("TextLabel", {
		Name = "Title",
		Size = UDim2.new(0.46, -4, 1, 0),
		Position = UDim2.new(0, 2, 0, 0),
		BackgroundTransparency = 1,
		Font = Theme.Fonts.Body,
		TextSize = Theme.TextSize.Body,
		TextColor3 = Theme.Colors.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = data.Name or "",
		Parent = frame,
	})

	-- Controls live in their own container so widget code can lay them out
	-- relative to each other without touching the label.
	local control = Utility:Create("Frame", {
		Name = "Control",
		Size = UDim2.new(0.52, 0, 1, 0),
		Position = UDim2.new(0.48, 0, 0, 0),
		BackgroundTransparency = 1,
		Parent = frame,
	})

	return {
		Frame = frame,
		Title = title,
		Control = control,
		Height = height,
	}
end

return Row
