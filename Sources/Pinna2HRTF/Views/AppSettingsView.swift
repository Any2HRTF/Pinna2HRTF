import SwiftUI
import AppKit
import UserNotifications

struct AppSettingsView: View {
    @ObservedObject var store: AppStore
    @AppStorage(AppPreferences.projectDirectory) private var projectDirectory = ""
    @AppStorage(AppPreferences.inputHandling) private var inputHandling = InputHandling.copy.rawValue
    @AppStorage(AppPreferences.evaluationGrid) private var evaluationGrid = ""
    @AppStorage(AppPreferences.minimumFrequency) private var minimumFrequency = 0
    @AppStorage(AppPreferences.maximumFrequency) private var maximumFrequency = 24000
    @AppStorage(AppPreferences.frequencySteps) private var frequencySteps = 129
    @AppStorage(AppPreferences.maxInstances) private var maxInstances = 1
    @AppStorage(AppPreferences.maxCPULoad) private var maxCPULoad = 90
    @AppStorage(AppPreferences.notifyAll) private var notifyAll = true
    @AppStorage(AppPreferences.notifyCompletion) private var notifyCompletion = true
    @AppStorage(AppPreferences.notifyFailure) private var notifyFailure = true
    @AppStorage(AppPreferences.appearance) private var appearance = "system"
    @AppStorage(AppPreferences.developerMode) private var developerMode = false
    @AppStorage(AppPreferences.developerNumCalc) private var developerNumCalc = ""
    @AppStorage(AppPreferences.developerMeshGrading) private var developerMeshGrading = ""
    @State private var invalidGrid = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            projects.tabItem { Label("New Projects", systemImage: "folder.badge.plus") }
            computing.tabItem { Label("Computing", systemImage: "cpu") }
            notifications.tabItem { Label("Notifications", systemImage: "bell") }
            tools.tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
        }
        .padding(20)
        .frame(width: 620, height: 450)
        .onChange(of: developerMode) { _ in store.environmentPreferencesDidChange() }
        .onChange(of: developerNumCalc) { _ in store.environmentPreferencesDidChange() }
        .onChange(of: developerMeshGrading) { _ in store.environmentPreferencesDidChange() }
        .onChange(of: notifyAll) { enabled in
            if !enabled { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
        }
        .alert("Invalid evaluation grid", isPresented: $invalidGrid) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose a folder containing Nodes.txt and Elements.txt.")
        }
    }

    private var general: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
    }

    private var projects: some View {
        Form {
            Section {
                LabeledContent("Project location") {
                    HStack {
                        Text(projectDirectory.isEmpty ? "Application Support" : projectDirectory)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button("Choose…") { chooseDirectory(selection: $projectDirectory) }
                            .fixedSize()
                        if !projectDirectory.isEmpty {
                            Button("Reset") { projectDirectory = "" }
                                .fixedSize()
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                Picker("Input files", selection: $inputHandling) {
                    ForEach(InputHandling.allCases) { handling in
                        Text(handling.title).tag(handling.rawValue)
                    }
                }
                LabeledContent("Evaluation grid") {
                    HStack {
                        Text(evaluationGrid.isEmpty ? "ARI grid (91 directions)" : evaluationGrid)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button("Choose Grid…") { chooseGrid() }
                            .fixedSize()
                        if !evaluationGrid.isEmpty {
                            Button("Reset") { evaluationGrid = "" }
                                .fixedSize()
                        }
                    }
                }
            } header: {
                Text("New project defaults")
            }
            Section("Simulation defaults") {
                numberSetting("Minimum frequency", value: $minimumFrequency, range: 0...max(0, min(maximumFrequency - 1, 95999)), step: 100, unit: "Hz")
                numberSetting("Maximum frequency", value: $maximumFrequency, range: max(1, min(minimumFrequency + 1, 96000))...96000, step: 100, unit: "Hz")
                numberSetting("Frequency steps", value: $frequencySteps, range: 2...8193)
            }
        }
        .formStyle(.grouped)
    }

    private var computing: some View {
        Form {
            Section {
                numberSetting("Parallel NumCalc instances", value: $maxInstances, range: 1...1024)
                numberSetting("CPU load limit", value: $maxCPULoad, range: 1...100, unit: "%")
            } header: {
                Text("New project defaults")
            }
        }
        .formStyle(.grouped)
    }

    private var notifications: some View {
        Form {
            Section {
                Toggle("Allow notifications", isOn: $notifyAll)
                Toggle("When a stage completes", isOn: $notifyCompletion)
                    .disabled(!notifyAll)
                Toggle("When a stage fails", isOn: $notifyFailure)
                    .disabled(!notifyAll)
            }
        }
        .formStyle(.grouped)
    }

    private var tools: some View {
        Form {
            Section("Tools") {
                toolRow("NumCalc", path: store.environment.numcalcExecutable)
                toolRow("Mesh grading", path: store.environment.meshGradingExecutable)
                if !Defaults.isPackagedApp {
                    toolRow("uv", path: store.environment.uvExecutable)
                }
            }
            Section {
                Toggle("Developer mode", isOn: $developerMode)
                if developerMode {
                    executableSetting("NumCalc", path: $developerNumCalc, defaultPath: store.library.environment.numcalcExecutable)
                    executableSetting("Mesh grading", path: $developerMeshGrading, defaultPath: store.library.environment.meshGradingExecutable)
                    if !Defaults.isPackagedApp {
                        TextField("uv", text: environmentBinding(\.uvExecutable))
                        TextField("External dependencies", text: environmentBinding(\.externalDir))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func numberSetting(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, unit: String = "") -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                TextField(title, value: value, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onChange(of: value.wrappedValue) { newValue in
                        let bounded = min(max(newValue, range.lowerBound), range.upperBound)
                        if bounded != newValue { value.wrappedValue = bounded }
                    }
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }

    private func toolRow(_ title: String, path: String) -> some View {
        let ready = FileManager.default.isExecutableFile(atPath: path)
        return HStack {
            Label(title, systemImage: ready ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ready ? .green : .red)
            Spacer()
            Text(ready ? "Available" : "Missing")
                .foregroundStyle(.secondary)
        }
        .help(path)
    }

    private func executableSetting(_ title: String, path: Binding<String>, defaultPath: String) -> some View {
        LabeledContent(title) {
            HStack {
                TextField("", text: path, prompt: Text(defaultPath))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(title) path")
                    .help(defaultPath)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        path.wrappedValue = url.path
                    }
                }
                .fixedSize()
                if !path.wrappedValue.isEmpty {
                    Button("Reset") { path.wrappedValue = "" }
                        .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func environmentBinding(_ keyPath: WritableKeyPath<EnvironmentConfig, String>) -> Binding<String> {
        Binding {
            store.library.environment[keyPath: keyPath]
        } set: { value in
            store.library.environment[keyPath: keyPath] = value
            store.library.persist()
            store.refreshArtifacts()
        }
    }

    private func chooseDirectory(selection: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            selection.wrappedValue = url.path
        }
    }

    private func chooseGrid() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an evaluation grid folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ["Nodes.txt", "Elements.txt"].allSatisfy({
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }) else {
            invalidGrid = true
            return
        }
        evaluationGrid = url.path
    }
}
