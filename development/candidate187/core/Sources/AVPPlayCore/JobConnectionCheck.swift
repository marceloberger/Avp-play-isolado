import Foundation

/// Read queries only. Never prepares a Job, writes receipts, copies files or runs a game.
public enum JobConnectionCheck {
    public static func run(job: Job, store: ContentStore, control: DeviceControl = DeviceControl()) throws -> String {
        let device = try control.pick(udid: job.request.device)
        guard device.connected else { throw DeviceError.tool("Vision Pro selecionado está desconectado do CoreDevice.") }
        guard job.remaining.contains(.stage), !job.remaining.contains(.build) else {
            return "Vision Pro conectado e acessível. Nenhuma etapa foi executada. Use Resume manualmente quando desejar."
        }
        guard let bundle = job.request.bundleId, !bundle.isEmpty else {
            throw DeviceError.tool("Bundle ID da instalação não está definido neste Job; identidade não confirmada.")
        }
        let directory = store.directory(for: job.recipe)
        func identity() throws -> String {
            let current = try control.pick(udid: device.udid)
            let app = try control.installedApp(device: current, bundle: bundle)
            return try InstallationContent.installationScope(device: current, bundle: bundle, apps: [app],
                scopeFile: directory.appendingPathComponent(".stage-container.json"),
                receipts: directory.appendingPathComponent(".stage-verification.json"))
        }
        let scope = try identity()
        let root = try control.checkedFiles(device: device, bundle: bundle, subdirectory: "Documents")
        var missing: [String] = []
        for file in job.recipe.files where file.role == "apk" {
            if let path = StagePlan.destination(for: file), path.hasPrefix("Documents/"),
               (path as NSString).deletingLastPathComponent == "Documents",
               !root.contains(where: { !$0.isDirectory && $0.relativePath == (path as NSString).lastPathComponent }) {
                missing.append(path)
            }
        }
        if job.recipe.files.contains(where: { $0.role == "apk" }) {
            let target = KleptonRecipeCompatibility.resolve(job.recipe).toolchain.target
            guard Recipe.isSafeName(target) else { throw RecipeError.invalid("invalid runtime tree") }
            let folder = "Documents/\(target)"
            // Query the failing path too. Its absence is accepted only with ancestor evidence.
            let files = try control.checkedFiles(device: device, bundle: bundle, subdirectory: folder)
            for name in ["AndroidManifest.xml", "apktool.yml"] where !files.contains(where: { !$0.isDirectory && $0.relativePath == name }) {
                missing.append("\(folder)/\(name)")
            }
        }
        guard try identity() == scope else {
            throw DeviceError.tool("Identidade da instalação mudou durante Check Again; resultado inconclusivo.")
        }
        let detail = missing.isEmpty
            ? "Listagem remota disponível. Esta consulta não valida todos os bytes do Stage."
            : "Listagem remota disponível. Ausência confirmada por listagem: \(missing.joined(separator: ", "))."
        return "Conexão verificada: Vision Pro acessível, identidade da instalação confirmada. \(detail) Stage continua pendente. Nenhum arquivo transferido. Use Resume manualmente quando desejar."
    }
}
