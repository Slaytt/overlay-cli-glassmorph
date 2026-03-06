#!/usr/bin/env node

import { WebSocket } from "ws";
import pty from "node-pty";

const WS_URL = "ws://localhost:8765";
const args = process.argv.slice(2);

if (args.length === 0) {
  console.error("Usage: vibe <commande> [args...]");
  process.exit(1);
}

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

  const term = pty.spawn(args[0], args.slice(1), {
    name: "xterm-256color",
    cols: process.stdout.columns || 220,
    rows: process.stdout.rows || 50,
    cwd: process.cwd(),
    env: process.env,
  });

  // PTY → terminal local + HUD
  term.onData((data) => {
    process.stdout.write(data);
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

  // ── Bidirectionnel : HUD → PTY ───────────────────────────────────────────
  // Les boutons SwiftUI (Y/n, saisie) envoient du texte que l'on injecte
  // directement dans le process enfant comme si c'était une vraie frappe clavier
  if (hudAvailable) {
    ws.on("message", (rawData) => {
      const text = rawData.toString("utf8");
      term.write(text);
    });
  }

  // Clavier local → PTY
  if (process.stdin.isTTY) process.stdin.setRawMode(true);
  process.stdin.resume();
  process.stdin.on("data", (data) => term.write(data.toString()));

  process.stdout.on("resize", () => {
    term.resize(process.stdout.columns, process.stdout.rows);
  });

  for (const sig of ["SIGINT", "SIGTERM"]) {
    process.on(sig, () => term.kill(sig));
  }
}

run();
