# cleanup_all.sh — one-click stop of all chroot macOS services + cleanup of
# build-helper / debug-loop zombies. Useful when CPU/load gets stuck due to:
#   - WindowServer crash loops respawned by launchd
#   - macwsallocd respawn churn from a bad XPC handler
#   - autosignd zombies accumulating from repeated postinst.sh runs
#   - orphan oslog/tail/grep/find_crash.sh from interactive debug sessions
#   - stale lldb/debugserver attached to dead procs
#
# Run as root (or via `sudo bash`).
#
# NO shebang on purpose — AMFI SIGKILLs execve() of any file with a `#!` line
# on this jailbreak. Always invoke as `bash cleanup_all.sh`.

echo === stopping GUI stack ===
# This script is the explicit thermal/crash-loop emergency stop.  A test lease
# must protect a controlled measurement from an unrelated ordinary start/stop,
# but it must not make emergency recovery partial.  Runtime-confirmed
# 2026-07-29: a stale Chrome test lease made macos_gui.sh refuse this stop;
# cleanup later killed the processes but left ws_headless/mode state behind
# while the orphan workload had already held the device near 5.2 W.
# Authenticate with the exact current token, then clear the now-stopped lease
# so a dead test owner cannot block the next deliberate session.
# A SIGKILL of macwshostd does not kill its already-spawned macos_gui.sh child;
# launchd reparents that transaction to pid 1 and its live PID keeps the
# atomic transition lock authoritative.  Runtime-confirmed 2026-08-16: an
# interrupted cold trust scan survived the old cleanup and the next macPad
# retry correctly refused with exit 75.  Emergency recovery owns termination
# of that exact script, so retire only a numeric lock owner whose current
# command is still the project macos_gui.sh before asking stop to acquire the
# transaction itself.
cleanup_transaction_dir=/tmp/.macos_gui.transaction
cleanup_transaction_pid_file="$cleanup_transaction_dir/pid"
cleanup_transaction_pid=""
if [ -f "$cleanup_transaction_pid_file" ]; then
  cleanup_transaction_pid=$(awk 'NR == 1 { print; exit }' \
    "$cleanup_transaction_pid_file" 2>/dev/null)
  case "$cleanup_transaction_pid" in
    ''|*[!0-9]*) cleanup_transaction_pid="" ;;
  esac
fi
if [ -n "$cleanup_transaction_pid" ]; then
  cleanup_transaction_command=$(ps -p "$cleanup_transaction_pid" \
    -o command= 2>/dev/null)
  case "$cleanup_transaction_command" in
    *'/var/jb/usr/macOS/bin/macos_gui.sh '*)
      echo "retiring active GUI transaction pid=$cleanup_transaction_pid"
      kill -TERM "$cleanup_transaction_pid" 2>/dev/null || true
      cleanup_wait=0
      while kill -0 "$cleanup_transaction_pid" 2>/dev/null && \
            [ "$cleanup_wait" -lt 20 ]; do
        sleep 0.1
        cleanup_wait=$((cleanup_wait + 1))
      done
      kill -9 "$cleanup_transaction_pid" 2>/dev/null || true
      ;;
  esac
fi
cleanup_lease_file=/tmp/macws_test_lease
cleanup_lease_token=""
if [ -f "$cleanup_lease_file" ]; then
  cleanup_lease_token=$(awk 'NR == 1 { print; exit }' "$cleanup_lease_file" 2>/dev/null)
fi
if [ -n "$cleanup_lease_token" ]; then
  MACWS_TEST_LEASE_TOKEN="$cleanup_lease_token" \
    bash /var/jb/usr/macOS/bin/macos_gui.sh stop 2>&1 | head -5
else
  bash /var/jb/usr/macOS/bin/macos_gui.sh stop 2>&1 | head -5
fi
rm -f "$cleanup_lease_file"

echo === unloading all macwsguide jobs ===
for plist in /var/jb/Library/LaunchDaemons/com.macwsguide.*.plist \
             /var/jb/usr/macOS/LaunchDaemons/com.macwsguide.*.plist \
             /var/jb/usr/macOS/gui-launchd/com.macwsguide.*.plist; do
  [ -f "$plist" ] && launchctl unload "$plist" 2>/dev/null
done

echo === unloading WindowServer launchd plists ===
# launchctl unload may block on system-domain plists; bound each call.
for plist in /var/jb/usr/macOS/LaunchDaemons/com.apple.WindowServer.plist \
             /var/jb/usr/macOS/LaunchDaemons/com.apple.coreservices.launchservicesd.plist; do
  [ -f "$plist" ] || continue
  launchctl unload "$plist" 2>/dev/null &
done
sleep 3
for p in $(jobs -p); do kill -9 $p 2>/dev/null; done

echo === killing chroot processes ===
for pat in WindowServer launchservicesd coreservicesd OSXvnc-server Terminal GlassDemo \
           "Activity Monitor" launchdchrootexec MTLSimDriverHost macwsinputd \
           macwsdisplayd macwsinteropd \
           "Visual Studio Code.app" "Code Helper" \
           "Google Chrome.app" "Chrome Helper" \
           "/Applications/Steam.app/Contents/MacOS/steam_osx" \
           "/Library/Application Support/Steam/.*Steam Helper" MacWSHost; do
  pkill -9 -f "$pat" 2>/dev/null
