#!/usr/bin/env bash
# Funções compartilhadas pelos scripts de build do kRemote.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

log()  { printf '\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "'$1' não encontrado no PATH"; }

flutter_version() { flutter --version --machine 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["frameworkVersion"])' 2>/dev/null || echo "?"; }

# Versão do app (pubspec: version: X.Y.Z+N). BUILD_NUMBER sobrescreve N.
app_version() { sed -n 's/^version: *\([0-9.]*\)+\?\([0-9]*\).*/\1/p' pubspec.yaml; }
build_number() { echo "${BUILD_NUMBER:-$(sed -n 's/^version: *[0-9.]*+\([0-9]*\).*/\1/p' pubspec.yaml)}"; }

ensure_deps() {
  require flutter
  log "Flutter $(flutter_version) — resolvendo dependências"
  flutter pub get >/dev/null
}
