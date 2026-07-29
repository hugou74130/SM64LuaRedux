--
-- Copyright (c) 2025, Mupen64 maintainers.
--
-- SPDX-License-Identifier: GPL-2.0-or-later
--

--
-- Bruteforce (pure core)
--
-- This module contains ONLY pure logic: candidate generation (input perturbation),
-- frame-minimisation bookkeeping and search-loop control. It performs NO emulator calls,
-- so it is fully unit-testable off-mupen (see tests/bruteforce_test.lua).
--
-- The emulator-facing driver (views/Bruteforce.lua) feeds candidates from here into the game,
-- measures how many frames each takes to reach the semantic goal (a target Mario action) and
-- reports the result back. This module keeps the best (fewest-frame) input list found.
--

Bruteforce = {}

-- Button fields of a JoypadInputs table that we may perturb (the jump / action buttons).
-- Stick X/Y are handled separately. START / dpad / C are never touched (they change intent).
local PERTURB_BUTTONS = { 'A', 'B', 'Z' }

-- Known SM64 movement techniques, as button stamps laid over consecutive frames from an insertion
-- point (the stick is left alone, so Mario keeps heading where the baseline was already heading).
--
-- Why this exists: every other operator is subtractive or corrective — it removes frames, retimes an
-- EXISTING button edge, or jitters the stick. None of them can INVENT a movement the baseline does not
-- contain, so a segment that is slow because it walks where it should have dived/long-jumped is
-- unimprovable no matter how long the search runs (a plain walk has no button edges to retime, and
-- landing "A here, then B two frames later" by random flips essentially never happens).
--
-- The search only PROPOSES these; the emulator judges. A pattern that does not apply in Mario's
-- current state simply fails to reach the goal and costs one candidate, so this table does not have to
-- be a perfect model of SM64 — it just has to name the moves worth trying.
-- An empty stamp frame means "leave this frame alone" (the airborne gap inside a dive).
-- The SAME stamp means different moves depending on Mario's state (B is a dive while running but a
-- punch standing still; Z+A is a long jump running and a backflip stationary), which is exactly why
-- proposing rather than modelling works: one entry covers every state it applies in.
local TECHNIQUES = {
    -- airborne distance
    { name = 'jump', stamp = { { A = true } } },
    { name = 'double_jump', stamp = { { A = true }, {}, {}, { A = true } } },
    { name = 'longjump', stamp = { { Z = true, A = true } } },
    { name = 'longjump_z', stamp = { { Z = true }, { Z = true, A = true } } },
    { name = 'longjump_dive', stamp = { { Z = true, A = true }, {}, { B = true } } },
    { name = 'backflip', stamp = { { Z = true }, {}, { A = true } } },
    -- dives: fast, cover ground, end in a slide
    { name = 'dive', stamp = { { A = true }, { B = true } } },
    { name = 'dive_late', stamp = { { A = true }, {}, { B = true } } },
    { name = 'dive_ground', stamp = { { B = true } } },
    { name = 'dive_recover', stamp = { { B = true }, {}, {}, {}, { A = true } } },
    -- ground moves
    { name = 'slide_kick', stamp = { { Z = true, B = true } } },
    { name = 'crouch_slide', stamp = { { Z = true } } },
    { name = 'ground_pound', stamp = { { A = true }, {}, { Z = true } } },
}
Bruteforce._TECHNIQUES = TECHNIQUES

-- Upper bound on how many technique candidates one sweep may queue, so a long segment cannot flood
-- the budget with them (positions are strided to fit). This budget is shared across ALL techniques,
-- so it scales with the size of the table: too low and adding a technique silently buys variety by
-- giving up position granularity, which matters because a move landed a few frames off usually fails.
local TECH_MAX_ENTRIES = 900

-- Window lengths for the aim sweep, in frames (0 = from the start point to the end of the run).
-- Re-aiming a single frame almost never saves one; travelling a whole stretch straighter does, so the
-- windows span from a short correction to the entire remainder.
local AIM_WINDOWS = { 8, 16, 32, 64, 0 }
local AIM_MAX_ENTRIES = 320

local function clamp(min, n, max)
    if n < min then return min end
    if n > max then return max end
    return n
end

---Builds a deterministic RNG (a linear congruential generator) from an integer seed. Returns a
---function yielding floats in [0,1), like math.random(). Used so a search can be made reproducible
---(same seed → same candidates), which also lets the stochastic operators be unit-tested.
---@param seed integer
---@return fun():number
local function make_lcg(seed)
    local s = seed % 2147483648
    if s <= 0 then s = 1 end
    return function()
        s = (1103515245 * s + 12345) % 2147483648
        return s / 2147483648
    end
end
Bruteforce.make_lcg = make_lcg

---Deep-clones a single JoypadInputs table. Missing button fields default to false, stick to 0.
---@param input table|nil
---@return table
local function clone_input(input)
    input = input or {}
    return {
        A = input.A or false,
        B = input.B or false,
        Z = input.Z or false,
        L = input.L or false,
        R = input.R or false,
        start = input.start or false,
        up = input.up or false,
        down = input.down or false,
        left = input.left or false,
        right = input.right or false,
        Cup = input.Cup or false,
        Cdown = input.Cdown or false,
        Cleft = input.Cleft or false,
        Cright = input.Cright or false,
        X = input.X or 0,
        Y = input.Y or 0,
    }
end

---Deep-clones an input list (array of JoypadInputs).
---@param list table[]
---@return table[]
local function clone_list(list)
    local out = {}
    for i = 1, #list do
        out[i] = clone_input(list[i])
    end
    return out
end

Bruteforce.clone_input = clone_input
Bruteforce.clone_list = clone_list

