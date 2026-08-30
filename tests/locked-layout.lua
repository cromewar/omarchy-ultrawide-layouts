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
local real_hl = hl
hl = { get_config = function() return { top = 5, right = 5, bottom = 5, left = 5 } end }
local visual_snapshot = {
  ["0x20"] = box(2, 2, 291, 796),
  ["0x21"] = box(307, 2, 586, 796),
  ["0x22"] = box(907, 2, 291, 796),
}
layout.begin_capture(10, 3, os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or "", visual_snapshot)
layout.recalculate(context(area, { handoff_left }))
equal("partial handoff does not finalize", nil, layout._state(10))
handoff_center.box = box(0, 0, 600, 800)
layout.recalculate(context(area, { handoff_left, handoff_center }))
equal("second partial handoff stays pending", nil, layout._state(10))
equal("transfer-time reflow cannot move center", 300, handoff_center.box.x)
handoff_right.box = box(600, 0, 600, 800)
layout.recalculate(context(area, { handoff_left, handoff_center, handoff_right }))
equal("final transferred target commits capture", 3, layout._state(10).column_count)
equal("snapshot preserves left width", 300, handoff_left.box.w)
equal("snapshot preserves center box", 600, handoff_center.box.w)
equal("snapshot preserves right x", 900, handoff_right.box.x)
hl = real_hl

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

io.write("\nLayout lock — explicit directional swaps\n")
layout._reset()
local swap_left = target("0x61", 13, box(0, 0, 300, 800))
local swap_center = target("0x62", 13, box(300, 0, 600, 800))
local swap_right = target("0x63", 13, box(900, 0, 300, 800))
local swap_state = capture(13, { swap_left, swap_center, swap_right }, area)

-- Hyprland implements SUPER + SHIFT + Arrow by swapping these two entries in
-- the custom layout's target vector, then asking the layout to recalculate.
layout.recalculate(context(area, { swap_left, swap_right, swap_center }))
equal("center swaps into right slot", 900, swap_center.box.x)
equal("right swaps into center slot", 300, swap_right.box.x)
equal("cross-zone swap transfers fixed role", "fixed", swap_state.assignments["0x63"].kind)
equal("cross-zone swap transfers dynamic role", "dynamic", swap_state.assignments["0x62"].kind)

layout.recalculate(context(area, { swap_right, swap_left, swap_center }))
equal("second swap moves right window left", 0, swap_right.box.x)
equal("second swap moves left window center", 300, swap_left.box.x)

-- Automatic removal after a manual swap still creates a vacancy instead of
-- moving either remaining window.
layout.recalculate(context(area, { swap_left, swap_center }))
equal("close after swap keeps center window", 300, swap_left.box.x)
equal("close after swap keeps right window", 900, swap_center.box.x)
local swap_replacement = target("0x64", 13, box(0, 0, 1, 1))
layout.recalculate(context(area, { swap_left, swap_center, swap_replacement }))
equal("new window fills manually vacated left slot", 0, swap_replacement.box.x)

io.write("\nLayout lock — explicit dynamic-stack swaps\n")
layout._reset()
local stack_left = target("0x71", 14, box(0, 0, 300, 800))
local stack_center = target("0x72", 14, box(300, 0, 600, 800))
local stack_top = target("0x73", 14, box(900, 0, 300, 400))
local stack_bottom = target("0x74", 14, box(900, 400, 300, 400))
capture(14, { stack_left, stack_center, stack_top, stack_bottom }, area)
layout.recalculate(context(area, { stack_left, stack_center, stack_bottom, stack_top }))
equal("bottom swaps into top stack position", 0, stack_bottom.box.y)
equal("top swaps into bottom stack position", 400, stack_top.box.y)

