import AVPPlayCore
import SwiftUI

struct LocalAdditionalFilesReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let review: LocalAdditionalFileReview
    let confirm: ([String: String]) throws -> Void
    @State private var selected: Set<String> = []
    @State private var destinations: [String: String] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Revisar arquivos adicionais").font(.title2.bold())
            Text("Arquivos locais não são considerados oficiais. Confira origem, hash e destino antes de incluir.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(review.candidates) { item in
                        VStack(alignment: .leading, spacing: 7) {
                            Toggle(isOn: selectionBinding(for: item)) {
                                Text("\(item.name) · \(item.classification)").font(.headline)
                            }
                            Text("Origem: \(item.origin)").textSelection(.enabled)
                            Text("Tamanho: \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) (\(item.size) bytes)")
                            Text("SHA-256: \(item.sha256)").textSelection(.enabled)
                            TextField("Destino relativo a Documents/", text: destinationBinding(for: item))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("additional-destination-\(item.name)")
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("additional-review-\(item.name)")
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("\(selected.count) arquivo(s) selecionado(s)").foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Confirmar inclusão") { confirmSelection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("confirm-additional-files")
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 540)
        .onAppear {
            destinations = Dictionary(uniqueKeysWithValues: review.candidates.map { ($0.origin, $0.suggestedDestination) })
        }
    }

    private func selectionBinding(for item: LocalGameImport.AdditionalFileReview) -> Binding<Bool> {
        Binding(get: { selected.contains(item.origin) }, set: { value in
            if value { selected.insert(item.origin) } else { selected.remove(item.origin) }
        })
    }

    private func destinationBinding(for item: LocalGameImport.AdditionalFileReview) -> Binding<String> {
        Binding(get: { destinations[item.origin] ?? item.suggestedDestination }, set: { destinations[item.origin] = $0 })
    }

    private func confirmSelection() {
        let chosen = destinations.filter { selected.contains($0.key) }
        guard chosen.count == selected.count,
              chosen.values.allSatisfy(LocalGameImport.safeAdditionalDestination) else {
            error = "Revise os destinos: use caminhos relativos seguros dentro de Documents/."
            return
        }
        do { try confirm(chosen); dismiss() }
        catch { self.error = "Falha ao incluir arquivos: \(error.localizedDescription)" }
    }
}
