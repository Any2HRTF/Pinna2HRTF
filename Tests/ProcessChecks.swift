import Foundation

enum ProcessChecks {
    static func run(in folder: URL) throws {
        let log = folder.appendingPathComponent("process.log")
        let done = DispatchSemaphore(value: 0)
        let eventReceived = DispatchSemaphore(value: 0)
        let capture = try PipelineLogCapture(fileURL: log, header: "", onEvent: { event in
            precondition(event.message == "finished")
            eventReceived.signal()
        }, onFailure: { message in
            preconditionFailure(message)
        })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'stdout\\n'; printf 'stderr\\n' >&2; printf '@@PINNA2HRTF_EVENT@@{\"message\":\"finished\"}'"]
        try process.run(capturing: capture) { _ in done.signal() }
        precondition(done.wait(timeout: .now() + 10) == .success)
        precondition(eventReceived.wait(timeout: .now()) == .success)
        precondition(eventReceived.wait(timeout: .now()) == .timedOut)
        let text = try String(contentsOf: log, encoding: .utf8)
        precondition(text.contains("stdout\n") && text.contains("stderr\n"))
        precondition(text.hasSuffix("{\"message\":\"finished\"}"))

        // A missing technical log must not stop draining a full stdout pipe.
        let unlogged = Process()
        unlogged.executableURL = URL(fileURLWithPath: "/usr/bin/head")
        unlogged.arguments = ["-c", "200000", "/dev/zero"]
        try unlogged.run(capturing: nil) { _ in done.signal() }
        precondition(done.wait(timeout: .now() + 10) == .success)
        precondition(unlogged.terminationStatus == 0)

        let invalid = Process()
        invalid.executableURL = folder.appendingPathComponent("missing-executable")
        do {
            try invalid.run(capturing: capture) { _ in preconditionFailure("An unstarted process completed") }
            preconditionFailure("Missing executable should fail")
        } catch { precondition(invalid.terminationHandler == nil) }

        let cancelled = Process()
        cancelled.executableURL = URL(fileURLWithPath: "/bin/sleep")
        cancelled.arguments = ["30"]
        try cancelled.run(capturing: nil) { _ in done.signal() }
        ProcessTreeTerminator.terminate(cancelled)
        precondition(done.wait(timeout: .now() + 10) == .success)
        precondition(!cancelled.isRunning && cancelled.terminationStatus != 0)
        print("Process output draining, launch failure and cancellation checks passed.")
    }
}
