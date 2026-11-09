import SwiftUI
import AppKit
import UserNotifications

struct AppSettingsView: View {
    private enum Pane: Hashable, CaseIterable {
        case general, projects, computing, notifications, tools

        var title: String {
            switch self {
            case .general: "General"
            case .projects: "New Projects"
            case .computing: "Computing"
            case .notifications: "Notifications"
            case .tools: "Tools"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .projects: "folder.badge.plus"
            case .computing: "cpu"
            case .notifications: "bell.badge"
            case .tools: "wrench.and.screwdriver"
            }
        }

        /// Used only until the pane has been laid out once.
        var estimatedHeight: CGFloat {
            switch self {
            case .general: 80
            case .projects: 250
            case .computing: 140
            case .notifications: 130
            case .tools: 220
            }
        }
    }

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
    @AppStorage(AppPreferences.developerUV) private var developerUV = ""
    @AppStorage(AppPreferences.developerPython) private var developerPython = ""
    @AppStorage(AppPreferences.developerExternalDir) private var developerExternalDir = ""
    @State private var invalidGrid = false
    @State private var selectedPane: Pane = .general
    @State private var paneHeights: [Pane: CGFloat] = [:]

    private static let paneWidth: CGFloat = 640

    var body: some View {
        TabView(selection: $selectedPane) {
            ForEach(Pane.allCases, id: \.self) { pane in
                paneContent(pane)
                    .fixedSize()
                    .padding(.horizontal, 40)
                    .padding(.top, 22)
                    .padding(.bottom, 26)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeights[pane] = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .tabItem { Label(pane.title, systemImage: pane.symbol) }
                    .tag(pane)
            }
        }
        .frame(width: Self.paneWidth, height: paneHeights[selectedPane] ?? selectedPane.estimatedHeight)
        .animation(.easeInOut(duration: 0.2), value: selectedPane)
        .animation(.easeInOut(duration: 0.2), value: developerMode)
        .onChange(of: developerMode) { _ in store.environmentPreferencesDidChange() }
        .onChange(of: developerNumCalc) { _ in store.environmentPreferencesDidChange() }
        .onChange(of: developerMeshGrading) { _ in store.environmentPreferencesDidChange() }
        .onChange(of: developerUV) { _ in store.environmentPreferencesDidChange() }
        .onChange(of: developerPython) { _ in store.environmentPreferencesDidChange() }
        .onChange(of: developerExternalDir) { _ in store.environmentPreferencesDidChange() }
        .onChange(of: notifyAll) { enabled in
            if !enabled { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
        }
        .alert("Invalid evaluation grid", isPresented: $invalidGrid) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose a folder containing Nodes.txt and Elements.txt.")
        }
    }

    @ViewBuilder private func paneContent(_ pane: Pane) -> some View {
        switch pane {
        case .general: general
        case .projects: projects
        case .computing: computing
        case .notifications: notifications
        case .tools: tools
        }
    }

    private var general: some View {
        Form {
            Picker("Appearance:", selection: $appearance) {
                Text("Match System").tag("system")
                Divider()
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
        }
    }

    private var projects: some View {
        Form {
            Section {
                locationPicker("Project location:", path: $projectDirectory,
                               defaultTitle: "Application Support", choose: { chooseDirectory(selection: $projectDirectory) })
                Picker("Input files:", selection: $inputHandling) {
                    ForEach(InputHandling.allCases) { handling in
                        Text(handling.title).tag(handling.rawValue)
                    }
                }
                locationPicker("Evaluation grid:", path: $evaluationGrid,
                               defaultTitle: "ARI Grid (91 directions)", choose: chooseGrid)
            }
            Section {
                LabeledContent("Frequency range:") {
                    HStack(spacing: 6) {
                        numberField("Minimum frequency", value: $minimumFrequency, range: 0...max(0, min(maximumFrequency - 1, 95999)), step: 100)
                        Text("to")
                        numberField("Maximum frequency", value: $maximumFrequency, range: max(1, min(minimumFrequency + 1, 96000))...96000, step: 100)
                        Text("Hz")
                    }
                }
                LabeledContent("Frequency steps:") {
                    numberField("Frequency steps", value: $frequencySteps, range: 2...8193)
                }
                caption("Applies to new projects only.")
            }
        }
    }

    private var computing: some View {
        Form {
            LabeledContent("Parallel NumCalc instances:") {
                numberField("Parallel NumCalc instances", value: $maxInstances, range: 1...1024)
            }
            LabeledContent("CPU load limit:") {
                HStack(spacing: 6) {
                    numberField("CPU load limit", value: $maxCPULoad, range: 1...100)
                    Text("%")
                }
            }
            caption("Applies to new projects only.")
        }
    }

    private var notifications: some View {
        Form {
            Toggle("Allow notifications", isOn: $notifyAll)
            LabeledContent("Notify me:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("When a stage completes", isOn: $notifyCompletion)
                    Toggle("When a stage fails", isOn: $notifyFailure)
                }
                .disabled(!notifyAll)
            }
            .padding(.top, 4)
        }
    }

