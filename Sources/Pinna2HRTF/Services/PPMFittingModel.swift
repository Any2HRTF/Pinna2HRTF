import Foundation
import SceneKit
import ModelIO
import SceneKit.ModelIO
import AppKit
import simd

@MainActor
final class PPMFittingModel: ObservableObject {
    let request: PPMFittingRequest
    let scene = SCNScene()
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("pinna-ppm-fit-\(UUID().uuidString)", isDirectory: true)

    @Published var controls: [PPMFittingControl] = []
    @Published private(set) var metrics: [PPMFittingMetric] = []
    @Published var busy = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var message = "Preparing the PPM fit…"
    @Published var error: String?
    @Published var templateBlendPath = ""
    @Published var showTarget = true { didSet { updateTargetOpacity() } }
    @Published var showPPM = true { didSet { ppmNode?.isHidden = !showPPM } }
    @Published var showSkeleton = true { didSet { skeletonNode?.isHidden = !showSkeleton } }
    @Published var targetOpacity = 0.32 { didSet { updateTargetOpacity() } }
    @Published private(set) var cameraRevision = 0
    @Published private(set) var isUpdatingPreview = false

    private var parameters: [String: Double] = [:]
    private var undoHistory: [[String: Double]] = []
    private var redoHistory: [[String: Double]] = []
    private var activeEditSnapshot: [String: Double]?
    private var activeEditWasRecorded = false
    private let maximumHistoryCount = 100
    private var previewGeneration = 0
    private var previewWorkerTask: Task<Void, Never>?
    private var pythonWorker: PPMFittingPythonWorker?
    private var targetNode: SCNNode?
    private var ppmNode: SCNNode?
    private var skeletonNode: SCNNode?
    private var cameraNode: SCNNode?
    private var targetCenter = SCNVector3Zero
    private var cameraConfigured = false
    private var cameraExtent: CGFloat = 1

    init(request: PPMFittingRequest) {
        self.request = request
    }

    deinit { try? FileManager.default.removeItem(at: workspace) }

    var canSave: Bool { !busy && !isUpdatingPreview && !controls.isEmpty && !parameters.isEmpty }

    var globalControls: [PPMFittingControl] { controls.filter { $0.section == "global" } }
    var convexGroups: [String] {
        Array(Set(controls.filter { $0.section == "convex" }.map(\.group))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    var concaveControls: [PPMFittingControl] { controls.filter { $0.section == "concave" } }

    func open() async {
        guard controls.isEmpty, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            if let initial = request.initialTemplateBlend, FileManager.default.fileExists(atPath: initial.path) {
                templateBlendPath = initial.path
            } else {
                let desktopBlend = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/PPM.blend")
                if FileManager.default.fileExists(atPath: desktopBlend.path) { templateBlendPath = desktopBlend.path }
            }
            try await initialize(usingSavedParameters: request.savedParameters)
            try loadTarget()
            message = "Adjust a control to update the PPM preview. Fit globally, then local bone controls, then shape keys."
        } catch {
            self.error = error.localizedDescription
            message = "Could not open the fitting workspace."
        }
    }

    func update(_ control: PPMFittingControl, value: Double) {
        guard let index = controls.firstIndex(where: { $0.id == control.id }), value.isFinite else { return }
        let updatedValue = min(max(value, control.minimum), control.maximum)
        guard controls[index].value != updatedValue else { return }
        recordHistoryBeforeControlChange()
        controls[index].value = updatedValue
        requestPreviewUpdate()
    }

    func beginControlEditing() {
        guard activeEditSnapshot == nil else { return }
        activeEditSnapshot = controlValues
        activeEditWasRecorded = false
    }

    func endControlEditing() {
        activeEditSnapshot = nil
        activeEditWasRecorded = false
    }

    func undo() {
        guard !busy else { return }
        endControlEditing()
        guard let snapshot = undoHistory.popLast() else { return }
        appendHistory(controlValues, to: &redoHistory)
        restoreControlValues(snapshot)
        updateHistoryAvailability()
        requestPreviewUpdate()
    }

    func redo() {
        guard !busy else { return }
        endControlEditing()
        guard let snapshot = redoHistory.popLast() else { return }
        appendHistory(controlValues, to: &undoHistory)
        restoreControlValues(snapshot)
        updateHistoryAvailability()
        requestPreviewUpdate()
    }

    private func restoreControlValues(_ values: [String: Double]) {
        controls = controls.map { control in
            var restored = control
            if let value = values[control.id] { restored.value = value }
            return restored
        }
    }

    private func recordHistoryBeforeControlChange() {
        if let activeEditSnapshot {
            guard !activeEditWasRecorded else { return }
            appendHistory(activeEditSnapshot, to: &undoHistory)
            activeEditWasRecorded = true
        } else {
            appendHistory(controlValues, to: &undoHistory)
        }
        redoHistory.removeAll(keepingCapacity: true)
        updateHistoryAvailability()
    }

    private func appendHistory(_ snapshot: [String: Double], to history: inout [[String: Double]]) {
        history.append(snapshot)
        if history.count > maximumHistoryCount {
            history.removeFirst(history.count - maximumHistoryCount)
        }
    }

    private func updateHistoryAvailability() {
        canUndo = !undoHistory.isEmpty
        canRedo = !redoHistory.isEmpty
    }

    private func requestPreviewUpdate() {
        if error != nil { error = nil }
        if !isUpdatingPreview {
            isUpdatingPreview = true
            message = "Updating the PPM preview…"
        }
        schedulePreview()
    }

    func resetControls() async {
        guard !busy, !isUpdatingPreview else { return }
        let previousValues = controlValues
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await initialize(usingSavedParameters: nil)
            if previousValues != controlValues {
                appendHistory(previousValues, to: &undoHistory)
                redoHistory.removeAll(keepingCapacity: true)
                updateHistoryAvailability()
            }
            message = "Restored the starting PPM parameters."
        } catch { self.error = error.localizedDescription }
    }

