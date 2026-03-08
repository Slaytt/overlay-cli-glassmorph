import SwiftUI
import AppKit

// ── Liste des sessions ────────────────────────────────────────────────────────
//
// Scroll intelligent : auto-scroll uniquement si l'utilisateur est déjà en bas.
//
// Mécanisme de détection :
//   Une vue sentinelle invisible (Color.clear 1px) est placée à la fin du
//   LazyVStack. LazyVStack monte/démonte les vues selon leur visibilité, donc :
//     onAppear  → sentinelle visible → utilisateur est en bas
//     onDisappear → sentinelle hors écran → utilisateur a scrollé vers le haut
//
// Quand du nouvel output arrive et que l'utilisateur n'est pas en bas,
// un bouton flottant "↓ Nouveau output" apparaît pour lui signaler et
// lui permettre de revenir en bas en un clic.

struct SessionListView: View {
    @ObservedObject var model: SessionStore

    @State private var isAtBottom    = true
    @State private var hasNewOutput  = false

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.sessions) { session in
                            SessionCard(session: session, onSend: model.sendToTerminal)
                                .id(session.id)
                        }

                        // Sentinelle invisible — LazyVStack la monte/démonte selon
                        // la position de scroll, ce qui met à jour isAtBottom.
                        Color.clear
                            .frame(height: 1)
                            .id("bottom-sentinel")
                            .onAppear  { isAtBottom = true;  hasNewOutput = false }
                            .onDisappear { isAtBottom = false }
                    }
                    .padding(12)
                }
                .onChange(of: model.sessions.count) { _ in
                    if isAtBottom {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                        }
                    } else {
                        hasNewOutput = true
                    }
                }
                .onChange(of: model.sessions.last?.output) { _ in
                    if isAtBottom {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                        }
                    } else {
                        hasNewOutput = true
                    }
                }

                // Bouton flottant — visible quand du nouveau contenu est arrivé
                // mais que l'utilisateur a scrollé vers le haut.
                if hasNewOutput && !isAtBottom {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                        }
                        hasNewOutput = false
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Nouveau output")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(.orange.opacity(0.5), lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.spring(duration: 0.25), value: hasNewOutput && !isAtBottom)
        }
    }
}

// ── Card par session ──────────────────────────────────────────────────────────

struct SessionCard: View {
    let session: CommandSession
    let onSend: ((String) -> Void)?
    @State private var askCopied     = false
    @State private var isCardHovering = false

    var statusColor: Color {
        guard let code = session.exitCode else { return .orange }
        return code == 0 ? .green : .red
    }

    var statusIcon: String {
        guard let code = session.exitCode else { return "ellipsis" }
        return code == 0 ? "checkmark" : "xmark"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // ── En-tête ────────────────────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(statusColor)
                    .frame(width: 14, height: 14)
                    .background(statusColor.opacity(0.15))
                    .clipShape(Circle())

                Text(session.command)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))

                Spacer()

                // Bouton Kill — visible au hover sur une session en cours.
                // Envoie Ctrl+C (\u{0003}) dans le PTY via sendToTerminal.
                if isCardHovering && session.isRunning {
                    Button {
                        onSend?("\u{0003}")
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "stop.circle")
                                .font(.system(size: 10, weight: .medium))
                            Text("Stop")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(.red.opacity(0.85))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.red.opacity(0.1))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(.red.opacity(0.35), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                }

                AskGeminiButton(session: session, copied: $askCopied)

                Text(session.startTime, style: .time)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
            }

            // ── Output sémantique ──────────────────────────────────────────
            let blocks = session.parsedOutput
            if !blocks.isEmpty {
                ParsedOutputView(blocks: blocks)
            }

            // ── Confirmation Y/n ───────────────────────────────────────────
            if session.needsConfirmation && session.isRunning {
                ConfirmationButtons(onSend: onSend)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(10)
        .background(.white.opacity(isCardHovering ? 0.05 : 0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
            .white.opacity(isCardHovering ? 0.12 : 0.07), lineWidth: 1
        ))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isCardHovering = hovering }
        }
        .animation(.easeInOut(duration: 0.2), value: session.needsConfirmation)
        .animation(.easeInOut(duration: 0.15), value: isCardHovering)
    }
}

// ── Rendu des blocs sémantiques ───────────────────────────────────────────────

struct ParsedOutputView: View {
    let blocks: [OutputBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .text(let s):
                    Text(s)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                case .toolCall(let icon, let verb, let target, let detail):
                    ToolCallCard(icon: icon, verb: verb, target: target, detail: detail)

                case .codeBlock(let lang, let code):
                    CodeSnippetView(language: lang, code: code)

                case .diff(let filename, let added, let removed, let preview):
                    DiffView(filename: filename, added: added, removed: removed, preview: preview)
                }
            }
        }
    }
}

