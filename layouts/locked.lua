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

local function target_id(target)
  local window = target.window
  if not window then
    return "target:" .. tostring(target.index)
  end
  -- A group is one tiled target. Its active member can change without the
  -- target moving, so identify the group object rather than whichever member
  -- happens to be exposed as target.window right now.
  if window.group then
    return "group:" .. tostring(window.group)
  end
  if window.address and window.address ~= "" then
    return tostring(window.address)
  end
  return "stable:" .. tostring(window.stable_id or target.index)
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

local function ensure_state_dir()
  -- The path comes only from HOME/XDG_STATE_HOME. %q prevents whitespace or
  -- shell metacharacters in it from changing the command.
  local ok = os.execute("mkdir -p " .. string.format("%q", state_dir))
  return ok == true or ok == 0
end

local function persist(state)
  if M._persistence_disabled then return true end
  if not ensure_state_dir() then return false end
  local path = state_path(state.workspace)
  local temporary = path .. ".tmp"
  local file = io.open(temporary, "w")
  if not file then return false end
  file:write("return ", serialize(state), "\n")
  file:close()
  return os.rename(temporary, path) ~= nil
end

local function persist_or_error(state)
  if not persist(state) then
    error("could not persist layout lock state for workspace " .. tostring(state.workspace))
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
  state.area = normalized(area, area)
  persist_or_error(state)
end

local function begin_request(ws, expected, session)
  ws = tonumber(ws)
  expected = tonumber(expected)
  if not ws or not expected or expected < 1 then return false end
  states[ws] = nil
  requests[ws] = {
    version = VERSION,
    workspace = ws,
    session = tostring(session or ""),
    expected = expected,
    capture = {},
    capture_order = {},
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
  local changed = false

  -- Dynamic members are ephemeral. Fixed assignments deliberately are not:
  -- their vacancy is the feature this layout provides.
  local next_order = {}
  for _, id in ipairs(state.dynamic_order or {}) do
    if live[id] then
      next_order[#next_order + 1] = id
    else
      state.assignments[id] = nil
      changed = true
    end
  end
  state.dynamic_order = next_order

  -- A window unknown to the capture always joins the dynamic column.
  for _, target in ipairs(ctx.targets) do
    local id = target_id(target)
    if not state.assignments[id] then
      state.assignments[id] = { kind = "dynamic", zone = state.dynamic_zone }
      state.dynamic_order[#state.dynamic_order + 1] = id
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
    for _, target in ipairs(ctx.targets) do capture_box(request, target, ctx.area) end
    if #request.capture_order >= request.expected then
      requests[ws] = nil
      states[ws] = request
      finalize_capture(request, ctx.area)
      place_state(ctx, request)
    else
      -- Until Hyprland has transferred the final target, leave each target in
      -- the logical box supplied by the previous layout.
      for _, target in ipairs(ctx.targets) do target:place(copy_box(target.box)) end
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

function M.begin_capture(ws, expected, session)
  return begin_request(ws, expected, session)
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
