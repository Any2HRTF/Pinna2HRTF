import SwiftUI
import UniformTypeIdentifiers
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
                .font(.caption)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("About \(SettingHelpCatalog.entry(helpID)?.title ?? "this setting")")
        .help("Show information")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            if let entry = SettingHelpCatalog.entry(helpID) {
                SettingHelpPopover(entry: entry)
            }
        }
    }
}

struct SettingHelpPopover: View {
    let entry: SettingHelpEntry
    @Environment(\.dismiss) private var dismiss
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(entry.title)
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .focused($closeFocused)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close Information")
                .help("Close Information")
            }
            Text(entry.description)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if !entry.publications.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Publications")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(entry.publications) { publication in
                        Button(publication.title) {
                            if let url = URL(string: publication.url) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .onAppear { closeFocused = true }
    }
}

struct SettingLabel: View {
    let title: String
    let helpID: String

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            SettingHelpButton(helpID: helpID)
        }
    }
}

struct SettingToggle: View {
    let title: String
    let helpID: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 6) {
            Toggle(title, isOn: $isOn)
            SettingHelpButton(helpID: helpID)
        }
    }
}

struct SettingsDisclosure<Content: View>: View {
    let title: String
    let systemImage: String
    @State private var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: String, systemImage: String, expanded: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self._isExpanded = State(initialValue: expanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 18, height: 18)
                    Label(title, systemImage: systemImage)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                VStack(alignment: .leading, spacing: 9) {
                    content()
                }
                .padding(.top, 8)
                .padding(.leading, 2)
            }
        }
    }
}

struct WorkspaceScrollEdges: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .vertical)
        } else {
            content
        }
    }
}

struct LabeledTextField: View {
    let title: String
    let helpID: String
    let fieldEnabled: Bool
    @Binding var text: String

    init(_ title: String, helpID: String, text: Binding<String>, fieldEnabled: Bool = true) {
        self.title = title
        self.helpID = helpID
        self.fieldEnabled = fieldEnabled
        self._text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingLabel(title: title, helpID: helpID)
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .disabled(!fieldEnabled)
                .opacity(fieldEnabled ? 1 : 0.55)
        }
    }
}

struct LabeledMillimeterSlider: View {
    let title: String
    let helpID: String
    let sliderEnabled: Bool
    @Binding var value: Double
    let range: ClosedRange<Double>

    init(_ title: String, helpID: String, value: Binding<Double>, range: ClosedRange<Double>, sliderEnabled: Bool = true) {
        self.title = title
        self.helpID = helpID
        self.sliderEnabled = sliderEnabled
        self._value = value
        self.range = range
    }

    var body: some View {
        HStack(spacing: 8) {
            SettingLabel(title: title, helpID: helpID)
            if sliderEnabled {
                Slider(value: $value, in: range, step: 1)
                    .frame(maxWidth: .infinity)
            }
            Text("\(Int(value.rounded())) mm")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .opacity(sliderEnabled ? 1 : 0.55)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

enum PathFieldMode {
    case file
    case directory
    case any
}

struct PathField: View {
    let title: String
    let helpID: String
    @Binding var text: String
    var mode: PathFieldMode = .any

    init(_ title: String, helpID: String, text: Binding<String>, mode: PathFieldMode = .any) {
        self.title = title
        self.helpID = helpID
        self._text = text
        self.mode = mode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingLabel(title: title, helpID: helpID)
            HStack(spacing: 6) {
                TextField(title, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Button("Choose") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = mode != .directory
                    panel.canChooseDirectories = mode != .file
                    if panel.runModal() == .OK, let url = panel.url {
                        text = url.path
                    }
                }
            }
        }
    }
}

struct ToolPathField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(isInstalled ? .green : .red)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(isInstalled ? "Installed" : "Missing")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isInstalled ? .green : .red)
                Spacer()
            }
            HStack(spacing: 6) {
                TextField(title, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Button("Choose") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        text = url.path
                    }
                }
            }
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
        VStack(alignment: .leading, spacing: 4) {
            SettingLabel(title: "Model", helpID: helpID)
            Picker("Model", selection: $selection) {
                if options.isEmpty {
                    Text("No bundled models found").tag(selection)
                } else {
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension UTType {
    static var yaml: UTType { UTType(filenameExtension: "yaml")! }
}
