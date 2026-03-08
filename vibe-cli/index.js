#!/usr/bin/env node

import { WebSocket } from "ws";
import pty from "node-pty";
import { randomUUID } from "node:crypto";

// ── Configuration ─────────────────────────────────────────────────────────────
// VIBE_PORT permet de changer le port sans recompiler (utile pour les tests).

const PORT     = process.env.VIBE_PORT ?? "8765";
const WS_URL   = `ws://localhost:${PORT}`;
const args     = process.argv.slice(2);

// --debug : affiche sur stderr chaque message JSON construit (avec ou sans HUD).
// Utile pour tester le protocole sans lancer l'app Swift.
const DEBUG    = args.includes("--debug");
const cmdArgs  = args.filter(a => a !== "--debug");

if (cmdArgs.length === 0) {
  console.error("Usage: vibe [--debug] <commande> [args...]");
  process.exit(1);
}

// ── Nettoyage ANSI ────────────────────────────────────────────────────────────
// Le nettoyage se fait ici (Node) et non côté Swift, car :
//   1. On a accès au flux PTY byte à byte avant toute interprétation
//   2. Swift reçoit du texte UTF-8 propre → zéro regex côté SwiftUI
//   3. Responsabilité unique : le CLI transforme, Swift affiche
//
// Reprend la logique de TerminalOutputModel.stripAnsi (Swift) portée en JS.

function stripAnsi(text) {
  let s = text;
  // Séquences OSC : ESC ] … BEL ou ESC ] … ESC \
  s = s.replace(/\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)/g, "");
  // Séquences CSI : ESC [ … lettre finale (couleurs, curseur, effacement…)
  s = s.replace(/\x1B\[[0-9;?]*[A-Za-z~]/g, "");
  // Séquences DCS / PM / APC
  s = s.replace(/\x1B[PX^_].*?\x1B\\/gs, "");
  // Autres ESC 2-chars (ESC M, ESC =, ESC >, …)
  s = s.replace(/\x1B[^\[\]PX^_]/g, "");
  // ESC orphelins restants
  s = s.replace(/\x1B/g, "");
  // Caractères de contrôle sauf \n et \t
  s = s.replace(/[\x00-\x08\x0B\x0C\x0E-\x1A\x1C-\x1F\x7F]/g, "");
  // \r\n → \n  |  \r seul → supprimé (overwrite TUI sans créer une nouvelle ligne)
  s = s.replace(/\r\n/g, "\n").replace(/\r/g, "");
  // Réduire les séries de lignes vides excessives
  s = s.replace(/\n{3,}/g, "\n\n");
  return s;
}

// ── Détection de prompt Y/n ───────────────────────────────────────────────────
// Même logique que CommandSession.needsConfirmation (Swift).
// On inspecte la fin du buffer accumulé pour éviter les faux positifs
// sur des lignes d'output qui contiendraient ces motifs en passant.

const CONFIRM_PATTERN =
  /(\(Y\/n\)|\(y\/N\)|\[Y\/n\]|\[y\/N\]|\(yes\/no\)|\[yes\/no\]|continue\?|proceed\?|\? \[y\/n\])/i;

function detectsConfirmPrompt(tail) {
  return CONFIRM_PATTERN.test(tail);
}

// ── Protocole JSON ────────────────────────────────────────────────────────────
// sendMessage est le seul endroit où l'on sérialise vers le WebSocket.
// Tous les messages suivent le schéma VibeMessage défini dans MessageProtocol.swift :
// { type, ...payload } — flat, sans objet "payload" imbriqué.

function sendMessage(ws, type, payload = {}) {
  const json = JSON.stringify({ type, ...payload });
  if (DEBUG) process.stderr.write(`[vibe:debug] ${json}\n`);
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  try {
    ws.send(json);
  } catch (err) {
    console.error(`[vibe] Erreur envoi message "${type}":`, err.message);
  }
}

// ── Connexion WebSocket avec retry ────────────────────────────────────────────
// 3 tentatives avec délais exponentiels : 500 ms, 1 s, 2 s.
// Si le HUD n'est pas joignable après tous les essais, on continue en mode
// "terminal classique" sans crash — vibe reste utilisable sans l'app Swift.

const RETRY_DELAYS = [500, 1000, 2000]; // ms

async function connectToHUD() {
  for (let attempt = 0; attempt < RETRY_DELAYS.length; attempt++) {
    const ws = await tryConnect();
    if (ws) return ws;

    const delay = RETRY_DELAYS[attempt];
    const remaining = RETRY_DELAYS.length - attempt - 1;
    console.error(
      `[vibe] HUD non joignable (tentative ${attempt + 1}/${RETRY_DELAYS.length})` +
      (remaining > 0 ? ` — nouvel essai dans ${delay}ms…` : "")
    );
    if (remaining > 0) await sleep(delay);
  }

  console.error("[vibe] HUD inaccessible — mode terminal classique activé.");
  return null;
}

