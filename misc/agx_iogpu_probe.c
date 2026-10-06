// agx_iogpu_probe.c — iOS-native diagnostic for IOGPU::+0x108 size-cap.
//
// Opens an AGXAccelerator user-client in iOS-native context (where things
// work), uses Dopamine KRW to walk:
//
//   io_connect_t (mach port name)
//     → UC kernel kobject              [task_get_ipc_port_kobject]
//     → IOGPUDevice* at UC+0x120       [kread64]
//     → IOGPU*       at IOGPUDevice+0x48
//     → IOGPUTask*   at IOGPUDevice+0x58
//     → open options at UC+0x128 / AGXShared+0xd8
//     → cap fields   at IOGPU+0x108 / IOGPU+0x224
//
// Compile + sign + run on iOS (NOT chroot):
//   clang -arch arm64 -framework IOKit /tmp/agx_iogpu_probe.c -o /tmp/agx_iogpu_probe
//   sudo ldid -S /tmp/agx_iogpu_probe
//   sudo /var/jb/usr/bin/jbctl trustcache add $(ldid -arch arm64 -h /tmp/agx_iogpu_probe \
//        2>/dev/null | awk -F= '/CDHash/{print $2}')
//   sudo /tmp/agx_iogpu_probe                         # fields only
//   sudo /tmp/agx_iogpu_probe 1 AGXAccelerator queue     # one queue only
//   sudo /tmp/agx_iogpu_probe 1 AGXAccelerator exercise  # resource call tests
//
// Decision matrix once we have numbers:
//
//   +0x108 != 0 here  &  +0x108 != 0 in chroot WS via libmachook KRW path:
//     → '+0x108 is the limit' hypothesis is WRONG; reject point is elsewhere
//       (look at the +0x44 b.hi at f03b9c, or +0x224 path)
//
//   +0x108 != 0 here  &  +0x108 == 0 in chroot WS:
//     → IOGPU is NOT a singleton; per-UC instance is real
//       → RE the createDevice / IOGPU::start path more carefully to find what
//         conditions cause re-init or fork
//
//   +0x108 == 0 here too:
//     → IOGPU::start never ran or didn't propagate; check GARTCacheSize
//       property in IORegistry, check boot-args, check whether backboardd
//       was actually working with sel=0x9 (maybe IT uses something else)

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <dlfcn.h>
#include <unistd.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>

static uint64_t (*p_task_self)(void);
static uint64_t (*p_task_get_ipc_port_kobject)(uint64_t task, mach_port_name_t port);
static uint64_t (*p_kread64)(uint64_t addr);
static uint32_t (*p_kread32)(uint64_t addr);
static int      (*p_jbclient_process_checkin)(char **rootPath, char **bootUUID,
                                              char **sandboxExt, bool *fullyDebugged);
static int      (*p_jbclient_initialize_primitives)(void);
static int      (*p_is_kcall_available)(void);

static int load_libjb(void) {
    void *lib = dlopen("/var/jb/basebin/libjailbreak.dylib", RTLD_NOW);
    if (!lib) {
        fprintf(stderr, "dlopen libjailbreak: %s\n", dlerror());
        return -1;
    }
    p_task_self                  = dlsym(lib, "task_self");
    p_task_get_ipc_port_kobject  = dlsym(lib, "task_get_ipc_port_kobject");
    p_kread64                    = dlsym(lib, "kread64");
    p_kread32                    = dlsym(lib, "kread32");
    p_jbclient_process_checkin   = dlsym(lib, "jbclient_process_checkin");
    p_jbclient_initialize_primitives = dlsym(lib, "jbclient_initialize_primitives");
    p_is_kcall_available         = dlsym(lib, "is_kcall_available");
    if (!p_task_self || !p_task_get_ipc_port_kobject || !p_kread64 || !p_kread32) {
        fprintf(stderr, "dlsym critical missing: ts=%p tgkobj=%p k64=%p k32=%p\n",
                p_task_self, p_task_get_ipc_port_kobject, p_kread64, p_kread32);
        return -1;
    }
    if (p_jbclient_process_checkin) {
        char *root = NULL, *uuid = NULL, *sbox = NULL;
        bool dbg = false;
        int r = p_jbclient_process_checkin(&root, &uuid, &sbox, &dbg);
        fprintf(stderr, "jbclient_process_checkin = %d (root=%s)\n", r,
                root ? root : "(null)");
    }
    if (p_jbclient_initialize_primitives) {
        int r = p_jbclient_initialize_primitives();
        fprintf(stderr, "jbclient_initialize_primitives = %d\n", r);
    }
    if (p_is_kcall_available) {
        fprintf(stderr, "is_kcall_available = %d (informational)\n",
                p_is_kcall_available());
    }
    return 0;
}

