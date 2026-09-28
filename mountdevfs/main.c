// mountdevfs — mount a fresh devfs at the given mountpoint (default the chroot
// /dev). The chrooted macOS rootfs otherwise has no /dev/ptmx, so pty-based
// programs fail: Terminal.app's forkpty() -> open("/dev/ptmx") returns ENOENT
// ("forkpty: No such file or directory") and no shell can spawn.
//
// Why a dedicated iOS tool instead of the obvious alternatives:
//   * mount_bindfs (the project's bind helper) mounts READ-ONLY, so /dev/ptmx
//     can't be opened O_RDWR (EROFS) even though the node is exposed.
//   * the macOS /sbin/mount_devfs run inside the chroot is EPERM'd — the iOS
//     kernel denies mount(2) to a chrooted macOS-platform process (even with
//     the project entitlements).
//   * iOS has no devfs mount helper, so `mount -t devfs` can't find
//     mount_devfs and fails.
// Dopamine's mount-bindfs helper does not rely on uid 0 alone: it temporarily
// borrows the jailbreak's unsandboxed root credential around mount(2), then
// restores the original credential.  iPadOS 16.4.1 runtime evidence is exact:
// this helper was root, trustcached and narrowly entitled, yet direct
// mount("devfs") still returned EPERM.  Use the same bounded credential
// transaction rather than weakening the caller's process sandbox globally.
//
// Idempotent: if the mountpoint is already a devfs, it does nothing, so
// postinst.sh can call it on every (re)install.
#include <dlfcn.h>
#include <rootless.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

#define LIBJAILBREAK_PATH ROOT_PATH("/usr/lib/libjailbreak.dylib")

typedef int (*jbclient_root_steal_ucred_fn)(uint64_t, uint64_t *);

static int already_devfs(const char *path) {
    struct statfs sfs;
    if (statfs(path, &sfs) != 0) return 0;
    return strcmp(sfs.f_fstypename, "devfs") == 0;
}

int main(int argc, char **argv) {
    const char *mp = (argc >= 2) ? argv[1] : "/var/mnt/rootfs/dev";
    if (already_devfs(mp)) {
        printf("devfs already mounted at %s\n", mp);
        return 0;
    }

    void *jailbreak = dlopen(LIBJAILBREAK_PATH, RTLD_NOW | RTLD_LOCAL);
    if (!jailbreak) {
        fprintf(stderr, "mount devfs %s: libjailbreak unavailable: %s\n",
                mp, dlerror());
        return 1;
    }
    jbclient_root_steal_ucred_fn steal =
        (jbclient_root_steal_ucred_fn)dlsym(
            jailbreak, "jbclient_root_steal_ucred");
    if (!steal) {
        fprintf(stderr,
                "mount devfs %s: jbclient_root_steal_ucred unavailable\n", mp);
        dlclose(jailbreak);
        return 1;
    }

    uint64_t originalCredential = 0;
    int stealStatus = steal(0, &originalCredential);
    if (stealStatus != 0 || originalCredential == 0) {
        fprintf(stderr,
                "mount devfs %s: unsandboxed credential failed: %d\n",
                mp, stealStatus);
        dlclose(jailbreak);
        return 1;
    }
    int result = mount("devfs", mp, 0, NULL);
    int mountError = errno;
    int restoreStatus = steal(originalCredential, NULL);
    dlclose(jailbreak);
    if (restoreStatus != 0) {
        fprintf(stderr,
                "mount devfs %s: credential restore failed: %d\n",
                mp, restoreStatus);
        return 1;
    }
    if (result != 0) {
        fprintf(stderr, "mount devfs %s: %s\n", mp, strerror(mountError));
        return 1;
    }
    printf("mounted devfs at %s\n", mp);
    return 0;
}
