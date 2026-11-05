import Foundation
import AppKit

enum WorkflowStep: Int, CaseIterable, Identifiable {
    case inputs, prepare, model, simulation, calculate, results
    var id: Int { rawValue }
    var title: String { ["Inputs", "Prepare ears", "Ear model", "Simulation setup", "Calculate", "Results"][rawValue] }
    var stage: Stage? {
        switch self {
        case .inputs: nil
        case .prepare: .scanPreparation
        case .model: .inference
        case .simulation: .preprocessing
        case .calculate: .numcalc
        case .results: .postprocessing
        }
    }
}

<<<<<<< Updated upstream
enum EarModelMethod: String, Codable, CaseIterable, Identifiable {
=======
enum EarModelMethod: String, CaseIterable, Identifiable {
>>>>>>> Stashed changes
    case mesh2ppm, manual, none
    var id: String { rawValue }
    var title: String {
        switch self { case .mesh2ppm: "Mesh2PPM"; case .manual: "Manual PPM fitting"; case .none: "No PPM" }
    }
}

<<<<<<< Updated upstream
extension ProjectSettings {
    mutating func selectEarModel(_ method: EarModelMethod) {
        manualPPMFitting.selectedMethod = method
        inference.usePredictionsForPreprocessing = method == .mesh2ppm
        manualPPMFitting.useForPreprocessing = method == .manual
    }
}

extension ProjectRecord {
    var includedEars: [EarSide] {
        EarSide.allCases.filter { side in
            scanPreparation.enabled ? (side == .left ? scanPreparation.prepareLeft : scanPreparation.prepareRight)
                : !(side == .left ? leftEar : rightEar).isEmpty
        }
    }

    var workflowMethod: EarModelMethod? {
        let manual = settings.manualPPMFitting
        if let method = manual.selectedMethod { return method }
        if !manual.useForPreprocessing { return settings.inference.usePredictionsForPreprocessing ? .mesh2ppm : EarModelMethod.none }
        if settings.inference.usePredictionsForPreprocessing || includedEars.contains(where: { manual.meshPath(for: $0) == nil }) { return nil }
        return .manual
    }
}

=======
>>>>>>> Stashed changes
struct WorkflowAction {
    var title: String
    var step: WorkflowStep
    var stage: Stage? = nil
    var fit: EarSide? = nil
    var enabled = true
}

@MainActor
extension AppStore {
<<<<<<< Updated upstream
    var earModelMethod: EarModelMethod? { selectedProject?.workflowMethod }

    func selectEarModelMethod(_ method: EarModelMethod) {
        guard !selectedProjectIsRunning else { return }
        updateSelectedProject { $0.settings.selectEarModel(method) }
    }

    var workflowSides: [EarSide] { selectedProject?.includedEars ?? [] }
=======
    var earModelMethod: EarModelMethod? {
        guard let p = selectedProject else { return nil }
        let automatic = p.settings.inference.usePredictionsForPreprocessing
        let manual = p.settings.manualPPMFitting.useForPreprocessing
        return automatic && manual ? nil : manual ? .manual : automatic ? .mesh2ppm : EarModelMethod.none
    }

    func selectEarModelMethod(_ method: EarModelMethod) {
        guard !selectedProjectIsRunning else { return }
        updateSelectedProject {
            $0.settings.inference.usePredictionsForPreprocessing = method == .mesh2ppm
            $0.settings.manualPPMFitting.useForPreprocessing = method == .manual
        }
    }

    var workflowSides: [EarSide] {
        guard let p = selectedProject else { return [] }
        return EarSide.allCases.filter { side in
            p.scanPreparation.enabled ? (side == .left ? p.scanPreparation.prepareLeft : p.scanPreparation.prepareRight) :
                !(side == .left ? p.leftEar : p.rightEar).isEmpty
        }
    }
>>>>>>> Stashed changes

    var workflowInputIssue: String? {
        guard let p = selectedProject else { return "Create or select a project" }
        if p.saveLocation.isEmpty { return "Choose save location" }
        if p.scanPreparation.enabled {
            if p.scanPreparation.scanPath.isEmpty { return "Choose full-head scan" }
            if !FileManager.default.fileExists(atPath: p.scanPreparation.scanPath) { return "Locate missing head scan" }
        }
        if workflowSides.isEmpty { return p.scanPreparation.enabled ? "Select ears to prepare" : "Choose an ear mesh" }
        if !p.scanPreparation.enabled {
            for side in workflowSides where !FileManager.default.fileExists(atPath: side == .left ? p.leftEar : p.rightEar) {
                return "Locate missing \(side.rawValue) ear"
            }
        }
        return nil
    }

