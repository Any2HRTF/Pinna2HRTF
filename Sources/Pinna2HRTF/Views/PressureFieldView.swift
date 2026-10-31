import SwiftUI
import SceneKit

struct PressureFieldView: View {
    @StateObject private var model: PressureFieldModel
    @Environment(\.colorScheme) private var colorScheme

    init(source: URL) { _model = StateObject(wrappedValue: PressureFieldModel(source: source)) }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack { selectors }
                VStack(alignment: .leading) { selectors }
            }
            .padding(12)
            Divider()
            ZStack(alignment: .bottomLeading) {
                PersistentSceneView(scene: model.scene, darkMode: colorScheme == .dark,
                    placementMode: false, cameraPositionChanged: { _, _, _ in }, surfaceSelected: { _ in })
                    .id(model.cameraRevision)
                    .opacity(model.loading ? 0.3 : 1)
                if model.error == nil && !model.loading {
                    legend.padding(14)
                }
                if model.loading {
                    ProgressView("Loading pressure…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let error = model.error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.title)
                        Text(error).textSelection(.enabled)
                        Button("Retry") { Task { await model.open(); await model.load() } }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                }
            }
        }
        .task { await model.open() }
        .task(id: model.selection) { await model.load() }
        .onChange(of: model.quantity) { _ in model.changeQuantity() }
        .onChange(of: model.lockScale) { _ in model.recolor() }
    }

    @ViewBuilder private var selectors: some View {
        Picker("Frequency", selection: $model.step) {
            ForEach(model.steps) { step in Text(step.label).tag(step.id) }
        }
        .frame(minWidth: 160)
        Picker("Surface", selection: $model.surface) {
            ForEach(model.surfaces, id: \.self) { Text($0).tag($0) }
        }
        Picker("Quantity", selection: $model.quantity) {
            ForEach(PressureQuantity.allCases) { Text($0.rawValue).tag($0) }
        }
        Button("Reset View", systemImage: "arrow.counterclockwise", action: model.resetCamera)
            .labelStyle(.iconOnly)
            .help("Reset pressure view")
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.open(); await model.load() } }
            .labelStyle(.iconOnly)
            .help("Reload available NumCalc results")
            .disabled(model.loading)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(model.quantity.rawValue) · \(model.quantity.unit)").font(.caption.weight(.semibold))
            LinearGradient(colors: model.quantity.palette.map { Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)) }, startPoint: .leading, endPoint: .trailing)
                .frame(width: 210, height: 10)
            HStack {
                Text(model.range.lowerBound, format: .number.precision(.significantDigits(4)))
                Spacer()
                Text(model.range.upperBound, format: .number.precision(.significantDigits(4)))
            }.font(.caption.monospacedDigit()).frame(width: 210)
            Toggle("Lock color scale", isOn: $model.lockScale).toggleStyle(.checkbox)
                .help("Keep the displayed range when changing frequencies. Values outside it use the end colors.")
            Text("Raw NumCalc pressure · before SOFA normalization")
                .font(.caption2).foregroundStyle(.secondary)
            if model.quantity == .level {
                Text("Zero values use the −160 dB display floor.").font(.caption2).foregroundStyle(.secondary)
            } else if model.quantity == .phase {
                Text("Gray indicates undefined phase at zero pressure.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
