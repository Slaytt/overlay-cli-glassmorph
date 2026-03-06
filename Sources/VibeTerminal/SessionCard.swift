import SwiftUI
import AppKit

// ── Liste des sessions ────────────────────────────────────────────────────────

struct SessionListView: View {
    @ObservedObject var model: TerminalOutputModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.sessions) { session in
                        SessionCard(session: session, onSend: model.sendToTerminal)
                            .id(session.id)
                    }
                }
                .padding(12)
                .id("list-bottom")
            }
            .onChange(of: model.sessions.count) { _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("list-bottom", anchor: .bottom) }
            }
            .onChange(of: model.sessions.last?.output) { _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    if let id = model.sessions.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }
}

// ── Card par commande ─────────────────────────────────────────────────────────

struct SessionCard: View {
    let session: CommandSession
    let onSend: ((String) -> Void)?
    @State private var askCopied = false

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
            // ── En-tête de la commande ──────────────────────────────────────
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

                // Bouton Ask Gemini
                AskGeminiButton(session: session, copied: $askCopied)

                Text(session.startTime, style: .time)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
            }

            // ── Output parsé ────────────────────────────────────────────────
            let trimmed = session.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                ParsedOutputView(rawOutput: trimmed, statusColor: statusColor)
            }

            // ── Boutons Y/n si nécessaire ────────────────────────────────
            if session.needsConfirmation && session.isRunning {
                ConfirmationButtons(onSend: onSend)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(10)
        .background(.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.07), lineWidth: 1))
        .animation(.easeInOut(duration: 0.2), value: session.needsConfirmation)
    }
}

// ── Bouton Ask Gemini ─────────────────────────────────────────────────────────

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { copied = false }
            }
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
                copied ? Color.green.opacity(0.4) : Color.purple.opacity(0.3),
                lineWidth: 0.5
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
            ConfirmButton(label: "Rejeter (N)", color: .red) { onSend?("n\r") }
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

// ── Output parsé avec pills pour les tool calls ───────────────────────────────

struct ParsedOutputView: View {
    let rawOutput: String
    let statusColor: Color

    // Regex pour détecter les tool calls Claude Code : "● Read(path)" etc.
    private static let toolRegex = try? NSRegularExpression(
        pattern: #"[●⎿▶]\s*(Read|Write|Edit|MultiEdit|Bash|Create|Delete|View|Glob|Grep|LS|TodoWrite|TodoRead)\((.{1,200}?)\)"#
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parsedLines().enumerated()), id: \.offset) { _, line in
                switch line {
                case .text(let s):
                    Text(s)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .fileOp(let icon, let verb, let name):
                    FileOpPill(icon: icon, verb: verb, filename: name)
                }
            }
        }
        .padding(10)
        .background(.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(statusColor.opacity(0.2), lineWidth: 1))
    }

    enum ParsedLine {
        case text(String)
        case fileOp(icon: String, verb: String, name: String)
    }

    private func parsedLines() -> [ParsedLine] {
        guard let regex = Self.toolRegex else {
            return [.text(rawOutput)]
        }

        var result: [ParsedLine] = []
        var textBuffer = ""

        for rawLine in rawOutput.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)

            if let match = regex.firstMatch(in: line, range: range),
               match.numberOfRanges >= 3,
               let verbRange = Range(match.range(at: 1), in: line),
               let argsRange = Range(match.range(at: 2), in: line) {

                // Flush le buffer texte avant la pill
                if !textBuffer.isEmpty {
                    result.append(.text(textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)))
                    textBuffer = ""
                }

                let verb = String(line[verbRange])
                let args = String(line[argsRange])
                let filename = args.components(separatedBy: "/").last
                    .flatMap { $0.isEmpty ? nil : $0 } ?? args

                let icons: [String: String] = [
                    "Read": "doc.text", "View": "doc.text",
                    "Write": "pencil.and.outline", "Edit": "pencil.and.outline",
                    "MultiEdit": "pencil.and.outline", "Create": "doc.badge.plus",
                    "Bash": "terminal.fill", "Delete": "trash",
                    "Glob": "magnifyingglass", "Grep": "text.magnifyingglass",
                    "LS": "folder", "TodoWrite": "checklist", "TodoRead": "checklist"
                ]
                result.append(.fileOp(icon: icons[verb] ?? "doc", verb: verb, name: filename))
            } else {
                textBuffer += (textBuffer.isEmpty ? "" : "\n") + line
            }
        }

        if !textBuffer.isEmpty {
            result.append(.text(textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return result
    }
}

// ── Pill pour les tool calls ──────────────────────────────────────────────────

struct FileOpPill: View {
    let icon: String
    let verb: String
    let filename: String

    var pillColor: Color {
        switch verb {
        case "Write", "Edit", "MultiEdit": return .blue
        case "Bash": return .orange
        case "Create": return .green
        case "Delete": return .red
        default: return .white
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text(verb)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
            Text("·")
                .foregroundStyle(.white.opacity(0.3))
            Text(filename)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(pillColor.opacity(0.85))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(pillColor.opacity(0.1))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(pillColor.opacity(0.25), lineWidth: 0.5))
    }
}
