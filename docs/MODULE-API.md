# TBV v4 — module & option API

## Module definition

A module is a plain table. Copy `src/TBVv4/Modules/Templates/ModuleTemplate.lua`, then
add it to `src/TBVv4/Modules/Index.lua`.

```lua
local module = {
    Name        = "Feature Name",   -- card title AND the config key (renaming orphans saved values)
    Tab         = "Utility",        -- tab, created on demand
    Section     = "Display",        -- section inside the tab (default "Main")
    Side        = "Left",           -- "Left" or "Right" column (default "Left")
    Description = "Short hint",     -- small grey line under the title
    Default     = false,            -- enabled on first boot?

    Options  = function(module, ctx) end,  -- build widgets; called once
    OnEnable = function(module, ctx) end,  -- called when switched on
    OnDisable = function(module, ctx) end, -- called when switched off
}

return module
```

## `module` handle

Available as `self` (or the first parameter) inside `Options`, `OnEnable`, `OnDisable`.

| Method | Description |
|---|---|
| `module:AddToggle(data)` | switch with optional keybind chip |
| `module:AddSlider(data)` | numeric slider + type-in value |
| `module:AddDropdown(data)` | single or multi select |
| `module:AddColorPicker(data)` | HSV colour picker |
| `module:AddTextBox(data)` | free text |
| `module:AddButton(data)` | action button (holds no state) |
| `module:AddLabel(data)` | static or live-updating text |
| `module:AddOption(kind, data)` | the generic form of the above |
| `module:GetOption(flag)` | look up an option by flag at any time |
| `module:SetStatus(text)` | update the line under the card title |
| `module:SetEnabled(bool)` | programmatically enable/disable |
| `module.Options` / `module.OptionsByFlag` | option lists |
| `module.Enabled` | current state |

## `ctx` handle

The sandbox each module receives. Everything created through it is torn down on disable.

| Member | Description |
|---|---|
| `ctx:Connect(signal, fn)` | connect to a Roblox event; auto-disconnected on disable |
| `ctx:OnHeartbeat(fn, interval)` | throttled callback on the shared scheduler |
| `ctx:OnRender(fn, interval)` | same, on `RenderStepped` |
| `ctx:Raycast(origin, dir, params)` | `workspace:Raycast` wrapper |
| `ctx:RaycastParams(filter, filterType, ignoreWater)` | cached `RaycastParams` |
| `ctx:Notify(title, text, duration)` | toast |
| `ctx:DisconnectAll()` | manual teardown (rarely needed) |
| `ctx.Library`, `ctx.Theme`, `ctx.Utility`, `ctx.Config` | framework surfaces |
| `ctx.LocalPlayer`, `ctx.Camera` | common shortcuts |
| `ctx.<AnyService>` | `ctx.RunService`, `ctx.HttpService`, ... lazily resolved and cached |

### Option data

```lua
-- Toggle
{ Name = "Label", Flag = "Key", Default = false, CanBind = true,
  Callback = function(value) end }

-- Slider
{ Name = "Label", Flag = "Key", Min = 0, Max = 100, Default = 50,
  Decimals = 0, Suffix = "%", Callback = function(value) end }

-- Dropdown
{ Name = "Label", Flag = "Key", Options = { "A", "B" }, Default = "A",
  Multi = false, Callback = function(value) end }   -- Multi: value is an array

-- Colour picker
{ Name = "Label", Flag = "Key", Default = Color3.fromRGB(255, 20, 147),
  Callback = function(color) end }

-- Text box
{ Name = "Label", Flag = "Key", Default = "", Placeholder = "...",
  Callback = function(text) end }

-- Button
{ Name = "Press me", Callback = function() end }

-- Label
{ Name = "Readout text", Flag = "Key" }   -- :SetText() / :SetColor() at runtime
```

Notes:

* `Flag` defaults to `Name`. It is the config key — changing it orphans saved values.
* `Default` is also the reset value on first boot.
* Callbacks fire on user input **and** on profile load. Use
  `option:SetValue(v, true)` when you need to change a value without firing logic.
* Update an option's callback later by assigning to it, e.g.
  `self:GetOption("TextSize").Callback = function(v) label.TextSize = v end`.
* Dropdowns can be repopulated at runtime with `option:SetOptions({ ... })`.

## Config conversion reference

| Option | Stored as |
|---|---|
| Toggle | `true` / `false` |
| Slider | number |
| Dropdown | string, or array of strings when `Multi` |
| Colour picker | `"#RRGGBB"` |
| Text box | string |
| Button, Label | not stored |
| Toggle keybind | `Binds[flag] = "F3"` (KeyCode name) |

## Worked example

```lua
local module = {
    Name = "Distance Readout", Tab = "Utility", Section = "Developer", Default = false,
}

function module:Options(ctx)
    self:AddToggle({ Name = "Enabled", Flag = "On", Default = true })
    self:AddSlider({ Name = "Max distance", Flag = "Distance", Min = 10, Max = 500, Default = 100 })
    self:AddLabel({ Name = "Waiting...", Flag = "Readout" })
end

function module:OnEnable(ctx)
    -- Build params once; they are cached and reused for the lifetime of the module.
    local params = ctx:RaycastParams({ ctx.LocalPlayer.Character },
        Enum.RaycastFilterType.Blacklist, true)

    ctx:OnHeartbeat(function()
        if not self:GetOption("On").Value then return end
        local camera = workspace.CurrentCamera
        local result = ctx:Raycast(camera.CFrame.Position,
            camera.CFrame.LookVector * self:GetOption("Distance").Value, params)
        self:GetOption("Readout"):SetText(result
            and string.format("%s  %.1f studs", result.Instance.Name,
                (result.Position - camera.CFrame.Position).Magnitude)
            or "Nothing in range")
    end, 0.15)
end

function module:OnDisable(ctx)
    self:GetOption("Readout"):SetText("Waiting...")
end

return module
```

## House rules

1. Never call `RunService.Heartbeat:Connect` directly — use `ctx:OnHeartbeat`.
2. Destroy anything you create in `OnEnable` inside `OnDisable`.
3. Read options through `GetOption` *inside* loops so live edits apply immediately.
4. Keep heavy work off `ctx:OnRender`; prefer a throttled heartbeat.
5. Never reach into `Library.OptionTypes` or build Instances for the window yourself —
   ask the module handle, so layout and theming stay in one place.
