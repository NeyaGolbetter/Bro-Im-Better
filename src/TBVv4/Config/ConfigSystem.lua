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
