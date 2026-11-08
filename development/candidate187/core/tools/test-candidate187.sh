#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_root="$(mktemp -d /private/tmp/avp-base179-affected36-c187-XXXXXX)"
export AVPPLAY_TEST_FIXTURE_ROOT="$fixture_root"
export AVPPLAY_HOME="$fixture_root/data"
export AVPPLAY_TEST_RUNTIME850_RESOURCES="$PWD/../dist/AVP Play Candidate 187.app/Contents/Resources/optional-runtime"
mkdir -p "$AVPPLAY_HOME"
echo "Disposable test data: $fixture_root"
swift test "$@"
