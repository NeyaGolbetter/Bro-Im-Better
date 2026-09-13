/**
 * Headless smoke test for the bundled TBV v4 build.
 *
 * Roblox cannot run in CI, so we execute dist/TBVv4.lua inside fengari (a Lua
 * 5.3 VM written in JavaScript) against the mock environment in
 * roblox_mock.lua. That gives us a real boot: instances get created, tweens
 * fire, the task scheduler advances virtual time, profiles are written through
 * a fake file API, and every module is enabled and disabled.
 *
 * Setup:  npm install fengari
 * Usage:  node tools/smoke/run.js [--frames 900]
 */

const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring } = require("fengari");

const ROOT = path.resolve(__dirname, "..", "..");
const MOCK = path.join(__dirname, "roblox_mock.lua");
const BUNDLE = path.join(ROOT, "dist", "TBVv4.lua");

const args = process.argv.slice(2);
const framesArg = args.indexOf("--frames");
const FRAMES = framesArg >= 0 ? Number(args[framesArg + 1]) : 900;

function runLua(L, source, name) {
  const status = lauxlib.luaL_dostring(L, to_luastring(source));
  if (status !== lua.LUA_OK) {
    const error = lua.lua_tojsstring(L, -1) || "unknown error";
    throw new Error(`[${name}] ${error}`);
  }
}

function getGlobalNumber(L, name) {
  lua.lua_getglobal(L, to_luastring(name));
  const value = lua.lua_tointeger(L, -1);
  lua.lua_pop(L, 1);
  return value;
}

function callGlobal(L, name, ...args) {
  lua.lua_getglobal(L, to_luastring(name));
  for (const arg of args) {
    if (typeof arg === "number") lua.lua_pushnumber(L, arg);
    else if (typeof arg === "string") lua.lua_pushstring(L, to_luastring(arg));
    else if (typeof arg === "boolean") lua.lua_pushboolean(L, arg ? 1 : 0);
    else lua.lua_pushnil(L);
  }
  const status = lua.lua_pcall(L, args.length, 0, 0);
  if (status !== lua.LUA_OK) {
    const error = lua.lua_tojsstring(L, -1) || "unknown error";
    lua.lua_pop(L, 1);
    throw new Error(`${name} failed: ${error}`);
  }
}

function readKey(L, index) {
  const type = lua.lua_type(L, index);
  if (type === lua.LUA_TNUMBER) return String(lua.lua_tonumber(L, index));
  if (type === lua.LUA_TSTRING) return lua.lua_tojsstring(L, index);
  return `<${lua.lua_typename(L, type)}>`;
}

function dumpTable(L, globalName) {
  lua.lua_getglobal(L, to_luastring(globalName));
  if (lua.lua_type(L, -1) !== lua.LUA_TTABLE) {
    lua.lua_pop(L, 1);
    return {};
  }
  const result = {};
  lua.lua_pushnil(L);
  while (lua.lua_next(L, -2) !== 0) {
    // Never call lua_tojsstring on the KEY: it coerces numbers in place, which
    // corrupts the iterator and raises "invalid key to 'next'".
    const key = readKey(L, -2);
    const type = lua.lua_type(L, -1);
    if (type === lua.LUA_TSTRING) result[key] = lua.lua_tojsstring(L, -1);
    else if (type === lua.LUA_TNUMBER) result[key] = lua.lua_tonumber(L, -1);
    else if (type === lua.LUA_TBOOLEAN) result[key] = lua.lua_toboolean(L, -1);
    else result[key] = `<${lua.lua_typename(L, type)}>`;
    lua.lua_pop(L, 1);
  }
  lua.lua_pop(L, 1);
  return result;
}

