// exec_hooks.c — auto-sign-on-exec (client side, runs inside the chroot).
//
// AMFI kills any exec of a Mach-O whose CDHash is not in the jailbreak
// trustcache (EBADEXEC / "Operation not permitted"). The privileged trustcache
// add can only happen in an iOS-platform process, so before every exec we ask
// the iOS-side `autosignd` daemon (over a unix socket) to sign + trustcache the
// target binary, then proceed with the real exec.
//
// Interposes the array/spawn exec forms (posix_spawn[p], execve, execv,
// execvp). The varargs forms (execl*) are not covered — they are rare and call
// the array forms internally within libsystem (not interposable here).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <ctype.h>
#include <unistd.h>
#include <pthread.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/un.h>
#include <sys/time.h>
#include "interpose.h"
#include "macws_macho_arch.h"

// The macOS 13 SDK shipped with this Theos setup omits libproc.h, while the
// libSystem symbol is present on the target. Keep the public ABI declaration
// local instead of importing a private SDK header.
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#define MACWS_PROC_PIDPATH_MAX 4096

#define SOCK_PATH "/tmp/autosignd.sock"   // as seen from inside the chroot

static bool exec_diagnostics_enabled(void) {
    return getenv("MACWS_RUNTIME_DIAGNOSTICS") != NULL ||
           access("/tmp/macws_runtime_diagnostics", F_OK) == 0;
}

// ── in-process cache of paths already sent to the daemon ────────────────────
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static char **g_cache = NULL;
static size_t g_cache_n = 0, g_cache_cap = 0;

static int cache_check_and_add(const char *p) {
    int present = 0;
    pthread_mutex_lock(&g_lock);
    for (size_t i = 0; i < g_cache_n; i++) {
        if (strcmp(g_cache[i], p) == 0) { present = 1; break; }
    }
    if (!present) {
        if (g_cache_n == g_cache_cap) {
            g_cache_cap = g_cache_cap ? g_cache_cap * 2 : 64;
            g_cache = realloc(g_cache, g_cache_cap * sizeof(char *));
        }
        g_cache[g_cache_n++] = strdup(p);
    }
    pthread_mutex_unlock(&g_lock);
    return present;
}

// Ask the daemon to sign + trustcache one absolute (chroot) path. Fail-open:
// any error (daemon down, timeout) just returns so the real exec still runs.
static void request_sign(const char *path) {
    if (!path || path[0] != '/') return;
    if (cache_check_and_add(path)) return;   // already requested this boot

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;

    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        char line[1100];
        int n = snprintf(line, sizeof(line), "%s\n", path);
        if (n > 0 && (size_t)n < sizeof(line)) {
            if (write(fd, line, (size_t)n) == n) {
                char ack[8];
                (void)read(fd, ack, sizeof(ack));   // wait for "OK\n" before exec
            }
        }
    }
    close(fd);
}

// Resolve a command name, including cwd-relative spellings, to an absolute
// path (malloc'd), or NULL.
static char *resolve(const char *file) {
    if (!file || !*file) return NULL;
    if (file[0] == '/') return strdup(file);

    // A path containing a slash is relative to the caller's cwd, not PATH.
    // Steam's verified-client launcher uses `exec ./steam_osx`; returning that
    // spelling unchanged made request_sign() reject it because its protocol
    // deliberately accepts only chroot-absolute paths.  Resolve the existing
    // executable before contacting autosignd so an updater-replaced image is
    // admitted before the kernel evaluates its new CodeDirectory.
    if (strchr(file, '/')) {
        char absolute[MACWS_PROC_PIDPATH_MAX];
        if (realpath(file, absolute)) return strdup(absolute);
        return NULL;
    }

    const char *path = getenv("PATH");
    if (!path) path = "/usr/bin:/bin:/usr/sbin:/sbin";
    char *dup = strdup(path);
    if (!dup) return NULL;
    char *out = NULL;
    for (char *dir = strtok(dup, ":"); dir; dir = strtok(NULL, ":")) {
        char cand[1024];
        if (snprintf(cand, sizeof(cand), "%s/%s", dir, file) >= (int)sizeof(cand)) continue;
        struct stat st;
        if (stat(cand, &st) == 0 && (st.st_mode & S_IXUSR)) {
            char absolute[MACWS_PROC_PIDPATH_MAX];
            out = realpath(cand, absolute) ? strdup(absolute) : strdup(cand);
            break;
        }
    }
    free(dup);
    return out;
}

