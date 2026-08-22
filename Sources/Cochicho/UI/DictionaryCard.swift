import SwiftUI

// MARK: - 05 DICTIONARY

struct DictionaryCard: View {
    var size: TileSize = .tall
    private var store: DictionaryStore { .shared }
    @State private var newHear = ""
    @State private var newWrite = ""

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(
                    number: "05", title: "DICIONÁRIO",
                    trailing: "\(store.entries.filter(\.isEnabled).count) ATIVAS"
                )

                if size != .small {
                    HStack(spacing: 6) {
                        TextField("ouvir…", text: $newHear)
                        Text("→")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.accent)
                        TextField("escrever…", text: $newWrite)
                        Button("+") { add() }
                            .buttonStyle(PillButtonStyle(prominent: true))
                            .disabled(newWrite.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .textFieldStyle(.plain)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.ink)
                }

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.entries) { entry in
                            row(entry)
                        }
                    }
                }
            }
        }
    }

    private func add() {
        let write = newWrite.trimmingCharacters(in: .whitespaces)
        let hear = newHear.trimmingCharacters(in: .whitespaces)
        guard !write.isEmpty else { return }
        store.add(hear.isEmpty ? .term(write) : .correction(hear: hear, write: write))
        newHear = ""
        newWrite = ""
    }

    private func row(_ entry: DictionaryEntry) -> some View {
        HStack(spacing: 8) {
            if entry.kind == .correction {
                Text(entry.hear)
                    .font(Theme.mono(10))
                    .foregroundStyle(entry.isEnabled ? Theme.inkDim : Theme.inkFaint)
                    .lineLimit(1)
                Text("→")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.accent.opacity(entry.isEnabled ? 1 : 0.3))
            }
            Text(entry.write)
                .font(Theme.mono(10, .medium))
                .foregroundStyle(entry.isEnabled ? Theme.ink : Theme.inkFaint)
                .lineLimit(1)
            Spacer()
            Button(entry.isEnabled ? "ON" : "OFF") {
                store.toggle(entry)
            }
            .buttonStyle(.plain)
            .font(Theme.mono(8, .semibold))
            .foregroundStyle(entry.isEnabled ? Theme.ok : Theme.inkFaint)
            Button("×") {
                store.remove(entry)
            }
            .buttonStyle(.plain)
            .font(Theme.mono(10))
            .foregroundStyle(Theme.inkFaint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
