import Foundation

func projectDuplicationChecks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("pinna-duplicate-check-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("Original Project", isDirectory: true)
    let manual = source.appendingPathComponent("Manual PPM", isDirectory: true)
    try fm.createDirectory(at: manual, withIntermediateDirectories: true)
    let input = source.appendingPathComponent("ear.stl")
    try Data("unchanged input".utf8).write(to: input)
    let mesh = manual.appendingPathComponent("Left.stl")
    try Data("saved mesh".utf8).write(to: mesh)
    let blend = manual.appendingPathComponent("PPM.blend")
    try Data("saved template".utf8).write(to: blend)
    let params = manual.appendingPathComponent("Left.json")
    let parameters: [String: Any] = ["template_blend": blend.path, "parameters": ["example": 0.5]]
    try JSONSerialization.data(withJSONObject: parameters).write(to: params)
    var project = Defaults.newProject(packageRoot: Defaults.packageRoot(), index: 1)
    project.name = "Original Project"
    project.saveLocation = source.path
    project.leftEar = input.path
    project.rightEar = root.appendingPathComponent("external.stl").path
    project.stageOutcomes = ["preprocessing": .done]
    project.settings.preprocessing.sourcePositionInputLeft = ManualMicrophonePosition(x: 1, y: 2, z: 3, meshPath: input.path, meshIdentity: ArtifactScanner.meshIdentity(input)!)
    project.settings.manualPPMFitting.setFit(meshPath: mesh.path, parametersPath: params.path,
        blendPath: blend.path, sourcePath: input.path, sourceIdentity: ArtifactScanner.meshIdentity(input)!, for: .left)
    project.settings.manualPPMFitting.templateBlendPath = blend.path
    project.settings.manualPPMFitting.useForPreprocessing = true
    let metadata: [String: Any] = ["paths": ["output_dir": source.path, "left_ear": input.path],
        "manual_ppm": ["left_parameters": params.path], "preprocessing": ["title": project.name]]
    project.preservedConfigJSON = String(decoding: try JSONSerialization.data(withJSONObject: metadata), as: UTF8.self)
    let yamlURL = source.appendingPathComponent("Project Settings.yaml")
    try ProjectConfigDocument.encode(metadata).write(to: yamlURL, atomically: true, encoding: .utf8)
    let originalYAML = try Data(contentsOf: yamlURL)
    let parent = root.appendingPathComponent("new parent/missing child", isDirectory: true)
    let copy = try ProjectDuplicator.duplicate(project, name: "  My copy  ", parentFolder: parent.path,
                                                projectRoots: [source.path])
    let destination = parent.appendingPathComponent("My copy")
    precondition(copy.id != project.id && copy.name == "My copy" && copy.saveLocation == destination.path)
    precondition(copy.stageOutcomes == nil && copy.settings.preprocessing.sourcePositionInputLeft == nil)
    precondition(copy.leftEar == destination.appendingPathComponent("ear.stl").path)
    precondition(copy.rightEar == project.rightEar)
    precondition(ArtifactScanner.validManualPPMFittingMesh(for: copy, side: .left) != nil)
    precondition(copy.settings.manualPPMFitting.leftBlendPath == destination.appendingPathComponent("Manual PPM/PPM.blend").path)
    let updatedParams = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("Manual PPM/Left.json"))) as! [String: Any]
    precondition(updatedParams["template_blend"] as? String == destination.appendingPathComponent("Manual PPM/PPM.blend").path)
    precondition((updatedParams["parameters"] as? [String: Double])?["example"] == 0.5)
    let copiedYAML = try ProjectConfigDocument.parse(String(contentsOf: destination.appendingPathComponent("Project Settings.yaml"), encoding: .utf8))
    precondition((copiedYAML["paths"] as? [String: String])?["output_dir"] == destination.path)
    precondition((copiedYAML["preprocessing"] as? [String: String])?["title"] == copy.name)
    precondition(!copy.preservedConfigJSON!.contains(source.path.replacingOccurrences(of: "/", with: "\\/")))
    let originalAfter = try Data(contentsOf: yamlURL)
    precondition(originalAfter == originalYAML)
    let copiedInput = try Data(contentsOf: URL(fileURLWithPath: copy.leftEar))
    let originalInput = try Data(contentsOf: input)
    precondition(copiedInput == originalInput)

    func rejects(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Unsafe duplicate was accepted") } catch {}
    }
    rejects { _ = try ProjectDuplicator.duplicate(project, name: "My copy", parentFolder: parent.path, projectRoots: [source.path]) }
    rejects { _ = try ProjectDuplicator.duplicate(project, name: "Nested", parentFolder: source.path, projectRoots: [source.path]) }
    rejects { _ = try ProjectDuplicator.destination(name: "../escape", parentFolder: parent.path) }
    rejects { _ = try ProjectDuplicator.destination(name: "Copy", parentFolder: "relative/path") }
    let alias = root.appendingPathComponent("alias")
    try fm.createSymbolicLink(at: alias, withDestinationURL: source)
    rejects { _ = try ProjectDuplicator.duplicate(project, name: "Nested", parentFolder: alias.path, projectRoots: [source.path]) }
    let parentAlias = URL(fileURLWithPath: "/private/tmp/pinna-dup-alias-\(UUID())")
    try fm.createSymbolicLink(at: parentAlias, withDestinationURL: root)
    defer { try? fm.removeItem(at: parentAlias) }
    let aliasCopy = try ProjectDuplicator.duplicate(project, name: "Alias copy", parentFolder: parentAlias.appendingPathComponent("new child").path, projectRoots: [source.path])
    precondition(ArtifactScanner.validManualPPMFittingMesh(for: aliasCopy, side: .left) != nil)
    let aliasIdentity = ArtifactScanner.meshIdentity(URL(fileURLWithPath: aliasCopy.leftEar))
    precondition(aliasCopy.settings.manualPPMFitting.leftSourceIdentity == aliasIdentity)
    var missing = project
    missing.saveLocation = root.appendingPathComponent("gone").path
    rejects { _ = try ProjectDuplicator.duplicate(missing, name: "Missing source", parentFolder: root.path, projectRoots: [source.path]) }
    var empty = Defaults.newProject(packageRoot: Defaults.packageRoot(), index: 2)
    empty.saveLocation = root.appendingPathComponent("Unsaved original").path
    let emptyCopy = try ProjectDuplicator.duplicate(empty, name: "Empty copy", parentFolder: root.path, projectRoots: [source.path])
    precondition(fm.fileExists(atPath: emptyCopy.saveLocation))
    precondition(!fm.fileExists(atPath: empty.saveLocation))
    try "broken: [".write(to: source.appendingPathComponent("broken.yaml"), atomically: true, encoding: .utf8)
    rejects { _ = try ProjectDuplicator.duplicate(project, name: "Failed copy", parentFolder: root.path, projectRoots: [source.path]) }
    precondition(!fm.fileExists(atPath: root.appendingPathComponent("Failed copy").path))
    let remaining = try fm.contentsOfDirectory(atPath: root.path)
    precondition(remaining.allSatisfy { !$0.hasPrefix(".pinna-duplicate-") })
    print("Project duplication: missing folders, saved-fit relocation, source preservation, collisions, symlink containment and failure cleanup passed.")
}