done

# Retire the bounded Stray runner's device-local launchd safety lease after
# its job has been unloaded above.  Also name the exact prepared executable so
# emergency cleanup does not depend on the wider GUI shutdown succeeding.
stray_exec='/Users/root/Library/Application Support/Steam/steamapps/macws-runtime/Stray/Stray.app/Contents/MacOS/Stray-Mac-Shipping'
for pid in $(ps -axo pid=,command= 2>/dev/null |
    awk -v exact="$stray_exec" '$0 ~ exact {print $1}'); do
  command=$(ps -p "$pid" -o command= 2>/dev/null)
  [ "$command" = "$stray_exec" ] && kill -9 "$pid" 2>/dev/null
done
rm -f /var/mobile/Library/Logs/macws-stray-safety.heartbeat \
      /var/jb/Library/LaunchDaemons/com.macwsguide.stray-safety.plist

# Steam's 7DTD adapter launches the prepared arm64 Unity player rather than
# the x86 launcher.  The game can outlive Steam after a wedged AppKit event
# callback, so the general Steam patterns above do not match it.  Recovery
# owns this exact prepared executable (including the optional Steam argument)
# and must not leave the old Unity process holding SkyLight input locks across
# the next GUI start.
seven_days_exec='/Users/root/Library/Application Support/Steam/steamapps/macws-runtime/7 Days To Die/7DaysToDie-ARM.app/Contents/MacOS/7 Days To Die'
for pid in $(ps -axo pid=,command= 2>/dev/null |
    awk -v exact="$seven_days_exec" 'index($0, exact) {print $1}'); do
  command=$(ps -p "$pid" -o command= 2>/dev/null)
  case "$command" in
    "$seven_days_exec"|"$seven_days_exec "*)
      kill -9 "$pid" 2>/dev/null
      ;;
  esac
done

# A running UIKit application is owned by mobile and may survive root's
# procursus pkill on this jailbreak. Remove its exact dynamic launchd label,
# then kill only the executable path if SpringBoard has not reaped it yet.
for label in $(launchctl list 2>/dev/null \
    | awk '/UIKitApplication:com\.macwsguide\.host/{print $3}'); do
  launchctl remove "$label" 2>/dev/null
done
for pid in $(ps aux 2>/dev/null \
    | awk '/Applications\/MacWSHost\.app\/MacWSHost/ && !/awk/{print $2}'); do
  kill -9 "$pid" 2>/dev/null
done

echo === killing all autosignd zombies ===
killall -9 autosignd 2>/dev/null

echo === killing macwsallocd ===
killall -9 macwsallocd 2>/dev/null

echo === killing macwsinputd ===
killall -9 macwsinputd 2>/dev/null
echo === killing display and interop bridges ===
killall -9 macwsdisplayd 2>/dev/null
killall -9 macwsinteropd 2>/dev/null
rm -f /var/mnt/rootfs/private/tmp/macws_window_metrics.*.bin 2>/dev/null
rm -f /var/mnt/rootfs/private/tmp/macws_menu_client.*.sock 2>/dev/null
rm -f /var/mnt/rootfs/private/tmp/macws_menu_snapshot.*.bin 2>/dev/null

echo === killing orphan build/debug scripts ===
for pat in 'sh /tmp/' oslog build_on_ios.sh \
           '/var/jb/usr/macOS/bin/postinst.sh' '/var/jb/usr/bin/ldid' \
           find_crash.sh '/var/jb/usr/bin/lldb' debugserver tmux; do
  pkill -9 -f "$pat" 2>/dev/null
done
# procursus pkill has occasionally missed an already-orphaned oslog process.
# Resolve only the exact debug executables from ps and terminate their PIDs.
for pid in $(ps aux 2>/dev/null \
    | awk '/\/oslog( |$)|\/debugserver( |$)|\/lldb( |$)/ && !/awk/{print $2}'); do
  kill -9 "$pid" 2>/dev/null
done

# cleanup_all deliberately unloads every com.macwsguide job first so a
# crashing GUI dependency cannot respawn while processes are being reaped.
# macwshostd is different: it is the iOS-side control plane that lets macPad
# start a fresh, stopped workspace.  Leaving it unloaded makes the next app
# launch permanently report "root control service offline" because no process
# remains that can bootstrap the GUI stack.  Republish only this bounded Mach
# service after cleanup; its status operation is passive and does not start
# WindowServer or any chroot service.
hostd_plist=/var/jb/Library/LaunchDaemons/com.macwsguide.hostd.plist
if [ -f "$hostd_plist" ]; then
  echo === restoring macPad root control service ===
  launchctl load "$hostd_plist" 2>/dev/null || true
fi

sleep 2
echo
echo === final state ===
ps aux | grep -iE \
  "WindowServer|macwsallocd|macwsinputd|macwsdisplayd|macwsinteropd|OSXvnc|autosignd|launchdchroot|GlassDemo|Terminal|launchservicesd|coreservicesd|Visual Studio Code|Code Helper|Google Chrome|Chrome Helper|Steam Helper|Steam.app/Contents/MacOS/steam_osx|MacWSHost" \
  | grep -v grep | head -10 || echo "(none)"
echo
uptime
