--[==[
	TBV v4  ::  Library/Objects.lua
	----------------------------------------------------------------------------
	Every frame in TBV v4 is built here, so layout lives in exactly one place and
	modules never touch raw Roblox instances.

	Hierarchy:

		ScreenGui
		 ├── Overlay ............ popups (dropdowns, colour panels) live here so
		 │                       they are never clipped by scroll frames
		 ├── Watermark .......... small always-on-top HUD
		 ├── Notifications ...... bottom-right toast stack
		 └── Window
			  ├── Header ........ draggable; logo, search, hide/close
			  └── Body
				   ├── TabColumn  vertical tab strip
				   └── Content ... scrolling columns of Sections

	ZIndex strategy: the ScreenGui uses Sibling behaviour, so ordering is decided
	by each branch's ZIndex (window 10, watermark 40, notifications 50, overlay
	60) rather than by deep nesting.
]==]

local import = ...
local Theme = import("Library/Theme")
local Utility = import("Library/Utility")

local Objects = {}

--------------------------------------------------------------------------------
--  Switch (shared by module headers and anywhere else a compact toggle is
--  needed) - spring driven, same feel as the Toggle option widget.
--------------------------------------------------------------------------------

local SWITCH_W, SWITCH_H = 34, 18
local KNOB_SIZE = 14
local SWITCH_TRAVEL = SWITCH_W - KNOB_SIZE - 4

--- data: { Parent, Default, Callback, Anchor }
function Objects.NewSwitch(api, data)
	local frame = Utility:Create("TextButton", {
		Name = "Switch",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(SWITCH_W, SWITCH_H),
		Position = data.Position or UDim2.new(1, -8, 0.5, 0),
		AnchorPoint = data.Anchor or Vector2.new(1, 0.5),
		BackgroundColor3 = Theme.Colors.Outline,
		Text = "",
		Parent = data.Parent,
	})
	Utility:AddCorner(frame, SWITCH_H / 2)

	local fill = Utility:Create("Frame", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Theme.Colors.AccentFrom,
		BackgroundTransparency = 1,
		Parent = frame,
	})
	Utility:AddCorner(fill, SWITCH_H / 2)
	Utility:AddGradient(fill, Theme:AccentSequence(), 0, "Accent")

	local knob = Utility:Create("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 2, 0.5, 0),
		Size = UDim2.fromOffset(KNOB_SIZE, KNOB_SIZE),
		BackgroundColor3 = Theme.Colors.TextMuted,
		Parent = frame,
	})
	Utility:AddCorner(knob, KNOB_SIZE / 2)

	local switch = { Frame = frame, Value = data.Default == true }

	local spring = Utility:Spring(switch.Value and 1 or 0, 220, 24)
	spring.Value = switch.Value and 1 or 0

	local updater = nil
	local function ensureUpdater()
		if updater then return end
		updater = Utility:OnHeartbeat(function()
			knob.Position = UDim2.new(0, 2 + SWITCH_TRAVEL * spring.Value, 0.5, 0)
			if spring:IsSettled() then
				knob.Position = UDim2.new(0, 2 + SWITCH_TRAVEL * spring.Target, 0.5, 0)
				if updater then updater:Disconnect(); updater = nil end
			end
		end)
	end

	function switch:Render()
		spring:Set(self.Value and 1 or 0)
		ensureUpdater()
		Utility:Tween(fill, Theme:Info("Fast"), { BackgroundTransparency = self.Value and 0 or 1 }, "transparency")
		Utility:Tween(knob, Theme:Info("Fast"), {
			BackgroundColor3 = self.Value and Theme.Colors.Text or Theme.Colors.TextMuted,
		}, "color")
	end

	function switch:Set(value, skipCallback)
		value = value == true
		if self.Value == value then return end
		self.Value = value
		self:Render()
		if not skipCallback and data.Callback then data.Callback(value) end
	end

	Utility:Press(frame, function()
		switch:Set(not switch.Value)
	end, { RippleColor = Theme.Colors.PinkLight })

	switch:Render()
	return switch
end

--------------------------------------------------------------------------------
--  Module card
--------------------------------------------------------------------------------

