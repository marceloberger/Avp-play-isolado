import AVPPlayCore
import SwiftUI

/// A truthful device state derived only from the last device inventory. Unknown is kept separate from not installed.
enum IsolatedRemoteCompanionState: Equatable {
    case unknown
    case notInstalled
    case current(version: String)
    case updateAvailable(installed: String)
    case newerThanBundled(installed: String)

    static func resolve(installedVersions: [String: String]?, bundleID: String, bundledVersion: String) -> Self {
        guard let installedVersions else { return .unknown }
        guard let installed = installedVersions[bundleID] else { return .notInstalled }
        guard installed != "?" else { return .current(version: installed) }
        if Updater.isNewer(bundledVersion, than: installed) { return .updateAvailable(installed: installed) }
        if Updater.isNewer(installed, than: bundledVersion) { return .newerThanBundled(installed: installed) }
        return .current(version: installed)
    }

    var title: String {
        switch self {
        case .unknown: "Device not reachable"
        case .notInstalled: "Not installed"
        case .current: "On the Vision Pro"
        case .updateAvailable: "Update available"
        case .newerThanBundled: "Installed version is newer"
        }
    }
    var installed: Bool {
        switch self {
        case .unknown, .notInstalled: false
        case .current, .updateAvailable, .newerThanBundled: true
        }
    }
    var symbol: String {
        switch self {
        case .unknown: "wifi.slash"
        case .notInstalled: "circle.dashed"
        case .current: "checkmark.circle.fill"
        case .updateAvailable: "arrow.up.circle.fill"
        case .newerThanBundled: "exclamationmark.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .unknown, .notInstalled: .secondary
        case .current: .green
        case .updateAvailable, .newerThanBundled: .orange
        }
    }
    var description: String {
        switch self {
        case .unknown: "The Vision Pro is not reachable right now. Check Setup and refresh the device inventory."
        case .notInstalled: "AVP Play Remote Isolado is not installed on the selected Vision Pro."
        case .current(let version): "Installed, version \(version). The bundled isolated client is version \(IsolatedRemoteBuild.bundledVersion)."
        case .updateAvailable(let installed): "Installed, version \(installed). The bundled isolated client is version \(IsolatedRemoteBuild.bundledVersion)."
        case .newerThanBundled(let installed): "Installed version \(installed) is newer than the bundled isolated source (\(IsolatedRemoteBuild.bundledVersion)). Reinstall is disabled to avoid replacing it with an older build."
        }
    }
}

extension AppModel {
    var isolatedRemoteCompanionState: IsolatedRemoteCompanionState {
        let versions = installedApps.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.bundleIdentifier, $0.version ?? "?") }) }
        return IsolatedRemoteCompanionState.resolve(installedVersions: versions, bundleID: IsolatedRemoteBuild.bundleID,
                                             bundledVersion: IsolatedRemoteBuild.bundledVersion)
    }

    var isolatedRemoteCompanionShown: Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = query.isEmpty || "avp play remote".contains(query) || "remote control".contains(query)
        let excluded = (filterCommunity && !filterVerified) || (filterInstalled && !isolatedRemoteCompanionState.installed)
            || filterDownloaded || filterFavourites || filterFavouritesMissing || filterMixedReality
        return matches && !excluded
    }
}

enum IsolatedRemoteCompanion {
    static let route = "isolated-avp-play-remote"
    static let title = "AVP Play Remote"
}

enum IsolatedRemoteNavigation {
    enum Destination: Equatable { case companionDetail, game(String) }
    static func destination(for route: String) -> Destination {
        route == IsolatedRemoteCompanion.route ? .companionDetail : .game(route)
    }
}

struct IsolatedRemoteCompanionCover: View {
    var body: some View {
        Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit).overlay {
            LinearGradient(colors: [Color(red: 0.16, green: 0.36, blue: 0.95), Color(red: 0.42, green: 0.18, blue: 0.78)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "visionpro").font(.system(size: 54, weight: .light))
                        Text(IsolatedRemoteCompanion.title).font(.title3.bold())
                    }.foregroundStyle(.white)
                }
        }.clipped()
    }
}

