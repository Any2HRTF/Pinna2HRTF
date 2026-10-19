import Foundation

struct PipelineLogEvent: Decodable, Sendable {
    var message: String
    var level: String?
    var key: String?
}

/// Saves the complete child-process stream and extracts only explicit progress events.
final class PipelineLogCapture: @unchecked Sendable {
    static let eventPrefix = "@@PINNA2HRTF_EVENT@@"

    let fileURL: URL
    private let queue = DispatchQueue(label: "Pinna2HRTF.pipeline-log-capture")
    private let onEvent: (PipelineLogEvent) -> Void
    private let onFailure: (String) -> Void
    private var fileHandle: FileHandle?
    private var pendingLine = Data()
    private var didReportFailure = false

    init(fileURL: URL, header: String, onEvent: @escaping (PipelineLogEvent) -> Void, onFailure: @escaping (String) -> Void) throws {
        self.fileURL = fileURL
        self.onEvent = onEvent
        self.onFailure = onFailure
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(header.utf8).write(to: fileURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        fileHandle = handle
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.sync {
            do {
                try fileHandle?.write(contentsOf: data)
            } catch {
                reportFailure(error)
            }
            pendingLine.append(data)
            consumeCompleteLines()
        }
    }

    func finish() {
        queue.sync {
            if !pendingLine.isEmpty {
                consume(pendingLine)
                pendingLine.removeAll(keepingCapacity: false)
            }
            do {
                try fileHandle?.synchronize()
            } catch {
                reportFailure(error)
            }
            fileHandle?.closeFile()
            fileHandle = nil
        }
    }

    private func consumeCompleteLines() {
        while let newline = pendingLine.firstIndex(of: 0x0A) {
            consume(Data(pendingLine[..<newline]))
            pendingLine.removeSubrange(...newline)
        }
    }

    private func consume(_ data: Data) {
        let line = String(decoding: data, as: UTF8.self)
        guard line.hasPrefix(Self.eventPrefix) else { return }
        let json = line.dropFirst(Self.eventPrefix.count)
        guard let payload = json.data(using: .utf8), let event = try? JSONDecoder().decode(PipelineLogEvent.self, from: payload), !event.message.isEmpty else { return }
        onEvent(event)
    }

    private func reportFailure(_ error: Error) {
        guard !didReportFailure else { return }
        didReportFailure = true
        onFailure(error.localizedDescription)
    }
}
