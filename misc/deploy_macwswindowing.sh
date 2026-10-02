# Run explicitly with bash; keeping this file shebang-free also makes a synced
# copy safe under the jailbreak's AMFI shebang restriction.
# Usage: bash misc/deploy_macwswindowing.sh [device-ip] [--activate]
# Staging is the default. --activate explicitly installs and restarts SpringBoard.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DEVICE_IP="${1:-192.168.1.6}"
ACTIVATE=0
if [ "${2:-}" = --activate ]; then
    ACTIVATE=1
elif [ "$#" -gt 1 ]; then
    echo 'Error: second argument must be --activate when activation is intended.' >&2
    exit 64
fi
DEVICE_USER="${MACWS_DEVICE_USER:-mobile}"
DEVICE_SSH="${DEVICE_USER}@${DEVICE_IP}"
BUILD_DIR="$PROJECT_DIR/MacWSWindowing"
BUILT="$BUILD_DIR/.theos/obj/MacWSWindowing.dylib"
REMOTE_DIR=/var/jb/var/mobile/macws-cross-build
REMOTE_NEW="$REMOTE_DIR/MacWSWindowing.dylib.new"
REMOTE_BINARY="$REMOTE_DIR/MacWSWindowing.dylib"
REMOTE_SHA="$REMOTE_DIR/MacWSWindowing.sha256"
REMOTE_MANIFEST="$REMOTE_DIR/MacWSWindowing.build.json"
INSTALLED=/var/jb/Library/MobileSubstrate/DynamicLibraries/MacWSWindowing.dylib

FIXUPS=$(mktemp)
BUILD_MANIFEST=$(mktemp)
SOURCE_SNAPSHOT=$(mktemp)
trap 'rm -f "$FIXUPS" "$BUILD_MANIFEST" "$SOURCE_SNAPSHOT"' EXIT
python3 "$SCRIPT_DIR/macws_artifact_contract.py" snapshot \
    --root "$PROJECT_DIR" --manifest "$SOURCE_SNAPSHOT"

gmake -C "$BUILD_DIR" clean all \
    FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 \
    THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1

[ -s "$BUILT" ] || {
    echo "Error: MacWSWindowing build product not found: $BUILT" >&2
    exit 1
}

dyld_info -arch arm64e -fixups "$BUILT" > "$FIXUPS"
cf_count=$(awk '$2 == "__cfstring" && $4 == "auth-bind" && /key=DA/ { count++ } END { print count+0 }' "$FIXUPS")
plain_cf_count=$(awk '$2 == "__cfstring" && $4 == "bind" { count++ } END { print count+0 }' "$FIXUPS")
if [ "$cf_count" -lt 1 ] || [ "$plain_cf_count" -ne 0 ]; then
    echo "Error: Apple-ld64 auth-fixup invariant failed (auth=$cf_count plain=$plain_cf_count)." >&2
    exit 1
fi
echo "==> Verified arm64e __cfstring fixups: auth-bind/key=DA count=$cf_count, plain-bind count=0"

# A default/rootful Theos build can have perfectly valid arm64e authenticated
# fixups while still naming Substrate at /Library/Frameworks.  Dopamine's
# rootless SpringBoard cannot resolve that path and ElleKit simply omits the
# tweak.  Verify the actual LC_LOAD_DYLIB commands before publishing it.
LOAD_COMMANDS=$(otool -L "$BUILT")
if printf '%s\n' "$LOAD_COMMANDS" | grep -q $'\t/Library/'; then
    echo 'Error: MacWSWindowing contains rootful /Library load commands.' >&2
    printf '%s\n' "$LOAD_COMMANDS" >&2
    exit 1
fi
if ! printf '%s\n' "$LOAD_COMMANDS" |
        grep -q $'\t@rpath/CydiaSubstrate.framework/CydiaSubstrate '; then
    echo 'Error: MacWSWindowing lacks its rootless @rpath Substrate dependency.' >&2
    printf '%s\n' "$LOAD_COMMANDS" >&2
    exit 1
fi
echo '==> Verified rootless MacWSWindowing load commands'
python3 "$SCRIPT_DIR/macws_artifact_contract.py" create \
    --root "$PROJECT_DIR" --binary "$BUILT" --manifest "$BUILD_MANIFEST" \
    --source-snapshot "$SOURCE_SNAPSHOT"

ssh "$DEVICE_SSH" "mkdir -p '$REMOTE_DIR'"
scp "$BUILT" "$DEVICE_SSH:$REMOTE_NEW"
scp "$BUILD_MANIFEST" "$DEVICE_SSH:${REMOTE_MANIFEST}.new"

# A package-verification build only needs the validated Apple-ld64 artifact
# in the on-device cache. Do not replace the live tweak or restart SpringBoard
# until the user explicitly chooses to activate the new version.
if [ "$ACTIVATE" != 1 ] || [ "${MACWS_WINDOWING_STAGE_ONLY:-0}" = 1 ]; then
    ssh -t "$DEVICE_SSH" "sudo sh -c '
set -e
ldid -h \"$REMOTE_NEW\" >/dev/null
mv \"$REMOTE_NEW\" \"$REMOTE_BINARY\"
mv \"${REMOTE_MANIFEST}.new\" \"$REMOTE_MANIFEST\"
chown root:wheel \"$REMOTE_BINARY\"
chmod 0755 \"$REMOTE_BINARY\"
sha256sum \"$REMOTE_BINARY\" > \"$REMOTE_SHA\"
'"
    echo "==> Staged validated MacWSWindowing for the next package build; SpringBoard unchanged"
    exit 0
fi

# sudo is intentionally interactive unless the caller has configured a sudo
# credential helper. No password is stored in this repository.
ssh -t "$DEVICE_SSH" "sudo sh -c '
set -e
ldid -h \"$REMOTE_NEW\" >/dev/null
mv \"$REMOTE_NEW\" \"$REMOTE_BINARY\"
mv \"${REMOTE_MANIFEST}.new\" \"$REMOTE_MANIFEST\"
chown root:wheel \"$REMOTE_BINARY\"
chmod 0755 \"$REMOTE_BINARY\"
sha256sum \"$REMOTE_BINARY\" > \"$REMOTE_SHA\"
tmp=\"${INSTALLED}.apple-ld64-new\"
cp \"$REMOTE_BINARY\" \"\$tmp\"
chown root:wheel \"\$tmp\"
chmod 0755 \"\$tmp\"
mv \"\$tmp\" \"$INSTALLED\"
rm -f /var/mobile/.eksafemode
killall SpringBoard
'"

echo "==> Installed validated MacWSWindowing; SpringBoard is restarting"
