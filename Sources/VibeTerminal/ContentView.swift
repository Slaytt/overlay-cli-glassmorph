import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: TerminalOutputModel
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                HeaderBar(isHovering: $isHovering, model: model)

                Divider()
                    .overlay(
                        LinearGradient(
                            colors: [.orange.opacity(0.6), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )

                if model.sessions.isEmpty {
                    EmptyStateView()
                } else {
                    SessionListView(model: model)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 300)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(
                        colors: [.orange.opacity(0.16), .orange.opacity(0.04), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(LinearGradient(
                    colors: [.orange.opacity(0.5), .white.opacity(0.1), .orange.opacity(0.08)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .orange.opacity(0.2), radius: 30)
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 14)
        .onHover { hovering in withAnimation(.easeInOut(duration: 0.18)) { isHovering = hovering } }
    }
}

// ── Header ────────────────────────────────────────────────────────────────────

struct HeaderBar: View {
    @Binding var isHovering: Bool
    let model: TerminalOutputModel

    var body: some View {
        HStack(spacing: 8) {
            // Dot animé selon état
            let running = model.sessions.last?.isRunning ?? false
            Circle()
                .fill(running ? Color.orange : Color.green.opacity(0.8))
                .frame(width: 7, height: 7)
                .shadow(color: running ? .orange : .green, radius: running ? 6 : 3)
                .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true).speed(running ? 1 : 0), value: running)

            Text("Vibe")
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(.orange.opacity(0.9))

            if let cmd = model.sessions.last?.command {
                Text("·")
                    .foregroundStyle(.white.opacity(0.3))
                Text(cmd)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer()

            if isHovering {
                HStack(spacing: 5) {
                    PillButton(label: "Copier", icon: "doc.on.doc") {
                        let text = model.sessions.map { "$ \($0.command)\n\($0.output)" }.joined(separator: "\n\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    PillButton(label: "Vider", icon: "trash") { model.clear() }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// ── Liste des sessions ────────────────────────────────────────────────────────

struct SessionListView: View {
    @ObservedObject var model: TerminalOutputModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.sessions) { session in
                        SessionCard(session: session)
                            .id(session.id)
                    }
                }
                .padding(12)
                .id("list-bottom")
            }
            .onChange(of: model.sessions.count) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("list-bottom", anchor: .bottom)
                }
            }
            .onChange(of: model.sessions.last?.output) { _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    if let id = model.sessions.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// ── Card par commande ─────────────────────────────────────────────────────────

struct SessionCard: View {
    let session: CommandSession

    var statusColor: Color {
        guard let code = session.exitCode else { return .orange }
        return code == 0 ? .green : .red
    }

    var statusIcon: String {
        guard let code = session.exitCode else { return "ellipsis" }
        return code == 0 ? "checkmark" : "xmark"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Titre de la commande
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

                Text(session.startTime, style: .time)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
            }

            // Output nettoyé
            if !session.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(session.output.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(statusColor.opacity(0.2), lineWidth: 1)
                    )
            }
        }
        .padding(10)
        .background(.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        )
    }
}

// ── État vide ─────────────────────────────────────────────────────────────────

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(.orange.opacity(0.4))
            Text("Lance une commande avec vibe")
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
            Text("vibe npm run build  ·  vibe pytest  ·  vibe git status")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.2))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

// ── Composants communs ────────────────────────────────────────────────────────

struct PillButton: View {
    let label: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium))
                Text(label).font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.orange.opacity(0.85))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(.orange.opacity(0.1))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.orange.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