// ── ToolCallCard ──────────────────────────────────────────────────────────────

struct ToolCallCard: View {
    let icon: String
    let verb: String
    let target: String
    let detail: String

    private var verbLabel: String {
        switch verb {
        case "Read", "View":             return "a lu"
        case "Write":                    return "a écrit"
        case "Edit", "MultiEdit":        return "a modifié"
        case "Bash":                     return "a exécuté"
        case "Create":                   return "a créé"
        case "Delete":                   return "a supprimé"
        case "Glob":                     return "a cherché dans"
        case "Grep":                     return "a analysé"
        case "WebSearch", "WebFetch":    return "a consulté"
        default:                         return "→ \(verb)"
        }
    }

    private var accentColor: Color {
        switch verb {
        case "Write", "Edit", "MultiEdit": return .blue
        case "Bash":                        return .orange
        case "Create":                      return .green
        case "Delete":                      return .red
        case "WebSearch", "WebFetch":       return .cyan
        default:                            return .white
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // Icône
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accentColor)
                .frame(width: 28, height: 28)
                .background(accentColor.opacity(0.1))
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(accentColor.opacity(0.25), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("Claude \(verbLabel)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))

                    Text(target)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accentColor.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(accentColor.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(accentColor.opacity(0.18), lineWidth: 1))
    }
}

// ── CodeSnippetView ───────────────────────────────────────────────────────────

struct CodeSnippetView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Barre supérieure
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))

                Text(language.lowercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    withAnimation(.easeInOut(duration: 0.15)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { copied = false }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(copied ? "Copié !" : "Copier le code")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(copied ? .green.opacity(0.85) : .white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.15), value: copied)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.04))

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            // Corps du code — sélectionnable
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

// ── DiffView ──────────────────────────────────────────────────────────────────

struct DiffView: View {
    let filename: String
    let added: Int
    let removed: Int
    let preview: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // En-tête cliquable
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange.opacity(0.65))

                    Text(filename)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    HStack(spacing: 4) {
                        if added > 0 {
                            Text("+\(added)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.green.opacity(0.9))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.green.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        if removed > 0 {
                            Text("-\(removed)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.red.opacity(0.85))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.red.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            // Contenu du diff (expandable)
            if isExpanded {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(preview.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            DiffLineView(content: line)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 220)
            }
        }
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
            isExpanded ? Color.orange.opacity(0.2) : Color.white.opacity(0.07),
            lineWidth: 1
        ))
    }
}

struct DiffLineView: View {
    let content: String

    private var background: Color {
        if content.hasPrefix("+") && !content.hasPrefix("+++") { return .green.opacity(0.07) }
        if content.hasPrefix("-") && !content.hasPrefix("---") { return .red.opacity(0.07)   }
        if content.hasPrefix("@@")                             { return .blue.opacity(0.06)   }
        return .clear
    }

    private var foreground: Color {
        if content.hasPrefix("+") && !content.hasPrefix("+++") { return .green.opacity(0.88) }
        if content.hasPrefix("-") && !content.hasPrefix("---") { return .red.opacity(0.75)   }
        if content.hasPrefix("@@")                             { return .blue.opacity(0.75)   }
        return .white.opacity(0.55)
    }

    var body: some View {
        Text(content.isEmpty ? " " : content)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .background(background)
    }
}

// ── Bouton Ask ────────────────────────────────────────────────────────────────

struct AskGeminiButton: View {
    let session: CommandSession
    @Binding var copied: Bool

    var body: some View {
        Button {
            let prefix = "Explique-moi ce bloc de code et cette action technique en te concentrant sur l'architecture :\n\n"
            let content = "$ \(session.command)\n\(session.output)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prefix + content, forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { copied = false } }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "sparkles")
                    .font(.system(size: 10, weight: .medium))
                Text(copied ? "Copié !" : "Ask")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .foregroundStyle(copied ? .green.opacity(0.9) : .purple.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(copied ? Color.green.opacity(0.12) : Color.purple.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(
                copied ? Color.green.opacity(0.4) : Color.purple.opacity(0.3), lineWidth: 0.5
            ))
        }
        .buttonStyle(.plain)
    }
}

// ── Boutons de confirmation Y/n ───────────────────────────────────────────────

struct ConfirmationButtons: View {
    let onSend: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.orange.opacity(0.6))
            Text("Action requise")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.orange.opacity(0.7))
            Spacer()
            ConfirmButton(label: "Approuver (Y)", color: .green) { onSend?("y\r") }
            ConfirmButton(label: "Rejeter (N)", color: .red)     { onSend?("n\r") }
        }
        .padding(8)
        .background(.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.2), lineWidth: 1))
    }
}

struct ConfirmButton: View {
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(color.opacity(0.9))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
