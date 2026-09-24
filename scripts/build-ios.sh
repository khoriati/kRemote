#!/usr/bin/env bash
# Build iOS.
#   scripts/build-ios.sh setup             # dependências nativas + abre assinatura no Xcode (1ª vez)
#   scripts/build-ios.sh run               # compila e roda no iPhone conectado (debug, hot reload)
#   scripts/build-ios.sh device            # instala build release no iPhone conectado
#   scripts/build-ios.sh ipa               # .ipa para distribuição (TestFlight/ad-hoc)
#   scripts/build-ios.sh archive-nosign    # .xcarchive sem assinatura (CI)
#
# Assinatura: defina IOS_TEAM_ID (Apple Developer Team) e, para ipa,
# IOS_EXPORT_METHOD (app-store|ad-hoc|development; padrão development).
source "$(dirname "$0")/_common.sh"
[[ "$(uname)" == "Darwin" ]] || die "Builds iOS exigem macOS"
require xcodebuild
ensure_deps

MODE="${1:-run}"
VERSION="$(app_version)"
NUMBER="$(build_number)"
OUT="build/dist/ios"
mkdir -p "$OUT"

apply_team() {
  if [[ -n "${IOS_TEAM_ID:-}" ]]; then
    log "Aplicando DEVELOPMENT_TEAM=$IOS_TEAM_ID ao projeto"
    sed -i '' -E "s/(DEVELOPMENT_TEAM = )[^;]*;/\1${IOS_TEAM_ID};/g; s/(PRODUCT_BUNDLE_IDENTIFIER = br\.com\.khori\.kremote;)/\1/" ios/Runner.xcodeproj/project.pbxproj
    grep -q "DEVELOPMENT_TEAM = $IOS_TEAM_ID" ios/Runner.xcodeproj/project.pbxproj || \
      sed -i '' -E "s/(CODE_SIGN_STYLE = Automatic;)/\1\n\t\t\t\tDEVELOPMENT_TEAM = ${IOS_TEAM_ID};/" ios/Runner.xcodeproj/project.pbxproj
  else
    warn "IOS_TEAM_ID não definido; usando a equipe configurada no Xcode"
  fi
}

iphone_id() {
  flutter devices --machine | python3 -c 'import sys,json;d=[x for x in json.load(sys.stdin) if x["targetPlatform"]=="ios" and not x.get("emulator")];print(d[0]["id"] if d else "")'
}

case "$MODE" in
  setup)
    log "Instalando pods"
    (cd ios && pod install --repo-update)
    apply_team
    ok "Abrindo Xcode — em Runner › Signing & Capabilities selecione sua equipe"
    open ios/Runner.xcworkspace
    ;;
  run)
    apply_team
    DEVICE="$(iphone_id)"; [[ -n "$DEVICE" ]] || die "Nenhum iPhone conectado/confiável"
    log "Rodando no iPhone $DEVICE (debug)"
    flutter run -d "$DEVICE"
    ;;
  device)
    apply_team
    DEVICE="$(iphone_id)"; [[ -n "$DEVICE" ]] || die "Nenhum iPhone conectado/confiável"
    log "Instalando release no iPhone $DEVICE"
    flutter build ios --release --build-name "$VERSION" --build-number "$NUMBER"
    flutter install -d "$DEVICE" --release
    ok "Instalado"
    ;;
  ipa)
    apply_team
    METHOD="${IOS_EXPORT_METHOD:-development}"
    log "Gerando IPA ($METHOD) v$VERSION ($NUMBER)"
    cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>${METHOD}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>stripSwiftSymbols</key><true/>
  <key>compileBitcode</key><false/>
  $( [[ -n "${IOS_TEAM_ID:-}" ]] && echo "<key>teamID</key><string>${IOS_TEAM_ID}</string>" )
</dict></plist>
PLIST
    flutter build ipa --release --build-name "$VERSION" --build-number "$NUMBER" \
      --obfuscate --split-debug-info=build/symbols/ios --export-options-plist build/ExportOptions.plist
    cp build/ios/ipa/*.ipa "$OUT/kremote-$VERSION.ipa"
    ok "IPA em $OUT"; ls -la "$OUT"
    ;;
  archive-nosign)
    log "Archive sem assinatura"
    flutter build ios --release --no-codesign --build-name "$VERSION" --build-number "$NUMBER"
    ok "Runner.app em build/ios/iphoneos"
    ;;
  *) die "modo desconhecido: $MODE (setup|run|device|ipa|archive-nosign)" ;;
esac
