import Foundation
import SceneKit
import AppKit
import simd

@MainActor
final class MeshEditorModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case navigate = "Navigate", landmarks = "Landmarks", selection = "Select Faces", plane = "Cutting Plane"
        var id: String { rawValue }
    }
    let request: MeshEditorRequest
    let scene = SCNScene()
    let workspace = URL(fileURLWithPath: "/private/tmp/pinna-mesh-editor-\(UUID().uuidString)")
    @Published var tool: Tool
    @Published var busy = false
    @Published var message = "Loading mesh…"
    @Published var error: String?
    @Published var selectedFaces = Set<Int>()
    @Published var throughSelection = false
    @Published var addToSelection = false
    @Published var landmarks: [SCNVector3] = []
    @Published var landmarkSlot = 0
    @Published var planeX = "0"
    @Published var planeY = "1"
    @Published var planeZ = "0"
    @Published var planeOffset = 0.0
    @Published var flipPlane = false
    @Published var fitPlanePreview = true
    @Published var planePreviewWidth = 40.0
    @Published var planePreviewHeight = 40.0
    @Published var revision = 0
    private(set) var cameraRevision = 0
    private var versions: [URL] = []
    private var operations: [[String: Any]] = []
    private var toolBeforeNavigation: Tool = .selection
    private var currentVersion = 0
    private var versionCounter = 0
    private var originalSHA256 = ""
    private(set) var vertices: [Float] = []
    private(set) var faces: [UInt32] = []
    private var vertexData = Data(), normalData = Data()
    private var boundsMin = SIMD3<Float>(repeating: -1), boundsMax = SIMD3<Float>(repeating: 1)
    private var meshNode: SCNNode?
    private var meshEdgesNode: SCNNode?
    private var selectionNode: SCNNode?
    private var planeNode: SCNNode?
    private var cameraNode: SCNNode?
    private var targetNode: SCNNode?
    private var markerNodes: [SCNNode] = []

    init(request: MeshEditorRequest) {
        self.request = request
        self.tool = request.isAlignment ? .landmarks : .selection
    }
    deinit { try? FileManager.default.removeItem(at: workspace) }

    var tools: [Tool] { request.isAlignment ? [.landmarks] : [.selection, .plane] }
    var canUndo: Bool { !busy && currentVersion > 0 }
    var canRedo: Bool { !busy && currentVersion + 1 < versions.count }
    var hasAlignment: Bool { operations.prefix(currentVersion).contains { $0["action"] as? String == "align" } }
    var canSave: Bool { !busy && !versions.isEmpty && selectedFaces.isEmpty && tool != .plane && (!request.isAlignment || hasAlignment) }
    var span: Double { max(Double(simd_length(boundsMax - boundsMin)), 1) }
    var center: SIMD3<Float> { (boundsMin + boundsMax) / 2 }
    var normal: SIMD3<Float>? {
        guard let x = Float(planeX), let y = Float(planeY), let z = Float(planeZ), x.isFinite, y.isFinite, z.isFinite else { return nil }
        let vector = SIMD3<Float>(x, y, z)
        guard simd_length(vector) > 0.000001 else { return nil }
        return simd_normalize(vector) * (flipPlane ? -1 : 1)
    }
    var planeOrigin: SIMD3<Float> {
        // Flip changes the kept side, not the location of the cutting plane.
        let direction = (normal ?? SIMD3<Float>(0,1,0)) * (flipPlane ? -1 : 1)
        return center + direction * Float(planeOffset)
    }

    var fittedPlanePreview: CuttingPlanePreview? {
        guard planeOffset.isFinite, let normal else { return nil }
        return CuttingPlanePreview.fit(vertices: vertices, faces: faces, origin: planeOrigin,
                                       normal: normal * (flipPlane ? -1 : 1))
    }

    var validPlanePreviewSize: Bool {
        planePreviewWidth.isFinite && planePreviewHeight.isFinite && planePreviewWidth > 0 && planePreviewHeight > 0
    }

    func setNavigationMode(_ active: Bool) {
        guard !request.isAlignment else { return }
        if active {
            guard tool != .navigate else { return }
            toolBeforeNavigation = tool
            tool = .navigate
        } else if tool == .navigate {
            tool = toolBeforeNavigation
        }
    }

    func updatePlanePreviewSizing() {
        if !fitPlanePreview, let fitted = fittedPlanePreview {
            planePreviewWidth = Double(fitted.width)
            planePreviewHeight = Double(fitted.height)
        }
        refreshOverlays()
    }

    static func send(_ command: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: command)
        let response = try await Task.detached(priority: .userInitiated) {
            try ProjectConfigDocument.runPython("""
            import sys, json
            from HRTFCalculation.MeshEditing import execute
            print(json.dumps(execute(json.load(sys.stdin)), allow_nan=False))
            """, input: data)
        }.value
        guard let result = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw ProjectValidation.Failure(message: "The mesh editor returned unreadable data.")
        }
        return result
    }

    func open() async {
        guard versions.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let first = workspace.appendingPathComponent("mesh-0.ply")
            let result = try await Self.send(["action": "open", "source": request.source.path,
                "original_source": request.originalSource.path, "output": first.path,
                "frame": workspace.appendingPathComponent("frame").path])
            originalSHA256 = result["source_sha256"] as? String ?? ""
            versions = [first]
            try install(result)
            message = request.isAlignment ? "Choose Landmarks, then click the nose tip, left ear-canal entrance, and right ear-canal entrance." : "Select and delete faces to open the canal. Use a cutting plane to trim the attachment area."
        } catch { self.error = error.localizedDescription }
    }

    func edit(_ action: String, arguments: [String: Any] = [:]) async {
        guard !busy, !versions.isEmpty else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            versionCounter += 1
            let next = workspace.appendingPathComponent("mesh-\(versionCounter).ply")
            var command = arguments
            command["action"] = action
            command["source"] = versions[currentVersion].path
            command["output"] = next.path
            command["frame"] = workspace.appendingPathComponent("frame").path
            let result = try await Self.send(command)
            // Read the new buffers before changing undo history.
            try install(result)
            versions = Array(versions.prefix(currentVersion + 1)) + [next]
            var operation = arguments
            operation["action"] = action
            for key in ["transform", "alignment_method", "landmark_labels"] {
                if let value = result[key] { operation[key] = value }
            }
            operations = Array(operations.prefix(currentVersion)) + [operation]
            currentVersion += 1
            selectedFaces.removeAll()
            if action == "align" { landmarks.removeAll(); refreshMarkers(); tool = .landmarks; resetCamera() }
            if action == "cut" { toolBeforeNavigation = .plane; tool = .navigate; planeOffset = 0 }
            refreshOverlays()
            message = "\(faces.count / 3) faces · Edit applied. Undo is available."
            revision += 1
        } catch { self.error = error.localizedDescription }
    }

    func moveHistory(_ offset: Int) async {
        let index = currentVersion + offset
        guard !busy, versions.indices.contains(index) else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let result = try await Self.send(["action": "inspect", "source": versions[index].path,
                                             "frame": workspace.appendingPathComponent("frame").path])
            try install(result)
            currentVersion = index
            selectedFaces.removeAll()
            landmarks.removeAll()
            refreshMarkers()
            tool = request.isAlignment ? .landmarks : .navigate
            refreshOverlays()
            revision += 1
            message = "\(faces.count / 3) faces · \(offset < 0 ? "Undone" : "Redone")"
        } catch { self.error = error.localizedDescription }
    }

    func save() async -> Bool {
        guard canSave else { return false }
        busy = true
        error = nil
        defer { busy = false }
        do {
            var command: [String: Any] = ["action": "save", "kind": request.isAlignment ? "alignment" : "ear",
                "source": versions[currentVersion].path, "original_source": request.originalSource.path,
                "original_sha256": originalSHA256, "destination": request.destination.path,
                "operations": Array(operations.prefix(currentVersion))]
            if let side = request.side, let report = request.preparedReport, let generation = request.preparedGeneration {
                command["side"] = side.rawValue
                command["prepared_report"] = report.path
                command["prepared_generation"] = generation
            }
            _ = try await Self.send(command)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    private func install(_ result: [String: Any]) throws {
        guard let v = result["vertices"] as? String, let n = result["normals"] as? String,
              let f = result["faces"] as? String, let bounds = result["bounds"] as? [[Double]], bounds.count == 2 else {
            throw ProjectValidation.Failure(message: "The mesh frame is incomplete.")
        }
        let newVertices = try Data(contentsOf: URL(fileURLWithPath: v))
        let newNormals = try Data(contentsOf: URL(fileURLWithPath: n))
        let newFaces = try Data(contentsOf: URL(fileURLWithPath: f))
        guard newVertices.count % 12 == 0, newNormals.count == newVertices.count, newFaces.count % 12 == 0 else {
            throw ProjectValidation.Failure(message: "Invalid mesh buffers.")
        }
        vertexData = newVertices; normalData = newNormals
        vertices = vertexData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        faces = newFaces.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        boundsMin = SIMD3<Float>(Float(bounds[0][0]), Float(bounds[0][1]), Float(bounds[0][2]))
        boundsMax = SIMD3<Float>(Float(bounds[1][0]), Float(bounds[1][1]), Float(bounds[1][2]))
        meshNode?.removeFromParentNode()
        meshEdgesNode?.removeFromParentNode()
        let geometry = geometry(indices: newFaces)
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedRed: 0.81, green: 0.77, blue: 0.72, alpha: 1)
        material.roughness.contents = 0.8
        material.isDoubleSided = true
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.categoryBitMask = 1
        scene.rootNode.addChildNode(node)
        meshNode = node
        if !request.isAlignment {
            let edges = self.geometry(indices: newFaces)
            let edgeMaterial = SCNMaterial()
            edgeMaterial.diffuse.contents = NSColor(calibratedRed: 0.015, green: 0.025, blue: 0.04, alpha: 1)
            edgeMaterial.lightingModel = .constant
            edgeMaterial.fillMode = .lines
            edgeMaterial.cullMode = .back
            edgeMaterial.isDoubleSided = false
            edgeMaterial.readsFromDepthBuffer = false
            edgeMaterial.writesToDepthBuffer = false
            edges.materials = [edgeMaterial]
            let edgeNode = SCNNode(geometry: edges)
            edgeNode.renderingOrder = 20
            edgeNode.categoryBitMask = 0
            edgeNode.castsShadow = false
            scene.rootNode.addChildNode(edgeNode)
            meshEdgesNode = edgeNode
        }
        if cameraNode == nil { configureCamera() }
        selectedFaces.removeAll()
        refreshOverlays()
    }

    private func geometry(indices: Data) -> SCNGeometry {
        let vertex = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: vertices.count / 3,
                                      usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let normal = SCNGeometrySource(data: normalData, semantic: .normal, vectorCount: vertices.count / 3,
                                      usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let element = SCNGeometryElement(data: indices, primitiveType: .triangles, primitiveCount: indices.count / 12, bytesPerIndex: 4)
        return SCNGeometry(sources: [vertex, normal], elements: [element])
    }

    private func configureCamera() {
        scene.background.contents = NSColor(calibratedWhite: 0.16, alpha: 1)
        let target = SCNNode(); target.simdPosition = center
        scene.rootNode.addChildNode(target); targetNode = target
        let node = SCNNode(); let camera = SCNCamera()
        camera.zNear = 0.05; camera.zFar = max(span * 30, 10000); camera.fieldOfView = 38
        node.camera = camera
        let constraint = SCNLookAtConstraint(target: target)
        constraint.worldUp = SCNVector3(0,0,1); constraint.isGimbalLockEnabled = true
        node.constraints = [constraint]
        scene.rootNode.addChildNode(node); cameraNode = node
        // Equal lights on the two ear sides keep either ear readable when orbiting.
        for side: Float in [-1, 1] {
            let sideNode = SCNNode(); let sideLight = SCNLight()
            sideLight.type = .directional; sideLight.intensity = 700
            sideLight.castsShadow = false; sideNode.light = sideLight
            sideNode.simdPosition = SIMD3<Float>(0.4, side, 0.6) * Float(span)
            let aim = SCNLookAtConstraint(target: target)
            aim.worldUp = SCNVector3(0,0,1); aim.isGimbalLockEnabled = true
            sideNode.constraints = [aim]
            target.addChildNode(sideNode)
        }
        let lightNode = SCNNode(); let light = SCNLight()
        light.type = .omni; light.intensity = 250; lightNode.light = light
        node.addChildNode(lightNode)
        let ambientNode = SCNNode(); let ambient = SCNLight()
        ambient.type = .ambient; ambient.intensity = 320; ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
        resetCamera()
    }

    func resetCamera() {
        cameraRevision += 1
        targetNode?.simdPosition = center
        let side: Float = request.side == .right ? -1 : 1
        cameraNode?.simdPosition = center + SIMD3<Float>(0, side * Float(span * 1.7), Float(span * 0.15))
        revision += 1
    }
    var pointOfView: SCNNode? { cameraNode }

    func pickLandmark(_ point: SCNVector3) {
        guard !busy, tool == .landmarks else { return }
        if landmarkSlot < landmarks.count { landmarks[landmarkSlot] = point }
        else { landmarks.append(point) }
        landmarkSlot = min(landmarks.count, 2)
        refreshMarkers()
    }
    private func refreshMarkers() {
        markerNodes.forEach { $0.removeFromParentNode() }; markerNodes.removeAll()
        let colors: [NSColor] = [.systemRed, .systemBlue, .systemGreen]
        for (index, point) in landmarks.enumerated() {
            let sphere = SCNSphere(radius: CGFloat(span * 0.006))
            sphere.firstMaterial?.diffuse.contents = colors[index]
            sphere.firstMaterial?.lightingModel = .constant
            let node = SCNNode(geometry: sphere); node.position = point; node.categoryBitMask = 16
            scene.rootNode.addChildNode(node); markerNodes.append(node)
        }
    }

    func selectPolygon(_ points: [CGPoint], in view: SCNView) {
        guard !busy, tool == .selection, points.count >= 3 else { return }
        let path = CGMutablePath(); path.addLines(between: points); path.closeSubpath()
        let rectangle = path.boundingBox
        var chosen = Set<Int>()
        // Only projected centroids enclosed by the lasso are candidates. The
        // default front-surface mode also checks the closest hit for occlusion.
        for face in 0..<(faces.count / 3) {
            let p = (vertex(Int(faces[face*3])) + vertex(Int(faces[face*3+1])) + vertex(Int(faces[face*3+2]))) / 3
            let projected = view.projectPoint(SCNVector3(p))
            let point = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
            guard projected.z >= 0, projected.z <= 1, rectangle.contains(point), path.contains(point) else { continue }
            if !throughSelection {
                let hits = view.hitTest(point, options: [.categoryBitMask: 1, .searchMode: SCNHitTestSearchMode.closest.rawValue, .backFaceCulling: false])
                guard hits.first?.faceIndex == face else { continue }
            }
            chosen.insert(face)
        }
        if addToSelection { selectedFaces.formUnion(chosen) } else { selectedFaces = chosen }
        message = "\(selectedFaces.count) faces selected. Review the red area, then Delete Selected Faces."
        refreshOverlays()
    }

    private func vertex(_ index: Int) -> SIMD3<Float> { SIMD3(vertices[index*3], vertices[index*3+1], vertices[index*3+2]) }

    func refreshOverlays() {
        selectionNode?.removeFromParentNode(); selectionNode = nil
        planeNode?.removeFromParentNode(); planeNode = nil
        var highlighted = selectedFaces
        if tool == .plane, planeOffset.isFinite, let normal {
            let origin = planeOrigin
            highlighted = Set((0..<(faces.count / 3)).filter { face in
                let p = (vertex(Int(faces[face*3])) + vertex(Int(faces[face*3+1])) + vertex(Int(faces[face*3+2]))) / 3
                return simd_dot(p - origin, normal) < 0
            })
            if let preview = fittedPlanePreview {
                let custom = !fitPlanePreview && validPlanePreviewSize
                let plane = SCNPlane(width: custom ? CGFloat(planePreviewWidth) : CGFloat(preview.width),
                                     height: custom ? CGFloat(planePreviewHeight) : CGFloat(preview.height))
                plane.firstMaterial?.diffuse.contents = NSColor.systemCyan.withAlphaComponent(0.18)
                plane.firstMaterial?.isDoubleSided = true
                plane.firstMaterial?.writesToDepthBuffer = false
                plane.firstMaterial?.lightingModel = .constant
                let node = SCNNode(geometry: plane); node.categoryBitMask = 8
                node.simdPosition = preview.center
                node.simdOrientation = preview.orientation
                scene.rootNode.addChildNode(node); planeNode = node
            }
        }
        if !highlighted.isEmpty {
            let selectedIndices: [UInt32] = highlighted.sorted().flatMap { face in Array(faces[face*3..<face*3+3]) }
            let data = selectedIndices.withUnsafeBytes { Data($0) }
            let selectedGeometry = geometry(indices: data)
            let material = SCNMaterial()
            material.diffuse.contents = NSColor.systemRed.withAlphaComponent(0.8)
            material.isDoubleSided = true; material.lightingModel = .constant
            material.writesToDepthBuffer = false
            selectedGeometry.materials = [material]
            selectedGeometry.shaderModifiers = [.geometry: "_geometry.position.xyz += _geometry.normal * 0.015;"]
            let node = SCNNode(geometry: selectedGeometry); node.renderingOrder = 10; node.categoryBitMask = 4
            scene.rootNode.addChildNode(node); selectionNode = node
        }
        revision += 1
    }
}
