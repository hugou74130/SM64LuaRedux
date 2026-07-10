--
-- Copyright (c) 2025, Mupen64 maintainers.
--
-- SPDX-License-Identifier: GPL-2.0-or-later
--

-- Standalone unit test for the Auto-Route geometry added to Engine.lua.
--
-- It loads the *real* Engine.lua (so the shipped code is what gets tested),
-- stubbing only the globals Engine's geometry helpers touch. Run with:
--
--     lua5.4 test/autoroute_geometry_test.lua
--
-- No emulator required: this validates the pure math (atan2s convention,
-- angle-to-point, distance), which is the part that must be exactly right for
-- Target Point steering to head the correct way.

-- Resolve the repo root from this file's location so the test can be run from
-- anywhere.
local this = debug.getinfo(1).source:sub(2)
local root = this:match('^(.*[/\\])test[/\\]') or './'

-- Minimal math shim mirroring src/core/Helpers.lua's apply_math_shim().
if not math.pow then
    math.pow = function(x, y) return x ^ y end
end
if not math.atan2 then
    math.atan2 = math.atan
end

-- Globals referenced (only inside functions) by Engine.lua.
Joypad = { input = { X = 0, Y = 0 } }
Settings = { tas = { movement_mode = 1, target_x = 0, target_z = 0 } }
Memory = { current = { mario_x = 0, mario_z = 0 } }

dofile(root .. 'src/core/Engine.lua')

-- ---------------------------------------------------------------------------
local failures = 0
local checks = 0

local function approx_u16_equal(a, b)
    -- Compare angles on the u16 circle, tolerating +-1 rounding.
    local d = (a - b) % 65536
    if d > 32768 then d = d - 65536 end
    return math.abs(d) <= 1
end

local function check(name, got, want)
    checks = checks + 1
    if not approx_u16_equal(got, want) then
        failures = failures + 1
        print(string.format('FAIL  %-34s got=%d want=%d', name, got, want))
    else
        print(string.format('ok    %-34s = %d', name, got))
    end
end

local function check_num(name, got, want, tol)
    checks = checks + 1
    if math.abs(got - want) > (tol or 1e-6) then
        failures = failures + 1
        print(string.format('FAIL  %-34s got=%s want=%s', name, tostring(got), tostring(want)))
    else
        print(string.format('ok    %-34s = %s', name, tostring(got)))
    end
end

-- Cardinal directions from the origin. SM64: yaw 0 => +Z, yaw 16384 => +X,
-- yaw 32768 => -Z, yaw 49152 => -X.
check('to +Z is yaw 0', Engine.angle_to_point(0, 0, 0, 100), 0)
check('to +X is yaw 16384', Engine.angle_to_point(0, 0, 100, 0), 16384)
check('to -Z is yaw 32768', Engine.angle_to_point(0, 0, 0, -100), 32768)
check('to -X is yaw 49152', Engine.angle_to_point(0, 0, -100, 0), 49152)

-- A 45-degree diagonal toward (+X, +Z) is yaw 8192.
check('to (+X,+Z) is yaw 8192', Engine.angle_to_point(0, 0, 50, 50), 8192)

-- Translation invariance: only the relative offset matters.
check('translation invariant', Engine.angle_to_point(1000, -250, 1100, -250), 16384)

-- atan2s argument order (z, x) matches the game's convention.
check('atan2s(+z,0) = 0', Engine.atan2s(1, 0), 0)
check('atan2s(0,+x) = 16384', Engine.atan2s(0, 1), 16384)

-- Distance is plain Euclidean XZ distance.
check_num('distance 3-4-5', Engine.distance_to_point(0, 0, 3, 4), 5)
check_num('distance zero', Engine.distance_to_point(7, 7, 7, 7), 0)

-- distance_to_target reads Memory/Settings.
Memory.current.mario_x = 10
Memory.current.mario_z = 10
Settings.tas.target_x = 13
Settings.tas.target_z = 14
check_num('distance_to_target', Engine.distance_to_target(), 5)

-- ---------------------------------------------------------------------------
print(string.format('\n%d checks, %d failure(s)', checks, failures))
if failures > 0 then
    os.exit(1)
end
