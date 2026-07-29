import Darwin
import Foundation

@_silgen_name("fork")
func cFork() -> pid_t

let startedAt = Date()
let queueDescriptor = kqueue()
guard queueDescriptor >= 0 else {
    fatalError("kqueue: \(String(cString: strerror(errno)))")
}

let childPID = cFork()
if childPID == 0 {
    sleep(15)
    let executable = strdup("/bin/sleep")!
    let argument = strdup("5")!
    var arguments: [UnsafeMutablePointer<CChar>?] = [executable, argument, nil]
    arguments.withUnsafeMutableBufferPointer { buffer in
        execv(executable, buffer.baseAddress!)
    }
    _exit(127)
}

let pidStride = MemoryLayout<pid_t>.stride
let processCount = Int(proc_listallpids(nil, 0))
var pids = Array(repeating: pid_t(), count: max(1, processCount + 32))
let returnedCount = pids.withUnsafeMutableBufferPointer { buffer in
    proc_listallpids(buffer.baseAddress, Int32(buffer.count * pidStride))
}

var changes: [kevent] = []
for pid in pids.prefix(Int(returnedCount)) where pid > 0 {
    var processInfo = proc_bsdinfo()
    let expectedSize = MemoryLayout<proc_bsdinfo>.stride
    guard proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        &processInfo,
        Int32(expectedSize)
    ) == expectedSize, processInfo.pbi_uid == getuid() else {
        continue
    }

    var event = kevent()
    event.ident = UInt(pid)
    event.filter = Int16(EVFILT_PROC)
    event.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR | EV_RECEIPT)
    event.fflags = UInt32(NOTE_EXEC) | UInt32(NOTE_EXIT)
    event.data = 0
    event.udata = nil
    changes.append(event)
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

let failures = receipts.prefix(max(0, Int(receiptCount))).filter {
    ($0.flags & UInt16(EV_ERROR)) != 0 && $0.data != 0
}
var childRegistration = kevent()
childRegistration.ident = UInt(childPID)
childRegistration.filter = Int16(EVFILT_PROC)
childRegistration.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR)
childRegistration.fflags = UInt32(NOTE_EXEC) | UInt32(NOTE_EXIT)
var childRegistrationTimeout = timespec(tv_sec: 0, tv_nsec: 0)
let childRegistrationResult = withUnsafeMutablePointer(to: &childRegistration) { event in
    kevent(
        queueDescriptor,
        event,
        1,
        nil,
        0,
        &childRegistrationTimeout
    )
}
for failure in failures.prefix(20) {
    print("failure ident=\(failure.ident) errno=\(failure.data)")
}
print(
    "pid=\(getpid()) candidates=\(changes.count) receipts=\(receiptCount) "
        + "failures=\(failures.count) child=\(childPID) "
        + "child_registered=\(changes.contains { $0.ident == UInt(childPID) }) "
        + "child_registration_result=\(childRegistrationResult) errno=\(errno) "
        + "elapsed=\(Date().timeIntervalSince(startedAt))"
)
fflush(stdout)

var observedChildExec = false
for _ in 0..<50 {
    var events = Array(repeating: kevent(), count: 256)
    var wait = timespec(tv_sec: 0, tv_nsec: 0)
    let eventCount = events.withUnsafeMutableBufferPointer { eventBuffer in
        kevent(
            queueDescriptor,
            nil,
            0,
            eventBuffer.baseAddress,
            Int32(eventBuffer.count),
            &wait
        )
    }
    for event in events.prefix(max(0, Int(eventCount))) {
        if event.ident == UInt(childPID) {
            print(
                "child_event ident=\(event.ident) flags=\(event.flags) "
                    + "fflags=\(event.fflags) data=\(event.data)"
            )
        }
        if event.ident == UInt(childPID),
           (event.fflags & UInt32(NOTE_EXEC)) != 0 {
            observedChildExec = true
        }
    }
    usleep(500_000)
}
print("observed_child_exec=\(observedChildExec)")
var childStatus: Int32 = 0
waitpid(childPID, &childStatus, 0)
print("child_status=\(childStatus)")
