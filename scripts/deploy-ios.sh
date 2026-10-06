#!/usr/bin/env bash
# Deploy no iPhone: build release (sem debug, ofuscado) + instalação.
#   scripts/deploy-ios.sh [device-id]
exec "$(dirname "$0")/build-ios.sh" device "$@"
