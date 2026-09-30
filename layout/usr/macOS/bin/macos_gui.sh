# macos_gui.sh — start / stop the chroot macOS GUI stack (WindowServer + VNC +
# Terminal) on the iOS side, with a choice of display mode and full cleanup of
# any previously-running macOS services.
#
# Run as root from the iOS shell (NOT inside the chroot):
#
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh production        # one-click production profile
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh start coexist     # same production defaults, explicit command
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh start exclusive   # macOS takes the physical panel + VNC
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh stop              # tear everything down, return to iOS
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh restart coexist   # stop, then start in the given mode
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh status            # show what is running
#   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh trust             # restore this boot's persistent code trust only
#
# Options for start/restart:
#   coexist | exclusive   display mode (default: coexist)
#   --experimental        compatibility alias; native-AGX path is now the default
#   --no-experimental     rejected: production compatibility is built in
#   --diagnostics         also enable high-overhead AGX flight recorders/traces
#   --no-terminal         start WindowServer + VNC only, no Terminal
#   --no-vnc              disable remote VNC; keep the localhost pointer proxy
#   --pace-us=N           diagnostic synthetic-completion pace (8333..500000)
#   --runtime-cap=N        optional automation wall-clock cap (minimum 60s)
#
# The iOS-native temperature watchdog is mandatory.  There is deliberately no
# option to disable it: every GUI mode and benchmark stays inside the same
# thermal safety envelope.
#
# Why launchd jobs (and not just `OSXvnc &`):
#   launchdchrootexec posix_spawn()s the target with POSIX_SPAWN_SETEXEC, so it
#   *becomes* the chrooted process — there is no wrapper process to hold the
#   children alive.  A backgrounded OSXvnc/Terminal therefore dies the moment its
#   parent chroot bash (or the SSH session) exits.  launchd is the only parent
#   that survives a disconnect AND, because launchdchrootexec takes its
#   getppid()==1 "system service" path only under launchd, gives the GUI clients
#   the same launch type WindowServer already relies on.  So VNC + Terminal are
#   run as generated launchd jobs (modelled on com.apple.WindowServer.plist).
#
# NO shebang on purpose: this jailbreak's AMFI SIGKILLs execve() of any file with
# a `#!` line (see CLAUDE.md).  Always invoke via `bash <path>`.

set -u

# ─── Paths ──────────────────────────────────────────────────────────────────
ROOTFS=/var/mnt/rootfs
MACOS_DAEMONS=/var/jb/usr/macOS/LaunchDaemons  # WindowServer + required macOS services
WINDOWSERVER_PLIST="$MACOS_DAEMONS/com.apple.WindowServer.plist"
LAUNCHSERVICESD_PLIST="$MACOS_DAEMONS/com.apple.coreservices.launchservicesd.plist"
SHAREDFILELISTD_PLIST="$MACOS_DAEMONS/com.apple.coreservices.sharedfilelistd.plist"
MACOS_DISKARBITRATIOND_PLIST="$MACOS_DAEMONS/com.macwsguide.macos-diskarbitrationd.plist"
FILECOORDINATION_PLIST="$MACOS_DAEMONS/com.macwsguide.filecoordination.plist"
SYSTEMSTATUSD_PLIST="$MACOS_DAEMONS/com.apple.systemstatusd.plist"
FONTD_PLIST="$MACOS_DAEMONS/com.macwsguide.xtyped.plist"
VIEWBRIDGE_PLIST="$MACOS_DAEMONS/com.macwsguide.viewbridge.plist"
EXTENSIONKIT_PLIST="$MACOS_DAEMONS/com.macwsguide.extensionkit.plist"
HISERVICES_PLIST="$MACOS_DAEMONS/com.macwsguide.hiservices.plist"
GEOD_PLIST="$MACOS_DAEMONS/com.macwsguide.geod.plist"
OFFICE_LICENSING_PLIST="$MACOS_DAEMONS/com.macwsguide.office-licensing.plist"
CHROOTEXEC=/var/jb/usr/macOS/bin/launchdchrootexec
RUN_BASH=/var/jb/usr/macOS/bin/run_bash.sh
POSTINST=/var/jb/usr/macOS/bin/postinst.sh
RESTART_AUTOSIGND=/var/jb/usr/macOS/bin/restart_autosignd.sh
METAL2METAL_COMPAT_PROVISIONER=/var/jb/usr/macOS/bin/ensure_metal2metal_compat.sh
THERMAL_HELPER=/var/jb/usr/macOS/bin/macwsthermal
MOUNTDEVFS=/var/jb/usr/macOS/bin/mountdevfs
LOGDIR=/var/jb/var/mobile
TEST_LEASE=/tmp/macws_test_lease
GUI_TRANSACTION_LOCK=/tmp/.macos_gui.transaction
GUI_TRANSACTION_PID="$GUI_TRANSACTION_LOCK/pid"
GUI_START_STATE=/tmp/macos_gui_start.state
GUI_TRANSACTION_HELD=0
GUI_TRANSACTION_STARTED=0

GUI_LAUNCHD_DIR=/var/jb/usr/macOS/gui-launchd   # script-owned; NOT auto-scanned at boot
WATCHDOG_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.watchdog.plist"
VSCODE_ASSET_DIR=/var/jb/usr/macOS/share/vscode
VNC_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.osxvnc.plist"
VNC_POINTER_PROXY_SOCKET="$ROOTFS/private/tmp/macws_vnc_pointer_proxy.sock"
TERM_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.terminal.plist"
PBOARD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.pboard.plist"
PBS_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.pbs.plist"
LSD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.lsd.plist"
LSD_SYSTEM_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.lsd-system.plist"
CFPREFSD_DAEMON_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.cfprefsd-daemon.plist"
CFPREFSD_AGENT_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.cfprefsd-agent.plist"
CFPREFSD_MOBILE_AGENT_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.cfprefsd-mobile-agent.plist"
COREAUDIOD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.coreaudiod.plist"
AUDIO_COMPONENT_REGISTRAR_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.audiocomponentregistrar.plist"
AUDIO_OUTPUT_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.audio-output.plist"
MACOS_LOCATIOND_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.macos-locationd.plist"
CORELOCATIONAGENT_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.corelocationagent.plist"
LOCATIONBRIDGE_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.locationbridge.plist"
ICONSERVICESD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.iconservicesd.plist"
ICONSERVICESAGENT_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.iconservicesagent.plist"
PLUGINKIT_PKD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.pluginkit-pkd.plist"
QUICKLOOK_THUMBNAILS_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.quicklook-thumbnails.plist"
QUICKLOOKD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.quicklookd.plist"
QUICKLOOK_SATELLITE_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.quicklook-satellite.plist"
CSNAMEDDATAD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.csnameddatad.plist"
CORESERVICESD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.coreservicesd.plist"
AUTHD_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.authd.plist"
DESKTOP_SERVICES_HELPER_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.desktopserviceshelper.plist"
FINDER_DESKTOP_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.finder-desktop.plist"
DOCK_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.dock.plist"
SYSTEMUI_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.systemuiserver.plist"
CONTROL_CENTER_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.controlcenter.plist"
INPUT_PLIST="$MACOS_DAEMONS/com.macwsguide.input.plist"
DISPLAY_PLIST="$MACOS_DAEMONS/com.macwsguide.display.plist"
INTEROP_PLIST="$MACOS_DAEMONS/com.macwsguide.interop.plist"
WINDOWSERVER_LABEL=UIKitApplication:com.macwsguide.windowserver
# Upgrade-only label used by packages predating the UIKitApplication namespace.
# A loaded copy owns the same SkyLight MachServices and makes the current job
# exit 256 before launchd can assign it a PID.
WINDOWSERVER_LEGACY_LABEL=com.apple.WindowServer
VNC_LABEL=UIKitApplication:com.macwsguide.osxvnc
TERM_LABEL=UIKitApplication:com.macwsguide.terminal
PBOARD_LABEL=com.macwsguide.pboard
PBS_LABEL=com.macwsguide.pbs
LSD_LABEL=com.macwsguide.lsd
LSD_SYSTEM_LABEL=com.macwsguide.lsd-system
CFPREFSD_DAEMON_LABEL=com.macwsguide.cfprefsd-daemon
CFPREFSD_AGENT_LABEL=com.macwsguide.cfprefsd-agent
CFPREFSD_MOBILE_AGENT_LABEL=com.macwsguide.cfprefsd-mobile-agent
COREAUDIOD_LABEL=com.apple.audio.coreaudiod
AUDIO_COMPONENT_REGISTRAR_LABEL=com.apple.macosbooter.audio.AudioComponentRegistrar
AUDIO_OUTPUT_LABEL=com.macwsguide.audio-output
MACOS_LOCATIOND_LABEL=com.macwsguide.macos-locationd
CORELOCATIONAGENT_LABEL=com.macwsguide.corelocationagent
LOCATIONBRIDGE_LABEL=com.macwsguide.locationbridge
ICONSERVICESD_LABEL=com.macwsguide.iconservicesd
ICONSERVICESAGENT_LABEL=com.macwsguide.iconservicesagent
PLUGINKIT_PKD_LABEL=com.macwsguide.pluginkit-pkd
QUICKLOOK_THUMBNAILS_LABEL=com.macwsguide.quicklook-thumbnails
QUICKLOOKD_LABEL=com.macwsguide.quicklookd
QUICKLOOK_SATELLITE_LABEL=com.macwsguide.quicklook-satellite
CSNAMEDDATAD_LABEL=com.macwsguide.csnameddatad
CORESERVICESD_LABEL=com.macwsguide.coreservicesd
AUTHD_LABEL=com.macwsguide.authd
DESKTOP_SERVICES_HELPER_LABEL=com.macwsguide.desktopserviceshelper
FINDER_DESKTOP_LABEL=com.macwsguide.finder-desktop
DOCK_LABEL=com.macwsguide.dock
SYSTEMUI_LABEL=com.macwsguide.systemuiserver
CONTROL_CENTER_LABEL=com.macwsguide.controlcenter
INPUT_LABEL=UIKitApplication:com.macwsguide.input
DISPLAY_LABEL=UIKitApplication:com.macwsguide.display
INTEROP_LABEL=UIKitApplication:com.macwsguide.interop
VIEWBRIDGE_LABEL=com.macwsguide.viewbridge
EXTENSIONKIT_LABEL=com.macwsguide.extensionkit
HISERVICES_LABEL=com.macwsguide.hiservices
GEOD_LABEL=com.macwsguide.geod
OFFICE_LICENSING_LABEL=com.macwsguide.office-licensing
SHAREDFILELISTD_LABEL=com.apple.coreservices.sharedfilelistd
MACOS_DISKARBITRATIOND_LABEL=com.macwsguide.macos-diskarbitrationd
FILECOORDINATION_LABEL=com.macwsguide.filecoordination
WATCHDOG_LABEL=com.macwsguide.watchdog
VSCODE_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.vscode.plist"
GEEKBENCH_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.geekbench.plist"
VSCODE_LABEL=UIKitApplication:com.macwsguide.vscode
STEAM_PLIST="$GUI_LAUNCHD_DIR/com.macwsguide.steam.runtime.plist"
STEAM_LABEL=UIKitApplication:com.macwsguide.steam
# Upgrade-only label used by packages predating Steam's application-class
# migration.  Leaving it registered would let the old efficient coalition
# race the new production job for Steam's singleton namespace.
STEAM_LEGACY_LABEL=com.macwsguide.steam
VSCODE_TRUST_SENTINEL="$ROOTFS/Applications/Visual Studio Code.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"
VSCODE_PROFILE_NAME=macws-vscode-profile-agx-native-production1
VSCODE_PROFILE_DIR="$ROOTFS/private/tmp/$VSCODE_PROFILE_NAME"
VSCODE_EXTENSIONS_DIR="$ROOTFS/private/tmp/macws-vscode-extensions"
# Metal's source-library FS cache is keyed by compiler build, not by the
# effective target triple. Before the macabi source adapter existed, VS Code
# populated this exact cache with air64-apple-ios16.3.0 MTLBs. Metal later
# returned those blobs to the macOS AGX device and rejected them as an
# unsupported library format. Keep an explicit project schema beside the
# regenerable library cache so a package/cold start cannot silently reuse
# artifacts produced under the old target policy.
VSCODE_METAL_CACHE_ROOT="$ROOTFS/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/C/com.microsoft.VSCode.helper/com.apple.metal"
VSCODE_METAL_LIBRARY_CACHE="$VSCODE_METAL_CACHE_ROOT/31001"
VSCODE_METAL_CACHE_SCHEMA=macws-macabi-source-v1
VSCODE_METAL_CACHE_MARKER="$VSCODE_METAL_CACHE_ROOT/.macws-source-target-schema"
VSCODE_ANGLE_MACABI_LIBRARY="$ROOTFS/usr/local/share/macws/angle/angle-default-1ba8ec3-macabi.metallib"
STEAM_ANGLE_MACABI_LIBRARY="$ROOTFS/usr/local/share/macws/angle/angle-default-5d4df51-macabi.metallib"
CHROME150_PLIST=/var/jb/Library/LaunchDaemons/com.macwsguide.chrome150.plist
CHROME150_LABEL=UIKitApplication:com.macwsguide.chrome150
EXPERIMENTAL_KCMD="$ROOTFS/private/tmp/macws_kcmd_fix"
EXPERIMENTAL_WRAPPED_KCMD="$ROOTFS/private/tmp/macws_kcmd_wrapped_fix"
EXPERIMENTAL_COMMAND_ERROR="$ROOTFS/private/tmp/macws_command_error_diag"
EXPERIMENTAL_IOGPU_ERROR="$ROOTFS/private/tmp/macws_iogpu_error_diag"
EXPERIMENTAL_PIPELINE_DIAG="$ROOTFS/private/tmp/macws_pipeline_diag"
EXPERIMENTAL_COMPLETION="$ROOTFS/private/tmp/macws_cancel_completion"
EXPERIMENTAL_VNC_SHARE="$ROOTFS/private/tmp/macws_vnc_share"
EXPERIMENTAL_FINAL_COMPOSITE="$ROOTFS/private/tmp/macws_final_composite"
EXPERIMENTAL_OBSERVE_PF550="$ROOTFS/private/tmp/macws_observe_pf550"
EXPERIMENTAL_SUBMIT_RING="$ROOTFS/private/tmp/macws_submit_ring"
EXPERIMENTAL_FAST_SUBMIT_RING="$ROOTFS/private/tmp/macws_submit_fast_ring"
EXPERIMENTAL_RUNTIME_DIAGNOSTICS="$ROOTFS/private/tmp/macws_runtime_diagnostics"
MTLCOMPILER_DIAGNOSTICS=/tmp/macws_mtlcompiler_diagnostics
MTLCOMPILER_HOLD=/tmp/macws_mtlcompiler_hold
STEAM_ANGLE_ASSET_BUILD=/tmp/macws_steam_angle_asset_build
CATALYST_LAUNCH_TRACE=/tmp/macws_catalyst_launch.trace
MAPS_HOST_CARRIER_MARKER=/tmp/macws-maps-host-carrier.pid
EXPERIMENTAL_QUEUE_QOS="$ROOTFS/private/tmp/macws_queue_qos_diag"
EXPERIMENTAL_OWNED_SCANOUT="$ROOTFS/private/tmp/macws_owned_scanout"
EXPERIMENTAL_PACE="$ROOTFS/private/tmp/macws_coexist_pace_us"
EXPERIMENTAL_CAPTURE="$ROOTFS/private/tmp/macws_capture_final"
EXPERIMENTAL_CAPTURE_DONE="$ROOTFS/private/tmp/macws_capture_done"
VNC_SHARED_FRAME="$ROOTFS/private/tmp/macws_vnc_fb"
VNC_SHARED_SURFID="$ROOTFS/private/tmp/macws_vnc_surfid"
VNC_ACTIVITY="$ROOTFS/private/tmp/macws_vnc_activity"
RENDER_ACTIVITY="$ROOTFS/private/tmp/macws_render_activity"
INTERACTION_WAKE="$ROOTFS/private/tmp/macws_interaction_wake.sock"
VNC_ACTIVATION_REPLY="$ROOTFS/private/tmp/macws_vnc_activation_reply.sock"
GRAPHICS_READY="$ROOTFS/private/tmp/macws_graphics_ready"
LOCATION_PROVIDER_READY="$ROOTFS/private/tmp/macws_location_provider_ready"
ARMED_CAPTURE_GENERATION=""
CAPTURE_READY_WAIT=60
# A cold native-AGX start may spend more than 45 seconds realizing classes and
# compiling the first compositor pipelines before the first clean producer
# completion.  Keep the real completion/PID witness mandatory, but allow that
# evidence enough time to arrive; runtime sampling on 2026-07-30 saw a healthy
# WindowServer actively render before the old deadline, then publish the exact
# clean-producer witness shortly after the launcher had returned failure.
WINDOWSERVER_READY_WAIT=90
STARTED_WS_PID=""

VNC_BIN=/usr/local/bin/OSXvnc-server                                              # chroot path
TERM_BIN="/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"   # chroot path
PBOARD_BIN=/usr/libexec/pboard
PBS_BIN=/System/Library/CoreServices/pbs
FINDER_BIN=/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
DOCK_BIN=/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
SYSTEMUI_BIN=/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer
CONTROL_CENTER_BIN=/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter
OFFICE_LICENSING_BIN=/Library/PrivilegedHelperTools/com.microsoft.office.licensingV2.helper
ICONSERVICESD_BIN=/System/Library/CoreServices/iconservicesd
ICONSERVICESAGENT_BIN=/System/Library/CoreServices/iconservicesagent
PLUGINKIT_PKD_BIN=/usr/libexec/pkd
QUICKLOOK_THUMBNAILS_BIN=/System/Library/Frameworks/QuickLookThumbnailing.framework/Support/com.apple.quicklook.ThumbnailsAgent
QUICKLOOKD_BIN=/System/Library/Frameworks/QuickLook.framework/Resources/quicklookd.app/Contents/MacOS/quicklookd
QUICKLOOK_SATELLITE_BIN=/System/Library/Frameworks/QuickLook.framework/Versions/A/XPCServices/QuickLookSatellite.xpc/Contents/MacOS/QuickLookSatellite
QUICKLOOK_UI_SERVICE_BIN=/System/Library/Frameworks/QuickLookUI.framework/Versions/A/XPCServices/QuickLookUIService.xpc/Contents/MacOS/QuickLookUIService
CSNAMEDDATAD_BIN=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/CarbonCore.framework/Versions/A/XPCServices/csnameddatad.xpc/Contents/MacOS/csnameddatad
CORESERVICESD_BIN=/System/Library/CoreServices/coreservicesd
AUTHD_BIN=/System/Library/Frameworks/Security.framework/Versions/A/XPCServices/authd.xpc/Contents/MacOS/authd
DESKTOP_SERVICES_HELPER_BIN=/System/Library/PrivateFrameworks/DesktopServicesPriv.framework/Versions/A/Resources/DesktopServicesHelper
CSNAMEDDATA_PROXY=/var/jb/usr/macOS/Frameworks/HIServices.framework/Versions/A/XPCServices/HIServicesProxy.xpc/HIServicesProxy
DOCK_HELPER_PROXY=/var/jb/usr/macOS/Frameworks/Dock.framework/Versions/A/XPCServices/DockHelperProxy.xpc/DockHelperProxy
QUICKLOOK_UI_PROXY=/var/jb/usr/macOS/Frameworks/QuickLookUI.framework/Versions/A/XPCServices/QuickLookUIServiceProxy.xpc/QuickLookUIServiceProxy
# Never launch Ventura's stock cfprefsd image directly.  iPadOS AMFI rejects
# its Apple CT policy, while the project's broad chroot entitlement profile
# gives it com.apple.security.system-container and makes sandbox_init kill it.
# postinst creates this byte-identical private copy with the dedicated minimal
# cfprefsd entitlement profile that was runtime-validated on iPadOS 16.3.
CFPREFSD_BIN=/usr/local/libexec/macws-cfprefsd
DEFAULTS_BIN=/usr/bin/defaults
LSREGISTER_BIN=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
WORKSPACECTL_BIN=/usr/local/bin/macwsworkspacectl
LSD_SESSION_USER_DIR=/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/0/macws-lsd-session/
LSD_SYSTEM_DATA_VAULT_DIR=/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/0/com.apple.LaunchServices.dv
LAUNCHSERVICES_VERIFY_LOG="$LOGDIR/launchservices-catalog-verify.log"
SETTINGS_EXTENSION_REGISTER_LOG="$LOGDIR/settings-extension-register.log"
SETTINGS_EXTENSIONS_RUNTIME=/var/jb/usr/macOS/bin/ensure_settings_extensions_runtime.sh
SETTINGS_EXTENSIONS_RUNTIME_LOG="$LOGDIR/settings-extensions-runtime.log"
WORKSPACE_WALLPAPER='/usr/local/share/macws/wallpapers/macws-forest-lake.png'
FINAL_COMPOSITE_STATE="$ROOTFS/private/tmp/macws_final_composite.state"
WORKSPACE_GRAPH_STATE="$ROOTFS/private/tmp/macws_workspace_graph.state"
VNC_DESKTOP=macOS-iPad

SPRINGBOARD=/System/Library/LaunchDaemons/com.apple.SpringBoard.plist
BACKBOARDD=/System/Library/LaunchDaemons/com.apple.backboardd.plist

# Process-match patterns (full paths; unique to the chroot macOS processes so we
# never hit an iOS process by accident — iOS has no WindowServer/launchservicesd).
P_WINDOWSERVER='SkyLight.framework/Resources/WindowServer'
P_LAUNCHSERVICESD='CoreServices/launchservicesd'
P_SHAREDFILELISTD='/System/Library/CoreServices/sharedfilelistd'
P_SYSTEMSTATUSD='SystemStatusServer.framework/Support/systemstatusd'
P_FONTD='ATS.framework/Support/fontd'
P_OSXVNC='OSXvnc-server'
P_TERMINAL='Utilities/Terminal.app/Contents/MacOS/Terminal'
P_PBOARD='/usr/libexec/pboard'
P_PBS='/System/Library/CoreServices/pbs'
P_ACTIVITYMON='Activity Monitor.app/Contents/MacOS/Activity Monitor'
P_GLASSDEMO='/tmp/GlassDemo'
P_AMADINE='/Applications/Amadine.app/Contents/MacOS/Amadine'
P_WORD='/Applications/Microsoft Word.app/Contents/MacOS/Microsoft Word'
P_EXCEL='/Applications/Microsoft Excel.app/Contents/MacOS/Microsoft Excel'
P_POWERPOINT='/Applications/Microsoft PowerPoint.app/Contents/MacOS/Microsoft PowerPoint'
P_MAPS='/System/Applications/Maps.app/Contents/MacOS/Maps'
P_SYSTEM_SETTINGS='/System/Applications/System Settings.app/Contents/MacOS/System Settings'
P_FINDER='CoreServices/Finder.app/Contents/MacOS/Finder'
P_DOCK='CoreServices/Dock.app/Contents/MacOS/Dock'
P_SYSTEMUI='CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer'
P_CONTROL_CENTER='CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter'
P_OFFICE_LICENSING='PrivilegedHelperTools/com.microsoft.office.licensingV2.helper'
P_ICONSERVICESD='CoreServices/iconservicesd'
P_ICONSERVICESAGENT='CoreServices/iconservicesagent'
P_QUICKLOOK_THUMBNAILS='QuickLookThumbnailing.framework/Support/com.apple.quicklook.ThumbnailsAgent'
P_QUICKLOOKD='QuickLook.framework/Resources/quicklookd.app/Contents/MacOS/quicklookd'
P_QUICKLOOK_SATELLITE='QuickLook.framework/Versions/A/XPCServices/QuickLookSatellite.xpc/Contents/MacOS/QuickLookSatellite'
P_CSNAMEDDATAD='XPCServices/csnameddatad.xpc/Contents/MacOS/csnameddatad'
P_CORESERVICESD='/System/Library/CoreServices/coreservicesd'
P_DOCK_HELPER='XPCServices/DockHelper.xpc/Contents/MacOS/DockHelper'
P_INPUTD='/usr/local/bin/macwsinputd'
P_DISPLAYD='/usr/local/bin/macwsdisplayd'
P_INTEROPD='/usr/local/libexec/MacWSInteropService.app/Contents/MacOS/macwsinteropd'
P_VSCODE='Visual Studio Code.app/Contents/'
P_CHROME150='Google Chrome.app/Contents/'
P_STEAM_OUTER='/Applications/Steam.app/Contents/MacOS/steam_osx'
P_STEAM_LIVE='/Steam.AppBundle/Steam/Contents/MacOS/steam_osx'
P_STEAM_HELPER='Steam Helper.app/Contents/MacOS/Steam Helper'

# Opt-in invocation audit for tracking an unexpected second start/stop without
# leaving permanent command logging in normal use.  The 2026-07-29 controlled
# browser run had its 16,667-us sentinel overwritten to 100,000 us by another
# invocation; process uptime alone could not identify its already-exited
# parent.  Touch $LOGDIR/macws_trace_gui_invocations before a diagnostic run.
if [ -f "$LOGDIR/macws_trace_gui_invocations" ]; then
    {
        printf '%s pid=%s ppid=%s uid=%s args=' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$PPID" "$(id -u)"
        printf '%q ' "$@"
        printf ' parent='
        ps -o command= -p "$PPID" 2>/dev/null || true
        printf '\n'
    } >> "$LOGDIR/macos_gui_invocations.log" 2>&1
fi

# A controlled performance run can hold an explicit lease so a stale SSH
# script cannot silently tear down its WindowServer and replace the pacing or
# client set mid-sample.  Runtime-confirmed 2026-07-29: an unrelated deferred
# `ssh ... bash -s` invoked `start coexist --no-terminal --no-watchdog` during
# a VS Code cold-start regression; the invocation audit captured the exact
# command and parent after it replaced the measured WindowServer PID.  Normal
# interactive use is unchanged because the lease file is absent.  Test owners
# create the file and pass the same token through sudo:
#
#   sudo env MACWS_TEST_LEASE_TOKEN=<token> bash macos_gui.sh start ...
#
# `status` remains read-only and is always allowed.
case "${1:-}" in
    start|restart|stop|production|repair-desktop)
        if [ -f "$TEST_LEASE" ]; then
            expected_lease=$(awk 'NR == 1 { print; exit }' "$TEST_LEASE" 2>/dev/null)
            provided_lease="${MACWS_TEST_LEASE_TOKEN:-}"
            if [ -z "$expected_lease" ] || [ "$provided_lease" != "$expected_lease" ]; then
                log_line="REFUSED: active test lease blocks '$1' (pid=$$ ppid=$PPID)"
                echo "[macos_gui] $log_line" >&2
                echo "$(date '+%Y-%m-%d %H:%M:%S') $log_line" \
                    >> "$LOGDIR/macos_gui_invocations.log" 2>&1
                exit 75
            fi
        fi
        ;;
esac

# ─── Watchdog (crash-loop safety net) ───────────────────────────────────────
# The native-AGX workload is distributed across WindowServer, application GPU
# processes and the kernel driver. A single process's CPU percentage therefore
# cannot establish whether the iPad is thermally safe. The primary guard reads
# iPadOS's NSProcessInfo thermal state and AppleSmartBattery temperature through
# an iOS-native helper. Temperature values and non-critical states are evidence
# only; per policy, thermal intervention occurs only at `critical`.
WD_THERMAL_POLL=300  # temperature sensors are sampled every 5 minutes
WD_ARM_TIMEOUT=30    # cold-boot launchd scheduling can exceed the old 10s window
# Do not gate or stop the GUI on `memory_pressure -Q`. iOS deliberately uses
# otherwise-idle RAM for caches and reclaimable objects, so a free-percentage
# threshold is not a reliable pressure-state boundary. The former 58% policy
# produced a runtime-confirmed false stop during an otherwise healthy launch
# and is retired. XNU/iOS memorystatus remains the authority for reclamation.
WD_RESTART_LIMIT=12  # WindowServer restarts within WD_WINDOW that means "crash loop"
                     # (raised from 4: Firefox triggers some SkyLight CAWSBackend asserts
                     #  we haven't byte-patched yet (render_update composite_destination
                     #  nullptr). launchd respawns WS in ~1s; up to ~12 restarts per 45s
                     #  is annoying but not yet runaway — only stop if it's much worse)
WD_WINDOW=45         # seconds — restart-counting window
WD_POLL=5            # seconds between checks
# Interactive VNC sessions must not disappear at an arbitrary test deadline.
# The old unconditional 300-second limit runtime-confirmed the user's abrupt
# shutdown: the watchdog logged the cap trip while VS Code logged SIGTERM.
# Crash-loop/load/sustained-CPU guards remain armed. Bounded automation can
# opt back into a wall-clock limit with --runtime-cap=SECONDS.
WD_MAX_RUNTIME=0
WD_LOG="$LOGDIR/macos_gui_watchdog.log"
WD_TRIP=/tmp/macws_safety_trip
WD_PIDFILE=/tmp/macos_gui_watchdog.pid
WD_READY=/tmp/macos_gui_watchdog.ready
WD_THERMAL_SNAPSHOT="$LOGDIR/macos_gui_thermal_snapshot"
WD_WS_PIDFILE=/tmp/macos_gui_watchdog.ws-pid
RECOVERED_WS_PID=""
RECOVERY_EXTRA_RESTARTS=0

# ─── Helpers ────────────────────────────────────────────────────────────────
log() { echo "[macos_gui] $*"; }

# `start`, `restart`, and `stop` mutate the same outer-launchd contracts. A
# second control-centre tap used to enter cleanup while the first invocation
# was still publishing services, leaving a plausible-looking half stack whose
# WindowServer or lsd belonged to the wrong generation. `mkdir` is the one
# atomic primitive available in the device shell. Keep the lock recoverable by
# recording the exact owner PID and reclaiming it only after that PID is gone.
release_gui_transaction() {
    local owner=""
    [ "$GUI_TRANSACTION_HELD" -eq 1 ] || return 0
    owner=$(sed -n '1p' "$GUI_TRANSACTION_PID" 2>/dev/null)
    if [ "$owner" = "$$" ]; then
        rm -f "$GUI_TRANSACTION_PID"
        rmdir "$GUI_TRANSACTION_LOCK" 2>/dev/null || true
    fi
    GUI_TRANSACTION_HELD=0
}

acquire_gui_transaction() {
    local operation="$1" owner="" owner_command="" attempt=0
    while [ "$attempt" -lt 2 ]; do
        if mkdir "$GUI_TRANSACTION_LOCK" 2>/dev/null; then
            printf '%s\n' "$$" > "$GUI_TRANSACTION_PID" || {
                rmdir "$GUI_TRANSACTION_LOCK" 2>/dev/null || true
                return 1
            }
            GUI_TRANSACTION_HELD=1
            GUI_TRANSACTION_STARTED=$(date +%s)
            trap release_gui_transaction EXIT
            return 0
        fi
        owner=$(sed -n '1p' "$GUI_TRANSACTION_PID" 2>/dev/null)
        case "$owner" in
            ''|*[!0-9]*) owner="" ;;
        esac
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
            owner_command=$(ps -p "$owner" -o command= 2>/dev/null)
            log "ERROR: GUI transition '$operation' refused; pid=$owner is already changing the MacWS stack (${owner_command:-unknown command})."
            return 75
        fi
        # A killed shell cannot run its EXIT trap. Remove only the two exact
        # script-owned lock objects, then retry the atomic mkdir once.
        rm -f "$GUI_TRANSACTION_PID"
        rmdir "$GUI_TRANSACTION_LOCK" 2>/dev/null || return 75
        log "Recovered stale GUI transition lock (previous owner=${owner:-unknown})."
        attempt=$((attempt + 1))
    done
    return 75
}

write_gui_start_state() {
    local phase="$1" detail="${2:-}" temporary="${GUI_START_STATE}.new.$$"
    {
        printf 'schema=macws-gui-start-v1\n'
        printf 'pid=%s\n' "$$"
        printf 'operation=%s\n' "$CMD"
        printf 'mode=%s\n' "$MODE"
        printf 'phase=%s\n' "$phase"
        printf 'started_at=%s\n' "$GUI_TRANSACTION_STARTED"
        printf 'updated_at=%s\n' "$(date +%s)"
        printf 'detail=%s\n' "$detail"
    } > "$temporary" || return 1
    chmod 0644 "$temporary" || return 1
    mv -f "$temporary" "$GUI_START_STATE"
}

require_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "macos_gui.sh: must run as root — use:  sudo bash $0 $*" >&2
        exit 1
    fi
}

# Kill chroot macOS processes whose full command line contains a (fixed-string)
# pattern. This device has no pkill/pgrep, so do it with ps + kill. Patterns are
# full chroot paths, unique to the macOS processes, so iOS processes are never hit.
CLEANUP_TERM_PIDS=""
RESTORE_MAPS_AFTER_WS=0
pattern_is_running() {
    ps aux 2>/dev/null | grep -v grep | grep -Fq "$1"
}

kill_by_pattern() {
    local pat="$1" pids pid
    # `ps aux` truncates long command lines on iPadOS 16.  Steam Helper's
    # executable path only appears past that boundary, so the old cleanup
    # silently left its CEF/browser descendants alive after the owning job
    # exited.  `ps ax -o command=` is the same full-width process view used by
    # the status path and is runtime-confirmed to expose the complete Helper
    # path on this device.
    pids=$(ps ax -o pid=,command= 2>/dev/null |
        grep -v grep | grep -F "$pat" | awk '{print $1}')
    for pid in $pids; do
        [ "$pid" = "$$" ] && continue
        kill "$pid" 2>/dev/null
        case " $CLEANUP_TERM_PIDS " in
            *" $pid "*) ;;
            *) CLEANUP_TERM_PIDS="$CLEANUP_TERM_PIDS $pid" ;;
        esac
    done
    return 0
}

