--[==[
	TBV v4  ::  Library/Library.lua
	----------------------------------------------------------------------------
	The orchestrator: owns the ScreenGui, the tab/section/module registries, the
	module lifecycle, input handling, notifications and profile persistence.

	Nothing here draws a single frame - that is Objects.lua - and nothing here
	knows what any module does. Modules receive a sandboxed `ctx` and a
	`module` handle, so features stay editable in isolation.

	Module definition format (see Modules/Templates/ModuleTemplate.lua):

		{
			Name        = "FPS Counter",   -- shown on the card, also the config key
			Tab         = "Utility",       -- tab the module lives on
			Section     = "HUD",           -- section inside the tab (default "Main")
			Side        = "Left",          -- column (default "Left")
			Description = "Shows live FPS",
			Default     = false,           -- enabled on first boot?
			Options     = function(module, ctx) ... end,  -- build options (once)
			OnEnable    = function(module, ctx) ... end,
			OnDisable   = function(module, ctx) ... end,
		}

	Lifecycle
		Register -> (option widgets built) -> Enable/Disable
		Every connection made through ctx:Connect / ctx:OnHeartbeat is stored on
		the module and disconnected on Disable, which is the difference between
		"toggle it off and the lag stops" and "toggle it off and the loop keeps
		running forever".
]==]

local import = ...
local Theme = import("Library/Theme")
local Utility = import("Library/Utility")
local Objects = import("Library/Objects")
local Config = import("Config/ConfigSystem")

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local Library = {}
Library.__index = Library

Library.Version = "4.0.0"
Library.Name = "TBV v4"

-- Populated below; Objects.lua looks widgets up by name in this table.
Library.OptionTypes = {
	Toggle = import("Library/Options/Toggle"),
	Slider = import("Library/Options/Slider"),
	Dropdown = import("Library/Options/Dropdown"),
	ColorPicker = import("Library/Options/ColorPicker"),
	TextBox = import("Library/Options/TextBox"),
	Button = import("Library/Options/Button"),
	Label = import("Library/Options/Label"),
}

--------------------------------------------------------------------------------
--  Construction
--------------------------------------------------------------------------------

local LocalPlayer = Players.LocalPlayer

--- Pick the best GUI container available in the current environment.
-- gethui (where provided) survives character respawns and avoids CoreGui
-- permission issues; CoreGui is the usual fallback, PlayerGui last.
local function resolveContainer()
	local candidates = {}

	-- gethui is only defined on some executors, so probe for it defensively
	-- instead of referencing the global directly.
	local hasGethui, gethuiFn = pcall(function() return gethui end)
	if hasGethui and typeof(gethuiFn) == "function" then
		table.insert(candidates, gethuiFn)
	end
	table.insert(candidates, function() return game:GetService("CoreGui") end)
	table.insert(candidates, function() return LocalPlayer:WaitForChild("PlayerGui") end)

	for _, attempt in ipairs(candidates) do
		local ok, container = pcall(attempt)
		if ok and container then return container end
	end

	error("[TBV v4] no GUI container available")
end

