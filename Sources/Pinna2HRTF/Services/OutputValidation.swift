import Foundation

enum OutputValidation {
    static func validate(stage: Stage, project: ProjectRecord) throws {
        guard ArtifactScanner.stageIsComplete(stage, project: project, validateReceipt: false) else {
            throw ProjectValidation.Failure(message: "The task exited successfully, but its expected output files are missing, empty, or incomplete.")
        }
        if stage == .scanPreparation {
            let config = URL(fileURLWithPath: project.saveLocation).appendingPathComponent("Project Settings.yaml")
            _ = try ProjectConfigDocument.request("validate-prepared", ["path": config.path])
        }
        if stage == .numcalc {
            let root = URL(fileURLWithPath: project.saveLocation)
            for (side, input) in [("Left", project.pipelineLeftEar), ("Right", project.pipelineRightEar)] where !input.isEmpty {
                guard ArtifactScanner.numcalcIsComplete(root.appendingPathComponent("Projects/\(side)")) else {
                    throw ProjectValidation.Failure(message: "NumCalc exited, but \(side.lowercased())-ear frequency results are incomplete. Previous SOFA files do not validate the new run.")
                }
            }
        }
        guard stage == .postprocessing else { return }
        let folder = ArtifactScanner.postprocessingDirectory(for: project)
        let root = URL(fileURLWithPath: project.saveLocation)
        let ears = [("Left", project.pipelineLeftEar), ("Right", project.pipelineRightEar)].filter { !$0.1.isEmpty }
        let sourceNames = try ears.map { side, _ -> Set<String> in
            let source = root.appendingPathComponent("Projects/\(side)/Output2HRTF")
            return Set(try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "sofa" }.map(\.lastPathComponent))
        }
        guard let names = sourceNames.first, !names.isEmpty, sourceNames.allSatisfy({ $0 == names }) else {
            throw ProjectValidation.Failure(message: "Postprocessing is missing matching SOFA results for the selected ears.")
        }
        let expected = ears.count == 2 ? names.map { String($0.dropLast(5)) + "_merged.sofa" } : Array(names)
        guard expected.allSatisfy({ ArtifactScanner.isSOFAContainer(folder.appendingPathComponent($0)) }) else {
            throw ProjectValidation.Failure(message: "Postprocessing did not produce all expected HRTF and HRIR files.")
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "sofa" }
        _ = try ProjectConfigDocument.request("validate_outputs", ["paths": files.map(\.path)])
    }
}
