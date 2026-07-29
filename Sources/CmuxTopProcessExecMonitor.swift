import Darwin
import os

private struct CmuxTopMonitoredProcessIdentity: Equatable {
    let startSeconds: Int
    let startMicroseconds: Int
    let executableName: String

    init(_ cacheKey: CmuxTopProcessScopeCacheKey) {
        startSeconds = cacheKey.startSeconds
        startMicroseconds = cacheKey.startMicroseconds
        executableName = cacheKey.executableName
    }

    func isSameProcess(as other: CmuxTopMonitoredProcessIdentity) -> Bool {
        startSeconds == other.startSeconds
            && startMicroseconds == other.startMicroseconds
    }
}

// One kqueue watches every readable same-user process for exec and exit events.
// Kernel process filters survive exec. The retained identity distinguishes PID
// reuse and lets the monitor ignore changed-name execs, which already invalidate
// the scope cache through its executable-name key.
private struct CmuxTopProcessExecMonitorState {
    let queueDescriptor: Int32
    var registeredIdentitiesByPID: [Int: CmuxTopMonitoredProcessIdentity] = [:]
    var pendingExecPIDs: Set<Int> = []

    init() {
        queueDescriptor = kqueue()
    }

    mutating func synchronize(
        activeKeysByPID: [Int: CmuxTopProcessScopeCacheKey],
        watchablePIDs: Set<Int>
    ) -> Set<Int> {
        guard queueDescriptor >= 0 else { return [] }

        let execPIDs = takeExecEvents()
        var invalidatedPIDs: Set<Int> = []
        var registrations: [(pid: Int, identity: CmuxTopMonitoredProcessIdentity)] = []
        for pid in watchablePIDs {
            guard let cacheKey = activeKeysByPID[pid] else {
                continue
            }
            let identity = CmuxTopMonitoredProcessIdentity(cacheKey)
            reconcile(
                pid: pid,
                identity: identity,
                execPIDs: execPIDs,
                invalidatedPIDs: &invalidatedPIDs,
                registrations: &registrations
            )
        }
        pendingExecPIDs.formUnion(register(registrations))
        return invalidatedPIDs
    }

    mutating func synchronize(
        sampledProcesses: [proc_bsdinfo],
        scopeKeys: [CmuxTopProcessScopeCacheKey]
    ) -> Set<Int> {
        guard queueDescriptor >= 0 else { return [] }
        precondition(sampledProcesses.count == scopeKeys.count)

        let execPIDs = takeExecEvents()
        var invalidatedPIDs: Set<Int> = []
        var registrations: [(pid: Int, identity: CmuxTopMonitoredProcessIdentity)] = []
        let currentUID = getuid()
        for (index, process) in sampledProcesses.enumerated()
            where process.pbi_uid == currentUID {
            let pid = Int(process.pbi_pid)
            guard pid > 0 else { continue }
            let identity = CmuxTopMonitoredProcessIdentity(scopeKeys[index])
            reconcile(
                pid: pid,
                identity: identity,
                execPIDs: execPIDs,
                invalidatedPIDs: &invalidatedPIDs,
                registrations: &registrations
            )
        }
        pendingExecPIDs.formUnion(register(registrations))
        return invalidatedPIDs
    }

    mutating func synchronize(
        activeKeysByPID: [Int: CmuxTopProcessScopeCacheKey],
        sampledProcesses: [proc_bsdinfo]
    ) -> Set<Int> {
        guard queueDescriptor >= 0 else { return [] }

        let execPIDs = takeExecEvents()
        var invalidatedPIDs: Set<Int> = []
        var registrations: [(pid: Int, identity: CmuxTopMonitoredProcessIdentity)] = []
        let currentUID = getuid()
        for process in sampledProcesses where process.pbi_uid == currentUID {
            let pid = Int(process.pbi_pid)
            guard pid > 0,
                  let cacheKey = activeKeysByPID[pid] else {
                continue
            }
            let identity = CmuxTopMonitoredProcessIdentity(cacheKey)
            reconcile(
                pid: pid,
                identity: identity,
                execPIDs: execPIDs,
                invalidatedPIDs: &invalidatedPIDs,
                registrations: &registrations
            )
        }
        pendingExecPIDs.formUnion(register(registrations))
        return invalidatedPIDs
    }

    private mutating func reconcile(
        pid: Int,
        identity: CmuxTopMonitoredProcessIdentity,
        execPIDs: Set<Int>,
        invalidatedPIDs: inout Set<Int>,
        registrations: inout [(pid: Int, identity: CmuxTopMonitoredProcessIdentity)]
    ) {
        guard let previousIdentity = registeredIdentitiesByPID[pid],
              previousIdentity.isSameProcess(as: identity) else {
            registrations.append((pid, identity))
            return
        }
        if execPIDs.contains(pid),
           previousIdentity.executableName == identity.executableName {
            invalidatedPIDs.insert(pid)
        }
        registeredIdentitiesByPID[pid] = identity
    }

