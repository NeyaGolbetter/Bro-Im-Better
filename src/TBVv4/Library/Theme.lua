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
