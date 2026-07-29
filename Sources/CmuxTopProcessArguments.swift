import Darwin
import Foundation
import os

private struct CmuxTopKernProcArgsBufferPool {
    var buffers: [[UInt8]] = []
}

private nonisolated let cmuxTopKernProcArgsBufferPool = OSAllocatedUnfairLock(
    initialState: CmuxTopKernProcArgsBufferPool()
)
// KERN_PROCARGS2 reports a kernel-sized capacity, commonly much larger than the
// returned argv/environment. Reuse a bounded number of those scratch buffers so
// recurring discovery scans do not dirty a fresh allocator region per process.
private nonisolated let cmuxTopKernProcArgsMaximumRetainedBuffers = 4

struct CmuxTopProcessArguments: Sendable {
    let arguments: [String]
    let environment: [String: String]
}

extension CmuxTopProcessSnapshot {
    static func processArgumentsAndEnvironment(for pid: Int) -> CmuxTopProcessArguments? {
        guard pid > 0, pid <= Int(Int32.max) else {
            return nil
        }
        let parsed: CmuxTopProcessArguments?? = withKernProcArgsBytes(for: pid) { bytes in
            processArgumentsAndEnvironment(fromKernProcArgsBuffer: bytes)
        }
        return parsed ?? nil
    }

    static func processArgumentsAndEnvironment(fromKernProcArgs bytes: [UInt8]) -> CmuxTopProcessArguments? {
        bytes.withUnsafeBufferPointer { buffer in
            processArgumentsAndEnvironment(fromKernProcArgsBuffer: buffer)
        }
    }

    private static func processArgumentsAndEnvironment(
        fromKernProcArgsBuffer bytes: UnsafeBufferPointer<UInt8>
    ) -> CmuxTopProcessArguments? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { rawBuffer in
            rawBuffer.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size))
        }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        skipString(in: bytes, index: &index)
        skipNulls(in: bytes, index: &index)

        var arguments: [String] = []
        for _ in 0..<argc {
            guard index < bytes.count else { return nil }
            let start = index
            skipString(in: bytes, index: &index)
            if let argument = String(bytes: bytes[start..<index], encoding: .utf8) {
                arguments.append(argument)
            }
            consumeTerminatingNull(in: bytes, index: &index)
        }

        var environment: [String: String] = [:]
        while index < bytes.count {
            skipNulls(in: bytes, index: &index)
            guard index < bytes.count else { break }
            let start = index
            skipString(in: bytes, index: &index)
            guard start < index,
                  let entry = String(bytes: bytes[start..<index], encoding: .utf8),
                  let equals = entry.firstIndex(of: "=") else {
                continue
            }
            let key = String(entry[..<equals])
            guard !key.isEmpty else { continue }
            environment[key] = String(entry[entry.index(after: equals)...])
        }

        return CmuxTopProcessArguments(arguments: arguments, environment: environment)
    }

    static func withKernProcArgsBytes<Result>(
        for pid: Int,
        _ body: (UnsafeBufferPointer<UInt8>) -> Result
    ) -> Result? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return nil
        }

        var buffer = cmuxTopKernProcArgsBufferPool.withLock { pool in
            pool.buffers.popLast() ?? []
        }
        if buffer.count < size {
            buffer = [UInt8](repeating: 0, count: size)
        }
        defer {
            cmuxTopKernProcArgsBufferPool.withLock { pool in
                guard pool.buffers.count < cmuxTopKernProcArgsMaximumRetainedBuffers else {
                    return
                }
                pool.buffers.append(buffer)
            }
        }

        size = buffer.count
        let success = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &size, nil, 0) == 0
        }
        guard success,
              size > MemoryLayout<Int32>.size,
              size <= buffer.count else {
            return nil
        }
        return buffer.withUnsafeBufferPointer { rawBuffer in
            body(
                UnsafeBufferPointer(
                    start: rawBuffer.baseAddress,
                    count: Int(size)
                )
            )
        }
    }

    private static func skipString(in bytes: UnsafeBufferPointer<UInt8>, index: inout Int) {
        while index < bytes.count, bytes[index] != 0 {
            index += 1
        }
    }

    private static func skipNulls(in bytes: UnsafeBufferPointer<UInt8>, index: inout Int) {
        while index < bytes.count, bytes[index] == 0 {
            index += 1
        }
    }

    private static func consumeTerminatingNull(in bytes: UnsafeBufferPointer<UInt8>, index: inout Int) {
        if index < bytes.count, bytes[index] == 0 {
            index += 1
        }
    }
}