static void ensure_signed(const char *file) {
    char *abs = resolve(file);
    if (abs) { request_sign(abs); free(abs); }
}

// ── keep exactly one architecture-matched libmachook across exec ───────────
//
// Runtime evidence from WindowServer-2026-07-22-234833.ips shows that this
// device's dyld loads both the ARM64/ALL and ARM64/E thin inserts into the same
// ARM64/ALL process.  That gives each dylib its own static state and installs
// stateful Metal/VNC hooks twice.  launchdchrootexec selects one dylib for the
// initial executable; these helpers preserve the same invariant when that
// process launches a child of a different subtype.

static const char *insert_for_target(const char *path, macws_macho_arch_t *out_arch) {
    macws_macho_arch_t arch = macws_macho_arch_for_path(path);
    const char *insert = macws_insert_dylib_for_arch(arch);
    if (!insert) {
#if defined(__arm64e__)
        arch = MACWS_ARCH_ARM64E;
#else
        arch = MACWS_ARCH_ARM64;
#endif
        insert = macws_insert_dylib_for_arch(arch);
        if (exec_diagnostics_enabled()) {
            fprintf(stderr,
                "#### exec arch-select: unknown Mach-O subtype for %s; keeping %s slice\n",
                path ? path : "(null)", macws_arch_name(arch));
        }
    }
    if (out_arch) *out_arch = arch;
    return insert;
}

typedef struct {
    char **items;
    char *insert_entry;
} selected_env_t;

// codex-code-mode-host embeds V8 and creates the isolate lazily on the first
// session/execute request. Runtime-confirmed on iPadOS 16.3 with host UUID
// 4D33D3D9-A8E6-3023-9E9B-53FA38F8CE89: the unmodified launch environment
// fails 4/4 times in IsolateGroup::EnsureCodeRange, while the same framed IPC
// request completes 4/4 times with both existing W^X compatibility adapters.
// Scope that required launch contract to the helper executable itself so it
// also holds when Codex, app-server, a shell, or an MCP caller starts it.
static bool is_codex_code_mode_host(const char *path) {
    if (!path || !*path) return false;
    const char *basename = strrchr(path, '/');
    basename = basename ? basename + 1 : path;
    return strcmp(basename, "codex-code-mode-host") == 0;
}

static bool env_key_matches(const char *entry, const char *key) {
    if (!entry || !key) return false;
    size_t key_len = strlen(key);
    return strncmp(entry, key, key_len) == 0 && entry[key_len] == '=';
}

static bool is_macws_insert_library(const char *path) {
    return path &&
        (strcmp(path, "/usr/local/lib/libmachook.dylib") == 0 ||
         strcmp(path, "/usr/local/lib/libmachook_arm64.dylib") == 0);
}

static char *env_build_selected_insert(char *const source[],
                                       const char *selected_insert) {
    static const char prefix[] = "DYLD_INSERT_LIBRARIES=";
    const char *existing = NULL;
    for (size_t i = 0; source && source[i]; i++) {
        if (strncmp(source[i], prefix, sizeof(prefix) - 1) == 0)
            existing = source[i] + sizeof(prefix) - 1;
    }

    size_t capacity = sizeof(prefix) + strlen(selected_insert) +
        (existing ? strlen(existing) + 1 : 0);
    char *entry = calloc(capacity, 1);
    if (!entry) return NULL;
    snprintf(entry, capacity, "%s%s", prefix, selected_insert);

    // The architecture selector owns only libmachook's slice. Preserve every
    // additional dylib explicitly requested by the parent while removing both
    // possible libmachook spellings first. Runtime-confirmed with Stray PID
    // 87905: the prior blanket replacement discarded Steam's trusted thin
    // steamloader/gameoverlayrenderer entries, so no overlay process was even
    // requested. Keeping the other entries restores the caller's launch
    // contract without enabling an overlay for processes that did not ask.
    char *copy = existing ? strdup(existing) : NULL;
    char *cursor = NULL;
    for (char *item = copy ? strtok_r(copy, ":", &cursor) : NULL;
         item; item = strtok_r(NULL, ":", &cursor)) {
        if (!*item || is_macws_insert_library(item)) continue;
        strlcat(entry, ":", capacity);
        strlcat(entry, item, capacity);
    }
    free(copy);
    return entry;
}

