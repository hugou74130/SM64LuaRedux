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
    }
end)

-- How many frames to allow when measuring the baseline before giving up (safety net when the
-- target action is never reached, e.g. because the movie is not replaying the action).
local CAPTURE_SAFETY_CAP = 1200

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
    if b.goal_radius == nil then b.goal_radius = 50 end
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
    BruteforceDriver.frame_idx = 0
    BruteforceDriver.phase = 'capture'
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
    -- goal = the sheet's end, where Mario is right now
    BruteforceDriver.target_action = Memory.current.mario_action
    BruteforceDriver.target_x = Memory.current.mario_x
    BruteforceDriver.target_y = Memory.current.mario_y
    BruteforceDriver.target_z = Memory.current.mario_z
    BruteforceDriver.start_state = sheet._savestate
    BruteforceDriver.start_frame = nil          -- sheet results are applied to the sheet, not spliced into a movie
    BruteforceDriver.driving_sheet = sheet
    -- Make sure the sheet is the one that drives the capture, replaying from its start with no chaining.
    -- busy = true so that when the sheet reaches its preview (flips busy to false) we can detect the
    -- end of the segment; reset_playback rewinds it so it plays from the start during capture.
    SemanticWorkflowProject.current = sheet
    sheet:reset_playback()
    sheet._on_preview_input_reached = nil
    sheet.busy = true
    BruteforceDriver.start()
end

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
    BruteforceDriver.active = false
    BruteforceDriver.phase = 'idle'
    BruteforceDriver.candidate = nil
    BruteforceDriver.capture_list = nil
    emu_halt()
    if BruteforceDriver.status == 'BRUTEFORCE_STATUS_CAPTURING'
        or BruteforceDriver.status == 'BRUTEFORCE_STATUS_SEARCHING' then
        BruteforceDriver.status = 'BRUTEFORCE_STATUS_STOPPED'
    end
end

-- Chunk-mode orchestration is mutually recursive, so forward-declare the pieces.
local advance_to_next_candidate
local start_chunk
local finish_chunk
local finalize_chunks
local finalize_verified

-- Loads the search's start state for the next candidate; on completion resumes the RUN phase.
-- `search_state` is the original start in single mode, or the current chunk's start savestate in
-- chunk mode — so each chunk's runs stay SHORT (only that chunk's frames), no matter how many
-- chunks precede it.
local function begin_candidate_run()
    BruteforceDriver.phase = 'load'
    savestate.do_memory(BruteforceDriver.search_state, 'load', function()
        BruteforceDriver.frame_idx = 0
        BruteforceDriver.candidate_min_dist2 = math.huge -- reset the closest-approach tracker
        BruteforceDriver.phase = 'run'
        -- Re-assert that the emulator is running: in the sheet-driven flow the semantic sheet paused it
        -- when it reached its preview during capture, so the search would otherwise sit frozen. Harmless
        -- (idempotent) for the manual/movie flow where the emulator was already running.
        emu_run()
    end)
end

-- Requests the next candidate from the core; when the budget is exhausted, finishes the current
-- chunk (chunk mode) or the whole search.
advance_to_next_candidate = function()
    local next_candidate = Bruteforce.next_candidate(BruteforceDriver.core)
    if next_candidate == nil then
        if BruteforceDriver.chunks then
            finish_chunk()
        else
            BruteforceDriver.phase = 'done'
            BruteforceDriver.active = false
            BruteforceDriver.status = 'BRUTEFORCE_STATUS_DONE'
            emu_halt()
        end
        return
    end
    BruteforceDriver.candidate = next_candidate
    begin_candidate_run()
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
        budget = Settings.bruteforce.budget,
    })
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
        BruteforceDriver.status = 'BRUTEFORCE_STATUS_DONE'
    else
        -- the reconstructed run drifted and no longer reaches the goal: don't ship it
        BruteforceDriver.core = nil
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
            budget = Settings.bruteforce.budget,
        })
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
    local goal_reached = Memory.current.mario_action == BruteforceDriver.target_action
    if BruteforceDriver.target_x ~= nil then
        local dx = Memory.current.mario_x - BruteforceDriver.target_x
        local dy = Memory.current.mario_y - BruteforceDriver.target_y
        local dz = Memory.current.mario_z - BruteforceDriver.target_z
        local dist2 = dx * dx + dy * dy + dz * dz
        if BruteforceDriver.phase == 'run' and dist2 < BruteforceDriver.candidate_min_dist2 then
            BruteforceDriver.candidate_min_dist2 = dist2
        end
        local r = Settings.bruteforce.goal_radius
        if goal_reached and dist2 > (r * r) then
            goal_reached = false
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
            Bruteforce.report_result(BruteforceDriver.core, BruteforceDriver.candidate, BruteforceDriver.frame_idx, true, nil, end_state)
            advance_to_next_candidate()
            return Bruteforce.clone_input(nil)
        elseif BruteforceDriver.frame_idx >= BruteforceDriver.core.max_frames then
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
    end

    -- 'load' / 'chainload' / 'chainsave' / 'done': feed a neutral input so no ambient movie/manual
    -- input can contaminate a measurement during an async transition.
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
            local tried_line = string.format('%s %d / %d   |   %s %d',
                Locales.str('BRUTEFORCE_TRIED'), s.tried, s.budget,
                Locales.str('BRUTEFORCE_NICHES'), s.niches or 0)
            if s.best_hspeed ~= nil then
                tried_line = tried_line .. string.format('   |   %s %.1f',
                    Locales.str('BRUTEFORCE_SPEED'), s.best_hspeed)
            end
            label_at(UID.StatusTried, grid_rect(0, 8, 8, 1), tried_line)
        end
        if d.error then
            label_at(UID.StatusError, grid_rect(0, 9, 8, 1), Locales.str(d.error))
        end

        -- Row 10: apply best + export .m64 (playable movie).
        -- Only enabled when a real improvement was found (gain > 0) — nothing to save otherwise.
        -- When the search was launched for a Semantic Workflow sheet, "Apply best" rewrites that
        -- sheet's sections with the optimized frame-exact inputs instead of dumping a text file.
        local has_gain = d.core ~= nil and Bruteforce.summary(d.core).gain > 0
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
