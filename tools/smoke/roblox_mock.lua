--[==[
	TBV v4  ::  tools/smoke/roblox_mock.lua
	----------------------------------------------------------------------------
	A miniature Roblox environment so the bundled build can be executed
	headlessly (under fengari, a Lua 5.3 VM in JavaScript).

	This is a TEST DOUBLE, not an emulator: it implements only the API surface
	TBV v4 actually touches, with just enough fidelity to run a real boot -
	instance hierarchy, property change signals, GUI events, tweens, a virtual
	clock plus coroutine-backed task library, JSON, and the file API.

	What it catches that a parser cannot:
	  * nil method calls / typos on objects (card:SetVisble etc.)
	  * wrong argument counts into Roblox constructors
	  * lifecycle bugs (module enable/disable, config round-trip)
	  * infinite loops in the debounced save queue
	  * config serialisation errors (JSON round-trip through the file API)
]==]

-- Polyfills: Luau has these, Lua 5.3 does not.
math.clamp = math.clamp or function(value, minimum, maximum)
	if value < minimum then return minimum end
	if value > maximum then return maximum end
	return value
end

table.clear = table.clear or function(t)
	for key in pairs(t) do t[key] = nil end
end

local WARNINGS = {}
_G.__TBV_WARNINGS = WARNINGS

