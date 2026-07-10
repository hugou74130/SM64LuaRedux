# Auto-Route

Auto-Route adds a new movement mode — **Target Point** — that steers Mario
straight toward a world coordinate instead of a fixed angle.

While the classic *Match Angle* mode holds a single angle forever, Target Point
recomputes the optimal angle **every frame** from Mario's current position to the
target. As Mario moves, the heading updates automatically, so he curves in and
converges on the spot.

## How it works

Each frame, the engine computes the world yaw from Mario `(x, z)` to the target
`(x, z)` using SM64's `atan2s` convention:

```
goal_yaw = atan2s(target_z - mario_z, target_x - mario_x)
```

That yaw is fed into the existing angle optimizer (the same binary search over
the effective-angle table used by every other mode), then through the magnitude
scaler. So Target Point benefits from all of the tool's existing precision — it
just supplies a live goal angle instead of a static one.

## Usage

1. Open the **Auto-Route** tab.
2. Walk (or place) Mario where you want the target, then press
   **Set Target To Current Position**. You can also type the coordinates into the
   `X` / `Z` spinners.
3. Enable **Route To Target**. Mario now heads toward the coordinate.
4. Optionally set a **Stop dist**: once Mario is within that many units of the
   target, the stick is released so he coasts instead of overshooting. `0`
   disables this (Mario steers indefinitely).

Hotkey: `Ctrl+5` toggles the Target Point mode (matching `Ctrl+1..4` for the
other movement modes).

### Invert 180°

`atan2s` follows the game's own angle convention, so steering should be correct
out of the box. If, on a given setup, Mario runs directly *away* from the target,
tick **Invert 180°** to flip the goal angle. (A 90° error instead would indicate
the target X/Z were entered swapped.)

## Live readout

The tab shows, in real time:

- **Distance** — horizontal (XZ) distance from Mario to the target.
- **Angle to target** — the goal yaw (respecting Invert), formatted per your
  angle-unit setting.
- Mario's current **X / Z**.
- A **status** line: off / routing / arrived.

## Notes and limits

- Target Point drives the analog stick only. It does not press A/B/Z or perform
  jumps — combine it with the Semantic Workflow or manual button inputs for
  tricks that need buttons.
- It steers toward the point in a straight line; it is not a pathfinder and will
  happily walk Mario into a wall or off a ledge if that is the straight-line
  direction. Use **Stop dist** and short segments for control.
- Speed-target (`.99`) straining and arctan straining are gated to the yaw/angle
  modes and do not fight Target Point; magnitude capping still applies, so you
  can throttle approach speed with the magnitude setting on the TAS tab.