    private var tools: some View {
        Form {
            Section {
                toolRow("NumCalc:", path: store.environment.numcalcExecutable)
                toolRow("Mesh grading:", path: store.environment.meshGradingExecutable)
                toolRow("Python:", path: store.environment.pythonExecutable ?? ProcessLauncher.runtimePythonURL.path)
                if !Defaults.isPackagedApp || developerMode {
                    toolRow("uv (development):", path: store.environment.uvExecutable)
                }
                toolRow("Mesh2HRTF:", path: URL(fileURLWithPath: store.environment.externalDir).appendingPathComponent("src/Mesh2HRTF/mesh2hrtf").path, directory: true)
            }
            Section {
                Toggle("Developer mode", isOn: $developerMode)
                    .padding(.top, 6)
                if developerMode {
                    pathSetting("NumCalc:", path: $developerNumCalc, defaultPath: store.library.environment.numcalcExecutable)
                    pathSetting("Mesh grading:", path: $developerMeshGrading, defaultPath: store.library.environment.meshGradingExecutable)
                    pathSetting("Python:", path: $developerPython, defaultPath: ProcessLauncher.runtimePythonURL.path)
                    pathSetting("uv:", path: $developerUV, defaultPath: store.library.environment.uvExecutable)
                    pathSetting("External dependencies:", path: $developerExternalDir, defaultPath: store.library.environment.externalDir, directory: true)
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Safari-style location pop-up: the default, the chosen folder, and "Other…".
    private func locationPicker(_ title: String, path: Binding<String>, defaultTitle: String, choose: @escaping () -> Void) -> some View {
        let selection = Binding<String>(
            get: { path.wrappedValue.isEmpty ? "default" : "custom" },
            set: { choice in
                if choice == "default" { path.wrappedValue = "" }
                if choice == "other" { DispatchQueue.main.async(execute: choose) }
            })
        return Picker(title, selection: selection) {
            Text(defaultTitle).tag("default")
            if !path.wrappedValue.isEmpty {
                Label {
                    Text(FileManager.default.displayName(atPath: path.wrappedValue))
                } icon: {
                    Image(nsImage: Self.menuIcon(forPath: path.wrappedValue))
                }
                .labelStyle(.titleAndIcon)
                .tag("custom")
            }
            Divider()
            Text("Other…").tag("other")
        }
        .help(path.wrappedValue.isEmpty ? defaultTitle : path.wrappedValue)
    }

    private static func menuIcon(forPath path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    private func numberField(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1) -> some View {
        HStack(spacing: 4) {
            TextField(title, value: value, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .onChange(of: value.wrappedValue) { newValue in
                    let bounded = min(max(newValue, range.lowerBound), range.upperBound)
                    if bounded != newValue { value.wrappedValue = bounded }
                }
            Stepper(title, value: value, in: range, step: step)
                .labelsHidden()
        }
    }

    private func toolRow(_ title: String, path: String, directory: Bool = false) -> some View {
        var isDirectory: ObjCBool = false
        let ready = directory
            ? FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            : FileManager.default.isExecutableFile(atPath: path)
        return LabeledContent(title) {
            HStack(spacing: 5) {
                Image(systemName: ready ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ready ? .green : .red)
                Text(ready ? "Available" : "Missing")
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, 2)
        .help(path)
    }

    private func pathSetting(_ title: String, path: Binding<String>, defaultPath: String, directory: Bool = false) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", text: path, prompt: Text(defaultPath))
                    .labelsHidden()
                    .frame(width: 230)
                    .accessibilityLabel("\(title) path")
                    .help(defaultPath)
                Button("Choose…") {
                    if directory {
                        chooseDirectory(selection: path)
                    } else {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            path.wrappedValue = url.path
                        }
                    }
                }
                Button("Reset") { path.wrappedValue = "" }
                    .disabled(path.wrappedValue.isEmpty)
            }
        }
        .accessibilityElement(children: .contain)
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