# Stop several exact chroot executables from one full-width process snapshot.
# Routine stop used to invoke `ps ax` once per pattern (more than thirty times
# on the production path).  Runtime timing on 2026-08-17 showed that all
# selected processes converged inside the existing shared grace period; the
# repeated process-table walks and serial launchctl calls, not TERM latency,
# dominated the 37-second stop.  Keep the same fixed-string executable
# identities and the same PID-bounded KILL fallback while taking one coherent
# snapshot for the complete WindowServer generation.
kill_patterns() {
    local snapshot="" line="" pid="" command="" pat="" matched=0
    [ "$#" -gt 0 ] || return 0
    snapshot=$(ps ax -o pid=,command= 2>/dev/null) || return 0
    while IFS= read -r line; do
        pid=${line%%[![:space:]]*}
        line=${line#"$pid"}
        line=${line#${line%%[![:space:]]*}}
        pid=${line%%[[:space:]]*}
        command=${line#"$pid"}
        command=${command#${command%%[![:space:]]*}}
        case "$pid" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "$pid" = "$$" ] && continue
        matched=0
        for pat in "$@"; do
            case "$command" in
                *"$pat"*) matched=1; break ;;
            esac
        done
        [ "$matched" -eq 1 ] || continue
        kill "$pid" 2>/dev/null
        case " $CLEANUP_TERM_PIDS " in
            *" $pid "*) ;;
            *) CLEANUP_TERM_PIDS="$CLEANUP_TERM_PIDS $pid" ;;
        esac
    done <<EOF
$snapshot
EOF
    return 0
}

# Third-party AppKit applications are just as tightly bound to their creating
# WindowServer generation as the system applications above.  Runtime-confirmed
# 2026-08-13 in Amadine.host.log and all three Office host logs: after a WS
# replacement each process received "WindowServer event port death" and
# "port matched the WindowServer port created in BindCGSToRunLoop", then
# remained alive with no reusable window.  Retire those exact executables at
# the same lifecycle boundary so Host never mistakes a dead CGS client for an
# application it can reopen.
kill_third_party_ws_clients() {
    kill_by_pattern "$P_AMADINE"
    kill_by_pattern "$P_WORD"
    kill_by_pattern "$P_EXCEL"
    kill_by_pattern "$P_POWERPOINT"
}

# AppKit clients can ignore or remain stuck while handling SIGTERM.  A plain
# process uptime check used to make cleanup look successful even though an old
# Finder survived for 81 minutes at 83% CPU and continuously logged an
# incompatible LaunchServices schema.  Give the complete, exact PID set one
# shared grace period, then KILL only surviving members of that set.  This is a
# lifecycle invariant: no client connected to the previous WindowServer may
# enter the next generation.
finish_pattern_cleanup() {
    local deadline alive="" pid
    [ -z "$CLEANUP_TERM_PIDS" ] && return 0
    deadline=$(( $(date +%s) + 2 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        alive=""
        for pid in $CLEANUP_TERM_PIDS; do
            kill -0 "$pid" 2>/dev/null && alive="$alive $pid"
        done
        [ -z "$alive" ] && break
        sleep 0.1
    done
    for pid in $alive; do
        kill -KILL "$pid" 2>/dev/null
    done
    CLEANUP_TERM_PIDS=""
}

# True if any running process's command line contains the (fixed-string) pattern.
proc_running() {
    ps aux 2>/dev/null | grep -v grep | grep -qF "$1"
}

wait_for_vnc_pointer_proxy() {
    local waited=0
    while [ "$waited" -lt 100 ]; do
        if proc_running "$P_OSXVNC" && [ -S "$VNC_POINTER_PROXY_SOCKET" ]; then
            log "OSXvnc pointer proxy ready at $VNC_POINTER_PROXY_SOCKET."
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    proc_running "$P_OSXVNC" ||
        log "ERROR: OSXvnc pointer-proxy process did not start."
    [ -S "$VNC_POINTER_PROXY_SOCKET" ] ||
        log "ERROR: OSXvnc pointer-proxy socket was not published."
    return 1
}

# launchd's current PID for one exact job (empty / "-" when not running).
launchd_job_pid() {
    local snapshot="" line="" value=""
    # Keep PID parsing in this shell.  At the Stray/Steam allocation peak the
    # old ``launchctl | awk`` pipeline runtime-confirmed an ENOMEM in awk and
    # returned an empty PID even though WindowServer remained alive.  Callers
    # which need to make lifecycle decisions must also check this function's
    # status: a failed launchctl observation is unknown, never "no process".
    snapshot=$(launchctl list "$1" 2>/dev/null) || return 75
    while IFS= read -r line; do
        case "$line" in
            *'"PID"'*'= '*)
                value=${line#*= }
                value=${value%%;*}
                value=${value#\"}
                value=${value%\"}
                value=${value#${value%%[![:space:]]*}}
                value=${value%${value##*[![:space:]]}}
                case "$value" in
                    ''|*[!0-9]*) ;;
                    *) printf '%s\n' "$value"; return 0 ;;
                esac
                ;;
        esac
    done <<EOF
$snapshot
EOF
    printf '%s\n' '-'
    return 0
}

ws_pid() { launchd_job_pid "$WINDOWSERVER_LABEL"; }

record_ws_pid() {
    local pid="$1" tmp="${WD_WS_PIDFILE}.$$"
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$pid" > "$tmp" && mv "$tmp" "$WD_WS_PIDFILE"
}

# Do not connect multiple CGS clients while WindowServer is still realizing
# AGX classes, compiling its first pipelines, and publishing the first display
# command buffer.  Runtime A/B on 2026-07-27 showed 2400/2400 clean producer
# completions when clients were staggered, while the old simultaneous startup
# let the first WindowServer die with SIGSEGV and left VNC attached to a dead
# CGS session. In experimental mode, the first clean producer completion writes
# a one-shot PID witness; production readiness must not depend on diagnostic
# stderr traffic. Otherwise require a stable PID for eight consecutive samples.
wait_for_initial_ws_ready() {
    local log_start_line="$1" current="" previous="" stable=0 waited=0 ready_pid=""
    : "$log_start_line"
    while [ "$waited" -lt "$WINDOWSERVER_READY_WAIT" ]; do
        sleep 1
        waited=$((waited + 1))
        current=$(ws_pid)
        if [ -z "$current" ] || [ "$current" = "-" ]; then
            previous=""
            stable=0
            continue
        fi
        if [ "$current" = "$previous" ]; then
            stable=$((stable + 1))
        else
            previous="$current"
            stable=1
        fi

        if [ "$WANT_EXPERIMENTAL" = 1 ] && [ "$WANT_VNC" = 1 ]; then
            ready_pid=$(awk 'NR == 1 { print; exit }' "$GRAPHICS_READY" \
                2>/dev/null)
            if [ "$stable" -ge 2 ] && [ "$ready_pid" = "$current" ]; then
                STARTED_WS_PID="$current"
                log "WindowServer graphics ready (pid=$current, clean producer observed)."
                return 0
            fi
        elif [ "$stable" -ge 8 ]; then
            # A --no-vnc run intentionally has no VNC completion observer, so
            # it cannot emit the VNC-FLOW readiness witness above.  Only call
            # this process readiness; the subsequent CDP/WebGL test supplies
            # the actual graphics witness for headless measurements.
            STARTED_WS_PID="$current"
            log "WindowServer process ready (pid=$current, stable for ${stable}s; graphics not yet witnessed)."
            return 0
        fi
    done
    log "ERROR: WindowServer did not reach graphics-ready state after ${WINDOWSERVER_READY_WAIT}s."
    return 1
}

started_ws_unchanged() {
    local stage="$1" current
    current=$(ws_pid)
    if [ -n "$STARTED_WS_PID" ] && [ "$current" = "$STARTED_WS_PID" ]; then
        return 0
    fi
    log "ERROR: WindowServer changed during $stage (ready=$STARTED_WS_PID current=${current:--})."
    log "       Refusing to leave VNC attached to a dead CGS session."
    return 1
}

# Extract one key=value field from the helper's single-line output.  The helper
# uses integer centi-degrees specifically so policy never depends on locale or
# floating-point parsing in the shell.
thermal_field() {
    local line="$1" wanted="$2"
    printf '%s\n' "$line" | awk -v wanted="$wanted" '
        {
            for (i = 1; i <= NF; i++) {
                split($i, pair, "=")
                if (pair[1] == wanted) { print pair[2]; exit }
            }
        }'
}

# Populate THERMAL_* globals from one iOS-native sensor snapshot.  A nonzero
# helper exit status is expected for fair/serious/critical states, so validity
# is determined from its structured output rather than command success alone.
thermal_snapshot() {
    THERMAL_LINE=""
    THERMAL_STATE=""
    THERMAL_TEMP_CENTIC=""
    THERMAL_HELPER_RC=127

    [ -x "$THERMAL_HELPER" ] || return 1
    THERMAL_LINE=$("$THERMAL_HELPER" 2>&1)
    THERMAL_HELPER_RC=$?
    THERMAL_STATE=$(thermal_field "$THERMAL_LINE" thermal-state)
    THERMAL_TEMP_CENTIC=$(thermal_field "$THERMAL_LINE" effective-temp-centic)

    case "$THERMAL_STATE" in
        nominal|fair|serious|critical) ;;
        *) return 1 ;;
    esac
    return 0
}

record_thermal_snapshot() {
    local payload="$1" snapshot_tmp="${WD_THERMAL_SNAPSHOT}.$$"
    printf 'sampled-at=%s %s\n' "$(date +%s)" "$payload" > "$snapshot_tmp"
    mv "$snapshot_tmp" "$WD_THERMAL_SNAPSHOT"
}

# A GUI client cannot reuse its WindowServer connection after that server dies.
# Runtime evidence from OSXvnc is explicit:
#   "received notification of WindowServer event port death"
#   "port matched the WindowServer port created in BindCGSToRunLoop"
# Keeping that old process alive therefore leaves a valid TCP listener backed by
# a permanently dead CGS session.  Tear down only WS-dependent clients, wait for
# launchd's replacement WS to stay alive for two samples, then reconnect them.
stop_ws_dependents() {
    # LaunchServices, IconServices, named-data and SharedFileList are session
    # catalogs, not CGS clients. A controlled WindowServer generation change
    # can preserve them; full cleanup still omits the option and retires them.
    local preserve_catalog_services=0
    [ "${1:-}" = preserve-catalog-services ] && preserve_catalog_services=1
    CLEANUP_TERM_PIDS=""
    RESTORE_MAPS_AFTER_WS=0
    # Maps was previously omitted from the dependent set. Runtime evidence
    # showed its old process still alive with 0 windows and ~956 MiB footprint
    # after "WindowServer event port death"; it did not publish another window
    # in that generation. Remember that it was open, retire the stale generation
    # below, and let the foreground Host's existing Catalyst carrier recreate
    # exactly one fresh generation.
    pattern_is_running "$P_MAPS" && RESTORE_MAPS_AFTER_WS=1
    launchctl unload "$VNC_PLIST"  2>/dev/null
    launchctl unload "$TERM_PLIST" 2>/dev/null
    launchctl remove "$VNC_LABEL"  2>/dev/null
    launchctl remove "$TERM_LABEL" 2>/dev/null
    launchctl unload "$INPUT_PLIST" 2>/dev/null
    launchctl remove "$INPUT_LABEL" 2>/dev/null
    launchctl unload "$DISPLAY_PLIST" 2>/dev/null
    launchctl remove "$DISPLAY_LABEL" 2>/dev/null
    launchctl unload "$INTEROP_PLIST" 2>/dev/null
    launchctl remove "$INTEROP_LABEL" 2>/dev/null
    launchctl unload "$DESKTOP_SERVICES_HELPER_PLIST" 2>/dev/null
    launchctl remove "$DESKTOP_SERVICES_HELPER_LABEL" 2>/dev/null
    launchctl unload "$AUTHD_PLIST" 2>/dev/null
    launchctl remove "$AUTHD_LABEL" 2>/dev/null
    # This file is an output witness from the current interopd generation, not
    # persistent configuration. Never let a replacement process inherit an
    # apparently-ready provider from a dead generation.
    rm -f "$LOCATION_PROVIDER_READY"
    launchctl unload "$HISERVICES_PLIST" 2>/dev/null
    launchctl unload "$GEOD_PLIST" 2>/dev/null
    launchctl unload "$EXTENSIONKIT_PLIST" 2>/dev/null
    launchctl unload "$VIEWBRIDGE_PLIST" 2>/dev/null
    launchctl remove "$HISERVICES_LABEL" 2>/dev/null
    launchctl remove "$GEOD_LABEL" 2>/dev/null
    launchctl remove "$EXTENSIONKIT_LABEL" 2>/dev/null
    launchctl remove "$VIEWBRIDGE_LABEL" 2>/dev/null
    launchctl unload "$VSCODE_PLIST" 2>/dev/null
    launchctl remove "$VSCODE_LABEL" 2>/dev/null
    launchctl unload "$GEEKBENCH_PLIST" 2>/dev/null
    launchctl remove "UIKitApplication:com.macwsguide.geekbench" 2>/dev/null
    launchctl unload "$STEAM_PLIST" 2>/dev/null
    launchctl remove "$STEAM_LABEL" 2>/dev/null
    launchctl remove "$STEAM_LEGACY_LABEL" 2>/dev/null
    if [ "$preserve_catalog_services" -ne 1 ]; then
        launchctl unload "$SHAREDFILELISTD_PLIST" 2>/dev/null
        launchctl remove "$SHAREDFILELISTD_LABEL" 2>/dev/null
    fi

    # These are on-demand Ventura location services, kept outside the
    # auto-scanned LaunchDaemons directory so they can never race a missing
    # chroot/WindowServer at jailbreak startup.  Unload their exact jobs;
    # never use killall locationd because that would also terminate iPadOS's
    # native system location daemon.
    launchctl unload "$CORELOCATIONAGENT_PLIST" 2>/dev/null
    launchctl remove "$CORELOCATIONAGENT_LABEL" 2>/dev/null
    launchctl unload "$LOCATIONBRIDGE_PLIST" 2>/dev/null
    launchctl remove "$LOCATIONBRIDGE_LABEL" 2>/dev/null
    launchctl unload "$MACOS_LOCATIOND_PLIST" 2>/dev/null
    launchctl remove "$MACOS_LOCATIOND_LABEL" 2>/dev/null
    launchctl unload "$CHROME150_PLIST" 2>/dev/null
    launchctl remove "$CHROME150_LABEL" 2>/dev/null
    if [ "$preserve_catalog_services" -ne 1 ]; then
        launchctl unload "$LSD_PLIST" 2>/dev/null
        launchctl remove "$LSD_LABEL" 2>/dev/null
        launchctl unload "$LSD_SYSTEM_PLIST" 2>/dev/null
        launchctl remove "$LSD_SYSTEM_LABEL" 2>/dev/null
        launchctl unload "$ICONSERVICESAGENT_PLIST" 2>/dev/null
        launchctl unload "$ICONSERVICESD_PLIST" 2>/dev/null
        launchctl unload "$PLUGINKIT_PKD_PLIST" 2>/dev/null
        launchctl unload "$QUICKLOOK_THUMBNAILS_PLIST" 2>/dev/null
        launchctl unload "$QUICKLOOKD_PLIST" 2>/dev/null
        launchctl unload "$QUICKLOOK_SATELLITE_PLIST" 2>/dev/null
        launchctl remove "$ICONSERVICESAGENT_LABEL" 2>/dev/null
        launchctl remove "$ICONSERVICESD_LABEL" 2>/dev/null
        launchctl remove "$PLUGINKIT_PKD_LABEL" 2>/dev/null
        launchctl remove "$QUICKLOOK_THUMBNAILS_LABEL" 2>/dev/null
        launchctl remove "$QUICKLOOKD_LABEL" 2>/dev/null
        launchctl remove "$QUICKLOOK_SATELLITE_LABEL" 2>/dev/null
        launchctl unload "$CSNAMEDDATAD_PLIST" 2>/dev/null
        launchctl remove "$CSNAMEDDATAD_LABEL" 2>/dev/null
        launchctl unload "$CORESERVICESD_PLIST" 2>/dev/null
        launchctl remove "$CORESERVICESD_LABEL" 2>/dev/null
    fi
    for workspace_plist in "$FINDER_DESKTOP_PLIST" "$DOCK_PLIST" \
                           "$SYSTEMUI_PLIST" "$CONTROL_CENTER_PLIST"; do
        launchctl unload "$workspace_plist" 2>/dev/null
    done
    for workspace_label in "$FINDER_DESKTOP_LABEL" "$DOCK_LABEL" \
                           "$SYSTEMUI_LABEL" "$CONTROL_CENTER_LABEL"; do
        launchctl remove "$workspace_label" 2>/dev/null
    done
    # A root SSH shell on this jailbreak can still submit `launchctl load`
    # into mobile's user/501 domain.  A system-domain unload then reports
    # success/no-op while the browser job survives and contaminates the next
    # supposedly clean benchmark.  Runtime-confirmed 2026-07-29 via
    # `launchctl print user/501/com.macwsguide.chrome150`.  Remove both
    # disposable browser jobs in that actual domain as well.
    launchctl asuser 501 launchctl unload "$VSCODE_PLIST" 2>/dev/null
    launchctl asuser 501 launchctl remove "$VSCODE_LABEL" 2>/dev/null
    launchctl asuser 501 launchctl unload "$GEEKBENCH_PLIST" 2>/dev/null
    launchctl asuser 501 launchctl remove "UIKitApplication:com.macwsguide.geekbench" 2>/dev/null
    launchctl asuser 501 launchctl unload "$STEAM_PLIST" 2>/dev/null
    launchctl asuser 501 launchctl remove "$STEAM_LABEL" 2>/dev/null
    launchctl asuser 501 launchctl remove "$STEAM_LEGACY_LABEL" 2>/dev/null
    launchctl asuser 501 launchctl unload "$CHROME150_PLIST" 2>/dev/null
    launchctl asuser 501 launchctl remove "$CHROME150_LABEL" 2>/dev/null

    kill_by_pattern "$P_OSXVNC"
    kill_by_pattern "$P_TERMINAL"
    kill_by_pattern "$P_ACTIVITYMON"
    kill_by_pattern "$P_GLASSDEMO"
    kill_third_party_ws_clients
    kill_by_pattern "$P_MAPS"
    # Like Maps, System Settings owns a WindowServer-bound AppKit shell plus
    # ExtensionKit child scenes.  Keeping that shell across a WindowServer
    # generation leaves a live PID with a dead CGS port; its stale metrics can
    # then be mistaken for a reusable window while the sidebar/content is
    # blank. Retire only the exact macOS executable during stack cleanup.
    kill_by_pattern "$P_SYSTEM_SETTINGS"
    rm -f "$MAPS_HOST_CARRIER_MARKER"
    kill_by_pattern "$P_FINDER"
    kill_by_pattern "$P_DOCK"
    kill_by_pattern "$P_DOCK_HELPER"
    kill_by_pattern "$P_SYSTEMUI"
    kill_by_pattern "$P_CONTROL_CENTER"
    if [ "$preserve_catalog_services" -ne 1 ]; then
        kill_by_pattern "$P_ICONSERVICESAGENT"
        kill_by_pattern "$P_ICONSERVICESD"
        kill_by_pattern "$P_QUICKLOOK_THUMBNAILS"
        kill_by_pattern "$P_QUICKLOOKD"
        kill_by_pattern "$P_QUICKLOOK_SATELLITE"
        kill_by_pattern "$P_CSNAMEDDATAD"
        kill_by_pattern "$P_CORESERVICESD"
        kill_by_pattern "$P_SHAREDFILELISTD"
    fi
    kill_by_pattern "$P_INPUTD"
    kill_by_pattern "$P_DISPLAYD"
    kill_by_pattern "$P_INTEROPD"
    kill_by_pattern "$P_VSCODE"
    kill_by_pattern "$P_STEAM_OUTER"
    kill_by_pattern "$P_STEAM_LIVE"
    kill_by_pattern "$P_STEAM_HELPER"
    kill_by_pattern "$P_CHROME150"
    finish_pattern_cleanup
    rm -f "$ROOTFS"/private/tmp/macws_app_input.*.sock
    rm -f "$ROOTFS"/private/tmp/macws_window_metrics.*.bin
    rm -f "$ROOTFS"/private/tmp/macws_menu_client.*.sock
    rm -f "$ROOTFS"/private/tmp/macws_menu_snapshot.*.bin
    rm -f "$ROOTFS"/private/tmp/macws_input_target.sock
}

start_macos_diskarbitrationd() {
    local waited=0 pid=""

    pid=$(launchd_job_pid "$MACOS_DISKARBITRATIOND_LABEL")
    case "$pid" in
        ''|*[!0-9]*) ;;
        *)
            if kill -0 "$pid" 2>/dev/null; then
                log "Private Ventura DiskArbitration endpoint already ready."
                return 0
            fi
            ;;
    esac

    # The public service name belongs to iPadOS and remains untouched.  The
    # injected Ventura daemon and clients symmetrically rewrite only their own
    # bootstrap traffic to the private service declared by this exact job.
    log "Starting private Ventura DiskArbitration endpoint..."
    launchctl unload "$MACOS_DISKARBITRATIOND_PLIST" 2>/dev/null
    launchctl remove "$MACOS_DISKARBITRATIOND_LABEL" 2>/dev/null
    rm -f "$LOGDIR/macos-diskarbitrationd.out" \
          "$LOGDIR/macos-diskarbitrationd.err"
    launchctl load "$MACOS_DISKARBITRATIOND_PLIST" || return 1
    while [ "$waited" -lt 10 ]; do
        pid=$(launchd_job_pid "$MACOS_DISKARBITRATIOND_LABEL")
        case "$pid" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$pid" 2>/dev/null && break ;;
        esac
        sleep 1
        waited=$((waited + 1))
    done
    case "$pid" in
        ''|*[!0-9]*)
            log "ERROR: private Ventura DiskArbitration endpoint did not start."
            tail -n 30 "$LOGDIR/macos-diskarbitrationd.err" 2>/dev/null || true
            return 1
            ;;
    esac
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 2
    kill -0 "$pid" 2>/dev/null || {
        log "ERROR: private Ventura DiskArbitration endpoint exited during readiness."
        tail -n 30 "$LOGDIR/macos-diskarbitrationd.err" 2>/dev/null || true
        return 1
    }
    log "Private Ventura DiskArbitration endpoint ready (pid=$pid)."
}

probe_sharedfilelistd() {
    local probe_pid waited=0 status=0
    local probe_log="$LOGDIR/sharedfilelistd.ready"

    rm -f "$probe_log"
    "$CHROOTEXEC" 0 0 "$ROOTFS" \
        /usr/local/bin/macwsworkspacectl shared-file-list-ready \
        >"$probe_log" 2>&1 &
    probe_pid=$!
    while kill -0 "$probe_pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    if kill -0 "$probe_pid" 2>/dev/null; then
        kill -TERM "$probe_pid" 2>/dev/null
        local terminate_wait=0
        while kill -0 "$probe_pid" 2>/dev/null &&
              [ "$terminate_wait" -lt 10 ]; do
            sleep 0.1
            terminate_wait=$((terminate_wait + 1))
        done
        if kill -0 "$probe_pid" 2>/dev/null; then
            # Runtime-confirmed on 2026-08-23: the probe was blocked in
            # LSSharedFileListCopySnapshot -> SFLGenericList snapshotItems,
            # while its worker waited synchronously for sharedfilelistd. It
            # did not leave after SIGTERM, and this formerly unbounded wait
            # wedged the entire Repair Desktop transaction. The target is the
            # exact child PID created above; force only that timed-out probe.
            kill -KILL "$probe_pid" 2>/dev/null
        fi
        wait "$probe_pid" 2>/dev/null || true
        log "ERROR: SharedFileList snapshot round-trip timed out."
        tail -n 20 "$probe_log" 2>/dev/null || true
        return 1
    fi
    wait "$probe_pid" 2>/dev/null || status=$?
    if [ "$status" -ne 0 ] ||
       ! grep -q '^shared-file-list-ready ' "$probe_log" 2>/dev/null; then
        log "ERROR: SharedFileList snapshot round-trip failed (status=$status)."
        tail -n 20 "$probe_log" 2>/dev/null || true
        return 1
    fi
    log "macOS SharedFileList snapshot round-trip ready."
}

start_sharedfilelistd_generation() {
    local waited=0
    rm -f "$LOGDIR/sharedfilelistd.out" "$LOGDIR/sharedfilelistd.err"
    launchctl load "$SHAREDFILELISTD_PLIST" || return 1
    while ! proc_running "$P_SHAREDFILELISTD" && [ "$waited" -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    proc_running "$P_SHAREDFILELISTD" || {
        log "ERROR: macOS sharedfilelistd did not reach a live process."
        tail -n 30 "$LOGDIR/sharedfilelistd.err" 2>/dev/null || true
        return 1
    }
    # The protocol round-trip below is a stronger readiness witness than a
    # blind two-second sleep: it constructs a fresh client, obtains the real
    # recent-document snapshot, and is bounded to five seconds. Check process
    # liveness again after that completed transaction so a daemon which exits
    # during the former quarantine window still fails this generation.
    probe_sharedfilelistd || return 1
    proc_running "$P_SHAREDFILELISTD" || {
        log "ERROR: macOS sharedfilelistd exited after its protocol witness."
        tail -n 30 "$LOGDIR/sharedfilelistd.err" 2>/dev/null || true
        return 1
    }
}

start_sharedfilelistd() {
    local generation=1

    start_macos_diskarbitrationd || return 1

    # AppKit populates the Apple menu and Steam initializes its login UI via
    # LSSharedFileListCopySnapshot. On the 2026-08-14 production run the real
    # Steam main thread blocked synchronously in SFLLoginItemList because the
    # corresponding Ventura Mach service had never been loaded. Loading this
    # stock daemon live released that exact call and Steam immediately reached
    # its Web Helper launch. A live PID and registered MachService are not
    # sufficient: require the bounded recent-document snapshot round-trip that
    # used to hang in VolumeManager::volumes.
    if proc_running "$P_SHAREDFILELISTD"; then
        launchctl list "$SHAREDFILELISTD_LABEL" >/dev/null 2>&1 && {
            probe_sharedfilelistd && {
                log "macOS SharedFileList endpoint already ready."
                return 0
            }
            log "Existing macOS SharedFileList process failed its protocol witness; restarting it."
        }
        kill_by_pattern "$P_SHAREDFILELISTD"
        finish_pattern_cleanup
    fi

    log "Starting macOS SharedFileList service before GUI applications..."
    while [ "$generation" -le 2 ]; do
        if [ "$generation" -gt 1 ]; then
            # Runtime-confirmed 2026-08-21: one cold-start launchd generation
            # produced only launchdchrootexec's pre-exec lines and no durable
            # process.  A full unload/load of the same stock daemon immediately
            # produced a real PID that stayed Ss for the ten-second observation
            # window.  Retire the failed generation, but keep every production
            # PID/stability/protocol witness mandatory on the replacement.
            log "Retrying macOS SharedFileList with a fresh launchd generation..."
            launchctl unload "$SHAREDFILELISTD_PLIST" 2>/dev/null || true
            kill_by_pattern "$P_SHAREDFILELISTD"
            finish_pattern_cleanup
            sleep 1
        fi
        if start_sharedfilelistd_generation; then
            log "macOS SharedFileList endpoint ready (generation=$generation)."
            return 0
        fi
        generation=$((generation + 1))
    done
    return 1
}

wait_for_replacement_ws() {
    local expected="$1" current="" stable=0 tries=0
    RECOVERY_EXTRA_RESTARTS=0
    while [ "$tries" -lt 20 ]; do
        sleep 1
        tries=$((tries + 1))
        current=$(ws_pid)
        if [ -z "$current" ] || [ "$current" = "-" ]; then
            stable=0
            continue
        fi
        if [ "$current" != "$expected" ]; then
            log "watchdog: replacement WindowServer changed again ($expected -> $current)"
            expected="$current"
            stable=1
            RECOVERY_EXTRA_RESTARTS=$((RECOVERY_EXTRA_RESTARTS + 1))
        else
            stable=$((stable + 1))
        fi
        if [ "$stable" -ge 2 ]; then
            RECOVERED_WS_PID="$current"
            return 0
        fi
    done
    RECOVERED_WS_PID=""
    return 1
}

ensure_navigation_spaces() {
    local rc=0

    # CGSSpaceCreate needs Dock's per-session Space controller to be live.
    # Runtime-confirmed on the 2026-08-09 cold boot: invoking the controller
    # after WindowServer but before Dock blocked indefinitely inside
    # `ensure-navigation-spaces`.  Require the upstream owner and bound the
    # IPC transaction so a broken Space service can never wedge GUI startup.
    proc_running "$P_DOCK" || {
        log "ERROR: Dock must be ready before establishing native macOS desktops."
        return 1
    }
    rm -f "$LOGDIR/navigation-spaces.log"
    /var/jb/usr/bin/timeout -k 2 20 \
        "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
        ensure-navigation-spaces > "$LOGDIR/navigation-spaces.log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "ERROR: could not establish adjacent native macOS desktops."
        [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] ||
            log "ERROR: native desktop IPC exceeded the 20-second startup bound."
        tail -n 20 "$LOGDIR/navigation-spaces.log" 2>/dev/null || true
        return 1
    fi
    log "Native macOS desktop navigation topology ready: $(tail -n 1 "$LOGDIR/navigation-spaces.log")"
}

refresh_dock_after_navigation_spaces() {
    local old_pid="" new_pid="" waited=0

    # Runtime-confirmed on 2026-08-11: a Dock process started before
    # `ensure-navigation-spaces` continued to accept vertical Mission Control
    # gestures but ignored both horizontal Space gestures (zero presentation
    # frames).  Reloading that same production job after the final two-Space
    # catalog existed immediately restored 48 live geometry updates and a
    # 38.96 FPS final drawable.  Bind Dock to the completed catalog as part of
    # the startup transaction instead of leaving a manual-restart dependency.
    old_pid=$(launchd_job_pid "$DOCK_LABEL")
    launchctl unload "$DOCK_PLIST" 2>/dev/null || return 1
    launchctl load "$DOCK_PLIST" || return 1
    while [ "$waited" -lt 15 ]; do
        new_pid=$(launchd_job_pid "$DOCK_LABEL")
        case "$new_pid" in
            ''|'-'|*[!0-9]*) ;;
            *)
                if [ "$new_pid" != "$old_pid" ] && proc_running "$P_DOCK"; then
                    log "Dock rebound to completed native desktop catalog (pid $old_pid -> $new_pid)."
                    return 0
                fi
                ;;
        esac
        sleep 1
        waited=$((waited + 1))
    done
    log "ERROR: Dock did not rebind to the completed native desktop catalog."
    return 1
}

start_ws_dependents_after_replacement() {
    local old_pid="$1" observed_pid="$2"

    # A memorystatus/resource-pressure event can retire autosignd in the same
    # interval as WindowServer.  The replacement WindowServer is already a
    # launchd job, so launchd will keep retrying it; every retry used to reach
    # libmachook's mandatory JIT authorization with no signing endpoint and
    # abort at jit.m:81.  Runtime-confirmed 2026-09-10 by the adjacent lines
    # `MACWS-JIT authorization failed ... connect_errno=61` for WindowServer,
    # macwsinputd and authd, followed by the watchdog recovery failure.  Repair
    # that shared upstream prerequisite before waiting for a stable replacement
    # generation.  wait_for_replacement_ws already follows any PID transition
    # caused by the endpoint becoming available.
    ensure_autosignd_ready || {
        log "watchdog: autosignd prerequisite did not recover"
        return 1
    }
    if ! wait_for_replacement_ws "$observed_pid"; then
        log "watchdog: replacement WindowServer did not become stable within 20 seconds"
        return 1
    fi

    publish_settings_service_contracts || {
        log "watchdog: private macOS settings service contracts did not recover"
        return 1
    }
    publish_desktop_operation_services || {
        log "watchdog: private macOS desktop-operation contracts did not recover"
        return 1
    }
    ensure_locationd_dirhelper_tree || {
        log "watchdog: Ventura locationd cache tree did not recover"
        return 1
    }
    [ ! -f "$MACOS_LOCATIOND_PLIST" ] ||
        launchctl load "$MACOS_LOCATIOND_PLIST" 2>/dev/null
    [ ! -f "$CORELOCATIONAGENT_PLIST" ] ||
        launchctl load "$CORELOCATIONAGENT_PLIST" 2>/dev/null
    if [ -f "$INPUT_PLIST" ]; then
        launchctl load "$INPUT_PLIST" 2>/dev/null
    fi
    [ ! -f "$DISPLAY_PLIST" ] || launchctl load "$DISPLAY_PLIST" 2>/dev/null
    [ ! -f "$INTEROP_PLIST" ] || launchctl load "$INTEROP_PLIST" 2>/dev/null
    # The native location producer publishes scalar fixes through interopd.
    # Start it only after that Mach listener exists; an XPC client created
    # before the listener on cold boot can lose its cached first fix.
    [ ! -f "$LOCATIONBRIDGE_PLIST" ] ||
        launchctl load "$LOCATIONBRIDGE_PLIST" 2>/dev/null
    [ ! -f "$LSD_SYSTEM_PLIST" ] || \
        launchctl load "$LSD_SYSTEM_PLIST" 2>/dev/null
    [ ! -f "$LSD_PLIST" ] || launchctl load "$LSD_PLIST" 2>/dev/null
    start_sharedfilelistd || {
        log "watchdog: macOS SharedFileList endpoint did not recover"
        return 1
    }
    [ ! -f "$ICONSERVICESD_PLIST" ] || \
        launchctl load "$ICONSERVICESD_PLIST" 2>/dev/null
    [ ! -f "$ICONSERVICESAGENT_PLIST" ] || \
        launchctl load "$ICONSERVICESAGENT_PLIST" 2>/dev/null
    [ ! -f "$PLUGINKIT_PKD_PLIST" ] || \
        launchctl load "$PLUGINKIT_PKD_PLIST" 2>/dev/null
    [ ! -f "$QUICKLOOK_THUMBNAILS_PLIST" ] || \
        launchctl load "$QUICKLOOK_THUMBNAILS_PLIST" 2>/dev/null
    [ ! -f "$QUICKLOOKD_PLIST" ] || \
        launchctl load "$QUICKLOOKD_PLIST" 2>/dev/null
    [ ! -f "$QUICKLOOK_SATELLITE_PLIST" ] || \
        launchctl load "$QUICKLOOK_SATELLITE_PLIST" 2>/dev/null
    [ ! -f "$CSNAMEDDATAD_PLIST" ] || \
        launchctl load "$CSNAMEDDATAD_PLIST" 2>/dev/null
    [ ! -f "$CORESERVICESD_PLIST" ] || \
        launchctl load "$CORESERVICESD_PLIST" 2>/dev/null
    for workspace_plist in "$FINDER_DESKTOP_PLIST" "$DOCK_PLIST" \
                           "$SYSTEMUI_PLIST" "$CONTROL_CENTER_PLIST"; do
        [ ! -f "$workspace_plist" ] || launchctl load "$workspace_plist" 2>/dev/null
    done
    # A replacement WindowServer owns a new session/Space catalog. Wait for
    # Dock's replacement controller before rebuilding the adjacent native
    # desktop topology; the bounded helper prevents recovery itself wedging.
    local workspace_waited=0
    while ! proc_running "$P_DOCK" && [ "$workspace_waited" -lt 15 ]; do
        sleep 1
        workspace_waited=$((workspace_waited + 1))
    done
    ensure_navigation_spaces || return 1
    refresh_dock_after_navigation_spaces || return 1
    apply_workspace_wallpaper || return 1
    # Full-screen Mission Control drags must be posted from OSXvnc's real
    # WindowServer/CGS client. Keep that process alive even when remote RFB is
    # disabled; write_plists then binds its RFB listener to localhost only.
    rm -f "$VNC_POINTER_PROXY_SOCKET"
    launchctl load "$VNC_PLIST" 2>/dev/null
    wait_for_vnc_pointer_proxy || {
        log "watchdog: local Mission Control pointer proxy did not recover"
        return 1
    }
    if [ "$WANT_TERMINAL" = 1 ]; then
        sleep 2
        launchctl load "$TERM_PLIST" 2>/dev/null
    fi
    if [ "$RESTORE_MAPS_AFTER_WS" = 1 ] &&
       [ -x /var/jb/usr/bin/uiopen ]; then
        # macwshost://maps is the sole production Catalyst launch route. It
        # brings the existing Host Scene forward, then the foreground Host
        # performs the responsible-process spawn required by UIKitSystem.
        /var/jb/usr/bin/uiopen --url 'macwshost://maps' >/dev/null 2>&1 ||
            log "watchdog: WARNING: Maps restoration request was rejected"
    fi
    if [ "$WANT_EXPERIMENTAL" = 1 ] && [ "$WANT_VNC" = 1 ] &&
       [ "$WANT_TERMINAL" = 1 ]; then
        arm_initial_vnc_capture_if_requested
        wait_for_initial_vnc_capture_if_requested
    fi
    log "watchdog: GUI clients reconnected after WS $old_pid -> $RECOVERED_WS_PID (vnc=$WANT_VNC terminal=$WANT_TERMINAL)"
    return 0
}

