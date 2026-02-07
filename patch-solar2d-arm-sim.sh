#!/bin/bash
#
# patch-solar2d-arm-sim.sh
#
# Patches Solar2D 3727 simulator templates to:
# 1. Compile arm64 slices for iOS/tvOS Simulator on Apple Silicon Macs
# 2. Fix the -miphoneos-version-min flag for simulator builds (should be
#    -mios-simulator-version-min for arm64 simulator targets)
#
# Solar2D's Defaults.lua only compiles x86_64 for simulator targets, and
# hardcodes -miphoneos-version-min for ALL builds including simulator.
# On arm64, the linker distinguishes iOS vs iOS-simulator platforms and
# refuses to link simulator frameworks with a device version-min flag.
#
# Run this after installing/reinstalling Solar2D:
#   bash patch-solar2d-arm-sim.sh
#

set -euo pipefail

SOLAR2D_APP="/Applications/Corona-3727/Corona Simulator.app"
TEMPLATE_DIR="$SOLAR2D_APP/Contents/Resources/iostemplate"

if [ ! -d "$TEMPLATE_DIR" ]; then
    echo "ERROR: Solar2D template directory not found at $TEMPLATE_DIR"
    echo "       Is Solar2D 3727 installed?"
    exit 1
fi

PATCHED=0
SKIPPED=0

patch_template() {
    local archive="$1"
    local basename
    basename=$(basename "$archive")

    if [ ! -f "$archive" ]; then
        echo "  SKIP: $basename (not found)"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)

    # Extract
    tar xjf "$archive" -C "$tmpdir" 2>/dev/null

    local defaults="$tmpdir/libtemplate/Defaults.lua"
    if [ ! -f "$defaults" ]; then
        echo "  SKIP: $basename (no Defaults.lua)"
        rm -rf "$tmpdir"
        ((SKIPPED++)) || true
        return
    fi

    # Use Python for reliable text replacement (tabs in Lua source)
    # Two patches:
    #   1. Add "arm64" to the simulator architecture list in modernSlices()
    #   2. Fix -miphoneos-version-min to -mios-simulator-version-min for simulator templates
    local rc=0
    python3 -c "
import sys

with open(sys.argv[1], 'r') as f:
    content = f.read()

changed = False

# --- Patch 1: Add arm64 to simulator architecture list ---
old_arch = '\t\t\t\"x86_64\",\n\t\t},'
new_arch = '\t\t\t\"x86_64\",\n\t\t\t\"arm64\",\n\t\t},'

# Only patch inside modernSlices
idx = content.find('modernSlices = function')
if idx == -1:
    sys.exit(1)

search_start = idx
first_match = content.find(old_arch, search_start)
if first_match != -1:
    content = content[:first_match] + new_arch + content[first_match + len(old_arch):]
    changed = True

# --- Patch 2: Fix version-min flag for simulator builds ---
# Replace hardcoded -miphoneos-version-min with -mios-simulator-version-min
# in the updateFlags function. The original line is:
#   '-miphoneos-version-min=' .. minVersion,
# We need to make it conditional on sdkType, but since Defaults.lua may not
# have easy access to sdkType in updateFlags, we replace the flag directly
# for simulator templates (this script only runs on simulator archives).
old_flag = \"'-miphoneos-version-min=' .. minVersion\"
new_flag = \"'-mios-simulator-version-min=' .. minVersion\"

if old_flag in content:
    content = content.replace(old_flag, new_flag)
    changed = True

if not changed:
    # Already patched
    sys.exit(2)

with open(sys.argv[1], 'w') as f:
    f.write(content)
" "$defaults" || rc=$?
    if [ $rc -eq 2 ]; then
        echo "  OK:   $basename (already patched)"
        rm -rf "$tmpdir"
        ((SKIPPED++)) || true
        return
    elif [ $rc -ne 0 ]; then
        echo "  FAIL: $basename (no modernSlices function found)"
        rm -rf "$tmpdir"
        return
    fi

    # Verify both patches
    local verify_ok=true
    if ! grep -q '"arm64"' "$defaults"; then
        echo "  FAIL: $basename (arm64 patch verification failed)"
        verify_ok=false
    fi
    if grep -q 'miphoneos-version-min' "$defaults"; then
        echo "  FAIL: $basename (version-min patch verification failed)"
        verify_ok=false
    fi
    if [ "$verify_ok" = false ]; then
        rm -rf "$tmpdir"
        return
    fi

    # Re-compress (bzip2, tar) — preserve same structure
    (cd "$tmpdir" && tar cjf "$archive" ./* 2>/dev/null || tar cjf "$archive" *)

    echo "  DONE: $basename"
    rm -rf "$tmpdir"
    ((PATCHED++)) || true
}

echo "Patching Solar2D simulator templates for arm64 + version-min fix..."
echo "Template dir: $TEMPLATE_DIR"
echo ""

echo "iOS Simulator templates:"
for f in "$TEMPLATE_DIR"/iphonesimulator_*.tar.bz; do
    patch_template "$f"
done

echo ""
echo "tvOS Simulator templates:"
for f in "$TEMPLATE_DIR"/appletvsimulator_*.tar.bz; do
    patch_template "$f"
done

echo ""
echo "Done. Patched $PATCHED templates, skipped $SKIPPED."
echo ""
echo "Now rebuild your app in Solar2D — the iOS/tvOS Simulator build"
echo "will include arm64 and run natively on Apple Silicon."
