#!/usr/bin/env bash
# Content-verified local -> iPad sync, targeted build/deploy, and runtime checks.
#
# Examples:
#   bash misc/device_pipeline.sh --sync-only
#   MACWS_SUDO_PASSWORD=... bash misc/device_pipeline.sh --component display
#   bash misc/device_pipeline.sh --component libmachook
#   bash misc/device_pipeline.sh --component full --restart-workspace

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
DEVICE=${MACWS_DEVICE:-mobile@192.168.1.6}
DEVICE_PORT=${MACWS_DEVICE_PORT:-22}
REMOTE_PROJECT=${MACWS_REMOTE_PROJECT:-/var/jb/var/mobile/MacWSBootingGuide}
THEOS_PATH=${MACWS_DEVICE_THEOS:-/var/jb/var/mobile/theos}
COMPONENT=sync
DO_SYNC=1
RESTART_WORKSPACE=0
REPAIR_DESKTOP=0

usage() {
    cat <<'EOF'
Usage: bash misc/device_pipeline.sh [options]

  --sync-only                  Sync source and prove no content drift (default)
  --verify-only                Do not copy; fail if local/device source differs
  --component NAME             runtime | display | input | workspace | host | hostd | compiler | libmachook | metal | full
  --no-sync                    Build current device tree without synchronizing
  --restart-workspace          Rebuild the live GUI session after deployment and verify it
  --repair-desktop             Run the in-place desktop repair after deployment
  --device USER@HOST           Override mobile@192.168.1.6
  --port PORT                  Override SSH port 22
  -h, --help                   Show this help

Set MACWS_SUDO_PASSWORD for non-interactive deployment. If it is unset, the
script asks sudo once through an interactive SSH session without storing it.
Source sync is an overlay and deliberately never deletes device-only files.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --sync-only) COMPONENT=sync ;;
        --verify-only) COMPONENT=verify; DO_SYNC=0 ;;
        --component)
            [ "$#" -ge 2 ] || { echo "Missing value for --component" >&2; exit 2; }
            COMPONENT=$2
            shift
            ;;
        --no-sync) DO_SYNC=0 ;;
        --restart-workspace) RESTART_WORKSPACE=1 ;;
        --repair-desktop) REPAIR_DESKTOP=1 ;;
        --device)
            [ "$#" -ge 2 ] || { echo "Missing value for --device" >&2; exit 2; }
            DEVICE=$2
            shift
            ;;
        --port)
            [ "$#" -ge 2 ] || { echo "Missing value for --port" >&2; exit 2; }
            DEVICE_PORT=$2
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

case "$COMPONENT" in
    sync|verify|runtime|display|input|workspace|host|hostd|compiler|libmachook|metal|full) ;;
    *) echo "Unsupported component: $COMPONENT" >&2; exit 2 ;;
esac

SSH_ARGS=(-p "$DEVICE_PORT" -o ConnectTimeout=8)
RSYNC_SHELL="ssh -p $DEVICE_PORT -o ConnectTimeout=8"
RSYNC_EXCLUDES=(
    --exclude=.git/
    --exclude=.theos/
    --exclude='*/.theos/'
    --exclude=packages/
    # The production-policy admission check reads this authoritative manifest
    # on-device.  Keep the much larger evidence/documentation tree out of the
    # source overlay while making a fresh-device full build self-contained.
    --include=docs/
    --include=docs/runtime-switches.tsv
    --exclude='docs/*'
    --exclude='*.deb'
    --exclude='__pycache__/'
    --exclude='*.pyc'
    --exclude=.codex/
    --exclude='.codex-*'
    --exclude=tmp-source-sync/
)

device_ssh() {
    ssh "${SSH_ARGS[@]}" "$DEVICE" "$@"
}