---Wraps raw bruteforce frames (final resolved JoypadInputs: X/Y sticks + button booleans) into
---full Semantic Workflow SectionInputs — the exact per-frame shape a sheet's sections hold. Each
---input plays exactly ONE frame (`timeout = 1`, `end_action = 0` i.e. disabled) and uses a MANUAL
---TAS state whose manual_joystick_x/y equal the recorded stick, so the TAS engine reproduces the
---stick bit-exact, while the buttons ride in `joy`. The result can be written straight into a
---sheet's sections (Sheet:apply_optimized_inputs), making the optimization real, editable content.
---Dependencies are injected (tas_factory, manual_mode) to keep this pure and unit-testable off-mupen.
---@param frames table[] the raw frames (e.g. a search state's best_list)
---@param count integer how many frames to take (e.g. best_frames)
---@param tas_factory fun():table returns a fresh TAS state table (NewTASState in-app)
---@param manual_mode integer the MovementModes.manual value
---@return table[] inputs list of frame-exact SectionInputs
function Bruteforce.to_overrides(frames, count, tas_factory, manual_mode)
    local out = {}
    for i = 1, count do
        local f = frames[i] or {}
        local st = tas_factory()
        st.movement_mode = manual_mode
        st.manual_joystick_x = f.X or 0
        st.manual_joystick_y = f.Y or 0
        out[i] = { tas_state = st, joy = clone_input(f), timeout = 1, end_action = 0, editing = false }
    end
    return out
end

---Estimates, for every baseline frame, the FULL-DEFLECTION stick direction that points at the goal —
---without reading the camera. The trick: the captured baseline already pairs each stick input with
---the world movement it produced, so the per-frame stick->world rotation is simply
---`world_angle(movement) - stick_angle(input)`. Frames with no usable signal (deadzone stick, or
---Mario barely moved) inherit the nearest valid estimate. The result drives the goal-aiming
---mutation: directed search toward the target instead of blind stick noise. Pure.
---@param inputs table[] the baseline inputs (1..n)
---@param states table per-frame Mario states, 0-INDEXED: states[0] = before any input, states[i] = after input i ({ x, z })
---@param goal table { x, z } the goal position
---@return table|nil aims array 1..n of unit stick directions { x, y }, or nil when nothing usable
function Bruteforce.estimate_aims(inputs, states, goal)
    if goal == nil or goal.x == nil or goal.z == nil then return nil end
    local n = #inputs
    local thetas = {}
    for i = 1, n do
        local s0, s1, inp = states[i - 1], states[i], inputs[i]
        if s0 and s1 and inp then
            local dx = (s1.x or 0) - (s0.x or 0)
            local dz = (s1.z or 0) - (s0.z or 0)
            local sx, sy = inp.X or 0, inp.Y or 0
            if math.sqrt(dx * dx + dz * dz) >= 1 and math.sqrt(sx * sx + sy * sy) >= 8 then
                thetas[i] = math.atan(dz, dx) - math.atan(sy, sx)
            end
        end
    end
    -- fill gaps from the nearest valid estimate (backward pass, then forward pass)
    local last = nil
    for i = 1, n do
        if thetas[i] ~= nil then last = thetas[i] elseif last ~= nil then thetas[i] = last end
    end
    last = nil
    for i = n, 1, -1 do
        if thetas[i] ~= nil then last = thetas[i] elseif last ~= nil then thetas[i] = last end
    end
    local aims, any = {}, false
    for i = 1, n do
        local th = thetas[i]
        local s = states[i - 1] or states[i]
        if th ~= nil and s ~= nil then
            local g = math.atan(goal.z - (s.z or 0), goal.x - (s.x or 0))
            local a = g - th
            aims[i] = { x = math.cos(a), y = math.sin(a) }
            any = true
        end
    end
    return any and aims or nil
end

---Shortest distance between two SM64 u16 angles (0..65535 == 360 degrees), handling wraparound.
---@param a integer
---@param b integer
---@return integer 0..32768
function Bruteforce.angle_diff(a, b)
    local d = math.abs((a - b) % 65536)
    return math.min(d, 65536 - d)
end

---Whether Mario's current state matches the goal state within tolerances. This is the ACCEPTANCE
---criterion for a reached candidate. Matching more than action+position — also horizontal speed and
---facing angle — is what makes an optimization CHAIN-SAFE: a segment that ends in the same state
---leaves every downstream sheet seeing the same start, so it does not desync the rest of the TAS.
---Any goal field that is nil is not checked (backward compatible: a position-only or action-only
---goal still works). Pure.
---
---The speed check is deliberately ASYMMETRIC. Arriving at the goal with MORE horizontal speed than
---the baseline is what a genuine frame-saving looks like in SM64 — it is a better handoff state, not
---a desync risk — so it must not be rejected. A symmetric tolerance here structurally forbade every
---real route improvement and let only trivial dead-frame removals through, which is why searches
---converged almost immediately on a one-frame gain. Arriving SLOWER is still bounded tightly
---(`speed_tol`): that is a genuinely worse handoff and the case that broke downstream sheets.
---`speed_tol_up` bounds the fast side generously but not infinitely, so an absurd speed (a different
---route/glitch rather than a tightened line) is still refused. Passing `speed_tol_up` as nil keeps
---the old symmetric behaviour.
---@param cur table { action, x, y, z, h_speed, yaw }
---@param goal table { action, x, y, z, h_speed, yaw } — nil fields are skipped
---@param radius number position tolerance (game units); nil/goal.x nil skips the position check
---@param speed_tol number|nil how much SLOWER than the goal is accepted; nil (or goal.h_speed nil) skips it
---@param angle_tol number|nil facing-angle tolerance (u16 units); nil (or goal.yaw nil) skips it
---@param speed_tol_up number|nil how much FASTER than the goal is accepted; nil = symmetric (uses speed_tol)
---@return boolean
function Bruteforce.state_matches_goal(cur, goal, radius, speed_tol, angle_tol, speed_tol_up)
    if goal.action ~= nil and cur.action ~= goal.action then return false end
    if goal.x ~= nil and radius ~= nil then
        local dx = (cur.x or 0) - goal.x
        local dy = (cur.y or 0) - (goal.y or 0)
        local dz = (cur.z or 0) - goal.z
        if dx * dx + dy * dy + dz * dz > radius * radius then return false end
    end
    if goal.h_speed ~= nil and speed_tol ~= nil then
        local delta = (cur.h_speed or 0) - goal.h_speed
        if delta < -speed_tol then return false end
        if delta > (speed_tol_up or speed_tol) then return false end
    end
    if goal.yaw ~= nil and angle_tol ~= nil then
        if Bruteforce.angle_diff(cur.yaw or 0, goal.yaw) > angle_tol then return false end
    end
    return true
end

---Whether any sheet in `sheets` chains (directly or transitively) off `sheet` — i.e. whether anything
---downstream would be broken by changing this segment's end state. This decides whether the search has
---to stay chain-safe at all: in the normal flow a sheet is bruteforced BEFORE the next one is written,
---so nothing depends on its end state and constraining the end speed/angle would only reject real
---gains. Guards against a malformed base cycle (hand-edited project) so it can never spin. Pure.
---@param sheets table[]|nil every sheet in the project
---@param sheet table|nil the sheet being optimized
---@return boolean
function Bruteforce.has_dependents(sheets, sheet)
    if sheets == nil or sheet == nil then return false end
    for i = 1, #sheets do
        local other = sheets[i]
        if other ~= nil and other ~= sheet then
            local base = other._base_sheet
            local seen = {}
            while base ~= nil and not seen[base] do
                if base == sheet then return true end
                seen[base] = true
                base = base._base_sheet
            end
        end
    end
    return false
end

---Derives a goal radius from how far Mario actually travels per frame near the goal, so the tolerance
---is never a number the user has to guess.
---
---The scale that matters is ONE FRAME OF TRAVEL. Mario's positions are sampled once per frame, so a
---radius below that lets him step straight over the goal without ever being measured inside it (the
---goal would never be reached); a radius far above it lets the goal fire while he is merely PASSING,
---several frames before he actually arrives — which inflates the gain by that slack and truncates the
---applied result. Both failures were observed. Taking the fastest of the last few frames keeps the
---radius catchable, and the 1.5 factor leaves margin for a candidate approaching on a slightly
---different line. Clamped so a stopped Mario still gets a usable tolerance and a teleport/glitch frame
---cannot blow it up. Pure.
---@param states table per-frame positions { x, y, z }, indexed 0..n (states[0] = before any input)
---@param n integer the goal frame index
---@param opts table|nil { factor, min, max }
---@return number|nil radius nil when there is not enough position data
function Bruteforce.auto_goal_radius(states, n, opts)
    if states == nil or n == nil or n < 1 then return nil end
    opts = opts or {}
    local travel = nil
    for i = math.max(1, n - 2), n do
        local a, b = states[i - 1], states[i]
        if a ~= nil and b ~= nil then
            local dx = (b.x or 0) - (a.x or 0)
            local dy = (b.y or 0) - (a.y or 0)
            local dz = (b.z or 0) - (a.z or 0)
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if travel == nil or d > travel then travel = d end
        end
    end
    if travel == nil then return nil end
    return clamp(opts.min or 5, travel * (opts.factor or 1.5), opts.max or 150)
end

---Splits a captured baseline into `n` roughly-equal chunks and picks each chunk's goal checkpoint
---from the recorded per-frame Mario states (the state at the chunk's last frame). Long segments are
---optimised chunk by chunk (each chunk reaches its checkpoint, chained), which is far more tractable
---than searching the whole thing at once. Pure.
---@param baseline table[] the full baseline input list
---@param states table[] per-frame { action, x, y, z }, aligned with baseline
---@param n integer desired number of chunks (>= 1)
---@return table[] chunks array of { inputs = table[], checkpoint = { action, x, y, z } }
function Bruteforce.split(baseline, states, n)
    local total = #baseline
    n = math.max(1, math.min(n, math.max(1, total)))
    local chunk_len = math.max(1, math.ceil(total / n))
    local chunks = {}
    local from = 1
    while from <= total do
        local to = math.min(from + chunk_len - 1, total)
        local inputs = {}
        for i = from, to do
            inputs[#inputs + 1] = clone_input(baseline[i])
        end
        local cp = states[to] or states[#states] or {}
        chunks[#chunks + 1] = {
            inputs = inputs,
            checkpoint = { action = cp.action, x = cp.x, y = cp.y, z = cp.z },
            from = from, -- 1-based baseline frame this chunk starts at (for per-chunk aim estimation)
        }
        from = to + 1
    end
    return chunks
end

--#region m64 export (pure encoding helpers)

-- Button bit layout of a mupen .m64 input word (the standard N64 BUTTONS bitfield, read as a
-- little-endian u16). D-pad in the low nibble, then Start/Z/B/A, then the C buttons, then R/L
-- triggers. Getting this wrong maps e.g. Z onto L_TRIG (0x2000), which is exactly what happened.
local M64_BUTTON_BITS = {
    right = 0x0001, left = 0x0002, down = 0x0004, up = 0x0008,
    start = 0x0010, Z = 0x0020, B = 0x0040, A = 0x0080,
    Cright = 0x0100, Cleft = 0x0200, Cdown = 0x0400, Cup = 0x0800,
    R = 0x1000, L = 0x2000,
}

-- Header field offsets (0-based) in a mupen .m64 that we patch when re-heading a copied movie.
local M64_OFF_VI_COUNT = 0x00C   -- u32: number of VIs
local M64_OFF_SAMPLES = 0x018    -- u32: number of input samples (frames)
local M64_OFF_START_TYPE = 0x01C -- u16: 1 = from savestate, 2 = from power-on
Bruteforce.M64_HEADER_SIZE = 0x400

---Encodes one JoypadInputs table into its 4-byte mupen .m64 representation (2-byte buttons + X + Y).
---@param joy table
---@return string bytes A 4-byte string.
function Bruteforce.encode_m64_input(joy)
    local bits = 0
    for field, mask in pairs(M64_BUTTON_BITS) do
        if joy[field] then bits = bits | mask end
    end
    local x = clamp(-128, math.floor(joy.X or 0), 127)
    local y = clamp(-128, math.floor(joy.Y or 0), 127)
    return string.pack('<I2', bits) .. string.pack('b', x) .. string.pack('b', y)
end

---Replaces `count` bytes at 0-based `offset` of `str` with `bytes` (whose length must equal count).
---@param str string
---@param offset integer 0-based
---@param bytes string
---@return string
local function patch_bytes(str, offset, bytes)
    return str:sub(1, offset) .. bytes .. str:sub(offset + #bytes + 1)
end

---Re-heads a copied .m64 header for a from-savestate movie of `frame_count` input frames.
---@param header string The original movie's 0x400-byte header.
---@param frame_count integer
---@return string header The patched header.
function Bruteforce.reheader_m64(header, frame_count)
    header = patch_bytes(header, M64_OFF_VI_COUNT, string.pack('<I4', frame_count * 2))
    header = patch_bytes(header, M64_OFF_SAMPLES, string.pack('<I4', frame_count))
    header = patch_bytes(header, M64_OFF_START_TYPE, string.pack('<I2', 1)) -- from savestate
    return header
end

---Builds the .m64 input body for the first `count` frames of an input list.
---@param list table[]
---@param count integer
---@return string body
function Bruteforce.build_m64_body(list, count)
    local parts = {}
    for i = 1, count do
        parts[i] = Bruteforce.encode_m64_input(list[i] or clone_input(nil))
    end
    return table.concat(parts)
end

---Splices `optimized_body` into a full .m64, replacing `seg_len` input frames starting at
---`start_frame` (0-based movie frame). The whole file structure is preserved (header, any embedded
---savestate, and the inputs outside the segment); only the segment inputs and the frame counters
---change, so the result plays exactly like the source movie but with the optimised (shorter)
---segment. Input frames are read as the trailing `samples * 4` bytes, which is robust whether or
---not the movie embeds a savestate between the header and the inputs.
---@param movie_data string The full source .m64 file contents.
---@param start_frame integer 0-based movie frame where the segment starts.
---@param seg_len integer Number of input frames the original segment spans.
---@param optimized_body string The replacement input bytes (a multiple of 4 bytes).
---@return string|nil spliced The new .m64 contents, or nil on validation failure.
---@return string|nil error An error tag when spliced is nil.
function Bruteforce.splice_m64(movie_data, start_frame, seg_len, optimized_body)
    if #movie_data < Bruteforce.M64_HEADER_SIZE then return nil, 'movie_too_small' end
    local samples = string.unpack('<I4', movie_data, M64_OFF_SAMPLES + 1)
    local input_start = #movie_data - samples * 4 -- inputs are the trailing samples*4 bytes
    if input_start < Bruteforce.M64_HEADER_SIZE then return nil, 'bad_input_offset' end
    if start_frame < 0 or seg_len < 0 or start_frame + seg_len > samples then
        return nil, 'segment_out_of_range'
    end
    if #optimized_body % 4 ~= 0 then return nil, 'bad_body' end

    local seg_start_byte = input_start + start_frame * 4        -- 0-based
    local seg_end_byte = input_start + (start_frame + seg_len) * 4 -- 0-based, exclusive
    local new_total = samples - seg_len + (#optimized_body // 4)

    local spliced = movie_data:sub(1, seg_start_byte) .. optimized_body .. movie_data:sub(seg_end_byte + 1)
    spliced = patch_bytes(spliced, M64_OFF_SAMPLES, string.pack('<I4', new_total))
    spliced = patch_bytes(spliced, M64_OFF_VI_COUNT, string.pack('<I4', new_total * 2))
    return spliced
end

--#endregion

---Creates a new bruteforce search state.
---@param opts table {
---  baseline: table[]            -- the recorded baseline input list (1-based, per frame),
---  baseline_frames: integer     -- frames the baseline took to reach the goal (the reference),
---  max_frames: integer          -- timeout: candidates not reaching the goal within this are rejected,
---  perturb_chance: number       -- 0..1, probability a frame's stick is perturbed,
---  perturb_magnitude: integer   -- stick nudge amplitude (+/-),
---  flip_chance: number          -- 0..1, probability a jump button is flipped on a perturbed frame,
---  budget: integer              -- maximum number of candidates to try,
---  pulse_after: integer|nil     -- raise magnitude after this many non-improving candidates (default 40),
---  rng: fun():number|nil        -- returns a float in [0,1); defaults to math.random,
--- }
---@return table state
function Bruteforce.new(opts)
    assert(opts.baseline and #opts.baseline > 0, 'bruteforce: baseline must be a non-empty input list')
    local baseline = clone_list(opts.baseline)
    local baseline_frames = opts.baseline_frames or #baseline
    local state = {
        baseline = baseline,
        baseline_frames = baseline_frames,
        max_frames = opts.max_frames or baseline_frames,
        perturb_chance = opts.perturb_chance or 0.25,
        base_magnitude = opts.perturb_magnitude or 8,
        flip_chance = opts.flip_chance or 0.05,  -- per-frame chance to toggle a jump button (A/B/Z timing)
        remove_chance = opts.remove_chance or 0.15, -- chance a candidate drops a frame (direct frame-min)
        remove_redundant_bias = opts.remove_redundant_bias or 0.7, -- of removals, how often to target a neutral/duplicate frame
        multi_remove_chance = opts.multi_remove_chance or 0.15, -- chance a removal drops a short run (2-3) at once
        edge_nudge_chance = opts.edge_nudge_chance or 0.15, -- chance to slide a jump-button edge in time (timing search)
        insert_chance = opts.insert_chance or 0.08, -- chance a candidate duplicates a frame (compensates a removal / delays a tail)
        -- Goal-aiming operator: per-frame full-deflection stick directions pointing at the goal,
        -- estimated from the captured baseline (see estimate_aims). nil disables the operator.
        aims = opts.aims,
        aim_chance = opts.aim_chance or 0.08,   -- chance a perturbed frame snaps to its goal-aim direction
        hold_chance = opts.hold_chance or 0.06, -- chance to smooth a short window into one held stick
        rotate_chance = opts.rotate_chance or 0.15, -- chance a frame's stick is ROTATED (angle search, magnitude kept)
        rotate_max_rad = opts.rotate_max_rad or 0.25, -- max rotation (radians) of a single stick rotation
        snap_chance = opts.snap_chance or 0.10,     -- chance a frame's stick is snapped to FULL deflection (127), angle kept
        crossover_chance = opts.crossover_chance or 0.15, -- chance to recombine two beam parents instead of mutating one
        window_chance = opts.window_chance or 0.35, -- chance to perturb only a local window (vs the whole editable region)
        window_frac = opts.window_frac or 0.25,     -- window size as a fraction of the editable length
        window_min = opts.window_min or 4,          -- minimum window length (below this, always perturb the whole region)
        -- Improvement heatmap: frames whose mutations produced improvements accumulate heat, and
        -- local windows are drawn toward the hot zones — the search learns WHERE the frames live.
        heat = {},                                  -- frame index -> improvement credit
        heat_bias = opts.heat_bias or 0.4,          -- chance a local window is centered on the heatmap
        edit_from = opts.edit_from or 1, -- only perturb frames >= this (chunk mode freezes the optimised prefix)
        -- Early-abort pruning: once a best exists, a candidate that has not reached the goal by
        -- best_frames + prune_slack can no longer improve (the slack keeps near-ties for the beam's
        -- diversity / speed tie-break), so the driver cuts it there instead of running to max_frames.
        -- The search literally gets FASTER as it improves. See Bruteforce.cutoff.
        prune_slack = opts.prune_slack or 2,
        -- Mid-run checkpoint (set by the driver via set_checkpoint after it snapshots the best run's
        -- state at this frame): candidates tagged preserve_prefix leave frames 1..checkpoint_frame
        -- untouched, so the driver can replay them FROM the checkpoint — half the emulator frames.
        checkpoint_frame = nil,
        suffix_prob = opts.suffix_prob or 0.5, -- chance to generate a checkpoint-compatible (suffix-only) mutation
        -- Candidate dedupe: never spend an emulator run on an input list already tried.
        dedupe = opts.dedupe ~= false,
        seen = {},       -- candidate hash -> true
        seen_count = 0,
        budget = opts.budget or 2000,
        -- Convergence auto-stop: after this many candidates without any improvement the search is
        -- declared converged and ends early (no point burning the rest of the budget). Scales with
        -- the budget so big searches get proportionally more patience.
        convergence_after = opts.convergence_after or math.max(200, math.floor((opts.budget or 2000) * 0.25)),
        -- Overtime: when the budget runs out on a HOT STREAK (a recent improvement), the search
        -- keeps going until the streak cools (overtime_grace stalls), capped at hard_cap candidates.
        overtime_grace = opts.overtime_grace or 100,
        hard_cap = opts.hard_cap or (opts.budget or 2000) * 2,
        pulse_after = opts.pulse_after or 40,
        -- rng: an explicit rng wins; else a seed gives a reproducible search; else math.random.
        rng = opts.rng or (opts.seed and make_lcg(opts.seed)) or math.random,

        best_list = clone_list(baseline),
        best_frames = baseline_frames,
        -- Deterministic removal sweep: right after any new best is found, systematically try
        -- "best minus one redundant frame" for every redundant frame (instead of hoping the random
        -- removal mutation hits them). This is the cheapest guaranteed way to shave frames.
        sweep_enabled = opts.sweep ~= false,
        sweep_queue = nil, -- removal indices still to try against the current best (end-first)
        sweep_pos = 1,
        sweep_base = nil,  -- the best_frames the queue was built for (rebuilt when it changes)
        -- The sweep re-anchors on every new best, and the technique injections are by far its most
        -- expensive tier (hundreds of entries, each a full emulator replay). Re-running ALL of them
        -- after every improvement is what makes a long search drag: the cost is (improvements x whole
        -- queue). They are therefore swept in full on the FIRST pass and then only every
        -- `tech_every` rebuilds; the cheap tiers (removals, button retimings) still run every time,
        -- which is what actually pays off right after an improvement. Set tech_every = 1 to restore
        -- the exhaustive-every-time behaviour.
        sweep_rebuilds = 0,
        tech_every = opts.tech_every or 4,
        -- Per-technique outcomes on THIS segment: { tries, reaches }. A technique with plenty of
        -- tries and zero reaches does not apply here and is dropped from later sweeps (rebuild_sweep).
        tech_stats = {},
        tech_min_trials = opts.tech_min_trials or 25,
        beam = {},                        -- top-K reached candidates {list, frames, hspeed}, fewest frames first
        beam_width = opts.beam_width or 5, -- how many parallel candidates the search keeps
        -- Soft-fitness explore pool: the closest-K candidates that did NOT reach the goal, kept so the
        -- search can perturb around near-misses to discover new reaching routes (makes the aggressive
        -- frame-removal / button-flip mutations productive instead of wasted when they overshoot).
        explore = {},                       -- {list, distance}, closest to the goal first
        explore_width = opts.explore_width or 5,
        explore_prob = opts.explore_prob or 0.3, -- chance to seed from a near-miss instead of a solution
        -- Quality-diversity archive (only fills when the driver reports per-candidate end-state).
        archive = {},                       -- cell_key -> { list, frames, reached, distance }
        archive_keys = {},                  -- array of occupied cell keys, for uniform random expansion
        archive_count = 0,
        archive_prob = opts.archive_prob or 0.35, -- chance to expand a random archive niche (diversity)
        cell_size = opts.cell_size or 100,        -- position grid size (game units) for the cell descriptor
        cell_speed_size = opts.cell_speed_size or 4, -- horizontal-speed bucket size for the cell descriptor
        tie_to_newcomer = opts.tie_to_newcomer or 0.3, -- on a cell fitness tie, chance the newcomer replaces
        tried = 0,
        improvements = 0,
        -- How many candidates ever reproduced the goal (baseline included). This is the single most
        -- diagnostic number when a search reports no gain: 0 means the goal is never being reached at
        -- all (bad goal / unreachable state), which is a completely different problem from "reached
        -- often but nothing shorter was accepted".
        reaches = 0,
        stagnation = 0,
        -- Perturbation magnitude/chance = a live floor (base_*) + annealing heat (proactive, high->low
        -- over the search) + a stagnation pulse (reactive). All three add up; see effective_*().
        pulse_bonus = 0,
        anneal = opts.anneal ~= false, -- on by default: explore hot early, refine cold late
        -- Cools to zero over the first `anneal_fraction` of the budget (default half), then stays
        -- cold to refine — so it scales to Max candidates: a small budget cools quickly.
        anneal_span = opts.anneal_span
            or math.max(1, math.floor((opts.budget or 2000) * (opts.anneal_fraction or 0.5))),
        anneal_hot_bonus = opts.anneal_hot_bonus or 32,        -- extra magnitude at full temperature
        anneal_hot_chance = opts.anneal_hot_chance or 0.25,    -- extra perturb chance at full temperature
        _first = true,          -- first candidate is the unperturbed baseline (re-measures the reference in-sim)
        _reference_set = false, -- the reference is re-based on the first in-loop measurement (see report_result)
    }
    return state
end

---The annealing temperature: 1.0 while hot at the start, decaying to 0.0 once `anneal_span`
---candidates have been tried (0 when annealing is disabled). Public for tests.
---@param state table
---@return number
function Bruteforce.temperature(state)
    if not state.anneal or state.anneal_span <= 0 then return 0 end
    return math.max(0, 1 - state.tried / state.anneal_span)
end

-- Effective perturbation magnitude = live floor (base_magnitude) + annealing heat + stagnation pulse.
local function effective_magnitude(state)
    local heat = math.floor(Bruteforce.temperature(state) * state.anneal_hot_bonus)
    return math.min(127, math.max(1, state.base_magnitude + heat + state.pulse_bonus))
end
Bruteforce._effective_magnitude = effective_magnitude

-- Effective per-frame perturb chance = base chance + annealing heat, clamped to [0, 1].
local function effective_chance(state)
    return math.min(1, state.perturb_chance + Bruteforce.temperature(state) * state.anneal_hot_chance)
end

---How many full stagnation periods (pulse_after candidates each) have passed without improvement.
---0 while progressing; grows one level per period while stuck; resets with the next improvement.
---Public for tests.
---@param state table
---@return integer
local function stagnation_level(state)
    if state.pulse_after <= 0 then return 0 end
    return math.floor(state.stagnation / state.pulse_after)
end
Bruteforce._stagnation_level = stagnation_level

---The stagnation escalation: while the search is improving these are exactly the base parameters,
---and each stagnation level widens them — more button flips and frame removals (structural changes,
---not just stick noise), more exploration from near-misses, LESS checkpoint suffix polish (fine
---polish is what is failing), and a wider prune window (slower-but-different routes get to finish
---and seed the beam/archive again instead of being cut). Everything snaps back the moment a better
---solution is found. Public for tests.
---@param state table
---@return table eff { flip_chance, remove_chance, suffix_prob, explore_prob, slack_bonus }
function Bruteforce.escalation(state)
    local level = stagnation_level(state)
    -- caps never go below the configured base, so an explicitly-high setting keeps its meaning
    return {
        flip_chance = math.min(math.max(0.5, state.flip_chance), state.flip_chance * (1 + level)),
        remove_chance = math.min(math.max(0.6, state.remove_chance), state.remove_chance * (1 + 0.5 * level)),
        suffix_prob = state.suffix_prob / (1 + level),
        explore_prob = math.min(math.max(0.6, state.explore_prob), state.explore_prob * (1 + 0.3 * level)),
        rotate_max_rad = math.min(math.pi, state.rotate_max_rad * (1 + 0.5 * level)),
        slack_bonus = 2 * level,
    }
end

-- Below this stick magnitude the game reads no movement (deadzone), so such a frame is a "wait".
local STICK_DEADZONE = 8

---A frame is "neutral" when it presses no jump button and its stick is inside the deadzone — i.e. a
---do-nothing wait frame. Dropping one of these is the likeliest way to save a frame while still
---reaching the goal (the meaningful inputs just happen one frame earlier).
---@param f table
---@return boolean
local function frame_is_neutral(f)
    return not f.A and not f.B and not f.Z
        and math.abs(f.X or 0) < STICK_DEADZONE and math.abs(f.Y or 0) < STICK_DEADZONE
end
Bruteforce._frame_is_neutral = frame_is_neutral

---Whether two frames apply the same controller state (same sticks + same jump buttons). A run of
---equal frames is a held input; dropping one shortens the hold, another cheap way to save a frame.
local function frames_equal(a, b)
    if (a.X or 0) ~= (b.X or 0) or (a.Y or 0) ~= (b.Y or 0) then return false end
    for _, btn in ipairs(PERTURB_BUTTONS) do
        if (a[btn] or false) ~= (b[btn] or false) then return false end
    end
    return true
end

-- How far two stick values may differ and still count as "the same held input" for the removal sweep.
local SWEEP_NEAR_TOL = 3

---Whether two frames are NEARLY the same controller state (same buttons, sticks within `tol`). The
---Semantic Workflow recomputes the stick from the intended angle through the LIVE camera every single
---frame, so a steadily-held direction comes out as values that wobble by a unit or two rather than
---repeating exactly. Against such a baseline an exact comparison finds almost no droppable frames,
---which left the deterministic removal sweep with an essentially empty queue on stick-driven
---segments (a plain walk has no button edges to sweep either). Pure.
local function frames_near_equal(a, b, tol)
    if math.abs((a.X or 0) - (b.X or 0)) > tol or math.abs((a.Y or 0) - (b.Y or 0)) > tol then
        return false
    end
    for _, btn in ipairs(PERTURB_BUTTONS) do
        if (a[btn] or false) ~= (b[btn] or false) then return false end
    end
    return true
end
Bruteforce._frames_near_equal = frames_near_equal

---Chooses a frame index to remove within [edit_from, #out]. Prefers "redundant" frames (neutral
---waits, or exact duplicates of the previous frame) because dropping those most often still reaches
---the goal — it just shifts the meaningful inputs earlier. Falls back to a uniformly random frame so
---the search can still discover savings that require cutting a meaningful frame. Public for tests.
---@param state table
---@param out table[]
---@return integer|nil index
local function pick_removal_index(state, out)
    local lo, hi = state.edit_from, #out
    if hi <= lo then return nil end
    if state.rng() < state.remove_redundant_bias then
        local redundant = {}
        for i = lo, hi do
            if frame_is_neutral(out[i]) or (i > lo and frames_equal(out[i], out[i - 1])) then
                redundant[#redundant + 1] = i
            end
        end
        if #redundant > 0 then
            return redundant[math.floor(state.rng() * #redundant) + 1]
        end
    end
    return lo + math.floor(state.rng() * (hi - lo + 1))
end
Bruteforce._pick_removal_index = pick_removal_index

---Frame-removal mutation (in place): with probability remove_chance, delete one frame — or, with
---probability multi_remove_chance, a short run of 2-3 — from the editable region, preferring redundant
---frames. Dropping a frame shifts the action earlier; if the candidate still reaches the goal that is
---a frame saved outright. Returns how many frames were removed. Public for tests.
---@param state table
---@param out table[]
---@return integer removed
local function apply_removal(state, out)
    if (#out - state.edit_from + 1) <= 1
        or state.rng() >= Bruteforce.escalation(state).remove_chance then
        return 0
    end
    local n_remove = 1
    if state.rng() < state.multi_remove_chance then
        n_remove = 2 + math.floor(state.rng() * 2) -- 2 or 3 frames at once
    end
    local removed = 0
    for _ = 1, n_remove do
        if (#out - state.edit_from + 1) <= 1 then break end
        local idx = pick_removal_index(state, out)
        if idx == nil then break end
        table.remove(out, idx)
        removed = removed + 1
    end
    return removed
end
Bruteforce._apply_removal = apply_removal

---Chooses the frame range to perturb within [lo, hi]. Usually the whole editable region, but with
---probability window_chance it restricts to a random contiguous WINDOW — a local search that tweaks
---one part of a long input sequence without disturbing the rest, which finds precise timing gains on
---long segments that a global shake would keep destroying. Public for tests.
---@param state table
---@param lo integer
---@param hi integer
---@return integer wlo
---@return integer whi
local function pick_window(state, lo, hi)
    local span = hi - lo + 1
    if span <= state.window_min or state.rng() >= state.window_chance then
        return lo, hi
    end
    local wlen = math.max(state.window_min, math.floor(span * state.window_frac))
    if wlen >= span then return lo, hi end
    -- Heatmap draw: center the window on a frame sampled by improvement credit (hot frames win),
    -- so the local search concentrates where mutations have actually been paying off.
    if state.heat_bias > 0 and next(state.heat) ~= nil and state.rng() < state.heat_bias then
        local total = 0
        for i = lo, hi do total = total + 0.1 + (state.heat[i] or 0) end
        local r = state.rng() * total
        local acc, center = 0, hi
        for i = lo, hi do
            acc = acc + 0.1 + (state.heat[i] or 0)
            if acc >= r then
                center = i
                break
            end
        end
        local wlo = clamp(lo, center - math.floor(wlen / 2), hi - wlen + 1)
        return wlo, wlo + wlen - 1
    end
    local wlo = lo + math.floor(state.rng() * (span - wlen + 1))
    return wlo, wlo + wlen - 1
end
Bruteforce._pick_window = pick_window

---Edge-nudge mutation (in place): shifts a single jump-button (A/B/Z) press/release EDGE earlier or
---later by 1-3 frames. In SM64 most frame losses are button TIMING (late jump, held-too-long dive),
---not stick noise — so a dedicated operator that slides one edge hits exactly the axis frame-reduction
---lives on, far more efficiently than random button flips. Returns whether it moved an edge. Public.
---@param state table
---@param out table[]
---@return boolean moved
local function apply_edge_nudge(state, out)
    if state.rng() >= state.edge_nudge_chance then return false end
    local b = PERTURB_BUTTONS[math.floor(state.rng() * #PERTURB_BUTTONS) + 1]
    local edges = {}
    for i = math.max(state.edit_from + 1, 2), #out do
        if (out[i][b] or false) ~= (out[i - 1][b] or false) then
            edges[#edges + 1] = i
        end
    end
    if #edges == 0 then return false end
    local e = edges[math.floor(state.rng() * #edges) + 1]
    local delta = 1 + math.floor(state.rng() * 3) -- 1..3 frames
    if state.rng() < 0.5 then
        -- move the edge EARLIER: extend the post-edge value backwards
        local newval = out[e][b] or false
        for i = math.max(state.edit_from, e - delta), e - 1 do out[i][b] = newval end
    else
        -- move the edge LATER: extend the pre-edge value forwards
        local oldval = out[e - 1][b] or false
        for i = e, math.min(#out, e + delta - 1) do out[i][b] = oldval end
    end
    return true
end
Bruteforce._apply_edge_nudge = apply_edge_nudge

---Frame-insertion mutation (in place): with probability insert_chance, duplicate one frame of the
---editable region. Insertion delays everything after it by a frame — the counterpart of removal,
---letting the search fix a timing that removal alone broke (e.g. drop a wait early, add one later).
---The list is trimmed back to max_frames by the caller, so this never exceeds the timeout. Public.
---@param state table
---@param out table[]
---@return boolean inserted
local function apply_insert(state, out)
    if state.insert_chance <= 0 or state.rng() >= state.insert_chance then return false end
    local lo, hi = state.edit_from, #out
    if hi < lo then return false end
    local idx = lo + math.floor(state.rng() * (hi - lo + 1))
    table.insert(out, idx, clone_input(out[idx]))
    return true
end
Bruteforce._apply_insert = apply_insert

---Hold-smoothing mutation (in place): with probability hold_chance, copy one frame's stick over a
---short following window (2-8 frames). Optimal SM64 inputs are usually clean HELD sticks; random
---perturbation accumulates noise, and this operator is the counter-pressure that simplifies a noisy
---stretch back into a hold. Buttons are untouched. Public for tests.
---@param state table
---@param out table[]
---@return boolean held
local function apply_hold(state, out)
    if state.hold_chance <= 0 or state.rng() >= state.hold_chance then return false end
    local lo, hi = state.edit_from, #out
    if hi - lo < 2 then return false end
    local len = 2 + math.floor(state.rng() * 7) -- 2..8 frames
    local s = lo + math.floor(state.rng() * (hi - lo - 1))
    local e = math.min(hi, s + len - 1)
    local X, Y = out[s].X, out[s].Y
    for i = s + 1, e do
        out[i].X = X
        out[i].Y = Y
    end
    return true
end
Bruteforce._apply_hold = apply_hold

---Produces a perturbed copy of the given input list.
---@param state table
---@param source table[]
---@return table[]
local function perturb(state, source)
    local out = clone_list(source)

    apply_removal(state, out)
    apply_insert(state, out)

    -- Pad to the timeout length (the tail is ignored once the goal is reached)...
    for i = #out + 1, state.max_frames do
        out[i] = clone_input(out[#out] or source[#source])
    end
    -- ...and trim back down to it (an insertion may have pushed one frame past the timeout).
    for i = #out, state.max_frames + 1, -1 do
        out[i] = nil
    end

    apply_hold(state, out)

    local mag = effective_magnitude(state)
    local chance = effective_chance(state)
    local eff = Bruteforce.escalation(state) -- flips & rotation escalate while the search stalls
    -- Perturb either the whole editable region or a local window (see pick_window). Never touches the
    -- frozen prefix (frames before edit_from), which chunk mode relies on.
    local wlo, whi = pick_window(state, state.edit_from, #out)
    -- remember where this candidate mutates, so an improvement credits the heatmap there
    state._last_wlo, state._last_whi = wlo, whi
    for i = wlo, whi do
        local frame = out[i]
        if state.rng() < chance then
            local dx = math.floor(state.rng() * (2 * mag + 1)) - mag
            local dy = math.floor(state.rng() * (2 * mag + 1)) - mag
            frame.X = clamp(-127, frame.X + dx, 127)
            frame.Y = clamp(-127, frame.Y + dy, 127)
        end
        -- Polar stick mutations: SM64 movement is angle-driven and optimal inputs are almost always
        -- at full deflection, so mutating in (angle, magnitude) space hits the useful axes directly.
        -- ROTATE keeps the magnitude and turns the direction a little; SNAP keeps the direction and
        -- pushes the stick to the rim (127). Both skip deadzone frames (no meaningful direction).
        if state.rotate_chance > 0 and state.rng() < state.rotate_chance then
            local x, y = frame.X, frame.Y
            local r = math.sqrt(x * x + y * y)
            if r >= STICK_DEADZONE then
                local a = math.atan(y, x) + (state.rng() * 2 - 1) * eff.rotate_max_rad
                frame.X = clamp(-127, math.floor(r * math.cos(a) + 0.5), 127)
                frame.Y = clamp(-127, math.floor(r * math.sin(a) + 0.5), 127)
            end
        end
        -- Goal-aiming: snap the stick to full deflection POINTED AT THE GOAL (direction estimated
        -- from the captured baseline, see estimate_aims) — directed search instead of blind noise.
        if state.aims ~= nil and state.aim_chance > 0 and state.rng() < state.aim_chance then
            local aim = state.aims[i] or state.aims[#state.aims]
            if aim ~= nil then
                frame.X = clamp(-127, math.floor(127 * aim.x + 0.5), 127)
                frame.Y = clamp(-127, math.floor(127 * aim.y + 0.5), 127)
            end
        end
        if state.snap_chance > 0 and state.rng() < state.snap_chance then
            local x, y = frame.X, frame.Y
            local r = math.sqrt(x * x + y * y)
            if r >= STICK_DEADZONE then
                local s = 127 / r
                frame.X = clamp(-127, math.floor(x * s + 0.5), 127)
                frame.Y = clamp(-127, math.floor(y * s + 0.5), 127)
            end
        end
        -- Independent jump-button (A/B/Z) toggle: explores frame-perfect jump timing even on frames
        -- whose stick was not perturbed.
        if eff.flip_chance > 0 and state.rng() < eff.flip_chance then
            local btn = PERTURB_BUTTONS[math.floor(state.rng() * #PERTURB_BUTTONS) + 1]
            frame[btn] = not frame[btn]
        end
    end

    -- Slide a jump-button edge in time (frame-perfect timing search — see apply_edge_nudge).
    apply_edge_nudge(state, out)
    return out
end

---One-point crossover: child = a's frames up to a random cut, then b's frames after it. Recombines
---two reached solutions (e.g. a good early jump from one with a good landing from the other) —
---something no single-parent mutation can produce. The cut never lands inside the frozen prefix.
---Public for tests.
---@param state table
---@param a table[]
---@param b table[]
---@return table[]
local function crossover(state, a, b)
    local cut_lo = state.edit_from
    local cut_hi = math.min(#a, #b) - 1
    if cut_hi <= cut_lo then return clone_list(a) end
    local cut = cut_lo + math.floor(state.rng() * (cut_hi - cut_lo + 1))
    local out = {}
    for i = 1, cut do out[i] = clone_input(a[i]) end
    for i = cut + 1, #b do out[i] = clone_input(b[i]) end
    return out
end
Bruteforce._crossover = crossover

-- Speed score used to break frame ties in the beam: nil (unknown) loses to any measured speed.
local function beam_speed(h)
    return h ~= nil and math.abs(h) or -math.huge
end

-- Inserts a reached candidate into the beam (kept sorted by frames ascending — ties broken by
-- HIGHER horizontal speed at the goal, capped at beam_width) and refreshes best_list / best_frames
-- from the beam's front. The speed tie-break matters for chaining: among equal-frame solutions, the
-- one arriving fastest gives the next segment the best possible start.
local function beam_insert(state, candidate, frames, hspeed)
    local beam = state.beam
    local pos = #beam + 1
    for i = 1, #beam do
        if frames < beam[i].frames
            or (frames == beam[i].frames and beam_speed(hspeed) > beam_speed(beam[i].hspeed)) then
            pos = i
            break
        end
    end
    table.insert(beam, pos, { list = clone_list(candidate), frames = frames, hspeed = hspeed })
    while #beam > state.beam_width do
        table.remove(beam)
    end
    state.best_list = beam[1].list
    state.best_frames = beam[1].frames
end

-- Inserts a non-reached candidate into the explore pool (kept sorted by distance-to-goal ascending,
-- capped at explore_width) so the search can perturb around the closest near-misses.
local function explore_insert(state, candidate, distance)
    local pool = state.explore
    local pos = #pool + 1
    for i = 1, #pool do
        if distance < pool[i].distance then
            pos = i
            break
        end
    end
    table.insert(pool, pos, { list = clone_list(candidate), distance = distance })
    while #pool > state.explore_width do
        table.remove(pool)
    end
end

-- Advances the stagnation counter and, every pulse_after non-improving results, raises the
-- perturbation magnitude to escape a local optimum (auto-regulation; resets on improvement).
local function register_stagnation(state)
    state.stagnation = state.stagnation + 1
    -- pulse_after <= 0 disables the auto-pulse entirely (for fixed-strength searches),
    -- and also guards against a modulo-by-zero.
    if state.pulse_after > 0 and state.stagnation % state.pulse_after == 0 then
        state.pulse_bonus = math.min(state.pulse_bonus + state.base_magnitude, 127)
    end
end

-- Picks an entry from a pool, biased toward the front (rng squared favours low indices).
local function pick_biased(state, pool)
    return pool[math.min(#pool, 1 + math.floor((state.rng() ^ 2) * #pool))].list
end

-- Quality-diversity archive (scattershot-lite / MAP-Elites): keeps the best candidate per "cell" of a
-- behaviour descriptor of the end state. Unlike the beam (which collapses onto one route), the archive
-- structurally preserves many distinct approaches at once, so a slower-looking route that later admits
-- a big shortcut is never discarded — that is what lets the search tunnel out of local optima. It is
-- only active when the driver reports an end-state per candidate; otherwise it stays empty and the
-- search behaves exactly like the beam+explore version.

---Quantized behaviour descriptor of a candidate's end state. Bins on the Mario action (exact), the
---position (coarse grid) and, when provided, a horizontal-speed bucket. Two runs share a cell iff all
---bins match. Binning on action+speed (not only position) matters because every run that REACHES the
---goal ends at the same spot — the useful diversity is in HOW it gets there. Public for tests.
---@param state table
---@param fs table { action, x, z, hspeed? }
---@return string
local function cell_key(state, fs)
    local q = state.cell_size
    local key = string.format('%d:%d:%d',
        math.floor(fs.action or 0),
        math.floor((fs.x or 0) / q),
        math.floor((fs.z or 0) / q))
    if fs.hspeed ~= nil then
        key = key .. ':' .. math.floor(fs.hspeed / state.cell_speed_size)
    end
    return key
end
Bruteforce._cell_key = cell_key

-- Lexicographic "is A a better cell representative than B": reaching the goal wins, then fewer frames,
-- then closer to the goal. On an exact tie the newcomer sometimes wins, which keeps archive diversity.
local function cell_better(state, a, b)
    if b == nil then return true end
    if a.reached ~= b.reached then return a.reached end
    if a.reached then
        if a.frames ~= b.frames then return a.frames < b.frames end
    else
        local ad, bd = a.distance or math.huge, b.distance or math.huge
        if ad ~= bd then return ad < bd end
    end
    return state.rng() < state.tie_to_newcomer
end

---Inserts a candidate into the archive under its end-state cell, keeping the better representative.
---@param state table
---@param candidate table[]
---@param frames integer
---@param reached boolean
---@param distance number|nil
---@param fs table end-state features { action, x, z, hspeed? }
local function archive_insert(state, candidate, frames, reached, distance, fs)
    local key = cell_key(state, fs)
    local old = state.archive[key]
    local entry = { list = clone_list(candidate), frames = frames, reached = reached, distance = distance,
        -- a replaced representative keeps its cell's expansion history (curiosity bookkeeping)
        expansions = old and old.expansions or 0 }
    if cell_better(state, entry, old) then
        if old == nil then
            state.archive_count = state.archive_count + 1
            state.archive_keys[state.archive_count] = key
        end
        state.archive[key] = entry
    end
end
Bruteforce._archive_insert = archive_insert

-- Picks an archive cell's input list to expand from, curiosity-weighted: a 2-way tournament that
-- prefers the LESS-expanded cell. Fresh frontier niches therefore get expanded first, while cells
-- that have already been mined heavily fade — better than uniform, which keeps re-rolling the same
-- crowded niches on large archives.
local function pick_archive_cell(state)
    local keys = state.archive_keys
    local e1 = state.archive[keys[math.floor(state.rng() * state.archive_count) + 1]]
    local e2 = state.archive[keys[math.floor(state.rng() * state.archive_count) + 1]]
    local e = (e2.expansions or 0) < (e1.expansions or 0) and e2 or e1
    e.expansions = (e.expansions or 0) + 1
    return e.list
end
Bruteforce._pick_archive_cell = pick_archive_cell

---The frame at which the driver may cut a running candidate: once a best exists, anything that has
---not reached the goal by best_frames + prune_slack cannot improve, so there is no point emulating
---the rest. Falls back to max_frames while nothing has been reached yet (the reference must be
---measured in full). The search therefore speeds up as it improves.
---@param state table
---@return integer cutoff
function Bruteforce.cutoff(state)
    if #state.beam == 0 then return state.max_frames end
    -- Stagnation widens the window (slack_bonus): when polish stalls, slower-but-different routes
    -- are allowed to finish again so they can seed the beam/archive with fresh diversity.
    return math.min(state.max_frames,
        state.best_frames + state.prune_slack + Bruteforce.escalation(state).slack_bonus)
end

---Declares (or clears, with nil/empty) the mid-run checkpoint LADDER the driver holds: savestates of
---the CURRENT best run after each listed frame count (ascending). While set, the core tags some
---candidates `preserve_prefix = frame` (their frames 1..frame are bit-identical to the best), which
---the driver replays from that checkpoint instead of the segment start. With a ladder of 1/2 and
---3/4, mutations touching only the last quarter replay only ~25% of the frames.
---@param state table
---@param frames integer[]|nil ascending checkpoint frames
function Bruteforce.set_checkpoints(state, frames)
    if frames ~= nil and #frames == 0 then frames = nil end
    state.checkpoint_frames = frames
    -- deepest rung kept in checkpoint_frame for the sweep tagging fast path / backward compat
    state.checkpoint_frame = frames and frames[1] or nil
end

---Single-checkpoint sugar over set_checkpoints (kept for compatibility and tests).
---@param state table
---@param frame integer|nil
function Bruteforce.set_checkpoint(state, frame)
    Bruteforce.set_checkpoints(state, frame ~= nil and { frame } or nil)
end

---The deepest checkpoint frame strictly below `first_touched`, or nil. Used to tag deterministic
---sweep candidates with the cheapest replay start their change allows.
---@param state table
---@param first_touched integer
---@return integer|nil
local function deepest_checkpoint_before(state, first_touched)
    local list = state.checkpoint_frames
    if list == nil then return nil end
    local best = nil
    for i = 1, #list do
        if list[i] < first_touched then best = list[i] end
    end
    return best
end

---A compact exact hash of a candidate (sticks + jump buttons per frame), used to skip duplicates.
---@param list table[]
---@return string
local function hash_candidate(list)
    local parts = {}
    for i = 1, #list do
        local f = list[i]
        parts[i] = string.char(
            (f.A and 1 or 0) + (f.B and 2 or 0) + (f.Z and 4 or 0),
            (f.X or 0) + 128, (f.Y or 0) + 128)
    end
    return table.concat(parts)
end
Bruteforce._hash_candidate = hash_candidate

-- Remembers a candidate as tried. Capped so a huge budget cannot grow the set unboundedly.
local function mark_seen(state, candidate)
    if not state.dedupe or state.seen_count >= 20000 then return end
    local h = hash_candidate(candidate)
    if not state.seen[h] then
        state.seen[h] = true
        state.seen_count = state.seen_count + 1
    end
end

local function is_seen(state, candidate)
    return state.dedupe and state.seen[hash_candidate(candidate)] == true
end

-- Rebuilds the deterministic sweep queue against the CURRENT best. Two families of guaranteed-worth
-- candidates, end-first (changes near the end disturb the least of the run):
--   1. remove: drop one redundant frame (neutral wait / duplicate of the previous frame) — the
--      cheapest possible frame save;
--   2. edge: shift one A/B/Z press/release edge by exactly 1 frame (both directions) — in SM64 most
--      lost frames are button timing, so every edge of the best gets its +-1 tried systematically.
local function rebuild_sweep(state)
    local queue = {}
    local list = state.best_list
    local hi = math.min(state.best_frames, #list)
    local lo = math.max(state.edit_from, 1)

    -- Removal candidates in decreasing order of prior probability. Tier 3 makes the single-frame
    -- removal sweep EXHAUSTIVE: dropping a frame is the most direct frame saving there is, and trying
    -- every index costs at most best_frames candidates — far better value than spending the same
    -- budget on random stick noise. Without it, a baseline with no neutral/duplicate frames and no
    -- button edges (a Semantic Workflow walk) got no deterministic candidates at all.
    -- Every entry carries a `prior` (how likely its tier is to pay off) and the `frame` it touches.
    -- Both feed the final ordering: the queue is drained best-first rather than in tier order, so a
    -- winning candidate surfaces in the first dozens instead of the several hundredth. That matters
    -- doubly because the queue is REBUILT on every improvement — the cost of finding each gain is
    -- paid again each time.
    local redundant = {}
    local queued = {}
    local function queue_remove(i, count_as_redundant, prior)
        if queued[i] then return end
        queued[i] = true
        queue[#queue + 1] = { kind = 'remove', idx = i, frame = i, prior = prior }
        if count_as_redundant then redundant[#redundant + 1] = i end
    end

    -- tier 1: obviously redundant — a neutral wait, or an exact duplicate of the previous frame
    for i = hi, lo, -1 do
        if frame_is_neutral(list[i]) or (i > 1 and list[i - 1] ~= nil and frames_equal(list[i], list[i - 1])) then
            queue_remove(i, true, 3.0)
        end
    end
    -- tier 2: near-duplicates — the same held direction, jittered by the per-frame angle/camera maths
    for i = hi, lo, -1 do
        if i > 1 and list[i - 1] ~= nil and frames_near_equal(list[i], list[i - 1], SWEEP_NEAR_TOL) then
            queue_remove(i, true, 3.0)
        end
    end

    -- edge / shift entries for a given step size k (queued end-first). k = 1 first (cheap fixes),
    -- then k = 2 — a 2-frame retiming often works where both intermediate 1-frame moves fail, and
    -- the random operators almost never land that exact coordinated change.
    local function queue_button_moves(k, prior)
        for e = hi, math.max(lo + 1, 2), -1 do
            for _, b in ipairs(PERTURB_BUTTONS) do
                if (list[e][b] or false) ~= (list[e - 1][b] or false) then
                    if e - k >= lo then
                        queue[#queue + 1] = { kind = 'edge', btn = b, e = e, dir = -1, k = k, frame = e, prior = prior }
                    end
                    if e + k - 1 <= hi then
                        queue[#queue + 1] = { kind = 'edge', btn = b, e = e, dir = 1, k = k, frame = e, prior = prior }
                    end
                end
            end
        end
        -- shift: move a WHOLE press (both edges together, duration kept) by k frames.
        for _, b in ipairs(PERTURB_BUTTONS) do
            for i = hi, lo, -1 do
                local held = list[i][b] or false
                local prev = i > 1 and (list[i - 1][b] or false) or false
                if held and not prev then
                    local r = i
                    local f = i + 1 -- falling edge (first frame past the press)
                    while f <= hi and (list[f][b] or false) do f = f + 1 end
                    if r - k >= lo then
                        queue[#queue + 1] = { kind = 'shift', btn = b, r = r, f = f, dir = -1, k = k, frame = r, prior = prior }
                    end
                    if f + k - 1 <= hi then
                        queue[#queue + 1] = { kind = 'shift', btn = b, r = r, f = f, dir = 1, k = k, frame = r, prior = prior }
                    end
                end
            end
        end
    end
    queue_button_moves(1, 2.6)

    -- adjacent-pair removals around redundant frames: when dropping one redundant frame alone broke
    -- the run, dropping it TOGETHER with a neighbour sometimes still reaches (2 frames saved at once).
    local paired = {}
    for _, idx in ipairs(redundant) do
        for _, p in ipairs({ idx - 1, idx }) do
            if p >= lo and p + 1 <= hi and not paired[p] then
                paired[p] = true
                queue[#queue + 1] = { kind = 'remove2', idx = p, frame = p, prior = 2.2 }
            end
        end
    end

    queue_button_moves(2, 2.1)

    -- Technique injection: try INVENTING a movement the baseline does not contain (a jump, dive or
    -- long jump) at each insertion point. This is the only operator that can add a move rather than
    -- trim or retime one, so it is what recovers a segment that is slow because it walks a distance it
    -- should have covered with a technique. Positions are strided so a long segment cannot flood the
    -- budget; queued before the speculative tier-3 removals since a found technique is worth many
    -- frames while a removal is worth one.
    -- Only on the first pass and every `tech_every` rebuilds after it — see sweep_rebuilds.
    local include_tech = (state.sweep_rebuilds or 0) % math.max(1, state.tech_every or 1) == 0
    local span = hi - lo + 1
    if include_tech and span > 0 and #TECHNIQUES > 0 then
        -- Learn from failure: a technique that has been tried plenty of times on THIS segment without
        -- ever reproducing the goal does not apply here (a ground pound with nothing to land on, a
        -- long jump where there is no room). Re-queueing its ~60 candidates on every full pass is pure
        -- waste, so it is dropped for the rest of the search. Techniques with no verdict yet are
        -- always kept, so nothing is judged before it has had a fair trial.
        local live = {}
        for t = 1, #TECHNIQUES do
            local st = state.tech_stats and state.tech_stats[t]
            if st == nil or st.reaches > 0 or st.tries < (state.tech_min_trials or 25) then
                live[#live + 1] = t
            end
        end
        if #live > 0 then
            -- Stride from the FULL table, not from the survivors: dropping a dead technique must
            -- actually REMOVE work, not hand its slots to the others at a finer granularity (which
            -- would keep the queue pegged at the cap and save nothing).
            local stride = math.max(1, math.ceil((span * #TECHNIQUES) / TECH_MAX_ENTRIES))
            for _, t in ipairs(live) do
                local len = #TECHNIQUES[t].stamp
                for i = hi - len + 1, lo, -stride do
                    if i >= lo then
                        queue[#queue + 1] = { kind = 'tech', tech = t, at = i, frame = i, prior = 2.0 }
                    end
                end
            end
        end
    end

    -- AIM sweep: re-point the stick at the goal over a WINDOW of frames. This is the only
    -- deterministic operator that changes DIRECTION — removals delete, retimings move buttons, and
    -- technique stamps only add buttons, all of them leaving the stick untouched. So a segment that is
    -- slow because Mario travels a curve he should have travelled straight had no systematic candidate
    -- at all: the aim operator existed, but only as an 8%-chance flourish inside the RANDOM path,
    -- which barely runs once the deterministic queue is this large. Needs the capture-estimated aims.
    if state.aims ~= nil and span > 0 then
        local stride = math.max(1, math.ceil((span * #AIM_WINDOWS) / AIM_MAX_ENTRIES))
        for _, win in ipairs(AIM_WINDOWS) do
            for i = hi, lo, -stride do
                local len = win == 0 and (hi - i + 1) or win
                if len > 0 and i + len - 1 <= hi then
                    queue[#queue + 1] = { kind = 'aim', at = i, len = len, frame = i, prior = 2.4 }
                end
            end
        end
    end

    -- tier 3: every remaining frame. The lowest prior — it is the speculative "try dropping ANY frame"
    -- tier — so the ordering below naturally drains it last unless the heatmap says otherwise.
    for i = hi, lo, -1 do
        queue_remove(i, false, 1.0)
    end

    -- Order by expected value instead of by tier. `heat` records which frames past improvements came
    -- from, so once anything has paid off the sweep concentrates there rather than grinding end-first
    -- through hundreds of candidates that already failed. Heat is empty on the first pass, which
    -- leaves the tier order exactly as before — no behaviour change until there is something to learn.
    for i = 1, #queue do queue[i]._seq = i end
    local heat = state.heat or {}
    table.sort(queue, function(a, b)
        local sa = (a.prior or 1) * (1 + (heat[a.frame or 0] or 0))
        local sb = (b.prior or 1) * (1 + (heat[b.frame or 0] or 0))
        if sa ~= sb then return sa > sb end
        return a._seq < b._seq -- keep the original (end-first) order within equal scores
    end)

    state.sweep_queue = queue
    state.sweep_pos = 1
    state.sweep_base = state.best_frames
    state.sweep_list = state.best_list
    state.sweep_rebuilds = (state.sweep_rebuilds or 0) + 1
end

-- Builds the candidate for one sweep entry: a copy of the best with the entry's single change,
-- padded to the timeout length. Tags preserve_prefix when the change lies entirely past the
-- driver's checkpoint, so the driver can replay it from there.
local function build_sweep_candidate(state, entry)
    local out = {}
    local first_touched
    if entry.kind == 'remove' or entry.kind == 'remove2' then
        local skip_to = entry.kind == 'remove2' and entry.idx + 1 or entry.idx
        for i = 1, math.min(state.best_frames, #state.best_list) do
            if i < entry.idx or i > skip_to then out[#out + 1] = clone_input(state.best_list[i]) end
        end
        first_touched = entry.idx
    elseif entry.kind == 'edge' then
        for i = 1, math.min(state.best_frames, #state.best_list) do
            out[i] = clone_input(state.best_list[i])
        end
        local b, e, k = entry.btn, entry.e, entry.k or 1
        if entry.dir < 0 then
            local v = out[e][b] or false -- extend the post-edge value k frames back
            for i = e - k, e - 1 do out[i][b] = v end
            first_touched = e - k
        else
            local v = out[e - 1][b] or false -- extend the pre-edge value k frames forward
            for i = e, e + k - 1 do out[i][b] = v end
            first_touched = e
        end
    elseif entry.kind == 'aim' then
        -- Full-deflection stick pointed at the goal across the window; buttons untouched, so this
        -- changes only the DIRECTION Mario travels, never what he does.
        for i = 1, math.min(state.best_frames, #state.best_list) do
            out[i] = clone_input(state.best_list[i])
        end
        local last = nil
        for j = entry.at, math.min(entry.at + entry.len - 1, #out) do
            local a = state.aims[j] or last
            last = a or last
            if a ~= nil then
                out[j].X = clamp(-128, math.floor((a.x or 0) * 127 + 0.5), 127)
                out[j].Y = clamp(-128, math.floor((a.y or 0) * 127 + 0.5), 127)
            end
        end
        first_touched = entry.at
    elseif entry.kind == 'tech' then
        -- Stamp a technique's buttons over consecutive frames, leaving the stick (and any button the
        -- stamp does not mention) untouched, so Mario keeps heading where the baseline sent him.
        for i = 1, math.min(state.best_frames, #state.best_list) do
            out[i] = clone_input(state.best_list[i])
        end
        local stamp = TECHNIQUES[entry.tech].stamp
        for j = 1, #stamp do
            local frame = out[entry.at + j - 1]
            if frame ~= nil then
                for _, b in ipairs(PERTURB_BUTTONS) do
                    if stamp[j][b] then frame[b] = true end
                end
            end
        end
        first_touched = entry.at
    else -- shift: move the whole press [r, f-1] by k frames, keeping its duration
        for i = 1, math.min(state.best_frames, #state.best_list) do
            out[i] = clone_input(state.best_list[i])
        end
        local b, r, f, k = entry.btn, entry.r, entry.f, entry.k or 1
        if entry.dir < 0 then
            for i = r - k, r - 1 do out[i][b] = true end
            for i = f - k, f - 1 do out[i][b] = false end
            first_touched = r - k
        else
            for i = r, r + k - 1 do out[i][b] = false end
            for i = f, f + k - 1 do out[i][b] = true end
            first_touched = r
        end
    end
    for i = #out + 1, state.max_frames do
        out[i] = clone_input(out[#out])
    end
    out.preserve_prefix = deepest_checkpoint_before(state, first_touched)
    return out
end

---Returns the next DETERMINISTIC sweep candidate, or nil when the sweep is exhausted for this best.
---Runs right after any new best is found: every redundant frame of the best is tried removed, and
---every jump-button edge is tried shifted +-1 frame — exactly once each, end-first — instead of
---waiting for the random mutations to stumble on them. Each success produces a new best, which
---rebuilds the queue, so the sweep greedily drains ALL guaranteed candidates before random search
---resumes. Already-tried candidates (dedupe) are skipped without consuming budget. Public for tests.
---@param state table
---@return table[]|nil candidate
local function next_sweep_candidate(state)
    if not state.sweep_enabled or #state.beam == 0 then return nil end
    if state.best_frames - state.edit_from + 1 <= 1 then return nil end
    -- rebuild when the best changed — by frame count OR by identity (a same-frame, faster-arriving
    -- solution took the front): the sweeps must always anchor on the actual current best.
    if state.sweep_queue == nil or state.sweep_base ~= state.best_frames
        or state.sweep_list ~= state.best_list then
        rebuild_sweep(state)
    end
    while state.sweep_pos <= #state.sweep_queue do
        local entry = state.sweep_queue[state.sweep_pos]
        state.sweep_pos = state.sweep_pos + 1
        -- highest frame index the entry touches (guards against a stale queue past the best's end)
        local top
        local k = entry.k or 1
        if entry.kind == 'remove' then
            top = entry.idx
        elseif entry.kind == 'remove2' then
            top = entry.idx + 1
        elseif entry.kind == 'edge' then
            top = entry.dir < 0 and entry.e or entry.e + k - 1
        elseif entry.kind == 'tech' then
            top = entry.at + #TECHNIQUES[entry.tech].stamp - 1
        elseif entry.kind == 'aim' then
            top = entry.at + entry.len - 1
        else
            top = entry.dir < 0 and entry.f - 1 or entry.f + k - 1
        end
        if top <= state.best_frames then
            local out = build_sweep_candidate(state, entry)
            if not is_seen(state, out) then
                -- Remember which technique produced this candidate so report_result can score it
                -- (see tech_stats): that is how a technique that never applies here gets dropped.
                state._last_tech = entry.kind == 'tech' and entry.tech or nil
                return out
            end
        end
    end
    return nil
end
Bruteforce._next_sweep_candidate = next_sweep_candidate

-- One stochastic candidate: the priority ladder of the random search (archive niche > checkpoint
-- suffix polish > crossover > explore pool > beam > baseline).
local function generate_random(state)
    -- Stagnation escalation: while stuck, polish gives way to exploration (see Bruteforce.escalation).
    local eff = Bruteforce.escalation(state)
    -- Quality-diversity expansion: sometimes expand a random archive niche instead of the beam, to
    -- keep exploring distinct routes and escape local optima (no-op until the archive has cells).
    if state.archive_count > 0 and state.rng() < state.archive_prob then
        return perturb(state, pick_archive_cell(state))
    end
    -- Checkpoint suffix polish: mutate ONLY past one rung of the driver's checkpoint ladder, leaving
    -- the best's prefix untouched — the driver then replays these from that rung's savestate (half
    -- the emulator cost at the 1/2 rung, a quarter at the 3/4 rung). Fades out while stagnating
    -- (polish is what is failing).
    if state.checkpoint_frames ~= nil and #state.beam > 0 and state.rng() < eff.suffix_prob then
        local usable = {}
        for _, frame in ipairs(state.checkpoint_frames) do
            if state.best_frames > frame + 2 then usable[#usable + 1] = frame end
        end
        if #usable > 0 then
            local frame = usable[math.floor(state.rng() * #usable) + 1]
            local saved = state.edit_from
            state.edit_from = math.max(saved, frame + 1)
            local out = perturb(state, state.best_list)
            state.edit_from = saved
            out.preserve_prefix = frame
            return out
        end
    end
    -- Crossover: recombine two beam parents (a prefix of one + a suffix of the other), then mutate.
    if state.crossover_chance > 0 and #state.beam >= 2 and state.rng() < state.crossover_chance then
        local a = pick_biased(state, state.beam)
        local b = pick_biased(state, state.beam)
        if a ~= b then
            return perturb(state, crossover(state, a, b))
        end
    end
    local use_explore = #state.explore > 0 and (#state.beam == 0 or state.rng() < eff.explore_prob)
    if use_explore then
        return perturb(state, pick_biased(state, state.explore))
    elseif #state.beam > 0 then
        return perturb(state, pick_biased(state, state.beam))
    end
    -- nothing reached and no near-miss yet: keep perturbing the baseline
    return perturb(state, state.baseline)
end

---Returns the next candidate input list to try, or nil when the search budget is exhausted.
---The first candidate is the unperturbed baseline. Next come the DETERMINISTIC sweep candidates
---(remove each redundant frame / shift each button edge +-1 — guaranteed-worth tries). After that
---the stochastic ladder takes over (see generate_random). Duplicate candidates are skipped
---(deterministic ones) or regenerated (stochastic ones) so no emulator run is wasted on an input
---list that was already measured.
---@param state table
---@return table[]|nil candidate
function Bruteforce.next_candidate(state)
    if Bruteforce.done(state) then
        return nil
    end
    -- forget the previous candidate's mutation window; perturb() re-records it, so heat credit only
    -- ever lands on the window of the candidate actually being reported
    state._last_wlo, state._last_whi = nil, nil
    state._last_tech = nil -- only a sweep technique candidate sets this; see report_result
    if state._first then
        state._first = false
        local base = clone_list(state.baseline)
        mark_seen(state, base)
        return base
    end
    local sweep = next_sweep_candidate(state)
    if sweep ~= nil then
        mark_seen(state, sweep)
        return sweep
    end
    local cand = generate_random(state)
    if state.dedupe then
        for _ = 1, 2 do
            if not is_seen(state, cand) then break end
            cand = generate_random(state) -- already measured: reroll rather than waste an emulator run
        end
        mark_seen(state, cand)
    end
    return cand
end

---Reports the outcome of running the candidate returned by the last next_candidate call.
---Reached candidates enter the beam (minimise frames); near-misses enter the explore pool
---(minimise distance) when a distance is provided. The search's best is the beam's fewest-frame member.
---@param state table
---@param candidate table[] the candidate that was run
---@param frames integer number of frames it took (only meaningful when reached is true)
---@param reached boolean whether the goal (target action) was reached within max_frames
---@param distance number|nil closest approach to the goal position during the run (soft fitness)
---@param end_state table|nil the candidate's end-state features { action, x, z, hspeed? } for the
---  quality-diversity archive. When nil the archive stays inactive (beam+explore behaviour).
---@return boolean improved whether this candidate became the new overall best
function Bruteforce.report_result(state, candidate, frames, reached, distance, end_state)
    state.tried = state.tried + 1
    if reached then state.reaches = (state.reaches or 0) + 1 end

    -- Score the technique this candidate came from, if any. Enough tries with no reach means the
    -- technique does not apply to this segment and later sweeps stop queueing it (rebuild_sweep).
    if state._last_tech ~= nil then
        local st = state.tech_stats[state._last_tech]
        if st == nil then
            st = { tries = 0, reaches = 0 }
            state.tech_stats[state._last_tech] = st
        end
        st.tries = st.tries + 1
        if reached then st.reaches = st.reaches + 1 end
    end

    -- Feed the quality-diversity archive (keeps the best candidate per behaviour cell; drives the
    -- diverse expansion in next_candidate). Every candidate, reached or not, seeds/updates its cell.
    if end_state ~= nil then
        archive_insert(state, candidate, frames, reached, distance, end_state)
    end

    -- The very first candidate is the unperturbed baseline, re-run through the exact same
    -- load-then-replay path every candidate uses. Re-base the reference on that measurement so
    -- baseline and candidates are always compared on identical terms (removes any measurement
    -- offset the emulator's per-candidate savestate reload could introduce).
    if not state._reference_set then
        state._reference_set = true
        -- Whether the baseline itself reproduced the goal. If it did NOT (the search's action+radius
        -- goal detection didn't fire on the captured baseline replay), there is NO valid reference:
        -- baseline_frames stays at the stale capture value, so a later candidate reaching in fewer
        -- frames would show a FAKE positive gain. summary() forces gain to 0 in that case, which
        -- stops a spurious result from ever being applied to a sheet (it would break it). See summary.
        state.baseline_reached = reached
        if reached then
            state.baseline_frames = frames
            beam_insert(state, candidate, frames, end_state and end_state.hspeed) -- seed the beam with the baseline
        end
        return false
    end

    if not reached then
        if distance ~= nil then
            explore_insert(state, candidate, distance) -- keep the near-miss to explore from
            -- Closest any failing candidate ever came to the goal. When a search reports no gain this
            -- says WHY the misses miss: a few units means the goal is nearly made (a radius or
            -- end-state issue), hundreds means the mutations are throwing the run off entirely.
            if state.closest_miss == nil or distance < state.closest_miss then
                state.closest_miss = distance
            end
        end
        register_stagnation(state)
        return false
    end

    local prev_best = state.best_frames
    local prev_front = state.beam[1]
    beam_insert(state, candidate, frames, end_state and end_state.hspeed)
    -- An improvement is a shorter run, OR — at equal frames — a faster-arriving one taking the
    -- beam's front (a better chaining base). Both reset the stagnation machinery and re-anchor the
    -- deterministic sweeps / checkpoints on the new best.
    if state.best_frames < prev_best or state.beam[1] ~= prev_front then
        state.improvements = state.improvements + 1
        state.stagnation = 0
        state.pulse_bonus = 0 -- cool down after an improvement
        -- heatmap credit: the frames this winning candidate mutated get hotter, drawing future
        -- local windows toward them (see pick_window)
        if state._last_wlo ~= nil then
            local credit = 1 / (state._last_whi - state._last_wlo + 1)
            for i = state._last_wlo, state._last_whi do
                state.heat[i] = (state.heat[i] or 0) + credit
            end
        end
        return true
    end
    register_stagnation(state)
    return false
end

---Whether the search should stop. Three exits:
---  converged — convergence_after candidates without improvement (burning more budget is pointless);
---  hard cap  — the absolute candidate ceiling (2x budget by default);
---  budget    — the budget is spent AND the search is not on a hot streak (overtime: a search that
---              improved within the last overtime_grace candidates keeps going, up to the hard cap).
---@param state table
---@return boolean
function Bruteforce.done(state)
    -- Never claim convergence while guaranteed-worth candidates are still queued. The deterministic
    -- sweep can hold more entries than `convergence_after` (the technique injections alone are
    -- hundreds), and stopping mid-queue would both skip systematic work and report "likely optimal"
    -- about a search that never finished checking. The hard cap below still bounds the run.
    local sweep_pending = state.sweep_queue ~= nil and state.sweep_pos <= #state.sweep_queue
    if state.stagnation >= state.convergence_after and not sweep_pending then return true end
    if state.tried >= (state.hard_cap or state.budget) then return true end
    if state.tried >= state.budget then
        return state.improvements == 0 or state.stagnation >= state.overtime_grace
    end
    return false
end

---A snapshot of the current search progress for display.
---@param state table
---@return table summary { best_frames, baseline_frames, gain, tried, budget, improvements, niches, stagnation, best_hspeed }
function Bruteforce.summary(state)
    -- gain is only meaningful when the baseline itself reached the goal (a valid reference). A search
    -- whose baseline never reproduced the goal has a stale baseline_frames, so its "gain" would be
    -- fake — force it to 0 so nothing spurious is ever applied. (nil = legacy/synthetic core that
    -- predates this field; treat as reached so chunk-mode verified results still report their gain.)
    local valid_reference = state.baseline_reached ~= false
    return {
        best_frames = state.best_frames,
        baseline_frames = state.baseline_frames,
        gain = valid_reference and math.max(0, state.baseline_frames - state.best_frames) or 0,
        tried = state.tried,
        budget = state.budget,
        improvements = state.improvements,
        -- Diagnostics for "why is the gain 0?". `best == baseline` with `gain 0` has two very
        -- different causes that the frame counts alone cannot distinguish:
        --   reaches == 0            -> the goal is NEVER reproduced (bad/unreachable goal). The beam is
        --                              never seeded, the deterministic sweep never anchors, and gain is
        --                              forced to 0 — the search structurally cannot find anything.
        --   reaches > 0, gain == 0  -> the goal IS reached, but nothing shorter was ever accepted.
        reaches = state.reaches or 0,
        -- Whether the baseline replay itself reproduced the goal. false = there is no valid reference,
        -- so `baseline_frames` is the stale capture value and gain is pinned to 0 on purpose.
        baseline_reached = state.baseline_reached,
        -- Deterministic sweep progress: how many guaranteed-worth candidates were queued against the
        -- current best, and how many have been drained. `sweep_queued == 0` means the sweep found
        -- NOTHING to try — the search is running on random mutation alone, which is the difference
        -- between systematically answering "can a frame be dropped?" and hoping to stumble on it.
        sweep_queued = state.sweep_queue and #state.sweep_queue or 0,
        sweep_done = state.sweep_queue and math.min(state.sweep_pos - 1, #state.sweep_queue) or 0,
        -- Closest a non-reaching candidate ever got to the goal (game units), nil if none missed.
        closest_miss = state.closest_miss,
        niches = state.archive_count,       -- number of distinct behaviour cells the search is keeping
        stagnation = state.stagnation,      -- candidates since the last improvement (0 = just improved)
        -- horizontal speed at the goal of the best solution (nil until measured); among equal-frame
        -- solutions the beam keeps the fastest-arriving one, which chains best into the next segment
        best_hspeed = state.beam and state.beam[1] and state.beam[1].hspeed or nil,
        -- current stagnation-escalation level (0 = progressing/precise; each level = one pulse_after
        -- period without improvement, widening the search — see Bruteforce.escalation)
        shake = (state.stagnation ~= nil and state.pulse_after ~= nil)
            and stagnation_level(state) or 0,
        -- whether the search ended by CONVERGENCE (a long streak with zero improvement) rather than
        -- by exhausting its budget — "likely optimal for this budget"
        converged = (state.stagnation ~= nil and state.convergence_after ~= nil)
            and state.stagnation >= state.convergence_after or false,
    }
end

return Bruteforce
