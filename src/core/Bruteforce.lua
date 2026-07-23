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
        rotate_chance = opts.rotate_chance or 0.15, -- chance a frame's stick is ROTATED (angle search, magnitude kept)
        rotate_max_rad = opts.rotate_max_rad or 0.25, -- max rotation (radians) of a single stick rotation
        snap_chance = opts.snap_chance or 0.10,     -- chance a frame's stick is snapped to FULL deflection (127), angle kept
        crossover_chance = opts.crossover_chance or 0.15, -- chance to recombine two beam parents instead of mutating one
        window_chance = opts.window_chance or 0.35, -- chance to perturb only a local window (vs the whole editable region)
        window_frac = opts.window_frac or 0.25,     -- window size as a fraction of the editable length
        window_min = opts.window_min or 4,          -- minimum window length (below this, always perturb the whole region)
        edit_from = opts.edit_from or 1, -- only perturb frames >= this (chunk mode freezes the optimised prefix)
        budget = opts.budget or 2000,
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
    if (#out - state.edit_from + 1) <= 1 or state.rng() >= state.remove_chance then
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

    local mag = effective_magnitude(state)
    local chance = effective_chance(state)
    -- Perturb either the whole editable region or a local window (see pick_window). Never touches the
    -- frozen prefix (frames before edit_from), which chunk mode relies on.
    local wlo, whi = pick_window(state, state.edit_from, #out)
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
                local a = math.atan(y, x) + (state.rng() * 2 - 1) * state.rotate_max_rad
                frame.X = clamp(-127, math.floor(r * math.cos(a) + 0.5), 127)
                frame.Y = clamp(-127, math.floor(r * math.sin(a) + 0.5), 127)
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
        if state.flip_chance > 0 and state.rng() < state.flip_chance then
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

-- Rebuilds the deterministic sweep queue against the CURRENT best: the indices of its redundant
-- frames (neutral waits / duplicates of the previous frame), end-first — removing near the end
-- disturbs the least of the run, so those are tried first.
local function rebuild_sweep(state)
    local queue = {}
    local list = state.best_list
    local hi = math.min(state.best_frames, #list)
    for i = hi, state.edit_from, -1 do
        if frame_is_neutral(list[i]) or (i > 1 and list[i - 1] ~= nil and frames_equal(list[i], list[i - 1])) then
            queue[#queue + 1] = i
        end
    end
    state.sweep_queue = queue
    state.sweep_pos = 1
    state.sweep_base = state.best_frames
end

---Returns the next DETERMINISTIC sweep candidate ("current best minus one redundant frame"), or nil
---when the sweep is exhausted for this best. Runs right after any new best is found: instead of
---waiting for the random removal mutation to stumble on them, every obviously-droppable frame of the
---best solution is tried exactly once, end-first. Each confirmed removal produces a new best, which
---rebuilds the queue — so this greedily peels off ALL removable frames before random search resumes.
---Public for tests.
---@param state table
---@return table[]|nil candidate
local function next_sweep_candidate(state)
    if not state.sweep_enabled or #state.beam == 0 then return nil end
    if state.best_frames - state.edit_from + 1 <= 1 then return nil end
    if state.sweep_queue == nil or state.sweep_base ~= state.best_frames then
        rebuild_sweep(state)
    end
    while state.sweep_pos <= #state.sweep_queue do
        local idx = state.sweep_queue[state.sweep_pos]
        state.sweep_pos = state.sweep_pos + 1
        if idx <= state.best_frames then
            local out = {}
            for i = 1, math.min(state.best_frames, #state.best_list) do
                if i ~= idx then out[#out + 1] = clone_input(state.best_list[i]) end
            end
            -- pad to the timeout length, like perturb() does
            for i = #out + 1, state.max_frames do
                out[i] = clone_input(out[#out])
            end
            return out
        end
    end
    return nil
end
Bruteforce._next_sweep_candidate = next_sweep_candidate

---Returns the next candidate input list to try, or nil when the search budget is exhausted.
---The first candidate is the unperturbed baseline. Next come the DETERMINISTIC sweep candidates
---(current best minus each redundant frame — guaranteed cheap savings). After that it perturbs
---either a beam member (a solution, to shave more frames), a crossover of two beam members, or,
---with probability explore_prob, a near-miss from the explore pool (to discover a new reaching
---route). Both pools are biased toward their best entries.
---@param state table
---@return table[]|nil candidate
function Bruteforce.next_candidate(state)
    if state.tried >= state.budget then
        return nil
    end
    if state._first then
        state._first = false
        return clone_list(state.baseline)
    end
    -- Deterministic removal sweep first: guaranteed-cheap frame savings before any random search.
    local sweep = next_sweep_candidate(state)
    if sweep ~= nil then
        return sweep
    end
    -- Quality-diversity expansion: sometimes expand a random archive niche instead of the beam, to
    -- keep exploring distinct routes and escape local optima (no-op until the archive has cells).
    if state.archive_count > 0 and state.rng() < state.archive_prob then
        return perturb(state, pick_archive_cell(state))
    end
    -- Crossover: recombine two beam parents (a prefix of one + a suffix of the other), then mutate.
    if state.crossover_chance > 0 and #state.beam >= 2 and state.rng() < state.crossover_chance then
        local a = pick_biased(state, state.beam)
        local b = pick_biased(state, state.beam)
        if a ~= b then
            return perturb(state, crossover(state, a, b))
        end
    end
    local use_explore = #state.explore > 0 and (#state.beam == 0 or state.rng() < state.explore_prob)
    if use_explore then
        return perturb(state, pick_biased(state, state.explore))
    elseif #state.beam > 0 then
        return perturb(state, pick_biased(state, state.beam))
    end
    -- nothing reached and no near-miss yet: keep perturbing the baseline
    return perturb(state, state.baseline)
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
        if reached then
            state.baseline_frames = frames
            beam_insert(state, candidate, frames, end_state and end_state.hspeed) -- seed the beam with the baseline
        end
        return false
    end

    if not reached then
        if distance ~= nil then
            explore_insert(state, candidate, distance) -- keep the near-miss to explore from
        end
        register_stagnation(state)
        return false
    end

    local prev_best = state.best_frames
    beam_insert(state, candidate, frames, end_state and end_state.hspeed)
    if state.best_frames < prev_best then
        state.improvements = state.improvements + 1
        state.stagnation = 0
        state.pulse_bonus = 0 -- cool down after an improvement
        return true
    end
    register_stagnation(state)
    return false
end

---Whether the search budget has been fully consumed.
---@param state table
---@return boolean
function Bruteforce.done(state)
    return state.tried >= state.budget
end

---A snapshot of the current search progress for display.
---@param state table
---@return table summary { best_frames, baseline_frames, gain, tried, budget, improvements, niches, stagnation, best_hspeed }
function Bruteforce.summary(state)
    return {
        best_frames = state.best_frames,
        baseline_frames = state.baseline_frames,
        gain = state.baseline_frames - state.best_frames,
        tried = state.tried,
        budget = state.budget,
        improvements = state.improvements,
        niches = state.archive_count,       -- number of distinct behaviour cells the search is keeping
        stagnation = state.stagnation,      -- candidates since the last improvement (0 = just improved)
        -- horizontal speed at the goal of the best solution (nil until measured); among equal-frame
        -- solutions the beam keeps the fastest-arriving one, which chains best into the next segment
        best_hspeed = state.beam and state.beam[1] and state.beam[1].hspeed or nil,
    }
end

return Bruteforce