verify_source_sync() {
    local candidates local_manifest remote_manifest
    candidates=$(rsync -rcln --itemize-changes \
        -e "$RSYNC_SHELL" "${RSYNC_EXCLUDES[@]}" \
        "$PROJECT_DIR/" "$DEVICE:$REMOTE_PROJECT/" |
        awk '$1 ~ /^[<>]f/ || $1 ~ /^cL/ { sub(/^[^ ]+ /, ""); print }')
    [ -n "$candidates" ] || {
        echo "==> Source invariant: rsync checksum dry-run reports zero content drift"
        return 0
    }

    # macOS openrsync repeatedly reports a handful of byte-identical files as
    # checksum changes (observed hashes were equal on both ends). Resolve only
    # those candidates with the platform-native SHA-256 tools so the invariant
    # is both strict and free of that implementation's false positives.
    local_manifest=$(
        cd "$PROJECT_DIR"
        while IFS= read -r path; do
            if [ -f "$path" ]; then
                printf 'F %s %s\n' \
                    "$(shasum -a 256 "$path" | awk '{print $1}')" "$path"
            elif [ -L "$path" ]; then
                printf 'L %s %s\n' "$(readlink "$path")" "$path"
            else
                printf 'M - %s\n' "$path"
            fi
        done <<< "$candidates"
    )
    remote_manifest=$(printf '%s\n' "$candidates" | device_ssh \
        "cd '$REMOTE_PROJECT'; while IFS= read -r path; do \
            if [ -f \"\$path\" ]; then \
                hash=\$(/var/jb/usr/bin/sha256sum \"\$path\"); hash=\${hash%% *}; \
                printf 'F %s %s\\n' \"\$hash\" \"\$path\"; \
            elif [ -L \"\$path\" ]; then \
                printf 'L %s %s\\n' \"\$(readlink \"\$path\")\" \"\$path\"; \
            else printf 'M - %s\\n' \"\$path\"; fi; done")
    if [ "$local_manifest" != "$remote_manifest" ]; then
        echo "ERROR: local/device source content still differs:" >&2
        diff -u <(printf '%s\n' "$local_manifest") \
                <(printf '%s\n' "$remote_manifest") >&2 || true
        return 1
    fi
    echo "==> Source invariant: all rsync candidates have identical SHA-256 content"
}

sync_source() {
    echo "==> Synchronizing source overlay to $DEVICE:$REMOTE_PROJECT"
    # Do not preserve source mtimes. A changed file must be newer than an old
    # Theos object on the device or GNU make can silently reuse stale code.
    # Checksums decide whether content is transferred; permissions and links
    # remain intact. No --delete is intentional for device-only evidence.
    rsync -rlpc --itemize-changes -e "$RSYNC_SHELL" \
        "${RSYNC_EXCLUDES[@]}" "$PROJECT_DIR/" "$DEVICE:$REMOTE_PROJECT/"
    verify_source_sync

    local head dirty
    head=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || printf unknown)
    dirty=$(git -C "$PROJECT_DIR" status --porcelain=v1 2>/dev/null | wc -l | tr -d ' ')
    device_ssh "printf '%s\\n' 'schema=1' 'local_head=$head' 'dirty_paths=$dirty' > '$REMOTE_PROJECT/.macws-source-sync'"
    echo "==> Source identity recorded: head=$head dirty_paths=$dirty"
}

run_privileged_device_script() {
    local payload encoded
    payload=$(</dev/stdin)
    # Non-login SSH sessions on the jailbroken device do not consistently
    # inherit Procursus or Apple's sbin directories. Theos invokes tools such
    # as sysctl by name, so make the iOS build environment deterministic for
    # every component instead of depending on the caller's interactive PATH.
    payload="export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/usr/bin:/usr/sbin:/bin:/sbin
$payload"
    encoded=$(printf '%s' "$payload" | base64 | tr -d '\n')
    if [ -n "${MACWS_SUDO_PASSWORD:-}" ]; then
        # Keep credential validation and every later sudo in the same PTY:
        # this device uses tty-scoped sudo tickets. Expect waits for sudo's
        # no-echo password prompt instead of preloading plaintext into the PTY.
        MACWS_PIPELINE_PASSWORD=$MACWS_SUDO_PASSWORD \
        MACWS_PIPELINE_DEVICE=$DEVICE \
        MACWS_PIPELINE_PORT=$DEVICE_PORT \
        MACWS_PIPELINE_PAYLOAD=$encoded \
        /usr/bin/expect <<'EXPECT'
set timeout -1
set remote_command "sudo -v && printf '%s' '$env(MACWS_PIPELINE_PAYLOAD)' | /var/jb/usr/bin/base64 -d | bash"
spawn -noecho ssh -p $env(MACWS_PIPELINE_PORT) -o ConnectTimeout=8 -tt \
    $env(MACWS_PIPELINE_DEVICE) $remote_command
expect {
    -re {(?i)password.*:} {
        send -- "$env(MACWS_PIPELINE_PASSWORD)\r"
        exp_continue
    }
    eof
}
set result [wait]
exit [lindex $result 3]
EXPECT
    else
        ssh "${SSH_ARGS[@]}" -t "$DEVICE" \
            "sudo -v && printf '%s' '$encoded' | /var/jb/usr/bin/base64 -d | bash"
    fi
}

