import Foundation

struct GeometryValues: Codable, Equatable {
    var left: Double?
    var right: Double?
    enum CodingKeys: String, CodingKey { case left = "ear_distance_left", right = "ear_distance_right" }
    var distance: Double {
        let values = [left, right].compactMap { $0 }
        return values.reduce(0, +) / Double(values.count)
    }
    func validate() throws {
        guard distance.isFinite, distance > 0, [left, right].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw HeadGeometrySettings.error("Ear distance must be positive and leave both ear distances nonnegative, in millimetres.")
        }
    }
    func applying(_ settings: PreprocessingSettings) throws -> GeometryValues {
        guard let text = settings.earDistance else { return self }
        return try atDistance(HeadGeometrySettings.number(text))
    }
    func atDistance(_ value: Double) throws -> GeometryValues {
        let delta = value - distance
        let result = GeometryValues(left: left.map { $0 + delta }, right: right.map { $0 + delta })
        try result.validate()
        return result
    }
}

enum HeadGeometrySettings {
    static func needsWarning(_ distance: Double) -> Bool { distance <= 50 }
    static func error(_ message: String) -> NSError { NSError(domain: "EarDistance", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func number(_ text: String) throws -> Double {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), value.isFinite else {
            throw error("Enter a finite number in millimetres.")
        }
        return value
    }
    static func validate(_ settings: PreprocessingSettings) throws {
        if let text = settings.earDistance, try number(text) <= 0 { throw error("Ear distance must be positive.") }
    }
    static func migrateRegistry(_ object: Any) throws -> Any {
        // Version compatibility only; remove with v2.0.0.
        guard var root = object as? [String: Any], var projects = root["projects"] as? [[String: Any]] else { throw error("Invalid project registry.") }
        for index in projects.indices {
            guard var settings = projects[index]["settings"] as? [String: Any], var p = settings["preprocessing"] as? [String: Any] else { continue }
            if p["earDistance"] == nil {
                let sides = try ["earDistanceLeft", "earDistanceRight"].compactMap { p[$0] as? String }.map(number)
                if !sides.isEmpty { p["earDistance"] = String(sides.reduce(0, +) / Double(sides.count)) }
                else {
                    // Legacy headRadius field: version compatibility only; remove with v2.0.0.
                    let old = p["headRadius"] as? String
                    if p["useCustomHeadRadius"] as? Bool ?? (old != nil), let old { p["earDistance"] = old }
                }
            }
            for key in ["headRadius", "useCustomHeadRadius", "earDistanceLeft", "earDistanceRight", "linkGeometry"] { p.removeValue(forKey: key) }
            settings["preprocessing"] = p; projects[index]["settings"] = settings
        }
        root.removeValue(forKey: "appVersion")
        root["projects"] = projects
        return root
    }
}
