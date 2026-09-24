#!/usr/bin/env bash
# Atalhos de desenvolvimento.
#   scripts/dev.sh run [device-id]   # flutter run (lista aparelhos se não informado)
#   scripts/dev.sh devices           # aparelhos conectados
#   scripts/dev.sh probe <ip> <cmd>  # sonda Android TV pela linha de comando (ver tool/atv_probe.dart)
#   scripts/dev.sh clean             # limpa builds
source "$(dirname "$0")/_common.sh"
require flutter
case "${1:-run}" in
  devices) flutter devices ;;
  run)
    if [[ -n "${2:-}" ]]; then flutter run -d "$2"; else flutter devices; echo; flutter run; fi ;;
  probe) shift; dart run tool/atv_probe.dart "$@" ;;
  clean) flutter clean && rm -rf build/dist && ok "Limpo" ;;
  *) die "uso: dev.sh run|devices|probe|clean" ;;
esac
