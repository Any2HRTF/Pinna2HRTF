import Foundation

struct PPMFittingRequest: Identifiable {
    let id = UUID()
    let projectID: UUID
    let side: EarSide
    let targetMesh: URL
    let sourceIdentity: String
    let destinationMesh: URL
    let destinationParameters: URL
    let destinationBlend: URL
    let savedParameters: URL?
    let initialTemplateBlend: URL?
}

struct PPMFittingControl: Identifiable, Equatable {
    let id: String
    let section: String
    let group: String
    let label: String
    var value: Double
    let minimum: Double
    let maximum: Double
    let unit: String
}

struct PPMFittingMetric: Identifiable, Equatable {
    let id: String
    let label: String
    let value: Double
}
