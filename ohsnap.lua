-- OhSnap: Windows 11 style snapping for Omarchy floating workspaces.
-- Part of the dooooooks.ohsnap Omarchy plugin; loaded from hyprland.lua by its
-- `install` script.
--
-- On a workspace set to floating (Super + L, or Appearance > Workspace Layout),
-- drag a window by its titlebar (or with Super + left mouse) and drop it with
-- the cursor against a screen edge:
--
--   top edge            -> maximize
--   left / right edge   -> snap to that half of the screen
--   any corner          -> snap to that quarter of the screen
--
-- Dragging a snapped window away gives it back the size it had before. A
-- maximized window is pulled back out by dragging its titlebar, as before.
--
-- How it works: Hyprland's Lua API has no drag events, and the titlebar plugin
-- swallows the mouse button, so the drag is read from the window itself. While
-- a window is being dragged it moves in lockstep with the cursor; the moment
-- the cursor moves and the window does not, the button has been let go, and the
-- drop point is where the cursor was the last time they moved together.
--
-- That alone only notices a drop once the mouse moves again, so the plugin's
-- ohsnap-watch helper (needs the `input` group) reads the real button release
-- and calls window_snap_release() below, which drops the window at once.

local M = {}

-- Tuning ---------------------------------------------------------------------
-- Override any of these in hyprland.lua, before the line that loads this file:
--   ohsnap_config = { gap = 0, edge = 12 }
local config = rawget(_G, "ohsnap_config") or {}

local EDGE = config.edge or 8         -- px from a screen edge that counts as "at the edge"
local CORNER = config.corner or 120   -- px from a corner along an edge that counts as a corner
local TICK = config.tick or 20        -- ms between checks
local SLACK = 2                       -- px of rounding allowed between window and cursor moves
local GAP = config.gap                -- px around snapped windows; nil uses Hyprland's gaps_out
local IPC = "ohsnap"                  -- omarchy-shell target of the outline

-- Set to a path (e.g. os.getenv("HOME") .. "/.cache/ohsnap.log") to debug.
local DEBUG_LOG = config.debug_log

-- Omarchy tags every window on a floating workspace with this.
local FLOATING_TAG = "omarchy-floating-workspace"

local function log(...)
  if not DEBUG_LOG then return end
  local f = io.open(DEBUG_LOG, "a")
  if not f then return end
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  f:write(os.date("%H:%M:%S "), table.concat(parts, " "), "\n")
  f:close()
end

-- Window address -> { w, h } it had before being snapped.
local restore = {}

-- What the active window and cursor looked like on the last tick.
local last = nil
-- The drag in progress: { address, ox, oy, dropx, dropy }.
local drag = nil

local function has_tag(window, wanted)
  for _, tag in ipairs(window.tags or {}) do
    if tag == wanted or tag == wanted .. "*" then
      return true
    end
  end
  return false
end

local function sel(address)
  return "address:" .. address
end

local function gap()
  if GAP then return GAP end
  local g = hl.get_config("general.gaps_out")
  if type(g) == "table" then
    return g.top or g[1] or 0
  end
  return tonumber(g) or 0
end

-- Height of the titlebar drawn above a window on a floating workspace, which
-- sits outside the window's own box and has to fit on screen too.
local function titlebar()
  local ok, h = pcall(hl.get_config, "plugin.hyprbars.bar_height")
  return (ok and tonumber(h)) or 0
end

-- The part of a monitor windows may use, plus the whole screen, in global
-- layout coordinates.
local function work_area(monitor)
  local w = math.floor(monitor.width / monitor.scale)
  local h = math.floor(monitor.height / monitor.scale)
  if (monitor.transform or 0) % 2 == 1 then
    w, h = h, w
  end

  local r = monitor.reserved or {}
  local left, right = r.left or 0, r.right or 0
  local top, bottom = r.top or 0, r.bottom or 0

  return {
    x = monitor.x + left,
    y = monitor.y + top,
    w = w - left - right,
    h = h - top - bottom,
    mx = monitor.x,
    my = monitor.y,
    mw = w,
    mh = h,
  }
end

