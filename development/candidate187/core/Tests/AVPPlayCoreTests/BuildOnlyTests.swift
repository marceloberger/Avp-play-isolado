import XCTest
@testable import AVPPlayCore

final class BuildOnlyTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("build-only-angle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func createInputs(_ root: URL, omit: String? = nil) throws {
        for platform in ["xros", "xrsim"] {
            for lib in ["libEGL", "libGLESv2"] {
                let relative = "vendor/out/\(platform)/\(lib).framework/\(lib)"
                guard relative != omit else { continue }
                let file = root.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("prebuilt slice fixture".utf8).write(to: file)
            }
        }
    }

    private static func createFrameworks(_ root: URL) throws {
        for lib in ["libEGL", "libGLESv2"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("visionos/Frameworks/ANGLE_\(lib).xcframework"),
                                                   withIntermediateDirectories: true)
        }
    }

    private static func append(_ text: String, log: URL) throws {
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func testDistributedPackageWithoutGitWrapsAllLocalANGLESlices() throws {
        let root = try scratch(), calls = LockedBox(0)
        try createInputs(root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("vendor/.git").path))
        let log = root.appendingPathComponent("build-only.log")
        try BuildOnlyPipeline.prepareANGLE(workspace: root, log: log, environment: ["XROS_PLATFORMS": "xros"]) { command, output in
            calls.set(calls.get() + 1)
            XCTAssertEqual(command.executable.lastPathComponent, "mkangle.sh")
            XCTAssertEqual(command.directory, root.appendingPathComponent("visionos", isDirectory: true))
            XCTAssertTrue(command.arguments.isEmpty)
            XCTAssertNil(command.environment["KLEPTON_DEVICE"])
            try Self.append("[mkangle] fixture complete\n", log: output)
            try Self.createFrameworks(root)
            return 0
        }
        XCTAssertEqual(calls.get(), 1)
        XCTAssertTrue(try String(contentsOf: log).contains("[mkangle] fixture complete"))
        // A second dependency check reuses the complete outputs, without invoking a helper.
        try BuildOnlyPipeline.prepareANGLE(workspace: root, log: log) { _, _ in
            XCTFail("Existing ANGLE frameworks must not be replaced")
            return 1
        }
    }

    func testOneMissingANGLEFrameworkTriggersWrappingWithoutGit() throws {
        let root = try scratch(), calls = LockedBox(0)
        try createInputs(root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("visionos/Frameworks/ANGLE_libEGL.xcframework"), withIntermediateDirectories: true)
        try BuildOnlyPipeline.prepareANGLE(workspace: root, log: root.appendingPathComponent("build-only.log")) { _, _ in
            calls.set(calls.get() + 1)
            try Self.createFrameworks(root)
            return 0
        }
        XCTAssertEqual(calls.get(), 1)
    }

    func testExistingFrameworksDoNotRequireRawBinariesOrGit() throws {
        let root = try scratch()
        try Self.createFrameworks(root)
        try BuildOnlyPipeline.prepareANGLE(workspace: root, log: root.appendingPathComponent("build-only.log")) { _, _ in
            XCTFail("Must reuse already packaged frameworks")
            return 1
        }
    }

    func testMissingLocalSliceFailsBeforeAnyProcessAndNamesExactPath() throws {
        let root = try scratch(), calls = LockedBox(0)
        let missing = "vendor/out/xrsim/libGLESv2.framework/libGLESv2"
        try createInputs(root, omit: missing)
        let log = root.appendingPathComponent("build-only.log")
        XCTAssertThrowsError(try BuildOnlyPipeline.prepareANGLE(workspace: root, log: log) { _, _ in
            calls.set(calls.get() + 1)
            return 0
        }) { error in
            guard case BuildOnlyError.missingANGLEInputs(let paths) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(paths, [root.appendingPathComponent(missing)])
        }
        XCTAssertEqual(calls.get(), 0)
        XCTAssertTrue(try String(contentsOf: log).contains(missing))
    }

    func testEmptyLocalBinaryIsRejectedAndSuccessWithoutOutputsIsRejected() throws {
        let root = try scratch(), log = root.appendingPathComponent("build-only.log")
        try createInputs(root)
        let slice = root.appendingPathComponent("vendor/out/xros/libEGL.framework/libEGL")
        try Data().write(to: slice)
        XCTAssertThrowsError(try BuildOnlyPipeline.prepareANGLE(workspace: root, log: log) { _, _ in
            XCTFail("Empty dependency must fail before helper launch")
            return 0
        })
        try Data("restored fixture".utf8).write(to: slice)
        XCTAssertThrowsError(try BuildOnlyPipeline.prepareANGLE(workspace: root, log: log) { _, _ in 0 }) { error in
            guard case BuildOnlyError.missingANGLEFrameworks(let paths) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(paths.count, 2)
        }
    }

    func testAllStageOutputAndPythonTracebackRemainInTheLog() throws {
        let root = try scratch(), log = root.appendingPathComponent("build-only.log")
        let first = BuildOnlyCommand(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                    arguments: ["-c", "print('first stage stdout', flush=True)"], directory: root)
        try BuildOnlyPipeline.run(first, log: log)
        let failing = BuildOnlyCommand(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                      arguments: ["-c", "import sys; print('second stage stdout', flush=True); raise RuntimeError('fixture failure')"], directory: root)
        XCTAssertThrowsError(try BuildOnlyPipeline.run(failing, log: log))
        let text = try String(contentsOf: log)
        for expected in ["first stage stdout", "second stage stdout", "Traceback (most recent call last)", "RuntimeError: fixture failure", "[exit 0]", "[exit 1]"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        XCTAssertEqual(text.components(separatedBy: "Working directory:").count - 1, 2)
    }

    func testFailedXcodeStageIsRetainedInSeparateAndAggregateLogs() throws {
        let root = try scratch(), aggregate = root.appendingPathComponent("build-only.log")
        try Data("previous helper output\n".utf8).write(to: aggregate)
        let log = root.appendingPathComponent("xcodebuild.log")
        let command = BuildOnlyPipeline.compileCommand(project: root.appendingPathComponent("Fake.xcodeproj"), product: "Fake", derivedData: root.appendingPathComponent("derived"))
        XCTAssertThrowsError(try BuildOnlyPipeline.run(command, log: log, aggregateLog: aggregate) { _, output in
            try Self.append("error: simulated compiler failure\n", log: output)
            return 65
        })
        let combined = try String(contentsOf: aggregate)
        XCTAssertTrue(combined.hasPrefix("previous helper output\n"))
        XCTAssertTrue(combined.contains(try String(contentsOf: log)))
        XCTAssertTrue(combined.contains("[exit 65]"))
    }

    func testLaunchFailureKeepsPreviousLogsAndRecordsError() throws {
        let root = try scratch(), log = root.appendingPathComponent("build-only.log")
        try Data("earlier stage\n".utf8).write(to: log)
        let command = BuildOnlyCommand(executable: root.appendingPathComponent("missing/python3"), arguments: [], directory: root)
        XCTAssertThrowsError(try BuildOnlyPipeline.run(command, log: log))
        let text = try String(contentsOf: log)
        XCTAssertTrue(text.hasPrefix("earlier stage\n"))
        XCTAssertTrue(text.contains("Launch failed:"))
    }

    func testProductDiscoveryCapturesStdoutStderrAndRejectsPythonFailure() throws {
        let root = try scratch(), log = root.appendingPathComponent("build-only.log")
        let script = root.appendingPathComponent("targets.py")
        try "import sys\nprint('diagnostic on stderr', file=sys.stderr)\nprint('FakeProduct')\n"
            .write(to: script, atomically: true, encoding: .utf8)
        XCTAssertEqual(try BuildOnlyPipeline.resolveProduct(visionos: root, target: "re4", log: log), "FakeProduct")
        try "raise RuntimeError('product discovery fixture failure')\n".write(to: script, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try BuildOnlyPipeline.resolveProduct(visionos: root, target: "re4", log: log)) { error in
            guard case BuildOnlyError.commandFailed = error else { return XCTFail("\(error)") }
        }
        let text = try String(contentsOf: log)
        for expected in ["diagnostic on stderr", "FakeProduct", "Traceback (most recent call last)", "RuntimeError: product discovery fixture failure", "[exit 1]"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
    }

    func testGenericVisionOSCompileDoesNotUseDeviceOrInstallOperations() throws {
        let project = URL(fileURLWithPath: "/isolated/visionos/Fake.xcodeproj")
        let output = URL(fileURLWithPath: "/isolated/derived")
        let command = BuildOnlyPipeline.compileCommand(project: project, product: "Fake",
                                                       derivedData: output,
                                                       environment: ["KLEPTON_TARGET": "batman"])
        XCTAssertEqual(command.executable.path, "/usr/bin/xcodebuild")
        XCTAssertTrue(command.arguments.contains("generic/platform=visionOS"))
        XCTAssertTrue(command.arguments.contains("build"))
        XCTAssertFalse(command.arguments.contains("device"))
        XCTAssertFalse(command.arguments.contains("install"))
        XCTAssertFalse(command.arguments.contains("stage_assets.sh"))
        XCTAssertNil(command.environment["KLEPTON_DEVICE"])

        let invocationCount = LockedBox(0)
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("build-only-test-\(UUID().uuidString).log")
        try BuildOnlyPipeline.run(command, log: log) { observed, _ in
            invocationCount.set(invocationCount.get() + 1)
            XCTAssertEqual(observed, command)
            XCTAssertEqual(observed.executable.lastPathComponent, "xcodebuild")
            XCTAssertFalse(observed.arguments.contains { $0.contains("devicectl") || $0.contains("stage_assets") })
            return 0
        }
        XCTAssertEqual(invocationCount.get(), 1, "build-only launches exactly the generic compiler command")
        XCTAssertFalse(BuildOnlyPipeline.isSafe(BuildOnlyCommand(
            executable: URL(fileURLWithPath: "/toolchain/visionos/run.sh"), arguments: ["device"], directory: project)))
        XCTAssertFalse(BuildOnlyPipeline.isSafe(BuildOnlyCommand(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["stage_assets.sh"], directory: project)))
        XCTAssertFalse(BuildOnlyPipeline.isSafe(BuildOnlyCommand(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"), arguments: ["install"], directory: project)))
        XCTAssertFalse(BuildOnlyPipeline.isSafe(BuildOnlyCommand(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"), arguments: ["build"], directory: project,
            environment: ["KLEPTON_DEVICE": "should-never-be-inherited"])))
        let unsafe = BuildOnlyCommand(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                      arguments: ["stage_assets.py"], directory: project)
        let shouldNotRun = LockedBox(false)
        XCTAssertThrowsError(try BuildOnlyPipeline.run(unsafe, log: log) { _, _ in
            shouldNotRun.set(true)
            return 0
        })
        XCTAssertFalse(shouldNotRun.get(), "the command guard rejects staging before launching any process")
    }

    func testLocalVariantBuildOnlyJobDoesNotIncludeAccountFetchStageOrInstall() {
        XCTAssertEqual(InstallStep.localAPKBuildOnly, [.buildOnly])
        XCTAssertFalse(InstallStep.localAPKBuildOnly.contains(.account))
        XCTAssertFalse(InstallStep.localAPKBuildOnly.contains(.fetch))
        XCTAssertFalse(InstallStep.localAPKBuildOnly.contains(.stage))
        XCTAssertFalse(InstallStep.localAPKBuildOnly.contains(.build))
    }

    func testBuildOnlyCompatibilityUsesKleptonAliasAndAPKNameForResidentEvil() throws {
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let recipe = try RecipeStore(directory: recipes).load(id: "store-2637179839719680")
        XCTAssertEqual(recipe.toolchain.target, "x2637179839719680", "reproduces the original unrecognized-target failure")
        XCTAssertEqual(recipe.files.first(where: { $0.role == "apk" })?.localName, "x2637179839719680.apk")
        let compatible = KleptonRecipeCompatibility.resolve(recipe)
        XCTAssertEqual(compatible.toolchain.target, "re4")
        XCTAssertEqual(compatible.files.first(where: { $0.role == "apk" })?.localName, "re4.apk")
        XCTAssertEqual(compatible.id, recipe.id)
        XCTAssertEqual(compatible.package, recipe.package)
        XCTAssertEqual(compatible.versionCode, recipe.versionCode)
        XCTAssertEqual(compatible.files.filter { $0.role != "apk" }, recipe.files.filter { $0.role != "apk" })
        let command = BuildOnlyPipeline.compileCommand(
            project: URL(fileURLWithPath: "/isolated/visionos/KleptonArkham.xcodeproj"),
            product: "KleptonArkham", derivedData: URL(fileURLWithPath: "/isolated/derived"),
            environment: ["KLEPTON_TARGET": compatible.toolchain.target])
        XCTAssertEqual(command.environment["KLEPTON_TARGET"], "re4")
        XCTAssertTrue(command.arguments.contains("generic/platform=visionOS"))
        XCTAssertFalse(command.arguments.contains("install"))
        XCTAssertFalse(command.arguments.contains("stage_assets.sh"))
        XCTAssertNil(command.environment["KLEPTON_DEVICE"])
    }

    func testCompatibilityLeavesBatmanAndOtherTargetsUnchanged() throws {
        let recipes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
        let batman = try RecipeStore(directory: recipes).load(id: "batman")
        let untouched = try RecipeStore(directory: recipes).load(id: "store-2637179839719680")
        XCTAssertEqual(KleptonRecipeCompatibility.resolve(batman).toolchain.target, batman.toolchain.target)
        XCTAssertEqual(KleptonRecipeCompatibility.resolve(untouched).toolchain.target, "re4")
        XCTAssertEqual(KleptonRecipeCompatibility.resolve(untouched).files, untouched.files.map { file in
            var expected = file
            if expected.role == "apk", expected.localName == "x2637179839719680.apk" {
                expected.localName = "re4.apk"
            }
            return expected
        })
    }
}
