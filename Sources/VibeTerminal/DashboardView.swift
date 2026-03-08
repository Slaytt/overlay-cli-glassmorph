import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var model: SessionStore

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
//
// Lit le cwd depuis la dernière CommandSession reçue — pas FileManager.currentDirectoryPath
// qui retourne le répertoire de travail du process Swift (l'app elle-même), pas
// celui du projet que l'utilisateur développe.
//
// Le listage des fichiers s'exécute sur un thread utilitaire (Task.detached) pour
// ne pas bloquer le main actor pendant les appels FileManager synchrones.

struct SidebarView: View {
    @EnvironmentObject var model: SessionStore

    // Entrées du répertoire : (nom, estUnDossier)
    @State private var entries:   [(name: String, isDir: Bool)] = []
    @State private var hasClaude: Bool = false
    @State private var isLoading: Bool = false

    // cwd de la dernière session reçue, chaîne vide si aucune session encore.
    private var cwd: String { model.sessions.last?.cwd ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Contexte projet", icon: "folder")

            if cwd.isEmpty {
                // Aucune session reçue — pas de placeholder "bientôt disponible"
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 22, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.15))
                    Text("Lance une commande\npour voir le contexte projet")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.25))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        CwdHeaderView(cwd: cwd, hasClaude: hasClaude)
                        FileListView(entries: entries, isLoading: isLoading)
                    }
                    .padding(12)
                }
            }
        }
        .onAppear  { loadFiles() }
        .onChange(of: cwd) { _ in loadFiles() }
    }

    // ── Listage asynchrone ────────────────────────────────────────────────────

    private func loadFiles() {
        guard !cwd.isEmpty else {
            entries = []; hasClaude = false; return
        }
        isLoading = true

        // Capturer `cwd` (String, Sendable) avant d'entrer dans le Task.detached
        // pour éviter d'accéder à une propriété main actor-isolated depuis un autre thread.
        let path = cwd

        Task.detached(priority: .utility) {
            let fm   = FileManager.default
            let raw  = (try? fm.contentsOfDirectory(atPath: path)) ?? []

            var dirs:  [(String, Bool)] = []
            var files: [(String, Bool)] = []
            var claudeFound = false

            for name in raw.sorted() {
                // Détecter CLAUDE.md dans la liste brute (avant filtrage)
                if name == "CLAUDE.md" { claudeFound = true }

                // Sauter les fichiers cachés (comme `ls` sans -a)
                guard !name.hasPrefix(".") else { continue }

                var isDir: ObjCBool = false
                let full = (path as NSString).appendingPathComponent(name)
                fm.fileExists(atPath: full, isDirectory: &isDir)

                if isDir.boolValue { dirs.append((name, true)) }
                else               { files.append((name, false)) }
            }

            // Dossiers en premier, puis fichiers — comme ls avec --group-directories-first
            let allEntries = dirs + files

            await MainActor.run {
                self.entries   = allEntries
                self.hasClaude = claudeFound
                self.isLoading = false
            }
        }
    }
}

// ── En-tête CWD ───────────────────────────────────────────────────────────────

struct CwdHeaderView: View {
    let cwd: String
    let hasClaude: Bool

    // Nom du dossier seul (dernière composante du chemin)
    private var folderName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Ligne label + badge CLAUDE.md
            HStack(spacing: 6) {
                Image(systemName: "mappin.circle")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                Text("Répertoire courant")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))

                if hasClaude {
                    Text("CLAUDE.md")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.9))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.orange.opacity(0.15))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(.orange.opacity(0.3), lineWidth: 0.5))
                }
            }

            // Nom court du projet en gras
            Text(folderName)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.orange.opacity(0.85))

            // Chemin complet tronqué au milieu
            Text(cwd)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.25))
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(8)
        .background(.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.06), lineWidth: 1))
    }
}

// ── Liste de fichiers ─────────────────────────────────────────────────────────

struct FileListView: View {
    let entries:   [(name: String, isDir: Bool)]
    let isLoading: Bool

    // Limite d'affichage : au-delà, on affiche "… N autres"
    private static let displayLimit = 25

    var body: some View {
        if isLoading {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Text("Chargement…")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.vertical, 4)
        } else if entries.isEmpty {
            Text("Dossier vide")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.white.opacity(0.2))
                .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(entries.prefix(Self.displayLimit), id: \.name) { entry in
                    FileRowView(name: entry.name, isDir: entry.isDir)
                }
                if entries.count > Self.displayLimit {
                    Text("… \(entries.count - Self.displayLimit) autres fichiers")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.2))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                }
            }
            .background(.white.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// ── Ligne de fichier ──────────────────────────────────────────────────────────

struct FileRowView: View {
    let name: String
    let isDir: Bool

    private var icon: String {
        if isDir { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "swift":           return "curlybraces"
        case "js", "ts", "mjs": return "doc.text.fill"
        case "json":            return "curlybraces.square.fill"
        case "md":              return "doc.richtext"
        case "sh", "bash", "zsh": return "terminal"
        case "py":              return "doc.text.fill"
        case "html", "css":     return "globe"
        case "png", "jpg", "jpeg", "svg", "gif": return "photo.fill"
        default:                return "doc.fill"
        }
    }

    private var iconColor: Color {
        if isDir { return .yellow.opacity(0.65) }
        switch (name as NSString).pathExtension.lowercased() {
        case "swift":           return .orange
        case "js", "ts", "mjs": return Color(red: 0.95, green: 0.8, blue: 0.2)
        case "json":            return .green.opacity(0.8)
        case "md":              return .blue.opacity(0.8)
        case "sh", "bash", "zsh": return .purple.opacity(0.7)
        case "py":              return Color(red: 0.4, green: 0.7, blue: 1.0)
        case "html":            return .red.opacity(0.7)
        case "css":             return .blue.opacity(0.6)
        default:                return .white.opacity(0.35)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 12, alignment: .center)

            Text(isDir ? name + "/" : name)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isDir ? .white.opacity(0.65) : .white.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
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
