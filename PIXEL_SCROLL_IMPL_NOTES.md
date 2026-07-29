# Pixel scroll implementation notes

Branch `pixel-scroll` in the `ghostty` submodule, 4 commits on top of `80d7fb35a`.

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
