import SwiftUI
import Foundation
import AppKit

struct SettingHelpPublication: Codable, Identifiable {
    let title: String
    let url: String

    var id: String { url }
}

struct SettingHelpEntry: Codable, Identifiable {
    let id: String
    let title: String
    let description: String
    let publications: [SettingHelpPublication]
}

enum SettingHelpCatalog {
    static let entries: [String: SettingHelpEntry] = {
        let url = Defaults.pipelineRoot.appendingPathComponent("ProjectSettingHelp.json")
        guard let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([SettingHelpEntry].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }()

    static func entry(_ id: String) -> SettingHelpEntry? {
        entries[id]
    }
}

struct SettingHelpButton: View {
    let helpID: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("About \(SettingHelpCatalog.entry(helpID)?.title ?? "This Setting")")
        .help("Show Information")
        .popover(isPresented: $isPresented) {
            if let entry = SettingHelpCatalog.entry(helpID) {
                SettingHelpPopover(entry: entry)
            }
        }
    }
}

struct SettingHelpPopover: View {
    let entry: SettingHelpEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.title)
                .font(.headline)
            Text(entry.description)
                .fixedSize(horizontal: false, vertical: true)
            if !entry.publications.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Publications")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(entry.publications) { publication in
                        Button(publication.title) {
                            if let url = URL(string: publication.url) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .multilineTextAlignment(.leading)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

struct SettingLabel: View {
    let title: String
    let helpID: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            SettingHelpButton(helpID: helpID)
        }
    }
}

struct SettingToggle: View {
    let title: String
    let helpID: String
    @Binding var isOn: Bool

    var body: some View {
        LabeledContent {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        } label: {
            SettingLabel(title: title, helpID: helpID)
        }
    }
}

struct FieldWarning: View {
    let message: String

    init(_ message: String) { self.message = message }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .symbolRenderingMode(.multicolor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Locale {
    static let posix = Locale(identifier: "en_US_POSIX")
}

enum FieldWidth {
    static let number: CGFloat = 96
    static let text: CGFloat = 220
}

struct LabeledTextField: View {
    let title: String
    let helpID: String
    let fieldEnabled: Bool
    @Binding var text: String
    var validationError: String?

    init(_ title: String, helpID: String, text: Binding<String>, fieldEnabled: Bool = true, validationError: String? = nil) {
        self.title = title
        self.helpID = helpID
        self.fieldEnabled = fieldEnabled
        self._text = text
        self.validationError = validationError
    }

    private var isNumber: Bool {
        SettingsCatalog.rules.fields.contains { $0.id == helpID && ($0.kind == "integer" || $0.kind == "decimal") }
    }

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                TextField(title, text: $text)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(isNumber ? .trailing : .leading)
                    .frame(minWidth: isNumber ? FieldWidth.number : 80, maxWidth: isNumber ? FieldWidth.number : FieldWidth.text)
                    .disabled(!fieldEnabled)
                if fieldEnabled, let error = validationError ?? ProjectValidation.fieldMessage(helpID, text: text) {
                    FieldWarning(error)
                }
            }
        } label: {
            SettingLabel(title: title, helpID: helpID)
        }
    }
}

struct NumberStepperField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit: String?

    var body: some View {
        HStack(spacing: 6) {
            TextField(title, value: $value, format: .number.grouping(.never).locale(.posix))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: FieldWidth.number)
                .onChange(of: value) { newValue in
                    let bounded = min(max(newValue, range.lowerBound), range.upperBound)
                    if bounded != newValue { value = bounded }
                }
            Text(unit ?? " ")
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)
                .accessibilityHidden(unit == nil)
            Stepper(title, value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}

enum PathFieldMode {
    case file
    case directory
}

struct PathField: View {
    let title: String
    let helpID: String
    @Binding var text: String
    let mode: PathFieldMode
    let defaultName: String?
    let defaultPath: String?

    init(_ title: String, helpID: String, text: Binding<String>, mode: PathFieldMode, defaultName: String? = nil, defaultPath: String? = nil) {
        self.title = title
        self.helpID = helpID
        self._text = text
        self.mode = mode
        self.defaultName = defaultName
        self.defaultPath = defaultPath
    }

    private var effectivePath: String { text.isEmpty ? defaultPath ?? "" : text }

    private var displayName: String {
        if !text.isEmpty { return URL(fileURLWithPath: text, isDirectory: mode == .directory).lastPathComponent }
        return defaultName.map { "\($0) (Default)" } ?? "None"
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(displayName)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(effectivePath)
                    .contextMenu {
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(effectivePath, forType: .string)
                        }
                        .disabled(effectivePath.isEmpty)
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: effectivePath)])
                        }
                        .disabled(effectivePath.isEmpty || !FileManager.default.fileExists(atPath: effectivePath))
                    }
                Button("Choose…", action: choose)
                    .fixedSize()
                    .accessibilityLabel("Choose \(title)")
            }
        } label: {
            SettingLabel(title: title, helpID: helpID)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = mode == .file
        panel.canChooseDirectories = mode == .directory
        panel.canCreateDirectories = mode == .directory
        panel.allowsMultipleSelection = false
        if !text.isEmpty {
            let current = URL(fileURLWithPath: text, isDirectory: mode == .directory)
            panel.directoryURL = mode == .directory ? current : current.deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            text = url.path
        }
    }
}

struct ModelPicker: View {
    @Binding var selection: String
    let options: [String]
    let helpID: String

    init(selection: Binding<String>, options: [String], helpID: String) {
        self._selection = selection
        self.options = options
        self.helpID = helpID
    }

    var body: some View {
        Picker(selection: $selection) {
            if options.isEmpty {
                Text("No Models").tag(selection)
            } else {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        } label: {
            SettingLabel(title: "Model", helpID: helpID)
        }
        .pickerStyle(.menu)
    }
}

struct ViewportControlsMaterial: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
