--
-- Copyright (c) 2025, Mupen64 maintainers.
--
-- SPDX-License-Identifier: GPL-2.0-or-later
--

-- Button fields that UI views read directly as boolean is_checked. joypad.get() can return them as
-- nil (e.g. while the emulator is paused with no active input, as the bruteforce leaves it), which
-- would crash those toggle buttons ("expected is_checked to be boolean"). Normalize them to booleans.
local BUTTON_FIELDS = {
	'A', 'B', 'Z', 'L', 'R', 'start',
	'up', 'down', 'left', 'right',
	'Cup', 'Cdown', 'Cleft', 'Cright',
}

---Coerces a raw joypad table's button fields to booleans and its stick to numbers (in place).
---@param input table|nil
---@return table
local function normalize_input(input)
	input = input or {}
	for _, b in ipairs(BUTTON_FIELDS) do
		input[b] = input[b] and true or false
	end
	input.X = input.X or 0
	input.Y = input.Y or 0
	return input
end

Joypad = {
	---@type JoypadInputs
	input = normalize_input({}),
}

---Updates the Joypad input state.
function Joypad.update()
	Joypad.input = normalize_input(joypad.get(Settings.controller_index))
end

---Sends the current Joypad input state to the emulator.
function Joypad.send()
	joypad.set(Settings.controller_index, Joypad.input)
end