    var workflowNextAction: WorkflowAction {
        if let issue = workflowInputIssue { return .init(title: issue, step: .inputs) }
        if isPlacingMicrophone { return .init(title: "Finish microphone placement", step: .simulation) }
        if isCheckingProjectFiles { return .init(title: "Checking project files…", step: workflowStep, enabled: false) }
        if let p = selectedProject, p.scanPreparation.enabled,
           !(selectedProjectStatus?.completed.contains(.scanPreparation) ?? false) {
            return .init(title: "Prepare ears", step: .prepare, stage: .scanPreparation)
        }
        if let issue = selectedValidationIssues.first(where: { $0.id.hasPrefix("ear_edit.") }) {
            return .init(title: issue.message, step: .prepare)
        }
        if earModelMethod == nil { return .init(title: "Choose one ear modelling method", step: .model) }
        if earModelMethod == .manual,
           let side = workflowSides.first(where: { !(selectedProjectStatus?.validFitSides.contains($0) ?? false) }) {
            return .init(title: "Fit \(side.rawValue) ear", step: .model, fit: side)
        }
        if let stage = nextStage, let step = WorkflowStep.allCases.first(where: { $0.stage == stage }) {
            return .init(title: "Run \(stage.title)", step: step, stage: stage)
        }
        return .init(title: "Open results", step: .results)
    }

    func performWorkflowAction() {
<<<<<<< Updated upstream
        if let id = selectedProjectID, runningProcesses[id] != nil { stopRunningProcess(); return }
        guard !selectedProjectIsRunning else { return }
=======
        if selectedProjectIsRunning { stopRunningProcess(); return }
>>>>>>> Stashed changes
        let action = workflowNextAction
        workflowStep = action.step
        workflowRevealRequest = UUID()
        guard action.enabled else { return }
<<<<<<< Updated upstream
        if action.step == .results && action.stage == nil, let project = selectedProject {
            NSWorkspace.shared.open(ArtifactScanner.postprocessingDirectory(for: project))
        } else if let side = action.fit { beginManualPPMFitting(side) }
        else if let stage = action.stage, canRun(stage: stage) { run(stage: stage) }
    }

    func workflowSymbol(_ step: WorkflowStep) -> String {
        let state = workflowStatus(step)
        if state == "Complete" { return "checkmark.circle" }
        if state == "Failed" || state == "Needs rerun" { return "exclamationmark.triangle" }
        if state.hasPrefix("Not needed") || state.hasPrefix("Optional") { return "minus.circle" }
        if state == "Ready" || state.hasPrefix("Running") { return "play.circle" }
        return "circle"
    }

    func workflowStatus(_ step: WorkflowStep) -> String {
        guard let project = selectedProject else { return "Needs input" }
        if step == .inputs { return workflowInputIssue == nil ? "Complete" : "Needs input" }
        if step == .prepare && !project.scanPreparation.enabled { return "Optional" }
        if step == .model {
            if earModelMethod == nil { return "Choose method" }
            if earModelMethod == EarModelMethod.none { return "Not needed" }
=======
        if let side = action.fit { beginManualPPMFitting(side) }
        else if let stage = action.stage, canRun(stage: stage) { run(stage: stage) }
    }

    func workflowStatus(_ step: WorkflowStep) -> String {
        guard let project = selectedProject else { return "Needs input" }
        if step == .inputs { return workflowInputIssue == nil ? "Complete" : "Needs input" }
        if step == .prepare && !project.scanPreparation.enabled { return "Optional inspection / editing" }
        if step == .model {
            if earModelMethod == nil { return "Choose method" }
            if earModelMethod == EarModelMethod.none { return "Not needed · direct meshes" }
>>>>>>> Stashed changes
            if earModelMethod == .manual {
                let count = workflowSides.filter { selectedProjectStatus?.validFitSides.contains($0) ?? false }.count
                return !workflowSides.isEmpty && count == workflowSides.count ? "Complete" : "Needs fit · \(count)/\(workflowSides.count)"
            }
        }
        guard let stage = step.stage else { return "Ready" }
        let state = stageStates[stage] ?? .ready
        if state == .running { return "Running…" }
        if state == .failed { return "Failed" }
        if state == .stopped { return "Stopped" }
        if step.rawValue >= WorkflowStep.simulation.rawValue && preprocessingNeedsRerun(for: project) { return "Needs rerun" }
        if selectedProjectStatus?.completed.contains(stage) ?? false { return "Complete" }
        return canRun(stage: stage) ? "Ready" : "Needs input"
    }
}
