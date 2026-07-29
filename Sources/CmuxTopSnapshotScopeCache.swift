import Foundation
import Darwin
import os

struct CmuxTopProcessScopeCacheKey: Hashable {
    let pid: Int
    let startSeconds: Int
    let startMicroseconds: Int
    let executableName: String

    init(
        pid: Int,
        startSeconds: Int,
        startMicroseconds: Int,
        executableName: String = ""
    ) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.executableName = executableName
    }
}

private struct CmuxTopProcessScopeCacheValue {
    // nil means "this process was probed and has no cmux scope". A negative entry
    // is honored as a hit only until `negativeExpiresAtNanos`, so a non-cmux
    // process is re-probed at most once per TTL window instead of on every
    // system.top poll. Expiration phases are distributed across that window to
    // avoid a machine-wide re-probe burst. Positive entries never expire
    // (`negativeExpiresAtNanos` is ignored when `scope != nil`): a cmux scope
    // comes from inherited environment or a stable argv and does not disappear
    // for the process lifetime.
    let scope: CmuxTopProcessScope?
    let negativeExpiresAtNanos: UInt64
}

// Maximum time a "no cmux scope" result stays cached before the process is
// probed again. The key includes the kernel executable name, so ordinary execs
// invalidate immediately. The TTL still covers same-name execs that change argv
// or environment without changing the pid, start time, or executable name.
// Newly spawned processes have new keys and are probed immediately.
// Internal (not private) so tests can read the TTL via @testable import.
nonisolated let cmuxTopNegativeScopeTTLNanoseconds: UInt64 = 60 * 1_000_000_000

// Result of probing a single process for its cmux scope. `resolved` means the
// probe completed (the scope may legitimately be absent) and is safe to cache.
// `unavailable` means a transient failure (process exited mid-probe, pid reuse,
// or a failed sysctl) and must NOT be cached so the next poll retries.
enum CmuxTopProcessScopeProbeResult: Equatable {
    case resolved(CmuxTopProcessScope?)
    case unavailable
}

// CmuxTopProcessSnapshot.capture is intentionally synchronous because it backs
// both async task-manager sampling and sync v2 system.top socket handling. Keep
// this tiny lock isolated to dictionary reads/writes; procargs/sysctl work must
// happen outside the critical section.
private nonisolated let cmuxTopScopeCache = OSAllocatedUnfairLock(
    initialState: [CmuxTopProcessScopeCacheKey: CmuxTopProcessScopeCacheValue]()
)

extension CmuxTopProcessSnapshot {
    static func scopeCacheKey(from kinfo: kinfo_proc) -> CmuxTopProcessScopeCacheKey {
        let startTime = kinfo.kp_proc.p_un.__p_starttime
        return CmuxTopProcessScopeCacheKey(
            pid: Int(kinfo.kp_proc.p_pid),
            startSeconds: Int(startTime.tv_sec),
            startMicroseconds: Int(startTime.tv_usec),
            executableName: scopeCacheExecutableName(kinfo.kp_proc.p_comm)
        )
    }

    static func scopeCacheKey(from bsdInfo: proc_bsdinfo) -> CmuxTopProcessScopeCacheKey {
        CmuxTopProcessScopeCacheKey(
            pid: Int(bsdInfo.pbi_pid),
            startSeconds: Int(bsdInfo.pbi_start_tvsec),
            startMicroseconds: Int(bsdInfo.pbi_start_tvusec),
            executableName: scopeCacheExecutableName(bsdInfo.pbi_comm)
        )
    }

