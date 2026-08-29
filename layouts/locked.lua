-- Stable per-workspace layout slots for omarchy-ultrawide-layouts.
--
-- Hyprland hands a custom Lua layout the logical boxes produced by the old
-- layout while it transfers targets to the new one.  We capture those boxes,
-- keep every non-dynamic target in its slot, and only restack the chosen
-- dynamic column.  Boxes are stored relative to ctx.area so a monitor or work
-- area resize preserves the shape instead of preserving stale pixels.

local M = {}

local LAYOUT_NAME = "cromewar-ultrawide-lock"
local VERSION = 1
local COLUMN_TOLERANCE = 8

local state_home = os.getenv("XDG_STATE_HOME")
if not state_home or state_home == "" then
  state_home = (os.getenv("HOME") or "") .. "/.local/state"
end

local state_dir = state_home .. "/omarchy/layout-locks"
local states = {}
local requests = {}

local function copy_box(box)
  return { x = box.x, y = box.y, w = box.w, h = box.h }
end

local function normalized(box, area)
  if area.w == 0 or area.h == 0 then
    return { x = 0, y = 0, w = 1, h = 1 }
  end
  return {
    x = (box.x - area.x) / area.w,
    y = (box.y - area.y) / area.h,
    w = box.w / area.w,
    h = box.h / area.h,
  }
end

local function denormalized(box, area)
  return {
    x = area.x + box.x * area.w,
    y = area.y + box.y * area.h,
    w = box.w * area.w,
    h = box.h * area.h,
  }
end

local function window_id(window, fallback)
  if not window then return "target:" .. tostring(fallback or "unknown") end
  -- A group is one tiled target. Its active member can change without the
  -- target moving, so identify the group object rather than whichever member
  -- happens to be exposed as target.window right now.
  if window.group then
    return "group:" .. tostring(window.group)
  end
  if window.address and window.address ~= "" then
    return tostring(window.address)
  end
  return "stable:" .. tostring(window.stable_id or fallback or "unknown")
end

local function target_id(target)
  return window_id(target.window, target.index)
end

local function workspace_id(ctx)
  for _, target in ipairs(ctx.targets) do
    local window = target.window
    if window and window.workspace and window.workspace.id then
      return tonumber(window.workspace.id)
    end
  end
  return nil
end

