import SwiftUI
import AppKit
import UserNotifications

struct AppSettingsView: View {
    enum Pane: Hashable, CaseIterable {
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
    }

    static let paneWidth: CGFloat = 540

    @ObservedObject var store: AppStore
    @AppStorage(AppPreferences.developerMode) private var developerMode = false
    @AppStorage(AppPreferences.developerNumCalc) private var developerNumCalc = ""
    @AppStorage(AppPreferences.developerMeshGrading) private var developerMeshGrading = ""
    @AppStorage(AppPreferences.developerUV) private var developerUV = ""
    @AppStorage(AppPreferences.developerPython) private var developerPython = ""
    @AppStorage(AppPreferences.developerExternalDir) private var developerExternalDir = ""
    @AppStorage(AppPreferences.notifyAll) private var notifyAll = true
    @State private var selectedPane: Pane = .general
    @State private var paneHeights: [Pane: CGFloat] = [:]

    var body: some View {
        // The window gets an explicit height from the measured pane. Letting the TabView size itself
        // from the form's ideal height makes AppKit loop on constraint updates while the window resizes.
        TabView(selection: $selectedPane) {
            ForEach(Pane.allCases, id: \.self) { pane in
                ScrollView(.vertical) {
                    SettingsPaneView(pane: pane, store: store)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeights[pane] = $0 }
                }
                .tabItem { Label(pane.title, systemImage: pane.symbol) }
                .tag(pane)
            }
        }
        .frame(width: Self.paneWidth,
               height: min(paneHeights[selectedPane] ?? 200, max(160, (NSScreen.main?.visibleFrame.height ?? 820) - 120)))
        .onChange(of: developerMode) { _ in store.environmentPreferencesDidChange() }
        .onChange(of: developerNumCalc) { _ in store.environmentPreferencesDidChange() }
        .onChange(of: developerMeshGrading) { _ in store.environmentPreferencesDidChange() }
        .onChange(of: developerUV) { _ in store.environmentPreferencesDidChange() }
        .onChange(of: developerPython) { _ in store.environmentPreferencesDidChange() }
        .onChange(of: developerExternalDir) { _ in store.environmentPreferencesDidChange() }
        .onChange(of: notifyAll) { enabled in
            if !enabled { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
        }
    }
}

/// One Settings tab, laid out as a System Settings–style grouped form that sizes the window to its content.
struct SettingsPaneView: View {
    let pane: AppSettingsView.Pane
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

    var body: some View {
        Form {
            switch pane {
            case .general: general
            case .projects: projects
            case .computing: computing
            case .notifications: notifications
            case .tools: tools
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: AppSettingsView.paneWidth)
        .animation(.default, value: developerMode)
        .alert("Invalid evaluation grid", isPresented: $invalidGrid) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose a folder containing Nodes.txt and Elements.txt.")
        }
    }

    // MARK: Panes

