import Foundation
import AppKit

extension AppStore {
    func refreshGeometry() {
        guard let project = selectedProject else { geometryValues = nil; return }
        let generation = UUID().uuidString
        geometryKey = generation
        Task { @MainActor in
            let discovered = await Task.detached(priority: .utility) { () -> ([String], [String]) in
        var arguments = ["-m", "HRTFCalculation.Geometry"]
        var stamps = [project.id.uuidString]
        for side in EarSide.allCases {
            let path = project.pipelineEar(for: side)
            guard !path.isEmpty else { continue }
            let selected = ArtifactScanner.preprocessingMesh(for: project, side: side)
            let mesh = selected ?? URL(fileURLWithPath: path)
            guard let identity = ArtifactScanner.meshIdentity(mesh) else { continue }
            arguments += [side == .left ? "--left" : "--right", mesh.path]
            stamps.append(mesh.standardizedFileURL.path + "|" + identity)
        }
                return (arguments, stamps)
            }.value
            guard self.geometryKey == generation, self.selectedProject == project else { return }
            self.applyGeometryDiscovery(project, arguments: discovered.0, stamps: discovered.1)
        }
    }

    private func applyGeometryDiscovery(_ project: ProjectRecord, arguments: [String], stamps: [String]) {
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
        let environment = environment
        Task { @MainActor [weak self] in
            let result: Result<GeometryValues, Error>
            do { result = .success(try await Self.measureGeometry(arguments, environment: environment, failure: "Geometry inspection failed.")) }
            catch { result = .failure(error) }
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

    /// Runs `HRTFCalculation.Geometry` through the shared launcher (registered, cancellable on quit, time-limited).
    private static func measureGeometry(_ arguments: [String], environment: EnvironmentConfig, failure: String) async throws -> GeometryValues {
        let process = try ProcessLauncher.shared.makeProcess(.python(arguments), environment: environment)
        let result = try await ProcessLauncher.shared.runHelperAsync(process, timeout: 180)
        guard result.status == 0 else { throw HeadGeometrySettings.error(result.text.isEmpty ? failure : result.text) }
        return try JSONDecoder().decode(GeometryValues.self, from: result.output)
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
            alert.messageText = "Reset generated outputs?"
            alert.informativeText = "Changing ear distance resets preprocessing and later results. Inputs, predicted ears, and modified files are kept."
            alert.addButton(withTitle: "Reset and apply"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let outputs = try runner.outputsFor(project)
            geometryEditing = true
            runner.beginOutputOperation(project.id)
            Task { @MainActor in
                let result = await Task.detached(priority: .userInitiated) { outputs.reset(from: .preprocessing) }.value
                self.runner.endOutputOperation(project.id)
                self.geometryEditing = false
                if result.success {
                    self.runner.failedStagesByProject[project.id]?.subtract([.preprocessing, .numcalc, .postprocessing])
                    if let mesh = self.selectedMesh, !FileManager.default.fileExists(atPath: mesh.path) { self.viewer.resetViewer() }
                    apply()
                }
                self.appendLog(result.summary, for: project.id)
                self.refreshArtifacts()
            }
        } catch { geometryMessage = error.localizedDescription; appendLog("Geometry: \(error.localizedDescription)") }
    }

    func inspectEarDistance(_ project: ProjectRecord) async throws -> GeometryValues {
        var arguments = ["-m", "HRTFCalculation.Geometry"]
        for side in EarSide.allCases {
            let path = project.pipelineEar(for: side)
            guard !path.isEmpty else { continue }
            let mesh = ArtifactScanner.preprocessingMesh(for: project, side: side) ?? URL(fileURLWithPath: path)
            arguments += [side == .left ? "--left" : "--right", mesh.path]
        }
        return try await Self.measureGeometry(arguments, environment: environment, failure: "Distance measurement failed.")
    }

    func checkEarDistanceAndRun(_ project: ProjectRecord) {
        runner.beginOutputOperation(project.id)
        geometryEditing = true
        Task { @MainActor in
            var ownsPreflightGuard = true
            defer {
                if ownsPreflightGuard { runner.endOutputOperation(project.id) }
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
                    alert.informativeText = "Ear distance: \(values.distance) mm. This creates a very small head. Continue or adjust the distance?"
                    alert.addButton(withTitle: "Adjust distance")
                    alert.addButton(withTitle: "Continue")
                    guard alert.runModal() == .alertSecondButtonReturn else {
                        earDistanceFocusRequest = UUID()
                        return
                    }
                }
                runner.endOutputOperation(project.id)
                ownsPreflightGuard = false
                geometryEditing = false
                runner.prepareAndRun(stage: .preprocessing, project: project)
            } catch { appendLog("Could not measure ear distance: \(error.localizedDescription)", for: project.id) }
        }
    }
}
