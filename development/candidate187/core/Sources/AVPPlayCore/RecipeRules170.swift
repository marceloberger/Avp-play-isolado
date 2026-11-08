import Foundation

public enum Klepton850RecipeRules {
    public static let version = "850-cc2856c"
    public static let revision = "recipes170-v1"
    public static func engineName(_ engine: LocalGenericEngine) -> String {
        switch engine {
        case .unreal4, .unreal: return "ue4"
        case .nativeActivity: return "native"
        default: return engine.rawValue
        }
    }
    public static func obbOverride(target: String?, package: String) -> String? {
        struct Contract: Decodable { let version: String; let genericOBB: [String: String] }
        guard let target, let url = Bundle.module.url(forResource: "klepton850-recipe-rules170", withExtension: "json"),
              let data = try? Data(contentsOf: url), let contract = try? JSONDecoder().decode(Contract.self, from: data),
              contract.version == version, let path = contract.genericOBB[target],
              path == "Android/obb/" + package else { return nil }
        return "android-files/" + path
    }
    /// Only explicit filenames constitute a required-file decision. Storage paths alone are risks.
    public static func obbNames(in references: [String]) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"(?i)([A-Za-z0-9._-]+\.obb)\b"#)
        return Set(references.flatMap { text in
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            }
        }).sorted()
    }
}

