--
-- Copyright (c) 2025, Mupen64 maintainers.
--
-- SPDX-License-Identifier: GPL-2.0-or-later
--

--
-- Unit tests for the pure bruteforce core (src/core/Bruteforce.lua).
-- Runs OFF-mupen with a standard Lua 5.4 interpreter:
--
--   lua tests/bruteforce_test.lua      (from the repo root)
--

-- Locate src/core/Bruteforce.lua relative to this test file so it runs from any CWD.
local here = debug.getinfo(1).source:sub(2):match('(.*[/\\])') or './'
local core_file = here .. '..' .. package.config:sub(1, 1) .. 'src' ..
    package.config:sub(1, 1) .. 'core' .. package.config:sub(1, 1) .. 'Bruteforce.lua'

local Bruteforce = dofile(core_file)

local passed, failed = 0, 0
local function check(name, cond)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print('  FAIL: ' .. name)
    end
end

---A deterministic RNG (LCG) so tests are reproducible without touching math.random state.
local function make_rng(seed)
    local s = seed or 1
    return function()
        s = (1103515245 * s + 12345) % 2147483648
        return s / 2147483648
    end
end

---Builds a simple baseline input list of n frames holding the stick fully up.
local function make_baseline(n)
    local list = {}
    for i = 1, n do
        list[i] = { X = 0, Y = 127, A = false, B = false, Z = false }
    end
    return list
end

-- clone_input: defaults + independence
do
    local a = { A = true, X = 40 }
    local b = Bruteforce.clone_input(a)
    check('clone_input copies known field', b.A == true and b.X == 40)
    check('clone_input defaults missing button to false', b.B == false)
    check('clone_input defaults missing stick to 0', b.Y == 0)
    b.A = false
    check('clone_input is independent of source', a.A == true)
    local empty = Bruteforce.clone_input(nil)
    check('clone_input(nil) yields neutral input', empty.A == false and empty.X == 0)
end

-- new: initial state
do
    local st = Bruteforce.new({ baseline = make_baseline(10), baseline_frames = 10, budget = 5 })
    check('new: best_frames starts at baseline_frames', st.best_frames == 10)
    check('new: max_frames defaults to baseline_frames', st.max_frames == 10)
    check('new: not done initially', not Bruteforce.done(st))
    local s = Bruteforce.summary(st)
    check('summary: gain starts at 0', s.gain == 0)
    check('summary: baseline_frames reported', s.baseline_frames == 10)
end

-- first candidate is the unperturbed baseline
do
    local base = make_baseline(6)
    local st = Bruteforce.new({ baseline = base, baseline_frames = 6, budget = 10, rng = make_rng(7) })
    local c1 = Bruteforce.next_candidate(st)
    local identical = true
    for i = 1, #base do
        if c1[i].X ~= base[i].X or c1[i].Y ~= base[i].Y then identical = false end
    end
    check('first candidate equals baseline', identical)
    -- and it is a copy, not the same table
    c1[1].Y = 0
    check('first candidate is a copy of baseline', base[1].Y == 127)
end

-- report_result: keeps a strictly-better reached result, rejects worse / unreached
do
    local st = Bruteforce.new({ baseline = make_baseline(20), baseline_frames = 20, budget = 100, rng = make_rng(3) })
    local cand = Bruteforce.next_candidate(st) -- baseline
    Bruteforce.report_result(st, cand, 20, true) -- reference re-measured
    check('report: reference does not beat itself', st.best_frames == 20)

    local better = Bruteforce.next_candidate(st)
    local improved = Bruteforce.report_result(st, better, 17, true)
    check('report: fewer frames improves', improved and st.best_frames == 17)

    local worse = Bruteforce.next_candidate(st)
    local improved2 = Bruteforce.report_result(st, worse, 19, true)
    check('report: more frames does not improve', not improved2 and st.best_frames == 17)

    local unreached = Bruteforce.next_candidate(st)
    local improved3 = Bruteforce.report_result(st, unreached, 5, false)
    check('report: unreached goal never improves even if short', not improved3 and st.best_frames == 17)

    local s = Bruteforce.summary(st)
    check('summary: gain reflects improvement', s.gain == 3)
end

-- reference re-basing: the first reported result (baseline re-run) re-bases the reference
do
    local st = Bruteforce.new({ baseline = make_baseline(20), baseline_frames = 20, budget = 100, rng = make_rng(5) })
    local base = Bruteforce.next_candidate(st) -- baseline
    -- the in-loop baseline actually measures 18 frames (differs from the captured 20)
    local improved = Bruteforce.report_result(st, base, 18, true)
    check('rebase: first report is not an improvement', not improved)
    check('rebase: reference becomes the in-loop measurement', st.baseline_frames == 18 and st.best_frames == 18)
    check('rebase: gain is 0 right after re-basing', Bruteforce.summary(st).gain == 0)
    local c = Bruteforce.next_candidate(st)
    local imp2 = Bruteforce.report_result(st, c, 17, true)
    check('rebase: candidate beating the re-based reference improves', imp2 and st.best_frames == 17)
    check('rebase: gain reflects the re-based reference', Bruteforce.summary(st).gain == 1)
end

-- budget: next_candidate returns nil once exhausted; done() flips
do
    local st = Bruteforce.new({ baseline = make_baseline(4), baseline_frames = 4, budget = 3, rng = make_rng(9) })
    for _ = 1, 3 do
        local c = Bruteforce.next_candidate(st)
        check('candidate available within budget', c ~= nil)
        Bruteforce.report_result(st, c, 4, false)
    end
    check('done after budget consumed', Bruteforce.done(st))
    check('no candidate past budget', Bruteforce.next_candidate(st) == nil)
end

-- perturbation stays within stick bounds and preserves list length up to max_frames
do
    local st = Bruteforce.new({
        baseline = make_baseline(8),
        baseline_frames = 8,
        max_frames = 8,
        perturb_chance = 1.0, -- perturb every frame
        perturb_magnitude = 100,
        budget = 200,
        rng = make_rng(42),
    })
    Bruteforce.next_candidate(st) -- consume baseline
    local within = true
    local right_len = true
    for _ = 1, 50 do
        local c = Bruteforce.next_candidate(st)
        if #c ~= 8 then right_len = false end
        for i = 1, #c do
            if c[i].X < -127 or c[i].X > 127 or c[i].Y < -127 or c[i].Y > 127 then within = false end
        end
        Bruteforce.report_result(st, c, 8, false)
    end
    check('perturbed sticks stay within [-127,127]', within)
    check('perturbed candidate keeps max_frames length', right_len)
end

-- determinism: same seed -> same candidate sequence
do
    local function run_seq(seed)
        local st = Bruteforce.new({ baseline = make_baseline(5), baseline_frames = 5, perturb_chance = 1.0, budget = 20, rng = make_rng(seed) })
        local acc = {}
        for _ = 1, 5 do
            local c = Bruteforce.next_candidate(st)
            for i = 1, #c do acc[#acc + 1] = c[i].X .. ',' .. c[i].Y end
            Bruteforce.report_result(st, c, 5, false)
        end
        return table.concat(acc, ';')
    end
    check('deterministic rng -> identical sequences', run_seq(123) == run_seq(123))
    check('different seed -> different sequences', run_seq(123) ~= run_seq(124))
end

