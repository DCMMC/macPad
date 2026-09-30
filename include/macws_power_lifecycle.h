#ifndef MACWS_POWER_LIFECYCLE_H
#define MACWS_POWER_LIFECYCLE_H

// Native hostd owns the iPad lock-state transition. The marker is visible as
// /private/tmp inside the chroot and through the rootfs mount from iPadOS.
#define MACWS_WORKSPACE_SLEEP_MARKER \
    "/private/tmp/macws_workspace_sleeping"
#define MACWS_WORKSPACE_SLEEP_MARKER_HOST \
    "/var/mnt/rootfs" MACWS_WORKSPACE_SLEEP_MARKER

// AppInputBridge translates these Darwin notifications into the ordinary
// synchronous NSWorkspace sleep/wake notifications in each AppKit process.
#define MACWS_WORKSPACE_WILL_SLEEP_NOTIFY \
    "com.macwsguide.workspace.will-sleep"
#define MACWS_WORKSPACE_DID_WAKE_NOTIFY \
    "com.macwsguide.workspace.did-wake"

#endif