static bool terminal_direct_bash_child(
    const char *path, char *const envp[]) {
    if (!path || (strcmp(path, "/bin/bash") != 0 &&
                  strcmp(path, "/bin/sh") != 0)) {
        return false;
    }
    // TERM_PROGRAM is inherited by commands run inside a terminal. Pair it
    // with the actual parent executable so a user's later `bash` command is
    // never rewritten.
    static const char terminal_suffix[] =
        "/Terminal.app/Contents/MacOS/Terminal";
    // The hook executes in Terminal's forkpty child immediately before exec.
    // Runtime `ps` proves that child's PPID is the live Terminal PID, while a
    // later user-launched bash has a shell PPID. Resolve that kernel process
    // relationship directly instead of consulting SETEXEC-stale libc/dyld
    // identity caches in the fork child.
    char parent_path[MACWS_PROC_PIDPATH_MAX];
    int parent_path_len = proc_pidpath(
        getppid(), parent_path, sizeof(parent_path));
    if (parent_path_len <= 0) return false;
    parent_path[sizeof(parent_path) - 1] = '\0';
    size_t parent_len = strlen(parent_path);
    size_t suffix_len = sizeof(terminal_suffix) - 1;
    if (parent_len < suffix_len ||
        strcmp(parent_path + parent_len - suffix_len, terminal_suffix) != 0) {
        return false;
    }

    extern char **environ;
    char *const *source = envp ? envp : environ;
    for (size_t i = 0; source && source[i]; i++) {
        if (strcmp(source[i], "TERM_PROGRAM=Apple_Terminal") == 0)
            return true;
    }
    return false;
}