recover_ws_dependents() {
    local old_pid="$1" observed_pid="$2"
    log "watchdog: reconnecting GUI clients to replacement WindowServer $observed_pid"
    stop_ws_dependents preserve-catalog-services
    rm -f "$EXPERIMENTAL_CAPTURE" "$EXPERIMENTAL_CAPTURE_DONE"
    start_ws_dependents_after_replacement "$old_pid" "$observed_pid"
}

trip_watchdog() {
    local reason="$1"
    echo "$reason" > "$WD_TRIP"
    log "watchdog: SAFETY TRIP: $reason"
    stop_all
}

watchdog_pidfile_cleanup() {
    local owner=""
    [ -f "$WD_PIDFILE" ] || return 0
    IFS=' ' read -r owner _ 2>/dev/null < "$WD_PIDFILE" || owner=""
    [ "$owner" = "$$" ] && rm -f "$WD_PIDFILE" "$WD_READY"
    return 0
}

# Watchdog loop (runs iOS-side, backgrounded by `start`). Thermal telemetry is
# observation-only; WindowServer lifecycle and explicit runtime caps are
# independent non-thermal trip paths.
run_watchdog() {
    local last_pid="" restarts=0 t0 started now pid pid_probe_rc=0
    local missing_samples=0 next_thermal=0
    local ws_seen=0 startup_wait_logged=0 startup_missing_logged=0
    local observation_unavailable_logged=0
    local startup_owner="${MACWS_WATCHDOG_STARTUP_OWNER:-}"
    local runtime_cap_label="disabled"
    case "$startup_owner" in
        ''|*[!0-9]*) startup_owner="" ;;
    esac
    # Every launchd generation records its own PID. The ownership-aware EXIT
    # trap cannot erase a replacement watchdog's pidfile if relaunch timing
    # overlaps with the previous process exiting.
    echo "$$" > "$WD_PIDFILE"
    trap watchdog_pidfile_cleanup EXIT
    # launchd restarts this process after an abnormal death. Preserve the last
    # observed WindowServer PID outside the shell process so the replacement
    # can detect a server-generation change that happened while no loop was
    # running. Runtime-confirmed 2026-08-04: the old nohup watchdog vanished
    # with a stale pidfile while macwsdisplayd outlived WindowServer; restarting
    # only macwsdisplayd immediately restored every workspace capture layer.
    IFS=' ' read -r last_pid _ 2>/dev/null < "$WD_WS_PIDFILE" || last_pid=""
    case "$last_pid" in
        ''|*[!0-9]*) last_pid="" ;;
    esac
    t0=$SECONDS
    started=$t0
    next_thermal=$((started + WD_THERMAL_POLL))
    [ "$WD_MAX_RUNTIME" -gt 0 ] &&
        runtime_cap_label="${WD_MAX_RUNTIME}s"

    # Handshake proves that the independent watchdog process is alive. Thermal
    # state is observation-only and never controls Stray or the GUI session.
    if thermal_snapshot; then
        record_thermal_snapshot "$THERMAL_LINE"
        log "watchdog: initial thermal sample: $THERMAL_LINE"
    else
        record_thermal_snapshot "unavailable rc=$THERMAL_HELPER_RC output='${THERMAL_LINE:-}'"
        log "watchdog: WARNING: initial thermal telemetry unavailable rc=$THERMAL_HELPER_RC output='${THERMAL_LINE:-}'; observation-only"
    fi

    echo "$$" > "$WD_READY"
    log "watchdog: armed (temperature every ${WD_THERMAL_POLL}s, observe-only; memory guard=disabled; restarts>=$WD_RESTART_LIMIT/${WD_WINDOW}s; runtime cap=$runtime_cap_label)"
    while :; do
        sleep "$WD_POLL"
        now=$SECONDS
        if [ "$now" -ge "$next_thermal" ]; then
            next_thermal=$((now + WD_THERMAL_POLL))
            if thermal_snapshot; then
                record_thermal_snapshot "$THERMAL_LINE"
                log "watchdog: thermal sample: $THERMAL_LINE"
            else
                record_thermal_snapshot "unavailable rc=$THERMAL_HELPER_RC output='${THERMAL_LINE:-}'"
                log "watchdog: WARNING: thermal telemetry unavailable rc=$THERMAL_HELPER_RC output='${THERMAL_LINE:-}'; observation-only"
            fi
        fi

        # One allocation-safe launchctl snapshot supplies both job and PID
        # state.  If launchctl itself cannot be executed, the observation is
        # unknown: preserve the live GUI and retry instead of incrementing a
        # missing-process counter from missing evidence.
        pid=$(ws_pid)
        pid_probe_rc=$?
        if [ "$pid_probe_rc" -ne 0 ]; then
            if [ "$ws_seen" = 0 ] && [ -n "$startup_owner" ] &&
               kill -0 "$startup_owner" 2>/dev/null; then
                if [ "$startup_wait_logged" = 0 ]; then
                    log "watchdog: thermal guard active while launcher pid=$startup_owner prepares WindowServer."
                    startup_wait_logged=1
                fi
                continue
            fi
            if [ "$observation_unavailable_logged" = 0 ]; then
                log "watchdog: WARNING: WindowServer launchd observation unavailable rc=$pid_probe_rc; preserving session and retrying."
                observation_unavailable_logged=1
            fi
            missing_samples=0
            continue
        fi
        observation_unavailable_logged=0
        ws_seen=1
        if [ -z "$pid" ] || [ "$pid" = "-" ]; then
            missing_samples=$((missing_samples + 1))
            if [ "$missing_samples" -eq 1 ] || [ "$missing_samples" -eq 3 ]; then
                log "watchdog: WindowServer job is loaded but has no PID; requesting launchd start (sample=$missing_samples)"
                # EnableJIT needs a live autosignd RPC before the first
                # WindowServer instruction reaches libmachook. A later
                # dependent-recovery check cannot undo that abort.
                if ensure_autosignd_ready; then
                    launchctl start "$WINDOWSERVER_LABEL" 2>/dev/null
                else
                    log "watchdog: deferring WindowServer retry until autosignd is reachable"
                fi
            fi
            if [ "$missing_samples" -ge 4 ]; then
                # The foreground launcher owns the bounded 90-second initial
                # readiness transaction. Killing its LaunchServices/HIServices
                # dependencies after only four watchdog samples guarantees
                # that a cold AGX/JIT retry can never recover, while the
                # launcher keeps waiting against an already-destroyed stack.
                # During this phase keep the observe-only health guard and
                # leave lifecycle failure to wait_for_initial_ws_ready(). Once
                # the owner exits, ordinary missing-PID intervention resumes.
                if [ -n "$startup_owner" ] &&
                   kill -0 "$startup_owner" 2>/dev/null; then
                    if [ "$startup_missing_logged" = 0 ]; then
                        log "watchdog: launcher pid=$startup_owner still owns initial WindowServer readiness; deferring lifecycle trip."
                        startup_missing_logged=1
                    fi
                    continue
                fi
                trip_watchdog "WindowServer 连续 $((missing_samples * WD_POLL)) 秒没有进程，已自动停止 macOS GUI"
                return 0
            fi
        else
            missing_samples=0
            startup_missing_logged=0
        fi
        if [ -n "$pid" ] && [ "$pid" != "-" ] && [ -n "$last_pid" ] && [ "$pid" != "$last_pid" ]; then
            restarts=$((restarts + 1))
            log "watchdog: WindowServer restarted ($last_pid -> $pid), count=$restarts in window"
            if ! recover_ws_dependents "$last_pid" "$pid"; then
                trip_watchdog "WindowServer 重启后未能建立稳定会话，已自动停止 macOS GUI"
                return 0
            fi
            restarts=$((restarts + RECOVERY_EXTRA_RESTARTS))
            pid="$RECOVERED_WS_PID"
        fi
        if [ -n "$pid" ] && [ "$pid" != "-" ]; then
            last_pid="$pid"
            record_ws_pid "$pid" || \
                log "watchdog: WARNING: could not persist WindowServer pid=$pid"
        fi
        now=$SECONDS
        if [ $((now - t0)) -ge "$WD_WINDOW" ]; then restarts=0; t0=$now; fi
        if [ "$restarts" -ge "$WD_RESTART_LIMIT" ]; then
            trip_watchdog "WindowServer 在 ${WD_WINDOW} 秒内重启 ${restarts} 次，已自动停止"
            return 0
        fi
        if [ "$WD_MAX_RUNTIME" -gt 0 ] &&
           [ $((now - started)) -ge "$WD_MAX_RUNTIME" ]; then
            trip_watchdog "自动化运行达到 ${WD_MAX_RUNTIME} 秒显式上限，已自动停止"
            return 0
        fi
    done
}

# Restore only existing signatures required before autosignd and the macOS
# session can start. Dopamine's dynamic trustcache is reboot-volatile, while
# all CodeDirectories below persist on disk. Runtime LLDB on the 2026-08-09
# cold boot proved that omitting launchservicesd.dylib makes its loader call a
# NULL dlopen result; WindowServer then blocks in LS setup before publishing
# the SkyLight session port, leaving Dock and every AppKit client hung in
# get_session_port. This bounded restore changes no binary or signature.
BOOT_TRUSTCACHE_INFO=""
BASE_TRUST_READY=0
WINDOWING_STATUS_PROBE=/var/jb/usr/macOS/bin/macws_control_probe
WINDOWING_TWEAK=/var/jb/Library/MobileSubstrate/DynamicLibraries/MacWSWindowing.dylib
WINDOWING_VALIDATED_CACHE=/var/jb/var/mobile/macws-cross-build/MacWSWindowing.dylib
WINDOWING_VALIDATED_SHA=/var/jb/var/mobile/macws-cross-build/MacWSWindowing.sha256

# SpringBoard cannot publish the observer witness unless its arm64e tweak is
# physically present when the process starts.  The package database can still
# claim ownership after that file has disappeared: runtime on 2026-08-30 had a
# live SpringBoard pid=5322, no dense-grid witness, and dpkg listed the dylib
# while the packaged MobileSubstrate MacWSWindowing image did not exist. The
# macOS-linked artifact cache is produced by deploy_macwswindowing.sh only
# after its authenticated __cfstring fixups pass dyld_info validation.  Recover
# a missing installed copy from that exact content-addressed artifact before
# restarting SpringBoard; never substitute an on-device-linked image.
restore_windowing_bridge_binary() {
    local expected_hash="" cached_hash="" temporary=""
    [ -s "$WINDOWING_TWEAK" ] && return 0
    if [ ! -s "$WINDOWING_VALIDATED_CACHE" ] ||
       [ ! -s "$WINDOWING_VALIDATED_SHA" ]; then
        log "ERROR: MacWSWindowing is missing and no validated cross-build cache is available."
        return 1
    fi
    expected_hash=$(awk 'NR == 1 { print $1; exit }' \
        "$WINDOWING_VALIDATED_SHA" 2>/dev/null)
    cached_hash=$(sha256sum "$WINDOWING_VALIDATED_CACHE" 2>/dev/null |
        awk 'NR == 1 { print $1; exit }')
    if [ -z "$expected_hash" ] || [ "$cached_hash" != "$expected_hash" ]; then
        log "ERROR: MacWSWindowing validated cache failed its SHA-256 invariant."
        return 1
    fi
    temporary="${WINDOWING_TWEAK}.restore.$$"
    rm -f "$temporary"
    if ! cp "$WINDOWING_VALIDATED_CACHE" "$temporary" ||
       ! chown root:wheel "$temporary" ||
       ! chmod 0755 "$temporary" ||
       ! ldid -h "$temporary" >/dev/null 2>&1 ||
       ! mv -f "$temporary" "$WINDOWING_TWEAK"; then
        rm -f "$temporary"
        log "ERROR: failed to restore the validated MacWSWindowing image."
        return 1
    fi
    log "Restored missing MacWSWindowing from validated cache (sha256=$cached_hash)."
}

current_springboard_pid() {
    ps ax -o pid=,command= 2>/dev/null | awk \
        '$2 == "/System/Library/CoreServices/SpringBoard.app/SpringBoard" { print $1; exit }'
}

windowing_bridge_ready() {
    [ -x "$WINDOWING_STATUS_PROBE" ] &&
        "$WINDOWING_STATUS_PROBE" windowing-status >/dev/null 2>&1
}

# Read live protocol state, never infer service availability from a flag.
# An upgrade cannot replace a running SpringBoard image. Do not turn a missing
# file or incompatible service into a surprise respring/retry loop at launch.
# A fresh SpringBoard automatically publishes after installing its observers.
ensure_windowing_bridge() {
    local waited=0
    restore_windowing_bridge_binary || return 1
    while [ "$waited" -lt 12 ]; do
        if windowing_bridge_ready; then
            log "iPad windowing bridge ready for the current SpringBoard generation."
            return 0
        fi
        sleep 0.25
        waited=$((waited + 1))
    done
    log "ERROR: running SpringBoard has no compatible MacWSWindowing service. Complete the package upgrade and restart SpringBoard once; no restart was performed."
    return 1
}


application_trust_thermally_safe() {
    if ! thermal_snapshot; then
        log "ERROR: application trust scan could not read the mandatory thermal sensor."
        return 1
    fi
    case "$THERMAL_TEMP_CENTIC" in
        ''|*[!0-9]*)
            log "ERROR: application trust scan received an invalid temperature: $THERMAL_LINE"
            return 1
            ;;
    esac
    # Admission follows iPadOS's own aggregate pressure classification.  A
    # fixed battery-temperature cutoff rejected a measured `nominal` state at
    # 36.09 C during Repair Desktop, after the old session had already been
    # stopped, and left the user without a desktop.  Keep the numeric sensor
    # as an observation/validity witness; only a non-nominal state pauses the
    # expensive trust walk.
    if [ "$THERMAL_STATE" != nominal ]; then
        log "THERMAL-PAUSE: application trust checkpoint preserved; $THERMAL_LINE"
        return 1
    fi
    return 0
}

restore_cold_boot_trust() {
    local path=""
    local boot_trust_helper=/var/jb/usr/macOS/bin/macws_boot_trust.py
    local boot_trust_cache="$ROOTFS/var/db/macws/boot-trust"
    BASE_TRUST_READY=0
    [ -f "$boot_trust_helper" ] || {
        log "ERROR: packaged CodeDirectory trust reader is missing."
        return 1
    }
    application_trust_thermally_safe || return 1
    set --
    for path in \
        /var/jb/usr/macOS/bin/launchdchrootexec \
        /var/jb/usr/macOS/bin/launchservicesd \
        /var/jb/usr/macOS/bin/macwsaudiooutd \
        /var/jb/usr/macOS/lib/libmachook.dylib \
        /var/jb/usr/macOS/lib/libmachook_arm64.dylib \
        /var/jb/Applications/MacWSCatalystLauncher.app/MacWSCatalystLauncher \
        "$ROOTFS/usr/local/lib/libmachook.dylib" \
        "$ROOTFS/usr/local/lib/libmachook_arm64.dylib" \
        "$ROOTFS/usr/lib/dyld" \
        "$ROOTFS/usr/lib/libobjc-trampolines.dylib" \
        "$ROOTFS/System/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate" \
        /var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate \
        "$ROOTFS/bin/bash" \
        "$ROOTFS$DEFAULTS_BIN" \
        "$ROOTFS/usr/sbin/filecoordinationd" \
        "$ROOTFS/System/Library/CoreServices/launchservicesd" \
        "$ROOTFS/System/Library/CoreServices/launchservicesd.dylib" \
        "$ROOTFS$LSREGISTER_BIN" \
        "$ROOTFS/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/CursorAsset" \
        "$ROOTFS/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/CursorAsset_base" \
        "$ROOTFS$P_SHAREDFILELISTD" \
        "$ROOTFS/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer" \
        "$ROOTFS$VNC_BIN" \
        "$ROOTFS$TERM_BIN" \
        "$ROOTFS/System/Library/PrivateFrameworks/SystemStatusServer.framework/Support/systemstatusd" \
        "$ROOTFS/usr/local/libexec/macws-cfprefsd" \
        "$ROOTFS/usr/sbin/coreaudiod" \
        "$ROOTFS/System/Library/Frameworks/AudioToolbox.framework/AudioComponentRegistrar" \
        "$ROOTFS/System/Library/Components/CoreAudio.component/Contents/MacOS/CoreAudio" \
        "$ROOTFS/System/Library/Components/AudioDSP.component/Contents/MacOS/AudioDSP" \
        "$ROOTFS/usr/libexec/lsd" \
        "$ROOTFS$PLUGINKIT_PKD_BIN" \
        "$ROOTFS/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder" \
        "$ROOTFS/System/Applications/Preview.app/Contents/MacOS/Preview" \
        "$ROOTFS/System/Library/Frameworks/CoreImage.framework/Versions/A/Frameworks/libWrapGL.dylib" \
        "$ROOTFS/System/Library/PrivateFrameworks/TimelineUI.framework/Versions/A/TimelineUI" \
        "$ROOTFS/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock" \
        "$ROOTFS/System/Library/CoreServices/Dock.app/Contents/XPCServices/DockHelper.xpc/Contents/MacOS/DockHelper" \
        "$ROOTFS$CSNAMEDDATAD_BIN" \
        "$ROOTFS$CORESERVICESD_BIN" \
        "$ROOTFS$AUTHD_BIN" \
        "$ROOTFS$DESKTOP_SERVICES_HELPER_BIN" \
        "$ROOTFS/System/Library/PrivateFrameworks/ViewBridge.framework/Versions/A/XPCServices/ViewBridgeAuxiliary.xpc/Contents/MacOS/ViewBridgeAuxiliary" \
        "$ROOTFS/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/XPCServices/com.apple.hiservices-xpcservice.xpc/Contents/MacOS/com.apple.hiservices-xpcservice" \
        "$ROOTFS/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/com.apple.appkit.xpc.openAndSavePanelService.xpc/Contents/MacOS/com.apple.appkit.xpc.openAndSavePanelService" \
        "$ROOTFS/System/Library/Frameworks/ExtensionFoundation.framework/Versions/A/XPCServices/extensionkitservice.xpc/Contents/MacOS/extensionkitservice" \
        "$ROOTFS/System/Library/CoreServices/UIKitSystem.app/Contents/MacOS/UIKitSystem" \
        "$ROOTFS/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer" \
        "$ROOTFS/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter" \
        "$ROOTFS/System/Library/CoreServices/iconservicesd" \
        "$ROOTFS/System/Library/CoreServices/iconservicesagent" \
        "$ROOTFS$QUICKLOOK_THUMBNAILS_BIN" \
        "$ROOTFS$QUICKLOOKD_BIN" \
        "$ROOTFS$QUICKLOOK_SATELLITE_BIN" \
        "$ROOTFS$QUICKLOOK_UI_SERVICE_BIN" \
        "$ROOTFS/usr/libexec/pboard" \
        "$ROOTFS/System/Library/CoreServices/pbs" \
        "$ROOTFS$OFFICE_LICENSING_BIN" \
        "$ROOTFS/System/Applications/System Settings.app/Contents/MacOS/System Settings" \
        "$ROOTFS/System/Applications/Maps.app/Contents/MacOS/Maps" \
        "$ROOTFS/System/Applications/Weather.app/Contents/MacOS/Weather" \
        "$ROOTFS/tmp/GlassDemo" \
        "$ROOTFS/System/Library/CoreServices/CoreLocationAgent.app/Contents/MacOS/CoreLocationAgent" \
        "$ROOTFS/usr/libexec/locationd" \
        "$ROOTFS/System/Library/PrivateFrameworks/GeoServices.framework/Versions/A/XPCServices/com.apple.geod.xpc/Contents/MacOS/com.apple.geod" \
        "$ROOTFS/usr/local/bin/macwsinputd" \
        "$ROOTFS/usr/local/bin/macwsdisplayd" \
        "$ROOTFS/usr/local/bin/macwsinteropd" \
        "$ROOTFS/usr/local/bin/macwsworkspacectl"; do
        set -- "$@" "$path"
    done

    # Preview is linked against Hydra before libmachook/autosignd can run.
    # Runtime-confirmed on 2026-09-10 after a cold-boot trust restore: Preview
    # itself reached dyld, which rejected the on-disk arm64e Hydra slice as
    # unavailable; its current-boot CDHash was absent from `jbctl trustcache
    # info`.  postinst already preserves and registers this complete framework
    # tree, so the reboot repair must restore the same dependency closure.
    # Scan only Mach-O headers and re-register existing signatures; never
    # re-sign the framework or alter its nested-code relationship.
    set -- "$@" "$ROOTFS/System/Library/PrivateFrameworks/Hydra.framework"

    # Cursor Agent loads signed native Node add-ons with dlopen after its
    # already-trusted Node executable has started. Dopamine's dynamic
    # trustcache is reboot-volatile, so autosignd's exec hook cannot repair
    # those non-exec loads. Runtime-confirmed on the 2026-09-15 cold boot:
    # merkle-tree-napi.darwin-arm64.node failed with "code signature invalid"
    # until macws_boot_trust restored the 20 existing CodeDirectories under
    # this bounded installation root. Restore the signatures without
    # re-signing or modifying Cursor's nested-code resources.
    set -- "$@" "$ROOTFS/opt/local/libexec/macws-cursor"

    quicklook_display_root="$ROOTFS/System/Library/Frameworks/QuickLookUI.framework/Versions/A/PlugIns"
    for quicklook_display_bundle in "$quicklook_display_root"/*.qldisplay; do
        [ -d "$quicklook_display_bundle" ] || continue
        quicklook_display_name=${quicklook_display_bundle##*/}
        quicklook_display_name=${quicklook_display_name%.qldisplay}
        set -- "$@" "$quicklook_display_bundle/Contents/MacOS/$quicklook_display_name"
    done

    # Restore the COMPLETE old application closure, not just the default
    # Terminal. Delaying Office/Steam trust until the first click would merely
    # move the cold-start stall to app launch. The reader validates inode,
    # size, mtime and ctime on every run, also catching same-boot app updates.
    # Runtime 2026-09-12: old shell walk cost 452 s for 1067 images; even an
    # uncached bounded reader scans the full application roots in 72 s.
    for path in "$ROOTFS"/Applications/*.app \
        "$ROOTFS/Users/root/Library/Application Support/Steam/Steam.AppBundle/Steam" \
        "$ROOTFS/Users/root/Library/Application Support/Steam/steamapps/macws-runtime"/*/*.app; do
        [ ! -d "$path/Contents" ] || set -- "$@" "$path/Contents"
    done
    # Exact Ventura shared-cache CodeDirectories remain required. The native
    # backend uses the same verified libjailbreak API as jbctl, one process,
    # and checks actual live membership after registering missing hashes.
    /var/jb/usr/bin/python3 "$boot_trust_helper" \
        --manifest "$boot_trust_cache/hashes.json" \
        --resource-index "$boot_trust_cache/resources.sqlite" \
        --thermal-tool /var/jb/usr/macOS/bin/macwsthermal \
        --hash b5da39409492ac85e5a8e8ab618fe77e2d7a2980 \
        --hash bbb765988e2677b98d47a549d612fa0d4af25f69 \
        "$@" || return 1
    BASE_TRUST_READY=1
    log "Cold-boot trust closure ready (complete dependency closure; live membership verified)."
}

# True if a macOS binary can actually run in the chroot right now.
chroot_works() {
    case "$(bash "$RUN_BASH" -c 'echo __CHROOT_OK__' 2>/dev/null)" in
        *__CHROOT_OK__*) return 0 ;;
        *)               return 1 ;;
    esac
}

# launchdchrootexec's injected JIT authorization path is a live autosignd
# round-trip, not just an executable-trust probe.  Emergency cleanup
# deliberately kills autosignd so a wedged signing transaction cannot survive
# recovery; a later GUI start must therefore republish that bounded prerequisite
# before asking bash to prove the chroot.  Runtime-confirmed on 2026-08-21: with
# the base trust closure already restored, the old ordering produced
# `autosignd connected=0 connect_errno=61` followed by the EnableJIT assertion;
# ensure_chroot_works then misreported that as an incomplete base trustcache and
# launched the much more expensive postinst path.
ensure_autosignd_ready() {
    if [ ! -f "$RESTART_AUTOSIGND" ]; then
        log "ERROR: autosignd lifecycle helper is missing at $RESTART_AUTOSIGND"
        return 1
    fi
    if ! bash "$RESTART_AUTOSIGND" > "$LOGDIR/restart-autosignd.log" 2>&1; then
        log "ERROR: autosignd could not publish its chroot-visible socket."
        tail -n 10 "$LOGDIR/restart-autosignd.log" 2>/dev/null || true
        return 1
    fi
    log "autosignd is running with a verified chroot-visible socket."
}

# The executable signature persists across a reboot, but Dopamine's dynamic
# trustcache does not.  Checking only /bin/bash is insufficient for a GUI app:
# runtime-confirmed after the 2026-07-30 reboot, bash and VS Code's main
# executable ran while dyld rejected Electron Framework before libmachook or
# autosignd could execute.  Use that early dependency as a second sentinel.
vscode_bundle_trusted() {
    local hash=""

    # VS Code is optional.  Its absence must not block the generic GUI stack.
    [ -e "$VSCODE_TRUST_SENTINEL" ] || return 0
    hash=$(/var/jb/usr/bin/ldid -arch arm64 -h "$VSCODE_TRUST_SENTINEL" 2>/dev/null |
        /var/jb/usr/bin/grep 'CDHash=' | /var/jb/usr/bin/cut -c8-)
    [ -n "$hash" ] || return 1
    [ "$BASE_TRUST_READY" = 1 ] && return 0
    printf '%s\n' "$BOOT_TRUSTCACHE_INFO" |
        /var/jb/usr/bin/grep -Fqi "$hash"
}

# cfprefsd is now a direct outer-launchd target, so autosignd cannot repair it:
# AMFI evaluates the executable before libmachook can connect to autosignd.
# Runtime-confirmed on iPadOS 16.3: the stock Ventura signature is killed with
# "unsuitable CT policy 0x8 for this platform/device" and launchd records exit
# status 9.  Require both the persistent project entitlement marker and the
# current-boot arm64e trustcache entry before any CFPreferences client starts.
macos_cfprefsd_trusted() {
    local binary="$ROOTFS$CFPREFSD_BIN" hash=""
    [ -f "$binary" ] || return 1
    /var/jb/usr/bin/ldid -e "$binary" 2>/dev/null |
        /var/jb/usr/bin/grep -q \
            '<key>com.apple.private.graphics-restart-no-kill</key>' || return 1
    hash=$(/var/jb/usr/bin/ldid -arch arm64e -h "$binary" 2>/dev/null |
        /var/jb/usr/bin/grep 'CDHash=' | /var/jb/usr/bin/cut -c8-)
    [ -n "$hash" ] || return 1
    [ "$BASE_TRUST_READY" = 1 ] && return 0
    printf '%s\n' "$BOOT_TRUSTCACHE_INFO" |
        /var/jb/usr/bin/grep -Fqi "$hash"
}

# Repair the same-volume temporary directory contract that Ventura
# CoreFoundation's cfprefsd requires for atomic plist replacement.  The
# mounted macOS /private/var is a distinct filesystem root in this chroot, so
# iPadOS _dirhelper_relative resolves it beneath /private/var/.TemporaryItems.
# LLDB runtime-confirmed all three components and their required modes.  Keep
# this in the production start path as well as postinst so cold starts repair
# an incomplete/restored rootfs before the first preferences client connects.
ensure_cfprefsd_dirhelper_tree() {
    local temporary_root="$ROOTFS/private/var/.TemporaryItems"
    local temporary_user="$temporary_root/folders.0"
    local temporary_leaf="$temporary_user/TemporaryItems"
    local temporary_mobile="$temporary_root/folders.501"
    local temporary_mobile_leaf="$temporary_mobile/TemporaryItems"
    local root_home="$ROOTFS/private/var/root"
    local root_library="$root_home/Library"
    local root_preferences="$root_library/Preferences"
    local mobile_home="$ROOTFS/Users/mobile"
    local mobile_library="$mobile_home/Library"
    local mobile_preferences="$mobile_library/Preferences"
    local mobile_user_root="$ROOTFS/var/folders/zz/macws_uid501"
    local mobile_user_dir="$mobile_user_root/0"
    local mobile_cache_dir="$mobile_user_root/C"
    local mobile_temp_dir="$mobile_user_root/T"

    mkdir -p "$temporary_leaf" "$temporary_mobile_leaf" \
        "$root_preferences" \
        "$mobile_preferences" "$mobile_user_dir" "$mobile_cache_dir" \
        "$mobile_temp_dir" || return 1
    chown root:wheel "$temporary_root" "$temporary_user" "$temporary_leaf" \
        "$root_home" "$root_library" "$root_preferences" \
        2>/dev/null || true
    chown 501:501 "$temporary_mobile" "$temporary_mobile_leaf" \
        "$mobile_home" "$mobile_library" "$mobile_preferences" \
        "$mobile_user_root" "$mobile_user_dir" "$mobile_cache_dir" \
        "$mobile_temp_dir" \
        2>/dev/null || return 1
    chmod 1311 "$temporary_root" || return 1
    chmod 0700 "$temporary_user" "$temporary_leaf" || return 1
    chmod 0700 "$root_home" "$root_library" "$root_preferences" || return 1
    chmod 0700 "$temporary_mobile" "$temporary_mobile_leaf" \
        "$mobile_preferences" || return 1
    chmod 0755 "$mobile_home" "$mobile_library" || return 1
    chmod 0700 "$mobile_user_root" "$mobile_user_dir" \
        "$mobile_cache_dir" "$mobile_temp_dir" || return 1
}

ensure_launchservices_session_user_dir() {
    local directory="$ROOTFS$LSD_SESSION_USER_DIR"
    local system_data_vault="$ROOTFS$LSD_SYSTEM_DATA_VAULT_DIR"
    mkdir -p "$directory" || return 1
    chown root:wheel "$directory" 2>/dev/null || true
    chmod 0700 "$directory" || return 1

    # RE-confirmed against Ventura 13.4 LaunchServices on iPad14,5:
    # -[_LSDefaults dataVaultURLWithUID:] at unslid 0x180a25fc4 calls
    # __user_local_dirname(0), appends com.apple.LaunchServices.dv, then calls
    # rootless_mkdir_datavault.  The iOS 16.0 host creates an ordinary child
    # here but rejects the macOS DataVault-label operation with EPERM and the
    # libc routine removes that child again.  A filtered rootfs restore lacks
    # the persistent directory that a normal macOS boot already has; lsd then
    # returns nil from databaseStoreFileURLWithUID: and crashes while seeding.
    # Provision that real root-only store before either stock lsd starts.  On
    # an existing directory Apple's unchanged routine observes EEXIST and
    # returns its real csstore URL; no Objective-C result or assertion is
    # replaced. Runtime-confirmed on iOS 16.0 with the generated
    # com.apple.LaunchServices-4035-v2.csstore and a completed -kill -seed.
    mkdir -p "$system_data_vault" || return 1
    chown root:wheel "$system_data_vault" 2>/dev/null || true
    chmod 0700 "$system_data_vault" || return 1
}

# iconservicesd deliberately runs as Ventura's _iconservices account
# (uid/gid 240), while the root-session agent is a separate process. A cache
# directory inherited from an older root-run service remains mode 0700 and
# makes the real store daemon fail every rendition write with EACCES. Keep
# ownership aligned with the launch contract before either endpoint starts.
#
# The renderer marker is also a one-time cache-compatibility boundary. Runtime
# traces on 2026-09-10 showed that IconServices had cached fully transparent
# PDF/TXT renditions while Core Image's libWrapGL CodeDirectory was absent from
# the reboot-volatile trustcache. Once that real backend is trusted, preserve
# the old generated store under a precisely-scoped backup name and let the
# stock daemon regenerate it; user documents are never touched.
ensure_iconservices_store_tree() {
    local store="$ROOTFS/Library/Caches/com.apple.iconservices.store"
    local marker="$ROOTFS/Library/Caches/.macws-iconservices-renderer"
    local expected="wrapgl-trust-v1"
    local current="" backup=""

    current=$(sed -n '1p' "$marker" 2>/dev/null || true)
    if [ "$current" != "$expected" ] && [ -d "$store" ]; then
        backup="${store}.macws-pre-${expected}.$$"
        mv "$store" "$backup" || return 1
        log "Preserved incompatible generated IconServices cache at $backup."
    fi
    mkdir -p "$store" || return 1
    chown -R 240:240 "$store" 2>/dev/null || return 1
    chmod 0700 "$store" || return 1
    if [ "$current" != "$expected" ]; then
        printf '%s\n' "$expected" > "${marker}.new.$$" || return 1
        chmod 0644 "${marker}.new.$$" || return 1
        mv -f "${marker}.new.$$" "$marker" || return 1
    fi
}

