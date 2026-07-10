--
-- Copyright (c) 2025, Mupen64 maintainers.
--
-- SPDX-License-Identifier: GPL-2.0-or-later
--

return {
    process = function(input)
        if Settings.tas.movement_mode == MovementModes.disabled then
            return input
        elseif Settings.tas.movement_mode == MovementModes.manual then
            Joypad.input.X = Settings.tas.manual_joystick_x or input.x
            Joypad.input.Y = Settings.tas.manual_joystick_y or input.y
            return Joypad.input
        end
        Memory.update()

        -- Auto-Route arrival handling.
        if Settings.tas.movement_mode == MovementModes.target_point then
            local waypoints = Settings.tas.waypoints
            local stop_dist = Settings.tas.target_stop_dist or 0
            if waypoints and #waypoints > 0 then
                -- Path mode: advance to the next waypoint when close enough.
                local reach = stop_dist > 0 and stop_dist or Engine.WAYPOINT_DEFAULT_REACH
                if Engine.distance_to_target() <= reach then
                    local next_index, complete = Engine.advance_waypoint(
                        Settings.tas.waypoint_index or 1, #waypoints, Settings.tas.waypoint_loop)
                    Settings.tas.waypoint_index = next_index
                    if complete then
                        input.X = 0
                        input.Y = 0
                        return input
                    end
                end
            elseif stop_dist > 0 and Engine.distance_to_target() <= stop_dist then
                -- Single-point mode: release the stick within the stop radius so
                -- Mario coasts instead of overshooting.
                input.X = 0
                input.Y = 0
                return input
            end
        end

        local result = Engine.inputsForAngle(Settings.tas.goal_angle, input)
        if Settings.tas.goal_mag then
            Engine.scaleInputsForMagnitude(result, Settings.tas.goal_mag, Settings.tas.high_magnitude)
        end

        input.X = result.X
        input.Y = result.Y
        return input
    end,
}
