import Foundation

func pressureQuantityChecks() {
    precondition(PressureQuantity.magnitude.value(real: 3, imaginary: 4) == 5)
    precondition(abs(PressureQuantity.level.value(real: 0.00002, imaginary: 0)!) < 1e-12)
    precondition(abs(PressureQuantity.level.value(real: 0.0002, imaginary: 0)! - 20) < 1e-12)
    precondition(PressureQuantity.level.value(real: 0, imaginary: 0) == -160)
    precondition(abs(PressureQuantity.phase.value(real: 0, imaginary: 1)! - .pi / 2) < 1e-12)
    precondition(abs(PressureQuantity.phase.value(real: 0, imaginary: -1)! + .pi / 2) < 1e-12)
    precondition(PressureQuantity.phase.value(real: 0, imaginary: 0) == nil)
    precondition(PressureQuantity.real.value(real: -3, imaginary: 4) == -3)
    precondition(PressureQuantity.imaginary.value(real: 3, imaginary: -4) == -4)
    precondition(PressureQuantity.phase.palette.first == PressureQuantity.phase.palette.last)
    print("Pressure magnitude, dB reference, phase, signed components and cyclic palette checks passed.")
}

@MainActor
func pressureFrameChecks() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pinna-pressure-check-\(UUID())")
    let result = folder.appendingPathComponent("be.out/be.1")
    try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func write(_ path: String, _ text: String) throws {
        try text.write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    try write("NC.inp", "## Load Frequency Curve\n0 2\n0 0 0\n1 1000 0\nNODES\nNodes.txt\nELEMENTS\nElements.txt\nBOUNDARY\n")
    try write("Nodes.txt", "3\n10 0 0 0\n20 1 0 0\n30 0 1 0\n")
    try write("Elements.txt", "1\n7 10 20 30 0 0 0\n")
    try write("be.out/be.1/pBoundary", "Mesh2HRTF 1.3.0\n1\n0 1\n7 3 4\n")
    let model = PressureFieldModel(source: folder.appendingPathComponent("NC.inp"))
    await model.open()
    precondition(model.error == nil, model.error ?? "")
    precondition(model.steps.count == 1 && model.selectedStep?.frequency == 1000)
    await model.load()
    precondition(model.error == nil, model.error ?? "")
    let cameraRevision = model.cameraRevision
    precondition(model.scene.rootNode.childNodes.filter { $0.geometry != nil }.count == 1)
    model.quantity = .magnitude
    model.changeQuantity()
    precondition(model.range.contains(5))
    let lockedRange = model.range
    model.lockScale = true
    try write("be.out/be.1/pBoundary", "Mesh2HRTF 1.3.0\n1\n0 1\n7 0 20\n")
    await model.load()
    precondition(model.range == lockedRange)
    precondition(model.cameraRevision == cameraRevision)
    model.resetCamera()
    precondition(model.cameraRevision > cameraRevision)
    try write("be.out/be.1/pBoundary", "Mesh2HRTF 1.3.0\n1\n0 1\n")
    await model.load()
    precondition(model.error != nil)
    precondition(model.scene.rootNode.childNodes.allSatisfy { $0.geometry == nil })
    print("Native pressure loading, color-scale locking, camera preservation and incomplete-result handling passed.")
}
