--[==[
	TBV v4  ::  Library/Options/Dropdown.lua
	----------------------------------------------------------------------------
	Single- and multi-select dropdown.

	Why popups live in Library.Overlay instead of inside the row:
	  A dropdown inside a scrolling list gets clipped by the scroll frame and
	  renders underneath later siblings (Roblox ZIndex does not inherit through
	  containers). Parenting to a screen-level overlay frame sidesteps both
	  problems, and because the overlay sits at (0,0) with the screen's size we
	  can position popups with plain screen coordinates.

	Animation: the panel grows from 0 height with an Exponential tween while
	fading in, and the chevron rotates 180 degrees over the same duration.

	Serialisation: string (single) or array of strings (multi).
]==]

local import = ...
local Theme = import("Library/Theme")
local Utility = import("Library/Utility")
local Row = import("Library/Options/Row")

local UserInputService = game:GetService("UserInputService")

local Dropdown = {}

local ITEM_H = 24
local MAX_VISIBLE = 7

-- Registry of every open panel so opening one closes the others, and so the
-- library can wipe them when the window is dragged or hidden.
local openPanels = {}

local function closeAllPanels()
	-- Iterate backwards: each Close() mutates the registry it is walking.
	for i = #openPanels, 1, -1 do
		local entry = openPanels[i]
		if entry and entry.Close then entry.Close() end
	end
end

-- One global "click outside -> close" listener, created lazily on first use.
local outsideListener = nil
local function ensureOutsideListener()
	if outsideListener then return end
	outsideListener = UserInputService.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then return end

		local point = UserInputService:GetMouseLocation()
		for i = #openPanels, 1, -1 do
			local entry = openPanels[i]
			local bounds = entry.Bounds and entry.Bounds()
			if bounds then
				local insidePanel = point.X >= bounds.X and point.X <= bounds.X + bounds.W
					and point.Y >= bounds.Y and point.Y <= bounds.Y + bounds.H
				if not insidePanel then
					entry.Close()
				end
			end
		end
	end)
end

