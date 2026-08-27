import SwiftUI
import UniformTypeIdentifiers

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
            if isExpanded {
                VStack(alignment: .leading, spacing: 9) {
                    content()
                }
                .padding(.top, 8)
                .padding(.leading, 2)
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct LabeledTextField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct LabeledMillimeterSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) {
        self.title = title
        self._value = value
        self.range = range
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.rounded())) mm")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: 1)
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
    @Binding var text: String
    var mode: PathFieldMode = .any

    init(_ title: String, text: Binding<String>, mode: PathFieldMode = .any) {
        self.title = title
        self._text = text
        self.mode = mode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(title, text: $text)
                    .textFieldStyle(.roundedBorder)
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

    init(selection: Binding<String>, options: [String]) {
        self._selection = selection
        self.options = options
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension UTType {
    static var yaml: UTType { UTType(filenameExtension: "yaml")! }
}
