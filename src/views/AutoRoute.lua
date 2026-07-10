--
-- Copyright (c) 2025, Mupen64 maintainers.
--
-- SPDX-License-Identifier: GPL-2.0-or-later
--

-- Auto-Route tab.
--
-- Exposes the `target_point` movement mode: instead of holding a fixed angle,
-- the engine recomputes, every frame, the world yaw pointing from Mario towards
-- the active target and feeds it into the existing angle optimizer. The target
-- is either a single (X, Z) point or the current waypoint of a path, which can
-- be built, edited, saved, loaded, imported and visualized.

local HEADER_ROW = 0
local MODE_ROW = 1
local CAPTURE_ROW = 2
local COORD_ROW = 3
local STOP_ROW = 4
local WAYPOINT_ROW = 5
local WAYPOINT2_ROW = 6
local EXTRA_ROW = 7
local EDIT_HEADER_ROW = 8
local EDIT_SEL_ROW = 9
local EDIT_BTN_ROW = 10
local READOUT_ROW = 12

-- View-local selection for the waypoint editor.
local selected = 1

local UID = UIDProvider.allocate_once('AutoRoute', function(enum_next)
    return {
        Header = enum_next(),
        Mode = enum_next(),
        Invert = enum_next(),
        Capture = enum_next(),
        TargetXLabel = enum_next(),
        TargetX = enum_next(4),
        TargetZLabel = enum_next(),
        TargetZ = enum_next(4),
        StopLabel = enum_next(),
        StopDist = enum_next(4),
        Loop = enum_next(),
        AddWaypoint = enum_next(),
        ClearWaypoints = enum_next(),
        WaypointInfo = enum_next(),
        RemoveLast = enum_next(),
        Nearest = enum_next(),
        SaveRoute = enum_next(),
        LoadRoute = enum_next(),
        Overlay = enum_next(),
        ImportClipboard = enum_next(),
        EditHeader = enum_next(),
        SelSpinner = enum_next(4),
        SelCoords = enum_next(),
        MoveUp = enum_next(),
        MoveDown = enum_next(),
        DeleteSel = enum_next(),
        InsertSel = enum_next(),
        SetActive = enum_next(),
        ReadoutLabel = enum_next(),
        DistEta = enum_next(),
        AngPath = enum_next(),
        Status = enum_next(),
    }
end)

