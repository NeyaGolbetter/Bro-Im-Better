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
