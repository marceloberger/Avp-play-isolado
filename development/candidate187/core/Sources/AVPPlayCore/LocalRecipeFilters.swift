import Foundation

/// A user-defined grouping of local recipe identifiers. It deliberately stores no catalog records or account data.
public struct LocalRecipeFilter: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var recipeIDs: Set<String>

    public init(id: String = UUID().uuidString, name: String, recipeIDs: Set<String> = []) {
        self.id = id
        self.name = name
        self.recipeIDs = recipeIDs
    }
}

public enum LocalRecipeFilterMode: String, Codable, CaseIterable, Sendable {
    case off, only, hide
}

/// Local-only filter rules, separated from the Meta-backed online catalogue filters.
public enum LocalRecipeFilters {
    public static func passes(_ recipeID: String, filters: [LocalRecipeFilter], modes: [String: LocalRecipeFilterMode]) -> Bool {
        for filter in filters {
            switch modes[filter.id] ?? .off {
            case .off: continue
            case .only: if !filter.recipeIDs.contains(recipeID) { return false }
            case .hide: if filter.recipeIDs.contains(recipeID) { return false }
            }
        }
        return true
    }

    public static func cleanName(_ name: String) -> String {
        let oneLine = name.components(separatedBy: .newlines).joined(separator: " ")
        return String(oneLine.trimmingCharacters(in: .whitespaces).prefix(40))
    }

    public static func nameProblem(_ name: String, in filters: [LocalRecipeFilter], except: String? = nil) -> String? {
        let clean = cleanName(name)
        if clean.isEmpty { return "Enter a filter name." }
        if filters.contains(where: {
            $0.id != except && $0.name.compare(clean, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) { return "A filter with that name already exists." }
        return nil
    }

    public static func decode(_ data: Data?) -> [LocalRecipeFilter] {
        guard let data, let filters = try? JSONDecoder().decode([LocalRecipeFilter].self, from: data) else { return [] }
        return filters
    }

    public static func encode(_ filters: [LocalRecipeFilter]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(filters)) ?? Data("[]".utf8)
    }

    public static func decodeModes(_ data: Data?, filters: [LocalRecipeFilter]) -> [String: LocalRecipeFilterMode] {
        guard let data,
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        let ids = Set(filters.map(\.id))
        return values.reduce(into: [:]) { result, pair in
            guard ids.contains(pair.key), let mode = LocalRecipeFilterMode(rawValue: pair.value), mode != .off else { return }
            result[pair.key] = mode
        }
    }

    public static func encodeModes(_ modes: [String: LocalRecipeFilterMode]) -> Data {
        let values = modes.filter { $0.value != .off }.mapValues(\.rawValue)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(values)) ?? Data("{}".utf8)
    }
}
