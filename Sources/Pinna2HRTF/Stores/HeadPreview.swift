import Foundation
import SceneKit
import AppKit

extension ViewerModel {
    var headPreviewURL: URL? {
        guard let id = store?.selectedProjectID else { return nil }
        return Defaults.appDataURL.appendingPathComponent("Cache/Head Preview/\(id.uuidString)/head.stl")
    }

    func requestHeadPreview(resetCamera: Bool = false) {
        guard let store, let project = store.selectedProject, let identity = headPreviewURL, !isPlacingMicrophone else { return }
        let previous = selectedMesh == identity
        let camera = resetCamera ? nil : previous ? selectedCameraState : headPreviewCache[project.id]?.camera
        let values = ProjectValidation.formValues(for: project)
        let ears = Dictionary(uniqueKeysWithValues: project.includedEars.compactMap { side in
            ArtifactScanner.preprocessingMesh(for: project, side: side).map { (side.rawValue, $0.path) }
        })
        let parameters = values.keys.filter { ($0.hasPrefix("head.") || $0.hasPrefix("torso.")) || $0 == "mesh2hrtf.ear_distance" }.sorted().map { "\($0)=\(values[$0]!)" }
        let sources = ears.keys.sorted().map { side in
            let path = ears[side]!
            return side + "=" + path + ":" + (ArtifactScanner.meshIdentity(URL(fileURLWithPath: path)) ?? "missing")
        }
        let key = ([project.id.uuidString] + parameters + sources).joined(separator: "|")
        if previous && headPreviewPendingKey == key { return }
        headPreviewTask?.cancel()
        headPreviewPendingKey = nil
        let loadID = UUID()
        meshLoadID = loadID
        selectedPressure = nil
        selectedImage = nil
        selectedMesh = identity
        if let cached = headPreviewCache[project.id], cached.key == key {
            if !previous || resetCamera || selectedScene !== cached.loaded.scene {
                showCachedHeadPreview(cached, identity: identity, projectID: project.id, loadID: loadID, resetCamera: resetCamera)
            }
            headPreviewMessage = nil
            return
        }
        if !previous { selectedScene = SCNScene() }
        headPreviewMessage = "Updating head preview…"
        if let error = values.keys.filter({ ($0.hasPrefix("head.") || $0.hasPrefix("torso.")) || $0 == "mesh2hrtf.ear_distance" }).sorted().compactMap({ SettingsCatalog.check(values, id: $0) }).first {
            headPreviewMessage = error
            return
        }
        guard !ears.isEmpty else { headPreviewMessage = "Choose an ear mesh to preview the head."; return }
        let folder = identity.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        var preprocessing: [String: Any] = ["torso_mode": project.settings.preprocessing.torsoMode ?? SettingsCatalog.text("preprocessing.torso_mode")]
        for field in PreprocessingSettings.geometryFields {
            if let text = project.settings.preprocessing[keyPath: field.keyPath] { preprocessing[field.config] = Double(text).map { $0 as Any } ?? text }
        }
        if let distance = project.settings.preprocessing.earDistance { preprocessing["ear_distance"] = Double(distance).map { $0 as Any } ?? distance }
        var payload: [String: Any] = ["folder": folder.path, "preprocessing": preprocessing]
        for (side, path) in ears { payload[side] = path }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        headPreviewPendingKey = key
        headPreviewTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<LoadedScene, Error> in
                defer { try? FileManager.default.removeItem(at: folder) }
                return Result {
                    let data = try ProjectConfigDocument.request("head-preview", payload, timeout: 120)
                    guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: String], let head = reply["head"],
                          let scene = Self.loadScene(url: URL(fileURLWithPath: head), darkMode: dark, savedCamera: camera, microphonePreview: nil,
                                                     ears: [reply["left"], reply["right"]].compactMap { $0 }.map { URL(fileURLWithPath: $0) }) else {
                        throw ProjectValidation.Failure(message: "The head preview is unavailable.")
                    }
                    return scene
                }
            }.value
            guard let self, !Task.isCancelled, self.meshLoadID == loadID, self.store?.selectedProjectID == project.id, self.selectedMesh == identity else { return }
            self.headPreviewPendingKey = nil
            switch result {
            case .success(let loaded):
                let latest = resetCamera ? nil : previous ? self.selectedCameraState : camera
                var completed = loaded
                if let latest, let cameraNode = loaded.scene.rootNode.childNodes.first(where: { $0.camera != nil }) {
                    let scale = Double(loaded.maximumDimension)
                    let position = SCNVector3(CGFloat(Double(loaded.center.x) + latest.x * scale), CGFloat(Double(loaded.center.y) + latest.y * scale), CGFloat(Double(loaded.center.z) + latest.z * scale))
                    cameraNode.position = position
                    if let q = latest.orientation, q.count == 4 {
                        cameraNode.constraints = nil
                        cameraNode.orientation = SCNQuaternion(q[0], q[1], q[2], q[3])
                    }
                    if let target = latest.target, target.count == 3 {
                        loaded.scene.rootNode.childNode(withName: "cameraTarget", recursively: false)?.position = SCNVector3(target[0], target[1], target[2])
                    }
                    completed = LoadedScene(scene: loaded.scene, center: loaded.center, maximumDimension: loaded.maximumDimension, cameraPosition: position)
                }
                self.finishLoadingMesh(completed, url: identity, loadID: loadID, projectID: project.id, savedCamera: latest, resetCamera: resetCamera)
                self.headPreviewCache[project.id] = CachedHeadPreview(key: key, loaded: completed, camera: self.selectedCameraState)
                self.headPreviewMessage = nil
            case .failure(let error): self.headPreviewMessage = error.localizedDescription
            }
        }
    }

    private func showCachedHeadPreview(_ cached: CachedHeadPreview, identity: URL, projectID: UUID, loadID: UUID, resetCamera: Bool) {
        var loaded = cached.loaded
        if resetCamera, let cameraNode = loaded.scene.rootNode.childNodes.first(where: { $0.camera != nil }),
           let target = loaded.scene.rootNode.childNode(withName: "cameraTarget", recursively: false) {
            target.position = loaded.center
            let size = loaded.maximumDimension
            let position = SCNVector3(loaded.center.x + size * 1.7, loaded.center.y - size * 0.25, loaded.center.z + size * 0.2)
            cameraNode.position = position
            let look = SCNLookAtConstraint(target: target)
            look.worldUp = SCNVector3(0, 0, 1)
            look.isGimbalLockEnabled = true
            cameraNode.constraints = [look]
            loaded = LoadedScene(scene: loaded.scene, center: loaded.center, maximumDimension: size, cameraPosition: position)
        }
        finishLoadingMesh(loaded, url: identity, loadID: loadID, projectID: projectID,
                          savedCamera: resetCamera ? nil : cached.camera, resetCamera: resetCamera)
        headPreviewCache[projectID] = CachedHeadPreview(key: cached.key, loaded: loaded, camera: selectedCameraState)
        updateSceneBackground(darkMode: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

}