# Ventura's _locationd account is uid/gid 205 and Darwin dirhelper resolves
# its per-user cache root to this deterministic hash.  Runtime on the target
# reached `CLLocationController` only after the complete 0/C/T hierarchy
# existed; without it locationd exits with "could not create persistent store
# directory" and errno EIO.  Repair only this exact service-owned tree.
ensure_locationd_dirhelper_tree() {
    local location_root="$ROOTFS/var/folders/zz/zyxvpxvq6csfxvn_n00000sm00006d"
    mkdir -p "$location_root/0" "$location_root/C" "$location_root/T" ||
        return 1
    chown -R 205:205 "$location_root" 2>/dev/null || true
    chmod 0700 "$location_root" "$location_root/0" \
        "$location_root/C" "$location_root/T" || return 1
}

# Self-heal both post-reboot failure classes before starting WindowServer.
# One postinst pass restores the base chroot plus every persistent executable
# signature in VS Code's nested frameworks; both witnesses must pass afterward.
ensure_chroot_works() {
    local chroot_ok=0 vscode_ok=0 cfprefs_ok=0

    log "Checking the macOS chroot is runnable..."
    restore_cold_boot_trust || {
        log "ERROR: reboot-volatile macOS trust closure could not be restored."
        return 1
    }
    ensure_autosignd_ready || return 1
    # devfs mounts are reboot-volatile, unlike the rootfs contents and package
    # signatures.  A successful trust probe alone therefore cannot establish
    # that GUI clients can create pseudo-terminals. Runtime evidence from the
    # current cold start was exact: /var/mnt/rootfs/dev/ptmx was absent and
    # Terminal reported `[forkpty: No such file or directory]`; invoking the
    # iOS-native helper created the real devfs node immediately. Make that
    # mount and its concrete ptmx witness part of every production preflight.
    if [ ! -x "$MOUNTDEVFS" ] ||
       ! "$MOUNTDEVFS" "$ROOTFS/dev" \
            > "$LOGDIR/mountdevfs.log" 2>&1 ||
       [ ! -c "$ROOTFS/dev/ptmx" ]; then
        log "ERROR: chroot devfs is unavailable; Terminal cannot create a pty."
        tail -n 10 "$LOGDIR/mountdevfs.log" 2>/dev/null || true
        return 1
    fi
    # A restored/rootfs snapshot can regress only the data-only shader artifact
    # while every executable trust sentinel remains valid. Hash-check the
    # focused provisioner on every cold start; its matching path is one 1-MiB
    # read and performs no compiler or signing work.
    if [ ! -f "$METAL2METAL_COMPAT_PROVISIONER" ] ||
       ! bash "$METAL2METAL_COMPAT_PROVISIONER" \
            > "$LOGDIR/quartzcore-compat.log" 2>&1; then
        log "ERROR: exact QuartzCore native-AGX compatibility library is unavailable."
        tail -n 20 "$LOGDIR/quartzcore-compat.log" 2>/dev/null || true
        return 1
    fi
    chroot_works && chroot_ok=1
    vscode_bundle_trusted && vscode_ok=1
    macos_cfprefsd_trusted && cfprefs_ok=1
    if [ "$chroot_ok" -eq 1 ] && [ "$vscode_ok" -eq 1 ] &&
       [ "$cfprefs_ok" -eq 1 ]; then
        log "chroot, VS Code, and macOS cfprefsd trust sentinels OK."
        return 0
    fi
    [ "$chroot_ok" -eq 1 ] ||
        log "chroot not runnable (base trustcache is incomplete)."
    [ "$vscode_ok" -eq 1 ] ||
        log "VS Code Electron Framework is not trusted (application trustcache is incomplete)."
    [ "$cfprefs_ok" -eq 1 ] ||
        log "macOS cfprefsd lacks the project signature or current-boot trustcache entry."
    if [ -f "$POSTINST" ]; then
        log "Re-registering trustcaches via postinst.sh (~1 min)..."
        bash "$POSTINST" > "$LOGDIR/postinst.log" 2>&1
        if chroot_works && vscode_bundle_trusted && macos_cfprefsd_trusted; then
            log "chroot, VS Code, and macOS cfprefsd trust sentinels OK after postinst."
            return 0
        fi
    fi
    log "ERROR: chroot or VS Code trust sentinel still fails after postinst — aborting."
    log "       Inspect: $LOGDIR/postinst.log  and  sudo dmesg | grep AMFI"
    return 1
}

# Materialize only the project-owned benchmark profile. The user's normal VS
# Code profile is never read, removed or rewritten. These small authoritative
# files are copied on each GUI start so package upgrades cannot leave an old
# plist, workload URL or extension behind; Chromium caches and session storage
# remain intact for normal warm starts.
prepare_vscode_production_assets() {
    local extension_source="$VSCODE_ASSET_DIR/macwsguide.macws-aquarium-runner-0.0.2"
    local extension_target="$VSCODE_EXTENSIONS_DIR/macwsguide.macws-aquarium-runner-0.0.2"
    local installed_schema="" marker_tmp=""

    [ -d "$ROOTFS/Applications/Visual Studio Code.app" ] || return 0
    if [ ! -f "$VSCODE_PLIST" ] ||
       [ ! -f "$VSCODE_ASSET_DIR/settings.json" ] ||
       [ ! -f "$VSCODE_ASSET_DIR/extensions.json" ] ||
       [ ! -d "$extension_source" ]; then
        log "ERROR: packaged VS Code production assets are incomplete."
        return 1
    fi

    if ! mkdir -p "$VSCODE_PROFILE_DIR/User" "$extension_target" ||
       ! cp "$VSCODE_ASSET_DIR/settings.json" "$VSCODE_PROFILE_DIR/User/settings.json" ||
       ! cp "$VSCODE_ASSET_DIR/extensions.json" "$VSCODE_EXTENSIONS_DIR/extensions.json" ||
       ! cp "$extension_source/package.json" "$extension_target/package.json" ||
       ! cp "$extension_source/extension.js" "$extension_target/extension.js" ||
       ! cp "$extension_source/README.md" "$extension_target/README.md"; then
        log "ERROR: failed to materialize the VS Code production profile."
        return 1
    fi

    # Runtime-confirmed on 2026-08-01: the legacy libraries.data contained
    # air64-apple-ios16.3.0 while a freshly generated cache contained only
    # air64-apple-ios19.0.0-macabi and made every previously failing ANGLE
    # source request return a real _MTLLibrary. cleanup_macos has already
    # stopped every VS Code helper, so invalidating these two exact,
    # regenerable files cannot race an active Metal cache writer.
    [ ! -f "$VSCODE_METAL_CACHE_MARKER" ] ||
        installed_schema=$(sed -n '1p' "$VSCODE_METAL_CACHE_MARKER" 2>/dev/null)
    if [ "$installed_schema" != "$VSCODE_METAL_CACHE_SCHEMA" ]; then
        if ! mkdir -p "$VSCODE_METAL_CACHE_ROOT" ||
           ! rm -f "$VSCODE_METAL_LIBRARY_CACHE/libraries.list" \
                   "$VSCODE_METAL_LIBRARY_CACHE/libraries.data"; then
            log "ERROR: failed to invalidate the incompatible VS Code Metal library cache."
            return 1
        fi
        marker_tmp="$VSCODE_METAL_CACHE_MARKER.$$"
        if ! printf '%s\n' "$VSCODE_METAL_CACHE_SCHEMA" > "$marker_tmp" ||
           ! mv -f "$marker_tmp" "$VSCODE_METAL_CACHE_MARKER"; then
            rm -f "$marker_tmp"
            log "ERROR: failed to commit the VS Code Metal cache schema marker."
            return 1
        fi
        log "VS Code Metal source cache migrated to $VSCODE_METAL_CACHE_SCHEMA."
    fi
    log "VS Code production assets ready (isolated profile=$VSCODE_PROFILE_NAME)."
}

prepare_metal_library_target_cache() {
    # This is derived-data versioning, not a feature/debug gate. Compiler
    # compatibility is always enabled. The helper checks actual chroot roots,
    # so omitted live clients defer safely instead of losing an mmap-backed
    # cache. A normal cold startup migrates once before any GUI client starts.
    /var/jb/usr/bin/python3 "${BASH_SOURCE[0]%/*}/macws_metal_cache_migration.py" \
        --rootfs "$ROOTFS" --defer-if-running
}

prepare_production_boot_jobs() {
    # The boot-scanned jailbreak directory is a separate launch authority.
    # Historical diagnostics/optional-app jobs there are not covered by the
    # generated GUI-job preflight. Archive only recognized original jobs;
    # never unload a live application while auditing an upgrade.
    /var/jb/usr/bin/python3 "${BASH_SOURCE[0]%/*}/macws_retire_legacy_boot_jobs.py"
}

write_plists() {
    local vnc_listen_scope=""
    if [ "$WANT_VNC" != 1 ]; then
        vnc_listen_scope="        <string>-localhost</string>"
    fi
    mkdir -p "$GUI_LAUNCHD_DIR"
    source "${BASH_SOURCE[0]%/*}/macws_diagnostic_flags.sh" || return 1

    # VNC is an explicit session transport choice, not a feature sentinel.
    # Rewrite the job's own environment before launchctl loads it so both
    # cold start and launchd recovery retain the requested no-VNC policy.
    /var/jb/usr/bin/python3 - "$WINDOWSERVER_PLIST" "$WANT_VNC" <<'PY' || return 1
import os
import plistlib
import sys
path, vnc = sys.argv[1:]
with open(path, 'rb') as stream:
    job = plistlib.load(stream)
job.setdefault('EnvironmentVariables', {})['MACWS_VNC_SHARE'] = vnc
temporary = path + '.new-' + str(os.getpid())
with open(temporary, 'wb') as stream:
    plistlib.dump(job, stream, sort_keys=False)
os.chmod(temporary, os.stat(path).st_mode)
os.replace(temporary, path)
PY

    # Remove the pre-xpcproxy scaffold on upgrade.  A normal launchd Mach job
    # cannot provide an Application-type XPC service's AppKit main-thread
    # lifecycle; keeping it registered races the real bundle activation and
    # leaves Dock's MenuGroup waiting forever for a reply.
    launchctl unload "$GUI_LAUNCHD_DIR/com.macwsguide.dockhelper.plist" 2>/dev/null
    launchctl remove com.macwsguide.dockhelper 2>/dev/null
    rm -f "$GUI_LAUNCHD_DIR/com.macwsguide.dockhelper.plist"
    # Upgrade cleanup for the temporary service contracts used while the
    # DesktopServices authorization failure was being traced.  They use the
    # same private protocol names as the production jobs below and therefore
    # must not remain registered in parallel.
    launchctl unload "$GUI_LAUNCHD_DIR/com.macwsguide.authd-test.plist" 2>/dev/null
    launchctl unload "$GUI_LAUNCHD_DIR/com.macwsguide.desktopserviceshelper-test.plist" 2>/dev/null
    launchctl remove com.macwsguide.desktopserviceshelper-test 2>/dev/null
    rm -f "$GUI_LAUNCHD_DIR/com.macwsguide.authd-test.plist" \
          "$GUI_LAUNCHD_DIR/com.macwsguide.desktopserviceshelper-test.plist"

    # Ventura normally installs this as both a system daemon and login agent.
    # MacWS has one outer launchd domain, so publish one stock protocol owner
    # and execute the real macOS binary in the chroot.  start_sharedfilelistd
    # requires a PID before it performs the typed snapshot round-trip, hence
    # RunAtLoad is intentional here even though the stock plist is on-demand.
    # Runtime-confirmed via MacWSStartup.log on 2026-08-23: the startup path
    # previously referenced this generated location without ever creating it,
    # and both launch attempts failed with ENOENT after an otherwise complete
    # application-trust walk.
    cat > "$SHAREDFILELISTD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${SHAREDFILELISTD_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${P_SHAREDFILELISTD}</string>
    </array>
    <key>MachServices</key>
    <dict><key>com.apple.coreservices.sharedfilelistd.xpc</key><true/></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>ThrottleInterval</key><integer>5</integer>
    <!-- RE-confirmed in Ventura 13.4 CoreServicesInternal and
         runtime-confirmed on iPad13,6: uid 0's /var/root home candidate is
         rejected against Finder's canonical /private/var/root bookmark,
         leaving the stale bit set even after the canonical fallback resolves.
         CoreFoundation's supported fixed-home input makes the first candidate
         canonical and stops sharedfilelistd's resolve/update notification
         loop without bypassing bookmark validation. -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>CFFIXED_USER_HOME</key><string>/private/var/root</string>
    </dict>
    <key>StandardOutPath</key><string>${LOGDIR}/sharedfilelistd.out</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/sharedfilelistd.err</string>
</dict>
</plist>
PLIST

    cat > "$VNC_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${VNC_LABEL}</string>
    <key>POSIXSpawnType</key>
    <string>Interactive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string>
        <string>0</string>
        <string>0</string>
        <string>${ROOTFS}</string>
        <string>${VNC_BIN}</string>
        <string>-rfbnoauth</string>
${vnc_listen_scope}
        <!--
          OSXvnc maps RFB button 4 to the third CGPostMouseEvent slot unless
          this option is enabled. Runtime tracing in Dock then receives
          CGEvent type 0x19 (OtherMouseDown), while the swapped mapping
          delivers the correct type 3 (RightMouseDown). Keep RFB's
          conventional bit-4 right button and translate it with the server's
          documented compatibility switch. Dock still applies its own later
          tracking-state gate; correct event type alone does not bypass it.
        -->
        <string>-swapButtons</string>
        <!--
          The installed OSXvnc-server defaults rfbDeferUpdateTime to 40 ms.
          RE-confirmed at arm64 clientOutput+0xec: it unlocks the client mutex,
          sleeps defer*1000, then relocks before intersecting damage and
          calling rfbSendFramebufferUpdate. The shared-frame producer and
          generation watcher already coalesce at a bounded frame cadence, so
          this second fixed delay only lengthens menu/drag feedback and holds
          the single clientOutput stream behind later damage.
        -->
        <string>-deferupdate</string>
        <string>0</string>
        <string>-desktop</string>
        <string>${VNC_DESKTOP}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <!--
          System-wide pointer ownership belongs to OSXvnc's native
          CGPostMouseEvent path. Runtime tests cover AppKit's global menu,
          contextual menu, NSWindow modal drag tracker, and application
          content through this one coherent stream. libmachook only fixes the
          Retina RFB-pixel -> Quartz-point scale before calling the original.
          AppInputBridge remains a fallback for non-VNC/native-host input; it
          must not duplicate an active VNC gesture in one target process.
        -->
        <key>MACWS_VNC_NATIVE_ALL</key>
        <string>1</string>
        <!--
          The Retina desktop is 15.2 MiB uncompressed. Runtime timing at the
          actual rfbSendFramebufferUpdate boundary showed a moved-window Zlib
          frame spending 1584 ms in encoding/socket output while mmap copy
          used 1.87 ms. Controlled Tight full-frame requests on this device
          made compression level 1 the lowest-latency measured setting
          (343 ms versus 544 ms at level 6 and 1184 ms at level 9). libmachook
          preserves the client-selected encoding but clamps its compression
          work factor to level 1 before the stream is initialized.
        -->
        <key>MACWS_VNC_LOW_LATENCY_COMPRESSION</key>
        <string>1</string>
    </dict>
    <key>StandardOutPath</key>
    <string>${LOGDIR}/osxvnc.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGDIR}/osxvnc.log</string>
</dict>
</plist>
PLIST

    # The chroot has no ordinary macOS loginwindow/LaunchAgent bootstrap, so
    # com.apple.pboard is otherwise absent. Runtime evidence was explicit:
    # OSXvnc logged "Pasteboard Inaccessible" and Electron aborted a drag with
    # "0 items on the pasteboard, but 1 drag images". Register the real macOS
    # pboard binary through the same chroot launcher and expose its original
    # Mach service names in the outer launchd domain.
    cat > "$PBOARD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PBOARD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string>
        <string>0</string>
        <string>0</string>
        <string>${ROOTFS}</string>
        <string>${PBOARD_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>com.apple.pasteboard.1</key>
        <true/>
        <key>com.apple.coreservices.uauseractivitypasteboardclient.xpc</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>${LOGDIR}/pboard.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGDIR}/pboard.log</string>
</dict>
</plist>
PLIST

    # AppKit does not build the Services submenu in-process. Runtime evidence
    # on 2026-07-29 showed Terminal requesting
    # com.apple.pbs.fetch_services twice while launchctl had no provider; the
    # visible submenu remained at "Building...". The actual macOS 13.4
    # com.apple.pbs LaunchAgent maps that Mach service to
    # /System/Library/CoreServices/pbs. Recreate that service in the outer
    # launchd domain and execute the real binary in the chroot.
    cat > "$PBS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PBS_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string>
        <string>0</string>
        <string>0</string>
        <string>${ROOTFS}</string>
        <string>${PBS_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>com.apple.pbs.fetch_services</key>
        <true/>
    </dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>NSRunningFromLaunchd</key>
        <string>1</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOGDIR}/pbs.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGDIR}/pbs.log</string>
</dict>
</plist>
PLIST

    # A normal macOS login bootstrap publishes both CFPreferences services
    # before Dock/Finder start.  Runtime-confirmed on the target: without the
    # macOS agent, Dock creates a LaunchPadDBName and immediately reports that
    # its ByHost domain is non-persistent, so no Launchpad database is created.
    # iPadOS publishes identically named but platform-incompatible endpoints;
    # libmachook maps these private listeners and every chroot client together.
    cat > "$CFPREFSD_DAEMON_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${CFPREFSD_DAEMON_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${CFPREFSD_BIN}</string>
        <string>daemon</string>
    </array>
    <key>MachServices</key>
    <dict><key>com.apple.macosbooter.cfprefsd.daemon</key><true/></dict>
    <key>EnableTransactions</key><true/>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>StandardOutPath</key><string>${LOGDIR}/cfprefsd-daemon.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/cfprefsd-daemon.log</string>
</dict>
</plist>
PLIST

    cat > "$CFPREFSD_AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${CFPREFSD_AGENT_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${CFPREFSD_BIN}</string>
        <string>agent</string>
    </array>
    <key>MachServices</key>
    <dict><key>com.apple.macosbooter.cfprefsd.agent</key><true/></dict>
    <key>EnableTransactions</key><true/>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>StandardOutPath</key><string>${LOGDIR}/cfprefsd-agent.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/cfprefsd-agent.log</string>
</dict>
</plist>
PLIST

    # Steam's production game process runs as uid 501, matching the iPadOS
    # mobile account.  The restored Ventura image has no uid-501 login domain,
    # so publish the same unmodified cfprefsd agent protocol on a distinct
    # bootstrap name and give only this job the narrowly scoped synthetic
    # login identity supplied by libmachook.  Root desktop clients continue to
    # use the established agent above.
    cat > "$CFPREFSD_MOBILE_AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${CFPREFSD_MOBILE_AGENT_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>501</string><string>501</string>
        <string>${ROOTFS}</string><string>${CFPREFSD_BIN}</string>
        <string>agent</string>
    </array>
    <key>MachServices</key>
    <dict><key>com.apple.macosbooter.cfprefsd.agent.501</key><true/></dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>MACWS_SYNTHETIC_MOBILE_USER</key><string>1</string>
        <key>HOME</key><string>/Users/mobile</string>
        <key>USER</key><string>mobile</string>
        <key>LOGNAME</key><string>mobile</string>
    </dict>
    <key>EnableTransactions</key><true/>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>StandardOutPath</key><string>${LOGDIR}/cfprefsd-mobile-agent.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/cfprefsd-mobile-agent.log</string>
</dict>
</plist>
PLIST

    # Ventura applications use /usr/libexec/lsd, not the legacy
    # launchservicesd endpoint alone.  iPadOS publishes the same com.apple.lsd
    # names in user/501; without isolation the chroot's lsregister runtime-
    # confirmed that it opened iOS's container database (Bundle table = 0).
    # macOS runs two copies of lsd in different launchd domains.  The system
    # daemon opens the durable csstore (`runAsRoot` is its stock role switch),
    # while the Background-session agent exposes the application catalog to
    # AppKit clients and obtains generations from the daemon's dissemination
    # endpoint.  A single iPadOS bootstrap domain cannot publish the same
    # service names twice, so libmachook maps the unmodified protocols onto a
    # private system family and private session family.
    cat > "$LSD_SYSTEM_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LSD_SYSTEM_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>/usr/libexec/lsd</string>
        <string>runAsRoot</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>MACWS_LSD_ROLE</key><string>system</string></dict>
    <key>MachServices</key>
    <dict>
        <key>com.apple.macosbooter.lsd.system.advertisingidentifiers</key><true/>
        <key>com.apple.macosbooter.lsd.system.diagnostics</key><true/>
        <key>com.apple.macosbooter.lsd.system.dissemination</key><true/>
        <key>com.apple.macosbooter.lsd.system.encryption</key><true/>
        <key>com.apple.macosbooter.lsd.system.extensions</key><true/>
        <key>com.apple.macosbooter.lsd.system.mapdb</key><true/>
        <key>com.apple.macosbooter.lsd.system.modifydb</key><true/>
        <key>com.apple.macosbooter.lsd.system.open</key><true/>
        <key>com.apple.macosbooter.lsd.system.openurl</key><true/>
        <key>com.apple.macosbooter.lsd.system.personaobserver</key><true/>
        <key>com.apple.macosbooter.lsd.system.plugin</key><true/>
        <key>com.apple.macosbooter.lsd.system.trustedsignatures</key><true/>
        <key>com.apple.macosbooter.lsd.system.security.translocation</key><true/>
    </dict>
    <key>EnableTransactions</key><true/>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>StandardOutPath</key><string>${LOGDIR}/lsd-system.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/lsd-system.log</string>
</dict>
</plist>
PLIST

    cat > "$LSD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LSD_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>/usr/libexec/lsd</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>MACWS_LSD_ROLE</key><string>session</string>
        <key>MACWS_LSD_SESSION_USER_DIR</key><string>${LSD_SESSION_USER_DIR}</string>
    </dict>
    <key>MachServices</key>
    <dict>
        <key>com.apple.macosbooter.lsd.advertisingidentifiers</key><true/>
        <key>com.apple.macosbooter.lsd.diagnostics</key><true/>
        <key>com.apple.macosbooter.lsd.extensions</key><true/>
        <key>com.apple.macosbooter.lsd.mapdb</key><true/>
        <key>com.apple.macosbooter.lsd.modifydb</key><true/>
        <key>com.apple.macosbooter.lsd.open</key><true/>
        <key>com.apple.macosbooter.lsd.openurl</key><true/>
        <key>com.apple.macosbooter.lsd.personaobserver</key><true/>
        <key>com.apple.macosbooter.lsd.plugin</key><true/>
        <key>com.apple.macosbooter.lsd.trustedsignatures</key><true/>
        <key>com.apple.macosbooter.security.translocation</key><true/>
    </dict>
    <key>EnableTransactions</key><true/>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>StandardOutPath</key><string>${LOGDIR}/lsd-session.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/lsd-session.log</string>
