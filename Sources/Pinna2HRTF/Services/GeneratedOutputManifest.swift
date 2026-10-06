import Foundation
import CryptoKit
import Darwin

// Same producer conventions and JSON schema as the Windows app. Only unchanged,
// owned files are deleted; directories are removed only when empty.
final class GeneratedOutputManifest {
    enum OutputStage: String, Codable, CaseIterable {
        case inference = "Inference", preprocessing = "Preprocessing"
        case numcalc = "Numcalc", postprocessing = "Postprocessing"
        var order: Int { Self.allCases.firstIndex(of: self)! }
    }
    struct Entry: Codable {
        var Stage: OutputStage = .inference
        var Size: Int64
        var ModifiedUtcTicks: Int64
        var Sha256 = ""
    }
    struct PendingRun: Codable {
        var Stage: OutputStage
        var Before: [String: Entry]
        var Directories: [String]
    }
    struct Document: Codable {
        var Version = 1
        var Files: [String: Entry] = [:]
        var Directories: [String: OutputStage] = [:]
        var Pending: PendingRun?
    }
    struct ResetResult {
        var deleted = 0, modified = 0, nonEmpty = 0, errors = 0
        var success: Bool { modified == 0 && errors == 0 }
        var summary: String {
            "Outputs reset (all): deleted \(deleted), kept modified \(modified), kept non-empty directories \(nonEmpty), errors \(errors)."
        }
    }
    enum Failure: LocalizedError {
        case invalidRoot, unsafePath, busy, invalidManifest, changingFile
        var errorDescription: String? {
            switch self {
            case .invalidRoot: "Choose a separate project output folder."
            case .unsafePath: "Linked or protected output paths cannot be managed automatically."
            case .busy: "Project outputs are busy."
            case .invalidManifest: "The generated-output manifest is invalid or unsupported."
            case .changingFile: "An output file is still changing."
            }
        }
    }
    private let root: URL
    private let inputs: [String]
    private let gate = NSLock()
    private var runLock: Int32?
    private let fm = FileManager.default
    private var metadata: URL { root.appendingPathComponent(".pinna2hrtf") }
    private var manifest: URL { metadata.appendingPathComponent("generated-output-manifest.json") }

