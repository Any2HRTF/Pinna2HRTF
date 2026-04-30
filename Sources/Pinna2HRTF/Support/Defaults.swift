import Foundation

enum Defaults {
    static func packageRoot(from filePath: String = #filePath) -> URL {
        let start = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        var current = start
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return start
    }

    static func worktreeRoot(from filePath: String = #filePath) -> URL {
        packageRoot(from: filePath).deletingLastPathComponent()
    }

    static var appDataURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Pinna2HRTF", isDirectory: true)
    }

    static func environment(root: URL) -> EnvironmentConfig {
        EnvironmentConfig(
            uvExecutable: root.appendingPathComponent("External/bin/uv").path,
            numcalcExecutable: root.appendingPathComponent("External/bin/NumCalc").path,
            meshGradingExecutable: root.appendingPathComponent("External/bin/hrtf_mesh_grading").path,
            externalDir: root.appendingPathComponent("External").path
        )
    }

    static func settings(packageRoot: URL) -> ProjectSettings {
        ProjectSettings(
            inference: InferenceSettings(
                modelConfig: packageRoot.appendingPathComponent("HRTFCalculation/Inference/resources/Local 9 Views.yaml").path,
                modelCheckpoint: packageRoot.appendingPathComponent("HRTFCalculation/Inference/resources/Local 9 Views.pth").path
            )
        )
    }

    static func sampleProject(root: URL, packageRoot: URL, index: Int) -> ProjectRecord {
        ProjectRecord(
            name: "Project \(index)",
            leftEar: root.appendingPathComponent("Paper/Data/03 Automatic Stitching/Input/Target STL Left/NH130.stl").path,
            rightEar: root.appendingPathComponent("Paper/Data/03 Automatic Stitching/Input/Target STL Right/NH130.stl").path,
            saveLocation: appDataURL.appendingPathComponent("Projects/Project \(index)").path,
            settings: settings(packageRoot: packageRoot)
        )
    }
}