local function sorted_keys(value)
  local result = {}
  for key in pairs(value) do
    result[#result + 1] = key
  end
  table.sort(result, function(a, b)
    if type(a) == type(b) then return a < b end
    return tostring(a) < tostring(b)
  end)
  return result
end

local function serialize(value, indent)
  indent = indent or ""
  local kind = type(value)
  if kind == "string" then return string.format("%q", value) end
  if kind == "number" or kind == "boolean" then return tostring(value) end
  if kind ~= "table" then return "nil" end

  local child = indent .. "  "
  local lines = { "{" }
  for _, key in ipairs(sorted_keys(value)) do
    local rendered_key
    if type(key) == "string" and key:match("^[%a_][%w_]*$") then
      rendered_key = key
    else
      rendered_key = "[" .. serialize(key) .. "]"
    end
    lines[#lines + 1] = child .. rendered_key .. " = " .. serialize(value[key], child) .. ","
  end
  lines[#lines + 1] = indent .. "}"
  return table.concat(lines, "\n")
end

local function state_path(ws)
  return state_dir .. "/" .. tostring(ws) .. ".lua"
end

local function persist(state)
  if M._persistence_disabled then return true end
  -- The command that begins a capture creates this directory before asking
  -- Hyprland to switch algorithms. Do not use os.execute("mkdir -p") here:
  -- Hyprland reaps the child process itself, so embedded Lua can receive
  -- `nil, "No child processes", 10` even though mkdir succeeded.
  local path = state_path(state.workspace)
  local temporary = path .. ".tmp"
  local file, open_error = io.open(temporary, "w")
  if not file then return false, "open " .. temporary .. ": " .. tostring(open_error) end
  local written, write_error = file:write("return ", serialize(state), "\n")
  local closed, close_error = file:close()
  if not written or not closed then
    os.remove(temporary)
    return false, "write " .. temporary .. ": " .. tostring(write_error or close_error)
  end
  local renamed, rename_error = os.rename(temporary, path)
  if not renamed then
    os.remove(temporary)
    return false, "rename " .. temporary .. ": " .. tostring(rename_error)
  end
  return true
end

local function persist_or_error(state)
  local ok, detail = persist(state)
  if not ok then
    error("could not persist layout lock state for workspace " .. tostring(state.workspace) ..
      ": " .. tostring(detail))
  end
end

local function load_state(ws)
  if states[ws] then return states[ws] end
  local loader = loadfile(state_path(ws), "t", {})
  if not loader then return nil end
  local ok, state = pcall(loader)
  if not ok or type(state) ~= "table" or state.version ~= VERSION then return nil end
  if state.session ~= (os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or "") then return nil end
  states[ws] = state
  return state
end

local function capture_box(state, target, area)
  local id = target_id(target)
  if not state.capture[id] then
    state.capture[id] = normalized(target.box, area)
    state.capture_order[#state.capture_order + 1] = id
  end
end

local function snapshot_workspace(ws)
  if not hl or not hl.get_workspace_windows then return nil end
  local ok, windows = pcall(hl.get_workspace_windows, ws)
  if not ok or type(windows) ~= "table" then return nil end
  local snapshot = {}
  for _, window in ipairs(windows) do
    local at, size = window.at, window.size
    if window.mapped and not window.floating and (window.fullscreen or 0) == 0 and
        at and size and at.x and at.y and size.x and size.y then
      local id = window_id(window)
      local existing = snapshot[id]
      -- Groups expose every member here but only one layout target. Prefer its
      -- visible member; all members normally share the same visual rectangle.
      if not existing or (existing.hidden and not window.hidden) then
        snapshot[id] = {
          x = at.x,
          y = at.y,
          w = size.x,
          h = size.y,
          hidden = window.hidden or false,
        }
      end
    end
  end
  return next(snapshot) and snapshot or nil
end

local function workspace_target_ids(ws)
  if not hl or not hl.get_workspace_windows then return nil end
  local ok, windows = pcall(hl.get_workspace_windows, ws)
  if not ok or type(windows) ~= "table" then return nil end
  local present = {}
  for _, window in ipairs(windows) do
    if window.mapped and not window.floating and (window.fullscreen or 0) == 0 then
      present[window_id(window)] = true
    end
  end
  return present
end

local function overlaps(a1, a2, b1, b2)
  return math.min(a2, b2) - math.max(a1, b1) > 1
end

local function neighbor_edge(box, boxes, side)
  local chosen
  for _, other in pairs(boxes) do
    if other ~= box then
      if side == "left" and other.x + other.w <= box.x + COLUMN_TOLERANCE and
          overlaps(other.y, other.y + other.h, box.y, box.y + box.h) then
        chosen = chosen and math.max(chosen, other.x + other.w) or (other.x + other.w)
      elseif side == "right" and other.x >= box.x + box.w - COLUMN_TOLERANCE and
          overlaps(other.y, other.y + other.h, box.y, box.y + box.h) then
        chosen = chosen and math.min(chosen, other.x) or other.x
      elseif side == "top" and other.y + other.h <= box.y + COLUMN_TOLERANCE and
          overlaps(other.x, other.x + other.w, box.x, box.x + box.w) then
        chosen = chosen and math.max(chosen, other.y + other.h) or (other.y + other.h)
      elseif side == "bottom" and other.y >= box.y + box.h - COLUMN_TOLERANCE and
          overlaps(other.x, other.x + other.w, box.x, box.x + box.w) then
        chosen = chosen and math.min(chosen, other.y) or other.y
      end
    end
  end
  return chosen
end

local function configured_inner_gaps()
  local result = { top = 0, right = 0, bottom = 0, left = 0 }
  if not hl or not hl.get_config then return result end
  local ok, value = pcall(hl.get_config, "general.gaps_in")
  if not ok or type(value) ~= "table" then return result end
  for side in pairs(result) do result[side] = tonumber(value[side]) or 0 end
  return result
end

local function prepare_snapshot(state, area, seed)
  local boxes = state.snapshot
  if not boxes then return false end

  local min_x, min_y, max_x, max_y
  for _, box in pairs(boxes) do
    min_x = min_x and math.min(min_x, box.x) or box.x
    min_y = min_y and math.min(min_y, box.y) or box.y
    max_x = max_x and math.max(max_x, box.x + box.w) or (box.x + box.w)
    max_y = max_y and math.max(max_y, box.y + box.h) or (box.y + box.h)
  end

  local gaps = configured_inner_gaps()
  local inset = {
    left = math.max(0, min_x - area.x),
    top = math.max(0, min_y - area.y),
    right = math.max(0, area.x + area.w - max_x),
    bottom = math.max(0, area.y + area.h - max_y),
  }

  -- The first target transferred by Hyprland still has its original logical
  -- box. Use it to separate client borders/reserved space from gaps precisely.
  if seed then
    local visual = boxes[target_id(seed)]
    local logical = seed.box
    if visual and logical then
      local touches_left = math.abs(logical.x - area.x) <= COLUMN_TOLERANCE
      local touches_top = math.abs(logical.y - area.y) <= COLUMN_TOLERANCE
      local touches_right = math.abs(logical.x + logical.w - area.x - area.w) <= COLUMN_TOLERANCE
      local touches_bottom = math.abs(logical.y + logical.h - area.y - area.h) <= COLUMN_TOLERANCE
      inset.left = math.max(0, visual.x - logical.x - (touches_left and 0 or gaps.left))
      inset.top = math.max(0, visual.y - logical.y - (touches_top and 0 or gaps.top))
      inset.right = math.max(0, logical.x + logical.w - visual.x - visual.w -
        (touches_right and 0 or gaps.right))
      inset.bottom = math.max(0, logical.y + logical.h - visual.y - visual.h -
        (touches_bottom and 0 or gaps.bottom))
    end
  end

  local logical_boxes = {}
  for id, box in pairs(boxes) do
    local left_neighbor = neighbor_edge(box, boxes, "left")
    local right_neighbor = neighbor_edge(box, boxes, "right")
    local top_neighbor = neighbor_edge(box, boxes, "top")
    local bottom_neighbor = neighbor_edge(box, boxes, "bottom")

    local left = area.x
    if left_neighbor then
      left = ((box.x - gaps.left - inset.left) +
        (left_neighbor + gaps.right + inset.right)) / 2
    end
    local right = area.x + area.w
    if right_neighbor then
      right = ((box.x + box.w + gaps.right + inset.right) +
        (right_neighbor - gaps.left - inset.left)) / 2
    end
    local top = area.y
    if top_neighbor then
      top = ((box.y - gaps.top - inset.top) +
        (top_neighbor + gaps.bottom + inset.bottom)) / 2
    end
    local bottom = area.y + area.h
    if bottom_neighbor then
      bottom = ((box.y + box.h + gaps.bottom + inset.bottom) +
        (bottom_neighbor - gaps.top - inset.top)) / 2
    end
    logical_boxes[id] = normalized({ x = left, y = top, w = right - left, h = bottom - top }, area)
  end

  local order = sorted_keys(logical_boxes)
  table.sort(order, function(a, b)
    local aa, bb = logical_boxes[a], logical_boxes[b]
    if math.abs(aa.x - bb.x) > 0.0001 then return aa.x < bb.x end
    if math.abs(aa.y - bb.y) > 0.0001 then return aa.y < bb.y end
    return a < b
  end)
  state.capture = logical_boxes
  state.capture_order = order
  state.snapshot = nil
  return true
end

local function union_boxes(ids, boxes)
  local x1, y1, x2, y2
  for _, id in ipairs(ids) do
    local box = boxes[id]
    if box then
      x1 = x1 and math.min(x1, box.x) or box.x
      y1 = y1 and math.min(y1, box.y) or box.y
      x2 = x2 and math.max(x2, box.x + box.w) or (box.x + box.w)
      y2 = y2 and math.max(y2, box.y + box.h) or (box.y + box.h)
    end
  end
  if not x1 then return { x = 0, y = 0, w = 1, h = 1 } end
  return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

local function finalize_capture(state, area)
  local tolerance = COLUMN_TOLERANCE / math.max(area.w, 1)
  local columns = {}

  for _, id in ipairs(state.capture_order) do
    local box = state.capture[id]
    local chosen
    for _, column in ipairs(columns) do
      if math.abs(column.x - box.x) <= tolerance then
        chosen = column
        break
      end
    end
    if not chosen then
      chosen = { x = box.x, ids = {} }
      columns[#columns + 1] = chosen
    end
    chosen.ids[#chosen.ids + 1] = id
  end

  table.sort(columns, function(a, b) return a.x < b.x end)
  local dynamic = columns[#columns]
  state.column_count = #columns
  state.dynamic_zone = #columns
  state.dynamic_box = union_boxes(dynamic and dynamic.ids or {}, state.capture)
  state.assignments = {}
  state.dynamic_order = {}
  state.vacancies = {}

  for column_index, column in ipairs(columns) do
    for _, id in ipairs(column.ids) do
      if column == dynamic then
        state.assignments[id] = { kind = "dynamic", zone = column_index }
        state.dynamic_order[#state.dynamic_order + 1] = id
      else
        state.assignments[id] = {
          kind = "fixed",
          zone = column_index,
          box = state.capture[id],
        }
      end
    end
  end

  state.capture = nil
  state.capture_order = nil
  state.expected = nil
  state.seen = nil
  state.snapshot = nil
  state.area = normalized(area, area)
  persist_or_error(state)
end

local function begin_request(ws, expected, session, snapshot)
  ws = tonumber(ws)
  expected = tonumber(expected)
  if not ws or not expected or expected < 1 then return false end
  snapshot = snapshot or snapshot_workspace(ws)
  if snapshot then
    expected = 0
    for _ in pairs(snapshot) do expected = expected + 1 end
  end
  states[ws] = nil
  requests[ws] = {
    version = VERSION,
    workspace = ws,
    session = tostring(session or ""),
    expected = expected,
    capture = {},
    capture_order = {},
    snapshot = snapshot,
    seen = {},
  }
  return true
end

local function live_target_map(ctx)
  local live, by_id = {}, {}
  for _, target in ipairs(ctx.targets) do
    local id = target_id(target)
    live[id] = true
    by_id[id] = target
  end
  return live, by_id
end

local function place_state(ctx, state)
  local live, by_id = live_target_map(ctx)
  -- During a config reload Hyprland transfers targets into the newly created
  -- custom algorithm one at a time. The workspace query distinguishes a real
  -- close from a target that simply has not reached this callback yet.
  local present = workspace_target_ids(state.workspace) or live
  local changed = false
  state.vacancies = state.vacancies or {}

  -- Keep the geometry of a closed fixed target as a reusable vacancy. This
  -- preserves the empty slot now and lets the next new window fill that same
  -- left/center position rather than being diverted to the dynamic column.
  for id, assignment in pairs(state.assignments) do
    if assignment.kind == "fixed" and not present[id] then
      state.vacancies[#state.vacancies + 1] = {
        zone = assignment.zone,
        box = assignment.box,
      }
      state.assignments[id] = nil
      changed = true
    end
  end

  -- Dynamic members compact inside their shared zone when one closes.
  local next_order = {}
  for _, id in ipairs(state.dynamic_order or {}) do
    if present[id] then
      next_order[#next_order + 1] = id
    else
      state.assignments[id] = nil
      changed = true
    end
  end
  state.dynamic_order = next_order

  -- Reuse fixed vacancies first. With none left, a new window joins the
  -- dynamic column and stacks there with any existing dynamic members.
  for _, target in ipairs(ctx.targets) do
    local id = target_id(target)
    if not state.assignments[id] then
      if #state.vacancies > 0 then
        local vacancy = table.remove(state.vacancies, 1)
        state.assignments[id] = {
          kind = "fixed",
          zone = vacancy.zone,
          box = vacancy.box,
        }
      else
        state.assignments[id] = { kind = "dynamic", zone = state.dynamic_zone }
        state.dynamic_order[#state.dynamic_order + 1] = id
      end
      changed = true
    end
  end

  for id, assignment in pairs(state.assignments) do
    local target = by_id[id]
    if target and assignment.kind == "fixed" and assignment.box then
      target:place(denormalized(assignment.box, ctx.area))
    end
  end

  local count = #state.dynamic_order
  if count > 0 then
    local zone = denormalized(state.dynamic_box, ctx.area)
    for index, id in ipairs(state.dynamic_order) do
      local target = by_id[id]
      if target then
        target:place({
          x = zone.x,
          y = zone.y + zone.h * (index - 1) / count,
          w = zone.w,
          h = zone.h / count,
        })
      end
    end
  end

  if changed then persist_or_error(state) end
end

local function fallback_grid(ctx)
  local count = #ctx.targets
  if count == 0 then return end
  for index, target in ipairs(ctx.targets) do
    if ctx.column then
      target:place(ctx:column(index - 1, count))
    else
      target:place({
        x = ctx.area.x + ctx.area.w * (index - 1) / count,
        y = ctx.area.y,
        w = ctx.area.w / count,
        h = ctx.area.h,
      })
    end
  end
end

function M.recalculate(ctx)
  local ws = workspace_id(ctx)
  if not ws then return end

  local request = requests[ws]
  if request then
    if request.snapshot then prepare_snapshot(request, ctx.area, ctx.targets[1]) end
    for _, target in ipairs(ctx.targets) do
      request.seen[target_id(target)] = true
      capture_box(request, target, ctx.area)
    end
    local seen = 0
    for _ in pairs(request.seen) do seen = seen + 1 end
    if seen >= request.expected then
      requests[ws] = nil
      states[ws] = request
      finalize_capture(request, ctx.area)
      place_state(ctx, request)
    else
      -- Until Hyprland has transferred the final target, leave each target in
      -- the logical box snapshotted before the old layout began removing and
      -- rearranging its remaining targets.
      for _, target in ipairs(ctx.targets) do
        local box = request.capture[target_id(target)]
        target:place(box and denormalized(box, ctx.area) or copy_box(target.box))
      end
    end
    return
  end

  local state = load_state(ws)
  if not state then
    fallback_grid(ctx)
    return
  end
  place_state(ctx, state)
end

local function recapture(ctx)
  local ws = workspace_id(ctx)
  if not ws or #ctx.targets == 0 then return false end
  local session = os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or ""
  begin_request(ws, #ctx.targets, session)
  M.recalculate(ctx)
  return true
end

local function make_focused_dynamic(ctx)
  local ws = workspace_id(ctx)
  local state = ws and load_state(ws)
  if not state then return "workspace is not locked" end

  local focused
  for _, target in ipairs(ctx.targets) do
    if target.window and target.window.active then focused = target break end
  end
  if not focused then return "no focused tiled window" end

  local focus_box = normalized(focused.box, ctx.area)
  local tolerance = COLUMN_TOLERANCE / math.max(ctx.area.w, 1)
  local new_dynamic = {}

  -- Freeze the old dynamic column at the boxes it has right now.
  for _, target in ipairs(ctx.targets) do
    local id = target_id(target)
    state.assignments[id] = {
      kind = "fixed",
      zone = state.assignments[id] and state.assignments[id].zone or 0,
      box = normalized(target.box, ctx.area),
    }
    local box = normalized(target.box, ctx.area)
    if math.abs(box.x - focus_box.x) <= tolerance then
      new_dynamic[#new_dynamic + 1] = id
    end
  end

  state.dynamic_order = {}
  state.dynamic_zone = (state.assignments[target_id(focused)] or {}).zone or 0
  state.dynamic_box = union_boxes(new_dynamic, (function()
    local boxes = {}
    for _, target in ipairs(ctx.targets) do boxes[target_id(target)] = normalized(target.box, ctx.area) end
    return boxes
  end)())
  for _, id in ipairs(new_dynamic) do
    state.assignments[id] = { kind = "dynamic", zone = state.dynamic_zone }
    state.dynamic_order[#state.dynamic_order + 1] = id
  end

  persist_or_error(state)
  place_state(ctx, state)
  return true
end

function M.layout_msg(ctx, message)
  if message == "recapture" then return recapture(ctx) end
  if message == "dynamic-focused" then return make_focused_dynamic(ctx) end
  return "unknown layout lock command: " .. tostring(message)
end

function M.begin_capture(ws, expected, session, snapshot)
  return begin_request(ws, expected, session, snapshot)
end

function M.cancel_capture(ws)
  ws = tonumber(ws)
  requests[ws] = nil
  states[ws] = nil
  return true
end

-- Test hooks are intentionally small; production callers use the global API.
function M._set_state_dir(path) state_dir = path end
function M._reset()
  states = {}
  requests = {}
end
function M._state(ws) return states[tonumber(ws)] end

_G.cromewar_ultrawide_lock = M

if hl and hl.layout and hl.layout.register then
  hl.layout.register(LAYOUT_NAME, {
    recalculate = M.recalculate,
    layout_msg = M.layout_msg,
  })
end

return M
