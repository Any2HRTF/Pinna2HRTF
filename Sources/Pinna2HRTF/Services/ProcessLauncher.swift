import Foundation
import Darwin

/// Single entry point for every subprocess the app starts.
///
/// It builds the Python/uv command lines (packaged app: bundled interpreter;
/// development: `uv run --no-sync` in the source tree), registers each running
/// process so it can be cancelled and is stopped with its whole process tree on
/// quit, and applies timeouts to short helper calls.
final class ProcessLauncher: @unchecked Sendable {
    static let shared = ProcessLauncher()

    enum Command {
        /// `Pinna2HRTF <stage> --config <file>`
        case pipelineStage(Stage, config: URL)
        /// `python <arguments>` in the pipeline environment.
        case python([String])
        /// `uv sync --no-editable` (development builds only).
        case uvSync
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct HelperResult {
        let status: Int32
        let output: Data
        var text: String { String(decoding: output, as: UTF8.self) }
    }

    private let lock = NSLock()
    private var tracked: [ObjectIdentifier: Process] = [:]
    private var terminating = false

    // MARK: Command construction

    static var packageURL: URL { Defaults.pipelineRoot }
    static var runtimePythonURL: URL { packageURL.appendingPathComponent(".venv/bin/python") }

    static func command(_ command: Command, environment: EnvironmentConfig) throws -> (executable: URL, arguments: [String]) {
        let bundledUV = FileManager.default.isExecutableFile(atPath: environment.uvExecutable)
        func uvCommand() throws -> (URL, [String]) {
            if bundledUV { return (URL(fileURLWithPath: environment.uvExecutable), []) }
            if environment.uvIsExplicit == true {
                throw Failure(message: "The selected uv executable is unavailable. Check the path in Settings.")
            }
            return (URL(fileURLWithPath: "/usr/bin/env"), ["uv"])
        }
        let python = environment.pythonExecutable.map { URL(fileURLWithPath: $0) }
        switch command {
        case .pipelineStage(let stage, let config):
            if let python { return (python, ["-m", "HRTFCalculation", stage.rawValue, "--config", config.path]) }
            if Defaults.isPackagedApp {
                return (runtimePythonURL, ["-m", "HRTFCalculation", stage.rawValue, "--config", config.path])
            }
            let uv = try uvCommand()
            return (uv.0, uv.1 + ["run", "--no-sync", "Pinna2HRTF", stage.rawValue, "--config", config.path])
        case .python(let arguments):
            if let python { return (python, arguments) }
            if Defaults.isPackagedApp { return (runtimePythonURL, arguments) }
            let uv = try uvCommand()
            return (uv.0, uv.1 + ["run", "--no-sync", "python"] + arguments)
        case .uvSync:
            let uv = try uvCommand()
            guard bundledUV || Defaults.which("uv") != nil else {
                throw Failure(message: "UV is missing. Install uv for development or use the self-contained release app.")
            }
            return (uv.0, uv.1 + ["sync", "--no-editable"])
        }
    }

    static func processEnvironment(_ environment: EnvironmentConfig, rootURL: URL = Defaults.runtimeRoot) -> [String: String] {
        var values = ProcessInfo.processInfo.environment
        let appData = Defaults.appDataURL
        values["PINNA2HRTF_ROOT"] = rootURL.path
        values["MPLCONFIGDIR"] = appData.appendingPathComponent("Cache/matplotlib").path
        values["PYTHONPYCACHEPREFIX"] = appData.appendingPathComponent("Cache/python").path
        values["PYTHONNOUSERSITE"] = "1"
        values["BLENDER_USER_CONFIG"] = appData.appendingPathComponent("Blender/config").path
        values["BLENDER_USER_SCRIPTS"] = appData.appendingPathComponent("Blender/scripts").path
        values["BLENDER_USER_DATAFILES"] = appData.appendingPathComponent("Blender/datafiles").path
        if !Defaults.isPackagedApp {
            values["UV_CACHE_DIR"] = appData.appendingPathComponent("Cache/uv").path
        }
        values["PYTHONPATH"] = packageURL.path
        values["PATH"] = URL(fileURLWithPath: environment.externalDir).appendingPathComponent("bin").path
            + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (values["PATH"] ?? "")
        return values
    }

