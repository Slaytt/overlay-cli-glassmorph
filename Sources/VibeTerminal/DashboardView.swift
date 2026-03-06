import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var model: TerminalOutputModel

    var body: some View {
        HStack(spacing: 0) {
            // ── Colonne gauche : Contexte projet ──────────────────────────
            SidebarView()
                .frame(width: 220)

            GlassDivider()

            // ── Colonne centre : Flux des sessions ────────────────────────
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Flux de commandes", icon: "terminal")
                if model.sessions.isEmpty {
                    EmptyStateView()
                } else {
                    SessionListView(model: model)
                }
            }

            GlassDivider()

            // ── Colonne droite : Notes d'apprentissage ────────────────────
            NotesView()
                .frame(width: 260)
        }
    }
}

// ── Sidebar : contexte projet ─────────────────────────────────────────────────

struct SidebarView: View {
    private let cwd = FileManager.default.currentDirectoryPath

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Contexte projet", icon: "folder")

            VStack(alignment: .leading, spacing: 6) {
                Label("Répertoire courant", systemImage: "mappin.circle")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))

                Text(cwd)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.6))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .padding(8)
                    .background(.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 12)

            Spacer()

            // Placeholder : arborescence
            VStack(spacing: 8) {
                Image(systemName: "sidebar.squares.left")
                    .font(.system(size: 22, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.15))
                Text("Arborescence projet\nbientôt disponible")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.2))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 20)
        }
        .padding(.top, 4)
    }
}

// ── Zone de notes persistantes ────────────────────────────────────────────────

struct NotesView: View {
    @AppStorage("vibe_learning_notes") private var notes = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Notes d'apprentissage", icon: "note.text")

            ZStack(alignment: .topLeading) {
                // Placeholder quand vide
                if notes.isEmpty && !isFocused {
                    Text("Prends des notes ici…\nElles sont sauvegardées automatiquement.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.2))
                        .padding(14)
                }

                TextEditor(text: $notes)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .focused($isFocused)
                    .padding(10)
            }
            .background(.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isFocused ? Color.orange.opacity(0.4) : Color.white.opacity(0.06),
                        lineWidth: 1
                    )
            )
            .padding(12)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
    }
}

// ── Composants communs Dashboard ──────────────────────────────────────────────

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange.opacity(0.6))
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(0.02))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.05)).frame(height: 1)
        }
    }
}

struct GlassDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.08), .clear],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(width: 1)
    }
}
