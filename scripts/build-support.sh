#!/bin/bash
# Keep build products outside sync-managed source folders. Swift 6.4 signs resource
# bundles during compilation; Finder/iCloud attributes can otherwise invalidate them.
SWEEP_CHECKOUT_ID="$(printf '%s' "$PROJECT_DIR" | shasum -a 256 | cut -c1-16)"
SWEEP_BUILD_PATH="${SWEEP_BUILD_PATH:-$HOME/Library/Caches/ProjectSweep/Builds/$SWEEP_CHECKOUT_ID}"
BUILD_ARGS=(--scratch-path "$SWEEP_BUILD_PATH")

configure_core_link_inputs() {
    CORE_OBJECTS=("$BIN_DIR"/CleanupCore.build/*.swift.o)
    MODULE_DIR="$BIN_DIR/Modules"
    if [[ -f "$BIN_DIR/libCleanupCore.a" ]]; then
        CORE_OBJECTS=("$BIN_DIR/libCleanupCore.a")
        MODULE_DIR="$BIN_DIR"
    fi
}