    /// A configured, not yet started process for `command`.
    func makeProcess(_ command: Command, environment: EnvironmentConfig, liveEvents: Bool = false) throws -> Process {
        let resolved = try Self.command(command, environment: environment)
        let process = Process()
        process.executableURL = resolved.executable
        process.arguments = resolved.arguments
        process.currentDirectoryURL = Self.packageURL
        var values = Self.processEnvironment(environment)
        if liveEvents { values["PINNA2HRTF_LIVE_EVENTS"] = "1" }
        process.environment = values
        return process
    }

    // MARK: Tracking

    var hasRunningProcesses: Bool {
        lock.lock(); defer { lock.unlock() }
        return tracked.values.contains { $0.isRunning }
    }

    func register(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        tracked[ObjectIdentifier(process)] = process
    }

    func unregister(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        tracked[ObjectIdentifier(process)] = nil
    }

    /// Starts `process` with combined output captured into `capture` and keeps
    /// it registered until it exits.
    func launch(_ process: Process, capturing capture: PipelineLogCapture?, onExit: @escaping @Sendable (Process) -> Void) throws {
        try refuseWhileTerminating()
        register(process)
        do {
            try process.run(capturing: capture) { [weak self] process in
                self?.unregister(process)
                onExit(process)
            }
        } catch {
            unregister(process)
            throw error
        }
    }

    /// Starts `process` (its I/O already configured) and keeps it registered
    /// until it exits. Any termination handler already set is preserved.
    func launch(_ process: Process) throws {
        try refuseWhileTerminating()
        let previous = process.terminationHandler
        process.terminationHandler = { [weak self] process in
            self?.unregister(process)
            previous?(process)
        }
        register(process)
        do { try process.run() } catch {
            unregister(process)
            process.terminationHandler = previous
            throw error
        }
    }

    /// Runs a short helper to completion on the calling thread, collecting
    /// stdout and stderr together. The helper and its children are stopped
    /// when `timeout` elapses.
    func runHelper(_ process: Process, timeout: TimeInterval) throws -> HelperResult {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let reader = pipe.fileHandleForReading
        let stopReading = LockedValue(Date.distantFuture)
        let output = LockedValue(Data())
        let readerDone = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try launch(process)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = Self.drain(reader.fileDescriptor) { stopReading.value }
            output.value = data
            readerDone.signal()
        }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            ProcessTreeTerminator.terminate(process)
            _ = exited.wait(timeout: .now() + 5)
        }
        // A grandchild can keep the pipe open; stop reading shortly after exit.
        stopReading.value = Date().addingTimeInterval(2)
        readerDone.wait()
        try? reader.close()
        if timedOut {
            throw Failure(message: "The helper did not finish within \(Int(timeout)) seconds and was stopped.")
        }
        return HelperResult(status: process.terminationStatus, output: output.value)
    }

    /// Async wrapper around `runHelper` that never blocks the caller's thread.
    func runHelperAsync(_ process: Process, timeout: TimeInterval) async throws -> HelperResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try self.runHelper(process, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: Cancellation

    /// Stops `process` and its descendants on a background queue.
    func cancel(_ process: Process, completion: (@Sendable () -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessTreeTerminator.terminate(process)
            completion?()
        }
    }

    /// Stops every tracked process tree. Blocks until all are gone; used on quit.
    func terminateAll() {
        lock.lock()
        terminating = true
        let processes = Array(tracked.values)
        lock.unlock()
        let group = DispatchGroup()
        for process in processes where process.isRunning {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                ProcessTreeTerminator.terminate(process)
            }
        }
        _ = group.wait(timeout: .now() + 15)
    }

    private func refuseWhileTerminating() throws {
        lock.lock(); defer { lock.unlock() }
        if terminating { throw Failure(message: "The app is quitting.") }
    }

    /// Reads what is already buffered in `descriptor` without blocking past `deadline`.
    /// Stops at EOF or when the deadline passes (a grandchild may still hold the pipe).
    static func drain(_ descriptor: Int32, deadline: Date) -> Data {
        drain(descriptor) { deadline }
    }

    /// Reads until EOF or until the (re-evaluated) deadline passes.
    static func drain(_ descriptor: Int32, until deadline: () -> Date) -> Data {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = deadline().timeIntervalSinceNow
            if remaining <= 0 { break }
            var descriptorPoll = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptorPoll, 1, Int32(max(1, min(remaining, 0.25) * 1000)))
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 { continue }
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { result.append(contentsOf: buffer[0..<count]); continue }
            if count == 0 { break }
            if errno == EAGAIN || errno == EINTR { continue }
            break
        }
        return result
    }
}

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