typedef enum {
    kProbeFieldsOnly,
    kProbeDeviceInfoOnly,
    kProbeQueueOnly,
    kProbeExercise,
} probe_mode_t;

static void dump_registered_queues(uint64_t kernel_queue, int target_pid) {
    // RE-confirmed via IOGPUCommandQueue::init and
    // IOGPUScheduler::registerCommandQueue in the iOS 16.3 IOGPUFamily:
    // queue+0x538 is the scheduler; scheduler+0x48 is an array of 24-byte
    // records; scheduler+0x50 is the record count; each record begins with
    // an IOGPUCommandQueue*.  Queue fields below are likewise direct loads
    // in IOGPUCommandQueue::updatePriority/isOpportunisticWorkload.
    if (!kernel_queue) return;
    uint64_t scheduler = p_kread64(kernel_queue + 0x538);
    uint64_t records = scheduler ? p_kread64(scheduler + 0x48) : 0;
    uint32_t count = scheduler ? p_kread32(scheduler + 0x50) : 0;
    fprintf(stderr,
            "    scheduler=%#llx records=%#llx count=%u target_pid=%d\n",
            (unsigned long long)scheduler, (unsigned long long)records,
            count, target_pid);
    // A corrupt count should never be allowed to turn a diagnostic into a
    // long kernel-memory walk.
    if (!records || count > 4096) return;
    for (uint32_t i = 0; i < count; ++i) {
        uint64_t queue = p_kread64(records + (uint64_t)i * 24);
        if (!queue) continue;
        uint32_t pid = p_kread32(queue + 0x490);
        if (target_pid >= 0 && pid != (uint32_t)target_pid) continue;
        uint32_t requested = p_kread32(queue + 0x444);
        uint32_t background = p_kread32(queue + 0x448);
        uint32_t effective = p_kread32(queue + 0x44c);
        uint32_t qos = p_kread32(queue + 0x450);
        uint32_t error = p_kread32(queue + 0x520);
        fprintf(stderr,
                "      record[%u] queue=%#llx pid=%u requested=%u "
                "background=%u effective=%u qos=%u error=%u\n",
                i, (unsigned long long)queue, pid, requested, background,
                effective, qos, error);
    }
}