static selected_env_t env_select_insert(char *const envp[], const char *path) {
    extern char **environ;
    char *const *source = envp ? envp : environ;
    size_t count = 0;
    while (source && source[count]) count++;

    // Runtime-confirmed on iPadOS 16.3 with Terminal 447: Terminal's direct
    // /bin/bash children receive TERM_PROGRAM=Apple_Terminal but no HOME,
    // USER, SHELL, or useful chroot PATH. With HOME absent, bash cannot select
    // either /Users/root/.bashrc or the root account's login profile. Repair
    // that launch contract here, at the parent/child exec boundary, rather
    // than changing bash itself or relying on a particular Terminal profile.
    bool terminal_bash = terminal_direct_bash_child(path, envp);
    bool code_mode_host = is_codex_code_mode_host(path);

    selected_env_t selected = {0};
    // Insert dylib + optional Terminal shell entries + optional Code Mode JIT
    // entries + trailing NULL.
    size_t extra = (terminal_bash ? 6 : 2) + (code_mode_host ? 2 : 0);
    selected.items = calloc(count + extra, sizeof(char *));
    const char *insert = insert_for_target(path, NULL);
    selected.insert_entry = env_build_selected_insert(source, insert);
    if (!selected.items || !selected.insert_entry) {
        free(selected.items);
        free(selected.insert_entry);
        selected.items = NULL;
        selected.insert_entry = NULL;
        return selected;
    }

    static const char prefix[] = "DYLD_INSERT_LIBRARIES=";
    size_t out = 0;
    for (size_t i = 0; i < count; i++) {
        if (strncmp(source[i], prefix, sizeof(prefix) - 1) == 0)
            continue;
        if (terminal_bash &&
            (strncmp(source[i], "HOME=", 5) == 0 ||
             strncmp(source[i], "USER=", 5) == 0 ||
             strncmp(source[i], "SHELL=", 6) == 0 ||
             strncmp(source[i], "PATH=", 5) == 0)) {
            continue;
        }
        if (code_mode_host &&
            (env_key_matches(source[i], "MACWS_JIT_MPROTECT_COMPAT") ||
             env_key_matches(source[i], "MACWS_JIT_FAULT_WRITE_COMPAT"))) {
            continue;
        }
        selected.items[out++] = source[i];
    }
    if (terminal_bash) {
        selected.items[out++] = "HOME=/Users/root";
        selected.items[out++] = "USER=root";
        selected.items[out++] = "SHELL=/bin/bash";
        selected.items[out++] =
            "PATH=/opt/local/bin:/opt/local/sbin:/usr/local/bin:"
            "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    }
    if (code_mode_host) {
        selected.items[out++] = "MACWS_JIT_MPROTECT_COMPAT=1";
        selected.items[out++] = "MACWS_JIT_FAULT_WRITE_COMPAT=1";
    }
    selected.items[out++] = selected.insert_entry;
    selected.items[out] = NULL;
    return selected;
}

static void env_selected_free(selected_env_t *selected) {
    if (!selected) return;
    free(selected->insert_entry);
    free(selected->items);
    selected->insert_entry = NULL;
    selected->items = NULL;
}

static pthread_mutex_t g_exec_env_lock = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    char *old_value;
    int had_old_value;
    char *old_jit_mprotect;
    int had_old_jit_mprotect;
    char *old_jit_fault_write;
    int had_old_jit_fault_write;
    int managed_codex_jit;
} saved_insert_t;

static void save_environment_value(const char *key, char **old_value,
                                   int *had_old_value) {
    const char *old = getenv(key);
    if (!old) return;
    char *copy = strdup(old);
    if (!copy) return;
    *old_value = copy;
    *had_old_value = 1;
}

static saved_insert_t process_env_select_insert(const char *path) {
    saved_insert_t saved = {0};
    const char *old = getenv("DYLD_INSERT_LIBRARIES");
    if (old) {
        saved.old_value = strdup(old);
        saved.had_old_value = 1;
    }
    extern char **environ;
    char *entry = env_build_selected_insert(
        environ, insert_for_target(path, NULL));
    static const char prefix[] = "DYLD_INSERT_LIBRARIES=";
    if (entry) {
        setenv("DYLD_INSERT_LIBRARIES", entry + sizeof(prefix) - 1, 1);
        free(entry);
    } else {
        setenv("DYLD_INSERT_LIBRARIES", insert_for_target(path, NULL), 1);
    }
    if (is_codex_code_mode_host(path)) {
        saved.managed_codex_jit = 1;
        save_environment_value("MACWS_JIT_MPROTECT_COMPAT",
            &saved.old_jit_mprotect, &saved.had_old_jit_mprotect);
        save_environment_value("MACWS_JIT_FAULT_WRITE_COMPAT",
            &saved.old_jit_fault_write, &saved.had_old_jit_fault_write);
        setenv("MACWS_JIT_MPROTECT_COMPAT", "1", 1);
        setenv("MACWS_JIT_FAULT_WRITE_COMPAT", "1", 1);
    }
    return saved;
}

static void restore_environment_value(const char *key, char *old_value,
                                      int had_old_value) {
    if (had_old_value && old_value)
        setenv(key, old_value, 1);
    else
        unsetenv(key);
    free(old_value);
}

static void process_env_restore_insert(saved_insert_t *saved) {
    if (saved->had_old_value && saved->old_value)
        setenv("DYLD_INSERT_LIBRARIES", saved->old_value, 1);
    else
        unsetenv("DYLD_INSERT_LIBRARIES");
    free(saved->old_value);
    if (saved->managed_codex_jit) {
        restore_environment_value("MACWS_JIT_MPROTECT_COMPAT",
            saved->old_jit_mprotect, saved->had_old_jit_mprotect);
        restore_environment_value("MACWS_JIT_FAULT_WRITE_COMPAT",
            saved->old_jit_fault_write, saved->had_old_jit_fault_write);
    }
}