    static func cachedCMUXScope(
        for pid: Int,
        cacheKey: CmuxTopProcessScopeCacheKey,
        nowNanoseconds: UInt64,
        probe: (Int, CmuxTopProcessScopeCacheKey) -> CmuxTopProcessScopeProbeResult = CmuxTopProcessSnapshot.cmuxScopeProbe
    ) -> CmuxTopProcessScope? {
        if let cached = cmuxTopScopeCache.withLock({ cache in cache[cacheKey] }) {
            if let scope = cached.scope {
                // Positive results never expire: a discovered cmux scope is stable.
                return scope
            }
            if nowNanoseconds < cached.negativeExpiresAtNanos {
                // Negative result still within its TTL: honor the cached miss.
                return nil
            }
            // Negative TTL expired: fall through and re-probe in case the process
            // execed into a cmux-scoped command since it was last sampled.
        }

        switch probe(pid, cacheKey) {
        case .resolved(let scope):
            // Cache the resolved result. Positive scopes are kept indefinitely;
            // negative scopes are kept only until the TTL elapses so a later exec
            // is eventually attributed. The key is pruned to live pids each
            // capture, so a recycled pid gets a fresh key.
            //
            // capture() runs concurrently (async task-manager sampling and sync
            // system.top socket handling), and the probe happened outside the
            // lock. Never let a stale negative from an older capture clobber a
            // positive scope a newer capture already discovered for the same
            // process: if we probed nil but a positive entry now exists, keep and
            // return it.
            return cmuxTopScopeCache.withLock { cache -> CmuxTopProcessScope? in
                if scope == nil, let existing = cache[cacheKey], let existingScope = existing.scope {
                    return existingScope
                }
                cache[cacheKey] = CmuxTopProcessScopeCacheValue(
                    scope: scope,
                    negativeExpiresAtNanos: negativeScopeExpiryNanoseconds(
                        after: nowNanoseconds,
                        cacheKey: cacheKey
                    )
                )
                return scope
            }
        case .unavailable:
            // Transient failure: do not cache, retry on the next poll.
            return nil
        }
    }

    static func pruneCMUXScopeCache(activeKeys: Set<CmuxTopProcessScopeCacheKey>) {
        cmuxTopScopeCache.withLock { cache in
            cache = cache.filter { activeKeys.contains($0.key) }
        }
    }

    /// Assigns stable phases across the existing 60-second freshness window so
    /// thousands of negative entries do not all expire in one snapshot.
    private static func negativeScopeExpiryNanoseconds(
        after nowNanoseconds: UInt64,
        cacheKey: CmuxTopProcessScopeCacheKey
    ) -> UInt64 {
        let pid = UInt64(truncatingIfNeeded: cacheKey.pid)
        let seconds = UInt64(truncatingIfNeeded: cacheKey.startSeconds)
        let microseconds = UInt64(truncatingIfNeeded: cacheKey.startMicroseconds)
        let nameHash = cacheKey.executableName.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        let mixed = pid &* 0x9E37_79B1_85EB_CA87
            ^ seconds &* 0xC2B2_AE3D_27D4_EB4F
            ^ microseconds
            ^ nameHash
        let phase = mixed % cmuxTopNegativeScopeTTLNanoseconds
        let currentPhase = nowNanoseconds % cmuxTopNegativeScopeTTLNanoseconds
        let delta = phase > currentPhase
            ? phase - currentPhase
            : cmuxTopNegativeScopeTTLNanoseconds - (currentPhase - phase)
        return nowNanoseconds &+ delta
    }

