# Bruteforce — nocturnal improvements (read me when you wake up)

Everything below was built while you slept. **Nothing is committed or pushed** (branch `feat/bruteforce`).
All pure logic is unit-tested: `lua tests/bruteforce_test.lua` → **193 passed, 0 failed** (was 127).
The sheet-side wiring is verified headlessly (22 checks) with the real Sheet code.

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
