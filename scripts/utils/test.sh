#!/usr/bin/env bash
#
# Test pipelines.
#
#   ./scripts/utils/test.sh          # fast: unit tests only (pure logic, seconds)
#   ./scripts/utils/test.sh --slow   # slow: end-to-end script tests — actually runs
#                              # build.sh / bundle.sh / release.sh and inspects
#                              # the dist/ artifacts they produce (minutes)
#   ./scripts/utils/test.sh --all    # both
#
# The slow suite lives in Tests/ccdeckScriptTests and is gated behind
# CCDECK_SLOW_TESTS=1, so a plain `swift test` stays fast (slow tests show as
# skipped). It never notarizes or publishes: bundle runs with --no-notarize and
# release runs with --dry-run.
set -euo pipefail

cd "$(dirname "$0")/../.."

case "${1:-}" in
    "")
        swift test --filter ccdeckTests
        ;;
    --slow)
        CCDECK_SLOW_TESTS=1 swift test --filter ccdeckScriptTests
        ;;
    --all)
        CCDECK_SLOW_TESTS=1 swift test
        ;;
    *)
        echo "usage: $0 [--slow|--all]" >&2
        exit 2
        ;;
esac