build_display() {
    echo "==> Building and atomically deploying macwsdisplayd only"
    run_privileged_device_script <<REMOTE
set -euo pipefail
PROJECT='$REMOTE_PROJECT'
THEOS='$THEOS_PATH'
cd "\$PROJECT"
touch macwsdisplayd/main.m macwsdisplayd/MacWSFinalCompositeReceiver.m \
    macwsdisplayd/MacWSFinalCompositeReceiver.h \
    include/macws_final_composite_protocol.h include/macws_host_protocol.h \
    include/macws_stream_protocol.h
THEOS="\$THEOS" THEOS_PROJECT_DIR="\$PROJECT" THEOS_BUILD_DIR="\$PROJECT" \
    make -C macwsdisplayd FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 \
    THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1
BUILT=.theos/obj/macosx/macwsdisplayd
[ -n "\$BUILT" ] && [ -x "\$BUILT" ]
grep -Fqa 'macws_final_composite.state' "\$BUILT"
sudo launchctl unload /var/jb/usr/macOS/LaunchDaemons/com.macwsguide.display.plist \
    2>/dev/null || true
sudo install -o root -g wheel -m 0755 "\$BUILT" /var/jb/usr/macOS/bin/macwsdisplayd
sudo install -o root -g wheel -m 0755 "\$BUILT" /var/mnt/rootfs/usr/local/bin/macwsdisplayd
for path in /var/jb/usr/macOS/bin/macwsdisplayd /var/mnt/rootfs/usr/local/bin/macwsdisplayd; do
    hash=\$(ldid -arch arm64 -h "\$path" 2>/dev/null | grep CDHash= | cut -c8-)
    [ -n "\$hash" ] && sudo /var/jb/usr/bin/jbctl trustcache add "\$hash" >/dev/null
done
sudo launchctl load /var/jb/usr/macOS/LaunchDaemons/com.macwsguide.display.plist
sleep 2
cmp -s "\$BUILT" /var/jb/usr/macOS/bin/macwsdisplayd
cmp -s "\$BUILT" /var/mnt/rootfs/usr/local/bin/macwsdisplayd
grep -Fqa 'macws_final_composite.state' /var/jb/usr/macOS/bin/macwsdisplayd
ps -axo pid,comm | grep 'macwsdisplayd$'
REMOTE
}

build_input() {
    echo "==> Building and atomically deploying macwsinputd only"
    run_privileged_device_script <<REMOTE
set -euo pipefail
PROJECT='$REMOTE_PROJECT'
THEOS='$THEOS_PATH'
cd "\$PROJECT"
touch macwsinputd/main.c include/macws_host_protocol.h
THEOS="\$THEOS" THEOS_PROJECT_DIR="\$PROJECT" THEOS_BUILD_DIR="\$PROJECT" \
    make -C macwsinputd FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 \
    THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1
BUILT=.theos/obj/macosx/macwsinputd
[ -n "\$BUILT" ] && [ -x "\$BUILT" ]
grep -Fqa 'GLOBAL-SURFACE-INFER' "\$BUILT"
sudo launchctl unload \
    /var/jb/usr/macOS/LaunchDaemons/com.macwsguide.input.plist \
    2>/dev/null || true
sudo install -o root -g wheel -m 0755 "\$BUILT" \
    /var/jb/usr/macOS/bin/macwsinputd
sudo install -o root -g wheel -m 0755 "\$BUILT" \
    /var/mnt/rootfs/usr/local/bin/macwsinputd
for path in /var/jb/usr/macOS/bin/macwsinputd \
            /var/mnt/rootfs/usr/local/bin/macwsinputd; do
    hash=\$(ldid -arch arm64 -h "\$path" 2>/dev/null | \
        grep CDHash= | cut -c8-)
    [ -n "\$hash" ] && sudo /var/jb/usr/bin/jbctl trustcache add \
        "\$hash" >/dev/null
done
sudo launchctl load \
    /var/jb/usr/macOS/LaunchDaemons/com.macwsguide.input.plist
sleep 1
cmp -s "\$BUILT" /var/jb/usr/macOS/bin/macwsinputd
cmp -s "\$BUILT" /var/mnt/rootfs/usr/local/bin/macwsinputd
grep -Fqa 'GLOBAL-SURFACE-INFER' /var/jb/usr/macOS/bin/macwsinputd
test -S /var/mnt/rootfs/private/tmp/macws_host_input.sock
ps -axo pid,comm | grep 'macwsinputd$'
REMOTE
}

