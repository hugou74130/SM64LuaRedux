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

        -- Auto-Route: once within the stop radius of the target, release the stick so
        -- Mario coasts/decelerates instead of overshooting the coordinate.
        if Settings.tas.movement_mode == MovementModes.target_point
            and Settings.tas.target_stop_dist > 0
            and Engine.distance_to_target() <= Settings.tas.target_stop_dist then
            input.X = 0
            input.Y = 0
            return input
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