    private static func scopeCacheExecutableName<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { rawBuffer in
            let endIndex = rawBuffer.firstIndex(of: 0) ?? rawBuffer.endIndex
            return String(decoding: rawBuffer[..<endIndex], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // Probes a single process for its cmux scope via sysctl.
    //
    // `KERN_PROCARGS2` can fail two very different ways: transiently, because the
    // process exited mid-probe or its pid was reused (then `kinfoProc` no longer
    // matches the expected start-time key), or permanently, because the process
    // belongs to another user / is protected (the kernel denies procargs for the
    // process's whole life). We must cache the permanent case as a definitive
    // "no readable cmux scope" — those processes are not cmux-scoped and stay in
    // `activeKeys`, so leaving them uncached would re-run this sysctl fan-out on
    // every poll. We must NOT cache the transient case, so a process that is
    // simply mid-exec is retried.
    //
    // The discriminator is liveness: if a procargs read fails but the process is
    // still alive with the same start time, the failure is a permanent denial and
    // resolves to nil; otherwise it raced with exit/reuse and is `.unavailable`.
    // Callers derive `expectedCacheKey` from a `proc_bsdinfo` snapshot of this pid
    // in the same enumeration pass, so a pre-read `kinfoProc` check would only
    // repeat work. The post-read guard still catches pid reuse during the
    // `KERN_PROCARGS2` probe window.
    static func cmuxScopeProbe(
        for pid: Int,
        expectedCacheKey: CmuxTopProcessScopeCacheKey
    ) -> CmuxTopProcessScopeProbeResult {
        guard pid > 0, pid <= Int(Int32.max) else { return .unavailable }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            // Sizing failed: permanent denial if still alive, else exit race.
            return processMatchesKey(pid, expectedCacheKey) ? .resolved(nil) : .unavailable
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let success = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &size, nil, 0) == 0
        }
        guard success else {
            return processMatchesKey(pid, expectedCacheKey) ? .resolved(nil) : .unavailable
        }
        guard processMatchesKey(pid, expectedCacheKey) else {
            return .unavailable
        }

        return .resolved(cmuxScope(fromKernProcArgs: Array(buffer.prefix(Int(size)))))
    }

    // True when `pid` is still the same process (same start time) as the key.
    private static func processMatchesKey(
        _ pid: Int,
        _ expectedCacheKey: CmuxTopProcessScopeCacheKey
    ) -> Bool {
        guard let process = kinfoProc(for: pid) else { return false }
        return scopeCacheKey(from: process) == expectedCacheKey
    }

    static func cmuxScope(fromKernProcArgs bytes: [UInt8]) -> CmuxTopProcessScope? {
        guard let process = cmuxScopeArgumentsAndEnvironment(fromKernProcArgs: bytes) else {
            return nil
        }
        return cmuxScope(arguments: process.arguments, environment: process.environment)
    }

