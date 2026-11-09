import Foundation
import AppKit

enum WorkflowStep: Int, CaseIterable, Identifiable {
    case inputs, prepare, simulation, calculate, results
    var id: Int { rawValue }
    var title: String { ["Project", "Ear preparation & modelling", "Simulation setup", "Calculation", "SOFA export"][rawValue] }
    var stage: Stage? {
        switch self {
        case .inputs: nil
        case .prepare: .scanPreparation
        case .simulation: .preprocessing
        case .calculate: .numcalc
        case .results: .postprocessing
        }
    }
}

enum EarModelMethod: String, Codable, CaseIterable, Identifiable {
    case mesh2ppm, manual, none
    var id: String { rawValue }
    var title: String {
        switch self { case .mesh2ppm: "Mesh2PPM"; case .manual: "Manual PPM fitting"; case .none: "No PPM" }
    }
}

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

extension Stage {
    var workflowRunTitle: String {
        switch self {
        case .scanPreparation: "Run \(WorkflowStep.prepare.title)"
        case .inference: "Run Mesh2PPM"
        case .preprocessing: "Run \(WorkflowStep.simulation.title)"
        case .numcalc: "Run \(WorkflowStep.calculate.title)"
        case .postprocessing: "Run \(WorkflowStep.results.title)"
        }
    }
}

struct WorkflowAction {
    var title: String
    var step: WorkflowStep
    var stage: Stage? = nil
    var fit: EarSide? = nil
    var enabled = true
}

@MainActor
extension AppStore {
    var earModelMethod: EarModelMethod? { selectedProject?.workflowMethod }

    func selectEarModelMethod(_ method: EarModelMethod) {
        guard !selectedProjectIsRunning else { return }
        updateSelectedProject { $0.settings.selectEarModel(method) }
    }

    var workflowSides: [EarSide] { selectedProject?.includedEars ?? [] }

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
            return .init(title: Stage.scanPreparation.workflowRunTitle, step: .prepare, stage: .scanPreparation, enabled: canRun(stage: .scanPreparation))
        }
        if let issue = selectedValidationIssues.first(where: { $0.id.hasPrefix("ear_edit.") }) {
            return .init(title: issue.message, step: .prepare)
        }
        if earModelMethod == nil { return .init(title: "Choose one ear modelling method", step: .prepare) }
        if earModelMethod == .manual,
           let side = workflowSides.first(where: { !(selectedProjectStatus?.validFitSides.contains($0) ?? false) }) {
            return .init(title: "Fit \(side.rawValue) ear", step: .prepare, fit: side)
        }
        if let stage = nextStage {
            let step = stage == .inference ? WorkflowStep.prepare : WorkflowStep.allCases.first(where: { $0.stage == stage })
            if let step { return .init(title: stage.workflowRunTitle, step: step, stage: stage, enabled: canRun(stage: stage)) }
        }
        return .init(title: "Open results", step: .results)
    }

    func performWorkflowAction() {
        if let id = selectedProjectID, runningProcesses[id] != nil { stopRunningProcess(); return }
        guard !selectedProjectIsRunning else { return }
        let action = workflowNextAction
        workflowStep = action.step
        workflowRevealRequest = UUID()
        guard action.enabled else { return }
        if action.step == .results && action.stage == nil, let project = selectedProject {
            NSWorkspace.shared.open(ArtifactScanner.postprocessingDirectory(for: project))
        } else if let side = action.fit { beginManualPPMFitting(side) }
        else if let stage = action.stage, canRun(stage: stage) { run(stage: stage) }
    }

    func workflowSymbol(for state: String) -> String {
        if state == "Complete" { return "checkmark.circle" }
        if state == "Failed" || state == "Needs rerun" { return "exclamationmark.triangle" }
        if state.hasPrefix("Not needed") || state.hasPrefix("Optional") { return "minus.circle" }
        if state == "Ready" || state.hasPrefix("Running") { return "play.circle" }
        return "circle"
    }

    func workflowStatus(_ step: WorkflowStep) -> String {
        guard let project = selectedProject else { return "Needs input" }
        if step == .inputs { return workflowInputIssue == nil ? "Complete" : "Needs input" }
        if step == .prepare {
            if project.scanPreparation.enabled {
                let scanState = stageStates[.scanPreparation] ?? .ready
                if scanState == .running { return "Running…" }
                if scanState == .failed { return "Failed" }
                if scanState == .stopped { return "Stopped" }
                if !(selectedProjectStatus?.completed.contains(.scanPreparation) ?? false) {
                    return canRun(stage: .scanPreparation) ? "Ready" : "Needs input"
                }
            }
            if earModelMethod == nil { return "Choose method" }
            if earModelMethod == EarModelMethod.none { return project.scanPreparation.enabled ? "Complete" : "Optional" }
            if earModelMethod == .manual {
                let count = workflowSides.filter { selectedProjectStatus?.validFitSides.contains($0) ?? false }.count
                return !workflowSides.isEmpty && count == workflowSides.count ? "Complete" : "Needs fit · \(count)/\(workflowSides.count)"
            }
            let inferenceState = stageStates[.inference] ?? .ready
            if inferenceState == .running { return "Running…" }
            if inferenceState == .failed { return "Failed" }
            if inferenceState == .stopped { return "Stopped" }
            if selectedProjectStatus?.completed.contains(.inference) == true { return "Complete" }
            return canRun(stage: .inference) ? "Ready" : "Needs input"
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