--- options: { Profile, AutoSave, GameScope, UIKey }
function Library.new(options)
	options = options or {}

	local self = setmetatable({}, Library)

	self.Profile = options.Profile or "Default"
	self.AutoSave = options.AutoSave ~= false
	self.UIKey = options.UIKey or Enum.KeyCode.RightShift
	self.Modules = {}      -- name -> module object
	self.ModuleOrder = {}  -- stable iteration order
	self.Tabs = {}         -- name -> tab object
	self.TabOrder = {}
	self.Visible = true
	self.PopupOpen = false
	self._Popups = {}         -- close callbacks registered by open popups
	self._Notifications = {}

	-- api is the table handed to every widget: it exposes the pieces widgets
	-- need without giving them the whole library surface.
	self.Theme = Theme
	self.Utility = Utility
	self.Config = Config

	------------------------------------------------------------ gui layers
	local container = resolveContainer()

	local screenGui = Utility:Create("ScreenGui", {
		Name = "TBVv4",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 1000,
		Parent = container,
	})
	self.ScreenGui = screenGui

	-- Overlay hosts popups so scroll frames can never clip them.
	self.Overlay = Utility:Create("Frame", {
		Name = "Overlay",
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		ZIndex = 60,
		Parent = screenGui,
	})

	self.NotificationHost = Utility:Create("Frame", {
		Name = "Notifications",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, 0),
		Size = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		ZIndex = 50,
		Parent = screenGui,
	})

	-- Line 1 of the watermark is the game name. It is resolved asynchronously
	-- (see _RefreshGameName) so boot never blocks on a web request.
	self._WatermarkLines = { "Place " .. tostring(game.PlaceId) }
	-- Shared HUD layer for modules that want to draw on screen (FPS counters,
	-- clocks, readouts). Keeping one layer means module drawings cannot fight
	-- over ZIndex or leak frames when a module is disabled.
	self.Hud = Utility:Create("Frame", {
		Name = "Hud",
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		ZIndex = 30,
		Parent = screenGui,
	})

	self.Watermark = Objects.NewWatermark(self, {
		Parent = screenGui,
		Lines = self._WatermarkLines,
	})
	self:_RefreshGameName()

	local window = Objects.NewWindow(self, {
		Parent = screenGui,
		Title = self.Name,
		OnSearch = function(text) self:ApplySearch(text) end,
		OnClose = function() self:SetVisible(false) end,
		OnHide = function() self:SetVisible(false) end,
		OnMoved = function(position) self:_QueueSaveSettings() end,
	})
	self.Window = window

	------------------------------------------------------------ input
	self:_BindInput()

	-- Start the shared spring/heartbeat scheduler.
	Utility:StartScheduler()

	-- Persist window position and global preferences.
	self:_LoadSettings()

	return self
end

--- Look up the place name in the background and patch watermark line 1.
-- GetProductInfo is a yielding web call - doing it inline would freeze the
-- loading screen for hundreds of milliseconds on a cold cache.
function Library:_RefreshGameName()
	task.spawn(function()
		local ok, info = pcall(function()
			return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
		end)
		if not ok or type(info) ~= "table" or type(info.Name) ~= "string" then return end

		if not self._WatermarkLines then return end
		self._WatermarkLines[1] = info.Name
		if self.Watermark then
			self.Watermark:SetLines(self._WatermarkLines)
		end
	end)
end

--------------------------------------------------------------------------------
--  Tabs & sections
--------------------------------------------------------------------------------

