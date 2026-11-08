import Foundation

/// Resolves catalog recipe identifiers to names understood by the installed Klepton toolchain.
/// The catalog recipe remains authoritative for package/version/file identity; only Klepton's
/// target alias and the APK's private working filename may be adapted here.
public enum KleptonRecipeCompatibility {
    public static let residentEvilOBBFile = "main.203.com.Armature.VR4.obb"

    private struct Mapping {
        let recipeID: String
        let declaredTarget: String
        let kleptonTarget: String
        let declaredAPKName: String
        let kleptonAPKName: String
    }

    private static let mappings = [
        Mapping(recipeID: "store-2637179839719680",
                declaredTarget: "x2637179839719680", kleptonTarget: "re4",
                declaredAPKName: "x2637179839719680.apk", kleptonAPKName: "re4.apk")
    ]

    /// A copy suitable for Klepton's scripts. The official/catalog recipe and its file records
    /// are not modified, so local variant identity and verification remain tied to the recipe.
    public static func resolve(_ recipe: Recipe) -> Recipe {
        guard let mapping = mappings.first(where: {
            $0.recipeID == recipe.id && $0.declaredTarget == recipe.toolchain.target
        }) else { return recipe }

        var result = recipe
        result.toolchain.target = mapping.kleptonTarget
        for index in result.files.indices where result.files[index].role == "apk"
            && result.files[index].localName == mapping.declaredAPKName {
            result.files[index].localName = mapping.kleptonAPKName
        }
        return result
    }

    /// Adds the missing RE4 data-panel metadata to an isolated toolchain copy. The installed toolchain is never edited.
    @discardableResult
    public static func addResidentEvilTargetMetadata(to toolchainRoot: URL) throws -> URL {
        let targets = toolchainRoot.appendingPathComponent("visionos/targets.py")
        let original = try String(contentsOf: targets, encoding: .utf8)
        let targetMarker = #"    "re4": {"#
        guard original.components(separatedBy: targetMarker).count == 2,
              let targetStart = original.range(of: targetMarker)?.upperBound,
              let targetEnd = original.range(of: "\n    },", range: targetStart..<original.endIndex)?.lowerBound else {
            throw RecipeError.invalid("the RE4 target metadata layout in targets.py is not recognized")
        }

        let targetBlock = String(original[targetStart..<targetEnd])
        let lines = targetBlock.components(separatedBy: "\n")
        let obbKey = try NSRegularExpression(pattern: #"^\s*"obb"\s*:"#)
        let obbFileKey = try NSRegularExpression(pattern: #"^\s*"obb_file"\s*:"#)
        let obbLines = lines.filter { line in
            obbKey.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        guard obbLines.count == 1,
              let obbIndex = lines.firstIndex(where: { line in
                  obbKey.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
              }) else {
            throw RecipeError.invalid("the RE4 target must contain exactly one obb entry")
        }

        var normalizedLines = lines.filter { line in
            obbFileKey.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil
        }
        let normalizedOBBIndex = normalizedLines.firstIndex(where: { line in
            obbKey.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }) ?? obbIndex
        let obbIndent = String(lines[obbIndex].prefix { $0 == " " || $0 == "\t" })
        normalizedLines.insert("\(obbIndent)\"obb_file\": \"\(residentEvilOBBFile)\",", at: normalizedOBBIndex + 1)

        let normalizedBlock = normalizedLines.joined(separator: "\n")
        guard normalizedBlock != targetBlock else { return targets }
        var updated = original
        updated.replaceSubrange(targetStart..<targetEnd, with: normalizedBlock)
        try updated.write(to: targets, atomically: true, encoding: .utf8)
        return targets
    }

    /// Makes a per-RE4 working copy for the original install flow and marks it as modified for provenance.
    public static func residentEvilToolchainCopy(from source: Toolchain, under directory: URL) throws -> Toolchain {
        let sourceTargets = source.root.appendingPathComponent("visionos/targets.py")
        if source.isModified,
           let text = try? String(contentsOf: sourceTargets, encoding: .utf8),
           text.contains("\"obb_file\": \"\(residentEvilOBBFile)\"") { return source }
        let folder = directory.appendingPathComponent("re4-\(source.version())-\(source.commit())", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let fresh = directory.appendingPathComponent(".re4-\(UUID().uuidString).new", isDirectory: true)
            defer { try? fm.removeItem(at: fresh) }
            try fm.copyItem(at: source.root, to: fresh)
            try addResidentEvilTargetMetadata(to: fresh)
            try fm.moveItem(at: fresh, to: folder)
        }
        _ = try addResidentEvilTargetMetadata(to: folder)
        let copy = try ToolchainPackager(root: ToolchainPackager.defaultRoot).markModified(folder)
        return copy
    }
}
