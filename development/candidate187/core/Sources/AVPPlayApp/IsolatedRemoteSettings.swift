import AVPPlayCore
import SwiftUI

struct IsolatedRemoteSettings: View {
    @EnvironmentObject var remote: RemoteServer

    var body: some View {
        Section("Remote Control") {
            Toggle("Enable Remote Control", isOn: Binding(get: { remote.enabled }, set: { remote.setEnabled($0) }))
            Text("The local network connection uses TLS. This Isolated client has its own app identity, Bonjour service, ports and pairings; it does not share credentials with the official AVP Play app. Game actions still require confirmation on this Mac.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if remote.enabled {
                if let problem = remote.problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if let paused = remote.pairingPausedUntil, paused > Date() {
                    Label("Pairing is paused until \(paused.formatted(date: .omitted, time: .shortened)).", systemImage: "lock.fill")
                        .foregroundStyle(.orange)
                } else {
                    LabeledContent("Pairing Code") {
                        Text(remote.code.enumerated().map { $0.offset == 3 ? " \($0.element)" : String($0.element) }.joined())
                            .font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                    }
                    Button("New Code") { remote.newCode() }
                    Text("Open AVP Play Remote on the Vision Pro, allow local network access, and enter this code. It authorizes the initial pairing only.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                if RemoteServer.addresses().isEmpty {
                    Text("No local network address is available. Connect this Mac and the Vision Pro to the same local network.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Manual Address") {
                        Text(RemoteServer.addresses().joined(separator: "\n"))
                            .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                }

                if remote.peers.isEmpty {
                    Text("Paired remotes will appear here. Keep the Mac and Vision Pro on the same local network.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(remote.peers) { peer in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(peer.name).font(.headline)
                                Label(remote.connected.contains(peer.clientId) ? "Connected now" : "Not connected",
                                      systemImage: remote.connected.contains(peer.clientId) ? "checkmark.circle.fill" : "circle")
                                    .font(.callout)
                                    .foregroundStyle(remote.connected.contains(peer.clientId) ? .green : .secondary)
                                Text("Paired \(peer.paired.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let lastSeen = peer.lastSeen {
                                    Text("Last connected \(lastSeen.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { remote.remove(peer) }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            Text("Turn on ‘Keep running when the window is closed’ in the menu bar settings to keep the connection available after closing the window.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        IsolatedRemoteCompanionSection()
        IsolatedMenuSettings()
    }
}
