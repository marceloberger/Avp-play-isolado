import Foundation

/// Runs only Klepton's local APK unpack/preparation step. This deliberately does not create an Installer or Job,
/// so it cannot enter account, fetch, build, signing, install, device sync, or launch steps.
public struct LocalAPKPreparer: Sendable {
    public init() {}

    /// User-facing Prepare writes exclusively to a new workspace; installed toolchains stay immutable.
    @discardableResult
    public func prepareIsolated(recipe: Recipe, variantID: String, store: ContentStore,
                                toolchain: Toolchain, localVariants: LocalAPKVariantStore,
                                verifyAssetHashes: Bool = true, workspaceRoot: URL? = nil) throws -> URL {
        try RuntimePolicy177.requireSource(toolchain)
        guard (toolchain.version() == 824 && toolchain.commit() == "a61188d" && OptionalRuntime824.hasVerifiedReceipt(for: toolchain))
                || (toolchain.version() == 850 && toolchain.commit() == "cc2856c" && OptionalRuntime850.hasVerifiedReceipt(for: toolchain)) else {
            throw LocalAPKVariantError.invalidRecord("Prepare exige Klepton 824 ou 850 verificado; a escolha salva não foi alterada.")
        }
        _ = try localVariants.validatedForPreparation(id: variantID, for: recipe)
        let parent = workspaceRoot ?? DataLocation.base.appendingPathComponent("prepared-local", isDirectory: true)
        let workspace = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        _ = try IsolatedToolchainWorkspace.stage(from: toolchain, to: workspace)
        return try prepare(recipe: recipe, variantID: variantID, store: store,
            toolchain: Toolchain(root: workspace), localVariants: localVariants, verifyAssetHashes: verifyAssetHashes)
    }

    /// Revalidates the selected local variant through `Toolchain.prepare` before writing intermediates.
    /// Returns the prepared target directory.
    @discardableResult
    public func prepare(recipe: Recipe, variantID: String, store: ContentStore,
                        toolchain: Toolchain, localVariants: LocalAPKVariantStore = LocalAPKVariantStore(),
                        verifyAssetHashes: Bool = true) throws -> URL {
        guard Recipe.isSafeName(recipe.id), Recipe.isSafeName(recipe.toolchain.target),
              recipe.files.contains(where: { $0.role == "apk" }) else {
            throw LocalAPKVariantError.recipeMismatch(recipe.id)
        }
        let kleptonRecipe = KleptonRecipeCompatibility.resolve(recipe)
        try toolchain.prepare(recipe: kleptonRecipe, store: store, localAPKVariantID: variantID,
                              localVariants: localVariants, verifyLocalAssetHashes: verifyAssetHashes)
        return toolchain.root.appendingPathComponent(kleptonRecipe.toolchain.target, isDirectory: true)
    }
}
