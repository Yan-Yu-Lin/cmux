# Pixel-scroll (smooth scrolling) implementation spec — cmux ghostty fork

## Goal

Port Neovide-style pixel-perfect smooth scrolling for the **primary screen scrollback** into
the ghostty submodule at `~/20-29-Development/21-Active-Projects/cmux-smooth/ghostty`
(manaflow-ai/ghostty fork, currently at `80d7fb35a`, detached HEAD — create branch
`pixel-scroll` first).

A reference implementation exists at `/tmp/ghostty-pixel-scroll` (parkers0405/ghostty-pixel-scroll,
based on a ~Jan 2026 upstream). **Do NOT port its diff wholesale** — it is entangled with a Neovim
GUI, collab cursors, and panel features we do not want. Reimplement only the terminal-mode
pixel scroll mechanism, using the reference for the shader math and edge-case handling.

## Scope

IN:
- Primary-screen scrollback smooth scrolling (trackpad precision AND discrete wheel).
- `pixel-scroll` config option, **default `true`** (so no config change is needed; the user's
  stock Ghostty won't see this key).
- Metal shader path (this is for cmux on macOS). Keep OpenGL/GTK compiling (guard with
  no-op defaults) but don't invest in it.

OUT (explicitly do not implement):
- Spring animation / `scroll-animation-duration` / bounciness (reference fork disables the
  spring on primary screen anyway — smoothness comes purely from sub-line accumulation).
- Alternate-screen (TUI) smooth scrolling. Alt screen keeps current line-based behavior.
- Per-cell offsets (`CellText.pixel_offset_y`, `CellBg` struct change) — reference only uses
  them for its nvim-gui; terminal mode passes 0. Skip entirely.
- `renderer/Thread.zig` timer changes — no animation means no timer needed. Do not add a
  draw loop (cmux CLAUDE.md forbids app-level display links; renderer wakeups on scroll
  events suffice since every scroll event calls `queueRender`).

## Mechanism (from reference, verified)

1. **Accumulate pixels, not lines** — in `Surface.scrollCallback`, when pixel scroll is active,
   skip the line-quantizing path. Accumulate `mouse.pixel_scroll_offset: f64`. Each time it
   crosses ±cell_height, call `terminal.scrollViewport(.{.delta = ±1})` and keep the remainder.
   Snap the remainder to 0 when the viewport is at bottom (`viewportIsBottom()`) or top
   (`pages.viewport == .top`). Publish remainder to renderer state:
   `renderer_state.mouse.pixel_scroll_offset_y = -offset` (range (0, cell_h]).
   Reference: `/tmp/ghostty-pixel-scroll/src/Surface.zig:4880-4958`.

2. **Render one extra row above and below the viewport** so mid-shift has content to show.
   Reference does `RenderState.rows = pages.rows + 2` with row 0 = row above viewport
   (walk `viewport_pin` up, crossing page boundary via `node.prev`), row N+1 = row below
   (`pages.getBottomRight(.viewport)` + 1). Reference: `/tmp/ghostty-pixel-scroll/src/terminal/render.zig:387-460`.
   **See "Design decision: extra rows" below — do not blindly copy this.**

3. **Uniform shift on the GPU** — add `pixel_scroll_offset_y: f32` to the shader `Uniforms`.
   At rest it equals `cell_height` (hides the top extra row). While scrolling it varies in
   `[0, 2*cell_h]`: renderer computes
   `clamped = clamp(offset_from_state, -cell_h, cell_h); uniform = max(round(cell_h - clamped), 1.0)`.
   The `max(...,1.0)` matters: shaders infer "extra rows active" from `uniform > 0`.
   Reference: `/tmp/ghostty-pixel-scroll/src/renderer/generic.zig:4100-4140`.

4. **Shader edits** (reference `/tmp/ghostty-pixel-scroll/src/renderer/shaders/shaders.metal`,
   fully implemented there for Metal — transplant the logic):
   - `Uniforms` struct: add the float (`:28` in reference). Keep Zig `extern struct` and MSL
     struct field order/alignment in sync (`src/renderer/metal/shaders.zig:192` in our fork).
   - `cell_text_vertex`: `cell_pos.y -= pixel_scroll_offset_y` then round to whole pixels
     (reference ~`:901`).
   - `cell_bg_fragment`: shift sampling `+ pixel_scroll_offset_y`; when extra rows active,
     treat shifted rows outside `[1, grid_size.y-2]` as padding and clamp color sampling to
     the visible edge rows (reference `:504-540`).
   - `cell_text_fragment`: clip glyphs that stray into the extra-row bands
     (reference `:1100-1112`, `text_has_extra_rows`).
   - `image_vertex`: `image_pos.y -= pixel_scroll_offset_y` (reference `:1272`).
   - GLSL mirrors exist in reference `src/renderer/shaders/glsl/` if needed for the
     OpenGL build to keep compiling — but a no-op (uniform always 0 / not added) is fine
     for GTK as long as it compiles.

5. **Padding extend** — with extra rows, bottom/top padding would sample the hidden rows.
   Reference forces `uniforms.padding_extend` all-true when pixel_scroll is on
   (`generic.zig:5285` in reference). Mirror that (our fork: `padding_extend` logic in
   `generic.zig` around the rebuild path, see `:2616-2700`).

## Our fork's current geography (verified against 80d7fb35a)

- `src/Surface.zig:5133` — `scrollCallback`. Current quantizing accumulator at `:5148-5203`
  (`pending_scroll_y`). The viewport scroll happens at `:5301-5306`. Mouse-reporting and
  alt-screen-arrow-keys branches at `:5236-5299` must stay line-based (return before the
  pixel path, and reset the pixel offset).
- `src/Surface.zig:361` — `Mouse` struct (surface-local), add `pixel_scroll_offset: f64 = 0`.
- `src/renderer/State.zig:106` — renderer-shared `Mouse` struct: add
  `pixel_scroll_offset_y: f32 = 0`.
- `src/terminal/render.zig:350` — `RenderState.beginUpdate` (two-phase since upstream
  refactor; `update()` = begin+end). Viewport rows built by a **page-chunk iterator** loop at
  `:508-613` (`viewport_pin.pageIterator(.right_down, null)`), not a per-row loop. Cursor
  viewport position is computed inside this loop (`:527-543`).
- `src/renderer/generic.zig:1253` — `updateFrame`; critical section `:1297-1447` extracts data
  under the terminal lock into a `Critical` struct — add the mouse pixel offset there
  (reference does `self.scroll_pixel_offset = critical.mouse.pixel_scroll_offset_y` at its
  `:1811`).
- `src/renderer/generic.zig:2616-2627` — grid sizing from `state.rows` and
  `uniforms.grid_size`.
- `src/renderer/metal/shaders.zig:192` — `Uniforms extern struct`.
- `src/renderer/shaders/shaders.metal:12` — MSL `Uniforms`; entry points:
  `cell_bg_fragment:451`, `cell_text_vertex:556`, `cell_text_fragment:678`, `image_vertex:788`.
- Config: `src/config/Config.zig` — add `@"pixel-scroll": bool = true` following the pattern
  of a nearby bool option (e.g. `mouse-hide-while-typing`). Plumb into surface DerivedConfig
  AND renderer DerivedConfig (grep `mouse_scroll_multiplier` for surface plumbing pattern).

## Design decision: extra rows (IMPORTANT — read before coding)

The reference resizes `RenderState.rows = pages.rows + 2` globally. In OUR fork that is
riskier because `RenderState` has non-renderer consumers, most critically
`src/apprt/embedded.zig:3546 buildRenderGridJson` (iOS/process-mirror render-grid export —
cmux ships features on this; its row count and cursor `viewport` coordinates must NOT change),
plus `renderer/link.zig`, `renderer/Overlay.zig`, `renderer/cell.zig`, keyboard copy-mode
selection code.

Two acceptable designs — evaluate both in code before committing, pick ONE:

**Option A (faithful):** `rows = pages.rows + 2` inside `RenderState`, viewport occupies
indices 1..N, then fix EVERY consumer: cursor.viewport y (+1 producer-side or consumer-side —
pick one convention and audit all readers), selection bounds, link/hover row mapping,
copy-mode, and make `buildRenderGridJson` skip the first/last rows and subtract 1 from
cursor y so the exported JSON is byte-identical to today. High blast radius; only choose it
if Option B turns out uglier in practice.

**Option B (renderer-local, recommended):** leave `RenderState.rows` = viewport rows
untouched. Add two *side* fields to `RenderState` (e.g. `extra_row_top: RowData`-equivalent +
`extra_row_bottom`, or a small dedicated struct reusing the row-build machinery), populated in
`beginUpdate` only when a new `pixel_scroll` flag is set on the state (set it from the
renderer's derived config via the existing state plumbing, or simplest: always populate —
two rows of copy cost is negligible). In `generic.zig`, size the cell GPU grid to
`state.rows + 2`, write viewport rows at `y+1`, write the side rows at 0 and N+1, and add +1
to every renderer-side y consumer (`uniforms.cursor_pos`, preedit, selection highlight cells,
etc. — grep for writes to cell y coordinates in `rebuildCells`). All exports and non-renderer
consumers stay untouched by construction.

For building the extra rows in `beginUpdate`: row above = walk `viewport_pin` up one row
(if `viewport_pin.y > 0` use same node y-1, else `node.prev`'s last row; if none exists —
top of scrollback — mark the extra row empty). Row below = pin one past
`pages.getBottomRight(.viewport)`; empty if at end. An empty extra row must render as
background color (cells empty), never garbage.

## Cursor caveat

With everything shifted by the uniform, the cursor rectangle (drawn from
`uniforms.cursor_pos`, a grid coordinate) shifts with the grid — that's correct
(cursor sits in content). Verify cursor renders at the right place at rest
(offset = cell_h ⇒ net shift 0 for visible content, i.e. row y+1 lands where row y used to).
Same check for: selection highlight, search-match highlights, IME preedit overlay,
`keyboard copy-mode` cursor (fork-specific feature — grep `copy_mode` in generic.zig),
and hover-link underlines. Any of these that renders via cell y-coordinates gets the same +1;
anything that renders via pixel coordinates computed from grid y needs the same treatment.
The cmux fork also has custom cursor-geometry callbacks (`cursor geometry` in
docs/ghostty-fork.md) — check `ghostty_surface_cursor_*` exports in embedded.zig still report
viewport-relative (unshifted) coordinates.

## Reset/edge cases (all must be handled; reference handles most)

- Screen switch (primary ⇄ alternate): zero the offset + uniform.
- Mouse reporting active / alt-screen: line-based path, zero the offset.
- `scroll_to_bottom` on keystroke (`Surface.zig:4532`) and any other `scrollViewport(.bottom/.top)`
  call sites (`:6715`, `:7976`): zero the offset.
- Font size / cell height change, resize: zero the offset (stale pixel remainder would
  misalign).
- No scrollback history yet (`total_rows <= rows`): pixel path inactive, offset 0.
- Uniform must never exceed `2*cell_h` nor drop below 1.0 while feature active.

## Toolchain / build / verify

- Zig: MUST use `/opt/homebrew/opt/zig@0.15/bin/zig` (0.15.2). The PATH `zig` is 0.16 and
  the build hard-fails on version mismatch. Export
  `PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH"` in every build shell.
- Fast compile check while iterating (in `ghostty/`):
  `zig build -Demit-macos-app=false`
- Zig tests: `zig build test -Dtest-filter=<name>` — add at least one test for the
  accumulator math (cross-boundary, snap-at-bottom, snap-at-top) following existing test
  style in Surface.zig or a small new file; and one for extra-row population in render.zig
  (see existing RenderState tests at the bottom of render.zig for the pattern).
- Full xcframework (only when code is done):
  `zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast`
  (takes many minutes; do it once at the end).
- Do NOT touch the parent cmux repo in this task (no Swift changes needed — cmux already
  forwards precise deltas via `ghostty_surface_mouse_scroll`). Do not commit the submodule
  pointer in the parent.
- Commit on the `pixel-scroll` branch in the ghostty submodule with clear messages.
  NEVER push. NEVER create PRs/issues (repo rule).
- The ghostty repo's own CLAUDE.md applies inside the submodule.

## Acceptance

1. `zig build -Demit-macos-app=false` clean.
2. New unit tests pass via `-Dtest-filter`.
3. Existing test suite: run `zig build test` once at the end; pre-existing failures (if any)
   must be shown to be pre-existing by stashing your diff and re-running the same filter.
4. Render-grid JSON export unchanged for a given screen (Option B guarantees; Option A must
   prove — there are render-grid tests, grep `render_grid` / `buildRenderGridJson` tests in
   embedded.zig / tests dirs).
5. Final ReleaseFast xcframework build succeeds.
6. Write a summary of every file touched + line ranges + the option (A/B) chosen and why,
   plus any known limitations, to `~/20-29-Development/21-Active-Projects/cmux-smooth/PIXEL_SCROLL_IMPL_NOTES.md`.
