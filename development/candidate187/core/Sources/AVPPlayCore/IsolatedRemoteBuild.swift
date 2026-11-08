import Foundation

/// Remote construction is a separate, explicitly invoked operation. Never a game Job or startup hook.
public enum IsolatedRemoteBuild {
    public static let sourceCommit = "2df4c8cd2bd4627bd18e799f85b2688dac363185"
    public static let bundleID = "io.github.mymartek.avpplay.modified.candidate187.remote"
    /// Version in the SHA-256 verified source archive shipped with build 162. This is not the latest GitHub release.
    public static let bundledVersion = "1.0.0"
    public static func command(source: URL, output: URL, team: String) throws -> BuildOnlyCommand {
        guard team.count == 10,team.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber)}) else {
            throw RecipeError.invalid("A valid Apple team is required; no profile or certificate will be created.")
        }
        return BuildOnlyCommand(executable:URL(fileURLWithPath:"/usr/bin/xcodebuild"),arguments:[
            "-project",source.appendingPathComponent("AVPPlayRemote.xcodeproj").path,"-scheme","AVPPlayRemote",
            "-configuration","Release","-destination","generic/platform=visionOS","-derivedDataPath",output.path,
            "DEVELOPMENT_TEAM=\(team)","PRODUCT_BUNDLE_IDENTIFIER=\(bundleID)",
            "CODE_SIGNING_ALLOWED=NO","CODE_SIGNING_REQUIRED=NO","CODE_SIGN_IDENTITY=","build"
        ],directory:source)
    }
    /// Adapt only a fresh, verified source extraction; never edit the bundled archive or an installed client.
    static func isolateSource(_ source: URL) throws {
        let replacements = [
            "Sources/Shared/RemoteProtocol.swift": [
                "_avpplay-iso._tcp": RemoteWire.serviceType,
                "47821": String(RemoteWire.defaultPort), "47822": String(RemoteWire.pairPort),
                "avpplay-isolated-remote-pair-v1": "avpplay-candidate187-remote-pair-v1"],
            "Sources/Model/Support.swift": ["io.github.mymartek.avpplay.modified.remote": bundleID],
            "Sources/Info.plist": ["_avpplay-iso._tcp": RemoteWire.serviceType]
        ]
        for (relative, values) in replacements {
            let file = source.appendingPathComponent(relative)
            guard file.resolvingSymlinksInPath().path.hasPrefix(source.resolvingSymlinksInPath().path + "/") else {
                throw PackageError.contentMismatch
            }
            var text = try String(contentsOf: file)
            for (old, new) in values {
                guard text.contains(old) else { throw PackageError.contentMismatch }
                text = text.replacingOccurrences(of: old, with: new)
            }
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }
    public static func build(resources: URL, workspace: URL, team: String) throws -> URL {
        guard !FileManager.default.fileExists(atPath:workspace.path) else { throw BuildOnlyError.workspaceExists(workspace) }
        let archive=resources.appendingPathComponent("source.tar.gz")
        let expected=try String(contentsOf:resources.appendingPathComponent("source.sha256")).split(separator:" ").first.map(String.init)
        guard try Hashing.sha256(of:archive)==expected else { throw PackageError.checksumMismatch }
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        _=try Toolchain.capture(["/usr/bin/tar","-xzf",archive.path,"-C",workspace.path])
        let source=workspace.appendingPathComponent("source")
        try isolateSource(source)
        let command=try command(source:source,output:workspace.appendingPathComponent("DerivedData"),team:team)
        try BuildOnlyPipeline.run(command,log:workspace.appendingPathComponent("build.log"))
        let app=workspace.appendingPathComponent("DerivedData/Build/Products/Release-xros/AVPPlayRemote.app")
        let info=try ReusableBuild.infoPlist(app.appendingPathComponent("Info.plist"))
        guard info["CFBundleIdentifier"] as? String == bundleID else { throw PackageError.contentMismatch }
        return app
    }
    public static func sign(app: URL, team: String, device: Device, output: URL) throws -> ExistingAppSigner.SignedApp {
        let artifact=ReusableBuild(app:app,workspace:app.deletingLastPathComponent(),sourceJobID:"isolated-remote",
                                  bundleID:bundleID,files:try ReusableBuild.inventory(app))
        // Uses only existing compatible identities/profiles. No provisioning registration or installation.
        return try ExistingAppSigner.sign(artifact,team:team,device:device,outputRoot:output)
    }
    /// Only invoked by the separate confirmation button. Does not install any game or launch an app.
    public static func installSigned(app: URL, device: Device) throws {
        let info=try ReusableBuild.infoPlist(app.appendingPathComponent("Info.plist"))
        guard info["CFBundleIdentifier"] as? String == bundleID else { throw PackageError.contentMismatch }
        _=try Toolchain.capture(["/usr/bin/codesign","--verify","--deep","--strict",app.path])
        let control=DeviceControl()
        try control.install(app,device:device)
        _=try control.installedApp(device:device,bundle:bundleID)
    }
    public static func latestTag() async throws -> String {
        let url=URL(string:"https://api.github.com/repos/myMartek/avp-play-remote/releases/latest")!
        let (data,response)=try await URLSession.shared.data(from:url)
        guard (response as? HTTPURLResponse)?.statusCode==200,
              let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let tag=value["tag_name"] as? String, tag.range(of:#"^v?\d+(\.\d+){1,3}$"#,options:.regularExpression) != nil else {
            throw RecipeError.invalid("Cannot validate official Remote release metadata.")
        }
        return tag
    }
}