-- Which zone a point is in, or nil.
local function zone_at(px, py, a)
  local x, y = px - a.mx, py - a.my
  local bar = a.y - a.my
  local top = y <= bar + EDGE
  local bottom = y >= a.mh - EDGE - 1
  local left = x <= EDGE
  local right = x >= a.mw - EDGE - 1
  local near_left = x <= CORNER
  local near_right = x >= a.mw - CORNER
  local near_top = y <= bar + CORNER
  local near_bottom = y >= a.mh - CORNER

  if (top and near_left) or (left and near_top) then return "top-left" end
  if (top and near_right) or (right and near_top) then return "top-right" end
  if (bottom and near_left) or (left and near_bottom) then return "bottom-left" end
  if (bottom and near_right) or (right and near_bottom) then return "bottom-right" end
  if top then return "maximize" end
  if left then return "left" end
  if right then return "right" end
  return nil
end

local function place(address, box)
  local target = sel(address)
  hl.dispatch(hl.dsp.window.resize({ x = box.w, y = box.h, relative = false, window = target }))
  hl.dispatch(hl.dsp.window.move({ x = box.x, y = box.y, relative = false, window = target }))

  -- If an absolute move turns out to be monitor-relative, correct it once.
  hl.timer(function()
    local w = hl.get_window(target)
    if not w then return end
    log("landed", w.at.x, w.at.y, w.size.x, w.size.y, "wanted", box.x, box.y, box.w, box.h)
    if w.at.x ~= box.x or w.at.y ~= box.y then
      hl.dispatch(hl.dsp.window.move({ x = box.x - w.at.x, y = box.y - w.at.y, relative = true, window = target }))
    end
  end, { type = "oneshot", timeout = 1 })
end

-- Where a window snapped into a zone goes: its own box (below its titlebar),
-- and the whole area it covers on screen, titlebar included, for the preview.
local function zone_box(zone, monitor)
  local a = work_area(monitor)
  local g = gap()
  local t = titlebar()

  if zone == "maximize" then
    return nil, { x = a.x + g, y = a.y + g, w = a.w - 2 * g, h = a.h - 2 * g }
  end

  -- Each window's box starts below its titlebar, so every row gives it room.
  local full_h = a.h - 2 * g - t
  local half_w = math.floor((a.w - 3 * g) / 2)
  local half_h = math.floor((a.h - 3 * g) / 2) - t
  local lx, rx = a.x + g, a.x + 2 * g + half_w
  local ty, by = a.y + g + t, a.y + 2 * g + half_h + 2 * t
  -- The right and bottom pieces take up any rounding so the edges line up.
  local rw = a.x + a.w - g - rx
  local bh = a.y + a.h - g - by

  local boxes = {
    ["left"] = { x = lx, y = ty, w = half_w, h = full_h },
    ["right"] = { x = rx, y = ty, w = rw, h = full_h },
    ["top-left"] = { x = lx, y = ty, w = half_w, h = half_h },
    ["top-right"] = { x = rx, y = ty, w = rw, h = half_h },
    ["bottom-left"] = { x = lx, y = by, w = half_w, h = bh },
    ["bottom-right"] = { x = rx, y = by, w = rw, h = bh },
  }
  local box = boxes[zone]
  if not box then return nil, nil end
  return box, { x = box.x, y = box.y - t, w = box.w, h = box.h + t }
end

-- The outline drawn by the shell side of the plugin (SnapPreview.qml).
local preview_zone = nil

local function hide_preview()
  if not preview_zone then return end
  preview_zone = nil
  hl.exec_cmd("omarchy-shell -q " .. IPC .. " hide")
end

local function show_preview(zone, monitor)
  local key = zone and (zone .. "@" .. monitor.name) or nil
  if key == preview_zone then return end
  if not zone then
    hide_preview()
    return
  end
  local _, area = zone_box(zone, monitor)
  if not area then return end
  preview_zone = key
  hl.exec_cmd(string.format("omarchy-shell -q %s show %s %d %d %d %d",
    IPC, monitor.name, math.floor(area.x - monitor.x), math.floor(area.y - monitor.y),
    math.floor(area.w), math.floor(area.h)))
end

local function snap(window, zone, monitor)
  local address = window.address

  if not restore[address] then
    restore[address] = { w = window.size.x, h = window.size.y }
  end

  if zone == "maximize" then
    hl.dispatch(hl.dsp.window.fullscreen({ mode = "maximized", action = "set", window = sel(address) }))
    return
  end

  log("snap", zone, address)
  place(address, (zone_box(zone, monitor)))
end

