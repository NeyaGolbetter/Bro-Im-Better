# TBV v4

A clean-room Roblox Luau **UI framework + module system**, built as the foundation for a
rebranded "TBV v4" script. Purple/pink theme, Gotham typography, TweenService motion,
an animated boot screen, per-game profiles, and a module architecture designed so
features can be added without touching the library.

```
   deep purple #8A2BE2  ->  neon pink #FF1493      on  dark slate #120E16
```

---

## What is (and is not) in this repository

**Included** — the framework layer:

| Area | What you get |
|---|---|
| UI library | Window, vertical tab strip, two-column sections, module cards, search, keybinds, notifications, watermark, HUD layer, overlay-hosted popups |
| Widgets | Toggle (spring-driven), Slider, Dropdown (single/multi), Colour picker (HSV), Text box, Button, Label |
| Theme | One token file (colours, fonts, easing, timing) with live re-theming via `Theme:SetAccent()` |
| Loading screen | Glowing pulsing "TBV v4" wordmark, gradient progress bar, percentage, dynamic status text, exponential fade-out |
| Config | `writefile`/`readfile`/`isfolder`/`makefolder` with automatic in-memory fallback, debounced writes, per-game scoping, JSON profiles |
| Module system | Declarative module definitions, managed lifecycle (auto-disconnect on disable), shared throttled scheduler |
| Raycasting | `workspace:Raycast()` + cached `RaycastParams`, with a migration table off the deprecated `FindPartOnRay` family |
| Tooling | Bundler, Luau syntax gate, Roblox API validator, headless smoke test, upstream rebrand script |

**Not included** — modules whose purpose is to gain an unfair advantage over other
people in online games (aimbot/killaura, ESP and tracers, speed/fly/velocity
manipulation) and anti-cheat bypass code. The framework is deliberately feature-agnostic:
it ships with legitimate utility modules (FPS readout, clock, raycast probe, interface
settings, profile manager) that exercise every widget and every lifecycle path, and a
documented template for adding more.

> Note: this repository contained only a README when work started — there was no
> upstream VapeV4 source checked in to modify. Everything here is written from scratch.
> To rebrand an existing upstream tree, use `tools/rebrand.py` (see below).

---

## Quick start

```bash
python3 tools/build.py            # bundle src/ -> dist/TBVv4.lua
```

Load `dist/TBVv4.lua` with your executor. The build is a single self-contained Luau file
with an internal module resolver — no `HttpGet`, no external requires.

* **Hide/show the interface:** `RightShift` (configurable, see Interface → UI key)
* **Toggle a module:** click the switch, or right-click the card header
* **Expand a module:** click the card header
* **Bind a key:** click the key chip on a toggle, then press a key (`Esc` clears)
* **Save/load:** Interface tab → Profiles

### Layout on disk

```
src/TBVv4/
  Main.lua                     entry point / boot sequence
  Library/
    Theme.lua                  design tokens (colours, fonts, easing, timing)
    Utility.lua                tweens, springs, schedulers, fades, raycasts
    Objects.lua                every frame: window, tab, section, card, toast
    Library.lua                orchestrator: registries, lifecycle, profiles
    Options/                   Row, Toggle, Slider, Dropdown, ColorPicker,
                               TextBox, Button, Label
  Loading/LoadingScreen.lua    animated boot screen
  Config/ConfigSystem.lua      file API + JSON persistence
  Modules/
    Index.lua                  the registry - add your module here
    Utility/                   FPSCounter, Clock, RaycastProbe, Interface, Profiles
    Templates/ModuleTemplate.lua
tools/                         build, validate, smoke test, rebrand
docs/                          architecture + module API
dist/TBVv4.lua                 generated distributable
```

---

## Adding a module

Two steps. Copy `Modules/Templates/ModuleTemplate.lua`, then list it in `Modules/Index.lua`:

```lua
local module = {
    Name        = "My Feature",
    Tab         = "Utility",
    Section     = "Display",
    Side        = "Left",
    Description = "One line shown under the title",
    Default     = false,
}

function module:Options(ctx)
    self:AddToggle({ Name = "Enable thing", Flag = "Thing", Default = true })
    self:AddSlider({ Name = "Range", Flag = "Range", Min = 0, Max = 100, Default = 25 })
end

function module:OnEnable(ctx)
    ctx:OnHeartbeat(function(dt)
        -- throttled, and disconnected automatically when the module is disabled
    end, 0.25)
end

function module:OnDisable(ctx)
    -- destroy anything you created in OnEnable
end

return module
```

