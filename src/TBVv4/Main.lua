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
