#!/usr/bin/env bash
# Build Android.
#   scripts/build-android.sh debug            # APK de depuração (instalável direto)
#   scripts/build-android.sh release          # APK release (assinado se houver keystore)
#   scripts/build-android.sh bundle           # AAB para a Play Store
#   scripts/build-android.sh install [debug|release] [id]  # deploy: compila e instala por cima (mantém dados)
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
    DEVICE="${3:-$(flutter devices --machine | python3 -c 'import sys,json;d=[x for x in json.load(sys.stdin) if x["targetPlatform"].startswith("android")];print(d[0]["id"] if d else "")')}"
    [[ -n "$DEVICE" ]] || die "Nenhum Android conectado (ative a depuração USB)"
    if [[ "$SUB" == "release" ]]; then
      write_key_properties
      log "APK release v$VERSION ($NUMBER) — ofuscado, sem debug"
      flutter build apk --release --build-name "$VERSION" --build-number "$NUMBER" --obfuscate --split-debug-info=build/symbols/android
    else
      log "APK debug v$VERSION ($NUMBER)"
      flutter build apk --debug --build-name "$VERSION" --build-number "$NUMBER"
    fi
    log "Instalando ($SUB) em $DEVICE (atualização por cima, preserva cadastros e emparelhamentos)"
    require adb
    adb -s "$DEVICE" get-state >/dev/null 2>&1 || die "Aparelho $DEVICE não está visível ao adb (cabo USB / depuração)"
    # `flutter install` desinstala antes; `adb install -r` atualiza mantendo os dados.
    adb -s "$DEVICE" install -r "build/app/outputs/flutter-apk/app-$SUB.apk" \
      || { warn "adb install -r falhou (assinatura diferente?); usando flutter install (apaga os dados do app)"; flutter install -d "$DEVICE" --"$SUB"; }
    ok "Instalado — abra o kRemote no aparelho"
    exit 0
    ;;
  *) die "modo desconhecido: $MODE (debug|release|bundle|install)" ;;
esac
ok "Artefatos em $OUT:"; ls -la "$OUT"
