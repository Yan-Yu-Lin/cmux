# Pixel scroll implementation notes

Current branch: `pixel-scroll-v0.65.0` in the `ghostty` submodule, based on
the Ghostty commit pinned by cmux `v0.65.0`, `324c0273`. It contains the
original 7 feature/fix commits, the current-Ghostty API migration commit, and
one Uniforms layout re-pin commit. The previous branch `pixel-scroll` (head
`3234ce204` on `f76c132e5`) is kept unchanged so the 0.64.22 Smooth build stays
reproducible.

## 2026-10-06 port to cmux v0.65.0

Rebased `f76c132e5..pixel-scroll` onto `324c0273` (109 upstream Ghostty
commits). Upstream had meanwhile added, in the same files, its own
**iOS-only** fractional scroll and render-inset machinery:

- `39ade10b6` — `Uniforms.scroll_offset`, `RenderState.pixel_offset`, one
  bottom overscan row (`RenderState.overscan_rows`), driven only by
  `ghostty_surface_scroll_to_row_pixel_if_revision`.
- `cd59106ad` / `e2258e898` — render top/bottom insets and their overscan
  bands (`RenderState.top_overscan_rows`, `requested_*_overscan_rows`). Row
  data index `i` is viewport row `i - top_overscan_rows`; cursor/selection
  stay viewport-relative.
- `5045df3f2` — offset-only changes mark the render state dirty.

Verified that cmux v0.65.0 calls those C APIs only from
`Packages/iOS/CmuxMobileTerminal` (`GhosttySurfaceView+LocalPixelScroll.swift`,
`ghostty_surface_set_render_insets`). On macOS `scroll_offset`,
`top_overscan_rows` and `overscan_rows` are therefore always zero, and our
overlay remains the only thing that moves the macOS grid. Arthur chose to port
the overlay as-is (not redesign on top of the iOS primitive); both mechanisms
are kept and made to coexist.

### Coexistence model

Two independent shifts, which simply add:

| | upstream (iOS) | cmux Smooth (macOS) |
|---|---|---|
| uniform | `scroll_offset` (+ `top_overscan_rows * cell_h`) | `pixel_scroll_offset_y` |
| buffer rows | `top_overscan_rows + rows + overscan_rows` | `+ 2` extra rows (one above everything, one below) |
| row_data index → buffer row | `i` | `i + 1` (`row_offset`) |
| viewport row → buffer row | `vy + top_overscan_rows` | `vy + top_overscan_rows + row_offset` |

`pixelScrollRows()` now returns false on iOS at comptime, so on iOS the
overlay is fully off and upstream renders exactly as it intends; on macOS
upstream's terms are zero. The combined formulas are still correct if both
were ever non-zero at once.

### Conflicts, per commit

- **`7cb3da950` renderer: shift the grid** — `generic.zig` (8 hunks),
  `shaders.metal` (3 hunks).
  - `updateFrame`: kept upstream's `requested_top/bottom_overscan_rows`
    requests *and* ours (`terminal_state.pixel_scroll`), now fed from
    `pixelScrollRows()` so iOS never builds extra rows.
  - `rebuildCells` sizing: `buffer_rows = state_rows (upstream: top band +
    viewport + bottom overscan) + pixelScrollExtraRowCount()`; the row loop
    walks all `state_rows` of row_data. Kept upstream's `top_overscan_px`
    folding into `scroll_offset`.
  - Row loop: `data_y` = row_data index, `y = data_y + row_offset` (buffer),
    `vy = data_y - top_overscan_rows` (viewport; out of range for band rows).
    All viewport-relative lookups inside `rebuildRow` (padding heuristic,
    shaper cursor row, link hover) use `vy`; upstream's
    `vp.y + top_overscan_rows != y` and `y - top_overscan_rows` link tests
    became `vp.y != vy` and `vy < state.rows` + `vy`, which are equivalent
    when our offset is zero.
  - Preedit: upstream changed `PreeditRange.y` to a row_data index. Our
    `range.y != vy` test became `range.y + pixelScrollRowOffset() != y`, and
    the preedit cell position stays `range.y + row_offset`.
  - Cursor: block-cursor uniform and `addCursor` grid position are
    `cursor_vp.y + top_overscan_rows + row_offset` (the caller passes the sum).
  - Images: upstream offsets placements by `images.top_overscan_rows` and
    translates them by `scroll_offset`. Our extra row above is the same kind
    of shift (images are also translated by `pixel_scroll_offset_y`, one cell
    at rest), so `images.top_overscan_rows = top_overscan_rows + row_offset`.
    **Behavior note:** the old fork did not add the extra row to image
    placements, so Kitty images sat one row too high under pixel-scroll; this
    port fixes that as a side effect. Not visually verified.
  - Shaders: bg fragment samples at `y + scroll_offset + pixel_scroll_offset_y`.
    Padding detection uses upstream's own test (sampled row outside the
    buffer) when our shift is off, and our on-screen test (with
    `scroll_offset` folded in) when it's on. Text vertex applies
    `scroll_offset`, then ours + `round()` only while ours is active, so the
    iOS fractional motion is not pixel-snapped. Image vertex subtracts both.