    func save() async -> Bool {
        guard canSave else { return false }
        guard ArtifactScanner.meshIdentity(request.targetMesh) == request.sourceIdentity else {
            error = "The target ear changed while it was being fitted. Close this workspace and reopen it to use the current mesh."
            return false
        }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try FileManager.default.createDirectory(at: request.destinationMesh.deletingLastPathComponent(), withIntermediateDirectories: true)
            let generated = workspace.appendingPathComponent("saved-fit.stl")
            let generatedBlend = workspace.appendingPathComponent("saved-fit.blend")
            let result = try await execute(["action": "save", "parameters": parameters,
                "controls": controlValues, "output": generated.path, "blend_output": generatedBlend.path,
                "mirror_y": request.side == .right])
            install(result)
            guard ArtifactScanner.meshIdentity(request.targetMesh) == request.sourceIdentity else {
                throw ProjectValidation.Failure(message: "The target ear changed while the fit was being saved. The existing fit was preserved.")
            }
            guard FileManager.default.fileExists(atPath: generated.path) else {
                throw ProjectValidation.Failure(message: "The PPM fitting engine did not produce a mesh.")
            }
            guard FileManager.default.fileExists(atPath: generatedBlend.path) else {
                throw ProjectValidation.Failure(message: "The PPM fitting engine did not produce an editable Blender file.")
            }
            if FileManager.default.fileExists(atPath: request.destinationMesh.path) {
                try FileManager.default.removeItem(at: request.destinationMesh)
            }
            try FileManager.default.copyItem(at: generated, to: request.destinationMesh)
            if FileManager.default.fileExists(atPath: request.destinationBlend.path) {
                try FileManager.default.removeItem(at: request.destinationBlend)
            }
            try FileManager.default.copyItem(at: generatedBlend, to: request.destinationBlend)
            let archivedTemplate = try archiveTemplateIfNeeded()
            if let archivedTemplate { templateBlendPath = archivedTemplate.path }
            let document: [String: Any] = [
                "version": 1,
                "template_blend": archivedTemplate?.path ?? templateBlendPath,
                "parameters": parameters
            ]
            let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: request.destinationParameters, options: .atomic)
            try installPPM(at: generated, isAlreadyMirrored: request.side == .right)
            message = "Saved the fitted PPM for the \(request.side.rawValue) ear."
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private var previewMeshURL: URL { workspace.appendingPathComponent("preview.meshbin") }
    private var controlValues: [String: Double] { Dictionary(uniqueKeysWithValues: controls.map { ($0.id, $0.value) }) }

