import Foundation
import Darwin

enum ProcessTreeTerminator {
    // Capture descendants before signaling the parent; NumCalc jobs use separate sessions.
    static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let root = process.processIdentifier
        let query = Process()
        query.executableURL = URL(fileURLWithPath: "/bin/ps")
        query.arguments = ["-axo", "pid=,ppid="]
        let pipe = Pipe()
        query.standardOutput = pipe
        do { try query.run() } catch { process.terminate(); return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if query.isRunning { query.waitUntilExit() }
        var children: [Int32: [Int32]] = [:]
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let columns = line.split(whereSeparator: { $0.isWhitespace })
            if columns.count == 2, let pid = Int32(columns[0]), let parent = Int32(columns[1]) { children[parent, default: []].append(pid) }
        }
        var descendants: [Int32] = []
        func visit(_ pid: Int32) {
            for child in children[pid] ?? [] { visit(child); descendants.append(child) }
        }
        visit(root)
        for pid in descendants { _ = Darwin.kill(pid, SIGTERM) }
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && (process.isRunning || descendants.contains(where: { Darwin.kill($0, 0) == 0 })) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for pid in descendants where Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) }
        if process.isRunning { _ = Darwin.kill(root, SIGKILL) }
    }
}
