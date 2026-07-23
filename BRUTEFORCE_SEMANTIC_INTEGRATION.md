# Bruteforce ↔ Semantic Workflow integration — design

> Companion to `BRUTEFORCE_DESIGN.md`. Records the approved design for wiring the frame-reduction
> bruteforcer into the Semantic Workflow. NOT committed (branch `feat/bruteforce`, never push).

## Goal (user's words)

> "Une sheet = une action. Une fois qu'on a fini l'action (la sheet), on bruteforce pour voir si on
> a rien perdu, comme ça on peut passer à la prochaine action."

Sheets are kept **short** on purpose (one action = one small sheet), so bruteforcing a whole sheet
is cheap. The bruteforce is a **gate**: gain 0 = optimal, green light to move on; gain N = you left
N frames on the table.

## Decisions

- **Unit = the whole Sheet.** Start = the sheet's start savestate; goal = the Mario action + position
  at the sheet's end (Mario is already there right after the sheet plays).
- **On a gain: report + optional Apply.** Apply propagates the gain down the chain.
- **Apply mechanism = optimized override track on the sheet (approach A).** The bruteforced result is
  raw `.joy` frames — exactly what `Sheet:evaluate_frame()` already yields per frame. So we store the
  optimized frames on the sheet and, when `applied`, `evaluate_frame` yields them (as **manual** TAS
  states: `movement_mode = manual`, `manual_joystick_x/y` = recorded stick, buttons from `joy`) instead
  of the semantic sections. Because sheets chain by **re-running** the base sheet to produce the next
  sheet's start savestate, an applied sheet automatically re-runs its *optimized* frames → the next
  sheet starts from the faster state. **Zero change to the chaining logic.** The semantic content is
  preserved and the track is reversible (un-apply).

## Pieces (respecting the platform split)

- **Pure, tested** (`src/core/Bruteforce.lua`): `Bruteforce.to_overrides(frames, count, tas_factory,
  manual_mode)` — wraps raw bruteforce frames into semantic override objects `{tas_state, joy}`.
  Dependencies (NewTASState, MovementModes.manual) are **injected** so it unit-tests off-mupen.
- **Emulator-facing** (not unit-tested, like the rest of the driver):
  - `BruteforceDriver.start_for_sheet(sheet)` (`src/views/Bruteforce.lua`): start = `sheet._savestate`,
    goal = `Memory.current` (Mario at the sheet's end), baseline captured by replaying the sheet.
  - Phase-aware **semantic suppression**: `CurrentSemanticWorkflowOverride()` returns nil while the
    driver is active AND not in the `capture` phase — so the semantic sheet drives the baseline
    capture but never fights the driver (or pauses emu) during the search.
  - Optimized playback branch in `Sheet:evaluate_frame()` + `_opt_index` in the counter reset.
  - Per-sheet **bruteforce button + gain badge** in `ProjectTab` (the `action` icon).

## Data flow

```
[sheet._savestate] --capture(replay sheet)--> baseline + goal(end action+pos)
      --BruteforceDriver(strength, budget)--> best = raw frames
      --Apply--> sheet.optimized = { inputs = to_overrides(best), gain, applied = true }
      --evaluate_frame yields optimized frames--> chain propagates the gain automatically
```

## Invalidation (known limitation of this increment)

Editing the semantic sheet after applying should mark the optimized track stale. This increment
exposes an explicit un-apply (click the button again) rather than auto-invalidating on every edit
site; auto-invalidation on edit is a follow-up.

## Testing

- Pure: `Bruteforce.to_overrides` (frame count, manual mode set, stick copied, buttons preserved).
- Emulator-facing: manual in-mupen test (same as the existing driver), on the current romhack.
