# TBV v4 — architecture

## 1. Dependency graph

Modules are resolved by a tiny `import()` shim (generated into the bundle by
`tools/build.py`). The graph is acyclic on purpose — it is what keeps the build
orderable and testable:

```
Theme                     (no dependencies)
  |
  +-- Utility             tweens, springs, schedulers, fades, raycasts
        |
        +-- Config        file API + JSON  (no dependencies)
        |
        +-- Options/*
        |     Row  Toggle  Slider  Dropdown  ColorPicker  TextBox  Button  Label
        |
        +-- Objects       Window, Tab, Section, ModuleCard, Toast, Watermark, Switch
              |
              +-- Library  registries, lifecycle, profiles, input, notifications
                    |
                    +-- Loading/LoadingScreen   (Theme + Utility only)
                    |
                    +-- Modules/Index  ->  module definitions (context injected)
                          |
                          +-- Main      boot sequence
```

Two rules keep this honest:

* **Widgets never import Library.** `Objects` and `Options/*` receive an `api` table,
  which *is* the Library instance. Writing `api.Library.X` anywhere in a widget is a
  bug (and was, twice, during development).
* **Feature modules import nothing.** They receive `ctx` and a `module` handle, so a
  module can be deleted, renamed or reordered without the library noticing.

## 2. Boot sequence (`Main.lua`)

| # | Step | Work |
|---|------|------|
| 1 | `Config:Init()` | feature-detect the file API, create `TBVv4/`, `TBVv4/Settings/`, `TBVv4/Configs/` |
| 2 | `Config:SetScope(game.PlaceId)` | profiles become per-game |
| 3 | `Utility:StartScheduler()` | the single Heartbeat + RenderStepped connection |
| 4 | Loading screen | created before the library so something is on screen within one frame |
| 5 | `Library.new()` | ScreenGui, layers, window, input binding, settings restore |
| 6 | Register modules | iterate `Modules/Index.lua`, build cards + options |
| 7 | Restore profile | `Deserialize` (existing profile) or `ApplyDefaults` (first boot) |
| 8 | Reveal | fade the loading screen out, animate the window in, notify |

Each step reports progress with a weight, so the bar reflects real work rather than
wall-clock time. A step that throws is caught, warned about, and the loading screen is
destroyed — a full-screen frame must never be left swallowing input.

## 3. GUI layers

The ScreenGui uses `ZIndexBehavior.Sibling`, so ordering is decided per branch:

| ZIndex | Layer | Contents |
|--------|-------|----------|
| 9 | `Glow` | soft accent halo behind the window |
| 10 | `Window` | header, tab strip, content columns |
| 30 | `Hud` | shared layer for module-drawn readouts (FPS, clock) |
| 40 | `Watermark` | draggable brand HUD |
| 50 | `Notifications` | bottom-right toast stack |
| 60 | `Overlay` | dropdown panels and colour picker popups |

Popups live in the overlay rather than inside their row: a dropdown parented to a card
inside a scrolling frame gets clipped by the scroller and renders underneath later
siblings, because ZIndex does not inherit through containers. Because the overlay sits
at `(0,0)` with the screen's size, popups are positioned with plain screen coordinates,
and they auto-flip above the anchor when they would run off the bottom.

## 4. Motion

| Concern | Implementation |
|---|---|
| Menu toggles, dropdowns, hover | `EasingStyle.Quart`, 0.18–0.32s |
| Window open, loading fade, toasts | `EasingStyle.Exponential`, 0.55s |
| Press feedback | `EasingStyle.Back` with a small squash |
| Toggle knobs | analytic damped spring (`k=210, d=24`), sub-stepped at 1/120s |
| Everything | `Theme.Speed` multiplier; `0` disables animation |

Tweens go through `Utility:Tween(instance, info, props, tag)`. The tag cancels the
previous tween with the same tag on the same instance, which is what stops rapid
hover in/out from leaving a pile of tweens fighting over one property.

Springs are stepped from one Heartbeat loop. A settled spring is removed from the step
list, so an idle UI costs nothing; `spring:Set()` re-registers it.

## 5. Performance decisions

1. **One Heartbeat, one RenderStepped.** Every background callback in the build rides
   `Utility:OnHeartbeat` / `:OnRender` with an optional interval, instead of opening its
   own connection. Disconnecting is O(1) (flag + compact), so a callback can disconnect
   itself mid-iteration safely.
2. **Throttling at the scheduler**, not in module code — an interval of 0.25s costs one
   accumulator compare per frame.
3. **No work when hidden.** Module callbacks are disconnected on disable, so turning a
   module off actually stops its loop.
4. **Debounced writes.** Dragging a slider fires dozens of change events; `Config:QueueSave`
   coalesces them into one write 1.5s after the last change.
5. **Cached `RaycastParams`.** Keyed by filter contents, so casting every frame does not
   rebuild and re-hash the filter table.
6. **Avoid redundant text writes.** Readouts compare against the last rendered string
   before touching `TextLabel.Text` — text re-layout is expensive and 60 writes/second
   of an unchanged "60" is pure waste.
7. **Cached service lookups** (`Utility:Service`) instead of repeated `game:GetService`.

## 6. Persistence

```
<workspace>/TBVv4/
  Settings/ui.json                  window position, accent, watermark, UI key
  Configs/<PlaceId>/<Profile>.json  one file per profile, per game
```

Profile shape:

```json
{
  "Version": 1,
  "Build": "TBV v4",
  "Profile": "Default",
  "Modules": {
    "FPS Counter": {
      "Enabled": true,
      "Options": { "UpdateRate": 0.5, "TextColor": "#FFB6C1" },
      "Binds":    { "ShowAverage": "F3" }
    }
  }
}
```

Each option type owns `Serialize`/`Deserialize`, so `Color3` becomes `"#RRGGBB"` and
`Enum.KeyCode` becomes its `Name` — JSON has neither type. Unknown modules and flags
are ignored on load, so renaming or removing a module never breaks an existing profile.

## 7. Module lifecycle

```
Register  -> Options() builds widgets (once)
          -> SetEnabled(true)  => OnEnable(module, ctx)
          -> SetEnabled(false) => ctx:DisconnectAll() => OnDisable(module, ctx)
```

`ctx:Connect`, `ctx:OnHeartbeat` and `ctx:OnRender` all register with the module's
context and are torn down on disable — that is the difference between "toggle it off
and the lag stops" and "toggle it off and the loop keeps running forever".

## 8. Testing strategy

Roblox cannot run in CI, so verification is layered:

1. **Parse** — `tools/check-syntax.js` runs a real Luau parser over every file and the
   bundle.
2. **Validate** — `tools/validate-api.py` checks every `Enum.X.Y` and every property set
   through `Utility:Create()` against Roblox's API dump (via `@rbxts/types`).
3. **Execute** — `tools/smoke/run.js` boots the bundle inside a mock Roblox environment
   (`tools/smoke/roblox_mock.lua`) under fengari: real instance hierarchy, property
   signals, GUI events, tweens, a virtual clock with a coroutine-backed `task` library,
   JSON, and a fake file API. It drives 900 frames, exercises every widget, toggles
   every module, and fails on any runtime warning.

The mock is a test double, not an emulator: it implements just the surface TBV v4
touches. It is deliberately strict — missing globals are not auto-stubbed, so a typo
shows up as a warning rather than silently passing.
