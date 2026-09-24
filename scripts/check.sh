#!/usr/bin/env bash
# Qualidade: formatação, análise estática e testes (com cobertura opcional).
#   scripts/check.sh            # format check + analyze + test
#   scripts/check.sh --coverage # idem, gera coverage/lcov.info
source "$(dirname "$0")/_common.sh"
ensure_deps

log "Verificando formatação"
dart format --output=none --set-exit-if-changed --line-length 120 lib test tool || die "Rode: dart format --line-length 120 lib test tool"

log "Analisando"
flutter analyze --fatal-infos

log "Testando"
if [[ "${1:-}" == "--coverage" ]]; then
  flutter test --coverage
  ok "Cobertura em coverage/lcov.info"
else
  flutter test
fi
ok "Tudo verde"