-- beam search: keeps the top-K fewest-frame reached candidates
do
    local st = Bruteforce.new({ baseline = make_baseline(20), baseline_frames = 20, budget = 100, beam_width = 3, rng = make_rng(11) })
    Bruteforce.report_result(st, make_baseline(20), 20, true) -- re-base + seed the beam
    check('beam: seeded with baseline', st.best_frames == 20 and #st.beam == 1)
    for _, f in ipairs({ 15, 18, 12, 25, 10 }) do
        Bruteforce.report_result(st, make_baseline(f), f, true)
    end
    check('beam: capped at beam_width', #st.beam == 3)
    check('beam: best is the fewest-frame candidate (10)', st.best_frames == 10)
    check('beam: front holds the K best in order',
        st.beam[1].frames == 10 and st.beam[2].frames == 12 and st.beam[3].frames == 15)
    check('beam: a worse candidate does not displace the top', st.beam[3].frames == 15)
end

-- frame-removal mutation: dropping a frame shifts the action earlier (keeps padded length)
do
    local src = {}
    for i = 1, 6 do src[i] = { X = i, Y = 0 } end
    local st = Bruteforce.new({ baseline = src, baseline_frames = 6, max_frames = 6,
        perturb_chance = 0, flip_chance = 0, remove_chance = 1.0, rng = make_rng(1) })
    Bruteforce.next_candidate(st) -- consume baseline
    local c = Bruteforce.next_candidate(st)
    check('removal: candidate keeps max_frames length', #c == 6)
    local same = true
    for i = 1, 6 do if c[i].X ~= i then same = false end end
    check('removal: sequence is shifted (a frame was dropped)', not same)
end

-- jump-button perturbation: flipping toggles A/B/Z (frame-perfect jump timing search)
do
    local src = {}
    for i = 1, 5 do src[i] = { X = 0, Y = 0, A = false, B = false, Z = false } end
    local st = Bruteforce.new({ baseline = src, baseline_frames = 5, max_frames = 5,
        perturb_chance = 0, flip_chance = 1.0, remove_chance = 0, rng = make_rng(2) })
    Bruteforce.next_candidate(st) -- consume baseline
    local c = Bruteforce.next_candidate(st)
    local any_button = false
    for i = 1, #c do if c[i].A or c[i].B or c[i].Z then any_button = true end end
    check('button flip: toggles a jump button', any_button)
end

-- annealing: perturbation is hot at the start and cools over the search (auto high->low)
do
    local st = Bruteforce.new({ baseline = make_baseline(10), baseline_frames = 10, budget = 100,
        perturb_magnitude = 8, anneal_hot_bonus = 32, anneal_span = 100, rng = make_rng(1) })
    check('anneal: temperature starts at 1 (hot)', math.abs(Bruteforce.temperature(st) - 1) < 1e-9)
    check('anneal: magnitude starts hot (base + hot_bonus)', Bruteforce._effective_magnitude(st) == 40)
    st.tried = 50
    check('anneal: temperature halfway', math.abs(Bruteforce.temperature(st) - 0.5) < 1e-9)
    check('anneal: magnitude cooler halfway', Bruteforce._effective_magnitude(st) == 8 + math.floor(0.5 * 32))
    st.tried = 100
    check('anneal: temperature 0 (cold) at span end', Bruteforce.temperature(st) == 0)
    check('anneal: magnitude down to base when cold', Bruteforce._effective_magnitude(st) == 8)
    st.tried = 200
    check('anneal: stays cold past the span', Bruteforce.temperature(st) == 0)
end

-- annealing scales to Max candidates: the cool-down span follows the budget (default half of it)
do
    local small = Bruteforce.new({ baseline = make_baseline(10), baseline_frames = 10, budget = 50, rng = make_rng(1) })
    check('anneal: span defaults to half the budget (50 -> 25)', small.anneal_span == 25)
    small.tried = 25
    check('anneal: cold by half the budget', Bruteforce.temperature(small) == 0)
    small.tried = 12
    check('anneal: still warm before that', Bruteforce.temperature(small) > 0)
    local big = Bruteforce.new({ baseline = make_baseline(10), baseline_frames = 10, budget = 2000, rng = make_rng(1) })
    check('anneal: span scales with a bigger budget (2000 -> 1000)', big.anneal_span == 1000)
end

-- annealing off: temperature is always 0, magnitude is just the base
do
    local st = Bruteforce.new({ baseline = make_baseline(10), baseline_frames = 10, perturb_magnitude = 8, anneal = false, rng = make_rng(1) })
    check('anneal off: temperature is 0', Bruteforce.temperature(st) == 0)
    check('anneal off: magnitude is the base', Bruteforce._effective_magnitude(st) == 8)
end

-- the reactive stagnation pulse still adds on top of the (cold) floor
do
    local st = Bruteforce.new({ baseline = make_baseline(10), baseline_frames = 10, budget = 1000,
        perturb_magnitude = 8, anneal = false, pulse_after = 40, rng = make_rng(1) })
    Bruteforce.report_result(st, make_baseline(10), 10, true) -- re-base + seed beam
    check('pulse: magnitude is the base before any stall', Bruteforce._effective_magnitude(st) == 8)
    for _ = 1, 40 do Bruteforce.report_result(st, make_baseline(12), 12, true) end -- 40 non-improving
    check('pulse: magnitude bumped after pulse_after stalls', Bruteforce._effective_magnitude(st) > 8)
    -- an improvement cools the pulse back down
    Bruteforce.report_result(st, make_baseline(9), 9, true)
    check('pulse: cools back to base after an improvement', Bruteforce._effective_magnitude(st) == 8)
end

-- edit_from: chunk mode freezes the optimised prefix (frames before edit_from are never perturbed)
do
    local src = {}
    for i = 1, 10 do src[i] = { X = 100, Y = 100, A = false } end
    local st = Bruteforce.new({ baseline = src, baseline_frames = 10, max_frames = 10,
        perturb_chance = 1.0, flip_chance = 1.0, remove_chance = 1.0, edit_from = 6, anneal = false, rng = make_rng(3) })
    Bruteforce.next_candidate(st) -- consume baseline
    local prefix_intact = true
    for _ = 1, 50 do
        local c = Bruteforce.next_candidate(st)
        for i = 1, 5 do
            if c[i].X ~= 100 or c[i].Y ~= 100 or c[i].A ~= false then prefix_intact = false end
        end
        Bruteforce.report_result(st, c, 10, false, 50)
    end
    check('edit_from: frozen prefix (frames 1..5) is never perturbed', prefix_intact)

    local st2 = Bruteforce.new({ baseline = src, baseline_frames = 10, max_frames = 10,
        perturb_chance = 1.0, remove_chance = 0, edit_from = 6, anneal = false, rng = make_rng(3) })
    Bruteforce.next_candidate(st2)
    local c2 = Bruteforce.next_candidate(st2)
    local editable_changed = false
    for i = 6, 10 do if c2[i].X ~= 100 or c2[i].Y ~= 100 then editable_changed = true end end
    check('edit_from: editable region (frames 6..10) IS perturbed', editable_changed)
end

-- chunking: split a baseline + per-frame states into N chunks with boundary checkpoints
do
    local base, states = {}, {}
    for i = 1, 10 do
        base[i] = { X = i, Y = 0 }
        states[i] = { action = 0x1000 + i, x = i * 10, y = 0, z = i * 5 }
    end
    local chunks = Bruteforce.split(base, states, 3) -- 10 frames / 3 -> 4,4,2
    check('split: produces the requested number of chunks', #chunks == 3)
    check('split: chunk lengths cover the baseline', #chunks[1].inputs == 4 and #chunks[2].inputs == 4 and #chunks[3].inputs == 2)
    check('split: total frames preserved', (#chunks[1].inputs + #chunks[2].inputs + #chunks[3].inputs) == 10)
    check('split: checkpoint 1 is the state at frame 4', chunks[1].checkpoint.action == 0x1000 + 4 and chunks[1].checkpoint.x == 40)
    check('split: last checkpoint is the final state (frame 10)', chunks[3].checkpoint.action == 0x1000 + 10 and chunks[3].checkpoint.z == 50)
    check('split: first chunk starts at frame 1', chunks[1].inputs[1].X == 1)
    check('split: second chunk starts at frame 5', chunks[2].inputs[1].X == 5)
    -- n=1 -> a single chunk equal to the whole baseline
    local one = Bruteforce.split(base, states, 1)
    check('split: n=1 yields one full-length chunk', #one == 1 and #one[1].inputs == 10)
    -- n larger than the baseline is clamped
    local many = Bruteforce.split({ { X = 0 }, { X = 1 } }, { { action = 1 }, { action = 2 } }, 9)
    check('split: n clamped to baseline length', #many == 2)
end

-- soft fitness: near-misses populate the explore pool (closest-K by distance)
do
    local st = Bruteforce.new({ baseline = make_baseline(20), baseline_frames = 20, budget = 200, explore_width = 3, rng = make_rng(7) })
    Bruteforce.report_result(st, make_baseline(20), 20, true) -- re-base + seed beam
    for _, dist in ipairs({ 300, 150, 500, 100, 250, 80 }) do
        Bruteforce.report_result(st, make_baseline(20), 20, false, dist) -- non-reached near-misses
    end
    check('explore: pool capped at explore_width', #st.explore == 3)
    check('explore: keeps the closest near-misses',
        st.explore[1].distance == 80 and st.explore[2].distance == 100 and st.explore[3].distance == 150)
end

-- soft fitness: a non-reached result without a distance is ignored (backward compatible)
do
    local st = Bruteforce.new({ baseline = make_baseline(20), baseline_frames = 20, budget = 50, rng = make_rng(1) })
    Bruteforce.report_result(st, make_baseline(20), 20, true)
    Bruteforce.report_result(st, make_baseline(20), 20, false) -- no distance argument
    check('explore: nil distance leaves the pool empty', #st.explore == 0)
end

-- m64 input encoding: button bits, stick bytes, length
do
    local b = Bruteforce.encode_m64_input({ A = true, X = 127, Y = 0 })
    check('encode: 4 bytes per frame', #b == 4)
    check('encode: A sets bit 0x0080', (string.unpack('<I2', b)) == 0x0080)
    check('encode: stick X byte', string.unpack('b', b, 3) == 127)
    check('encode: stick Y byte', string.unpack('b', b, 4) == 0)

    local c = Bruteforce.encode_m64_input({ B = true, Z = true, X = -50, Y = 100 })
    check('encode: B|Z sets 0x0060', (string.unpack('<I2', c)) == (0x0040 | 0x0020))
    check('encode: negative stick X', string.unpack('b', c, 3) == -50)
    check('encode: stick Y = 100', string.unpack('b', c, 4) == 100)

    -- L must NOT collide with Z (the bug the user caught: Z was mapped to L_TRIG 0x2000)
    check('encode: Z is 0x0020, not L', (string.unpack('<I2', Bruteforce.encode_m64_input({ Z = true }))) == 0x0020)
    check('encode: L is 0x2000', (string.unpack('<I2', Bruteforce.encode_m64_input({ L = true }))) == 0x2000)

    local n = Bruteforce.encode_m64_input({})
    check('encode: neutral input is zero buttons', (string.unpack('<I2', n)) == 0)
end

-- m64 header re-heading: patches frame count / VI count / start type, preserves size and other bytes
do
    local header = string.rep('X', Bruteforce.M64_HEADER_SIZE)
    local h = Bruteforce.reheader_m64(header, 73)
    check('reheader: size preserved (0x400)', #h == Bruteforce.M64_HEADER_SIZE)
    check('reheader: input samples @0x018 = 73', (string.unpack('<I4', h, 0x018 + 1)) == 73)
    check('reheader: VI count @0x00C = 146', (string.unpack('<I4', h, 0x00C + 1)) == 146)
    check('reheader: start type @0x01C = 1 (savestate)', (string.unpack('<I2', h, 0x01C + 1)) == 1)
    check('reheader: signature area untouched', h:sub(1, 4) == 'XXXX')
    check('reheader: byte after patched fields untouched', h:sub(0x020 + 1, 0x020 + 1) == 'X')
end

-- m64 body building: count frames * 4 bytes
do
    local list = { { A = true, X = 10, Y = 20 }, { B = true, X = -10, Y = -20 } }
    local body = Bruteforce.build_m64_body(list, 2)
    check('body: 4 bytes per frame', #body == 8)
    check('body: frame 1 A bit', (string.unpack('<I2', body, 1)) == 0x0080)
    check('body: frame 2 B bit', (string.unpack('<I2', body, 5)) == 0x0040)
    -- padding when list is shorter than count
    local padded = Bruteforce.build_m64_body({ { A = true } }, 3)
    check('body: pads to count with neutral frames', #padded == 12)
    check('body: padded frames are neutral', (string.unpack('<I2', padded, 5)) == 0)
end

-- m64 splice: replaces a segment in a full movie, preserving structure + updating counters
do
    -- Build a synthetic movie: 0x400 header (samples field @0x018) + `n` frames, frame i has stick X=i*10.
    local function make_movie(n)
        local header = string.rep('\0', 0x018) .. string.pack('<I4', n) .. string.rep('\0', 0x400 - 0x018 - 4)
        local body = {}
        for i = 1, n do
            body[i] = string.pack('<I2', 0) .. string.pack('b', i * 10) .. string.pack('b', 0)
        end
        return header .. table.concat(body)
    end

    local movie = make_movie(5) -- frames X = 10,20,30,40,50
    local optimized = Bruteforce.encode_m64_input({ X = 99 }) -- 1 frame replacing 2
    local spliced = Bruteforce.splice_m64(movie, 1, 2, optimized) -- replace frames idx 1,2 (X=20,30)

    check('splice: returns a string', type(spliced) == 'string')
    local new_samples = string.unpack('<I4', spliced, 0x018 + 1)
    check('splice: sample count updated (5-2+1=4)', new_samples == 4)
    check('splice: VI count updated', (string.unpack('<I4', spliced, 0x00C + 1)) == 8)
    check('splice: total size matches 0x400 + 4*4', #spliced == 0x400 + 4 * 4)
    -- verify the resulting input stream: 10, 99, 40, 50
    local istart = #spliced - new_samples * 4
    check('splice: frame 0 preserved (X=10)', string.unpack('b', spliced, istart + 3) == 10)
    check('splice: segment replaced (X=99)', string.unpack('b', spliced, istart + 4 + 3) == 99)
    check('splice: frame after segment preserved (X=40)', string.unpack('b', spliced, istart + 8 + 3) == 40)
    check('splice: last frame preserved (X=50)', string.unpack('b', spliced, istart + 12 + 3) == 50)

    -- validation failures return nil + tag
    check('splice: out-of-range segment rejected', (Bruteforce.splice_m64(movie, 4, 5, optimized)) == nil)
    check('splice: too-small movie rejected', (Bruteforce.splice_m64('short', 0, 0, optimized)) == nil)
end

-- fixed mode is still possible: anneal off + pulse off => the magnitude is CONSTANT for the whole
-- search (the auto-managed driver keeps both ON; this checks the opts still disable them cleanly).
do
    local fixed = Bruteforce.new({ baseline = { { A = false } }, baseline_frames = 1, max_frames = 4,
        perturb_magnitude = 8, anneal_hot_bonus = 50, anneal = false, pulse_after = 0 })
    check('fixed: magnitude == chosen level at start', Bruteforce._effective_magnitude(fixed) == 8)
    -- drive many non-improving results (would trigger annealing decay + pulses if they were on)
    for _ = 1, 300 do Bruteforce.report_result(fixed, { { A = false } }, 4, false, 100) end
    check('fixed: no pulse bump after stagnation', fixed.pulse_bonus == 0)
    check('fixed: magnitude still == chosen level', Bruteforce._effective_magnitude(fixed) == 8)
    check('fixed: temperature stays 0', Bruteforce.temperature(fixed) == 0)
end

-- to_overrides: wrap raw frames into semantic manual overrides for the Semantic Workflow
do
    local MANUAL = 2 -- stand-in for MovementModes.manual
    local made = 0
    local function tas_factory()
        made = made + 1
        return { movement_mode = 1, manual_joystick_x = 0, manual_joystick_y = 0, other = 'kept' }
    end
    local frames = {
        { X = 40, Y = -20, A = true, B = false, Z = false },
        { X = -127, Y = 100, A = false, B = true, Z = true },
        { X = 0, Y = 0, A = false, B = false, Z = false }, -- extra, should be ignored by count=2
    }
    local ov = Bruteforce.to_overrides(frames, 2, tas_factory, MANUAL)

    check('to_overrides: respects count', #ov == 2)
    check('to_overrides: made one tas_state per frame', made == 2)
    check('to_overrides: movement_mode set to manual', ov[1].tas_state.movement_mode == MANUAL)
    check('to_overrides: manual stick copies X', ov[1].tas_state.manual_joystick_x == 40)
    check('to_overrides: manual stick copies Y', ov[1].tas_state.manual_joystick_y == -20)
    check('to_overrides: keeps other tas fields', ov[1].tas_state.other == 'kept')
    check('to_overrides: joy carries the sticks', ov[2].joy.X == -127 and ov[2].joy.Y == 100)
    check('to_overrides: joy carries the buttons', ov[2].joy.B == true and ov[2].joy.Z == true)
    -- full SectionInputs shape: each optimized frame plays exactly one frame in a real sheet
    check('to_overrides: frame-exact timeout', ov[1].timeout == 1 and ov[2].timeout == 1)
    check('to_overrides: end_action disabled (0)', ov[1].end_action == 0)
    check('to_overrides: not marked editing', ov[1].editing == false)
    -- joy must be a distinct clone (mutating the override must not touch the source frame)
    ov[1].joy.X = 999
    check('to_overrides: joy is a clone, not the source frame', frames[1].X == 40)
    -- a missing frame degrades to a neutral override rather than crashing
    local sparse = Bruteforce.to_overrides({}, 1, tas_factory, MANUAL)
    check('to_overrides: missing frame -> neutral stick', sparse[1].tas_state.manual_joystick_x == 0)
end

-- RNG seeding: a seed makes the search reproducible (and the stochastic ops testable)
do
    local lcg1 = Bruteforce.make_lcg(123)
    local lcg2 = Bruteforce.make_lcg(123)
    check('make_lcg: same seed -> same stream', lcg1() == lcg2() and lcg1() == lcg2())
    check('make_lcg: outputs are in [0,1)', (function()
        local v = Bruteforce.make_lcg(7)()
        return v >= 0 and v < 1
    end)())

    local function first_candidate(seed)
        local st = Bruteforce.new({ baseline = make_baseline(6), baseline_frames = 6, max_frames = 6,
            perturb_chance = 1.0, seed = seed })
        Bruteforce.next_candidate(st) -- consume the baseline
        return Bruteforce.next_candidate(st)
    end
    local a, b, c = first_candidate(99), first_candidate(99), first_candidate(100)
    local same_ab, diff_ac = true, false
    for i = 1, #a do
        if a[i].X ~= b[i].X or a[i].Y ~= b[i].Y then same_ab = false end
        if a[i].X ~= c[i].X then diff_ac = true end
    end
    check('seed: same seed -> identical candidate', same_ab)
    check('seed: different seed -> different candidate', diff_ac)
end

-- smarter frame-removal: neutrality/duplicate detection + redundant bias + multi-frame removal
do
    check('neutral: a wait frame (no buttons, centred stick) is neutral',
        Bruteforce._frame_is_neutral({ X = 0, Y = 0 }) == true)
    check('neutral: a held stick is NOT neutral',
        Bruteforce._frame_is_neutral({ X = 100, Y = 0 }) == false)
    check('neutral: a pressed jump button is NOT neutral',
        Bruteforce._frame_is_neutral({ X = 0, Y = 0, A = true }) == false)

    -- redundant bias = 1 => must target the single neutral frame (index 2)
    do
        local out = { { X = 100, Y = 0 }, { X = 0, Y = 0 }, { X = 100, Y = 0 }, { X = 110, Y = 0 } }
        local st = Bruteforce.new({ baseline = { { X = 1, Y = 0 } }, baseline_frames = 1,
            remove_redundant_bias = 1.0, rng = make_rng(5) })
        check('removal bias: targets the neutral frame', Bruteforce._pick_removal_index(st, out) == 2)
    end
    -- duplicate of the previous frame counts as redundant (index 2 duplicates index 1)
    do
        local out = { { X = 100, Y = 0, A = true }, { X = 100, Y = 0, A = true }, { X = 50, Y = 0 } }
        local st = Bruteforce.new({ baseline = { { X = 1, Y = 0 } }, baseline_frames = 1,
            remove_redundant_bias = 1.0, rng = make_rng(5) })
        check('removal bias: targets the duplicate frame', Bruteforce._pick_removal_index(st, out) == 2)
    end
    -- multi-frame removal drops a short run of 2-3 at once
    do
        local out = {}
        for i = 1, 10 do out[i] = { X = 100, Y = 0 } end
        local st = Bruteforce.new({ baseline = { { X = 1, Y = 0 } }, baseline_frames = 1,
            remove_chance = 1.0, multi_remove_chance = 1.0, remove_redundant_bias = 0.0, rng = make_rng(11) })
        local removed = Bruteforce._apply_removal(st, out)
        check('multi-remove: drops 2 or 3 frames at once', removed >= 2 and removed <= 3)
        check('multi-remove: list shrank by exactly that many', #out == 10 - removed)
    end
end

-- windowed mutation: local search restricts perturbation to a contiguous sub-window
do
    -- window_chance = 0 => always the whole editable region
    local full = Bruteforce.new({ baseline = { { X = 0 } }, baseline_frames = 1, window_chance = 0.0, rng = make_rng(1) })
    local lo, hi = Bruteforce._pick_window(full, 3, 20)
    check('window: chance 0 -> whole region', lo == 3 and hi == 20)

    -- window_chance = 1 => a strict sub-window within [lo,hi], of the expected fraction length
    local win = Bruteforce.new({ baseline = { { X = 0 } }, baseline_frames = 1,
        window_chance = 1.0, window_frac = 0.25, window_min = 2, rng = make_rng(3) })
    local wlo, whi = Bruteforce._pick_window(win, 1, 20)
    check('window: stays inside the region', wlo >= 1 and whi <= 20)
    check('window: is a strict sub-window', (whi - wlo + 1) < 20)
    check('window: honours the fraction length', (whi - wlo + 1) == math.floor(20 * 0.25))

    -- a tiny region (<= window_min) is always perturbed whole (no point windowing)
    local tiny = Bruteforce.new({ baseline = { { X = 0 } }, baseline_frames = 1,
        window_chance = 1.0, window_min = 8, rng = make_rng(4) })
    local tlo, thi = Bruteforce._pick_window(tiny, 1, 5)
    check('window: tiny region perturbed whole', tlo == 1 and thi == 5)
end

-- quality-diversity archive (scattershot-lite): cell binning + best-per-cell + diverse expansion
do
    local st = Bruteforce.new({ baseline = make_baseline(4), baseline_frames = 4, max_frames = 4,
        tie_to_newcomer = 0.0, cell_size = 100, cell_speed_size = 4, rng = make_rng(1) })

    local k1 = Bruteforce._cell_key(st, { action = 5, x = 10,  z = 20, hspeed = 30 })
    local k2 = Bruteforce._cell_key(st, { action = 5, x = 90,  z = 20, hspeed = 30 }) -- same 100-unit cell
    local k3 = Bruteforce._cell_key(st, { action = 5, x = 210, z = 20, hspeed = 30 }) -- different x cell
    local k4 = Bruteforce._cell_key(st, { action = 6, x = 10,  z = 20, hspeed = 30 }) -- different action
    local k5 = Bruteforce._cell_key(st, { action = 5, x = 10,  z = 20, hspeed = 90 }) -- different speed bucket
    check('cell_key: same coarse cell -> same key', k1 == k2)
    check('cell_key: different position cell -> different key', k1 ~= k3)
    check('cell_key: different action -> different key', k1 ~= k4)
    check('cell_key: different speed bucket -> different key', k1 ~= k5)

    local cand = make_baseline(4)
    Bruteforce._archive_insert(st, cand, 4, false, 50, { action = 5, x = 10, z = 20, hspeed = 30 })
    check('archive: first insert creates a cell', st.archive_count == 1)
    Bruteforce._archive_insert(st, cand, 3, true, nil, { action = 5, x = 10, z = 20, hspeed = 30 })
    check('archive: reached replaces non-reached (same cell)', st.archive[k1].reached == true)
    check('archive: replace keeps the cell count', st.archive_count == 1)
    Bruteforce._archive_insert(st, cand, 2, true, nil, { action = 5, x = 10, z = 20, hspeed = 30 })
    check('archive: fewer frames wins', st.archive[k1].frames == 2)
    Bruteforce._archive_insert(st, cand, 9, true, nil, { action = 5, x = 10, z = 20, hspeed = 30 })
    check('archive: worse (more frames) rejected', st.archive[k1].frames == 2)
    Bruteforce._archive_insert(st, cand, 5, true, nil, { action = 5, x = 500, z = 20, hspeed = 30 })
    check('archive: a new cell increments the count', st.archive_count == 2)
end

-- archive is fed by report_result(end_state) and expanded by next_candidate
do
    local st = Bruteforce.new({ baseline = make_baseline(5), baseline_frames = 5, max_frames = 5,
        archive_prob = 1.0, tie_to_newcomer = 0.0, budget = 100, rng = make_rng(2) })
    Bruteforce.next_candidate(st) -- consume the baseline (_first)
    Bruteforce.report_result(st, make_baseline(5), 5, false, 40, { action = 1, x = 0, z = 0, hspeed = 10 })
    check('report_result: end_state populates the archive', st.archive_count == 1)
    local c = Bruteforce.next_candidate(st) -- archive_prob = 1 -> must expand the archive niche
    check('next_candidate: expands the archive (valid candidate)', type(c) == 'table' and #c == 5)

    -- backward compat: without end_state the archive stays empty (beam+explore behaviour preserved)
    local st2 = Bruteforce.new({ baseline = make_baseline(5), baseline_frames = 5, max_frames = 5, rng = make_rng(3) })
    Bruteforce.next_candidate(st2)
    Bruteforce.report_result(st2, make_baseline(5), 5, false, 40) -- no end_state
    check('archive stays empty without end_state', st2.archive_count == 0)
end

-- edge-nudge: shifts a jump-button press/release edge in time (timing search)
do
    -- rising edge at frame 3 on ALL three jump buttons (so whichever the operator picks has an edge)
    local orig = {}
    for i = 1, 5 do local v = i >= 3; orig[i] = { A = v, B = v, Z = v } end
    local out = {}
    for i = 1, 5 do out[i] = { A = orig[i].A, B = orig[i].B, Z = orig[i].Z } end
    local st = Bruteforce.new({ baseline = { { A = false } }, baseline_frames = 1,
        edge_nudge_chance = 1.0, edit_from = 1, rng = make_rng(9) })
    check('edge-nudge: reports it moved an edge', Bruteforce._apply_edge_nudge(st, out) == true)
    local changed = false
    for i = 1, #out do
        for _, b in ipairs({ 'A', 'B', 'Z' }) do
            if (out[i][b] or false) ~= orig[i][b] then changed = true end
        end
    end
    check('edge-nudge: the button timing changed', changed)

    -- a flat channel (no edge on any button) is a no-op
    local flat = { { A = false }, { A = false }, { A = false } }
    local st2 = Bruteforce.new({ baseline = { { A = false } }, baseline_frames = 1,
        edge_nudge_chance = 1.0, edit_from = 1, rng = make_rng(9) })
    check('edge-nudge: no edge -> no-op', Bruteforce._apply_edge_nudge(st2, flat) == false)

    -- chance 0 disables it
    local st3 = Bruteforce.new({ baseline = { { A = false } }, baseline_frames = 1,
        edge_nudge_chance = 0.0, edit_from = 1, rng = make_rng(9) })
    check('edge-nudge: chance 0 -> disabled', Bruteforce._apply_edge_nudge(st3, flat) == false)
end

-- frame-insertion: duplicates a frame (the counterpart of removal, for timing compensation)
do
    local out = {}
    for i = 1, 5 do out[i] = { X = i * 10, Y = 0 } end
    local st = Bruteforce.new({ baseline = { { X = 0 } }, baseline_frames = 1,
        insert_chance = 1.0, edit_from = 1, rng = make_rng(4) })
    check('insert: reports insertion', Bruteforce._apply_insert(st, out) == true)
    check('insert: list grew by one', #out == 6)
    local dup = false
    for i = 2, #out do if out[i].X == out[i - 1].X then dup = true end end
    check('insert: inserted frame duplicates a frame', dup)

    local st0 = Bruteforce.new({ baseline = { { X = 0 } }, baseline_frames = 1,
        insert_chance = 0.0, rng = make_rng(4) })
    check('insert: chance 0 -> disabled', Bruteforce._apply_insert(st0, out) == false)

    -- through perturb, the candidate is trimmed back to max_frames (never exceeds the timeout)
    local st2 = Bruteforce.new({ baseline = make_baseline(6), baseline_frames = 6, max_frames = 6,
        perturb_chance = 0, insert_chance = 1.0, remove_chance = 0, flip_chance = 0,
        edge_nudge_chance = 0, rotate_chance = 0, snap_chance = 0, rng = make_rng(2) })
    Bruteforce.next_candidate(st2) -- consume baseline
    local c = Bruteforce.next_candidate(st2)
    check('insert: candidate trimmed back to max_frames', #c == 6)
end

-- polar stick mutation: ROTATE keeps the magnitude and turns the direction
do
    local base = {}
    for i = 1, 6 do base[i] = { X = 0, Y = 127 } end
    local st = Bruteforce.new({ baseline = base, baseline_frames = 6, max_frames = 6,
        perturb_chance = 0, flip_chance = 0, remove_chance = 0, edge_nudge_chance = 0,
        insert_chance = 0, snap_chance = 0, crossover_chance = 0, rotate_chance = 1.0,
        window_chance = 0, anneal = false, rng = make_rng(21) })
    Bruteforce.next_candidate(st) -- consume baseline
    local c = Bruteforce.next_candidate(st)
    local turned, mag_kept = false, true
    for i = 1, 6 do
        if c[i].X ~= 0 then turned = true end
        local r = math.sqrt(c[i].X ^ 2 + c[i].Y ^ 2)
        if r < 124 or r > 128 then mag_kept = false end
    end
    check('rotate: direction changed on some frame', turned)
    check('rotate: magnitude preserved (~127)', mag_kept)
end

-- polar stick mutation: SNAP keeps the direction and pushes the stick to full deflection
do
    local base = {}
    for i = 1, 4 do base[i] = { X = 30, Y = 40 } end -- r = 50, direction ratio 3:4
    local st = Bruteforce.new({ baseline = base, baseline_frames = 4, max_frames = 4,
        perturb_chance = 0, flip_chance = 0, remove_chance = 0, edge_nudge_chance = 0,
        insert_chance = 0, rotate_chance = 0, crossover_chance = 0, snap_chance = 1.0,
        window_chance = 0, anneal = false, rng = make_rng(22) })
    Bruteforce.next_candidate(st) -- consume baseline
    local c = Bruteforce.next_candidate(st)
    local full, dir_kept = true, true
    for i = 1, 4 do
        local r = math.sqrt(c[i].X ^ 2 + c[i].Y ^ 2)
        if r < 125 or r > 128 then full = false end
        if c[i].X <= 0 or c[i].Y <= 0 or math.abs(4 * c[i].X - 3 * c[i].Y) > 12 then dir_kept = false end
    end
    check('snap: stick pushed to full deflection (~127)', full)
    check('snap: direction preserved (3:4 ratio)', dir_kept)
end

-- polar mutations skip deadzone frames (no meaningful direction to rotate/snap)
do
    local base = {}
    for i = 1, 4 do base[i] = { X = 3, Y = 0 } end -- inside the deadzone
    local st = Bruteforce.new({ baseline = base, baseline_frames = 4, max_frames = 4,
        perturb_chance = 0, flip_chance = 0, remove_chance = 0, edge_nudge_chance = 0,
        insert_chance = 0, rotate_chance = 1.0, snap_chance = 1.0, crossover_chance = 0,
        window_chance = 0, anneal = false, rng = make_rng(23) })
    Bruteforce.next_candidate(st) -- consume baseline
    local c = Bruteforce.next_candidate(st)
    local untouched = true
    for i = 1, 4 do if c[i].X ~= 3 or c[i].Y ~= 0 then untouched = false end end
    check('polar: deadzone frames untouched', untouched)
end

-- crossover: child = a's prefix + b's suffix, single cut point, independent copy
do
    local a, b = {}, {}
    for i = 1, 8 do a[i] = { X = 1, Y = 0 }; b[i] = { X = 2, Y = 0 } end
    local st = Bruteforce.new({ baseline = { { X = 0 } }, baseline_frames = 1,
        edit_from = 1, rng = make_rng(6) })
    local child = Bruteforce._crossover(st, a, b)
    check('crossover: child has full length', #child == 8)
    check('crossover: starts with parent a', child[1].X == 1)
    check('crossover: ends with parent b', child[8].X == 2)
    local switches = 0
    for i = 2, 8 do if child[i].X ~= child[i - 1].X then switches = switches + 1 end end
    check('crossover: single cut point', switches == 1)
    child[1].X = 99
    check('crossover: child is a copy of the parents', a[1].X == 1)
end

-- deterministic removal sweep: every redundant frame of the best is tried exactly once, end-first
do
    local base = {
        { X = 10, Y = 0 }, { X = 20, Y = 0 }, { X = 30, Y = 0 },
        { X = 0, Y = 0 }, -- neutral wait frame: the obvious drop
        { X = 50, Y = 0 }, { X = 60, Y = 0 },
    }
    local function make_state(extra)
        local opts = {
            baseline = base, baseline_frames = 6, max_frames = 6,
            perturb_chance = 0, flip_chance = 0, remove_chance = 0, edge_nudge_chance = 0,
            insert_chance = 0, rotate_chance = 0, snap_chance = 0, crossover_chance = 0,
            window_chance = 0, anneal = false, pulse_after = 0, budget = 50, rng = make_rng(8),
        }
        for k, v in pairs(extra or {}) do opts[k] = v end
        return Bruteforce.new(opts)
    end

    local st = make_state()
    Bruteforce.next_candidate(st) -- baseline
    Bruteforce.report_result(st, Bruteforce.clone_list(base), 6, true) -- re-base + seed beam
    local c = Bruteforce.next_candidate(st)
    check('sweep: candidate drops exactly the neutral frame',
        c[1].X == 10 and c[2].X == 20 and c[3].X == 30 and c[4].X == 50 and c[5].X == 60)
    check('sweep: padded back to max_frames', #c == 6 and c[6].X == 60)
    -- the removal works: one frame saved -> new best; the queue rebuilds against the new best
    Bruteforce.report_result(st, c, 5, true)
    check('sweep: improvement recorded', st.best_frames == 5)
    -- the new best has no redundant frame left -> sweep exhausted, random search resumes
    local c2 = Bruteforce.next_candidate(st)
    check('sweep: exhausts then falls back to random search', type(c2) == 'table' and #c2 == 6)

    -- sweep = false disables the deterministic phase entirely
    local st2 = make_state({ sweep = false })
    Bruteforce.next_candidate(st2)
    Bruteforce.report_result(st2, Bruteforce.clone_list(base), 6, true)
    check('sweep: disabled -> no sweep candidate', Bruteforce._next_sweep_candidate(st2) == nil)

    -- no sweep before anything reached (nothing trustworthy to trim yet)
    local st3 = make_state()
    Bruteforce.next_candidate(st3)
    check('sweep: inactive while the beam is empty', Bruteforce._next_sweep_candidate(st3) == nil)
end

-- beam speed tie-break: among equal-frame solutions, the fastest arrival becomes the best
do
    local st = Bruteforce.new({ baseline = make_baseline(20), baseline_frames = 20,
        budget = 100, rng = make_rng(12) })
    Bruteforce.report_result(st, make_baseline(20), 20, true, nil, { action = 1, x = 0, z = 0, hspeed = 10 })
    local slow = make_baseline(15); slow[1].X = 1
    local fast = make_baseline(15); fast[1].X = 2
    Bruteforce.report_result(st, slow, 15, true, nil, { action = 1, x = 0, z = 0, hspeed = 20 })
    Bruteforce.report_result(st, fast, 15, true, nil, { action = 1, x = 500, z = 0, hspeed = 45 })
    check('speed tie-break: same frames, faster arrival wins the front', st.beam[1].hspeed == 45)
    check('speed tie-break: best_list is the faster candidate', st.best_list[1].X == 2)
    check('speed tie-break: best_frames unchanged by a tie swap', st.best_frames == 15)
    local slower = make_baseline(15); slower[1].X = 3
    Bruteforce.report_result(st, slower, 15, true, nil, { action = 1, x = 900, z = 0, hspeed = 5 })
    check('speed tie-break: slower same-frame candidate does not displace', st.beam[1].hspeed == 45)
    check('summary: exposes best_hspeed', Bruteforce.summary(st).best_hspeed == 45)
    -- fewer frames still beats any speed
    Bruteforce.report_result(st, make_baseline(12), 12, true, nil, { action = 1, x = 0, z = 900, hspeed = 1 })
    check('speed tie-break: fewer frames still wins outright', st.best_frames == 12 and st.beam[1].hspeed == 1)
    -- speed is compared by magnitude (a fast backwards arrival counts too)
    local bw = make_baseline(12); bw[1].X = 7
    Bruteforce.report_result(st, bw, 12, true, nil, { action = 1, x = 0, z = 400, hspeed = -50 })
    check('speed tie-break: negative speed compared by magnitude', st.beam[1].hspeed == -50)
    -- results without an end_state still enter the beam (hspeed nil loses ties, never crashes)
    Bruteforce.report_result(st, make_baseline(12), 12, true)
    check('speed tie-break: nil hspeed accepted and loses the tie', st.beam[1].hspeed == -50)
end

-- curiosity-weighted archive expansion: the 2-way tournament prefers the less-expanded cell
do
    local st = Bruteforce.new({ baseline = make_baseline(4), baseline_frames = 4, max_frames = 4,
        tie_to_newcomer = 0.0, rng = make_rng(1) })
    local listA = make_baseline(4); listA[1].X = 1
    local listB = make_baseline(4); listB[1].X = 2
    Bruteforce._archive_insert(st, listA, 4, false, 50, { action = 1, x = 0, z = 0, hspeed = 0 })
    Bruteforce._archive_insert(st, listB, 4, false, 50, { action = 1, x = 1000, z = 0, hspeed = 0 })
    check('curiosity: two cells registered', st.archive_count == 2)
    local keyA = Bruteforce._cell_key(st, { action = 1, x = 0, z = 0, hspeed = 0 })
    local keyB = Bruteforce._cell_key(st, { action = 1, x = 1000, z = 0, hspeed = 0 })
    st.archive[keyA].expansions = 5 -- cell A has been mined heavily already
    -- rng stub: the tournament draws cell 1 (A) then cell 2 (B)
    local draws, di = { 0.0, 0.9 }, 0
    st.rng = function() di = di + 1; return draws[di] or 0.5 end
    local picked = Bruteforce._pick_archive_cell(st)
    check('curiosity: tournament picks the less-expanded cell', picked[1].X == 2)
    check('curiosity: expansion counted on the picked cell', st.archive[keyB].expansions == 1)
    -- a better representative replacing the cell keeps the cell's expansion history
    Bruteforce._archive_insert(st, listA, 3, true, nil, { action = 1, x = 1000, z = 0, hspeed = 0 })
    check('curiosity: replacement inherits the expansion count', st.archive[keyB].expansions == 1)
end

-- early-abort cutoff: candidates that cannot beat the best anymore are cut at best + slack
do
    local st = Bruteforce.new({ baseline = make_baseline(30), baseline_frames = 30, max_frames = 30,
        prune_slack = 2, rng = make_rng(1) })
    check('cutoff: full max_frames while nothing reached', Bruteforce.cutoff(st) == 30)
    Bruteforce.report_result(st, make_baseline(30), 30, true) -- re-base + seed beam
    check('cutoff: best at baseline -> still capped by max_frames', Bruteforce.cutoff(st) == 30)
    Bruteforce.report_result(st, make_baseline(20), 20, true) -- big improvement
    check('cutoff: best + slack once improved', Bruteforce.cutoff(st) == 22)
end

-- candidate dedupe: identical input lists are never handed out twice
do
    local a = { { X = 5, Y = -3, A = true } }
    local b = { { X = 5, Y = -3, A = true } }
    local c = { { X = 5, Y = -3, A = false } }
    check('hash: equal candidates hash equal', Bruteforce._hash_candidate(a) == Bruteforce._hash_candidate(b))
    check('hash: different button -> different hash', Bruteforce._hash_candidate(a) ~= Bruteforce._hash_candidate(c))

    -- with all mutation chances at 0 the generator would return the baseline forever; dedupe
    -- must detect the repeat (the reroll returns an identical list, but it is marked as seen)
    local st = Bruteforce.new({ baseline = make_baseline(4), baseline_frames = 4, max_frames = 4,
        perturb_chance = 0, flip_chance = 0, remove_chance = 0, edge_nudge_chance = 0,
        insert_chance = 0, rotate_chance = 0, snap_chance = 0, crossover_chance = 0,
        window_chance = 0, anneal = false, sweep = false, budget = 10, rng = make_rng(2) })
    Bruteforce.next_candidate(st) -- baseline (marked seen)
    check('dedupe: baseline marked as seen', st.seen_count == 1)
    Bruteforce.next_candidate(st)
    check('dedupe: seen set does not grow on duplicates', st.seen_count == 1)
end

-- deterministic edge sweep: every A/B/Z edge of the best gets its +-1-frame shift tried, end-first
do
    -- best: distinct sticks, A pressed on frames 3-4 -> edges at e=3 (press) and e=5 (release)
    local base = {}
    for i = 1, 6 do base[i] = { X = i * 10, Y = 0, A = (i == 3 or i == 4) } end
    local st = Bruteforce.new({ baseline = base, baseline_frames = 6, max_frames = 6,
        perturb_chance = 0, flip_chance = 0, remove_chance = 0, edge_nudge_chance = 0,
        insert_chance = 0, rotate_chance = 0, snap_chance = 0, crossover_chance = 0,
        window_chance = 0, anneal = false, pulse_after = 0, budget = 50, rng = make_rng(3) })
    Bruteforce.next_candidate(st) -- baseline
    Bruteforce.report_result(st, Bruteforce.clone_list(base), 6, true) -- seed beam
    -- no redundant frames -> the sweep goes straight to edge candidates, end-first:
    -- 1) release edge (e=5) moved earlier: A held only on frame 3
    local c1 = Bruteforce.next_candidate(st)
    check('edge sweep: first = release edge 1 frame earlier',
        c1[3].A == true and c1[4].A == false and c1[5].A == false)
    Bruteforce.report_result(st, c1, 6, false, 100)
    -- 2) release edge (e=5) moved later: A held on frames 3-5
    local c2 = Bruteforce.next_candidate(st)
    check('edge sweep: second = release edge 1 frame later',
        c2[3].A == true and c2[4].A == true and c2[5].A == true)
    Bruteforce.report_result(st, c2, 6, false, 100)
    -- 3) press edge (e=3) moved earlier: A held on frames 2-4
    local c3 = Bruteforce.next_candidate(st)
    check('edge sweep: third = press edge 1 frame earlier',
        c3[2].A == true and c3[3].A == true and c3[4].A == true)
    Bruteforce.report_result(st, c3, 6, false, 100)
    -- 4) press edge (e=3) moved later: A held only on frame 4
    local c4 = Bruteforce.next_candidate(st)
    check('edge sweep: fourth = press edge 1 frame later',
        c4[2].A == false and c4[3].A == false and c4[4].A == true)
    Bruteforce.report_result(st, c4, 6, false, 100)
    -- sticks are never touched by an edge shift
    local sticks_kept = true
    for i = 1, 6 do if c1[i].X ~= i * 10 then sticks_kept = false end end
    check('edge sweep: sticks untouched', sticks_kept)
end

-- mid-run checkpoint: suffix-only candidates preserve the best's prefix and carry the tag
do
    local base = {}
    for i = 1, 12 do base[i] = { X = i * 10, Y = 5, A = false } end
    local st = Bruteforce.new({ baseline = base, baseline_frames = 12, max_frames = 12,
        perturb_chance = 1.0, flip_chance = 0.5, remove_chance = 0.5, edge_nudge_chance = 0.5,
        insert_chance = 0.5, rotate_chance = 0.5, snap_chance = 0.5, crossover_chance = 0,
        suffix_prob = 1.0, sweep = false, anneal = false, budget = 200, rng = make_rng(7) })
    Bruteforce.next_candidate(st) -- baseline
    Bruteforce.report_result(st, Bruteforce.clone_list(base), 12, true) -- seed beam
    Bruteforce.set_checkpoint(st, 6)
    local prefix_ok, tagged = true, true
    for _ = 1, 30 do
        local c = Bruteforce.next_candidate(st)
        if c.preserve_prefix ~= 6 then tagged = false end
        for i = 1, 6 do
            if c[i].X ~= i * 10 or c[i].Y ~= 5 or c[i].A ~= false then prefix_ok = false end
        end
        Bruteforce.report_result(st, c, 12, false, 50)
    end
    check('checkpoint: suffix candidates tagged preserve_prefix', tagged)
    check('checkpoint: frames 1..checkpoint bit-identical to the best', prefix_ok)

    -- clearing the checkpoint stops the tagging
    Bruteforce.set_checkpoint(st, nil)
    local c = Bruteforce.next_candidate(st)
    check('checkpoint: cleared -> no tag', c.preserve_prefix == nil)
end

-- checkpoint + sweep: deterministic candidates whose change lies past the checkpoint are tagged too
do
    local base = {
        { X = 10, Y = 0 }, { X = 20, Y = 0 }, { X = 30, Y = 0 }, { X = 40, Y = 0 },
        { X = 0, Y = 0 }, -- neutral frame at index 5 (past a checkpoint at 3)
        { X = 60, Y = 0 },
    }
    local st = Bruteforce.new({ baseline = base, baseline_frames = 6, max_frames = 6,
        perturb_chance = 0, flip_chance = 0, remove_chance = 0, edge_nudge_chance = 0,
        insert_chance = 0, rotate_chance = 0, snap_chance = 0, crossover_chance = 0,
        window_chance = 0, anneal = false, budget = 50, rng = make_rng(4) })
    Bruteforce.next_candidate(st)
    Bruteforce.report_result(st, Bruteforce.clone_list(base), 6, true)
    Bruteforce.set_checkpoint(st, 3)
    local c = Bruteforce.next_candidate(st) -- sweep: removes the neutral frame 5
    check('checkpoint sweep: removal past the checkpoint is tagged', c.preserve_prefix == 3)
    check('checkpoint sweep: it is the expected removal', c[4].X == 40 and c[5].X == 60)
end

-- stagnation escalation: parameters widen level by level while stuck, snap back on improvement
do
    local st = Bruteforce.new({ baseline = make_baseline(30), baseline_frames = 30, max_frames = 30,
        pulse_after = 30, prune_slack = 2, flip_chance = 0.05, remove_chance = 0.15,
        suffix_prob = 0.5, explore_prob = 0.3, anneal = false, rng = make_rng(1) })
    Bruteforce.report_result(st, make_baseline(30), 30, true) -- re-base + seed beam
    Bruteforce.report_result(st, make_baseline(20), 20, true) -- an improvement -> level 0

    check('escalation: level 0 while progressing', Bruteforce._stagnation_level(st) == 0)
    local e0 = Bruteforce.escalation(st)
    check('escalation: level 0 = base params',
        e0.flip_chance == 0.05 and e0.remove_chance == 0.15 and e0.suffix_prob == 0.5 and e0.slack_bonus == 0)
    check('escalation: cutoff = best + slack at level 0', Bruteforce.cutoff(st) == 22)

    for _ = 1, 60 do Bruteforce.report_result(st, make_baseline(25), 25, true) end -- 60 stalls
    check('escalation: level 2 after two periods', Bruteforce._stagnation_level(st) == 2)
    local e2 = Bruteforce.escalation(st)
    check('escalation: flips tripled at level 2', math.abs(e2.flip_chance - 0.15) < 1e-9)
    check('escalation: removals doubled at level 2', math.abs(e2.remove_chance - 0.30) < 1e-9)
    check('escalation: suffix polish fades', math.abs(e2.suffix_prob - 0.5 / 3) < 1e-9)
    check('escalation: explore grows', e2.explore_prob > 0.3)
    check('escalation: prune window widens', Bruteforce.cutoff(st) == 26)
    check('escalation: cutoff still capped by max_frames', Bruteforce.cutoff(st) <= 30)

    Bruteforce.report_result(st, make_baseline(19), 19, true) -- improvement -> everything snaps back
    check('escalation: improvement resets the level', Bruteforce._stagnation_level(st) == 0)
    check('escalation: cutoff back to best + slack', Bruteforce.cutoff(st) == 21)

    -- an explicitly-high base chance is never clamped below itself
    local hi = Bruteforce.new({ baseline = make_baseline(4), baseline_frames = 4,
        remove_chance = 1.0, rng = make_rng(2) })
    check('escalation: explicit chance 1.0 preserved', Bruteforce.escalation(hi).remove_chance == 1.0)
end

-- deterministic press-shift sweep: a whole press moves +-1 frame with its duration kept
do
    -- best: A pressed on frames 3-4 only; sticks distinct
    local base = {}
    for i = 1, 6 do base[i] = { X = i * 10, Y = 0, A = (i == 3 or i == 4) } end
    local st = Bruteforce.new({ baseline = base, baseline_frames = 6, max_frames = 6,
        perturb_chance = 0, flip_chance = 0, remove_chance = 0, edge_nudge_chance = 0,
        insert_chance = 0, rotate_chance = 0, snap_chance = 0, crossover_chance = 0,
        window_chance = 0, anneal = false, pulse_after = 0, budget = 50, rng = make_rng(3) })
    Bruteforce.next_candidate(st) -- baseline
    Bruteforce.report_result(st, Bruteforce.clone_list(base), 6, true) -- seed beam
    -- consume the 4 single-edge candidates first (tested elsewhere)
    for _ = 1, 4 do
        Bruteforce.report_result(st, Bruteforce.next_candidate(st), 6, false, 100)
    end
    -- 5th: whole press shifted 1 frame EARLIER -> A on frames 2-3, duration still 2
    local c5 = Bruteforce.next_candidate(st)
    check('shift sweep: press moved 1 frame earlier, duration kept',
        c5[2].A == true and c5[3].A == true and c5[4].A == false and c5[5].A == false)
    Bruteforce.report_result(st, c5, 6, false, 100)
    -- 6th: whole press shifted 1 frame LATER -> A on frames 4-5, duration still 2
    local c6 = Bruteforce.next_candidate(st)
    check('shift sweep: press moved 1 frame later, duration kept',
        c6[2].A == false and c6[3].A == false and c6[4].A == true and c6[5].A == true)
    Bruteforce.report_result(st, c6, 6, false, 100)
    -- a press starting at frame 1 cannot move earlier; one ending at the last frame cannot move later
    local edge_base = {}
    for i = 1, 4 do edge_base[i] = { X = 10, Y = 0, A = true, B = false } end -- A held 1..4
    local st2 = Bruteforce.new({ baseline = edge_base, baseline_frames = 4, max_frames = 4,
        perturb_chance = 0, flip_chance = 0, remove_chance = 0, edge_nudge_chance = 0,
        insert_chance = 0, rotate_chance = 0, snap_chance = 0, crossover_chance = 0,
        window_chance = 0, anneal = false, pulse_after = 0, budget = 20, rng = make_rng(4) })
    Bruteforce.next_candidate(st2)
    Bruteforce.report_result(st2, Bruteforce.clone_list(edge_base), 4, true)
    -- walk the whole sweep: no candidate may ever press A outside the list or crash
    local n = 0
    while true do
        local c = Bruteforce._next_sweep_candidate(st2)
        if c == nil then break end
        n = n + 1
        Bruteforce.report_result(st2, c, 4, false, 100)
        if n > 50 then break end
    end
    check('shift sweep: full-length press produces a bounded, crash-free sweep', n <= 50)
end

-- estimate_aims: recovers the stick->world rotation from the capture and points at the goal
do
    -- world moves +z when the stick points +x => rotation theta = +pi/2 on every frame
    local inputs, states = {}, {}
    states[0] = { x = 0, z = 0 }
    for i = 1, 6 do
        inputs[i] = { X = 127, Y = 0 }
        states[i] = { x = 0, z = i * 10 }
    end
    -- goal straight +x of Mario: aim angle = atan(0,+dx) - pi/2 = -pi/2 -> stick (0, -1)
    local aims = Bruteforce.estimate_aims(inputs, states, { x = 500, z = 0 })
    check('aims: returns an estimate per frame', aims ~= nil and #aims == 6)
    check('aims: direction compensates the stick->world rotation',
        aims ~= nil and math.abs(aims[1].x) < 0.2 and aims[1].y < -0.8)

    -- deadzone / motionless frames inherit the nearest valid estimate
    local inputs2, states2 = {}, {}
    states2[0] = { x = 0, z = 0 }
    for i = 1, 5 do
        if i == 3 then
            inputs2[i] = { X = 0, Y = 0 } -- deadzone: no theta measurable
            states2[i] = { x = states2[i - 1].x, z = states2[i - 1].z }
        else
            inputs2[i] = { X = 127, Y = 0 }
            states2[i] = { x = states2[i - 1].x, z = states2[i - 1].z + 10 }
        end
    end
    local aims2 = Bruteforce.estimate_aims(inputs2, states2, { x = 500, z = 0 })
    check('aims: gap frames inherit a neighbour estimate', aims2 ~= nil and aims2[3] ~= nil)

    check('aims: nil goal disables the estimator',
        Bruteforce.estimate_aims(inputs, states, nil) == nil)
    check('aims: all-deadzone baseline yields nil',
        Bruteforce.estimate_aims({ { X = 0, Y = 0 } }, { [0] = { x = 0, z = 0 }, { x = 0, z = 0 } },
            { x = 10, z = 10 }) == nil)
end

-- aim operator: perturbed frames snap to full deflection toward the goal
do
    local base = {}
    for i = 1, 5 do base[i] = { X = 20, Y = 90 } end
    local aims = {}
    for i = 1, 5 do aims[i] = { x = 0.6, y = -0.8 } end
    local st = Bruteforce.new({ baseline = base, baseline_frames = 5, max_frames = 5,
        perturb_chance = 0, flip_chance = 0, remove_chance = 0, edge_nudge_chance = 0,
        insert_chance = 0, rotate_chance = 0, snap_chance = 0, crossover_chance = 0,
        hold_chance = 0, window_chance = 0, anneal = false,
        aims = aims, aim_chance = 1.0, rng = make_rng(31) })
    Bruteforce.next_candidate(st) -- baseline
    local c = Bruteforce.next_candidate(st)
    local aimed = true
    for i = 1, 5 do
        if c[i].X ~= 76 or c[i].Y ~= -102 then aimed = false end -- 127*(0.6,-0.8) rounded
    end
    check('aim op: sticks snapped to the goal direction at full deflection', aimed)

    -- without aims the operator is inert (previous rounds' behaviour preserved)
    local st2 = Bruteforce.new({ baseline = base, baseline_frames = 5, max_frames = 5,
        perturb_chance = 0, flip_chance = 0, remove_chance = 0, edge_nudge_chance = 0,
        insert_chance = 0, rotate_chance = 0, snap_chance = 0, crossover_chance = 0,
        hold_chance = 0, window_chance = 0, anneal = false, aim_chance = 1.0, rng = make_rng(31) })
    Bruteforce.next_candidate(st2)
    local c2 = Bruteforce.next_candidate(st2)
    check('aim op: inert without aims', c2[1].X == 20 and c2[1].Y == 90)
end

-- hold operator: smooths a short window into one held stick
do
    local out = {}
    for i = 1, 10 do out[i] = { X = i * 10, Y = -i, A = (i == 4) } end
    local st = Bruteforce.new({ baseline = { { X = 0 } }, baseline_frames = 1,
        hold_chance = 1.0, edit_from = 1, rng = make_rng(6) })
    check('hold: reports smoothing', Bruteforce._apply_hold(st, out) == true)
    local run_len = 0
    for i = 2, 10 do
        if out[i].X == out[i - 1].X and out[i].Y == out[i - 1].Y then run_len = run_len + 1 end
    end
    check('hold: produced a held-stick run', run_len >= 1)
    check('hold: buttons untouched', out[4].A == true)
    local st0 = Bruteforce.new({ baseline = { { X = 0 } }, baseline_frames = 1,
        hold_chance = 0.0, rng = make_rng(6) })
    check('hold: chance 0 -> disabled', Bruteforce._apply_hold(st0, out) == false)
end

-- sweep k=2: after the +-1 entries, whole 2-frame retimings are tried deterministically
do
    -- A pressed on frames 3-4; queue = 4 edge k1, 2 shift k1, (no removals/remove2), then k=2
    local base = {}
    for i = 1, 6 do base[i] = { X = i * 10, Y = 0, A = (i == 3 or i == 4) } end
    local st = Bruteforce.new({ baseline = base, baseline_frames = 6, max_frames = 6,
        perturb_chance = 0, flip_chance = 0, remove_chance = 0, edge_nudge_chance = 0,
        insert_chance = 0, rotate_chance = 0, snap_chance = 0, crossover_chance = 0,
        hold_chance = 0, window_chance = 0, anneal = false, pulse_after = 0,
        budget = 60, rng = make_rng(8) })
    Bruteforce.next_candidate(st) -- baseline
    Bruteforce.report_result(st, Bruteforce.clone_list(base), 6, true)
    for _ = 1, 6 do -- consume the k=1 entries (tested in earlier blocks)
        Bruteforce.report_result(st, Bruteforce.next_candidate(st), 6, false, 100)
    end
    -- first k=2 entry: release edge (e=5) extended 2 frames back -> A erased entirely
    local c7 = Bruteforce.next_candidate(st)
    local any_a = false
    for i = 1, 6 do if c7[i].A then any_a = true end end
    check('sweep k=2: first entry erases the press (release edge pulled 2 back)', any_a == false)
end

-- remove2 sweep: an adjacent pair around a redundant frame is dropped in one candidate
do
    local base = {
        { X = 10, Y = 0 }, { X = 20, Y = 0 }, { X = 30, Y = 0 },
        { X = 0, Y = 0 }, -- redundant neutral frame (index 4)
        { X = 50, Y = 0 }, { X = 60, Y = 0 },
    }
    local st = Bruteforce.new({ baseline = base, baseline_frames = 6, max_frames = 6,
        perturb_chance = 0, flip_chance = 0, remove_chance = 0, edge_nudge_chance = 0,
        insert_chance = 0, rotate_chance = 0, snap_chance = 0, crossover_chance = 0,
        hold_chance = 0, window_chance = 0, anneal = false, pulse_after = 0,
        budget = 60, rng = make_rng(9) })
    Bruteforce.next_candidate(st)
    Bruteforce.report_result(st, Bruteforce.clone_list(base), 6, true)
    Bruteforce.report_result(st, Bruteforce.next_candidate(st), 6, false, 100) -- single removal of 4
    -- next: remove2 pair (3,4) -> 10,20,50,60 then pads
    local c = Bruteforce.next_candidate(st)
    check('remove2: drops the redundant frame with its neighbour',
        c[1].X == 10 and c[2].X == 20 and c[3].X == 50 and c[4].X == 60)
end

-- escalation exposes the widened rotation + summary exposes the shake level
do
    local st = Bruteforce.new({ baseline = make_baseline(10), baseline_frames = 10,
        pulse_after = 30, rotate_max_rad = 0.25, anneal = false, rng = make_rng(1) })
    Bruteforce.report_result(st, make_baseline(10), 10, true)
    check('summary: shake 0 while progressing', Bruteforce.summary(st).shake == 0)
    for _ = 1, 30 do Bruteforce.report_result(st, make_baseline(12), 12, true) end
    check('summary: shake 1 after one stagnation period', Bruteforce.summary(st).shake == 1)
    check('escalation: rotation widens with the level',
        Bruteforce.escalation(st).rotate_max_rad > 0.25)
end

-- checkpoint ladder: suffix candidates use one of the rungs, sweeps tag the deepest usable rung
do
    local base = {}
    for i = 1, 16 do base[i] = { X = i * 5, Y = 3, A = false } end
    local st = Bruteforce.new({ baseline = base, baseline_frames = 16, max_frames = 16,
        perturb_chance = 1.0, flip_chance = 0, remove_chance = 0, edge_nudge_chance = 0,
        insert_chance = 0, rotate_chance = 0, snap_chance = 0, crossover_chance = 0,
        hold_chance = 0, window_chance = 0, anneal = false, suffix_prob = 1.0,
        sweep = false, budget = 300, rng = make_rng(13) })
    Bruteforce.next_candidate(st) -- baseline
    Bruteforce.report_result(st, Bruteforce.clone_list(base), 16, true) -- seed beam
    Bruteforce.set_checkpoints(st, { 8, 12 })
    check('ladder: deepest rung mirrored in checkpoint_frame', st.checkpoint_frame == 8)

    local used_8, used_12, prefix_ok = false, false, true
    for _ = 1, 40 do
        local c = Bruteforce.next_candidate(st)
        if c.preserve_prefix == 8 then used_8 = true end
        if c.preserve_prefix == 12 then used_12 = true end
        local rung = c.preserve_prefix or 0
        for i = 1, rung do
            if c[i].X ~= i * 5 or c[i].Y ~= 3 then prefix_ok = false end
        end
        Bruteforce.report_result(st, c, 16, false, 50)
    end
    check('ladder: both rungs get used', used_8 and used_12)
    check('ladder: the tagged prefix is bit-identical to the best', prefix_ok)

    -- clearing the ladder stops the tagging
    Bruteforce.set_checkpoints(st, nil)
    check('ladder: cleared -> no deepest rung', st.checkpoint_frame == nil)
    check('ladder: cleared -> untagged candidates', Bruteforce.next_candidate(st).preserve_prefix == nil)
end

-- checkpoint ladder + sweep: the deterministic candidate picks the DEEPEST rung below its change
do
    local base = {
        { X = 10, Y = 0 }, { X = 20, Y = 0 }, { X = 30, Y = 0 }, { X = 40, Y = 0 },
        { X = 50, Y = 0 }, { X = 60, Y = 0 }, { X = 70, Y = 0 },
        { X = 0, Y = 0 }, -- redundant neutral frame at index 8 (past both rungs)
        { X = 90, Y = 0 }, { X = 100, Y = 0 },
    }
    local st = Bruteforce.new({ baseline = base, baseline_frames = 10, max_frames = 10,
        perturb_chance = 0, flip_chance = 0, remove_chance = 0, edge_nudge_chance = 0,
        insert_chance = 0, rotate_chance = 0, snap_chance = 0, crossover_chance = 0,
        hold_chance = 0, window_chance = 0, anneal = false, pulse_after = 0,
        budget = 50, rng = make_rng(14) })
    Bruteforce.next_candidate(st)
    Bruteforce.report_result(st, Bruteforce.clone_list(base), 10, true)
    Bruteforce.set_checkpoints(st, { 5, 7 })
    local c = Bruteforce.next_candidate(st) -- sweep: removes the neutral frame 8
    check('ladder sweep: tagged with the deepest rung below the change', c.preserve_prefix == 7)
end

-- a faster-arriving same-frame solution now counts as an IMPROVEMENT (resets stagnation, re-anchors
-- the deterministic sweeps on the new best)
do
    local base = {
        { X = 10, Y = 0 }, { X = 20, Y = 0 }, { X = 30, Y = 0 },
        { X = 0, Y = 0 }, -- neutral frame (sweep target)
        { X = 50, Y = 0 }, { X = 60, Y = 0 },
    }
    local st = Bruteforce.new({ baseline = base, baseline_frames = 6, max_frames = 6,
        perturb_chance = 0, flip_chance = 0, remove_chance = 0, edge_nudge_chance = 0,
        insert_chance = 0, rotate_chance = 0, snap_chance = 0, crossover_chance = 0,
        hold_chance = 0, window_chance = 0, anneal = false, pulse_after = 30,
        budget = 100, rng = make_rng(17) })
    Bruteforce.next_candidate(st) -- baseline
    Bruteforce.report_result(st, Bruteforce.clone_list(base), 6, true, nil,
        { action = 1, x = 0, z = 0, hspeed = 10 })
    Bruteforce.report_result(st, Bruteforce.clone_list(base), 6, false, 100) -- some stagnation
    check('speed-improvement: stagnation accumulated', st.stagnation == 1)

    local tie = Bruteforce.clone_list(base)
    for i = 1, 6 do tie[i].X = tie[i].X + 1 end -- distinguishable same-frame solution
    tie[4].X = 0                                -- keep the neutral frame neutral
    local improved = Bruteforce.report_result(st, tie, 6, true, nil,
        { action = 1, x = 0, z = 0, hspeed = 50 })
    check('speed-improvement: same frames + faster arrival counts as improvement', improved == true)
    check('speed-improvement: stagnation reset', st.stagnation == 0)
    check('speed-improvement: the faster solution is the best', st.best_list[1].X == 11)

    -- the deterministic sweep re-anchors on the NEW best (drops its neutral frame)
    local c = Bruteforce.next_candidate(st)
    check('speed-improvement: sweep rebuilt from the new best',
        c[1].X == 11 and c[2].X == 21 and c[4].X == 51)

    -- a SLOWER same-frame solution is not an improvement
    local slow = Bruteforce.clone_list(base)
    for i = 1, 6 do slow[i].X = slow[i].X + 2 end
    check('speed-improvement: slower same-frame arrival is not an improvement',
        Bruteforce.report_result(st, slow, 6, true, nil, { action = 1, x = 0, z = 0, hspeed = 5 }) == false)
end

-- auto-stop: convergence, overtime on a hot streak, and the hard cap
do
    -- convergence: a long zero-improvement streak ends the search early
    local st = Bruteforce.new({ baseline = make_baseline(10), baseline_frames = 10,
        budget = 100000, convergence_after = 5, pulse_after = 30, anneal = false, rng = make_rng(18) })
    Bruteforce.report_result(st, make_baseline(10), 10, true)
    check('convergence: not done while fresh', Bruteforce.done(st) == false)
    for _ = 1, 5 do Bruteforce.report_result(st, make_baseline(10), 10, false, 50) end
    check('convergence: done after the streak', Bruteforce.done(st) == true)
    check('convergence: no candidate handed out', Bruteforce.next_candidate(st) == nil)
    check('convergence: summary flags it', Bruteforce.summary(st).converged == true)

    -- overtime: the budget is spent but a recent improvement keeps the search alive
    local st2 = Bruteforce.new({ baseline = make_baseline(10), baseline_frames = 10,
        budget = 5, overtime_grace = 3, convergence_after = 100, hard_cap = 20,
        pulse_after = 30, anneal = false, rng = make_rng(19) })
    Bruteforce.report_result(st2, make_baseline(10), 10, true)  -- reference
    Bruteforce.report_result(st2, make_baseline(9), 9, true)    -- improvement
    Bruteforce.report_result(st2, make_baseline(8), 8, true)    -- improvement
    Bruteforce.report_result(st2, make_baseline(20), 20, false, 50)
    Bruteforce.report_result(st2, make_baseline(20), 20, false, 50)
    check('overtime: budget spent but hot streak -> keeps going',
        st2.tried >= st2.budget and Bruteforce.done(st2) == false)
    Bruteforce.report_result(st2, make_baseline(20), 20, false, 50)
    check('overtime: streak cooled -> done', Bruteforce.done(st2) == true)
    check('overtime: not flagged as converged', Bruteforce.summary(st2).converged == false)

    -- hard cap: an absolute ceiling even while improving
    local st3 = Bruteforce.new({ baseline = make_baseline(10), baseline_frames = 10,
        budget = 2, hard_cap = 4, overtime_grace = 100, convergence_after = 1000,
        pulse_after = 30, anneal = false, rng = make_rng(20) })
    Bruteforce.report_result(st3, make_baseline(10), 10, true)
    Bruteforce.report_result(st3, make_baseline(9), 9, true)
    Bruteforce.report_result(st3, make_baseline(8), 8, true)
    Bruteforce.report_result(st3, make_baseline(7), 7, true)
    check('hard cap: stops even on a hot streak', Bruteforce.done(st3) == true)
end

-- improvement heatmap: winning windows heat up, and hot frames attract future local windows
do
    local st = Bruteforce.new({ baseline = make_baseline(20), baseline_frames = 20, max_frames = 20,
        window_chance = 1.0, window_frac = 0.25, window_min = 2, heat_bias = 1.0,
        pulse_after = 30, anneal = false, budget = 100, rng = make_rng(23) })
    Bruteforce.report_result(st, make_baseline(20), 20, true) -- re-base + seed beam

    -- an improving candidate that mutated frames 10..12 credits exactly those frames
    st._last_wlo, st._last_whi = 10, 12
    Bruteforce.report_result(st, make_baseline(18), 18, true)
    check('heat: winning window credited', (st.heat[10] or 0) > 0 and (st.heat[11] or 0) > 0)
    check('heat: frames outside the window untouched', st.heat[9] == nil and st.heat[13] == nil)

    -- a non-improving candidate credits nothing
    st._last_wlo, st._last_whi = 1, 3
    Bruteforce.report_result(st, make_baseline(19), 19, true) -- worse than best (18): no credit
    check('heat: losing window not credited', st.heat[1] == nil)

    -- pick_window now gravitates toward the hot zone
    st.heat = { [10] = 50 } -- one overwhelmingly hot frame
    local hits, tries = 0, 30
    for _ = 1, tries do
        local wlo, whi = Bruteforce._pick_window(st, 1, 20)
        if wlo <= 10 and whi >= 10 then hits = hits + 1 end
    end
    check('heat: local windows concentrate on the hot frame', hits >= tries * 0.8)

    -- heat credit only lands on the reported candidate's own window: a sweep candidate (which
    -- mutates no window) leaves the tracker cleared, so a stale window can never be credited
    st._last_wlo, st._last_whi = 5, 6
    local c = Bruteforce.next_candidate(st) -- best is all-duplicates: this is a sweep removal
    check('heat: sweep candidate clears the stale window tracker',
        c ~= nil and st._last_wlo == nil)
end

-- gain is ZEROED when the baseline never reached the goal (prevents applying a spurious result to
-- an already-optimal sheet — the pipeline-breaks-a-sheet bug)
do
    -- baseline (first candidate) does NOT reach: reference stays stale, beam empty
    local st = Bruteforce.new({ baseline = make_baseline(20), baseline_frames = 20, max_frames = 20,
        budget = 100, rng = make_rng(41) })
    Bruteforce.next_candidate(st)                       -- baseline
    Bruteforce.report_result(st, make_baseline(20), 20, false, 200) -- baseline did NOT reach
    check('no-ref: baseline_reached is false', st.baseline_reached == false)
    check('no-ref: baseline_frames stays at the stale capture value', st.baseline_frames == 20)

    -- a later candidate DOES reach in fewer frames -> best_frames drops, raw diff would be > 0
    Bruteforce.report_result(st, make_baseline(14), 14, true, nil, { action = 1, x = 0, z = 0, hspeed = 5 })
    check('no-ref: best_frames reflects the reaching candidate', st.best_frames == 14)
    check('no-ref: summary gain is FORCED to 0 (no valid reference)', Bruteforce.summary(st).gain == 0)

    -- and once a reaching candidate exists, further reaches still never fabricate a gain
    Bruteforce.report_result(st, make_baseline(12), 12, true, nil, { action = 1, x = 0, z = 0, hspeed = 5 })
    check('no-ref: still no fake gain after more reaches', Bruteforce.summary(st).gain == 0)
end

-- gain works normally when the baseline DID reach (valid reference)
do
    local st = Bruteforce.new({ baseline = make_baseline(20), baseline_frames = 20, max_frames = 20,
        budget = 100, rng = make_rng(42) })
    Bruteforce.next_candidate(st)
    Bruteforce.report_result(st, make_baseline(18), 18, true) -- baseline reaches, re-bases to 18
    check('ref: baseline_reached true', st.baseline_reached == true)
    check('ref: gain 0 right after re-basing', Bruteforce.summary(st).gain == 0)
    Bruteforce.report_result(st, make_baseline(15), 15, true)
    check('ref: real improvement produces a real gain', Bruteforce.summary(st).gain == 3)
end

-- synthetic / legacy core (no baseline_reached field) still reports its gain (chunk-mode compat)
do
    local synthetic = { baseline_frames = 30, best_frames = 24, beam = {}, tried = 0,
        budget = 2000, improvements = 0, stagnation = 0, archive_count = 0,
        convergence_after = 500, pulse_after = 30 }
    check('legacy core: nil baseline_reached treated as valid -> gain reported',
        Bruteforce.summary(synthetic).gain == 6)
end

-- angle_diff: shortest u16 angular distance with wraparound
do
    check('angle_diff: zero', Bruteforce.angle_diff(1000, 1000) == 0)
    check('angle_diff: simple', Bruteforce.angle_diff(1000, 1100) == 100)
    check('angle_diff: wraps the short way', Bruteforce.angle_diff(10, 65530) == 16)
    check('angle_diff: half circle is the max', Bruteforce.angle_diff(0, 32768) == 32768)
    check('angle_diff: symmetric', Bruteforce.angle_diff(60000, 100) == Bruteforce.angle_diff(100, 60000))
end

-- state_matches_goal: the chain-safe acceptance criterion (action + position + speed + angle)
do
    local goal = { action = 5, x = 100, y = 0, z = 200, h_speed = 30, yaw = 16384 }
    local exact = { action = 5, x = 100, y = 0, z = 200, h_speed = 30, yaw = 16384 }
    check('match: exact state accepted', Bruteforce.state_matches_goal(exact, goal, 50, 1.0, 256) == true)

    check('match: wrong action rejected',
        Bruteforce.state_matches_goal({ action = 6, x = 100, y = 0, z = 200, h_speed = 30, yaw = 16384 },
            goal, 50, 1.0, 256) == false)
    check('match: position within radius accepted',
        Bruteforce.state_matches_goal({ action = 5, x = 130, y = 0, z = 210, h_speed = 30, yaw = 16384 },
            goal, 50, 1.0, 256) == true) -- dist ~31.6 < 50
    check('match: position outside radius rejected',
        Bruteforce.state_matches_goal({ action = 5, x = 200, y = 0, z = 200, h_speed = 30, yaw = 16384 },
            goal, 50, 1.0, 256) == false)

    -- speed: the chain-breaker the user hit — same spot, different speed -> rejected
    check('match: speed within tol accepted',
        Bruteforce.state_matches_goal({ action = 5, x = 100, y = 0, z = 200, h_speed = 30.5, yaw = 16384 },
            goal, 50, 1.0, 256) == true)
    check('match: speed outside tol rejected (would desync the next sheet)',
        Bruteforce.state_matches_goal({ action = 5, x = 100, y = 0, z = 200, h_speed = 45, yaw = 16384 },
            goal, 50, 1.0, 256) == false)

    -- facing angle: same spot & speed but turned the wrong way -> rejected
    check('match: angle within tol accepted',
        Bruteforce.state_matches_goal({ action = 5, x = 100, y = 0, z = 200, h_speed = 30, yaw = 16384 + 100 },
            goal, 50, 1.0, 256) == true)
    check('match: angle outside tol rejected',
        Bruteforce.state_matches_goal({ action = 5, x = 100, y = 0, z = 200, h_speed = 30, yaw = 16384 + 4000 },
            goal, 50, 1.0, 256) == false)

    -- backward compatible: nil tolerances / nil goal fields skip those checks (legacy position goal)
    local pos_goal = { action = 5, x = 100, y = 0, z = 200 }
    check('match: nil speed/angle tol -> position-only goal still works',
        Bruteforce.state_matches_goal({ action = 5, x = 105, y = 0, z = 200, h_speed = 999, yaw = 0 },
            pos_goal, 50, nil, nil) == true)
    check('match: action-only goal (no position) accepts any position',
        Bruteforce.state_matches_goal({ action = 5, x = 9999, y = 0, z = 9999 },
            { action = 5 }, nil, nil, nil) == true)
end

print(string.format('bruteforce_test: %d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
