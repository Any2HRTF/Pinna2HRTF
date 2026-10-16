import Foundation
import simd

struct MeshEditorRequest: Identifiable {
    let id = UUID()
    let projectID: UUID
    let source: URL
    let originalSource: URL
    let destination: URL
    let side: EarSide?
    let preparedGeneration: String?
    let preparedReport: URL?
    var isAlignment: Bool { side == nil }
    var title: String { side.map { "Edit \($0.title) Ear" } ?? "Nose and Ear Alignment" }
}

/// A compact display rectangle around the mesh/plane intersection.
/// Its size affects only the overlay; the backend still cuts a half-space.
struct CuttingPlanePreview {
    let center: SIMD3<Float>
    let orientation: simd_quatf
    let width: Float
    let height: Float

    static func fit(vertices: [Float], faces: [UInt32], origin: SIMD3<Float>, normal: SIMD3<Float>) -> Self? {
        guard !vertices.isEmpty, !faces.isEmpty else { return nil }
        let direction = simd_normalize(normal)
        let orientation = simd_quatf(from: SIMD3<Float>(0,0,1), to: direction)
        let xAxis = orientation.act(SIMD3<Float>(1,0,0))
        let yAxis = orientation.act(SIMD3<Float>(0,1,0))
        var lower = SIMD3<Float>(repeating: .infinity)
        var upper = SIMD3<Float>(repeating: -.infinity)
        let local = stride(from: 0, to: vertices.count, by: 3).map { index -> SIMD3<Float> in
            let offset = SIMD3(vertices[index], vertices[index+1], vertices[index+2]) - origin
            let point = SIMD3(simd_dot(offset, xAxis), simd_dot(offset, yAxis), simd_dot(offset, direction))
            lower = simd_min(lower, point); upper = simd_max(upper, point)
            return point
        }
        let tolerance = max(simd_length(upper - lower) * 0.000001, 0.000001)
        var sectionMin = SIMD2<Float>(repeating: .infinity)
        var sectionMax = SIMD2<Float>(repeating: -.infinity)
        var intersects = false
        func include(_ point: SIMD3<Float>) {
            let xy = SIMD2(point.x, point.y)
            sectionMin = simd_min(sectionMin, xy); sectionMax = simd_max(sectionMax, xy)
            intersects = true
        }
        for index in stride(from: 0, to: faces.count, by: 3) {
            let a = local[Int(faces[index])], b = local[Int(faces[index+1])], c = local[Int(faces[index+2])]
            if min(a.z, b.z, c.z) > tolerance || max(a.z, b.z, c.z) < -tolerance { continue }
            for (start, end) in [(a,b), (b,c), (c,a)] {
                if abs(start.z) <= tolerance { include(start) }
                if (start.z < 0 && end.z > 0) || (start.z > 0 && end.z < 0) {
                    include(start + (end - start) * (start.z / (start.z - end.z)))
                }
            }
        }
        // Keep an out-of-mesh plane visible using the mesh's projected footprint.
        if !intersects {
            sectionMin = SIMD2(lower.x, lower.y); sectionMax = SIMD2(upper.x, upper.y)
        }
        let midpoint = (sectionMin + sectionMax) / 2
        return Self(center: origin + xAxis * midpoint.x + yAxis * midpoint.y,
                    orientation: orientation,
                    width: max((sectionMax.x - sectionMin.x) * 1.08, 0.5),
                    height: max((sectionMax.y - sectionMin.y) * 1.08, 0.5))
    }
}
