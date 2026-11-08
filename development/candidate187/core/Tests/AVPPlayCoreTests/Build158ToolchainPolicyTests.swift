import XCTest
@testable import AVPPlayCore

final class Build158ToolchainPolicyTests: XCTestCase {
    private func fixture() throws -> (URL, ToolchainPackager, Recipe) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("avp158-policy-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("visionos/run.sh"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        return (root, ToolchainPackager(root: root), try RecipeStore(directory: recipes).load(id: "batman"))
    }

    @discardableResult
    private func plant(_ packager: ToolchainPackager, version: Int, commit: String, ancestors: [String],
                       targets: [String] = ["batman"], modified: Bool = false) throws -> Toolchain {
        let root = packager.root.appendingPathComponent("\(version)-\(commit)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("visionos/run.sh"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("visionos/Sources"), withIntermediateDirectories: true)
        for path in ["Makefile", "visionos/gen_xcodeproj.py", "visionos/Sources/kl_app.c"] {
            try Data("verified fixture: \(path)\n".utf8).write(to: root.appendingPathComponent(path))
        }
        let targetRows = targets.map { "    \"\($0)\": {},\n" }.joined()
        try Data("TARGETS = {\n\(targetRows)}\n".utf8)
            .write(to: root.appendingPathComponent("visionos/targets.py"))
        let manifest = ToolchainManifest(format: 1, version: version, commit: commit, ancestors: ancestors,
            created: Date(timeIntervalSince1970: 1), modified: modified)
        let manifestURL = root.appendingPathComponent("toolchain.json")
        try ToolchainPackager.encoder.encode(manifest).write(to: manifestURL)
        let toolchain = try Toolchain(root: root)
        if [824, 850].contains(version) && !modified {
            let files = ["toolchain.json", "Makefile", "visionos/run.sh", "visionos/targets.py",
                         "visionos/gen_xcodeproj.py", "visionos/Sources/kl_app.c"]
            let receipt = try Dictionary(uniqueKeysWithValues: files.map { ($0, try Hashing.sha256(of: root.appendingPathComponent($0))) })
            try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent(".isolated-source-sha256.json"))
        }
        return toolchain
    }

    func testOnly850IsSelectedAndRecipeMinimumIsChecked() throws {
        let (_, packager, base) = try fixture()
        let legacy = try plant(packager, version: 750, commit: "900daf8", ancestors: ["900daf8"])
        XCTAssertNil(packager.build158Toolchain(for: base), "750 must never be a fallback for a new build")
        let official = try plant(packager, version: 824, commit: "a61188d", ancestors: ["a61188d", "900daf8", "dc1a2a8"])
        XCTAssertNil(packager.build158Toolchain(for: base), "Even a historical verified receipt cannot enable 824 builds")
        let verified = try Verified850Fixture.source()
        let current = ToolchainPackager(root: verified.root.deletingLastPathComponent())
        XCTAssertEqual(current.build158Toolchain(for: base)?.commit(), "cc2856c")
        var future = base
        future.toolchain.minCommit = "deadbee"
        XCTAssertNil(current.build158Toolchain(for: future), "an unsatisfied recipe fails closed")
        future = base
        future.toolchain.target = "not-in-official-824"
        XCTAssertNil(current.build158Toolchain(for: future), "an absent target fails closed before a build starts")

        var generic = base
        generic.toolchain.target = "x1921533091289407"
        XCTAssertEqual(current.build158Toolchain(for: generic)?.commit(), "cc2856c",
                       "A valid generic store target may be attempted on the verified 850")
        for invalid in ["x", "x1234", "x12345a", "xx1921533091289407", "generic-1921533091289407"] {
            XCTAssertFalse(official.acceptsBuildTarget(invalid), "Malformed generic target must fail closed: \(invalid)")
            generic.toolchain.target = invalid
            XCTAssertNil(current.build158Toolchain(for: generic), "Malformed generic target must not be admitted")
        }
        _ = legacy
    }

