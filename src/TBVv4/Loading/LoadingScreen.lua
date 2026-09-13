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
