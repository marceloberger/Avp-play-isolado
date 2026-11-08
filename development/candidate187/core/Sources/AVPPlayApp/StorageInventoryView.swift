import AVPPlayCore
import SwiftUI

/// Additional inventory remains compact until a category is opened.
struct StorageInventoryView: View {
    let inventory: LocalStorageInventory
    @State private var expanded: Set<LocalStorageCategory> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(LocalStorageCategory.allCases, id: \.self) { category in
                let entries = inventory.entries.filter { $0.category == category }
                let bytes = entries.reduce(Int64(0)) { $0 + $1.uniqueBytes }
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(category) },
                    set: { isOpen in if isOpen { expanded.insert(category) } else { expanded.remove(category) } }
                )) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: entry.available ? "folder" : "externaldrive.badge.exclamationmark")
                                    .foregroundStyle(entry.available ? Color.secondary : Color.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title).lineLimit(2).textSelection(.enabled)
                                    if !entry.available || !entry.issues.isEmpty {
                                        Text(entry.available ? "Parcial · alguns arquivos não puderam ser lidos" : "Indisponível · caminho não acessível")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                Spacer(minLength: 12)
                                Text(StoredGameRow.size(entry.uniqueBytes)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout).padding(.vertical, 2)
                        }
                        if entries.isEmpty { Text("Nenhum dado identificado nesta categoria.").font(.callout).foregroundStyle(.secondary) }
                    }
                    .padding(.leading, 16).padding(.vertical, 5)
                } label: {
                    HStack {
                        Text(category.title)
                        Spacer()
                        Text(StoredGameRow.size(bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Text("Tamanhos lógicos. Caminhos repetidos e hard links contam uma vez; dados compartilhados ou sem associação comprovada ficam fora dos totais individuais. Clones APFS podem compartilhar espaço físico.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
    }
}
