import AppKit
import SceneKit
import SwiftUI

struct PressureStep: Decodable, Identifiable {
    let id: Int
    let frequency: Double?
    let surfaces: [String]
    var label: String { frequency.map { String(format: "%.2f Hz", $0) } ?? "Step \(id)" }
}

struct PressureFrame: Decodable {
    let vertices: [[Float]]
    let triangles: [[UInt32]]
    let association: String
    let real: [Double]
    let imaginary: [Double]
}

enum PressureQuantity: String, CaseIterable, Identifiable {
    case level = "Level", magnitude = "Magnitude", phase = "Phase", real = "Real", imaginary = "Imaginary"
    var id: String { rawValue }
    var unit: String { self == .level ? "dB re 20 µPa" : self == .phase ? "rad" : "Pa" }
    func value(real: Double, imaginary: Double) -> Double? {
        switch self {
        case .level: return 20 * log10(max(hypot(real, imaginary) / 0.00002, 1e-8))
        case .magnitude: return hypot(real, imaginary)
        case .phase: return real == 0 && imaginary == 0 ? nil : atan2(imaginary, real)
        case .real: return real
        case .imaginary: return imaginary
        }
    }

    var palette: [SIMD3<Float>] {
        switch self {
        case .phase: return [SIMD3(0.85,0.15,0.2), SIMD3(0.9,0.8,0.1), SIMD3(0.1,0.75,0.75), SIMD3(0.3,0.2,0.8), SIMD3(0.85,0.15,0.2)]
        case .real, .imaginary: return [SIMD3(0.15,0.3,0.75), SIMD3(0.95,0.95,0.95), SIMD3(0.8,0.15,0.15)]
        default: return [SIMD3(0.267,0.005,0.329), SIMD3(0.23,0.322,0.546), SIMD3(0.128,0.567,0.551), SIMD3(0.369,0.789,0.383), SIMD3(0.993,0.906,0.144)]
        }
    }
}

@MainActor
final class PressureFieldModel: ObservableObject {
    let source: URL
    @Published var steps: [PressureStep] = []
    @Published var step = 0
    @Published var surface = "Boundary"
    @Published var quantity: PressureQuantity = .level
    @Published var lockScale = false
    @Published private(set) var range: ClosedRange<Double> = 0...1
    @Published private(set) var scene = SCNScene()
    @Published private(set) var cameraRevision = 0
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var loadID = UUID()
    private var frame: PressureFrame?
    private var fieldNode: SCNNode?
    private var camera: SCNNode?
    private var cameraTarget: SCNNode?
    private var cameraDistance: Float = 1
    private var loadedSurface: String?
    private var colorsRangeSet = false

    init(source: URL) { self.source = source }
    var selection: String { "\(step)|\(surface)" }
    var selectedStep: PressureStep? { steps.first { $0.id == step } }
    var surfaces: [String] { selectedStep?.surfaces ?? ["Boundary"] }

    private static func read<T: Decodable>(_ command: [String: Any], as type: T.Type) async throws -> T {
        let input = try JSONSerialization.data(withJSONObject: command)
        return try await Task.detached(priority: .userInitiated) {
            let data = try ProjectConfigDocument.runPython("""
            import json, sys
            from HRTFCalculation.PressureField import execute
            print(json.dumps(execute(json.load(sys.stdin)), allow_nan=False))
            """, input: input)
            return try JSONDecoder().decode(type, from: data)
        }.value
    }

