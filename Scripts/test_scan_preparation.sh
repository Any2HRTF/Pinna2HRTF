#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
"${PINNA2HRTF_PYTHON:-$ROOT/.venv/bin/python}" -m unittest discover -s Tests -p 'test_*.py'
if [[ "$(uname -s)" != Darwin ]]; then exit 0; fi
SDK_PATH="$(xcrun --sdk "${PINNA2HRTF_MACOS_SDK:-macosx26.5}" --show-sdk-path)"
SDK_SWIFT_INTERFACE="$(find "$SDK_PATH/usr/lib/swift/Swift.swiftmodule" -name '*-apple-macos.swiftinterface' -print -quit)"
SDK_SWIFT_VERSION="$(sed -n 's|// swift-compiler-version: Apple Swift version \([^ ]*\).*|\1|p' "$SDK_SWIFT_INTERFACE")"
CHECK_BIN="$(mktemp /private/tmp/pinna-scan-checks.XXXXXX)"
trap 'rm -f "$CHECK_BIN"' EXIT
CLANG_MODULE_CACHE_PATH=/private/tmp/pinna2hrtf-clang-cache swiftc -sdk "$SDK_PATH" \
  -Xfrontend -interface-compiler-version -Xfrontend "$SDK_SWIFT_VERSION" \
  Sources/Pinna2HRTF/Models/PipelineModels.swift Sources/Pinna2HRTF/Models/MeshEditorModels.swift Sources/Pinna2HRTF/Support/Defaults.swift \
  Sources/Pinna2HRTF/Services/ProjectConfigDocument.swift Sources/Pinna2HRTF/Services/ProjectDuplicator.swift Sources/Pinna2HRTF/Services/ProjectValidation.swift \
  Sources/Pinna2HRTF/Services/PipelineConfigWriter.swift Sources/Pinna2HRTF/Services/ArtifactScanner.swift \
  Sources/Pinna2HRTF/Services/GeneratedOutputManifest.swift Sources/Pinna2HRTF/Services/PipelineLogCapture.swift \
  Sources/Pinna2HRTF/Services/ProjectStatusSnapshot.swift Tests/ProjectStatusSnapshotChecks.swift Tests/SpatialUpsamplingChecks.swift Sources/Pinna2HRTF/Services/ProcessTreeTerminator.swift Tests/ProcessChecks.swift Tests/ProjectDuplicationChecks.swift Tests/OutputResetChecks.swift Tests/ScanPreparationChecks.swift -o "$CHECK_BIN"
"$CHECK_BIN"

CLANG_MODULE_CACHE_PATH=/private/tmp/pinna2hrtf-clang-cache swiftc -sdk "$SDK_PATH" \
  -Xfrontend -interface-compiler-version -Xfrontend "$SDK_SWIFT_VERSION" \
  Sources/Pinna2HRTF/Models/PipelineModels.swift Sources/Pinna2HRTF/Models/MeshEditorModels.swift Sources/Pinna2HRTF/Support/Defaults.swift \
  Sources/Pinna2HRTF/Services/ProjectConfigDocument.swift Sources/Pinna2HRTF/Services/ProjectValidation.swift \
  Sources/Pinna2HRTF/Services/PipelineConfigWriter.swift Sources/Pinna2HRTF/Services/ArtifactScanner.swift \
  Sources/Pinna2HRTF/Services/GeneratedOutputManifest.swift Sources/Pinna2HRTF/Services/MeshEditorModel.swift \
  Sources/Pinna2HRTF/Services/PressureFieldModel.swift Sources/Pinna2HRTF/Views/NavigableSCNView.swift Sources/Pinna2HRTF/Views/PPMFittingSceneView.swift Sources/Pinna2HRTF/Views/MeshWorkspaceSplitView.swift Sources/Pinna2HRTF/Views/CoordinateSystem.swift Sources/Pinna2HRTF/Services/PPMTargetAppearance.swift Sources/Pinna2HRTF/Views/EditorSCNView.swift Tests/PressureFieldChecks.swift Tests/PPMTargetAppearanceChecks.swift Tests/PPMFittingCameraChecks.swift Tests/MeshWorkspaceLayoutChecks.swift Tests/MeshEditorChecks.swift -o "$CHECK_BIN"
"$CHECK_BIN"