return {
    name = function() return Locales.str('AUTOROUTE_TAB_NAME') end,
    draw = function()
        local theme = Styles.theme()
        local foreground_color = Drawing.foreground_color()

        -- Backfill fields for presets saved before Auto-Route existed.
        Settings.tas.target_x = Settings.tas.target_x or 0
        Settings.tas.target_z = Settings.tas.target_z or 0
        Settings.tas.target_stop_dist = Settings.tas.target_stop_dist or 0
        Settings.tas.waypoints = Settings.tas.waypoints or {}
        Settings.tas.waypoint_index = Settings.tas.waypoint_index or 1

        local waypoints = Settings.tas.waypoints
        local waypoint_count = #waypoints

        local function header(uid, row, text)
            ugui.label({
                uid = uid,
                rectangle = grid_rect(0, row, 8, 1),
                text = text,
                color = foreground_color,
                font_size = theme.font_size * Drawing.scale * 1.25,
                font_name = theme.font_name,
                align_x = BreitbandGraphics.alignment['start'],
                align_y = BreitbandGraphics.alignment.center,
            })
        end

        local function mono(uid, rect, text)
            ugui.label({
                uid = uid,
                rectangle = rect,
                text = text,
                color = foreground_color,
                font_size = theme.font_size * Drawing.scale,
                font_name = 'Consolas',
                align_x = BreitbandGraphics.alignment['start'],
                align_y = BreitbandGraphics.alignment.center,
            })
        end

        header(UID.Header, HEADER_ROW, Locales.str('AUTOROUTE_HEADER'))

        -- Movement mode toggle: target_point <-> disabled.
        local _, meta = ugui.toggle_button({
            uid = UID.Mode,
            rectangle = grid_rect(0, MODE_ROW, 5, 1),
            text = Locales.str('AUTOROUTE_MODE'),
            is_checked = Settings.tas.movement_mode == MovementModes.target_point,
        })
        if meta.signal_change == ugui.signal_change_states.started then
            action.invoke(Settings.tas.movement_mode == MovementModes.target_point
                and ACTION_SET_MOVEMENT_MODE_DISABLED
                or ACTION_SET_MOVEMENT_MODE_TARGET_POINT)
        end

        local _, invert_meta = ugui.toggle_button({
            uid = UID.Invert,
            rectangle = grid_rect(5, MODE_ROW, 3, 1),
            text = Locales.str('AUTOROUTE_INVERT'),
            is_checked = Settings.tas.target_invert,
        })
        if invert_meta.signal_change == ugui.signal_change_states.started then
            action.invoke(ACTION_TOGGLE_TARGET_INVERT)
        end

        -- Capture current position as the single-point target.
        if ugui.button({
                uid = UID.Capture,
                rectangle = grid_rect(0, CAPTURE_ROW, 8, 1),
                text = Locales.str('AUTOROUTE_SET_TARGET'),
            }) then
            action.invoke(ACTION_SET_TARGET_TO_CURRENT_POS)
        end

        -- Single-point target coordinate spinners.
        mono(UID.TargetXLabel, grid_rect(0, COORD_ROW, 1, 1), 'X')
        Settings.tas.target_x = ugui.spinner({
            uid = UID.TargetX,
            rectangle = grid_rect(1, COORD_ROW, 3, 1),
            value = Settings.tas.target_x,
            increment = 1,
            minimum_value = -32768,
            maximum_value = 32768,
        })
        mono(UID.TargetZLabel, grid_rect(4, COORD_ROW, 1, 1), 'Z')
        Settings.tas.target_z = ugui.spinner({
            uid = UID.TargetZ,
            rectangle = grid_rect(5, COORD_ROW, 3, 1),
            value = Settings.tas.target_z,
            increment = 1,
            minimum_value = -32768,
            maximum_value = 32768,
        })

        -- Stop radius (0 disables) and path looping.
        mono(UID.StopLabel, grid_rect(0, STOP_ROW, 2, 1), Locales.str('AUTOROUTE_STOP_DIST'))
        Settings.tas.target_stop_dist = math.max(0, ugui.spinner({
            uid = UID.StopDist,
            rectangle = grid_rect(2, STOP_ROW, 2, 1),
            value = Settings.tas.target_stop_dist,
            increment = 1,
            minimum_value = 0,
            maximum_value = 32768,
        }))
        Settings.tas.waypoint_loop = ugui.toggle_button({
            uid = UID.Loop,
            rectangle = grid_rect(5, STOP_ROW, 3, 1),
            text = Locales.str('AUTOROUTE_LOOP'),
            is_checked = Settings.tas.waypoint_loop or false,
        })

        -- Waypoint path controls.
        if ugui.button({
                uid = UID.AddWaypoint,
                rectangle = grid_rect(0, WAYPOINT_ROW, 3, 1),
                text = Locales.str('AUTOROUTE_ADD_WAYPOINT'),
            }) then
            action.invoke(ACTION_ADD_WAYPOINT)
        end
        if ugui.button({
                uid = UID.ClearWaypoints,
                rectangle = grid_rect(3, WAYPOINT_ROW, 2, 1),
                text = Locales.str('AUTOROUTE_CLEAR_WAYPOINTS'),
            }) then
            action.invoke(ACTION_CLEAR_WAYPOINTS)
        end
        local waypoint_index = waypoint_count > 0 and math.min(Settings.tas.waypoint_index, waypoint_count) or 0
        mono(UID.WaypointInfo, grid_rect(5, WAYPOINT_ROW, 3, 1),
            string.format(Locales.str('AUTOROUTE_WAYPOINTS'), waypoint_index, waypoint_count))

        -- Persistence row.
        if ugui.button({
                uid = UID.RemoveLast,
                rectangle = grid_rect(0, WAYPOINT2_ROW, 2, 1),
                text = Locales.str('AUTOROUTE_REMOVE_LAST'),
            }) then
            action.invoke(ACTION_REMOVE_LAST_WAYPOINT)
        end
        if ugui.button({
                uid = UID.Nearest,
                rectangle = grid_rect(2, WAYPOINT2_ROW, 2, 1),
                text = Locales.str('AUTOROUTE_NEAREST'),
            }) then
            action.invoke(ACTION_JUMP_NEAREST_WAYPOINT)
        end
        if ugui.button({
                uid = UID.SaveRoute,
                rectangle = grid_rect(4, WAYPOINT2_ROW, 2, 1),
                text = Locales.str('AUTOROUTE_SAVE_ROUTE'),
            }) then
            action.invoke(ACTION_SAVE_ROUTE)
        end
        if ugui.button({
                uid = UID.LoadRoute,
                rectangle = grid_rect(6, WAYPOINT2_ROW, 2, 1),
                text = Locales.str('AUTOROUTE_LOAD_ROUTE'),
            }) then
            action.invoke(ACTION_LOAD_ROUTE)
        end

        -- Overlay toggle + clipboard import.
        Settings.autoroute_overlay = ugui.toggle_button({
            uid = UID.Overlay,
            rectangle = grid_rect(0, EXTRA_ROW, 3, 1),
            text = Locales.str('AUTOROUTE_OVERLAY'),
            is_checked = Settings.autoroute_overlay ~= false,
        })
        if ugui.button({
                uid = UID.ImportClipboard,
                rectangle = grid_rect(3, EXTRA_ROW, 5, 1),
                text = Locales.str('AUTOROUTE_IMPORT_CLIPBOARD'),
            }) then
            action.invoke(ACTION_IMPORT_CLIPBOARD)
        end

        -- Waypoint editor.
        header(UID.EditHeader, EDIT_HEADER_ROW, Locales.str('AUTOROUTE_EDIT'))
        selected = math.max(1, math.min(selected, math.max(1, waypoint_count)))
        selected = math.floor(ugui.spinner({
            uid = UID.SelSpinner,
            is_enabled = waypoint_count > 0,
            rectangle = grid_rect(0, EDIT_SEL_ROW, 2, 1),
            value = selected,
            increment = 1,
            minimum_value = 1,
            maximum_value = math.max(1, waypoint_count),
        }))
        selected = math.max(1, math.min(selected, math.max(1, waypoint_count)))

        local sel_text = Locales.str('AUTOROUTE_NO_WAYPOINTS')
        if waypoint_count > 0 then
            local wp = waypoints[selected]
            sel_text = string.format('#%d   X %s   Z %s', selected,
                Formatter.u(wp.x, 1), Formatter.u(wp.z, 1))
        end
        mono(UID.SelCoords, grid_rect(2, EDIT_SEL_ROW, 6, 1), sel_text)

        local bw = 1.6
        if ugui.button({
                uid = UID.MoveUp,
                is_enabled = waypoint_count > 1 and selected > 1,
                rectangle = grid_rect(0, EDIT_BTN_ROW, bw, 1),
                text = '[icon:arrow_up]',
            }) then
            swap(waypoints, selected, selected - 1)
            selected = selected - 1
        end
        if ugui.button({
                uid = UID.MoveDown,
                is_enabled = waypoint_count > 1 and selected < waypoint_count,
                rectangle = grid_rect(bw, EDIT_BTN_ROW, bw, 1),
                text = '[icon:arrow_down]',
            }) then
            swap(waypoints, selected, selected + 1)
            selected = selected + 1
        end
        if ugui.button({
                uid = UID.DeleteSel,
                is_enabled = waypoint_count > 0,
                rectangle = grid_rect(bw * 2, EDIT_BTN_ROW, bw, 1),
                text = Locales.str('AUTOROUTE_DELETE'),
            }) then
            table.remove(waypoints, selected)
            selected = math.max(1, math.min(selected, #waypoints))
            Settings.tas.waypoint_index = math.max(1, math.min(Settings.tas.waypoint_index, math.max(1, #waypoints)))
        end
        if ugui.button({
                uid = UID.InsertSel,
                rectangle = grid_rect(bw * 3, EDIT_BTN_ROW, bw, 1),
                text = Locales.str('AUTOROUTE_INSERT'),
            }) then
            local at = waypoint_count > 0 and (selected + 1) or 1
            table.insert(waypoints, at, { x = Memory.current.mario_x, z = Memory.current.mario_z })
            selected = at
        end
        if ugui.button({
                uid = UID.SetActive,
                is_enabled = waypoint_count > 0,
                rectangle = grid_rect(bw * 4, EDIT_BTN_ROW, 8 - bw * 4, 1),
                text = Locales.str('AUTOROUTE_SET_ACTIVE'),
            }) then
            Settings.tas.waypoint_index = selected
        end

        -- Compact live readouts.
        header(UID.ReadoutLabel, READOUT_ROW - 1, Locales.str('AUTOROUTE_READOUT'))

        local tx, tz = Engine.active_target()
        local distance = Engine.distance_to_target()
        local angle = Engine.angle_to_point(
            Memory.current.mario_x or 0, Memory.current.mario_z or 0, tx, tz)
        if Settings.tas.target_invert then
            angle = (angle + 32768) % 65536
        end
        local eta = Engine.eta_frames(distance, Memory.current.mario_h_speed or 0)
        local eta_text = eta == math.huge and Locales.str('AUTOROUTE_ETA_NA') or (MoreMaths.round(eta, 0) .. 'f')

        mono(UID.DistEta, grid_rect(0, READOUT_ROW, 8, 1),
            Locales.str('AUTOROUTE_DISTANCE') .. ': ' .. Formatter.u(distance, 2)
            .. '   ' .. Locales.str('AUTOROUTE_ETA') .. ': ' .. eta_text)

        local path_text = ''
        if waypoint_count > 0 then
            local remaining = Engine.path_remaining_length(waypoints, waypoint_index,
                Memory.current.mario_x or 0, Memory.current.mario_z or 0)
            local total = Engine.path_total_length(waypoints)
            path_text = '   ' .. string.format(Locales.str('AUTOROUTE_PATH_LEN'),
                Formatter.u(remaining, 0), Formatter.u(total, 0))
        end
        mono(UID.AngPath, grid_rect(0, READOUT_ROW + 1, 8, 1),
            Locales.str('AUTOROUTE_ANGLE') .. ': ' .. Formatter.angle(angle) .. path_text)

        local status
        if Settings.tas.movement_mode ~= MovementModes.target_point then
            status = Locales.str('AUTOROUTE_STATUS_OFF')
        elseif Settings.tas.target_stop_dist > 0 and distance <= Settings.tas.target_stop_dist then
            status = Locales.str('AUTOROUTE_STATUS_ARRIVED')
        else
            status = Locales.str('AUTOROUTE_STATUS_ROUTING')
        end
        mono(UID.Status, grid_rect(0, READOUT_ROW + 2, 8, 1), status)
    end,
}
