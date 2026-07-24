# Bruteforce — nocturnal improvements (read me when you wake up)

Everything below was built while you slept. **Nothing is committed or pushed** (branch `feat/bruteforce`).
All pure logic is unit-tested: `lua tests/bruteforce_test.lua` → **193 passed, 0 failed** (was 127).
The sheet-side wiring is verified headlessly (22 checks) with the real Sheet code.

## Removed (2026-07-24, user decision): the "Bruteforce ALL" pipeline

The overnight all-sheets pipeline (Round 8) was **removed** at the user's request. Their reasoning:
optimizing ONE sheet, applying it, then moving to the next by hand is more relevant and controllable
than an auto-chaining overnight run — the auto-chaining kept causing desync/coherence problems that
weren't worth it. Deleted: `BruteforcePipeline` (whole region), its UI button, the processor +
`atdrawd2d` ticks, the `BRUTEFORCE_PIPELINE*` locales, and the project backup/auto-save. Kept: every
per-sheet search improvement (chain-safe state goal, verify, checkpoints-off, escalation, etc.) since
they all help the manual per-sheet flow. Do not re-add a pipeline unless explicitly requested.

## Fix (2026-07-24, user-reported): checkpoints made gains unreproducible → nothing applied

Follow-up: after the honest-remeasure verify fix, gains were STILL discarded (VERIFY_FAILED) and
never applied. Root cause found: the mid-run **checkpoint ladder** (a speed optimization — measure
suffix-only candidates from a savestate taken partway through the best) produces measurements that
do NOT reproduce when the best is replayed honestly from the true start. A savestate taken mid-run
can be a frame out of alignment, so a candidate "reaches the goal" measured from the checkpoint but
misses it on a full replay — and the end-to-end verify then (correctly) discards it. Plain replay
from the start IS deterministic (the whole search depends on that), so the checkpoints were the only
non-deterministic measurement path. Fix: **checkpoints disabled** (`USE_CHECKPOINTS = false` in the
driver). Every candidate is now measured honestly from the true start, so every best reproduces and
applies. Cost: the polish phase loses the ~2x checkpoint speedup (early-abort cutoff still applies);
correctness over speed — the magic button must actually apply its gains. Re-enable only once the
checkpoint frame alignment is proven correct in mupen. Tests: 281 passed.

## Fix (2026-07-24, user-reported): VERIFY_FAILED discarded real improvements

Symptom: the search found gains, then the single-mode verification (`verifysingle`) said
"did not reproduce the goal — discarded" and applied nothing. Cause: verify required the best to
reach the goal at EXACTLY `best_frames`, but candidates measured from a mid-run checkpoint can land
a frame or two off when replayed from frame 0, so a perfectly reproducible result got thrown away.
Fix: `verifysingle` now HONESTLY re-measures — it replays the best from the true start up to the
timeout (`max_frames`) and keeps the result at whatever frame it actually reaches the goal, updating
`best_frames` to that honest count (gain recomputed; still applied if really shorter). It only
discards when the best never reaches within the timeout (a genuinely unreproducible result). Net:
verify can now only turn a false-discard into an honest keep, never reject a reproducing result.

## Fix (2026-07-24, user-reported): optimizing sheet 1 desynced sheet 2