// VS Code's macOS shell-environment resolver starts an interactive login
// shell, then asks that shell to exec the full Electron binary in Node mode
// solely to print:
//
//     <12-hex-token> + JSON.stringify(process.env) + <same-token>
//
// Runtime evidence on this iPad shows the otherwise non-GUI Electron child
// reserves 24.5 GiB of VM before aborting at Oilpan's CagedHeap reservation.
// Preserve the exact resolver protocol at the exec boundary, after the login
// shell has made all of its environment changes, without starting Chromium.
// The four independent predicates below keep normal VS Code main/render/GPU
// execs on the ordinary libmachook + native-AGX path.
static bool env_has_exact(char *const envp[], const char *entry) {
    extern char **environ;
    char *const *source = envp ? envp : environ;
    for (size_t i = 0; source && source[i]; i++) {
        if (strcmp(source[i], entry) == 0) return true;
    }
    return false;
}

static bool path_has_suffix(const char *path, const char *suffix) {
    if (!path || !suffix) return false;
    size_t path_len = strlen(path);
    size_t suffix_len = strlen(suffix);
    return path_len >= suffix_len &&
        strcmp(path + path_len - suffix_len, suffix) == 0;
}

// Steam's overlay helper is intentionally short-lived when its launch
// contract is incomplete, and the client only reports it later as an
// "unknown" reaped PID.  Keep this diagnostic behind a filesystem sentinel
// so ordinary production exec/wait traffic pays only one access() for the
// exact helper path.  The output records evidence; it does not alter argv,
// environment, process status, or Steam's retry policy.
static bool steam_overlay_spawn_diagnostics_enabled(const char *path) {
    return path_has_suffix(path, "/gameoverlayui") &&
        access("/tmp/macws_steam_overlay_spawn_diag", F_OK) == 0;
}

static void steam_overlay_dump_spawn(
    const char *api, const char *path, char *const argv[],
    char *const envp[]) {
    fprintf(stderr, "#### STEAM-OVERLAY-SPAWN api=%s path=%s argv=",
        api ? api : "(null)", path ? path : "(null)");
    for (size_t i = 0; argv && argv[i] && i < 32; i++)
        fprintf(stderr, "%s[%zu]=<%.512s>", i ? " " : "", i, argv[i]);
    fputc('\n', stderr);

    static const char *const prefixes[] = {
        "DYLD_INSERT_LIBRARIES=", "SteamAppId=", "SteamGameId=",
        "SteamOverlayGameId=", "STEAM_GAME_PIDS=", "HOME=", "USER=",
        "LOGNAME=", "TMPDIR=", "PATH=", NULL
    };
    fprintf(stderr, "#### STEAM-OVERLAY-SPAWN env=");
    for (size_t i = 0; envp && envp[i]; i++) {
        for (size_t j = 0; prefixes[j]; j++) {
            size_t length = strlen(prefixes[j]);
            if (strncmp(envp[i], prefixes[j], length) == 0) {
                fprintf(stderr, "<%.1024s> ", envp[i]);
                break;
            }
        }
    }
    fputc('\n', stderr);
    fflush(stderr);
}

static pthread_mutex_t g_steam_overlay_pid_lock = PTHREAD_MUTEX_INITIALIZER;
static pid_t g_steam_overlay_pids[16];

static void steam_overlay_remember_pid(pid_t pid) {
    if (pid <= 0) return;
    pthread_mutex_lock(&g_steam_overlay_pid_lock);
    for (size_t i = 0; i < sizeof(g_steam_overlay_pids) /
                            sizeof(g_steam_overlay_pids[0]); i++) {
        if (g_steam_overlay_pids[i] == 0) {
            g_steam_overlay_pids[i] = pid;
            break;
        }
    }
    pthread_mutex_unlock(&g_steam_overlay_pid_lock);
}

