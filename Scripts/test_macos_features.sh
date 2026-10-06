#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="$(xcrun --sdk "${PINNA2HRTF_MACOS_SDK:-macosx26.5}" --show-sdk-path)"
TEST_DIR="$(mktemp -d /private/tmp/pinna2hrtf-feature-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -sdk "$SDK" -module-cache-path /private/tmp/pinna2hrtf-test-module-cache \
  "$ROOT/Sources/Pinna2HRTF/Models/PipelineModels.swift" \
  "$ROOT/Sources/Pinna2HRTF/Services/GeneratedOutputManifest.swift" \
  "$ROOT/Sources/Pinna2HRTF/Services/ArtifactScanner.swift" \
  "$ROOT/Sources/Pinna2HRTF/Services/PipelineConfigWriter.swift" \
  "$ROOT/Tests/MacOSFeatureChecks.swift" -o "$TEST_DIR/checks"
"$TEST_DIR/checks"