Symptom: applying a gain to a sheet broke the SYNC of the next sheet. Cause: the goal was
"action + position within radius" — but two paths can reach the same spot with DIFFERENT speed and
facing angle. An optimized sheet 1 ended in a slightly different state, so sheet 2 (which started
from the original end state) desynced.
Fix — chain-safe goal: an accepted optimization must also match Mario's HORIZONTAL SPEED and FACING
ANGLE at the goal, so it leaves him in the same state (a real frame-saving does; a route change
doesn't → rejected). Pure core: `Bruteforce.state_matches_goal(cur, goal, radius, speed_tol,
angle_tol)` + `Bruteforce.angle_diff` (u16 wraparound), fully tested. Driver captures speed+yaw at
the goal (manual, sheet, and capture-end paths) and uses the predicate; chunk checkpoints stay
position-only but the end-to-end verify restores the full-state goal. Chain-safety is AUTOMATIC — no
user knob (it's the magic button): fixed internal tolerances in the driver, `CHAIN_SPEED_TOL` = 1.0
and `CHAIN_ANGLE_TOL` = 256 (~1.4°). Tests: 281 passed (15 new). (An earlier draft exposed the
tolerances as UI dials; removed — the user must not have to tune the magic button.)

## Fix (2026-07-24, user-reported): pipeline broke already-optimal sheets

Symptom: "converged — likely optimal" fired, then the pipeline APPLIED a result even to a sheet with
no real improvement, replacing the sheet's inputs with a broken bruteforce candidate.
Root cause (`report_result` reference re-basing): the first candidate is the baseline replayed under
the search's action+radius goal detection. If that detection did NOT fire on the baseline (it uses a
different mechanism than the capture's end signal, so it can miss), `baseline_frames` stayed at the
STALE capture value while the beam stayed empty. A later candidate reaching in fewer frames then
produced a FAKE positive gain (`stale_baseline - short_reach > 0`), which passed the `gain > 0` apply
gate and overwrote the sheet with a shorter, non-reproducing sequence.
Fix (pure core, testable): track `baseline_reached`; `summary.gain` is forced to 0 whenever the
baseline never reached (no valid reference), so a spurious result can NEVER be applied. `nil` (legacy
/ chunk-mode synthetic core) is treated as valid so verified chunk results still report their gain.
Pipeline also now clears `core`/`driving_sheet` before each sheet (no cross-sheet leak) and reports
`GOAL_NOT_REACHED` for skipped sheets. Tests: 266 passed (9 new).

Belt-and-suspenders (driver, needs mupen validation): single/sheet-mode completion now runs an
END-TO-END VERIFICATION before a positive-gain result can be applied — it replays `best_list` from
the true start (phases `verifysingleload`/`verifysingle`, mirroring the proven chunk-mode verify) and
only keeps the result if it still reaches the goal. If it does NOT reproduce (e.g. a candidate
measured from a mid-run checkpoint that doesn't replay identically from frame 0), the result is
DISCARDED with `BRUTEFORCE_ERROR_VERIFY_FAILED` — nothing is written to the sheet. So a result can
only reach a sheet if it (a) has a valid reference AND (b) reproduces the goal from scratch.

## Fix (2026-07-24, user-reported): pipeline froze between sheets

Symptom: the pipeline searched the first sheet, found nothing, and never moved to the next sheet.
Cause: pipeline transitions were driven only from the INPUT processor (`emu.atinput`), but the very
events that trigger a transition — a search ending, a sheet run reaching its preview — PAUSE the
emulator, after which atinput never fires again: the pipeline had no heartbeat exactly when it
needed one. Fix: `BruteforcePipeline.tick()` is now also called from the GUI loop
(`atdrawd2d` in `src/SM64Lua.lua`), which keeps running while paused — same execution context as a
user clicking a button. Transitions are state-guarded, so the double tick is harmless.

## Round 9 (2026-07-24) — the leftover roadmap items: heatmap + crash-proof nights

1. **Improvement heatmap** (pure core): every improving candidate credits the frames its mutation
   window touched; local windows are then drawn toward the hot zones (`heat_bias` 0.4 of windowed
   draws are heat-weighted). The search literally learns WHERE in the segment the frames live.
   Sweep/baseline candidates never pollute the credit (window tracker cleared per candidate).
2. **Crash-proof overnight pipeline**: at pipeline start the whole project is backed up on disk
   (`.bak` copies of the meta, every `.sws` and savestate — pre-pipeline originals always
   recoverable), and after every applied gain the project AUTO-SAVES. A crash at 4am only loses the
   sheet being searched, never the gains already found. Only active when the project has a saved
   location; the save is pcall-guarded so a disk error can't kill the run.

Still deliberately NOT done: the semantic angle-space mutation (candidates as intended-yaw +
magnitude converted through the live camera each frame) — it changes the candidate representation
and should only be built once the round-8 pipeline is validated in mupen. Multi-emulator
parallelism remains impossible from Lua. Tests: 257 passed (5 new).

## Round 8 (2026-07-24) — the overnight pipeline: "Bruteforce TOUT"

The magic button, scaled to the whole TAS. New in the Bruteforce tab: **Bruteforce TOUT** (row 11).
It walks the project's sheet list in order and, for each sheet: re-runs its chain to its end
(rebuilding invalidated ancestors — the exact mechanics of clicking the sheet), launches the
validated sheet-search flow, **applies any gain** (rewriting the sheet, so the next sheet re-chains
from the faster state automatically), and moves on. When the list is done it writes
`bruteforce_report.txt` next to the script with per-sheet gains and shows `gain total: N` in the
tab. Runs from the input processor, so it keeps working whatever tab is visible; the GUI throttle
covers it; Stop (pipeline button or the search Stop) is safe anytime.

Two search upgrades shipped with it (both in the pure core):

1. **Speed counts as progress**: at equal frames, a faster-arriving solution taking the beam front
   now counts as an IMPROVEMENT — it resets stagnation, rebuilds the checkpoints and re-anchors the
   deterministic sweeps on the new best. Better chaining bases get polished instead of ignored.
2. **Auto-stop + overtime** (`Bruteforce.done` rework): a search that goes `convergence_after`
   candidates (default max(200, budget/4)) with zero improvement stops early as **"Convergé —
   probablement optimal"** (new status); a search whose budget runs out ON A HOT STREAK keeps going
   until the streak cools (overtime_grace = 100), capped at 2x budget. Budgets now spend themselves
   where they pay.

Tests: 252 passed (14 new). Files: `src/core/Bruteforce.lua`, `src/views/Bruteforce.lua`
(BruteforcePipeline), `src/processors/Bruteforce.lua` (tick), `src/SM64Lua.lua` (throttle), locales.

## Round 7 (2026-07-24) — raw wall-clock speed (the "is it possible to make it faster" round)

Two levers, both automatic:

1. **GUI throttle during search** (`src/SM64Lua.lua`): while a search is active, the whole ugui
   redraw drops from `Settings.ff_fps` (30) to 4 fps — every redrawn frame was CPU stolen from the
   emulation the search waits on. Likely the biggest real-machine win of this round; the status
   line still updates 4x/s. Reverts by itself when the search ends.
2. **Checkpoint LADDER** (1/2 AND 3/4 of the best, was: single 1/2): suffix mutations in the last
   quarter now replay only ~25% of the frames. The rungs are built in sequence, each segment
   replayed from the previous rung's savestate, so the replay never has to survive an async save
   (phases ckload/ckrun/cksave, chained). Core: `set_checkpoints` (ladder), sweep candidates tag
   the DEEPEST rung below their change, suffix polish picks a random usable rung.

Notes: UltraFastForward is already the fastest core mode (checked `lib/api.lua`), and there is no
cheaper savestate primitive than `savestate.do_memory` — those ceilings are the emulator's.
Tests: 238 passed (6 new: ladder tagging/selection/clearing, deepest-rung sweep tagging).

## Round 6 (2026-07-24) — "toutes les améliorations" : directed search + full sweep family

1. **Goal-aiming operator** (the headline): `Bruteforce.estimate_aims` recovers the per-frame
   stick->world rotation FROM THE CAPTURE ITSELF (each baseline frame pairs a stick input with the
   world movement it produced — no camera read needed), then aims full-deflection sticks straight at
   the goal position. The mutation engine can now propose *directed* inputs instead of blind noise.
   Wired for both single-segment and chunk mode (per-chunk goals). Bench: best result of any round —
   `21.85` vs `22.90` at the smallest frame budget, near the toy optimum (~21) at every budget.
2. **±2-frame sweep**: every button edge and whole-press shift is also tried at 2 frames (after the
   ±1 pass) — a 2-frame retiming often works where both 1-frame intermediates fail.
3. **Adjacent-pair removal sweep** (`remove2`): each redundant frame is also tried dropped together
   with a neighbour — 2 frames saved at once where the single drop broke the run.
4. **Hold-smoothing operator**: occasionally copies one frame's stick over the next 2-8 frames.
   Optimal SM64 inputs are clean holds; this is the counter-pressure to accumulated mutation noise.
5. **Rotation escalates with stagnation** (up to ±pi) alongside flips/removals/explore/slack.
6. **UI: `shake:` level** in the status line — 0 while polishing, climbing while stuck, so you can
   SEE the auto-strength escalate and reset.

Tests: 232 passed (16 new: estimate_aims recovery/gaps/nil, aim op, hold op, k=2 sweep, remove2,
shake). Files: `src/core/Bruteforce.lua`, `src/views/Bruteforce.lua`, locales.

## Round 5 (2026-07-24) — anti-stagnation: escalate EVERYTHING when stuck, not just stick noise

Feedback: "finds an improvement almost immediately, then gets stuck for a while". The quick find is
the deterministic sweep doing its job; the stall was because stagnation only raised stick magnitude,
while the early-abort cutoff was starving route diversity. Fixes (all in the pure core):

1. **Multi-dimensional stagnation escalation** (`Bruteforce.escalation`): each stagnation period
   (30 non-improving candidates) now also raises button-flip and frame-removal rates (structural
   changes), grows the explore-pool usage, FADES the checkpoint suffix polish (fine polish is what
   is failing), and — key — **widens the early-abort window** (`cutoff` slack +2 per level) so
   slower-but-different routes get to finish and reseed the beam/archive. Everything snaps back to
   precise the moment an improvement lands. Explicitly-high configured chances are never clamped down.
2. **Whole-press shift sweep**: the deterministic sweep now also tries moving each A/B/Z press
   *intact* (both edges together, duration kept) ±1 frame — the coordinated two-edge change random
   mutation almost never produces, and a classic SM64 timing fix.

Bench: slightly slower on the smooth toy problem early (wider net costs frames), better at long
budgets — the "stuck" regime this round targets. Tests: 216 passed (16 new). File: `src/core/Bruteforce.lua`.

## Round 4 (2026-07-24) — wall-clock speed: the search now runs (much) more candidates per second

Feedback: "it still takes time to find". The bottleneck is emulator replay time per candidate, so
this round attacks exactly that. Four mechanisms, all automatic:

1. **Early-abort pruning** (`Bruteforce.cutoff`): once a best exists, any candidate that has not
   reached the goal by `best + 2` frames cannot improve — the driver cuts it there instead of
   running to the full baseline length. The search literally speeds up as it improves.
2. **Mid-run checkpoint** (the big one): after every improvement, the driver replays the best once
   and savestates it at HALF its length. Half of all subsequent candidates mutate only the second
   half (`preserve_prefix` tag) and are replayed FROM the checkpoint — ~2x more candidates/second
   in the polish phase. Costs one half-replay per improvement; invalidated automatically the moment
   the best changes. New driver phases: `ckload` -> `ckrun` -> `cksave` (modeled on the proven
   `chain` phases; Stop mid-save is guarded).
3. **Deterministic edge-timing sweep**: the sweep now also tries every A/B/Z press/release edge of
   the best shifted +-1 frame (end-first), in addition to the redundant-frame removals — SM64's
   frame losses are mostly button timing, and now every such fix is TRIED systematically instead of
   waiting for the random mutation to find it.
4. **Candidate dedupe**: exact input lists already measured are never sent to the emulator again
   (hash set; deterministic sweeps skip, stochastic ones reroll).

Synthetic bench: ~25% more candidates per emulated frame at equal quality — and the bench cannot
measure the edge-sweep gains (its toy model has no button timing), so real segments should do
better. Tests: 200 passed (17 new: cutoff, hash/dedupe, edge sweep order, checkpoint tagging,
checkpoint+sweep interplay). Files: `src/core/Bruteforce.lua`, `src/views/Bruteforce.lua`.

## Round 3 (2026-07-22) — auto-managed strength + Apply REALLY rewrites the sheet

Two changes requested after field testing ("only saved 1 frame on a sloppy action"; "apply must
actually modify the sheet"):

1. **The strength dial is GONE — the search manages itself.** No more weak/medium/strong choice.
   The search stays precise while it is improving; every 30 non-improving candidates the stagnation
   pulse raises the shake (cumulatively — a long stall escalates to big route-changing moves) and
   any improvement cools it back down. Benchmarked ≥ the old fixed level at every budget, and it
   can no longer get stuck the way a fixed weak/medium setting could.
2. **"Apply to sheet" now WRITES the result into the sheet.** The sheet's sections are replaced by
   one "Bruteforced" section holding one frame-exact input per optimized frame (manual stick +
   buttons, timeout 1). The optimization is now the sheet's REAL content: visible and editable in
   the input list, **persisted to the .sws on save** (fixes the old "in-memory only" limitation),
   and chained through the normal semantic pipeline. The old hidden "override track" machinery
   (signature auto-invalidation included) was removed — it is no longer needed since editing the
   sheet now edits the actual inputs. NOTE: applying is destructive to the sheet's semantic
   sections by design (the .sws on disk keeps the old version until you save the project).

Verified headlessly with the real Sheet implementation (13 checks: rewrite, selection, frame-exact
playback, end-of-sheet pause, chaining callback, JSON-encodability). Core tests: 183 passed.
Files: `src/core/Bruteforce.lua` (presets removed, to_overrides emits full SectionInputs),
`src/views/Bruteforce.lua` (auto strength, apply rewrite, UI reflow), `Sheet.lua` (Impl + Def:
apply_optimized_inputs replaces the override track), `Settings.lua`, `Locales.lua` + lang files.

## Round 2 (2026-07-22) — six new search improvements, all tested (160 → 193 tests)

Benchmarked on a synthetic goal-reaching model (same budget of 400 candidates, 20 seeds):
the old operator set saved **4.3 frames** on average, the new one saves **7.8 frames** —
near the model's theoretical optimum. Nothing to configure; all on by default.

1. **Deterministic removal sweep** — the moment a new best is found, every obviously-droppable
   frame of it (neutral waits, duplicates of the previous frame) is tried EXACTLY once, end-first.
   Each confirmed removal produces a new best and re-runs the sweep, so all cheap frame savings are
   peeled off greedily instead of waiting for the random removal mutation to stumble on them.
2. **Polar stick mutations** — SM64 movement is angle-driven and optimal inputs are almost always at
   full deflection. ROTATE turns a frame's direction slightly (magnitude kept); SNAP pushes the stick
   to the rim (127, angle kept). Both skip deadzone frames.
3. **Crossover** — recombines two beam solutions (prefix of one + suffix of the other): a good early
   jump from one route combined with a good landing from another, which no single-parent mutation
   can produce.
4. **Frame insertion** — duplicates a frame (the counterpart of removal), letting the search fix a
   timing that a removal alone broke. Candidates are still trimmed to the timeout.
5. **Speed tie-break** — among equal-frame solutions, the beam now keeps the one arriving at the goal
   with the highest horizontal speed → the next segment (chained sheet) starts from the best state.
   Shown live in the tab as `speed@goal:` (FR: `vitesse au but :`).
6. **Curiosity-weighted archive expansion** — the quality-diversity archive now expands its
   least-mined niches first (2-way tournament on expansion counts) instead of uniformly re-rolling
   crowded ones.

Files touched in round 2: `src/core/Bruteforce.lua` (all six), `src/views/Bruteforce.lua` +
`src/core/Locales.lua` + both lang files (`BRUTEFORCE_SPEED`), `tests/bruteforce_test.lua` (+33 checks).

## TL;DR — the search is smarter by default, no new knobs to set
The bruteforce now explores much better and attacks frame-count more directly. You don't have to change
anything — launch it exactly like before. The improvements kick in automatically.

I also had a research agent read the **real Scattershot source** (the SM64 community's state-of-the-art
search) and the biggest idea from it is now in your tool: a **quality-diversity archive**.

## What changed (all in the pure core `src/core/Bruteforce.lua`, fully tested)

1. **Quality-diversity archive (scattershot-lite / MAP-Elites)** — the big one.
   Instead of only keeping a beam of the best few solutions (which collapses onto one route and gets
   stuck), the search now keeps the **best candidate per "cell"** of a behaviour descriptor of where/how
   each run ended: `(Mario action, coarse x/z, horizontal-speed bucket)`. Every so often it expands a
   **random cell** instead of the beam. This structurally preserves many distinct approaches at once, so
   a slower-looking route that later admits a big shortcut is never thrown away. This is the mechanism
   behind Scattershot's records. The status line now shows **`niches: N`** = how many distinct behaviour
   cells it's tracking (higher = more diverse exploration).

2. **Smarter frame-removal** — the mutation that directly shortens the run.
   It now **prefers dropping redundant frames** (neutral "wait" frames, or exact duplicates of the
   previous frame) because those are the ones most likely to still reach the goal when removed. It also
   occasionally removes a **short run of 2–3 frames** at once for bigger jumps toward a shorter solution.

3. **Edge-nudge operator** — targets the axis frame-reduction actually lives on.
   In SM64 most lost frames are **jump-button timing** (late jump, held-too-long dive), not stick noise.
   A dedicated operator slides a single A/B/Z **press/release edge** ±1–3 frames, far more efficient than
   random button flips.

4. **Windowed (local) mutation** — for precision on long sheets.
   Sometimes it perturbs only a **contiguous window** of the input sequence instead of the whole thing,
   so it can polish one part of a long run without destroying the rest.

5. **RNG seeding** — a search can be made reproducible (same seed → same candidates). Foundational for
   testing the stochastic operators; also handy if you ever want a repeatable run.

## Quality-of-life
- **Auto-invalidation**: if you **edit a sheet after applying** a bruteforce optimization, the stale
  optimization is now dropped automatically the next time the sheet runs — so your edits take effect
  instead of silently replaying the old optimized frames. (Signature-based; `src/views/SemanticWorkflow/Implementations/Sheet.lua`.)
- **Richer status**: the Bruteforce tab now shows `niches:` alongside `tried:`; `summary()` also exposes
  `stagnation` (candidates since the last improvement).
- **Joypad crash fix** (the Timer-view `is_checked` crash you hit): `Joypad.input` buttons are now always
  booleans (`src/core/Joypad.lua`), protecting every view — that was a pre-existing latent bug.

## What is NOT done (deliberately, needs your call / an in-mupen test)
- **In-mupen validation**: the emulator-facing wiring can't be tested off-mupen. Please run a real search
  on your romhack and confirm `tried` climbs and `niches` grows.
- **Not persisted to `.sws`**: an applied optimization still lives in memory for the session only.
- **Deferred research ideas** (from the Scattershot study, if you want to go further): facing-relative
  angle mutation (needs facing-yaw exposed), an automatic simulated-annealing schedule (you chose manual
  strength, so I left it manual), curiosity-weighted cell selection, and exposing a mid-run **checkpoint
  state** to the archive (Scattershot bins on intermediate states — this would multiply the archive's
  power). None are needed for a solid win; all are clean follow-ups.

## Files touched (none committed)
- `src/core/Bruteforce.lua` — archive, smarter removal, edge-nudge, windowed mutation, RNG seeding, richer summary.
- `src/views/Bruteforce.lua` — feeds end-state features to the archive; shows `niches:`.
- `src/core/Joypad.lua` — button normalization (crash fix).
- `src/views/SemanticWorkflow/Implementations/Sheet.lua` — optimization auto-invalidation (content signature).
- `src/core/Locales.lua`, `src/res/lang/en_US.lua`, `src/res/lang/fr_FR.lua` — `BRUTEFORCE_NICHES`.
- `tests/bruteforce_test.lua` — +33 tests for all of the above.

Design notes: `BRUTEFORCE_SEMANTIC_INTEGRATION.md` (integration) and `BRUTEFORCE_DESIGN.md` (base tool).
