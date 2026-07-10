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

Hotkeys (all reassignable in Settings → Hotkeys):

- `Ctrl+5` toggles Target Point mode (matching `Ctrl+1..4` for the other modes).
- `Ctrl+6` sets the single-point target to Mario's current position.
- `Ctrl+7` appends a waypoint at Mario's current position.
- `Ctrl+8` jumps the active waypoint to the one nearest Mario.

## Waypoint paths

Instead of a single point, you can chain a route:

1. Walk Mario to each spot in order and press **Add Waypoint** at each one.
2. Enable **Route To Target**. Mario heads to waypoint 1, and once he is within
   the reach radius he automatically advances to waypoint 2, then 3, and so on.
3. **Loop path** wraps back to waypoint 1 after the last one (useful for grinding
   a circuit); with it off, Mario stops (stick released) at the final waypoint.
4. **Clear** empties the path and returns to single-point mode.

The reach radius for advancing between waypoints is the **Stop dist** value, or a
small default (25 units) when Stop dist is 0. The `Waypoint i/N` readout shows
progress. When any waypoints exist they take priority over the single X/Z point.

### Managing a path

- **Remove Last** deletes the most recently added waypoint.
- **Nearest** jumps the active index to the waypoint closest to Mario — handy
  after a savestate load to resync the route to where he actually is.
- **Save Route** / **Load Route** write and read the path as JSON in
  `route.json` (next to the script), so you can keep and share routes. Malformed
  files are rejected and non-numeric entries are dropped on load.
- The **Path** readout shows remaining length (Mario → current waypoint → end)
  over the total path length.

## Editing a path

The **Edit Waypoints** section selects a waypoint with the spinner and shows its
coordinates. From there:

- the up/down arrows reorder the selected waypoint,
- **Del** removes it,
- **Insert** inserts Mario's current position right after the selection,
- **Set Active** makes the selected waypoint the one Mario is currently routing to.

## Importing coordinates

**Import from Clipboard** parses coordinates copied from another tool (for
example STROOP's position readout) into a waypoint path. Each line is scanned for
numbers: a line with three or more becomes `X, Y, Z` (Y ignored), a line with two
becomes `X, Z`, and anything else is skipped. Separators (spaces, commas,
semicolons, tabs, parentheses) are all tolerated, so pasting a block of positions
generally just works.

## Overlay

With the **World Visualizer** enabled (Tools tab) and **Overlay** ticked on the
Auto-Route tab, the route is drawn in the game world: yellow segments connect the
waypoints, a green line runs from Mario to the active target, and each waypoint is
marked (the active one in green). The overlay uses the World Visualizer's camera
projection, so it only shows while that overlay is on.

## Extras

- **ETA** — the readout estimates how many frames Mario needs to reach the active
  target at his current horizontal speed (`distance / h_speed`), or
  `unreachable` when he is stopped.
- **VarWatch variables** — `dist_to_target` and `angle_to_target` are available in
  the VarWatch settings (hidden by default); enable them to show target distance
  and heading in the main variable list and overlay.

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

## Tests

The geometry and route logic have an emulator-free unit test. From the repo root:

```
bash test/run.sh
```

This byte-compiles every Lua file (catching syntax errors) and runs
`test/autoroute_geometry_test.lua`. The same checks run in CI on push via
`.github/workflows/autoroute-tests.yml`.

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