function main() {
  if (!fs.existsSync(BUNDLE)) {
    console.error(`${path.relative(ROOT, BUNDLE)} missing - run: python3 tools/build.py`);
    process.exit(1);
  }

  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  // 1. Environment
  runLua(L, fs.readFileSync(MOCK, "utf8"), "mock");
  console.log("  ok    mock environment loaded");

  // 2. Boot the real bundle.
  runLua(L, fs.readFileSync(BUNDLE, "utf8"), "bundle");
  console.log("  ok    bundle executed (boot completed)");

  // 3. Drive frames so heartbeats, tweens and debounced saves all run.
  for (let i = 0; i < FRAMES; i++) {
    callGlobal(L, "__TBV_STEP", 1 / 60);
  }
  console.log(`  ok    ${FRAMES} frames simulated (~${(FRAMES / 60).toFixed(1)}s virtual time)`);

  // 4. Exercise input handling: UI hotkey and a module bind.
  callGlobal(L, "__TBV_PRESS", "RightShift");
  callGlobal(L, "__TBV_STEP", 1 / 60);
  callGlobal(L, "__TBV_PRESS", "RightShift");
  console.log("  ok    hotkey handled");

  // 5. Deep probe: exercise the interactive surface, not just registration.
  const probe = `
    local handle = TBVv4
    local report = {
      modules = 0,
      enabled = 0,
      options = 0,
      files = 0,
      profileFound = false,
      settingsFound = false,
      dropdowns = 0,
      pickers = 0,
      sliders = 0,
      toggles = 0,
      binds = 0,
      popupReopen = false,
      popupClosed = false,
    }

    if handle and handle.Library then
      local lib = handle.Library
      local dropdown = nil

      for _, name in ipairs(lib.ModuleOrder) do
        report.modules = report.modules + 1
        local mod = lib.Modules[name]
        if mod.Enabled then report.enabled = report.enabled + 1 end
        report.options = report.options + #mod.Options

        -- Full lifecycle: enable -> run -> disable -> restore.
        mod:SetEnabled(true)
        mod:SetEnabled(false)
        mod:SetEnabled(mod.Definition.Default == true)

        for _, option in ipairs(mod.Options) do
          if option.Type == "Dropdown" then
            report.dropdowns = report.dropdowns + 1
            dropdown = dropdown or option
            option:Open()
            option:Close()
            if option.Multi then option:SetValue({ tostring(option.Options[1]) }) end
          elseif option.Type == "ColorPicker" then
            report.pickers = report.pickers + 1
            option:Open()
            option:Close()
            option:SetValue(Color3.fromRGB(120, 40, 200))
          elseif option.Type == "Slider" then
            report.sliders = report.sliders + 1
            option:SetValue(option.Min)
            option:SetValue(option.Max)
            option:SetValue(option.Min + (option.Max - option.Min) / 2)
          elseif option.Type == "Toggle" then
            report.toggles = report.toggles + 1
            option:SetValue(true)
            option:SetValue(false)
            if option.SetBind then
              option:SetBind(Enum.KeyCode.F3)
              report.binds = report.binds + 1
            end
          elseif option.Type == "TextBox" then
            option:SetValue("smoke test")
          elseif option.Type == "Label" then
            option:SetText("updated by smoke test")
          end
        end
      end

      -- Window / shell interactions.
      for _, tabName in ipairs(lib.TabOrder) do lib:SelectTab(tabName) end
      lib:ApplySearch("fps")
      lib:ApplySearch("")
      lib:Notify("smoke", "notification path", 1)
      lib:ClosePopups()

      -- Popup registry: after a global dismiss a widget must still be able to
      -- reopen on the NEXT click (regression: isOpen was left true, so the
      -- first click only closed a panel that was already hidden).
      if dropdown then
        dropdown:Open()
        lib:ClosePopups()
        dropdown:Open()
        report.popupReopen = (lib.PopupOpen == true)
        dropdown:Close()
        report.popupClosed = (lib.PopupOpen == false)
      end
      lib:SetWatermarkLines({ "smoke", "TBV v4" })
      lib:SetWatermarkVisible(true)
      lib:ToggleVisible()
      lib:ToggleVisible()

      -- Profile round-trip.
      lib:SaveProfile("smoke")
      lib.Profile = "smoke"
      report.profileFound = lib:LoadProfile("smoke") == true
      lib:DeleteProfile("smoke")
    end

    if __TBV_FILES then
      for key, value in pairs(__TBV_FILES) do
        report.files = report.files + 1
        if key:find("TBVv4/Settings/") then report.settingsFound = true end
      end
    end
    return report
  `;

  lua.lua_getglobal(L, to_luastring("load"));
  lua.lua_pushstring(L, to_luastring(`return (function() ${probe} end)()`));
  const loaded = lua.lua_pcall(L, 1, 1, 0);
  if (loaded !== lua.LUA_OK) {
    throw new Error(`probe failed to compile: ${lua.lua_tojsstring(L, -1)}`);
  }
  const callStatus = lua.lua_pcall(L, 0, 1, 0);
  if (callStatus !== lua.LUA_OK) {
    throw new Error(`probe failed: ${lua.lua_tojsstring(L, -1)}`);
  }

  const results = {};
  lua.lua_pushnil(L);
  while (lua.lua_next(L, -2) !== 0) {
    const key = readKey(L, -2);
    const type = lua.lua_type(L, -1);
    if (type === lua.LUA_TNUMBER) results[key] = lua.lua_tonumber(L, -1);
    else if (type === lua.LUA_TBOOLEAN) results[key] = lua.lua_toboolean(L, -1);
    lua.lua_pop(L, 1);
  }
  lua.lua_pop(L, 1);

  const warnings = dumpTable(L, "__TBV_WARNINGS");
  const warningCount = Object.keys(warnings).length;

  console.log("\n  --- report -------------------------------------------------");
  console.log(`  modules registered : ${results.modules}`);
  console.log(`  options built      : ${results.options}`);
  console.log(`    toggles/sliders  : ${results.toggles} / ${results.sliders}`);
  console.log(`    dropdowns/pickers: ${results.dropdowns} / ${results.pickers}`);
  console.log(`    keybinds set     : ${results.binds}`);
  console.log(`  popup reopen       : ${results.popupReopen ? "ok" : "FAILED"} (closed cleanly: ${results.popupClosed ? "ok" : "FAILED"})`);
  console.log(`  modules enabled    : ${results.enabled}`);
  console.log(`  files written      : ${results.files}`);
  console.log(`  profile round-trip : ${results.profileFound ? "ok" : "FAILED"}`);
  console.log(`  settings written   : ${results.settingsFound ? "ok" : "missing"}`);
  console.log(`  runtime warnings   : ${warningCount}`);
  for (const key of Object.keys(warnings)) {
    console.log(`      - ${warnings[key]}`);
  }
  console.log("  ------------------------------------------------------------\n");

  const failures = [];
  if (!results.modules || results.modules < 5) failures.push("expected at least 5 modules");
  if (!results.options || results.options < 10) failures.push("expected at least 10 options");
  if (!results.dropdowns || !results.pickers) failures.push("expected dropdown and colour picker coverage");
  if (!results.sliders || !results.toggles) failures.push("expected slider and toggle coverage");
  if (!results.popupReopen) failures.push("dropdown did not reopen after a global dismiss");
  if (!results.popupClosed) failures.push("popup registry still flagged open after close");
  if (!results.profileFound) failures.push("profile round-trip failed");
  if (warningCount > 0) failures.push(`${warningCount} runtime warning(s)`);

  if (failures.length) {
    console.error("SMOKE TEST FAILED: " + failures.join("; "));
    process.exit(1);
  }

  console.log("SMOKE TEST PASSED");
  process.exit(0);
}

try {
  main();
} catch (error) {
  console.error("\nSMOKE TEST ERROR: " + error.message);
  process.exit(1);
}
