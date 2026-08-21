import AppKit
import SwiftUI

// MARK: - 04 HISTORY

struct HistoryCard: View {
    private var history: HistoryStore { .shared }
    @State private var query = ""
    @State private var copiedID: UUID?

    private var filtered: [HistoryEntry] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return history.entries }
        return history.entries.filter {
            $0.text.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(
                    number: "04", title: "HISTÓRICO",
                    trailing: "\(history.entries.count)"
                )

                TextField("buscar…", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if filtered.isEmpty {
                    Spacer()
                    Text(history.entries.isEmpty
                         ? "NADA AINDA — SEGURE A TECLA E FALE"
                         : "NENHUM RESULTADO")
                        .font(Theme.mono(10))
                        .tracking(1.5)
                        .foregroundStyle(Theme.inkFaint)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(filtered) { entry in
                                row(entry)
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(entry.date, format: .dateTime.day().month(.twoDigits).hour().minute())
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.inkFaint)
                Text(entry.engine)
                    .font(Theme.mono(8, .medium))
                    .tracking(1)
                    .foregroundStyle(Theme.inkDim)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
                Text(entry.language)
                    .font(Theme.mono(8))
                    .foregroundStyle(Theme.inkFaint)
                Spacer()
                Text(copiedID == entry.id ? "COPIADO ✓" : "\(entry.wordCount)W")
                    .font(Theme.mono(8, .medium))
                    .tracking(1)
                    .foregroundStyle(copiedID == entry.id ? Theme.ok : Theme.inkFaint)
                Button {
                    HistoryStore.shared.remove(entry)
                } label: {
                    Text("×")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.inkFaint)
                }
                .buttonStyle(.plain)
            }
            Text(entry.text)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.ink)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
            copiedID = entry.id
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                if copiedID == entry.id { copiedID = nil }
            }
        }
    }
}
