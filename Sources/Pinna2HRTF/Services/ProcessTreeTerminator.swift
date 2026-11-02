import Foundation
import Darwin

/// Stops a process together with every descendant, including jobs that left the
/// parent's session (NumCalc is started through `setsid`) and children spawned
/// while the stop is in progress.
///
/// Procedure, repeated until nothing tracked is left:
/// 1. SIGSTOP the tree top-down and re-snapshot until no new member appears, so
///    nobody can fork or exit-and-reparent while we look.
/// 2. SIGTERM every member, then SIGCONT so the signal can be handled.
/// 3. Wait for a grace period, then SIGKILL survivors.
/// Every signal is sent only to a PID whose start time still matches the one
/// recorded when it was first seen, which guards against PID reuse.
enum ProcessTreeTerminator {
    struct Identity: Hashable {
        let pid: pid_t
        let startSeconds: Int
        let startMicroseconds: Int32
    }

    private struct Entry {
        let identity: Identity
        let parent: pid_t
        let group: pid_t
    }

    static func terminate(_ process: Process, grace: TimeInterval = 2) {
        guard process.isRunning else { return }
        terminate(rootPID: process.processIdentifier, grace: grace)
        // Foundation reaps the root; make sure a stray root never outlives us.
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    static func terminate(rootPID root: pid_t, grace: TimeInterval = 2) {
        guard root > 1, root != getpid() else { return }
        let ownGroup = getpgrp()
        let ownSession = getsid(0)
        var tracked: [pid_t: Identity] = [:]
        var groups = Set<pid_t>()
        var sessions = Set<pid_t>()

        for _ in 0..<6 {
            // 1. Freeze until the membership is stable.
            var members: [Entry] = []
            for _ in 0..<25 {
                let snapshot = Self.snapshot()
                members = collect(root: root, snapshot: snapshot, tracked: tracked, groups: groups, sessions: sessions)
                var discovered = false
                for entry in members {
                    let pid = entry.identity.pid
                    if tracked[pid] == nil { tracked[pid] = entry.identity; discovered = true }
                    if entry.group > 1, entry.group != ownGroup { groups.insert(entry.group) }
                    let session = getsid(pid)
                    if session > 1, session != ownSession { sessions.insert(session) }
                    _ = Darwin.kill(pid, SIGSTOP)
                }
                if !discovered { break }
            }
            guard !members.isEmpty else { return }

            // 2. Ask everyone to stop, then let them run their handlers.
            for entry in members { _ = Darwin.kill(entry.identity.pid, SIGTERM) }
            for entry in members { _ = Darwin.kill(entry.identity.pid, SIGCONT) }

            // 3. Grace period, then force.
            let deadline = Date().addingTimeInterval(grace)
            var survivors = alive(members.map(\.identity))
            while !survivors.isEmpty && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
                survivors = alive(survivors)
            }
            for identity in alive(survivors) { _ = Darwin.kill(identity.pid, SIGKILL) }
            Thread.sleep(forTimeInterval: 0.05)

            let remaining = collect(root: root, snapshot: Self.snapshot(), tracked: tracked, groups: groups, sessions: sessions)
            if remaining.isEmpty { return }
        }
    }

    /// Descendants of `root` (top-down), plus orphans that kept the session or
    /// process group of a member seen earlier, plus their descendants.
    private static func collect(root: pid_t, snapshot: [pid_t: Entry], tracked: [pid_t: Identity],
                                groups: Set<pid_t>, sessions: Set<pid_t>) -> [Entry] {
        var children: [pid_t: [pid_t]] = [:]
        for entry in snapshot.values { children[entry.parent, default: []].append(entry.identity.pid) }
        let me = getpid()
        func acceptable(_ entry: Entry) -> Bool {
            let pid = entry.identity.pid
            guard pid > 1, pid != me else { return false }
            // A PID seen before must still be the same process.
            if let known = tracked[pid], known != entry.identity { return false }
            return true
        }
        var seeds: [pid_t] = []
        if let rootEntry = snapshot[root], acceptable(rootEntry) { seeds.append(root) }
        for entry in snapshot.values where entry.parent == 1 && entry.identity.pid != root && acceptable(entry) {
            if groups.contains(entry.group) || tracked[entry.identity.pid] != nil { seeds.append(entry.identity.pid); continue }
            if !sessions.isEmpty, sessions.contains(getsid(entry.identity.pid)) { seeds.append(entry.identity.pid) }
        }
        var result: [Entry] = []
        var visited = Set<pid_t>()
        var queue = seeds
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard visited.insert(pid).inserted, let entry = snapshot[pid], acceptable(entry) else { continue }
            result.append(entry)
            queue += children[pid] ?? []
        }
        return result
    }

    private static func alive(_ identities: [Identity]) -> [Identity] {
        let snapshot = Self.snapshot()
        return identities.filter { snapshot[$0.pid]?.identity == $0 }
    }

    /// Live (non-zombie) processes keyed by PID.
    private static func snapshot() -> [pid_t: Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [:] }
            size += size / 4 + MemoryLayout<kinfo_proc>.stride * 16
            let capacity = size / MemoryLayout<kinfo_proc>.stride
            var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            let status = processes.withUnsafeMutableBufferPointer { buffer in
                sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &size, nil, 0)
            }
            if status != 0 {
                if errno == ENOMEM { continue }
                return [:]
            }
            var result: [pid_t: Entry] = [:]
            for info in processes.prefix(size / MemoryLayout<kinfo_proc>.stride) {
                guard info.kp_proc.p_stat != CChar(SZOMB) else { continue }
                let start = info.kp_proc.p_un.__p_starttime
                let identity = Identity(pid: info.kp_proc.p_pid, startSeconds: start.tv_sec, startMicroseconds: start.tv_usec)
                result[identity.pid] = Entry(identity: identity, parent: info.kp_eproc.e_ppid, group: info.kp_eproc.e_pgid)
            }
            return result
        }
        return [:]
    }
}
