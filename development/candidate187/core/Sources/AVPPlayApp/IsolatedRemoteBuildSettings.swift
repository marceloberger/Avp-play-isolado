import AppKit
import AVPPlayCore
import SwiftUI

struct IsolatedRemoteBuildSettings: View {
    @EnvironmentObject var model: AppModel
    var detailPresentation = false
    @State private var busy = false
    @State private var unsigned: URL?
    @State private var signed: URL?
    @State private var message: String?

    var body: some View {
        Section(detailPresentation ? "On the Vision Pro" : "AVP Play Remote for the Vision Pro") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.isolatedRemoteCompanionState.description)
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Version \(IsolatedRemoteBuild.bundledVersion) · verified source commit \(IsolatedRemoteBuild.sourceCommit.prefix(7))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(actionTitle) { beginInstall() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(busy || installBlocker != nil)
                    .accessibilityIdentifier("remote.companion.install")
            }
            if let blocker = installBlocker { Text(blocker).font(.callout).foregroundStyle(.secondary) }
            if busy { ProgressView("Preparing the Isolated client…") }
            if let message { Text(message).font(.caption).textSelection(.enabled) }

            DisclosureGroup("Advanced: build, sign, and install separately") {
                Button("Build Isolated client without installing") { buildUnsigned() }
                    .disabled(busy || !model.teamValid || model.runningJob != nil || model.device == nil || isDowngrade)
                    .accessibilityIdentifier("remote.companion.build")
                if let unsigned {
                    Button("Sign with an existing certificate and profile") { sign(unsigned) }
                        .disabled(busy || model.device == nil)
                        .accessibilityIdentifier("remote.companion.sign")
                }
                if let signed {
                    Button("Install this signed Isolated client…") { confirmAndInstall(signed) }
                        .disabled(busy || model.device == nil || isDowngrade)
                }
            }
            Button("Check the latest official Remote release") {
                Task {
                    do {
                        let tag = try await IsolatedRemoteBuild.latestTag()
                        message = "Latest official upstream tag: \(tag). This Isolated client remains pinned to v\(IsolatedRemoteBuild.bundledVersion) until that release receives an audited Isolated package. No download or install was started."
                    } catch { message = "Could not query the official release: \(error)" }
                }
            }.disabled(busy)
        }
    }

    private var actionTitle: String {
        switch model.isolatedRemoteCompanionState {
        case .updateAvailable: "Update"
        case .current: "Install Again"
        case .newerThanBundled: "Newer version installed"
        case .unknown, .notInstalled: "Install"
        }
    }

    private var isDowngrade: Bool {
        if case .newerThanBundled = model.isolatedRemoteCompanionState { return true }
        return false
    }

    private var installBlocker: String? {
        if isDowngrade { return "The installed client is newer than the verified bundled source; reinstall is blocked to prevent a downgrade." }
        if model.xcodeProblem != nil { return "Xcode is unavailable. See Setup for the required installation instructions." }
        if !model.teamValid { return "Set a valid Apple team in Setup. This flow will use existing signing credentials only." }
        if model.device == nil { return model.deviceProblem ?? "The selected Vision Pro is not reachable." }
        if model.runningJob != nil { return "Wait for the current game Job to finish before preparing the Remote client." }
        return nil
    }

    private func beginInstall() {
        guard installBlocker == nil, let device = model.device else { return }
        let alert = NSAlert()
        alert.messageText = "Prepare and install AVP Play Remote Isolado?"
        alert.informativeText = "The app will build the pinned, verified source, sign it with an existing compatible certificate/profile, then ask again before installing only \(IsolatedRemoteBuild.bundleID) on \(device.name). No provisioning profile will be created, and the client will not be opened."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let resources = Bundle.main.resourceURL?.appendingPathComponent("optional-remote")
        guard let resources else { message = "The verified Isolated Remote source is missing from this app bundle."; return }
        let team = model.teamId
        let workspace = DataLocation.base.appendingPathComponent("remote-builds/\(UUID().uuidString)")
        let output = workspace.appendingPathComponent("signed", isDirectory: true)
        busy = true
        Task {
            let result = await Task.detached {
                Result {
                    let unsignedApp = try IsolatedRemoteBuild.build(resources: resources, workspace: workspace, team: team)
                    return try IsolatedRemoteBuild.sign(app: unsignedApp, team: team, device: device, output: output)
                }
            }.value
            busy = false
            switch result {
            case .success(let artifact):
                signed = artifact.app
                message = "Isolated client built and signed from the verified bundled source."
                confirmAndInstall(artifact.app)
            case .failure(let error):
                message = "Install preparation stopped: \(error). No new certificate/profile was requested and nothing was installed."
            }
        }
    }

    private func buildUnsigned() {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("optional-remote") else { return }
        let team = model.teamId
        let workspace = DataLocation.base.appendingPathComponent("remote-builds/\(UUID().uuidString)")
        busy = true
        Task {
            let result = await Task.detached { Result { try IsolatedRemoteBuild.build(resources: resources, workspace: workspace, team: team) } }.value
            switch result {
            case .success(let app): unsigned = app; signed = nil; message = "Built without signing or installing: \(app.path)"
            case .failure(let error): message = "Build stopped: \(error)"
            }
            busy = false
        }
    }

    private func sign(_ app: URL) {
        guard let device = model.device else { message = "Select the Vision Pro in Setup. Nothing was installed."; return }
        let team = model.teamId
        let output = app.deletingLastPathComponent().appendingPathComponent("signed-\(UUID().uuidString)")
        busy = true
        Task {
            let result = await Task.detached { Result { try IsolatedRemoteBuild.sign(app: app, team: team, device: device, output: output) } }.value
            switch result {
            case .success(let artifact): signed = artifact.app; message = "Signed Isolated client: \(artifact.app.path). Not installed."
            case .failure(let error): message = "Signing stopped: \(error). No profile or certificate was created."
            }
            busy = false
        }
    }

    private func confirmAndInstall(_ app: URL) {
        guard let device = model.device else { return }
        let alert = NSAlert()
        alert.messageText = "Install AVP Play Remote Isolado?"
        alert.informativeText = "Installs or replaces only \(IsolatedRemoteBuild.bundleID) on \(device.name). It does not launch the client or modify games."
        alert.addButton(withTitle: "Install Remote")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        Task {
            let result = await Task.detached { Result { try IsolatedRemoteBuild.installSigned(app: app, device: device) } }.value
            switch result {
            case .success: message = "Isolated Remote installed and identity confirmed; the app was not opened."; model.refresh()
            case .failure(let error): message = "Installation could not be confirmed: \(error)"
            }
            busy = false
        }
    }
}
