import Foundation

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
        while true {
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

    deinit {
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}
