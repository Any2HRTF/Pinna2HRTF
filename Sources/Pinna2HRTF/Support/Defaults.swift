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

    static var pipelineRoot: URL {
        if let resourceURL = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent("HRTFCalculation").path) {
            return resourceURL
        }
        return packageRoot()
    }

    static var isPackagedApp: Bool {
        if let resourceURL = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent("HRTFCalculation").path) {
            return true
        }
        return false
    }

    static var runtimeRoot: URL {
        if let resourceURL = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent("HRTFCalculation").path) {
            return resourceURL
        }
        return worktreeRoot()
    }

    static var appDataURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Pinna2HRTF", isDirectory: true)
    }

    static var runtimeProjectURL: URL {
        appDataURL.appendingPathComponent("Runtime", isDirectory: true)
    }

    static func environment(root: URL) -> EnvironmentConfig {
        let pipeline = pipelineRoot
        let appSupportBin = appDataURL.appendingPathComponent("External/bin", isDirectory: true)
        return EnvironmentConfig(
            uvExecutable: executablePath(named: "uv", bundled: pipeline.appendingPathComponent("External/bin/uv"), install: appSupportBin.appendingPathComponent("uv")),
            numcalcExecutable: executablePath(named: "NumCalc", bundled: pipeline.appendingPathComponent("External/bin/NumCalc"), install: appSupportBin.appendingPathComponent("NumCalc")),
            meshGradingExecutable: executablePath(named: "hrtf_mesh_grading", bundled: pipeline.appendingPathComponent("External/bin/hrtf_mesh_grading"), install: appSupportBin.appendingPathComponent("hrtf_mesh_grading")),
            externalDir: externalDir(root: root, pipeline: pipeline).path
        )
    }

    static func externalDir(root: URL, pipeline: URL) -> URL {
        let bundled = pipeline.appendingPathComponent("External", isDirectory: true)
        if isPackagedApp {
            return bundled
        }
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let source = root.appendingPathComponent("External", isDirectory: true)
        if FileManager.default.fileExists(atPath: source.path) {
            return source
        }
        return appDataURL.appendingPathComponent("External", isDirectory: true)
    }

    static func executablePath(named name: String, bundled: URL, install: URL) -> String {
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        if let path = which(name) {
            return path
        }
        if FileManager.default.isExecutableFile(atPath: install.path) {
            return install.path
        }
        return bundled.path
    }

    static func which(_ name: String) -> String? {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for path in paths {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
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