--- Get (or lazily create) a tab and its columns container.
function Library:GetTab(name)
	if self.Tabs[name] then return self.Tabs[name] end

	local tab = { Name = name, Sections = {}, Columns = {} }

	-- Each tab owns a columns frame inside the shared content scroller; only the
	-- active tab's frame is visible.
	local columns = Utility:Create("Frame", {
		Name = name .. "_Columns",
		Size = UDim2.new(1, -16, 0, 0),
		Position = UDim2.new(0, 8, 0, 8),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 12,
		Parent = self.Window.Content,
	})
	local layout = Utility:Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 10),
		Parent = columns,
	})

	tab.Frame = columns
	tab.Layout = layout
	tab.Columns = {
		Left = Utility:Create("Frame", {
			Name = "Left", Size = UDim2.new(0.5, -5, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
			ZIndex = 12, Parent = columns,
		}),
		Right = Utility:Create("Frame", {
			Name = "Right", Size = UDim2.new(0.5, -5, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
			ZIndex = 12, Parent = columns,
		}),
	}
	Utility:AddList(tab.Columns.Left, Enum.FillDirection.Vertical, 12)
	Utility:AddList(tab.Columns.Right, Enum.FillDirection.Vertical, 12)

	tab.Button = Objects.NewTab(self, {
		Name = name,
		Parent = self.Window.TabColumn,
		LayoutOrder = #self.TabOrder + 1,
		OnSelected = function() self:SelectTab(name) end,
	})

	self.Tabs[name] = tab
	self.TabOrder[#self.TabOrder + 1] = name

	if not self.ActiveTab then
		self:SelectTab(name)
	end

	return tab
end

--- Get (or lazily create) a section inside a tab column.
function Library:GetSection(tabName, sectionName, side)
	local tab = self:GetTab(tabName)
	local key = (side or "Left") .. "/" .. sectionName

	if tab.Sections[key] then return tab.Sections[key] end

	local section = Objects.NewSection(self, {
		Name = sectionName,
		Parent = tab.Columns[side or "Left"],
		LayoutOrder = #tab.Sections + 1,
	})

	tab.Sections[key] = section
	return section
end

function Library:SelectTab(name)
	if not self.Tabs[name] then return end
	self.ActiveTab = name

	for _, tabName in ipairs(self.TabOrder) do
		local tab = self.Tabs[tabName]
		tab.Frame.Visible = (tabName == name)
		tab.Button:SetSelected(tabName == name)
	end

	self:ClosePopups()
end

--------------------------------------------------------------------------------
--  Module registration
--------------------------------------------------------------------------------

--- Build the per-module context. Every connection created through it is tracked
-- so disabling the module tears everything down.
local function newContext(library, module)
	local ctx = {
		Library = library,
		Theme = Theme,
		Utility = Utility,
		Config = Config,
		LocalPlayer = LocalPlayer,
		Camera = workspace.CurrentCamera,
		Module = module,
		_Connections = {},
		_Tasks = {},
	}

	-- Lazy service accessor: ctx.Players, ctx.RunService, ...
	setmetatable(ctx, {
		__index = function(_, key)
			local ok, service = pcall(function() return game:GetService(key) end)
			if ok and service then
				ctx[key] = service -- memoise
				return service
			end
			return nil
		end,
	})

	--- Connect to a Roblox event; disconnected when the module is disabled.
	function ctx:Connect(signal, callback)
		local connection = signal:Connect(callback)
		ctx._Connections[#ctx._Connections + 1] = connection
		return connection
	end

	--- Register a throttled heartbeat callback (shared scheduler, one connection
	-- for the entire build). interval in seconds; nil/0 = every frame.
	function ctx:OnHeartbeat(callback, interval)
		local task = Utility:OnHeartbeat(callback, interval)
		ctx._Tasks[#ctx._Tasks + 1] = task
		return task
	end

	function ctx:OnRender(callback, interval)
		local task = Utility:OnRender(callback, interval)
		ctx._Tasks[#ctx._Tasks + 1] = task
		return task
	end

	--- Modern raycast wrapper (workspace:Raycast + cached RaycastParams).
	function ctx:Raycast(origin, direction, params)
		return Utility:Raycast(origin, direction, params)
	end

	function ctx:RaycastParams(filterDescendants, filterType, ignoreWater)
		return Utility.RaycastParams(filterDescendants, filterType, ignoreWater)
	end

	function ctx:Notify(title, text, duration)
		library:Notify(title, text, duration)
	end

	function ctx:DisconnectAll()
		for _, connection in ipairs(ctx._Connections) do
			pcall(function() connection:Disconnect() end)
		end
		for _, task in ipairs(ctx._Tasks) do
			pcall(function() task:Disconnect() end)
		end
		ctx._Connections = {}
		ctx._Tasks = {}
	end

	return ctx
end

--- Register a module definition and build its card + options.
function Library:RegisterModule(definition)
	if not definition or not definition.Name then
		warn("[TBV v4] RegisterModule called without a Name")
		return nil
	end
	if self.Modules[definition.Name] then
		warn("[TBV v4] duplicate module name: " .. definition.Name)
		return nil
	end

	local tab = self:GetTab(definition.Tab or "Main")
	local section = self:GetSection(definition.Tab or "Main", definition.Section or "Main", definition.Side or "Left")

	local module = {
		Name = definition.Name,
		Definition = definition,
		Enabled = false,
		Options = {},
		OptionsByFlag = {},
		Tab = tab,
		Section = section,
	}

	local ctx = newContext(self, module)
	module.Context = ctx

	-- The card is created disabled; after options are built we decide whether to
	-- enable it (from the profile, or the definition default).
	module.Card = section:AddCard({
		Name = definition.Name,
		Description = definition.Description,
		Default = false,
		OnToggle = function(value)
			module:SetEnabled(value)
		end,
	})

	---------------------------------------------------------------- public API
	function module:AddOption(kind, data)
		local option = self.Card:AddOption(kind, data)
		if option then
			self.Options[#self.Options + 1] = option
			if option.Flag then self.OptionsByFlag[option.Flag] = option end
		end
		return option
	end

	-- Shorthand builders so module authors rarely touch AddOption directly.
	function module:AddToggle(data) return self:AddOption("Toggle", data) end
	function module:AddSlider(data) return self:AddOption("Slider", data) end
	function module:AddDropdown(data) return self:AddOption("Dropdown", data) end
	function module:AddColorPicker(data) return self:AddOption("ColorPicker", data) end
	function module:AddTextBox(data) return self:AddOption("TextBox", data) end
	function module:AddButton(data) return self:AddOption("Button", data) end
	function module:AddLabel(data)
		return self:AddOption("Label", data)
	end

	function module:GetOption(flag)
		return self.OptionsByFlag[flag]
	end

	function module:SetStatus(text)
		self.Card:SetStatus(text)
	end

	function module:SetEnabled(value)
		value = value == true
		if self.Enabled == value then return end
		self.Enabled = value
		self.Card:SetEnabled(value, true) -- card -> module callback is skipped

		if value then
			if self.Definition.OnEnable then
				local ok, err = pcall(self.Definition.OnEnable, self, self.Context)
				if not ok then warn("[TBV v4] " .. self.Name .. " OnEnable error: " .. tostring(err)) end
			end
		else
			-- Order matters: stop callbacks first, then let the module clean up.
			self.Context:DisconnectAll()
			if self.Definition.OnDisable then
				local ok, err = pcall(self.Definition.OnDisable, self, self.Context)
				if not ok then warn("[TBV v4] " .. self.Name .. " OnDisable error: " .. tostring(err)) end
			end
		end

		self.Library:_QueueSaveProfile()
	end

	module.Library = self

	---------------------------------------------------------------- options
	if definition.Options then
		local ok, err = pcall(definition.Options, module, ctx)
		if not ok then warn("[TBV v4] " .. definition.Name .. " Options error: " .. tostring(err)) end
	end

	self.Modules[definition.Name] = module
	self.ModuleOrder[#self.ModuleOrder + 1] = definition.Name

	return module
end

--- Called by option widgets whenever a value changes: triggers the debounced
-- profile write.
function Library:OnOptionChanged(option)
	if option and option.Module then
		self:_QueueSaveProfile()
	end
end

--------------------------------------------------------------------------------
--  Search
--------------------------------------------------------------------------------

function Library:ApplySearch(text)
	text = (text or ""):lower()
	local searching = text ~= ""

	local perTab = {}
	for _, name in ipairs(self.ModuleOrder) do
		local module = self.Modules[name]
		local matches = (not searching) or (tostring(name):lower():find(text, 1, true) ~= nil)

		module.Card:SetVisible(matches)
		if matches then
			local tabName = module.Definition.Tab or "Main"
			perTab[tabName] = (perTab[tabName] or 0) + 1
		end

		-- Auto-expanding while searching is a nice touch: matches are instantly
		-- useful, no second click required.
		if searching and matches then
			module.Card:SetExpanded(true)
		end
	end

	-- Hide sections that ended up empty, and surface a tab with matches.
	for _, tabName in ipairs(self.TabOrder) do
		local tab = self.Tabs[tabName]
		for _, section in pairs(tab.Sections) do
			local any = false
			for _, card in ipairs(section.Cards) do
				if card.Frame.Visible then any = true break end
			end
			section:SetVisible(any)
		end
	end

	if searching then
		local bestName, bestCount = nil, 0
		for tabName, count in pairs(perTab) do
			if count > bestCount then bestName, bestCount = tabName, count end
		end
		if bestName and bestName ~= self.ActiveTab then
			self:SelectTab(bestName)
		end
	end
end

--------------------------------------------------------------------------------
--  Notifications / watermark / visibility
--------------------------------------------------------------------------------

function Library:Notify(title, text, duration)
	local offset = 8
	for i = 1, #self._Notifications do
		offset = offset + (self._Notifications[i].Height or 52) + 8
	end

	local notification = Objects.NewNotification(self, {
		Title = title or self.Name,
		Text = text or "",
		Duration = duration or 4,
		Parent = self.NotificationHost,
		OffsetBottom = offset,
	})

	local entry = { Frame = notification.Frame, Height = 52 }
	self._Notifications[#self._Notifications + 1] = entry

	-- Measure once laid out, then re-stack so tall notifications do not overlap.
	task.defer(function()
		if not entry.Frame.Parent then return end
		entry.Height = math.max(52, entry.Frame.AbsoluteSize.Y)
	end)

	task.delay(duration or 4, function()
		for i = #self._Notifications, 1, -1 do
			if self._Notifications[i] == entry then
				table.remove(self._Notifications, i)
				break
			end
		end
		self:_RestackNotifications()
	end)

	return notification
end

function Library:_RestackNotifications()
	local offset = 8
	for i = 1, #self._Notifications do
		local entry = self._Notifications[i]
		if entry.Frame and entry.Frame.Parent then
			Utility:Tween(entry.Frame, Theme:Info("Normal", Theme.Easing.Emphasized), {
				Position = UDim2.fromOffset(-8, -offset),
			}, "slide")
			offset = offset + (entry.Height or 52) + 8
		end
	end
end

--- Replace the watermark's text lines (line 1 is conventionally the game name).
function Library:SetWatermarkLines(lines)
	self._WatermarkLines = lines or {}
	self.Watermark:SetLines(self._WatermarkLines)
end

function Library:SetWatermarkVisible(value)
	self.Watermark.Frame.Visible = value == true
end

--- Show/hide the window. animated=false is used during boot so the window does
-- not play its open animation underneath the loading screen.
function Library:SetVisible(value, animated)
	self.Visible = value == true
	self.Window:SetVisible(self.Visible, animated)
	if not self.Visible then self:ClosePopups() end
end

function Library:ToggleVisible()
	self:SetVisible(not self.Visible)
end

--- Widgets register their close handler here so "dismiss everything" is a
-- single call. Hiding the overlay children directly would leave each widget
-- thinking it was still open, and its next click would close instead of open.
function Library:RegisterPopup(closeCallback)
	self._Popups[#self._Popups + 1] = closeCallback
	self.PopupOpen = true
end

function Library:UnregisterPopup(closeCallback)
	for index = #self._Popups, 1, -1 do
		if self._Popups[index] == closeCallback then
			table.remove(self._Popups, index)
			break
		end
	end
	self.PopupOpen = #self._Popups > 0
end

function Library:ClosePopups()
	-- Iterate backwards: each close() unregisters itself.
	for index = #self._Popups, 1, -1 do
		pcall(self._Popups[index])
	end
	self.PopupOpen = false
end

--------------------------------------------------------------------------------
--  Input
--------------------------------------------------------------------------------

function Library:_BindInput()
	self._InputConnection = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

		-- Never swallow keys while the user is typing.
		if UserInputService:GetFocusedTextBox() then return end

		if input.KeyCode == self.UIKey then
			self:ToggleVisible()
			return
		end

		-- Module keybinds.
		for _, name in ipairs(self.ModuleOrder) do
			local module = self.Modules[name]
			for _, option in ipairs(module.Options) do
				if option.Type == "Toggle" and option.Bind == input.KeyCode then
					option:SetValue(not option.Value)
				end
			end
		end
	end)
end

--------------------------------------------------------------------------------
--  Persistence
--------------------------------------------------------------------------------

--- Serialise everything the profile should remember.
function Library:Serialize()
	local data = {
		Version = 1,
		Build = self.Name,
		Profile = self.Profile,
		Modules = {},
	}

	for _, name in ipairs(self.ModuleOrder) do
		local module = self.Modules[name]
		local options, binds = {}, {}

		for _, option in ipairs(module.Options) do
			local widget = Library.OptionTypes[option.Type]
			if widget and widget.Serialize then
				local value = widget.Serialize(option)
				if value ~= nil then
					options[option.Flag] = value
				end
			end
			if option.Type == "Toggle" and option.Bind then
				binds[option.Flag] = option.Bind.Name
			end
		end

		data.Modules[name] = {
			Enabled = module.Enabled,
			Options = options,
			Binds = binds,
		}
	end

	return data
end

--- Apply a profile. Unknown modules/flags are ignored so older profiles keep
-- working after modules are added or renamed.
function Library:Deserialize(data)
	if type(data) ~= "table" then return end
	local modules = data.Modules
	if type(modules) ~= "table" then return end

	for _, name in ipairs(self.ModuleOrder) do
		local module = self.Modules[name]
		local saved = modules[name]
		if type(saved) == "table" then
			if type(saved.Options) == "table" then
				for _, option in ipairs(module.Options) do
					local widget = Library.OptionTypes[option.Type]
					local raw = saved.Options[option.Flag]
					if widget and widget.Deserialize and raw ~= nil then
						pcall(widget.Deserialize, option, raw)
					end
				end
			end

			if type(saved.Binds) == "table" then
				for _, option in ipairs(module.Options) do
					local keyName = saved.Binds[option.Flag]
					if option.Type == "Toggle" and type(keyName) == "string" and Enum.KeyCode[keyName] then
						if option.SetBind then option:SetBind(Enum.KeyCode[keyName]) end
					end
				end
			end

			if saved.Enabled == true then
				-- Enabled last: options must exist before the module starts.
				module:SetEnabled(true)
			end
		end
	end
end

--- Enable every module whose definition sets Default = true.
-- Called on first boot (no saved profile yet); when a profile exists,
-- Deserialize() decides what is enabled instead.
function Library:ApplyDefaults()
	for _, name in ipairs(self.ModuleOrder) do
		local module = self.Modules[name]
		if module.Definition.Default == true and not module.Enabled then
			module:SetEnabled(true)
		end
	end
end

function Library:_QueueSaveProfile()
	if not self.AutoSave then return end
	Config:QueueSave(self.Profile, function()
		return self:Serialize()
	end)
end

function Library:_QueueSaveSettings()
	if not self.AutoSave then return end
	Config:QueueSaveSettings("ui", function()
		return self:SerializeSettings()
	end)
end

function Library:SerializeSettings()
	local position = self.Window:GetPosition()
	return {
		Version = 1,
		Visible = self.Visible,
		Watermark = self.Watermark.Frame.Visible,
		Position = { X = position.X.Offset, Y = position.Y.Offset, XScale = position.X.Scale, YScale = position.Y.Scale },
		Profile = self.Profile,
		AccentFrom = Theme.Hex.AccentFrom,
		AccentTo = Theme.Hex.AccentTo,
	}
end

function Library:_LoadSettings()
	local settings = Config:LoadSettings("ui")
	if type(settings) ~= "table" then return end

	if type(settings.Position) == "table" and settings.Position.X then
		self.Window:SetPosition(UDim2.new(
			settings.Position.XScale or 0.5, settings.Position.X or 0,
			settings.Position.YScale or 0.5, settings.Position.Y or 0
		))
	end
	if type(settings.Watermark) == "boolean" then
		self:SetWatermarkVisible(settings.Watermark)
	end
	if type(settings.AccentFrom) == "string" and type(settings.AccentTo) == "string" then
		Theme:SetAccent(settings.AccentFrom, settings.AccentTo)
	end
end

--------------------------------------------------------------------------------
--  Profiles
--------------------------------------------------------------------------------

function Library:ListProfiles()
	local names = Config:List()
	if #names == 0 then names = { "Default" } end
	return names
end

function Library:SaveProfile(name)
	self.Profile = name or self.Profile
	local ok = Config:Save(self.Profile, self:Serialize())
	if ok then
		self:Notify(self.Name, "Saved profile \"" .. self.Profile .. "\"", 3)
	else
		self:Notify(self.Name, "Failed to save profile", 4)
	end
	return ok
end

function Library:LoadProfile(name)
	self.Profile = name or self.Profile
	local data = Config:Load(self.Profile)
	if not data then
		self:Notify(self.Name, "Profile \"" .. self.Profile .. "\" not found", 3)
		return false
	end
	self:Deserialize(data)
	self:Notify(self.Name, "Loaded profile \"" .. self.Profile .. "\"", 3)
	return true
end

function Library:DeleteProfile(name)
	local ok = Config:Delete(name)
	if self.Profile == name then self.Profile = "Default" end
	return ok
end

--------------------------------------------------------------------------------
--  Teardown
--------------------------------------------------------------------------------

function Library:Destroy()
	Config:Flush()
	for _, name in ipairs(self.ModuleOrder) do
		local module = self.Modules[name]
		if module.Enabled then module:SetEnabled(false) end
	end
	if self._InputConnection then
		self._InputConnection:Disconnect()
		self._InputConnection = nil
	end
	Utility:StopScheduler()
	self.ScreenGui:Destroy()
end

return Library
