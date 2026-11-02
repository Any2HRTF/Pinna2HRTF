import SceneKit

/// Symmetric illumination in world space keeps both ears equally lit from all sides.
enum EvenMeshLighting {
    static func install(in scene: SCNScene, camera: SCNNode) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 300
        let fill = SCNNode()
        fill.light = ambient
        scene.rootNode.addChildNode(fill)

        let rotations: [SCNVector3] = [
            SCNVector3(0, 0, 0), SCNVector3(0, Float.pi, 0),
            SCNVector3(0, Float.pi / 2, 0), SCNVector3(0, -Float.pi / 2, 0),
            SCNVector3(Float.pi / 2, 0, 0), SCNVector3(-Float.pi / 2, 0, 0)
        ]
        for rotation in rotations {
            let light = SCNLight()
            light.type = .directional
            light.intensity = 110
            light.castsShadow = false
            let node = SCNNode()
            node.light = light
            node.eulerAngles = rotation
            scene.rootNode.addChildNode(node)
        }
        // A soft, angled light follows the view, revealing surface contours
        // without making one side of the model permanently darker.
        let key = SCNLight()
        key.type = .directional
        key.intensity = 500
        key.castsShadow = false
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.45, -0.5, 0)
        camera.addChildNode(keyNode)
    }
}