    /// Decodes argv plus only the four environment keys used for cmux scope.
    /// Full process environments can contain thousands of strings, so building
    /// a dictionary for every system process causes avoidable allocator churn.
    private static func cmuxScopeArgumentsAndEnvironment(
        fromKernProcArgs bytes: [UInt8]
    ) -> CmuxTopProcessArguments? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }

        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { rawBuffer in
            rawBuffer.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size))
        }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        skipKernProcString(in: bytes, index: &index)
        skipKernProcNulls(in: bytes, index: &index)

        var arguments: [String] = []
        arguments.reserveCapacity(argc)
        for _ in 0..<argc {
            guard index < bytes.count else { return nil }
            let start = index
            skipKernProcString(in: bytes, index: &index)
            if let argument = String(bytes: bytes[start..<index], encoding: .utf8) {
                arguments.append(argument)
            }
            consumeKernProcNull(in: bytes, index: &index)
        }

        var environment: [String: String] = [:]
        environment.reserveCapacity(4)
        while index < bytes.count {
            skipKernProcNulls(in: bytes, index: &index)
            guard index < bytes.count else { break }
            let start = index
            skipKernProcString(in: bytes, index: &index)
            guard start < index,
                  let entry = cmuxScopeEnvironmentEntry(bytes[start..<index]) else {
                continue
            }
            environment[entry.key] = entry.value
        }
        return CmuxTopProcessArguments(arguments: arguments, environment: environment)
    }

    private static func cmuxScopeEnvironmentEntry(
        _ bytes: ArraySlice<UInt8>
    ) -> (key: String, value: String)? {
        guard let equals = bytes.firstIndex(of: 0x3D) else {
            return nil
        }
        let keyBytes = bytes[..<equals]
        let key: String
        if keyBytes.elementsEqual("CMUX_WORKSPACE_ID".utf8) {
            key = "CMUX_WORKSPACE_ID"
        } else if keyBytes.elementsEqual("CMUX_TAB_ID".utf8) {
            key = "CMUX_TAB_ID"
        } else if keyBytes.elementsEqual("CMUX_SURFACE_ID".utf8) {
            key = "CMUX_SURFACE_ID"
        } else if keyBytes.elementsEqual("CMUX_PANEL_ID".utf8) {
            key = "CMUX_PANEL_ID"
        } else {
            return nil
        }
        let valueStart = bytes.index(after: equals)
        guard let value = String(bytes: bytes[valueStart...], encoding: .utf8) else {
            return nil
        }
        return (key, value)
    }

    private static func skipKernProcString(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] != 0 {
            index += 1
        }
    }

    private static func skipKernProcNulls(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] == 0 {
            index += 1
        }
    }

    private static func consumeKernProcNull(in bytes: [UInt8], index: inout Int) {
        if index < bytes.count, bytes[index] == 0 {
            index += 1
        }
    }

    static func cmuxScope(arguments: [String], environment: [String: String]) -> CmuxTopProcessScope? {
        if let environmentScope = cmuxScopeFromEnvironment(environment) {
            return environmentScope
        }
        if let hookScope = cmuxHookMonitorScope(arguments: arguments) {
            return hookScope
        }
        return nil
    }

    private static func cmuxScopeFromEnvironment(_ environment: [String: String]) -> CmuxTopProcessScope? {
        let workspaceID = uuidValue(in: environment, keys: ["CMUX_WORKSPACE_ID", "CMUX_TAB_ID"])
        let surfaceID = uuidValue(in: environment, keys: ["CMUX_SURFACE_ID", "CMUX_PANEL_ID"])
        guard workspaceID != nil || surfaceID != nil else { return nil }
        return CmuxTopProcessScope(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            attributionReason: "cmux-environment"
        )
    }

    private static func cmuxHookMonitorScope(arguments: [String]) -> CmuxTopProcessScope? {
        guard containsSubcommandPath(["hooks", "codex", "monitor"], in: arguments) else {
            return nil
        }
        let workspaceID = uuidOptionValue(in: arguments, names: ["--workspace"])
        let surfaceID = uuidOptionValue(in: arguments, names: ["--surface", "--panel"])
        guard workspaceID != nil || surfaceID != nil else { return nil }
        return CmuxTopProcessScope(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            attributionReason: "cmux-hook-arguments"
        )
    }

    private static func containsSubcommandPath(_ path: [String], in arguments: [String]) -> Bool {
        let normalizedPath = path.map { $0.lowercased() }
        guard !normalizedPath.isEmpty, arguments.count >= normalizedPath.count + 1 else { return false }
        let executableName = URL(fileURLWithPath: arguments[0])
            .lastPathComponent
            .lowercased()
        guard executableName == "cmux" else { return false }
        let subcommands = arguments
            .dropFirst()
            .prefix(normalizedPath.count)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return Array(subcommands) == normalizedPath
    }

    private static func uuidValue(in environment: [String: String], keys: [String]) -> UUID? {
        for key in keys {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let uuid = UUID(uuidString: raw) else {
                continue
            }
            return uuid
        }
        return nil
    }

    private static func uuidOptionValue(in arguments: [String], names: Set<String>) -> UUID? {
        for index in arguments.indices {
            let argument = arguments[index].trimmingCharacters(in: .whitespacesAndNewlines)
            for name in names {
                let prefix = "\(name)="
                guard argument.hasPrefix(prefix) else { continue }
                let raw = String(argument.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty, let uuid = UUID(uuidString: raw) else { continue }
                return uuid
            }

            guard names.contains(argument) else { continue }
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else { continue }
            let raw = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let uuid = UUID(uuidString: raw) else { continue }
            return uuid
        }
        return nil
    }

    private static func kinfoProc(for pid: Int) -> kinfo_proc? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &process, &length, nil, 0)
        guard result == 0,
              length >= MemoryLayout<kinfo_proc>.stride,
              process.kp_proc.p_pid == pid_t(pid) else {
            return nil
        }
        return process
    }
}

extension CmuxTopProcessArguments {
    func matchesCMUXScope(workspaceId: UUID, surfaceId: UUID) -> Bool {
        guard let scope = CmuxTopProcessSnapshot.cmuxScope(arguments: arguments, environment: environment) else {
            return false
        }
        return scope.workspaceID == workspaceId && scope.surfaceID == surfaceId
    }
}
