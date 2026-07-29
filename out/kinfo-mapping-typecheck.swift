import Darwin

func bsdInfo(from process: kinfo_proc) -> proc_bsdinfo {
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

func allBSDProcesses() -> [proc_bsdinfo] {
    var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    let processStride = MemoryLayout<kinfo_proc>.stride
    var requiredBytes = 0
    guard sysctl(&mib, u_int(mib.count), nil, &requiredBytes, nil, 0) == 0 else {
        return []
    }
    var kernelProcesses = Array(
        repeating: kinfo_proc(),
        count: max(1, requiredBytes / processStride + 64)
    )
    var returnedBytes = kernelProcesses.count * processStride
    let result = kernelProcesses.withUnsafeMutableBytes { buffer in
        sysctl(&mib, u_int(mib.count), buffer.baseAddress, &returnedBytes, nil, 0)
    }
    guard result == 0 else { return [] }
    return kernelProcesses.prefix(returnedBytes / processStride).map(bsdInfo(from:))
}
