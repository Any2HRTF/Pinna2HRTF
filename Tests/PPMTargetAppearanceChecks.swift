import AppKit
import SceneKit
import Metal

@MainActor func targetAppearanceChecks() throws {
    let scene = SCNScene()
    scene.background.contents = NSColor.black
    let camera = SCNNode()
    camera.camera = SCNCamera()
    camera.camera!.usesOrthographicProjection = true
    camera.camera!.orthographicScale = 2
    camera.position = SCNVector3(0, 0, 5)
    scene.rootNode.addChildNode(camera)
    let ppm = SCNNode(geometry: SCNPlane(width: 2, height: 2))
    ppm.geometry!.firstMaterial!.diffuse.contents = NSColor.red
    ppm.geometry!.firstMaterial!.lightingModel = .constant
    scene.rootNode.addChildNode(ppm)
    let target = SCNNode()
    let container = SCNNode()
    let scan = SCNNode(geometry: SCNBox(width: 2, height: 2, length: 0.1, chamferRadius: 0))
    scan.position.z = 0.2
    container.addChildNode(scan)
    target.addChildNode(container)
    scene.rootNode.addChildNode(target)
    let light = SCNNode()
    light.light = SCNLight()
    light.light!.type = .ambient
    light.light!.intensity = 1000
    scene.rootNode.addChildNode(light)
    let renderer = MTLCreateSystemDefaultDevice().map { SCNRenderer(device: $0, options: nil) }
    renderer?.scene = scene
    renderer?.pointOfView = camera
    var pixels: [NSColor] = []
    for opacity in [0.0, 0.5, 1.0] {
        PPMTargetAppearance.apply(to: target, opacity: opacity, visible: true)
        precondition(target.isHidden == (opacity == 0))
        let material = scan.geometry!.firstMaterial!
        precondition(material.transparency == 1)
        precondition((material.transparent.contents as? NSColor)?.alphaComponent == CGFloat(opacity))
        precondition(material.transparencyMode == .singleLayer)
        precondition(material.writesToDepthBuffer)
        guard let renderer else { continue }
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 128, height: 128), antialiasingMode: .none)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            throw NSError(domain: "TargetOpacityChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Renderer returned an empty image."])
        }
        let color = bitmap.colorAt(x: 64, y: 64)!.usingColorSpace(.deviceRGB)!
        pixels.append(color)
        if opacity == 0.5 {
            let closedMesh = scan.geometry
            scan.geometry = SCNPlane(width: 2, height: 2)
            PPMTargetAppearance.apply(to: target, opacity: opacity, visible: true)
            let singleFace = renderer.snapshot(atTime: 0, with: CGSize(width: 128, height: 128), antialiasingMode: .none)
            let singleBitmap = NSBitmapImageRep(data: singleFace.tiffRepresentation!)!
            let singleColor = singleBitmap.colorAt(x: 64, y: 64)!.usingColorSpace(.deviceRGB)!
            // A closed scan must not double its opacity by blending its rear face.
            precondition(abs(singleColor.redComponent - color.redComponent) < 0.02)
            precondition(abs(singleColor.greenComponent - color.greenComponent) < 0.02)
            scan.geometry = closedMesh
        }
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/pinna-target-opacity-\(Int(opacity * 100)).png"))
    }
    if !pixels.isEmpty {
        precondition(pixels[0].redComponent > pixels[0].greenComponent + 0.4)
        // Rendered gray contribution increases as the target becomes opaque.
        precondition(pixels[1].greenComponent > pixels[0].greenComponent + 0.05)
        precondition(pixels[2].greenComponent > pixels[1].greenComponent + 0.05)
    } else {
        print("Metal unavailable; target material checks passed, rendered pixel checks skipped.")
    }
    precondition(ppm.geometry!.firstMaterial!.transparency == 1)
    PPMTargetAppearance.apply(to: target, opacity: 0.5, visible: false)
    precondition(target.isHidden)
    PPMTargetAppearance.apply(to: target, opacity: 0.5, visible: true)
    precondition(!target.isHidden)
    print("Target opacity at 0/50/100%, nested geometry and display switching passed (rendered: \(renderer != nil)).")
}