static void probe_one(const char *match_class, uint32_t type,
                      probe_mode_t mode, int target_pid) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
        IOServiceMatching(match_class));
    if (!svc) {
        fprintf(stderr, "[%s] no service\n", match_class);
        return;
    }
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), type, &conn);
    IOObjectRelease(svc);
    if (kr != 0) {
        fprintf(stderr, "[%s type=%u] IOServiceOpen kr=0x%x\n",
                match_class, type, kr);
        return;
    }
    fprintf(stderr, "\n=== [%s type=%u] io_connect_t=0x%x ===\n",
            match_class, type, conn);

    uint64_t task = p_task_self();
    uint64_t uc   = p_task_get_ipc_port_kobject(task, conn);
    fprintf(stderr, "  task            = %#llx\n", (unsigned long long)task);
    fprintf(stderr, "  UC kobj         = %#llx\n", (unsigned long long)uc);
    if (!uc) {
        fprintf(stderr, "  no kobject — closing\n");
        IOServiceClose(conn);
        return;
    }

    uint64_t vt_uc      = p_kread64(uc + 0x00);
    uint64_t device     = p_kread64(uc + 0x120);
    uint64_t uc_options = p_kread64(uc + 0x128);
    uint8_t  uc_103 = (uint8_t)(p_kread32(uc + 0x100) >> 24);
    fprintf(stderr, "  UC vtable       = %#llx\n", (unsigned long long)vt_uc);
    fprintf(stderr, "  UC+0x120 device = %#llx\n", (unsigned long long)device);
    fprintf(stderr, "  UC+0x128 options= %#llx\n",
            (unsigned long long)uc_options);
    fprintf(stderr, "  UC+0x103 byte   = 0x%02x  (1=restricted method table)\n", uc_103);
    if (!device) { IOServiceClose(conn); return; }

    uint64_t vt_dev  = p_kread64(device + 0x00);
    uint64_t iogpu   = p_kread64(device + 0x48);
    uint64_t gpu_task = p_kread64(device + 0x58);
    fprintf(stderr, "  Device vtable   = %#llx\n", (unsigned long long)vt_dev);
    fprintf(stderr, "  Device+0x48 IOGPU = %#llx\n", (unsigned long long)iogpu);
    fprintf(stderr, "  Device+0x58 IOGPUTask = %#llx\n",
            (unsigned long long)gpu_task);
    if (!iogpu) { IOServiceClose(conn); return; }

    uint64_t vt_iogpu   = p_kread64(iogpu + 0x00);
    // RE-confirmed via AGXShared::init: the receiver is the newly created
    // IOGPUDevice subclass, not the IOGPU singleton at Device+0x48.
    uint64_t agx_options = p_kread64(device + 0xd8);
    uint64_t cap_108    = p_kread64(iogpu + 0x108);
    uint32_t cap_224    = p_kread32(iogpu + 0x224);
    fprintf(stderr, "  IOGPU vtable    = %#llx\n", (unsigned long long)vt_iogpu);
    fprintf(stderr, "  Device/AGXShared+0xd8 options = %#llx\n",
            (unsigned long long)agx_options);
    fprintf(stderr, "  IOGPU+0x108     = %#llx  (the size cap field)\n",
            (unsigned long long)cap_108);
    fprintf(stderr, "  IOGPU+0x224     = %#x      (outCnt-related field)\n",
            cap_224);
    fprintf(stderr, "  derived         3*0x108/4 = %#llx\n",
            (unsigned long long)((cap_108 * 3) / 4));

    // RE-confirmed against the iOS 16.3 IOGPUFamily binary:
    // IOGPUTask::init(IOGPU *, task *, unsigned count,
    //                 IORangeAllocator **allocators)
    // retains allocator[i] into task+0x138+(i*8).  It does not retain the
    // count in an adjacent field, so this dump is intentionally just the 16
    // fixed slots, not an inferred count.
    if (gpu_task) {
        uint64_t vt_task = p_kread64(gpu_task + 0x00);
        fprintf(stderr, "  IOGPUTask vtable = %#llx\n",
                (unsigned long long)vt_task);
        for (unsigned i = 0; i < 16; ++i) {
            uint64_t allocator = p_kread64(gpu_task + 0x138 + i * 8);
            fprintf(stderr, "  IOGPUTask allocator[%u] = %#llx\n", i,
                    (unsigned long long)allocator);
        }
    }

    if (mode == kProbeFieldsOnly) {
        fprintf(stderr,
                "  fields-only: skipping resource/queue call tests\n");
        IOServiceClose(conn);
        return;
    }

    // Selector 0x100 is a read-only device-information query used by AGX's
    // setupImmediate path. Kernel builds hard-check its output structure
    // length. Probe a small, explicit set of known/adjacent ABI sizes so a
    // new OS adapter can be pinned to runtime evidence instead of broadening
    // the production clamp or suppressing the driver's initialization error.
    if (mode == kProbeDeviceInfoOnly) {
        static const size_t sizes[] = {0x68, 0x70, 0x78, 0x80};
        for (size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); ++i) {
            unsigned char out_info[0x80] = {0};
            size_t out_size = sizes[i];
            kr = IOConnectCallStructMethod(conn, 0x100, NULL, 0,
                out_info, &out_size);
            fprintf(stderr,
                "  sel=0x100 requested=%#zx returned=%#zx -> kr=%#x %s\n",
                sizes[i], out_size, kr, kr == 0 ? "(OK)" : "(FAIL)");
        }
        IOServiceClose(conn);
        return;
    }

    // === Trigger sel=0x9 type=0x80 STANDALONE from iOS-native context ===
    // Multiple shape variants — to test if the args-shape (not credentials)
    // gates the rejection. Real WS-captured bytes (2026-06-19 runtime):
    //   +0x00: 80 (type=0x80)
    //   +0x08: 01 00 01 00 01 00 01 00 (mystery 4-short struct)
    //   +0x14: 70 04 00 00 (flag mask 0x470)
    //   +0x30: 01 (then VA — pinned-VA magic)
    //   +0x38: pinned VA
    //   +0x40: pinned VA (same as +0x38)
    //   +0x48: 0x4000 (length)
    //   +0x60: 01 (mystery flag)
    if (mode == kProbeExercise) {
        extern kern_return_t mach_vm_allocate(uint64_t target,
            uint64_t *addr, uint64_t size, int flags);
        struct shape {
            const char *name;
            uint64_t f08;     // +0x08 mystery 4-short
            uint32_t f14;     // +0x14 flag mask
            uint64_t f60;     // +0x60 mystery
            int      raw30;   // +0x30: 1 = magic 0x1, 0 = use mach_vm VA, 2 = pinned VA
        };
        struct shape shapes[] = {
            // (1) clean — what original test used
            { "clean f14=0x430 zeros",         0,                    0x0430, 0, 0 },
            // (2) try WS f14
            { "clean f14=0x470 zeros",         0,                    0x0470, 0, 0 },
            // (3) WS flags struct only
            { "WS flags struct f14=0x470",     0x0001000100010001,   0x0470, 0, 0 },
            // (4) WS flags + f60=1
            { "WS flags + f60=1 f14=0x470",    0x0001000100010001,   0x0470, 1, 0 },
            // (5) WS f60 only
            { "f60=1 only f14=0x470",          0,                    0x0470, 1, 0 },
            // (6) full WS shape with magic 0x30 = 0x1
            { "full WS shape (+0x30=0x1)",     0x0001000100010001,   0x0470, 1, 1 },
            // (7) full WS shape + pinned VA at +0x30
            { "full WS shape (pinned +0x30)",  0x0001000100010001,   0x0470, 1, 2 },
            { NULL, 0, 0, 0, 0 }
        };
        for (int si = 0; shapes[si].name; ++si) {
            uint64_t user_va = 0;
            kern_return_t ar = mach_vm_allocate(
                (uint64_t)(uintptr_t)mach_task_self(), &user_va, 0x4000, 0x1);
            if (ar) continue;
            memset((void*)(uintptr_t)user_va, 0, 0x4000);
            unsigned char in_args[0x68];
            unsigned char out_args[0x50];
            memset(in_args, 0, sizeof(in_args));
            memset(out_args, 0, sizeof(out_args));
            in_args[0x00] = 0x80;
            *(uint64_t *)(in_args + 0x08) = shapes[si].f08;
            *(uint32_t *)(in_args + 0x14) = shapes[si].f14;
            *(uint64_t *)(in_args + 0x60) = shapes[si].f60;
            if (shapes[si].raw30 == 1) {
                *(uint64_t *)(in_args + 0x30) = 0x1; // magic
                *(uint64_t *)(in_args + 0x38) = user_va;
                *(uint64_t *)(in_args + 0x40) = 0x4000;
            } else if (shapes[si].raw30 == 2) {
                *(uint64_t *)(in_args + 0x30) = user_va;
                *(uint64_t *)(in_args + 0x38) = user_va;
                *(uint64_t *)(in_args + 0x40) = user_va;
            } else {
                *(uint64_t *)(in_args + 0x30) = user_va;
                *(uint64_t *)(in_args + 0x40) = 0x4000;
            }
            *(uint64_t *)(in_args + 0x48) = 0x4000;
            size_t outSz = sizeof(out_args);
            kr = IOConnectCallMethod(conn, 0x9, NULL, 0,
                in_args, sizeof(in_args), NULL, NULL,
                out_args, &outSz);
            fprintf(stderr, "  shape[%d] '%s' -> kr=%#x %s\n", si, shapes[si].name, kr,
                kr == 0 ? "*** SUCCESS ***" : "(fail)");
            extern kern_return_t mach_vm_deallocate(uint64_t target, uint64_t addr, uint64_t size);
            mach_vm_deallocate((uint64_t)(uintptr_t)mach_task_self(), user_va, 0x4000);
        }
    }

    // === Trigger sel=0xa heap-create from iOS-native context ===
    // The iOS-native userland Metal builds args this way (from
    // ~/Downloads/agx-re/ios/IOGPU disasm of _IOGPUResourceCreate):
    //   args+0x00 = type byte (0 = heap, 0x80 = client buffer, 0x82 = iosurface)
    //   args+0x14 = flag mask (0x430 for iosurface, 0x0 for heap typical)
    //   args+0x40 = size (for type=0 heap) or length (for type=0x80)
    //   total inStructCnt typically 0x60 - 0x70 bytes
    //
    // Output struct: kernel writes a IOGPUResource ID/handle at args.out
    // outStructCnt = 0x50 (matches what macOS userland sends).
    if (mode == kProbeExercise) {
        unsigned char in_args[0x70];
        unsigned char out_args[0x50];
        memset(in_args, 0, sizeof(in_args));
        memset(out_args, 0, sizeof(out_args));
        // type=0 heap, size=0x10000 (64KB heap chunk like Mempool would req)
        in_args[0x00] = 0x00;
        *(uint64_t *)(in_args + 0x40) = 0x10000;
        size_t outSz = sizeof(out_args);
        // *** CRITICAL: iOS-native sel=0x9 = new_resource (NOT sel=0xa).
        // Chroot's macOS sel=0xa goes through libmachook's
        // IOConnectTranslateSelector → 0x9 → kernel's new_resource. So to
        // match what chroot's failing call REALLY hits, we call 0x9 here.
        kr = IOConnectCallMethod(conn, 0x9,
            NULL, 0,          /* scalar in */
            in_args, sizeof(in_args),
            NULL, NULL,       /* scalar out */
            out_args, &outSz);
        fprintf(stderr, "  sel=0x9 type=0 size=0x10000 (raw, no pre-setup) -> kr=0x%x %s\n",
            kr, kr == 0 ? "(SUCCESS!)" : "(FAIL)");
        if (kr == 0) {
            uint32_t gid = *(uint32_t *)(out_args + 0x00);
            fprintf(stderr, "    out gid          = %#x\n", gid);
            fprintf(stderr, "    outStructCnt out = %#zx\n", outSz);
        }
    }

    // Native-reference LLDB capture (iPad13,6, iOS 16.3.1 20D67) observed
    // _IOGPUDeviceCreateWithAPIProperty(options=0x10, property="Metal") before
    // queue creation.  Reproduce that input for both the queue-only A/B and
    // the wider exercise instead of relying on a zero-filled diagnostic.
    {
        unsigned char in_p[0x10];
        memset(in_p, 0, sizeof(in_p));
        memcpy(in_p, "Metal", sizeof("Metal"));
        // RE-confirmed via _IOGPUDeviceCreateWithAPIProperty at
        // 0x1eec63a94..0x1eec63ac4: the actual wrapper uses
        // IOConnectCallStructMethod with a fixed 0x10-byte input and no
        // output, not the 0x408-byte IOConnectCallMethod diagnostic used by
        // the old probe.
        kr = IOConnectCallStructMethod(conn, 0x6,
            in_p, 0x10, NULL, NULL);
        fprintf(stderr, "  sel=0x6 set_api_property (prereq?) -> kr=0x%x %s\n",
            kr, kr == 0 ? "(SUCCESS)" : "(FAIL)");
    }
    // Retry sel=0x9 after sel=0x6 only in the explicit resource exercise.
    if (mode == kProbeExercise) {
        unsigned char in_args[0x70];
        unsigned char out_args[0x50];
        memset(in_args, 0, sizeof(in_args));
        memset(out_args, 0, sizeof(out_args));
        in_args[0x00] = 0x00;
        *(uint64_t *)(in_args + 0x40) = 0x10000;
        size_t outSz = sizeof(out_args);
        kr = IOConnectCallMethod(conn, 0x9,
            NULL, 0,
            in_args, sizeof(in_args),
            NULL, NULL,
            out_args, &outSz);
        fprintf(stderr, "  sel=0x9 AFTER sel=0x6 setup -> kr=0x%x %s\n",
            kr, kr == 0 ? "(SUCCESS — sel=0x6 IS the missing prereq)" : "(FAIL)");
    }

    // Try sel=0x7 = new_command_queue (kernel-side). Chroot fails on this.
    {
        unsigned char in_q[0x408];
        unsigned char out_q[0x10];
        memset(in_q, 0, sizeof(in_q));
        memset(out_q, 0, sizeof(out_q));
        // Runtime-confirmed via the native LLDB trace: QoS=2 and the
        // background/priority byte is zero.  The leading bytes are only a
        // diagnostic queue name in the iOS 16.3 kernel initializer.
        memcpy(in_q, "agx_iogpu_probe", sizeof("agx_iogpu_probe"));
        *(uint32_t *)(in_q + 0x400) = 2;
        in_q[0x404] = 0;
        size_t outSz = sizeof(out_q);
        kr = IOConnectCallMethod(conn, 0x7,
            NULL, 0,
            in_q, sizeof(in_q),
            NULL, NULL,
            out_q, &outSz);
        fprintf(stderr, "  sel=0x7 (queue-create) -> kr=0x%x %s\n",
            kr, kr == 0 ? "(SUCCESS)" : "(FAIL)");
        if (kr == 0 && outSz >= 0x10) {
            uint32_t queue_id = *(uint32_t *)(out_q + 0x00);
            uint64_t queue_token = *(uint64_t *)(out_q + 0x08);
            // RE-confirmed via IOGPUDevice::retainCommandQueue(unsigned):
            // Device+0x88 is the command-queue IOGPUNamespace;
            // namespace+0x10 is its pointer array and +0x28 its capacity.
            uint64_t queue_namespace = p_kread64(device + 0x88);
            uint64_t queue_array = queue_namespace
                ? p_kread64(queue_namespace + 0x10) : 0;
            uint32_t queue_capacity = queue_namespace
                ? p_kread32(queue_namespace + 0x28) : 0;
            uint64_t kernel_queue = queue_array && queue_id < queue_capacity
                ? p_kread64(queue_array + (uint64_t)queue_id * 8) : 0;
            fprintf(stderr,
                    "    queue id=%#x token=%#llx namespace=%#llx "
                    "capacity=%u kernel=%#llx\n",
                    queue_id, (unsigned long long)queue_token,
                    (unsigned long long)queue_namespace, queue_capacity,
                    (unsigned long long)kernel_queue);
            if (kernel_queue) {
                uint64_t accelerator = p_kread64(kernel_queue + 0x530);
                uint32_t work_queue_count = p_kread32(kernel_queue + 0x80c);
                uint32_t work_queue_limit = p_kread32(kernel_queue + 0x820);
                uint32_t priority = p_kread32(kernel_queue + 0x44c);
                uint32_t qos = p_kread32(kernel_queue + 0x450);
                uint32_t cfg_1870 = accelerator
                    ? p_kread32(accelerator + 0x1870) : 0;
                uint32_t cfg_56c = accelerator
                    ? p_kread32(accelerator + 0x56c) : 0;
                fprintf(stderr,
                        "    AGXCommandQueue +0x530=%#llx +0x80c=%u "
                        "+0x820=%u priority=%u qos=%u\n",
                        (unsigned long long)accelerator, work_queue_count,
                        work_queue_limit, priority, qos);
                fprintf(stderr,
                        "    accelerator config +0x1870=%u +0x56c=%u\n",
                        cfg_1870, cfg_56c);
                if (target_pid >= 0) {
                    dump_registered_queues(kernel_queue, target_pid);
                }
            }
        }
    }

    // Try sel=0x100 = device info query — should always work
    {
        unsigned char out_info[0x70];
        memset(out_info, 0, sizeof(out_info));
        size_t outSz = sizeof(out_info);
        kr = IOConnectCallMethod(conn, 0x100,
            NULL, 0, NULL, 0, NULL, NULL,
            out_info, &outSz);
        fprintf(stderr, "  sel=0x100 (device-info) -> kr=0x%x %s\n",
            kr, kr == 0 ? "(OK)" : "(FAIL)");
    }

    IOServiceClose(conn);
}

int main(int argc, char **argv) {
    fprintf(stderr, "agx_iogpu_probe — iOS-native AGX UC field reader\n");
    if (load_libjb() != 0) return 1;

    // Types 0 and 2 have hung IOServiceOpen on this device.  Keep the default
    // bounded to the native low-word type 1; explicitly requested values are
    // useful for a single controlled A/B test (for example 0x100001) but are
    // never fuzzed automatically.
    uint32_t type = 1;
    if (argc > 1) type = (uint32_t)strtoul(argv[1], NULL, 0);
    const char *match_class = argc > 2 ? argv[2] : "AGXAccelerator";
    probe_mode_t mode = kProbeFieldsOnly;
    if (argc > 3 && strcmp(argv[3], "queue") == 0) {
        mode = kProbeQueueOnly;
    } else if (argc > 3 && strcmp(argv[3], "info") == 0) {
        mode = kProbeDeviceInfoOnly;
    } else if (argc > 3 && strcmp(argv[3], "exercise") == 0) {
        mode = kProbeExercise;
    }
    int target_pid = -1;
    if (argc > 4) target_pid = (int)strtol(argv[4], NULL, 0);
    probe_one(match_class, type, mode, target_pid);
    return 0;
}