</dict>
</plist>
PLIST

    # IconServices is normally split between a system store daemon and a
    # per-login agent.  The chroot has neither launchd domain, while iPadOS
    # publishes incompatible services under the same bootstrap names.  Run
    # the two stock Ventura executables with their stock UID split and publish
    # collision-free names; libmachook maps both listeners and clients.
    cat > "$ICONSERVICESD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${ICONSERVICESD_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>240</string><string>240</string>
        <string>${ROOTFS}</string><string>${ICONSERVICESD_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict><key>com.apple.macosbooter.iconservices.store</key><true/></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>${LOGDIR}/iconservicesd.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/iconservicesd.log</string>
</dict>
</plist>
PLIST

    cat > "$ICONSERVICESAGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${ICONSERVICESAGENT_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${ICONSERVICESAGENT_BIN}</string>
        <string>runAsRoot</string>
    </array>
    <key>MachServices</key>
    <dict><key>com.apple.macosbooter.iconservices</key><true/></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>${LOGDIR}/iconservicesagent.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/iconservicesagent.log</string>
</dict>
</plist>
PLIST

    # PluginKit discovery must use the same Ventura LaunchServices catalog as
    # Finder and Quick Look. Runtime oslog on 2026-09-07 showed the unisolated
    # client reaching iPadOS pkd (pid 1836), which rejected the macOS
    # com.apple.quicklook.preview and .thumbnail extension points with -10814.
    # Host Ventura's stock pkd under a collision-free endpoint; libmachook
    # rewrites both its check-in and every chroot client's lookup.
    cat > "$PLUGINKIT_PKD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${PLUGINKIT_PKD_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${PLUGINKIT_PKD_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict><key>com.apple.macosbooter.pluginkit.pkd</key><true/></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>EnableTransactions</key><true/>
    <key>EnablePressuredExit</key><true/>
    <key>StandardOutPath</key><string>${LOGDIR}/pluginkit-pkd.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/pluginkit-pkd.log</string>
</dict>
</plist>
PLIST

    # Finder's QLThumbnailGenerator client and iPadOS both use the public
    # com.apple.quicklook.ThumbnailsAgent name. Runtime-confirmed on the target
    # on 2026-09-06: the process holding that public job was uid 501 and had
    # UUID BA2DE509-8911-30D7-9933-702807526BE2 (the iPadOS executable), while
    # the installed Ventura executable has UUID
    # 6FF47A91-A359-38A8-8E56-CCEA34DC129F. Publish the unmodified Ventura
    # service under private names; libmachook rewrites both client lookup and
    # the agent's NSXPCListener check-in at the transport boundary.
    cat > "$QUICKLOOK_THUMBNAILS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${QUICKLOOK_THUMBNAILS_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${QUICKLOOK_THUMBNAILS_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>com.apple.macosbooter.quicklook.ThumbnailsAgent</key><true/>
        <key>com.apple.macosbooter.quicklook.ThumbnailsAgent.CacheDelete</key><true/>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>EnableTransactions</key><true/>
    <key>EnablePressuredExit</key><true/>
    <key>StandardOutPath</key><string>${LOGDIR}/quicklook-thumbnails.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/quicklook-thumbnails.log</string>
</dict>
</plist>
PLIST

    # Finder's preview panel and qlmanage use the separate Ventura quicklookd
    # endpoint. The stock LaunchAgent publishes both names; host the same
    # executable and NSXPC listeners under collision-free names so thumbnail
    # generation and preview requests stay on one Ventura protocol family.
    cat > "$QUICKLOOKD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${QUICKLOOKD_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${QUICKLOOKD_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>com.apple.macosbooter.quicklook</key><true/>
        <key>com.apple.macosbooter.quicklookd.xpc</key><true/>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>EnableTransactions</key><true/>
    <key>EnablePressuredExit</key><true/>
    <key>StandardOutPath</key><string>${LOGDIR}/quicklookd.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/quicklookd.log</string>
</dict>
</plist>
PLIST

    # Ventura's legacy thumbnail path runs generators in the bundled
    # QuickLookSatellite XPC service. RE-confirmed in QuickLook 13.4 at
    # -[QLServerSatellite _connect]+0x68: the thumbnail agent connects to
    # com.apple.quicklook.satellite, then sends its unmodified setup/request
    # dictionaries. Runtime LLDB on the target observed that send but no
    # satellite process or completion/failure callback because the chroot has
    # no XPC bundle activation domain. Publish the stock executable and wire
    # protocol under a collision-free Mach name; libmachook adapts only the
    # listener/lookup transport boundary.
    cat > "$QUICKLOOK_SATELLITE_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${QUICKLOOK_SATELLITE_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string>
        <string>0</string>
        <string>0</string>
        <string>${ROOTFS}</string>
        <string>${QUICKLOOK_SATELLITE_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict><key>com.apple.macosbooter.quicklook.satellite</key><true/></dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>/Users/root</string>
        <key>TMPDIR</key><string>/tmp</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>EnableTransactions</key><true/>
    <key>ThrottleInterval</key><integer>3</integer>
    <key>StandardOutPath</key><string>${LOGDIR}/quicklook-satellite.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/quicklook-satellite.log</string>
</dict>
</plist>
PLIST

    # CarbonCore normally asks launchd's XPC bundle resolver to instantiate
    # csnameddatad for a login session. The chroot has no XPC bundle domain.
    # Runtime-confirmed on 2026-08-06: a Dock secondary click reached the real
    # DOCKFileTile showMenu:options: path, then logged lookup error 3 for this
    # exact endpoint and produced no menu window. Publish the stock Ventura
    # XPC executable under a collision-free service name; libmachook maps both
    # the listener and every chroot client without replacing its protocol.
    cat > "$CSNAMEDDATAD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${CSNAMEDDATAD_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array><string>${CSNAMEDDATA_PROXY}</string></array>
    <key>MachServices</key>
    <dict><key>com.apple.macosbooter.carboncore.csnameddata</key><true/></dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>XPC_SERVICE_NAME</key><string>${CSNAMEDDATAD_LABEL}</string>
        <key>MACWS_XPC_TARGET</key><string>${CSNAMEDDATAD_BIN}</string>
        <key>CA_VSYNC_OFF</key><string>1</string>
        <key>MACWS_AGX_NATIVE</key><string>1</string>
        <key>MACWS_AGX_REGISTER_CLASSES</key><string>1</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>${LOGDIR}/csnameddatad.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/csnameddatad.log</string>
</dict>
</plist>
PLIST

    # CoreDrag's stock CarbonCore client asks the stock coreservicesd for the
    # CSSeed v0x10001 table before it creates any drag session.  This is a
    # separate Mach service from csnameddatad: runtime Finder logs showed
    # CoreDragCreate returning -900 while csnameddatad was healthy, and the
    # Ventura launch contract below identifies the missing owner precisely.
    # Publish the unmodified Ventura daemon on a private endpoint; libmachook
    # maps the daemon's check-in and clients symmetrically.
    cat > "$CORESERVICESD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${CORESERVICESD_LABEL}</string>
    <key>POSIXSpawnType</key><string>Interactive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string>
        <string>0</string>
        <string>0</string>
        <string>${ROOTFS}</string>
        <string>${CORESERVICESD_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>com.apple.macosbooter.CoreServices.coreservicesd</key>
        <dict><key>ResetAtClose</key><true/></dict>
    </dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>/Users/root</string>
        <key>TMPDIR</key><string>/tmp</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>EnableTransactions</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>${LOGDIR}/coreservicesd.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/coreservicesd.log</string>
</dict>
</plist>
PLIST

    # Finder's DesktopServices client performs real Authorization.framework
    # and helper handshakes before it accepts a file operation.  The chroot has
    # no macOS launchd XPC bundle domain, while iPadOS owns the public authd
    # name with a different protocol.  Publish the unmodified Ventura authd on
    # the private name selected by libmachook.  HIServicesProxy is only the
    # already-packaged setuid first image which enters the chroot; authd itself
    # remains the protocol owner.
    cat > "$AUTHD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${AUTHD_LABEL}</string>
    <key>POSIXSpawnType</key><string>Interactive</string>
    <key>ProgramArguments</key>
    <array><string>${CSNAMEDDATA_PROXY}</string></array>
    <key>MachServices</key>
    <dict><key>com.apple.macosbooter.authd</key><true/></dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>XPC_SERVICE_NAME</key><string>${AUTHD_LABEL}</string>
        <key>MACWS_XPC_TARGET</key><string>${AUTHD_BIN}</string>
        <key>HOME</key><string>/Users/root</string>
        <key>TMPDIR</key><string>/tmp</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>EnableTransactions</key><true/>
    <key>ThrottleInterval</key><integer>3</integer>
    <key>StandardOutPath</key><string>${LOGDIR}/authd.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/authd.log</string>
</dict>
</plist>
PLIST

    # DesktopServicesHelper is a stock Ventura per-session Mach service.  Its
    # own handshake validates the requesting process' audit token and TCC
    # entitlement; no reply or authorization decision is synthesized here.
    # MultipleInstances preserves the launchd request context used by the
    # original service contract.
    cat > "$DESKTOP_SERVICES_HELPER_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${DESKTOP_SERVICES_HELPER_LABEL}</string>
    <key>POSIXSpawnType</key><string>Adaptive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${DESKTOP_SERVICES_HELPER_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict><key>com.apple.macosbooter.DesktopServicesHelper</key><true/></dict>
    <key>MultipleInstances</key><true/>
    <key>EnableTransactions</key><true/>
    <key>KeepAlive</key><false/>
    <key>ThrottleInterval</key><integer>3</integer>
    <key>StandardOutPath</key><string>${LOGDIR}/desktopserviceshelper.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/desktopserviceshelper.log</string>
</dict>
</plist>
PLIST

    # A macOS Aqua login session normally launches Finder, Dock,
    # SystemUIServer and ControlCenter as per-user LaunchAgents.  The chroot
    # deliberately has no loginwindow domain, so map the stock Ventura agents'
    # executable and Mach-service contracts into the outer launchd domain.
    # These are the real desktop owners: Finder publishes desktop items, Dock
    # owns desktop pictures/Spaces/Launchpad, and the latter two publish the
    # right side of the global menu bar.  Host captures their SkyLight windows;
    # it does not draw substitutes.
    cat > "$FINDER_DESKTOP_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${FINDER_DESKTOP_LABEL}</string>
    <key>POSIXSpawnType</key><string>Interactive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${FINDER_BIN}</string>
        <string>-ApplePersistenceIgnoreState</string><string>YES</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>CA_VSYNC_OFF</key><string>1</string>
        <!-- Runtime A/B on 2026-09-07: Finder's document-open path without
             this logical-root contract recursively entered
             CoreServicesInternal FileCache/CFURL and SIGBUSed. With it, the
             same selection reached the real LS/RBS launch boundary. -->
        <key>MACWS_APP_MOUNT_COMPAT</key><string>1</string>
    </dict>
    <key>StandardOutPath</key><string>${LOGDIR}/finder-desktop.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/finder-desktop.log</string>
</dict>
</plist>
PLIST

    cat > "$DOCK_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${DOCK_LABEL}</string>
    <key>POSIXSpawnType</key><string>Interactive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${DOCK_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>com.apple.desktoppicture.cache-delete</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.appstore</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.controlcenter</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.downloads</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.fullscreen</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.launchpad</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.notificationcenter</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.ppt</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.remotedesktoppicture</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.server</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.sidecar</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dock.spaces</key><dict><key>HideUntilCheckIn</key><true/></dict>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>EnvironmentVariables</key>
    <dict><key>CA_VSYNC_OFF</key><string>1</string></dict>
    <key>StandardOutPath</key><string>${LOGDIR}/dock.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/dock.log</string>
</dict>
</plist>
PLIST

    cat > "$SYSTEMUI_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${SYSTEMUI_LABEL}</string>
    <key>POSIXSpawnType</key><string>Interactive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${SYSTEMUI_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>com.apple.SUISMessaging</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dockextra.server</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.dockling.server</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.ipodserver</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.systemuiserver.ServiceProvider</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.systemuiserver.screencapture</key><dict><key>HideUntilCheckIn</key><true/></dict>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>EnvironmentVariables</key>
    <dict><key>CA_VSYNC_OFF</key><string>1</string></dict>
    <key>StandardOutPath</key><string>${LOGDIR}/systemuiserver.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/systemuiserver.log</string>
</dict>
</plist>
PLIST

    cat > "$CONTROL_CENTER_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${CONTROL_CENTER_LABEL}</string>
    <key>POSIXSpawnType</key><string>Interactive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string><string>0</string><string>0</string>
        <string>${ROOTFS}</string><string>${CONTROL_CENTER_BIN}</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>com.apple.controlcenter</key><true/>
        <key>com.apple.controlcenter.show.toggles</key><dict><key>HideUntilCheckIn</key><true/></dict>
        <key>com.apple.usernotifications.delegate.com.apple.controlcenter.notifications.airplay</key><true/>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>EnvironmentVariables</key>
    <dict><key>CA_VSYNC_OFF</key><string>1</string></dict>
    <key>StandardOutPath</key><string>${LOGDIR}/controlcenter.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/controlcenter.log</string>
</dict>
</plist>
PLIST

    # Terminal is a GUI app: start it once (RunAtLoad) but do NOT relaunch when
    # the user closes it (KeepAlive false) so launchd does not thrash.
    cat > "$TERM_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${TERM_LABEL}</string>
    <key>POSIXSpawnType</key>
    <string>Interactive</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CHROOTEXEC}</string>
        <string>0</string>
        <string>0</string>
        <string>${ROOTFS}</string>
        <string>${TERM_BIN}</string>
        <!--
          A cold start must create a usable shell window, not restore whichever
          auxiliary panel happened to survive the previous GUI generation.
          Runtime evidence on 2026-08-07 captured a Terminal process whose
          only on-screen layer-3 window was "Inspector"; the corresponding
          /var/root Saved Application State windows.plist contained that same
          sole persistent window.  Use AppKit's native persistence opt-out for
          this launch, while leaving Terminal preferences and profiles intact.
        -->
        <string>-ApplePersistenceIgnoreState</string>
        <string>YES</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <!--
      Terminal is a CoreAnimation client as well as an AppKit application.
      Runtime A/B on 2026-07-28: with the same producer-owned scanout and the
      same paced RFB input, the client advanced through nearly the entire
      command with CA_VSYNC_OFF=1; without it, the completed WindowServer
      surface stopped changing after the first character.  The chroot has no
      working display-vblank handoff, so client commits must not wait for it.
    -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>CA_VSYNC_OFF</key>
        <string>1</string>
        <!--
          Terminal's fast pty output can race its one delayed AppKit redraw in
          this virtual-display session.  This narrowly enables libmachook's
          debounced responder invalidation for Terminal only.  It is a bounded
          usability scaffold, not a substitute for a real display clock. A
          device A/B showed 120ms firing after the text model was complete but
          before TTView's pixels stabilized (VNC stopped at "echo dyna");
          750ms produced the command, output, and new prompt with no later
          input event.
        -->
        <key>MACWS_APP_DISPLAY_SETTLE_MS</key>
        <string>750</string>
    </dict>
    <key>StandardOutPath</key>
    <string>${LOGDIR}/terminal.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGDIR}/terminal.log</string>
</dict>
</plist>
PLIST
}

# Tear down every macOS GUI service we may have started.  Idempotent: unloading a
# job that is not loaded / killing a process that is gone are harmless no-ops.
stop_watchdogs() {
    local watchdog_pid="" candidate="" stopped="" deadline="" alive=""
    # A watchdog that trips must finish stop_all() before it exits. Unloading
    # its own launchd job here would terminate it halfway through restoration;
    # SuccessfulExit=false leaves the loaded job dormant after the clean exit.
    # Ordinary start/stop callers unload the job first so no replacement can
    # race their cleanup transaction.
    if [ "$CMD" != watchdog ]; then
        launchctl unload "$WATCHDOG_PLIST" 2>/dev/null
        launchctl remove "$WATCHDOG_LABEL" 2>/dev/null
    fi
    if [ -f "$WD_PIDFILE" ]; then
        watchdog_pid=$(awk 'NR == 1 { print $1 }' "$WD_PIDFILE" 2>/dev/null)
        case "$watchdog_pid" in
            ''|*[!0-9]*) ;;
            *)
                if [ "$watchdog_pid" != "$$" ]; then
                    kill "$watchdog_pid" 2>/dev/null
                    stopped="$stopped $watchdog_pid"
                fi
                ;;
        esac
    fi
    # Migration cleanup for watchdogs started by versions that had no pidfile.
    # Runtime evidence on 2026-07-29 found two simultaneous loops; the older
    # one reloaded VNC/Terminal during a manual restart and launchctl reported
    # both jobs "service already loaded". Match the complete script+subcommand
    # rather than a broad process name.
    for candidate in $(ps -ax -o pid=,command= 2>/dev/null | awk \
        -v needle="bash $0 watchdog " 'index($0, needle) { print $1 }'); do
        if [ "$candidate" != "$$" ]; then
            kill "$candidate" 2>/dev/null
            case " $stopped " in
                *" $candidate "*) ;;
                *) stopped="$stopped $candidate" ;;
            esac
        fi
    done

    # TERM is asynchronous. Runtime-confirmed on 2026-08-01: a previous
    # watchdog could still be inside its recovery/cleanup transaction after a
    # new `start` had created the production flags, then remove those new flags
    # and make preflight fail. Wait for the exact PIDs selected above before
    # starting another generation; use a bounded KILL only for those same
    # stale watchdogs, never a broad process-name kill.
    deadline=$(( $(date +%s) + 5 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        alive=""
        for candidate in $stopped; do
            kill -0 "$candidate" 2>/dev/null && alive="$alive $candidate"
        done
        [ -z "$alive" ] && break
        sleep 0.1
    done
    for candidate in $alive; do
        kill -KILL "$candidate" 2>/dev/null
    done
    if [ -n "$alive" ]; then
        deadline=$(( $(date +%s) + 2 ))
        while [ "$(date +%s)" -lt "$deadline" ]; do
            stopped=""
            for candidate in $alive; do
                kill -0 "$candidate" 2>/dev/null && stopped="$stopped $candidate"
            done
            [ -z "$stopped" ] && break
            sleep 0.1
        done
    fi
    rm -f "$WD_PIDFILE" "$WD_READY"
    [ "$CMD" = watchdog ] || rm -f "$WD_WS_PIDFILE"
}

# Every sentinel below changes code paths, installs tracing, records submit
# payloads, or performs an unsafe A/B readback.  Production startup removes the
# complete list; functional compatibility no longer needs enable files.
# Keep this list in sync with docs/runtime-switches.tsv; the host-side
# misc/audit_runtime_switches.py check fails when a newly-added source sentinel
# is not recorded there.
diagnostic_flag_paths() {
    # Generated from the authoritative manifest so new diagnostics cannot be
    # silently omitted from production cleanup or the preflight check.
    source "${BASH_SOURCE[0]%/*}/macws_diagnostic_flags.sh" || return 1
    macws_diagnostic_flag_paths
}

clear_diagnostic_state() {
    local path
    diagnostic_flag_paths | {
        # Batch the same exact operands in this pipeline's subshell, avoiding
        # one rm process per flag even when every flag is already absent.
        # Keep both namespace spellings and both startup cleanup calls.
        set --
        while IFS= read -r path; do
            set -- "$@" "$ROOTFS$path" "$path"
        done
        [ "$#" -eq 0 ] || rm -f "$@"
    }
    rm -f "$MTLCOMPILER_DIAGNOSTICS" "$MTLCOMPILER_HOLD" \
        "$STEAM_ANGLE_ASSET_BUILD" \
        "$CATALYST_LAUNCH_TRACE" \
        /tmp/iosclear_run /tmp/iosclear_pf550_mode \
        /tmp/iosclear_early_delay /tmp/iosclear_early_hold \
        /tmp/iosclear_dump_agx_methods /tmp/iosclear_hires \
        /tmp/iosclear_terminal_size /tmp/iosclear_draw_mode
    # Remove exact legacy sentinels once; the compiler tweak now reads only
    # boot-local /tmp paths, so stale persistent switches cannot affect boot.
    rm -f "$LOGDIR/macws_mtlcompiler_diagnostics" \
        "$LOGDIR/macws_mtlcompiler_hold" \
        "$LOGDIR/macws_steam_angle_asset_build" \
        /var/mobile/macws_mtlcompiler_diagnostics \
        /var/mobile/macws_mtlcompiler_hold \
        /var/mobile/iosclear_run \
        /var/mobile/iosclear_pf550_mode \
        /var/mobile/iosclear_early_delay \
        /var/mobile/iosclear_early_hold \
        /var/mobile/iosclear_dump_agx_methods \
        /var/mobile/iosclear_hires \
        /var/mobile/iosclear_terminal_size \
        /var/mobile/iosclear_draw_mode
    # Exact retired preference/readiness records cannot control production.
    # Current bridge readiness is live notifyd capability state, not a file.
    rm -f /var/mobile/Library/Preferences/com.macwsguide.dense-grid.disabled \
        /var/mobile/Library/Preferences/com.macwsguide.dense-grid.loaded \
        "$LOGDIR/macws_catalyst_launch.trace" \
        "$LOGDIR/macws-runningboard-settings-bridge.ready" \
        /tmp/macws-runningboard-settings-bridge.ready \
        /tmp/macws-settings-runtime.boot-ready \
        /tmp/macws-base-trust.boot-ready \
        /tmp/macws-launchservices-catalog.ready
    # Request/reply captures are created only by the compiler diagnostic
    # sentinel.  Remove these exact project-owned directories before an
    # ordinary session so neither stale evidence nor bounded binary dumps add
    # filesystem work to production shader compilation.
    rm -rf "$LOGDIR/mtlcompiler_requests" "$LOGDIR/mtlcompiler_replies"

    # Bounded dump directories are historical evidence, not session state.
    # Match only exact MacWS prefixes one directory below the chroot tmp root.
    find "$ROOTFS/private/tmp" -maxdepth 1 -type d \
        \( -name 'macws_fast_submit_error_[0-9]*_[0-9]*' \
        -o -name 'macws_submit_error_[0-9]*_[0-9]*' \) \
        -exec rm -rf {} \; 2>/dev/null
    find "$ROOTFS/private/tmp" -maxdepth 1 -type f \
        \( -name 'macws_submit_*.bin' \
        -o -name 'macws_submit_kcmd_*.bin' \
        -o -name 'macws_submit_segment_*.bin' \
        -o -name 'macws_submit_type1_*.bin' \
        -o -name 'macws_pf550_small_probe.bgra' \
        -o -name 'macws_vnc_rejected.bgra' \
        -o -name 'macws_back115.raw' \
        -o -name 'macws_backdense.raw' \
        -o -name 'macws_agx_runtime_methods.log' \
        -o -name 'macws_mtl_source_failure_*.metal' \
        -o -name 'macws_mtl_data_*.bin' \
        -o -name 'macws_cached_library_*.bin' \
        -o -name 'macws_compiled_library_*.bin' \
        -o -name 'macws_video_nv12_*.meta' \
        -o -name 'macws_video_nv12_*_p[01].raw' \
        -o -name 'macws_video_texture_*_p[01].raw' \
        -o -name 'macws_video_gpu_sample_*.rgba' \
        -o -name 'macws_disp.log' \) \
        -exec rm -f {} \; 2>/dev/null
}

normalize_managed_production_jobs() {
    # Optional jobs can outlive the package that originally installed them.
    # Migrate only known formerly-shipped settings in these exact MacWS jobs;
    # do not silently erase arbitrary diagnostics or rewrite stock iOS jobs.
    /var/jb/usr/bin/python3 - "$CHROOTEXEC" "$ROOTFS" \
        "$WINDOWSERVER_PLIST" "$VNC_PLIST" "$TERM_PLIST" \
        "$VSCODE_PLIST" "$CHROME150_PLIST" "$STEAM_PLIST" <<'MACWS_JOB_MIGRATION'
import os
import plistlib
import stat
import sys
import tempfile

chrootexec, rootfs, *paths = sys.argv[1:]
identities = {
    'com.apple.WindowServer.plist': 'windowserver',
    'com.macwsguide.osxvnc.plist': 'osxvnc',
    'com.macwsguide.terminal.plist': 'terminal',
    'com.macwsguide.vscode.plist': 'vscode',
    'com.macwsguide.chrome150.plist': 'chrome150',
    'com.macwsguide.steam.runtime.plist': 'steam',
}
retired_shipped_environment = {'MACWS_PIN_FALLBACK'}
updates = []
try:
    # Validate every candidate before writing any file. A broken or unrelated
    # optional job is a configuration error, never a reason to skip preflight.
    for path in paths:
        if not os.path.lexists(path):
            continue
        metadata = os.lstat(path)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError(f'{path}: expected a regular managed job')
        identity = identities.get(os.path.basename(path))
        with open(path, 'rb') as stream:
            job = plistlib.load(stream)
        if not identity or not isinstance(job, dict):
            raise ValueError(f'{path}: unknown managed job')
        labels = ('com.macwsguide.' + identity,
                  'UIKitApplication:com.macwsguide.' + identity)
        arguments = job.get('ProgramArguments')
        valid_arguments = (isinstance(arguments, list) and
                           all(isinstance(value, str) for value in arguments))
        direct_chroot = (valid_arguments and len(arguments) >= 5 and
                         arguments[0] == chrootexec and arguments[3] == rootfs)
        # Steam's shipped job intentionally runs the exact iOS preflight
        # script before that script execs launchdchrootexec as uid 501.
        steam_preflight = (identity == 'steam' and arguments == [
            '/var/jb/usr/bin/bash',
            os.path.join(os.path.dirname(chrootexec), 'prepare_steam_runtime.sh')])
        if (job.get('Label') not in labels or
                not (direct_chroot or steam_preflight)):
            raise ValueError(f'{path}: managed chroot launch identity mismatch')
        environment = job.get('EnvironmentVariables', {})
        if (not isinstance(environment, dict) or
                not all(isinstance(key, str) and isinstance(value, str)
                        for key, value in environment.items())):
            raise ValueError(f'{path}: invalid EnvironmentVariables dictionary')
        removed = sorted(retired_shipped_environment.intersection(environment))
        if removed:
            for key in removed:
                del environment[key]
            updates.append((path, job, metadata, removed))
    for path, job, metadata, removed in updates:
        descriptor, temporary = tempfile.mkstemp(
            prefix='.macws-job-migration-', dir=os.path.dirname(path))
        try:
            with os.fdopen(descriptor, 'wb') as stream:
                plistlib.dump(job, stream, sort_keys=False)
                if (os.geteuid(), os.getegid()) != (metadata.st_uid, metadata.st_gid):
                    os.fchown(stream.fileno(), metadata.st_uid, metadata.st_gid)
                os.fchmod(stream.fileno(), stat.S_IMODE(metadata.st_mode))
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        print('[macos_gui] Migrated retired production environment: ' +
              path + ' (' + ', '.join(removed) + ')')
except (OSError, ValueError, plistlib.InvalidFileException) as error:
    print('[macos_gui] ERROR: managed job migration: ' + str(error), file=sys.stderr)
    sys.exit(1)
MACWS_JOB_MIGRATION
}

retire_legacy_vscode_job() {
    # Before gui-launchd was introduced, this exact optional job lived in the
    # jailbreak's boot-autoload directory. Keep its bytes recoverable, but do
    # not let it race the current generated production profile after reboot.
    /var/jb/usr/bin/python3 - \
        /var/jb/Library/LaunchDaemons/com.macwsguide.vscode.plist \
        "$VSCODE_PLIST" /var/jb/usr/macOS/retired-launch-jobs \
        "$CHROOTEXEC" "$ROOTFS" <<'MACWS_LEGACY_JOB_RETIREMENT'
import hashlib
import os
import plistlib
import re
import stat
import sys

legacy, active, quarantine, chrootexec, rootfs = sys.argv[1:]
try:
    if not os.path.lexists(legacy):
        sys.exit(0)
    metadata = os.lstat(legacy)
    if (os.path.basename(legacy) != 'com.macwsguide.vscode.plist' or
            os.path.realpath(legacy) == os.path.realpath(active) or
            not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 65536):
        raise ValueError('legacy job is not the bounded regular old VS Code file')
    with open(legacy, 'rb') as stream:
        original = stream.read(65537)
    if len(original) > 65536:
        raise ValueError('legacy job exceeds the identity-parser bound')
    # An old source comment contained "--no-concurrent-*", which is illegal
    # XML. Strip comments only for identity verification; NEVER install the
    # parsed/repaired document or change the quarantined original bytes.
    identity_document = re.sub(br'<!--[\s\S]*?-->', b'', original)
    job = plistlib.loads(identity_document)
    arguments = job.get('ProgramArguments') if isinstance(job, dict) else None
    if (not isinstance(job, dict) or
            job.get('Label') not in ('com.macwsguide.vscode',
                                     'UIKitApplication:com.macwsguide.vscode') or
            not isinstance(arguments, list) or len(arguments) < 5 or
            not all(isinstance(value, str) for value in arguments) or
            arguments[:5] != [chrootexec, '0', '0', rootfs,
                '/Applications/Visual Studio Code.app/Contents/MacOS/Electron']):
        raise ValueError('unrecognized legacy VS Code launch identity; keeping original')
    # Refuse a symlink quarantine or an unexpected concurrent replacement.
    if os.path.lexists(quarantine):
        if not stat.S_ISDIR(os.lstat(quarantine).st_mode):
            raise ValueError('quarantine must be a real directory')
    else:
        os.mkdir(quarantine, 0o700)
    latest = os.lstat(legacy)
    if (latest.st_dev, latest.st_ino, latest.st_size, latest.st_mtime_ns) != (
            metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns):
        raise ValueError('legacy job changed during identity verification')
    destination = os.path.join(quarantine, 'com.macwsguide.vscode.' +
                               hashlib.sha256(original).hexdigest() + '.plist.disabled')
    if os.path.lexists(destination):
        if not stat.S_ISREG(os.lstat(destination).st_mode):
            raise ValueError('existing quarantine copy is not a regular file')
        with open(destination, 'rb') as stream:
            if stream.read(65537) != original:
                raise ValueError('existing quarantine copy differs; keeping original')
    else:
        # Both paths live on the same jailbreak volume. link+unlink is
        # no-clobber and preserves owner/mode/xattrs with an original inode
        # always present; a failed link leaves the autoload file untouched.
        os.link(legacy, destination)
    os.unlink(legacy)
    print('[macos_gui] Retired legacy VS Code autoload job; recoverable at ' + destination)
except Exception as error:
    print('[macos_gui] ERROR: legacy VS Code retirement: ' + str(error), file=sys.stderr)
    sys.exit(1)
MACWS_LEGACY_JOB_RETIREMENT
}

production_preflight() {
    local path plist key bad=0
    local expected_vscode_profile_dir="$ROOTFS/private/tmp/macws-vscode-profile-agx-native-production1"
    clear_diagnostic_state
    normalize_managed_production_jobs || return 1
    retire_legacy_vscode_job || return 1

    # No production launch job may enable allocator/debug flight recorders via
    # environment.  Functional compatibility variables are documented and
    # intentionally excluded from this deny-list.
    source "${BASH_SOURCE[0]%/*}/macws_diagnostic_flags.sh" || return 1
    local diagnostic_environment_pattern
    diagnostic_environment_pattern=$(macws_diagnostic_environment_pattern)
    for plist in "$WINDOWSERVER_PLIST" "$VNC_PLIST" "$TERM_PLIST" \
                 "$VSCODE_PLIST" "$CHROME150_PLIST" "$STEAM_PLIST"; do
        [ -f "$plist" ] || continue
        if plutil "$plist" 2>/dev/null | grep -Eq \
            "\"?($diagnostic_environment_pattern)\"?[[:space:]]*="; then
            log "ERROR: production debug environment found in $plist"
            bad=1
        fi
    done
    if [ -d "$ROOTFS/Applications/Visual Studio Code.app" ]; then
        if [ ! -f "$VSCODE_ANGLE_MACABI_LIBRARY" ] ||
           [ "$(wc -c < "$VSCODE_ANGLE_MACABI_LIBRARY" 2>/dev/null)" != 714152 ]; then
            log "ERROR: exact ANGLE 1ba8ec3 macabi default library is missing or invalid: $VSCODE_ANGLE_MACABI_LIBRARY"
            bad=1
        fi
        for key in MACWS_JIT_MPROTECT_COMPAT \
                   MACWS_JIT_FAULT_WRITE_COMPAT \
                   MACWS_AMFI_IMMOVABLE_TASK_PORT_COMPAT \
                   MACWS_MACOS_SYSTEM_POLICY_COMPAT; do
            if ! plutil "$VSCODE_PLIST" 2>/dev/null |
                 grep -Eq "\"?$key\"?[[:space:]]*=[[:space:]]*1;"; then
                log "ERROR: required VS Code production environment $key=1 missing from $VSCODE_PLIST"
                bad=1
            fi
        done
        for path in \
            '--user-data-dir=/tmp/macws-vscode-profile-agx-native-production1' \
            '--extensions-dir=/tmp/macws-vscode-extensions' \
            '--disable-gpu-sandbox' \
            '--use-angle=metal' \
            '--ignore-gpu-blocklist' \
            '--disable-features=SkiaGraphite,avfoundation-overlays' \
            '--disable-avfoundation-overlays'; do
            if ! plutil "$VSCODE_PLIST" 2>/dev/null | grep -Fq -- "$path"; then
                log "ERROR: required VS Code production argument missing: $path"
                bad=1
            fi
        done
        if [ "$VSCODE_PROFILE_DIR" != "$expected_vscode_profile_dir" ]; then
            log "ERROR: VS Code asset target does not match its launch profile: $VSCODE_PROFILE_DIR"
            bad=1
        elif ! cmp -s "$VSCODE_ASSET_DIR/settings.json" \
                       "$VSCODE_PROFILE_DIR/User/settings.json"; then
            # Runtime-confirmed on 2026-09-04: the stale production generation
            # spawned AgentHost despite the packaged false setting; that same
            # generation later had Chrome_IOThread retrying a full MOJO Mach
            # queue at 100% CPU.
            log "ERROR: VS Code production settings are missing or stale in $VSCODE_PROFILE_DIR"
            bad=1
        fi
        if plutil "$VSCODE_PLIST" 2>/dev/null |
             grep -Eq '"--disable-gpu"([[:space:],;]|$)'; then
            log "ERROR: VS Code native-AGX profile still disables the GPU: $VSCODE_PLIST"
            bad=1
        fi
        for path in "$COREAUDIOD_PLIST" \
                    "$AUDIO_COMPONENT_REGISTRAR_PLIST" \
                    "$AUDIO_OUTPUT_PLIST" \
                    /var/jb/usr/macOS/bin/macwsaudiooutd; do
            if [ ! -e "$path" ]; then
                log "ERROR: VS Code audio bridge prerequisite missing: $path"
                bad=1
            fi
        done
    fi
    if [ -d "$ROOTFS/Applications/Steam.app" ]; then
        for key in MACWS_STEAM_CPU_RENDERING \
                   MACWS_JIT_MPROTECT_COMPAT \
                   MACWS_JIT_FAULT_WRITE_COMPAT \
                   MACWS_AMFI_IMMOVABLE_TASK_PORT_COMPAT \
                   MACWS_CRASHPAD_IMMOVABLE_TASK_PORT_COMPAT; do
            if ! plutil "$STEAM_PLIST" 2>/dev/null |
                 grep -Eq "\"?$key\"?[[:space:]]*=[[:space:]]*1;"; then
                log "ERROR: required Steam production environment $key=1 missing from $STEAM_PLIST"
                bad=1
            fi
        done
        for key in MACWS_AGX_NATIVE MACWS_AGX_REGISTER_CLASSES; do
            if plutil "$STEAM_PLIST" 2>/dev/null |
                 grep -Eq "\"?$key\"?[[:space:]]*=[[:space:]]*1;"; then
                log "ERROR: Steam CPU-download profile unexpectedly enables $key: $STEAM_PLIST"
                bad=1
            fi
        done
        steam_launcher="$ROOTFS/usr/local/bin/macws-run-steam.sh"
        if [ ! -f "$steam_launcher" ] ||
           ! grep -Ev '^[[:space:]]*#' "$steam_launcher" |
                grep -Eq -- '(^|[[:space:]])-cef-disable-gpu([[:space:]]|$)'; then
            log "ERROR: Steam launcher does not select the CPU-download CEF profile: $steam_launcher"
            bad=1
        fi
        if grep -Ev '^[[:space:]]*#' "$steam_launcher" |
             grep -Eq -- '(^|[[:space:]])-cef-force-gpu([[:space:]]|$)'; then
            log "ERROR: Steam native-AGX CEF policy survived in CPU-download profile: $steam_launcher"
            bad=1
        fi
    fi
    if ! plutil "$WINDOWSERVER_PLIST" 2>/dev/null |
         grep -Eq "\"?MACWS_VNC_SHARE\"?[[:space:]]*=[[:space:]]*$WANT_VNC;"; then
        log "ERROR: WindowServer VNC transport does not match this session."
        bad=1
    fi
    if [ "$WANT_VNC" != 1 ] &&
       ! plutil "$VNC_PLIST" 2>/dev/null | grep -Fq -- '"-localhost"'; then
        log "ERROR: local pointer-proxy VNC job is not restricted to localhost: $VNC_PLIST"
        bad=1
    fi
    for key in MACWS_VNC_NATIVE_ALL MACWS_VNC_LOW_LATENCY_COMPRESSION; do
        if ! plutil "$VNC_PLIST" 2>/dev/null |
             grep -Eq "\"?$key\"?[[:space:]]*=[[:space:]]*1;"; then
            log "ERROR: required OSXvnc environment $key=1 missing from $VNC_PLIST"
            bad=1
        fi
    done
    diagnostic_flag_paths | while IFS= read -r path; do
        [ ! -e "$ROOTFS$path" ] || echo "$path"
        [ ! -e "$path" ] || echo "iOS:$path"
    done > "$ROOTFS/private/tmp/macws_production_preflight.bad"
    if [ -s "$ROOTFS/private/tmp/macws_production_preflight.bad" ]; then
        log "ERROR: diagnostic flag survived production cleanup:"
        sed 's/^/       /' "$ROOTFS/private/tmp/macws_production_preflight.bad"
        bad=1
    fi
    rm -f "$ROOTFS/private/tmp/macws_production_preflight.bad"
    for path in "$MTLCOMPILER_DIAGNOSTICS" \
                "$MTLCOMPILER_HOLD" \
                "$STEAM_ANGLE_ASSET_BUILD" \
                /tmp/iosclear_run /tmp/iosclear_pf550_mode \
                /tmp/iosclear_early_delay /tmp/iosclear_early_hold \
                /tmp/iosclear_dump_agx_methods /tmp/iosclear_hires \
                /tmp/iosclear_terminal_size /tmp/iosclear_draw_mode; do
        if [ -e "$path" ]; then
            log "ERROR: iOS MTLCompilerService diagnostic flag survived production cleanup: $path"
            bad=1
        fi
    done
    [ "$bad" = 0 ] || return 1
    log "PRODUCTION-PREFLIGHT: native AGX required; diagnostics/env traces/dump sentinels OFF."
    return 0
}

cleanup_macos() {
    log "Cleaning up previous macOS GUI services..."
    stop_watchdogs
    CLEANUP_TERM_PIDS=""

    # 1) Unload the two project-owned launchd directories once. launchctl
    # accepts a directory as an atomic job set (the start path already loads
    # these same directories). Serial plist unload + label remove pairs made a
    # routine stop spend tens of seconds crossing the launchd control plane.
    # Exact process cleanup below remains the postcondition witness and catches
    # jobs from historical labels or malformed older plists.
    launchctl unload "$GUI_LAUNCHD_DIR" 2>/dev/null
    launchctl unload "$MACOS_DAEMONS" 2>/dev/null
    # Upgrade cleanup for labels no longer represented by a current plist.
    launchctl remove com.macwsguide.dockhelper 2>/dev/null
    launchctl remove "$WINDOWSERVER_LEGACY_LABEL" 2>/dev/null
    rm -f "$LOCATION_PROVIDER_READY"

    # 2) stray GUI clients (Terminal, VNC, Activity Monitor, ...)
    kill_patterns \
        "$P_OSXVNC" "$P_TERMINAL" "$P_PBOARD" "$P_PBS" \
        "$P_OFFICE_LICENSING" "$P_ACTIVITYMON" "$P_GLASSDEMO" \
        "$P_AMADINE" "$P_WORD" "$P_EXCEL" "$P_POWERPOINT" \
        "$P_MAPS" "$P_SYSTEM_SETTINGS" "$P_FINDER" "$P_DOCK" \
        "$P_DOCK_HELPER" "$P_SYSTEMUI" "$P_CONTROL_CENTER" \
        "$P_ICONSERVICESAGENT" "$P_ICONSERVICESD" \
        "$P_QUICKLOOK_THUMBNAILS" "$P_QUICKLOOKD" \
        "$P_QUICKLOOK_SATELLITE" \
        "$P_SHAREDFILELISTD" "$P_INPUTD" "$P_DISPLAYD" \
        "$P_INTEROPD" "$P_VSCODE" "$P_STEAM_OUTER" \
        "$P_STEAM_LIVE" "$P_STEAM_HELPER" "$P_WINDOWSERVER" \
        "$P_LAUNCHSERVICESD" "$P_SYSTEMSTATUSD" "$P_FONTD"
    # Maps cannot survive a WindowServer generation change: its CGS port is
    # permanently bound to the retired server even if the Catalyst carrier
    # process remains live.  The old omission made the next launch falsely
    # reuse that live PID and publish no AppKit window.
    rm -f "$MAPS_HOST_CARRIER_MARKER"
    rm -f "$ROOTFS"/private/tmp/macws_app_input.*.sock
    rm -f "$ROOTFS"/private/tmp/macws_window_metrics.*.bin
    rm -f "$ROOTFS"/private/tmp/macws_menu_client.*.sock
    rm -f "$ROOTFS"/private/tmp/macws_menu_snapshot.*.bin
    rm -f "$ROOTFS"/private/tmp/macws_input_target.sock

    # 3) WindowServer and the macOS service daemons loaded with it. A plist
    # label migration cannot be cleaned up by unloading the current directory:
    # launchd retains the already-loaded old label even though the file at the
    # same path now names the UIKitApplication job. Remove both exact project
    # generations before the next one can claim the shared SkyLight services.
    launchctl remove "$WINDOWSERVER_LABEL" 2>/dev/null
    launchctl remove "$WINDOWSERVER_LEGACY_LABEL" 2>/dev/null

    # 4) anything still lingering
    finish_pattern_cleanup

    clear_diagnostic_state

    # The mmap is a producer-owned WindowServer artifact, not persistent
    # session state.  Keeping it after the producer exits lets a fresh OSXvnc
    # process advertise pixels from an earlier application even when the new
    # WindowServer has not published a frame.  Remove it only after every old
    # producer/client has been stopped so no live mapping is invalidated.
    rm -f "$VNC_SHARED_FRAME" "$VNC_SHARED_SURFID" "$VNC_ACTIVITY" \
        "$INTERACTION_WAKE" "$VNC_ACTIVATION_REPLY" \
        "$GRAPHICS_READY" \
        "$EXPERIMENTAL_CAPTURE" "$EXPERIMENTAL_CAPTURE_DONE" \
        "$EXPERIMENTAL_KCMD" "$EXPERIMENTAL_WRAPPED_KCMD" \
        "$EXPERIMENTAL_COMMAND_ERROR" "$EXPERIMENTAL_COMPLETION" \
        "$EXPERIMENTAL_VNC_SHARE" "$EXPERIMENTAL_FINAL_COMPOSITE" \
        "$EXPERIMENTAL_OBSERVE_PF550" \
        "$EXPERIMENTAL_SUBMIT_RING" "$EXPERIMENTAL_FAST_SUBMIT_RING" \
        "$EXPERIMENTAL_OWNED_SCANOUT" "$EXPERIMENTAL_QUEUE_QOS" \
        "$EXPERIMENTAL_RUNTIME_DIAGNOSTICS" "$EXPERIMENTAL_PACE" \
        "$RENDER_ACTIVITY"
    sleep 1
    log "Cleanup done."
}

mode_coexist() {
    log "Display mode: COEXISTENCE — iPad panel stays on iOS, macOS renders to VNC only."
    # Make sure the iOS UI is up (a previous 'exclusive' run may have unloaded it).
    launchctl load "$BACKBOARDD"  2>/dev/null
    launchctl load "$SPRINGBOARD" 2>/dev/null
}

mode_exclusive() {
    log "Display mode: EXCLUSIVE — macOS takes over the physical panel (and VNC)."
    log "WARNING: exclusive mode drives the panel from WindowServer; on this device"
    log "         that GPU path is the most panic-prone. coexist is the safer choice."
    # Hand the panel to macOS: stop iOS SpringBoard/backboardd (SpringBoard first).
    launchctl unload "$SPRINGBOARD" 2>/dev/null
    launchctl unload "$BACKBOARDD"  2>/dev/null
}

seed_launchservices_database() {
    if [ ! -x "$ROOTFS$LSREGISTER_BIN" ]; then
        log "ERROR: stock macOS lsregister is missing at $LSREGISTER_BIN"
        return 1
    fi
    if [ ! -x "$ROOTFS$WORKSPACECTL_BIN" ]; then
        log "ERROR: native workspace controller is missing at $WORKSPACECTL_BIN"
        return 1
    fi
    rm -f "$LOGDIR/lsregister.log"
    # Each private lsd generation needs an authoritative rebuild: the session
    # store is not retained across generations even when a source fingerprint
    # is unchanged. The previous `-f -apps system,local,user` path appended
    # records repeatedly:
    # runtime evidence found a 148,717,568-byte store and a 50-60 second
    # `_LSDatabaseClean` on every lsd launch.  Ventura's stock `-kill -seed`
    # transaction produced a clean 6-10 MB store in 6 seconds on this device
    # and immediately passed every application/ExtensionKit witness. Never
    # substitute a stale marker for the real catalog verification below.
    log "Rebuilding the real macOS application catalog for this lsd generation..."
    if ! "$CHROOTEXEC" 0 0 "$ROOTFS" "$LSREGISTER_BIN" \
            -kill -seed > "$LOGDIR/lsregister.log" 2>&1; then
        log "ERROR: LaunchServices clean seed failed."
        tail -n 20 "$LOGDIR/lsregister.log" 2>/dev/null || true
        return 1
    fi
    # Ventura's Settings panes are system-level ExtensionKit content, not
    # embedded in System Settings.app.  A normal application-only scan leaves
    # these plug-ins absent (or with stale Container state -1 records) after a
    # cold database rebuild.  Register every pane through LaunchServices' own
    # plug-in registrar and require exact platform-1 records before publishing
    # the settings services.
    rm -f "$SETTINGS_EXTENSION_REGISTER_LOG"
    if ! "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
            verify-launchservices-catalog \
            > "$SETTINGS_EXTENSION_REGISTER_LOG" 2>&1; then
        log "Clean seed needs explicit System Settings extension activation..."
        if ! MACWS_CATALOG_REGISTRATION=1 \
                "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
                register-settings-extensions \
                >> "$SETTINGS_EXTENSION_REGISTER_LOG" 2>&1 ||
           ! "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
                verify-launchservices-catalog \
                >> "$SETTINGS_EXTENSION_REGISTER_LOG" 2>&1; then
            log "ERROR: rebuilt LaunchServices catalog failed record verification."
            tail -n 20 "$SETTINGS_EXTENSION_REGISTER_LOG" 2>/dev/null || true
            return 1
        fi
    fi
    log "LaunchServices application catalog ready."
}

verify_launchservices_database_for_desktop_repair() {
    # A live repair accepts the current catalog only after the typed stock
    # application/ExtensionKit records pass verification. A missing /tmp
    # marker cannot invalidate working records or force a needless rebuild.
    if "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
            verify-launchservices-catalog \
            > "$LAUNCHSERVICES_VERIFY_LOG" 2>&1; then
        log "LaunchServices live catalog verified without rebuilding."
        return 0
    fi
    log "Live LaunchServices catalog verification failed; running the clean seed transaction."
    seed_launchservices_database
}

prepare_settings_service_proxies() {
    local proxy=""
    # These freestanding iOS first images chroot before libSystem consumes
    # launchd's one-shot context.  Package postinst establishes this invariant,
    # but an incremental developer copy can replace a file and silently clear
    # its setuid bit.  Reassert the exact owner/mode before publishing any
    # service so cold production starts cannot regress to Connection Invalid.
    for proxy in \
        /var/jb/usr/macOS/Frameworks/ViewBridge.framework/Versions/A/XPCServices/ViewBridgeAuxiliary.xpc/ViewBridgeAuxiliary \
        /var/jb/usr/macOS/Frameworks/HIServices.framework/Versions/A/XPCServices/HIServicesProxy.xpc/HIServicesProxy \
        /var/jb/usr/macOS/Frameworks/AppKit.framework/Versions/C/XPCServices/OpenAndSavePanelProxy.xpc/OpenAndSavePanelProxy \
        /var/jb/usr/macOS/Frameworks/QuickLookUI.framework/Versions/A/XPCServices/QuickLookUIServiceProxy.xpc/QuickLookUIServiceProxy \
        /var/jb/usr/macOS/Frameworks/ExtensionFoundation.framework/Versions/A/XPCServices/ExtensionKitProxy.xpc/ExtensionKitProxy \
        /var/jb/usr/macOS/PrivateFrameworks/GeoServices.framework/Versions/A/XPCServices/GeodProxy.xpc/GeodProxy \
        /var/jb/Applications/SettingsExtensionProxy.app/SettingsExtensionProxy; do
        if [ ! -x "$proxy" ]; then
            log "ERROR: required macOS service proxy is missing: $proxy"
            return 1
        fi
        chown root:wheel "$proxy" || return 1
        chmod 4755 "$proxy" || return 1
    done
    # The generic ViewBridge/ExtensionKit/HIServices contracts are desktop
    # dependencies, but the 48 per-pane iOS carrier binaries are not.  Keep
    # this startup path limited to the service proxies it is about to publish.
    # System Settings performs the full pane reconciliation through hostd at
    # its own launch boundary, where the verifier requires every carrier to be
    # executable and setuid before the app can start. Re-running chown+chmod as
    # 96 separate processes here cost 2.11 seconds on the 2026-09-02 warm-start
    # trace even though none of those binaries participates in desktop launch.
    if [ ! -f "$SETTINGS_EXTENSIONS_RUNTIME" ]; then
        log "ERROR: Settings ExtensionKit runtime helper is missing."
        return 1
    fi
    log "Settings service proxies ready; per-pane runtimes are prepared on demand."
}

prepare_settings_extension_runtimes() {
    # Every Ventura Settings pane is a distinct ExtensionKit executable and
    # therefore needs a distinct registered iOS first-image carrier.  Runtime
    # on 2026-08-05 proved that sharing one path makes RunningBoard reject the
    # second pane with unequal identities, while preparing only Appearance
    # leaves Wi-Fi/Bluetooth/etc. at OSLaunchdErrorDomain/2.  This expensive
    # transaction is intentionally called only when System Settings is being
    # launched, and it retains the same complete verification invariant.
    rm -f "$SETTINGS_EXTENSIONS_RUNTIME_LOG"
    if ! bash "$SETTINGS_EXTENSIONS_RUNTIME" --verify \
            > "$SETTINGS_EXTENSIONS_RUNTIME_LOG" 2>&1; then
        log "Repairing System Settings extension runtimes after verification failure..."
        if ! bash "$SETTINGS_EXTENSIONS_RUNTIME" \
                >> "$SETTINGS_EXTENSIONS_RUNTIME_LOG" 2>&1 ||
           ! bash "$SETTINGS_EXTENSIONS_RUNTIME" --verify \
                >> "$SETTINGS_EXTENSIONS_RUNTIME_LOG" 2>&1; then
            log "ERROR: System Settings extension runtimes could not be prepared."
            tail -n 20 "$SETTINGS_EXTENSIONS_RUNTIME_LOG" 2>/dev/null || true
            return 1
        fi
    fi
    log "All System Settings extension runtimes and carriers are ready."
}

publish_settings_service_contracts() {
    local plist="" label=""
    prepare_settings_service_proxies || return 1
    for plist in "$VIEWBRIDGE_PLIST" "$EXTENSIONKIT_PLIST" \
                 "$HISERVICES_PLIST" "$GEOD_PLIST"; do
        if [ ! -f "$plist" ]; then
            log "ERROR: required macOS service job is missing: $plist"
            return 1
        fi
        launchctl load "$plist" || return 1
    done
    for label in "$VIEWBRIDGE_LABEL" "$EXTENSIONKIT_LABEL" \
                 "$HISERVICES_LABEL" "$GEOD_LABEL"; do
        launchctl list "$label" >/dev/null 2>&1 || {
            log "ERROR: private macOS service contract was not registered: $label"
            return 1
        }
    done
    log "Private macOS ViewBridge, ExtensionKit, HIServices and GeoServices contracts ready."
}

publish_desktop_operation_services() {
    local plist="" label="" authd_pid="" waited=0
    [ -x "$CSNAMEDDATA_PROXY" ] || {
        log "ERROR: authd chroot proxy is missing: $CSNAMEDDATA_PROXY"
        return 1
    }
    chown root:wheel "$CSNAMEDDATA_PROXY" || return 1
    chmod 4755 "$CSNAMEDDATA_PROXY" || return 1
    for plist in "$AUTHD_PLIST" "$DESKTOP_SERVICES_HELPER_PLIST"; do
        if [ ! -f "$plist" ]; then
            log "ERROR: required macOS desktop-operation job is missing: $plist"
            return 1
        fi
    done
    [ -x "$ROOTFS$AUTHD_BIN" ] || {
        log "ERROR: Ventura authd launch target is missing: $AUTHD_BIN"
        return 1
    }
    [ -x "$ROOTFS$DESKTOP_SERVICES_HELPER_BIN" ] || {
        log "ERROR: DesktopServicesHelper launch target is missing: $DESKTOP_SERVICES_HELPER_BIN"
        return 1
    }
    for plist_label in \
        "$AUTHD_PLIST:$AUTHD_LABEL" \
        "$DESKTOP_SERVICES_HELPER_PLIST:$DESKTOP_SERVICES_HELPER_LABEL"; do
        plist=${plist_label%%:*}
        label=${plist_label#*:}
        launchctl list "$label" >/dev/null 2>&1 || launchctl load "$plist" || return 1
        launchctl list "$label" >/dev/null 2>&1 || {
            log "ERROR: private desktop-operation contract was not registered: $label"
            return 1
        }
    done

    # authd is RunAtLoad and services synchronous Authorization.framework
    # requests. Require the real stock payload to survive startup; the helper
    # stays on demand and its registered MachService is its readiness contract.
    while [ "$waited" -lt 10 ]; do
        authd_pid=$(launchd_job_pid "$AUTHD_LABEL")
        case "$authd_pid" in
            ''|'-'|*[!0-9]*) ;;
            *) kill -0 "$authd_pid" 2>/dev/null && break ;;
        esac
        sleep 1
        waited=$((waited + 1))
    done
    case "$authd_pid" in
        ''|'-'|*[!0-9]*)
            log "ERROR: Ventura authd did not publish a live process."
            tail -n 30 "$LOGDIR/authd.log" 2>/dev/null || true
            return 1
            ;;
    esac
    kill -0 "$authd_pid" 2>/dev/null || {
        log "ERROR: Ventura authd exited during startup."
        tail -n 30 "$LOGDIR/authd.log" 2>/dev/null || true
        return 1
    }
    log "Private Ventura authd and DesktopServicesHelper contracts ready."
}