    init(projectRoot: String, inputs: [String]) throws {
        guard !projectRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidRoot }
        // standardizedFileURL rewrites /private/tmp through the /tmp symlink.
        // Keep the caller's path so link checks inspect the actual output root.
        root = URL(fileURLWithPath: projectRoot)
        guard root.path != "/" else { throw Failure.invalidRoot }
        self.inputs = inputs.filter { !$0.isEmpty }.map { Self.canonicalPath($0).lowercased() }
    }
    deinit { if let fd = runLock { close(fd) } }

    func begin(_ stage: OutputStage) throws {
        gate.lock(); defer { gate.unlock() }
        guard runLock == nil else { throw Failure.busy }
        let lease = try acquire()
        do {
            var doc = try load()
            try capture(&doc)
            try reconcile(&doc)
            let before = try scan()
            doc.Pending = PendingRun(Stage: stage, Before: before.files, Directories: Array(before.directories))
            try save(doc)
            runLock = lease
        } catch { close(lease); throw error }
    }

    func complete() throws {
        gate.lock(); defer { gate.unlock() }
        guard let lease = runLock else { return }
        defer { close(lease); runLock = nil }
        var doc = try load()
        try capture(&doc)
        try save(doc)
    }

    func reset() -> ResetResult {
        gate.lock(); defer { gate.unlock() }
        var result = ResetResult()
        do {
            guard runLock == nil else { throw Failure.busy }
            guard fm.fileExists(atPath: root.path) else { return result }
            let lease = try acquire(); defer { close(lease) }
            var doc = try load()
            try capture(&doc)
            try reconcile(&doc)
            try save(doc)
            for (relative, entry) in doc.Files {
                guard let url = safePath(relative) else { result.errors += 1; continue }
                do {
                    guard fm.fileExists(atPath: url.path) else { doc.Files.removeValue(forKey: relative); continue }
                    let actual = try fingerprint(url)
                    guard actual.Sha256.caseInsensitiveCompare(entry.Sha256) == .orderedSame else { result.modified += 1; continue }
                    guard safePath(relative) != nil, try fileMetadata(url).ModifiedUtcTicks == actual.ModifiedUtcTicks else { throw Failure.changingFile }
                    try fm.removeItem(at: url)
                    doc.Files.removeValue(forKey: relative)
                    result.deleted += 1
                } catch { result.errors += 1 }
            }
            let directories = Set(doc.Directories.keys).union(try scan().directories.filter { Self.classifyEmptyDirectory($0) != nil })
            for relative in directories.sorted(by: { $0.count > $1.count }) {
                guard let url = safePath(relative) else { result.errors += 1; continue }
                do {
                    guard fm.fileExists(atPath: url.path) else { doc.Directories.removeValue(forKey: relative); continue }
                    guard !inputs.contains(where: { $0.hasPrefix(Self.canonicalPath(url.path).lowercased() + "/") }), try fm.contentsOfDirectory(atPath: url.path).isEmpty else { result.nonEmpty += 1; continue }
                    // POSIX rmdir cannot recursively delete files added concurrently.
                    guard rmdir(url.path) == 0 else { throw Failure.changingFile }
                    doc.Directories.removeValue(forKey: relative)
                } catch { result.errors += 1 }
            }
            try save(doc)
        } catch { result.errors += 1 }
        return result
    }

    private func capture(_ doc: inout Document) throws {
        guard let pending = doc.Pending else { return }
        let after = try scan()
        for (relative, entry) in after.files {
            if let before = pending.Before[relative] {
                if before.Size == entry.Size && before.ModifiedUtcTicks == entry.ModifiedUtcTicks { continue }
                guard let owned = doc.Files[relative], owned.Size == before.Size, owned.ModifiedUtcTicks == before.ModifiedUtcTicks else { continue }
            }
            guard let stage = Self.classify(relative), let url = safePath(relative) else { continue }
            if pending.Stage == .inference && stage != .inference { continue }
            if pending.Stage == .postprocessing && stage != .postprocessing { continue }
            var owned = try fingerprint(url); owned.Stage = stage
            doc.Files[relative] = owned
        }
        for relative in after.directories.subtracting(pending.Directories) where Self.directoryCanBeCreated(relative, by: pending.Stage) {
            if doc.Directories[relative] == nil { doc.Directories[relative] = pending.Stage }
        }
        removeMissing(&doc)
        try trackDirectories(&doc, directories: after.directories)
        doc.Pending = nil
    }

    private func reconcile(_ doc: inout Document) throws {
        let current = try scan()
        for relative in current.files.keys {
            guard doc.Files[relative] == nil, let stage = Self.classify(relative), let url = safePath(relative) else { continue }
            var entry = try fingerprint(url); entry.Stage = stage
            doc.Files[relative] = entry
        }
        removeMissing(&doc)
        try trackDirectories(&doc, directories: current.directories)
    }
    private func removeMissing(_ doc: inout Document) {
        for relative in doc.Files.keys {
            if let url = safePath(relative), !fm.fileExists(atPath: url.path) { doc.Files.removeValue(forKey: relative) }
        }
        for relative in doc.Directories.keys {
            if let url = safePath(relative), !fm.fileExists(atPath: url.path) { doc.Directories.removeValue(forKey: relative) }
        }
    }
    private func trackDirectories(_ doc: inout Document, directories: Set<String>) throws {
        for relative in directories {
            let stages = doc.Files.filter { $0.key.hasPrefix(relative + "/") }.map { $0.value.Stage }
            if let first = stages.min(by: { $0.order < $1.order }) {
                if doc.Directories[relative] == nil || first.order < doc.Directories[relative]!.order { doc.Directories[relative] = first }
            } else if doc.Directories[relative] == nil, let stage = Self.classifyEmptyDirectory(relative), let url = safePath(relative), try fm.contentsOfDirectory(atPath: url.path).isEmpty {
                doc.Directories[relative] = stage
            }
        }
    }

    private static func match(_ path: String, _ pattern: String) -> Bool {
        path.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func classify(_ path: String) -> OutputStage? {
        if match(path, #"^\.pinna2hrtf_native_run\.yaml$"#) || match(path, #"^(Intermediates/)?Results Inference\.csv$"#) ||
            match(path, #"^Intermediates/(Left|Right)/(ICP_[^/]+\.stl|Prediction_[^/]+\.stl|Prediction_Parameters_[^/]+\.csv)$"#) ||
            match(path, #"^(Intermediates/)?(Prediction STL|Prediction Parameters|ICP STL) (Left|Right)/[^/]+\.(stl|csv)$"#) { return .inference }
        if match(path, #"^Intermediates/(Left|Right)/(input_ear\.stl|source_landmark\.json|closed_ear\.stl|cut_head\.stl|stitched_head\.stl|graded_head\.ply|dummy_head\.stl)$"#) ||
            match(path, #"^Intermediates/dummy_head\.stl$"#) ||
            match(path, #"^Projects/(Left|Right)/(parameters\.json|3d Model\.blend[0-9]*|NumCalc/source_[0-9]+/NC\.inp|(ObjectMeshes|EvaluationGrids)/[^/]+/(Nodes|Elements)\.txt)$"#) ||
            match(path, #"^\.pinna2hrtf-preprocessing-signature$"#) { return .preprocessing }
        if match(path, #"^Projects/(Left|Right)/NumCalc/source_[0-9]+/(NC[0-9]+-[0-9]+_log\.txt|NC([0-9]+-[0-9]+|from[0-9]+|until[0-9]+)?\.out|Memory\.txt|be\.out/be\.[0-9]+/(pBoundary|pEvalGrid|vBoundary|vEvalGrid))$"#) { return .numcalc }
        if match(path, #"^(HRTF|Projects/(Left|Right)/Output2HRTF)/(HRIR|HRTF)_[^/]+\.(sofa|png|jpg|jpeg|pdf)$"#) ||
            match(path, #"^Projects/(Left|Right)/Output2HRTF/(report_source_[0-9]+\.csv|report_issues\.(txt|csv))$"#) { return .postprocessing }
        return nil
    }
    private static func classifyEmptyDirectory(_ path: String) -> OutputStage? {
        if match(path, #"^Intermediates$"#) || match(path, #"^(Prediction STL|Prediction Parameters|ICP STL) (Left|Right)$"#) { return .inference }
        if match(path, #"^Projects/(Left|Right)/NumCalc/source_[0-9]+/be\.out(/be\.[0-9]+)?$"#) { return .numcalc }
        if match(path, #"^Intermediates/(Left|Right)$"#) || match(path, #"^Projects$"#) ||
            match(path, #"^Projects/(Left|Right)(/(ObjectMeshes|EvaluationGrids|NumCalc)(/.*)?)?$"#) { return .preprocessing }
        if match(path, #"^HRTF(/.*)?$"#) || match(path, #"^Projects/(Left|Right)/Output2HRTF(/.*)?$"#) { return .postprocessing }
        return nil
    }
    private static func directoryCanBeCreated(_ path: String, by stage: OutputStage) -> Bool {
        switch stage {
        case .inference: return match(path, #"^Intermediates(/(Left|Right))?$"#) || match(path, #"^(Prediction STL|Prediction Parameters|ICP STL) (Left|Right)$"#)
        case .preprocessing: return match(path, #"^Intermediates(/(Left|Right))?$"#) || match(path, #"^Projects(/(Left|Right)(/.*)?)?$"#)
        case .numcalc: return match(path, #"^Projects/(Left|Right)/NumCalc/source_[0-9]+/be\.out(/be\.[0-9]+)?$"#)
        case .postprocessing: return match(path, #"^HRTF(/.*)?$"#) || match(path, #"^Projects/(Left|Right)/Output2HRTF(/.*)?$"#)
        }
    }
    private func safePath(_ relative: String) -> URL? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.contains(":"), !relative.contains("\\"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasSuffix(" ") || $0.hasSuffix(".") }),
            Self.match(relative, #"^(Intermediates|Projects|HRTF)(/|$)|^(Prediction STL|Prediction Parameters|ICP STL) (Left|Right)(/|$)|^Results Inference\.csv$|^\.pinna2hrtf(-preprocessing-signature|_native_run\.yaml)$"#) else { return nil }
        let url = root.appendingPathComponent(relative)
        let candidate = Self.canonicalPath(url.path).lowercased()
        guard url.path.hasPrefix(root.path + "/"), !inputs.contains(where: { candidate == $0 || candidate.hasPrefix($0 + "/") }), !hasLinkedAncestor(url) else { return nil }
        return url
    }
    private func hasLinkedAncestor(_ url: URL) -> Bool {
        var current = url
        while current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK { return true }
            current.deleteLastPathComponent()
        }
        return false
    }
    private static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    private func scan() throws -> (files: [String: Entry], directories: Set<String>) {
        guard !hasLinkedAncestor(root) else { throw Failure.unsafePath }
        var files: [String: Entry] = [:], directories = Set<String>()
        func visit(_ folder: URL) throws {
            for url in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) {
                let relative = String(url.path.dropFirst(root.path.count + 1))
                guard safePath(relative) != nil else { continue }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values.isDirectory == true { directories.insert(relative); try visit(url) }
                else if values.isRegularFile == true { files[relative] = try fileMetadata(url) }
            }
        }
        if fm.fileExists(atPath: root.path) { try visit(root) }
        return (files, directories)
    }
    private func fileMetadata(_ url: URL) throws -> Entry {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? NSNumber, let date = attrs[.modificationDate] as? Date else { throw Failure.changingFile }
        return Entry(Size: size.int64Value, ModifiedUtcTicks: Int64(date.timeIntervalSince1970 * 10_000_000) + 621355968000000000)
    }
    private func fingerprint(_ url: URL) throws -> Entry {
        let before = try fileMetadata(url)
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        let after = try fileMetadata(url)
        guard before.Size == after.Size, before.ModifiedUtcTicks == after.ModifiedUtcTicks else { throw Failure.changingFile }
        var entry = before
        entry.Sha256 = hash.finalize().map { String(format: "%02X", $0) }.joined()
        return entry
    }
    private func acquire() throws -> Int32 {
        guard !hasLinkedAncestor(metadata), !hasLinkedAncestor(manifest) else { throw Failure.unsafePath }
        try fm.createDirectory(at: metadata, withIntermediateDirectories: true)
        let lock = metadata.appendingPathComponent("outputs.lock")
        guard !hasLinkedAncestor(lock) else { throw Failure.unsafePath }
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.unsafePath }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw Failure.busy }
        return fd
    }
    private func load() throws -> Document {
        guard !hasLinkedAncestor(manifest) else { throw Failure.unsafePath }
        guard fm.fileExists(atPath: manifest.path) else { return Document() }
        let doc = try JSONDecoder().decode(Document.self, from: Data(contentsOf: manifest))
        guard doc.Version == 1, doc.Files.values.allSatisfy({ Self.match($0.Sha256, #"^[a-fA-F0-9]{64}$"#) }) else { throw Failure.invalidManifest }
        return doc
    }
    private func save(_ doc: Document) throws {
        guard !hasLinkedAncestor(metadata), !hasLinkedAncestor(manifest) else { throw Failure.unsafePath }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(doc).write(to: manifest, options: .atomic)
    }
}
