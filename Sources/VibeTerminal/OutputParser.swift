import Foundation

// ── Types de blocs sémantiques ────────────────────────────────────────────────

struct OutputBlock: Identifiable {
    let id = UUID()
    let kind: BlockKind
}

enum BlockKind {
    case text(String)
    case toolCall(icon: String, verb: String, target: String, detail: String)
    case codeBlock(language: String, code: String)
    case diff(filename: String, added: Int, removed: Int, preview: String)
}

// ── Parseur (machine à états) ─────────────────────────────────────────────────

enum OutputParser {

    // Regex tool call Claude Code : "● Read(path)" avec TERM=dumb
    private static let toolRegex = try? NSRegularExpression(
        pattern: #"[●▶]\s*(Read|Write|Edit|MultiEdit|Bash|Create|Delete|View|Glob|Grep|LS|TodoWrite|TodoRead|WebSearch|WebFetch)\((.{1,300}?)\)"#
    )

    private static let verbIcons: [String: String] = [
        "Read": "doc.text",        "View": "doc.text",
        "Write": "pencil.and.outline",  "Edit": "pencil.and.outline",
        "MultiEdit": "pencil.and.outline", "Create": "doc.badge.plus",
        "Bash": "terminal.fill",   "Delete": "trash",
        "Glob": "magnifyingglass", "Grep": "text.magnifyingglass",
        "LS": "folder",            "TodoWrite": "checklist",
        "TodoRead": "checklist",   "WebSearch": "globe",
        "WebFetch": "network"
    ]

    // ── Point d'entrée ────────────────────────────────────────────────────────

    static func parse(_ raw: String) -> [OutputBlock] {
        var blocks:        [OutputBlock] = []
        var textLines:     [String]      = []
        var codeLines:     [String]      = []
        var diffLines:     [String]      = []
        var codeLang                     = ""
        var inCode                       = false
        var inDiff                       = false
        var pendingVerb:   String?       = nil
        var pendingIcon:   String        = "doc"
        var pendingTarget: String        = ""
        var detailLines:   [String]      = []

        func flushText() {
            let joined = textLines
                .filter { !isNoise($0) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(OutputBlock(kind: .text(joined))) }
            textLines = []
        }

        func flushTool() {
            guard let verb = pendingVerb else { return }
            let detail = detailLines
                .map { $0.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "⎿ ")) }
                .filter { !$0.isEmpty && !isNoise($0) }
                .joined(separator: " · ")
            blocks.append(OutputBlock(kind: .toolCall(
                icon: pendingIcon, verb: verb, target: pendingTarget, detail: detail
            )))
            pendingVerb  = nil
            pendingTarget = ""
            detailLines  = []
        }

        func flushDiff() {
            let added   = diffLines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
            let removed = diffLines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
            if added + removed > 0 {
                let filename = blocks.last.flatMap { b -> String? in
                    if case .toolCall(_, let v, let t, _) = b.kind,
                       ["Write","Edit","MultiEdit"].contains(v) { return t }
                    return nil
                } ?? "fichier"
                let preview = diffLines.prefix(30).joined(separator: "\n")
                blocks.append(OutputBlock(kind: .diff(
                    filename: filename, added: added, removed: removed, preview: preview
                )))
            }
            diffLines = []
            inDiff    = false
        }

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // ── Bloc de code ──────────────────────────────────────────────
            if trimmed.hasPrefix("```") {
                if inCode {
                    flushTool()
                    blocks.append(OutputBlock(kind: .codeBlock(
                        language: codeLang,
                        code: codeLines.joined(separator: "\n")
                    )))
                    codeLines = []
                    inCode    = false
                    codeLang  = ""
                } else {
                    flushTool(); flushText()
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    if codeLang.isEmpty { codeLang = "code" }
                    inCode = true
                }
                continue
            }
            if inCode { codeLines.append(line); continue }

            // ── Diff unifié ───────────────────────────────────────────────
            if inDiff {
                let isDiffLine = trimmed.hasPrefix("+") || trimmed.hasPrefix("-")
                               || trimmed.hasPrefix("@@") || trimmed.hasPrefix(" ")
                               || trimmed.hasPrefix("---") || trimmed.hasPrefix("+++")
                if isDiffLine { diffLines.append(line); continue }
                else          { flushDiff() }          // fin du diff
            }

            // ── Bruit ─────────────────────────────────────────────────────
            if isNoise(line) { continue }

            // ── Tool call ─────────────────────────────────────────────────
            if let (verb, target) = extractToolCall(from: line) {
                flushTool(); flushText()
                pendingVerb   = verb
                pendingIcon   = verbIcons[verb] ?? "doc"
                pendingTarget = target
                continue
            }

            // ── Détail du tool call (ligne ⎿ ou indentée après outil) ─────
            if pendingVerb != nil,
               trimmed.hasPrefix("⎿") || (trimmed.hasPrefix(" ") && !trimmed.isEmpty) {
                detailLines.append(line)
                continue
            }

            // Si on sort du contexte d'un tool call, on le flush
            if pendingVerb != nil { flushTool() }

            // ── Début de diff ─────────────────────────────────────────────
            if trimmed.hasPrefix("---") || trimmed.hasPrefix("+++") || trimmed.hasPrefix("@@") {
                flushText()
                inDiff = true
                diffLines.append(line)
                continue
            }

            // ── Texte normal ──────────────────────────────────────────────
            textLines.append(line)
        }

        // Flush finaux
        flushTool()
        flushText()
        if inCode, !codeLines.isEmpty {
            blocks.append(OutputBlock(kind: .codeBlock(
                language: codeLang, code: codeLines.joined(separator: "\n")
            )))
        }
        if inDiff, !diffLines.isEmpty { flushDiff() }

        return blocks
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    static func isNoise(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }

        // Spinners & loaders
        let spinnerSet = CharacterSet(charactersIn: "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
        if t.unicodeScalars.allSatisfy({ spinnerSet.contains($0) || $0 == " " }) { return true }

        // "Evaporating…" et variantes
        if t.lowercased().contains("evaporating") { return true }

        // Pourcentage seul : "45%" ou "100.0%"
        if t.range(of: #"^\d+(\.\d+)?%$"#, options: .regularExpression) != nil { return true }

        // Lignes de boîte pure (╭─╮│╰╯)
        let boxChars = CharacterSet(charactersIn: "╭╮╰╯─│·▪ ")
        if t.unicodeScalars.allSatisfy({ boxChars.contains($0) }) && t.count > 2 { return true }

        return false
    }

    private static func extractToolCall(from line: String) -> (verb: String, target: String)? {
        guard let regex = toolRegex else { return nil }
        let nsLine = line as NSString
        let range  = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges >= 3,
              let verbRange = Range(match.range(at: 1), in: line),
              let argsRange = Range(match.range(at: 2), in: line)
        else { return nil }

        let verb = String(line[verbRange])
        let args = String(line[argsRange])
        let target = args.components(separatedBy: "/")
            .last.flatMap { $0.isEmpty ? nil : $0 } ?? args

        return (verb, target)
    }
}
