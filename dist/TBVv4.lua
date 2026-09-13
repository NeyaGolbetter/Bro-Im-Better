--[==[
	TBV v4  ::  build 0637197
	----------------------------------------------------------------------------
	GENERATED FILE - edit src/TBVv4/** instead, then run: python3 tools/build.py

	Modules are inlined in dependency order and resolved through the local
	import() shim below (no global state, no external requires).

	Included modules (22):
	  - Config/ConfigSystem
	  - Library/Theme
	  - Library/Utility
	  - Library/Objects
	  - Library/Options/Row
	  - Library/Options/Button
	  - Library/Options/ColorPicker
	  - Library/Options/Dropdown
	  - Library/Options/Label
	  - Library/Options/Slider
	  - Library/Options/TextBox
	  - Library/Options/Toggle
	  - Library/Library
	  - Loading/LoadingScreen
	  - Modules/Utility/Clock
	  - Modules/Utility/FPSCounter
	  - Modules/Utility/Interface
	  - Modules/Utility/Profiles
	  - Modules/Utility/RaycastProbe
	  - Modules/Index
	  - Main
	  - Modules/Templates/ModuleTemplate
]==]

local TBV_MODULES = {}
local TBV_CACHE = {}
local TBV_LOADING = {}

local function TBV_REGISTER(name, chunk)
	TBV_MODULES[name] = chunk
end

--- Tiny module resolver with memoisation and cycle detection.
local function import(name)
	if TBV_CACHE[name] ~= nil then
		return TBV_CACHE[name]
	end

	local chunk = TBV_MODULES[name]
	if not chunk then
		error("[TBV v4] unknown module: " .. tostring(name), 2)
	end

	if TBV_LOADING[name] then
		error("[TBV v4] circular import detected: " .. tostring(name), 2)
	end

	TBV_LOADING[name] = true
	local ok, result = pcall(chunk, import)
	TBV_LOADING[name] = nil

	if not ok then
		error("[TBV v4] module " .. tostring(name) .. " failed to load: " .. tostring(result), 2)
	end

	TBV_CACHE[name] = result
	return result
end

--==========================================================================
--  Config/ConfigSystem
--==========================================================================
TBV_REGISTER("Config/ConfigSystem", function(...)
--[==[
	TBV v4  ::  Config/ConfigSystem.lua
	----------------------------------------------------------------------------
	Profile storage for TBV v4.

	Directory layout on disk (paths are explicitly branded, replacing the old
	`vape` folder):

		<workspace>/TBVv4/
			Settings/               global UI preferences (window position, accent)
			Configs/
				<PlaceId>/
					<Profile>.json  one file per profile, per game

	Executor compatibility
	----------------------
	Not every executor implements the file API, and some sandboxes it per game.
	Every filesystem call is therefore feature-detected once at startup:

		if isfolder and makefolder and writefile and readfile then -> real files
		else                                                       -> memory adapter

	The rest of the codebase calls the same API either way, so a missing
	writefile degrades to "settings last for this session" instead of throwing
	and breaking the whole UI.

	Performance
	-----------
	Writes are debounced (see :QueueSave). Dragging a slider fires dozens of
	change events per second; without a debounce we would hit the disk on every
	one of them, which is the single biggest source of stutter in naive builds.
]==]

local HttpService = game:GetService("HttpService")

local Config = {
	-- Branding: every path constant lives here so a rebrand is a one-line edit.
	Root = "TBVv4",
	SettingsFolder = "TBVv4/Settings",
	ConfigFolder = "TBVv4/Configs",

	-- Runtime state
	Available = false,
	Backend = "Memory",
	Scope = "0",
	AutoSave = true,
	Debounce = 1.5,

	_LastWrite = 0,
	_Pending = nil,
}

--------------------------------------------------------------------------------
--  Filesystem capability detection
--------------------------------------------------------------------------------

local fs = {
	isfolder = typeof(isfolder) == "function" and isfolder or nil,
	makefolder = typeof(makefolder) == "function" and makefolder or nil,
	isfile = typeof(isfile) == "function" and isfile or nil,
	writefile = typeof(writefile) == "function" and writefile or nil,
	readfile = typeof(readfile) == "function" and readfile or nil,
	listfiles = typeof(listfiles) == "function" and listfiles or nil,
	delfile = typeof(delfile) == "function" and delfile or nil,
}

local memory = {} -- fallback store: [path] = contents

local function folderExists(path)
	if fs.isfolder then return fs.isfolder(path) end
	return memory["__dir:" .. path] == true
end

local function fileExists(path)
	if fs.isfile then return fs.isfile(path) end
	return type(memory[path]) == "string"
end

local function makeFolder(path)
	if folderExists(path) then return true end
	if fs.makefolder then
		local ok = pcall(fs.makefolder, path)
		if ok then return true end
	end
	memory["__dir:" .. path] = true -- record intent for the memory backend
	return false
end

local function writeFile(path, contents)
	memory[path] = contents
	if fs.writefile then
		return pcall(fs.writefile, path, contents)
	end
	return false
end

local function readFile(path)
	if fs.readfile then
		local ok, data = pcall(fs.readfile, path)
		if ok and type(data) == "string" then return data end
	end
	return memory[path]
end

local function listFiles(path)
	if fs.listfiles then
		local ok, files = pcall(fs.listfiles, path)
		if ok and type(files) == "table" then return files end
	end
	local out = {}
	local prefix = path:gsub("/$", "") .. "/"
	for key in pairs(memory) do
		if key:sub(1, #prefix) == prefix and key:sub(1, 7) ~= "__dir:" then
			out[#out + 1] = key
		end
	end
	return out
end

local function deleteFile(path)
	memory[path] = nil
	if fs.delfile then return pcall(fs.delfile, path) end
	return true
end

--------------------------------------------------------------------------------
--  JSON (guarded - a malformed profile must never break the boot sequence)
--------------------------------------------------------------------------------

local function encode(data)
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(data)
	end)
	if not ok then
		warn("[TBV v4] JSONEncode failed: " .. tostring(encoded))
		return nil
	end
	return encoded
end

local function decode(raw)
	if type(raw) ~= "string" or raw == "" then return nil end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok then
		warn("[TBV v4] JSONDecode failed (profile may be corrupt): " .. tostring(decoded))
		return nil
	end
	if type(decoded) ~= "table" then return nil end
	return decoded
end

--------------------------------------------------------------------------------
--  Lifecycle
--------------------------------------------------------------------------------

--- Detect the file API and create the folder tree. Safe to call repeatedly.
function Config:Init()
	self.Available = (fs.isfolder ~= nil and fs.makefolder ~= nil
		and fs.writefile ~= nil and fs.readfile ~= nil)

	self.Backend = self.Available and "FileSystem" or "Memory"

	makeFolder(self.Root)
	makeFolder(self.SettingsFolder)
	makeFolder(self.ConfigFolder)

	if not self.Available then
		warn("[TBV v4] file API unavailable - profiles will not persist between sessions")
	end

	return self
end

--- Restrict profiles to a specific game. Pass a PlaceId (or any string).
function Config:SetScope(scope)
	scope = tostring(scope or "0")
	self.Scope = scope
	makeFolder(self.ConfigFolder .. "/" .. scope)
	return self
end

local function profilePath(name)
	return string.format("%s/%s/%s.json", Config.ConfigFolder, Config.Scope, tostring(name))
end

local function settingsPath(name)
	return string.format("%s/%s.json", Config.SettingsFolder, tostring(name))
end

--------------------------------------------------------------------------------
--  Profiles
--------------------------------------------------------------------------------

function Config:Save(profileName, data)
	local encoded = encode(data)
	if not encoded then return false end
	local ok = writeFile(profilePath(profileName), encoded)
	if not ok then
		warn("[TBV v4] failed to write profile: " .. tostring(profileName))
	end
	return ok
end

function Config:Load(profileName)
	if not fileExists(profilePath(profileName)) then return nil end
	return decode(readFile(profilePath(profileName)))
end

function Config:Exists(profileName)
	return fileExists(profilePath(profileName))
end

function Config:Delete(profileName)
	return deleteFile(profilePath(profileName))
end

--- List available profile names for the current scope, newest-agnostic but
-- alphabetically sorted so the dropdown order is stable between sessions.
function Config:List()
	local names = {}
	for _, path in ipairs(listFiles(self.ConfigFolder .. "/" .. self.Scope)) do
		local name = tostring(path):match("([^/\\]+)%.json$")
		if name then names[#names + 1] = name end
	end
	table.sort(names)
	return names
end

--------------------------------------------------------------------------------
--  Debounced saving
--------------------------------------------------------------------------------

--- Queue a save instead of writing immediately.
-- gather: function() -> table, invoked at write time so we always serialise the
-- freshest state rather than a snapshot taken when the change happened.
-- pathFn: optional custom path builder (used for global settings).
function Config:QueueSave(profileName, gather, pathFn)
	if not self.AutoSave then return end
	self._Pending = { name = profileName, gather = gather, pathFn = pathFn }

	-- Restart the debounce window on every new change.
	self._LastWrite = os.clock()
	if self._FlushTask then return end

	self._FlushTask = true
	task.spawn(function()
		while self._Pending do
			task.wait(0.25)
			if self._Pending and (os.clock() - self._LastWrite) >= self.Debounce then
				local pending = self._Pending
				self._Pending = nil
				local ok, data = pcall(pending.gather)
				if ok then
					if pending.pathFn then
						local encoded = encode(data)
						if encoded then writeFile(pending.pathFn(pending.name), encoded) end
					else
						self:Save(pending.name, data)
					end
				end
			end
		end
		self._FlushTask = nil
	end)
end

--- Write any queued changes immediately (called on shutdown / profile switch).
function Config:Flush()
	if not self._Pending then return end
	local pending = self._Pending
	self._Pending = nil
	local ok, data = pcall(pending.gather)
	if not ok then return end
	if pending.pathFn then
		local encoded = encode(data)
		if encoded then writeFile(pending.pathFn(pending.name), encoded) end
	else
		self:Save(pending.name, data)
	end
end

--------------------------------------------------------------------------------
--  Global settings (window position, theme, watermark toggles, ...)
--------------------------------------------------------------------------------

function Config:SaveSettings(name, data)
	local encoded = encode(data)
	if not encoded then return false end
	return writeFile(settingsPath(name), encoded)
end

--- Debounced write for global settings (same mechanism as profile saves, but
-- into TBVv4/Settings/ instead of the per-game profile folder).
function Config:QueueSaveSettings(name, gather)
	return self:QueueSave(name, gather, settingsPath)
end

function Config:LoadSettings(name)
	if not fileExists(settingsPath(name)) then return nil end
	return decode(readFile(settingsPath(name)))
end

function Config:DeleteSettings(name)
	return deleteFile(settingsPath(name))
end

--------------------------------------------------------------------------------
--  Diagnostics (surfaced in the Settings module so users can self-support)
--------------------------------------------------------------------------------

function Config:GetStatus()
	local capabilities = {}
	for key, value in pairs(fs) do
		capabilities[key] = value ~= nil
	end
	return {
		Backend = self.Backend,
		Root = self.Root,
		Scope = self.Scope,
		AutoSave = self.AutoSave,
		Functions = capabilities,
	}
end

return Config
end)

--==========================================================================
--  Library/Theme
--==========================================================================
TBV_REGISTER("Library/Theme", function(...)
--[==[
	TBV v4  ::  Library/Theme.lua
	----------------------------------------------------------------------------
	Single source of truth for every visual design token in TBV v4.

	Why a token file instead of hard-coded colours?
	  * Re-theming becomes a data change, not a search-and-replace across 20 files.
	  * Modules can read tokens (Theme.Colors.AccentFrom) instead of guessing.
	  * Runtime re-theming is possible: Theme:SetAccent() updates every gradient
	    that was registered through Utility.AddGradient(..., "Accent"), so a user
	    can recolour the whole UI live without rebuilding any frames.

	PALETTE (spec)
	  Background .. #120E16 / #18111D   dark slate-charcoal
	  Accent ...... #8A2BE2 -> #FF1493  deep purple -> neon pink gradient
	  Secondary ... #A020F0 / #FFB6C1   soft violet / light pink
	  Text ........ #FFFFFF / #E6E6FA   bright white / soft lavender

	This file has no dependencies (it is the root of the dependency graph):
		Theme -> (nothing)
		Utility -> Theme
		Options/* -> Utility + Theme
		Objects -> Utility + Theme + Options/*
		Library -> Utility + Theme + Objects + Config
]==]

local TweenService = game:GetService("TweenService")

local Theme = {}

--------------------------------------------------------------------------------
--  Colour tokens (hex strings are the canonical form; Color3 values are derived)
--------------------------------------------------------------------------------

Theme.Hex = {
	-- Surfaces, darkest -> lightest
	Shadow      = "#0A070C", -- drop shadow / scrim behind modals
	Background  = "#120E16", -- main window background
	Surface     = "#18111D", -- cards, sections, dropdown bodies
	SurfaceAlt  = "#1E1524", -- hovered / raised cards
	SurfaceTop  = "#221829", -- title bar, tab strip
	Outline     = "#2C2036", -- 1px strokes & dividers

	-- Brand accents (the gradient the whole build is recognised by)
	AccentFrom  = "#8A2BE2", -- Deep Purple
	AccentTo    = "#FF1493", -- Neon Pink
	Violet      = "#A020F0", -- Soft Violet (secondary fills)
	PinkLight   = "#FFB6C1", -- Light Pink (secondary text / highlights)

	-- Text
	Text        = "#FFFFFF", -- primary labels
	TextMuted   = "#E6E6FA", -- soft lavender, secondary text
	TextDim     = "#9C94AD", -- tertiary / placeholder text

	-- Semantic
	Success     = "#57F287",
	Warning     = "#FEE75C",
	Danger      = "#ED4245",
	Info        = "#A020F0",
}

--- "#RRGGBB" -> Color3. Written by hand (instead of Color3.fromHex) so the
-- library behaves identically on executors that ship an older Roblox client.
local function hexToColor3(hex)
	hex = tostring(hex):gsub("#", "")
	local r = tonumber(hex:sub(1, 2), 16) or 0
	local g = tonumber(hex:sub(3, 4), 16) or 0
	local b = tonumber(hex:sub(5, 6), 16) or 0
	return Color3.fromRGB(r, g, b)
end
Theme.FromHex = hexToColor3

-- Derived Color3 table. Modules should read Theme.Colors.* rather than re-parsing.
Theme.Colors = {}
for name, hex in pairs(Theme.Hex) do
	Theme.Colors[name] = hexToColor3(hex)
end

--------------------------------------------------------------------------------
--  Typography
--  Roblox's own font enums only - no external font assets to download, so the
--  UI never shows a fallback flash on slower connections.
--------------------------------------------------------------------------------

Theme.Fonts = {
	Header = Enum.Font.FredokaOne,  -- "TBV v4" logo / loading screen wordmark
	Title  = Enum.Font.GothamBold,  -- window title, module titles, tab names
	Body   = Enum.Font.GothamMedium,-- option labels, buttons
	Sub    = Enum.Font.Gotham,      -- hints, small captions
	Mono   = Enum.Font.Code,        -- numbers, key names, hex values
}

Theme.TextSize = {
	Logo   = 26,
	Title  = 15,
	Body   = 13,
	Small  = 12,
	Micro  = 11,
}

--------------------------------------------------------------------------------
--  Motion
--  Quart = snappy, "physical" UI movement (menu toggles, dropdowns).
--  Exponential = the emphasised curve used for the big moves (window open,
--  loading-screen fade) where we want a fast start and a long, soft settle.
--------------------------------------------------------------------------------

Theme.Easing = {
	Standard   = Enum.EasingStyle.Quart,
	Emphasized = Enum.EasingStyle.Exponential,
	Linear     = Enum.EasingStyle.Linear,
	Back       = Enum.EasingStyle.Back,   -- tiny overshoot on press feedback
}

Theme.Direction = {
	In    = Enum.EasingDirection.In,
	Out   = Enum.EasingDirection.Out,
	InOut = Enum.EasingDirection.InOut,
}

-- Global speed multiplier. 1 = default; 0.5 = twice as fast; 0 disables
-- animation entirely (useful on low-end hardware). Applied inside Theme:Info,
-- so every tween in the build respects it without extra plumbing.
Theme.Speed = 1

Theme.Timing = {
	Instant = 0.10, -- press feedback
	Fast    = 0.18, -- hover, colour swaps
	Normal  = 0.32, -- dropdowns, expand/collapse
	Slow    = 0.55, -- window open, loading fade, notifications
}

--- Convenience: Theme:Info("Normal" | 0.4, style?, direction?) -> TweenInfo
-- Keeping every duration on a named scale means the whole interface shares one
-- rhythm instead of each widget inventing its own timing.
function Theme:Info(speed, style, direction)
	local duration = type(speed) == "number" and speed or (Theme.Timing[speed] or Theme.Timing.Normal)
	duration = duration * (Theme.Speed or 1)
	return TweenInfo.new(
		duration,
		style or Theme.Easing.Standard,
		direction or Theme.Direction.Out
	)
end

--------------------------------------------------------------------------------
--  Geometry
--------------------------------------------------------------------------------

Theme.Sizes = {
	Window     = Vector2.new(720, 500),
	TabColumn  = 132,
	Header     = 46,
	ModuleHead = 34,
	Option     = 30,
	Corner     = 8,
	CornerSm   = 6,
	Stroke     = 1,
}

--------------------------------------------------------------------------------
--  Gradients
--  Returned as ColorSequences so they can be dropped straight onto UIGradient.
--------------------------------------------------------------------------------

function Theme:AccentSequence()
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, Theme.Colors.AccentFrom),
		ColorSequenceKeypoint.new(1, Theme.Colors.AccentTo),
	})
end

-- Dimmer variant used for unselected/hover states so accent colours do not
-- scream at full saturation everywhere.
function Theme:AccentSequenceDim(alphaFrom, alphaTo)
	alphaFrom = alphaFrom or 0.65
	alphaTo = alphaTo or 0.65
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, Theme.Colors.AccentFrom:Lerp(Theme.Colors.Background, 1 - alphaFrom)),
		ColorSequenceKeypoint.new(1, Theme.Colors.AccentTo:Lerp(Theme.Colors.Background, 1 - alphaTo)),
	})
end

-- Vertical surface sheen: a barely-there light-to-dark used on cards so flat
-- panels still read as physical surfaces.
function Theme:SurfaceSequence()
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, Theme.Colors.SurfaceAlt),
		ColorSequenceKeypoint.new(1, Theme.Colors.Surface),
	})
end

--------------------------------------------------------------------------------
--  Runtime re-theming
--  Tiny dependency-free signal: no BindableEvent, so it works even if the
--  executor sandboxes Instance creation limits.
--------------------------------------------------------------------------------

local listeners = {}

function Theme:OnAccentChanged(callback)
	table.insert(listeners, callback)
	return function()
		for i = #listeners, 1, -1 do
			if listeners[i] == callback then
				table.remove(listeners, i)
				break
			end
		end
	end
end

--- Recolour the whole UI at runtime. Every object created through
-- Utility.AddGradient(..., "Accent") is updated automatically.
function Theme:SetAccent(from, to)
	if typeof(from) == "string" then from = hexToColor3(from) end
	if typeof(to) == "string" then to = hexToColor3(to) end

	Theme.Hex.AccentFrom = "#" .. from:ToHex()
	Theme.Hex.AccentTo = "#" .. to:ToHex()
	Theme.Colors.AccentFrom = from
	Theme.Colors.AccentTo = to

	for i = 1, #listeners do
		task.spawn(listeners[i], from, to)
	end
end

-- Restore the shipped brand gradient.
function Theme:ResetAccent()
	Theme:SetAccent(hexToColor3("#8A2BE2"), hexToColor3("#FF1493"))
end

return Theme
end)

--==========================================================================
--  Library/Utility
--==========================================================================
TBV_REGISTER("Library/Utility", function(...)
--[==[
	TBV v4  ::  Library/Utility.lua
	----------------------------------------------------------------------------
	Low level helpers shared by every widget in TBV v4.

	Design goals (these are the "performance" half of the rewrite):
	  1. ONE Heartbeat connection for the entire build.
		 Every animated number (springs) and every background task (module
		 callbacks) is stepped from a single scheduler instead of each module
		 calling RunService.Heartbeat:Connect() itself. 20 modules used to mean
		 20 connections + 20 closure allocations per frame; now it means one
		 loop over an array.
	  2. Tagged tweens. Utility:Tween(obj, info, props, "size") cancels the
		 previous tween with the same tag, which stops the classic Roblox bug
		 where rapid hover in/out leaves a dozen tweens fighting over one
		 property (visible as jitter, and it burns CPU).
	  3. No per-frame Instance.new. Ripples are the only transient instances and
		 they are destroyed on completion.

	Dependency: Utility -> Theme
]==]

local import = ...
local Theme = import("Library/Theme")

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Utility = {}

--------------------------------------------------------------------------------
--  Instance construction
--------------------------------------------------------------------------------

--- Create an Instance, apply a property table, then parent children.
-- Parent is applied LAST on purpose: setting properties before parenting avoids
-- the double layout/reflow cost Roblox pays when a child is moved into a
-- container that already has a UIListLayout.
function Utility:Create(className, props, children)
	local object = Instance.new(className)

	if props then
		for key, value in pairs(props) do
			if key ~= "Parent" then
				object[key] = value
			end
		end
	end

	if children then
		for i = 1, #children do
			children[i].Parent = object
		end
	end

	if props and props.Parent then
		object.Parent = props.Parent
	end

	return object
end

--------------------------------------------------------------------------------
--  Tweening
--------------------------------------------------------------------------------

local activeTweens = {} -- [instance][tag] = Tween

--- Play a tween, cancelling any previous tween on the same instance + tag.
-- tag: "size" | "position" | "color" | "transparency" | ...
function Utility:Tween(instance, tweenInfo, properties, tag)
	tag = tag or "default"

	local byTag = activeTweens[instance]
	if not byTag then
		byTag = {}
		activeTweens[instance] = byTag

		-- Leak guard: drop the bookkeeping when the instance goes away.
		instance.Destroying:Connect(function()
			activeTweens[instance] = nil
		end)
	end

	if byTag[tag] then
		pcall(function()
			byTag[tag]:Cancel()
		end)
	end

	local tween = TweenService:Create(instance, tweenInfo, properties)
	byTag[tag] = tween

	tween.Completed:Connect(function()
		local current = activeTweens[instance]
		if current and current[tag] == tween then
			current[tag] = nil
		end
	end)

	tween:Play()
	return tween
end

--- Cancel every tracked tween on an instance (used before destroying it).
function Utility:CancelTweens(instance)
	local byTag = activeTweens[instance]
	if not byTag then return end
	for _, tween in pairs(byTag) do
		pcall(function() tween:Cancel() end)
	end
	activeTweens[instance] = nil
end

--------------------------------------------------------------------------------
--  Springs
--  Analytic damped spring integrated with sub-steps so it stays stable even if
--  a frame takes 100ms (a single big Euler step would explode at k=180).
--------------------------------------------------------------------------------

local MAX_STEP = 1 / 120
local springs = {}   -- active springs (array, iterated in order)
local springSet = {} -- membership set for O(1) re-insert on :Set()

function Utility:Spring(initial, stiffness, damping, mass)
	local spring = {
		Value = initial or 0,
		Target = initial or 0,
		Velocity = 0,
		Stiffness = stiffness or 170,
		Damping = damping or 22,
		Mass = mass or 1,
	}

	function spring:Set(target, velocity)
		self.Target = target
		if velocity then self.Velocity = velocity end
		-- Re-activate: settled springs are removed from the step list to keep
		-- the scheduler loop short when the UI is idle.
		if not springSet[self] then
			springSet[self] = true
			springs[#springs + 1] = self
		end
		return self
	end

	function spring:Step(dt)
		local steps = math.max(1, math.ceil(dt / MAX_STEP))
		local h = dt / steps
		for _ = 1, steps do
			local force = -self.Stiffness * (self.Value - self.Target) - self.Damping * self.Velocity
			self.Velocity = self.Velocity + (force / self.Mass) * h
			self.Value = self.Value + self.Velocity * h
		end
	end

	function spring:IsSettled()
		return math.abs(self.Value - self.Target) < 0.001 and math.abs(self.Velocity) < 0.01
	end

	function spring:Destroy()
		springSet[self] = nil
		self.Destroyed = true
	end

	springSet[spring] = true
	springs[#springs + 1] = spring
	return spring
end

--------------------------------------------------------------------------------
--  Shared schedulers
--------------------------------------------------------------------------------

local heartbeatTasks = {} -- {callback, interval, accumulator, enabled}
local schedulerConnection = nil

--- Register a callback on a shared Heartbeat loop.
-- interval: seconds between calls (0 / nil = every frame). Throttling at the
-- scheduler level means a module asking for 10Hz costs one accumulator compare
-- per frame instead of a full callback + its own connection.
--- Remove dead tasks from an array in place (no allocation, O(n) once per
-- frame at worst). Disconnecting only flags the task, so a callback is free to
-- disconnect itself mid-iteration without corrupting the loop.
local function compact(tasks)
	local write = 0
	for read = 1, #tasks do
		local item = tasks[read]
		if item and not item._dead then
			write = write + 1
			tasks[write] = item
		end
	end
	for index = #tasks, write + 1, -1 do
		tasks[index] = nil
	end
end

function Utility:OnHeartbeat(callback, interval)
	local task = {
		callback = callback,
		interval = interval or 0,
		accumulator = 0,
		enabled = true,
	}

	-- O(1): the array is compacted by the scheduler instead.
	function task:Disconnect()
		self.enabled = false
		self._dead = true
	end

	heartbeatTasks[#heartbeatTasks + 1] = task
	return task
end

--- Same idea for per-render work (RunService.RenderStepped) - kept separate so
-- camera-relative code can stay on the render step while simulation stays on
-- Heartbeat.
local renderTasks = {}
local renderConnection = nil

function Utility:OnRender(callback, interval)
	local task = {
		callback = callback,
		interval = interval or 0,
		accumulator = 0,
		enabled = true,
	}
	function task:Disconnect()
		self.enabled = false
		self._dead = true
	end
	renderTasks[#renderTasks + 1] = task
	return task
end

-- Start the single connection that drives springs + all background tasks.
function Utility:StartScheduler()
	if schedulerConnection then return end

	schedulerConnection = RunService.Heartbeat:Connect(function(dt)
		-- 1. Springs. Compact the array in place (no allocation) as they settle.
		local write = 0
		for read = 1, #springs do
			local spring = springs[read]
			if spring.Destroyed then
				-- dropped
			elseif spring:IsSettled() then
				spring.Value = spring.Target
				spring.Velocity = 0
				springSet[spring] = nil
			else
				spring:Step(dt)
				write = write + 1
				springs[write] = spring
			end
		end
		for i = #springs, write + 1, -1 do
			springs[i] = nil
		end

		-- 2. Throttled heartbeat tasks. A callback may disconnect itself (and
		-- other tasks), so we check for dead entries rather than assuming the
		-- array is stable, then compact once at the end of the frame.
		for i = 1, #heartbeatTasks do
			local task = heartbeatTasks[i]
			if task and not task._dead and task.enabled then
				if task.interval > 0 then
					task.accumulator = task.accumulator + dt
					if task.accumulator >= task.interval then
						task.accumulator = task.accumulator % task.interval
						task.callback(task.accumulator)
					end
				else
					task.callback(dt)
				end
			end
		end
		compact(heartbeatTasks)
	end)

	if not renderConnection then
		renderConnection = RunService.RenderStepped:Connect(function(dt)
			for i = 1, #renderTasks do
				local task = renderTasks[i]
				if task and not task._dead and task.enabled then
					if task.interval > 0 then
						task.accumulator = task.accumulator + dt
						if task.accumulator >= task.interval then
							task.accumulator = task.accumulator % task.interval
							task.callback(task.accumulator)
						end
					else
						task.callback(dt)
					end
				end
			end
			compact(renderTasks)
		end)
	end
end

function Utility:StopScheduler()
	if schedulerConnection then
		schedulerConnection:Disconnect()
		schedulerConnection = nil
	end
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
end

--------------------------------------------------------------------------------
--  Fading
--  Roblox has no "fade this whole subtree" primitive, so we snapshot the base
--  transparency of every descendant once, then interpolate 0 -> 1 progress.
--------------------------------------------------------------------------------

local fadeBases = setmetatable({}, { __mode = "k" })

local FADE_PROPERTIES = {
	Frame = "BackgroundTransparency",
	TextLabel = "BackgroundTransparency",
	TextButton = "BackgroundTransparency",
	ImageLabel = "ImageTransparency",
	ImageButton = "ImageTransparency",
	ScrollingFrame = "BackgroundTransparency",
}

local function snapshot(instance)
	if fadeBases[instance] then return fadeBases[instance] end

	local entries = {}
	local candidates = { instance }
	for _, descendant in ipairs(instance:GetDescendants()) do
		candidates[#candidates + 1] = descendant
	end

	for _, object in ipairs(candidates) do
		local property = FADE_PROPERTIES[object.ClassName]
		if property then
			entries[#entries + 1] = { object = object, property = property, base = object[property] }
		end
		if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
			entries[#entries + 1] = { object = object, property = "TextTransparency", base = object.TextTransparency }
			if object.TextStrokeTransparency < 1 then
				entries[#entries + 1] = { object = object, property = "TextStrokeTransparency", base = object.TextStrokeTransparency }
			end
		end
		if object:IsA("UIStroke") then
			entries[#entries + 1] = { object = object, property = "Transparency", base = object.Transparency }
		end
	end

	fadeBases[instance] = entries
	return entries
end

--- Fade a subtree in or out.
-- mode: "In" | "Out".  duration: seconds.  onComplete: called when finished.
--
-- We tween a NumberValue proxy instead of each transparency property: one tween
-- drives N properties through a single Changed handler, which is far cheaper
-- than creating a tween per descendant (the usual naive approach).
function Utility:Fade(instance, mode, duration, onComplete)
	local entries = snapshot(instance)
	duration = duration or Theme.Timing.Normal

	local proxy = Instance.new("NumberValue")

	-- progress: 0 = fully hidden, 1 = fully visible.
	local function apply(progress)
		local hidden = 1 - progress
		for i = 1, #entries do
			local entry = entries[i]
			if entry.object.Parent then
				entry.object[entry.property] = math.min(1, entry.base + hidden)
			end
		end
	end

	if mode == "In" then
		instance.Visible = true
		proxy.Value = 0
	else
		proxy.Value = 1
	end
	apply(proxy.Value)

	local connection = proxy:GetPropertyChangedSignal("Value"):Connect(function()
		apply(proxy.Value)
	end)

	local tween = Utility:Tween(
		proxy,
		Theme:Info(duration, Theme.Easing.Emphasized),
		{ Value = (mode == "In") and 1 or 0 },
		"fade"
	)

	tween.Completed:Connect(function()
		connection:Disconnect()
		if mode == "Out" then
			instance.Visible = false
		end
		proxy:Destroy()
		if onComplete then onComplete() end
	end)

	return tween
end

--------------------------------------------------------------------------------
--  Decoration helpers
--------------------------------------------------------------------------------

local accentGradients = setmetatable({}, { __mode = "k" })

--- Attach a UIGradient.
-- tag "Accent" registers the gradient so Theme:SetAccent() can recolour it live.
function Utility:AddGradient(parent, colorSequence, rotation, tag)
	local gradient = Utility:Create("UIGradient", {
		Color = colorSequence,
		Rotation = rotation or 0,
		Parent = parent,
	})

	if tag == "Accent" then
		accentGradients[gradient] = true
		Theme:OnAccentChanged(function()
			Utility:Tween(gradient, Theme:Info("Normal"), { Color = Theme:AccentSequence() }, "color")
		end)
	end

	return gradient
end

function Utility:AddCorner(parent, radius)
	return Utility:Create("UICorner", {
		CornerRadius = UDim.new(0, radius or Theme.Sizes.Corner),
		Parent = parent,
	})
end

function Utility:AddStroke(parent, color, thickness, transparency)
	return Utility:Create("UIStroke", {
		Color = color or Theme.Colors.Outline,
		Thickness = thickness or Theme.Sizes.Stroke,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

function Utility:AddPadding(parent, all)
	return Utility:Create("UIPadding", {
		PaddingTop = UDim.new(0, all or 8),
		PaddingBottom = UDim.new(0, all or 8),
		PaddingLeft = UDim.new(0, all or 8),
		PaddingRight = UDim.new(0, all or 8),
		Parent = parent,
	})
end

--- Vertical or horizontal list layout with a gap.
function Utility:AddList(parent, direction, gap, horizontalAlignment)
	return Utility:Create("UIListLayout", {
		FillDirection = direction or Enum.FillDirection.Vertical,
		HorizontalAlignment = horizontalAlignment or Enum.HorizontalAlignment.Left,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, gap or 6),
		Parent = parent,
	})
end

--------------------------------------------------------------------------------
--  Interaction: hover, press, ripple, drag
--------------------------------------------------------------------------------

local hoverStates = setmetatable({}, { __mode = "k" })

--- Hover feedback. Tweens background colour and (optionally) scales the button.
-- Scale uses a saved base size so repeated hovers never compound.
function Utility:Hover(button, options)
	options = options or {}
	local baseSize = button.Size
	local baseColor = button.BackgroundColor3
	local hoverColor = options.HoverColor or Theme.Colors.SurfaceAlt
	local scale = options.Scale or 1.02
	local speed = options.Speed or "Fast"

	hoverStates[button] = { baseSize = baseSize, baseColor = baseColor }

	button.MouseEnter:Connect(function()
		local state = hoverStates[button]
		if not state then return end
		Utility:Tween(button, Theme:Info(speed), { BackgroundColor3 = hoverColor }, "color")
		if scale ~= 1 then
			Utility:Tween(button, Theme:Info(speed), {
				Size = UDim2.new(state.baseSize.X.Scale * scale, state.baseSize.X.Offset * scale,
					state.baseSize.Y.Scale * scale, state.baseSize.Y.Offset * scale),
			}, "size")
		end
	end)

	button.MouseLeave:Connect(function()
		local state = hoverStates[button]
		if not state then return end
		Utility:Tween(button, Theme:Info(speed), { BackgroundColor3 = state.baseColor }, "color")
		if scale ~= 1 then
			Utility:Tween(button, Theme:Info(speed), { Size = state.baseSize }, "size")
		end
	end)

	return button
end

--- Expanding circular ripple at a UDim2 position inside a clipping parent.
function Utility:Ripple(parent, position, color)
	if not parent.ClipsDescendants then
		-- Without clipping the circle would bleed over the whole UI.
		return
	end

	local diameter = math.max(parent.AbsoluteSize.X, parent.AbsoluteSize.Y) * 2.2
	local ripple = Utility:Create("Frame", {
		Name = "Ripple",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = position,
		Size = UDim2.fromOffset(0, 0),
		BackgroundColor3 = color or Theme.Colors.PinkLight,
		BackgroundTransparency = 0.55,
		ZIndex = (parent.ZIndex or 1) + 5,
	})
	Utility:AddCorner(ripple, math.ceil(diameter / 2))
	ripple.Parent = parent

	Utility:Tween(ripple, Theme:Info(0.45, Theme.Easing.Emphasized), {
		Size = UDim2.fromOffset(diameter, diameter),
		BackgroundTransparency = 1,
	}, "ripple").Completed:Connect(function()
		ripple:Destroy()
	end)
end

--- Press feedback: quick squash + ripple, then invoke the callback.
-- The callback fires immediately (input latency matters more than the 90ms of
-- animation), the animation is purely cosmetic.
function Utility:Press(button, callback, options)
	options = options or {}
	local squash = options.Squash or 0.96
	local baseSize = button.Size

	button.MouseButton1Down:Connect(function()
		local state = hoverStates[button]
		local size = state and state.baseSize or baseSize
		Utility:Tween(button, Theme:Info("Instant", Theme.Easing.Back), {
			Size = UDim2.new(size.X.Scale, size.X.Offset * squash, size.Y.Scale, size.Y.Offset * squash),
		}, "size")

		-- Ripple centred on the cursor.
		local mouse = UserInputService:GetMouseLocation()
		local absolute = button.AbsolutePosition
		Utility:Ripple(button, UDim2.fromOffset(mouse.X - absolute.X, mouse.Y - absolute.Y), options.RippleColor)
	end)

	button.MouseButton1Up:Connect(function()
		local state = hoverStates[button]
		Utility:Tween(button, Theme:Info("Fast", Theme.Easing.Back), {
			Size = state and state.baseSize or baseSize,
		}, "size")
	end)

	button.MouseButton1Click:Connect(function()
		if callback then callback() end
	end)

	button.MouseLeave:Connect(function()
		local state = hoverStates[button]
		if state then
			Utility:Tween(button, Theme:Info("Fast"), { Size = state.baseSize }, "size")
		end
	end)

	return button
end

--- Drag a GuiObject by a handle frame.
-- Uses InputChanged (not RenderStepped) so we only do work on actual movement,
-- and snaps back inside the viewport on release with a soft tween.
function Utility:MakeDraggable(gui, handle, onDragEnd)
	local dragging = false
	local startInput = nil
	local startPosition = nil

	local function update(input)
		local delta = input.Position - startInput.Position
		gui.Position = UDim2.new(
			startPosition.X.Scale, startPosition.X.Offset + delta.X,
			startPosition.Y.Scale, startPosition.Y.Offset + delta.Y
		)
	end

	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			startInput = input
			startPosition = gui.Position
			Utility:CancelTweens(gui)
		end
	end)

	handle.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			update(input)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			startInput = nil

			-- Clamp inside the screen so the UI can never be "lost".
			local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
			local x = math.clamp(gui.AbsolutePosition.X, 0, math.max(0, viewport.X - gui.AbsoluteSize.X))
			local y = math.clamp(gui.AbsolutePosition.Y, 0, math.max(0, viewport.Y - gui.AbsoluteSize.Y))
			Utility:Tween(gui, Theme:Info("Fast"), { Position = UDim2.fromOffset(x, y) }, "position")

			if onDragEnd then onDragEnd(gui.Position) end
		end
	end)
end

--------------------------------------------------------------------------------
--  Raycasting (modern API)
--  ------------------------------------------------------------------------
--  MIGRATION NOTES - the deprecated family vs. workspace:Raycast
--
--    workspace:FindPartOnRay(ray, ignore, ...)          -> workspace:Raycast(origin, dir, params)
--    workspace:FindPartOnRayWithIgnoreList(ray, list)   -> params.FilterDescendantsInstances = list
--    workspace:FindPartOnRayWithWhitelist(ray, list)    -> params.FilterType = Enum.RaycastFilterType.Whitelist
--    workspace:FindFirstChild / loops for ignore lists  -> params:AddToFilter(instance)
--    Ray.new(origin, dir)                               -> (origin, direction) as two args
--    part, point, normal, material = FindPartOnRay(...)  -> result.Instance / .Position / .Normal / .Material
--
--  Two practical wins:
--    * RaycastParams is built once and cached, so repeated casts do not rebuild
--      filter tables every frame (a real cost when casting 30x a second).
--    * RaycastResult is a single object: no more 4-return-value destructuring.
--------------------------------------------------------------------------------

local paramsCache = {}

--- Build (and cache) a RaycastParams object.
-- Cache key is the filter list + mode so callers can request the same params
-- every frame without allocating.
local function buildRaycastParams(filterDescendants, filterType, ignoreWater, collisionGroup)
	filterType = filterType or Enum.RaycastFilterType.Blacklist
	ignoreWater = ignoreWater == true

	local names = {}
	if filterDescendants then
		for i = 1, #filterDescendants do
			names[i] = tostring(filterDescendants[i])
		end
	end
	local key = table.concat(names, "|") .. "::" .. tostring(filterType) .. "::" .. tostring(ignoreWater) .. "::" .. tostring(collisionGroup)

	if paramsCache[key] then return paramsCache[key] end

	local params = RaycastParams.new()
	params.FilterType = filterType
	params.IgnoreWater = ignoreWater
	if filterDescendants then
		params.FilterDescendantsInstances = filterDescendants
	end
	if collisionGroup then
		params.CollisionGroup = collisionGroup
	end

	paramsCache[key] = params
	return params
end
Utility.RaycastParams = buildRaycastParams

--- Thin wrapper over workspace:Raycast so callers have one obvious place to
-- look, and so we can add instrumentation later without touching call sites.
function Utility:Raycast(origin, direction, params)
	return workspace:Raycast(origin, direction, params)
end

--- Convenience: cast from the current camera through a screen point.
function Utility:RaycastFromScreen(screenPoint, distance, params)
	local camera = workspace.CurrentCamera
	if not camera then return nil end
	local unit = camera:ScreenPointToRay(screenPoint.X, screenPoint.Y).Direction
	return workspace:Raycast(camera.CFrame.Position, unit * (distance or 500), params)
end

--------------------------------------------------------------------------------
--  Signals (dependency free; avoids spinning up BindableEvents)
--------------------------------------------------------------------------------

function Utility:Signal()
	local listeners = {}
	local signal = {}

	function signal:Connect(callback)
		listeners[#listeners + 1] = callback
		return {
			Disconnect = function()
				for i = #listeners, 1, -1 do
					if listeners[i] == callback then
						table.remove(listeners, i)
						break
					end
				end
			end,
		}
	end

	function signal:Fire(...)
		for i = 1, #listeners do
			local ok, err = pcall(listeners[i], ...)
			if not ok then
				warn("[TBV v4] signal listener error: " .. tostring(err))
			end
		end
	end

	function signal:Destroy()
		table.clear(listeners)
	end

	return signal
end

--------------------------------------------------------------------------------
--  Math / misc
--------------------------------------------------------------------------------

function Utility:Clamp(value, min, max)
	return math.clamp(value, min, max)
end

function Utility:Lerp(a, b, t)
	return a + (b - a) * t
end

function Utility:Map(value, inMin, inMax, outMin, outMax)
	return outMin + (value - inMin) * (outMax - outMin) / (inMax - inMin)
end

function Utility:Round(value, decimals)
	local factor = 10 ^ (decimals or 0)
	return math.floor(value * factor + 0.5) / factor
end

--- Cached service getter. game:GetService is not free when called in a loop.
local serviceCache = {}
function Utility:Service(name)
	if not serviceCache[name] then
		serviceCache[name] = game:GetService(name)
	end
	return serviceCache[name]
end

return Utility
end)

--==========================================================================
--  Library/Objects
--==========================================================================
TBV_REGISTER("Library/Objects", function(...)
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
end)

--==========================================================================
--  Library/Options/Row
--==========================================================================
TBV_REGISTER("Library/Options/Row", function(...)
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
end)

--==========================================================================
--  Library/Options/Button
--==========================================================================
TBV_REGISTER("Library/Options/Button", function(...)
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
end)

--==========================================================================
--  Library/Options/ColorPicker
--==========================================================================
TBV_REGISTER("Library/Options/ColorPicker", function(...)
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
end)

--==========================================================================
--  Library/Options/Dropdown
--==========================================================================
TBV_REGISTER("Library/Options/Dropdown", function(...)
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
end)

--==========================================================================
--  Library/Options/Label
--==========================================================================
TBV_REGISTER("Library/Options/Label", function(...)
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
end)

--==========================================================================
--  Library/Options/Slider
--==========================================================================
TBV_REGISTER("Library/Options/Slider", function(...)
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
end)

--==========================================================================
--  Library/Options/TextBox
--==========================================================================
TBV_REGISTER("Library/Options/TextBox", function(...)
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
end)

--==========================================================================
--  Library/Options/Toggle
--==========================================================================
TBV_REGISTER("Library/Options/Toggle", function(...)
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
end)

--==========================================================================
--  Library/Library
--==========================================================================
TBV_REGISTER("Library/Library", function(...)
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
end)

--==========================================================================
--  Loading/LoadingScreen
--==========================================================================
TBV_REGISTER("Loading/LoadingScreen", function(...)
--[==[
	TBV v4  ::  Loading/LoadingScreen.lua
	----------------------------------------------------------------------------
	Animated boot screen shown while the build initialises.

	What it does
	  * Glowing "TBV v4" wordmark (FredokaOne + UIStroke glow) with a purple ->
		pink gradient that slowly pulses by tweening UIGradient.Offset on a
		reversing, infinitely repeating Sine tween. Cheap: one tween, no
		per-frame Lua work.
	  * Rounded progress bar with a gradient fill, a moving "shine" highlight and
		live percentage text.
	  * Dynamic status line ("Initialising core...", "Registering modules...").
	  * Fades out with an Exponential tween and destroys itself, then calls
		onComplete.

	Usage
		local loading = LoadingScreen.new(api, screenGui)
		loading:Show()
		loading:RunSteps({
			{ Label = "Initialising core...",    Weight = 10, Run = function() ... end },
			{ Label = "Registering modules...",  Weight = 40, Run = function() ... end },
		}, function() print("done") end)

	Weights are relative, so a slow step can be given a bigger share of the bar
	and the progress readout stays honest.
]==]

local import = ...
local Theme = import("Library/Theme")
local Utility = import("Library/Utility")

local RunService = game:GetService("RunService")

local LoadingScreen = {}
LoadingScreen.__index = LoadingScreen

local BAR_W = 420
local BAR_H = 8

--- Step definitions can pass their own status strings here; the defaults below
-- are deliberately neutral - swap in whatever phrasing your build needs.
LoadingScreen.DefaultSteps = {
	"Initialising core...",
	"Loading theme...",
	"Registering modules...",
	"Restoring profile...",
	"Building interface...",
	"Finalising setup...",
}

function LoadingScreen.new(api, parent)
	local self = setmetatable({}, LoadingScreen)
	self.api = api
	self.Progress = 0
	self.Destroyed = false

	------------------------------------------------------------------ root
	local root = Utility:Create("Frame", {
		Name = "TBVv4_Loading",
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.new(0, 0, 0, 0),
		BackgroundColor3 = Theme.Colors.Background,
		BackgroundTransparency = 0, -- Fade() snapshots this as the "visible" base
		ZIndex = 100,
		Parent = parent,
	})
	self.Root = root

	-- Very subtle vertical wash so the flat background is not dead space.
	local wash = Utility:Create("Frame", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Theme.Colors.Surface,
		BackgroundTransparency = 0.65,
		ZIndex = 100,
		Parent = root,
	})
	Utility:Create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.Colors.SurfaceTop),
			ColorSequenceKeypoint.new(0.55, Theme.Colors.Background),
			ColorSequenceKeypoint.new(1, Theme.Colors.Background),
		}),
		Parent = wash,
	})

	------------------------------------------------------------------ logo
	local logo = Utility:Create("TextLabel", {
		Name = "Logo",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -46),
		Size = UDim2.new(0, 420, 0, 74),
		BackgroundTransparency = 1,
		Font = Theme.Fonts.Header,
		TextSize = 62,
		TextColor3 = Theme.Colors.Text,
		Text = "TBV v4",
		ZIndex = 102,
		Parent = root,
	})

	-- The pulsing gradient. Offset travels -0.35 -> 0.35 and reverses forever,
	-- which reads as the colour "breathing" across the letters.
	local logoGradient = Utility:Create("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0.00, Theme.Colors.AccentFrom),
			ColorSequenceKeypoint.new(0.35, Theme.Colors.Violet),
			ColorSequenceKeypoint.new(0.65, Theme.Colors.AccentTo),
			ColorSequenceKeypoint.new(1.00, Theme.Colors.AccentFrom),
		}),
		Offset = Vector2.new(-0.35, 0),
		Parent = logo,
	})

	Utility:Tween(logoGradient, TweenInfo.new(2.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true, 0), {
		Offset = Vector2.new(0.35, 0),
	}, "pulse")

	-- Glow: a thick, soft stroke behind the glyphs.
	Utility:Create("UIStroke", {
		Color = Theme.Colors.AccentTo,
		Thickness = 2,
		Transparency = 0.55,
		Parent = logo,
	})

	local tagline = Utility:Create("TextLabel", {
		Name = "Tagline",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -6),
		Size = UDim2.new(0, 420, 0, 18),
		BackgroundTransparency = 1,
		Font = Theme.Fonts.Sub,
		TextSize = Theme.TextSize.Small,
		TextColor3 = Theme.Colors.TextMuted,
		Text = "Loading your experience...",
		ZIndex = 102,
		Parent = root,
	})

	------------------------------------------------------------------ bar
	local track = Utility:Create("Frame", {
		Name = "Track",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 34),
		Size = UDim2.fromOffset(BAR_W, BAR_H),
		BackgroundColor3 = Theme.Colors.SurfaceTop,
		ClipsDescendants = true,
		ZIndex = 102,
		Parent = root,
	})
	Utility:AddCorner(track, BAR_H / 2)
	Utility:AddStroke(track, Theme.Colors.Outline, 1)

	local fill = Utility:Create("Frame", {
		Name = "Fill",
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = Theme.Colors.AccentFrom,
		ZIndex = 103,
		Parent = track,
	})
	Utility:AddCorner(fill, BAR_H / 2)
	Utility:AddGradient(fill, Theme:AccentSequence(), 0, "Accent")

	-- "Shine": a small bright segment that slides along the filled portion.
	local shine = Utility:Create("Frame", {
		Name = "Shine",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(0, 40, 0, BAR_H),
		BackgroundColor3 = Theme.Colors.PinkLight,
		BackgroundTransparency = 0.75,
		ZIndex = 104,
		Parent = track,
	})
	Utility:AddCorner(shine, BAR_H / 2)

	local percent = Utility:Create("TextLabel", {
		Name = "Percent",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0.5, BAR_W / 2 + 12, 0.5, 34),
		Size = UDim2.new(0, 48, 0, 18),
		BackgroundTransparency = 1,
		Font = Theme.Fonts.Mono,
		TextSize = Theme.TextSize.Small,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "0%",
		ZIndex = 103,
		Parent = root,
	})

	local status = Utility:Create("TextLabel", {
		Name = "Status",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 58),
		Size = UDim2.new(0, 420, 0, 16),
		BackgroundTransparency = 1,
		Font = Theme.Fonts.Body,
		TextSize = Theme.TextSize.Small,
		TextColor3 = Theme.Colors.TextDim,
		Text = "Initialising...",
		ZIndex = 102,
		Parent = root,
	})

	self.Logo = logo
	self.Fill = fill
	self.Shine = shine
	self.Percent = percent
	self.Status = status
	self.Track = track

	-- Shine loop: rides from 0 to 100% of the bar, forever, independent of the
	-- actual progress so the screen never looks frozen.
	Utility:Tween(shine, TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, false, 0), {
		Position = UDim2.new(1, 0, 0.5, 0),
	}, "shine")

	return self
end

--- Fade the loading screen in.
function LoadingScreen:Show()
	-- Fade() reads each object's current transparency as its "visible" base, so
	-- we must NOT pre-set the root to transparent here - doing so would make the
	-- screen fade in to fully invisible and stay there.
	Utility:Fade(self.Root, "In", Theme.Timing.Normal)
end

--- Update the bar. progress is 0..1; status is optional status text.
function LoadingScreen:SetProgress(progress, statusText)
	progress = math.clamp(tonumber(progress) or 0, 0, 1)
	self.Progress = progress

	-- Quart keeps the bar feeling responsive: it jumps towards the new value
	-- and then settles, instead of crawling linearly.
	Utility:Tween(self.Fill, Theme:Info(0.45, Theme.Easing.Standard), {
		Size = UDim2.new(progress, 0, 1, 0),
	}, "progress")

	-- Percentage counts in whole numbers only: fewer text re-layouts.
	self.Percent.Text = tostring(math.floor(progress * 100 + 0.5)) .. "%"

	if statusText then
		self.Status.Text = statusText
	end
end

function LoadingScreen:SetStatus(text)
	self.Status.Text = tostring(text or "")
end

--- Run an ordered list of steps, updating the bar as each one completes.
-- steps: { { Label = "...", Weight = 10, Run = function() end }, ... }
-- onComplete: called after the screen has faded out.
function LoadingScreen:RunSteps(steps, onComplete)
	local total = 0
	for i = 1, #steps do
		total = total + (steps[i].Weight or 1)
	end

	local done = 0
	for i = 1, #steps do
		local step = steps[i]

		self:SetProgress(total > 0 and (done / total) or 0, step.Label or "Working...")

		-- Yield two frames so the text/bar actually paint before the (possibly
		-- blocking) step runs. Without this the UI appears frozen during work.
		RunService.RenderStepped:Wait()
		RunService.RenderStepped:Wait()

		if step.Run then
			local ok, err = pcall(step.Run)
			if not ok then
				warn("[TBV v4] loading step failed (" .. tostring(step.Label) .. "): " .. tostring(err))
			end
		end

		done = done + (step.Weight or 1)
		self:SetProgress(total > 0 and (done / total) or 1)
	end

	self:SetProgress(1, "Finalising setup...")
	self:Finish(onComplete)
end

--- Snap to 100%, hold briefly so the finished state is readable, then fade out.
function LoadingScreen:Finish(onComplete)
	if self.Destroyed then return end
	self:SetProgress(1)

	task.wait(0.35)

	if self.Destroyed then return end
	self.Destroyed = true

	Utility:Fade(self.Root, "Out", Theme.Timing.Slow, function()
		self.Root:Destroy()
		if onComplete then onComplete() end
	end)
end

--- Immediate teardown (used when booting fails and we must not leave a
-- full-screen frame swallowing input).
function LoadingScreen:Destroy()
	if self.Destroyed then return end
	self.Destroyed = true
	Utility:CancelTweens(self.Root)
	self.Root:Destroy()
end

return LoadingScreen
end)

--==========================================================================
--  Modules/Utility/Clock
--==========================================================================
TBV_REGISTER("Modules/Utility/Clock", function(...)
--[==[
	TBV v4  ::  Modules/Utility/Clock.lua
	----------------------------------------------------------------------------
	Small on-screen clock. Demonstrates dropdown + colour picker + toggle options
	and a throttled heartbeat that only touches the label when the displayed
	string actually changes.
]==]

local module = {
	Name = "Clock",
	Tab = "Utility",
	Section = "Display",
	Side = "Left",
	Description = "On-screen local / server clock",
	Default = false,
}

function module:Options(ctx)
	self:AddDropdown({
		Name = "Source",
		Flag = "Source",
		Options = { "Local", "Server" },
		Default = "Local",
	})

	self:AddToggle({
		Name = "24 hour",
		Flag = "TwentyFour",
		Default = true,
	})

	self:AddToggle({
		Name = "Show seconds",
		Flag = "Seconds",
		Default = true,
	})

	self:AddSlider({
		Name = "Text size",
		Flag = "TextSize",
		Min = 10,
		Max = 32,
		Default = 14,
	})

	self:AddColorPicker({
		Name = "Text colour",
		Flag = "TextColor",
		Default = ctx.Theme.Colors.TextMuted,
	})
end

function module:OnEnable(ctx)
	local label = ctx.Utility:Create("TextLabel", {
		Name = "TBV_Clock",
		Position = UDim2.new(0, 14, 0, 86),
		Size = UDim2.fromOffset(180, 22),
		BackgroundTransparency = 1,
		Font = ctx.Theme.Fonts.Mono,
		TextSize = self:GetOption("TextSize").Value,
		TextColor3 = self:GetOption("TextColor").Value,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "--:--",
		ZIndex = 31,
		Parent = ctx.Library.Hud,
	})
	self._Label = label

	local function value(flag)
		local option = self:GetOption(flag)
		return option and option.Value
	end

	self:GetOption("TextSize").Callback = function(v) label.TextSize = v end
	self:GetOption("TextColor").Callback = function(v) label.TextColor3 = v end

	local lastText = nil

	-- 1Hz is plenty for a clock; without the interval this would run 60x/s.
	ctx:OnHeartbeat(function()
		local useServer = value("Source") == "Server"
		local timestamp

		if useServer then
			-- GetServerTimeNow returns seconds since Unix epoch, server-side.
			local ok, serverTime = pcall(function() return workspace:GetServerTimeNow() end)
			timestamp = (ok and type(serverTime) == "number") and serverTime or os.time()
		else
			timestamp = os.time()
		end

		local format
		if value("TwentyFour") then
			format = value("Seconds") and "%H:%M:%S" or "%H:%M"
		else
			format = value("Seconds") and "%I:%M:%S %p" or "%I:%M %p"
		end

		local text = os.date(format, timestamp)
		if text ~= lastText then
			lastText = text
			label.Text = text
		end
	end, 0.25)
end

function module:OnDisable(ctx)
	if self._Label then
		self._Label:Destroy()
		self._Label = nil
	end
end

return module
end)

--==========================================================================
--  Modules/Utility/FPSCounter
--==========================================================================
TBV_REGISTER("Modules/Utility/FPSCounter", function(...)
--[==[
	TBV v4  ::  Modules/Utility/FPSCounter.lua
	----------------------------------------------------------------------------
	Reference module. Shows a live FPS readout in the HUD layer.

	It exists to demonstrate the three things every TBV v4 module should do:

	  1. Build its options declaratively in Options() - no Instance.new here.
	  2. Do ALL background work through ctx:OnHeartbeat, which rides the shared
		 scheduler and is throttled to `interval` seconds. One module = zero new
		 connections to RunService.
	  3. Clean up after itself. Everything created in OnEnable is destroyed in
		 OnDisable, and every connection made via ctx:Connect / ctx:OnHeartbeat is
		 disconnected automatically.

	Performance detail worth copying: the text label is only updated when the
	rounded FPS value actually changes. Writing to TextLabel.Text forces a text
	re-layout, so doing it 60x a second for an unchanging "60" is pure waste.
]==]

local module = {
	Name = "FPS Counter",
	Tab = "Utility",
	Section = "Display",
	Side = "Left",
	Description = "Live frames-per-second readout",
	Default = false,
}

function module:Options(ctx)
	self:AddToggle({
		Name = "Show average",
		Flag = "ShowAverage",
		Default = false,
		Tooltip = "Average over the last second instead of instantaneous FPS",
	})

	self:AddSlider({
		Name = "Update rate",
		Flag = "UpdateRate",
		Min = 0.1,
		Max = 2,
		Default = 0.5,
		Decimals = 1,
		Suffix = "s",
	})

	self:AddSlider({
		Name = "Text size",
		Flag = "TextSize",
		Min = 10,
		Max = 32,
		Default = 16,
	})

	self:AddColorPicker({
		Name = "Text colour",
		Flag = "TextColor",
		Default = ctx.Theme.Colors.PinkLight,
	})

	self:AddLabel({
		Name = "FPS is sampled from the shared heartbeat scheduler, so this readout costs one extra accumulator check per frame.",
	})
end

function module:OnEnable(ctx)
	-- HUD element. Parented to the shared HUD layer, not to a new ScreenGui.
	local label = ctx.Utility:Create("TextLabel", {
		Name = "TBV_FPS",
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(0, 14, 0, 60),
		Size = UDim2.fromOffset(140, 22),
		BackgroundTransparency = 1,
		Font = ctx.Theme.Fonts.Mono,
		TextSize = self:GetOption("TextSize").Value,
		TextColor3 = self:GetOption("TextColor").Value,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "FPS: --",
		ZIndex = 31,
		Parent = ctx.Library.Hud,
	})
	self._Label = label

	local frames = 0
	local elapsed = 0
	local lastShown = nil

	-- Options are read through getters so live changes apply without a reboot.
	local function optionValue(flag)
		local option = self:GetOption(flag)
		return option and option.Value
	end

	self:GetOption("TextSize").Callback = function(value)
		label.TextSize = value
	end
	self:GetOption("TextColor").Callback = function(value)
		label.TextColor3 = value
	end

	-- Throttled: the interval comes from the slider and is read each tick.
	ctx:OnHeartbeat(function(dt)
		frames = frames + 1
		elapsed = elapsed + dt

		if elapsed < optionValue("UpdateRate") then return end

		local fps = math.floor(frames / elapsed + 0.5)
		frames = 0
		elapsed = 0

		-- Skip redundant text writes (text re-layout is not free).
		if fps ~= lastShown then
			lastShown = fps
			label.Text = string.format("FPS: %d", fps)
			-- Colour-code the readout: green > 50, amber > 30, red below.
			label.TextColor3 = fps >= 50 and ctx.Theme.Colors.Success
				or (fps >= 30 and ctx.Theme.Colors.Warning or ctx.Theme.Colors.Danger)
		end
	end, 0)

	label.Text = "FPS: --"
end

function module:OnDisable(ctx)
	-- ctx disconnects our heartbeat task; we only own the HUD label.
	if self._Label then
		self._Label:Destroy()
		self._Label = nil
	end
end

return module
end)

--==========================================================================
--  Modules/Utility/Interface
--==========================================================================
TBV_REGISTER("Modules/Utility/Interface", function(...)
--[==[
	TBV v4  ::  Modules/Utility/Interface.lua
	----------------------------------------------------------------------------
	Controls the UI itself: watermark, accent colours, animation speed, the key
	that hides the window, and a storage diagnostic readout.

	This module is also the reference for RUNTIME RE-THEMING. Calling
	Theme:SetAccent() repaints every gradient that was registered through
	Utility.AddGradient(..., "Accent") - no frame is rebuilt, no module is
	restarted. That is why the theme lives in a token file with a signal rather
	than being baked into each widget.
]==]

local module = {
	Name = "Interface",
	Tab = "Interface",
	Section = "Appearance",
	Side = "Left",
	Description = "Colours, watermark and motion",
	Default = true,
}

-- Candidate keys for the hide/show hotkey.
local UI_KEYS = { "RightShift", "LeftShift", "RightControl", "LeftAlt", "Insert", "Home", "F4" }

function module:Options(ctx)
	-- Global (non-profile) preferences live in TBVv4/Settings/ui.json, so each
	-- of these callbacks queues a settings write in addition to applying itself.
	local function queueSettings()
		ctx.Library:_QueueSaveSettings()
	end

	self:AddToggle({
		Name = "Show watermark",
		Flag = "Watermark",
		Default = true,
		Callback = function(value)
			ctx.Library:SetWatermarkVisible(value)
			queueSettings()
		end,
	})

	self:AddSlider({
		Name = "Animation speed",
		Flag = "AnimSpeed",
		Min = 0,
		Max = 2,
		Default = 1,
		Decimals = 2,
		Suffix = "x",
		Callback = function(value)
			-- 0 disables animation (instant UI) for low-end hardware.
			ctx.Theme.Speed = value
			queueSettings()
		end,
	})

	self:AddColorPicker({
		Name = "Accent (from)",
		Flag = "AccentFrom",
		Default = ctx.Theme.Colors.AccentFrom,
		Callback = function(value)
			ctx.Theme:SetAccent(value, self:GetOption("AccentTo").Value)
			queueSettings()
		end,
	})

	self:AddColorPicker({
		Name = "Accent (to)",
		Flag = "AccentTo",
		Default = ctx.Theme.Colors.AccentTo,
		Callback = function(value)
			ctx.Theme:SetAccent(self:GetOption("AccentFrom").Value, value)
			queueSettings()
		end,
	})

	self:AddButton({
		Name = "Reset accent",
		Callback = function()
			ctx.Theme:ResetAccent()
			self:GetOption("AccentFrom"):SetValue(ctx.Theme.Colors.AccentFrom, true)
			self:GetOption("AccentTo"):SetValue(ctx.Theme.Colors.AccentTo, true)
			queueSettings()
		end,
	})

	self:AddDropdown({
		Name = "UI key",
		Flag = "UIKey",
		Options = UI_KEYS,
		Default = "RightShift",
		Callback = function(value)
			if Enum.KeyCode[value] then
				ctx.Library.UIKey = Enum.KeyCode[value]
				queueSettings()
			end
		end,
	})

	self:AddToggle({
		Name = "Auto save profile",
		Flag = "AutoSave",
		Default = true,
		Callback = function(value)
			ctx.Library.AutoSave = value
			ctx.Config.AutoSave = value
		end,
	})

	self:AddButton({
		Name = "Test notification",
		Callback = function()
			ctx.Library:Notify("TBV v4", "Notifications are working.", 3)
		end,
	})

	-- Diagnostic label: tells the user whether their executor can persist files.
	self:AddLabel({ Name = "Storage: checking...", Flag = "StorageStatus" })
end

function module:OnEnable(ctx)
	local status = ctx.Config:GetStatus()
	local label = self:GetOption("StorageStatus")

	if label then
		label:SetText(string.format(
			"Storage: %s backend | root \"%s\" | scope %s",
			status.Backend, status.Root, status.Scope
		))
		if status.Backend == "Memory" then
			label:SetColor(ctx.Theme.Colors.Warning)
		else
			label:SetColor(ctx.Theme.Colors.Success)
		end
	end

	-- Apply persisted values to live systems on enable.
	local watermark = self:GetOption("Watermark")
	if watermark then ctx.Library:SetWatermarkVisible(watermark.Value) end

	local speed = self:GetOption("AnimSpeed")
	if speed then ctx.Theme.Speed = speed.Value end

	local key = self:GetOption("UIKey")
	if key and key.Value and Enum.KeyCode[key.Value] then
		ctx.Library.UIKey = Enum.KeyCode[key.Value]
	end

	-- Keep the watermark informative: game name + build + profile.
	ctx.Library:SetWatermarkLines({
		ctx.Library._WatermarkLines and ctx.Library._WatermarkLines[1] or "",
		"TBV v4  |  " .. (ctx.Library.Profile or "Default"),
	})
end

function module:OnDisable(ctx)
	-- Nothing to tear down: this module only tweaks settings that persist.
end

return module
end)

--==========================================================================
--  Modules/Utility/Profiles
--==========================================================================
TBV_REGISTER("Modules/Utility/Profiles", function(...)
--[==[
	TBV v4  ::  Modules/Utility/Profiles.lua
	----------------------------------------------------------------------------
	Profile manager UI: create, save, load and delete per-game configs.

	Demonstrates:
	  * Dropdown options being refreshed at runtime (:SetOptions)
	  * TextBox + Button wiring
	  * How persistence is scoped: one folder per PlaceId, so a config saved in
		one game is never offered in another.
]==]

local module = {
	Name = "Profiles",
	Tab = "Interface",
	Section = "Profiles",
	Side = "Right",
	Description = "Save and load configurations",
	Default = true,
}

function module:Options(ctx)
	local profileDropdown = self:AddDropdown({
		Name = "Profile",
		Flag = "Selected",
		Options = ctx.Library:ListProfiles(),
		Default = ctx.Library.Profile or "Default",
	})

	self:AddTextBox({
		Name = "New profile",
		Flag = "NewName",
		Placeholder = "profile name...",
		Default = "",
	})

	self:AddButton({
		Name = "Save current profile",
		Callback = function()
			local name = self:GetOption("NewName").Value
			if name == "" then name = ctx.Library.Profile end
			ctx.Library:SaveProfile(name)
			profileDropdown:SetOptions(ctx.Library:ListProfiles())
			profileDropdown:SetValue(name, true)
		end,
	})

	self:AddButton({
		Name = "Load selected profile",
		Callback = function()
			local name = profileDropdown.Value
			if not name then return end
			ctx.Library:LoadProfile(name)
		end,
	})

	self:AddButton({
		Name = "Delete selected profile",
		Callback = function()
			local name = profileDropdown.Value
			if not name then return end
			ctx.Library:DeleteProfile(name)
			profileDropdown:SetOptions(ctx.Library:ListProfiles())
			ctx:Notify("TBV v4", "Deleted profile \"" .. name .. "\"", 3)
		end,
	})

	self:AddButton({
		Name = "Refresh list",
		Callback = function()
			profileDropdown:SetOptions(ctx.Library:ListProfiles())
		end,
	})

	self:AddLabel({
		Name = "Profiles are written to TBVv4/Configs/<PlaceId>/<name>.json via writefile/readfile, with an in-memory fallback when the file API is unavailable.",
	})
end

function module:OnEnable(ctx)
	-- Refresh on enable so newly discovered profiles appear without a restart.
	local dropdown = self:GetOption("Selected")
	if dropdown then
		dropdown:SetOptions(ctx.Library:ListProfiles())
	end
end

function module:OnDisable(ctx) end

return module
end)

--==========================================================================
--  Modules/Utility/RaycastProbe
--==========================================================================
TBV_REGISTER("Modules/Utility/RaycastProbe", function(...)
--[==[
	TBV v4  ::  Modules/Utility/RaycastProbe.lua
	----------------------------------------------------------------------------
	Developer probe: reports what the centre of the camera is pointing at
	(part name, class, material, distance).

	This is the reference implementation for MODERN RAYCASTING in TBV v4.
	Everything here uses workspace:Raycast + RaycastParams; the deprecated
	FindPartOnRay family appears nowhere in the build. See the migration table in
	Library/Utility.lua for the old -> new mapping.

	Two performance notes that generalise to any raycasting code:
	  1. RaycastParams is built ONCE and reused. Rebuilding the params object (or
		 its filter list) every frame allocates and re-hashes the filter table.
	  2. The cast is throttled by the shared scheduler instead of running every
		 frame - visually identical results for a fraction of the cost.
]==]

local module = {
	Name = "Raycast Probe",
	Tab = "Utility",
	Section = "Developer",
	Side = "Right",
	Description = "Inspect what the camera is pointing at",
	Default = false,
}

function module:Options(ctx)
	self:AddSlider({
		Name = "Max distance",
		Flag = "Distance",
		Min = 10,
		Max = 1000,
		Default = 250,
	})

	self:AddSlider({
		Name = "Refresh rate",
		Flag = "Refresh",
		Min = 0.05,
		Max = 1,
		Default = 0.15,
		Decimals = 2,
		Suffix = "s",
	})

	self:AddToggle({
		Name = "Ignore own character",
		Flag = "IgnoreCharacter",
		Default = true,
	})

	self:AddToggle({
		Name = "Show material",
		Flag = "ShowMaterial",
		Default = true,
	})

	self:AddLabel({ Name = "Aim at a part to inspect it.", Flag = "Readout" })
end

function module:OnEnable(ctx)
	local params = nil
	local filter = {}

	--- (Re)build the cached RaycastParams for the current character.
	local function rebuildParams()
		filter = {}
		if self:GetOption("IgnoreCharacter").Value and ctx.LocalPlayer.Character then
			filter[1] = ctx.LocalPlayer.Character
		end
		-- Cached by filter contents, so repeated calls with the same character
		-- return the identical params object instead of allocating a new one.
		params = ctx:RaycastParams(filter, Enum.RaycastFilterType.Blacklist, true)
	end

	rebuildParams()

	-- A new character means a new ignore target.
	ctx:Connect(ctx.LocalPlayer.CharacterAdded, function()
		rebuildParams()
	end)

	self:GetOption("IgnoreCharacter").Callback = rebuildParams

	local readout = self:GetOption("Readout")
	local lastText = nil

	ctx:OnHeartbeat(function()
		local camera = workspace.CurrentCamera
		if not camera then return end

		local distance = self:GetOption("Distance").Value
		local result = ctx:Raycast(
			camera.CFrame.Position,
			camera.CFrame.LookVector * distance,
			params
		)

		local text
		if not result then
			text = "Nothing within " .. tostring(math.floor(distance)) .. " studs"
		else
			local instance = result.Instance
			local studs = math.floor((result.Position - camera.CFrame.Position).Magnitude * 10) / 10
			text = string.format("%s  (%s)", instance.Name, instance.ClassName)
			if self:GetOption("ShowMaterial").Value then
				text = text .. string.format("  [%s]", tostring(result.Material))
			end
			text = text .. string.format("  %.1f studs", studs)
		end

		if text ~= lastText and readout then
			lastText = text
			readout:SetText(text)
		end
	end, self:GetOption("Refresh").Value)
end

function module:OnDisable(ctx)
	local readout = self:GetOption("Readout")
	if readout then readout:SetText("Aim at a part to inspect it.") end
end

return module
end)

--==========================================================================
--  Modules/Index
--==========================================================================
TBV_REGISTER("Modules/Index", function(...)
--[==[
	TBV v4  ::  Modules/Index.lua
	----------------------------------------------------------------------------
	The module registry.

	Adding a feature is two steps:
		1. Create Modules/<Tab>/<Name>.lua (copy Templates/ModuleTemplate.lua)
		2. Import it here and add it to the list below.

	Nothing else in the build needs to change - tabs, sections, cards, config
	serialisation and search all derive from this list.

	Order matters only for how modules appear on screen (top to bottom, per
	column). Modules are grouped by Tab/Section automatically.
]==]

local import = ...

local Modules = {
	-- Utility tab ----------------------------------------------------------
	import("Modules/Utility/FPSCounter"),
	import("Modules/Utility/Clock"),
	import("Modules/Utility/RaycastProbe"),

	-- Interface tab (right column) ----------------------------------------
	import("Modules/Utility/Interface"),
	import("Modules/Utility/Profiles"),
}

-- Tip: to disable a module without deleting it, comment out its import above.
-- Saved settings stay on disk and come back when it is re-enabled.

return Modules
end)

--==========================================================================
--  Main
--==========================================================================
TBV_REGISTER("Main", function(...)
--[==[
	TBV v4  ::  Main.lua
	----------------------------------------------------------------------------
	Entry point. Owns the boot sequence and nothing else.

	Boot order matters:
		1. Config:Init()          - detect the file API and build TBVv4/
		2. Utility:StartScheduler - one Heartbeat connection for the whole build
		3. Loading screen         - created BEFORE the library so the user sees
									something within one frame of executing
		4. Library.new()          - build the ScreenGui and layers
		5. Register modules       - read Modules/Index.lua
		6. Restore profile        - apply saved options, then enable modules
		7. Reveal                 - fade the loading screen out, animate the
									window in, fire the "loaded" notification

	Any step that throws is caught: the loading screen is destroyed first so the
	user is never left staring at a full-screen frame that swallows input.
]==]

local import = ...

local Theme = import("Library/Theme")
local Utility = import("Library/Utility")
local Config = import("Config/ConfigSystem")
local LoadingScreen = import("Loading/LoadingScreen")
local Library = import("Library/Library")
local ModuleList = import("Modules/Index")

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local TBV = {
	Name = "TBV v4",
	Version = "4.0.0",
}

-- Expose a handle for the console / other scripts. getgenv is not guaranteed,
-- so fall back to a plain global assignment.
pcall(function()
	if typeof(getgenv) == "function" then
		getgenv().TBVv4 = TBV
	else
		_G.TBVv4 = TBV
	end
end)

--- Pick the GUI container used for the boot screen (same rules as the library).
local function resolveContainer()
	local ok, gethuiFn = pcall(function() return gethui end)
	if ok and typeof(gethuiFn) == "function" then
		local ok2, container = pcall(gethuiFn)
		if ok2 and container then return container end
	end
	local ok3, coreGui = pcall(function() return game:GetService("CoreGui") end)
	if ok3 and coreGui then return coreGui end
	return Players.LocalPlayer:WaitForChild("PlayerGui")
end

local function boot()
	---------------------------------------------------------------- storage
	Config:Init()
	-- Profiles are scoped per place: a config saved in one game is never
	-- offered in another.
	Config:SetScope(game.PlaceId)

	-- Start the shared spring/heartbeat scheduler before anything animates.
	Utility:StartScheduler()

	---------------------------------------------------------------- loading ui
	local loadingGui = Utility:Create("ScreenGui", {
		Name = "TBVv4_Loading",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 2000, -- above the finished UI while it boots
		Parent = resolveContainer(),
	})

	local loading = LoadingScreen.new({ Theme = Theme, Utility = Utility }, loadingGui)
	loading:Show()

	---------------------------------------------------------------- steps
	local library = nil

	loading:RunSteps({
		{
			Label = "Initialising core...",
			Weight = 10,
			Run = function()
				-- Warm the service cache used by every module.
				Utility:Service("RunService")
				Utility:Service("UserInputService")
				Utility:Service("HttpService")
			end,
		},
		{
			Label = "Loading theme...",
			Weight = 8,
			Run = function()
				-- Theme is already loaded; this step applies any persisted
				-- accent colours before the first frame is drawn.
				local settings = Config:LoadSettings("ui")
				if type(settings) == "table"
					and type(settings.AccentFrom) == "string"
					and type(settings.AccentTo) == "string" then
					Theme:SetAccent(settings.AccentFrom, settings.AccentTo)
				end
			end,
		},
		{
			Label = "Registering modules...",
			Weight = 45,
			Run = function()
				library = Library.new({
					Profile = "Default",
					AutoSave = true,
				})
				-- Window stays hidden until boot completes.
				library:SetVisible(false, false)

				for _, definition in ipairs(ModuleList) do
					library:RegisterModule(definition)
				end

				library:SelectTab(library.TabOrder[1])
			end,
		},
		{
			Label = "Restoring profile...",
			Weight = 20,
			Run = function()
				if not library then return end
				local saved = Config:Load(library.Profile)
				if saved then
					library:Deserialize(saved)
				else
					-- First boot: honour each module's Default flag, then write a
					-- baseline profile so next launch restores from disk.
					library:ApplyDefaults()
					Config:Save(library.Profile, library:Serialize())
				end
			end,
		},
		{
			Label = "Building interface...",
			Weight = 12,
			Run = function()
				if not library then return end
				library:ApplySearch("")
				RunService.RenderStepped:Wait()
			end,
		},
	}, function()
		---------------------------------------------------------- reveal
		if not library then
			loadingGui:Destroy()
			return
		end

		TBV.Library = library
		library:SetVisible(true)

		-- Persist window position / visibility / accent so the next session
		-- starts exactly where this one left off.
		library:_QueueSaveSettings()

		library:Notify("TBV v4", "Loaded - press " .. tostring(library.UIKey.Name) .. " to hide the interface.", 5)
	end)
end

-- Boot errors must never leave the loading screen on top of a broken UI.
local ok, err = pcall(boot)
if not ok then
	warn("[TBV v4] boot failed: " .. tostring(err))
	-- Best effort: remove any full-screen frame we may have created.
	pcall(function()
		for _, container in ipairs({ game:GetService("CoreGui"), Players.LocalPlayer:FindFirstChild("PlayerGui") }) do
			if container then
				for _, child in ipairs(container:GetChildren()) do
					if child.Name == "TBVv4_Loading" then child:Destroy() end
				end
			end
		end
	end)
end

return TBV
end)

--==========================================================================
--  Modules/Templates/ModuleTemplate
--==========================================================================
TBV_REGISTER("Modules/Templates/ModuleTemplate", function(...)
--[==[
	TBV v4  ::  Modules/Templates/ModuleTemplate.lua
	----------------------------------------------------------------------------
	Copy this file to Modules/<Tab>/<Name>.lua, then list it in Modules/Index.lua.

	THE CONTRACT
	------------
	A module is a plain table. TBV v4 reads these fields:

		Name        string   Unique. Used as the card title AND the config key,
							 so renaming a module orphans old saved values.
		Tab         string   Tab to live under (created on demand).
		Section     string   Section inside the tab (default "Main").
		Side        string   "Left" or "Right" column (default "Left").
		Description string   Small grey line under the card title.
		Default     boolean  Enabled on first boot?

		Options(module, ctx)   Build the option widgets. Called ONCE at boot.
		OnEnable(module, ctx)  Called when the switch turns on.
		OnDisable(module, ctx) Called when the switch turns off.

	Inside those functions:
		module:AddToggle / AddSlider / AddDropdown / AddColorPicker /
				AddTextBox / AddButton / AddLabel   -> build UI + saved settings
		module:GetOption(flag)                     -> read an option at any time
		module:SetStatus(text)                     -> update the card's sub-label

		ctx:Connect(signal, fn)       auto-disconnected on disable
		ctx:OnHeartbeat(fn, interval) throttled, auto-disconnected on disable
		ctx:OnRender(fn, interval)    same, on RenderStepped
		ctx:Raycast(origin, dir, params)
		ctx:RaycastParams(filter, filterType, ignoreWater)
		ctx:Notify(title, text, duration)
		ctx.Library / ctx.Theme / ctx.Utility / ctx.Config
		ctx.LocalPlayer / ctx.Camera / ctx.<AnyRobloxService>

	RULES OF THUMB
	--------------
	* Never call RunService.Heartbeat:Connect directly - use ctx:OnHeartbeat so
	  the connection is torn down with the module and shares one global loop.
	* Anything created in OnEnable must be destroyed in OnDisable.
	* Read options through GetOption inside loops so live edits apply instantly.
	* Keep heavy work off the render step; prefer throttled heartbeats.
]==]

local module = {
	Name = "Module Template",
	Tab = "Utility",
	Section = "Developer",
	Side = "Right",
	Description = "Starting point for new modules",
	Default = false,
}

--- Build the module's options. Runs once, before the first enable.
function module:Options(ctx)
	self:AddToggle({
		Name = "Example toggle",   -- label
		Flag = "ExampleToggle",    -- config key (defaults to Name if omitted)
		Default = false,
		CanBind = true,            -- show the keybind chip
		Callback = function(value)
			-- Fires on user input AND on profile load (skip callbacks with
			-- option:SetValue(v, true) when that matters).
			print("[TBV v4] example toggle:", value)
		end,
	})

	self:AddSlider({
		Name = "Example slider",
		Flag = "ExampleSlider",
		Min = 0,
		Max = 100,
		Default = 50,
		Decimals = 0,
		Suffix = "%",
	})

	self:AddDropdown({
		Name = "Example dropdown",
		Flag = "ExampleDropdown",
		Options = { "Alpha", "Beta", "Gamma" },
		Default = "Alpha",
		Multi = false, -- true -> value is an array of selected strings
	})

	self:AddColorPicker({
		Name = "Example colour",
		Flag = "ExampleColor",
		Default = ctx.Theme.Colors.PinkLight,
	})

	self:AddTextBox({
		Name = "Example text",
		Flag = "ExampleText",
		Placeholder = "type here...",
		Default = "",
	})

	self:AddButton({
		Name = "Example button",
		Callback = function()
			ctx:Notify("TBV v4", "Button pressed", 3)
		end,
	})

	self:AddLabel({ Name = "Labels are for hints and live readouts.", Flag = "ExampleLabel" })
end

--- Runs when the module is switched on.
function module:OnEnable(ctx)
	-- Example: a throttled background task. 0.25 = four times per second.
	ctx:OnHeartbeat(function(dt)
		local toggle = self:GetOption("ExampleToggle")
		if not toggle or not toggle.Value then return end
		-- ... do work ...
	end, 0.25)

	-- Example: reacting to a Roblox event (auto-disconnected on disable).
	ctx:Connect(ctx.LocalPlayer.CharacterAdded, function(character)
		self:SetStatus("Character: " .. character.Name)
	end)
end

--- Runs when the module is switched off. Connections and heartbeat tasks are
-- already gone by the time this is called; destroy anything you created.
function module:OnDisable(ctx)
	self:SetStatus("")
end

return module
end)

--------------------------------------------------------------------------------
--  Boot
--------------------------------------------------------------------------------

return import("Main")
