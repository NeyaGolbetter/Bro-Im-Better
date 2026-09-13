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