    private mutating func takeExecEvents() -> Set<Int> {
        var execPIDs = pendingExecPIDs
        pendingExecPIDs.removeAll(keepingCapacity: true)
        let capacity = 256

        for _ in 0..<64 {
            var events = Array(repeating: kevent(), count: capacity)
            var timeout = timespec(tv_sec: 0, tv_nsec: 0)
            let eventCount = events.withUnsafeMutableBufferPointer { eventBuffer in
                kevent(
                    queueDescriptor,
                    nil,
                    0,
                    eventBuffer.baseAddress,
                    Int32(eventBuffer.count),
                    &timeout
                )
            }
            guard eventCount > 0 else { break }

            for event in events.prefix(Int(eventCount)) {
                handle(event: event, execPIDs: &execPIDs)
            }
            if Int(eventCount) < capacity {
                break
            }
        }
        return execPIDs
    }

    private mutating func register(
        _ registrations: [(pid: Int, identity: CmuxTopMonitoredProcessIdentity)]
    ) -> Set<Int> {
        guard !registrations.isEmpty else { return [] }

        let registrationIdentitiesByPID = Dictionary(
            uniqueKeysWithValues: registrations.map { ($0.pid, $0.identity) }
        )
        var changes = registrations.map { registration -> kevent in
            var event = kevent()
            event.ident = UInt(registration.pid)
            event.filter = Int16(EVFILT_PROC)
            event.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR | EV_RECEIPT)
            event.fflags = UInt32(NOTE_EXEC) | UInt32(NOTE_EXIT)
            return event
        }
        var receipts = Array(repeating: kevent(), count: changes.count)
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        let receiptCount = changes.withUnsafeMutableBufferPointer { changeBuffer in
            receipts.withUnsafeMutableBufferPointer { receiptBuffer in
                kevent(
                    queueDescriptor,
                    changeBuffer.baseAddress,
                    Int32(changeBuffer.count),
                    receiptBuffer.baseAddress,
                    Int32(receiptBuffer.count),
                    &timeout
                )
            }
        }
        guard receiptCount > 0 else { return [] }

        var execPIDs: Set<Int> = []
        for receipt in receipts.prefix(Int(receiptCount)) {
            let pid = Int(receipt.ident)
            if (receipt.flags & UInt16(EV_ERROR)) != 0 {
                guard receipt.data == 0,
                      let identity = registrationIdentitiesByPID[pid] else {
                    continue
                }
                registeredIdentitiesByPID[pid] = identity
            } else {
                handle(event: receipt, execPIDs: &execPIDs)
            }
        }
        return execPIDs
    }

    private mutating func handle(event: kevent, execPIDs: inout Set<Int>) {
        guard event.filter == Int16(EVFILT_PROC) else { return }
        let pid = Int(event.ident)
        if (event.fflags & UInt32(NOTE_EXEC)) != 0 {
            execPIDs.insert(pid)
        }
        if (event.fflags & UInt32(NOTE_EXIT)) != 0 {
            registeredIdentitiesByPID.removeValue(forKey: pid)
        }
    }
}

private nonisolated let cmuxTopProcessExecMonitor = OSAllocatedUnfairLock(
    initialState: CmuxTopProcessExecMonitorState()
)

extension CmuxTopProcessSnapshot {
    static func synchronizeCMUXScopeExecMonitor(
        for sampledProcesses: [proc_bsdinfo],
        scopeKeys: [CmuxTopProcessScopeCacheKey]
    ) -> Set<Int> {
        cmuxTopProcessExecMonitor.withLock { state in
            state.synchronize(
                sampledProcesses: sampledProcesses,
                scopeKeys: scopeKeys
            )
        }
    }

    static func synchronizeCMUXScopeExecMonitor(
        activeKeysByPID: [Int: CmuxTopProcessScopeCacheKey],
        watchablePIDs: Set<Int>
    ) -> Set<Int> {
        cmuxTopProcessExecMonitor.withLock { state in
            state.synchronize(
                activeKeysByPID: activeKeysByPID,
                watchablePIDs: watchablePIDs
            )
        }
    }

    static func synchronizeCMUXScopeExecMonitor(
        activeKeysByPID: [Int: CmuxTopProcessScopeCacheKey],
        sampledProcesses: [proc_bsdinfo]
    ) -> Set<Int> {
        cmuxTopProcessExecMonitor.withLock { state in
            state.synchronize(
                activeKeysByPID: activeKeysByPID,
                sampledProcesses: sampledProcesses
            )
        }
    }

}
