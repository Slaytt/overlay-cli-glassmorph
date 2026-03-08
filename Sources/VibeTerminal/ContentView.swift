import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: SessionStore
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar(isHovering: $isHovering, model: model)

            Divider()
                .overlay(LinearGradient(
                    colors: [.orange.opacity(0.6), .clear],
                    startPoint: .leading, endPoint: .trailing
                ))

            if model.isDashboardMode {
                DashboardView()
            } else {
                if model.sessions.isEmpty {
                    EmptyStateView()
                } else {
                    SessionListView(model: model)
                }
            }
        }
        .frame(minWidth: 440, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
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
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) { isHovering = hovering }
        }
    }
}

// ── Header ────────────────────────────────────────────────────────────────────

struct HeaderBar: View {
    @Binding var isHovering: Bool
    @ObservedObject var model: SessionStore

    var body: some View {
        HStack(spacing: 8) {
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
                Text("·").foregroundStyle(.white.opacity(0.3))
                Text(cmd)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer()

            // Toggle Dashboard
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.isDashboardMode.toggle()
                }
            } label: {
                Image(systemName: model.isDashboardMode ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(model.isDashboardMode ? 0.7 : 0.35))
                    .padding(5)
                    .background(model.isDashboardMode ? Color.orange.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help(model.isDashboardMode ? "Mode compact" : "Table de commandement")

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