build_workspace() {
    echo "==> Building and atomically deploying macwsworkspacectl only"
    run_privileged_device_script <<REMOTE
set -euo pipefail
PROJECT='$REMOTE_PROJECT'
THEOS='$THEOS_PATH'
cd "\$PROJECT"
touch macwsworkspacectl/main.m
THEOS="\$THEOS" THEOS_PROJECT_DIR="\$PROJECT" THEOS_BUILD_DIR="\$PROJECT" \
    make -C macwsworkspacectl FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 \
    THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1
BUILT=.theos/obj/macosx/macwsworkspacectl
[ -n "\$BUILT" ] && [ -x "\$BUILT" ]
grep -Fqa 'register-settings-extensions' "\$BUILT"
sudo install -o root -g wheel -m 0755 "\$BUILT" \
    /var/jb/usr/macOS/bin/macwsworkspacectl
sudo install -o root -g wheel -m 0755 "\$BUILT" \
    /var/mnt/rootfs/usr/local/bin/macwsworkspacectl
for path in /var/jb/usr/macOS/bin/macwsworkspacectl /var/mnt/rootfs/usr/local/bin/macwsworkspacectl; do
    hash=\$(ldid -arch arm64 -h "\$path" 2>/dev/null | grep CDHash= | cut -c8-)
    [ -n "\$hash" ] && sudo /var/jb/usr/bin/jbctl trustcache add "\$hash" >/dev/null
done
cmp -s "\$BUILT" /var/jb/usr/macOS/bin/macwsworkspacectl
cmp -s "\$BUILT" /var/mnt/rootfs/usr/local/bin/macwsworkspacectl
REMOTE
}

build_host() {
    echo "==> Building and deploying the macPad control application only"
    run_privileged_device_script <<REMOTE
set -euo pipefail
PROJECT='$REMOTE_PROJECT'
THEOS='$THEOS_PATH'
cd "\$PROJECT"
# Full/package builds and pre-deploy signing can leave shared Theos cache
# entries owned by root. Repair ownership only when drift exists so the normal
# incremental path never fails at Swift's before-all marker cleanup.
if find .theos ! -user "\$(id -u)" -print -quit 2>/dev/null | grep -q .; then
    sudo chown -R "\$(id -u):\$(id -g)" .theos
fi
HOST_WAS_RUNNING=0
if ps -axo command= | awk \
        '/Applications\/MacWSHost.app\/MacWSHost/{found=1} END{exit !found}'; then
    HOST_WAS_RUNNING=1
fi
# sync_source deliberately gives transferred files a fresh device mtime, and
# Theos dependency files already track changed headers. Preserve incremental
# objects here; touching the whole Host rebuilt every translation unit even
# when one implementation changed.
THEOS="\$THEOS" THEOS_PROJECT_DIR="\$PROJECT" THEOS_BUILD_DIR="\$PROJECT" \
    make -C MacWSHost FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 \
    THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1
BUILT=.theos/obj/MacWSHost.app/MacWSHost
[ -n "\$BUILT" ] && [ -x "\$BUILT" ]
NM_FILE=/tmp/macws-device-pipeline-host-nm.\$\$
trap 'rm -f "\$NM_FILE"' EXIT
nm -nm "\$BUILT" 2>/dev/null > "\$NM_FILE"
for method in '-[MacWSMetalView hasFinalCompositeFrame]' \
              '-[MacWSViewController repairDesktopAction]' \
              '-[MacWSViewController applyStatus:]'; do
    grep -Fq -- "\$method" "\$NM_FILE"
done
grep -Fqa 'repair-desktop' "\$BUILT"
grep -Fqa 'performance-visible-target route=final-composite-catalog' "\$BUILT"
grep -Fqa 'host_unique_frames_presented' "\$BUILT"
sudo install -o root -g wheel -m 0755 "\$BUILT" \
    /var/jb/Applications/MacWSHost.app/MacWSHost
hash=\$(ldid -arch arm64 -h /var/jb/Applications/MacWSHost.app/MacWSHost \
    2>/dev/null | grep CDHash= | cut -c8-)
[ -n "\$hash" ] && sudo /var/jb/usr/bin/jbctl trustcache add "\$hash" >/dev/null
sudo /var/jb/usr/bin/uicache -p /var/jb/Applications/MacWSHost.app >/dev/null 2>&1 || true
killall MacWSHost 2>/dev/null || true
grep -Fqa 'repair-desktop' /var/jb/Applications/MacWSHost.app/MacWSHost
grep -Fqa 'performance-visible-target route=final-composite-catalog' \
    /var/jb/Applications/MacWSHost.app/MacWSHost
grep -Fqa 'host_unique_frames_presented' \
    /var/jb/Applications/MacWSHost.app/MacWSHost
# Installing a profiler while the workspace is deliberately stopped must not
# launch MacWSHost: its bootstrap Scene is allowed to start WindowServer and a
# default Terminal, which turns a cold deployment into an unrequested heat
# soak. Preserve the pre-deploy application lifecycle instead. A live Host is
# restarted so an interactive user receives the new binary immediately; an
# absent Host stays absent until the user opens macPad.
if [ "\$HOST_WAS_RUNNING" -eq 0 ]; then
    echo 'MacWSHost was stopped before deployment; leaving it stopped'
    exit 0
fi
/var/jb/usr/bin/uiopen --url macwshost://show-controls >/dev/null 2>&1
# UIKit scene restoration is asynchronous and, while Stray is saturating the
# device, runtime-confirmed at 3-4 seconds. A fixed two-second sleep made a
# successful signed install look like a deployment failure and encouraged an
# unnecessary second rebuild/restart. Poll only the exact process witness for
# a bounded ten seconds; this adds no delay on the normal fast path.
HOST_WITNESS=/tmp/macws-device-pipeline-host-witness.\$\$
trap 'rm -f "\$NM_FILE" "\$HOST_WITNESS"' EXIT
host_attempt=0
while ! ps -axo pid,comm | grep 'MacWSHost\$' >"\$HOST_WITNESS"; do
    host_attempt=\$((host_attempt + 1))
    [ "\$host_attempt" -lt 20 ] || {
        echo 'MacWSHost did not launch within 10 seconds' >&2
        exit 1
    }
    sleep 0.5
done
cat "\$HOST_WITNESS"
REMOTE
}