static bool steam_overlay_forget_pid(pid_t pid) {
    bool found = false;
    pthread_mutex_lock(&g_steam_overlay_pid_lock);
    for (size_t i = 0; i < sizeof(g_steam_overlay_pids) /
                            sizeof(g_steam_overlay_pids[0]); i++) {
        if (g_steam_overlay_pids[i] == pid) {
            g_steam_overlay_pids[i] = 0;
            found = true;
            break;
        }
    }
    pthread_mutex_unlock(&g_steam_overlay_pid_lock);
    return found;
}

static bool vscode_shell_env_printer_request(
    const char *path, char *const argv[], char *const envp[], char token[13]) {
    static const char electron_suffix[] =
        "/Applications/Visual Studio Code.app/Contents/MacOS/Electron";
    if (!path_has_suffix(path, electron_suffix) ||
        !env_has_exact(envp, "VSCODE_RESOLVING_ENVIRONMENT=1") ||
        !env_has_exact(envp, "ELECTRON_RUN_AS_NODE=1")) {
        return false;
    }

    const char *expression = NULL;
    for (size_t i = 0; argv && argv[i]; i++) {
        if (strcmp(argv[i], "-p") == 0 && argv[i + 1]) {
            expression = argv[i + 1];
            break;
        }
    }
    if (!expression || !strstr(expression, "JSON.stringify(process.env)"))
        return false;

    for (const char *p = expression; *p; p++) {
        if (!isxdigit((unsigned char)*p) ||
            (p != expression && isxdigit((unsigned char)p[-1]))) {
            continue;
        }
        size_t run = 0;
        while (isxdigit((unsigned char)p[run])) run++;
        if (run >= 12) {
            memcpy(token, p, 12);
            token[12] = '\0';
            return true;
        }
    }
    return false;
}

static void write_all(int fd, const char *bytes, size_t length) {
    while (length) {
        ssize_t written = write(fd, bytes, length);
        if (written <= 0) _exit(125);
        bytes += (size_t)written;
        length -= (size_t)written;
    }
}

static void write_json_string(int fd, const char *bytes, size_t length) {
    static const char hex[] = "0123456789abcdef";
    write_all(fd, "\"", 1);
    for (size_t i = 0; i < length; i++) {
        unsigned char c = (unsigned char)bytes[i];
        switch (c) {
            case '\"': write_all(fd, "\\\"", 2); break;
            case '\\': write_all(fd, "\\\\", 2); break;
            case '\b': write_all(fd, "\\b", 2); break;
            case '\f': write_all(fd, "\\f", 2); break;
            case '\n': write_all(fd, "\\n", 2); break;
            case '\r': write_all(fd, "\\r", 2); break;
            case '\t': write_all(fd, "\\t", 2); break;
            default:
                if (c < 0x20) {
                    char escaped[6] = {'\\', 'u', '0', '0',
                                       hex[c >> 4], hex[c & 0xf]};
                    write_all(fd, escaped, sizeof(escaped));
                } else {
                    write_all(fd, (const char *)&bytes[i], 1);
                }
                break;
        }
    }
    write_all(fd, "\"", 1);
}

__attribute__((noreturn)) static void vscode_shell_env_print(
    char *const envp[], const char token[13]) {
    extern char **environ;
    char *const *source = envp ? envp : environ;
    if (exec_diagnostics_enabled()) {
        fprintf(stderr,
            "#### VSCODE-SHELL-ENV exec adapter: emitting login-shell JSON "
            "without Chromium startup\n");
        fflush(stderr);
    }

    write_all(STDOUT_FILENO, token, 12);
    write_all(STDOUT_FILENO, "{", 1);
    bool first = true;
    for (size_t i = 0; source && source[i]; i++) {
        const char *equals = strchr(source[i], '=');
        if (!equals) continue;
        if (!first) write_all(STDOUT_FILENO, ",", 1);
        first = false;
        write_json_string(STDOUT_FILENO, source[i],
                          (size_t)(equals - source[i]));
        write_all(STDOUT_FILENO, ":", 1);
        write_json_string(STDOUT_FILENO, equals + 1, strlen(equals + 1));
    }
    write_all(STDOUT_FILENO, "}", 1);
    write_all(STDOUT_FILENO, token, 12);
    write_all(STDOUT_FILENO, "\n", 1);
    _exit(0);
}

