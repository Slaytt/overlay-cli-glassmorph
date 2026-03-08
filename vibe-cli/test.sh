#!/usr/bin/env bash
# test.sh — point d'entrée du test CLI VibeTerminal.
# Délègue la validation du protocole JSON à test.js (Node.js ESM).
#
# Usage :
#   cd vibe-cli && bash test.sh

set -euo pipefail
cd "$(dirname "$0")"

# Vérifier que node est disponible
if ! command -v node &>/dev/null; then
  echo "[FAIL] node n'est pas installé ou pas dans le PATH" >&2
  exit 1
fi

# Vérifier que les dépendances sont installées
if [[ ! -d node_modules ]]; then
  echo "[INFO] node_modules absent — lancement de npm install…"
  npm install --silent
fi

# Lancer le test du protocole JSON
node test.js
