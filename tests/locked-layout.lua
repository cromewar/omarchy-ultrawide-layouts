#!/usr/bin/env lua

local here = arg[0]:match("^(.*)/[^/]+$") or "."
local layout = dofile(here .. "/../layouts/locked.lua")
layout._persistence_disabled = true

local passed, failed = 0, 0

local function equal(name, expected, actual, tolerance)
  local ok
  if type(expected) == "number" and type(actual) == "number" then
    ok = math.abs(expected - actual) <= (tolerance or 0.001)
  else
    ok = expected == actual
  end
  if ok then
    io.write(string.format("  \27[32mok\27[0m    %-38s %s\n", name, tostring(actual)))
    passed = passed + 1
  else
    io.write(string.format("  \27[31mFAIL\27[0m  %-38s expected %s, got %s\n",
      name, tostring(expected), tostring(actual)))
    failed = failed + 1
  end
end

local function box(x, y, w, h)
  return { x = x, y = y, w = w, h = h }
end

local function target(id, ws, initial, active)
  local value = {
    index = tonumber(id:match("%d+")) or 0,
    window = {
      address = id,
      stable_id = tonumber(id:match("%d+")) or 0,
      active = active or false,
      workspace = { id = ws },
    },
    box = initial,
  }
  function value:place(next_box)
    self.box = box(next_box.x, next_box.y, next_box.w, next_box.h)
  end
  return value
end

local function context(area, targets)
  return { area = area, targets = targets }
end