// ── interposed exec family ──────────────────────────────────────────────────
// Under DYLD_INTERPOSE, a call to the original symbol from within this image is
// NOT re-interposed by dyld, so calling e.g. execve() here invokes the real one
// (matching the project's existing os_log_hooks pattern). Do not use dlsym here.

static int my_posix_spawn(pid_t *pid, const char *path,
                          const posix_spawn_file_actions_t *fa,
                          const posix_spawnattr_t *attr,
                          char *const argv[], char *const envp[]) {
    ensure_signed(path);
    selected_env_t selected = env_select_insert(envp, path);
    bool overlay_diag = steam_overlay_spawn_diagnostics_enabled(path);
    char *terminal_argv[] = {
        argv && argv[0] ? argv[0] : (char *)"/bin/bash",
        (char *)"-c",
        (char *)". /Users/root/.bashrc; exec /bin/bash -i",
        NULL
    };
    // Terminal 447's direct shell is runtime-confirmed as argv={/bin/bash}
    // with no HOME and with bash startup-file processing inactive. Execute
    // the requested file explicitly in a short-lived parent shell, then exec
    // the real interactive shell in-place. Exported environment from .bashrc
    // survives the exec; later user-launched bash processes are untouched.
    char *const *selected_argv = argv;
    if (terminal_direct_bash_child(path, envp) && argv && !argv[1])
        selected_argv = terminal_argv;
    if (overlay_diag)
        steam_overlay_dump_spawn("posix_spawn", path, selected_argv,
            selected.items ? selected.items : envp);
    int result = posix_spawn(pid, path, fa, attr, selected_argv,
        selected.items ? selected.items : envp);
    if (overlay_diag) {
        pid_t child = result == 0 && pid ? *pid : -1;
        fprintf(stderr,
            "#### STEAM-OVERLAY-SPAWN result=%d child=%d\n",
            result, child);
        fflush(stderr);
        if (result == 0) steam_overlay_remember_pid(child);
    }
    env_selected_free(&selected);
    return result;
}

static int my_posix_spawnp(pid_t *pid, const char *file,
                           const posix_spawn_file_actions_t *fa,
                           const posix_spawnattr_t *attr,
                           char *const argv[], char *const envp[]) {
    ensure_signed(file);
    char *resolved = resolve(file);
    selected_env_t selected = env_select_insert(envp, resolved ? resolved : file);
    bool overlay_diag = steam_overlay_spawn_diagnostics_enabled(
        resolved ? resolved : file);
    if (overlay_diag)
        steam_overlay_dump_spawn("posix_spawnp", resolved ? resolved : file,
            argv, selected.items ? selected.items : envp);
    int result = posix_spawnp(pid, file, fa, attr, argv,
        selected.items ? selected.items : envp);
    if (overlay_diag) {
        pid_t child = result == 0 && pid ? *pid : -1;
        fprintf(stderr,
            "#### STEAM-OVERLAY-SPAWN result=%d child=%d\n",
            result, child);
        fflush(stderr);
        if (result == 0) steam_overlay_remember_pid(child);
    }
    env_selected_free(&selected);
    free(resolved);
    return result;
}

static pid_t my_waitpid(pid_t pid, int *status, int options) {
    pid_t result = waitpid(pid, status, options);
    if (result > 0 && steam_overlay_forget_pid(result)) {
        if (status && WIFEXITED(*status)) {
            fprintf(stderr,
                "#### STEAM-OVERLAY-EXIT child=%d exited=%d\n",
                result, WEXITSTATUS(*status));
        } else if (status && WIFSIGNALED(*status)) {
            fprintf(stderr,
                "#### STEAM-OVERLAY-EXIT child=%d signal=%d\n",
                result, WTERMSIG(*status));
        } else {
            fprintf(stderr,
                "#### STEAM-OVERLAY-EXIT child=%d raw-status=%d\n",
                result, status ? *status : -1);
        }
        fflush(stderr);
    }
    return result;
}

