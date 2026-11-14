#!/bin/bash
# Builds everything, then runs the CompanionCore and StandByProtocol tests.
# None of these tests touch Music.app; msbctl does that (see README.md).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
"$root/scripts/build.sh"
echo "› running CompanionCoreTests"
"$root/.build/swiftc/CompanionCoreTests" "$@"
echo "› running StandByProtocol tests"
"$root/../Shared/StandByProtocol/scripts/test.sh"
