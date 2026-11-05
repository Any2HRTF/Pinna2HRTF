import Foundation
import Darwin

/// Keeps Blender and BezierPPM loaded while the user adjusts the fitting controls.
///
/// Protocol: one JSON object per line on stdin, exactly one JSON object per line
/// on stdout in reply. Bytes after a newline are kept for the next request, and
/// lines that are not JSON objects (stray library output) are logged and skipped,
/// so one request always pairs with one reply.
final class PPMFittingPythonWorker: @unchecked Sendable {
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private let stopped = LockedValue(false)

    init(pythonURL: URL, workingDirectory: URL) throws {
        process.executableURL = pythonURL
        process.arguments = ["-B", "-c", """
        import contextlib, sys
        with contextlib.redirect_stdout(sys.stderr):
            from HRTFCalculation.ManualPPMFitting import serve
        serve()
        """]
        process.currentDirectoryURL = workingDirectory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            NSLog("Pinna2HRTF PPM worker: %@", String(decoding: data.prefix(8192), as: UTF8.self))
        }
        try ProcessLauncher.shared.launch(process)
    }

    var isRunning: Bool {
        !stopped.value && process.isRunning
    }

    func execute(_ request: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard !stopped.value, process.isRunning else {
            throw ProjectValidation.Failure(message: "The PPM fitting worker stopped unexpectedly. Reopen the editor to retry.")
        }

        var line = request
        line.append(0x0A)
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: line)
        } catch {
            // EPIPE (SIGPIPE is ignored app-wide): the worker is gone.
            stopLocked()
            throw ProjectValidation.Failure(message: "The PPM fitting worker stopped unexpectedly. Reopen the editor to retry.")
        }

        let descriptor = outputPipe.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(120)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let candidate = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if let reply = Self.jsonReply(candidate) { return reply }
                if !candidate.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                    NSLog("Pinna2HRTF: ignored non-JSON PPM worker output: %@", String(decoding: candidate.prefix(500), as: UTF8.self))
                }
            }
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 250)
            if ready < 0 && errno == EINTR { continue }
            if ready < 0 || Date() > deadline || (ready == 0 && !process.isRunning) {
                // A late reply would pair with the next request, so the worker cannot be reused.
                stopLocked()
                throw ProjectValidation.Failure(message: "The fitting worker stopped or timed out. Reopen the editor to retry.")
            }
            if ready == 0 { continue }
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count < 0 && (errno == EINTR || errno == EAGAIN) {
                continue
            } else {
                stopLocked()
                throw ProjectValidation.Failure(message: "The PPM fitting worker closed its output unexpectedly.")
            }
        }
    }

    private static func jsonReply(_ line: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: line), object is [String: Any] else { return nil }
        return line
    }

    /// Safe to call from any thread while a request is in flight; the pending
    /// `execute` then fails promptly because the worker's output closes.
    func cancel() { stop() }

    private func stopLocked() {
        buffer.removeAll()
        stop()
    }

    private func stop() {
        stopped.value = true
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        ProcessLauncher.shared.unregister(process)
    }

    deinit {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        ProcessLauncher.shared.unregister(process)
        try? inputPipe.fileHandleForWriting.close()
    }
}
