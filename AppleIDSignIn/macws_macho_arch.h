#ifndef MACWS_MACHO_ARCH_H
#define MACWS_MACHO_ARCH_H

#include <fcntl.h>
#include <stdint.h>
#include <unistd.h>

#include <libkern/OSByteOrder.h>
#include <mach/machine.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>

typedef enum {
    MACWS_ARCH_UNKNOWN = 0,
    MACWS_ARCH_ARM64,
    MACWS_ARCH_ARM64E,
} macws_macho_arch_t;

static inline uint32_t macws_swap32_if(uint32_t value, int swap) {
    return swap ? OSSwapInt32(value) : value;
}

static inline macws_macho_arch_t
macws_classify_arm64(cpu_type_t cpu_type, cpu_subtype_t cpu_subtype) {
    if ((uint32_t)cpu_type != (uint32_t)CPU_TYPE_ARM64) return MACWS_ARCH_UNKNOWN;

    /* Capability bits occupy the high byte and are not part of the subtype. */
    uint32_t subtype = ((uint32_t)cpu_subtype) & 0x00ffffffu;
    return subtype == (uint32_t)CPU_SUBTYPE_ARM64E
        ? MACWS_ARCH_ARM64E : MACWS_ARCH_ARM64;
}

/*
 * Return the ARM64 slice a native Apple-Silicon dyld will select for path.
 * Universal macOS binaries normally contain x86_64 plus exactly one of arm64
 * or arm64e.  If an unusual file contains both, prefer arm64e, matching the
 * more-specific native subtype.
 */
static inline macws_macho_arch_t macws_macho_arch_for_path(const char *path) {
    if (!path) return MACWS_ARCH_UNKNOWN;

    int fd = open(path, O_RDONLY);
    if (fd < 0) return MACWS_ARCH_UNKNOWN;

    uint32_t magic = 0;
    if (pread(fd, &magic, sizeof(magic), 0) != sizeof(magic)) {
        close(fd);
        return MACWS_ARCH_UNKNOWN;
    }

    if (magic == MH_MAGIC_64 || magic == MH_CIGAM_64) {
        struct mach_header_64 mh;
        if (pread(fd, &mh, sizeof(mh), 0) != sizeof(mh)) {
            close(fd);
            return MACWS_ARCH_UNKNOWN;
        }
        int swap = magic == MH_CIGAM_64;
        macws_macho_arch_t result = macws_classify_arm64(
            (cpu_type_t)macws_swap32_if((uint32_t)mh.cputype, swap),
            (cpu_subtype_t)macws_swap32_if((uint32_t)mh.cpusubtype, swap));
        close(fd);
        return result;
    }

    int is_fat64 = magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64;
    if (magic != FAT_MAGIC && magic != FAT_CIGAM && !is_fat64) {
        close(fd);
        return MACWS_ARCH_UNKNOWN;
    }

    int swap = magic == FAT_CIGAM || magic == FAT_CIGAM_64;
    struct fat_header fh;
    if (pread(fd, &fh, sizeof(fh), 0) != sizeof(fh)) {
        close(fd);
        return MACWS_ARCH_UNKNOWN;
    }
    uint32_t count = macws_swap32_if(fh.nfat_arch, swap);
    if (count > 64) {
        close(fd);
        return MACWS_ARCH_UNKNOWN;
    }

    int found_arm64 = 0;
    off_t offset = (off_t)sizeof(struct fat_header);
    for (uint32_t i = 0; i < count; i++) {
        cpu_type_t cpu_type;
        cpu_subtype_t cpu_subtype;
        if (is_fat64) {
            struct fat_arch_64 arch;
            off_t at = offset + (off_t)i * (off_t)sizeof(arch);
            if (pread(fd, &arch, sizeof(arch), at) != sizeof(arch)) break;
            cpu_type = (cpu_type_t)macws_swap32_if((uint32_t)arch.cputype, swap);
            cpu_subtype = (cpu_subtype_t)macws_swap32_if((uint32_t)arch.cpusubtype, swap);
        } else {
            struct fat_arch arch;
            off_t at = offset + (off_t)i * (off_t)sizeof(arch);
            if (pread(fd, &arch, sizeof(arch), at) != sizeof(arch)) break;
            cpu_type = (cpu_type_t)macws_swap32_if((uint32_t)arch.cputype, swap);
            cpu_subtype = (cpu_subtype_t)macws_swap32_if((uint32_t)arch.cpusubtype, swap);
        }
        macws_macho_arch_t candidate = macws_classify_arm64(cpu_type, cpu_subtype);
        if (candidate == MACWS_ARCH_ARM64E) {
            close(fd);
            return candidate;
        }
        if (candidate == MACWS_ARCH_ARM64) found_arm64 = 1;
    }

    close(fd);
    return found_arm64 ? MACWS_ARCH_ARM64 : MACWS_ARCH_UNKNOWN;
}

static inline const char *macws_insert_dylib_for_arch(macws_macho_arch_t arch) {
    if (arch == MACWS_ARCH_ARM64E)
        return "/usr/local/lib/libmachook.dylib";
    if (arch == MACWS_ARCH_ARM64)
        return "/usr/local/lib/libmachook_arm64.dylib";
    return NULL;
}

static inline const char *macws_arch_name(macws_macho_arch_t arch) {
    if (arch == MACWS_ARCH_ARM64E) return "arm64e";
    if (arch == MACWS_ARCH_ARM64) return "arm64";
    return "unknown";
}

#endif /* MACWS_MACHO_ARCH_H */
