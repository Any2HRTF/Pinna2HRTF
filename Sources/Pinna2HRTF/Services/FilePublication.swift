import Foundation

/// Publish a set only after every replacement has been staged on its destination volume.
enum FilePublication {
    static func publish(_ files: [(URL, URL)]) throws {
        let fm = FileManager.default
        let transaction = UUID().uuidString
        var staged: [(URL, URL, URL)] = []
        var installed: [(URL, URL)] = []
        do {
            for (source, destination) in files {
                let parent = destination.deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                let next = parent.appendingPathComponent(".pinna-stage-\(transaction)-\(destination.lastPathComponent)")
                let backup = parent.appendingPathComponent(".pinna-backup-\(transaction)-\(destination.lastPathComponent)")
                staged.append((next, destination, backup))
                try fm.copyItem(at: source, to: next)
            }
            for (next, destination, backup) in staged {
                if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: backup) }
                installed.append((destination, backup))
                try fm.moveItem(at: next, to: destination)
            }
        } catch {
            for (destination, backup) in installed.reversed() {
                if fm.fileExists(atPath: backup.path) {
                    try? fm.removeItem(at: destination)
                    try? fm.moveItem(at: backup, to: destination)
                } else { try? fm.removeItem(at: destination) }
            }
            for (next, _, _) in staged { try? fm.removeItem(at: next) }
            throw error
        }
        for (_, _, backup) in staged { try? fm.removeItem(at: backup) }
    }
}