local CARD_HEAD = Theme.Sizes.ModuleHead

--- data: { Name, Description, Parent, Default, OnToggle }
function Objects.NewModuleCard(api, data)
	local card = {
		Name = data.Name,
		Options = {},
		OptionsByFlag = {},
		Enabled = data.Default == true,
		Expanded = false,
	}

	local frame = Utility:Create("Frame", {
		Name = data.Name,
		Size = UDim2.new(1, 0, 0, CARD_HEAD),
		BackgroundColor3 = Theme.Colors.Surface,
		ClipsDescendants = true,
		Parent = data.Parent,
	})
	Utility:AddCorner(frame, Theme.Sizes.Corner)
	local stroke = Utility:AddStroke(frame, Theme.Colors.Outline, 1)
	card.Frame = frame

	-- Left accent bar: a 3px purple->pink stripe that fades in when enabled.
	local accentBar = Utility:Create("Frame", {
		Name = "AccentBar",
		Size = UDim2.new(0, 3, 1, 0),
		BackgroundColor3 = Theme.Colors.AccentFrom,
		BackgroundTransparency = 1,
		Parent = frame,
	})
	Utility:AddGradient(accentBar, Theme:AccentSequence(), 90, "Accent")
	Utility:Create("UICorner", { CornerRadius = UDim.new(0, 3), Parent = accentBar })

	---------------------------------------------------------------- header
	local header = Utility:Create("TextButton", {
		Name = "Header",
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, CARD_HEAD),
		Position = UDim2.new(0, 0, 0, 0),
		BackgroundTransparency = 1,
		Text = "",
		Parent = frame,
	})

	local title = Utility:Create("TextLabel", {
		Name = "Title",
		Size = UDim2.new(1, -70, 1, 0),
		Position = UDim2.new(0, 12, 0, 0),
		BackgroundTransparency = 1,
		Font = Theme.Fonts.Title,
		TextSize = Theme.TextSize.Title,
		TextColor3 = Theme.Colors.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = data.Name,
		Parent = header,
	})

	-- Status text (module code can update it live, e.g. "3 targets").
	local status = Utility:Create("TextLabel", {
		Name = "Status",
		Size = UDim2.new(1, -70, 0, 12),
		Position = UDim2.new(0, 12, 0, 22),
		BackgroundTransparency = 1,
		Font = Theme.Fonts.Sub,
		TextSize = Theme.TextSize.Micro,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = data.Description or "",
		Parent = header,
	})
	card.StatusLabel = status

	local switch = Objects.NewSwitch(api, {
		Parent = header,
		Default = card.Enabled,
		Callback = function(value)
			card:SetEnabled(value)
		end,
	})

	---------------------------------------------------------------- body
	local body = Utility:Create("Frame", {
		Name = "Body",
		Size = UDim2.new(1, -16, 0, 0),
		Position = UDim2.new(0, 8, 0, CARD_HEAD),
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = frame,
	})
	Utility:AddList(body, Enum.FillDirection.Vertical, 4)
	card.Body = body

	---------------------------------------------------------------- behaviour
	function card:SetEnabled(value, skipCallback)
		value = value == true
		self.Enabled = value
		switch:Set(value, true)

		-- Enabled state: brighter surface, accent stroke, white title, accent bar.
		Utility:Tween(frame, Theme:Info("Fast"), {
			BackgroundColor3 = value and Theme.Colors.SurfaceAlt or Theme.Colors.Surface,
		}, "color")
		Utility:Tween(stroke, Theme:Info("Fast"), {
			Color = value and Theme.Colors.Violet or Theme.Colors.Outline,
		}, "color")
		Utility:Tween(title, Theme:Info("Fast"), {
			TextColor3 = value and Theme.Colors.Text or Theme.Colors.TextMuted,
		}, "color")
		Utility:Tween(accentBar, Theme:Info("Normal"), {
			BackgroundTransparency = value and 0 or 1,
		}, "transparency")

		if not skipCallback and data.OnToggle then data.OnToggle(value) end
	end

	function card:Toggle()
		self:SetEnabled(not self.Enabled)
	end

	--- Expand/collapse the option list. Height is measured from the body (which
	-- autosizes to its content) so the card grows to exactly the right size.
	function card:SetExpanded(value)
		value = value == true
		self.Expanded = value
		local height = CARD_HEAD + (value and (body.AbsoluteSize.Y + 8) or 0)
		Utility:Tween(frame, Theme:Info("Normal", Theme.Easing.Emphasized), {
			Size = UDim2.new(1, 0, 0, height),
		}, "size")
	end

	function card:RecalculateHeight()
		if self.Expanded then
			frame.Size = UDim2.new(1, 0, 0, CARD_HEAD + body.AbsoluteSize.Y + 8)
		end
	end

	function card:SetStatus(text)
		status.Text = tostring(text or "")
	end

	function card:SetDescription(text)
		status.Text = tostring(text or "")
	end

	function card:SetVisible(value)
		frame.Visible = value == true
		-- AbsoluteSize is 0 while hidden, so restore the height when shown again.
		if value then self:RecalculateHeight() end
	end

	--- Attach an option widget. kind: "Toggle" | "Slider" | ...
	function card:AddOption(kind, optionData)
		local widget = api.OptionTypes[kind]
		if not widget then
			warn("[TBV v4] unknown option type: " .. tostring(kind))
			return nil
		end

		optionData = optionData or {}
		optionData.Parent = body
		optionData.LayoutOrder = #self.Options + 1

		local option = widget.new(api, optionData)
		option.Module = self
		option.Card = self

		self.Options[#self.Options + 1] = option
		if option.Flag then self.OptionsByFlag[option.Flag] = option end

		-- Keep an expanded card correctly sized as options are added.
		if self.Expanded then
			task.defer(function() self:RecalculateHeight() end)
		end

		return option
	end

	-- Click header -> expand/collapse. Right-click header -> toggle on/off.
	header.MouseButton1Click:Connect(function()
		if api.PopupOpen then api:ClosePopups() end
		card:SetExpanded(not card.Expanded)
	end)
	header.MouseButton2Click:Connect(function()
		card:Toggle()
	end)

	Utility:Hover(frame, { HoverColor = Theme.Colors.SurfaceAlt, Speed = "Fast" })

	card:SetEnabled(card.Enabled, true)
	return card
end

--------------------------------------------------------------------------------
--  Section (a titled group of module cards inside a column)
--------------------------------------------------------------------------------

--- data: { Name, Parent, LayoutOrder }
function Objects.NewSection(api, data)
	local section = { Name = data.Name, Cards = {} }

	local frame = Utility:Create("Frame", {
		Name = data.Name or "Section",
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		BackgroundTransparency = 1,
		LayoutOrder = data.LayoutOrder or 0,
		Parent = data.Parent,
	})
	section.Frame = frame

	local header = Utility:Create("TextLabel", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		Font = Theme.Fonts.Title,
		TextSize = Theme.TextSize.Title,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = tostring(data.Name or ""):upper(),
		Parent = frame,
	})
	Utility:Create("UIPadding", { PaddingLeft = UDim.new(0, 2), Parent = header })

	-- Gradient underline: ties every section header back to the brand.
	local underline = Utility:Create("Frame", {
		Name = "Underline",
		Size = UDim2.new(1, 0, 0, 2),
		Position = UDim2.new(0, 0, 0, 22),
		BackgroundColor3 = Theme.Colors.AccentFrom,
		Parent = frame,
	})
	Utility:AddGradient(underline, Theme:AccentSequence(), 0, "Accent")
	Utility:AddCorner(underline, 1)

	local container = Utility:Create("Frame", {
		Name = "Container",
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		Position = UDim2.new(0, 0, 0, 32),
		BackgroundTransparency = 1,
		Parent = frame,
	})
	Utility:AddList(container, Enum.FillDirection.Vertical, 6)
	section.Container = container

	function section:AddCard(cardData)
		cardData.Parent = container
		local card = Objects.NewModuleCard(api, cardData)
		self.Cards[#self.Cards + 1] = card
		return card
	end

	function section:SetVisible(value)
		frame.Visible = value == true
	end

	return section
end

--------------------------------------------------------------------------------
--  Tab button
--------------------------------------------------------------------------------

--- data: { Name, Parent, LayoutOrder, Selected, OnSelected }
function Objects.NewTab(api, data)
	local tab = { Name = data.Name, Selected = data.Selected == true }

	local button = Utility:Create("TextButton", {
		Name = data.Name,
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = Theme.Colors.SurfaceTop,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Font = Theme.Fonts.Title,
		TextSize = Theme.TextSize.Body,
		TextColor3 = Theme.Colors.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "  " .. tostring(data.Name),
		LayoutOrder = data.LayoutOrder or 0,
		Parent = data.Parent,
	})
	Utility:AddCorner(button, Theme.Sizes.CornerSm)
	Utility:Create("UIPadding", { PaddingLeft = UDim.new(0, 6), Parent = button })

	-- Left indicator: scales from 0 height to full when the tab is active.
	local indicator = Utility:Create("Frame", {
		Name = "Indicator",
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.new(0, 3, 0, 0),
		Position = UDim2.new(0, 0, 0.5, 0),
		BackgroundColor3 = Theme.Colors.AccentFrom,
		Parent = button,
	})
	Utility:AddGradient(indicator, Theme:AccentSequence(), 90, "Accent")
	Utility:AddCorner(indicator, 2)
	tab.Button = button

	--- Paint the selected state.
	-- NOTE: this deliberately does NOT fire data.OnSelected. OnSelected routes
	-- back into Library:SelectTab, and SelectTab calls SetSelected on every tab,
	-- so firing it here recurses forever. Selection callbacks belong to user
	-- input only (see the Press handler below).
	function tab:SetSelected(value)
		value = value == true
		self.Selected = value

		Utility:Tween(button, Theme:Info("Normal"), {
			BackgroundTransparency = value and 0 or 1,
			TextColor3 = value and Theme.Colors.Text or Theme.Colors.TextMuted,
		}, "style")
		Utility:Tween(indicator, Theme:Info("Normal", Theme.Easing.Emphasized), {
			Size = UDim2.new(0, 3, value and 0.7 or 0, 0),
		}, "size")
	end

	Utility:Press(button, function()
		if data.OnSelected then data.OnSelected() end
	end)
	Utility:Hover(button, { HoverColor = Theme.Colors.SurfaceTop, Speed = "Instant" })

	tab:SetSelected(tab.Selected)
	return tab
end

--------------------------------------------------------------------------------
--  Notification toast
--------------------------------------------------------------------------------

--- data: { Title, Text, Duration, Parent }
function Objects.NewNotification(api, data)
	local duration = data.Duration or 4
	local width = 260

	local frame = Utility:Create("Frame", {
		Name = "Notification",
		Size = UDim2.fromOffset(width, 0),
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 20, 1, 0), -- starts off-screen (slides in)
		BackgroundColor3 = Theme.Colors.Surface,
		ClipsDescendants = true,
		Parent = data.Parent,
	})
	Utility:AddCorner(frame, Theme.Sizes.Corner)
	Utility:AddStroke(frame, Theme.Colors.Outline, 1)

	local accent = Utility:Create("Frame", {
		Size = UDim2.new(0, 3, 1, 0),
		BackgroundColor3 = Theme.Colors.AccentFrom,
		Parent = frame,
	})
	Utility:AddGradient(accent, Theme:AccentSequence(), 90, "Accent")

	local title = Utility:Create("TextLabel", {
		Size = UDim2.new(1, -20, 0, 18),
		Position = UDim2.new(0, 14, 0, 8),
		BackgroundTransparency = 1,
		Font = Theme.Fonts.Title,
		TextSize = Theme.TextSize.Body,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = data.Title or "TBV v4",
		Parent = frame,
	})

	local body = Utility:Create("TextLabel", {
		Size = UDim2.new(1, -20, 0, 0),
		Position = UDim2.new(0, 14, 0, 26),
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = Theme.Fonts.Sub,
		TextSize = Theme.TextSize.Small,
		TextColor3 = Theme.Colors.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Text = data.Text or "",
		Parent = frame,
	})

	-- Offsets are measured from the bottom-right corner of the (zero-size)
	-- notification host, so stacking is simple arithmetic on OffsetBottom.
	local bottom = data.OffsetBottom or 8
	local resting = UDim2.fromOffset(-8, -bottom)
	local hidden = UDim2.fromOffset(width + 20, -bottom)

	local height = 34 + body.AbsoluteSize.Y
	frame.Size = UDim2.fromOffset(width, 0)
	frame.Position = hidden

	-- Slide in from the right, then fade out after `duration`.
	Utility:Tween(frame, Theme:Info("Normal", Theme.Easing.Emphasized), {
		Size = UDim2.fromOffset(width, height),
		Position = resting,
	}, "slide")

	task.delay(duration, function()
		Utility:Tween(frame, Theme:Info("Slow", Theme.Easing.Emphasized), {
			Position = hidden,
			Size = UDim2.fromOffset(width, 0),
		}, "slide")
		Utility:Fade(frame, "Out", Theme.Timing.Normal, function()
			frame:Destroy()
		end)
	end)

	return { Frame = frame, Title = title, Body = body }
