#ifndef MACWS_PROCESS_ANCESTRY_H
#define MACWS_PROCESS_ANCESTRY_H

#include <stdint.h>
#include <sys/types.h>

// The iPhoneOS 16.5 SDK omits libproc.h/sys/proc_info.h even though
// libsystem_kernel exports proc_pidinfo and the kernel implements the same
// Darwin wire ABI. This is the exact proc_bsdinfo layout and flavor from the
// installed macOS 13.3 SDK. Keep the full 136-byte record: proc_pidinfo
// rejects a short prefix buffer even though ancestry needs only pbi_ppid.
typedef struct {
    uint32_t pbi_flags;
    uint32_t pbi_status;
    uint32_t pbi_xstatus;
    uint32_t pbi_pid;
    uint32_t pbi_ppid;
    uint32_t pbi_uid;
    uint32_t pbi_gid;
    uint32_t pbi_ruid;
    uint32_t pbi_rgid;
    uint32_t pbi_svuid;
    uint32_t pbi_svgid;
    uint32_t pbi_reserved;
    char pbi_comm[16];
    char pbi_name[32];
    uint32_t pbi_nfiles;
    uint32_t pbi_pgid;
    uint32_t pbi_pjobc;
    uint32_t pbi_tdev;
    uint32_t pbi_tpgid;
    int32_t pbi_nice;
    uint64_t pbi_start_tvsec;
    uint64_t pbi_start_tvusec;
} MacWSProcBSDInfo;

_Static_assert(sizeof(MacWSProcBSDInfo) == 136,
               "Darwin proc_bsdinfo wire ABI changed");

enum { MacWSProcPIDTBSDInfoFlavor = 3 };

extern int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer,
                        int buffersize);

static inline int MacWSProcessDescendsFrom(pid_t process, pid_t ancestor) {
    if (process <= 1 || ancestor <= 1) return 0;
    for (unsigned depth = 0; depth < 12 && process > 1; depth++) {
        if (process == ancestor) return 1;
        MacWSProcBSDInfo info = {0};
        int bytes = proc_pidinfo(process, MacWSProcPIDTBSDInfoFlavor, 0,
                                 &info, sizeof(info));
        if (bytes != sizeof(info) || info.pbi_pid != (uint32_t)process ||
            info.pbi_ppid <= 1 || info.pbi_ppid == (uint32_t)process)
            return 0;
        process = (pid_t)info.pbi_ppid;
    }
    return process == ancestor;
}

#endif