build_libmachook() {
    echo "==> Deterministically rebuilding/deploying libmachook only"
    run_privileged_device_script <<REMOTE
set -euo pipefail
cd '$REMOTE_PROJECT'
# A prior sudo/root build can leave otherwise-valid incremental objects and
# Swift marker directories read-only to the normal mobile builder. Normalize
# that cache once when drift is detected; subsequent fast builds avoid both a
# clean rebuild and an unconditional recursive chown.
if find .theos ! -user "\$(id -u)" -print -quit 2>/dev/null | grep -q .; then
    sudo chown -R "\$(id -u):\$(id -g)" .theos
fi
THEOS='$THEOS_PATH' bash misc/build_on_ios.sh --fast-force
cmp -s /var/jb/usr/macOS/lib/libmachook.dylib \
    /var/mnt/rootfs/usr/local/lib/libmachook.dylib
cmp -s /var/jb/usr/macOS/lib/libmachook_arm64.dylib \
    /var/mnt/rootfs/usr/local/lib/libmachook_arm64.dylib
REMOTE
}

build_compiler() {
    echo "==> Building and atomically deploying MTLCompilerService tweak only"
    run_privileged_device_script <<REMOTE
set -euo pipefail
PROJECT='$REMOTE_PROJECT'
THEOS='$THEOS_PATH'
cd "\$PROJECT"
touch MTLCompilerBypassOSCheck/Tweak.x
THEOS="\$THEOS" THEOS_PROJECT_DIR="\$PROJECT" THEOS_BUILD_DIR="\$PROJECT" \
    make -C MTLCompilerBypassOSCheck FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 \
    THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1
BUILT=.theos/obj/MTLCompilerBypassOSCheck.dylib
[ -s "\$BUILT" ]
grep -Fqa 'target adapter installed' "\$BUILT"
sudo install -o root -g wheel -m 0755 "\$BUILT" \
    /var/jb/Library/MobileSubstrate/DynamicLibraries/MTLCompilerBypassOSCheck.dylib
sudo install -o root -g wheel -m 0644 \
    MTLCompilerBypassOSCheck/MTLCompilerBypassOSCheck.plist \
    /var/jb/Library/MobileSubstrate/DynamicLibraries/MTLCompilerBypassOSCheck.plist
cmp -s "\$BUILT" \
    /var/jb/Library/MobileSubstrate/DynamicLibraries/MTLCompilerBypassOSCheck.dylib
# The service is on-demand.  With no game running, terminate only workers
# whose complete executable path is the stock compiler service so the next
# request loads this exact artifact.  These workers ignore SIGTERM on this
# iOS build; a path-validated SIGKILL is therefore required.
SERVICE=/System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/MTLCompilerService
ps -axo pid=,command= | awk -v service="\$SERVICE" \
    '\$2 == service { print \$1 }' | while IFS= read -r pid; do
    [ -n "\$pid" ] && sudo kill -KILL "\$pid"
done
grep -Fqa 'target adapter installed' \
    /var/jb/Library/MobileSubstrate/DynamicLibraries/MTLCompilerBypassOSCheck.dylib
REMOTE
}

