import SwiftUI
import AppKit

struct HeadGeometryControls: View {
    @ObservedObject var store: AppStore
    @State private var distance = ""
    @State private var editStart = ""
    @FocusState private var focused: Bool
    func display(_ value: Double) -> String { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value) }
    func sync() {
        guard !focused else { return }
        if let saved = store.selectedProject?.settings.preprocessing.earDistance {
            distance = (try? HeadGeometrySettings.number(saved)).map { display($0) } ?? saved
        } else {
            distance = store.geometryValues.map { display($0.distance) } ?? ""
        }
        editStart = distance
    }
    func commit() {
        if distance != editStart { store.editGeometry(ear: true, text: distance) }
        focused = false
        sync()
    }
    func focusRequested() {
        guard store.earDistanceFocusRequest != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            focused = true
            DispatchQueue.main.async {
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                store.earDistanceFocusRequest = nil
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledTextField("Ear distance from head center (mm)", helpID: "mesh2hrtf.ear_distance", text: $distance)
                .focused($focused).onSubmit { commit() }
                .id("ear-distance")
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let values = store.geometryValues {
                        Text("Left: \(values.left.map { display($0) } ?? "—") mm; Right: \(values.right.map { display($0) } ?? "—") mm.")
                    }
                    if !store.geometryMessage.isEmpty { Text(store.geometryMessage) }
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                Button("Reset from meshes") { store.editGeometry(ear: true, text: "", reset: true); sync() }
                    .fixedSize()
            }
        }
        .disabled(store.selectedProjectIsRunning || store.geometryEditing)
        .onAppear { store.refreshGeometry(); sync(); focusRequested() }
        .onChange(of: store.geometryValues) { _ in sync() }
        .onChange(of: store.selectedProjectID) { _ in focused = false; sync() }
        .onChange(of: focused) { value in if value { editStart = distance } else { commit() } }
        .onChange(of: store.earDistanceFocusRequest) { _ in focusRequested() }
    }
}