-- A snapped window gets its old size back as soon as it is dragged away. The
-- drag keeps its top-left corner under control, so only the size changes here.
local function unsnap(window)
  local saved = restore[window.address]
  if not saved then return end
  restore[window.address] = nil
  log("unsnap", window.address)
  hl.dispatch(hl.dsp.window.resize({ x = saved.w, y = saved.h, relative = false, window = sel(window.address) }))
end

local function drop(state)
  hide_preview()
  local window = hl.get_window(sel(state.address))
  if not (window and window.floating and has_tag(window, FLOATING_TAG)) then return end
  if (window.fullscreen or 0) ~= 0 then return end

  local monitor = hl.get_monitor_at(state.dropx, state.dropy) or hl.get_monitor_at_cursor()
  if not monitor then return end

  local zone = zone_at(state.dropx, state.dropy, work_area(monitor))
  log("drop", state.address, state.dropx, state.dropy, zone)

  if zone then
    snap(window, zone, monitor)
    return
  end

  -- A window brought back to its own size can end up with the grab point
  -- beyond its right edge; bring it back under the cursor.
  local x, w = window.at.x, window.size.x
  if state.dropx < x or state.dropx > x + w then
    local nx = math.floor(state.dropx - w / 2)
    hl.dispatch(hl.dsp.window.move({ x = nx - x, y = 0, relative = true, window = sel(window.address) }))
  end
end

local function close(a, b)
  return math.abs(a - b) <= SLACK
end

local function tick()
  local window = hl.get_active_window()
  local cursor = hl.get_cursor_pos()
  if not (window and cursor) then
    last = nil
    return
  end

  local floating = window.floating and (window.fullscreen or 0) == 0 and has_tag(window, FLOATING_TAG)

  local now = {
    address = window.address,
    x = window.at.x,
    y = window.at.y,
    w = window.size.x,
    h = window.size.y,
    cx = cursor.x,
    cy = cursor.y,
  }

  local prev = last
  last = now

  -- A drag in progress ends when the cursor moves without its window, or the
  -- window stops being the active floating one.
  if drag then
    if now.address ~= drag.address or not floating then
      local state = drag
      drag = nil
      drop(state)
      return
    end

    local ox, oy = now.x - now.cx, now.y - now.cy
    if close(ox, drag.ox) and close(oy, drag.oy) then
      drag.dropx, drag.dropy = now.cx, now.cy
      local monitor = hl.get_monitor_at(now.cx, now.cy)
      if monitor then
        show_preview(zone_at(now.cx, now.cy, work_area(monitor)), monitor)
      end
      return
    end

    -- Only a cursor moving away from a window that stayed put is a release.
    if now.x == prev.x and now.y == prev.y then
      local state = drag
      drag = nil
      drop(state)
    else
      -- Still moving together, just at a new offset (e.g. clamped at an edge).
      drag.ox, drag.oy = ox, oy
      drag.dropx, drag.dropy = now.cx, now.cy
    end
    return
  end

  if not (floating and prev and prev.address == now.address) then return end

  -- A drag starts when the window and cursor move by the same amount at the
  -- same size: a titlebar or Super drag, not a resize or a keyboard move.
  local moved = now.x ~= prev.x or now.y ~= prev.y
  local same_size = now.w == prev.w and now.h == prev.h
  local with_cursor = close(now.x - prev.x, now.cx - prev.cx) and close(now.y - prev.y, now.cy - prev.cy)

  if moved and same_size and with_cursor then
    drag = {
      address = now.address,
      ox = now.x - now.cx,
      oy = now.y - now.cy,
      dropx = now.cx,
      dropy = now.cy,
    }
    log("drag start", now.address)
    unsnap(window)
  end
end

hl.timer(tick, { type = "repeat", timeout = TICK })

-- Called by ohsnap-watch the instant the left button comes up.
function window_snap_release()
  if not drag then return end
  local state = drag
  drag = nil

  -- The last tick may be a few ms old; take the drop point from where the
  -- window is now, at the offset it was dragged with.
  local window = hl.get_window(sel(state.address))
  if window then
    state.dropx = window.at.x - state.ox
    state.dropy = window.at.y - state.oy
  end
  drop(state)
end

-- Forget windows that have closed.
hl.on("window.destroy", function(window)
  if window and window.address then
    restore[window.address] = nil
  end
end)

-- Leaving maximize brings back the window's own size, so it is no longer snapped.
hl.on("window.fullscreen", function(window)
  if window and (window.fullscreen or 0) == 0 then
    restore[window.address] = nil
  end
end)

return M