end

--------------------------------------------------------------------------------
--  Watermark
--------------------------------------------------------------------------------

--- data: { Parent, Lines } - Lines is an array of strings rendered top to bottom.
function Objects.NewWatermark(api, data)
	local frame = Utility:Create("Frame", {
		Name = "TBVv4_Watermark",
		Size = UDim2.fromOffset(180, 0),
		Position = UDim2.fromOffset(12, 12),
		BackgroundColor3 = Theme.Colors.Background,
		BackgroundTransparency = 0.25,
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 40,
		Parent = data.Parent,
	})
	Utility:AddCorner(frame, Theme.Sizes.Corner)
	Utility:AddStroke(frame, Theme.Colors.Outline, 1)
	Utility:AddList(frame, Enum.FillDirection.Vertical, 1)
	Utility:Create("UIPadding", {
		PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
		PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
		Parent = frame,
	})

	local brand = Utility:Create("TextLabel", {
		Name = "Brand",
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundTransparency = 1,
		Font = Theme.Fonts.Header,
		TextSize = 17,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "TBV v4",
		ZIndex = 41,
		Parent = frame,
	})
	Utility:Create("UIGradient", { Color = Theme:AccentSequence(), Parent = brand })

	local lines = {}
	local watermark = { Frame = frame, Lines = lines }

	function watermark:SetLines(newLines)
		-- Reuse existing labels; only create/destroy what is needed.
		for i = 1, math.max(#newLines, #lines) do
			if i > #newLines then
				if lines[i] then lines[i]:Destroy(); lines[i] = nil end
			else
				if not lines[i] then
					lines[i] = Utility:Create("TextLabel", {
						Size = UDim2.new(1, 0, 0, 14),
						BackgroundTransparency = 1,
						Font = Theme.Fonts.Sub,
						TextSize = Theme.TextSize.Micro,
						TextColor3 = Theme.Colors.TextMuted,
						TextXAlignment = Enum.TextXAlignment.Left,
						ZIndex = 41,
						Parent = frame,
					})
				end
				lines[i].Text = tostring(newLines[i])
			end
		end
	end

	watermark:SetLines(data.Lines or {})
	Utility:MakeDraggable(frame, frame)
	return watermark
end

--------------------------------------------------------------------------------
--  Window
--------------------------------------------------------------------------------

--- data: { Parent, Title, Size, OnSearch, OnClose }
function Objects.NewWindow(api, data)
	local window = { Tabs = {} }

	local frame = Utility:Create("Frame", {
		Name = "TBVv4_Window",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.fromOffset(Theme.Sizes.Window.X, Theme.Sizes.Window.Y),
		BackgroundColor3 = Theme.Colors.Background,
		ClipsDescendants = true,
		ZIndex = 10,
		Parent = data.Parent,
	})
	Utility:AddCorner(frame, 10)
	Utility:AddStroke(frame, Theme.Colors.Outline, 1)

	-- Soft outer glow: a slightly larger, very transparent frame behind.
	local glow = Utility:Create("Frame", {
		Name = "Glow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.new(1, 24, 1, 24),
		BackgroundColor3 = Theme.Colors.AccentFrom,
		BackgroundTransparency = 0.92,
		ZIndex = 9,
		Parent = frame.Parent,
	})
	Utility:AddCorner(glow, 18)
	window.Glow = glow

	---------------------------------------------------------------- header
	local header = Utility:Create("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, Theme.Sizes.Header),
		BackgroundColor3 = Theme.Colors.SurfaceTop,
		ZIndex = 11,
		Parent = frame,
	})
	Utility:AddCorner(header, 10)
	-- Square off the bottom corners where the header meets the body.
	Utility:Create("Frame", {
		Size = UDim2.new(1, 0, 0, 10),
		Position = UDim2.new(0, 0, 1, -10),
		BackgroundColor3 = Theme.Colors.SurfaceTop,
		BorderSizePixel = 0,
		ZIndex = 11,
		Parent = header,
	})

	local logo = Utility:Create("TextLabel", {
		Name = "Logo",
		Size = UDim2.new(0, 130, 1, 0),
		Position = UDim2.new(0, 14, 0, 0),
		BackgroundTransparency = 1,
		Font = Theme.Fonts.Header,
		TextSize = Theme.TextSize.Logo,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "TBV v4",
		ZIndex = 12,
		Parent = header,
	})
	Utility:Create("UIGradient", { Color = Theme:AccentSequence(), Parent = logo })

	-- Search: filters module cards across every tab.
	local search = Utility:Create("TextBox", {
		Name = "Search",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -76, 0.5, 0),
		Size = UDim2.fromOffset(180, 24),
		BackgroundColor3 = Theme.Colors.Background,
		PlaceholderColor3 = Theme.Colors.TextDim,
		Font = Theme.Fonts.Body,
		TextSize = Theme.TextSize.Small,
		TextColor3 = Theme.Colors.Text,
		ClearTextOnFocus = false,
		PlaceholderText = "Search modules...",
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 12,
		Parent = header,
	})
	Utility:AddCorner(search, Theme.Sizes.CornerSm)
	Utility:AddStroke(search, Theme.Colors.Outline, 1)
	Utility:Create("UIPadding", { PaddingLeft = UDim.new(0, 8), Parent = search })

	search:GetPropertyChangedSignal("Text"):Connect(function()
		if data.OnSearch then data.OnSearch(search.Text) end
	end)
	window.Search = search

	-- Small circular action buttons on the right.
	local function actionButton(name, position, iconText)
		local button = Utility:Create("TextButton", {
			Name = name,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = position,
			Size = UDim2.fromOffset(24, 24),
			BackgroundColor3 = Theme.Colors.Surface,
			AutoButtonColor = false,
			Font = Theme.Fonts.Title,
			TextSize = Theme.TextSize.Body,
			TextColor3 = Theme.Colors.TextMuted,
			Text = iconText,
			ZIndex = 12,
			Parent = header,
		})
		Utility:AddCorner(button, 12)
		Utility:Hover(button, { HoverColor = Theme.Colors.SurfaceAlt, Speed = "Instant" })
		return button
	end

	local hideButton = actionButton("Hide", UDim2.new(1, -40, 0.5, 0), "-")
	local closeButton = actionButton("Close", UDim2.new(1, -10, 0.5, 0), "x")

	---------------------------------------------------------------- body
	local body = Utility:Create("Frame", {
		Name = "Body",
		Size = UDim2.new(1, 0, 1, -Theme.Sizes.Header),
		Position = UDim2.new(0, 0, 0, Theme.Sizes.Header),
		BackgroundTransparency = 1,
		ZIndex = 11,
		Parent = frame,
	})

	local tabColumn = Utility:Create("ScrollingFrame", {
		Name = "Tabs",
		Size = UDim2.new(0, Theme.Sizes.TabColumn, 1, 0),
		BackgroundColor3 = Theme.Colors.SurfaceTop,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		ScrollBarThickness = 2,
		ScrollBarImageColor3 = Theme.Colors.Violet,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		ZIndex = 12,
		Parent = body,
	})
	Utility:AddList(tabColumn, Enum.FillDirection.Vertical, 4)
	Utility:Create("UIPadding", {
		PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
		Parent = tabColumn,
	})

	local content = Utility:Create("ScrollingFrame", {
		Name = "Content",
		Size = UDim2.new(1, -Theme.Sizes.TabColumn, 1, 0),
		Position = UDim2.new(0, Theme.Sizes.TabColumn, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Theme.Colors.Violet,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		ZIndex = 12,
		Parent = body,
	})

	local columns = Utility:Create("Frame", {
		Name = "Columns",
		Size = UDim2.new(1, -16, 0, 0),
		Position = UDim2.new(0, 8, 0, 8),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 12,
		Parent = content,
	})
	local columnsLayout = Utility:AddList(columns, Enum.FillDirection.Horizontal, 10)
	columnsLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	Utility:Create("UIPadding", { PaddingBottom = UDim.new(0, 8), Parent = columns })

	local leftColumn = Utility:Create("Frame", {
		Name = "Left",
		Size = UDim2.new(0.5, -5, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 12,
		Parent = columns,
	})
	Utility:AddList(leftColumn, Enum.FillDirection.Vertical, 12)

	local rightColumn = Utility:Create("Frame", {
		Name = "Right",
		Size = UDim2.new(0.5, -5, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 12,
		Parent = columns,
	})
	Utility:AddList(rightColumn, Enum.FillDirection.Vertical, 12)

	-- The columns frame only autosizes to its content, so give the canvas a
	-- little breathing room at the bottom.
	columns:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		content.CanvasSize = UDim2.new(0, 0, 0, columns.AbsoluteSize.Y + 16)
	end)

	window.Frame = frame
	window.Header = header
	window.Body = body
	window.TabColumn = tabColumn
	window.Content = content
	window.Columns = { Left = leftColumn, Right = rightColumn }

	---------------------------------------------------------------- behaviour
	function window:SetVisible(value, animated)
		value = value == true
		if animated == false then
			frame.Visible = value
			glow.Visible = value
			return
		end

		if value then
			frame.Visible = true
			glow.Visible = true
			frame.Size = UDim2.fromOffset(Theme.Sizes.Window.X * 0.94, Theme.Sizes.Window.Y * 0.94)
			frame.BackgroundTransparency = 1
			Utility:Tween(frame, Theme:Info("Slow", Theme.Easing.Emphasized), {
				Size = UDim2.fromOffset(Theme.Sizes.Window.X, Theme.Sizes.Window.Y),
				BackgroundTransparency = 0,
			}, "open")
			Utility:Fade(frame, "In", Theme.Timing.Normal)
		else
			Utility:Tween(frame, Theme:Info("Normal", Theme.Easing.Emphasized), {
				Size = UDim2.fromOffset(Theme.Sizes.Window.X * 0.94, Theme.Sizes.Window.Y * 0.94),
				BackgroundTransparency = 1,
			}, "open").Completed:Connect(function()
				frame.Visible = false
				glow.Visible = false
				frame.BackgroundTransparency = 0
			end)
		end
	end

	function window:SetPosition(position)
		frame.Position = position
		glow.Position = UDim2.new(position.X.Scale, position.X.Offset, position.Y.Scale, position.Y.Offset)
	end

	function window:GetPosition()
		return frame.Position
	end

	-- Dragging closed the popups so dropdown panels never get stranded on-screen.
	Utility:MakeDraggable(frame, header, function(position)
		glow.Position = position
		if api.ClosePopups then api:ClosePopups() end
		if data.OnMoved then data.OnMoved(position) end
	end)
	-- Keep the glow glued to the window while dragging.
	frame:GetPropertyChangedSignal("Position"):Connect(function()
		glow.Position = frame.Position
	end)

	closeButton.MouseButton1Click:Connect(function()
		if data.OnClose then data.OnClose() end
	end)
	hideButton.MouseButton1Click:Connect(function()
		if data.OnHide then data.OnHide() end
	end)
	Utility:Press(closeButton, nil, { RippleColor = Theme.Colors.Danger })
	Utility:Press(hideButton)

	return window
end

return Objects
