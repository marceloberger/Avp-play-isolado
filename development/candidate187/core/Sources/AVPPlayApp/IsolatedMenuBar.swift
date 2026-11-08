import AppKit
import AVPPlayCore
import ServiceManagement
import SwiftUI

extension AppModel {
    var isolatedMenuStatus: MenuBarStatus {
        let running = runningJob.flatMap { id in jobs.first { $0.id == id } }
        let progress = runningJob.flatMap { copyProgress[$0] }
        return MenuBarStatus(
            job: running.map { .init(title: $0.recipe.title, step: progress?.step ?? $0.current,
                                    done: progress?.done, total: progress?.total) },
            waiting: queued.count, failed: jobs.filter { $0.state == .failed }.count,
            deviceName: device?.name, remote: .off, renewal: nil)
    }
}

struct IsolatedMenuLabel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let status = model.isolatedMenuStatus
        HStack {
            Image(systemName: status.needsAttention ? "exclamationmark.triangle" : "visionpro")
            if let percent = status.percent { Text("\(percent) %").monospacedDigit() }
        }
        .onAppear { AppDelegate.openMain = { openWindow(id: "main") } }
    }
}

struct IsolatedMenuPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var remote: RemoteServer
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let status = model.isolatedMenuStatus
        VStack(alignment: .leading, spacing: 10) {
            Text("AVP Play Isolado").font(.headline)
            Text(status.jobLine)
            if let detail = status.jobDetail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            if let fraction = status.fraction { ProgressView(value: fraction) }
            Label(status.deviceLine, systemImage: "visionpro")
            Label(remote.enabled ? "Remote Isolado: \(remote.connected.count) conectado(s)" : "Remote Isolado desligado", systemImage: "network")
            HStack {
                Button(L("Open Window", "Fenster öffnen")) { show() }
                Button(L("Jobs", "Aufträge")) { model.section = .jobs; show() }
                Button(L("Check Again", "Neu prüfen")) { model.refresh() }.disabled(model.refreshing)
            }
            Divider()
            Button(L("Quit", "Beenden")) { NSApp.terminate(nil) }
        }
        .padding(14).frame(width: 360)
    }
    private func show() {
        openWindow(id: "main")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct IsolatedMenuSettings: View {
    @AppStorage(MenuBarPreferences.showKey) private var show = true
    @AppStorage(MenuBarPreferences.keepRunningKey) private var keepRunning = false
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var problem: String?
    var body: some View {
        Section(L("Menu Bar", "Menüleiste")) {
            Toggle(L("Show AVP Play Isolado in the menu bar", "AVP Play Isolado in der Menüleiste zeigen"), isOn: $show)
            Toggle(L("Keep running when the window is closed", "Nach dem Schließen des Fensters weiterlaufen"), isOn: $keepRunning)
                .disabled(!show)
            Text(L("Jobs continue while the window is closed only when this option is enabled. Quit always exits the app.",
                   "Aufträge laufen bei geschlossenem Fenster nur mit dieser Option weiter. Beenden schließt die App immer."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(L("Open at login", "Bei der Anmeldung öffnen"), isOn: Binding(get: { loginOn }, set: { on in
                do {
                    if on { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    problem = SMAppService.mainApp.status == .requiresApproval
                        ? L("Allow this app in System Settings > General > Login Items.", "Diese App in den Systemeinstellungen > Allgemein > Anmeldeobjekte erlauben.") : nil
                } catch { problem = error.localizedDescription }
                loginOn = SMAppService.mainApp.status == .enabled
            }))
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
        }
    }
}
