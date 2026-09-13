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
