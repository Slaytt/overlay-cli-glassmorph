# CLAUDE.md — VibeTerminal

## Projet
VibeTerminal est un HUD macOS flottant (overlay glassmorphique) pour monitorer
des sessions de développement. Un CLI Node (`vibe <cmd>`) exécute des commandes
via node-pty et streame l'output en JSON via WebSocket vers l'app Swift/SwiftUI.

## Stack
- **App macOS** : Swift 6, SwiftUI, AppKit (NSPanel), Network framework (NWListener)
- **CLI** : Node.js, node-pty, ws
- **Communication** : WebSocket sur localhost, messages JSON typés

## Structure

Sources/VibeTerminal/
App/              → main.swift, AppDelegate.swift
Models/           → SessionStore, CommandSession, MessageProtocol
Network/          → WebSocketServer, ConnectionManager
Views/            → ContentView, SessionCard, ToolCallPill, NotesPanel, ExplainPanel
vibe-cli/           → index.js (CLI Node)

## Conventions
- Swift 6 strict concurrency (@MainActor pour tout ce qui touche l'UI)
- Structs Codable pour le protocole WebSocket, jamais de parsing string ad-hoc
- Un fichier = une responsabilité
- Commentaires en français
- Noms de variables/fonctions en anglais
- Chaque changement doit compiler (`swift build`) et le CLI doit rester fonctionnel (`node vibe-cli/index.js echo test`)

## Commandes utiles
- `swift build` — compile l'app macOSle 
- `swift run` — lance l'app
- `cd vibe-cli && npm install && node index.js echo "test"` — teste le CLI
- Le WebSocket écoute sur le port défini par VIBE_PORT (défaut 8765)

## Ce qu'il ne faut PAS faire
- Ne pas envoyer de texte brut via WebSocket (toujours du JSON)
- Ne pas faire de strip ANSI côté Swift (c'est le CLI Node qui nettoie)
- Ne pas mettre de logique métier dans les Views
- Ne pas hardcoder le port WebSocket