run_defaults_utility() {
    # defaults is a headless startup probe, but CoreFoundation performs its
    # cfprefsd connection from inside the shared cache.  Select libmachook's
    # narrow preferences-client path: install only the two private XPC name
    # hooks, then skip CGSession/AppKit/Metal/input initialization.
    # A registered launchd service is not proof that cfprefsd is processing
    # requests.  A half-started generation previously left this exact utility
    # blocked for more than a minute while the startup/trust workload pushed
    # iPadOS thermal state to serious.  Bound every real protocol round-trip;
    # the caller still verifies the write/read value and fails startup if the
    # service is unhealthy.
    MACWS_CFPREFERENCES_CLIENT=1 \
        /var/jb/usr/bin/timeout -k 2 15 \
        "$CHROOTEXEC" 0 0 "$ROOTFS" "$DEFAULTS_BIN" "$@"
}

run_mobile_defaults_utility() {
    # Exercise the exact uid, identity and private endpoint inherited by the
    # prepared 7DTD process.  This remains a stock `defaults`/cfprefsd
    # round-trip; no preference result is synthesized by libmachook.
    HOME=/Users/mobile USER=mobile LOGNAME=mobile \
        MACWS_CFPREFERENCES_CLIENT=1 MACWS_SYNTHETIC_MOBILE_USER=1 \
        /var/jb/usr/bin/timeout -k 2 15 \
        "$CHROOTEXEC" 501 501 "$ROOTFS" "$DEFAULTS_BIN" "$@"
}

verify_preferences_persistence() {
    local value="" mission_control="" app_expose=""
    local dock_magnification="" dock_large_size="" dock_minimize_effect=""
    rm -f "$LOGDIR/cfprefsd-probe.log"
    if ! run_defaults_utility write \
            com.macwsguide.bootstrap PersistentPreferencesReady -bool true \
            > "$LOGDIR/cfprefsd-probe.log" 2>&1; then
        log "ERROR: private macOS CFPreferences write failed."
        tail -n 20 "$LOGDIR/cfprefsd-probe.log" 2>/dev/null || true
        return 1
    fi
    value=$(run_defaults_utility read \
        com.macwsguide.bootstrap PersistentPreferencesReady 2>> \
        "$LOGDIR/cfprefsd-probe.log") || value=""
    if [ "$value" != 1 ]; then
        log "ERROR: private macOS CFPreferences domain is not persistent (read='$value')."
        tail -n 20 "$LOGDIR/cfprefsd-probe.log" 2>/dev/null || true
        return 1
    fi
    # Dock registers its native fluid-gesture controllers while starting.  A
    # cold rootfs may not have created either preference yet; in that state
    # Ventura's real DOCKGestures object has no App Expose handler in slot 1,
    # so a correctly delivered three-finger-down stream is intentionally
    # ignored.  Persist the stock Dock preferences before Dock is launched and
    # verify the values through cfprefsd instead of installing another handler.
    rm -f "$LOGDIR/dock-gesture-preferences.log"
    if ! run_defaults_utility write \
            com.apple.dock showMissionControlGestureEnabled -bool true \
            > "$LOGDIR/dock-gesture-preferences.log" 2>&1 ||
       ! run_defaults_utility write \
            com.apple.dock showAppExposeGestureEnabled -bool true \
            >> "$LOGDIR/dock-gesture-preferences.log" 2>&1 ||
       ! run_defaults_utility write \
            com.apple.dock magnification -bool true \
            >> "$LOGDIR/dock-gesture-preferences.log" 2>&1 ||
       ! run_defaults_utility write \
            com.apple.dock largesize -int 128 \
            >> "$LOGDIR/dock-gesture-preferences.log" 2>&1 ||
       ! run_defaults_utility write \
            com.apple.dock mineffect -string genie \
            >> "$LOGDIR/dock-gesture-preferences.log" 2>&1; then
        log "ERROR: native Dock gesture/magnification preferences could not be persisted."
        tail -n 20 "$LOGDIR/dock-gesture-preferences.log" 2>/dev/null || true
        return 1
    fi
    mission_control=$(run_defaults_utility read \
        com.apple.dock showMissionControlGestureEnabled 2>> \
        "$LOGDIR/dock-gesture-preferences.log") || mission_control=""
    app_expose=$(run_defaults_utility read \
        com.apple.dock showAppExposeGestureEnabled 2>> \
        "$LOGDIR/dock-gesture-preferences.log") || app_expose=""
    dock_magnification=$(run_defaults_utility read \
        com.apple.dock magnification 2>> \
        "$LOGDIR/dock-gesture-preferences.log") || dock_magnification=""
    dock_large_size=$(run_defaults_utility read \
        com.apple.dock largesize 2>> \
        "$LOGDIR/dock-gesture-preferences.log") || dock_large_size=""
    dock_minimize_effect=$(run_defaults_utility read \
        com.apple.dock mineffect 2>> \
        "$LOGDIR/dock-gesture-preferences.log") || dock_minimize_effect=""
    if [ "$mission_control" != 1 ] || [ "$app_expose" != 1 ] ||
       [ "$dock_magnification" != 1 ] || [ "$dock_large_size" != 128 ] ||
       [ "$dock_minimize_effect" != genie ]; then
        log "ERROR: native Dock preferences failed verification (Mission Control='$mission_control', App Expose='$app_expose', magnification='$dock_magnification', largesize='$dock_large_size', mineffect='$dock_minimize_effect')."
        tail -n 20 "$LOGDIR/dock-gesture-preferences.log" 2>/dev/null || true
        return 1
    fi
    log "Private macOS CFPreferences database ready; native gestures, Genie minimize and maximum Dock hover magnification enabled."
}

verify_mobile_preferences_persistence() {
    local value=""
    rm -f "$LOGDIR/cfprefsd-mobile-probe.log"
    if ! run_mobile_defaults_utility write \
            com.macwsguide.bootstrap.mobile PersistentPreferencesReady \
            -bool true > "$LOGDIR/cfprefsd-mobile-probe.log" 2>&1; then
        log "ERROR: uid-501 macOS CFPreferences write failed."
        tail -n 20 "$LOGDIR/cfprefsd-mobile-probe.log" 2>/dev/null || true
        return 1
    fi
    value=$(run_mobile_defaults_utility read \
        com.macwsguide.bootstrap.mobile PersistentPreferencesReady 2>> \
        "$LOGDIR/cfprefsd-mobile-probe.log") || value=""
    if [ "$value" != 1 ]; then
        log "ERROR: uid-501 macOS CFPreferences domain is not persistent (read='$value')."
        tail -n 20 "$LOGDIR/cfprefsd-mobile-probe.log" 2>/dev/null || true
        return 1
    fi
    log "uid-501 macOS CFPreferences write/read round-trip ready."
}

apply_workspace_wallpaper() {
    local rc=0

    if [ ! -x "$ROOTFS$WORKSPACECTL_BIN" ]; then
        log "ERROR: native workspace controller is missing at $WORKSPACECTL_BIN"
        return 1
    fi
    rm -f "$LOGDIR/workspace-controller.log"
    /var/jb/usr/bin/timeout -k 2 20 \
        "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
        set-wallpaper "$WORKSPACE_WALLPAPER" \
        > "$LOGDIR/workspace-controller.log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "ERROR: the real macOS desktop wallpaper could not be applied."
        [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] ||
            log "ERROR: native wallpaper IPC exceeded the 20-second startup bound."
        tail -n 20 "$LOGDIR/workspace-controller.log" 2>/dev/null || true
        return 1
    fi
    log "Native macOS desktop wallpaper ready."
}

desktop_job_loaded() {
    launchctl list "$1" >/dev/null 2>&1
}

wait_for_desktop_job_pid() {
    local label="$1" previous_pid="${2:-}" waited=0 pid=""
    while [ "$waited" -lt 100 ]; do
        pid=$(launchd_job_pid "$label")
        case "$pid" in
            ''|'-'|*[!0-9]*) ;;
            *)
                if [ "$pid" != "$previous_pid" ] &&
                   kill -0 "$pid" 2>/dev/null; then
                    DESKTOP_JOB_PID="$pid"
                    return 0
                fi
                ;;
        esac
        sleep 0.1
        waited=$((waited + 1))
    done
    DESKTOP_JOB_PID=""
    return 1
}

wait_for_desktop_input_route() {
    local waited=0 dock_pid="" endpoint=""
    while [ "$waited" -lt 100 ]; do
        dock_pid=$(launchd_job_pid "$DOCK_LABEL")
        case "$dock_pid" in
            ''|'-'|*[!0-9]*) ;;
            *)
                endpoint="$ROOTFS/private/tmp/macws_app_input.$dock_pid.sock"
                if kill -0 "$dock_pid" 2>/dev/null &&
                   [ -S "$ROOTFS/private/tmp/macws_host_input.sock" ] &&
                   [ -S "$endpoint" ]; then
                    DESKTOP_INPUT_PID="$dock_pid"
                    log "Desktop input route ready (Dock pid=$dock_pid)."
                    return 0
                fi
                ;;
        esac
        sleep 0.1
        waited=$((waited + 1))
    done
    DESKTOP_INPUT_PID=""
    log "ERROR: current Dock launchd owner did not publish its AppInput endpoint within 10 seconds."
    return 1
}

retire_desktop_job() {
    local plist="$1" label="$2" old_pid="" waited=0
    old_pid=$(launchd_job_pid "$label")
    launchctl unload "$plist" 2>/dev/null || true
    launchctl remove "$label" 2>/dev/null || true
    case "$old_pid" in
        ''|'-'|*[!0-9]*) return 0 ;;
    esac
    while kill -0 "$old_pid" 2>/dev/null && [ "$waited" -lt 20 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    # Unload should retire its exact child.  If that child ignored TERM, kill
    # only the PID obtained from this exact launchd label; never match the
    # same-named native iPadOS service by process name.
    if kill -0 "$old_pid" 2>/dev/null; then
        kill -KILL "$old_pid" 2>/dev/null || return 1
    fi
}

retire_desktop_job_pair() {
    local first_plist="$1" first_label="$2" second_plist="$3" second_label="$4"
    local first_pid="" second_pid="" first_unload="" second_unload=""
    local first_remove="" second_remove="" waited=0

    first_pid=$(launchd_job_pid "$first_label")
    second_pid=$(launchd_job_pid "$second_label")

    # These jobs have independent launchd contracts.  Runtime timing on the
    # iPad showed sequential retirement costing 4s + 3s while reloading both
    # took less than one second.  Issue both launchd transitions together,
    # then apply one shared bounded exit window.  PID fallback remains scoped
    # to the exact label snapshots above, never to a process-name match.
    launchctl unload "$first_plist" >/dev/null 2>&1 & first_unload=$!
    launchctl unload "$second_plist" >/dev/null 2>&1 & second_unload=$!
    wait "$first_unload" 2>/dev/null || true
    wait "$second_unload" 2>/dev/null || true
    launchctl remove "$first_label" >/dev/null 2>&1 & first_remove=$!
    launchctl remove "$second_label" >/dev/null 2>&1 & second_remove=$!
    wait "$first_remove" 2>/dev/null || true
    wait "$second_remove" 2>/dev/null || true

    while [ "$waited" -lt 20 ]; do
        if ! { case "$first_pid" in ''|'-'|*[!0-9]*) false ;; *) kill -0 "$first_pid" 2>/dev/null ;; esac; } &&
           ! { case "$second_pid" in ''|'-'|*[!0-9]*) false ;; *) kill -0 "$second_pid" 2>/dev/null ;; esac; }; then
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    case "$first_pid" in
        ''|'-'|*[!0-9]*) ;;
        *) kill -0 "$first_pid" 2>/dev/null &&
               kill -KILL "$first_pid" 2>/dev/null || true ;;
    esac
    case "$second_pid" in
        ''|'-'|*[!0-9]*) ;;
        *) kill -0 "$second_pid" 2>/dev/null &&
               kill -KILL "$second_pid" 2>/dev/null || true ;;
    esac
    return 0
}

load_desktop_job() {
    local plist="$1" label="$2" name="$3" previous_pid="${4:-}"
    [ -f "$plist" ] || {
        log "ERROR: $name launch contract is missing: $plist"
        return 1
    }
    launchctl load "$plist" || {
        log "ERROR: $name launch contract could not be loaded."
        return 1
    }
    wait_for_desktop_job_pid "$label" "$previous_pid" || {
        log "ERROR: $name did not publish a live launchd PID within 10 seconds."
        return 1
    }
    log "$name ready (pid=$DESKTOP_JOB_PID)."
}

ensure_desktop_job() {
    local plist="$1" label="$2" name="$3" pid=""
    if desktop_job_loaded "$label"; then
        pid=$(launchd_job_pid "$label")
        case "$pid" in
            ''|'-'|*[!0-9]*)
                launchctl start "$label" 2>/dev/null || true
                if wait_for_desktop_job_pid "$label" ""; then
                    log "$name resumed from its existing contract (pid=$DESKTOP_JOB_PID)."
                    return 0
                fi
                ;;
            *)
                if kill -0 "$pid" 2>/dev/null; then
                    log "$name already ready (pid=$pid)."
                    return 0
                fi
                ;;
        esac
    fi
    retire_desktop_job "$plist" "$label" || return 1
    load_desktop_job "$plist" "$label" "$name"
}

reload_desktop_job() {
    local plist="$1" label="$2" name="$3" old_pid=""
    old_pid=$(launchd_job_pid "$label")
    retire_desktop_job "$plist" "$label" || return 1
    load_desktop_job "$plist" "$label" "$name" "$old_pid"
}

wait_for_fresh_final_composite() {
    local marker="$1" expected_ws="$2" timeout="${3:-10}"
    local waited=0 stable=0 state='' producer=''
    local graph_state='' graph_ws='' route=''
    while [ "$waited" -lt "$timeout" ]; do
        state=$(awk -F= '$1 == "state" { print $2; exit }' \
            "$FINAL_COMPOSITE_STATE" 2>/dev/null)
        producer=$(awk -F= '$1 == "producer" { print $2; exit }' \
            "$FINAL_COMPOSITE_STATE" 2>/dev/null)
        graph_state=$(awk -F= '$1 == "state" { print $2; exit }' \
            "$WORKSPACE_GRAPH_STATE" 2>/dev/null)
        graph_ws=$(awk -F= '$1 == "windowserver" { print $2; exit }' \
            "$WORKSPACE_GRAPH_STATE" 2>/dev/null)
        if [ -f "$FINAL_COMPOSITE_STATE" ] &&
           [ "$FINAL_COMPOSITE_STATE" -nt "$marker" ] &&
           [ "$state" = ready ] && [ "$producer" = "$expected_ws" ]; then
            route=final-composite
            stable=$((stable + 1))
            if [ "$stable" -ge 2 ]; then
                DESKTOP_PRESENTATION_ROUTE=$route
                return 0
            fi
        else
            stable=0
            route=''
        fi
        sleep 1
        waited=$((waited + 1))
    done
    log "ERROR: desktop presentation did not publish a stable fresh pixel route for WindowServer pid=$expected_ws (final-state=${state:-missing} final-producer=${producer:-missing} graph-state=${graph_state:-missing} graph-windowserver=${graph_ws:-missing})."
    return 1
}

repair_desktop() {
    local original_ws="" final_ws=""
    local composite_marker="$LOGDIR/macws-desktop-repair-composite.$$"
    local repair_started=$SECONDS stage_started=$SECONDS

    original_ws=$(ws_pid)
    case "$original_ws" in
        ''|'-'|*[!0-9]*)
            log "ERROR: desktop repair requires a running WindowServer."
            return 1
            ;;
    esac
    proc_running "$P_INPUTD" && proc_running "$P_DISPLAYD" || {
        log "ERROR: desktop repair requires the live input and display bridges."
        return 1
    }

    log "Repairing desktop services in place; preserving WindowServer pid=$original_ws and ordinary applications."
    # Regenerate the fixed contracts first.  This changes no loaded job and
    # makes recovery work even after an interrupted startup removed or left an
    # older plist on disk.
    write_plists || {
        log "ERROR: desktop launch contracts could not be regenerated."
        return 1
    }

    # DisplayStream is a presentation bridge, not an application owner. Keep
    # its healthy generation: restarting it used to abandon the explicit
    # IOSurface use-count protecting its last WindowServer snapshot. After
    # four repairs all four publisher slots remained permanently in-use, so a
    # replay reached WindowServer with `source=ready published=NO` and every
    # later Repair Desktop unnecessarily escalated to a full session rebuild.
    # Runtime-confirmed in WindowServer.err.previous on 2026-08-23 for
    # requester=58388, sequence=7420. Dock's topology mutation below already
    # asks this live receiver for a fresh authoritative composite; only create
    # the bridge here when its launchd endpoint is actually absent.
    ensure_desktop_job "$DISPLAY_PLIST" "$DISPLAY_LABEL" \
        "DisplayStream bridge" || return 1
    log "TIMING desktop-repair stage=contracts-display seconds=$((SECONDS - stage_started)) total=$((SECONDS - repair_started))"
    stage_started=$SECONDS

    # Preferences and LaunchServices are upstream of IconServices and Dock.
    # Preserve a healthy generation; recreate only a missing/dormant one so
    # existing applications keep their live service connections.
    ensure_cfprefsd_dirhelper_tree || {
        log "ERROR: could not repair the CFPreferences atomic-write hierarchy."
        return 1
    }
    ensure_desktop_job "$CFPREFSD_DAEMON_PLIST" \
        "$CFPREFSD_DAEMON_LABEL" "macOS CFPreferences daemon" || return 1
    ensure_desktop_job "$CFPREFSD_AGENT_PLIST" \
        "$CFPREFSD_AGENT_LABEL" "macOS CFPreferences agent" || return 1
    ensure_desktop_job "$CFPREFSD_MOBILE_AGENT_PLIST" \
        "$CFPREFSD_MOBILE_AGENT_LABEL" \
        "uid-501 macOS CFPreferences agent" || return 1
    verify_preferences_persistence || return 1
    verify_mobile_preferences_persistence || return 1
    log "TIMING desktop-repair stage=preferences seconds=$((SECONDS - stage_started)) total=$((SECONDS - repair_started))"
    stage_started=$SECONDS
    ensure_desktop_job "$LSD_SYSTEM_PLIST" "$LSD_SYSTEM_LABEL" \
        "macOS LaunchServices system store" || return 1
    ensure_desktop_job "$LSD_PLIST" "$LSD_LABEL" \
        "macOS LaunchServices session service" || return 1
    verify_launchservices_database_for_desktop_repair || return 1
    ensure_desktop_job "$PBOARD_PLIST" "$PBOARD_LABEL" \
        "macOS pasteboard service" || return 1
    publish_desktop_operation_services || return 1
    log "TIMING desktop-repair stage=launchservices-pasteboard seconds=$((SECONDS - stage_started)) total=$((SECONDS - repair_started))"
    stage_started=$SECONDS

    # Icon question marks are stale/fallback Dock tiles, not a reason to
    # fabricate images.  Recreate the two real Ventura IconServices endpoints
    # and then restart Dock so it resolves every tile from those endpoints.
    local icon_stage_started=$SECONDS csnamed_retire_task="" \
        coreservices_retire_task="" \
        pkd_retire_task="" ql_retire_task="" quicklookd_retire_task="" \
        quicklook_satellite_retire_task=""
    # The named-data launch contract is independent from both IconServices
    # contracts while retiring.  Start its exact-label retirement alongside
    # the IconServices pair, then publish all three fresh endpoints before
    # Dock is allowed to restart.
    retire_desktop_job "$CSNAMEDDATAD_PLIST" "$CSNAMEDDATAD_LABEL" &
    csnamed_retire_task=$!
    retire_desktop_job "$CORESERVICESD_PLIST" "$CORESERVICESD_LABEL" &
    coreservices_retire_task=$!
    retire_desktop_job "$PLUGINKIT_PKD_PLIST" "$PLUGINKIT_PKD_LABEL" &
    pkd_retire_task=$!
    retire_desktop_job "$QUICKLOOK_THUMBNAILS_PLIST" \
        "$QUICKLOOK_THUMBNAILS_LABEL" &
    ql_retire_task=$!
    retire_desktop_job "$QUICKLOOKD_PLIST" "$QUICKLOOKD_LABEL" &
    quicklookd_retire_task=$!
    retire_desktop_job "$QUICKLOOK_SATELLITE_PLIST" \
        "$QUICKLOOK_SATELLITE_LABEL" &
    quicklook_satellite_retire_task=$!
    retire_desktop_job_pair \
        "$ICONSERVICESAGENT_PLIST" "$ICONSERVICESAGENT_LABEL" \
        "$ICONSERVICESD_PLIST" "$ICONSERVICESD_LABEL" || {
            wait "$csnamed_retire_task" 2>/dev/null || true
            wait "$coreservices_retire_task" 2>/dev/null || true
            wait "$pkd_retire_task" 2>/dev/null || true
            wait "$ql_retire_task" 2>/dev/null || true
            wait "$quicklookd_retire_task" 2>/dev/null || true
            wait "$quicklook_satellite_retire_task" 2>/dev/null || true
            return 1
        }
    wait "$csnamed_retire_task" || return 1
    wait "$coreservices_retire_task" || return 1
    wait "$pkd_retire_task" || return 1
    wait "$ql_retire_task" || return 1
    wait "$quicklookd_retire_task" || return 1
    wait "$quicklook_satellite_retire_task" || return 1
    ensure_iconservices_store_tree || {
        log "ERROR: could not prepare the IconServices rendition store."
        return 1
    }
    log "TIMING desktop-repair detail=iconservices-nameddata-retire seconds=$((SECONDS - icon_stage_started))"
    icon_stage_started=$SECONDS
    rm -f "$LOGDIR/iconservicesd.log" "$LOGDIR/iconservicesagent.log"
    load_desktop_job "$ICONSERVICESD_PLIST" "$ICONSERVICESD_LABEL" \
        "macOS IconServices store" || return 1
    load_desktop_job "$ICONSERVICESAGENT_PLIST" \
        "$ICONSERVICESAGENT_LABEL" "macOS IconServices agent" || return 1
    load_desktop_job "$PLUGINKIT_PKD_PLIST" "$PLUGINKIT_PKD_LABEL" \
        "macOS PluginKit database service" || return 1
    load_desktop_job "$QUICKLOOK_THUMBNAILS_PLIST" \
        "$QUICKLOOK_THUMBNAILS_LABEL" \
        "macOS Quick Look thumbnail agent" || return 1
    load_desktop_job "$QUICKLOOKD_PLIST" "$QUICKLOOKD_LABEL" \
        "macOS Quick Look preview service" || return 1
    load_desktop_job "$QUICKLOOK_SATELLITE_PLIST" \
        "$QUICKLOOK_SATELLITE_LABEL" \
        "macOS Quick Look legacy generator satellite" || return 1
    load_desktop_job "$CSNAMEDDATAD_PLIST" "$CSNAMEDDATAD_LABEL" \
        "Dock CarbonCore named-data service" || return 1
    load_desktop_job "$CORESERVICESD_PLIST" "$CORESERVICESD_LABEL" \
        "CarbonCore seed service" || return 1
    log "TIMING desktop-repair detail=iconservices-nameddata-load seconds=$((SECONDS - icon_stage_started))"
    icon_stage_started=$SECONDS
    sleep 2
        desktop_job_loaded "$ICONSERVICESD_LABEL" &&
        desktop_job_loaded "$ICONSERVICESAGENT_LABEL" &&
        desktop_job_loaded "$PLUGINKIT_PKD_LABEL" &&
        desktop_job_loaded "$QUICKLOOK_THUMBNAILS_LABEL" &&
        desktop_job_loaded "$QUICKLOOKD_LABEL" &&
        desktop_job_loaded "$QUICKLOOK_SATELLITE_LABEL" &&
        desktop_job_loaded "$CSNAMEDDATAD_LABEL" &&
        desktop_job_loaded "$CORESERVICESD_LABEL" || {
            log "ERROR: IconServices/Quick Look/named-data did not survive its readiness window."
            return 1
        }
    log "TIMING desktop-repair detail=iconservices-nameddata-survival seconds=$((SECONDS - icon_stage_started))"
    log "TIMING desktop-repair stage=icons-nameddata seconds=$((SECONDS - stage_started)) total=$((SECONDS - repair_started))"
    stage_started=$SECONDS

    : > "$composite_marker" || return 1

    # Finder owns desktop items but may have live user windows.  Keep that
    # exact process if it exists; only launch the production job when absent.
    if proc_running "$P_FINDER"; then
        log "Finder is live; preserving its windows."
    else
        ensure_desktop_job "$FINDER_DESKTOP_PLIST" \
            "$FINDER_DESKTOP_LABEL" "Finder desktop owner" || return 1
    fi

    reload_desktop_job "$DOCK_PLIST" "$DOCK_LABEL" \
        "Dock and desktop-picture owner" || return 1
    reload_desktop_job "$SYSTEMUI_PLIST" "$SYSTEMUI_LABEL" \
        "macOS SystemUIServer" || return 1
    reload_desktop_job "$CONTROL_CENTER_PLIST" "$CONTROL_CENTER_LABEL" \
        "macOS Control Center" || return 1
    apply_workspace_wallpaper || return 1
    wait_for_desktop_input_route || return 1
    log "TIMING desktop-repair stage=desktop-agents-wallpaper seconds=$((SECONDS - stage_started)) total=$((SECONDS - repair_started))"
    stage_started=$SECONDS

    final_ws=$(ws_pid)
    if [ "$final_ws" != "$original_ws" ] ||
       ! kill -0 "$original_ws" 2>/dev/null; then
        log "ERROR: WindowServer changed during desktop repair ($original_ws -> ${final_ws:-missing})."
        return 1
    fi
    for label in "$ICONSERVICESD_LABEL" "$ICONSERVICESAGENT_LABEL" \
                 "$PLUGINKIT_PKD_LABEL" \
                 "$QUICKLOOK_THUMBNAILS_LABEL" \
                 "$QUICKLOOKD_LABEL" \
                 "$QUICKLOOK_SATELLITE_LABEL" \
                 "$CSNAMEDDATAD_LABEL" "$CORESERVICESD_LABEL" \
                 "$DOCK_LABEL" "$SYSTEMUI_LABEL" \
                 "$CONTROL_CENTER_LABEL"; do
        desktop_job_loaded "$label" || {
            log "ERROR: repaired desktop contract is not loaded: $label"
            return 1
        }
    done
    if ! wait_for_fresh_final_composite "$composite_marker" \
            "$original_ws" 12; then
        rm -f "$composite_marker"
        log "Desktop agents recovered, but the WindowServer final compositor is unhealthy; requesting a controlled full session rebuild."
        return 2
    fi
    rm -f "$composite_marker"
    log "TIMING desktop-repair stage=final-composite seconds=$((SECONDS - stage_started)) total=$((SECONDS - repair_started))"
    log "Desktop repair complete: WindowServer pid=$original_ws preserved; icons, Dock, wallpaper and menu services are live (presentation=${DESKTOP_PRESENTATION_ROUTE:-unknown})."
}

