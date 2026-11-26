import Foundation

enum SettingsCatalog {
    struct FieldRule: Decodable {
        let id: String
        let config: String
        let kind: String
        let minimum: Double?
        let exclusiveMinimum: Double?
        let maximum: Double?
        let multipleOf: Double?
        let optional: Bool?
        let choices: [String]?
        let when: String?
        let message: String
        let stages: [String]
    }

    struct Relation: Decodable {
        let id: String
        let kind: String
        let other: String?
        let fields: [String]?
        let when: String?
        let message: String
        let stages: [String]
    }

    struct Rules: Decodable {
        var fields: [FieldRule] = []
        var relations: [Relation] = []
        var parseMessages: [String: String] = [:]
    }

    static let rules: Rules = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = try? ProjectConfigDocument.request("rules", [:]),
              let rules = try? decoder.decode(Rules.self, from: data) else { return Rules() }
        return rules
    }()

    static let defaults: [String: [String: Any]] = {
        guard let data = try? ProjectConfigDocument.request("defaults", [:]),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = reply["config"] as? [String: [String: Any]] else { return [:] }
        return config
    }()

    static func value(_ key: String) -> Any? {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return defaults[parts[0]]?[parts[1]]
    }

    static func text(_ key: String) -> String {
        switch value(key) {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return ""
        }
    }

    static func flag(_ key: String) -> Bool { (value(key) as? Bool) ?? false }

    static func range(_ id: String) -> ClosedRange<Int> {
        guard let rule = rules.fields.first(where: { $0.id == id }) else { return 0...Int.max }
        let lower = Int(rule.minimum ?? rule.exclusiveMinimum.map { $0 + 1 } ?? 0)
        let upper = Int(rule.maximum ?? Double(Int.max))
        return lower...max(lower, upper)
    }

    static func fieldMessage(_ id: String, text: String) -> String? {
        guard let rule = rules.fields.first(where: { $0.id == id }) else { return nil }
        return message(rule, text: text)
    }

    static func message(_ rule: FieldRule, text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return rule.optional == true ? nil : rules.parseMessages[rule.kind] ?? rule.message }
        if rule.kind == "text" { return rule.choices.map { $0.contains(value) ? nil : rule.message } ?? nil }
        guard let number = number(value, kind: rule.kind) else { return rules.parseMessages[rule.kind] }
        if let minimum = rule.minimum, number < minimum { return rule.message }
        if let minimum = rule.exclusiveMinimum, number <= minimum { return rule.message }
        if let maximum = rule.maximum, number > maximum { return rule.message }
        if let step = rule.multipleOf, number.truncatingRemainder(dividingBy: step) != 0 { return rule.message }
        return nil
    }

    static func number(_ text: String, kind: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == "integer" { return Int(value).map(Double.init) }
        guard let number = Double(value), number.isFinite else { return nil }
        return number
    }

    static func check(_ values: [String: String], id: String) -> String? {
        if let text = values[id], let message = fieldMessage(id, text: text) { return message }
        let related = Set(rules.relations.filter { $0.id == id || $0.other == id || ($0.fields ?? []).contains(id) }.map(\.id))
        return issues(values, stage: nil).first { related.contains($0.id) }?.message
    }

    static func issues(_ values: [String: String], stage: Stage?) -> [(id: String, message: String)] {
        func active(_ condition: String?) -> Bool { condition.map { values[$0]?.lowercased() == "true" } ?? true }
        var found: [(id: String, message: String, stages: [String])] = []
        for rule in rules.fields where active(rule.when) {
            if let text = values[rule.id], let message = message(rule, text: text) { found.append((rule.id, message, rule.stages)) }
        }
        let invalid = Set(found.map(\.id))
        let kinds = Dictionary(rules.fields.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        for relation in rules.relations where active(relation.when) {
            if relation.kind == "any" {
                if !(relation.fields ?? []).contains(where: { values[$0]?.lowercased() == "true" }) {
                    found.append((relation.id, relation.message, relation.stages))
                }
                continue
            }
            guard let other = relation.other, !invalid.contains(relation.id), !invalid.contains(other),
                  let kind = kinds[relation.id],
                  let value = values[relation.id].flatMap({ number($0, kind: kind) }),
                  let bound = values[other].flatMap({ number($0, kind: kind) }) else { continue }
            if (relation.kind == "greater" && value <= bound) || (relation.kind == "at_least" && value < bound) {
                found.append((relation.id, relation.message, relation.stages))
            }
        }
        return found.filter { stage == nil || $0.stages.contains(stage!.rawValue) }.map { (id: $0.id, message: $0.message) }
    }
}
