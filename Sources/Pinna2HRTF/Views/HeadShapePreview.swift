import SwiftUI
import SceneKit
import ModelIO
import SceneKit.ModelIO

struct HeadShapePreview: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var scene: SCNScene?
    @State private var message = ""
    @State private var updating = false

    private struct Request: Equatable {
        let folder: URL
        let ears: [EarSide: URL]
        let preprocessing: [String: String]
        let darkMode: Bool
    }

    private var request: Request? {
        guard let project = store.selectedProject else { return nil }
        let ears = Dictionary(uniqueKeysWithValues: project.includedEars.compactMap { side in
            ArtifactScanner.preprocessingMesh(for: project, side: side).map { (side, $0) }
        })
        let pre = project.settings.preprocessing
        var preprocessing: [String: String] = [:]
        for field in PreprocessingSettings.headShapeFields {
            if let value = pre[keyPath: field.keyPath] { preprocessing[field.config] = value }
        }
        if let adaptive = pre.headAdaptiveOvalness { preprocessing["head_adaptive_ovalness"] = String(adaptive) }
        if let distance = pre.earDistance { preprocessing["ear_distance"] = distance }
        let folder = Defaults.appDataURL.appendingPathComponent("Cache/Head Preview/\(project.id.uuidString)", isDirectory: true)
        return Request(folder: folder, ears: ears, preprocessing: preprocessing, darkMode: colorScheme == .dark)
    }

    private var invalidField: String? {
        guard let project = store.selectedProject else { return nil }
        let values = ProjectValidation.formValues(for: project)
        return values.keys.filter { $0.hasPrefix("head.") || $0 == "mesh2hrtf.ear_distance" }.sorted()
            .compactMap { SettingsCatalog.check(values, id: $0) }.first
    }

    var body: some View {
        ZStack {
            if let scene {
                SceneView(scene: scene, pointOfView: scene.rootNode.childNode(withName: "camera", recursively: false),
                          options: [.allowsCameraControl])
                    .opacity(updating ? 0.6 : 1)
            } else {
                Text(message.isEmpty ? "Loading Preview…" : message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .background(Color(nsColor: .viewportBackground(darkMode: colorScheme == .dark)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Head shape preview")
        .task(id: request) { await refresh() }
    }

    private func refresh() async {
        guard let request else { scene = nil; message = ""; return }
        guard !request.ears.isEmpty else { scene = nil; message = "Choose an ear mesh to preview the head."; return }
        if let invalidField { message = invalidField; scene = nil; return }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        updating = true
        defer { updating = false }
        var payload: [String: Any] = ["folder": request.folder.path, "preprocessing": numericPreprocessing(request.preprocessing)]
        for (side, url) in request.ears { payload[side.rawValue] = url.path }
        let darkMode = request.darkMode
        let result = await Task.detached(priority: .userInitiated) { () -> Result<SCNScene, Error> in
            Result {
                let data = try ProjectConfigDocument.request("head-preview", payload, timeout: 120)
                guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: String], let head = reply["head"] else {
                    throw ProjectValidation.Failure(message: "The head preview is unavailable.")
                }
                let ears = [reply["left"], reply["right"]].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
                return Self.makeScene(head: URL(fileURLWithPath: head), ears: ears, darkMode: darkMode)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let built): scene = built; message = ""
        case .failure(let error): scene = nil; message = error.localizedDescription
        }
    }

    private func numericPreprocessing(_ values: [String: String]) -> [String: Any] {
        values.mapValues { text -> Any in
            if text == "true" || text == "false" { return text == "true" }
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? text
        }
    }

    private nonisolated static func makeScene(head: URL, ears: [URL], darkMode: Bool) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.viewportBackground(darkMode: darkMode)
        func add(_ url: URL, color: NSColor) {
            let asset = MDLAsset(url: url)
            for index in 0..<asset.count {
                let node = SCNNode(mdlObject: asset.object(at: index))
                node.geometry?.firstMaterial?.diffuse.contents = color
                node.geometry?.firstMaterial?.roughness.contents = 0.72
                scene.rootNode.addChildNode(node)
            }
        }
        add(head, color: NSColor(calibratedWhite: darkMode ? 0.62 : 0.78, alpha: 1))
        for ear in ears { add(ear, color: .systemOrange) }
        let bounds = scene.rootNode.boundingBox
        let size = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
        let target = SCNNode()
        target.position = SCNVector3((bounds.min.x + bounds.max.x) / 2, (bounds.min.y + bounds.max.y) / 2, (bounds.min.z + bounds.max.z) / 2)
        scene.rootNode.addChildNode(target)
        let camera = SCNCamera()
        camera.zFar = 10_000
        camera.fieldOfView = 34
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(target.position.x + size * 2.2, target.position.y - size * 0.35, target.position.z + size * 0.45)
        let look = SCNLookAtConstraint(target: target)
        look.worldUp = SCNVector3(0, 0, 1)
        look.isGimbalLockEnabled = true
        cameraNode.constraints = [look]
        scene.rootNode.addChildNode(cameraNode)
        EvenMeshLighting.install(in: scene, camera: cameraNode)
        return scene
    }
}