rebuild_desktop_session() {
    local original_ws="" current_ws="" rebuilt_ws="" stable=0 waited=0
    local state="" producer="" dock_pid="" endpoint=""
    local composite_marker="$LOGDIR/macws-desktop-session-composite.$$"
    local rebuild_started=$SECONDS

    original_ws=$(ws_pid)
    case "$original_ws" in
        ''|'-'|*[!0-9]*)
            log "ERROR: desktop-session rebuild requires a running WindowServer."
            return 1
            ;;
    esac
    desktop_job_loaded "$WATCHDOG_LABEL" || {
        # The session-only path briefly pauses this production safety owner
        # while it performs the same dependency transaction synchronously,
        # then must rearm it. An absent initial owner is therefore a typed
        # failure for the caller's full cold-start fallback, not permission to
        # leave a replacement desktop without lifecycle/thermal observation.
        log "ERROR: desktop-session rebuild requires the live lifecycle watchdog."
        return 1
    }

    : > "$composite_marker" || return 1
    log "Rebuilding only the WindowServer desktop generation (old pid=$original_ws); persistent catalogs, trust state and mounted assets remain live."

    # A client cannot reuse a dead CGS connection. Retire the exact established
    # WS-dependent set before changing the server generation, then republish
    # the service endpoints which WindowServer contacts synchronously during
    # startup. Runtime-confirmed by the first session-only test: starting WS
    # first and letting the ten-second watchdog poll unload/reload lsd later
    # left the new server without a final composite for 149 seconds. The cold
    # production order publishes lsd/SharedFileList/input first; preserve that
    # causal order here while reusing the existing databases and trust state.
    stop_ws_dependents preserve-catalog-services
    rm -f "$EXPERIMENTAL_CAPTURE" "$EXPERIMENTAL_CAPTURE_DONE"
    publish_settings_service_contracts || {
        rm -f "$composite_marker"
        log "ERROR: settings service contracts were not ready for the replacement WindowServer."
        return 1
    }
    publish_desktop_operation_services || {
        rm -f "$composite_marker"
        log "ERROR: desktop-operation contracts were not ready for the replacement WindowServer."
        return 1
    }
    ensure_desktop_job "$LSD_SYSTEM_PLIST" "$LSD_SYSTEM_LABEL" \
        "macOS LaunchServices system store" || {
        rm -f "$composite_marker"; return 1;
    }
    ensure_desktop_job "$LSD_PLIST" "$LSD_LABEL" \
        "macOS LaunchServices session service" || {
        rm -f "$composite_marker"; return 1;
    }
    verify_launchservices_database_for_desktop_repair || {
        rm -f "$composite_marker"; return 1;
    }
    start_sharedfilelistd || {
        rm -f "$composite_marker"; return 1;
    }
    ensure_desktop_job "$ICONSERVICESD_PLIST" "$ICONSERVICESD_LABEL" \
        "macOS IconServices store" || {
        rm -f "$composite_marker"; return 1;
    }
    ensure_desktop_job "$ICONSERVICESAGENT_PLIST" \
        "$ICONSERVICESAGENT_LABEL" "macOS IconServices agent" || {
        rm -f "$composite_marker"; return 1;
    }
    ensure_desktop_job "$PLUGINKIT_PKD_PLIST" "$PLUGINKIT_PKD_LABEL" \
        "macOS PluginKit database service" || {
        rm -f "$composite_marker"; return 1;
    }
    ensure_desktop_job "$QUICKLOOK_THUMBNAILS_PLIST" \
        "$QUICKLOOK_THUMBNAILS_LABEL" \
        "macOS Quick Look thumbnail agent" || {
        rm -f "$composite_marker"; return 1;
    }
    ensure_desktop_job "$QUICKLOOKD_PLIST" "$QUICKLOOKD_LABEL" \
        "macOS Quick Look preview service" || {
        rm -f "$composite_marker"; return 1;
    }
    ensure_desktop_job "$QUICKLOOK_SATELLITE_PLIST" \
        "$QUICKLOOK_SATELLITE_LABEL" \
        "macOS Quick Look legacy generator satellite" || {
        rm -f "$composite_marker"; return 1;
    }
    ensure_desktop_job "$CSNAMEDDATAD_PLIST" "$CSNAMEDDATAD_LABEL" \
        "Dock CarbonCore named-data service" || {
        rm -f "$composite_marker"; return 1;
    }
    ensure_desktop_job "$CORESERVICESD_PLIST" "$CORESERVICESD_LABEL" \
        "CarbonCore seed service" || {
        rm -f "$composite_marker"; return 1;
    }
    ensure_desktop_job "$INPUT_PLIST" "$INPUT_LABEL" \
        "macOS input bridge" || {
        rm -f "$composite_marker"; return 1;
    }
    ensure_autosignd_ready || {
        rm -f "$composite_marker"
        log "ERROR: autosignd was not ready before the WindowServer replacement."
        return 1
    }

    # From this point the explicit transaction owns the generation change, so
    # pause the watchdog to prevent a second recovery owner from racing these
    # already ordered jobs. A new mandatory watchdog is armed only after the
    # replacement desktop passes its service setup below.
    stop_watchdogs
    kill -KILL "$original_ws" 2>/dev/null || {
        rm -f "$composite_marker"
        log "ERROR: could not retire unhealthy WindowServer pid=$original_ws."
        start_watchdog >/dev/null 2>&1 || true
        return 1
    }
    launchctl start "$WINDOWSERVER_LABEL" 2>/dev/null || true

    waited=0
    stable=0
    while [ "$waited" -lt 30 ]; do
        sleep 1
        waited=$((waited + 1))
        current_ws=$(ws_pid)
        case "$current_ws" in
            ''|'-'|*[!0-9]*|"$original_ws") stable=0; continue ;;
        esac
        rebuilt_ws="$current_ws"
        stable=$((stable + 1))
        [ "$stable" -ge 2 ] && break
    done
    if [ "$stable" -lt 2 ]; then
        rm -f "$composite_marker"
        log "ERROR: replacement WindowServer did not publish a stable PID within 30 seconds."
        start_watchdog >/dev/null 2>&1 || true
        return 1
    fi
    if ! start_ws_dependents_after_replacement "$original_ws" "$rebuilt_ws"; then
        rm -f "$composite_marker"
        log "ERROR: replacement WindowServer clients did not reconnect."
        start_watchdog >/dev/null 2>&1 || true
        return 1
    fi
    rebuilt_ws="$RECOVERED_WS_PID"
    if ! start_watchdog; then
        rm -f "$composite_marker"
        log "ERROR: mandatory lifecycle watchdog could not be rearmed after desktop-session rebuild."
        return 1
    fi

    # Require the complete user-visible postcondition rather than a process log
    # message: a replacement WS, current Dock input endpoint, all desktop jobs,
    # and two consecutive fresh authoritative final-composite observations.
    # This is the same pixel invariant used by the in-place repair and cannot
    # succeed on the layer-only fallback that lacks native backdrop materials.
    waited=0
    stable=0
    while [ "$waited" -lt 90 ]; do
        sleep 1
        waited=$((waited + 1))
        current_ws=$(ws_pid)
        case "$current_ws" in
            ''|'-'|*[!0-9]*|"$original_ws") stable=0; continue ;;
        esac
        if [ -n "$rebuilt_ws" ] && [ "$current_ws" != "$rebuilt_ws" ]; then
            log "Desktop-session replacement changed during recovery ($rebuilt_ws -> $current_ws); validating the newest generation."
            stable=0
        fi
        rebuilt_ws="$current_ws"

        dock_pid=$(launchd_job_pid "$DOCK_LABEL")
        case "$dock_pid" in
            ''|'-'|*[!0-9]*) stable=0; continue ;;
        esac
        endpoint="$ROOTFS/private/tmp/macws_app_input.$dock_pid.sock"
        if ! kill -0 "$rebuilt_ws" 2>/dev/null ||
           ! kill -0 "$dock_pid" 2>/dev/null ||
           [ ! -S "$ROOTFS/private/tmp/macws_host_input.sock" ] ||
           [ ! -S "$endpoint" ] ||
           ! proc_running "$P_INPUTD" || ! proc_running "$P_DISPLAYD"; then
            stable=0
            continue
        fi
        state=$(awk -F= '$1 == "state" { print $2; exit }' \
            "$FINAL_COMPOSITE_STATE" 2>/dev/null)
        producer=$(awk -F= '$1 == "producer" { print $2; exit }' \
            "$FINAL_COMPOSITE_STATE" 2>/dev/null)
        if [ -f "$FINAL_COMPOSITE_STATE" ] &&
           [ "$FINAL_COMPOSITE_STATE" -nt "$composite_marker" ] &&
           [ "$state" = ready ] && [ "$producer" = "$rebuilt_ws" ] &&
           desktop_job_loaded "$ICONSERVICESD_LABEL" &&
           desktop_job_loaded "$ICONSERVICESAGENT_LABEL" &&
           desktop_job_loaded "$CSNAMEDDATAD_LABEL" &&
           desktop_job_loaded "$CORESERVICESD_LABEL" &&
           desktop_job_loaded "$DOCK_LABEL" &&
           desktop_job_loaded "$SYSTEMUI_LABEL" &&
           desktop_job_loaded "$CONTROL_CENTER_LABEL"; then
            stable=$((stable + 1))
            if [ "$stable" -ge 2 ]; then
                rm -f "$composite_marker"
                log "Desktop-session rebuild complete: WindowServer $original_ws -> $rebuilt_ws, Dock pid=$dock_pid, presentation=final-composite, seconds=$((SECONDS - rebuild_started))."
                return 0
            fi
        else
            stable=0
        fi
    done

    rm -f "$composite_marker"
    log "ERROR: minimal desktop-session rebuild did not reach its pixel/input postcondition within 90 seconds (WindowServer ${original_ws}->${rebuilt_ws:-missing}, final-state=${state:-missing}, final-producer=${producer:-missing}, Dock=${dock_pid:-missing})."
    return 1
}

toggle_native_launchpad() {
    [ -x "$ROOTFS$WORKSPACECTL_BIN" ] || {
        log "ERROR: native workspace controller is missing at $WORKSPACECTL_BIN"
        return 1
    }
    proc_running "$P_WINDOWSERVER" && proc_running "$P_DOCK" || {
        log "ERROR: Launchpad requires a running WindowServer and Dock."
        return 1
    }
    "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" show-launchpad
}

start_macos() {
    local ws_log_start_line=1 waited=0 macos_started=$SECONDS macos_stage_started=$SECONDS
    if [ -f "$LOGDIR/WindowServer.err" ]; then
        ws_log_start_line=$(( $(wc -l < "$LOGDIR/WindowServer.err") + 1 ))
    fi
    # SystemStatus clients immediately enumerate and register every subscribed
    # domain. Runtime sampling showed that starting WindowServer before
    # the private macOS SystemStatus endpoints exist leaves several NSXPC
    # queues serializing registrations to a disconnected endpoint. Register
    # and prove the stock macOS daemon under its collision-free private names
    # first; this is dependency ordering, not a client bypass.
    log "Starting macOS systemstatusd before WindowServer clients..."
    rm -f "$LOGDIR/systemstatusd.out" "$LOGDIR/systemstatusd.err"
    launchctl load "$SYSTEMSTATUSD_PLIST" || return 1
    waited=0
    while ! proc_running "$P_SYSTEMSTATUSD" && [ "$waited" -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    proc_running "$P_SYSTEMSTATUSD" || {
        log "ERROR: macOS systemstatusd did not start. See $LOGDIR/systemstatusd.err"
        return 1
    }

    # The stock fontd is not healthy in this chroot merely because its PID is
    # present: a runtime sample on 2026-08-06 found no original service main
    # thread, only CydiaSubstrate exception/signal workers, while clients
    # repeatedly logged "failed to get common fonts".  A controlled cold
    # Terminal A/B measured first-window latency at 8.463 s with that endpoint
    # present versus 3.361 s after unloading it.  Leave the stale job unloaded
    # so AppKit immediately selects its working per-process static registry.
    # This is dependency selection backed by a visible-window witness, not a
    # check bypass; the plist remains packaged for future root-cause work.
    launchctl unload "$FONTD_PLIST" >/dev/null 2>&1 || true
    log "Using AppKit's per-process static font registry (shared fontd disabled)."

    log "Publishing private macOS CFPreferences daemon and login agent..."
    ensure_cfprefsd_dirhelper_tree || {
        log "ERROR: could not prepare the CFPreferences atomic-write hierarchy."
        return 1
    }
    rm -f "$LOGDIR/cfprefsd-daemon.log" "$LOGDIR/cfprefsd-agent.log" \
        "$LOGDIR/cfprefsd-mobile-agent.log"
    launchctl load "$CFPREFSD_DAEMON_PLIST" || return 1
    launchctl load "$CFPREFSD_AGENT_PLIST" || return 1
    launchctl load "$CFPREFSD_MOBILE_AGENT_PLIST" || return 1
    launchctl list "$CFPREFSD_DAEMON_LABEL" >/dev/null 2>&1 || {
        log "ERROR: private macOS cfprefsd daemon contract was not registered."
        return 1
    }
    launchctl list "$CFPREFSD_AGENT_LABEL" >/dev/null 2>&1 || {
        log "ERROR: private macOS cfprefsd agent contract was not registered."
        return 1
    }
    launchctl list "$CFPREFSD_MOBILE_AGENT_LABEL" >/dev/null 2>&1 || {
        log "ERROR: uid-501 macOS cfprefsd agent contract was not registered."
        return 1
    }
    verify_preferences_persistence || return 1
    verify_mobile_preferences_persistence || return 1

    # Ventura's AudioComponentRegistrar must own a collision-free endpoint:
    # runtime-confirmed on 2026-09-15, the native iPadOS registrar returned its
    # iOS catalog and therefore no DefaultOutput component. The private stock
    # registrar returns Ventura's component, while coreaudiod supplies its
    # Loopback render unit. macwsaudiooutd consumes the render callback ring in
    # native iOS context and hands it to mediaserverd/the physical speaker.
    log "Publishing the private macOS audio catalog and native output bridge..."
    rm -f "$LOGDIR/macws-audio-component-registrar.log" \
          "$LOGDIR/macws-coreaudiod.log" \
          "$LOGDIR/macws-audio-output.log"
    launchctl load "$AUDIO_COMPONENT_REGISTRAR_PLIST" || return 1
    launchctl load "$COREAUDIOD_PLIST" || return 1
    launchctl load "$AUDIO_OUTPUT_PLIST" || return 1
    for label in "$AUDIO_COMPONENT_REGISTRAR_LABEL" "$COREAUDIOD_LABEL" \
                 "$AUDIO_OUTPUT_LABEL"; do
        launchctl list "$label" >/dev/null 2>&1 || {
            log "ERROR: audio launch contract was not registered: $label"
            return 1
        }
    done
    # The Adaptive registrar is otherwise dormant until the first renderer;
    # prime its real catalog before Electron performs AudioComponentFindNext.
    # Runtime-confirmed: Dopamine's launchctl load publishes these jobs in
    # user/501, exposed as user/foreground. A bare label is not a kickstart
    # service-target and exits 64 before the registrar can serve any client.
    if ! launchctl kickstart \
            "user/foreground/$AUDIO_COMPONENT_REGISTRAR_LABEL" \
            >> "$LOGDIR/macws-audio-component-registrar.log" 2>&1; then
        log "ERROR: private macOS audio catalog could not be started."
        tail -n 10 "$LOGDIR/macws-audio-component-registrar.log" 2>/dev/null || true
        return 1
    fi
    log "TIMING start-macos stage=status-preferences seconds=$((SECONDS - macos_stage_started)) total=$((SECONDS - macos_started))"
    macos_stage_started=$SECONDS

    # Office's serializer and applications do not write the volume-license
    # plist in-process. They synchronously call the stock privileged helper's
    # Mach service. A normal macOS boot publishes that service from the
    # helper's LaunchDaemon, but the chroot has no independent launchd domain.
    # Publish the unmodified protocol in the outer bootstrap and execute the
    # real helper through launchdchrootexec. This is optional when Office is
    # not installed and must never make the base desktop unavailable.
    if [ -x "$ROOTFS$OFFICE_LICENSING_BIN" ]; then
        if [ ! -f "$OFFICE_LICENSING_PLIST" ]; then
            log "WARNING: Office licensing helper is installed but its launch contract is missing."
        else
            log "Publishing Microsoft Office volume-licensing service..."
            rm -f "$LOGDIR/office-licensing.log"
            if launchctl load "$OFFICE_LICENSING_PLIST"; then
                # MachServices registration is the readiness contract.  The
                # stock helper is allowed to exit after an idle request and
                # launchd will reactivate it for the next Office client, so
                # waiting for a persistent PID would add ten seconds to every
                # desktop start and misreport a healthy on-demand service.
                log "Microsoft Office volume-licensing service registered (on demand)."
            else
                log "WARNING: Office licensing service could not be registered."
                tail -n 20 "$LOGDIR/office-licensing.log" 2>/dev/null || true
            fi
        fi
    fi

    log "Publishing the private macOS LaunchServices system store and session catalog..."
    ensure_launchservices_session_user_dir || {
        log "ERROR: could not prepare the isolated LaunchServices session store."
        return 1
    }
    rm -f "$LOGDIR/lsd-system.log" "$LOGDIR/lsd-session.log"
    launchctl load "$LSD_SYSTEM_PLIST" || return 1
    launchctl list "$LSD_SYSTEM_LABEL" >/dev/null 2>&1 || {
        log "ERROR: private macOS system lsd contract was not registered."
        return 1
    }
    launchctl load "$LSD_PLIST" || return 1
    launchctl list "$LSD_LABEL" >/dev/null 2>&1 || {
        log "ERROR: private macOS session lsd contract was not registered."
        return 1
    }

    # Register the stock IconServices store and root-session agent before
    # lsregister asks LaunchServices to resolve application resources.  Merely
    # leaving these services to the iOS bootstrap namespace produced an empty
    # Launchpad and transparent Dock tiles; clients were speaking to the wrong
    # platform contract.  Both processes must remain alive, not merely have a
    # launchd label, before the application catalog scan begins.
    log "Starting private macOS IconServices store and session agent..."
    ensure_iconservices_store_tree || {
        log "ERROR: could not prepare the IconServices rendition store."
        return 1
    }
    rm -f "$LOGDIR/iconservicesd.log" "$LOGDIR/iconservicesagent.log"
    launchctl load "$ICONSERVICESD_PLIST" || return 1
    launchctl load "$ICONSERVICESAGENT_PLIST" || return 1
    rm -f "$LOGDIR/pluginkit-pkd.log"
    launchctl load "$PLUGINKIT_PKD_PLIST" || return 1
    launchctl list "$PLUGINKIT_PKD_LABEL" >/dev/null 2>&1 || {
        log "ERROR: private Ventura PluginKit contract was not registered."
        return 1
    }
    rm -f "$LOGDIR/quicklook-thumbnails.log"
    launchctl load "$QUICKLOOK_THUMBNAILS_PLIST" || return 1
    launchctl list "$QUICKLOOK_THUMBNAILS_LABEL" >/dev/null 2>&1 || {
        log "ERROR: private Ventura Quick Look thumbnail contract was not registered."
        return 1
    }
    rm -f "$LOGDIR/quicklookd.log"
    launchctl load "$QUICKLOOKD_PLIST" || return 1
    launchctl list "$QUICKLOOKD_LABEL" >/dev/null 2>&1 || {
        log "ERROR: private Ventura Quick Look preview contract was not registered."
        return 1
    }
    rm -f "$LOGDIR/quicklook-satellite.log"
    launchctl load "$QUICKLOOK_SATELLITE_PLIST" || return 1
    launchctl list "$QUICKLOOK_SATELLITE_LABEL" >/dev/null 2>&1 || {
        log "ERROR: private Ventura Quick Look satellite contract was not registered."
        return 1
    }

    # CarbonCore exposes named-data and CSSeed through two different stock
    # services.  Dock consumes the first; CoreDrag requires the second before
    # Finder can create a native file-drag session. Start both with the catalog
    # services and share one bounded liveness witness.
    log "Publishing CarbonCore named-data and CSSeed services..."
    rm -f "$LOGDIR/csnameddatad.log" "$LOGDIR/coreservicesd.log"
    launchctl load "$CSNAMEDDATAD_PLIST" || return 1
    launchctl list "$CSNAMEDDATAD_LABEL" >/dev/null 2>&1 || {
        log "ERROR: CarbonCore named-data MachService contract was not registered."
        return 1
    }
    launchctl load "$CORESERVICESD_PLIST" || return 1
    launchctl list "$CORESERVICESD_LABEL" >/dev/null 2>&1 || {
        log "ERROR: CarbonCore CSSeed MachService contract was not registered."
        return 1
    }
    waited=0
    while [ "$waited" -lt 10 ]; do
        proc_running "$P_ICONSERVICESD" &&
            proc_running "$P_ICONSERVICESAGENT" &&
            proc_running "$P_CSNAMEDDATAD" &&
            proc_running "$P_CORESERVICESD" && break
        sleep 1
        waited=$((waited + 1))
    done
    proc_running "$P_ICONSERVICESD" || {
        log "ERROR: macOS iconservicesd did not stay alive. See $LOGDIR/iconservicesd.log"
        return 1
    }
    proc_running "$P_ICONSERVICESAGENT" || {
        log "ERROR: macOS iconservicesagent did not stay alive. See $LOGDIR/iconservicesagent.log"
        return 1
    }
    proc_running "$P_CSNAMEDDATAD" || {
        log "ERROR: CarbonCore named-data service did not reach a live process."
        tail -n 30 "$LOGDIR/csnameddatad.log" 2>/dev/null || true
        return 1
    }
    proc_running "$P_CORESERVICESD" || {
        log "ERROR: CarbonCore CSSeed service did not reach a live process."
        tail -n 30 "$LOGDIR/coreservicesd.log" 2>/dev/null || true
        return 1
    }
    # The former quarantine failure happened after the process was briefly
    # visible, so a single ps sample falsely declared readiness.  Require the
    # all three prerequisites to survive beyond that startup window.
    sleep 2
    proc_running "$P_ICONSERVICESD" &&
        proc_running "$P_ICONSERVICESAGENT" &&
        proc_running "$P_CSNAMEDDATAD" &&
        proc_running "$P_CORESERVICESD" || {
            log "ERROR: a catalog prerequisite exited during startup."
            tail -n 20 "$LOGDIR/iconservicesagent.log" 2>/dev/null || true
            tail -n 20 "$LOGDIR/csnameddatad.log" 2>/dev/null || true
            tail -n 20 "$LOGDIR/coreservicesd.log" 2>/dev/null || true
            return 1
        }
    log "Private macOS IconServices endpoints ready."
    # A registered launchd label is not a readiness witness: on the 2026-08-13
    # cold start, csnameddatad's persistent signature survived while its
    # reboot-volatile arm64e CDHash did not. launchd published the MachService
    # and repeatedly recorded exit status 9, while Dock's main thread blocked
    # in CarbonCore `_CSGetNamedData` and could not drain native gesture work.
    # `restore_cold_boot_trust` now restores the exact executable hash above;
    # require the real process to survive its former AMFI failure window too.
    log "CarbonCore named-data and CSSeed endpoints ready."
    log "TIMING start-macos stage=catalog-services seconds=$((SECONDS - macos_stage_started)) total=$((SECONDS - macos_started))"
    macos_stage_started=$SECONDS

    seed_launchservices_database || return 1
    log "TIMING start-macos stage=launchservices-catalog seconds=$((SECONDS - macos_stage_started)) total=$((SECONDS - macos_started))"
    macos_stage_started=$SECONDS

    # System Settings' first visible pane is a stock ExtensionKit scene.  Its
    # host synchronously resolves ViewBridgeAuxiliary and HIServices before
    # Appearance is launched, so all three collision-free service contracts
    # must exist before any GUI application can enter that dependency chain.
    log "Publishing macOS ViewBridge, ExtensionKit and HIServices services..."
    publish_settings_service_contracts || return 1
    log "Publishing Ventura authorization and DesktopServices helpers..."
    publish_desktop_operation_services || return 1

    log "Loading legacy macOS launchservicesd..."
    launchctl load "$LAUNCHSERVICESD_PLIST" || return 1
    # The launchd contract can be registered even when the loader's dylib is
    # absent from Dopamine's reboot-volatile trustcache. Runtime LLDB on the
    # 2026-08-09 cold boot showed WindowServer then blocking synchronously in
    # LSClientToServerConnection before it published the SkyLight session
    # port. Require the real payload process to survive first; a merely loaded
    # launchd label is not a readiness witness.
    waited=0
    while ! proc_running "$P_LAUNCHSERVICESD" && [ "$waited" -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    proc_running "$P_LAUNCHSERVICESD" || {
        log "ERROR: legacy macOS launchservicesd did not reach a live process."
        tail -n 30 "$LOGDIR/launchservicesd.err" 2>/dev/null ||
            tail -n 30 /var/jb/var/mobile/launchservicesd.err 2>/dev/null || true
        return 1
    }
    sleep 2
    proc_running "$P_LAUNCHSERVICESD" || {
        log "ERROR: legacy macOS launchservicesd exited during its readiness window."
        tail -n 30 /var/jb/var/mobile/launchservicesd.err 2>/dev/null || true
        return 1
    }
    log "Legacy macOS LaunchServices endpoint ready."

    start_sharedfilelistd || return 1
    log "Publishing private Ventura file-coordination services..."
    [ -f "$FILECOORDINATION_PLIST" ] || {
        log "ERROR: packaged Ventura file-coordination launch contract is missing."
        return 1
    }
    launchctl load "$FILECOORDINATION_PLIST" || return 1
    launchctl list "$FILECOORDINATION_LABEL" >/dev/null 2>&1 || {
        log "ERROR: Ventura file-coordination contract was not registered."
        return 1
    }
    log "TIMING start-macos stage=settings-legacy-sharedfile seconds=$((SECONDS - macos_stage_started)) total=$((SECONDS - macos_started))"
    macos_stage_started=$SECONDS

    log "Loading input bridge and WindowServer..."
    launchctl load "$INPUT_PLIST" || return 1
    launchctl remove "$WINDOWSERVER_LEGACY_LABEL" 2>/dev/null
    launchctl load "$WINDOWSERVER_PLIST" || return 1
    log "Waiting for WindowServer graphics initialization before GUI clients..."
    wait_for_initial_ws_ready "$ws_log_start_line" || return 1
    log "TIMING start-macos stage=windowserver seconds=$((SECONDS - macos_stage_started)) total=$((SECONDS - macos_started))"
    macos_stage_started=$SECONDS

    # Maps uses Ventura CoreLocationAgent and the four Ventura desktop
    # locationd protocols.  iPadOS publishes colliding but wire-incompatible
    # services; libmachook maps the stock macOS peers together under private
    # names.  Publish the on-demand jobs only after both LaunchServices and
    # WindowServer are ready because CoreLocationAgent is an AppKit process.
    log "Publishing private Ventura CoreLocation services..."
    ensure_locationd_dirhelper_tree || {
        log "ERROR: could not prepare Ventura locationd's uid-205 cache tree."
        return 1
    }
    [ -f "$MACOS_LOCATIOND_PLIST" ] &&
        [ -f "$CORELOCATIONAGENT_PLIST" ] &&
        [ -f "$LOCATIONBRIDGE_PLIST" ] || {
        log "ERROR: packaged Ventura CoreLocation launch contracts are missing."
        return 1
    }
    rm -f "$LOGDIR/macos-locationd.log" "$LOGDIR/corelocationagent.log" \
          "$LOGDIR/macwslocationd.log"
    launchctl load "$MACOS_LOCATIOND_PLIST" || return 1
    launchctl load "$CORELOCATIONAGENT_PLIST" || return 1
    launchctl list "$MACOS_LOCATIOND_LABEL" >/dev/null 2>&1 || {
        log "ERROR: Ventura locationd contract was not registered."
        return 1
    }
    launchctl list "$CORELOCATIONAGENT_LABEL" >/dev/null 2>&1 || {
        log "ERROR: CoreLocationAgent contract was not registered."
        return 1
    }
    log "Private Ventura CoreLocation contracts ready."

    log "Starting DisplayStream IOSurface bridge..."
    launchctl load "$DISPLAY_PLIST" || return 1

    log "Starting macOS pasteboard service (launchd job '$PBOARD_LABEL')..."
    rm -f "$LOGDIR/pboard.log"
    launchctl load "$PBOARD_PLIST" || return 1
    waited=0
    while ! proc_running "$P_PBOARD" && [ "$waited" -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    proc_running "$P_PBOARD" || {
        log "ERROR: macOS pboard process did not start."
        return 1
    }

    log "Starting iOS/macOS clipboard and file bridge..."
    launchctl load "$INTEROP_PLIST" || return 1

    # CLLocation's private keyed archive differs between iPadOS 16 and
    # Ventura 13.  The native producer therefore sends validated scalar fields
    # to macwsinteropd, which reconstructs the object with Ventura CoreLocation.
    # Publish the native producer only after interopd owns its Mach service.
    log "Starting native-to-Ventura location provider bridge..."
    launchctl load "$LOCATIONBRIDGE_PLIST" || return 1
    launchctl list "$LOCATIONBRIDGE_LABEL" >/dev/null 2>&1 || {
        log "ERROR: native-to-Ventura location bridge did not start."
        return 1
    }
    log "Native-to-Ventura location provider bridge ready."

    log "Starting macOS Services database service (launchd job '$PBS_LABEL')..."
    rm -f "$LOGDIR/pbs.log"
    launchctl load "$PBS_PLIST" || return 1
    waited=0
    while ! proc_running "$P_PBS" && [ "$waited" -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    proc_running "$P_PBS" || {
        log "ERROR: macOS pbs process did not start."
        return 1
    }
    log "TIMING start-macos stage=bridges-pasteboard-services seconds=$((SECONDS - macos_stage_started)) total=$((SECONDS - macos_started))"
    macos_stage_started=$SECONDS

    # DockHelper is an Application-type XPC service and must remain on-demand.
    # libmachook registers this proxy bundle in Dock; xpcproxy gives the stock
    # helper the NSApplication main-thread lifecycle required by TrackMenuCommon.
    # A permanently running launchd job is not an equivalent readiness witness.
    [ -x "$DOCK_HELPER_PROXY" ] || {
        log "ERROR: DockHelper XPC activation proxy is missing: $DOCK_HELPER_PROXY"
        return 1
    }
    log "Dock menu presentation helper registered for on-demand XPC activation."

    log "Starting the real macOS Aqua workspace agents (Finder, Dock, SystemUIServer, ControlCenter)..."
    for workspace_log in finder-desktop dock systemuiserver controlcenter; do
        rm -f "$LOGDIR/$workspace_log.log"
    done
    # AirPlayReceiver's supported p2pSolo preference is the authoritative
    # capability source when this chroot has no usable AWDL interface. Set it
    # before ControlCenter constructs APAdvertiserBTLEManager; otherwise the
    # failed IO80211 capability query leaves its initialization incomplete and
    # a retry timer consumes CPU for the lifetime of the desktop session.
    rm -f "$LOGDIR/airplay-power.log"
    if ! /var/jb/usr/bin/timeout -k 2 10 \
            "$CHROOTEXEC" 0 0 "$ROOTFS" "$WORKSPACECTL_BIN" \
            configure-airplay-power \
            > "$LOGDIR/airplay-power.log" 2>&1; then
        log "ERROR: AirPlay power capability configuration failed."
        tail -n 20 "$LOGDIR/airplay-power.log" 2>/dev/null || true
        return 1
    fi
    log "AirPlay AWDL-Solo capability configured through Apple's settings API."
    if ! proc_running "$P_FINDER"; then
        launchctl load "$FINDER_DESKTOP_PLIST" || return 1
    else
        log "Finder desktop owner is already running; preserving the single instance."
    fi
    launchctl load "$DOCK_PLIST" || return 1
    launchctl load "$SYSTEMUI_PLIST" || return 1
    launchctl load "$CONTROL_CENTER_PLIST" || return 1
    waited=0
    while [ "$waited" -lt 15 ]; do
        proc_running "$P_FINDER" && proc_running "$P_DOCK" &&
            proc_running "$P_SYSTEMUI" && proc_running "$P_CONTROL_CENTER" && break
        sleep 1
        waited=$((waited + 1))
    done
    for workspace_spec in \
        "Finder:$P_FINDER:finder-desktop.log" \
        "Dock:$P_DOCK:dock.log" \
        "SystemUIServer:$P_SYSTEMUI:systemuiserver.log" \
        "ControlCenter:$P_CONTROL_CENTER:controlcenter.log"; do
        workspace_name=${workspace_spec%%:*}
        workspace_rest=${workspace_spec#*:}
        workspace_pattern=${workspace_rest%%:*}
        workspace_log=${workspace_rest#*:}
        if proc_running "$workspace_pattern"; then
            log "$workspace_name workspace agent ready."
        else
            log "ERROR: $workspace_name did not reach a live process. See $LOGDIR/$workspace_log"
            return 1
        fi
    done
    # These IPCs used to run before Dock and could wedge indefinitely in
    # get_session_port. They are now bounded and run only after LaunchServices,
    # WindowServer, and all real Aqua session owners have explicit readiness
    # witnesses. Establish two adjacent native Spaces for continuous three-
    # finger navigation, then apply the persisted high-resolution wallpaper.
    ensure_navigation_spaces || return 1
    refresh_dock_after_navigation_spaces || return 1
    apply_workspace_wallpaper || return 1
    wait_for_desktop_input_route || return 1
    log "TIMING start-macos stage=aqua-spaces-wallpaper seconds=$((SECONDS - macos_stage_started)) total=$((SECONDS - macos_started))"
    macos_stage_started=$SECONDS

    if [ "$WANT_VNC" = 1 ]; then
        log "Starting remote VNC and Mission Control pointer proxy (launchd job '$VNC_LABEL')..."
    else
        log "Starting localhost-only Mission Control pointer proxy (launchd job '$VNC_LABEL')..."
    fi
    rm -f "$LOGDIR/osxvnc.log" "$VNC_POINTER_PROXY_SOCKET"
    launchctl load "$VNC_PLIST" || return 1
    wait_for_vnc_pointer_proxy || return 1
    started_ws_unchanged "OSXvnc pointer-proxy startup" || return 1

    if [ "$WANT_TERMINAL" = 1 ]; then
        log "Starting Terminal (launchd job '$TERM_LABEL')..."
        rm -f "$LOGDIR/terminal.log"
        launchctl load "$TERM_PLIST" || return 1
        # The desktop readiness transaction has already completed. RunAtLoad
        # owns Terminal's asynchronous application/window lifecycle; a fixed
        # five-second sleep delayed every cold launch even when the process was
        # alive after one scheduler turn. Require the launchd contract and a
        # bounded live-process witness, while first-frame capture (when VNC is
        # requested) remains the downstream pixel postcondition.
        launchctl list "$TERM_LABEL" >/dev/null 2>&1 || return 1
        waited=0
        while ! proc_running "$P_TERMINAL" && [ "$waited" -lt 20 ]; do
            sleep 0.1
            waited=$((waited + 1))
        done
        proc_running "$P_TERMINAL" || {
            log "ERROR: Terminal did not reach a live process within 2 seconds."
            return 1
        }
        started_ws_unchanged "Terminal startup" || return 1
    fi
    log "TIMING start-macos stage=optional-clients seconds=$((SECONDS - macos_stage_started)) total=$((SECONDS - macos_started))"
}

stop_all() {
    cleanup_macos
    # A watchdog stop does not pass back through macwshostd, so it must clear
    # the diagnostic sentinels itself.  Otherwise the next ordinary CLI start
    # silently inherits experimental protocol behavior.
    rm -f "$EXPERIMENTAL_KCMD" "$EXPERIMENTAL_COMPLETION" \
        "$EXPERIMENTAL_WRAPPED_KCMD" "$EXPERIMENTAL_COMMAND_ERROR" \
        "$EXPERIMENTAL_VNC_SHARE" "$EXPERIMENTAL_FINAL_COMPOSITE" \
        "$EXPERIMENTAL_OBSERVE_PF550" \
        "$EXPERIMENTAL_SUBMIT_RING" "$EXPERIMENTAL_OWNED_SCANOUT" \
        "$EXPERIMENTAL_FAST_SUBMIT_RING" \
        "$EXPERIMENTAL_QUEUE_QOS" "$EXPERIMENTAL_RUNTIME_DIAGNOSTICS" \
        "$EXPERIMENTAL_CAPTURE" \
        "$EXPERIMENTAL_CAPTURE_DONE" "$EXPERIMENTAL_PACE" \
        "$RENDER_ACTIVITY"
    log "Restoring iOS (SpringBoard / backboardd)..."
    launchctl load "$BACKBOARDD"  2>/dev/null
    launchctl load "$SPRINGBOARD" 2>/dev/null
    log "Stopped. The iPad is back on iOS."
}

status() {
    echo "=== macOS GUI status ==="
    if [ -f "$WD_THERMAL_SNAPSHOT" ]; then
        echo "thermal   : $(awk 'NR == 1 { print; exit }' "$WD_THERMAL_SNAPSHOT" 2>/dev/null)"
    else
        echo "thermal   : not sampled (watchdog is stopped or has not armed yet)"
    fi
    echo "memory    : guard disabled (managed by iOS/XNU memorystatus)"
    if proc_running backboardd; then
        echo "display   : COEXISTENCE (live iPadOS backboardd owns the panel)"
    else
        echo "display   : no iPadOS backboardd (exclusive workspace or stopped UI)"
    fi
    echo
    echo "-- processes --"
    ps aux | grep -iE "$P_WINDOWSERVER|$P_OSXVNC|$P_TERMINAL|$P_LAUNCHSERVICESD|$P_SHAREDFILELISTD|$P_SYSTEMSTATUSD|$P_FONTD|$P_PBOARD|$P_PBS|$P_FINDER|$P_DOCK|$P_SYSTEMUI|$P_CONTROL_CENTER" \
        | grep -v grep || echo "(none running)"
    echo
    echo "-- launchd jobs --"
    launchctl list 2>/dev/null | grep -iE "WindowServer|launchservices|systemstatus|macwsguide" \
        || echo "(none loaded)"
    echo
    if proc_running "$P_OSXVNC"; then
        if plutil "$VNC_PLIST" 2>/dev/null | grep -Fq -- '"-localhost"'; then
            echo "VNC: localhost-only pointer proxy (remote framebuffer disabled)"
        else
            echo "VNC: running -> connect with  vnc://<device-ip>:5900   (no password)"
        fi
    else
        echo "VNC: not running"
    fi
    echo
    echo "logs: $LOGDIR/osxvnc.log  $LOGDIR/terminal.log  $LOGDIR/lsd-system.log  $LOGDIR/lsd-session.log  $LOGDIR/dock.log  $LOGDIR/systemuiserver.log  $LOGDIR/controlcenter.log  $LOGDIR/WindowServer.err"
}

switch_status() {
    local path actual
    echo "=== MacWS production switch audit ==="
    echo "profile defaults: AGX-native=ON compatibility=ON diagnostics=OFF mode=coexist"
    echo
    echo "-- built-in production compatibility --"
    echo "native command ABI, cancelled-swap completion, owned scanout and final composite: default ON (no flag files)"
    echo "VNC CPU publication: configured by this session's --no-vnc choice"
    echo "idle completion pace: built-in 100000 us; diagnostic override is optional"
    echo
    echo "-- diagnostic/A-B flags (production expected OFF) --"
    diagnostic_flag_paths | while IFS= read -r path; do
        if [ -e "$ROOTFS$path" ]; then actual=ON; else actual=OFF; fi
        printf '%-48s expected=OFF actual=%s\n' "$path" "$actual"
    done
    echo
    echo "-- configured launch environments --"
    for path in "$WINDOWSERVER_PLIST" "$VNC_PLIST" "$TERM_PLIST" \
                "$VSCODE_PLIST" "$CHROME150_PLIST" "$STEAM_PLIST"; do
        [ -f "$path" ] || continue
        echo "[$path]"
        plutil "$path" 2>/dev/null | sed -n '/EnvironmentVariables =/,/^    };/p'
    done
    echo
    echo "authoritative inventory: docs/runtime-switches.tsv"
}

usage() {
    cat <<USAGE
macos_gui.sh — start/stop the chroot macOS GUI (WindowServer + VNC + Terminal)

Usage (run as root):
  sudo bash $0 production
  sudo bash $0 start [coexist|exclusive] [--no-experimental] [--diagnostics] [--pace-us=N] [--runtime-cap=SECONDS] [--no-terminal] [--no-vnc]
  sudo bash $0 switches
  sudo bash $0 guard [coexist|exclusive] [...]  # re-arm only; no GUI restart
  sudo bash $0 repair-desktop  # preserve apps; rebuild icons, Dock, wallpaper and menus
  sudo bash $0 rebuild-desktop-session  # bounded WS-only fallback; preserves catalogs/trust
  sudo bash $0 launchpad
  sudo bash $0 stop
  sudo bash $0 restart [coexist|exclusive] [...]
  sudo bash $0 status
  sudo bash $0 trust  # restore/audit this boot's code trust; no GUI restart

Modes:
  coexist     (default) iPad panel keeps showing iOS; macOS renders to VNC only.
  exclusive   macOS takes over the physical panel as well as VNC.

Safety: start launches a mandatory launchd-backed iOS-native health watchdog
before the GUI. If the guard is killed abnormally, launchd restarts it and its
persisted WindowServer generation reconnects stale GUI bridges.
It records a startup snapshot, samples temperature every five minutes, and
never stops Stray or the GUI for thermal reasons. Thermal state, numeric
temperatures, and unreadable samples are logged without intervention. The
former free-memory percentage guard is
disabled; iOS/XNU memorystatus owns cache reclamation and memory pressure.
Crash-loop and explicit runtime-cap guards remain separate. The watchdog
cannot be disabled. Logs to
$LOGDIR/macos_gui_watchdog.log.

The production profile enables native AGX and its required command/completion
compatibility adapters by default. High-overhead flight recorders and read-only
method tracing remain off unless --diagnostics is explicitly present. The
obsolete --no-experimental mode is rejected. Interactive
sessions have no arbitrary wall-clock timeout, while
thermal/crash-loop protection stays armed. Automated runs may add
--runtime-cap=300 (minimum 60 seconds).

Connect a VNC viewer to  vnc://<device-ip>:5900  (no password).
USAGE
}

# ─── Argument parsing ───────────────────────────────────────────────────────
CMD="${1:-}"
[ $# -gt 0 ] && shift

FORCE_PRODUCTION=0
if [ "$CMD" = production ]; then
    CMD=start
    FORCE_PRODUCTION=1
fi

MODE=coexist
WANT_VNC=1
WANT_TERMINAL=1
WANT_EXPERIMENTAL=1
WANT_DIAGNOSTICS=0
COEXIST_PACE_US=""
for a in "$@"; do
    case "$a" in
        coexist|coexistence|co)  MODE=coexist ;;
        exclusive|full|excl)     MODE=exclusive ;;
        --experimental)          WANT_EXPERIMENTAL=1 ;;
        --no-experimental)
            echo "macos_gui.sh: production compatibility is built in and cannot be disabled by a marker-file mode" >&2
            exit 64
            ;;
        --diagnostics)           WANT_DIAGNOSTICS=1 ;;
        --pace-us=*)             COEXIST_PACE_US="${a#--pace-us=}" ;;
        --runtime-cap=*)         WD_MAX_RUNTIME="${a#--runtime-cap=}" ;;
        --no-terminal)           WANT_TERMINAL=0 ;;
        --no-vnc)                WANT_VNC=0 ;;
        --no-watchdog)
            echo "macos_gui.sh: --no-watchdog was removed; thermal safety cannot be disabled" >&2
            exit 64
            ;;
        *) echo "macos_gui.sh: ignoring unknown option '$a'" >&2 ;;
    esac