    private func schedulePreview() {
        previewGeneration += 1
        startPreviewWorkerIfNeeded()
    }

    private func startPreviewWorkerIfNeeded() {
        guard previewWorkerTask == nil else { return }
        previewWorkerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshPreviewUntilCurrent()
            self.previewWorkerTask = nil
        }
    }

    private func refreshPreviewUntilCurrent() async {
        guard !busy, !parameters.isEmpty else {
            isUpdatingPreview = false
            return
        }

        while !Task.isCancelled {
            let generation = previewGeneration
            let values = controlValues
            do {
                let result = try await execute(["action": "preview_mesh", "parameters": parameters,
                    "controls": values, "mesh_data": previewMeshURL.path,
                    "mirror_y": request.side == .right])
                if generation != previewGeneration { continue }
                install(result)
                try installPPM(meshDataAt: previewMeshURL)
                isUpdatingPreview = false
                message = "Preview is up to date. Continue fitting or save this side."
                return
            } catch {
                if generation != previewGeneration { continue }
                self.error = error.localizedDescription
                isUpdatingPreview = false
                message = "Could not update the PPM preview."
                return
            }
        }
    }

    private func initialize(usingSavedParameters saved: URL?) async throws {
        let command: [String: Any] = [
            "action": "initialize",
            "template_blend": templateBlendPath,
            "saved_parameters": saved?.path ?? "",
            "target_mesh": request.targetMesh.path,
            "mesh_data": previewMeshURL.path,
            "mirror_y": request.side == .right
        ]
        let result = try await execute(command)
        install(result)
        try installPPM(meshDataAt: previewMeshURL)
        isUpdatingPreview = false
    }

    private func execute(_ command: [String: Any]) async throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])
        let worker: PPMFittingPythonWorker
        if let pythonWorker {
            worker = pythonWorker
        } else {
            guard let pythonURL = ProjectConfigDocument.pythonURL else {
                throw ProjectValidation.Failure(message: "The bundled Python runtime is unavailable.")
            }
            worker = try await Task.detached(priority: .userInitiated) {
                try PPMFittingPythonWorker(pythonURL: pythonURL, workingDirectory: Defaults.pipelineRoot)
            }.value
            pythonWorker = worker
        }
        let output = try await Task.detached(priority: .userInitiated) {
            try worker.execute(input)
        }.value
        guard let result = try JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw ProjectValidation.Failure(message: "The PPM fitting engine returned unreadable data.")
        }
        if let message = result["error"] as? String {
            throw ProjectValidation.Failure(message: message)
        }
        return result
    }

    private func install(_ result: [String: Any]) {
        if let bones = result["skeleton"] as? [[String: Any]] {
            installSkeleton(bones)
        }
        if let values = result["parameters"] as? [String: NSNumber] {
            parameters = values.mapValues(\.doubleValue)
        }
        if let list = result["controls"] as? [[String: Any]] {
            controls = list.compactMap { value in
                guard let id = value["id"] as? String,
                      let section = value["section"] as? String,
                      let group = value["group"] as? String,
                      let label = value["label"] as? String,
                      let number = value["value"] as? NSNumber,
                      let minimum = value["minimum"] as? NSNumber,
                      let maximum = value["maximum"] as? NSNumber else { return nil }
                return PPMFittingControl(id: id, section: section, group: group, label: label,
                    value: number.doubleValue, minimum: minimum.doubleValue, maximum: maximum.doubleValue,
                    unit: value["unit"] as? String ?? "")
            }
        }
        if let template = result["template_blend"] as? String, !template.isEmpty {
            templateBlendPath = template
        }
        if let resultMetrics = result["metrics"] as? [String: [String: Any]] {
            let order = ["ppm_to_target_rmse", "target_to_ppm_rmse", "symmetric_rmse",
                         "mean", "median", "max", "min"]
            let labels = [
                "ppm_to_target_rmse": "PPM → target RMSE",
                "target_to_ppm_rmse": "Target → PPM RMSE",
                "symmetric_rmse": "Symmetric RMSE",
                "mean": "Mean · PPM → target",
                "median": "Median · PPM → target",
                "max": "Max · PPM → target",
                "min": "Min · PPM → target"
            ]
            metrics = order.compactMap { name in
                guard let item = resultMetrics[name],
                      let value = (item["value"] as? NSNumber)?.doubleValue else { return nil }
                return PPMFittingMetric(id: name, label: labels[name] ?? name, value: value)
            }
        }
    }

    private func installSkeleton(_ bones: [[String: Any]]) {
        let root = SCNNode()
        root.name = "Blender posed skeleton"
        if request.side == .right { root.scale = SCNVector3(1, -1, 1) }
        for bone in bones {
            guard let name = bone["name"] as? String,
                  let coordinates = bone["points"] as? [[Double]], coordinates.count >= 2,
                  coordinates.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else { continue }
            let points = coordinates.map { SIMD3<Float>(Float($0[0]), Float($0[1]), Float($0[2])) }
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = name.hasSuffix("-Bendy") ? NSColor.cyan : NSColor.systemYellow
            // Draw through the surface, like Blender's armature In Front option.
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            let boneNode = SCNNode()
            boneNode.name = name
            for (start, end) in zip(points, points.dropFirst()) {
                let delta = end - start
                let length = simd_length(delta)
                guard length > 0.00001 else { continue }
                let cylinder = SCNCylinder(radius: 0.12, height: CGFloat(length))
                cylinder.radialSegmentCount = 6
                cylinder.materials = [material]
                let node = SCNNode(geometry: cylinder)
                node.simdPosition = (start + end) / 2
                node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
                node.renderingOrder = 100
                boneNode.addChildNode(node)
            }
            for point in [points[0], points[points.count - 1]] {
                let sphere = SCNSphere(radius: 0.22)
                sphere.segmentCount = 8
                sphere.materials = [material]
                let node = SCNNode(geometry: sphere)
                node.simdPosition = point
                node.renderingOrder = 101
                boneNode.addChildNode(node)
            }
            root.addChildNode(boneNode)
        }
        root.isHidden = !showSkeleton
        skeletonNode?.removeFromParentNode()
        scene.rootNode.addChildNode(root)
        skeletonNode = root
    }

    private func loadTarget() throws {
        guard FileManager.default.fileExists(atPath: request.targetMesh.path) else {
            throw ProjectValidation.Failure(message: "The target ear mesh could not be found.")
        }
        let asset = MDLAsset(url: request.targetMesh)
        guard asset.count > 0 else { throw ProjectValidation.Failure(message: "The target ear mesh is empty or unreadable.") }
        let root = SCNNode()
        root.name = "Target ear"
        for index in 0..<asset.count {
            let node = SCNNode(mdlObject: asset.object(at: index))
            root.addChildNode(node)
        }
        scene.rootNode.addChildNode(root)
        targetNode = root
        root.isHidden = !showTarget
        updateTargetOpacity()
        configureCameraIfNeeded()
    }

    private func installPPM(at url: URL, isAlreadyMirrored: Bool = false) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectValidation.Failure(message: "The PPM preview mesh is missing.")
        }
        let asset = MDLAsset(url: url)
        guard asset.count > 0 else { throw ProjectValidation.Failure(message: "The PPM preview mesh is empty or unreadable.") }
        ppmNode?.removeFromParentNode()
        let root = SCNNode()
        root.name = "BezierPPM fit"
        if request.side == .right && !isAlreadyMirrored {
            root.scale = SCNVector3(1, -1, 1)
        }
        for index in 0..<asset.count {
            let node = SCNNode(mdlObject: asset.object(at: index))
            let material = SCNMaterial()
            material.diffuse.contents = NSColor(calibratedRed: 0.92, green: 0.34, blue: 0.16, alpha: 1)
            material.roughness.contents = 0.48
            material.isDoubleSided = true
            node.geometry?.materials = [material]
            root.addChildNode(node)
        }
        root.isHidden = !showPPM
        scene.rootNode.addChildNode(root)
        ppmNode = root
        configureCameraIfNeeded()
    }

    private func installPPM(meshDataAt url: URL) throws {
        let geometry = try makePreviewGeometry(from: url)
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedRed: 0.92, green: 0.34, blue: 0.16, alpha: 1)
        material.roughness.contents = 0.48
        material.isDoubleSided = true
        geometry.materials = [material]

        if let ppmNode, let meshNode = ppmNode.childNodes.first {
            meshNode.geometry = geometry
            ppmNode.isHidden = !showPPM
            configureCameraIfNeeded()
            return
        }

        let root = SCNNode()
        root.name = "BezierPPM fit"
        if request.side == .right { root.scale = SCNVector3(1, -1, 1) }
        root.addChildNode(SCNNode(geometry: geometry))
        root.isHidden = !showPPM
        scene.rootNode.addChildNode(root)
        ppmNode?.removeFromParentNode()
        ppmNode = root
        configureCameraIfNeeded()
    }

    private func makePreviewGeometry(from url: URL) throws -> SCNGeometry {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 8 else {
            throw ProjectValidation.Failure(message: "The PPM preview mesh data is incomplete.")
        }
        let counts = data.withUnsafeBytes { raw -> (Int, Int) in
            let vertices = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            let triangles = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            return (Int(vertices), Int(triangles))
        }
        let (vertexCount, triangleCount) = counts
        let vertexBytes = vertexCount.multipliedReportingOverflow(by: 12)
        let indexBytes = triangleCount.multipliedReportingOverflow(by: 12)
        let distanceBytes = vertexCount.multipliedReportingOverflow(by: 4)
        guard vertexCount > 0, triangleCount > 0,
              !vertexBytes.overflow, !indexBytes.overflow, !distanceBytes.overflow,
              8 + vertexBytes.partialValue + indexBytes.partialValue + distanceBytes.partialValue == data.count else {
            throw ProjectValidation.Failure(message: "The PPM preview mesh data is malformed.")
        }

        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(vertexCount)
        var indices = [UInt32]()
        indices.reserveCapacity(triangleCount * 3)
        var distanceColors = [Float]()
        distanceColors.reserveCapacity(vertexCount * 3)
        data.withUnsafeBytes { raw in
            for index in 0..<vertexCount {
                let offset = 8 + index * 12
                let x = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                let y = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)))
                let z = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self)))
                positions.append(SIMD3(x, y, z))
            }
            let indexOffset = 8 + vertexBytes.partialValue
            for index in 0..<(triangleCount * 3) {
                let offset = indexOffset + index * 4
                indices.append(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            let distanceOffset = indexOffset + indexBytes.partialValue
            for index in 0..<vertexCount {
                let offset = distanceOffset + index * 4
                let distance = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                let color = Self.distanceErrorColor(distance)
                distanceColors.append(color.x)
                distanceColors.append(color.y)
                distanceColors.append(color.z)
            }
        }
        guard indices.allSatisfy({ Int($0) < vertexCount }) else {
            throw ProjectValidation.Failure(message: "The PPM preview mesh contains invalid triangle indices.")
        }

        var normals = Array(repeating: SIMD3<Float>(repeating: 0), count: vertexCount)
        for triangle in stride(from: 0, to: indices.count, by: 3) {
            let ia = Int(indices[triangle])
            let ib = Int(indices[triangle + 1])
            let ic = Int(indices[triangle + 2])
            let a = positions[ia]
            let b = positions[ib]
            let c = positions[ic]
            let ab = b - a
            let ac = c - a
            let normal = SIMD3(ab.y * ac.z - ab.z * ac.y,
                               ab.z * ac.x - ab.x * ac.z,
                               ab.x * ac.y - ab.y * ac.x)
            normals[ia] += normal
            normals[ib] += normal
            normals[ic] += normal
        }
        let vertices = positions.map { SCNVector3($0.x, $0.y, $0.z) }
        let vertexNormals = normals.map { normal -> SCNVector3 in
            let length = simd_length(normal)
            guard length > 0 else { return SCNVector3(0, 0, 1) }
            let unit = normal / length
            return SCNVector3(unit.x, unit.y, unit.z)
        }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorData = distanceColors.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles,
                                         primitiveCount: triangleCount, bytesPerIndex: 4)
        let colors = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: vertexCount,
                                       usesFloatComponents: true, componentsPerVector: 3,
                                       bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices),
                                     SCNGeometrySource(normals: vertexNormals), colors],
                           elements: [element])
    }

    private static func distanceErrorColor(_ distance: Float) -> SIMD3<Float> {
        let stops: [(Float, SIMD3<Float>)] = [
            (0.0, SIMD3(0.10, 0.32, 0.72)),
            (0.5, SIMD3(0.16, 0.72, 0.76)),
            (1.0, SIMD3(0.94, 0.88, 0.25)),
            (1.75, SIMD3(0.94, 0.43, 0.12)),
            (3.0, SIMD3(0.72, 0.12, 0.16))
        ]
        let value = min(max(distance.isFinite ? distance : 3, 0), 3)
        guard let upperIndex = stops.firstIndex(where: { $0.0 >= value }), upperIndex > 0 else {
            return stops[0].1
        }
        let lower = stops[upperIndex - 1]
        let upper = stops[upperIndex]
        let fraction = (value - lower.0) / (upper.0 - lower.0)
        return lower.1 + (upper.1 - lower.1) * fraction
    }

    private func updateTargetOpacity() {
        guard let targetNode else { return }
        PPMTargetAppearance.apply(to: targetNode, opacity: targetOpacity, visible: showTarget)
    }

    var pointOfView: SCNNode? { cameraNode }
    var cameraTarget: SCNVector3 { targetCenter }
    var cameraSpan: Double { Double(cameraExtent) }

    func resetCamera() {
        setCameraView(request.side == .right ? "Right" : "Left")
    }

    func setCameraView(_ direction: String) {
        guard let cameraNode else { return }
        let distance = cameraExtent * 1.8
        let offset = direction == "Front" ? SCNVector3(1, 0, 0.08)
            : SCNVector3(0, direction == "Right" ? -1 : 1, 0.08)
        cameraNode.position = SCNVector3(targetCenter.x + offset.x * distance,
                                        targetCenter.y + offset.y * distance,
                                        targetCenter.z + offset.z * distance)
        cameraNode.constraints = nil
        cameraNode.look(at: targetCenter, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        cameraRevision += 1
    }

    private func configureCameraIfNeeded() {
        guard targetNode != nil, ppmNode != nil, !cameraConfigured else { return }
        cameraConfigured = true
        let framing = SCNNode()
        if let targetNode { framing.addChildNode(targetNode.clone()) }
        if let ppmNode { framing.addChildNode(ppmNode.clone()) }
        let bounds = framing.boundingBox
        targetCenter = SCNVector3((bounds.min.x + bounds.max.x) / 2,
                                  (bounds.min.y + bounds.max.y) / 2,
                                  (bounds.min.z + bounds.max.z) / 2)
        let extent = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
        cameraExtent = max(extent, 1)
        let distance = max(extent * 1.8, 1)
        let target = SCNNode()
        target.name = "cameraTarget"
        target.position = targetCenter
        scene.rootNode.addChildNode(target)
        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.zFar = max(extent * 10, 10_000)
        let node = SCNNode()
        node.camera = camera
        let front: CGFloat = request.side == .left ? 1 : -1
        node.position = SCNVector3(targetCenter.x, targetCenter.y + front * distance, targetCenter.z + extent * 0.12)
        let lookAt = SCNLookAtConstraint(target: target)
        lookAt.isGimbalLockEnabled = true
        lookAt.worldUp = SCNVector3(0, 0, 1)
        node.constraints = [lookAt]
        scene.rootNode.addChildNode(node)
        cameraNode = node
        cameraRevision += 1
        let light = SCNLight()
        light.type = .directional
        light.intensity = 900
        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.position = SCNVector3(-extent * 0.65, extent * 0.75, -extent * 0.9)
        node.addChildNode(lightNode)
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 150
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
    }

    private func archiveTemplateIfNeeded() throws -> URL? {
        guard !templateBlendPath.isEmpty else { return nil }
        let source = URL(fileURLWithPath: templateBlendPath)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let folder = request.destinationMesh.deletingLastPathComponent().appendingPathComponent("Templates", isDirectory: true)
        if source.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") { return source }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("\(UUID().uuidString)-PPM.blend")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