    @ViewBuilder private var general: some View {
        Section {
            Picker("Appearance", selection: $appearance) {
                Text("Match System").tag("system")
                Divider()
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
        }
    }

    @ViewBuilder private var projects: some View {
        Section {
            locationPicker("Location", path: $projectDirectory,
                           defaultTitle: "Application Support", choose: { chooseDirectory(selection: $projectDirectory) })
            Picker("Input files", selection: $inputHandling) {
                ForEach(InputHandling.allCases) { handling in
                    Text(handling.title).tag(handling.rawValue)
                }
            }
        } header: {
            Text("Project Files")
        }
        Section {
            locationPicker("Evaluation grid", path: $evaluationGrid,
                           defaultTitle: "ARI Grid (91 directions)", choose: chooseGrid)
            LabeledContent("Lowest frequency") {
                numberField("Lowest frequency", value: $minimumFrequency,
                            range: 0...max(0, min(maximumFrequency - 1, 95999)), step: 100, unit: "Hz")
            }
            LabeledContent("Highest frequency") {
                numberField("Highest frequency", value: $maximumFrequency,
                            range: max(1, min(minimumFrequency + 1, 96000))...96000, step: 100, unit: "Hz")
            }
            LabeledContent("Frequency steps") {
                numberField("Frequency steps", value: $frequencySteps, range: 2...8193)
            }
        } header: {
            Text("Simulation Defaults")
        } footer: {
            footer("Applies to new projects only.")
        }
    }

    @ViewBuilder private var computing: some View {
        Section {
            LabeledContent("Parallel NumCalc instances") {
                numberField("Parallel NumCalc instances", value: $maxInstances, range: 1...1024)
            }
            LabeledContent("CPU load limit") {
                numberField("CPU load limit", value: $maxCPULoad, range: 1...100, unit: "%")
            }
        } footer: {
            footer("Applies to new projects only.")
        }
    }

    @ViewBuilder private var notifications: some View {
        Section {
            Toggle("Allow notifications", isOn: $notifyAll)
        }
        Section("Notify Me When") {
            Toggle("A stage completes", isOn: $notifyCompletion)
            Toggle("A stage fails", isOn: $notifyFailure)
        }
        .disabled(!notifyAll)
    }

    @ViewBuilder private var tools: some View {
        Section {
            toolStatus("NumCalc", path: store.environment.numcalcExecutable)
            toolStatus("Mesh grading", path: store.environment.meshGradingExecutable)
            toolStatus("Python", path: store.environment.pythonExecutable ?? ProcessLauncher.runtimePythonURL.path)
            if !Defaults.isPackagedApp || developerMode {
                toolStatus("uv", path: store.environment.uvExecutable)
            }
            toolStatus("Mesh2HRTF", path: URL(fileURLWithPath: store.environment.externalDir)
                .appendingPathComponent("src/Mesh2HRTF/mesh2hrtf").path, directory: true)
        } header: {
            Text("Components")
        }
        Section {
            Toggle("Developer mode", isOn: $developerMode)
            if developerMode {
                pathSetting("NumCalc", path: $developerNumCalc, defaultPath: store.library.environment.numcalcExecutable)
                pathSetting("Mesh grading", path: $developerMeshGrading, defaultPath: store.library.environment.meshGradingExecutable)
                pathSetting("Python", path: $developerPython, defaultPath: ProcessLauncher.runtimePythonURL.path)
                pathSetting("uv", path: $developerUV, defaultPath: store.library.environment.uvExecutable)
                pathSetting("External dependencies", path: $developerExternalDir,
                            defaultPath: store.library.environment.externalDir, directory: true)
            }
        }
    }

    // MARK: Controls

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func numberField(_ title: String, value: Binding<Int>, range: ClosedRange<Int>,
                             step: Int = 1, unit: String? = nil) -> some View {
        HStack(spacing: 6) {
            TextField(title, value: value, format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .onChange(of: value.wrappedValue) { newValue in
                    let bounded = min(max(newValue, range.lowerBound), range.upperBound)
                    if bounded != newValue { value.wrappedValue = bounded }
                }
            // Reserve the unit column on every row so fields and steppers line up.
            Text(unit ?? "")
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)
                .accessibilityHidden(unit == nil)
            Stepper(title, value: value, in: range, step: step)
                .labelsHidden()
        }
    }

    private func toolStatus(_ title: String, path: String, directory: Bool = false) -> some View {
        var isDirectory: ObjCBool = false
        let ready = directory
            ? FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            : FileManager.default.isExecutableFile(atPath: path)
        return LabeledContent {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ready ? Color.green : Color.orange)
                        .accessibilityHidden(true)
                    Text(ready ? "Available" : "Missing")
                        .foregroundStyle(.secondary)
                }
                Button {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "arrow.forward.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!ready)
                .help("Show in Finder")
                .accessibilityLabel("Show \(title) in Finder")
            }
        } label: {
            Text(title)
        }
        .help(path)
    }

    private func pathSetting(_ title: String, path: Binding<String>, defaultPath: String, directory: Bool = false) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, text: path, prompt: Text("Default"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                    .help(path.wrappedValue.isEmpty ? defaultPath : path.wrappedValue)
                    .accessibilityLabel("\(title) path")
                Button("Choose…") {
                    if directory {
                        chooseDirectory(selection: path)
                    } else {
                        chooseFile(selection: path)
                    }
                }
                Button {
                    path.wrappedValue = ""
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .disabled(path.wrappedValue.isEmpty)
                .help("Use the default")
                .accessibilityLabel("Reset \(title) path")
            }
        }
    }

    // MARK: Panels

    private func chooseFile(selection: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            selection.wrappedValue = url.path
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