done

if [ "$FORCE_PRODUCTION" = 1 ] &&
   { [ "$WANT_EXPERIMENTAL" != 1 ] || [ "$WANT_DIAGNOSTICS" = 1 ]; }; then
    echo "macos_gui.sh: production requires native compatibility ON and diagnostics OFF" >&2
    exit 1
fi

if [ "$WANT_DIAGNOSTICS" = 1 ] && [ "$WANT_EXPERIMENTAL" != 1 ]; then
    echo "macos_gui.sh: --diagnostics requires --experimental" >&2
    exit 1
fi

case "$WD_MAX_RUNTIME" in
    *[!0-9]*|'')
        echo "macos_gui.sh: --runtime-cap must be an integer (0 or at least 60 seconds)" >&2
        exit 1
        ;;
esac
if [ "$WD_MAX_RUNTIME" -ne 0 ] &&
   [ "$WD_MAX_RUNTIME" -lt 60 ]; then
    echo "macos_gui.sh: --runtime-cap must be 0 or at least 60 seconds" >&2
    exit 1
fi

# The tested 100-ms idle interval now lives in the renderer itself. Only an
# explicit diagnostic --pace-us request writes a temporary override.

if [ -n "$COEXIST_PACE_US" ]; then
    if [ "$WANT_EXPERIMENTAL" != 1 ]; then
        echo "macos_gui.sh: --pace-us requires --experimental" >&2
        exit 1
    fi
    case "$COEXIST_PACE_US" in
        *[!0-9]*|'')
            echo "macos_gui.sh: --pace-us must be an integer from 8333 to 500000" >&2
            exit 1
            ;;
    esac
    if [ "$COEXIST_PACE_US" -lt 8333 ] || [ "$COEXIST_PACE_US" -gt 500000 ]; then
        echo "macos_gui.sh: --pace-us must be from 8333 to 500000" >&2
        exit 1
    fi
fi

enable_experimental_if_requested() {
    [ "$WANT_EXPERIMENTAL" = 1 ] || return 0
    # MacWSHost consumes WindowServer's already-composited native-AGX surface
    # directly. This transport is independent of RFB and remains enabled when
    # --no-vnc is selected; the owned BGRA target is its render destination.
    # Remove obsolete production switches on upgrade. The implementation owns
    # these invariants even when /tmp starts completely empty.
    rm -f "$EXPERIMENTAL_KCMD" "$EXPERIMENTAL_WRAPPED_KCMD" \
        "$EXPERIMENTAL_COMPLETION" "$EXPERIMENTAL_FINAL_COMPOSITE" \
        "$EXPERIMENTAL_OWNED_SCANOUT" "$EXPERIMENTAL_VNC_SHARE"
    if [ "$WANT_VNC" != 1 ]; then
        # RFB is optional. Keep the native final-composite transport active
        # for MacWSHost, but do not allocate the separate mmap framebuffer or
        # run its CPU damage copier when there is no VNC consumer.
        rm -f "$EXPERIMENTAL_VNC_SHARE" "$EXPERIMENTAL_OBSERVE_PF550" \
            "$EXPERIMENTAL_CAPTURE" "$EXPERIMENTAL_CAPTURE_DONE"
    fi
    # Keep the old heap-allocating, mutex-protected deep recorder off the hot
    # path.  A VS Code GPU-process sample caught it in submission, and it can
    # perturb the timing-sensitive 0x102 failure.  The fixed-memory recorder
    # remains available only under the explicit diagnostic mode below.
    rm -f "$EXPERIMENTAL_SUBMIT_RING"
    rm -f "$EXPERIMENTAL_COMMAND_ERROR" "$EXPERIMENTAL_IOGPU_ERROR" \
        "$EXPERIMENTAL_PIPELINE_DIAG" "$EXPERIMENTAL_FAST_SUBMIT_RING" \
        "$EXPERIMENTAL_OBSERVE_PF550" "$EXPERIMENTAL_RUNTIME_DIAGNOSTICS" \
        "$MTLCOMPILER_DIAGNOSTICS"
    if [ "$WANT_DIAGNOSTICS" = 1 ]; then
        touch "$EXPERIMENTAL_COMMAND_ERROR" "$EXPERIMENTAL_IOGPU_ERROR" \
            "$EXPERIMENTAL_PIPELINE_DIAG" \
            "$EXPERIMENTAL_FAST_SUBMIT_RING" \
            "$EXPERIMENTAL_OBSERVE_PF550" \
            "$EXPERIMENTAL_RUNTIME_DIAGNOSTICS" \
            "$MTLCOMPILER_DIAGNOSTICS"
    fi
    rm -f "$EXPERIMENTAL_PACE"
    if [ -n "$COEXIST_PACE_US" ]; then
        echo "$COEXIST_PACE_US" > "$EXPERIMENTAL_PACE"
    fi
    if [ "$WANT_VNC" = 1 ]; then
        log "NATIVE-AGX: built-in command ABI + cancelled-swap completion + owned BGRA scanout + VNC mmap enabled."
    else
        log "NATIVE-AGX: built-in command ABI + cancelled-swap completion + final-composite IOSurface enabled; requested RFB CPU bridge disabled."
    fi
    if [ "$WANT_DIAGNOSTICS" = 1 ]; then
        log "DIAGNOSTICS: AGX fast submit recorder, lifecycle witnesses, PF550 observer, and command-error hooks enabled."
    fi
    if [ -n "$COEXIST_PACE_US" ]; then
        log "VIRTUAL-DISPLAY-COMPAT: completion pace=${COEXIST_PACE_US} us (not a hardware refresh signal)."
    fi
}

arm_initial_vnc_capture_if_requested() {
    [ "$WANT_EXPERIMENTAL" = 1 ] || return 0
    [ "$WANT_VNC" = 1 ] || return 0
    # A WindowServer-only diagnostic start deliberately has no app content to
    # capture.  Besides being misleading, arming here consumes the one-shot on
    # an empty desktop before a debugger can launch the test application.
    [ "$WANT_TERMINAL" = 1 ] || return 0
    # The initial completed PF80 surface is runtime-confirmed to contain only
    # alpha on some starts.  Request a bounded PF550 read after Terminal has
    # launched so a newly connected VNC client receives a real first frame
    # without needing a blind pointer movement.  WindowServer consumes this
    # generation once and writes macws_capture_done only after a validated,
    # spatially non-uniform frame has been published.
    sleep 1
    rm -f "$EXPERIMENTAL_CAPTURE_DONE"
    ARMED_CAPTURE_GENERATION=$(date +%s)
    echo "$ARMED_CAPTURE_GENERATION" > "$EXPERIMENTAL_CAPTURE"
    log "VNC: requested post-Terminal shared frame generation $ARMED_CAPTURE_GENERATION."
}

wait_for_initial_vnc_capture_if_requested() {
    [ -n "$ARMED_CAPTURE_GENERATION" ] || return 0

    # OSXvnc allocates its cached framebuffer before Terminal has necessarily
    # produced the first usable scanout. Runtime evidence on 2026-07-26 showed
    # an early client receiving a 2388x1668 all-zero update while WindowServer
    # acknowledged the validated, non-uniform mmap a few seconds later. Do not
    # advertise the session as ready until that exact generation is published.
    # A newly connecting client then asks OSXvnc for a full rectangle and the
    # existing mmap hook copies the completed frame into its ordinary buffer.
    local waited=0 ack_generation="" ack_pid=""
    log "VNC: waiting up to ${CAPTURE_READY_WAIT}s for a validated Retina first frame..."
    while [ "$waited" -lt "$CAPTURE_READY_WAIT" ]; do
        if [ -f "$EXPERIMENTAL_CAPTURE_DONE" ]; then
            ack_pid=$(awk 'NR == 1 { print $1 }' "$EXPERIMENTAL_CAPTURE_DONE" 2>/dev/null)
            ack_generation=$(awk 'NR == 1 { print $2 }' "$EXPERIMENTAL_CAPTURE_DONE" 2>/dev/null)
            if [ "$ack_generation" = "$ARMED_CAPTURE_GENERATION" ]; then
                log "VNC: Retina first frame ready (WindowServer pid=$ack_pid, generation=$ack_generation)."
                ARMED_CAPTURE_GENERATION=""
                return 0
            fi
        fi
        sleep 1
        waited=$((waited + 1))
    done

    log "WARNING: no validated VNC first frame after ${CAPTURE_READY_WAIT}s; VNC remains available for diagnostics."
    log "         Inspect $LOGDIR/WindowServer.err for 'VNC-FINAL generation=$ARMED_CAPTURE_GENERATION'."
    ARMED_CAPTURE_GENERATION=""
    return 0
}

# Write the exact launch intent into a script-owned launchd job. The job is not
# installed in an auto-scanned daemon directory, so it exists only for an
# explicitly started MacWS session. `SuccessfulExit=false` restarts it after a
# signal/jetsam death, while a deliberate clean exit remains stopped.
write_watchdog_plist() {
    local startup_owner="$1"
    shift
    {
        cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${WATCHDOG_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/var/jb/usr/bin/bash</string>
        <string>$0</string>
PLIST
        for watchdog_arg in "$@"; do
            # All values reaching this helper are constrained enum/numeric
            # command-line options, so none can contain XML metacharacters.
            printf '        <string>%s</string>\n' "$watchdog_arg"
        done
        cat <<PLIST
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>MACWS_WATCHDOG_STARTUP_OWNER</key>
        <string>${startup_owner}</string>
        <!-- launchd does not supply the interactive rootless Procursus PATH. -->
        <key>PATH</key>
        <string>/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <!-- The old job was runtime-confirmed to exit with
         JETSAM_REASON_MEMORY_IDLE_EXIT after arming.  This launchd lifecycle
         flag keeps the mandatory five-minute thermal sampler resident; it
         neither restores the retired free-memory guard nor overrides an iOS
         memorystatus limit. -->
    <key>EnablePressuredExit</key><false/>
    <key>ProcessType</key><string>Background</string>
    <key>ThrottleInterval</key><integer>2</integer>
    <key>StandardOutPath</key><string>${WD_LOG}</string>
    <key>StandardErrorPath</key><string>${WD_LOG}</string>
</dict>
</plist>
PLIST
    } > "$WATCHDOG_PLIST"
}

# Launch the mandatory thermal/crash-loop watchdog as an iOS-side launchd job
# and wait for its independent temperature-sensor handshake before returning.
start_watchdog() {
    local child="" ready_owner="" waited=0
    stop_watchdogs
    rm -f "$WD_LOG" "$WD_TRIP" "$WD_READY" "$WD_THERMAL_SNAPSHOT" \
        "$WD_WS_PIDFILE" "$LOGDIR/macos_gui_memory_snapshot"
    # Re-exec with the exact session intent.  The recovery path needs these
    # flags so a WS restart does not unexpectedly launch a VNC/Terminal job the
    # user disabled, and so it knows whether to request a fresh shared frame.
    set -- watchdog "$MODE"
    [ "$WANT_VNC" = 1 ] || set -- "$@" --no-vnc
    [ "$WANT_TERMINAL" = 1 ] || set -- "$@" --no-terminal
    [ "$WANT_EXPERIMENTAL" = 1 ] && set -- "$@" --experimental
    [ "$WANT_DIAGNOSTICS" = 1 ] && set -- "$@" --diagnostics
    [ -n "$COEXIST_PACE_US" ] && set -- "$@" "--pace-us=$COEXIST_PACE_US"
    [ "$WD_MAX_RUNTIME" -gt 0 ] &&
        set -- "$@" "--runtime-cap=$WD_MAX_RUNTIME"
    write_watchdog_plist "$$" "$@" || return 1
    if ! launchctl load "$WATCHDOG_PLIST"; then
        log "ERROR: mandatory health watchdog launchd job failed to load."
        return 1
    fi
    while [ "$waited" -lt "$WD_ARM_TIMEOUT" ]; do
        child=$(launchd_job_pid "$WATCHDOG_LABEL")
        IFS=' ' read -r ready_owner _ 2>/dev/null < "$WD_READY" || \
            ready_owner=""
        if [ -n "$child" ] && [ "$child" != "-" ] &&
           [ "$ready_owner" = "$child" ]; then
            log "watchdog: launchd-backed health guard ready (pid=$child; temperature=${WD_THERMAL_POLL}s observe-only; memory guard=disabled; log=$WD_LOG)."
            return 0
        fi
        if [ -f "$WD_TRIP" ]; then
            log "ERROR: mandatory health watchdog failed to arm."
            [ -f "$WD_TRIP" ] && sed 's/^/[macos_gui]        /' "$WD_TRIP"
            return 1
        fi
        # Runtime-confirmed after the 2026-09-14 cold boot: launchctl accepted
        # the job, but launchd had not assigned it a PID or produced stdout by
        # the old ten-second deadline. A one-shot start request is idempotent
        # for an already-running label and nudges an accepted-but-undispatched
        # cold-boot job without unloading or creating a competing generation.
        if [ "$waited" -eq 5 ]; then
            launchctl start "$WATCHDOG_LABEL" 2>/dev/null || true
        fi
        sleep 1
        waited=$((waited + 1))
    done
    log "ERROR: mandatory health watchdog did not acknowledge within ${WD_ARM_TIMEOUT} seconds."
    launchctl list "$WATCHDOG_LABEL" >> "$WD_LOG" 2>&1 || true
    return 1
}

case "$CMD" in
    start)
        require_root "$@"
        acquire_gui_transaction start || exit $?
        prepare_production_boot_jobs || exit 1
        start_started=$SECONDS
        start_stage_started=$SECONDS
        write_gui_start_state windowing "verifying the current SpringBoard request bridge"
        ensure_windowing_bridge || exit 1
        log "TIMING gui-start stage=windowing seconds=$((SECONDS - start_stage_started)) total=$((SECONDS - start_started))"
        start_stage_started=$SECONDS
        write_gui_start_state preparing "generating launchd contracts"
        write_plists || { log "ERROR: failed to write GUI launch plists."; exit 1; }
        log "TIMING gui-start stage=contracts seconds=$((SECONDS - start_stage_started)) total=$((SECONDS - start_started))"
        start_stage_started=$SECONDS
        write_gui_start_state cleaning "retiring the previous service generation"
        cleanup_macos
        log "TIMING gui-start stage=cleanup seconds=$((SECONDS - start_stage_started)) total=$((SECONDS - start_started))"
        start_stage_started=$SECONDS
        write_gui_start_state assets "preparing the production application profile"
        prepare_metal_library_target_cache || { stop_all; exit 1; }
        prepare_vscode_production_assets || { stop_all; exit 1; }
        enable_experimental_if_requested
        if [ "$WANT_EXPERIMENTAL" = 1 ] && [ "$WANT_DIAGNOSTICS" != 1 ]; then
            write_gui_start_state preflight "validating native AGX production switches"
            production_preflight || { stop_all; exit 1; }
        fi
        if [ "$MODE" = exclusive ]; then mode_exclusive; else mode_coexist; fi
        log "TIMING gui-start stage=assets-preflight-mode seconds=$((SECONDS - start_stage_started)) total=$((SECONDS - start_started))"
        start_stage_started=$SECONDS
        write_gui_start_state safety "arming the observe-only health watchdog"
        start_watchdog || { stop_all; exit 1; }
        log "TIMING gui-start stage=watchdog seconds=$((SECONDS - start_stage_started)) total=$((SECONDS - start_started))"
        start_stage_started=$SECONDS
        write_gui_start_state trust "restoring executable trust for this boot"
        bash /var/jb/usr/macOS/bin/ensure_jb_usr_bind.sh || { stop_all; exit 1; }
        ensure_chroot_works || { stop_all; exit 1; }
        log "TIMING gui-start stage=trust seconds=$((SECONDS - start_stage_started)) total=$((SECONDS - start_started))"
        start_stage_started=$SECONDS
        write_gui_start_state services "starting catalogs, WindowServer, bridges, and applications"
        start_macos || { stop_all; exit 1; }
        log "TIMING gui-start stage=services seconds=$((SECONDS - start_stage_started)) total=$((SECONDS - start_started))"
        start_stage_started=$SECONDS
        write_gui_start_state first-frame "waiting for the optional initial VNC capture"
        arm_initial_vnc_capture_if_requested
        wait_for_initial_vnc_capture_if_requested
        log "TIMING gui-start stage=first-frame seconds=$((SECONDS - start_stage_started)) total=$((SECONDS - start_started))"
        write_gui_start_state ready "WindowServer and requested clients are ready"
        echo
        log "Started in $MODE mode."
        status
        ;;
    stop)
        require_root "$@"
        acquire_gui_transaction stop || exit $?
        write_gui_start_state stopping "retiring the active GUI service generation"
        stop_all
        write_gui_start_state stopped "iOS display services restored"
        ;;
    restart)
        require_root "$@"
        acquire_gui_transaction restart || exit $?
        prepare_production_boot_jobs || exit 1
        write_gui_start_state windowing "verifying the current SpringBoard request bridge"
        ensure_windowing_bridge || exit 1
        write_gui_start_state preparing "generating launchd contracts"
        write_plists || { log "ERROR: failed to write GUI launch plists."; exit 1; }
        # A desktop restart does not require destroying the persistent
        # LaunchServices/CFPreferences/IconServices stores. When the complete
        # live-session prerequisite set exists and the requested display mode
        # matches it, replace only WindowServer and its connection-bound
        # clients. The routine below retains the same PID, input-socket and
        # two-consecutive-final-composite postconditions as the recovery path.
        # A failed fast transaction falls through to the authoritative full
        # stop/start below, so this changes latency rather than correctness.
        restart_ws=$(ws_pid)
        restart_mode_matches=0
        if { [ "$MODE" = coexist ] && proc_running backboardd; } ||
           { [ "$MODE" = exclusive ] && ! proc_running backboardd; }; then
            restart_mode_matches=1
        fi
        case "$restart_ws" in
            ''|'-'|*[!0-9]*) restart_live=0 ;;
            *) restart_live=1 ;;
        esac
        if [ "$restart_live" = 1 ] && [ "$restart_mode_matches" = 1 ] &&
           [ "$WANT_EXPERIMENTAL" = 1 ] &&
           proc_running "$P_INPUTD" && proc_running "$P_DISPLAYD" &&
           desktop_job_loaded "$WATCHDOG_LABEL"; then
            enable_experimental_if_requested
            write_gui_start_state desktop-session-rebuild \
                "replacing only WindowServer and its connection-bound clients"
            if rebuild_desktop_session; then
                write_gui_start_state ready \
                    "replacement WindowServer, desktop input and final composite are ready"
                log "Restarted the live $MODE desktop through the minimal session path."
                status
                exit 0
            fi
            log "Minimal desktop restart failed its postconditions; falling back to a full service generation."
        fi
        write_gui_start_state cleaning "retiring the active GUI service generation"
        stop_all
        write_gui_start_state assets "preparing the production application profile"
        prepare_metal_library_target_cache || { stop_all; exit 1; }
        prepare_vscode_production_assets || { stop_all; exit 1; }
        enable_experimental_if_requested
        if [ "$WANT_EXPERIMENTAL" = 1 ] && [ "$WANT_DIAGNOSTICS" != 1 ]; then
            write_gui_start_state preflight "validating native AGX production switches"
            production_preflight || { stop_all; exit 1; }
        fi
        if [ "$MODE" = exclusive ]; then mode_exclusive; else mode_coexist; fi
        write_gui_start_state safety "arming the observe-only health watchdog"
        start_watchdog || { stop_all; exit 1; }
        write_gui_start_state trust "restoring executable trust for this boot"
        bash /var/jb/usr/macOS/bin/ensure_jb_usr_bind.sh || { stop_all; exit 1; }
        ensure_chroot_works || { stop_all; exit 1; }
        write_gui_start_state services "starting catalogs, WindowServer, bridges, and applications"
        start_macos || { stop_all; exit 1; }
        write_gui_start_state first-frame "waiting for the optional initial VNC capture"
        arm_initial_vnc_capture_if_requested
        wait_for_initial_vnc_capture_if_requested
        write_gui_start_state ready "WindowServer and requested clients are ready"
        echo
        log "Restarted in $MODE mode."
        status
        ;;
    repair-desktop)
        require_root "$@"
        acquire_gui_transaction repair-desktop || exit $?
        write_gui_start_state desktop-repair \
            "preserving applications while rebuilding desktop services"
        repair_desktop
        repair_rc=$?
        if [ "$repair_rc" -ne 0 ]; then
            write_gui_start_state desktop-repair-failed \
                "desktop services did not satisfy their readiness witnesses"
            exit "$repair_rc"
        fi
        write_gui_start_state ready \
            "desktop services repaired without restarting WindowServer or applications"
        ;;
    rebuild-desktop-session)
        require_root "$@"
        acquire_gui_transaction rebuild-desktop-session || exit $?
        write_gui_start_state desktop-session-rebuild \
            "replacing only WindowServer and its connection-bound clients"
        rebuild_desktop_session || {
            rebuild_rc=$?
            write_gui_start_state desktop-session-rebuild-failed \
                "minimal WindowServer generation rebuild failed its postconditions"
            exit "$rebuild_rc"
        }
        write_gui_start_state ready \
            "replacement WindowServer, desktop input and final composite are ready"
        ;;
    status)
        status
        ;;
    windowing-status)
        # Read-only acceptance of the same predicate used by cold start.
        # In particular this must not refresh/restart SpringBoard.
        if windowing_bridge_ready; then
            log "WINDOWING-READY: current SpringBoard PID, bridge version, fullscreen capability and initial-size protocol verified."
        else
            log "WINDOWING-NOT-READY: current SpringBoard does not match the required bridge protocol."
            exit 1
        fi
        ;;
    trust)
        # Non-disruptive cold-boot repair/audit entry point.  It changes no
        # signature and does not stop or launch any GUI process; production
        # start runs the identical closure automatically before WindowServer.
        require_root "$@"
        restore_cold_boot_trust
        ;;
    switches)
        switch_status
        ;;
    guard)
        # Low-impact recovery/testing entry point: arm the mandatory guard for
        # an already-running GUI session without restarting WindowServer or
        # any client. Ordinary users get the same path automatically via start.
        require_root "$@"
        mkdir -p "$GUI_LAUNCHD_DIR"
        start_watchdog
        ;;
    launchpad)
        require_root "$@"
        toggle_native_launchpad
        ;;
    watchdog)
        require_root "$@"
        run_watchdog
        ;;
    ""|-h|--help|help)
        usage
        ;;
    *)
        echo "macos_gui.sh: unknown command '$CMD'" >&2
        usage
        exit 1
        ;;
esac
