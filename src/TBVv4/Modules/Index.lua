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
