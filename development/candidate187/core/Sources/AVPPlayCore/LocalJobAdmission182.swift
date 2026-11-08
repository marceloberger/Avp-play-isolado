import Foundation
import Darwin

extension JobStore {
    /// Admission is separate from Resume: it never rewrites an existing Job.
    /// Lock failure is closed, including permission errors and symlinked lock files.
    public func admitLocal182(_ proposed: Job) throws -> (job: Job, inserted: Bool) {
        guard proposed.request.localAPKVariantID != nil else { return (try enqueue(proposed), true) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent(".admission182.lock").path,
                              O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw JobError.cannotResume("Não foi possível bloquear a fila local; nenhum Job criado.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw JobError.cannotResume("Outra admissão está em andamento; tente novamente. Nenhum Job criado.")
        }
        defer { flock(descriptor, LOCK_UN) }
        if let existing = all().first(where: {
            $0.recipe.id == proposed.recipe.id && $0.request.localAPKVariantID != nil
                && ($0.state == .waiting || $0.state == .running)
        }) {
            guard existing.request == proposed.request, existing.steps == proposed.steps,
                  try LocalAPKBuildEvidence.recipeHash(existing.recipe) == LocalAPKBuildEvidence.recipeHash(proposed.recipe) else {
                throw JobError.cannotResume("Já existe um Job ativo para este jogo com outra configuração: \(existing.id). Nenhum duplicado criado.")
            }
            return (existing, false)
        }
        return (try enqueue(proposed), true)
    }
}

extension Job {
    public var localCompletion182: String {
        guard state == .finished else { return "Operação incompleta; consulte o Job e retome a etapa pendente." }
        if steps.contains(.buildOnly) { return "Build only concluído no Mac; instalação e Stage pendentes." }
        if steps.contains(.stage) && completed.contains(.stage) { return "Stage concluído: arquivos obrigatórios e selecionados verificados no dispositivo." }
        if completed.contains(.build) { return "Aplicativo instalado; Stage obrigatório ainda pendente." }
        return "Arquivos locais preparados; instalação e Stage pendentes."
    }
}
