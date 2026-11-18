import SwiftUI
import SceneKit

struct PressureFieldView: View {
    static let minimumViewerWidth: CGFloat = 420
    @StateObject private var model: PressureFieldModel
    @Environment(\.colorScheme) private var colorScheme

    init(source: URL) { _model = StateObject(wrappedValue: PressureFieldModel(source: source)) }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { selectors; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 8) { selectors }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            Divider()
            ZStack(alignment: .bottomLeading) {
                PersistentSceneView(scene: model.scene, darkMode: colorScheme == .dark,
                    placementMode: false, resetView: model.resetCamera, cameraPositionChanged: { _, _, _ in }, surfaceSelected: { _ in })
                    .id(model.cameraRevision)
                    .opacity(model.loading ? 0.3 : 1)
                if model.error == nil && !model.loading {
                    legend.padding(16)
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
            .overlay(alignment: .bottomTrailing) {
                ViewerOverlayControls(resetView: model.resetCamera)
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
        .frame(width: 190)
        Picker("Surface", selection: $model.surface) {
            ForEach(model.surfaces, id: \.self) { Text($0).tag($0) }
        }
        .frame(width: 180)
        Picker("Quantity", selection: $model.quantity) {
            ForEach(PressureQuantity.allCases) { Text($0.rawValue).tag($0) }
        }
        .frame(width: 165)
    }

    private var legendHelp: String {
        switch model.quantity {
        case .level: "Raw NumCalc pressure before SOFA normalization. Zero values use the −160 dB floor."
        case .phase: "Raw NumCalc pressure before SOFA normalization. Gray marks undefined phase at zero pressure."
        default: "Raw NumCalc pressure before SOFA normalization."
        }
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
                .help("Keep the range when changing frequency")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .help(legendHelp)
    }
}
