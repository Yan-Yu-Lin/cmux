# Phase 2 spec — Animated TUI (alt-screen) smooth scrolling

## Context

Phase 1 (DONE, branch `pixel-scroll`, 5 commits on top of 80d7fb35a) added pixel-perfect
smooth scrolling for the primary-screen scrollback in the ghostty submodule at
`~/20-29-Development/21-Active-Projects/cmux-smooth/ghostty`. Read
`PIXEL_SCROLL_IMPL_NOTES.md` (same dir as this file) to understand what exists: the
`ExtraRows` render-state struct, `pixel_scroll_offset_y` state/uniform plumbing, the
Metal/GLSL uniform layout test, and the deviations from the original spec.

Phase 2 adds smooth scrolling for **alternate-screen TUI apps** (nvim, less, htop...).
The user's hard requirement: **only wheel/trackpad scrolls animate; keyboard-driven
scrolling (j/k, Ctrl-d, gg, etc.) must stay instant line-by-line, exactly as today.**

Reference implementation: /tmp/ghostty-pixel-scroll (same caveats as phase 1: 6-months-old
base, entangled with nvim-gui features — reimplement, don't port). Relevant reference parts:
- `src/animation.zig` — `Spring` (critically damped, analytic update) ~70 lines. Copy this
  nearly verbatim (drop Spring2D/ScrollAnimation/corner cursor).
- `src/terminal/Screen.zig` + `Terminal.zig` — `scroll_tracker: isize` counter bumped in
  scroll-region scroll paths (grep `scroll_tracker`).
- `src/terminal/render.zig:401-430` — `scroll_jump_output` computed from tracker diff;
  `scroll_region_top/bottom` captured into render state.
- `src/renderer/generic.zig` — `tui_scroll_spring` state, accumulation
  (`:1719-1743`: reset spring when region bounds change; accumulate
  `spring.position += scroll_jump_total` for stacking), uniform computation
  (`:4116-4125`: alt screen sets `pixel_scroll_offset_y = cell_h` fixed,
  `tui_scroll_offset_y = spring.position * cell_h`, region top/bottom +1 for the hidden
  extra row).
- `src/renderer/shaders/shaders.metal` — `tui_scroll_offset_y`, `tui_scroll_region_top`,
  `tui_scroll_region_bottom` uniforms; per-row offset applied only when
  `row >= region_top && row <= region_bottom`; clip at region boundaries.
- Config: `scroll-animation-duration` (reference default 0.15 for terminal; use that) —
  0 disables animation entirely.

## What to build (mechanism)

1. **Jump detection (terminal core).** Add a monotonically accumulating counter on the
   Screen (or Terminal) that records signed row-shift amounts whenever the alt screen
   scrolls content within the scrolling region (scrollUp/scrollDown/insertLines/deleteLines
   paths — find the exact fork equivalents; upstream refactors may have moved these).
   Capture `scrolling_region.top/bottom` and the tracker diff into `RenderState` during
   `beginUpdate` (follow phase 1's pattern of adding fields beside `row_data`, do NOT
   change public C API meaning — check src/terminal/c/render.zig consumers as in phase 1).

2. **Wheel-recency gate (Surface).** In `scrollCallback`, when the alt screen is active and
   the event reaches either the mouse-reporting path or the alternate-scroll-arrow-keys
   path, record a monotonic timestamp (std.time.Instant) into renderer-shared state
   (`renderer_state.mouse`, mutex-held — same plumbing as phase 1's
   `pixel_scroll_offset_y`). Store as a timestamp, not a bool, so the renderer can apply
   the recency window.

3. **Spring + gate (renderer, generic.zig).** Port `Spring` into a new
   `src/renderer/animation.zig` (or fork-appropriate location). In `updateFrame`'s critical
   section, extract the tracker diff, region bounds, and last-wheel timestamp. Outside the
   critical section:
   - If animation disabled (duration <= 0) → nothing, snap as today.
   - If a nonzero jump arrived AND the last wheel event was within 150ms → accumulate onto
     the spring (`position += jump_rows`), mark animating.
   - If a jump arrived without recent wheel → reset the spring to 0 (snap; kills any
     in-flight glide so keyboard motion is never delayed).
   - Reset the spring whenever: screen switches, region bounds change, resize, font size
     change (same reset list as phase 1's offset).
   - Each frame while animating: `spring.update(dt, duration, zeta)`; when settled, clear
     animating.

4. **Frame driving.** Do NOT add an app-level display link or a new free-running timer.
   Ghostty's renderer Thread already has a draw-timer mechanism used when custom-shader
   animation is active (grep `custom_shader` / `draw_h` / `animation` in
   src/renderer/Thread.zig of OUR fork — find the actual mechanism first, it may differ
   from upstream). Piggyback: while `scroll_animating`, keep the draw timer armed exactly
   the way custom-shader animation does; disarm when the spring settles. Idle cost when not
   animating must remain zero. If the fork's mechanism is unsuitable, the fallback is
   scheduling wakeups from the renderer thread itself while animating — never from the
   app/Swift side, and never unconditionally.
   NOTE: this fork's Thread.zig has cmux-specific bounded-drain invariants documented in
   docs/ghostty-fork.md ("Bounded renderer mailbox turns") — read that section first and
   do not violate the conflict notes there.

5. **Uniforms + shaders.** Add `tui_scroll_offset_y: f32`, `tui_scroll_region_top: u16`,
   `tui_scroll_region_bottom: u16` to the Metal uniforms (and GLSL mirror for compile
   parity). Extend phase 1's uniform-layout probe test to pin the new offsets. In the cell
   text vertex + bg fragment + image vertex: rows within [region_top, region_bottom] get
   the additional `tui_scroll_offset_y` shift; content must clip at the region's pixel
   boundaries (statusline row must never be overdrawn by gliding content). Remember phase
   1's extra-row convention: on the alt screen `pixel_scroll_offset_y` sits at the at-rest
   value with extra rows active (see reference `:4116-4125` — region indices need the +1
   adjustment matching however phase 1's ExtraRows integration ended up indexing rows;
   verify against the actual phase 1 code, not the reference).

6. **Config.** `scroll-animation-duration: f32 = 0.15` (0 = off). Plumb to renderer derived
   config like phase 1's `pixel-scroll`. Optionally `scroll-animation-bounciness` (zeta
   mapping) — include only if trivial; default 0.

## Edge cases

- Fast repeated wheel scrolling: jumps accumulate onto the live spring (stacking), no reset
  between them — this is what makes flick-scrolling feel continuous.
- Wheel scroll then immediate keypress: the keypress-driven jump has no recent wheel →
  spring resets → instant snap. In-flight glide cancellation is REQUIRED, not optional.
- Alternate-scroll mode (no mouse reporting, wheel→arrow keys, `Surface.zig:5240-5272`):
  these wheel events must ALSO record the wheel timestamp — from nvim's perspective they're
  keyboard, but from the user's perspective they're wheel, so they should animate.
- Vertical splits / non-full-width scrolls: terminal scroll regions are full-width only; if
  the TUI repaints without a region scroll there's no jump to detect → no animation →
  current snap behavior. Acceptable, document it.
- Primary screen completely unaffected: phase 1 path untouched; spring code must not run
  outside the alt screen.
- The spring's visual offset must clamp so content never glides more than the region height.

## Toolchain / process (same as phase 1)

- Branch: continue on `pixel-scroll` (new commits on top of the existing 5).
- Zig: /opt/homebrew/opt/zig@0.15/bin/zig (0.15.2); PATH-prefix every build.
- Iterate: `zig build -Demit-macos-app=false`. Tests via `-Dtest-filter`.
- Unit tests required: spring math (settles, accumulates, resets), jump-tracker counting,
  recency-gate decision logic (pure-function it like phase 1's accumulator), uniform layout.
- Full `zig build test` at the end — expect 3180+12(phase1)+N passed; do NOT run it
  concurrently with other heavy builds (phase 1's only "failure" was a load-induced flake).
- Final: ReleaseFast universal xcframework build.
- Commits: logical, no branding, no Co-Authored-By. NEVER push. No PRs/issues.
- Append phase-2 notes to PIXEL_SCROLL_IMPL_NOTES.md (files touched, line ranges,
  deviations, limitations).

## Acceptance

1. Clean `zig build -Demit-macos-app=false`.
2. New unit tests pass; full suite no regressions.
3. Idle cost zero when not animating (demonstrate: no timer armed when spring settled —
   cite the code path).
4. Keyboard scrolls never animate; wheel scrolls animate on alt screen; primary screen
   behavior byte-identical to phase 1.
5. xcframework build succeeds.
6. Notes appended.
