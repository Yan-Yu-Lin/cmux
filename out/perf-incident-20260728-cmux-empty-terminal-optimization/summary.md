# cmux empty-terminal memory optimization

Symptom: A cmux Debug process with one empty Ghostty terminal retains substantially more physical memory than upstream Ghostty.
User impact: High baseline memory before users add terminals, browser surfaces, or scrollback.
Source: User-requested local investigation and optimization.
Target surface: macOS application startup and one-terminal steady state.
Build/version/tag: Baseline `246f6eec874276a037db11e97e9d7b55dfae50f8`; optimization tag `emem`.
Repro workload: Launch one isolated tagged cmux window with one empty login-shell terminal, wait for startup work to settle, then take repeated physical-footprint samples.
Expected bad behavior: Optional cmux services, SwiftUI state, decoded images, process scans, or timers are initialized before the user invokes their feature.

## Invariants

- Terminal behavior, alternate app icons, notifications, global search, settings, mobile presence, agent restoration, and memory diagnostics remain available.
- Optimizations change initialization and observation strategy, not user-visible capability.
- Before/after comparisons use the same build configuration, window dimensions, session fixture, settle period, and sample cadence.

## Current execution path and ownership

`CmuxMain.main` enters `cmuxApp.init`, which constructs settings, auth, `TabManager`, notification/sidebar stores, and then calls `AppDelegate.configure`. `configure` starts auth, mobile presence/render observation, agent transcript observation, session persistence, and memory monitoring before the first terminal window appears. `applicationDidFinishLaunching` then starts process indexing, hotkeys, icon appearance observation, notifications, global search, window controllers, and update services. `ContentView` owns the visible terminal layout plus file explorer, session index, command palette, and many feature-specific state values. `cmuxApp.body` constructs all application commands, including the large Debug menu, as one SwiftUI command graph.

Owners:

- Application composition and feature startup: `Sources/cmuxApp.swift` and `Sources/AppDelegate.swift`
- Mobile identity and 15-second presence heartbeat: `Sources/Mobile/MobileHostIdentity.swift` and `Sources/Cloud/PresenceHeartbeatClient.swift`
- Per-pane 4-second process scan: `Sources/PaneMemoryGuardrail.swift` and `Sources/AppDelegate+PaneMemoryGuardrail.swift`
- Real system-pressure reclamation and notification: `Sources/App/MemoryPressureMonitor.swift` plus responders registered by `AppDelegate+PaneMemoryGuardrail.swift`
- Root-window feature state: `Sources/ContentView.swift`
- Application command graph: `Sources/cmuxApp.swift`
- Runtime app icon decoding and appearance switching: `AppIconSettings` and `AppIconAppearanceObserver` in `Sources/cmuxApp.swift`

Confirmed behavior:

- `MobileHostIdentity.deviceID()` writes the already-set identifier to `UserDefaults` on every heartbeat. The process-wide notification wakes unrelated observers, including system-wide hotkey registration and application presentation synchronization.
- `PaneMemoryGuardrail` enumerates all processes every four seconds and performs a more detailed scoped scan every fifteen seconds. Its warning UI was removed; its only remaining output is a Debug log. The separate `MemoryPressureMonitor` owns actual hidden-renderer/browser reclamation and the critical-pressure notification.
- Eager file-explorer and session-index constructors are cheap. Their expensive I/O already starts only when the right sidebar needs data, so changing their ownership is lower priority.
- The root `ContentView` and SwiftUI command graph account for a large retained Debug heap and AttributeGraph node count. This is structural retained memory, not terminal renderer memory.
- Normal application startup retains a large graphics allocation absent from the existing UI-test startup policy. Icon assignment alone explains a 32 MiB decoded image, but prior one-at-a-time runtime experiments did not prove that it alone owns the remaining graphics pool.

## Architecture options

### Option A: demand-driven feature runtime

Keep a minimal launch set for terminal correctness, window restoration, pressure handling, settings, shortcuts, and notification delivery. Give optional services explicit owners with idempotent `startIfNeeded` entrypoints, and invoke those entrypoints from the feature actions that need them. Replace broad `UserDefaults.didChangeNotification` reactions with value-diffed settings snapshots. Replace dead periodic diagnostics with on-demand capture. Build Debug commands through a lazy AppKit menu delegate so opening the Debug menu constructs its items, while all current commands remain available.

Tradeoffs: best steady-state memory and CPU, explicit lifecycle ownership, and testable start conditions. It requires several small migrations because changing every optional service in one patch would create feature risk.

### Option B: staged eager bootstrap

Keep every current service eager but schedule optional groups after the first window, then after an idle delay. This improves launch peaks and time-to-first-window, but the empty steady state eventually retains the same services and graphics. Timer ordering also creates restoration and automation races.

Tradeoffs: smaller code change, weaker memory result, and more timing-dependent behavior.

## Recommendation

Use Option A incrementally. The first cut should remove redundant identity persistence, stop the output-free pane polling while preserving `MemoryPressureMonitor`, and add measurement seams that isolate command and startup-service retention without changing normal behavior. Subsequent cuts should lazy-build Debug commands and move optional services behind their existing shared feature entrypoints only after before/after captures identify material wins. This is principled because each service gains an owner and an observable start condition instead of relying on launch timing.

## Latest-main baseline

Tag `emb0`, PID 76520, tagged automation socket `/tmp/cmux-debug-emb0.sock`, session restoration disabled. The debug CLI confirmed one focused terminal in one workspace. Nine samples over 41 seconds were all 352 MiB physical footprint.

Steady-state footprint:

- Total: 352 MiB
- App-owned unmapped graphics: 178 MiB
- Decoded CG images: 32 MiB
- IOSurface: 23 MiB
- Dirty `MALLOC_SMALL`: 81 MiB
- Peak during startup: 543 MiB

Heap:

- 85,057,454 allocated bytes across 356,691 nodes
- Unknown Swift closure contexts: 13,481,696 bytes
- Swift metadata: 6,036,544 bytes
- `SwiftUI.PlatformItemList.Item` arrays: 3,345,664 bytes across 1,680 arrays
- `CmuxTopProcessInfo` and scope/CPU dictionaries retained about 3.1 MiB
- AttributeGraph zones retained about 3.7 MiB across roughly 64,000 allocations

Idle samples show two independent process scans:

- `PaneMemoryGuardrail` captures a whole-process snapshot every four seconds despite having no output except a Debug log.
- Session autosave calls `ProcessDetectedResumeIndexes.load()` before deciding that the session fingerprint is unchanged. On this machine that reads process arguments across the system every eight seconds. A 12-second stack sample attributed 1,069 samples to this autosave load and 244 samples to pane guardrail loads. The log confirms seven unchanged autosave results between each required 60-second persistence write.