static int my_execve(const char *path, char *const argv[], char *const envp[]) {
    char token[13];
    if (vscode_shell_env_printer_request(path, argv, envp, token))
        vscode_shell_env_print(envp, token);
    ensure_signed(path);
    selected_env_t selected = env_select_insert(envp, path);
    bool overlay_diag = steam_overlay_spawn_diagnostics_enabled(path);
    char *terminal_argv[] = {
        argv && argv[0] ? argv[0] : (char *)"/bin/bash",
        (char *)"-c",
        (char *)". /Users/root/.bashrc; exec /bin/bash -i",
        NULL
    };
    char *const *selected_argv = argv;
    // Terminal uses forkpty + execve (not posix_spawn) for its live shell on
    // this build; the posix_spawn branch above remains for other profiles.
    if (terminal_direct_bash_child(path, envp) && argv && !argv[1])
        selected_argv = terminal_argv;
    if (overlay_diag)
        steam_overlay_dump_spawn("execve", path, selected_argv,
            selected.items ? selected.items : envp);
    int result = execve(path, selected_argv,
                        selected.items ? selected.items : envp);
    if (overlay_diag) {
        fprintf(stderr,
            "#### STEAM-OVERLAY-SPAWN execve-return=%d\n", result);
        fflush(stderr);
    }
    env_selected_free(&selected);
    return result;
}

static int my_execv(const char *path, char *const argv[]) {
    char token[13];
    if (vscode_shell_env_printer_request(path, argv, NULL, token))
        vscode_shell_env_print(NULL, token);
    ensure_signed(path);
    pthread_mutex_lock(&g_exec_env_lock);
    saved_insert_t saved = process_env_select_insert(path);
    bool overlay_diag = steam_overlay_spawn_diagnostics_enabled(path);
    if (overlay_diag) {
        extern char **environ;
        steam_overlay_dump_spawn("execv", path, argv, environ);
    }
    int result = execv(path, argv);
    if (overlay_diag) {
        fprintf(stderr, "#### STEAM-OVERLAY-SPAWN execv-return=%d\n",
            result);
        fflush(stderr);
    }
    process_env_restore_insert(&saved);
    pthread_mutex_unlock(&g_exec_env_lock);
    return result;
}

static int my_execvp(const char *file, char *const argv[]) {
    char *resolved = resolve(file);
    char token[13];
    if (vscode_shell_env_printer_request(
            resolved ? resolved : file, argv, NULL, token))
        vscode_shell_env_print(NULL, token);
    ensure_signed(file);
    pthread_mutex_lock(&g_exec_env_lock);
    saved_insert_t saved = process_env_select_insert(resolved ? resolved : file);
    bool overlay_diag = steam_overlay_spawn_diagnostics_enabled(
        resolved ? resolved : file);
    if (overlay_diag) {
        extern char **environ;
        steam_overlay_dump_spawn("execvp", resolved ? resolved : file,
            argv, environ);
    }
    int result = execvp(file, argv);
    if (overlay_diag) {
        fprintf(stderr, "#### STEAM-OVERLAY-SPAWN execvp-return=%d\n",
            result);
        fflush(stderr);
    }
    process_env_restore_insert(&saved);
    pthread_mutex_unlock(&g_exec_env_lock);
    free(resolved);
    return result;
}

DYLD_INTERPOSE(my_posix_spawn, posix_spawn);
DYLD_INTERPOSE(my_posix_spawnp, posix_spawnp);
DYLD_INTERPOSE(my_waitpid, waitpid);
DYLD_INTERPOSE(my_execve, execve);
DYLD_INTERPOSE(my_execv, execv);
DYLD_INTERPOSE(my_execvp, execvp);
