--
-- Copyright (c) 2025, Mupen64 maintainers.
--
-- SPDX-License-Identifier: GPL-2.0-or-later
--

--
-- Bruteforce view + driver.
--
-- The DRIVER (BruteforceDriver) is an emulator-facing state machine that runs a search inside
-- mupen: it loads a start savestate, replays candidate inputs frame-by-frame, detects the
-- semantic goal (Mario reaching a target action) and reports frame counts back to the pure core
-- (core/Bruteforce.lua). It reuses only the proven primitives already used by the Semantic
-- Workflow (savestate.do_memory, emu.pause/set_speed_mode, Memory.current, joypad override),
-- so its behaviour mirrors code that is known to work.
--
-- The VIEW is a standard top-level tab ({name, draw}) that configures and controls the driver.
--
-- Coupling to the semantic layer: the goal is a target Mario action (end_action), the same notion
-- the Semantic Workflow uses. "Fewer frames" means reaching that action sooner.
--
-- NOTE: the driver's emulator interactions cannot be unit-tested off-mupen. The pure search logic
-- it delegates to is fully tested (tests/bruteforce_test.lua). See BRUTEFORCE_DESIGN.md for the
-- manual test plan.
--

local UID = UIDProvider.allocate_once('Bruteforce', function(enum_next)
    return {
        SetStart = enum_next(),
        SetGoal = enum_next(),
        -- spinners reserve extra uid slots for their internal textbox (see Tools.lua RngValue)
        GoalRadius = enum_next(4),
        GoalRadiusLabel = enum_next(),
        Chunks = enum_next(4),
        ChunksLabel = enum_next(),
        Budget = enum_next(4),
        StartStop = enum_next(),
        ApplyBest = enum_next(),
        ExportM64 = enum_next(),
        StartStatus = enum_next(),
        GoalStatus = enum_next(),
        BudgetLabel = enum_next(),
        StatusPhase = enum_next(),
        StatusSummary = enum_next(),
        StatusTried = enum_next(),
        StatusError = enum_next(),
        StatusDiag2 = enum_next(),
    }
end)

-- How many frames to allow when measuring the baseline before giving up (safety net when the
-- target action is never reached, e.g. because the movie is not replaying the action).
local CAPTURE_SAFETY_CAP = 1200

-- Chain-safety acceptance tolerances (AUTOMATIC — no user knob; the magic button handles chaining
-- itself). An applied optimization must leave Mario in ~a usable state (speed + facing angle), not
-- just the same spot, or the next sheet desyncs.
--
-- The speed bound is ASYMMETRIC on purpose. Arriving at the goal FASTER than the baseline is what a
-- real frame-saving looks like in SM64 (a tightened line keeps more speed) — it is a better handoff,
-- not a desync risk. The original symmetric ±1.0 rejected exactly those candidates, so only trivial
-- dead-frame removals survived and searches converged on a ~1-frame gain while reporting "optimal".
-- Arriving SLOWER stays tightly bounded: that IS the case that broke downstream sheets.
local CHAIN_SPEED_TOL = 1.0    -- how much SLOWER than the baseline is still accepted
local CHAIN_SPEED_TOL_UP = 8.0 -- how much FASTER is accepted; bounded so a wildly different route
                               -- (glitch/skip rather than a tightened line) is still refused
-- Facing angle: the downstream sheet is semantic — it re-aims every frame through the TAS engine, so
-- it absorbs a few degrees at the handoff. 1.4° was tight enough to reject genuine improvements for
-- no chaining benefit. NOTE: a downstream sheet already REWRITTEN by a previous apply is frame-exact
-- and less forgiving; if a chain ever desyncs after this change, this is the first knob to re-tighten.
local CHAIN_ANGLE_TOL = 1024 -- u16 angle units (~5.6 degrees)

-- Unchained tolerances. `chain_locked` changes HOW TIGHT the end state must match — never WHETHER it
-- is matched at all. Dropping the speed/angle checks entirely (tried, reverted) let the goal fire
-- while Mario was merely PASSING within goal_radius of the target instead of actually finishing the
-- action: the reported gain was partly the slack of the radius, and applying it truncated the sheet a
-- few frames early, so Mario no longer performed the action ("comme si c'était coupé"). The end state
-- matters even with nothing chained behind it, because the USER continues from there.
-- Fallback when the goal radius is automatic but the capture has no usable position data.
local DEFAULT_GOAL_RADIUS = 30

local CHAIN_SPEED_TOL_FREE = 4.0 -- how much slower than the goal is accepted when unchained
-- How much FASTER an unchained arrival may be. Measured, not guessed: on a real segment the search
-- was refusing 632 runs that stood exactly on the goal (closest_miss 0), in the goal action, two
-- frames early — every one of them on the fast side, by up to +38 against the old bound of 24. They
-- were genuine faster arrivals, not fly-throughs, and arriving earlier WITH more speed is a better
-- handoff for whatever the user writes next, so refusing them cost the gain outright. Still bounded:
-- a delta far beyond what the segment can physically produce means a different route or a glitch, not
-- a tightened line. If an applied result ever ends short of the goal again (watch `ends from goal:`),
-- this is the number to bring back down.
local CHAIN_SPEED_TOL_UP_FREE = 64.0
local CHAIN_ANGLE_TOL_FREE = 4096    -- ~22 degrees

-- Whether any OTHER sheet in the project chains (directly or transitively) off `sheet`. This decides
-- whether chain-safety is needed at all: in the user's workflow a sheet is bruteforced BEFORE the next
-- one is written, so there is usually nothing downstream to desync — and then constraining the end
-- speed/angle only throws away real gains. When a dependent does exist (re-optimizing an earlier
-- sheet), the tolerances come back automatically. No user knob: the button decides for itself.
-- The traversal itself is pure and lives (tested) in the core.
---@param sheet Sheet|nil
---@return boolean
local function sheet_has_dependents(sheet)
    if SemanticWorkflowProject == nil then return false end
    return Bruteforce.has_dependents(SemanticWorkflowProject.all, sheet)
end

---@return integer speed_mode
local function playback_speed_mode()
    return Settings.bruteforce.fast_forward and Mupen.CoreSpeedMode.UltraFastForward or Mupen.CoreSpeedMode.Normal
end

-- Emulator run/halt, mirroring the Semantic Workflow's proven usage exactly.
local function emu_run()
    emu.pause(true)
    emu.set_speed_mode(playback_speed_mode())
end

local function emu_halt()
    emu.pause(false)
    emu.set_speed_mode(Mupen.CoreSpeedMode.Normal)
end

-- Ensures Settings.bruteforce and all its fields exist. Presets.apply() swaps the whole Settings
-- table for a saved preset, which (if saved before this feature existed) may lack these fields;
-- this guard makes the view robust to that instead of indexing a nil table.
local function ensure_settings()
    local b = Settings.bruteforce
    if type(b) ~= 'table' then
        b = {}
        Settings.bruteforce = b
    end
    if b.budget == nil then b.budget = 2000 end
    if b.fast_forward == nil then b.fast_forward = true end
    if b.goal_radius == nil then b.goal_radius = 0 end -- 0 = derive it from Mario's motion
    if b.chunks == nil then b.chunks = 1 end
end

--#region Driver

