#!/usr/bin/env node

import { WebSocket } from "ws";
import pty from "node-pty";

const WS_URL = "ws://localhost:8765";
const args = process.argv.slice(2);

if (args.length === 0) {
  console.error("Usage: vibe <commande> [args...]");
  process.exit(1);
}

// --- Connexion WebSocket vers l'app Swift ---
function connectToHUD() {
  return new Promise((resolve) => {
    const ws = new WebSocket(WS_URL);
    const timeout = setTimeout(() => { ws.terminate(); resolve(null); }, 500);
    ws.on("open", () => { clearTimeout(timeout); resolve(ws); });
    ws.on("error", () => { clearTimeout(timeout); resolve(null); });
  });
}

async function run() {
  const ws = await connectToHUD();
  const hudAvailable = ws !== null;

  if (hudAvailable) {
    ws.send(`\x00CLEAR\x00`);
    ws.send(`$ ${args.join(" ")}\n`);
  }

  // PTY : le process enfant croit tourner dans un vrai terminal
  const term = pty.spawn(args[0], args.slice(1), {
    name: "xterm-256color",
    cols: process.stdout.columns || 220,
    rows: process.stdout.rows || 50,
    cwd: process.cwd(),
    env: process.env,
  });

  // Tout l'output du terminal (y compris TUI comme claude) passe ici
  term.onData((data) => {
    process.stdout.write(data); // Afficher dans le terminal courant

    if (hudAvailable && ws.readyState === WebSocket.OPEN) {
      ws.send(data);
    }
  });

  term.onExit(({ exitCode }) => {
    const msg = `\n[vibe] Terminé (code ${exitCode ?? "?"})\n`;
    if (hudAvailable && ws.readyState === WebSocket.OPEN) {
      ws.send(msg);
      ws.close();
    }
    process.exit(exitCode ?? 0);
  });

  // Forwarder les entrées clavier vers le process enfant (pour les TUI interactifs)
  if (process.stdin.isTTY) {
    process.stdin.setRawMode(true);
  }
  process.stdin.resume();
  process.stdin.on("data", (data) => term.write(data.toString()));

  // Adapter la taille du PTY si le terminal est redimensionné
  process.stdout.on("resize", () => {
    term.resize(process.stdout.columns, process.stdout.rows);
  });

  // Propagation des signaux
  for (const sig of ["SIGINT", "SIGTERM"]) {
    process.on(sig, () => term.kill(sig));
  }
}

run();
