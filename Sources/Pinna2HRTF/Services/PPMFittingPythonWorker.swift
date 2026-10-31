import Foundation
import Darwin

/// Keeps Blender and BezierPPM loaded while the user adjusts the fitting controls.
final class PPMFittingPythonWorker: @unchecked Sendable {
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let lock = NSLock()

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
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func execute(_ request: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard process.isRunning else {
            throw ProjectValidation.Failure(message: "The PPM fitting worker stopped unexpectedly.")
        }

        var line = request
        line.append(0x0A)
        try inputPipe.fileHandleForWriting.write(contentsOf: line)

        var response = Data()
        let deadline = Date().addingTimeInterval(120)
        while true {
            var descriptor = pollfd(fd: outputPipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready < 0 || Date() > deadline || !process.isRunning {
                cancel()
                throw ProjectValidation.Failure(message: "The fitting worker stopped or timed out. Reopen the editor to retry.")
            }
            if ready == 0 { continue }
            let chunk = outputPipe.fileHandleForReading.availableData
            guard !chunk.isEmpty else {
                throw ProjectValidation.Failure(message: "The PPM fitting worker closed its output unexpectedly.")
            }
            if let newline = chunk.firstIndex(of: 0x0A) {
                response.append(contentsOf: chunk[..<newline])
                return response
            }
            response.append(chunk)
        }
    }

    func cancel() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }
    deinit { cancel(); try? inputPipe.fileHandleForWriting.close() }
}