build_hostd() {
    echo "==> Building and atomically deploying macwshostd only"
    run_privileged_device_script <<REMOTE
set -euo pipefail
PROJECT='$REMOTE_PROJECT'
THEOS='$THEOS_PATH'
cd "\$PROJECT"
# See build_host: a prior signed/package build can leave shared marker files
# root-owned even though this component is compiled as mobile.
if find .theos ! -user "\$(id -u)" -print -quit 2>/dev/null | grep -q .; then
    sudo chown -R "\$(id -u):\$(id -g)" .theos
fi
# main.m deliberately resolves every shared protocol through ../include.
# Assert that invariant before compiling so a non-destructive device sync can
# never silently select a device-only shadow header from macwshostd/ again.
for header in macws_control_protocol.h macws_host_protocol.h \
              macws_steam_mach_rendezvous_protocol.h \
              macws_steam_semaphore_protocol.h macws_stream_protocol.h; do
    grep -Fq "#include \"../include/\$header\"" macwshostd/main.m
    [ -s "include/\$header" ]
done
THEOS="\$THEOS" THEOS_PROJECT_DIR="\$PROJECT" THEOS_BUILD_DIR="\$PROJECT" \
make -C macwshostd FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 \
    THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1
BUILT=.theos/obj/arm64/macwshostd
[ -n "\$BUILT" ] && [ -x "\$BUILT" ]
grep -Fqa 'retarget-metal-library' "\$BUILT"
grep -Fqa 'auto-lower-known-air' "\$BUILT"
# launchd reports OS_REASON_EXEC when an unsigned raw Theos object is copied
# into place. Sign and validate the exact artifact before unloading the
# currently working daemon, so deployment cannot leave hostd unavailable.
sudo ldid -S"\$PROJECT/entitlements.plist" -M "\$BUILT"
BUILT_HASH=\$(ldid -arch arm64 -h "\$BUILT" 2>/dev/null | \
    grep CDHash= | cut -c8-)
[ -n "\$BUILT_HASH" ]
THEOS="\$THEOS" THEOS_PROJECT_DIR="\$PROJECT" THEOS_BUILD_DIR="\$PROJECT" \
    make -C macwscontrolprobe FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 \
    THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1
PROBE=.theos/obj/arm64/macws_control_probe
[ -n "\$PROBE" ] && [ -x "\$PROBE" ]
grep -Fqa 'metal-retarget source=' "\$PROBE"
grep -Fqa 'steam-sem-timed-wait protocol=' "\$PROBE"
sudo install -o root -g wheel -m 0644 \
    "\$PROJECT/misc/repack_metallib_macabi.py" \
    /var/jb/usr/macOS/bin/repack_metallib_macabi.py
sudo install -o root -g wheel -m 0644 \
    "\$PROJECT/misc/install_stray_exact_metallib.py" \
    /var/jb/usr/macOS/bin/install_stray_exact_metallib.py
sudo launchctl unload \
    /var/jb/Library/LaunchDaemons/com.macwsguide.hostd.plist \
    2>/dev/null || true
sudo install -o root -g wheel -m 0755 "\$BUILT" \
    /var/jb/usr/macOS/bin/macwshostd
sudo install -o root -g wheel -m 0755 "\$PROBE" \
    /var/jb/usr/macOS/bin/macws_control_probe
for path in /var/jb/usr/macOS/bin/macwshostd \
            /var/jb/usr/macOS/bin/macws_control_probe; do
    hash=\$(ldid -arch arm64 -h "\$path" 2>/dev/null | \
        grep CDHash= | cut -c8-)
    [ -n "\$hash" ] && sudo /var/jb/usr/bin/jbctl trustcache add \
        "\$hash" >/dev/null
done
sudo launchctl load \
    /var/jb/Library/LaunchDaemons/com.macwsguide.hostd.plist
sleep 1
cmp -s "\$BUILT" /var/jb/usr/macOS/bin/macwshostd
grep -Fqa 'retarget-metal-library' /var/jb/usr/macOS/bin/macwshostd
grep -Fqa 'auto-lower-known-air' /var/jb/usr/macOS/bin/macwshostd
tail -n 20 /var/mobile/Library/Logs/MacWSHostd.log | \
    grep -F 'protocol=9' | tail -1
/var/jb/usr/macOS/bin/macws_control_probe steam-sem-timed-wait-selftest | \
    grep -F 'valid=yes'
REMOTE
}

