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