function Dropdown.new(api, data)
	local row = Row.new(api, data)
	local choices = data.Options or {}
	local multi = data.Multi == true

	---------------------------------------------------------------- button
	local button = Utility:Create("TextButton", {
		Name = "DropdownButton",
		Size = UDim2.new(1, -2, 0, 22),
		Position = UDim2.new(0, 1, 0.5, -11),
		BackgroundColor3 = Theme.Colors.Background,
		AutoButtonColor = false,
		Font = Theme.Fonts.Body,
		TextSize = Theme.TextSize.Small,
		TextColor3 = Theme.Colors.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row.Control,
	})
	Utility:AddPadding(button, 0)
	Utility:AddCorner(button, Theme.Sizes.CornerSm)
	Utility:AddStroke(button, Theme.Colors.Outline, 1)
	Utility:Create("UIPadding", {
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 20),
		Parent = button,
	})

	local chevron = Utility:Create("TextLabel", {
		Name = "Chevron",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(12, 12),
		BackgroundTransparency = 1,
		Font = Theme.Fonts.Title,
		TextSize = Theme.TextSize.Small,
		TextColor3 = Theme.Colors.TextDim,
		Text = "v",
		Parent = button,
	})

	---------------------------------------------------------------- state
	local option = {
		Type = "Dropdown",
		Name = data.Name,
		Flag = data.Flag or data.Name,
		Frame = row.Frame,
		Multi = multi,
		Options = choices,
		Value = multi and (data.Default or {}) or data.Default,
		Callback = data.Callback,
	}

	if multi and type(option.Value) ~= "table" then option.Value = {} end
	if not multi and option.Value == nil then option.Value = choices[1] end

	local panel = nil
	local panelEntry = nil -- our handle inside the shared openPanels registry
	local isOpen = false

	-- Registered with the library so window drags, tab switches and module
	-- header clicks can dismiss this panel properly.
	local popupCloser = function() option:Close() end

	--- Rebuild the button label from the current value.
	function option:Render()
		if self.Multi then
			local parts = {}
			for i = 1, #self.Value do
				parts[#parts + 1] = tostring(self.Value[i])
			end
			if #parts == 0 then
				button.Text = "None"
				button.TextColor3 = Theme.Colors.TextDim
			else
				button.Text = table.concat(parts, ", ")
				button.TextColor3 = Theme.Colors.Text
			end
		else
			button.Text = tostring(self.Value or "None")
			button.TextColor3 = self.Value and Theme.Colors.Text or Theme.Colors.TextDim
		end
	end

	function option:SetValue(value, skipCallback)
		self.Value = value
		self:Render()
		if not skipCallback then
			if self.Callback then
				if self.Multi then self.Callback(self.Value) else self.Callback(value) end
			end
			if api.OnOptionChanged then api.OnOptionChanged(self) end
		end
	end

	function option:GetValue()
		return self.Value
	end

	-- Replace the available choices at runtime (used by profile lists, etc).
	function option:SetOptions(newChoices)
		self.Options = newChoices or {}
		if not self.Multi then
			local stillValid = false
			for i = 1, #self.Options do
				if self.Options[i] == self.Value then stillValid = true break end
			end
			if not stillValid then self:SetValue(self.Options[1], true) end
		end
		if isOpen then self:Close() end
		self:Render()
	end

	function option:IsSelected(choice)
		if not self.Multi then return self.Value == choice end
		for i = 1, #self.Value do
			if self.Value[i] == choice then return true end
		end
		return false
	end

	---------------------------------------------------------------- popup
	local entries = {} -- choice -> check mark label

	local function buildPanel()
		if panel then return panel end

		local width = math.max(button.AbsoluteSize.X, 160)
		local height = math.min(#choices * ITEM_H + 8, MAX_VISIBLE * ITEM_H)

		panel = Utility:Create("Frame", {
			Name = "DropdownPanel",
			Size = UDim2.fromOffset(width, 0),
			BackgroundColor3 = Theme.Colors.Surface,
			ClipsDescendants = true,
			ZIndex = 60,
			Visible = false,
			Parent = api.Overlay,
		})
		Utility:AddCorner(panel, Theme.Sizes.Corner)
		Utility:AddStroke(panel, Theme.Colors.Outline, 1)

		local scroller = Utility:Create("ScrollingFrame", {
			Name = "List",
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = Theme.Colors.Violet,
			CanvasSize = UDim2.new(0, 0, 0, #choices * ITEM_H + 8),
			ZIndex = 61,
			Parent = panel,
		})
		Utility:AddList(scroller, Enum.FillDirection.Vertical, 2)
		Utility:Create("UIPadding", {
			PaddingTop = UDim.new(0, 4),
			PaddingBottom = UDim.new(0, 4),
			PaddingLeft = UDim.new(0, 4),
			PaddingRight = UDim.new(0, 4),
			Parent = scroller,
		})

		local function rebuild()
			for _, child in ipairs(scroller:GetChildren()) do
				if child:IsA("TextButton") then child:Destroy() end
			end
			entries = {}

			for index, choice in ipairs(choices) do
				local item = Utility:Create("TextButton", {
					Name = tostring(choice),
					Size = UDim2.new(1, -8, 0, ITEM_H),
					BackgroundColor3 = Theme.Colors.SurfaceAlt,
					BackgroundTransparency = 1,
					AutoButtonColor = false,
					Font = Theme.Fonts.Body,
					TextSize = Theme.TextSize.Small,
					TextColor3 = Theme.Colors.TextMuted,
					TextXAlignment = Enum.TextXAlignment.Left,
					Text = multi and "   " .. tostring(choice) or "   " .. tostring(choice),
					LayoutOrder = index,
					ZIndex = 62,
					Parent = scroller,
				})
				Utility:AddCorner(item, Theme.Sizes.CornerSm)

				local check = Utility:Create("TextLabel", {
					Size = UDim2.new(0, 14, 1, 0),
					Position = UDim2.new(0, 2, 0, 0),
					BackgroundTransparency = 1,
					Font = Theme.Fonts.Title,
					TextSize = Theme.TextSize.Small,
					TextColor3 = Theme.Colors.AccentTo,
					Text = "",
					ZIndex = 63,
					Parent = item,
				})
				entries[choice] = check

				Utility:Hover(item, { HoverColor = Theme.Colors.SurfaceAlt, Speed = "Instant" })

				item.MouseButton1Click:Connect(function()
					if option.Multi then
						local next = {}
						for i = 1, #option.Value do
							if option.Value[i] ~= choice then
								next[#next + 1] = option.Value[i]
							end
						end
						if #next == #option.Value then
							next[#next + 1] = choice
						end
						option:SetValue(next)
					else
						option:SetValue(choice)
						option:Close()
					end
					option:RenderPanel()
				end)
			end

			scroller.CanvasSize = UDim2.new(0, 0, 0, #choices * ITEM_H + 8)
		end

		function option:RenderPanel()
			for choice, check in pairs(entries) do
				check.Text = option:IsSelected(choice) and "*" or ""
				check.TextColor3 = option:IsSelected(choice) and Theme.Colors.AccentTo or Theme.Colors.TextDim
			end
		end

		rebuild()
		option._Rebuild = rebuild
		return panel
	end

	function option:Open()
		if isOpen then return end
		closeAllPanels()
		ensureOutsideListener()

		local popup = buildPanel()
		if self._Rebuild then self._Rebuild() end
		self:RenderPanel()

		-- Anchor under the button; flip above if it would run off-screen.
		local screen = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
		local height = math.min(#choices * ITEM_H + 8, MAX_VISIBLE * ITEM_H)
		local x = button.AbsolutePosition.X
		local y = button.AbsolutePosition.Y + button.AbsoluteSize.Y + 4
		if y + height > screen.Y then
			y = math.max(4, button.AbsolutePosition.Y - height - 4)
		end

		popup.Position = UDim2.fromOffset(x, y)
		popup.Size = UDim2.fromOffset(math.max(button.AbsoluteSize.X, 160), 0)
		popup.Visible = true

		isOpen = true

		-- Register with the shared "one popup at a time" registry. We keep a
		-- direct reference to this entry so Close() can remove it by identity
		-- instead of guessing from geometry.
		panelEntry = {
			Bounds = function()
				return {
					X = popup.AbsolutePosition.X, Y = popup.AbsolutePosition.Y,
					W = popup.AbsoluteSize.X, H = popup.AbsoluteSize.Y,
				}
			end,
			Close = function() option:Close() end,
		}
		openPanels[#openPanels + 1] = panelEntry
		api:RegisterPopup(popupCloser)

		Utility:Tween(popup, Theme:Info("Normal", Theme.Easing.Emphasized), {
			Size = UDim2.fromOffset(math.max(button.AbsoluteSize.X, 160), height),
		}, "size")
		Utility:Fade(popup, "In", Theme.Timing.Fast)
		Utility:Tween(chevron, Theme:Info("Normal"), { Rotation = 180 }, "rotation")
		Utility:Tween(button, Theme:Info("Fast"), { BackgroundColor3 = Theme.Colors.SurfaceAlt }, "color")
	end

	function option:Close()
		if not isOpen or not panel then return end
		isOpen = false

		api:UnregisterPopup(popupCloser)

		-- Drop our entry from the shared registry (identity match, not geometry).
		if panelEntry then
			for i = #openPanels, 1, -1 do
				if openPanels[i] == panelEntry then
					table.remove(openPanels, i)
					break
				end
			end
			panelEntry = nil
		end

		local popup = panel
		Utility:CancelTweens(popup)
		Utility:Tween(popup, Theme:Info("Fast", Theme.Easing.Emphasized), {
			Size = UDim2.fromOffset(popup.AbsoluteSize.X, 0),
		}, "size")
		Utility:Fade(popup, "Out", Theme.Timing.Fast, function()
			popup.Visible = false
		end)
		Utility:Tween(chevron, Theme:Info("Normal"), { Rotation = 0 }, "rotation")
		Utility:Tween(button, Theme:Info("Fast"), { BackgroundColor3 = Theme.Colors.Background }, "color")
	end

	Utility:Press(button, function()
		if isOpen then option:Close() else option:Open() end
	end)
	Utility:Hover(button, { Speed = "Instant" })

	option:Render()
	return option
end

function Dropdown.Serialize(option)
	return option.Value
end

function Dropdown.Deserialize(option, raw)
	if option.Multi then
		if type(raw) == "table" then
			-- Only keep values that still exist in the option list.
			local valid = {}
			for i = 1, #raw do
				for j = 1, #option.Options do
					if option.Options[j] == raw[i] then
						valid[#valid + 1] = raw[i]
						break
					end
				end
			end
			option:SetValue(valid, true)
		end
	elseif type(raw) == "string" then
		for i = 1, #option.Options do
			if option.Options[i] == raw then
				option:SetValue(raw, true)
				break
			end
		end
	end
end

return Dropdown
