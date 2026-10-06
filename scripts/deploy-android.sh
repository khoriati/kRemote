#!/usr/bin/env bash
# Deploy no Android: build release (sem debug, ofuscado) + instalação via USB.
#   scripts/deploy-android.sh [device-id]
exec "$(dirname "$0")/build-android.sh" install release "$@"
