#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift build
BIN_DIR="$(swift build --show-bin-path)"
SDK_DIR="$(xcrun --sdk macosx --show-sdk-path)"
CHECK_DIR="$PROJECT_DIR/.build/ui-boundary-checks"
mkdir -p "$CHECK_DIR"
CORE_OBJECTS=("$BIN_DIR"/CleanupCore.build/*.swift.o)
COMMON=(-parse-as-library -swift-version 6 -sdk "$SDK_DIR" -target arm64-apple-macosx14.0 -I "$BIN_DIR/Modules" -I Sources/CSQLite -lsqlite3)
swiftc "${COMMON[@]}" Sources/ProjectSweepApp/PreviewSafety.swift Tests/Acceptance/PreviewChecks.swift "${CORE_OBJECTS[@]}" -o "$CHECK_DIR/preview-checks"
"$CHECK_DIR/preview-checks"
swiftc "${COMMON[@]}" Sources/ProjectSweepApp/PreviewSafety.swift Sources/ProjectSweepApp/FolderGrants.swift Sources/ProjectSweepApp/BrowserState.swift Sources/ProjectSweepApp/ProjectTree.swift Sources/ProjectSweepApp/ToolInspection.swift Sources/ProjectSweepApp/SkillManagementState.swift Sources/ProjectSweepApp/SweepState.swift Tests/Acceptance/OutcomeChecks.swift "${CORE_OBJECTS[@]}" -o "$CHECK_DIR/outcome-checks"
"$CHECK_DIR/outcome-checks"
swiftc "${COMMON[@]}" Sources/ProjectSweepApp/PreviewSafety.swift Sources/ProjectSweepApp/FolderGrants.swift Sources/ProjectSweepApp/BrowserState.swift Sources/ProjectSweepApp/ProjectTree.swift Sources/ProjectSweepApp/ToolInspection.swift Sources/ProjectSweepApp/SkillManagementState.swift Sources/ProjectSweepApp/SweepState.swift Tests/Acceptance/ProjectWorkflowChecks.swift "${CORE_OBJECTS[@]}" -o "$CHECK_DIR/project-workflow-checks"
"$CHECK_DIR/project-workflow-checks"
swiftc "${COMMON[@]}" Sources/ProjectSweepApp/PreviewSafety.swift Sources/ProjectSweepApp/FolderGrants.swift Sources/ProjectSweepApp/BrowserState.swift Sources/ProjectSweepApp/ProjectTree.swift Sources/ProjectSweepApp/ToolInspection.swift Sources/ProjectSweepApp/SkillManagementState.swift Sources/ProjectSweepApp/SweepState.swift Tests/Acceptance/UsabilityStateChecks.swift "${CORE_OBJECTS[@]}" -o "$CHECK_DIR/usability-state-checks"
"$CHECK_DIR/usability-state-checks"

swiftc "${COMMON[@]}" Sources/ProjectSweepApp/FolderGrants.swift Sources/ProjectSweepApp/SkillManagementState.swift Tests/Acceptance/SkillStateChecks.swift "${CORE_OBJECTS[@]}" -o "$CHECK_DIR/skill-state-checks"
"$CHECK_DIR/skill-state-checks"

swiftc "${COMMON[@]}" Sources/ProjectSweepApp/PreviewSafety.swift Sources/ProjectSweepApp/FolderGrants.swift Sources/ProjectSweepApp/BrowserState.swift Sources/ProjectSweepApp/ProjectTree.swift Sources/ProjectSweepApp/ToolInspection.swift Sources/ProjectSweepApp/SkillManagementState.swift Sources/ProjectSweepApp/SweepState.swift Tests/Acceptance/ProjectTreeChecks.swift "${CORE_OBJECTS[@]}" -o "$CHECK_DIR/project-tree-checks"
"$CHECK_DIR/project-tree-checks"

swiftc "${COMMON[@]}" Sources/ProjectSweepApp/BrowserState.swift Tests/Acceptance/ProjectLibraryFilterChecks.swift "${CORE_OBJECTS[@]}" -o "$CHECK_DIR/project-library-filter-checks"
"$CHECK_DIR/project-library-filter-checks"

swiftc "${COMMON[@]}" Sources/ProjectSweepApp/PreviewSafety.swift Sources/ProjectSweepApp/FolderGrants.swift Sources/ProjectSweepApp/BrowserState.swift Sources/ProjectSweepApp/ProjectTree.swift Sources/ProjectSweepApp/ToolInspection.swift Sources/ProjectSweepApp/SkillManagementState.swift Sources/ProjectSweepApp/SweepState.swift Tests/Acceptance/ToolAutoDiscoveryChecks.swift "${CORE_OBJECTS[@]}" -o "$CHECK_DIR/tool-auto-discovery-checks"
"$CHECK_DIR/tool-auto-discovery-checks"