    func testModified824IsNotAcceptedAndHistoricalPinsRemainDataOnly() throws {
        let (_, packager, recipe) = try fixture()
        let modified = try plant(packager, version: 824, commit: "a61188d", ancestors: ["a61188d"], modified: true)
        XCTAssertNil(packager.build158Toolchain(for: recipe))
        var old = ToolchainChoices()
        old.choose(.init(version: 750, commit: "900daf8"), for: recipe.id)
        let data = try JSONEncoder().encode(old)
        let restored = try JSONDecoder().decode(ToolchainChoices.self, from: data)
        XCTAssertEqual(restored, old, "legacy selections remain readable and round-trip without migration")
        _ = modified
    }

    func testDeadpoolSpecificTargetAndGhostbustersGenericTargetAreAccepted() throws {
        let (_, packager, _) = try fixture()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let recipes = RecipeStore(directory: root)
        let deadpool = try recipes.load(id: "store-3240283705987790")
        let ghostbusters = try recipes.load(id: "store-4746232908818706")
        let gunClub = try recipes.load(id: "store-2285803881494677")
        let runtime = try plant(packager, version: 824, commit: "a61188d",
            ancestors: ["a61188d", "6b4da99", "4437316", "9f12962"],
            targets: ["x3240283705987790", "x2285803881494677"])

        XCTAssertNil(packager.build158Toolchain(for: deadpool),
                       "824 metadata remains readable but cannot admit a new build")
        XCTAssertTrue(runtime.hasTarget(deadpool.toolchain.target))
        XCTAssertTrue(runtime.satisfies(minCommit: gunClub.toolchain.minCommit),
                       "A full recipe SHA must match its abbreviated manifest ancestor")
        XCTAssertNil(packager.build158Toolchain(for: gunClub))
        XCTAssertTrue(runtime.satisfies(minCommit: ghostbusters.toolchain.minCommit),
                       "Ghostbusters' minimum commit is present in the 824 history")
        XCTAssertFalse(runtime.hasTarget(ghostbusters.toolchain.target),
                        "This fixture models the official 824 without a tuned Ghostbusters row")
        XCTAssertTrue(runtime.acceptsBuildTarget(ghostbusters.toolchain.target))
        XCTAssertNil(packager.build158Toolchain(for: ghostbusters),
                       "A generic target does not bypass the mandatory 850 policy")
        XCTAssertEqual(Toolchain.genericEnvironment(recipe: ghostbusters)["KLEPTON_GENERIC_TARGET"],
                       "x4746232908818706")
    }

    func testHistoricalPinsRemainUnchangedWhile850IsMandatory() throws {
        let (_, legacyPackager, recipe) = try fixture()
        let legacy824 = try plant(legacyPackager, version: 824, commit: "a61188d",
            ancestors: ["a61188d", "dc1a2a8", "900daf8"])
        let runtime = try Verified850Fixture.source()
        let packager = ToolchainPackager(root: runtime.root.deletingLastPathComponent())
        XCTAssertEqual(packager.build158Toolchain(for: recipe)?.commit(), "cc2856c")
        for pin in [ToolchainChoices.Pin(version: 824, commit: "a61188d", path: legacy824.root.path),
                    ToolchainChoices.Pin(version: 850, commit: "cc2856c", path: runtime.root.path),
                    ToolchainChoices.Pin(version: 850, commit: "missing", path: runtime.root.path)] {
            var choices = ToolchainChoices()
            choices.choose(pin, for: recipe.id)
            let before = try JSONEncoder().encode(choices)
            XCTAssertEqual(packager.selectedToolchain(for: recipe, choices: choices)?.commit(), "cc2856c")
            XCTAssertEqual(try JSONDecoder().decode(ToolchainChoices.self, from: before), choices)
            XCTAssertEqual(choices.games[recipe.id], pin, "Selection must not rewrite historical preferences")
            XCTAssertNil(legacyPackager.selectedToolchain(for: recipe, choices: choices), "No 824 fallback")
        }
    }
}