struct IsolatedRemoteVerifiedBadge: View {
    var body: some View {
        Label("Verified source", systemImage: "checkmark.seal.fill")
            .font(.caption.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
            .help("The bundled upstream source archive and Isolated identity patch are SHA-256 verified. This does not claim that this Isolated client has been tested on your Vision Pro.")
    }
}

struct IsolatedRemoteCompanionStatus: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        let state = model.isolatedRemoteCompanionState
        Label(state.title, systemImage: state.symbol).font(.caption.weight(.medium)).foregroundStyle(state.color)
    }
}

struct IsolatedRemoteCompanionCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false

    var body: some View {
        NavigationLink(value: IsolatedRemoteCompanion.route) {
            VStack(alignment: .leading, spacing: 0) {
                IsolatedRemoteCompanionCover()
                    .overlay(alignment: .topTrailing) { IsolatedRemoteVerifiedBadge().padding(8) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(IsolatedRemoteCompanion.title).font(.headline).lineLimit(1)
                    IsolatedRemoteCompanionStatus()
                    Label("Remote control for this Mac", systemImage: "appletvremote.gen4")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(hovering ? 0.22 : 0.1), radius: hovering ? 10 : 4, y: 2)
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityIdentifier("remote.companionCard")
    }
}

struct IsolatedRemoteCompanionDetail: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var remote: RemoteServer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                IsolatedRemoteCompanionCover().frame(maxHeight: 300).clipShape(RoundedRectangle(cornerRadius: 14))
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(IsolatedRemoteCompanion.title).font(.largeTitle.bold())
                        Text("Bundled version \(IsolatedRemoteBuild.bundledVersion) · source commit \(IsolatedRemoteBuild.sourceCommit.prefix(7))")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) { IsolatedRemoteCompanionStatus(); IsolatedRemoteVerifiedBadge() }
                    }
                    Spacer(minLength: 12)
                    Text(model.isolatedRemoteCompanionState.title).font(.headline)
                }
                Text("The remote control for AVP Play Isolado. It shows the library and Jobs on the Vision Pro; this Mac performs the requested work. The client is built from the bundled, hash-verified upstream source with an Isolated-only bundle identifier, Bonjour service, ports and keychain namespace.")
                    .fixedSize(horizontal: false, vertical: true)
                GroupBox("On the Vision Pro") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.isolatedRemoteCompanionState.description)
                        Text("App identifier: \(IsolatedRemoteBuild.bundleID)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("The Install action below uses only an existing compatible signing identity/profile. It does not create provisioning assets.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                IsolatedRemoteBuildSettings(detailPresentation: true)
                GroupBox("Getting Started") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Build and sign the Isolated client for the selected Vision Pro.")
                        Text("2. Enable Remote Control on this Mac and leave the Isolated server running.")
                        Text("3. Open AVP Play Remote on the headset, allow local network access and enter the pairing code shown on the Remote Control page.")
                        HStack {
                            Button("Open Remote Control") { model.section = .remote }
                                .accessibilityIdentifier("remote.companion.openControl")
                            Link("Source Code on GitHub", destination: URL(string: "https://github.com/myMartek/avp-play-remote")!)
                        }.padding(.top, 4)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            .padding(24).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle(IsolatedRemoteCompanion.title)
        .accessibilityIdentifier("remote.companionDetail")
    }
}

struct IsolatedRemoteCompanionSection: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Section("The app for the Vision Pro") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) { Text(IsolatedRemoteCompanion.title).font(.headline); IsolatedRemoteCompanionStatus() }
                    Text(model.isolatedRemoteCompanionState.description).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Installs only as \(IsolatedRemoteBuild.bundleID); no original AVP Play identity or Remote pairing data is reused.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                IsolatedRemoteVerifiedBadge()
            }
            NavigationLink("View AVP Play Remote details", value: IsolatedRemoteCompanion.route)
                .accessibilityIdentifier("remote.companion.details")
        }
    }
}
