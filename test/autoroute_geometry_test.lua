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

-- active_target: single point when no waypoints.
Settings.tas.waypoints = {}
local ax, az = Engine.active_target()
check_num('active_target x (point)', ax, 13)
check_num('active_target z (point)', az, 14)

-- active_target: current waypoint when a path exists.
Settings.tas.waypoints = { { x = 100, z = 200 }, { x = -5, z = -5 } }
Settings.tas.waypoint_index = 2
ax, az = Engine.active_target()
check_num('active_target x (waypoint)', ax, -5)
check_num('active_target z (waypoint)', az, -5)

-- advance_waypoint: mid-path advances, no completion.
local ni, complete = Engine.advance_waypoint(1, 3, false)
check_num('advance 1/3 -> 2', ni, 2)
check_num('advance 1/3 not complete', complete and 1 or 0, 0)

-- advance_waypoint: last waypoint, no loop -> stay + complete.
ni, complete = Engine.advance_waypoint(3, 3, false)
check_num('advance 3/3 -> 3', ni, 3)
check_num('advance 3/3 complete', complete and 1 or 0, 1)

-- advance_waypoint: last waypoint, loop -> wrap to 1, not complete.
ni, complete = Engine.advance_waypoint(3, 3, true)
check_num('advance 3/3 loop -> 1', ni, 1)
check_num('advance 3/3 loop not complete', complete and 1 or 0, 0)

-- eta_frames: distance / speed, huge when stopped.
check_num('eta 100u @ 25u/f = 4f', Engine.eta_frames(100, 25), 4)
check_num('eta stopped is huge', Engine.eta_frames(100, 0) == math.huge and 1 or 0, 1)

-- path_total_length: sum of segments (3-4-5 triangle perimeter minus hypotenuse).
local square = { { x = 0, z = 0 }, { x = 0, z = 10 }, { x = 10, z = 10 } }
check_num('path_total_length', Engine.path_total_length(square), 20)
check_num('path_total_length single', Engine.path_total_length({ { x = 1, z = 1 } }), 0)
check_num('path_total_length empty', Engine.path_total_length({}), 0)

-- path_remaining_length: from position to current waypoint + rest.
-- At (0, -5), heading to waypoint 1 (0,0): 5 + segment1 (10) + segment2 (10) = 25.
check_num('path_remaining full', Engine.path_remaining_length(square, 1, 0, -5), 25)
-- Already at last waypoint (10,10), index 3: just distance to it.
check_num('path_remaining last', Engine.path_remaining_length(square, 3, 10, 0), 10)

-- nearest_waypoint_index.
check_num('nearest is 2', Engine.nearest_waypoint_index(square, 1, 9), 2)
check_num('nearest empty is nil', Engine.nearest_waypoint_index({}, 0, 0) == nil and 1 or 0, 1)

-- sanitize_waypoints: drop malformed entries, keep numeric x/z.
local dirty = { { x = 1, z = 2 }, { x = 'bad', z = 3 }, { z = 4 }, 'nope', { x = 5, z = 6 } }
local clean = Engine.sanitize_waypoints(dirty)
check_num('sanitize keeps 2', #clean, 2)
check_num('sanitize entry1 x', clean[1].x, 1)
check_num('sanitize entry2 z', clean[2].z, 6)
check_num('sanitize non-table', #Engine.sanitize_waypoints('nope'), 0)

-- parse_coordinate_text: STROOP-style "X Y Z" uses x and z (skips y).
local p = Engine.parse_coordinate_text('1234.5 200 -678.9')
check_num('parse xyz count', #p, 1)
check_num('parse xyz x', p[1].x, 1234.5)
check_num('parse xyz z', p[1].z, -678.9)

-- Two numbers => x, z.
p = Engine.parse_coordinate_text('10, 20')
check_num('parse xz x', p[1].x, 10)
check_num('parse xz z', p[1].z, 20)

-- Multiple lines, mixed separators and parentheses; junk lines skipped.
p = Engine.parse_coordinate_text('(1, 2, 3)\nheader line\n4;5;6\n\t-7\t8\t9\nonlyone 5\n')
check_num('parse multiline count', #p, 3)
check_num('parse multiline l1 x', p[1].x, 1)
check_num('parse multiline l1 z', p[1].z, 3)
check_num('parse multiline l2 z', p[2].z, 6)
check_num('parse multiline l3 x', p[3].x, -7)

-- Non-string input yields empty.
check_num('parse non-string', #Engine.parse_coordinate_text(nil), 0)

-- reverse_waypoints: order flipped, input not mutated.
local orig = { { x = 1, z = 1 }, { x = 2, z = 2 }, { x = 3, z = 3 } }
local rev = Engine.reverse_waypoints(orig)
check_num('reverse count', #rev, 3)
check_num('reverse first x', rev[1].x, 3)
check_num('reverse last x', rev[3].x, 1)
check_num('reverse no mutation', orig[1].x, 1)
check_num('reverse non-table', #Engine.reverse_waypoints(nil), 0)
check_num('reverse empty', #Engine.reverse_waypoints({}), 0)

-- active_target clamps an out-of-range waypoint_index.
Settings.tas.waypoints = { { x = 7, z = 8 } }
Settings.tas.waypoint_index = 99
local cx, cz = Engine.active_target()
check_num('active_target clamps x', cx, 7)
check_num('active_target clamps z', cz, 8)
Settings.tas.waypoints = {}
Settings.tas.waypoint_index = 1

-- ---------------------------------------------------------------------------
print(string.format('\n%d checks, %d failure(s)', checks, failures))
if failures > 0 then
    os.exit(1)
end
