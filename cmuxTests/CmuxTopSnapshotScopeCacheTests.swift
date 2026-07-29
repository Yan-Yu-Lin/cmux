import Testing
import Foundation
import Darwin

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression coverage for the cmux-scope attribution cache used by system.top.
// See https://github.com/manaflow-ai/cmux/issues/5756.
//
// `.serialized` because these tests share the process-global cmux-top scope
// cache (`CmuxTopProcessSnapshot.cachedCMUXScope` / `pruneCMUXScopeCache`); they
// must not interleave with each other.
@Suite(.serialized)
struct CmuxTopSnapshotScopeCacheTests {
    @Test func discoveryKeepsScopedProcessesAndTheirUnscopedDescendants() {
        let included = CmuxTopProcessSnapshot.discoveryIncludedPIDs(
            parentPIDByPID: [
                100: 1,
                101: 100,
                102: 101,
                200: 1,
                201: 200,
                300: 1,
            ],
            scopedPIDs: [100, 300]
        )

        #expect(included == [100, 101, 102, 300])
    }

    @Test func discoveryFilterKeepsOnlyRequestedPanelProcessTrees() {
        let requestedWorkspaceID = UUID()
        let requestedPanelID = UUID()
        let unrelatedWorkspaceID = UUID()
        let unrelatedPanelID = UUID()
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                processInfo(
                    pid: 100,
                    parentPID: 1,
                    workspaceID: requestedWorkspaceID,
                    panelID: requestedPanelID
                ),
                processInfo(pid: 101, parentPID: 100),
                processInfo(
                    pid: 200,
                    parentPID: 1,
                    workspaceID: unrelatedWorkspaceID,
                    panelID: unrelatedPanelID
                ),
                processInfo(pid: 201, parentPID: 200),
            ],
            sampledAt: Date(timeIntervalSince1970: 42),
            includesProcessDetails: true,
            includesCMUXScope: true
        )

        let filtered = snapshot.filteringProcessTrees(
            for: [
                RestorableAgentSessionIndex.PanelKey(
                    workspaceId: requestedWorkspaceID,
                    panelId: requestedPanelID
                ),
            ]
        )

        #expect(Set(filtered.processes.map(\.pid)) == [100, 101])
    }

    // Before the fix, a process with no cmux scope was a permanent cache miss, so
    // every system.top poll re-ran the 3-sysctl probe for every non-cmux process
    // on the machine. The negative result must stay cached until process identity
    // changes or the exec monitor invalidates it.
    @Test func negativeScopeResultIsCachedBetweenExecEvents() {
        CmuxTopProcessSnapshot.pruneCMUXScopeCache(activeKeys: [])
        let cacheKey = CmuxTopProcessScopeCacheKey(
            pid: 901_001,
            startSeconds: 1_700_000_001,
            startMicroseconds: 11
        )
        var probeCount = 0
        let probe: (Int, CmuxTopProcessScopeCacheKey) -> CmuxTopProcessScopeProbeResult = { _, _ in
            probeCount += 1
            return .resolved(nil)
        }

        let first = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_001, cacheKey: cacheKey, probe: probe)
        let second = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_001, cacheKey: cacheKey, probe: probe)

        #expect(first == nil)
        #expect(second == nil)
        #expect(probeCount == 1, "non-cmux process should not be re-probed without an exec")
    }

    @Test func positiveScopeResultIsCachedAcrossPolls() {
        CmuxTopProcessSnapshot.pruneCMUXScopeCache(activeKeys: [])
        let cacheKey = CmuxTopProcessScopeCacheKey(
            pid: 901_002,
            startSeconds: 1_700_000_002,
            startMicroseconds: 22
        )
        let expected = CmuxTopProcessScope(
            workspaceID: UUID(uuidString: "99999999-9999-9999-9999-999999999999"),
            surfaceID: nil,
            attributionReason: "cmux-environment"
        )
        var probeCount = 0
        let probe: (Int, CmuxTopProcessScopeCacheKey) -> CmuxTopProcessScopeProbeResult = { _, _ in
            probeCount += 1
            return .resolved(expected)
        }

        // A discovered scope is cached indefinitely.
        let first = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_002, cacheKey: cacheKey, probe: probe)
        let second = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_002, cacheKey: cacheKey, probe: probe)

        #expect(first == expected)
        #expect(second == expected)
        #expect(probeCount == 1)
    }

    // A transient read failure (process exited mid-probe, pid reuse, failed
    // sysctl) must not be cached as a nil, so the next poll retries and can still
    // attribute a live cmux process.
    @Test func transientProbeFailureIsNotCachedAndRetries() {
        CmuxTopProcessSnapshot.pruneCMUXScopeCache(activeKeys: [])
        let cacheKey = CmuxTopProcessScopeCacheKey(
            pid: 901_003,
            startSeconds: 1_700_000_003,
            startMicroseconds: 33
        )
        let expected = CmuxTopProcessScope(
            workspaceID: nil,
            surfaceID: UUID(uuidString: "abababab-abab-abab-abab-abababababab"),
            attributionReason: "cmux-environment"
        )
        var probeCount = 0
        let probe: (Int, CmuxTopProcessScopeCacheKey) -> CmuxTopProcessScopeProbeResult = { _, _ in
            probeCount += 1
            // Fail the first two polls, then resolve.
            return probeCount < 3 ? .unavailable : .resolved(expected)
        }

        let first = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_003, cacheKey: cacheKey, probe: probe)
        let second = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_003, cacheKey: cacheKey, probe: probe)
        let third = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_003, cacheKey: cacheKey, probe: probe)
        let fourth = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_003, cacheKey: cacheKey, probe: probe)

        #expect(first == nil)
        #expect(second == nil)
        #expect(third == expected)
        #expect(fourth == expected, "resolved scope should now be cached")
        #expect(probeCount == 3, "transient failures retry; the resolved result is cached")
    }

    // A same-name `exec` preserves every field in the cache key, so the process
    // event monitor must invalidate the old negative before the next lookup.
    @Test func negativeScopeIsReprobedAfterExecInvalidation() {
        CmuxTopProcessSnapshot.pruneCMUXScopeCache(activeKeys: [])
        let cacheKey = CmuxTopProcessScopeCacheKey(
            pid: 901_004,
            startSeconds: 1_700_000_004,
            startMicroseconds: 44
        )
        let postExecScope = CmuxTopProcessScope(
            workspaceID: UUID(uuidString: "12121212-1212-1212-1212-121212121212"),
            surfaceID: nil,
            attributionReason: "cmux-environment"
        )
        var probeCount = 0
        var resolvedScope: CmuxTopProcessScope?
        let probe: (Int, CmuxTopProcessScopeCacheKey) -> CmuxTopProcessScopeProbeResult = { _, _ in
            probeCount += 1
            return .resolved(resolvedScope)
        }

        // Sampled pre-exec: no scope yet, cached negative.
        let preExec = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_004, cacheKey: cacheKey, probe: probe)
        // Polled again without an exec: served from the negative cache.
        let withoutExec = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_004, cacheKey: cacheKey, probe: probe)
        #expect(preExec == nil)
        #expect(withoutExec == nil)
        #expect(probeCount == 1)

        // The process has since execed into a cmux-scoped command without changing
        // its cache key. The event monitor invalidates the old negative.
        resolvedScope = postExecScope
        CmuxTopProcessSnapshot.invalidateCMUXScopeCache(forPIDs: [901_004])
        let afterExec = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_004, cacheKey: cacheKey, probe: probe)
        #expect(afterExec == postExecScope)
        #expect(probeCount == 2, "exec-invalidated negative entry must be re-probed")
    }

    @Test func processExecMonitorReportsSameNameExec() throws {
        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "read ignored; exec /bin/sh -c 'sleep 2'"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let pid = Int(process.processIdentifier)
        let initialInfo = try #require(CmuxTopProcessSnapshot.bsdInfo(for: pid))
        let initialKey = CmuxTopProcessSnapshot.scopeCacheKey(from: initialInfo)
        _ = CmuxTopProcessSnapshot.synchronizeCMUXScopeExecMonitor(
            activeKeysByPID: [pid: initialKey],
            watchablePIDs: [pid]
        )

        input.fileHandleForWriting.write(Data([0x0A]))
        input.fileHandleForWriting.closeFile()

        var observedExec = false
        var postExecKey: CmuxTopProcessScopeCacheKey?
        for _ in 0..<100 {
            Thread.sleep(forTimeInterval: 0.02)
            guard let info = CmuxTopProcessSnapshot.bsdInfo(for: pid) else { continue }
            let key = CmuxTopProcessSnapshot.scopeCacheKey(from: info)
            let invalidatedPIDs = CmuxTopProcessSnapshot.synchronizeCMUXScopeExecMonitor(
                activeKeysByPID: [pid: key],
                watchablePIDs: [pid]
            )
            if invalidatedPIDs.contains(pid) {
                observedExec = true
                postExecKey = key
                break
            }
        }

        #expect(observedExec)
        #expect(postExecKey?.executableName == initialKey.executableName)
    }

    @Test func liveProcessScopeProbeResolves() throws {
        let pid = Int(Darwin.getpid())
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        try #require(size == expectedSize)
        let cacheKey = CmuxTopProcessSnapshot.scopeCacheKey(from: info)

        let result = CmuxTopProcessSnapshot.cmuxScopeProbe(for: pid, expectedCacheKey: cacheKey)

        switch result {
        case .resolved:
            break
        case .unavailable:
            Issue.record("live process probe should resolve, even when it has no cmux scope")
        }
    }

    private func processInfo(
        pid: Int,
        parentPID: Int,
        workspaceID: UUID? = nil,
        panelID: UUID? = nil
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: parentPID,
            name: "process-\(pid)",
            path: "/usr/bin/process-\(pid)",
            ttyDevice: nil,
            cmuxWorkspaceID: workspaceID,
            cmuxSurfaceID: panelID,
            cmuxAttributionReason: workspaceID == nil && panelID == nil ? nil : "cmux-test",
            processGroupID: nil,
            terminalProcessGroupID: nil,
            cpuPercent: 0,
            residentBytes: 0,
            virtualBytes: 0,
            threadCount: 0
        )
    }

    // capture() runs concurrently. A slower sample that probed a process before
    // it execed (resolving nil) must not, on its delayed write, clobber a
    // positive scope that a faster overlapping sample already discovered.
    @Test func negativeProbeDoesNotClobberConcurrentlyDiscoveredPositive() {
        CmuxTopProcessSnapshot.pruneCMUXScopeCache(activeKeys: [])
        let cacheKey = CmuxTopProcessScopeCacheKey(
            pid: 901_005,
            startSeconds: 1_700_000_005,
            startMicroseconds: 55
        )
        let positive = CmuxTopProcessScope(
            workspaceID: UUID(uuidString: "13131313-1313-1313-1313-131313131313"),
            surfaceID: nil,
            attributionReason: "cmux-environment"
        )
        // This (older) sample resolves nil, but simulates a concurrent capture
        // discovering and caching the positive scope while the probe is in flight.
        let probe: (Int, CmuxTopProcessScopeCacheKey) -> CmuxTopProcessScopeProbeResult = { pid, key in
            _ = CmuxTopProcessSnapshot.cachedCMUXScope(
                for: pid, cacheKey: key) { _, _ in .resolved(positive) }
            return .resolved(nil)
        }

        let result = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_005, cacheKey: cacheKey, probe: probe)
        #expect(result == positive, "stale negative must not clobber a concurrently discovered positive")

        // The positive entry survives for later polls.
        let nextPoll = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_005, cacheKey: cacheKey) { _, _ in .resolved(nil) }
        #expect(nextPoll == positive)
    }
}
