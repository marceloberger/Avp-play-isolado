import AVPPlayCore
import SwiftUI

enum JobConnectionCheckState: Equatable {
    case checking
    case passed(String)
    case failed(String)

    var message: String {
        switch self {
        case .checking: return "Verificando conexão, instalação e acesso aos arquivos…"
        case .passed(let text), .failed(let text): return text
        }
    }
}

extension AppModel {
    var connectionCheckBlocked: Bool {
        checkingConnectionJobID != nil || refreshing || runningJob != nil || !queued.isEmpty
            || !resumingJobIDs.isEmpty || !preparingLocalVariantIDs.isEmpty
            || !localAutomaticPlanning.isEmpty || !importingLocalGameIDs.isEmpty || !localOperationWorkers.isEmpty
    }

    /// Button action: only updates ephemeral presentation state. No refresh(), pump() or Job writes.
    func checkJobConnection(_ job: Job) {
        guard !connectionCheckBlocked else {
            if checkingConnectionJobID != job.id {
                jobConnectionChecks[job.id] = .failed("Aguarde a operação ou verificação em andamento terminar e tente novamente.")
            }
            return
        }
        checkingConnectionJobID = job.id
        jobConnectionChecks[job.id] = .checking
        let query = jobConnectionQuery, store = paths.store
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try query(job, store) }
            }.value
            guard let self else { return }
            switch result {
            case .success(let message): self.jobConnectionChecks[job.id] = .passed(message)
            case .failure(let error):
                self.jobConnectionChecks[job.id] = .failed("Verificação falhou: \(Redaction.redact(String(describing: error))). Nenhum Resume iniciado. Tente Check Again novamente.")
            }
            self.checkingConnectionJobID = nil
        }
    }
}

struct JobConnectionCheckView: View {
    @ObservedObject var model: AppModel
    let job: Job

    func checkAgain() { model.checkJobConnection(job) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: checkAgain) {
                if model.checkingConnectionJobID == job.id {
                    HStack { ProgressView().controlSize(.small); Text("Verificando…") }
                } else { Label(L("Check Again", "Neu prüfen"), systemImage: "arrow.clockwise") }
            }
            .disabled(model.connectionCheckBlocked)
            if let state = model.jobConnectionChecks[job.id] {
                Text(state.message).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("job-connection-result")
            } else if model.connectionCheckBlocked {
                Text("Aguarde a operação ou verificação em andamento terminar.").font(.callout)
            }
        }
    }
}