local function capture(ws, targets, area)
  layout.begin_capture(ws, #targets, os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or "")
  layout.recalculate(context(area, targets))
  return layout._state(ws)
end

local area = box(0, 0, 1200, 800)

io.write("\nLayout lock — sequential algorithm handoff\n")
layout._reset()
local handoff_left = target("0x20", 10, box(0, 0, 300, 800))
local handoff_center = target("0x21", 10, box(300, 0, 600, 800))
local handoff_right = target("0x22", 10, box(900, 0, 300, 800))
layout.begin_capture(10, 3, os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or "")
layout.recalculate(context(area, { handoff_left }))
equal("partial handoff does not finalize", nil, layout._state(10))
layout.recalculate(context(area, { handoff_left, handoff_center }))
equal("second partial handoff stays pending", nil, layout._state(10))
layout.recalculate(context(area, { handoff_left, handoff_center, handoff_right }))
equal("final transferred target commits capture", 3, layout._state(10).column_count)

io.write("\nLayout lock — capture and fixed vacancies\n")
layout._reset()
local left = target("0x1", 1, box(0, 0, 300, 800))
local center = target("0x2", 1, box(300, 0, 600, 800), true)
local right = target("0x3", 1, box(900, 0, 300, 800))
local state = capture(1, { left, center, right }, area)
equal("rightmost column is dynamic", "dynamic", state.assignments["0x3"].kind)
equal("center target is fixed", "fixed", state.assignments["0x2"].kind)
equal("three captured columns", 3, state.dynamic_zone)
equal("capture remembers column count", 3, state.column_count)

layout.recalculate(context(area, { left, center }))
equal("closed dynamic leaves right vacant", 900, center.box.x + center.box.w)
equal("fixed center keeps x", 300, center.box.x)
equal("fixed center keeps width", 600, center.box.w)

io.write("\nLayout lock — groups are one stable target\n")
layout._reset()
local group = {}
local grouped = target("0x10", 6, box(0, 0, 600, 800))
grouped.window.group = group
local group_side = target("0x11", 6, box(600, 0, 600, 800))
state = capture(6, { grouped, group_side }, area)
grouped.window = {
  address = "0x12",
  stable_id = 12,
  active = true,
  group = group,
  workspace = { id = 6 },
}
layout.recalculate(context(area, { grouped, group_side }))
equal("changing active group member keeps slot", 0, grouped.box.x)
equal("group remains one fixed assignment", 2, (function()
  local count = 0
  for _ in pairs(state.assignments) do count = count + 1 end
  return count
end)())

io.write("\nLayout lock — dynamic column compaction and insertion\n")
layout._reset()
left = target("0x1", 2, box(0, 0, 300, 800))
center = target("0x2", 2, box(300, 0, 600, 800))
local top = target("0x3", 2, box(900, 0, 300, 400))
local bottom = target("0x4", 2, box(900, 400, 300, 400))
state = capture(2, { left, center, top, bottom }, area)
equal("two initial dynamic members", 2, #state.dynamic_order)

layout.recalculate(context(area, { left, center, bottom }))
equal("remaining dynamic expands to full height", 800, bottom.box.h)
equal("remaining dynamic stays on right", 900, bottom.box.x)

local newcomer = target("0x5", 2, box(0, 0, 1, 1))
layout.recalculate(context(area, { left, center, bottom, newcomer }))
equal("new window joins dynamic column", "dynamic", state.assignments["0x5"].kind)
equal("dynamic stack gives first half", 400, bottom.box.h)
equal("dynamic stack gives second half", 400, newcomer.box.h)
equal("new window is below existing member", 400, newcomer.box.y)

io.write("\nLayout lock — dynamic-column reassignment\n")
left.window.active = true
center.window.active = false
bottom.window.active = false
newcomer.window.active = false
local result = layout.layout_msg(context(area, { left, center, bottom, newcomer }), "dynamic-focused")
equal("dynamic-focused succeeds", true, result)
equal("focused left becomes dynamic", "dynamic", state.assignments["0x1"].kind)
equal("old right member becomes fixed", "fixed", state.assignments["0x4"].kind)
equal("new dynamic zone has full height", 800, left.box.h)

io.write("\nLayout lock — recapture and workspace scaling\n")
center.window.active = true
left.window.active = false
center.box = box(250, 0, 650, 800)
left.box = box(0, 0, 250, 800)
bottom.box = box(900, 0, 300, 400)
newcomer.box = box(900, 400, 300, 400)
equal("recapture succeeds", true,
  layout.layout_msg(context(area, { left, center, bottom, newcomer }), "recapture"))
state = layout._state(2)
equal("recapture keeps right dynamic", "dynamic", state.assignments["0x4"].kind)

local doubled = box(100, 50, 2400, 1600)
layout.recalculate(context(doubled, { left, center, bottom, newcomer }))
equal("fixed x scales with work area", 600, center.box.x)
equal("fixed width scales with work area", 1300, center.box.w)
equal("work-area origin is respected", 100, left.box.x)

io.write("\nLayout lock — workspace isolation and session safety\n")
local other_a = target("0xa", 7, box(0, 0, 600, 800))
local other_b = target("0xb", 7, box(600, 0, 600, 800))
local other = capture(7, { other_a, other_b }, area)
equal("other workspace has separate state", 7, other.workspace)
equal("first workspace state remains", 2, layout._state(2).workspace)

layout._reset()
layout._persistence_disabled = false
local temp = os.tmpname()
os.remove(temp)
os.execute("mkdir -p " .. string.format("%q", temp))
layout._set_state_dir(temp)
local persisted_left = target("0x30", 8, box(0, 0, 600, 800))
local persisted_right = target("0x31", 8, box(600, 0, 600, 800))
capture(8, { persisted_left, persisted_right }, area)
layout._reset()
persisted_left.box = box(0, 0, 1200, 800)
persisted_right.box = box(0, 0, 1, 1)
layout.recalculate(context(area, { persisted_left, persisted_right }))
equal("same-session reload restores fixed box", 600, persisted_left.box.w)
equal("same-session reload restores dynamic box", 600, persisted_right.box.x)

local stale = io.open(temp .. "/9.lua", "w")
stale:write('return { version = 1, workspace = 9, session = "stale", assignments = {}, dynamic_order = {}, dynamic_box = {x=0,y=0,w=1,h=1} }\n')
stale:close()
local stale_target = target("0x9", 9, box(0, 0, 1200, 800))
layout.recalculate(context(area, { stale_target }))
equal("stale session falls back safely", 1200, stale_target.box.w)
os.remove(temp .. "/8.lua")
os.remove(temp .. "/9.lua")
os.remove(temp)

io.write("\n")
if failed == 0 then
  io.write(string.format("\27[32m%d Lua layout checks passed\27[0m\n\n", passed))
else
  io.write(string.format("\27[31m%d passed, %d failed\27[0m\n\n", passed, failed))
end
os.exit(failed > 0 and 1 or 0)