---@class BruteforceDriver
BruteforceDriver = {
    -- 'idle' | 'capture' | 'run' | 'load' | 'done'
    phase = 'idle',
    active = false,
    ---@type any A mupen in-memory savestate (ByteBuffer) captured at the start of the segment.
    start_state = nil,
    ---@type integer|nil The Mario action that marks the goal.
    target_action = nil,
    ---@type table|nil The pure search core state.
    core = nil,
    ---@type table[]|nil The candidate input list currently being replayed.
    candidate = nil,
    frame_idx = 0,
    candidate_min_dist2 = math.huge, -- closest squared distance to the goal during the current run
    ---@type any The savestate the current search loads from (start_state, or a chunk's start).
    search_state = nil,
    -- Mid-run checkpoint LADDER: savestates of the CURRENT best run taken at 1/2 and 3/4 of its
    -- length. Candidates the core tags `preserve_prefix` (identical to the best up to that frame)
    -- are replayed from the matching rung instead of the segment start — half the emulator work at
    -- the 1/2 rung, a quarter at the 3/4 rung. Rebuilt lazily after every improvement (ck_pending),
    -- invalidated the moment the best changes.
    ---@type { frame: integer, state: any, min_dist2: number }[]|nil
    checkpoints = nil,
    ck_pending = false,
    -- checkpoint-build bookkeeping (targets built in sequence, each segment chained from the
    -- previous rung's savestate so the replay never straddles an async save)
    ck_targets = nil,
    ck_index = 1,
    ck_new = nil,
    ck_base_frame = 0,
    ck_base_state = nil,
    ck_min_dist2 = math.huge,
    ---Whether the run in progress started from a checkpoint rung (so its measurement is only a
    ---filter and must be confirmed by a full replay before being reported).
    from_checkpoint = false,
    ck_runs = 0,    -- filtered runs attempted, and how many of them looked like they reached:
    ck_reaches = 0, -- all-fail over a large sample means the rungs are misaligned, not the candidates
    ck_broken = false,
    ---@type table[]|nil The optimised chunk being replayed during the chain phase.
    chain_inputs = nil,
    chain_idx = 0,
    ---@type table[]|nil Accumulated optimised inputs across chunks (the final result).
    chunk_result = nil,
    ---@type table|nil The real final goal { action, x, y, z }, restored for end-to-end verification.
    final_goal = nil,
    verify_idx = 0,
    ---@type table[]|nil Accumulator used while measuring the baseline.
    capture_list = nil,
    status = 'BRUTEFORCE_STATUS_IDLE',
    ---@type string|nil A localisation key for the current error, if any.
    error = nil,
    ---@type Sheet|nil When set, the search was launched for a Semantic Workflow sheet: the baseline is
    ---captured by replaying that sheet, and "Apply" rewrites the sheet's sections with the optimized
    ---frame-exact inputs (instead of dumping files). Kept after done/stop so Apply can use it.
    driving_sheet = nil,
    ---Whether something downstream depends on this segment's exact end state, so the search must
    ---preserve it (speed + facing angle) to stay chain-safe. Decided automatically when the search
    ---starts: false only for a sheet with no dependents (the usual "bruteforce, then write the next
    ---sheet" flow), where preserving the end state protects nothing and only rejects real gains.
    ---Manual/movie searches stay locked — the rest of the movie IS downstream.
    chain_locked = true,
    ---Whether the CURRENT best has been replayed from the true start and confirmed to still reach the
    ---goal. Nothing may be applied or exported until this is true (see apply_to_sheet): an
    ---unverified result can replay to a different end state and corrupt the sheet.
    verified = false,
}

---Captures the current game state as the segment start. Callable from a UI callback.
function BruteforceDriver.set_start()
    savestate.do_memory('', 'save', function(_, data)
        BruteforceDriver.start_state = data
    end)
    -- Remember the current movie frame so the export can splice the optimised segment back into
    -- the real movie at the right place (keeping the movie's exact format so it still plays).
    local completion = movie and movie.get_seek_completion and movie.get_seek_completion()
    BruteforceDriver.start_frame = completion and completion[1] or nil
    BruteforceDriver.driving_sheet = nil -- manual start: not tied to a Semantic Workflow sheet
    -- Lock the end state only if a movie is actually loaded: then everything after the segment IS
    -- downstream of it and would desync. Set start/goal by hand with no movie (optimizing an action
    -- in isolation) has nothing downstream, exactly like a sheet with no dependents — so the search
    -- gets the same freedom instead of being pointlessly constrained.
    BruteforceDriver.chain_locked = BruteforceDriver.start_frame ~= nil
    BruteforceDriver.error = nil
end

---Sets the goal to Mario's current action AND position. Requiring the position makes the goal
---precise: a candidate must reach the same action near the same spot, not merely the same action
---somewhere else (many actions like WALKING are ambiguous on their own).
function BruteforceDriver.set_goal_from_current()
    BruteforceDriver.target_action = Memory.current.mario_action
    BruteforceDriver.target_x = Memory.current.mario_x
    BruteforceDriver.target_y = Memory.current.mario_y
    BruteforceDriver.target_z = Memory.current.mario_z
    -- Also capture speed + facing angle: matching these makes an optimization CHAIN-SAFE (it must
    -- leave Mario in the same state, not just the same spot, or downstream sheets desync).
    BruteforceDriver.target_h_speed = Memory.current.mario_h_speed
    BruteforceDriver.target_yaw = Memory.current.mario_facing_yaw
    BruteforceDriver.error = nil
end

---Whether the driver is ready to begin (start state + goal defined).
---@return boolean
function BruteforceDriver.can_start()
    return BruteforceDriver.start_state ~= nil and BruteforceDriver.target_action ~= nil
end

---Begins a search. Callable from a UI callback (same context as the Semantic Workflow's run).
function BruteforceDriver.start()
    if BruteforceDriver.active then return end
    ensure_settings()
    if not BruteforceDriver.can_start() then
        BruteforceDriver.error = 'BRUTEFORCE_ERROR_NOT_READY'
        return
    end
    BruteforceDriver.active = true
    BruteforceDriver.error = nil
    BruteforceDriver.core = nil
    BruteforceDriver.candidate = nil
    BruteforceDriver.capture_list = {}
    BruteforceDriver.capture_states = {} -- per-frame Mario state, for chunk-boundary checkpoints
    BruteforceDriver.chunks = nil
    BruteforceDriver.chunk_index = nil
    BruteforceDriver.chunk_result = nil
    BruteforceDriver.checkpoints = nil
    BruteforceDriver.ck_targets = nil
    BruteforceDriver.ck_pending = false
    BruteforceDriver.aims = nil
    BruteforceDriver.frame_idx = 0
    BruteforceDriver.phase = 'capture'
    BruteforceDriver.verified = false -- a fresh search has nothing verified yet
    BruteforceDriver.end_distance = nil
    BruteforceDriver.goal_radius = nil -- resolved at the end of the capture
    BruteforceDriver.from_checkpoint = false
    BruteforceDriver.ck_runs = 0
    BruteforceDriver.ck_reaches = 0
    BruteforceDriver.ck_broken = false
    BruteforceDriver.blocked_at = nil
    BruteforceDriver.blocked_count = 0
    BruteforceDriver.blocked_best = nil
    BruteforceDriver.blocked_speed = 0
    BruteforceDriver.blocked_angle = 0
    BruteforceDriver.blocked_slow = 0
    BruteforceDriver.blocked_fast = 0
    BruteforceDriver.blocked_dslow = nil
    BruteforceDriver.blocked_dfast = nil
    BruteforceDriver.status = 'BRUTEFORCE_STATUS_CAPTURING'
    -- Load the start state and let the game run; the baseline is recorded by observing the
    -- ambient inputs (movie / semantic sheet / manual) until the goal action is reached.
    savestate.do_memory(BruteforceDriver.start_state, 'load', function()
        BruteforceDriver.frame_idx = 0
        emu_run()
    end)
end

---Launches a search for a Semantic Workflow sheet. The sheet must have already run to its end (Mario
---is standing at the goal): start = the sheet's start savestate, goal = Mario's current action+position.
---The baseline is then captured by replaying the sheet from its start (the semantic playback drives the
---capture phase; it is suppressed during the search — see CurrentSemanticWorkflowOverride).
---@param sheet Sheet
function BruteforceDriver.start_for_sheet(sheet)
    if BruteforceDriver.active then return end
    ensure_settings()
    if sheet == nil or sheet._savestate == nil then
        BruteforceDriver.error = 'BRUTEFORCE_ERROR_SHEET_NOT_READY'
        return
    end
    -- goal = the sheet's end, where Mario is right now (state matched for chain safety, see below)
    BruteforceDriver.target_action = Memory.current.mario_action
    BruteforceDriver.target_x = Memory.current.mario_x
    BruteforceDriver.target_y = Memory.current.mario_y
    BruteforceDriver.target_z = Memory.current.mario_z
    BruteforceDriver.target_h_speed = Memory.current.mario_h_speed
    BruteforceDriver.target_yaw = Memory.current.mario_facing_yaw
    BruteforceDriver.start_state = sheet._savestate
    BruteforceDriver.start_frame = nil          -- sheet results are applied to the sheet, not spliced into a movie
    BruteforceDriver.driving_sheet = sheet
    -- Only preserve the end state if a later sheet actually chains off this one. Bruteforcing a sheet
    -- before writing the next one (the normal flow) has nothing downstream to protect, so the search
    -- is free to end faster / facing differently — which is where the real frame savings live.
    BruteforceDriver.chain_locked = sheet_has_dependents(sheet)
    -- Make sure the sheet is the one that drives the capture, replaying from its start with no chaining.
    -- busy = true so that when the sheet reaches its preview (flips busy to false) we can detect the
    -- end of the segment; reset_playback rewinds it so it plays from the start during capture.
    SemanticWorkflowProject.current = sheet
    sheet:reset_playback()
    sheet._on_preview_input_reached = nil
    sheet.busy = true
    BruteforceDriver.start()
end

-- Chunk-mode orchestration is mutually recursive, so forward-declare the pieces. Declared up here
-- because stop() also needs to hand a stopped-but-improved search to the verification pass.
local advance_to_next_candidate
local start_chunk
local finish_chunk
local finalize_chunks
local finalize_verified
local finish_single_search

---Applies the finished search result to the sheet it was launched for: converts the best raw frames
---to frame-exact manual SectionInputs and writes them INTO the sheet (replacing its sections). The
---optimization becomes the sheet's real content — editable, persisted on save, and chained normally.
---@return boolean ok
---@return string message_key
function BruteforceDriver.apply_to_sheet()
    local sheet = BruteforceDriver.driving_sheet
    if sheet == nil or BruteforceDriver.core == nil then
        return false, 'BRUTEFORCE_ERROR_NO_RESULT'
    end
    -- SAFETY INVARIANT: a result may only reach a sheet once it has been replayed from the true start
    -- and confirmed to still reach the goal. Without this, stopping a search by hand (which skips the
    -- verification a natural completion runs) would let an unreproducible result be written to the
    -- sheet — it replays to a DIFFERENT end state and silently corrupts the TAS.
    if not BruteforceDriver.verified then
        return false, 'BRUTEFORCE_ERROR_NOT_VERIFIED'
    end
    local summary = Bruteforce.summary(BruteforceDriver.core)
    if summary.gain <= 0 then
        return false, 'BRUTEFORCE_ERROR_NO_GAIN'
    end
    local inputs = Bruteforce.to_overrides(
        BruteforceDriver.core.best_list, summary.best_frames, NewTASState, MovementModes.manual)
    sheet:apply_optimized_inputs(inputs)
    return true, 'BRUTEFORCE_STATUS_SHEET_APPLIED'
end

---Stops the search and restores normal emulation. Safe to call at any time.
function BruteforceDriver.stop()
    -- Stopping a search that already found a real gain must not throw that gain away, but it must not
    -- hand over an UNVERIFIED result either. So finish properly: run the same end-to-end verification
    -- a natural completion runs, after which the result is safe to apply. Only from 'run' — the other
    -- phases have an async savestate callback in flight that would clobber the phase we set here.
    -- Chunk mode has its own end-to-end verify pass, so it just aborts. Pressing Stop again during the
    -- verification aborts for real (the guard below no longer matches phase 'run').
    if BruteforceDriver.active
        and BruteforceDriver.phase == 'run'
        and BruteforceDriver.chunks == nil
        and BruteforceDriver.core ~= nil
        and Bruteforce.summary(BruteforceDriver.core).gain > 0 then
        finish_single_search()
        return
    end
    BruteforceDriver.active = false
    BruteforceDriver.phase = 'idle'
    BruteforceDriver.verified = false
    BruteforceDriver.candidate = nil
    BruteforceDriver.capture_list = nil
    BruteforceDriver.checkpoints = nil
    BruteforceDriver.ck_targets = nil
    BruteforceDriver.ck_pending = false
    emu_halt()
    if BruteforceDriver.status == 'BRUTEFORCE_STATUS_CAPTURING'
        or BruteforceDriver.status == 'BRUTEFORCE_STATUS_SEARCHING' then
        BruteforceDriver.status = 'BRUTEFORCE_STATUS_STOPPED'
    end
end

-- Ends a single-mode search: halt, mark done, set the status.
-- Dumps the full end-of-search diagnostics to the Lua console. The tab's status rows clip at roughly
-- 48 characters, which truncated exactly the numbers that explain a zero gain — and these are numbers
-- the user needs to be able to copy out verbatim. pcall-guarded: a logging failure must never take
-- down a finished search.
local function log_summary()
    pcall(function()
        local d = BruteforceDriver
        if d.core == nil then return end
        local s = Bruteforce.summary(d.core)
        print(string.format(
            '[bruteforce] best=%d ref=%d gain=%d | tried=%d/%d reached=%d | sweep=%d/%d | shake=%d niches=%d',
            s.best_frames or -1, s.baseline_frames or -1, s.gain or 0,
            s.tried or 0, s.budget or 0, s.reaches or 0,
            s.sweep_done or 0, s.sweep_queued or 0, s.shake or 0, s.niches or 0))
        print(string.format(
            '[bruteforce] radius=%s blocked=%d@%s (speed %d / angle %d; too_slow %d by %s, too_fast %d by %s) closest_miss=%s end_dist=%s | chain=%s verified=%s ck=%d/%d%s',
            tostring(d.goal_radius), d.blocked_count or 0, tostring(d.blocked_best),
            d.blocked_speed or 0, d.blocked_angle or 0,
            d.blocked_slow or 0, tostring(d.blocked_dslow), d.blocked_fast or 0, tostring(d.blocked_dfast),
            tostring(s.closest_miss), tostring(d.end_distance),
            d.chain_locked and 'locked' or 'free', tostring(d.verified),
            d.ck_reaches or 0, d.ck_runs or 0, d.ck_broken and ' CK_BROKEN' or ''))
        -- Which techniques actually work on this segment: all-zero reaches across the board means the
        -- gain (if any) is not a missing move.
        local parts = {}
        for t, st in pairs(d.core.tech_stats or {}) do
            local name = Bruteforce._TECHNIQUES[t] and Bruteforce._TECHNIQUES[t].name or ('#' .. t)
            parts[#parts + 1] = string.format('%s %d/%d', name, st.reaches, st.tries)
        end
        if #parts > 0 then print('[bruteforce] tech reaches/tries: ' .. table.concat(parts, ', ')) end
    end)
end

local function done_single(status)
    BruteforceDriver.phase = 'done'
    BruteforceDriver.active = false
    BruteforceDriver.status = status
    emu_halt()
    log_summary()
end

-- Mid-run checkpoint ladder = a SPEED optimization: measure suffix-only candidates from a savestate
-- taken partway through the best, instead of replaying from the start. DISABLED, because a savestate
-- taken mid-run can be a frame out of alignment, so a candidate that "reaches the goal" measured from
-- the checkpoint may NOT reproduce when replayed honestly from the true start — which made the
-- end-to-end verification (correctly) discard real gains and apply nothing. Plain replay from the
-- start is deterministic, so with checkpoints off every measured best reproduces and applies. Flip
-- to true only after the checkpoint frame alignment is proven correct in mupen.
-- Re-enabled: checkpoint runs are now only a FILTER (a candidate that looks like it reaches is
-- re-measured honestly from the true start before it is reported), so a misaligned rung can cost a
-- candidate but can no longer produce an unreproducible result — which is what forced them off.
local USE_CHECKPOINTS = true

-- How many filtered runs to allow before judging whether the rungs work at all (see the run phase).
local CK_TRUST_SAMPLE = 40

-- Minimum spacing between checkpoint rungs: each one costs a partial replay of the best to build, so
-- rungs packed closer than this cost more than the replay they save.
local MIN_CK_GAP = 4

-- Drops the mid-run checkpoint ladder (the best just changed, so its savestates no longer match)
-- and asks for a fresh one to be built before the next candidate. Also called on a new core.
local function reset_checkpoint(rebuild)
    BruteforceDriver.checkpoints = nil
    BruteforceDriver.ck_targets = nil
    -- ck_broken: the rungs were measured to be useless this search (see the run phase) — never
    -- rebuild them, just run everything at full length.
    BruteforceDriver.ck_pending = USE_CHECKPOINTS and rebuild == true
        and not BruteforceDriver.ck_broken
    if BruteforceDriver.core then
        Bruteforce.set_checkpoints(BruteforceDriver.core, nil)
    end
end

-- Loads the search's start state for the next candidate; on completion resumes the RUN phase.
-- `search_state` is the original start in single mode, or the current chunk's start savestate in
-- chunk mode — so each chunk's runs stay SHORT (only that chunk's frames), no matter how many
-- chunks precede it. Candidates the core tagged `preserve_prefix` (identical to the best up to a
-- checkpoint rung) load that rung's savestate instead and start there — same measurement, a
-- fraction of the emulator frames.
-- Records that the finished run was at the goal POSITION in the goal ACTION at some frame, yet was
-- refused by the end-state tolerances. `blocked_best` is the earliest such frame seen: when it sits
-- below best_frames, the TOLERANCES are what is costing the frames, not the operators — the search
-- was reaching the target and being turned away.
local function note_blocked()
    if BruteforceDriver.blocked_at == nil then return end
    BruteforceDriver.blocked_count = (BruteforceDriver.blocked_count or 0) + 1
    if BruteforceDriver.blocked_best == nil
        or BruteforceDriver.blocked_at < BruteforceDriver.blocked_best then
        BruteforceDriver.blocked_best = BruteforceDriver.blocked_at
    end
end

---@param force_full boolean|nil ignore the checkpoints and replay from the true segment start
local function begin_candidate_run(force_full)
    BruteforceDriver.phase = 'load'
    local cand = BruteforceDriver.candidate
    local ck = nil
    if not force_full and cand.preserve_prefix ~= nil and BruteforceDriver.checkpoints ~= nil then
        for _, entry in ipairs(BruteforceDriver.checkpoints) do
            if entry.frame == cand.preserve_prefix then
                ck = entry
                break
            end
        end
    end
    -- A checkpoint run is only ever a FILTER (see the 'run' phase): its measurement is never trusted,
    -- so a misaligned rung can cost a candidate but can never produce a wrong frame count.
    BruteforceDriver.from_checkpoint = ck ~= nil
    if ck ~= nil then BruteforceDriver.ck_runs = (BruteforceDriver.ck_runs or 0) + 1 end
    BruteforceDriver.blocked_at = nil -- per-run: see note_blocked
    local load_state = ck ~= nil and ck.state or BruteforceDriver.search_state
    savestate.do_memory(load_state, 'load', function()
        BruteforceDriver.frame_idx = ck ~= nil and ck.frame or 0
        -- the closest-approach tracker starts from the prefix's own closest approach when resuming
        BruteforceDriver.candidate_min_dist2 = ck ~= nil and ck.min_dist2 or math.huge
        BruteforceDriver.phase = 'run'
        -- Re-assert that the emulator is running: in the sheet-driven flow the semantic sheet paused it
        -- when it reached its preview during capture, so the search would otherwise sit frozen. Harmless
        -- (idempotent) for the manual/movie flow where the emulator was already running.
        emu_run()
    end)
end

-- Starts (or continues) replaying toward the current checkpoint target, from the previous rung's
-- savestate — chaining segments this way means a replay never has to continue across an async save.
local function begin_ck_segment()
    BruteforceDriver.phase = 'ckload'
    savestate.do_memory(BruteforceDriver.ck_base_state, 'load', function()
        BruteforceDriver.frame_idx = BruteforceDriver.ck_base_frame
        BruteforceDriver.phase = 'ckrun'
        emu_run()
    end)
end

-- Builds the mid-run checkpoint LADDER: replays the current best and snapshots its state at 1/2 and
-- (when long enough) 3/4 of its length, each segment chained from the previous rung. Costs about
-- one 3/4-replay per improvement; pays for itself many times over via the shortened suffix runs.
local function build_checkpoints()
    local b = BruteforceDriver.core.best_frames
    -- Rungs at 1/2, 3/4 and 7/8. The deterministic sweep is END-FIRST, so most candidates only touch
    -- late frames and can start from the deepest rung: a 7/8 rung replays an eighth of the segment
    -- instead of all of it. A third rung is worth its build cost (one partial replay of the best)
    -- precisely because so many candidates land past it. Rungs closer than MIN_CK_GAP apart are not.
    local targets = {}
    for _, frac in ipairs({ 1 / 2, 3 / 4, 7 / 8 }) do
        local f = math.floor(b * frac)
        if f >= MIN_CK_GAP and (#targets == 0 or f - targets[#targets] >= MIN_CK_GAP) then
            targets[#targets + 1] = f
        end
    end
    if #targets == 0 then targets[1] = math.floor(b / 2) end
    BruteforceDriver.ck_targets = targets
    BruteforceDriver.ck_index = 1
    BruteforceDriver.ck_new = {}
    BruteforceDriver.ck_base_frame = 0
    BruteforceDriver.ck_base_state = BruteforceDriver.search_state
    BruteforceDriver.ck_min_dist2 = math.huge
    begin_ck_segment()
end

-- Requests the next candidate from the core; when the budget is exhausted, finishes the current
-- chunk (chunk mode) or the whole search. Rebuilds the mid-run checkpoint first when an
-- improvement invalidated it (only once the best is long enough for halving to pay off).
advance_to_next_candidate = function()
    if BruteforceDriver.ck_pending and BruteforceDriver.core
        and #BruteforceDriver.core.beam > 0 and BruteforceDriver.core.best_frames >= 8 then
        BruteforceDriver.ck_pending = false
        build_checkpoints()
        return
    end
    local next_candidate = Bruteforce.next_candidate(BruteforceDriver.core)
    if next_candidate == nil then
        if BruteforceDriver.chunks then
            finish_chunk()
        else
            finish_single_search()
        end
        return
    end
    BruteforceDriver.candidate = next_candidate
    begin_candidate_run()
end

-- Single-mode completion. A zero-gain search has nothing to apply -> straight to done. A positive
-- gain is VERIFIED end-to-end first: replay best_list from the true start and confirm it still
-- reaches the goal. If it does NOT reproduce (e.g. a candidate measured from a mid-run checkpoint
-- that doesn't replay identically from frame 0), the result is DISCARDED rather than applied — a
-- result that can't be reproduced would break the sheet it is written to. Mirrors chunk-mode verify.
finish_single_search = function()
    local core = BruteforceDriver.core
    local status = Bruteforce.summary(core).converged
        and 'BRUTEFORCE_STATUS_CONVERGED' or 'BRUTEFORCE_STATUS_DONE'
    if Bruteforce.summary(core).gain <= 0 then
        done_single(status)
        return
    end
    BruteforceDriver._verify_status = status
    BruteforceDriver.phase = 'verifysingleload'
    savestate.do_memory(BruteforceDriver.search_state, 'load', function()
        BruteforceDriver.verify_idx = 0
        BruteforceDriver.phase = 'verifysingle'
        emu_run()
    end)
end

-- Sets up and starts the search for chunk `i`: it searches ONLY this chunk's inputs, from the
-- chunk's start savestate (the optimised end of the previous chunk), toward this chunk's checkpoint.
start_chunk = function(i)
    local chunk = BruteforceDriver.chunks[i]
    local cp = chunk.checkpoint
    BruteforceDriver.target_action = cp.action
    BruteforceDriver.target_x = cp.x
    BruteforceDriver.target_y = cp.y
    BruteforceDriver.target_z = cp.z
    -- chunk checkpoints don't track speed/angle: position-only for internal boundaries. The final
    -- end-to-end verify (finalize_chunks) restores the full state goal and catches any drift.
    BruteforceDriver.target_h_speed = nil
    BruteforceDriver.target_yaw = nil
    -- Per-chunk goal-aiming directions: the same captured states, sliced to this chunk (0-indexed
    -- for estimate_aims: slice[0] = the state right before the chunk's first input).
    local aims = nil
    if BruteforceDriver.capture_states ~= nil and chunk.from ~= nil then
        local slice = {}
        for j = 0, #chunk.inputs do
            slice[j] = BruteforceDriver.capture_states[chunk.from - 1 + j]
        end
        aims = Bruteforce.estimate_aims(chunk.inputs, slice, { x = cp.x, z = cp.z })
    end
    -- Perturbation strength is AUTO-MANAGED, reactively: the search stays precise while it is
    -- improving, and every `pulse_after` non-improving candidates the stagnation pulse raises the
    -- shake (cumulatively, so a long stall escalates to big route-changing moves) until an
    -- improvement resets it. Benchmarked better than both a fixed level and a blind hot->cold
    -- schedule (which wastes the early budget destroying a baseline that already works).
    BruteforceDriver.core = Bruteforce.new({
        baseline = chunk.inputs,
        baseline_frames = #chunk.inputs,
        max_frames = #chunk.inputs,
        anneal = false,
        pulse_after = 30,
        aims = aims,
        budget = Settings.bruteforce.budget,
    })
    reset_checkpoint(false) -- fresh core: no checkpoint yet (built after its first improvement)
    BruteforceDriver.status = 'BRUTEFORCE_STATUS_SEARCHING'
    advance_to_next_candidate()
end

-- A chunk's budget is exhausted: append its optimised inputs to the running result. If more chunks
-- remain, replay them to build the next chunk's start savestate (the 'chain' phase); else finalise.
finish_chunk = function()
    local core = BruteforceDriver.core
    local optimised = {}
    for i = 1, core.best_frames do
        optimised[i] = Bruteforce.clone_input(core.best_list[i])
    end
    for _, f in ipairs(optimised) do
        BruteforceDriver.chunk_result[#BruteforceDriver.chunk_result + 1] = f
    end

    if BruteforceDriver.chunk_index < #BruteforceDriver.chunks then
        -- Chain: from this chunk's start, replay its optimised inputs, then save a savestate at the
        -- end — that becomes the next chunk's (short) start. Handled frame-by-frame in the 'chain'
        -- phase of process().
        BruteforceDriver.chain_inputs = optimised
        BruteforceDriver.chain_idx = 0
        BruteforceDriver.phase = 'chainload'
        savestate.do_memory(BruteforceDriver.search_state, 'load', function()
            BruteforceDriver.chain_idx = 0
            BruteforceDriver.phase = 'chain'
        end)
    else
        finalize_chunks()
    end
end

-- All chunks done: reconstruct the full run and VERIFY it end-to-end. We replay the concatenated
-- optimised chunks from the original start and check it still reaches the final goal — this gives
-- the TRUE frame count (not the sum of per-chunk measurements) and catches drift accumulated across
-- chunks (the chained checkpoints only match action+position, so many chunks can drift).
finalize_chunks = function()
    BruteforceDriver.target_action = BruteforceDriver.final_goal.action
    BruteforceDriver.target_x = BruteforceDriver.final_goal.x
    BruteforceDriver.target_y = BruteforceDriver.final_goal.y
    BruteforceDriver.target_z = BruteforceDriver.final_goal.z
    BruteforceDriver.target_h_speed = BruteforceDriver.final_goal.h_speed
    BruteforceDriver.target_yaw = BruteforceDriver.final_goal.yaw
    BruteforceDriver.status = 'BRUTEFORCE_STATUS_VERIFYING'
    BruteforceDriver.phase = 'verifyload'
    savestate.do_memory(BruteforceDriver.start_state, 'load', function()
        BruteforceDriver.verify_idx = 0
        BruteforceDriver.phase = 'verify'
    end)
end

-- End of the verification replay: expose the reconstructed run as the result if it reached the
-- final goal (with the real end-to-end frame count), otherwise flag chunk drift and keep no result.
finalize_verified = function(frames, reached)
    BruteforceDriver.chunks = nil
    BruteforceDriver.active = false
    BruteforceDriver.phase = 'done'
    emu_halt()
    if reached then
        local best = {}
        for i = 1, frames do best[i] = BruteforceDriver.chunk_result[i] end
        BruteforceDriver.core = {
            best_list = best,
            best_frames = frames, -- the true end-to-end count of the reconstructed run
            baseline_frames = BruteforceDriver.baseline_len,
            beam = {},
            tried = 0,
            budget = Settings.bruteforce.budget,
            improvements = 0,
        }
        BruteforceDriver.verified = true -- reproduced end-to-end by the chunk verify pass
        BruteforceDriver.status = 'BRUTEFORCE_STATUS_DONE'
    else
        -- the reconstructed run drifted and no longer reaches the goal: don't ship it
        BruteforceDriver.core = nil
        BruteforceDriver.verified = false
        BruteforceDriver.error = 'BRUTEFORCE_ERROR_CHUNK_DRIFT'
        BruteforceDriver.status = 'BRUTEFORCE_STATUS_STOPPED'
    end
end

-- Finishes measuring the baseline and transitions into the search (single or chunked).
local function finish_capture(reached)
    if not reached then
        BruteforceDriver.error = 'BRUTEFORCE_ERROR_GOAL_NOT_REACHED'
        BruteforceDriver.stop()
        BruteforceDriver.status = 'BRUTEFORCE_STATUS_STOPPED'
        return
    end
    local baseline = BruteforceDriver.capture_list
    local states = BruteforceDriver.capture_states
    BruteforceDriver.capture_list = nil
    -- movie-frame span of the original segment (used to splice the result back into the movie)
    BruteforceDriver.baseline_len = #baseline
    BruteforceDriver.search_state = BruteforceDriver.start_state -- searches load from here

    -- Goal-aiming directions, estimated from the capture (stick->world rotation per frame + goal
    -- position). Feeds the core's directed "aim at the goal" mutation; nil (no usable signal or
    -- legacy action-only goal) simply disables that operator.
    BruteforceDriver.aims = Bruteforce.estimate_aims(baseline, states,
        { x = BruteforceDriver.target_x, z = BruteforceDriver.target_z })

    -- Effective goal radius. A configured radius is an explicit override; 0 means "work it out"
    -- (the default), because the right tolerance is a property of how fast Mario is moving at the
    -- goal, not something the user can sensibly guess: too large and the goal fires while he is
    -- merely passing, which inflates the gain and truncates the applied result.
    BruteforceDriver.goal_radius = Settings.bruteforce.goal_radius
    if (Settings.bruteforce.goal_radius or 0) <= 0 then
        BruteforceDriver.goal_radius =
            Bruteforce.auto_goal_radius(states, #baseline) or DEFAULT_GOAL_RADIUS
    end

    local n = Settings.bruteforce.chunks or 1
    if n > 1 and #baseline > n then
        -- long segment: optimise it chunk by chunk, each chained from a fresh (short) savestate.
        -- Remember the real final goal — chunk searches overwrite target_* with their checkpoints,
        -- and the end-to-end verification restores it.
        BruteforceDriver.final_goal = {
            action = BruteforceDriver.target_action,
            x = BruteforceDriver.target_x,
            y = BruteforceDriver.target_y,
            z = BruteforceDriver.target_z,
            h_speed = BruteforceDriver.target_h_speed,
            yaw = BruteforceDriver.target_yaw,
        }
        BruteforceDriver.chunks = Bruteforce.split(baseline, states, n)
        BruteforceDriver.chunk_index = 1
        BruteforceDriver.chunk_result = {}
        start_chunk(1)
    else
        BruteforceDriver.chunks = nil
        -- Perturbation strength is AUTO-MANAGED reactively via the stagnation pulse — see
        -- start_chunk for the full rationale.
        BruteforceDriver.core = Bruteforce.new({
            baseline = baseline,
            baseline_frames = #baseline,
            max_frames = #baseline, -- only accept candidates that reach the goal in <= baseline frames
            anneal = false,
            pulse_after = 30,
            aims = BruteforceDriver.aims,
            budget = Settings.bruteforce.budget,
        })
        reset_checkpoint(false) -- fresh core: no checkpoint yet (built after its first improvement)
        BruteforceDriver.status = 'BRUTEFORCE_STATUS_SEARCHING'
        advance_to_next_candidate()
    end
end

---The per-frame processor entry point. Called from processors/Bruteforce.lua inside emu.atinput.
---When inactive it is a pass-through (zero impact on the normal pipeline).
---@param input table The final JoypadInputs for this frame (after all other processors).
---@return table input The (possibly overridden) inputs to apply.
function BruteforceDriver.process(input)
    if not BruteforceDriver.active then
        return input
    end

    -- Goal = same Mario action AND within goal_radius of the captured position (position makes the
    -- goal unambiguous). We also track the closest approach (squared, for speed) during a run so
    -- near-misses can feed the soft-fitness explore pool. target_x is nil only for legacy goals.
    -- Track the closest position approach (soft fitness for the explore pool / near-misses).
    if BruteforceDriver.target_x ~= nil then
        local dx = Memory.current.mario_x - BruteforceDriver.target_x
        local dy = Memory.current.mario_y - BruteforceDriver.target_y
        local dz = Memory.current.mario_z - BruteforceDriver.target_z
        local dist2 = dx * dx + dy * dy + dz * dz
        if BruteforceDriver.phase == 'run' and dist2 < BruteforceDriver.candidate_min_dist2 then
            BruteforceDriver.candidate_min_dist2 = dist2
        elseif BruteforceDriver.phase == 'ckrun' and dist2 < BruteforceDriver.ck_min_dist2 then
            -- prefix closest-approach, inherited by every candidate replayed from the checkpoint
            BruteforceDriver.ck_min_dist2 = dist2
        end
    end

    -- Goal acceptance: same action + position, plus — ONLY when something downstream depends on this
    -- segment (chain_locked) — the end speed and facing angle, so an applied optimization cannot desync
    -- what follows.
    --
    -- With nothing downstream the tolerances widen, but the end state is ALWAYS matched: the goal must
    -- never degenerate to action + position, or it fires while Mario is merely passing within
    -- goal_radius and the applied result is truncated short of finishing the action.
    -- Speed/angle checks only apply when a target was captured (nil = legacy goal).
    local locked = BruteforceDriver.chain_locked
    local speed_tol = locked and CHAIN_SPEED_TOL or CHAIN_SPEED_TOL_FREE
    local speed_tol_up = locked and CHAIN_SPEED_TOL_UP or CHAIN_SPEED_TOL_UP_FREE
    local angle_tol = locked and CHAIN_ANGLE_TOL or CHAIN_ANGLE_TOL_FREE
    local goal_reached = Bruteforce.state_matches_goal(
        {
            action = Memory.current.mario_action,
            x = Memory.current.mario_x, y = Memory.current.mario_y, z = Memory.current.mario_z,
            h_speed = Memory.current.mario_h_speed, yaw = Memory.current.mario_facing_yaw,
        },
        {
            action = BruteforceDriver.target_action,
            x = BruteforceDriver.target_x, y = BruteforceDriver.target_y, z = BruteforceDriver.target_z,
            h_speed = BruteforceDriver.target_h_speed, yaw = BruteforceDriver.target_yaw,
        },
        BruteforceDriver.goal_radius or Settings.bruteforce.goal_radius,
        BruteforceDriver.target_h_speed ~= nil and speed_tol or nil,
        BruteforceDriver.target_yaw ~= nil and angle_tol or nil,
        BruteforceDriver.target_h_speed ~= nil and speed_tol_up or nil)

    -- WHY a frame is refused. "Right action, right place, but refused on speed/angle" and "not there
    -- yet" need opposite fixes and are indistinguishable from the frame counts alone. So track the
    -- earliest frame of this run where the ACTION and POSITION alone would have accepted: if that is
    -- consistently below best_frames, the end-state tolerances are what is costing the frames, not the
    -- search. Cheap: one extra predicate call per frame, and only while actually running a candidate.
    if BruteforceDriver.phase == 'run' and not goal_reached
        and BruteforceDriver.blocked_at == nil and BruteforceDriver.target_action ~= nil then
        local pos_act_ok = Bruteforce.state_matches_goal(
            {
                action = Memory.current.mario_action,
                x = Memory.current.mario_x, y = Memory.current.mario_y, z = Memory.current.mario_z,
            },
            {
                action = BruteforceDriver.target_action,
                x = BruteforceDriver.target_x, y = BruteforceDriver.target_y, z = BruteforceDriver.target_z,
            },
            BruteforceDriver.goal_radius or Settings.bruteforce.goal_radius, nil, nil, nil)
        if pos_act_ok and BruteforceDriver.frame_idx > 0 then
            BruteforceDriver.blocked_at = BruteforceDriver.frame_idx
            -- Which tolerance actually refused it. Loosening the wrong one is how the applied result
            -- ended up truncated last time, so attribute the refusal instead of guessing: re-test with
            -- ONLY the speed bound, then with ONLY the angle bound.
            local cur = {
                action = Memory.current.mario_action,
                x = Memory.current.mario_x, y = Memory.current.mario_y, z = Memory.current.mario_z,
                h_speed = Memory.current.mario_h_speed, yaw = Memory.current.mario_facing_yaw,
            }
            local goal = {
                action = BruteforceDriver.target_action,
                x = BruteforceDriver.target_x, y = BruteforceDriver.target_y, z = BruteforceDriver.target_z,
                h_speed = BruteforceDriver.target_h_speed, yaw = BruteforceDriver.target_yaw,
            }
            local radius = BruteforceDriver.goal_radius or Settings.bruteforce.goal_radius
            if BruteforceDriver.target_h_speed ~= nil
                and not Bruteforce.state_matches_goal(cur, goal, radius, speed_tol, nil, speed_tol_up) then
                BruteforceDriver.blocked_speed = (BruteforceDriver.blocked_speed or 0) + 1
                -- WHICH SIDE of the speed bound refused, and by how much. The two need opposite
                -- fixes and different amounts, so record it rather than widening both blindly.
                local delta = (Memory.current.mario_h_speed or 0) - BruteforceDriver.target_h_speed
                if delta < 0 then
                    BruteforceDriver.blocked_slow = (BruteforceDriver.blocked_slow or 0) + 1
                    if BruteforceDriver.blocked_dslow == nil or delta < BruteforceDriver.blocked_dslow then
                        BruteforceDriver.blocked_dslow = delta -- the most extreme shortfall seen
                    end
                else
                    BruteforceDriver.blocked_fast = (BruteforceDriver.blocked_fast or 0) + 1
                    if BruteforceDriver.blocked_dfast == nil or delta > BruteforceDriver.blocked_dfast then
                        BruteforceDriver.blocked_dfast = delta
                    end
                end
            end
            if BruteforceDriver.target_yaw ~= nil
                and not Bruteforce.state_matches_goal(cur, goal, radius, nil, angle_tol, nil) then
                BruteforceDriver.blocked_angle = (BruteforceDriver.blocked_angle or 0) + 1
            end
        end
    end

    if BruteforceDriver.phase == 'capture' then
        -- Record Mario's state after frame_idx inputs (index by frames-applied) so chunk boundaries
        -- can use the state at their last frame as a checkpoint goal.
        BruteforceDriver.capture_states[BruteforceDriver.frame_idx] = {
            action = Memory.current.mario_action,
            x = Memory.current.mario_x,
            y = Memory.current.mario_y,
            z = Memory.current.mario_z,
        }
        -- Sheet-driven capture: the sheet itself decides where the segment ends (it flips busy to
        -- false and pauses the emulator when it reaches its preview). Detect THAT signal — trying to
        -- catch the goal action+position on the exact same frame is racy and hangs the emulator here.
        -- Take Mario's state at the sheet's end as the goal for the search.
        local sheet = BruteforceDriver.driving_sheet
        if sheet ~= nil then
            if BruteforceDriver.frame_idx > 0 and not sheet.busy then
                BruteforceDriver.capture_list[BruteforceDriver.frame_idx + 1] = Bruteforce.clone_input(input)
                BruteforceDriver.frame_idx = BruteforceDriver.frame_idx + 1
                BruteforceDriver.target_action = Memory.current.mario_action
                BruteforceDriver.target_x = Memory.current.mario_x
                BruteforceDriver.target_y = Memory.current.mario_y
                BruteforceDriver.target_z = Memory.current.mario_z
                BruteforceDriver.target_h_speed = Memory.current.mario_h_speed
                BruteforceDriver.target_yaw = Memory.current.mario_facing_yaw
                finish_capture(true)
            elseif BruteforceDriver.frame_idx >= CAPTURE_SAFETY_CAP then
                finish_capture(false)
            else
                BruteforceDriver.capture_list[BruteforceDriver.frame_idx + 1] = Bruteforce.clone_input(input)
                BruteforceDriver.frame_idx = BruteforceDriver.frame_idx + 1
            end
            return input
        end

        if goal_reached and BruteforceDriver.frame_idx > 0 then
            finish_capture(true)
        elseif BruteforceDriver.frame_idx >= CAPTURE_SAFETY_CAP then
            finish_capture(false)
        else
            BruteforceDriver.capture_list[BruteforceDriver.frame_idx + 1] = Bruteforce.clone_input(input)
            BruteforceDriver.frame_idx = BruteforceDriver.frame_idx + 1
        end
        return input
    elseif BruteforceDriver.phase == 'run' then
        -- End-state behaviour features for the quality-diversity archive: the action + position +
        -- horizontal speed where this candidate ended. Binning on these keeps diverse approaches alive.
        local end_state = {
            action = Memory.current.mario_action,
            x = Memory.current.mario_x,
            z = Memory.current.mario_z,
            hspeed = Memory.current.mario_h_speed,
        }
        if goal_reached and BruteforceDriver.frame_idx > 0 then
            -- Checkpoint runs are a FILTER, never a measurement. Replaying only the suffix from a
            -- mid-run savestate is what makes the search fast, but that savestate can be a frame out
            -- of alignment, and trusting its frame count is exactly what made results unreproducible
            -- before (checkpoints had to be disabled entirely). So a candidate that looks like it
            -- reaches is re-run HONESTLY from the true start, and only that second measurement is
            -- reported. Most candidates never reach, so most still cost only the cheap suffix.
            if BruteforceDriver.from_checkpoint then
                BruteforceDriver.ck_reaches = (BruteforceDriver.ck_reaches or 0) + 1
                begin_candidate_run(true)
                return Bruteforce.clone_input(nil)
            end
            note_blocked() -- it reached, but did it pass the goal position earlier and get refused?
            local improved = Bruteforce.report_result(BruteforceDriver.core, BruteforceDriver.candidate, BruteforceDriver.frame_idx, true, nil, end_state)
            if improved then
                -- the best changed: the old checkpoint no longer matches it — rebuild lazily
                reset_checkpoint(true)
            end
            advance_to_next_candidate()
            return Bruteforce.clone_input(nil)
        elseif BruteforceDriver.frame_idx >= Bruteforce.cutoff(BruteforceDriver.core) then
            -- early-abort pruning: past best_frames + slack this candidate cannot improve anymore,
            -- so stop emulating it — the search gets faster as the best gets shorter
            --
            -- Self-check on the rungs: a misaligned checkpoint makes EVERY suffix replay fail, which
            -- would quietly reject every candidate instead of speeding anything up — a far worse
            -- outcome than not using checkpoints at all. So if enough filtered runs have gone by with
            -- none of them reaching, while full runs demonstrably do reach, the rungs are bad: drop
            -- them for the rest of the search and go back to full-length runs.
            if BruteforceDriver.from_checkpoint
                and (BruteforceDriver.ck_runs or 0) >= CK_TRUST_SAMPLE
                and (BruteforceDriver.ck_reaches or 0) == 0
                and (Bruteforce.summary(BruteforceDriver.core).reaches or 0) > 0 then
                BruteforceDriver.ck_broken = true
                reset_checkpoint(false)
            end
            note_blocked() -- was it at the goal, in the goal action, and refused on speed/angle?
            local min_dist = BruteforceDriver.candidate_min_dist2 < math.huge
                and math.sqrt(BruteforceDriver.candidate_min_dist2) or nil
            Bruteforce.report_result(BruteforceDriver.core, BruteforceDriver.candidate, BruteforceDriver.frame_idx, false, min_dist, end_state)
            advance_to_next_candidate()
            return Bruteforce.clone_input(nil)
        else
            local out = BruteforceDriver.candidate[BruteforceDriver.frame_idx + 1] or Bruteforce.clone_input(nil)
            BruteforceDriver.frame_idx = BruteforceDriver.frame_idx + 1
            return out
        end
    elseif BruteforceDriver.phase == 'ckrun' then
        -- Replay the current best up to the current ladder target, then snapshot that state as a
        -- checkpoint rung (see build_checkpoints). Rungs are built in sequence, each replayed from
        -- the previous rung's savestate.
        local target = BruteforceDriver.ck_targets[BruteforceDriver.ck_index]
        if BruteforceDriver.frame_idx < target then
            local out = BruteforceDriver.core.best_list[BruteforceDriver.frame_idx + 1]
            BruteforceDriver.frame_idx = BruteforceDriver.frame_idx + 1
            return out or Bruteforce.clone_input(nil)
        end
        BruteforceDriver.phase = 'cksave'
        savestate.do_memory('', 'save', function(_, data)
            if not BruteforceDriver.active then return end -- Stop pressed mid-save: do not restart anything
            local d = BruteforceDriver
            d.ck_new[#d.ck_new + 1] = { frame = target, state = data, min_dist2 = d.ck_min_dist2 }
            d.ck_index = d.ck_index + 1
            if d.ck_index <= #d.ck_targets then
                -- next rung: chain the replay from the rung just saved
                d.ck_base_frame = target
                d.ck_base_state = data
                begin_ck_segment()
            else
                d.checkpoints = d.ck_new
                local frames = {}
                for i, entry in ipairs(d.ck_new) do frames[i] = entry.frame end
                Bruteforce.set_checkpoints(d.core, frames)
                advance_to_next_candidate()
            end
        end)
        return Bruteforce.clone_input(nil)
    elseif BruteforceDriver.phase == 'chain' then
        -- Replay the just-optimised chunk from its start, then snapshot the end as the next chunk's
        -- start savestate — so the next chunk's search only runs its own (short) frames.
        if BruteforceDriver.chain_idx < #BruteforceDriver.chain_inputs then
            local out = BruteforceDriver.chain_inputs[BruteforceDriver.chain_idx + 1]
            BruteforceDriver.chain_idx = BruteforceDriver.chain_idx + 1
            return out
        end
        BruteforceDriver.phase = 'chainsave'
        savestate.do_memory('', 'save', function(_, data)
            BruteforceDriver.search_state = data
            BruteforceDriver.chunk_index = BruteforceDriver.chunk_index + 1
            start_chunk(BruteforceDriver.chunk_index)
        end)
        return Bruteforce.clone_input(nil)
    elseif BruteforceDriver.phase == 'verify' then
        -- Replay the reconstructed run from the start and check it reaches the final goal.
        if goal_reached and BruteforceDriver.verify_idx > 0 then
            finalize_verified(BruteforceDriver.verify_idx, true)
            return Bruteforce.clone_input(nil)
        elseif BruteforceDriver.verify_idx >= #BruteforceDriver.chunk_result then
            finalize_verified(BruteforceDriver.verify_idx, false)
            return Bruteforce.clone_input(nil)
        end
        local out = BruteforceDriver.chunk_result[BruteforceDriver.verify_idx + 1]
        BruteforceDriver.verify_idx = BruteforceDriver.verify_idx + 1
        return out
    elseif BruteforceDriver.phase == 'verifysingle' then
        -- HONESTLY re-measure the best by replaying it from the true start (candidates measured from
        -- a mid-run checkpoint can land a frame or two off). If it reaches the goal at ANY frame up
        -- to the timeout, keep it at that TRUE frame count (gain recomputed from it — still applied
        -- if it's really shorter). Only discard when it never reaches within the timeout — that is a
        -- genuinely unreproducible result that would break a sheet. See finish_single_search.
        local core = BruteforceDriver.core
        if core ~= nil and goal_reached and BruteforceDriver.verify_idx > 0 then
            core.best_frames = BruteforceDriver.verify_idx -- the honest end-to-end count
            BruteforceDriver.verified = true -- reproduced from the true start: safe to apply/export
            -- How far the accepted run actually ends from the goal. The goal fires anywhere inside
            -- goal_radius, so a large value here means the result stops SHORT of the original end and
            -- part of the reported gain is really just the radius' slack — the sheet would replay
            -- truncated. Surfaced so a too-loose radius is visible instead of silently costing frames.
            if BruteforceDriver.target_x ~= nil then
                local dx = Memory.current.mario_x - BruteforceDriver.target_x
                local dy = Memory.current.mario_y - BruteforceDriver.target_y
                local dz = Memory.current.mario_z - BruteforceDriver.target_z
                BruteforceDriver.end_distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            end
            done_single(BruteforceDriver._verify_status)
            return Bruteforce.clone_input(nil)
        elseif core == nil or BruteforceDriver.verify_idx >= core.max_frames then
            BruteforceDriver.core = nil
            BruteforceDriver.error = 'BRUTEFORCE_ERROR_VERIFY_FAILED'
            done_single('BRUTEFORCE_STATUS_STOPPED')
            return Bruteforce.clone_input(nil)
        end
        local out = core.best_list[BruteforceDriver.verify_idx + 1] or Bruteforce.clone_input(nil)
        BruteforceDriver.verify_idx = BruteforceDriver.verify_idx + 1
        return out
    end

    -- 'load' / 'ckload' / 'cksave' / 'chainload' / 'chainsave' / 'done': feed a neutral input so no
    -- ambient movie/manual input can contaminate a measurement during an async transition.
    return Bruteforce.clone_input(nil)
end

---Writes the best input sequence to a file next to the script and copies a summary to clipboard.
---@return boolean ok
---@return string message_key
function BruteforceDriver.apply_best()
    if not BruteforceDriver.core then
        return false, 'BRUTEFORCE_ERROR_NO_RESULT'
    end
    local summary = Bruteforce.summary(BruteforceDriver.core)
    if summary.gain <= 0 then
        return false, 'BRUTEFORCE_ERROR_NO_GAIN'
    end
    local best = BruteforceDriver.core.best_list
    local lines = {
        string.format('# Bruteforce result: %d frames (baseline %d, gain %d)',
            summary.best_frames, summary.baseline_frames, summary.gain),
        '# frame\tstick_x\tstick_y\tA\tB\tZ',
    }
    for i = 1, summary.best_frames do
        local f = best[i] or Bruteforce.clone_input(nil)
        lines[#lines + 1] = string.format('%d\t%d\t%d\t%s\t%s\t%s',
            i, f.X, f.Y, tostring(f.A), tostring(f.B), tostring(f.Z))
    end
    local text = table.concat(lines, '\n') .. '\n'

    local path = folder .. 'bruteforce_result.txt'
    local file = io.open(path, 'wb')
    if file then
        file:write(text)
        file:close()
    end
    if clipboard and clipboard.set then
        clipboard.set('text', text)
    end
    return true, 'BRUTEFORCE_STATUS_APPLIED'
end

---Exports the best result by splicing the optimised segment into the currently open movie and
---writing "<movie>.bruteforced.m64" next to it. The movie's whole structure (header, any embedded
---savestate, and the inputs outside the segment) is preserved, so it plays like the source movie
---but with the shorter optimised segment.
---@return boolean ok
---@return string message_key
function BruteforceDriver.export_m64()
    if not BruteforceDriver.core then
        return false, 'BRUTEFORCE_ERROR_NO_RESULT'
    end
    -- Same invariant as apply_to_sheet: never ship a result that has not been reproduced end-to-end.
    if not BruteforceDriver.verified then
        return false, 'BRUTEFORCE_ERROR_NOT_VERIFIED'
    end
    if Bruteforce.summary(BruteforceDriver.core).gain <= 0 then
        return false, 'BRUTEFORCE_ERROR_NO_GAIN'
    end
    if BruteforceDriver.start_frame == nil or BruteforceDriver.baseline_len == nil then
        return false, 'BRUTEFORCE_ERROR_NO_MOVIE'
    end
    local movie_path = movie and movie.get_filename and movie.get_filename() or nil
    if not movie_path or movie_path == '' then
        return false, 'BRUTEFORCE_ERROR_NO_MOVIE'
    end
    local src = io.open(movie_path, 'rb')
    if not src then
        return false, 'BRUTEFORCE_ERROR_NO_MOVIE'
    end
    local movie_data = src:read('*all')
    src:close()
    if not movie_data or #movie_data < Bruteforce.M64_HEADER_SIZE then
        return false, 'BRUTEFORCE_ERROR_NO_MOVIE'
    end

    local core = BruteforceDriver.core
    local body = Bruteforce.build_m64_body(core.best_list, core.best_frames)
    local spliced = Bruteforce.splice_m64(movie_data, BruteforceDriver.start_frame, BruteforceDriver.baseline_len, body)
    if not spliced then
        return false, 'BRUTEFORCE_ERROR_WRITE_FAILED'
    end

    local out_path = movie_path:gsub('%.m64$', '') .. '.bruteforced.m64'
    local out = io.open(out_path, 'wb')
    if not out then
        return false, 'BRUTEFORCE_ERROR_WRITE_FAILED'
    end
    out:write(spliced)
    out:close()
    return true, 'BRUTEFORCE_STATUS_M64_EXPORTED'
end

--#endregion

--#region View

local function label_at(uid, rect, text)
    local theme = Styles.theme()
    ugui.label({
        uid = uid,
        rectangle = rect,
        text = text,
        color = Drawing.foreground_color(),
        font_size = theme.font_size * Drawing.scale,
        font_name = theme.font_name,
        align_x = BreitbandGraphics.alignment['start'],
        align_y = BreitbandGraphics.alignment.center,
    })
end

---A labelled integer spinner bound to a settings field. Returns the (integer) value.
---`enabled` controls whether it can be edited (e.g. the goal radius stays live during a search
---while the budget is locked once running).
local function config_spinner(label_uid, spinner_uid, row, label_key, value, min, max, enabled)
    label_at(label_uid, grid_rect(0, row, 4, 1), Locales.str(label_key))
    return math.floor(ugui.spinner({
        uid = spinner_uid,
        rectangle = grid_rect(4, row, 3, 1),
        value = value,
        minimum_value = min,
        maximum_value = max,
        is_enabled = enabled,
    }))
end

return {
    name = function() return Locales.str('BRUTEFORCE_TAB_NAME') end,
    draw = function()
        ensure_settings()
        local d = BruteforceDriver

        -- Row 0: set start
        if ugui.button({
                uid = UID.SetStart,
                rectangle = grid_rect(0, 0, 4, 1),
                text = Locales.str('BRUTEFORCE_SET_START'),
                is_enabled = not d.active,
            }) then
            d.set_start()
        end
        label_at(UID.StartStatus, grid_rect(4, 0, 4, 1),
            d.start_state and Locales.str('BRUTEFORCE_START_SET') or Locales.str('BRUTEFORCE_START_UNSET'))

        -- Row 1: set goal
        if ugui.button({
                uid = UID.SetGoal,
                rectangle = grid_rect(0, 1, 4, 1),
                text = Locales.str('BRUTEFORCE_SET_GOAL'),
                is_enabled = not d.active,
            }) then
            d.set_goal_from_current()
        end
        label_at(UID.GoalStatus, grid_rect(4, 1, 4, 1),
            d.target_action
            and string.format('0x%08X @%.0f,%.0f', d.target_action, d.target_x or 0, d.target_z or 0)
            or Locales.str('BRUTEFORCE_GOAL_UNSET'))

        -- Row 2: goal radius (position tolerance). 0 = ignore position (action only). Live-editable.
        -- (Speed + facing-angle chain-safety is AUTOMATIC — no knob; see CHAIN_SPEED_TOL/CHAIN_ANGLE_TOL.)
        Settings.bruteforce.goal_radius = config_spinner(UID.GoalRadiusLabel, UID.GoalRadius, 2,
            'BRUTEFORCE_GOAL_RADIUS', Settings.bruteforce.goal_radius, 0, 100000, true)

        -- Row 3: chunks. Split a long segment into N pieces optimised in sequence (1 = off).
        Settings.bruteforce.chunks = config_spinner(UID.ChunksLabel, UID.Chunks, 3,
            'BRUTEFORCE_CHUNKS', Settings.bruteforce.chunks, 1, 50, not d.active)

        -- No strength dial: perturbation is auto-managed by the search core (annealing hot->cold
        -- over the budget, plus a stagnation pulse that re-heats it whenever progress stalls).

        -- Row 4: max candidates (search budget).
        Settings.bruteforce.budget = config_spinner(UID.BudgetLabel, UID.Budget, 4,
            'BRUTEFORCE_BUDGET', Settings.bruteforce.budget, 1, 1000000, not d.active)

        -- Row 5: start / stop
        if ugui.button({
                uid = UID.StartStop,
                rectangle = grid_rect(0, 5, 4, 1),
                text = d.active and Locales.str('GENERIC_STOP') or Locales.str('GENERIC_START'),
                is_enabled = d.active or d.can_start(),
            }) then
            if d.active then d.stop() else d.start() end
        end

        -- Rows 6-9: live status
        label_at(UID.StatusPhase, grid_rect(0, 6, 8, 1), Locales.str(d.status))
        if d.core then
            local s = Bruteforce.summary(d.core)
            label_at(UID.StatusSummary, grid_rect(0, 7, 8, 1), string.format('%s %d  |  %s %d  |  %s %d',
                Locales.str('BRUTEFORCE_BEST'), s.best_frames,
                Locales.str('BRUTEFORCE_REFERENCE'), s.baseline_frames,
                Locales.str('BRUTEFORCE_GAIN'), s.gain))
            -- speed@goal: how fast the best solution ARRIVES at the goal. Among equal-frame
            -- solutions the search keeps the fastest arrival, which chains best into what follows.
            -- shake = the auto-escalation level: 0 while improving (precise polish), climbing while
            -- stuck (wider, route-changing search). Watching it move shows the auto-strength working.
            local tried_line = string.format('%s %d / %d   |   %s %d   |   %s %d',
                Locales.str('BRUTEFORCE_TRIED'), s.tried, s.budget,
                Locales.str('BRUTEFORCE_NICHES'), s.niches or 0,
                Locales.str('BRUTEFORCE_SHAKE'), s.shake or 0)
            if s.best_hspeed ~= nil then
                tried_line = tried_line .. string.format('   |   %s %.1f',
                    Locales.str('BRUTEFORCE_SPEED'), s.best_hspeed)
            end
            label_at(UID.StatusTried, grid_rect(0, 8, 8, 1), tried_line)
        end
        -- Row 9: the error, or (when there is none) the diagnostics that explain a zero gain.
        -- "best == ref, gain 0" has two opposite causes and the frame counts alone cannot tell them
        -- apart, so surface them: whether the goal is ever reproduced at all, and whether the search
        -- had to preserve the end state for chaining (which restricts what it may accept).
        if d.error then
            label_at(UID.StatusError, grid_rect(0, 9, 8, 1), Locales.str(d.error))
        elseif d.core then
            local s = Bruteforce.summary(d.core)
            local diag
            if (s.reaches or 0) == 0 and s.tried > 1 then
                -- The decisive case: nothing ever reproduced the goal, so the beam is never seeded and
                -- no gain is even possible. Say so instead of letting it read as "already optimal".
                diag = Locales.str('BRUTEFORCE_GOAL_NEVER_REACHED')
            else
                -- sweep = the DETERMINISTIC queue (drained/queued). 0 queued means the guaranteed
                -- frame-saving candidates found nothing to try and only random mutation is running.
                -- miss = how close the failing candidates get, which says whether they are near the
                -- goal (radius/end-state problem) or wildly off (mutations destroying the run).
                diag = string.format('%s %d  |  %s %d/%d',
                    Locales.str('BRUTEFORCE_REACHES'), s.reaches or 0,
                    Locales.str('BRUTEFORCE_SWEEP'), s.sweep_done or 0, s.sweep_queued or 0)
                -- The radius is derived from Mario's motion unless overridden, so show what it
                -- actually resolved to — an automatic value the user cannot see is a value they
                -- cannot trust.
                if d.goal_radius ~= nil then
                    diag = diag .. string.format('  |  %s %.0f',
                        Locales.str('BRUTEFORCE_RADIUS'), d.goal_radius)
                end
            end
            label_at(UID.StatusError, grid_rect(0, 9, 8, 1), diag)
        end

        -- Row 11 (BELOW the buttons — row 9 is only ~48 characters wide before the panel clips it,
        -- and cramming everything there truncated the very numbers that explain a zero gain).
        if d.core and not d.error then
            local s = Bruteforce.summary(d.core)
            local diag2 = ''
            local function add(text)
                diag2 = diag2 == '' and text or (diag2 .. '  |  ' .. text)
            end
            -- The decisive number when the queue drains with no gain: how many runs stood at the goal
            -- POSITION in the goal ACTION and were refused anyway, and the earliest frame that
            -- happened. `@F` below `best` means the END-STATE TOLERANCES are costing those frames, not
            -- the operators. Zero means Mario is never there in the right action any earlier — then a
            -- zero gain is the honest answer, not a search failure.
            add(string.format('%s %d@%d', Locales.str('BRUTEFORCE_BLOCKED'),
                d.blocked_count or 0, d.blocked_best or 0))
            -- Attribute the refusal: loosening the wrong tolerance is what truncated the applied
            -- result last time, so name the culprit rather than relaxing both.
            if (d.blocked_count or 0) > 0 then
                -- Which SIDE of the speed bound refused, and by how much: the fix and the amount both
                -- depend on it. Shown before the angle count because speed is the usual culprit.
                add(string.format('%s %d(-%s/+%s) %s %d',
                    Locales.str('BRUTEFORCE_BY_SPEED'), d.blocked_speed or 0,
                    d.blocked_dslow and string.format('%.0f', -d.blocked_dslow) or '0',
                    d.blocked_dfast and string.format('%.0f', d.blocked_dfast) or '0',
                    Locales.str('BRUTEFORCE_BY_ANGLE'), d.blocked_angle or 0))
            end
            if d.end_distance ~= nil then
                add(string.format('%s %.0f', Locales.str('BRUTEFORCE_END_DIST'), d.end_distance))
            elseif s.closest_miss ~= nil then
                add(string.format('%s %.0f', Locales.str('BRUTEFORCE_MISS'), s.closest_miss))
            end
            if d.chain_locked then add(Locales.str('BRUTEFORCE_CHAIN_LOCKED')) end
            label_at(UID.StatusDiag2, grid_rect(0, 11, 8, 1), diag2)
        end

        -- Row 10: apply best + export .m64 (playable movie).
        -- Only enabled when a real improvement was found (gain > 0) — nothing to save otherwise.
        -- When the search was launched for a Semantic Workflow sheet, "Apply best" rewrites that
        -- sheet's sections with the optimized frame-exact inputs instead of dumping a text file.
        -- `verified` is part of the enable condition, not just a guard inside the handler: an
        -- unverified best (e.g. a search stopped by hand before its verification pass) replays to a
        -- different end state, so the button must not even look available.
        local has_gain = d.core ~= nil and Bruteforce.summary(d.core).gain > 0 and d.verified
        local for_sheet = d.driving_sheet ~= nil
        if ugui.button({
                uid = UID.ApplyBest,
                rectangle = grid_rect(0, 10, 4, 1),
                text = Locales.str(for_sheet and 'BRUTEFORCE_APPLY_TO_SHEET' or 'BRUTEFORCE_APPLY_BEST'),
                is_enabled = has_gain and not d.active,
            }) then
            -- NB: use if/else, not `a and f() or g()` — the and/or idiom collapses f()'s multiple
            -- return values, dropping the status key (nil status later crashes the label).
            local ok, key
            if for_sheet then
                ok, key = d.apply_to_sheet()
            else
                ok, key = d.apply_best()
            end
            d.status = key or 'BRUTEFORCE_STATUS_IDLE'
        end
        if ugui.button({
                uid = UID.ExportM64,
                rectangle = grid_rect(4, 10, 4, 1),
                text = Locales.str('BRUTEFORCE_EXPORT_M64'),
                is_enabled = has_gain and not d.active,
            }) then
            local _, key = d.export_m64()
            d.status = key
        end
    end,
}

--#endregion