function warn(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring((select(i, ...)))
	end
	local message = table.concat(parts, " ")
	-- Keep the traceback in the collected list; the report only prints the
	-- first line of each warning, but full traces are invaluable when debugging.
	WARNINGS[#WARNINGS + 1] = message .. "\n" .. (debug.traceback() or "")
	print("[warn] " .. message)
end

--------------------------------------------------------------------------------
--  Value types
--------------------------------------------------------------------------------

local function makeType(name, constructor)
	return setmetatable(constructor, { __index = function(_, key) return rawget(constructor, key) end })
end

local Vector2 = {}
Vector2.__index = Vector2
Vector2.__type = "Vector2"
function Vector2.new(x, y)
	return setmetatable({ X = x or 0, Y = y or 0 }, Vector2)
end

local Vector3 = {}
Vector3.__index = Vector3
Vector3.__type = "Vector3"
function Vector3.new(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end
function Vector3.__sub(a, b)
	return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
function Vector3:Magnitude()
	return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
end

local UDim = {}
UDim.__index = UDim
UDim.__type = "UDim"
function UDim.new(scale, offset)
	return setmetatable({ Scale = scale or 0, Offset = offset or 0 }, UDim)
end

local UDim2 = {}
UDim2.__index = UDim2
UDim2.__type = "UDim2"
function UDim2.new(xScale, xOffset, yScale, yOffset)
	return setmetatable({
		X = UDim.new(xScale or 0, xOffset or 0),
		Y = UDim.new(yScale or 0, yOffset or 0),
	}, UDim2)
end
function UDim2.fromOffset(x, y)
	return UDim2.new(0, x or 0, 0, y or 0)
end
function UDim2.fromScale(x, y)
	return UDim2.new(x or 0, 0, y or 0, 0)
end

local Color3 = {}
Color3.__index = Color3
Color3.__type = "Color3"
function Color3.new(r, g, b)
	return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, Color3)
end
function Color3.fromRGB(r, g, b)
	return Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
end
function Color3.fromHSV(h, s, v)
	return Color3.new(h or 0, s or 1, v or 1)
end
function Color3.fromHex(hex)
	hex = tostring(hex):gsub("#", "")
	if #hex ~= 6 or not hex:match("^%x+$") then
		error("invalid hex colour: " .. tostring(hex), 2)
	end
	return Color3.fromRGB(tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16))
end
function Color3:ToHSV()
	return self.R, self.G, self.B
end
function Color3:ToHex()
	local function channel(value)
		local byte = math.floor(math.clamp(value, 0, 1) * 255 + 0.5)
		return string.format("%02X", byte)
	end
	return channel(self.R) .. channel(self.G) .. channel(self.B)
end
function Color3:Lerp(other, alpha)
	return Color3.new(
		self.R + (other.R - self.R) * alpha,
		self.G + (other.G - self.G) * alpha,
		self.B + (other.B - self.B) * alpha
	)
end

local ColorSequenceKeypoint = {}
function ColorSequenceKeypoint.new(time, color)
	return { Time = time, Value = color, __type = "ColorSequenceKeypoint" }
end
local ColorSequence = {}
function ColorSequence.new(keypoints)
	return { Keypoints = keypoints or {}, __type = "ColorSequence" }
end

local NumberSequenceKeypoint = {}
function NumberSequenceKeypoint.new(time, value)
	return { Time = time, Value = value, __type = "NumberSequenceKeypoint" }
end
local NumberSequence = {}
function NumberSequence.new(keypoints)
	return { Keypoints = keypoints or {}, __type = "NumberSequence" }
end

local RaycastParams = {}
RaycastParams.__index = RaycastParams
RaycastParams.__type = "RaycastParams"
function RaycastParams.new()
	return setmetatable({ FilterDescendantsInstances = {}, IgnoreWater = false }, RaycastParams)
end
function RaycastParams:AddToFilter(instance)
	table.insert(self.FilterDescendantsInstances, instance)
end

local TweenInfo = {}
function TweenInfo.new(duration, easingStyle, easingDirection, repeatCount, reverses, delayTime)
	return {
		Time = duration or 1,
		EasingStyle = easingStyle,
		EasingDirection = easingDirection,
		RepeatCount = repeatCount or 0,
		Reverses = reverses or false,
		DelayTime = delayTime or 0,
		__type = "TweenInfo",
	}
end

local CFrame = {}
function CFrame.new(x, y, z)
	return {
		Position = Vector3.new(x or 0, y or 0, z or 0),
		LookVector = Vector3.new(0, 0, -1),
		__type = "CFrame",
	}
end

--------------------------------------------------------------------------------
--  Enum
--------------------------------------------------------------------------------

local Enum = {}
local enumTypes = {}
setmetatable(Enum, {
	__index = function(_, typeName)
		if enumTypes[typeName] then return enumTypes[typeName] end
		local enumType = {}
		enumTypes[typeName] = enumType
		setmetatable(enumType, {
			__index = function(inner, member)
				local item = { Name = tostring(member), Value = 0, EnumType = enumType, __type = "EnumItem" }
				rawset(inner, member, item)
				return item
			end,
		})
		return enumType
	end,
})

--------------------------------------------------------------------------------
--  Events
--------------------------------------------------------------------------------

local function Signal()
	local listeners = {}
	local signal = {}

	function signal:Connect(callback)
		assert(type(callback) == "function", "Connect expects a function")
		local connection
		connection = {
			Connected = true,
			Disconnect = function()
				connection.Connected = false
				for index = #listeners, 1, -1 do
					if listeners[index] == callback then
						table.remove(listeners, index)
						break
					end
				end
			end,
		}
		listeners[#listeners + 1] = callback
		return connection
	end

	function signal:Fire(...)
		-- Snapshot: a listener may disconnect itself (or others) while we run.
		local snapshot = {}
		for index = 1, #listeners do snapshot[index] = listeners[index] end
		for index = 1, #snapshot do
			local ok, err = pcall(snapshot[index], ...)
			if not ok then
				warn("[mock] event listener error: " .. tostring(err))
			end
		end
	end

	function signal:Wait()
		return 1 / 60 -- tests do not simulate real blocking waits
	end

	return signal
end

--------------------------------------------------------------------------------
--  Instance
--------------------------------------------------------------------------------

local CLASS_TREE = {
	TextLabel = { "GuiObject", "GuiBase2d", "GuiBase", "Instance" },
	TextButton = { "GuiButton", "GuiObject", "GuiBase2d", "GuiBase", "Instance" },
	ImageButton = { "GuiButton", "GuiObject", "GuiBase2d", "GuiBase", "Instance" },
	ImageLabel = { "GuiObject", "GuiBase2d", "GuiBase", "Instance" },
	TextBox = { "GuiObject", "GuiBase2d", "GuiBase", "Instance" },
	Frame = { "GuiObject", "GuiBase2d", "GuiBase", "Instance" },
	ScrollingFrame = { "GuiObject", "GuiBase2d", "GuiBase", "Instance" },
	ScreenGui = { "GuiBase", "Instance" },
	UICorner = { "UIComponent", "Instance" },
	UIStroke = { "UIComponent", "Instance" },
	UIGradient = { "UIComponent", "Instance" },
	UIListLayout = { "UIComponent", "Instance" },
	UIPadding = { "UIComponent", "Instance" },
	NumberValue = { "Instance" },
	Camera = { "Instance" },
	Folder = { "Instance" },
}

local PROPERTY_DEFAULTS = {
	BackgroundTransparency = 0,
	TextTransparency = 0,
	ImageTransparency = 0,
	TextStrokeTransparency = 1,
	Transparency = 0,
	Text = "",
	PlaceholderText = "",
	TextSize = 12,
	Visible = true,
	Rotation = 0,
	ZIndex = 1,
	ClipsDescendants = false,
	Size = UDim2.new(0, 0, 0, 0),
	Position = UDim2.new(0, 0, 0, 0),
	AnchorPoint = Vector2.new(0, 0),
	LayoutOrder = 0,
	AutomaticSize = nil,
	ScrollBarThickness = 0,
}

local INSTANCE_EVENTS = {
	"MouseEnter", "MouseLeave", "MouseButton1Down", "MouseButton1Up", "MouseButton1Click",
	"MouseButton2Click", "InputBegan", "InputChanged", "InputEnded", "Focused",
	"FocusLost", "Destroying", "Changed",
}

local instanceCounter = 0

local InstanceLib = {}
function InstanceLib.new(className)
	instanceCounter = instanceCounter + 1

	local instance = {
		ClassName = className,
		Name = className .. "_" .. instanceCounter,
		_id = instanceCounter,
		_children = {},
		_signals = {},
		_props = {},
		_destroyed = false,
		__type = "Instance",
	}

	local metatable = {}

	function metatable:__index(key)
		-- Signals are created lazily so every instance need not pre-allocate them.
		for _, eventName in ipairs(INSTANCE_EVENTS) do
			if key == eventName then
				if not self._signals[key] then self._signals[key] = Signal() end
				return self._signals[key]
			end
		end

		if key == "AbsoluteSize" then
			local size = rawget(self, "_props").Size
			if size and size.X then return Vector2.new(size.X.Offset, size.Y.Offset) end
			return Vector2.new(200, 30)
		end
		if key == "AbsolutePosition" then
			local position = rawget(self, "_props").Position
			if position and position.X then return Vector2.new(position.X.Offset, position.Y.Offset) end
			return Vector2.new(0, 0)
		end

		local props = rawget(self, "_props")
		if props[key] ~= nil then return props[key] end
		if PROPERTY_DEFAULTS[key] ~= nil then return PROPERTY_DEFAULTS[key] end
		if key == "Parent" then return nil end
		return nil
	end

	function metatable:__newindex(key, value)
		local props = rawget(self, "_props")

		if key == "Parent" then
			local previous = props.Parent
			if previous and previous._children then
				for index = #previous._children, 1, -1 do
					if previous._children[index] == self then
						table.remove(previous._children, index)
						break
					end
				end
			end
			props.Parent = value
			if value and value._children then
				value._children[#value._children + 1] = self
			end
			InstanceLib._fireChanged(self, "Parent")
			return
		end

		props[key] = value
		InstanceLib._fireChanged(self, key)
	end

	function metatable:__tostring()
		return rawget(self, "Name")
	end

	setmetatable(instance, metatable)

	function instance:Destroy()
		if self._destroyed then return end
		self._destroyed = true
		if self._signals.Destroying then self._signals.Destroying:Fire() end
		self.Parent = nil
	end

	function instance:IsA(className)
		if self.ClassName == className then return true end
		local ancestors = CLASS_TREE[self.ClassName]
		if not ancestors then return false end
		for _, ancestor in ipairs(ancestors) do
			if ancestor == className then return true end
		end
		return false
	end

	function instance:GetChildren()
		local copy = {}
		for index = 1, #self._children do copy[index] = self._children[index] end
		return copy
	end

	function instance:GetDescendants()
		local out = {}
		local function walk(object)
			for _, child in ipairs(object._children) do
				out[#out + 1] = child
				walk(child)
			end
		end
		walk(self)
		return out
	end

	function instance:FindFirstChild(name)
		for _, child in ipairs(self._children) do
			if child.Name == name then return child end
		end
		return nil
	end

	function instance:WaitForChild(name, _timeout)
		local existing = self:FindFirstChild(name)
		if existing then return existing end
		local created = InstanceLib.new("Folder")
		created.Name = name
		created.Parent = self
		return created
	end

	function instance:GetPropertyChangedSignal(property)
		if not self._signals["pc:" .. property] then
			self._signals["pc:" .. property] = Signal()
		end
		return self._signals["pc:" .. property]
	end

	function instance:IsFocused()
		return self._props._focused == true
	end

	return instance
end

function InstanceLib._fireChanged(instance, property)
	local signal = instance._signals and instance._signals["pc:" .. property]
	if signal then signal:Fire() end
end

--------------------------------------------------------------------------------
--  Virtual clock + task library (real coroutine scheduling, so the debounced
--  save queue is exercised the same way it would be in Roblox)
--------------------------------------------------------------------------------

local clock = 0
local scheduled = {}

local task = {}

local function scheduleResume(co, ok, result)
	if not ok then
		warn("[mock] task error: " .. tostring(result))
		return
	end
	if type(result) == "table" and result.type == "wait" then
		scheduled[#scheduled + 1] = { co = co, wake = clock + (result.duration or 0) }
	end
end

function task.spawn(fn, ...)
	assert(type(fn) == "function", "task.spawn expects a function")
	local co = coroutine.create(fn)
	scheduleResume(co, coroutine.resume(co, ...))
end

function task.defer(fn, ...)
	task.spawn(fn, ...)
end

function task.delay(duration, fn, ...)
	local args = table.pack(...)
	task.spawn(function()
		task.wait(duration)
		fn(table.unpack(args, 1, args.n))
	end)
end

function task.wait(duration)
	local co, main = coroutine.running()
	if main then
		-- Called from the main chunk: cannot yield, so just report the elapsed
		-- time (this is what LoadingScreen:Finish does during boot).
		return duration or 0
	end
	return coroutine.yield({ type = "wait", duration = duration or 0 })
end

os.clock = function() return clock end

--------------------------------------------------------------------------------
--  Services
--------------------------------------------------------------------------------

local services = {}

local function newService(name)
	local service = InstanceLib.new("Folder")
	service.Name = name
	return service
end

-- TweenService: applies the final property values immediately, then fires
-- Completed. Tests care about end state, not interpolation.
local TweenService = newService("TweenService")

-- Completed is fired on the NEXT simulated frame, not during Play(): callers
-- attach their Completed handler after Utility:Tween() returns, and in real
-- Roblox the event fires when the tween finishes (later). Firing it inside
-- Play() would mean no listener is attached yet.
local pendingTweens = {}

function TweenService:Create(instance, tweenInfo, properties)
	local tween = {
		Instance = instance,
		TweenInfo = tweenInfo,
		Properties = properties,
		PlaybackState = Enum.PlaybackState.Begin,
	}
	tween.Completed = Signal()
	function tween:Play()
		if self._cancelled then return end
		for key, value in pairs(self.Properties) do
			self.Instance[key] = value
		end
		self.PlaybackState = Enum.PlaybackState.Completed
		if not self._queued then
			self._queued = true
			pendingTweens[#pendingTweens + 1] = self
		end
	end
	function tween:Cancel()
		self._cancelled = true
		self.PlaybackState = Enum.PlaybackState.Cancelled
	end
	function tween:Pause() end
	return tween
end

local function flushTweens()
	local due = pendingTweens
	pendingTweens = {}
	for _, tween in ipairs(due) do
		if not tween._cancelled then
			tween.Completed:Fire(Enum.PlaybackState.Completed)
		end
	end
end

local RunService = newService("RunService")
RunService.Heartbeat = Signal()
RunService.RenderStepped = Signal()
function RunService:IsClient() return true end
function RunService:BindToRenderStep() end

local UserInputService = newService("UserInputService")
UserInputService.InputBegan = Signal()
UserInputService.InputChanged = Signal()
UserInputService.InputEnded = Signal()
function UserInputService:GetMouseLocation() return Vector2.new(100, 100) end
function UserInputService:GetFocusedTextBox() return nil end

local HttpService = newService("HttpService")

-- A real (if compact) JSON codec: the profile round-trip has to survive quoted
-- strings, unicode-ish content and nested tables, so stubbing this out with
-- load("return {...}") would hide genuine escaping bugs.
local Json = {}

local ESCAPES = {
	['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b",
	["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escapeString(value)
	value = tostring(value)
	value = value:gsub('[%c"\\]', function(char)
		return ESCAPES[char] or string.format("\\u%04X", string.byte(char))
	end)
	return '"' .. value .. '"'
end

local function isArray(t)
	local count = 0
	for key in pairs(t) do
		if type(key) ~= "number" then return false end
		count = count + 1
	end
	for index = 1, count do
		if t[index] == nil then return false end
	end
	return true
end

local function writeValue(value, out)
	local kind = type(value)
	if value == nil then
		out[#out + 1] = "null"
	elseif kind == "boolean" then
		out[#out + 1] = value and "true" or "false"
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			out[#out + 1] = "null"
		elseif value == math.floor(value) and math.abs(value) < 2 ^ 53 then
			out[#out + 1] = string.format("%d", value)
		else
			out[#out + 1] = string.format("%.14g", value)
		end
	elseif kind == "string" then
		out[#out + 1] = escapeString(value)
	elseif kind == "table" then
		if isArray(value) then
			out[#out + 1] = "["
			for index = 1, #value do
				if index > 1 then out[#out + 1] = "," end
				writeValue(value[index], out)
			end
			out[#out + 1] = "]"
		else
			out[#out + 1] = "{"
			local first = true
			for key, item in pairs(value) do
				if not first then out[#out + 1] = "," end
				first = false
				out[#out + 1] = escapeString(tostring(key)) .. ":"
				writeValue(item, out)
			end
			out[#out + 1] = "}"
		end
	else
		out[#out + 1] = escapeString(tostring(value))
	end
end

function Json.Encode(value)
	local out = {}
	writeValue(value, out)
	return table.concat(out)
end

local function skipWhitespace(str, index)
	return str:find("[^ \t\r\n]", index) or (#str + 1)
end

local function parseValue(str, index)
	index = skipWhitespace(str, index)
	local char = str:sub(index, index)

	if char == "{" then
		index = index + 1
		local result = {}
		index = skipWhitespace(str, index)
		if str:sub(index, index) == "}" then return result, index + 1 end
		while true do
			index = skipWhitespace(str, index)
			assert(str:sub(index, index) == '"', "expected key at " .. index)
			local key
			key, index = parseValue(str, index)
			index = skipWhitespace(str, index)
			assert(str:sub(index, index) == ":", "expected ':' at " .. index)
			local value
			value, index = parseValue(str, index + 1)
			result[key] = value
			index = skipWhitespace(str, index)
			local separator = str:sub(index, index)
			if separator == "}" then return result, index + 1 end
			assert(separator == ",", "expected ',' or '}' at " .. index)
			index = index + 1
		end
	elseif char == "[" then
		index = index + 1
		local result = {}
		index = skipWhitespace(str, index)
		if str:sub(index, index) == "]" then return result, index + 1 end
		while true do
			local value
			value, index = parseValue(str, index)
			result[#result + 1] = value
			index = skipWhitespace(str, index)
			local separator = str:sub(index, index)
			if separator == "]" then return result, index + 1 end
			assert(separator == ",", "expected ',' or ']' at " .. index)
			index = index + 1
		end
	elseif char == '"' then
		local out = {}
		index = index + 1
		while true do
			local current = str:sub(index, index)
			if current == "" then error("unterminated string", 2) end
			if current == '"' then break end
			if current == "\\" then
				local next = str:sub(index + 1, index + 1)
				local simple = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
				if simple[next] then
					out[#out + 1] = simple[next]
					index = index + 2
				elseif next == "u" then
					out[#out + 1] = string.char(tonumber(str:sub(index + 2, index + 5), 16) or 63)
					index = index + 6
				else
					error("bad escape: \\" .. next, 2)
				end
			else
				out[#out + 1] = current
				index = index + 1
			end
		end
		return table.concat(out), index + 1
	elseif str:sub(index, index + 3) == "true" then
		return true, index + 4
	elseif str:sub(index, index + 4) == "false" then
		return false, index + 5
	elseif str:sub(index, index + 3) == "null" then
		return nil, index + 4
	else
		local numberText = str:match("^[-+0-9.eE]+", index)
		assert(numberText, "invalid value at " .. index)
		return tonumber(numberText), index + #numberText
	end
end

function Json.Decode(raw)
	assert(type(raw) == "string", "JSONDecode expects a string")
	local value = parseValue(raw, 1)
	return value
end

function HttpService:JSONEncode(value)
	return Json.Encode(value)
end
function HttpService:JSONDecode(raw)
	return Json.Decode(raw)
end
function HttpService:GenerateGUID() return "GUID" end

local TextService = newService("TextService")
function TextService:GetTextSize(text, textSize, _font, frameSize)
	local lines = 1
	for _ in tostring(text):gmatch("\n") do lines = lines + 1 end
	local width = math.min(frameSize and frameSize.X or 200, #tostring(text) * (textSize or 12) * 0.55)
	return Vector2.new(width, math.max(16, lines * (textSize or 12) * 1.2))
end

local MarketplaceService = newService("MarketplaceService")
function MarketplaceService:GetProductInfo(_id)
	return { Name = "Mock Place", Description = "Mocked for smoke tests" }
end

local Players = newService("Players")
local localPlayer = InstanceLib.new("Folder")
localPlayer.Name = "LocalPlayer"
localPlayer.CharacterAdded = Signal()
localPlayer.Character = nil
Players.LocalPlayer = localPlayer

local CoreGui = newService("CoreGui")

local workspaceMock = newService("Workspace")
local camera = InstanceLib.new("Camera")
camera.CFrame = CFrame.new(0, 5, 0)
camera.ViewportSize = Vector2.new(1920, 1080)
function camera:ScreenPointToRay(x, y)
	return { Origin = Vector3.new(0, 0, 0), Direction = Vector3.new(0, 0, -1) }
end
workspaceMock.CurrentCamera = camera
function workspaceMock:Raycast(_origin, _direction, _params)
	return nil -- no geometry in the mock
end
function workspaceMock:GetServerTimeNow()
	return os.time()
end

local gameMock = {
	PlaceId = 1818,
	GameId = 0,
	Name = "Mock Game",
	CreatorId = 0,
}
function gameMock:GetService(name)
	if services[name] then return services[name] end
	local service
	if name == "TweenService" then service = TweenService
	elseif name == "RunService" then service = RunService
	elseif name == "UserInputService" then service = UserInputService
	elseif name == "HttpService" then service = HttpService
	elseif name == "TextService" then service = TextService
	elseif name == "MarketplaceService" then service = MarketplaceService
	elseif name == "Players" then service = Players
	elseif name == "CoreGui" then service = CoreGui
	else service = newService(name) end
	services[name] = service
	return service
end
function gameMock:IsLoaded() return true end

--------------------------------------------------------------------------------
--  File API (exercised through the real writefile/readfile code path)
--------------------------------------------------------------------------------

local files = {}
_G.__TBV_FILES = files

function makefolder(path)
	files[path] = "__DIR__"
	return true
end
function isfolder(path)
	return files[path] == "__DIR__"
end
function isfile(path)
	return type(files[path]) == "string" and files[path] ~= "__DIR__"
end
function writefile(path, contents)
	assert(type(contents) == "string", "writefile expects a string")
	files[path] = contents
	return true
end
function readfile(path)
	assert(isfile(path), "readfile: file does not exist: " .. tostring(path))
	return files[path]
end
function delfile(path)
	files[path] = nil
	return true
end
function listfiles(path)
	local out = {}
	local prefix = path:gsub("/$", "") .. "/"
	for key, value in pairs(files) do
		if value ~= "__DIR__" and key:sub(1, #prefix) == prefix and not key:sub(#prefix + 1):find("/") then
			out[#out + 1] = key
		end
	end
	return out
end

--------------------------------------------------------------------------------
--  Globals
--------------------------------------------------------------------------------

_G.Instance = InstanceLib
_G.Enum = Enum
_G.game = gameMock
_G.workspace = workspaceMock
_G.task = task
_G.Color3 = Color3
_G.Vector2 = Vector2
_G.Vector3 = Vector3
_G.UDim = UDim
_G.UDim2 = UDim2
_G.CFrame = CFrame
_G.RaycastParams = RaycastParams
_G.TweenInfo = TweenInfo
_G.ColorSequence = ColorSequence
_G.ColorSequenceKeypoint = ColorSequenceKeypoint
_G.NumberSequence = NumberSequence
_G.NumberSequenceKeypoint = NumberSequenceKeypoint

function _G.typeof(value)
	if type(value) == "table" then
		return value.__type or "table"
	end
	return type(value)
end

--------------------------------------------------------------------------------
--  Test driver hook
--------------------------------------------------------------------------------

--- Advance virtual time by dt, resume due tasks and fire frame events.
function _G.__TBV_STEP(dt)
	clock = clock + (dt or 1 / 60)

	-- Tweens that finished since the last frame notify their listeners here.
	flushTweens()

	local index = 1
	while index <= #scheduled do
		local entry = scheduled[index]
		if coroutine.status(entry.co) ~= "dead" and clock >= entry.wake then
			table.remove(scheduled, index)
			scheduleResume(entry.co, coroutine.resume(entry.co))
		else
			index = index + 1
		end
	end

	RunService.RenderStepped:Fire(dt or 1 / 60)
	RunService.Heartbeat:Fire(dt or 1 / 60)
end

--- Simulate a key press (used to test the UI hotkey and module binds).
function _G.__TBV_PRESS(keyName, processed)
	UserInputService.InputBegan:Fire({
		UserInputType = Enum.UserInputType.Keyboard,
		KeyCode = Enum.KeyCode[keyName],
	}, processed == true)
end

function _G.__TBV_CLOCK() return clock end

return true