function tryConnect() {
  return new Promise((resolve) => {
    const ws      = new WebSocket(WS_URL);
    // Timeout plus généreux que l'ancien 500ms fixe pour couvrir les retards de démarrage
    const timeout = setTimeout(() => { ws.terminate(); resolve(null); }, 800);
    ws.on("open",  () => { clearTimeout(timeout); resolve(ws); });
    ws.on("error", () => { clearTimeout(timeout); resolve(null); });
  });
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// ── Point d'entrée principal ──────────────────────────────────────────────────

async function run() {
  const ws           = await connectToHUD();
  const hudAvailable = ws !== null;

  // Identifiant unique de session, partagé dans tous les messages de cette commande.
  // UUID v4 généré côté Node (source de vérité) pour corréler start/output/end côté Swift.
  const sessionId = randomUUID();
  const startedAt = Date.now(); // ms, pour calculer la durée à la fin

  // ── session:start ─────────────────────────────────────────────────────────
  // Premier message : crée un CommandSession dans SessionStore.
  // timestamp en secondes (Double Swift) pour rester cohérent avec le protocole.
  // sendMessage est null-safe : log toujours en --debug, n'envoie que si ws ouvert.
  sendMessage(ws, "session:start", {
    sessionId,
    command:   cmdArgs.join(" "),
    cwd:       process.cwd(),
    timestamp: startedAt / 1000,
  });

  // ── Spawn PTY ─────────────────────────────────────────────────────────────
  // TERM=dumb + NO_COLOR supprime les TUI animées (Claude Code, etc.)
  // et garantit un output texte plat, plus facile à parser.
  const shell = process.env.SHELL || "/bin/bash";
  const term = pty.spawn(shell, ["-l", "-c", cmdArgs.join(" ")], {
    name: "dumb",
    cols: process.stdout.columns || 220,
    rows: process.stdout.rows   || 50,
    cwd:  process.cwd(),
    env:  {
      ...process.env,
      TERM:                "dumb",
      NO_COLOR:            "1",
      CLAUDE_NO_ANIMATION: "1",
    },
  });

  term.on("error", (err) => {
    console.error("[vibe] Erreur PTY :", err.message);
    process.exit(1);
  });

  // Buffer glissant pour la détection de prompts Y/n.
  // On garde les 600 derniers caractères nettoyés — taille calquée sur Swift.
  let outputTail = "";

  // ── PTY → stdout local + HUD ──────────────────────────────────────────────
  term.onData((raw) => {
    // Écrire le flux brut dans le terminal courant (couleurs, animations conservées)
    process.stdout.write(raw);

    // Nettoyer avant d'envoyer au HUD (Swift n'effectue plus ce nettoyage)
    const clean = stripAnsi(raw);
    if (!clean) return;

    // session:output — chunk d'output nettoyé
    // sendMessage est null-safe : si pas de HUD, log en --debug uniquement.
    sendMessage(ws, "session:output", { sessionId, data: clean });

    // Mise à jour du buffer de détection (fenêtre glissante de 600 chars)
    outputTail = (outputTail + clean).slice(-600);

    // session:prompt — envoyé en plus de session:output si prompt détecté.
    // Le HUD affiche alors les boutons Y/n sans remplacer l'output.
    if (detectsConfirmPrompt(outputTail)) {
      const match   = outputTail.match(CONFIRM_PATTERN);
      const message = match ? match[0] : "Confirmation requise";
      sendMessage(ws, "session:prompt", {
        sessionId,
        promptType: "confirm",
        message,
      });
      // Réinitialiser le tail pour ne pas ré-émettre le même prompt à chaque chunk
      outputTail = "";
    }
  });

  // ── Fin du process ────────────────────────────────────────────────────────
  term.onExit(({ exitCode }) => {
    const duration = (Date.now() - startedAt) / 1000; // secondes (Double)

    // session:end — Swift marque la session comme terminée et affiche le statut
    sendMessage(ws, "session:end", { sessionId, exitCode: exitCode ?? null, duration });
    if (hudAvailable && ws.readyState === WebSocket.OPEN) ws.close();

    process.exit(exitCode ?? 0);
  });

  // ── HUD → PTY (bidirectionnel) ────────────────────────────────────────────
  // Swift envoie un message "input:reply" quand l'utilisateur clique sur
  // un bouton (Y/n) ou soumet une saisie libre. On l'injecte dans le PTY
  // comme si c'était une frappe clavier réelle.
  if (hudAvailable) {
    ws.on("message", (rawData) => {
      try {
        const msg = JSON.parse(rawData.toString("utf8"));
        if (msg.type === "input:reply" && typeof msg.text === "string") {
          term.write(msg.text);
        } else if (msg.type === "ping") {
          sendMessage(ws, "pong");
        }
        // Les autres types (pong, etc.) sont ignorés silencieusement côté CLI
      } catch {
        // Message non-JSON reçu — on l'ignore pour robustesse
      }
    });

    // ── Heartbeat ping toutes les 5 secondes ──────────────────────────────
    // Détecte les connexions fantômes (app Swift fermée sans fermer le WS).
    // Si le pong ne revient pas, ws.readyState passera à CLOSED naturellement.
    const pingInterval = setInterval(() => {
      sendMessage(ws, "ping");
    }, 5000);

    // Stopper le ping quand la connexion se ferme proprement
    ws.on("close", () => clearInterval(pingInterval));
  }

  // ── Clavier local → PTY ───────────────────────────────────────────────────
  if (process.stdin.isTTY) process.stdin.setRawMode(true);
  process.stdin.resume();
  process.stdin.on("data", (data) => term.write(data.toString()));

  // Propagation du redimensionnement du terminal vers le PTY enfant
  process.stdout.on("resize", () => {
    term.resize(process.stdout.columns, process.stdout.rows);
  });

  // Propagation des signaux pour éviter les process zombies
  for (const sig of ["SIGINT", "SIGTERM"]) {
    process.on(sig, () => term.kill(sig));
  }
}

run();