    func open() async {
        struct Catalog: Decodable { let steps: [PressureStep] }
        loading = true
        error = nil
        do {
            let catalog = try await Self.read(["action": "inspect", "source": source.path], as: Catalog.self)
            guard !Task.isCancelled else { return }
            steps = catalog.steps
            if !steps.contains(where: { $0.id == step }) { step = steps.first?.id ?? 0 }
            if !surfaces.contains(surface) { surface = surfaces.first ?? "Boundary" }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }

    func load() async {
        guard step > 0 else { return }
        if !surfaces.contains(surface) { surface = surfaces.first ?? "Boundary"; return }
        loading = true
        error = nil
        let requestedSurface = surface
        let requestedSelection = selection
        let requestID = UUID()
        loadID = requestID
        do {
            let result = try await Self.read(["action": "frame", "source": source.path, "step": step, "surface": surface], as: PressureFrame.self)
            guard !Task.isCancelled, loadID == requestID, selection == requestedSelection else { return }
            guard !result.vertices.isEmpty, !result.triangles.isEmpty,
                  result.vertices.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }),
                  result.triangles.allSatisfy({ $0.count == 3 && $0.allSatisfy { Int($0) < result.vertices.count } }),
                  ["cell", "point"].contains(result.association),
                  result.real.count == (result.association == "cell" ? result.triangles.count : result.vertices.count),
                  result.imaginary.count == result.real.count,
                  result.real.allSatisfy(\.isFinite), result.imaginary.allSatisfy(\.isFinite) else {
                throw ProjectValidation.Failure(message: "Invalid pressure geometry or values.")
            }
            frame = result
            if loadedSurface != requestedSurface || camera == nil { configureCamera(result) }
            loadedSurface = requestedSurface
            recolor()
        } catch {
            guard !Task.isCancelled, loadID == requestID, selection == requestedSelection else { return }
            frame = nil
            fieldNode?.removeFromParentNode()
            fieldNode = nil
            self.error = error.localizedDescription
        }
        loading = false
    }

    func changeQuantity() { colorsRangeSet = false; recolor() }

    func recolor() {
        guard let frame else { return }
        let values = zip(frame.real, frame.imaginary).map { quantity.value(real: $0, imaginary: $1) }
        let finite = values.compactMap { $0 }.filter(\.isFinite)
        if !lockScale || !colorsRangeSet {
            var lower = finite.min() ?? 0, upper = finite.max() ?? 1
            if quantity == .phase { lower = -.pi; upper = .pi }
            if quantity == .real || quantity == .imaginary { upper = max(abs(lower), abs(upper)); lower = -upper }
            if lower == upper { lower -= 0.5; upper += 0.5 }
            range = lower...upper
            colorsRangeSet = true
        }
        let palette = quantity.palette
        func color(_ value: Double?) -> SIMD4<Float> {
            guard let value, value.isFinite else { return SIMD4(0.5,0.5,0.5,1) }
            let t = Float(min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))) * Float(palette.count - 1)
            let index = min(Int(t), palette.count - 2)
            let rgb = palette[index] + (palette[index + 1] - palette[index]) * (t - Float(index))
            return SIMD4(rgb.x, rgb.y, rgb.z, 1)
        }
        var vertices: [SCNVector3] = []
        var colors: [SIMD4<Float>] = []
        for (face, triangle) in frame.triangles.enumerated() {
            for index in triangle {
                let point = frame.vertices[Int(index)]
                vertices.append(SCNVector3(point[0], point[1], point[2]))
                colors.append(color(values[frame.association == "cell" ? face : Int(index)]))
            }
        }
        let colorSource = SCNGeometrySource(data: colors.withUnsafeBytes { Data($0) }, semantic: .color,
            vectorCount: colors.count, usesFloatComponents: true, componentsPerVector: 4,
            bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let element = SCNGeometryElement(indices: Array(UInt32(0)..<UInt32(vertices.count)), primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        material.isDoubleSided = true
        geometry.materials = [material]
        fieldNode?.removeFromParentNode()
        let node = SCNNode(geometry: geometry)
        scene.rootNode.addChildNode(node)
        fieldNode = node
        objectWillChange.send()
    }

    private func configureCamera(_ frame: PressureFrame) {
        let points = frame.vertices.map { SIMD3($0[0], $0[1], $0[2]) }
        let lower = points.reduce(points[0], simd_min), upper = points.reduce(points[0], simd_max)
        cameraTarget?.removeFromParentNode()
        camera?.removeFromParentNode()
        let target = SCNNode()
        target.simdPosition = (lower + upper) / 2
        let node = SCNNode()
        let lens = SCNCamera()
        lens.fieldOfView = 38
        cameraDistance = max(simd_length(upper - lower) * 1.6, 0.001)
        lens.zNear = Double(cameraDistance) / 10000
        lens.zFar = Double(cameraDistance) * 100
        node.camera = lens
        let aim = SCNLookAtConstraint(target: target)
        aim.worldUp = SCNVector3(0,0,1)
        aim.isGimbalLockEnabled = true
        node.constraints = [aim]
        scene.rootNode.addChildNode(target)
        scene.rootNode.addChildNode(node)
        camera = node
        cameraTarget = target
        resetCamera()
    }

    func resetCamera() {
        guard let camera, let cameraTarget else { return }
        let side: Float = source.path.contains("/Right/") ? -1 : 1
        camera.simdPosition = cameraTarget.simdPosition + SIMD3(0, side * cameraDistance, cameraDistance * 0.08)
        cameraRevision += 1
    }
}
