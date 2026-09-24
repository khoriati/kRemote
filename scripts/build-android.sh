#!/usr/bin/env bash
# Build Android.
#   scripts/build-android.sh debug            # APK de depuração (instalável direto)
#   scripts/build-android.sh release          # APK release (assinado se houver keystore)
#   scripts/build-android.sh bundle           # AAB para a Play Store
#   scripts/build-android.sh install [debug]  # compila e instala no aparelho conectado (Moto G50 etc.)
#
# Assinatura release: exporte as variáveis abaixo (ou crie android/key.properties):
#   KEYSTORE_PATH, KEYSTORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD
# Sem elas, o release usa a chave de depuração (apenas para testes internos).
source "$(dirname "$0")/_common.sh"
ensure_deps

MODE="${1:-debug}"
VERSION="$(app_version)"
NUMBER="$(build_number)"
OUT="build/dist/android"
mkdir -p "$OUT"

write_key_properties() {
  if [[ -n "${KEYSTORE_PATH:-}" ]]; then
    cat > android/key.properties <<PROPS
storeFile=${KEYSTORE_PATH}
storePassword=${KEYSTORE_PASSWORD:?KEYSTORE_PASSWORD}
keyAlias=${KEY_ALIAS:?KEY_ALIAS}
keyPassword=${KEY_PASSWORD:?KEY_PASSWORD}
PROPS
    ok "android/key.properties gerado a partir do ambiente"
  elif [[ ! -f android/key.properties ]]; then
    warn "Sem keystore: release será assinado com a chave de depuração"
  fi
}

case "$MODE" in
  debug)
    log "APK debug v$VERSION ($NUMBER)"
    flutter build apk --debug --build-name "$VERSION" --build-number "$NUMBER"
    cp build/app/outputs/flutter-apk/app-debug.apk "$OUT/kremote-$VERSION-debug.apk"
    ;;
  release)
    write_key_properties
    log "APK release v$VERSION ($NUMBER)"
    flutter build apk --release --build-name "$VERSION" --build-number "$NUMBER" --obfuscate --split-debug-info=build/symbols/android
    cp build/app/outputs/flutter-apk/app-release.apk "$OUT/kremote-$VERSION.apk"
    ;;
  bundle)
    write_key_properties
    log "AAB release v$VERSION ($NUMBER)"
    flutter build appbundle --release --build-name "$VERSION" --build-number "$NUMBER" --obfuscate --split-debug-info=build/symbols/android
    cp build/app/outputs/bundle/release/app-release.aab "$OUT/kremote-$VERSION.aab"
    ;;
  install)
    SUB="${2:-debug}"
    DEVICE="$(flutter devices --machine | python3 -c 'import sys,json;d=[x for x in json.load(sys.stdin) if x["targetPlatform"].startswith("android")];print(d[0]["id"] if d else "")')"
    [[ -n "$DEVICE" ]] || die "Nenhum Android conectado (ative a depuração USB)"
    log "Instalando ($SUB) em $DEVICE"
    flutter install -d "$DEVICE" --"$SUB"
    ok "Instalado"
    exit 0
    ;;
  *) die "modo desconhecido: $MODE (debug|release|bundle|install)" ;;
esac
ok "Artefatos em $OUT:"; ls -la "$OUT"
