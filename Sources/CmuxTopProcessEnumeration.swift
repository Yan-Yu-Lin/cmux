import Darwin
import Foundation

private nonisolated let cmuxTopPIDPathBufferSize = 4096

extension CmuxTopProcessSnapshot {
    /// Samples one process for diagnostics without enumerating the system.
    static func resourceInfo(for pid: Int) -> CmuxTopProcessInfo? {
        guard let bsdInfo = bsdInfo(for: pid) else { return nil }
        var cpuSamples: [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample] = [:]
        return processInfo(
            from: bsdInfo,
            includeProcessDetails: false,
            includeCMUXScope: false,
            sampledAtNanoseconds: cpuSampleClockNanoseconds(),
            currentCPUSamples: &cpuSamples
        )?.info
    }

    /// Captures the process topology used by agent discovery and session restore
    /// without sampling CPU or memory for every process on the machine.
    static func captureDiscovery() -> CmuxTopProcessSnapshot {
        let sampledAt = Date()
        let sampledProcesses = allBSDProcesses()
        guard !sampledProcesses.isEmpty else {
            return CmuxTopProcessSnapshot(
                processes: [],
                sampledAt: sampledAt,
                includesProcessDetails: true,
                includesCMUXScope: true
            )
        }

        let scopeKeys = sampledProcesses.map { scopeCacheKey(from: $0) }
        invalidateCMUXScopeCache(
            forPIDs: synchronizeCMUXScopeExecMonitor(
                for: sampledProcesses,
                scopeKeys: scopeKeys
            )
        )
        var activeScopeKeys: Set<CmuxTopProcessScopeCacheKey> = []
        activeScopeKeys.reserveCapacity(sampledProcesses.count)
        var scopeByPID: [Int: CmuxTopProcessScope] = [:]
        var parentPIDByPID: [Int: Int] = [:]
        parentPIDByPID.reserveCapacity(sampledProcesses.count)

        for (index, process) in sampledProcesses.enumerated() {
            let pid = Int(process.pbi_pid)
            guard pid > 0 else { continue }
            let cacheKey = scopeKeys[index]
            activeScopeKeys.insert(cacheKey)
            parentPIDByPID[pid] = Int(process.pbi_ppid)
            if let scope = cachedCMUXScope(
                for: pid,
                cacheKey: cacheKey
            ) {
                scopeByPID[pid] = scope
            }
        }
        pruneCMUXScopeCache(activeKeys: activeScopeKeys)

        let includedPIDs = discoveryIncludedPIDs(
            parentPIDByPID: parentPIDByPID,
            scopedPIDs: Set(scopeByPID.keys)
        )
        let processes = sampledProcesses.compactMap { process -> CmuxTopProcessInfo? in
            let pid = Int(process.pbi_pid)
            guard includedPIDs.contains(pid) else { return nil }
            return discoveryProcessInfo(from: process, scope: scopeByPID[pid])
        }
        return CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: sampledAt,
            includesProcessDetails: true,
            includesCMUXScope: true
        )
    }

    /// Samples resources only for pane-owned process trees.
    static func captureResources(
        rootPIDs explicitRootPIDs: Set<Int>,
        ttyDevices: Set<Int64>,
        cmuxSurfaceIDs: Set<UUID>
    ) -> CmuxTopProcessSnapshot {
        let sampledAt = Date()
        let sampledProcesses = allBSDProcesses()
        guard !sampledProcesses.isEmpty else {
            return CmuxTopProcessSnapshot(
                processes: [],
                sampledAt: sampledAt,
                includesProcessDetails: false,
                includesCMUXScope: !cmuxSurfaceIDs.isEmpty
            )
        }

        let includesCMUXScope = !cmuxSurfaceIDs.isEmpty
        let scopeKeys: [CmuxTopProcessScopeCacheKey]
        if includesCMUXScope {
            scopeKeys = sampledProcesses.map { scopeCacheKey(from: $0) }
            invalidateCMUXScopeCache(
                forPIDs: synchronizeCMUXScopeExecMonitor(
                    for: sampledProcesses,
                    scopeKeys: scopeKeys
                )
            )
        } else {
            scopeKeys = []
        }
        var activeScopeKeys: Set<CmuxTopProcessScopeCacheKey> = []
        var scopeByPID: [Int: CmuxTopProcessScope] = [:]
        var parentPIDByPID: [Int: Int] = [:]
        parentPIDByPID.reserveCapacity(sampledProcesses.count)
        var rootPIDs = Set(explicitRootPIDs.filter { $0 > 0 })

        if includesCMUXScope {
            activeScopeKeys.reserveCapacity(sampledProcesses.count)
        }
        for (index, process) in sampledProcesses.enumerated() {
            let pid = Int(process.pbi_pid)
            guard pid > 0 else { continue }
            parentPIDByPID[pid] = Int(process.pbi_ppid)
            if ttyDevices.contains(Int64(process.e_tdev)) {
                rootPIDs.insert(pid)
            }
            guard includesCMUXScope else { continue }
            let cacheKey = scopeKeys[index]
            activeScopeKeys.insert(cacheKey)
            if let scope = cachedCMUXScope(
                for: pid,
                cacheKey: cacheKey
            ) {
                scopeByPID[pid] = scope
                if let surfaceID = scope.surfaceID,
                   cmuxSurfaceIDs.contains(surfaceID) {
                    rootPIDs.insert(pid)
                }
            }
        }
        if includesCMUXScope {
            pruneCMUXScopeCache(activeKeys: activeScopeKeys)
        }

        let includedPIDs = discoveryIncludedPIDs(
            parentPIDByPID: parentPIDByPID,
            scopedPIDs: rootPIDs
        )
        let processes = sampledProcesses.compactMap { process -> CmuxTopProcessInfo? in
            let pid = Int(process.pbi_pid)
            guard includedPIDs.contains(pid) else { return nil }
            return targetedResourceProcessInfo(from: process, scope: scopeByPID[pid])
        }
        return CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: sampledAt,
            includesProcessDetails: false,
            includesCMUXScope: includesCMUXScope
        )
    }

    /// Returns scoped processes plus every descendant needed to classify agent
    /// binaries that intentionally scrub their inherited cmux environment.
    static func discoveryIncludedPIDs(
        parentPIDByPID: [Int: Int],
        scopedPIDs: Set<Int>
    ) -> Set<Int> {
        guard !scopedPIDs.isEmpty else { return [] }
        var childrenByParentPID: [Int: [Int]] = [:]
        childrenByParentPID.reserveCapacity(parentPIDByPID.count)
        for (pid, parentPID) in parentPIDByPID where pid > 0 && parentPID > 0 {
            childrenByParentPID[parentPID, default: []].append(pid)
        }

        var included: Set<Int> = []
        var pending = Array(scopedPIDs)
        while let pid = pending.popLast() {
            guard included.insert(pid).inserted else { continue }
            pending.append(contentsOf: childrenByParentPID[pid] ?? [])
        }
        return included
    }

    static func allProcesses(includeProcessDetails: Bool, includeCMUXScope: Bool) -> [CmuxTopProcessInfo] {
        let sampledProcesses = allBSDProcesses()
        guard !sampledProcesses.isEmpty else { return [] }

        var scopeKeyByPID: [Int: CmuxTopProcessScopeCacheKey] = [:]
        scopeKeyByPID.reserveCapacity(sampledProcesses.count)
        for process in sampledProcesses {
            scopeKeyByPID[Int(process.pbi_pid)] = scopeCacheKey(from: process)
        }
        if includeCMUXScope {
            let invalidatedPIDs = synchronizeCMUXScopeExecMonitor(
                activeKeysByPID: scopeKeyByPID,
                sampledProcesses: sampledProcesses
            )
            invalidateCMUXScopeCache(forPIDs: invalidatedPIDs)
        }
        let activeScopeKeys = Set(scopeKeyByPID.values)
        var parentScopeKeys: [CmuxTopProcessScopeCacheKey: CmuxTopProcessScopeCacheKey] = [:]
        parentScopeKeys.reserveCapacity(sampledProcesses.count)
        for process in sampledProcesses {
            let key = scopeCacheKey(from: process)
            let parentPID = Int(process.pbi_ppid)
            guard let parentKey = scopeKeyByPID[parentPID] else { continue }
            parentScopeKeys[key] = parentKey
        }
        let sampledAtNanoseconds = cpuSampleClockNanoseconds()
        var currentCPUSamples: [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample] = [:]
        var processRecords: [(info: CmuxTopProcessInfo, cpuSampleKey: CmuxTopProcessScopeCacheKey?)] = []
        processRecords.reserveCapacity(sampledProcesses.count)
        for process in sampledProcesses {
            guard let processRecord = processInfo(
                from: process,
                includeProcessDetails: includeProcessDetails,
                includeCMUXScope: includeCMUXScope,
                sampledAtNanoseconds: sampledAtNanoseconds,
                currentCPUSamples: &currentCPUSamples
            ) else {
                continue
            }
            processRecords.append(processRecord)
        }
        let cpuPercentages = cpuPercentages(
            for: currentCPUSamples,
            activeKeys: activeScopeKeys,
            parentKeysByKey: parentScopeKeys,
            sampledAtNanoseconds: sampledAtNanoseconds
        )
        for index in processRecords.indices {
            guard let key = processRecords[index].cpuSampleKey,
                  let cpuPercent = cpuPercentages[key] else { continue }
            processRecords[index].info.cpuPercent = cpuPercent
        }
        if includeCMUXScope {
            pruneCMUXScopeCache(activeKeys: activeScopeKeys)
        }
        return processRecords.map(\.info)
    }

    private static func discoveryProcessInfo(
        from bsdInfo: proc_bsdinfo,
        scope: CmuxTopProcessScope?
    ) -> CmuxTopProcessInfo? {
        let pid = Int(bsdInfo.pbi_pid)
        guard pid > 0 else { return nil }
        let fallbackName = fixedString(bsdInfo.pbi_comm)
        let name = processName(pid: pid, fallback: fallbackName)
        let rawTTY = Int64(bsdInfo.e_tdev)
        let rawProcessGroupID = Int(bsdInfo.pbi_pgid)
        let rawTerminalProcessGroupID = Int(bsdInfo.e_tpgid)
        return CmuxTopProcessInfo(
            pid: pid,
            parentPID: Int(bsdInfo.pbi_ppid),
            name: name.isEmpty ? "pid-\(pid)" : name,
            path: processPath(pid: pid),
            ttyDevice: rawTTY > 0 ? rawTTY : nil,
            cmuxWorkspaceID: scope?.workspaceID,
            cmuxSurfaceID: scope?.surfaceID,
            cmuxAttributionReason: scope?.attributionReason,
            processGroupID: rawProcessGroupID > 0 ? rawProcessGroupID : nil,
            terminalProcessGroupID: rawTerminalProcessGroupID > 0 ? rawTerminalProcessGroupID : nil,
            cpuPercent: 0,
            memoryBytes: 0,
            memorySource: .unavailable,
            residentBytes: 0,
            residentMemorySource: .unavailable,
            virtualBytes: 0,
            threadCount: 0
        )
    }

    private static func targetedResourceProcessInfo(
        from bsdInfo: proc_bsdinfo,
        scope: CmuxTopProcessScope?
    ) -> CmuxTopProcessInfo? {
        let pid = Int(bsdInfo.pbi_pid)
        guard pid > 0 else { return nil }
        let taskInfo = taskInfo(for: pid)
        let resourceUsage = resourceUsage(for: pid)
        let fallbackName = fixedString(bsdInfo.pbi_comm)
        let rawTTY = Int64(bsdInfo.e_tdev)
        let rawProcessGroupID = Int(bsdInfo.pbi_pgid)
        let rawTerminalProcessGroupID = Int(bsdInfo.e_tpgid)

        let memoryBytes: Int64
        let memorySource: CmuxTopProcessMemorySource
        if let resourceUsage {
            memoryBytes = int64Clamped(resourceUsage.ri_phys_footprint)
            memorySource = .physicalFootprint
        } else if let taskInfo {
            memoryBytes = int64Clamped(taskInfo.pti_resident_size)
            memorySource = .residentSize
        } else {
            memoryBytes = 0
            memorySource = .unavailable
        }

        let residentBytes: Int64
        let residentMemorySource: CmuxTopProcessMemorySource
        if let taskInfo {
            residentBytes = int64Clamped(taskInfo.pti_resident_size)
            residentMemorySource = .residentSize
        } else if let resourceUsage {
            residentBytes = int64Clamped(resourceUsage.ri_resident_size)
            residentMemorySource = .rusageResidentSize
        } else {
            residentBytes = 0
            residentMemorySource = .unavailable
        }

        return CmuxTopProcessInfo(
            pid: pid,
            parentPID: Int(bsdInfo.pbi_ppid),
            name: fallbackName.isEmpty ? "pid-\(pid)" : fallbackName,
            path: nil,
            ttyDevice: rawTTY > 0 ? rawTTY : nil,
            cmuxWorkspaceID: scope?.workspaceID,
            cmuxSurfaceID: scope?.surfaceID,
            cmuxAttributionReason: scope?.attributionReason,
            processGroupID: rawProcessGroupID > 0 ? rawProcessGroupID : nil,
            terminalProcessGroupID: rawTerminalProcessGroupID > 0 ? rawTerminalProcessGroupID : nil,
            cpuPercent: 0,
            memoryBytes: memoryBytes,
            memorySource: memorySource,
            residentBytes: residentBytes,
            residentMemorySource: residentMemorySource,
            virtualBytes: int64Clamped(taskInfo?.pti_virtual_size ?? 0),
            threadCount: Int(taskInfo?.pti_threadnum ?? 0)
        )
    }

    static func deviceIdentifier(forTTYName ttyName: String) -> Int64? {
        let trimmed = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "not a tty" else {
            return nil
        }

        let path: String
        if trimmed.hasPrefix("/dev/") {
            path = trimmed
        } else {
            path = "/dev/\(trimmed)"
        }

        var statInfo = stat()
        guard stat(path, &statInfo) == 0 else {
            return nil
        }
        return Int64(statInfo.st_rdev)
    }

    private static func processInfo(
        from bsdInfo: proc_bsdinfo,
        includeProcessDetails: Bool,
        includeCMUXScope: Bool,
        sampledAtNanoseconds: UInt64,
        currentCPUSamples: inout [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample]
    ) -> (info: CmuxTopProcessInfo, cpuSampleKey: CmuxTopProcessScopeCacheKey?)? {
        let pid = Int(bsdInfo.pbi_pid)
        guard pid > 0 else { return nil }

        let taskInfo = taskInfo(for: pid)
        let resourceUsage = resourceUsage(for: pid)
        let cacheKey = scopeCacheKey(from: bsdInfo)
        let fallbackName = fixedString(bsdInfo.pbi_comm)
        let name = includeProcessDetails ? processName(pid: pid, fallback: fallbackName) : fallbackName
        let path = includeProcessDetails ? processPath(pid: pid) : nil
        let rawTTY = Int64(bsdInfo.e_tdev)
        let ttyDevice = rawTTY > 0 ? rawTTY : nil
        let cmuxScope = includeCMUXScope
            ? cachedCMUXScope(for: pid, cacheKey: cacheKey)
            : nil
        let rawProcessGroupID = Int(bsdInfo.pbi_pgid)
        let processGroupID = rawProcessGroupID > 0 ? rawProcessGroupID : nil
        let rawTerminalProcessGroupID = Int(bsdInfo.e_tpgid)
        let terminalProcessGroupID = rawTerminalProcessGroupID > 0 ? rawTerminalProcessGroupID : nil
        let memoryBytes: Int64
        let memorySource: CmuxTopProcessMemorySource
        if let resourceUsage {
            memoryBytes = int64Clamped(resourceUsage.ri_phys_footprint)
            memorySource = .physicalFootprint
        } else if let taskInfo {
            memoryBytes = int64Clamped(taskInfo.pti_resident_size)
            memorySource = .residentSize
        } else {
            memoryBytes = 0
            memorySource = .unavailable
        }
        let residentBytes: Int64
        let residentMemorySource: CmuxTopProcessMemorySource
        if let taskInfo {
            residentBytes = int64Clamped(taskInfo.pti_resident_size)
            residentMemorySource = .residentSize
        } else if let resourceUsage {
            residentBytes = int64Clamped(resourceUsage.ri_resident_size)
            residentMemorySource = .rusageResidentSize
        } else {
            residentBytes = 0
            residentMemorySource = .unavailable
        }
        let cpuSampleKey: CmuxTopProcessScopeCacheKey?
        if let taskInfo {
            let currentCPUSample = cpuSample(from: taskInfo, sampledAtNanoseconds: sampledAtNanoseconds)
            currentCPUSamples[cacheKey] = currentCPUSample
            cpuSampleKey = cacheKey
        } else {
            cpuSampleKey = nil
        }

        return (CmuxTopProcessInfo(
            pid: pid,
            parentPID: Int(bsdInfo.pbi_ppid),
            name: name.isEmpty ? "pid-\(pid)" : name,
            path: path,
            ttyDevice: ttyDevice,
            cmuxWorkspaceID: cmuxScope?.workspaceID,
            cmuxSurfaceID: cmuxScope?.surfaceID,
            cmuxAttributionReason: cmuxScope?.attributionReason,
            processGroupID: processGroupID,
            terminalProcessGroupID: terminalProcessGroupID,
            cpuPercent: 0,
            memoryBytes: memoryBytes,
            memorySource: memorySource,
            residentBytes: residentBytes,
            residentMemorySource: residentMemorySource,
            virtualBytes: int64Clamped(taskInfo?.pti_virtual_size ?? 0),
            threadCount: Int(taskInfo?.pti_threadnum ?? 0)
        ), cpuSampleKey)
    }

    private static func allBSDProcesses() -> [proc_bsdinfo] {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let processStride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<3 {
            var requiredBytes = 0
            guard sysctl(&mib, u_int(mib.count), nil, &requiredBytes, nil, 0) == 0,
                  requiredBytes > 0 else {
                return []
            }

            // Leave room for processes spawned between the size and data calls.
            // KERN_PROC_ALL returns topology for every process in one syscall,
            // avoiding a proc_pidinfo round trip for every PID on the machine.
            let capacity = max(1, requiredBytes / processStride + 64)
            var kernelProcesses = Array(repeating: kinfo_proc(), count: capacity)
            var returnedBytes = kernelProcesses.count * processStride
            let result = kernelProcesses.withUnsafeMutableBytes { buffer in
                sysctl(
                    &mib,
                    u_int(mib.count),
                    buffer.baseAddress,
                    &returnedBytes,
                    nil,
                    0
                )
            }
            if result == 0 {
                let count = min(kernelProcesses.count, returnedBytes / processStride)
                return kernelProcesses.prefix(count).compactMap { process in
                    guard process.kp_proc.p_pid > 0 else { return nil }
                    return bsdInfo(from: process)
                }
            }
            guard errno == ENOMEM else {
                return []
            }
        }
        return []
    }

    /// Converts the bulk KERN_PROC_ALL topology record to the libproc shape used
    /// by the existing attribution and resource-sampling pipeline.
    static func bsdInfo(from process: kinfo_proc) -> proc_bsdinfo {
        var info = proc_bsdinfo()
        info.pbi_flags = UInt32(bitPattern: process.kp_proc.p_flag)
        info.pbi_status = UInt32(UInt8(bitPattern: process.kp_proc.p_stat))
        info.pbi_xstatus = UInt32(process.kp_proc.p_xstat)
        info.pbi_pid = UInt32(bitPattern: process.kp_proc.p_pid)
        info.pbi_ppid = UInt32(bitPattern: process.kp_eproc.e_ppid)
        info.pbi_uid = process.kp_eproc.e_ucred.cr_uid
        info.pbi_gid = process.kp_eproc.e_ucred.cr_groups.0
        info.pbi_ruid = process.kp_eproc.e_pcred.p_ruid
        info.pbi_rgid = process.kp_eproc.e_pcred.p_rgid
        info.pbi_svuid = process.kp_eproc.e_pcred.p_svuid
        info.pbi_svgid = process.kp_eproc.e_pcred.p_svgid
        info.pbi_pgid = UInt32(bitPattern: process.kp_eproc.e_pgid)
        info.pbi_pjobc = UInt32(max(0, process.kp_eproc.e_jobc))
        info.e_tdev = UInt32(bitPattern: process.kp_eproc.e_tdev)
        info.e_tpgid = UInt32(bitPattern: process.kp_eproc.e_tpgid)
        info.pbi_nice = Int32(process.kp_proc.p_nice)
        info.pbi_start_tvsec = UInt64(max(0, process.kp_proc.p_un.__p_starttime.tv_sec))
        info.pbi_start_tvusec = UInt64(max(0, process.kp_proc.p_un.__p_starttime.tv_usec))
        withUnsafeBytes(of: process.kp_proc.p_comm) { source in
            withUnsafeMutableBytes(of: &info.pbi_comm) { destination in
                destination.copyBytes(from: source.prefix(destination.count))
            }
        }
        return info
    }

    static func bsdInfo(for pid: Int) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        return size == expectedSize ? info : nil
    }

    private static func taskInfo(for pid: Int) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let expectedSize = MemoryLayout<proc_taskinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTASKINFO, 0, &info, Int32(expectedSize))
        return size == expectedSize ? info : nil
    }

    private static func resourceUsage(for pid: Int) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutableBytes(of: &info) { rawBuffer -> Int32 in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            // proc_pid_rusage imports as rusage_info_t *; callers pass the concrete
            // rusage struct address cast to that opaque buffer type.
            let buffer = baseAddress.assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(
                pid_t(pid),
                RUSAGE_INFO_V4,
                buffer
            )
        }
        return result == 0 ? info : nil
    }

    private static func processName(pid: Int, fallback: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN + 1))
        let length = proc_name(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return fallback }
        let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : name
    }

    private static func processPath(pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: cmuxTopPIDPathBufferSize)
        let length = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func fixedString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { rawBuffer in
            let endIndex = rawBuffer.firstIndex(of: 0) ?? rawBuffer.endIndex
            return String(decoding: rawBuffer[..<endIndex], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func int64Clamped(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}
