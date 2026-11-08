import AppKit
import AVPPlayCore
import SwiftUI

/// Apple build/signing and local toolchain setup. The local workflow has no Meta account setup.
struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var signingInventory: AppleSigningInventory.Snapshot?
    @State private var scanningSigning = false
    @State private var scannedTeam: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Local import and analysis work without an account or headset. Building needs Xcode and the toolchain; signing needs an Apple developer team, and installing also needs a reachable Vision Pro.",
                       "Lokaler Import und Analyse funktionieren ohne Konto und Headset. Zum Bauen braucht es Xcode und die Toolchain; zum Signieren ein Apple-Entwicklerteam und zum Installieren außerdem eine erreichbare Vision Pro."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                CheckCard(title: "Xcode", state: model.xcodeProblem == nil ? (model.xcodeText == nil ? .checking : .ok) : .missing,
                          detail: model.xcodeProblem ?? model.xcodeText ?? L("Checking…", "Wird geprüft …")) {
                    if model.xcodeProblem != nil {
                        Link(L("Open Xcode in the App Store", "Xcode im App Store öffnen"), destination: URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!)
                    }
                }

                CheckCard(title: "Vision Pro", state: model.device == nil ? (model.devices.count > 1 ? .warning : .missing) : (model.deviceProblem == nil ? .ok : .warning),
                          detail: model.device.map { d in model.deviceProblem ?? L("\(d.name) with visionOS \(d.osVersion) is reachable", "\(d.name) mit visionOS \(d.osVersion) ist erreichbar")
                              + (d.transport.map { L(" over \($0.text).", " über \($0.text).") } ?? ".") }
                              ?? model.deviceProblem ?? L("Not connected", "Nicht verbunden")) {
                    if model.devices.count > 1 {
                        Picker(L("Use this one", "Dieses benutzen"), selection: Binding(
                            get: { model.device?.udid ?? "" }, set: { model.chosenDevice = $0; model.refresh() })) {
                            if model.device == nil { Text(L("Choose…", "Auswählen…")).tag("") }
                            ForEach(model.devices, id: \.udid) { d in Text("\(d.name) · visionOS \(d.osVersion)").tag(d.udid) }
                        }.fixedSize()
                    }
                    if model.device == nil, model.devices.isEmpty, model.xcodeText != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Pair the Vision Pro in Xcode › Window › Devices and Simulators. Enable Developer Mode on the headset and keep it unlocked and reachable.",
                                   "Kopple die Vision Pro in Xcode › Window › Devices and Simulators. Aktiviere den Entwicklermodus und halte das Headset entsperrt und erreichbar."))
                        }.font(.callout).foregroundStyle(.secondary)
                        Button(L("Check Again", "Neu prüfen")) { model.refresh() }.controlSize(.small)
                    }
                }

                CheckCard(title: L("Apple Developer Team", "Apple-Entwicklerteam"), state: teamState, detail: teamDetail) {
                    HStack {
                        TextField(L("Team ID", "Team-ID"), text: $model.teamId)
                            .textFieldStyle(.roundedBorder).frame(width: 170)
                            .onChange(of: model.teamId) { _, value in
                                model.teamId = value.uppercased().filter { $0.isLetter || $0.isNumber }
                            }
                        if !model.teamCandidates.isEmpty {
                            Menu(L("Choose from Xcode", "Aus Xcode auswählen")) {
                                ForEach(model.teamCandidates) { team in
                                    Button("\(team.name) · \(team.id)\(team.free ? L(" (free)", " (kostenlos)") : "")") { model.teamId = team.id }
                                }
                            }
                        }
                    }
                    if model.usesFreeTeam { FreeAccountLimits() }
                    if AppleTeams.refusedAsPaid().contains(model.teamId) {
                        // Von Apple beim Bauen als „Personal Team“ gemeldet, obwohl Xcode es als bezahlt führte.
                        HStack {
                            Text(L("Apple treated this team as a free “Personal Team” when a game was built, so AVP Play builds for it as for a free one. After renewing the membership:",
                                   "Apple hat dieses Team beim Bauen eines Spiels als kostenloses „Personal Team“ behandelt; deshalb baut AVP Play dafür wie für ein kostenloses. Nach einer erneuerten Mitgliedschaft:"))
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(L("Treat as Paid Again", "Wieder als bezahlt behandeln")) {
                                AppleTeams.forgetFree(model.teamId)
                                model.refresh()
                            }
                            .controlSize(.small)
                        }
                    }
                    if model.teamCandidates.isEmpty {
                        Text(L("Sign in to your Apple ID in Xcode › Settings › Accounts, then refresh this page.",
                               "Melde deine Apple-ID in Xcode › Einstellungen › Accounts an und aktualisiere diese Seite."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Button(scanningSigning ? "Consultando assinatura Apple…" : "Atualizar certificados e perfis locais") {
                        refreshSigningInventory()
                    }
                    .disabled(scanningSigning || !model.teamValid)
                    Text("Consulta a equipe no Xcode, as identidades válidas no Keychain e os perfis deste Mac. Para emitir ou baixar perfis, use Xcode › Settings › Apple Accounts › Download Manual Profiles e atualize aqui. Nenhuma assinatura será executada.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let inventory = signingInventory, scannedTeam == model.teamId {
                        Text("\(inventory.identities.count) identidade(s) Apple Development válida(s) · \(inventory.profiles.count) perfil(is) autenticado(s) da equipe.")
                            .font(.callout)
                        if model.device == nil {
                            Text("Sem Vision Pro selecionado: a inclusão do dispositivo será conferida antes de assinar.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(inventory.profiles) { profile in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.applicationIdentifier).textSelection(.enabled)
                                    Text("Validade: \(profile.expires.formatted()) · Extended Virtual Addressing: \(profile.extendedAddressing ? "autorizado" : "ausente") · Low-Latency Streaming: \(profile.lowLatency ? "autorizado" : "ausente")")
                                    ForEach(profile.problems, id: \.self) { problem in Text(problem).foregroundStyle(.orange) }
                                }.font(.caption)
                            }
                            ForEach(inventory.errors, id: \.self) { error in Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                            Text("A compatibilidade com cada jogo continua exigindo Bundle ID, certificado, dispositivo e todos os entitlements correspondentes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                SteamCard()

                CheckCard(title: "Toolchain", state: model.toolchainText == nil ? .missing : .ok,
                          detail: model.toolchainText ?? L("Klepton 850 + TLS168 unavailable; operations are blocked without fallback.",
                                                            "Klepton 850 + TLS168 indisponível; operações bloqueadas sem fallback.")) {
                    Text(L("The toolchain translates compatible games for visionOS. Local preparation and build-only use files on this Mac.",
                           "Die Toolchain übersetzt kompatible Spiele für visionOS. Lokale Vorbereitung und Build-only verwenden Dateien auf diesem Mac."))
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Build177: somente Klepton 850 cc2856c + TLS168. Jobs antigos são preservados; 824 bloqueada.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle(L("Apple & Toolchain Setup", "Apple- und Toolchain-Einrichtung"))
    }

    private var teamState: CheckState {
        guard model.teamValid else { return .missing }
        return model.usesFreeTeam ? .warning : .ok
    }

    private var teamDetail: String {
        guard model.teamValid else { return L("A team is needed only for Apple signing and installation.", "Ein Team wird nur zum Signieren und Installieren mit Apple benötigt.") }
        if let team = model.team { return "\(team.name) (\(team.id))" }
        return L("Team \(model.teamId) is selected.", "Team \(model.teamId) ist ausgewählt.")
    }

    private func refreshSigningInventory() {
        guard !scanningSigning, model.teamValid else { return }
        scanningSigning = true
        let team = model.teamId
        let device = model.device?.udid
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                AppleSigningInventory.scan(team: team, device: device)
            }.value
            signingInventory = result
            scannedTeam = team
            if model.teamId == team { model.teamCandidates = result.teams }
            scanningSigning = false
        }
    }

}

enum CheckState { case ok, warning, missing, checking }

struct CheckCard<Actions: View>: View {
    let title: String
    let state: CheckState
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    switch state {
                    case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case .missing: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    case .checking: ProgressView().controlSize(.small)
                    }
                }.font(.title2).frame(width: 28)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.headline)
                    Text(detail).fixedSize(horizontal: false, vertical: true)
                    actions
                }
                Spacer(minLength: 0)
            }.padding(8)
        }
    }
}