deploy_runtime_assets() {
    echo "==> Deploying scripts/plists only (no compiler or package install)"
    run_privileged_device_script <<REMOTE
set -euo pipefail
PROJECT='$REMOTE_PROJECT'
sudo install -o root -g wheel -m 0755 \
    "\$PROJECT/layout/usr/macOS/bin/ensure_steam_trust.sh" \
    /var/jb/usr/macOS/bin/ensure_steam_trust.sh
sudo install -o root -g wheel -m 0755 \
    "\$PROJECT/layout/usr/macOS/bin/prepare_steam_runtime.sh" \
    /var/jb/usr/macOS/bin/prepare_steam_runtime.sh
sudo install -o root -g wheel -m 0755 \
    "\$PROJECT/layout/usr/macOS/bin/macos_gui.sh" \
    /var/jb/usr/macOS/bin/macos_gui.sh
sudo install -o root -g wheel -m 0755 \
    "\$PROJECT/layout/usr/macOS/bin/ensure_settings_extensions_runtime.sh" \
    /var/jb/usr/macOS/bin/ensure_settings_extensions_runtime.sh
sudo install -o root -g wheel -m 0755 \
    "\$PROJECT/layout/usr/macOS/bin/ensure_objc_trampolines_arm64.py" \
    /var/jb/usr/macOS/bin/ensure_objc_trampolines_arm64.py
sudo install -o root -g wheel -m 0755 \
    "\$PROJECT/layout/usr/macOS/bin/ensure_metal2metal_compat.sh" \
    /var/jb/usr/macOS/bin/ensure_metal2metal_compat.sh
sudo install -o root -g wheel -m 0644 \
    "\$PROJECT/misc/metal2metal.py" \
    "\$PROJECT/misc/metal2metal_manifest.py" \
    "\$PROJECT/misc/metal2metal_profiles.py" \
    "\$PROJECT/misc/repack_metallib_macabi.py" \
    /var/jb/usr/macOS/bin/
sudo install -o root -g wheel -m 0644 \
    "\$PROJECT/misc/com.macwsguide.steam.runtime.plist" \
    /var/jb/usr/macOS/gui-launchd/com.macwsguide.steam.runtime.plist
sudo install -o root -g wheel -m 0644 \
    "\$PROJECT/misc/com.macwsguide.vscode.plist" \
    /var/jb/usr/macOS/gui-launchd/com.macwsguide.vscode.plist
sudo bash /var/jb/usr/macOS/bin/ensure_metal2metal_compat.sh
cmp -s "\$PROJECT/layout/usr/macOS/bin/ensure_steam_trust.sh" \
    /var/jb/usr/macOS/bin/ensure_steam_trust.sh
cmp -s "\$PROJECT/layout/usr/macOS/bin/prepare_steam_runtime.sh" \
    /var/jb/usr/macOS/bin/prepare_steam_runtime.sh
cmp -s "\$PROJECT/layout/usr/macOS/bin/macos_gui.sh" \
    /var/jb/usr/macOS/bin/macos_gui.sh
cmp -s "\$PROJECT/layout/usr/macOS/bin/ensure_settings_extensions_runtime.sh" \
    /var/jb/usr/macOS/bin/ensure_settings_extensions_runtime.sh
cmp -s "\$PROJECT/layout/usr/macOS/bin/ensure_objc_trampolines_arm64.py" \
    /var/jb/usr/macOS/bin/ensure_objc_trampolines_arm64.py
cmp -s "\$PROJECT/layout/usr/macOS/bin/ensure_metal2metal_compat.sh" \
    /var/jb/usr/macOS/bin/ensure_metal2metal_compat.sh
cmp -s "\$PROJECT/misc/com.macwsguide.steam.runtime.plist" \
    /var/jb/usr/macOS/gui-launchd/com.macwsguide.steam.runtime.plist
/var/jb/usr/bin/python3 -c 'import plistlib,sys; a=plistlib.load(open(sys.argv[1],"rb")); b=plistlib.load(open(sys.argv[2],"rb")); assert a == b' \
    "\$PROJECT/misc/com.macwsguide.vscode.plist" \
    /var/jb/usr/macOS/gui-launchd/com.macwsguide.vscode.plist
REMOTE
}

build_full() {
    echo "==> Incremental full package build/install (changed synced files have fresh mtimes)"
    run_privileged_device_script <<REMOTE
set -euo pipefail
cd '$REMOTE_PROJECT'
# A manually inspected or recovery build may have run under sudo and left the
# shared Theos cache root-owned.  Full builds normally run as mobile after the
# sudo ticket is validated; normalize only when ownership drift is actually
# present so Swift's
# before-all marker cleanup and the incremental object graph remain usable.
if find .theos ! -user "\$(id -u)" -print -quit 2>/dev/null | grep -q .; then
    sudo chown -R "\$(id -u):\$(id -g)" .theos
fi
THEOS='$THEOS_PATH' bash misc/build_on_ios.sh --resume
REMOTE
}