- **`841963078` test extra row population** — `render.zig`, append-only
  tests colliding with upstream's appended tests. Kept all of upstream's
  tests byte-identical and appended our 5 tests verbatim (a naive
  keep-both merge interleaved test bodies; verified by diffing every test
  body against both parents).
- **`79ee64d3b`, `4fce745f6`, `a43be7737`, `3234ce204`** — the pre-flight
  dry run predicted conflicts in `Surface.zig`, `generic.zig`, `size.zig` and
  `render.zig`, but after the resolution above they replayed cleanly.
  Hit-testing (`posToViewport` → `pixelScrollHitTestShift`) needs no change:
  upstream's insets don't touch the mouse coordinate space, and its
  `scroll_offset` is zero on macOS.
- **New `f8d5499d5` re-pin Uniforms layout** — upstream inserted
  `scroll_offset` after `min_contrast`, shifting later fields by 4 bytes, so
  the layout test failed (`expected 120, found 124`). Re-probed on-device by
  compiling the MSL struct and reading field addresses through a compute
  kernel: `scroll_offset` 120, `cursor_pos` 124, `cursor_color` 128,
  `bg_color` 132, `pixel_scroll_offset_y` 136, `bools` 140, size 144.

### Verification (port)

- `zig build -Demit-macos-app=false`: clean.
- Focused tests, all green: `pixel scroll` 88/88, `extra row` 78/78,
  `pixelScrollShift` 75/75, `Uniforms layout` 74/74, `overscan` 85/85
  (upstream's inset/overscan tests), `Size top_inset` 74/74,
  `Size.screenForGrid` 76/76. (Each filter run also includes the always-on
  tests, hence the totals.)
- `render` filter: 247/248; the one failure is
  `renderer.opengl.Frame.test.OpenGL acknowledges only after successful
  present and GPU completion`, which fails identically on pure upstream
  `324c0273` (checked in a temporary worktree) — pre-existing, unrelated.
- `xcrun metal -c shaders.metal`: compiles.
- Toolchain: the selected Xcode 27 (`/Applications/Xcode-27.0.0.app`) has no
  Metal Toolchain installed; cmux v0.65.0 pins Xcode 26 (`.xcode-version`),
  so all builds used `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  (Xcode 26.0, Metal Toolchain installed).

## 2026-08-15 upstream rebase

- Rebased all 7 pixel-scroll commits from `80d7fb35a` onto the exact Ghostty
  commit pinned by cmux `origin/main`, `f76c132e526f124fe4aaebd39f516751656844bc`.
  No feature commit was dropped or superseded upstream.
- The only textual conflict was in `src/renderer/generic.zig` around
  `rebuildCells`: upstream removed an obsolete commented timing probe at the
  same insertion point. The resolution keeps upstream's cleanup and the
  renderer-local extra-row buffer bookkeeping.
- Current Ghostty's `RenderState.Row` has a page-node generation `serial`.
  Extra pixel-scroll rows now initialize and publish the matching node serial
  beside each pin, preserving stale-node validation.
- Zig 0.16's `std.Io.Mutex` requires an I/O context. The cell-size reset path
  now uses `lockUncancelable(global.io())` and `unlock(global.io())`, matching
  current Ghostty, and the extra-row tests pass `testing.io` to
  `Terminal.init`.
- `zig build -Demit-macos-app=false` passed with Zig 0.16.0. Focused tests for
  `pixel scroll`, `extra row`, and the Metal `Uniforms` layout passed. The full
  aggregate test graph was attempted twice but was SIGKILLed with exit 137 on
  this machine; it reported no pixel-scroll test failure before termination.
- The ReleaseFast universal xcframework build passed with macOS arm64+x86_64,
  iOS arm64, and iOS arm64-simulator slices.

## Design decision: Option B (renderer-local extra rows)

Chosen, as the spec recommended. The evidence against Option A in this fork is
stronger than the spec anticipated: `RenderState.rows` is not just consumed by
the renderer and the render-grid export, it is **part of the libghostty-vt public
C API**. `src/terminal/c/render.zig:262` returns it directly for
`GHOSTTY_RENDER_STATE_ROWS`, and `:266` hands out `row_data` slices to C callers
through a row iterator. `src/terminal/formatter.zig` also asserts on exact
`state.rows` values in roughly 40 tests. Growing `rows` by 2 would have changed
an exported C API's meaning and broken those tests, on top of the consumers the
spec already listed.

Option B keeps `RenderState.rows` exactly as it is and adds the two rows in a
separate `ExtraRows` struct beside `row_data`. Every non-renderer consumer is
unaffected by construction, so acceptance criterion 4 (render-grid JSON
unchanged) holds trivially. Worth noting: `buildRenderGridJson` turned out not to
read `RenderState` at all — it walks the terminal screen directly — so it was
never at risk either way.

Population is opt-in via a `pixel_scroll` flag on `RenderState`, set by the
renderer from its derived config each frame, so libghostty-vt users and the
inspector pay nothing.

## Files touched

| File | What |
|---|---|
| `src/config/Config.zig` (~+13) | `pixel-scroll: bool = true` |
| `src/terminal/render.zig` (~+407) | `ExtraRows` struct, `updateExtraRows`, `endUpdate` style application, 5 tests |
| `src/Surface.zig` (~+379) | accumulator, `scrollPixelDelta` helper, reset sites, 6 tests |
| `src/renderer/State.zig` (~+13) | `Mouse.pixel_scroll_offset_y` |
| `src/renderer/generic.zig` (~+201) | grid sizing +2, y offsets, uniform computation, padding forcing |
| `src/renderer/metal/shaders.zig` (~+36) | `Uniforms.pixel_scroll_offset_y`, layout test |
| `src/renderer/shaders/shaders.metal` (~+77) | bg fragment, text vertex/fragment, image vertex |
| `src/renderer/opengl/shaders.zig`, `glsl/common.glsl` (~+10) | no-op field, layout parity only |

## How it works

1. **Surface** (`scrollCallback` → `applyPixelScroll` → `pixelScrollAccumulate`)
   accumulates the raw pixel delta. Whole cells become `scrollViewport` row
   deltas; the sub-row remainder is kept in `mouse.pixel_scroll_offset`,
   normalized to `(-cell_height, 0]`, and published (negated) to
   `renderer_state.mouse.pixel_scroll_offset_y`.

2. **RenderState.beginUpdate** additionally builds the row above and the row
   below the viewport into `extra_rows`. Absent rows (top of scrollback / bottom
   of screen) are marked with a null pin and render as background.

3. **Renderer** sizes the cell buffer to `state.rows + 2`, writes viewport row
   `y` at buffer row `y + 1`, writes the extra rows at `0` and `N+1`, and
   computes `uniforms.pixel_scroll_offset_y = max(round(cell_h - clamp(offset,
   -cell_h, cell_h)), 1)`.

4. **Shaders** shift everything up by that uniform. At rest it equals one cell
   height, so the top extra row sits just off screen and visible content lands
   exactly where it did before.

### Deviations from the spec, and why

- **The remainder's sign convention is fixed at `(-cell_height, 0]`**, not
  allowed to swing both ways. The renderer therefore always shifts in one
  direction and always fills the exposed band from the row *above* the viewport.
  This is what the reference does too, but the spec didn't say why; the reason is
  that a two-directional remainder would need the fill row to be chosen per
  frame, and the sign would flip every time the accumulator crossed zero.

- **The accumulator takes explicit `up`/`down` headroom** instead of consulting
  the screen. The reference calls `viewportIsBottom()` *after* scrolling and then
  retroactively zeroes the offset, which works but can't be unit tested and
  silently swallows scroll distance. Taking headroom as parameters (from
  `pages.scrollbar()`, which caches the viewport offset) makes the whole thing a
  pure function — that is what the 6 tests exercise.

- **Extra rows are rebuilt unconditionally, not dirty-tracked.** These rows sit
  outside the viewport, so their page-row dirty flag may already have been
  consumed and cleared by an earlier update while they were still inside it.
  Relying on it would leave stale content one row past the edge. `updateExtraRows`
  does keep a cheap early-out when neither the viewport pin nor the redraw flag
  changed. It also deliberately does **not** clear the page row's dirty flag,
  which belongs to the viewport loop.

- **`rebuildRow` now takes both `y` (buffer row) and `vy` (viewport row).** The
  spec said to "add +1 to every renderer-side y consumer", but roughly half the
  `y` uses inside `rebuildRow` are viewport-relative lookups (preedit range, link
  hover set, the shaper's cursor row, the padding heuristic) that must *not* be
  offset. Passing both makes which is which explicit at each site rather than
  leaving it to be inferred. The extra rows pass a deliberately out-of-range `vy`
  so none of those lookups can match.

- **Added a `Uniforms` layout test** (`src/renderer/metal/shaders.zig`). The Zig
  `extern struct` and the MSL struct are matched by raw memory layout with
  nothing in the build checking that they agree — a mismatch doesn't fail to
  compile, it silently feeds every shader garbage. I verified the new field's
  offsets against the actual Metal compiler (compiled a probe MSL struct and read
  the offsets back on-device) and pinned all 13 offsets in a test.

## Verification

- `zig build -Demit-macos-app=false`: clean.
- `zig build test`: **3180/3196 passed, 16 skipped, 0 failed.** Includes 12 new
  tests (6 accumulator, 5 extra-row, 1 uniform layout).
- ReleaseFast universal xcframework: **succeeded**, `macos/GhosttyKit.xcframework`
  produced with `macos-arm64_x86_64`, `ios-arm64`, `ios-arm64-simulator`.
- Render-grid JSON: unchanged by construction (Option B, and the export doesn't
  read `RenderState`).

### Environment issues hit (both pre-existing, not caused by this work)

- **The Metal toolchain was not installed on this machine.** Every build failed
  with `cannot execute tool 'metal'` — including at the base commit with my diff
  stashed. Fixed by running `xcodebuild -downloadComponent MetalToolchain` (~700
  MB). Worth knowing for any fresh machine.
- **GTK/OpenGL cannot be built here** (`gtk4`, `libadwaita-1`, `adw`, `gobject`
  missing). Verified identical failures at the base commit with the diff stashed.
  The OpenGL path is therefore **compile-verified only to the extent the macOS
  build covers it** — the `pixel_scroll_offset_y` field was added to both the
  OpenGL `Uniforms` and the GLSL `Globals` block to keep the std140 layout in
  sync, but that parity is unverified on a real GTK build. It is a no-op field
  there (always 0); the GLSL shaders implement no pixel scrolling, per the spec.

## Not done / known limitations

- **No on-device visual verification.** Everything here is verified by compile,
  unit test, and layout probe. The shader math (particularly the bg fragment's
  padding-vs-extra-row discrimination and the text fragment's clip band) has not
  been looked at running. This is the main thing to check when dogfooding: scroll
  slowly with a trackpad and watch the top and bottom edges for a sliver of the
  extra row leaking into the window padding.
- **Alternate screen, spring animation, per-cell offsets, `Thread.zig` timer** —
  all out of scope per the spec, all untouched.
- **Viewport jumps issued through the IO thread** (`scroll_page_up`,
  `scroll_page_down`, `scroll_page_fractional`, `scroll_page_lines`,
  `jump_to_prompt`, the `scroll_to_bottom` *binding*) do not reset the pixel
  offset, because they don't hold the renderer mutex at the call site. In
  practice the offset is sub-cell and the next scroll event re-normalizes it, so
  the visible effect is at most a few pixels of misalignment until then. The
  direct-call sites that *do* hold the lock (keystroke scroll-to-bottom in both
  paths, `scrollToBottom`, cell size change) all reset properly. Worth cleaning
  up if it's visible in practice.
- **`pixelScrollActive` requires scrollback to exist** (`total_rows > rows`), so
  a fresh shell with no history scrolls exactly as before. This matches the
  reference.

---

# Phase 1 follow-up: mouse selection misaligned by one row

On-device report: "selection isn't quite aligned with where the text actually
is", intermittently.

## Root cause — confirmed

Phase 1 taught the *renderer* about the sub-row offset but not the *hit-test*.
The renderer draws viewport row `y` at buffer row `y + 1` and shifts the whole
grid up by `pixel_scroll_offset_y` pixels, so in terminal space row `y` occupies

```
[(y + 1) * cell_h - shift, (y + 2) * cell_h - shift)
```

Inverting that gives `y = floor((t + shift - cell_h) / cell_h)`.
`Surface.posToViewport` computed the unshifted `floor(t / cell_h)`, so every
mouse-derived row was off by `shift - cell_h`, i.e. by exactly the sub-row
offset. Whenever the offset exceeded nothing at all, cells within that band
resolved to the row above or below the one drawn there.

This explains the "sometimes": the error is zero exactly when the offset is
zero, which is the case at the bottom of the scrollback, on the alternate
screen, with `pixel-scroll` off, and after every viewport jump (all of which
call `resetPixelScroll`). It only appears while resting partway into scrollback
after a trackpad scroll.

## Fix

The shift formula was duplicated in the renderer and would now have been
duplicated a third time in the hit-test, so it moved to one place:

| File:line | What |
|---|---|
| `src/renderer/size.zig:227` | new `pixelScrollShift(offset, cell_height)` — the single definition of the visual shift, with the phase-1 `@round`/`@max(…, 1)` behavior preserved verbatim |
| `src/renderer/generic.zig:2660` | `pixelScrollUniform` now calls it instead of recomputing |
| `src/Surface.zig:6923` | new `pixelScrollHitTestShift` — returns `shift - cell_h`, the correction to add to a surface-space y |
| `src/Surface.zig:6896` | `posToViewport` applies it |
| `src/Surface.zig:5587` | `mouseReport` applies it too (see below) |
| `src/renderer.zig:15` | `size` made `pub` so `Surface` can reach the helper |

`posToViewport` is the single chokepoint for everything the bug report covers:
click, drag, drag-autoscroll (`selectionScrollTick`), double-click word select,
triple-click line select, right-click word select, prompt clicks, quicklook
(`apprt/embedded.zig`), and cmd-hover link hit-testing (`linkAtPos`,
`mouseRefreshLinks`) all route through it. Verified by grep that nothing else
in `src/` or `macos/` calls it, and that no other consumer does its own
pixel→row math — with one exception.

**The exception is mouse reporting.** `input/mouse_encode.zig` converts pixels
to cells itself (`posToCell`), so it needed the same correction applied to the
position handed in. In practice this is almost always a no-op, because mouse
reporting being on makes `scrollCallback` take the reporting path before
`pixelScrollActive` is ever consulted, so the offset stays at whatever it was.
"Whatever it was" is the point: an offset left over from before the TUI enabled
reporting would otherwise misreport every subsequent event. Corrected for
symmetry rather than to fix an observed failure.

**No double-correction.** The renderer consumes
`renderer_state.mouse.pixel_scroll_offset_y` to build the uniform; the hit-test
reads the same field independently and inverts it. Neither reads the other's
output, and `posToViewport` results are never fed back into rendering geometry —
they become terminal pins, which are row-granular by definition.

## Why the at-rest case is unaffected

`pixelScrollHitTestShift` returns `0` on a zero offset via an explicit early
return, before any arithmetic. At rest `pixelScrollShift(0, h) == h` and the
correction would be `h - h == 0` anyway, so the early return is an optimization,
not a special case — but it does guarantee bit-for-bit identical behavior to
pre-phase-1 for every surface that has never pixel-scrolled. The test
`pixel scroll hit-testing is unchanged at rest` pins this across all 207 pixel
rows of a sample surface, comparing against the raw `Coordinate.convert` result.

## Test coverage

5 new tests in `src/renderer/size.zig`:

- 2 on `pixelScrollShift` itself: the at-rest identity, and the `@max(…, 1)`
  floor near `offset == cell_height` (which the shaders depend on to know the
  extra rows exist).
- **`pixel scroll hit-testing agrees with the drawn position`** — the real one.
  For all 20 sub-row offsets × all 10 rows, it computes where the renderer draws
  that row and asserts the first and last on-screen pixel of the band hit-tests
  back to it. This is a round-trip against the drawn geometry, not against a
  restatement of the fix.
- the at-rest regression test described above.
- one pinning the revealed sliver above row 0 to row 0, since viewport
  coordinates are unsigned and there is no row to name there.

The round-trip test was verified to genuinely fail against the uncorrected
conversion (`expected 0, found 1` — exactly the one-row misalignment reported)
rather than passing vacuously.

`zig build test`: **3185/3201 passed, 16 skipped, 0 failed** (+5 from phase 1's
3180). ReleaseFast universal xcframework rebuilt.

## Not verified

No on-device visual check — same caveat as phase 1. The math is verified by
round-trip against the renderer's own formula, which is now shared rather than
restated, so the two can no longer drift; but nobody has dragged a selection
while scrolled partway into scrollback on a running build.

---

# Phase 2 — animated TUI (alt-screen) scrolling

Branch `pixel-scroll`, 5 more commits on top of phase 1's 5 (`82ac3a26a`
back to `56061a6f2`).

## What it does

On the alternate screen, a scroll the user made with a wheel or trackpad
glides into place over ~150ms instead of snapping. A scroll the user made
with the keyboard (j/k, Ctrl-D, gg) snaps instantly and **cancels any
glide already in flight**. The primary screen is untouched.

## Files touched

| File | What |
|---|---|
| `src/terminal/Screen.zig` (+12) | `scroll_tracker: isize` |
| `src/terminal/Terminal.zig` (+13) | 5 tracker bumps in the region-scroll paths |
| `src/terminal/render.zig` (+241) | `scroll_jump_rows`, `scroll_region_top/bottom`, `last_scroll_tracker`, 6 tests |
| `src/renderer/animation.zig` (new, 526) | `Spring`, `scrollAction` gate, `wheel_recency_window_ns`, 11 tests |
| `src/renderer.zig` (+2) | export + test reference |
| `src/renderer/State.zig` (+17) | `Mouse.last_wheel_scroll: ?Instant` |
| `src/Surface.zig` (+26) | `recordWheelScroll`, called from 2 paths |
| `src/renderer/generic.zig` (+306) | spring state, `updateScrollAnimation` `:2792`, `stepScrollAnimation` `:2873`, `snapScrollAnimation` `:2913`, `scrollAnimationUniforms` `:2939`, `hasScrollAnimation` `:1221`, 4 snap sites |
| `src/renderer/Thread.zig` (+64/-20) | `drawTimerShouldRun` `:1019`, arm at `:1592`, disarm in `drawCallback` |
| `src/renderer/metal/shaders.zig` (+26) | 3 uniforms, layout test extended |
| `src/renderer/shaders/shaders.metal` (+81) | bg fragment, text vertex + fragment clip, image vertex |
| `src/renderer/opengl/shaders.zig`, `glsl/common.glsl` (+20) | no-op fields, layout parity only |
| `src/config/Config.zig` (+21) | `scroll-animation-duration`, `scroll-animation-bounciness` |

## How it works

1. **Jump detection.** `Screen.scroll_tracker` accumulates signed row
   shifts. Bumped in `insertLines` (+), `deleteLines` (-), `scrollUp`'s
   scrollback fast path (-), and both region-scroll branches of `index`
   (-). `reverseIndex` and `scrollDown` are covered transitively through
   `insertLines`; `scrollUp`'s margin path through `deleteLines`.
   `RenderState.beginUpdate` publishes the wrapping difference since the
   previous update as `scroll_jump_rows`, plus the region bounds.

2. **Wheel gate.** `Surface.recordWheelScroll` stamps
   `renderer_state.mouse.last_wheel_scroll` under the mutex, from both
   the mouse-reporting path and the alternate-scroll arrow-key path.
   `animation.scrollAction` decides `glide` / `snap` / `none` from the
   jump, the region-change flag, the screen, the config, and whether a
   wheel event landed within 150ms.

3. **Spring.** `updateScrollAnimation` (in `updateFrame`, inside the draw
   mutex, before `rebuildCells`) folds the jump in: `glide` adds to
   `spring.position`, `snap` resets. `stepScrollAnimation` (in
   `drawFrame`) advances it. The offset is in ROWS; the uniform converts
   to pixels and rounds.

4. **Frame driving.** `Renderer.hasScrollAnimation()` →
   `Thread.drawTimerShouldRun()` → the existing `draw_h` timer.
   `renderCallback` arms after each update; `drawCallback` rechecks after
   each draw and disarms.

5. **Shaders.** `tui_scroll_offset_y` shifts rows inside the region back
   toward their pre-jump position and decays to zero. Bounds are in cell
   BUFFER rows (phase 1's `+1`), so the shaders don't re-derive the extra
   row convention.

## Deviations from the spec, and why

- **`hasAnimations` is not the frame-driving hook; a new
  `hasScrollAnimation` is.** The spec said to piggyback on the
  custom-shader mechanism, and the timer is shared, but the *predicate*
  had to be separate. `Thread.syncDrawTimer` gates `hasAnimations` behind
  `custom-shader-animation`, which is a preference about decorative
  shaders — a user who sets it to `false` would have silently lost scroll
  animation. A glide needs no such gate because it is self-limiting.

- **The spring steps in `drawFrame`, not `updateFrame`.** The spec put
  the whole thing in `updateFrame`. That only runs when the terminal
  state changes, and a glide has to keep moving after the application has
  gone quiet — which is most of the animation. Accumulation stays in
  `updateFrame` (it needs the render state); only the time step moved.

- **`syncDrawTimer` was split into `drawTimerShouldRun` + the arm.** The
  original fused arm and disarm into one `skip:` block called from a
  handful of lifecycle points, so it could arm for a glide but never
  notice it had ended. `drawCallback` now rechecks the predicate after
  each draw. This is what makes "zero idle cost" true rather than
  approximate.
  *This does not touch the bounded-drain invariants documented in
  `docs/ghostty-fork.md`:* the mailbox snapshot loop, the post-render
  re-wake, and external-path continuation consumption are all unchanged.
  The one added call site is `renderCallback` **after** `drawFrame`,
  which mirrors the existing `.change_config` precedent at `:1141`.

- **Occlusion snaps the spring** (`setVisible(false)`). Not in the spec's
  reset list. An invisible surface skips its draws entirely
  (`Thread.drawFrame`'s `flags.visible` early return), so a glide left in
  flight would never reach rest: the spring would stay displaced, hold
  the draw timer armed, and tick at 120Hz producing nothing. This was the
  only real hole in the idle-cost guarantee.

- **A screen switch is folded into the region-change test** rather than
  being a separate reset. `RenderState` already reports zero jump across
  a switch (independent per-screen counters), so the only thing left to
  do was drop the offset, which the region-change branch already does.

- **The `none` action exists** and is not the same as `snap`. Most frames
  carry no jump; snapping them would kill every animation after its first
  frame. The reference implementation gets this right implicitly by
  guarding on `@abs(jump) >= threshold`; making it an explicit third case
  is what let the gate be unit tested.

- **The jump is not thresholded.** The reference uses
  `@abs(scroll_jump_total) >= 1.0`. Our tracker is integral, so any
  non-zero jump is already at least one row and the threshold is dead
  code.

- **Images glide but are not clipped** at the region boundary. An image
  spans many rows, so the region test is about where it starts, and the
  image fragment shader has no bounds to clip against. Kitty graphics
  inside an animating alt-screen scroll region are rare enough to accept
  this; documented in the shader.

- **`CellTextVertexOut` gained an `in_scroll_region` flat bool.** The
  fragment stage needs to know whether to clip, and unlike the
  reference's shader ours doesn't already carry `grid_pos` through to the
  fragment. Passing one flat bool is cheaper than passing the position.

- **OpenGL's region bounds are `u32`, not `u16`.** std140 has no 16-bit
  integer type. The OpenGL `Uniforms` is matched against the GLSL block,
  not against the Metal one, so the two can differ here.

## Verification

- `zig build -Demit-macos-app=false`: clean.
- `zig build test`: **3199/3215 passed, 16 skipped, 0 failed.** 19 new
  tests (11 animation, 6 jump-tracker, layout test extended, plus the
  two-piece integration tests for the glide-then-keypress and
  flick-stacking sequences).
- Metal uniform offsets re-probed on-device (compiled the MSL struct,
  read `&field - base` back through a compute kernel). Struct grew
  144 → 160 bytes; `tui_scroll_offset_y` at 136, bounds at 140/142, bools
  moved 136 → 144. All pinned.
- `xcrun metal -c shaders.metal`: compiles.
- ReleaseFast universal xcframework: **succeeded**, all three slices
  (`macos-arm64_x86_64`, `ios-arm64`, `ios-arm64-simulator`).

## Not done / known limitations

- **No on-device visual verification.** Same caveat as phase 1, and it
  matters more here: the text fragment's region clip band and the bg
  fragment's clamp are the two things most likely to be subtly wrong, and
  neither is reachable from a unit test. What to watch when dogfooding:
  scroll nvim with a trackpad and check that (a) the statusline never
  moves, (b) no sliver of gliding text draws over it, (c) `j` and `k` are
  as instant as they are today.
- **Repaints without a region scroll don't animate.** Terminal scroll
  regions are full-width, so a TUI with vertical splits that repaints
  each pane rather than scrolling a region produces no jump to detect.
  This falls back to today's snap behavior, which is correct, just not
  animated. Same for any application that redraws instead of scrolling.
- **The gate is per-surface, not per-application.** If an application
  scrolls its region on its own (a `tail -f`-style live update) within
  150ms of a user wheel event, that scroll animates too. Harmless in
  practice — it's a scroll either way — but worth knowing.
- **`scroll-animation-bounciness` is untested visually.** The zeta
  mapping (`1 - bounciness * 0.6`) is the reference's, and the spring
  handles zeta < 1 correctly by construction, but nobody has looked at an
  underdamped glide running. Default is 0, i.e. critically damped.
- **OpenGL parity is unverified**, same as phase 1: GTK can't be built on
  this machine. The three new fields are no-ops there.

## Post-dogfood fix: inverted displacement (`8ffd66897`)

First on-device dogfood: "it moves the entire window and moves it back,
instead of smooth scrolling."

**Cause.** The spring was displaced BY the jump (`position += jump`)
instead of against it. By the time the renderer observes a jump the grid
already holds the post-scroll content; what the user last saw is the
pre-scroll frame, so the spring has to start at the offset that UNDOES
the jump and decay to zero. Displacing the same way instead shifts
content further along its own direction of travel — doubling the visible
jump — and then springs back. That is exactly a lurch away and a rebound.

**Why it wasn't caught.** Two reasons, both worth recording:

1. **The reference implementation is wrong here, or at least
   self-contradictory.** `generic.zig:1732` comments "scroll_jump_total
   > 0 = content moved up", but its own `Terminal.zig:1558` adds on
   `insertLines`, which moves content DOWN. I had copied the accumulation
   verbatim on the strength of the comment. The sign is now derived from
   the shaders instead, where screen-space +Y is down and the grid shift
   subtracts — a source that can't disagree with itself.
2. **The two integration tests baked the sign into their literals**
   (`spring.position += -3`), so they asserted the behavior they were
   given rather than the behavior required, and passed either way.

**Fix.** `animation.springDisplacement(jump_rows) = -jump_rows`, with the
derivation in its doc comment. The integration tests now route through it
and additionally assert the offset never crosses zero, which is the
property a rebound violates. Verified the new test genuinely fails
against the old sign (`expected 3, found -3`) rather than passing
vacuously.

**Not the cause:** region-bounds indexing was checked and is correct. The
`+1` extra-row adjustment matches phase 1's convention, and for nvim's
usual full-screen region the clip band resolves to exactly
`grid_padding.x` at rest. "The entire window" moving was the doubled jump
of a full-height region, not an unrestricted shift.

- `zig build test` after the fix: **3201/3217 passed, 16 skipped, 0
  failed** (+2 tests).
- ReleaseFast universal xcframework: rebuilt, all three slices.
