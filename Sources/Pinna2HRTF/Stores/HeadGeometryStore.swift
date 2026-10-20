import Foundation
import AppKit

extension AppStore {
    func refreshGeometry() {
        guard let project = selectedProject else { geometryValues = nil; return }
        var arguments = ["-m", "HRTFCalculation.Geometry"]
        var stamps = [project.id.uuidString]
        for side in EarSide.allCases {
            let path = side == .left ? project.leftEar : project.rightEar
            guard !path.isEmpty else { continue }
            let selected = ArtifactScanner.preprocessingMesh(for: project, side: side)
            let mesh = selected ?? URL(fileURLWithPath: path)
            guard let identity = ArtifactScanner.meshIdentity(mesh) else { continue }
            arguments += [side == .left ? "--left" : "--right", mesh.path]
            stamps.append(mesh.standardizedFileURL.path + "|" + identity)
        }
        let key = stamps.joined(separator: "|")
        geometryKey = key
        guard stamps.count > 1 else { geometryValues = nil; geometryMessage = "Load an ear mesh to calculate geometry."; return }
        if let measured = geometryCache[key] {
            do {
                geometryValues = try measured.applying(project.settings.preprocessing)
                geometryMessage = ""
            } catch { geometryValues = measured; geometryMessage = error.localizedDescription }
            return
        }
        geometryValues = nil
        geometryMessage = "Calculating ear distance…"
        guard !geometryRequests.contains(key) else { return }
        geometryRequests.insert(key)
        let process = Process()
        if Defaults.isPackagedApp {
            process.executableURL = runtimePythonURL; process.arguments = arguments
        } else {
            let bundled = FileManager.default.isExecutableFile(atPath: environment.uvExecutable)
            process.executableURL = bundled ? URL(fileURLWithPath: environment.uvExecutable) : URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = (bundled ? [] : ["uv"]) + ["run", "--no-sync", "python"] + arguments
        }
        process.currentDirectoryURL = executionPackageURL; process.environment = processEnvironment()
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<GeometryValues, Error>
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw HeadGeometrySettings.error(String(data: data, encoding: .utf8) ?? "Geometry inspection failed.") }
                result = .success(try JSONDecoder().decode(GeometryValues.self, from: data))
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.geometryRequests.remove(key)
                switch result {
                case .success(let values):
                    self.geometryCache[key] = values
                    if self.geometryKey == key { self.refreshGeometry() }
                case .failure(let error):
                    if self.geometryKey == key { self.geometryValues = nil; self.geometryMessage = error.localizedDescription }
                }
            }
        }
    }

    func editGeometry(ear: Bool, text: String, reset: Bool = false) {
        guard let project = selectedProject, !selectedProjectIsRunning, !geometryEditing else { return }
        do {
            var desired: GeometryValues?
            if !reset {
                guard let current = geometryValues else { throw HeadGeometrySettings.error("Wait for geometry measurements before editing.") }
                let value = try HeadGeometrySettings.number(text)
                if value == current.distance { return }
                desired = try current.atDistance(value)
            }
            let apply = { [weak self] in
                guard let self, self.selectedProjectID == project.id else { return }
                self.updateSelectedProject { p in
                    p.settings.preprocessing.earDistance = desired.map { String($0.distance) }
                }
            }
            let output = URL(fileURLWithPath: project.saveLocation)
            let hasOutputs = ["Intermediates/dummy_head.stl", "Intermediates/Left/graded_head.ply", "Intermediates/Right/graded_head.ply", "Projects/Left", "Projects/Right"].contains { FileManager.default.fileExists(atPath: output.appendingPathComponent($0).path) }
            if !hasOutputs { apply(); return }
            let alert = NSAlert()
            alert.messageText = "Reset pipeline outputs?"
            alert.informativeText = "Changing geometry resets Preprocessing and all following outputs. Inferred ears, inputs, and modified files will be kept."
            alert.addButton(withTitle: "Reset and apply"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let outputs = try outputsFor(project)
            geometryEditing = true
            outputOperations.insert(project.id)
            Task { @MainActor in
                let result = await Task.detached(priority: .userInitiated) { outputs.reset(from: .preprocessing) }.value
                self.outputOperations.remove(project.id)
                self.geometryEditing = false
                if result.success {
                    self.failedStagesByProject[project.id]?.subtract([.preprocessing, .numcalc, .postprocessing])
                    if let mesh = self.selectedMesh, !FileManager.default.fileExists(atPath: mesh.path) { self.resetViewer() }
                    apply()
                }
                self.appendLog(result.summary, for: project.id)
                self.refreshArtifacts()
            }
        } catch { geometryMessage = error.localizedDescription; appendLog("Geometry: \(error.localizedDescription)") }
    }

    func geometryProcess(_ arguments: [String]) -> Process {
        let process = Process()
        if Defaults.isPackagedApp { process.executableURL = runtimePythonURL; process.arguments = arguments }
        else {
            let bundled = FileManager.default.isExecutableFile(atPath: environment.uvExecutable)
            process.executableURL = bundled ? URL(fileURLWithPath: environment.uvExecutable) : URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = (bundled ? [] : ["uv"]) + ["run", "--no-sync", "python"] + arguments
        }
        process.currentDirectoryURL = executionPackageURL
        process.environment = processEnvironment()
        return process
    }

    func inspectEarDistance(_ project: ProjectRecord) async throws -> GeometryValues {
        var arguments = ["-m", "HRTFCalculation.Geometry"]
        for side in EarSide.allCases {
            let path = side == .left ? project.leftEar : project.rightEar
            guard !path.isEmpty else { continue }
            let mesh = ArtifactScanner.preprocessingMesh(for: project, side: side) ?? URL(fileURLWithPath: path)
            arguments += [side == .left ? "--left" : "--right", mesh.path]
        }
        let process = geometryProcess(arguments)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw HeadGeometrySettings.error(String(data: data, encoding: .utf8) ?? "Distance measurement failed.") }
                    continuation.resume(returning: try JSONDecoder().decode(GeometryValues.self, from: data))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func readDistanceSettings(_ url: URL, into settings: inout PreprocessingSettings) throws {
        // Version compatibility only; remove with v2.0.0.
        let process = geometryProcess(["-m", "HRTFCalculation.Compatibility", url.path])
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw HeadGeometrySettings.error(String(data: data, encoding: .utf8) ?? "Could not load settings.") }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HeadGeometrySettings.error("Could not read ear distance.") }
        settings.earDistance = (result["ear_distance"] as? NSNumber).map { $0.stringValue }
        for warning in result["warnings"] as? [String] ?? [] { appendLog(warning) }
    }

    func checkEarDistanceAndRun(_ project: ProjectRecord) {
        outputOperations.insert(project.id)
        geometryEditing = true
        Task { @MainActor in
            var ownsPreflightGuard = true
            defer {
                if ownsPreflightGuard { outputOperations.remove(project.id) }
                geometryEditing = false
                refreshArtifacts()
            }
            do {
                let measured = try await inspectEarDistance(project)
                let values = try measured.applying(project.settings.preprocessing)
                try values.validate()
                guard selectedProjectID == project.id, selectedProject == project else {
                    appendLog("Project changed while measuring ear distance; start preprocessing again.", for: project.id)
                    return
                }
                if HeadGeometrySettings.needsWarning(values.distance) {
                    let alert = NSAlert()
                    alert.messageText = "Ear meshes are close to the head center"
                    alert.informativeText = "The ear distance from the head center is \(values.distance) mm. This will produce a very small head. You can proceed anyway or cancel to adjust the distance."
                    alert.addButton(withTitle: "Cancel and adjust")
                    alert.addButton(withTitle: "Proceed anyway")
                    guard alert.runModal() == .alertSecondButtonReturn else {
                        earDistanceFocusRequest = UUID()
                        return
                    }
                }
                outputOperations.remove(project.id)
                ownsPreflightGuard = false
                geometryEditing = false
                prepareAndRun(stage: .preprocessing, project: project)
            } catch { appendLog("Could not measure ear distance: \(error.localizedDescription)", for: project.id) }
        }
    }
}