verify_runtime_artifacts() {
    echo "==> Verifying source/install/runtime contract"
    device_ssh "set -e; \
        cmp -s '$REMOTE_PROJECT/layout/usr/macOS/bin/macos_gui.sh' /var/jb/usr/macOS/bin/macos_gui.sh; \
        cmp -s '$REMOTE_PROJECT/layout/usr/macOS/bin/ensure_settings_extensions_runtime.sh' /var/jb/usr/macOS/bin/ensure_settings_extensions_runtime.sh; \
        cmp -s '$REMOTE_PROJECT/layout/usr/macOS/bin/ensure_objc_trampolines_arm64.py' /var/jb/usr/macOS/bin/ensure_objc_trampolines_arm64.py; \
        cmp -s '$REMOTE_PROJECT/layout/usr/macOS/bin/prepare_steam_runtime.sh' /var/jb/usr/macOS/bin/prepare_steam_runtime.sh; \
        cmp -s '$REMOTE_PROJECT/layout/usr/macOS/bin/ensure_metal2metal_compat.sh' /var/jb/usr/macOS/bin/ensure_metal2metal_compat.sh; \
        /var/jb/usr/bin/python3 -c 'import plistlib,sys; a=plistlib.load(open(sys.argv[1],\"rb\")); b=plistlib.load(open(sys.argv[2],\"rb\")); assert a == b' '$REMOTE_PROJECT/misc/com.macwsguide.steam.runtime.plist' /var/jb/usr/macOS/gui-launchd/com.macwsguide.steam.runtime.plist; \
        /var/jb/usr/bin/python3 -c 'import plistlib,sys; a=plistlib.load(open(sys.argv[1],\"rb\")); b=plistlib.load(open(sys.argv[2],\"rb\")); assert a == b' '$REMOTE_PROJECT/misc/com.macwsguide.vscode.plist' /var/jb/usr/macOS/gui-launchd/com.macwsguide.vscode.plist; \
        grep -Fqa 'repair-desktop' /var/jb/Applications/MacWSHost.app/MacWSHost; \
        grep -Fqa 'macws_final_composite.state' /var/jb/usr/macOS/bin/macwsdisplayd; \
        cmp -s /var/jb/usr/macOS/bin/macwsdisplayd /var/mnt/rootfs/usr/local/bin/macwsdisplayd; \
        grep -Fqa 'register-settings-extensions' /var/jb/usr/macOS/bin/macwsworkspacectl; \
        cmp -s /var/jb/usr/macOS/bin/macwsworkspacectl /var/mnt/rootfs/usr/local/bin/macwsworkspacectl; \
        cmp -s /var/jb/usr/macOS/lib/libmachook.dylib /var/mnt/rootfs/usr/local/lib/libmachook.dylib; \
        cmp -s /var/jb/usr/macOS/lib/libmachook_arm64.dylib /var/mnt/rootfs/usr/local/lib/libmachook_arm64.dylib; \
        test -s /var/mnt/rootfs/usr/local/share/macws/metal2metal/routes/quartzcore-default.route.plist; \
        test -s /var/mnt/rootfs/usr/local/share/macws/metal2metal/routes/skylight-shaders.route.plist; \
        test -s /var/mnt/rootfs/usr/local/share/macws/metal2metal/routes/mpsimage-default.route.plist; \
        echo 'artifact invariant: ready'"
}

wait_for_host_operation() {
    local action=$1 expected=$2 timeout=${3:-180}
    device_ssh "set -e; \
        LOG=/var/mobile/Library/Logs/MacWSHostd.log; \
        BEFORE=\$(wc -l < \"\$LOG\" | tr -d ' '); \
        /var/jb/usr/bin/uiopen --url 'macwshost://$action' >/dev/null 2>&1; \
        I=0; while [ \$I -lt $timeout ]; do \
            I=\$((I+1)); \
            tail -n +\$((BEFORE+1)) \"\$LOG\" | grep -Fq '$expected' && break; \
            sleep 1; \
        done; \
        tail -n +\$((BEFORE+1)) \"\$LOG\" | grep -F '$expected' | tail -1"
}

restart_workspace() {
    echo "==> Restarting the live workspace through the bounded session path"
    run_privileged_device_script <<'REMOTE'
set -euo pipefail
sudo env PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/usr/bin:/usr/sbin:/bin:/sbin \
    bash /var/jb/usr/macOS/bin/macos_gui.sh restart coexist \
        --no-terminal --no-vnc
REMOTE
    device_ssh "set -e; \
        ps -axo pid,comm | grep 'WindowServer$'; \
        ps -axo pid,comm | grep 'macwsdisplayd$'; \
        grep -Fq 'state=ready' /var/mnt/rootfs/private/tmp/macws_final_composite.state; \
        cat /var/mnt/rootfs/private/tmp/macws_final_composite.state"
}

if [ "$DO_SYNC" -eq 1 ]; then
    sync_source
else
    verify_source_sync
fi

case "$COMPONENT" in
    sync|verify) ;;
    runtime) deploy_runtime_assets ;;
    display) build_display ;;
    input) build_input ;;
    workspace) deploy_runtime_assets; build_workspace ;;
    host) build_host ;;
    hostd) deploy_runtime_assets; build_hostd ;;
    compiler) build_compiler ;;
    libmachook) build_libmachook ;;
    metal) build_hostd; build_libmachook ;;
    full) build_full ;;
esac

if [ "$COMPONENT" != sync ] && [ "$COMPONENT" != verify ]; then
    verify_runtime_artifacts
fi
if [ "$RESTART_WORKSPACE" -eq 1 ]; then
    restart_workspace
fi
if [ "$REPAIR_DESKTOP" -eq 1 ]; then
    echo "==> Running bounded in-place desktop repair"
    wait_for_host_operation repair-desktop 'desktop-repair result=ready' 60
fi

echo "==> Device pipeline complete"