Tabs, sections, cards, config serialisation and search are all derived from that table.
Full reference: [`docs/MODULE-API.md`](docs/MODULE-API.md).

---

## Theming

Every visual value lives in `src/TBVv4/Library/Theme.lua`. The shipped palette:

| Token | Hex | Use |
|---|---|---|
| `Background` | `#120E16` | window background |
| `Surface` / `SurfaceAlt` | `#18111D` / `#1E1524` | cards, hovered cards |
| `SurfaceTop` | `#221829` | title bar, tab strip |
| `AccentFrom` → `AccentTo` | `#8A2BE2` → `#FF1493` | the brand gradient |
| `Violet` / `PinkLight` | `#A020F0` / `#FFB6C1` | secondary fills and highlights |
| `Text` / `TextMuted` | `#FFFFFF` / `#E6E6FA` | labels / muted text |

Fonts are Roblox built-ins only (no asset downloads, no fallback flash):
`FredokaOne` for the wordmark, `GothamBold` for titles, `GothamMedium` for body,
`Code` for numbers. Motion is `Quart` for UI movement and `Exponential` for the big
moves (window open, loading fade); `Theme.Speed` scales every duration so animation can
be slowed down or disabled from the Interface module.

Changing the accent at runtime repaints every registered gradient:

```lua
Theme:SetAccent(Color3.fromHex("#8A2BE2"), Color3.fromHex("#FF1493"))
```

---

## Tools

```bash
python3 tools/build.py --check                 # dependency order + size, no write
python3 tools/build.py                         # -> dist/TBVv4.lua

npm install luau-parser
node tools/check-syntax.js                     # parse every source + the bundle

npm install @rbxts/types
python3 tools/validate-api.py                  # Enums + instance properties vs. the
                                               # real Roblox API surface

npm install fengari
node tools/smoke/run.js                        # boot the bundle headlessly
```

### Rebranding an upstream tree

```bash
python3 tools/rebrand.py ../VapeV4ForRoblox --dry-run   # show the plan
python3 tools/rebrand.py ../VapeV4ForRoblox --report rebrand.json
```

It rewrites every case-insensitive variant of the old brand, renames the `vape/`
config root to `TBVv4/`, converts `.vape` profile files to `.json`, renames
files/directories, and skips binaries. It is context-aware: identifiers become
`TBVv4` (valid Lua) while comments and strings become `TBV v4`.

---

## Verification

The build is checked three ways (all reproduced in CI):

1. **Syntax** — 22 modules and the bundled output parse under a real Luau parser.
2. **API** — every `Enum.X.Y` reference and all 762 property assignments made through
   `Utility:Create()` are validated against Roblox's own API dump (via `@rbxts/types`).
   Roblox silently ignores writes to properties that do not exist, so this catches a
   whole class of invisible bugs.
3. **Smoke test** — the bundle boots inside a mock Roblox environment: 5 modules
   register, 31 options are built and driven (toggles flipped, sliders dragged,
   dropdowns and colour pickers opened/closed, keybinds set), every module is
   enabled and disabled, profiles round-trip through the file API, and the run
   finishes with zero runtime warnings.

Bugs these caught during development, all fixed: infinite recursion between
`SelectTab` and the tab selection callback; widgets reaching through `api.Library`
when `api` *is* the library; a stale `stopListening` reference in the keybind
handler; and nil holes left in the scheduler array when a callback disconnects
itself mid-iteration.

---

## Compatibility notes

* **File API** — `isfolder`/`makefolder`/`writefile`/`readfile`/`isfile`/`listfiles`/`delfile`
  are feature-detected once at boot. If they are missing the build falls back to an
  in-memory store and warns once; settings then last for the session instead of
  breaking the UI.
* **GUI container** — `gethui()` → `CoreGui` → `PlayerGui`, whichever is available.
* **Fonts** — the Gotham family is a legacy Roblox font set. If a future client removes
  it, swap the three `Theme.Fonts` entries for the current `BuilderSans` equivalents;
  nothing else references fonts directly.
* **Motion** — set Interface → Animation speed to `0` on low-end hardware; every
  tween duration is multiplied by `Theme.Speed`.