io.write("\nLayout lock — fixed vacancies are reusable\n")
layout._reset()
local vacancy_left = target("0x41", 11, box(0, 0, 300, 800))
local vacancy_center = target("0x42", 11, box(300, 0, 600, 800))
local vacancy_right = target("0x43", 11, box(900, 0, 300, 800))
local vacancy_state = capture(11, { vacancy_left, vacancy_center, vacancy_right }, area)
layout.recalculate(context(area, { vacancy_left, vacancy_right }))
equal("closing center leaves right in place", 900, vacancy_right.box.x)
equal("closing center records one vacancy", 1, #vacancy_state.vacancies)
local center_replacement = target("0x44", 11, box(0, 0, 1, 1))
layout.recalculate(context(area, { vacancy_left, center_replacement, vacancy_right }))
equal("new window fills center vacancy x", 300, center_replacement.box.x)
equal("new window fills center vacancy width", 600, center_replacement.box.w)
equal("replacement is fixed in reused slot", "fixed", vacancy_state.assignments["0x44"].kind)
layout.recalculate(context(area, { center_replacement, vacancy_right }))
local left_replacement = target("0x45", 11, box(0, 0, 1, 1))
layout.recalculate(context(area, { left_replacement, center_replacement, vacancy_right }))
equal("new window fills left vacancy", 0, left_replacement.box.x)
equal("right stays put through vacancy reuse", 900, vacancy_right.box.x)

io.write("\nLayout lock — intentional vacancy expansion\n")
layout._reset()
local expand_top = target("0x81", 15, box(0, 0, 300, 400), true)
local expand_bottom = target("0x82", 15, box(0, 400, 300, 400))
local expand_center = target("0x83", 15, box(300, 0, 600, 800))
local expand_right = target("0x84", 15, box(900, 0, 300, 800))
local expand_state = capture(15,
  { expand_top, expand_bottom, expand_center, expand_right }, area)
layout.recalculate(context(area, { expand_top, expand_center, expand_right }))
equal("closed lower-left slot becomes vacant", 1, #expand_state.vacancies)
local expand_context = context(area, { expand_top, expand_center, expand_right })
local conditional_swaps = 0
real_hl = hl
hl = {
  dsp = {
    layout = function(message) return { kind = "layout", message = message } end,
    window = {
      swap = function(options) return { kind = "swap", direction = options.direction } end,
    },
  },
  dispatch = function(action)
    if action.kind == "layout" then
      layout.layout_msg(expand_context, action.message)
    elseif action.kind == "swap" then
      conditional_swaps = conditional_swaps + 1
    end
  end,
}
equal("conditional up action succeeds", true, layout.directional_action("u"))
equal("wrong direction falls back to native swap", 1, conditional_swaps)
equal("wrong direction keeps upper-left height", 400, expand_top.box.h)
equal("conditional down action succeeds", true, layout.directional_action("d"))
equal("down expansion skips native swap", 1, conditional_swaps)
equal("expanded window fills full column height", 800, expand_top.box.h)
equal("expanded window keeps left x", 0, expand_top.box.x)
equal("expansion consumes the vacancy", 0, #expand_state.vacancies)
equal("expansion does not move center", 300, expand_center.box.x)
equal("expansion does not move right", 900, expand_right.box.x)
hl = real_hl

io.write("\nLayout lock — repeated vacancy expansion\n")
layout._reset()
local repeat_top = target("0x91", 16, box(0, 0, 300, 200), true)
local repeat_middle = target("0x92", 16, box(0, 200, 300, 200))
local repeat_bottom = target("0x93", 16, box(0, 400, 300, 400))
local repeat_center = target("0x94", 16, box(300, 0, 600, 800))
local repeat_right = target("0x95", 16, box(900, 0, 300, 800))
local repeat_state = capture(16,
  { repeat_top, repeat_middle, repeat_bottom, repeat_center, repeat_right }, area)
layout.recalculate(context(area, { repeat_top, repeat_center, repeat_right }))
equal("two closed stacked slots become vacant", 2, #repeat_state.vacancies)
equal("first down press consumes adjacent middle", true,
  layout.layout_msg(context(area, { repeat_top, repeat_center, repeat_right }),
    "fill-vacancy d"))
equal("first down press grows through middle", 400, repeat_top.box.h)
equal("second down press consumes adjacent bottom", true,
  layout.layout_msg(context(area, { repeat_top, repeat_center, repeat_right }),
    "fill-vacancy d"))
equal("second down press fills column", 800, repeat_top.box.h)
equal("both stacked vacancies are consumed", 0, #repeat_state.vacancies)

io.write("\nLayout lock — config reload handoff is not a close\n")
-- A reload re-runs the provider chunk, so its in-memory state is gone and the
-- saved file is read back while Hyprland transfers the targets one at a time.
layout._reset()
layout._persistence_disabled = false
local reload_dir = os.tmpname()
os.remove(reload_dir)
os.execute("mkdir -p " .. string.format("%q", reload_dir))
layout._set_state_dir(reload_dir)
local reload_left = target("0x51", 12, box(0, 0, 300, 800))
local reload_center = target("0x52", 12, box(300, 0, 600, 800))
local reload_right = target("0x53", 12, box(900, 0, 300, 800))
capture(12, { reload_left, reload_center, reload_right }, area)
for _, reload_target in ipairs({ reload_left, reload_center, reload_right }) do
  reload_target.window.mapped = true
  reload_target.window.floating = false
  reload_target.window.fullscreen = 0
end
real_hl = hl
hl = {
  get_workspace_windows = function()
    return { reload_left.window, reload_center.window, reload_right.window }
  end,
}
layout._reset()
layout.recalculate(context(area, { reload_left }))
local reload_state = layout._state(12)
equal("partial reload keeps unseen center assignment", "fixed", reload_state.assignments["0x52"].kind)
equal("partial reload keeps unseen dynamic assignment", "dynamic", reload_state.assignments["0x53"].kind)
equal("partial reload creates no false vacancy", 0, #reload_state.vacancies)
layout.recalculate(context(area, { reload_left, reload_right }))
equal("second transfer still keeps center", "fixed", reload_state.assignments["0x52"].kind)
layout.recalculate(context(area, { reload_right, reload_left, reload_center }))
equal("reload order change keeps left assignment", 0, reload_left.box.x)
equal("reload order change keeps center assignment", 300, reload_center.box.x)
equal("reload order change keeps right assignment", 900, reload_right.box.x)
equal("reload order change is not a swap", "0x53", reload_state.dynamic_order[1])

-- A window closed between the save and the reload must not hold the handoff
-- open: Hyprland's window list bounds how many targets can still arrive.
layout._reset()
hl = {
  get_workspace_windows = function()
    return { reload_left.window, reload_right.window }
  end,
}
layout.recalculate(context(area, { reload_left, reload_right }))
reload_state = layout._state(12)
equal("missing window ends the handoff", 1, #reload_state.vacancies)
equal("missing window's slot is vacated", "0x52", reload_state.vacancies[1].former)
hl = real_hl
os.remove(reload_dir .. "/12.lua")
os.remove(reload_dir)
layout._persistence_disabled = true

io.write("\nLayout lock — a close is a close, even while Hyprland still lists the window\n")
-- CWindow::unmapWindow removes the layout target before it clears the mapped
-- flag, so during the recalculate a close triggers the window is still in the
-- workspace list. That must not be mistaken for a reload handoff.
layout._reset()
local close_left = target("0x101", 17, box(0, 0, 300, 800))
local close_center = target("0x102", 17, box(300, 0, 600, 800))
local close_top = target("0x103", 17, box(900, 0, 300, 400))
local close_bottom = target("0x104", 17, box(900, 400, 300, 400))
local close_state = capture(17, { close_left, close_center, close_top, close_bottom }, area)
for _, t in ipairs({ close_left, close_center, close_top, close_bottom }) do
  t.window.mapped = true
  t.window.floating = false
  t.window.fullscreen = 0
end
real_hl = hl
hl = {
  get_workspace_windows = function()
    return { close_left.window, close_center.window, close_top.window, close_bottom.window }
  end,
}
layout.recalculate(context(area, { close_left, close_center, close_bottom }))
equal("closed dynamic member compacts at once", 800, close_bottom.box.h)
equal("closed dynamic member leaves the order", 1, #close_state.dynamic_order)
layout.recalculate(context(area, { close_left, close_bottom }))
equal("closed fixed slot is vacated at once", 1, #close_state.vacancies)
equal("vacancy remembers who left", "0x102", close_state.vacancies[1].former)
equal("left window does not move", 0, close_left.box.x)
hl = real_hl

io.write("\nLayout lock — a remapped window gets its own slot back\n")
-- GTK clients unmap and remap a toplevel without the process going anywhere;
-- Hyprland reports that as a close plus a new window with the same identity.
layout.recalculate(context(area, { close_bottom }))
equal("two vacancies after a second close", 2, #close_state.vacancies)
local remapped_center = target("0x102", 17, box(0, 0, 1, 1))
layout.recalculate(context(area, { close_bottom, remapped_center }))
equal("remapped window takes its own slot", 300, remapped_center.box.x)
equal("older vacancy is left for a stranger", 1, #close_state.vacancies)
local stranger = target("0x105", 17, box(0, 0, 1, 1))
layout.recalculate(context(area, { close_bottom, remapped_center, stranger }))
equal("stranger takes the oldest vacancy", 0, stranger.box.x)
equal("no vacancies remain", 0, #close_state.vacancies)

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

io.write("\nLayout lock — dynamic-focused folds vacancies in its column\n")
layout._reset()
local fold_top = target("0x111", 18, box(0, 0, 300, 400), true)
local fold_bottom = target("0x112", 18, box(0, 400, 300, 400))
local fold_center = target("0x113", 18, box(300, 0, 600, 800))
local fold_right = target("0x114", 18, box(900, 0, 300, 800))
local fold_state = capture(18, { fold_top, fold_bottom, fold_center, fold_right }, area)
layout.recalculate(context(area, { fold_top, fold_center, fold_right }))
equal("closed lower-left leaves a vacancy", 1, #fold_state.vacancies)
equal("dynamic-focused on the left column succeeds", true,
  layout.layout_msg(context(area, { fold_top, fold_center, fold_right }), "dynamic-focused"))
equal("vacancy in the new dynamic column is absorbed", 0, #fold_state.vacancies)
equal("dynamic zone spans the whole column", 800, fold_top.box.h)
local fold_new = target("0x115", 18, box(0, 0, 1, 1))
layout.recalculate(context(area, { fold_top, fold_center, fold_right, fold_new }))
equal("new window stacks under the focused one", 400, fold_new.box.y)
equal("stacked windows share the column", 400, fold_top.box.h)
equal("old dynamic column is now fixed", "fixed", fold_state.assignments["0x114"].kind)

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
local real_execute = os.execute
os.execute = function() return nil, "No child processes", 10 end
local persisted_left = target("0x30", 8, box(0, 0, 600, 800))
local persisted_right = target("0x31", 8, box(600, 0, 600, 800))
capture(8, { persisted_left, persisted_right }, area)
os.execute = real_execute
local persisted_file = io.open(temp .. "/8.lua", "r")
equal("embedded-Lua child status does not block persistence", true, persisted_file ~= nil)
if persisted_file then persisted_file:close() end
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
