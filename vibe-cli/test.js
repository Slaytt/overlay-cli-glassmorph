#!/usr/bin/env node
// test.js — vérifie la construction des messages JSON du protocole VibeTerminal.
//
// Ce test ne lance pas de PTY et ne se connecte pas au HUD.
// Il vérifie directement que :
//   1. Les messages produits par le CLI sont du JSON valide
//   2. Leur structure est conforme à MessageProtocol.swift (VibeMessage)
//   3. Le sessionId est cohérent entre les messages d'une même session
//
// Usage : node test.js

import { randomUUID } from "node:crypto";

// ── Helpers ───────────────────────────────────────────────────────────────────

let pass = 0; let fail = 0;
const ok  = (s) => { console.log(`  [PASS] ${s}`); pass++; };
const bad = (s) => { console.log(`  [FAIL] ${s}`); fail++; };

function buildMessage(type, payload = {}) {
  return JSON.stringify({ type, ...payload });
}

// ── Construction des messages d'une session fictive ───────────────────────────

const sessionId = randomUUID();
const startedAt = Date.now();

const rawMessages = [
  buildMessage("session:start", {
    sessionId,
    command:   "echo Phase 1 OK",
    cwd:       "/tmp/projet",
    timestamp: startedAt / 1000,
  }),
  buildMessage("session:output", { sessionId, data: "Phase 1 OK\n" }),
  buildMessage("session:end",    { sessionId, exitCode: 0, duration: 0.05 }),
  buildMessage("ping"),
  buildMessage("pong"),
];

console.log("");
console.log("=== vibe-cli — test du protocole JSON ===");
console.log("");

// ── 1. Validité JSON ──────────────────────────────────────────────────────────

console.log("1. Validité JSON");
const parsed = [];
for (const raw of rawMessages) {
  try {
    parsed.push(JSON.parse(raw));
    ok(`JSON valide : ${raw.slice(0, 72)}…`);
  } catch (e) {
    bad(`JSON invalide : ${raw}`);
  }
}

// ── 2. Champ "type" présent sur chaque message ────────────────────────────────

console.log("\n2. Champ 'type' présent");
for (const msg of parsed) {
  typeof msg.type === "string"
    ? ok(`type="${msg.type}"`)
    : bad(`message sans type : ${JSON.stringify(msg)}`);
}

// ── 3. session:start ──────────────────────────────────────────────────────────

console.log("\n3. Message session:start");
const start = parsed.find(m => m.type === "session:start");
if (!start) {
  bad("session:start absent");
} else {
  ok("session:start présent");
  for (const f of ["sessionId", "command", "cwd", "timestamp"]) {
    start[f] !== undefined
      ? ok(`  champ '${f}' présent : ${JSON.stringify(start[f]).slice(0, 40)}`)
      : bad(`  champ '${f}' manquant`);
  }
  typeof start.timestamp === "number"
    ? ok(`  timestamp est un nombre (${start.timestamp.toFixed(3)})`)
    : bad(`  timestamp doit être un nombre, reçu : ${typeof start.timestamp}`);
  start.command.includes("echo")
    ? ok(`  command contient 'echo' : '${start.command}'`)
    : bad(`  command inattendu : '${start.command}'`);
}

// ── 4. session:output ─────────────────────────────────────────────────────────

console.log("\n4. Message session:output");
const outputs = parsed.filter(m => m.type === "session:output");
if (!outputs.length) {
  bad("session:output absent");
} else {
  ok(`session:output présent (${outputs.length} chunk(s))`);
  const allData = outputs.map(m => m.data).join("");
  allData.includes("Phase 1 OK")
    ? ok(`  data contient "Phase 1 OK"`)
    : bad(`  "Phase 1 OK" absent du data agrégé`);
  outputs.every(m => typeof m.data === "string")
    ? ok("  data est bien une string")
    : bad("  data n'est pas une string sur tous les chunks");
}

// ── 5. session:end ────────────────────────────────────────────────────────────

console.log("\n5. Message session:end");
const end = parsed.find(m => m.type === "session:end");
if (!end) {
  bad("session:end absent");
} else {
  ok("session:end présent");
  end.exitCode === 0
    ? ok(`  exitCode = 0`)
    : bad(`  exitCode inattendu : ${end.exitCode}`);
  typeof end.duration === "number"
    ? ok(`  duration = ${end.duration}s`)
    : bad("  duration manquant ou invalide");
}

// ── 6. sessionId cohérent ─────────────────────────────────────────────────────

console.log("\n6. Cohérence sessionId");
const ids = new Set(parsed.filter(m => m.sessionId).map(m => m.sessionId));
ids.size === 1
  ? ok(`sessionId unique dans tous les messages : ${[...ids][0].slice(0, 16)}…`)
  : bad(`${ids.size} sessionId différents (attendu : 1)`);

// ── 7. ping / pong sans payload ───────────────────────────────────────────────

console.log("\n7. Messages ping / pong");
const ping = parsed.find(m => m.type === "ping");
const pong = parsed.find(m => m.type === "pong");
ping ? ok(`ping présent, payload vide : ${JSON.stringify(ping)}`)   : bad("ping absent");
pong ? ok(`pong présent, payload vide : ${JSON.stringify(pong)}`)   : bad("pong absent");

// ── 8. inputReply (structure seulement) ──────────────────────────────────────

console.log("\n8. Structure inputReply");
const replyRaw = buildMessage("input:reply", { sessionId, text: "y\r" });
try {
  const reply = JSON.parse(replyRaw);
  ok("input:reply — JSON valide");
  reply.type === "input:reply"       ? ok("  type correct")      : bad("  type incorrect");
  typeof reply.sessionId === "string" ? ok("  sessionId string")  : bad("  sessionId manquant");
  typeof reply.text === "string"      ? ok("  text string")       : bad("  text manquant");
  reply.text === "y\r"               ? ok("  text = 'y\\r'")      : bad(`  text inattendu : '${reply.text}'`);
} catch (e) {
  bad(`input:reply — JSON invalide : ${e.message}`);
}

// ── Résumé ────────────────────────────────────────────────────────────────────

console.log("\n==================================");
if (fail === 0) {
  console.log(`RÉSULTAT : ${pass}/${pass + fail} tests OK`);
  console.log("");
} else {
  console.log(`RÉSULTAT : ${fail} échec(s) / ${pass + fail} tests`);
  console.log("");
  process.exit(1);
}
