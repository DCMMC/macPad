cd $(realpath $HOME/../..)/usr/macOS

# Several provisioning steps below create paths in the mounted macOS volume
# before the historical late assignment near the toolchain section.  Keep the
# mount root authoritative from the first statement: after a reboot the
# Asphalt mobile-container step otherwise expands an unset ROOTFS to
# /Users/mobile on iOS, where the sealed root is read-only, and aborts before
# the generic /Applications trustcache restoration runs.
ROOTFS=/var/mnt/rootfs

# Cover the boot-scanned directory as well as generated GUI jobs. Exact
# historical jobs are archived without changing an already-running process.
/var/jb/usr/bin/python3 "${BASH_SOURCE[0]%/*}/macws_retire_legacy_boot_jobs.py" || {
    echo "[ERROR] Unresolved legacy MacWS boot launch configuration." >&2
    exit 1
}

# Invalidate the same-bootsession Settings ExtensionKit verification cache
# before an installation can replace any of its signed runtime dependencies.
rm -f /tmp/macws-settings-runtime.boot-ready \
      /tmp/macws-base-trust.boot-ready
# The repair mutates project and system-app runtime, not the signed
# third-party bundles under /Applications. It registers every CodeDirectory it
# does change below, so invalidating the independent application-trust marker
# only forces the next ordinary restart to re-run ldid over 1156 unchanged
# images. A real userspace/iOS reboot still changes kern.boottime and naturally
# selects the complete cold-boot trust path.

ENT="/var/jb/usr/macOS/bin/entitlements.plist"
CFPREFSD_ENT="/var/jb/usr/macOS/bin/cfprefsd-entitlements.plist"
EXTENSIONKIT_ENT="/var/jb/usr/macOS/bin/extensionkitservice-entitlements.plist"
APPEARANCE_ENT="/var/jb/usr/macOS/bin/appearance-extension-entitlements.plist"
CORELOCATIONAGENT_NATIVE_ENT="/var/jb/usr/macOS/bin/corelocationagent-native-entitlements.plist"
LOCATIOND_NATIVE_ENT="/var/jb/usr/macOS/bin/locationd-native-entitlements.plist"
GEOD_NATIVE_ENT="/var/jb/usr/macOS/bin/geod-native-entitlements.plist"
DISKARBITRATIOND_NATIVE_ENT="/var/jb/usr/macOS/bin/diskarbitrationd-native-entitlements.plist"
INTEROP_LOCATION_ENT="/var/jb/usr/macOS/bin/interop-location-entitlements.plist"
COREAUDIOD_AUDIO_ENT="/var/jb/usr/macOS/bin/coreaudiod-ios-audio.entitlements.plist"
LOAD_DYLIB_PATCHER="/var/jb/usr/macOS/bin/add_macho_load_dylib.py"
CODE_REQUIREMENT_WRITER="/var/jb/usr/macOS/bin/write_code_requirement.py"
WEATHER_PREPARER="/var/jb/usr/macOS/bin/prepare_weather_app.py"
WINDOWSERVER_PREPARER="/var/jb/usr/macOS/bin/prepare_ventura_windowserver.py"
ASPHALT_CA_INTERMEDIATE="/var/jb/usr/macOS/share/certificates/SectigoPublicServerAuthenticationCAOVR36.pem"
ASPHALT_OPENSSL_CONFIG="/var/jb/usr/macOS/share/openssl/openssl.cnf"
MACOS_CA_BUNDLE="/var/mnt/rootfs/etc/ssl/cert.pem"
ASPHALT_CA_BUNDLE="/var/mnt/rootfs/usr/local/ssl/cert.pem"
ASPHALT_OPENSSL_CONFIG_DEST="/var/mnt/rootfs/usr/local/ssl/openssl.cnf"
SUBLIME_SETTINGS_TEMPLATE="/var/jb/usr/macOS/share/sublime/Preferences.sublime-settings"

install_sublime_software_renderer_default() {
    local sublime_binary="$ROOTFS/Applications/Sublime Text.app/Contents/MacOS/sublime_text"
    local settings_directory="$ROOTFS/var/root/Library/Application Support/Sublime Text/Packages/User"
    local settings_path="$settings_directory/Preferences.sublime-settings"
    [ -x "$sublime_binary" ] || return 0
    [ -f "$SUBLIME_SETTINGS_TEMPLATE" ] || return 1

    # Sublime 4200's shipped Preferences (OSX).sublime-settings explicitly
    # selects OpenGL. Runtime sampling on iPad13,6 (2026-09-08) found 547/748
    # main-thread samples in CAOpenGLLayer and 534/748 in Sublime's
    # drawInCGLContext:, backed by GLRendererFloat. Install Sublime's supported
    # CPU-rendering setting only for a pristine profile. An existing User
    # preferences file is an explicit user choice and is never rewritten.
    if [ ! -e "$settings_path" ]; then
        mkdir -p "$settings_directory" || return 1
        cp "$SUBLIME_SETTINGS_TEMPLATE" "$settings_path" || return 1
        chown root:wheel "$settings_path" 2>/dev/null || true
        chmod 0644 "$settings_path" || return 1
        echo '[INFO] installed MacWS Sublime CPU-renderer default'
    fi
}

MACHO_PATCHER="/var/jb/usr/macOS/bin/set_macos_version.py"
OBJC_TRAMPOLINE_PATCHER="/var/jb/usr/macOS/bin/ensure_objc_trampolines_arm64.py"
LIBMACHOOK="/var/jb/usr/macOS/lib/libmachook.dylib"
LIBMACHOOK_ARM64="/var/jb/usr/macOS/lib/libmachook_arm64.dylib"
LIPO="/var/jb/usr/bin/lipo"

# Keep App-driven repair self-contained. Package installation normally fixes
# this first, but running it here also repairs older installs. Do not re-sign
# an already-correct thin library on every repair: this ldid build can change
# its CDHash across passes, which would accumulate obsolete trustcache entries.
split_libmachook=0
if [ -f "$LIBMACHOOK" ] && [ -f "$MACHO_PATCHER" ]; then
    if "$LIPO" -info "$LIBMACHOOK" 2>&1 | grep -q 'Architectures in the fat file'; then
        /var/jb/usr/bin/python3 "$MACHO_PATCHER" "$LIBMACHOOK" || exit 1
        tmp_arm64e="${LIBMACHOOK}.arm64e-new-$$"
        tmp_arm64="${LIBMACHOOK_ARM64}.new-$$"
        "$LIPO" "$LIBMACHOOK" -thin arm64e -output "$tmp_arm64e" || exit 1
        "$LIPO" "$LIBMACHOOK" -thin arm64 -output "$tmp_arm64" || {
            rm -f "$tmp_arm64e"
            exit 1
        }
        chmod 755 "$tmp_arm64e" "$tmp_arm64"
        mv "$tmp_arm64e" "$LIBMACHOOK"
        mv "$tmp_arm64" "$LIBMACHOOK_ARM64"
        split_libmachook=1
        echo '[INFO] split libmachook into thin arm64e + arm64 libraries'
    fi
fi
if [ ! -f "$LIBMACHOOK" ] || [ ! -f "$LIBMACHOOK_ARM64" ]; then
    echo '[ERROR] both thin libmachook slices are required' >&2
    exit 1
fi
for lib in "$LIBMACHOOK" "$LIBMACHOOK_ARM64"; do
    must_sign=$split_libmachook
    if [ -f "$MACHO_PATCHER" ]; then
        patch_output=$(/var/jb/usr/bin/python3 "$MACHO_PATCHER" "$lib") || exit 1
        echo "$patch_output"
        case "$patch_output" in
            *"patched $lib"*) must_sign=1 ;;
        esac
    fi
    if [ "$must_sign" -eq 1 ]; then
        # Two passes are required after lipo -thin; the first pass can leave
        # page hashes describing the pre-growth __LINKEDIT layout.
        /var/jb/usr/bin/ldid -S"$ENT" -M "$lib" || exit 1
        /var/jb/usr/bin/ldid -S"$ENT" -M "$lib" || exit 1
    fi
done

# ─── Trustcache optimization: cache existing hashes ─────────────────────────
# Dump trustcache once at startup to avoid repeated jbctl calls
TRUSTCACHE_FILE="/tmp/postinst_trustcache_$$"
jbctl trustcache info 2>/dev/null | tr '[:upper:]' '[:lower:]' > "$TRUSTCACHE_FILE"
trap "rm -f '$TRUSTCACHE_FILE'" EXIT

is_trusted() {
    local cdhash="$1"
    [ -z "$cdhash" ] && return 1
    grep -qi "$cdhash" "$TRUSTCACHE_FILE" 2>/dev/null
}

trust_cdhash() {
    local cdhash="$1"
    local path="$2"
    local arch="$3"
    if is_trusted "$cdhash"; then
        echo "[SKIP] $path [$arch]: $cdhash (already trusted)"
        return 0
    fi
    echo "[ADD]  $path [$arch]: $cdhash"
    jbctl trustcache add "$cdhash"
    # Add to cache so we don't re-add duplicates within this run
    echo "$cdhash" >> "$TRUSTCACHE_FILE"
}

# Sign a binary with the project entitlements AND register all its CDHashes.
# Optimized: skip re-signing if all per-arch hashes are already trusted.
sign_and_trustcache() {
    local path="$1"
    [ -f "$path" ] || return

    # Collect CDHashes per-arch (ldid -h without -arch does not output CDHash lines)
    local hashes="" h
    for arch in arm64 arm64e x86_64; do
        h=$(ldid -arch "$arch" -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
        [ -n "$h" ] && hashes="$hashes $h"
    done
    [ -z "$hashes" ] && return  # Not a Mach-O file

    # Check if ALL hashes are already trusted
    local dominated=1
    for h in $hashes; do
        if ! is_trusted "$h"; then
            dominated=0
            break
        fi
    done

    if [ "$dominated" -eq 1 ]; then
        return 0  # Silent skip - all trusted
    fi

    # Sign and collect new hashes
    ldid -S"$ENT" -M "$path" 2>/dev/null || return
    hashes=""
    for arch in arm64 arm64e x86_64; do
        h=$(ldid -arch "$arch" -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
        [ -n "$h" ] && hashes="$hashes $h"
    done

    # Add all hashes
    for h in $hashes; do
        trust_cdhash "$h" "$path" "all"
    done
}

# CoreLocationAgent refuses UUID registration unless the client has a real
# designated requirement and that requirement validates against the live
# process. ldid's default ad-hoc requirement contains certificate predicates
# that cannot hold without a signing certificate; generic -S signing can also
# leave no extractable requirement at all. Embed the explicit identifier
# requirement through ldid's raw -Q contract, then trust the resulting hashes.
# Do not re-sign a correct persistent image merely because Dopamine's dynamic
# trustcache was cleared by reboot.
sign_and_trustcache_with_identifier_requirement() {
    local path="$1"
    local identifier="$2"
    [ -f "$path" ] || return 0
    [ -f "$CODE_REQUIREMENT_WRITER" ] || return 1

    local needs_signature=0 current_entitlements="" requirement_file=""
    current_entitlements=$(ldid -e "$path" 2>/dev/null || true)
    printf '%s\n' "$current_entitlements" |
        grep -Fq '<key>com.apple.private.graphics-restart-no-kill</key>' ||
        needs_signature=1
    ldid -h "$path" 2>/dev/null |
        grep -Fqx "Identifier=$identifier" || needs_signature=1
    ldid -q "$path" 2>/dev/null | strings |
        grep -Fqx "$identifier" || needs_signature=1

    if [ "$needs_signature" -eq 1 ]; then
        requirement_file="/tmp/macws-code-requirement.$$.bin"
        /var/jb/usr/bin/python3 "$CODE_REQUIREMENT_WRITER" \
            "$identifier" "$requirement_file" || return 1
        ldid -I"$identifier" -Q"$requirement_file" -S"$ENT" -M "$path" || {
            rm -f "$requirement_file"
            return 1
        }
        ldid -I"$identifier" -Q"$requirement_file" -S"$ENT" -M "$path" || {
            rm -f "$requirement_file"
            return 1
        }
        rm -f "$requirement_file"
    fi

    ldid -q "$path" 2>/dev/null | strings |
        grep -Fqx "$identifier" || return 1
    local arch h
    for arch in arm64 arm64e x86_64; do
        h=$(ldid -arch "$arch" -h "$path" 2>/dev/null |
            grep CDHash= | cut -c8-)
        [ -n "$h" ] && trust_cdhash "$h" "$path" "$arch"
    done
}

prepare_sign_and_trustcache_weather() {
    local bundle='/var/mnt/rootfs/System/Applications/Weather.app'
    local path="$bundle/Contents/MacOS/Weather"
    local info="$bundle/Contents/Info.plist"
    [ -f "$path" ] || return 0
    [ -f "$info" ] || return 1
    [ -f "$WEATHER_PREPARER" ] || return 1
    [ -f "$CODE_REQUIREMENT_WRITER" ] || return 1

    local native_input="/tmp/macws-weather-native.$$.plist"
    local native_sanitized="/tmp/macws-weather-sanitized.$$.plist"
    local requirement_file="/tmp/macws-weather-requirement.$$.bin"
    ldid -arch arm64e -e "$path" > "$native_input" 2>/dev/null || {
        rm -f "$native_input" "$native_sanitized" "$requirement_file"
        return 1
    }
    /var/jb/usr/bin/python3 "$WEATHER_PREPARER" \
        entitlements "$native_input" "$native_sanitized" || {
        rm -f "$native_input" "$native_sanitized" "$requirement_file"
        return 1
    }
    /var/jb/usr/bin/python3 "$WEATHER_PREPARER" manifest "$info" || {
        rm -f "$native_input" "$native_sanitized" "$requirement_file"
        return 1
    }
    /var/jb/usr/bin/python3 "$CODE_REQUIREMENT_WRITER" \
        'com.apple.weather' "$requirement_file" || {
        rm -f "$native_input" "$native_sanitized" "$requirement_file"
        return 1
    }

    # The stock container-required boolean makes iPadOS containermanagerd
    # reject this manually carried macOS process.  Preserve every other
    # Weather capability first, then merge only the common MacWS admission
    # rights.  Two final passes settle ldid's grown __LINKEDIT page hashes.
    ldid -I'com.apple.weather' -Q"$requirement_file" \
        -S"$native_sanitized" "$path" &&
    ldid -I'com.apple.weather' -Q"$requirement_file" \
        -S"$ENT" -M "$path" &&
    ldid -I'com.apple.weather' -Q"$requirement_file" \
        -S"$ENT" -M "$path" || {
        rm -f "$native_input" "$native_sanitized" "$requirement_file"
        return 1
    }
    rm -f "$native_input" "$native_sanitized" "$requirement_file"

    local final_entitlements
    final_entitlements=$(ldid -e "$path" 2>/dev/null || true)
    printf '%s\n' "$final_entitlements" |
        grep -Fq '<key>com.apple.private.security.storage.Weather</key>' ||
        return 1
    printf '%s\n' "$final_entitlements" |
        grep -Fq '<key>com.apple.private.graphics-restart-no-kill</key>' ||
        return 1
    if printf '%s\n' "$final_entitlements" |
            grep -Fq '<key>com.apple.private.security.container-required</key>'; then
        return 1
    fi
    ldid -q "$path" 2>/dev/null | strings |
        grep -Fqx 'com.apple.weather' || return 1
    local arch h
    for arch in arm64 arm64e x86_64; do
        h=$(ldid -arch "$arch" -h "$path" 2>/dev/null |
            grep CDHash= | cut -c8-)
        [ -n "$h" ] && trust_cdhash "$h" "$path" "$arch"
    done
}

# ExtensionKit's service is admitted before autosignd can participate and its
# native private entitlements are part of the service contract.  The generic
# MacWS profile drops those rights, while the stock macOS signature is rejected
# by the iPadOS launch-constraint policy.  Preserve the service-specific
# profile and use two ldid passes so the final CodeDirectory describes the
# settled __LINKEDIT layout.
sign_and_trustcache_with_entitlements() {
    local path="$1"
    local entitlements="$2"
    local required_marker="${3:-<key>com.apple.private.extensionkit.host.any-extension</key>}"
    local identifier="${4:-}"
    [ -f "$path" ] || return 0
    [ -f "$entitlements" ] || return 1

    local hashes="" h dominated=1
    for arch in arm64 arm64e x86_64; do
        h=$(ldid -arch "$arch" -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
        [ -n "$h" ] && hashes="$hashes $h"
    done
    for h in $hashes; do
        if ! is_trusted "$h"; then
            dominated=0
            break
        fi
    done
    if [ -n "$hashes" ] && [ "$dominated" -eq 1 ] &&
       ldid -e "$path" 2>/dev/null |
           grep -Fq "$required_marker"; then
        if [ -z "$identifier" ] ||
           ldid -h "$path" 2>/dev/null |
               grep -Fqx "Identifier=$identifier"; then
            return 0
        fi
    fi

    if [ -n "$identifier" ]; then
        ldid -I"$identifier" -S"$entitlements" -M "$path" || return 1
        ldid -I"$identifier" -S"$entitlements" -M "$path" || return 1
    else
        ldid -S"$entitlements" -M "$path" || return 1
        ldid -S"$entitlements" -M "$path" || return 1
    fi
    for arch in arm64 arm64e x86_64; do
        h=$(ldid -arch "$arch" -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
        [ -n "$h" ] && trust_cdhash "$h" "$path" "$arch"
    done
    # A thin binary legitimately has no hash for the final probed
    # architectures.  Do not let the last false `[ -n "$h" ]` turn an
    # otherwise successful signing/trust operation into a function failure.
    return 0
}

# A stock service can need both its native private protocol rights and the
# MacWS admission/injection profile.  `ldid -M` merges the second profile into
# the current signature; signing with either profile alone drops the other
# half and reproduces an early sandbox or launch-constraint kill.  Validate
# both markers and the identifier before treating a persistent signature as a
# cold-start witness.  Callers that are themselves verified by a stock macOS
# agent can request an explicit identifier-only designated requirement; ldid's
# synthesized ad-hoc default contains certificate predicates that can never
# validate for our unsigned image.
sign_and_trustcache_merging_native_entitlements() {
    local path="$1"
    local native_entitlements="$2"
    local native_marker="$3"
    local identifier="$4"
    local explicit_requirement="${5:-0}"
    [ -f "$path" ] || return 0
    [ -f "$native_entitlements" ] || return 1

    local hashes="" h dominated=1 current_entitlements="" requirement_valid=1
    current_entitlements=$(ldid -e "$path" 2>/dev/null || true)
    if [ "$explicit_requirement" -eq 1 ]; then
        ldid -q "$path" 2>/dev/null | strings |
            grep -Fqx "$identifier" || requirement_valid=0
        if ldid -q "$path" 2>/dev/null | strings |
            grep -Fq 'subject.CN'; then
            requirement_valid=0
        fi
    fi
    for arch in arm64 arm64e x86_64; do
        h=$(ldid -arch "$arch" -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
        [ -n "$h" ] && hashes="$hashes $h"
    done
    for h in $hashes; do
        if ! is_trusted "$h"; then
            dominated=0
            break
        fi
    done
    if [ -n "$hashes" ] && [ "$dominated" -eq 1 ] &&
       [ "$requirement_valid" -eq 1 ] &&
       printf '%s\n' "$current_entitlements" |
           grep -Fq '<key>com.apple.private.graphics-restart-no-kill</key>' &&
       printf '%s\n' "$current_entitlements" | grep -Fq "$native_marker" &&
       ldid -h "$path" 2>/dev/null |
           grep -Fqx "Identifier=$identifier"; then
        return 0
    fi

    if [ "$explicit_requirement" -eq 1 ]; then
        local requirement_file="/tmp/macws-code-requirement.$$.bin"
        /var/jb/usr/bin/python3 "$CODE_REQUIREMENT_WRITER" \
            "$identifier" "$requirement_file" || return 1
        ldid -I"$identifier" -Q"$requirement_file" -S"$ENT" -M "$path" || {
            rm -f "$requirement_file"
            return 1
        }
        ldid -I"$identifier" -Q"$requirement_file" \
            -S"$native_entitlements" -M "$path" || {
            rm -f "$requirement_file"
            return 1
        }
        ldid -I"$identifier" -Q"$requirement_file" \
            -S"$native_entitlements" -M "$path" || {
            rm -f "$requirement_file"
            return 1
        }
        rm -f "$requirement_file"
    else
        ldid -I"$identifier" -S"$ENT" -M "$path" || return 1
        ldid -I"$identifier" -S"$native_entitlements" -M "$path" || return 1
        ldid -I"$identifier" -S"$native_entitlements" -M "$path" || return 1
    fi
    current_entitlements=$(ldid -e "$path" 2>/dev/null || true)
    printf '%s\n' "$current_entitlements" |
        grep -Fq '<key>com.apple.private.graphics-restart-no-kill</key>' || return 1
    printf '%s\n' "$current_entitlements" | grep -Fq "$native_marker" || return 1
    ldid -h "$path" 2>/dev/null |
        grep -Fqx "Identifier=$identifier" || return 1
    if [ "$explicit_requirement" -eq 1 ]; then
        ldid -q "$path" 2>/dev/null | strings |
            grep -Fqx "$identifier" || return 1
        ! ldid -q "$path" 2>/dev/null | strings |
            grep -Fq 'subject.CN' || return 1
    fi
    for arch in arm64 arm64e x86_64; do
        h=$(ldid -arch "$arch" -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
        [ -n "$h" ] && trust_cdhash "$h" "$path" "$arch"
    done
    return 0
}

add_trustcache() {
    local path="$1"
    local cdhash
    cdhash=$(ldid -arch arm64 -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
    [ -n "$cdhash" ] && trust_cdhash "$cdhash" "$path" "arm64"
}

add_arm64e_trustcache() {
    local path="$1"
    local cdhash
    cdhash=$(ldid -arch arm64e -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
    [ -n "$cdhash" ] && trust_cdhash "$cdhash" "$path" "arm64e"
}

add_x86_64_trustcache() {
    local path="$1"
    local cdhash
    cdhash=$(ldid -arch x86_64 -h "$path" 2>/dev/null | grep CDHash= | cut -c8-)
    [ -n "$cdhash" ] && trust_cdhash "$cdhash" "$path" "x86_64"
}

add_all_trustcache() {
    local path="$1"
    add_trustcache "$path"
    add_arm64e_trustcache "$path"
    add_x86_64_trustcache "$path"
}

ensure_filecoordinationd_signature() {
    local target="$ROOTFS/usr/sbin/filecoordinationd"
    local backup="${target}.macws-original"
    local temporary="${target}.macws-new.$$"
    local current_entitlements=""
    [ -f "$target" ] || return 0
    current_entitlements=$(ldid -e "$target" 2>/dev/null || true)
    if ! printf '%s\n' "$current_entitlements" |
            grep -Fq '<key>com.apple.private.graphics-restart-no-kill</key>'; then
        [ -e "$backup" ] || cp -p "$target" "$backup" || return 1
        rm -f "$temporary"
        cp -p "$target" "$temporary" || return 1
        ldid -S"$ENT" -M "$temporary" || {
            rm -f "$temporary"; return 1;
        }
        chown root:wheel "$temporary" 2>/dev/null || true
        chmod 0755 "$temporary" || return 1
        mv -f "$temporary" "$target" || return 1
        echo '[INFO] prepared filecoordinationd for chroot launch'
    fi
    add_all_trustcache "$target"
}

prepare_windowserver_runtime() {
    local target="$ROOTFS/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
    local backup="${target}.macws-original"
    local state=0
    [ -f "$target" ] || return 0
    [ -f "$WINDOWSERVER_PREPARER" ] || {
        echo '[ERROR] verified WindowServer preparation helper is missing' >&2
        return 1
    }
    if /var/jb/usr/bin/python3 "$WINDOWSERVER_PREPARER" --check "$target"; then
        state=0
    else
        state=$?
    fi
    if [ "$state" -eq 1 ]; then
        [ -e "$backup" ] || cp -p "$target" "$backup" || return 1
        /var/jb/usr/bin/python3 "$WINDOWSERVER_PREPARER" "$target" || return 1
    elif [ "$state" -ne 0 ]; then
        return "$state"
    fi
    sign_and_trustcache "$target"
}

# iPadOS rejects the stock Ventura CT policy on these early audio images before
# autosignd can run. Replace a stale signature through a fresh inode so AMFI
# cannot retain the old vnode's code-signing state, then trust the exact final
# CodeDirectory. AudioComponentRegistrar is a standalone daemon and needs the
# project launch profile; the two Audio Unit bundles are dlopen images and must
# remain entitlement-free.
ensure_audio_component_image() {
    local path="$1" identifier="$2" mode="$3"
    local current_entitlements="" temporary="" valid=1
    [ -f "$path" ] || return 1
    current_entitlements=$(ldid -e "$path" 2>/dev/null || true)
    ldid -h "$path" 2>/dev/null |
        grep -Fqx "Identifier=$identifier" || valid=0
    case "$mode" in
        daemon)
            printf '%s\n' "$current_entitlements" |
                grep -Fq '<key>com.apple.private.graphics-restart-no-kill</key>' ||
                valid=0
            ;;
        plugin)
            [ -z "$current_entitlements" ] || valid=0
            ;;
        *) return 1 ;;
    esac
    if [ "$valid" -ne 1 ]; then
        temporary="${path}.macws-new.$$"
        rm -f "$temporary"
        cp -p "$path" "$temporary" || return 1
        if [ "$mode" = daemon ]; then
            ldid -I"$identifier" -S"$ENT" -M "$temporary" || {
                rm -f "$temporary"; return 1;
            }
            ldid -I"$identifier" -S"$ENT" -M "$temporary" || {
                rm -f "$temporary"; return 1;
            }
        else
            ldid -I"$identifier" -S "$temporary" || {
                rm -f "$temporary"; return 1;
            }
            ldid -I"$identifier" -S "$temporary" || {
                rm -f "$temporary"; return 1;
            }
        fi
        chmod --reference="$path" "$temporary" 2>/dev/null || true
        chown --reference="$path" "$temporary" 2>/dev/null || true
        mv -f "$temporary" "$path" || return 1
    fi
    add_all_trustcache "$path"
}

ensure_coreaudiod_runtime() {
    local path="$ROOTFS/usr/sbin/coreaudiod"
    local dylib='/usr/local/lib/libmachook.dylib'
    local temporary="" entitlements="" valid=1
    [ -f "$path" ] || return 1
    [ -f "$COREAUDIOD_AUDIO_ENT" ] || return 1
    [ -f "$LOAD_DYLIB_PATCHER" ] || return 1
    strings "$path" 2>/dev/null | grep -Fqx "$dylib" || valid=0
    entitlements=$(ldid -e "$path" 2>/dev/null || true)
    printf '%s\n' "$entitlements" |
        grep -Fq '<key>com.apple.private.graphics-restart-no-kill</key>' ||
        valid=0
    printf '%s\n' "$entitlements" |
        grep -Fq '<key>com.apple.private.audio.hal.aop-audio.user-access</key>' ||
        valid=0
    ldid -h "$path" 2>/dev/null |
        grep -Fqx 'Identifier=coreaudiod' || valid=0
    if [ "$valid" -ne 1 ]; then
        temporary="${path}.macws-new.$$"
        rm -f "$temporary"
        cp -p "$path" "$temporary" || return 1
        /var/jb/usr/bin/python3 "$LOAD_DYLIB_PATCHER" \
            "$temporary" "$dylib" || {
                rm -f "$temporary"; return 1;
            }
        # Start from the copied native entitlement set, add the common MacWS
        # launch policy, then the exact IOAudio2 permissions observed on the
        # target. Two final passes settle the grown __LINKEDIT page hashes.
        ldid -Icoreaudiod -S"$ENT" -M "$temporary" || {
            rm -f "$temporary"; return 1;
        }
        ldid -Icoreaudiod -S"$COREAUDIOD_AUDIO_ENT" -M "$temporary" || {
            rm -f "$temporary"; return 1;
        }
        ldid -Icoreaudiod -S"$COREAUDIOD_AUDIO_ENT" -M "$temporary" || {
            rm -f "$temporary"; return 1;
        }
        chmod --reference="$path" "$temporary" 2>/dev/null || true
        chown --reference="$path" "$temporary" 2>/dev/null || true
        mv -f "$temporary" "$path" || return 1
    fi
    add_all_trustcache "$path"
}

# Give a stock macOS image the project code-signing policy once, then restore
# only its persistent CDHashes on subsequent repairs/reboots.  The entitlement
# marker avoids repeatedly changing the file and accumulating obsolete hashes.
ensure_project_signature_and_trustcache() {
    local path="$1"
    [ -f "$path" ] || return 0
    if ! ldid -e "$path" 2>/dev/null |
         grep -q '<key>com.apple.private.graphics-restart-no-kill</key>'; then
        ldid -S"$ENT" -M "$path" || return 1
    fi
    add_all_trustcache "$path"
}

# A dylib may not carry the broad application entitlement profile: iPadOS
# AMFI rejects that shape before dyld can map it with "has entitlements but is
# not a main binary". Runtime A/B on 2026-09-07 confirmed that Preview's
# CoreImage libWrapGL has exactly this stale shape; registering its old
# CDHashes did not help, while an entitlement-free ad-hoc signature removed
# the libWrapGL rejection and CIContext's "No supported back-end" failure.
ensure_entitlement_free_signature_and_trustcache() {
    local path="$1" entitlements=""
    [ -f "$path" ] || return 0
    entitlements=$(ldid -e "$path" 2>/dev/null || true)
    if [ -n "$entitlements" ]; then
        ldid -S "$path" || return 1
    fi
    add_all_trustcache "$path"
}

# A Ventura LaunchAgent can carry a macOS application identity and seatbelt
# profile that are invalid when the same executable is hosted as a root Mach
# service by outer iPadOS launchd. Runtime oslog on 2026-09-06 captured the
# kernel killing ThumbnailsAgent at exec with "failed to set executable path"
# while containermanagerd resolved its native application-identifier. Signing
# the same image with the project's no-container profile (without ldid -M)
# removed that stale identity and the real agent remained alive. Keep this
# replacement policy narrow to that proven launch-context mismatch.
ensure_uncontainered_project_signature_and_trustcache() {
    local path="$1" required_marker="${2:-}" entitlements=""
    [ -f "$path" ] || return 0
    entitlements=$(ldid -e "$path" 2>/dev/null || true)
    if ! printf '%s\n' "$entitlements" |
           grep -q '<key>com.apple.private.security.no-container</key>' ||
       { [ -n "$required_marker" ] &&
         ! printf '%s\n' "$entitlements" |
             grep -Fq "$required_marker"; } ||
       printf '%s\n' "$entitlements" |
           grep -q '<key>application-identifier</key>' ||
       printf '%s\n' "$entitlements" |
           grep -q '<key>com.apple.application-identifier</key>' ||
       printf '%s\n' "$entitlements" |
           grep -q '<key>seatbelt-profiles</key>'; then
        ldid -S"$ENT" "$path" || return 1
    fi
    add_all_trustcache "$path"
}

# DesktopServicesHelper's stock Ventura handshake reads the requesting task's
# com.apple.private.tcc.allow array and rejects Finder unless it contains the
# all-files service.  Existing installations may already carry the older
# project signature, so the generic marker above is not sufficient to migrate
# this one protocol client after an upgrade.
ensure_desktopservices_client_signature_and_trustcache() {
    local path="$1" entitlements=""
    [ -f "$path" ] || return 0
    entitlements=$(ldid -e "$path" 2>/dev/null || true)
    if ! printf '%s\n' "$entitlements" |
           grep -q '<key>com.apple.private.graphics-restart-no-kill</key>' ||
       ! printf '%s\n' "$entitlements" |
           grep -q '<string>kTCCServiceSystemPolicyAllFiles</string>'; then
        ldid -S"$ENT" -M "$path" || return 1
    fi
    add_all_trustcache "$path"
}

# Keep cfprefsd out of the generic project entitlement profile.  Runtime
# evidence on iPadOS 16.3 established both failure boundaries: the stock Apple
# image is rejected by AMFI CT policy 0x8, and adding the generic profile's
# com.apple.security.system-container makes sandbox_init kill the process.
# A private fresh-inode copy signed with this dedicated profile runs normally
# and can map the injected libmachook image.  Re-sign only if the persistent
# copy is absent or has the wrong identity/profile, avoiding obsolete CDHashes.
ensure_private_cfprefsd_and_trustcache() {
    local source_path='/var/mnt/rootfs/usr/sbin/cfprefsd'
    local target_path='/var/mnt/rootfs/usr/local/libexec/macws-cfprefsd'
    local temporary_root='/var/mnt/rootfs/private/var/.TemporaryItems'
    local temporary_user="$temporary_root/folders.0"
    local temporary_leaf="$temporary_user/TemporaryItems"
    local temporary_mobile="$temporary_root/folders.501"
    local temporary_mobile_leaf="$temporary_mobile/TemporaryItems"
    local mobile_home='/var/mnt/rootfs/Users/mobile'
    local mobile_library="$mobile_home/Library"
    local mobile_preferences="$mobile_library/Preferences"
    local mobile_user_root='/var/mnt/rootfs/var/folders/zz/macws_uid501'
    local mobile_user_dir="$mobile_user_root/0"
    local mobile_cache_dir="$mobile_user_root/C"
    local mobile_temp_dir="$mobile_user_root/T"
    local target_dir temporary needs_refresh=0 entitlements=''

    [ -f "$source_path" ] || return 1
    [ -f "$CFPREFSD_ENT" ] || return 1
    target_dir=${target_path%/*}
    mkdir -p "$target_dir" || return 1

    # RE-confirmed against Ventura CoreFoundation and the iPadOS 16.3
    # libsystem_coreservices implementation.  CFPDSource's atomic plist writer
    # calls _dirhelper_relative for the Preferences mount.  On this chroot's
    # mount topology it resolves to this exact three-level hierarchy and
    # rejects/misses it unless the modes are 01311, 0700, 0700 respectively.
    # Without it _CFPrefsTemporaryFDToWriteTo returns -1/ENOENT after the
    # target plist itself has already opened successfully.
    mkdir -p "$temporary_leaf" "$temporary_mobile_leaf" \
        "$mobile_preferences" "$mobile_user_dir" "$mobile_cache_dir" \
        "$mobile_temp_dir" || return 1
    chown root:wheel "$temporary_root" "$temporary_user" "$temporary_leaf" \
        2>/dev/null || true
    chown 501:501 "$temporary_mobile" "$temporary_mobile_leaf" \
        "$mobile_home" "$mobile_library" "$mobile_preferences" \
        "$mobile_user_root" "$mobile_user_dir" "$mobile_cache_dir" \
        "$mobile_temp_dir" \
        2>/dev/null || return 1
    chmod 1311 "$temporary_root" || return 1
    chmod 0700 "$temporary_user" "$temporary_leaf" || return 1
    chmod 0700 "$temporary_mobile" "$temporary_mobile_leaf" \
        "$mobile_preferences" || return 1
    chmod 0755 "$mobile_home" "$mobile_library" || return 1
    chmod 0700 "$mobile_user_root" "$mobile_user_dir" \
        "$mobile_cache_dir" "$mobile_temp_dir" || return 1

    if [ ! -f "$target_path" ]; then
        needs_refresh=1
    else
        entitlements=$(ldid -e "$target_path" 2>/dev/null || true)
        ldid -h "$target_path" 2>/dev/null |
            grep -q 'Identifier=com.macwsguide.cfprefsd' || needs_refresh=1
        printf '%s\n' "$entitlements" |
            grep -q '<key>com.apple.private.graphics-restart-no-kill</key>' || needs_refresh=1
        if printf '%s\n' "$entitlements" |
             grep -q '<key>com.apple.security.system-container</key>'; then
            needs_refresh=1
        fi
    fi

    if [ "$needs_refresh" -eq 1 ]; then
        temporary="${target_path}.new-$$"
        rm -f "$temporary"
        cp "$source_path" "$temporary" || return 1
        chmod 755 "$temporary" || return 1
        chown root:wheel "$temporary" 2>/dev/null || true
        ldid -Icom.macwsguide.cfprefsd -S"$CFPREFSD_ENT" "$temporary" || {
            rm -f "$temporary"
            return 1
        }
        mv -f "$temporary" "$target_path" || return 1
        echo "[INFO] installed dedicated private macOS cfprefsd"
    fi
    add_all_trustcache "$target_path"
}

# Emit every regular Mach-O/fat file in a tree as a NUL-delimited path list.
# Do not trust mode bits here: Valheim 0.220.5 runtime-confirmed that its
# PlayFabPartyMacOS bundle is real arm64 code shipped as mode 0644, while Office
# marks thousands of fonts and proofing resources executable.
list_macho_files() {
    /var/jb/usr/bin/python3 -c '
import os, stat, sys

magics = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
for base, _, names in os.walk(sys.argv[1]):
    for name in names:
        path = os.path.join(base, name)
        try:
            mode = os.stat(path, follow_symlinks=False).st_mode
            if not stat.S_ISREG(mode):
                continue
            with open(path, "rb") as stream:
                if stream.read(4) not in magics:
                    continue
            os.write(1, os.fsencode(path) + b"\0")
        except OSError:
            pass
' "$1"
}

# Re-register every already-signed Mach-O in an application bundle.
#
# Dynamic jailbreak trustcaches are lost across a device reboot, while the
# ad-hoc signatures stored in the macOS rootfs persist.  launchdchrootexec can
# repair the process it directly execs, but dyld validates dependent
# frameworks before libmachook/autosignd can run.  Runtime evidence from the
# first VS Code launch after the 2026-07-30 reboot showed exactly that split:
# Contents/MacOS/Code was trusted, then dyld rejected Electron Framework and,
# after that hash was added, Squirrel.framework.  Restoring the 44 signed
# executable files in the bundle made the unchanged VS Code 1.130 build reach
# CDP in four seconds.
#
# Do not call sign_and_trustcache here.  Re-signing a nested framework changes
# its CDHash and can invalidate the bundle's existing nested-code relationship.
# Reading and re-registering the persistent signatures is sufficient and keeps
# the installed application byte-for-byte unchanged.
trust_existing_app_bundle() {
    local bundle="$1"
    local name="$2"
    [ -d "$bundle" ] || return 0

    echo "[INFO] Restoring signed Mach-O trustcache entries for $name..."
    list_macho_files "$bundle/Contents" |
        while IFS= read -r -d '' path; do
            add_all_trustcache "$path"
        done
}

# Restore the persistent signatures of a framework tree without changing its
# nested-code relationship. This is the same cold-boot invariant as an app
# bundle, but private frameworks do not have a Contents directory.
trust_existing_macho_tree() {
    local tree="$1"
    local name="$2"
    [ -d "$tree" ] || return 0

    echo "[INFO] Restoring signed Mach-O trustcache entries for $name..."
    list_macho_files "$tree" |
        while IFS= read -r -d '' path; do
            add_all_trustcache "$path"
        done
}

# The iOS-native control daemon is the reboot-safe entry point used by the
# MacWSHost app.  Trust it here, but never unload it from this script: postinst
# may itself be running as a request served by macwshostd.
add_all_trustcache "/var/jb/usr/macOS/bin/macwshostd"
add_all_trustcache "/var/jb/usr/macOS/bin/macwskeychaind"

# ─── LaunchDaemons plist ownership/permissions ─────────────────────────────
# launchctl refuses to load any plist under a system LaunchDaemons dir unless
# owner=root:wheel and mode=0644.  The deb install preserves whatever owner
# the build host had (typically mobile:staff), so reset to root:wheel 0644.
# Without this, launchservicesd never starts (chroot Cocoa apps then crash in
# HIServices _RegisterApplication).
if [ -d /var/jb/usr/macOS/LaunchDaemons ]; then
    chown root:wheel /var/jb/usr/macOS/LaunchDaemons/*.plist 2>/dev/null || true
    chmod 644       /var/jb/usr/macOS/LaunchDaemons/*.plist 2>/dev/null || true
fi

# ─── On-demand auto-sign daemon (iOS side) ──────────────────────────────────
# Keep package-install and App-driven repair on one exact supervision path.
# This prevents one blocked daemon from being leaked for each install while
# retaining the reboot-volatile trustcache repair required by the first exec.
bash /var/jb/usr/macOS/bin/restart_autosignd.sh --force || exit 1

# ─── iOS-native IOSurface allocator daemon (for chroot WS CodeHeap) ─────────
# Chroot WS in AGX-native mode can't allocate via sel=0xa heap-creates (kernel
# rejects on the macOS user-client). This daemon runs in iOS-native context
# (sees the real AGX), allocates IOSurfaces of the requested size, returns the
# mach send-right back over XPC. libmachook's CODEHEAP-SHIM connects to it.
ALLOCD=/var/jb/usr/macOS/bin/macwsallocd
ALLOCD_PLIST=/var/jb/Library/LaunchDaemons/com.macwsguide.alloc.plist
if [ -x "$ALLOCD" ]; then
    add_all_trustcache "$ALLOCD"
    if [ -f "$ALLOCD_PLIST" ]; then
        # Rootless package extraction can preserve the build account's uid.
        # launchd rejects a system-domain plist before the allocator ever gets
        # a chance to check in, so normalize and verify the real load result.
        chown root:wheel "$ALLOCD_PLIST" || exit 1
        chmod 0644 "$ALLOCD_PLIST" || exit 1
        launchctl unload "$ALLOCD_PLIST" 2>/dev/null || true
        if ! launchctl load "$ALLOCD_PLIST"; then
            echo "[ERROR] failed to load com.macwsguide.alloc launchd job" >&2
            exit 1
        fi
        echo "[INFO] loaded com.macwsguide.alloc launchd job"
    fi
fi

add_trustcache "/var/jb/usr/macOS/bin/TestMetalIOSurface"
add_trustcache "/var/jb/usr/macOS/bin/PinnedVAProbe"
add_all_trustcache "/var/jb/usr/macOS/lib/libmachook.dylib"
add_all_trustcache "/var/jb/usr/macOS/lib/libmachook_arm64.dylib"
add_all_trustcache "/var/jb/usr/macOS/bin/launchdchrootexec"
add_all_trustcache "/var/jb/usr/macOS/bin/launchdchrootexec_debug"
add_all_trustcache "/var/jb/usr/macOS/bin/macwsinputd"
add_all_trustcache "/var/jb/usr/macOS/bin/macwsdisplayd"
add_all_trustcache "/var/jb/usr/macOS/bin/macwsaudiooutd"
ensure_audio_component_image \
    "$ROOTFS/System/Library/Frameworks/AudioToolbox.framework/AudioComponentRegistrar" \
    'com.apple.AudioComponentRegistrar' daemon || exit 1
ensure_audio_component_image \
    "$ROOTFS/System/Library/Components/CoreAudio.component/Contents/MacOS/CoreAudio" \
    'com.apple.audio.units.Components' plugin || exit 1
ensure_audio_component_image \
    "$ROOTFS/System/Library/Components/AudioDSP.component/Contents/MacOS/AudioDSP" \
    'com.apple.audio.AudioDSPComponents' plugin || exit 1
ensure_coreaudiod_runtime || exit 1
sign_and_trustcache_merging_native_entitlements \
    "/var/jb/usr/macOS/libexec/MacWSInteropService.app/Contents/MacOS/macwsinteropd" \
    "$INTEROP_LOCATION_ENT" \
    '<key>com.apple.locationd.simulation</key>' \
    'com.macwsguide.interopd' \
    1 || exit 1
add_all_trustcache "/var/jb/usr/macOS/Frameworks/MetalSerializer.framework/MetalSerializer"
cp -vf /var/jb/usr/macOS/Frameworks/MetalSerializer.framework/MetalSerializer_macos /var/mnt/rootfs/usr/local/Frameworks/MetalSerializer.framework/MetalSerializer
add_all_trustcache /var/mnt/rootfs/usr/local/Frameworks/MetalSerializer.framework/MetalSerializer
add_all_trustcache "/var/jb/usr/macOS/Frameworks/MTLSimDriver.framework/MTLSimDriver"
add_all_trustcache "/var/jb/usr/macOS/Frameworks/MTLSimImplementation.framework/MTLSimImplementation"
add_all_trustcache "/var/jb/usr/macOS/Frameworks/MTLSimDriver.framework/XPCServices/MTLSimDriverHost.xpc/MTLSimDriverHost"
# Theos rootless XPC bundles use a flat bundle layout.  Builds installed before
# the proxy was converted from a copied macOS bundle can leave a second
# `Contents/Info.plist` behind.  CoreFoundation then resolves that stale nested
# metadata instead of the new flat Info.plist, so xpc_add_bundle never sees the
# proxy's MachServices declaration.  Remove only that obsolete nested layout;
# the authoritative executable and Info.plist are at the bundle root.
VIEWBRIDGE_PROXY=/var/jb/usr/macOS/Frameworks/ViewBridge.framework/Versions/A/XPCServices/ViewBridgeAuxiliary.xpc
if [ -f "$VIEWBRIDGE_PROXY/Info.plist" ] &&
   [ -d "$VIEWBRIDGE_PROXY/Contents" ]; then
    rm -rf "$VIEWBRIDGE_PROXY/Contents"
    echo "[INFO] removed stale nested ViewBridge proxy bundle layout"
fi
VIEWBRIDGE_PROXY_EXEC="$VIEWBRIDGE_PROXY/ViewBridgeAuxiliary"
HISERVICES_PROXY_EXEC="/var/jb/usr/macOS/Frameworks/HIServices.framework/Versions/A/XPCServices/HIServicesProxy.xpc/HIServicesProxy"
OPEN_SAVE_PANEL_PROXY_EXEC="/var/jb/usr/macOS/Frameworks/AppKit.framework/Versions/C/XPCServices/OpenAndSavePanelProxy.xpc/OpenAndSavePanelProxy"
QUICKLOOK_UI_PROXY_EXEC="/var/jb/usr/macOS/Frameworks/QuickLookUI.framework/Versions/A/XPCServices/QuickLookUIServiceProxy.xpc/QuickLookUIServiceProxy"
DOCK_HELPER_PROXY_EXEC="/var/jb/usr/macOS/Frameworks/Dock.framework/Versions/A/XPCServices/DockHelperProxy.xpc/DockHelperProxy"
GEOD_PROXY_EXEC="/var/jb/usr/macOS/PrivateFrameworks/GeoServices.framework/Versions/A/XPCServices/GeodProxy.xpc/GeodProxy"
WRITE_CONFIG_PROXY_EXEC="/var/jb/usr/macOS/PrivateFrameworks/SystemAdministration.framework/XPCServices/WriteConfigProxy.xpc/WriteConfigProxy"
LOCATIOND_PROXY_EXEC="/var/jb/usr/macOS/PrivateFrameworks/CoreLocation.framework/XPCServices/LocationdProxy.xpc/LocationdProxy"
add_all_trustcache "$VIEWBRIDGE_PROXY_EXEC"
add_all_trustcache "$HISERVICES_PROXY_EXEC"
add_all_trustcache "$OPEN_SAVE_PANEL_PROXY_EXEC"
add_all_trustcache "$QUICKLOOK_UI_PROXY_EXEC"
add_all_trustcache "$DOCK_HELPER_PROXY_EXEC"
add_all_trustcache "$GEOD_PROXY_EXEC"
add_all_trustcache "$WRITE_CONFIG_PROXY_EXEC"
add_all_trustcache "$LOCATIOND_PROXY_EXEC"
add_all_trustcache "/var/jb/usr/macOS/bin/macwslocationd"
EXTENSIONKIT_PROXY="/var/jb/usr/macOS/Frameworks/ExtensionFoundation.framework/Versions/A/XPCServices/ExtensionKitProxy.xpc/ExtensionKitProxy"
add_all_trustcache "$EXTENSIONKIT_PROXY"
# These four services are launched as mobile-owned per-process XPC jobs, but
# share a freestanding first image that must chroot before libSystem/libxpc
# consumes launchd's one-shot context.  Runtime witness (2026-08-04): both
# ViewBridgeAuxiliary and ExtensionKitProxy in mode 0755 exited with the
# source-defined chroot-failure status 111; mode 4755 let the same images
# reach their real macOS targets.  Keep the privilege on these minimal launch
# stubs only and enforce the invariant for every consumer of main.c.
for proxy in \
    "$VIEWBRIDGE_PROXY_EXEC" \
    "$HISERVICES_PROXY_EXEC" \
    "$OPEN_SAVE_PANEL_PROXY_EXEC" \
    "$QUICKLOOK_UI_PROXY_EXEC" \
    "$DOCK_HELPER_PROXY_EXEC" \
    "$EXTENSIONKIT_PROXY" \
    "$GEOD_PROXY_EXEC" \
    "$WRITE_CONFIG_PROXY_EXEC" \
    "$LOCATIOND_PROXY_EXEC"; do
    if [ -x "$proxy" ]; then
        chown root:wheel "$proxy"
        chmod 4755 "$proxy"
    fi
done
add_all_trustcache "/var/jb/Applications/SettingsExtensionProxy.app/SettingsExtensionProxy"
if [ -x /var/jb/Applications/SettingsExtensionProxy.app/SettingsExtensionProxy ]; then
    chown root:wheel /var/jb/Applications/SettingsExtensionProxy.app/SettingsExtensionProxy
    chmod 4755 /var/jb/Applications/SettingsExtensionProxy.app/SettingsExtensionProxy
    uicache -p /var/jb/Applications/SettingsExtensionProxy.app >/dev/null 2>&1 || true
fi
add_all_trustcache "/var/jb/usr/macOS/Frameworks/FileCoordination.framework/Versions/A/XPCServices/FileCoordinationProxy.xpc/FileCoordinationProxy"
add_all_trustcache "/var/jb/usr/macOS/Frameworks/FileCoordination.framework/Versions/A/XPCServices/ProgressReportingProxy.xpc/ProgressReportingProxy"
# The flat iOS proxy bundles above are only the launch images visible to the
# iOS XPC service manager.  Their SETEXEC targets live inside the macOS rootfs
# and are admitted by iOS AMFI before libmachook/autosignd can run.  Runtime
# evidence on 2026-08-02: each proxy reached its chroot boundary, then the real
# target died before its first userspace log and the client received
# `Connection invalid`; none of the three real target CDHashes was present in
# the dynamic trustcache.  Persistently sign those upstream executables and
# restore their CDHashes on every postinst/re-jailbreak, exactly like the other
# initial process images below.
sign_and_trustcache "/var/mnt/rootfs/System/Library/PrivateFrameworks/ViewBridge.framework/Versions/A/XPCServices/ViewBridgeAuxiliary.xpc/Contents/MacOS/ViewBridgeAuxiliary"
sign_and_trustcache "/var/mnt/rootfs/System/Library/CoreServices/UIKitSystem.app/Contents/MacOS/UIKitSystem"
sign_and_trustcache "/var/mnt/rootfs/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/XPCServices/com.apple.hiservices-xpcservice.xpc/Contents/MacOS/com.apple.hiservices-xpcservice"
sign_and_trustcache "/var/mnt/rootfs/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/com.apple.appkit.xpc.openAndSavePanelService.xpc/Contents/MacOS/com.apple.appkit.xpc.openAndSavePanelService"
sign_and_trustcache "/var/mnt/rootfs/System/Library/Frameworks/QuickLookUI.framework/Versions/A/XPCServices/QuickLookUIService.xpc/Contents/MacOS/QuickLookUIService"
sign_and_trustcache_with_entitlements \
    "/var/mnt/rootfs/System/Library/Frameworks/ExtensionFoundation.framework/Versions/A/XPCServices/extensionkitservice.xpc/Contents/MacOS/extensionkitservice" \
    "$EXTENSIONKIT_ENT"
sign_and_trustcache_with_entitlements \
    "/var/mnt/rootfs/System/Library/ExtensionKit/Extensions/Appearance.appex/Contents/MacOS/Appearance" \
    "$APPEARANCE_ENT" \
    '<key>com.apple.security.exception.files.absolute-path.read-write</key>' \
    'com.apple.Appearance-Settings.extension'
sign_and_trustcache_merging_native_entitlements \
    "/var/mnt/rootfs/System/Library/CoreServices/CoreLocationAgent.app/Contents/MacOS/CoreLocationAgent" \
    "$CORELOCATIONAGENT_NATIVE_ENT" \
    '<key>com.apple.locationd.authorizeapplications</key>' \
    'com.apple.CoreLocationAgent' || exit 1
sign_and_trustcache_merging_native_entitlements \
    "/var/mnt/rootfs/usr/libexec/locationd" \
    "$LOCATIOND_NATIVE_ENT" \
    '<key>com.apple.private.security.storage.locationd</key>' \
    'com.apple.locationd' || exit 1
sign_and_trustcache_merging_native_entitlements \
    "/var/mnt/rootfs/System/Library/PrivateFrameworks/GeoServices.framework/Versions/A/XPCServices/com.apple.geod.xpc/Contents/MacOS/com.apple.geod" \
    "$GEOD_NATIVE_ENT" \
    '<key>com.apple.private.network.socket-delegate</key>' \
    'com.apple.geod' || exit 1
# codesign -vvv -d dyld_shared_cache_arm64e 2>&1 | grep CDHash=
jbctl trustcache add b5da39409492ac85e5a8e8ab618fe77e2d7a2980
# codesign -vvv -d dyld_shared_cache_arm64e.01 2>&1 | grep CDHash=
jbctl trustcache add bbb765988e2677b98d47a549d612fa0d4af25f69
add_all_trustcache "/var/mnt/rootfs/bin/bash"
ensure_filecoordinationd_signature || exit 1
prepare_windowserver_runtime || exit 1
LAUNCHSERVICES_LOADER=/var/jb/usr/macOS/bin/launchservicesd
LAUNCHSERVICES_TARGET=/var/mnt/rootfs/System/Library/CoreServices/launchservicesd
LAUNCHSERVICES_PAYLOAD=/var/mnt/rootfs/System/Library/CoreServices/launchservicesd.dylib
LAUNCHSERVICES_PAYLOAD_SOURCE=/var/jb/usr/macOS/Frameworks/launchservicesd.dylib
if [ ! -e "$LAUNCHSERVICES_PAYLOAD" ]; then
	cp -pv "$LAUNCHSERVICES_PAYLOAD_SOURCE" \
		"${LAUNCHSERVICES_PAYLOAD}.macws-new.$$" || exit 1
	mv -fv "${LAUNCHSERVICES_PAYLOAD}.macws-new.$$" \
		"$LAUNCHSERVICES_PAYLOAD" || exit 1
fi
if ! cmp -s "$LAUNCHSERVICES_LOADER" "$LAUNCHSERVICES_TARGET"; then
	# Fresh rootfs images contain Ventura's stock MH_EXECUTE. Preserve it
	# once, then atomically install the project's thin loader next to the
	# extracted payload dylib. A new inode also avoids stale AMFI vnode state.
	if [ ! -e "${LAUNCHSERVICES_TARGET}.macws-original" ]; then
		cp -pv "$LAUNCHSERVICES_TARGET" \
			"${LAUNCHSERVICES_TARGET}.macws-original" || exit 1
	fi
	cp -pv "$LAUNCHSERVICES_LOADER" \
		"${LAUNCHSERVICES_TARGET}.macws-new.$$" || exit 1
	chown root:wheel "${LAUNCHSERVICES_TARGET}.macws-new.$$" || exit 1
	chmod 0755 "${LAUNCHSERVICES_TARGET}.macws-new.$$" || exit 1
	mv -fv "${LAUNCHSERVICES_TARGET}.macws-new.$$" \
		"$LAUNCHSERVICES_TARGET" || exit 1
fi
add_all_trustcache "$LAUNCHSERVICES_TARGET"
SYSTEMSTATUSD="/var/mnt/rootfs/System/Library/PrivateFrameworks/SystemStatusServer.framework/Support/systemstatusd"
if [ -f "$SYSTEMSTATUSD" ] &&
   ! ldid -e "$SYSTEMSTATUSD" 2>/dev/null | grep -q '<key>com.apple.systemstatus.domains</key>'; then
    # A stock macOS systemstatusd only carries com.apple.rootless.critical.
    # macOS executables launched in the iOS chroot must use the same project
    # entitlement set as WindowServer before AMFI will admit the injected
    # libmachook image.  Do this once; repeated ldid passes can change CDHash.
    ldid -S"$ENT" -M "$SYSTEMSTATUSD" || exit 1
fi
add_all_trustcache "$SYSTEMSTATUSD"
add_all_trustcache "$LAUNCHSERVICES_PAYLOAD"
add_all_trustcache "/var/mnt/rootfs/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
add_all_trustcache /var/jb/usr/macOS/bin/HostInjectBootstrap
add_all_trustcache /var/mnt/rootfs/System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/Contents/MacOS/MTLCompilerService
add_all_trustcache /System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/MTLCompilerService
# Refresh the chroot copy of libmachook. CRITICAL: rm before cp so the new file
# gets a FRESH INODE. Overwriting in place (cp -f, same inode) leaves the chroot
# kernel's cached code-signature blob for that vnode stale -> it validates the new
# file's pages against the OLD cached hashes -> AMFI "Invalid Page" SIGKILLs every
# arm64e chroot process at dyld insert-map time. A new inode has no cached blob.
# (arm64 escaped this only because WindowServer stayed mapped from one clean load.)
rm -f /var/mnt/rootfs/usr/local/lib/libmachook.dylib
cp -vf /var/jb/usr/macOS/lib/libmachook.dylib /var/mnt/rootfs/usr/local/lib/libmachook.dylib
add_all_trustcache /var/mnt/rootfs/usr/local/lib/libmachook.dylib
# arm64 thin slice (loaded into pure-arm64 chroot processes: WindowServer, claude,
# MacPorts tools). Present only after an on-device build; guard so cross-compile
# installs (single fat libmachook.dylib) don't fail here.
if [ -f /var/jb/usr/macOS/lib/libmachook_arm64.dylib ]; then
	rm -f /var/mnt/rootfs/usr/local/lib/libmachook_arm64.dylib
	cp -vf /var/jb/usr/macOS/lib/libmachook_arm64.dylib /var/mnt/rootfs/usr/local/lib/libmachook_arm64.dylib
	add_all_trustcache /var/mnt/rootfs/usr/local/lib/libmachook_arm64.dylib
fi

# Asphalt embeds a peer-verifying OpenSSL client whose compiled default is
# /usr/local/ssl/cert.pem. gameoptions.gameloft.com currently sends a Sectigo
# leaf followed by an unrelated Entrust intermediate; the authentic missing
# Sectigo OV R36 intermediate is packaged above. Build an app-scoped CA file
# from Ventura's existing roots and that intermediate. This repairs chain
# construction without disabling hostname, signature, expiry, or peer checks.
if [ -f "$ASPHALT_CA_INTERMEDIATE" ] && [ -f "$MACOS_CA_BUNDLE" ]; then
	mkdir -p "$(dirname "$ASPHALT_CA_BUNDLE")" || exit 1
	ASPHALT_CA_TEMP="${ASPHALT_CA_BUNDLE}.new.$$"
	cat "$MACOS_CA_BUNDLE" "$ASPHALT_CA_INTERMEDIATE" > \
		"$ASPHALT_CA_TEMP" || exit 1
	chmod 0644 "$ASPHALT_CA_TEMP" || exit 1
	mv "$ASPHALT_CA_TEMP" "$ASPHALT_CA_BUNDLE" || exit 1
else
	echo '[ERROR] Asphalt peer-verification CA inputs are missing' >&2
	exit 1
fi

# Some self-contained Mac Catalyst applications retain OpenSSL's compiled
# `/usr/local/ssl` prefix even though their code and trust roots are bundled.
# Install a real, non-permissive config at that canonical location. Runtime
# diagnostics in Asphalt confirmed the missing file returned ENOENT before its
# otherwise-valid TLS handshake; this file neither disables verification nor
# changes the cipher/security level.
if [ -f "$ASPHALT_OPENSSL_CONFIG" ]; then
	mkdir -p "$(dirname "$ASPHALT_OPENSSL_CONFIG_DEST")" || exit 1
	cp "$ASPHALT_OPENSSL_CONFIG" "$ASPHALT_OPENSSL_CONFIG_DEST" || exit 1
	chmod 0644 "$ASPHALT_OPENSSL_CONFIG_DEST" || exit 1
else
	echo '[ERROR] OpenSSL compatibility config is missing' >&2
	exit 1
fi

# Catalyst children execute as the foreground iPadOS login user (uid/gid 501)
# so UIKit and the Data Protection Keychain share the same user session. Older
# packages stored Asphalt below /var/root; a uid-501 process cannot traverse
# that directory even if the leaf itself is chowned. Copy the existing Data
# tree once into the normal mobile macOS home, keep the source as a rollback
# backup, and never weaken /var/root permissions.
ASPHALT_OLD_CONTAINER="$ROOTFS/var/root/Library/Containers/com.gameloft.asphalt9mac/Data"
ASPHALT_MOBILE_CONTAINER="$ROOTFS/Users/mobile/Library/Containers/com.gameloft.asphalt9mac/Data"
if [ ! -d "$ASPHALT_MOBILE_CONTAINER" ]; then
	mkdir -p "${ASPHALT_MOBILE_CONTAINER%/Data}" || exit 1
	if [ -d "$ASPHALT_OLD_CONTAINER" ]; then
		cp -Rp "$ASPHALT_OLD_CONTAINER" "$ASPHALT_MOBILE_CONTAINER" || exit 1
	else
		mkdir -p "$ASPHALT_MOBILE_CONTAINER/Documents" \
			"$ASPHALT_MOBILE_CONTAINER/Library" || exit 1
	fi
fi
chown -R 501:501 "$ROOTFS/Users/mobile/Library/Containers/com.gameloft.asphalt9mac" || exit 1
chmod 0700 "$ROOTFS/Users/mobile/Library/Containers/com.gameloft.asphalt9mac" \
	"$ASPHALT_MOBILE_CONTAINER" || exit 1

# Establish the complete arm64e loader closure before the first chroot exec
# below.  The signatures persist across a reboot, but Dopamine's dynamic
# trustcache does not.  Runtime-confirmed on 2026-08-05: invoking /bin/bash
# before these two hashes were restored produced, in order,
#
#   AMFI: '/usr/lib/dyld' has no CMS blob
#   Library not loaded: @rpath/CydiaSubstrate.framework/CydiaSubstrate
#
# and SIGKILL/abort before the later legacy registration block could run.
# Registering the existing dyld and chroot CydiaSubstrate CodeDirectories made
# the unchanged bash process complete normally.  Keep this upstream of the
# Ventura codesign calls rather than weakening their result checks.
add_all_trustcache /var/mnt/rootfs/usr/lib/dyld
add_all_trustcache \
	/var/mnt/rootfs/System/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate

# System Settings panes are real Ventura ExtensionKit executables launched
# through unique iOS first-image carriers. Keep every pane's native
# entitlements, bundle-local dependency closure, load commands, common service
# exceptions, runtime fingerprint and reboot-volatile trustcache in one
# idempotent helper shared with the package postinst.
bash /var/jb/usr/macOS/bin/ensure_settings_extensions_runtime.sh || exit 1
# Package installation already paid the one-time signing/copying cost.  Deeply
# verify the completed closure now so the first GUI launch can reuse the exact
# bootsession/dependency witness instead of re-reading all 48 panes on its
# latency-sensitive path.  The verifier also writes the persistent trust-hash
# manifest used to restore the reboot-volatile dynamic trustcache.
bash /var/jb/usr/macOS/bin/ensure_settings_extensions_runtime.sh --verify || exit 1

# Native-host input bridge.  Keep the installed source and the chroot-visible
# executable on fresh inodes so AMFI does not reuse a stale vnode signature.
if [ -f /var/jb/usr/macOS/bin/macwsinputd ]; then
	rm -f /var/mnt/rootfs/usr/local/bin/macwsinputd
	cp -vf /var/jb/usr/macOS/bin/macwsinputd /var/mnt/rootfs/usr/local/bin/macwsinputd
	chmod 755 /var/mnt/rootfs/usr/local/bin/macwsinputd
	add_all_trustcache /var/mnt/rootfs/usr/local/bin/macwsinputd
fi
# Keep the repair path subject to the same package/runtime compatibility
# invariant as DEBIAN/postinst.  Copying a stale single-pane controller over a
# newer chroot binary would make a reboot self-heal deterministically regress
# into the long `register-settings-extensions` failure loop.
if ! /var/jb/usr/bin/grep -aFq 'register-settings-extensions' \
		/var/jb/usr/macOS/bin/macwsworkspacectl 2>/dev/null; then
	echo 'ERROR: installed macwsworkspacectl lacks the all-settings startup contract.' >&2
	exit 1
fi
for bridge in macwsdisplayd macwsinteropd macwsworkspacectl macws-neofetch; do
	if [ -f "/var/jb/usr/macOS/bin/$bridge" ]; then
		rm -f "/var/mnt/rootfs/usr/local/bin/$bridge"
		cp -vf "/var/jb/usr/macOS/bin/$bridge" "/var/mnt/rootfs/usr/local/bin/$bridge"
		chmod 755 "/var/mnt/rootfs/usr/local/bin/$bridge"
		add_all_trustcache "/var/mnt/rootfs/usr/local/bin/$bridge"
	fi
done
# Keep the CoreLocation client at a real bundle path.  CoreLocationAgent's
# copy_client_info routine skips designated-requirement extraction when both
# bundle identifier and bundle path are absent; the old /usr/local/bin daemon
# therefore remained permanently unverified even with a valid CodeDirectory.
INTEROP_BUNDLE_SOURCE=/var/jb/usr/macOS/libexec/MacWSInteropService.app/Contents
INTEROP_BUNDLE_TARGET=/var/mnt/rootfs/usr/local/libexec/MacWSInteropService.app/Contents
if [ -f "$INTEROP_BUNDLE_SOURCE/MacOS/macwsinteropd" ]; then
	mkdir -p "$INTEROP_BUNDLE_TARGET/MacOS"
	cp -f "$INTEROP_BUNDLE_SOURCE/Info.plist" \
		"$INTEROP_BUNDLE_TARGET/Info.plist"
	rm -f "$INTEROP_BUNDLE_TARGET/MacOS/macwsinteropd"
	cp -f "$INTEROP_BUNDLE_SOURCE/MacOS/macwsinteropd" \
		"$INTEROP_BUNDLE_TARGET/MacOS/macwsinteropd"
	chmod 644 "$INTEROP_BUNDLE_TARGET/Info.plist"
	chmod 755 "$INTEROP_BUNDLE_TARGET/MacOS/macwsinteropd"
	# CoreLocationAgent validates the live client through macOS Security.
	# ldid's embedded signature is sufficient for AMFI but Ventura Security
	# reports it as an unsupported live Code object.  Re-seal the complete
	# chroot bundle with Ventura's own ad-hoc signer so Info.plist, resources,
	# entitlements, identifier and the explicit identifier-only requirement are
	# represented in the native macOS CodeDirectory.  Runtime-confirmed on the
	# target: strict verification passes, flags=0x2(adhoc), and repeated signing
	# produces the same CDHash.
	MACWS_UTILITY_PROCESS=1 \
	/var/jb/usr/macOS/bin/launchdchrootexec 0 0 /var/mnt/rootfs \
		/usr/bin/codesign --force --sign - --timestamp=none \
		--preserve-metadata=identifier,entitlements,requirements \
		/usr/local/libexec/MacWSInteropService.app || exit 1
	MACWS_UTILITY_PROCESS=1 \
	/var/jb/usr/macOS/bin/launchdchrootexec 0 0 /var/mnt/rootfs \
		/usr/bin/codesign --verify --strict --verbose=2 \
		/usr/local/libexec/MacWSInteropService.app || exit 1
	ldid -e "$INTEROP_BUNDLE_TARGET/MacOS/macwsinteropd" 2>/dev/null |
		grep -Fq '<key>com.apple.locationd.simulation</key>' || exit 1
	ldid -h "$INTEROP_BUNDLE_TARGET/MacOS/macwsinteropd" 2>/dev/null |
		grep -Fqx 'Identifier=com.macwsguide.interopd' || exit 1
	add_all_trustcache "$INTEROP_BUNDLE_TARGET/MacOS/macwsinteropd"
fi
# LaunchServices' FSNode layer receives the kernel mount name for the macOS
# filesystem even after launchdchrootexec has changed the process root.  On the
# target device its real database therefore records bundle paths below
# `/rootfs` (for example `/rootfs/System/Applications/Launchpad.app`).  The
# matching runtime dump reports "Bundle node not found on disk" unless that
# kernel-visible mount name also resolves inside the chroot.  Keep a single,
# exact namespace alias to the logical process root; do not overwrite any real
# path a user may already have created.
if [ ! -e /var/mnt/rootfs/rootfs ] && [ ! -L /var/mnt/rootfs/rootfs ]; then
	ln -s / /var/mnt/rootfs/rootfs
elif [ -L /var/mnt/rootfs/rootfs ] &&
     [ "$(readlink /var/mnt/rootfs/rootfs 2>/dev/null)" != / ]; then
	echo '[ERROR] /var/mnt/rootfs/rootfs exists but does not target /' >&2
	exit 1
fi
# MacWSHost runs as the iOS mobile user while the chroot apps currently run as
# root.  A shared staging directory owned by mobile lets the Host copy
# security-scoped imports into the mounted rootfs; root can then publish the
# same native file URLs through macOS pboard without a second copy.
mkdir -p "/var/mnt/rootfs/Users/Shared/MacWS Imports"
chown mobile:mobile "/var/mnt/rootfs/Users/Shared/MacWS Imports" 2>/dev/null || true
chmod 0770 "/var/mnt/rootfs/Users/Shared/MacWS Imports"
add_all_trustcache '/var/mnt/rootfs/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor'
# Finder keeps its stock macOS Apple signature on a fresh rootfs.  The iOS
# kernel runtime-confirmed that signature is rejected with
# "unsuitable CT policy 0x8 for this platform/device" before Finder reaches
# AppKit.  Sign it once with the same project entitlement profile used by the
# other chroot applications, then only restore the persistent CDHash on later
# postinst/cold-start repairs.  The entitlement probe avoids repeatedly
# changing the signed file and accumulating obsolete trustcache entries.
FINDER_BIN='/var/mnt/rootfs/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder'
ensure_desktopservices_client_signature_and_trustcache "$FINDER_BIN" || exit 1
# Preview is Finder's stock default handler for both PDF and common image
# documents. Runtime oslog on 2026-09-07 captured its unmodified Ventura
# executable being killed before libmachook/AppKit startup with:
# "unsuitable CT policy 0x8 for this platform/device" followed by
# "code signature validation failed". Like Finder, it is a direct outer-
# launchd target, so give the executable the persistent project signature once
# and restore its dynamic trustcache entries on every postinst/reboot repair.
ensure_project_signature_and_trustcache \
    '/var/mnt/rootfs/System/Applications/Preview.app/Contents/MacOS/Preview' || exit 1
# Preview links Hydra before libmachook/autosignd can run. Runtime A/B on the
# installed Ventura images showed dyld advance from Hydra to libAlembic only
# after each already-signed Hydra Mach-O CDHash entered the dynamic trustcache.
trust_existing_macho_tree \
    '/var/mnt/rootfs/System/Library/PrivateFrameworks/Hydra.framework' \
    'Hydra.framework' || exit 1
ensure_entitlement_free_signature_and_trustcache \
    '/var/mnt/rootfs/System/Library/Frameworks/CoreImage.framework/Versions/A/Frameworks/libWrapGL.dylib' || exit 1
ensure_uncontainered_project_signature_and_trustcache \
    '/var/mnt/rootfs/System/Library/Frameworks/QuickLookThumbnailing.framework/Support/com.apple.quicklook.ThumbnailsAgent' || exit 1
ensure_uncontainered_project_signature_and_trustcache \
    '/var/mnt/rootfs/System/Library/Frameworks/QuickLook.framework/Versions/A/XPCServices/QuickLookSatellite.xpc/Contents/MacOS/QuickLookSatellite' || exit 1
ensure_project_signature_and_trustcache \
    '/var/mnt/rootfs/System/Library/Frameworks/QuickLookUI.framework/Versions/A/XPCServices/QuickLookUIService.xpc/Contents/MacOS/QuickLookUIService' || exit 1
QUICKLOOK_DISPLAY_ROOT='/var/mnt/rootfs/System/Library/Frameworks/QuickLookUI.framework/Versions/A/PlugIns'
for quicklook_display_bundle in "$QUICKLOOK_DISPLAY_ROOT"/*.qldisplay; do
    [ -d "$quicklook_display_bundle" ] || continue
    quicklook_display_name=${quicklook_display_bundle##*/}
    quicklook_display_name=${quicklook_display_name%.qldisplay}
    quicklook_display_executable="$quicklook_display_bundle/Contents/MacOS/$quicklook_display_name"
    [ ! -f "$quicklook_display_executable" ] || \
        ensure_project_signature_and_trustcache \
            "$quicklook_display_executable" || exit 1
done
ensure_uncontainered_project_signature_and_trustcache \
    '/var/mnt/rootfs/usr/libexec/pkd' \
    '<key>com.apple.runningboard.launch_extensions</key>' || exit 1
# Ventura pkd's -[PKDPlugIn diagnose] accepts an extension without a
# containing application only when rootless_check_trusted(bundleURL) reports
# that its bundle is SIP-protected.  RE-confirmed in Ventura 13.4 pkd UUID
# 76E60957-... at __TEXT+0x7914..+0x7978.  The extracted macOS filesystem lost
# SF_RESTRICTED on these two framework-owned Quick Look bundles (runtime stat:
# flags=0), so iPadOS's real rootless_check_trusted rejected them even after
# their signed sandbox entitlements were restored.  Mark only the bundle URL
# that pkd checks; do not bypass rootless_check_trusted or mark user plug-ins.
for quicklook_system_plugin in \
    '/var/mnt/rootfs/System/Library/Frameworks/QuickLookThumbnailing.framework/Versions/A/PlugIns/ThumbnailExtension_macOS.appex' \
    '/var/mnt/rootfs/System/Library/Frameworks/QuickLookUI.framework/Versions/A/PlugIns/QLPreviewGenerationExtension.appex'; do
    if [ -d "$quicklook_system_plugin" ]; then
        /var/jb/usr/bin/chflags restricted "$quicklook_system_plugin" || exit 1
    fi
done
sign_and_trustcache_merging_native_entitlements \
    '/var/mnt/rootfs/usr/libexec/diskarbitrationd' \
    "$DISKARBITRATIOND_NATIVE_ENT" \
    '<key>com.apple.private.security.disk-device-access</key>' \
    'com.apple.diskarbitrationd' || exit 1
# The chroot has no loginwindow trust/bootstrap handoff. These are direct
# outer-launchd targets, so each top-level executable must already satisfy the
# same project signing policy before libmachook/autosignd can run. Their stock
# code and service contracts remain intact; this only makes the launch targets
# admissible on the iOS kernel and restores dynamic trust after a reboot.
for workspace_binary in \
    '/var/mnt/rootfs/usr/libexec/lsd' \
    '/var/mnt/rootfs/System/Library/CoreServices/sharedfilelistd' \
    '/var/mnt/rootfs/System/Library/CoreServices/iconservicesd' \
    '/var/mnt/rootfs/System/Library/CoreServices/iconservicesagent' \
    '/var/mnt/rootfs/System/Library/Frameworks/QuickLook.framework/Resources/quicklookd.app/Contents/MacOS/quicklookd' \
    '/var/mnt/rootfs/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock' \
    '/var/mnt/rootfs/System/Library/CoreServices/Dock.app/Contents/XPCServices/DockHelper.xpc/Contents/MacOS/DockHelper' \
    '/var/mnt/rootfs/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/CarbonCore.framework/Versions/A/XPCServices/csnameddatad.xpc/Contents/MacOS/csnameddatad' \
    '/var/mnt/rootfs/System/Library/CoreServices/coreservicesd' \
    '/var/mnt/rootfs/System/Library/Frameworks/Security.framework/Versions/A/XPCServices/authd.xpc/Contents/MacOS/authd' \
    '/var/mnt/rootfs/System/Library/PrivateFrameworks/DesktopServicesPriv.framework/Versions/A/Resources/DesktopServicesHelper' \
    '/var/mnt/rootfs/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer' \
    '/var/mnt/rootfs/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter' \
    '/var/mnt/rootfs/System/Applications/Launchpad.app/Contents/MacOS/Launchpad'; do
    ensure_project_signature_and_trustcache "$workspace_binary" || exit 1
done

# Finder/qlmanage load the Ventura legacy Quick Look generators with dlopen,
# so autosignd's exec hook never gets a chance to repair them. Runtime oslog
# on 2026-09-06 captured Image.qlgenerator rejected by AMFI with CT policy 0x8,
# immediately followed by Quick Look's "missing or invalid generator" result.
# These bundle executables run inside the already-authorized client process;
# give each the same no-container signature and persistent boot trust used by
# the directly launched Ventura desktop services.
list_macho_files '/var/mnt/rootfs/System/Library/QuickLook' |
    while IFS= read -r -d '' quicklook_generator; do
        ensure_uncontainered_project_signature_and_trustcache \
            "$quicklook_generator" || exit 1
    done || exit 1
ensure_private_cfprefsd_and_trustcache || exit 1
# Finder's TimelineUI dependency is not present in the iOS dyld shared cache.
# Once Finder itself passed AMFI, dyld runtime-confirmed this exact on-disk
# image was the next rejected arm64e dependency.
ensure_project_signature_and_trustcache \
    '/var/mnt/rootfs/System/Library/PrivateFrameworks/TimelineUI.framework/Versions/A/TimelineUI' || exit 1
# The chroot has no loginwindow LaunchAgent domain, so macos_gui.sh publishes
# the stock fontd's original com.apple.fonts services through an outer launchd
# job. Like Finder, this top-level launch target must already pass AMFI before
# libmachook can run. Preserve its project signature and restore its CDHash on
# every post-reboot repair.
ensure_project_signature_and_trustcache \
    '/var/mnt/rootfs/System/Library/Frameworks/ApplicationServices.framework/Frameworks/ATS.framework/Support/fontd' || exit 1
# Ventura ships libobjc-trampolines without an ARM64/ALL slice even though the
# WindowServer executable in this rootfs is ARM64/ALL.  libobjc lazily dlopens
# this file at the first imp_implementationWithBlock call.  Runtime-confirmed
# after the 2026-09-02 iPad reboot: every WindowServer generation aborted in
# TrampolinePointerWrapper::Initialize with
#   have 'x86_64,x86_64h,arm64e', need 'arm64'
# before graphics-ready.  Add the architecture the real caller requires,
# preserve ARM64/E for ordinary Ventura processes, then re-sign the structurally
# changed universal file before registering all of its CodeDirectories.
OBJC_TRAMPOLINES='/var/mnt/rootfs/usr/lib/libobjc-trampolines.dylib'
if [ -f "$OBJC_TRAMPOLINES" ] && [ -f "$OBJC_TRAMPOLINE_PATCHER" ]; then
    if ! /var/jb/usr/bin/python3 "$OBJC_TRAMPOLINE_PATCHER" \
            --check "$OBJC_TRAMPOLINES" >/dev/null 2>&1; then
        OBJC_TRAMPOLINES_BACKUP="${OBJC_TRAMPOLINES}.pre-macws-arm64"
        [ -e "$OBJC_TRAMPOLINES_BACKUP" ] ||
            cp -p "$OBJC_TRAMPOLINES" "$OBJC_TRAMPOLINES_BACKUP" || exit 1
        /var/jb/usr/bin/python3 "$OBJC_TRAMPOLINE_PATCHER" \
            "$OBJC_TRAMPOLINES" || exit 1
        # The appended slice begins as a byte-for-byte ARM64/E copy with only
        # its Mach subtype corrected.  Re-sign twice so the final CodeDirectory
        # covers ldid's settled __LINKEDIT layout for every fat slice.
        /var/jb/usr/bin/ldid -S "$OBJC_TRAMPOLINES" || exit 1
        /var/jb/usr/bin/ldid -S "$OBJC_TRAMPOLINES" || exit 1
    fi
fi
add_all_trustcache /var/mnt/rootfs/usr/lib/libobjc-trampolines.dylib
add_all_trustcache /var/mnt/rootfs/usr/lib/dyld
add_all_trustcache /var/mnt/rootfs/bin/ps
add_all_trustcache /var/mnt/rootfs/bin/mv
add_all_trustcache /var/mnt/rootfs/bin/cp
add_all_trustcache /var/mnt/rootfs/usr/bin/log
add_all_trustcache /var/mnt/rootfs/bin/launchctl
add_all_trustcache /var/mnt/rootfs/usr/bin/open
add_all_trustcache /var/jb/usr/macOS/bin/PingMTLCompilerService
add_all_trustcache /var/jb/usr/macOS/bin/macws-llvm-dis
add_all_trustcache /var/jb/usr/macOS/bin/macws-llvm-as
add_all_trustcache /var/jb/usr/macOS/bin/launchdchrootexec
add_all_trustcache /var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate
add_all_trustcache /var/mnt/rootfs/System/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate
add_all_trustcache /var/mnt/rootfs/System/Tweaks/TweakLoader.dylib
add_all_trustcache "/var/mnt/rootfs/System/Library/CoreServices/Installer Progress.app/Contents/MacOS/Installer Progress"
add_all_trustcache /var/mnt/rootfs/usr/lib/systemhook.dylib
add_all_trustcache /var/jb/usr/lib/libroot.dylib
add_all_trustcache /var/mnt/rootfs/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/CursorAsset
add_all_trustcache /var/mnt/rootfs/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/CursorAsset_base
add_all_trustcache /var/mnt/rootfs/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/31001/Libraries/libGPUCompiler.dylib
# Runtime-confirmed on the 2026-09-14 cold boot: a uid/gid 501 Terminal main
# image was rejected by the root-owned first-party application admission
# invariant before spawn. Repair only the canonical regular stock executable;
# its content and existing CodeDirectory remain unchanged.
TERMINAL_MAIN=/var/mnt/rootfs/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
if [ -e "$TERMINAL_MAIN" ]; then
    [ -f "$TERMINAL_MAIN" ] && [ ! -L "$TERMINAL_MAIN" ] || {
        echo 'ERROR: Terminal main executable is not a regular file.' >&2
        exit 1
    }
    chown root:wheel "$TERMINAL_MAIN" || exit 1
fi
add_all_trustcache /var/mnt/rootfs/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
sign_and_trustcache '/var/mnt/rootfs/System/Applications/System Settings.app/Contents/MacOS/System Settings'
sign_and_trustcache_with_identifier_requirement \
    '/var/mnt/rootfs/System/Applications/Maps.app/Contents/MacOS/Maps' \
    'com.apple.Maps' || exit 1
prepare_sign_and_trustcache_weather || exit 1
install_sublime_software_renderer_default || exit 1
# GlassDemo is launched directly by macwshostd before libmachook can ask
# autosignd for help. Its persistent signature survives reboot, while
# Dopamine's dynamic trustcache does not.
add_all_trustcache /var/mnt/rootfs/tmp/GlassDemo
add_all_trustcache /var/mnt/rootfs/usr/local/lib/.jbroot/usr/lib/libroot.dylib
# A user application's main executable is not enough after a reboot: dyld must
# admit its nested frameworks before libmachook/autosignd has a chance to run.
# VS Code first exposed this with Electron/Squirrel/Mantle/ReactiveObjC, but the
# invariant applies equally to newly installed AppKit and Electron bundles.
# Restore every *already-signed* executable in /Applications so launch-by-path
# remains cold-boot safe without growing a hard-coded application list.
for application_bundle in /var/mnt/rootfs/Applications/*.app; do
    [ -d "$application_bundle" ] || continue
    trust_existing_app_bundle \
        "$application_bundle" \
        "$(basename "$application_bundle" .app)"
done
# Microsoft Office's applications talk to this helper before an injected app
# can ask autosignd to repair it.  A freshly expanded Microsoft 16.91 package
# carries only its vendor application identifier here; runtime inspection on
# iPad14,4 / iPadOS 16.2 (2026-09-29) showed that the known-working helper also
# needs the project's native+MacWS merged launch policy.  Establish that
# persistent invariant once, preserving the vendor identity with ldid -M, then
# restore every architecture's dynamic trust entry on later boots.
ensure_project_signature_and_trustcache \
    /var/mnt/rootfs/Library/PrivilegedHelperTools/com.microsoft.office.licensingV2.helper
# vnc server
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/MacOS/ARDAgent
add_all_trustcache /var/mnt/rootfs/bin/launchctl
add_all_trustcache /var/mnt/rootfs/bin/rm
add_all_trustcache /var/mnt/rootfs/bin/ls
add_all_trustcache /var/mnt/rootfs/bin/kill
add_all_trustcache /var/mnt/rootfs/bin/pwd
add_all_trustcache /var/mnt/rootfs/usr/bin/python3
add_all_trustcache /var/mnt/rootfs/usr/bin/defaults
add_all_trustcache /var/mnt/rootfs/usr/bin/perl
add_all_trustcache /var/mnt/rootfs/usr/bin/perl5.30
add_all_trustcache /var/mnt/rootfs/usr/bin/which
add_all_trustcache /var/mnt/rootfs/usr/bin/env
add_all_trustcache /var/mnt/rootfs/usr/bin/grep
add_all_trustcache /var/mnt/rootfs/usr/bin/vim
add_all_trustcache /var/mnt/rootfs/usr/bin/whoami
add_all_trustcache /var/mnt/rootfs/sbin/mount
add_all_trustcache /var/mnt/rootfs/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer
add_all_trustcache /var/mnt/rootfs/usr/local/bin/OSXvnc-server
sign_and_trustcache /var/mnt/rootfs/usr/libexec/pboard
sign_and_trustcache /var/mnt/rootfs/System/Library/CoreServices/pbs
bash /var/jb/usr/macOS/bin/ensure_jb_usr_bind.sh || exit 1

# Mount a writable devfs into the chroot /dev. Without it the rootfs /dev has no
# /dev/ptmx, so pty programs fail: Terminal.app -> forkpty -> open("/dev/ptmx")
# returns ENOENT ("forkpty: No such file or directory") and no shell spawns.
# mount_bindfs would expose the nodes read-only (ptmx O_RDWR -> EROFS) and the
# macOS mount_devfs is EPERM'd inside the chroot, so use our iOS-native helper.
# It is idempotent (no-op if /var/mnt/rootfs/dev is already a devfs).
if [ -x /var/jb/usr/macOS/bin/mountdevfs ]; then
	add_all_trustcache /var/jb/usr/macOS/bin/mountdevfs
	/var/jb/usr/macOS/bin/mountdevfs /var/mnt/rootfs/dev
fi

# ─── Homebrew / MacPorts: sign macOS rootfs utilities ─────────────────────────
# These binaries need re-signing because their Apple signatures are not in
# Dopamine's trustcache. sign_and_trustcache re-signs with our entitlements.plist
# and registers CDHashes — run once on first setup, then CDHashes are re-added
# on every reboot automatically.

ROOTFS=/var/mnt/rootfs

# Ventura QuartzCore's real desktop-window-effects shaders are compiled for a
# macOS AIR target, while this project intentionally executes them on the iOS
# native AGX driver. The focused provisioner preserves the original library,
# regenerates a complete secondary macabi artifact when required, and verifies
# the source/output identities recorded by metal2metal. It is also called by
# dpkg's postinst so an upgrade cannot leave a stale shader artifact behind
# valid trust sentinels.
METAL2METAL=/var/jb/usr/macOS/bin/metal2metal.py
METAL2METAL_ROUTE_DIR="$ROOTFS/usr/local/share/macws/metal2metal/routes"
QC_LLVM_DIS=/var/jb/usr/lib/llvm-16/bin/llvm-dis
QC_LLVM_AS=/var/jb/usr/lib/llvm-16/bin/llvm-as

qc_sha256() {
	sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

bash /var/jb/usr/macOS/bin/ensure_quartzcore_compat.sh || exit 1

# SkyLight has an independent desktop AIR target mismatch. Runtime failures
# reached backing-window, menu-bar, Mission Control, simple-color,
# alpha-texture, tile, and window-shadow paths. metal_source_probe enumerated
# all 54 functions in the exact Ventura 13.4 source and confirmed that every
# function carries the same desktop target (43 base functions and 11 requiring
# function constants). Retarget the complete library as one coherent closure;
# never replace the process-wide source library.
SKY_DEFAULT="$ROOTFS/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/SkyLightShaders.air64.metallib"
SKY_EXPECTED_SHA256=378174fcbf7fc639aa737cad7a765690b2d76fa3a66c7a8e71018441f3ac3184
SKY_COMPAT_DIR="$ROOTFS/usr/local/share/macws/skylight"
SKY_COMPAT_TARGET="$SKY_COMPAT_DIR/SkyLightShaders-desktop-effects-macabi.metallib"
SKY_MANIFEST_TARGET="$METAL2METAL_ROUTE_DIR/skylight-shaders.route.plist"
SKY_COMPAT_EXPECTED_SHA256=bfe93e8146325a912a0db9fc1ed28a2de32aa9ccb4065148398be12ac0644df1
if [ "$(qc_sha256 "$SKY_DEFAULT")" != "$SKY_EXPECTED_SHA256" ]; then
	echo "[ERROR] SkyLightShaders.air64.metallib is not the supported macOS 13.4 library." >&2
	exit 1
fi
mkdir -p "$SKY_COMPAT_DIR" "$METAL2METAL_ROUTE_DIR" || exit 1
SKY_COMPAT_TMP="$SKY_COMPAT_TARGET.new.$$"
SKY_MANIFEST_TMP="$SKY_MANIFEST_TARGET.new.$$"
python3 "$METAL2METAL" translate "$SKY_DEFAULT" "$SKY_COMPAT_TMP" \
	--llvm-dis "$QC_LLVM_DIS" --llvm-as "$QC_LLVM_AS" \
	--runtime-manifest "$SKY_MANIFEST_TMP" \
	--runtime-source-path "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/SkyLightShaders.air64.metallib" \
	--runtime-output-path "/usr/local/share/macws/skylight/SkyLightShaders-desktop-effects-macabi.metallib" || exit 1
if [ "$(qc_sha256 "$SKY_COMPAT_TMP")" != "$SKY_COMPAT_EXPECTED_SHA256" ]; then
	echo "[ERROR] Generated SkyLight desktop-effects library failed exact validation." >&2
	exit 1
fi
python3 "$METAL2METAL" verify-runtime-manifest "$SKY_MANIFEST_TMP" \
	--source "$SKY_DEFAULT" --output "$SKY_COMPAT_TMP" || exit 1
chmod 0644 "$SKY_COMPAT_TMP" || exit 1
chmod 0644 "$SKY_MANIFEST_TMP" || exit 1
mv -f "$SKY_COMPAT_TMP" "$SKY_COMPAT_TARGET" || exit 1
mv -f "$SKY_MANIFEST_TMP" "$SKY_MANIFEST_TARGET" || exit 1
echo '[INFO] installed exact SkyLight desktop-effects macabi shader library'

# MPSImage supplies the real desktop-effects reduction kernel reached after
# SkyLight's desktop surface pipelines are available. Runtime-confirmed
# failures first exposed its reduction kernels, but the ABI
# mismatch belongs to the library target rather than those names. Translate
# the complete exact Ventura source and let the generated manifest describe
# base versus function-constant creation structurally.
MPSIMAGE_DEFAULT="$ROOTFS/System/Library/Frameworks/MetalPerformanceShaders.framework/Versions/A/Frameworks/MPSImage.framework/Versions/A/Resources/default.metallib"
MPSIMAGE_EXPECTED_SHA256=376ded7ee154429f6950656eb668b26af27fc6149b734b11dd48a33d68fe4285
MPSIMAGE_COMPAT_DIR="$ROOTFS/usr/local/share/macws/mpsimage"
MPSIMAGE_COMPAT_TARGET="$MPSIMAGE_COMPAT_DIR/default-desktop-effects-macabi.metallib"
MPSIMAGE_MANIFEST_TARGET="$METAL2METAL_ROUTE_DIR/mpsimage-default.route.plist"
if [ "$(qc_sha256 "$MPSIMAGE_DEFAULT")" != "$MPSIMAGE_EXPECTED_SHA256" ]; then
	echo "[ERROR] MPSImage default.metallib is not the supported macOS 13.4 library." >&2
	exit 1
fi
mkdir -p "$MPSIMAGE_COMPAT_DIR" "$METAL2METAL_ROUTE_DIR" || exit 1
MPSIMAGE_COMPAT_TMP="$MPSIMAGE_COMPAT_TARGET.new.$$"
MPSIMAGE_MANIFEST_TMP="$MPSIMAGE_MANIFEST_TARGET.new.$$"
python3 "$METAL2METAL" translate "$MPSIMAGE_DEFAULT" "$MPSIMAGE_COMPAT_TMP" \
	--llvm-dis "$QC_LLVM_DIS" --llvm-as "$QC_LLVM_AS" \
	--auto-lower-known-air \
	--runtime-manifest "$MPSIMAGE_MANIFEST_TMP" \
	--runtime-source-path "/System/Library/Frameworks/MetalPerformanceShaders.framework/Versions/A/Frameworks/MPSImage.framework/Versions/A/Resources/default.metallib" \
	--runtime-output-path "/usr/local/share/macws/mpsimage/default-desktop-effects-macabi.metallib" || exit 1
python3 "$METAL2METAL" verify-runtime-manifest "$MPSIMAGE_MANIFEST_TMP" \
	--source "$MPSIMAGE_DEFAULT" --output "$MPSIMAGE_COMPAT_TMP" || exit 1
chmod 0644 "$MPSIMAGE_COMPAT_TMP" || exit 1
chmod 0644 "$MPSIMAGE_MANIFEST_TMP" || exit 1
mv -f "$MPSIMAGE_COMPAT_TMP" "$MPSIMAGE_COMPAT_TARGET" || exit 1
mv -f "$MPSIMAGE_MANIFEST_TMP" "$MPSIMAGE_MANIFEST_TARGET" || exit 1
echo '[INFO] installed complete MPSImage metal2metal library'

# Chromium 148 / Electron 42 ships ANGLE's default Metal library for macOS.
# Its container loads in the chroot, but iOS MTLCompilerService rejects
# function-constant specialization with "Target OS is incompatible". Install
# the byte-validated replacement built from the exact ANGLE 1ba8ec3 generated
# source through the project's real macabi compiler adapter. libmachook selects
# it only when the original embedded library's length+FNV hash match.
ANGLE_MACABI_SOURCE=/var/jb/usr/macOS/share/angle/angle-default-1ba8ec3-macabi.metallib
ANGLE_MACABI_DIR="$ROOTFS/usr/local/share/macws/angle"
ANGLE_MACABI_TARGET="$ANGLE_MACABI_DIR/angle-default-1ba8ec3-macabi.metallib"
if [ ! -f "$ANGLE_MACABI_SOURCE" ] ||
   [ "$(wc -c < "$ANGLE_MACABI_SOURCE" 2>/dev/null)" != 714152 ]; then
	echo "[ERROR] Packaged ANGLE macabi default library is missing or invalid." >&2
	exit 1
fi
mkdir -p "$ANGLE_MACABI_DIR" || exit 1
ANGLE_MACABI_TMP="$ANGLE_MACABI_TARGET.new.$$"
cp "$ANGLE_MACABI_SOURCE" "$ANGLE_MACABI_TMP" || exit 1
chmod 0644 "$ANGLE_MACABI_TMP" || exit 1
mv -f "$ANGLE_MACABI_TMP" "$ANGLE_MACABI_TARGET" || exit 1
echo '[INFO] installed ANGLE 1ba8ec3 macabi default Metal library'

# Steam build 1785799196 carries Chromium 126 / ANGLE 5d4df51 rather than
# VS Code's Chromium 148 shader set.  Install its independently generated and
# byte-validated macabi library; libmachook selects it only for Steam's exact
# 368459-byte/FNV-identified upstream container.
STEAM_ANGLE_MACABI_SOURCE=/var/jb/usr/macOS/share/angle/angle-default-5d4df51-macabi.metallib
STEAM_ANGLE_MACABI_TARGET="$ANGLE_MACABI_DIR/angle-default-5d4df51-macabi.metallib"
if [ ! -f "$STEAM_ANGLE_MACABI_SOURCE" ] ||
   [ "$(wc -c < "$STEAM_ANGLE_MACABI_SOURCE" 2>/dev/null)" != 711592 ]; then
	echo "[ERROR] Packaged Steam ANGLE macabi default library is missing or invalid." >&2
	exit 1
fi
STEAM_ANGLE_MACABI_TMP="$STEAM_ANGLE_MACABI_TARGET.new.$$"
cp "$STEAM_ANGLE_MACABI_SOURCE" "$STEAM_ANGLE_MACABI_TMP" || exit 1
chmod 0644 "$STEAM_ANGLE_MACABI_TMP" || exit 1
mv -f "$STEAM_ANGLE_MACABI_TMP" "$STEAM_ANGLE_MACABI_TARGET" || exit 1
echo '[INFO] installed Steam ANGLE 5d4df51 macabi default Metal library'

# Metal's on-disk source-library cache key omits the effective target triple.
# Caches created before the MacWS macabi source adapter therefore contain
# valid MTLBs for iOS that the macOS AGX device rejects. Version this narrow,
# regenerable cache independently from Chromium's profile/session caches.
VSCODE_METAL_CACHE_ROOT="$ROOTFS/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/C/com.microsoft.VSCode.helper/com.apple.metal"
VSCODE_METAL_LIBRARY_CACHE="$VSCODE_METAL_CACHE_ROOT/31001"
VSCODE_METAL_CACHE_SCHEMA=macws-macabi-source-v1
VSCODE_METAL_CACHE_MARKER="$VSCODE_METAL_CACHE_ROOT/.macws-source-target-schema"

invalidate_vscode_metal_source_cache() {
	local installed_schema="" marker_tmp=""
	[ -d "$ROOTFS/Applications/Visual Studio Code.app" ] || return 0
	[ ! -f "$VSCODE_METAL_CACHE_MARKER" ] ||
		installed_schema=$(sed -n '1p' "$VSCODE_METAL_CACHE_MARKER" 2>/dev/null)
	[ "$installed_schema" != "$VSCODE_METAL_CACHE_SCHEMA" ] || return 0

	# postinst can be invoked manually. Do not unlink an active helper's
	# mmap-backed cache: leave the marker absent and macos_gui.sh will perform
	# the same migration after its normal exact-process cleanup.
	if ps ax -o command= 2>/dev/null |
	   grep -E '[V]isual Studio Code\.app|[C]ode Helper' >/dev/null; then
		rm -f "$VSCODE_METAL_CACHE_MARKER"
		echo "[INFO] VS Code is running; deferred Metal source-cache migration to the next GUI start."
		return 0
	fi

	mkdir -p "$VSCODE_METAL_CACHE_ROOT" || return 1
	rm -f "$VSCODE_METAL_LIBRARY_CACHE/libraries.list" \
	      "$VSCODE_METAL_LIBRARY_CACHE/libraries.data" || return 1
	marker_tmp="$VSCODE_METAL_CACHE_MARKER.$$"
	printf '%s\n' "$VSCODE_METAL_CACHE_SCHEMA" > "$marker_tmp" || return 1
	mv -f "$marker_tmp" "$VSCODE_METAL_CACHE_MARKER" || return 1
	echo "[INFO] VS Code Metal source cache migrated to $VSCODE_METAL_CACHE_SCHEMA."
}

invalidate_vscode_metal_source_cache || {
	echo "[ERROR] Failed to migrate the VS Code Metal source cache." >&2
	exit 1
}

# Retire incompatible pre-DAG-fix Metal libraries once, after clients have
# exited. A live upgrade defers without touching any open cache; normal GUI
# startup retries at its cleanup boundary. No debug flag enables this fix.
/var/jb/usr/bin/python3 "${BASH_SOURCE[0]%/*}/macws_metal_cache_migration.py" \
	--rootfs "$ROOTFS" --defer-if-running || {
	echo "[ERROR] Failed to migrate the Metal DAG target cache." >&2
	exit 1
}

# Runtime `ps eww` on a fresh Terminal session shows that Terminal launches
# `/bin/bash` without `--login` and strips HOME/USER/SHELL from the child
# environment. This bash build did not consume a user startup file even when
# tested with explicit `--rcfile`; exec_hooks therefore sources the requested
# /Users/root/.bashrc in Terminal's direct shell prelude. Install loaders in
# root's ordinary non-login/login files as a fallback for sessions that do use
# standard bash startup processing after a reboot or a preference change.
TERMINAL_LOGIN_HOME="$ROOTFS/var/root"
TERMINAL_BASHRC_MARKER='# MacWS: load the interactive bash configuration'
mkdir -p "$TERMINAL_LOGIN_HOME"
# 0.3.4 briefly used BASH_ENV for this handoff. The production exec adapter
# now uses a Terminal-parent-scoped explicit prelude, so non-interactive child
# scripts remain untouched; remove only that exact obsolete managed file.
rm -f "$TERMINAL_LOGIN_HOME/.macws-terminal-env"

for TERMINAL_STARTUP_FILE in \
	"$TERMINAL_LOGIN_HOME/.bashrc" \
	"$TERMINAL_LOGIN_HOME/.bash_profile"
do
	if grep -Fq "$TERMINAL_BASHRC_MARKER" "$TERMINAL_STARTUP_FILE" 2>/dev/null; then
		continue
	fi
	if grep -Eq '(^|[[:space:]])(\.|source)[[:space:]]+/Users/root/\.bashrc' \
			"$TERMINAL_STARTUP_FILE" 2>/dev/null; then
		# Respect an existing user-owned integration. Appending our managed
		# block would source .bashrc twice and repeat aliases/PATH edits.
		continue
	fi
	{
		printf '\n%s\n' "$TERMINAL_BASHRC_MARKER"
		printf 'if [ -f /Users/root/.bashrc ]; then\n'
		printf '    . /Users/root/.bashrc\n'
		printf 'fi\n'
	} >> "$TERMINAL_STARTUP_FILE"
done
echo '[INFO] Terminal shells now source /Users/root/.bashrc'

# Keep project-managed MacPorts CLIs ahead of old one-off installations in
# /usr/local/bin. The package maintainer script invokes this same idempotent
# helper, so a normal dpkg install and a manual deep repair cannot diverge.
bash /var/jb/usr/macOS/bin/configure_terminal_cli.sh "$ROOTFS" || exit 1

# Core shell / execution helpers
sign_and_trustcache "$ROOTFS/bin/sh"
sign_and_trustcache "$ROOTFS/bin/chmod"
sign_and_trustcache "$ROOTFS/bin/mkdir"
sign_and_trustcache "$ROOTFS/bin/ln"
sign_and_trustcache "$ROOTFS/bin/cat"
sign_and_trustcache "$ROOTFS/bin/echo"

# Text processing
sign_and_trustcache "$ROOTFS/usr/bin/awk"
sign_and_trustcache "$ROOTFS/usr/bin/cut"
sign_and_trustcache "$ROOTFS/usr/bin/sed"
sign_and_trustcache "$ROOTFS/usr/bin/head"
sign_and_trustcache "$ROOTFS/usr/bin/tail"
sign_and_trustcache "$ROOTFS/usr/bin/tr"
sign_and_trustcache "$ROOTFS/usr/bin/sort"
sign_and_trustcache "$ROOTFS/usr/bin/uniq"
sign_and_trustcache "$ROOTFS/usr/bin/wc"
sign_and_trustcache "$ROOTFS/usr/bin/tee"
sign_and_trustcache "$ROOTFS/usr/bin/xargs"
sign_and_trustcache "$ROOTFS/usr/bin/grep"

# File / path utilities
sign_and_trustcache "$ROOTFS/usr/bin/find"
sign_and_trustcache "$ROOTFS/usr/bin/stat"
sign_and_trustcache "$ROOTFS/usr/bin/file"
sign_and_trustcache "$ROOTFS/usr/bin/readlink"
sign_and_trustcache "$ROOTFS/usr/bin/realpath"
sign_and_trustcache "$ROOTFS/usr/bin/install"
sign_and_trustcache "$ROOTFS/usr/bin/mktemp"
sign_and_trustcache "$ROOTFS/usr/bin/xcode-select"

# System info / privilege
sign_and_trustcache "$ROOTFS/usr/bin/uname"
sign_and_trustcache "$ROOTFS/usr/bin/sw_vers"
sign_and_trustcache "$ROOTFS/usr/bin/arch"
sign_and_trustcache "$ROOTFS/usr/bin/id"
sign_and_trustcache "$ROOTFS/usr/bin/date"
sign_and_trustcache "$ROOTFS/usr/bin/sudo"
sign_and_trustcache "$ROOTFS/usr/sbin/chown"

# Archive / compression
sign_and_trustcache "$ROOTFS/usr/bin/tar"
sign_and_trustcache "$ROOTFS/usr/bin/gzip"
sign_and_trustcache "$ROOTFS/usr/bin/bzip2"
sign_and_trustcache "$ROOTFS/usr/bin/xz"
sign_and_trustcache "$ROOTFS/usr/bin/zstd"
sign_and_trustcache "$ROOTFS/usr/bin/lz4"
sign_and_trustcache "$ROOTFS/usr/bin/unzip"

# Network
sign_and_trustcache "$ROOTFS/usr/bin/curl"
sign_and_trustcache "$ROOTFS/usr/bin/openssl"
sign_and_trustcache "$ROOTFS/usr/bin/rsync"

# Scripting runtimes
sign_and_trustcache "$ROOTFS/usr/bin/ruby"
sign_and_trustcache "$ROOTFS/usr/bin/git"

# Claude Code (native bun/JSC binary installed to /usr/local/bin/claude) and the
# macOS Keychain CLI it spawns for credential storage. See README "Running
# Claude Code in the chroot". Run with GIGACAGE_ENABLED=0 (see ~/.bashrc).
sign_and_trustcache "$ROOTFS/usr/local/bin/claude"
sign_and_trustcache "$ROOTFS/usr/bin/security"

# Portable Ruby (Homebrew's vendored Ruby 4.0.1)
PRUBY="$ROOTFS/opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.1"
sign_and_trustcache "$PRUBY/bin/ruby"
for bundle in \
    "lib/ruby/gems/4.0.0/extensions/arm64-darwin-20/4.0.0-static/fiddle-1.1.8/fiddle.bundle" \
    "lib/ruby/gems/4.0.0/extensions/arm64-darwin-20/4.0.0-static/debug-1.11.1/debug/debug.bundle" \
    "lib/ruby/gems/4.0.0/extensions/arm64-darwin-20/4.0.0-static/bootsnap-1.21.1/bootsnap/bootsnap.bundle" \
    "lib/ruby/gems/4.0.0/extensions/arm64-darwin-20/4.0.0-static/msgpack-1.8.0/msgpack/msgpack.bundle"
do
    sign_and_trustcache "$PRUBY/$bundle"
done

# MacPorts binaries and libraries (installed at /opt/local)
# Re-adds CDHashes on every reboot (signing is persistent, trustcache is not).
# On first install, run the bulk-sign loop in CLAUDE.md "Skills" to sign all Mach-O files.
if [ -d "$ROOTFS/opt/local" ]; then
    # Tcl interpreter (MacPorts uses tclsh internally; port binary is a wrapper script)
    sign_and_trustcache "$ROOTFS/opt/local/libexec/macports/bin/tclsh8.6"
    sign_and_trustcache "$ROOTFS/opt/local/bin/tclsh"
    sign_and_trustcache "$ROOTFS/opt/local/bin/tclsh9.0"

    # Confirmed-installed dependency libraries
    for lib in liblzma liblzma.5 libedit libedit.3 libffi libffi.8 \
                libintl libintl.8 libiconv libiconv.2 \
                libsqlite3 libsqlite3.0 libbz2 libbz2.1.0 libbz2.1 \
                libncurses libncurses.6 libncursesw libncursesw.6 \
                libmpdec libmpdec.4 libmpdec++ libmpdec++.4; do
        sign_and_trustcache "$ROOTFS/opt/local/lib/${lib}.dylib"
    done

    # Python 3.13 (confirmed working; installed via port install python313)
    PY313="$ROOTFS/opt/local/Library/Frameworks/Python.framework/Versions/3.13"
    sign_and_trustcache "$ROOTFS/opt/local/bin/python3.13"
    sign_and_trustcache "$PY313/bin/python3.13"
    sign_and_trustcache "$PY313/Resources/Python.app/Contents/MacOS/Python"
    sign_and_trustcache "$PY313/Python"

    # Python 3.13 extension modules and site-packages .so files
    # (also picks up any new .so files installed by pip)
    find "$PY313/lib" -type f \( -name "*.so" -o -name "*.dylib" \) 2>/dev/null \
        | while read f; do sign_and_trustcache "$f"; done

    # Re-register CDHashes for MacPorts Mach-O binaries/dylibs.
    # Only process files with Mach-O extensions to skip scripts/text files.
    echo "[INFO] Scanning MacPorts for Mach-O files..."
    MACHO_COUNT=0
    for dir in "$ROOTFS/opt/local/bin" "$ROOTFS/opt/local/sbin"; do
        [ -d "$dir" ] || continue
        for f in "$dir"/*; do
            [ -f "$f" ] || continue
            # Skip shell scripts (check for #! or text files)
            head -c2 "$f" 2>/dev/null | grep -q '^#!' && continue
            sign_and_trustcache "$f"
            MACHO_COUNT=$((MACHO_COUNT + 1))
        done
    done
    # Process only .dylib, .so, .bundle in lib directories
    find "$ROOTFS/opt/local/lib" "$ROOTFS/opt/local/libexec" \
         -type f \( -name "*.dylib" -o -name "*.so" -o -name "*.bundle" -o -name "*.a" \) \
         2>/dev/null | while read f; do
        sign_and_trustcache "$f"
        MACHO_COUNT=$((MACHO_COUNT + 1))
    done
    echo "[INFO] Processed $MACHO_COUNT MacPorts files"
fi

# Input protocol receivers map libmachook/macwsinputd for their complete
# lifetime.  Replacing the files on disk cannot update a running Dock or input
# broker; runtime disassembly on 2026-09-07 showed a live ABI-5 Dock rejecting
# every ABI-6 fullscreen pointer record after an otherwise successful package
# install.  Reload only jobs that were already loaded, after the new binaries
# have been copied, signed and trustcached.  This preserves the stopped-GUI
# state and does not disturb ordinary AppKit applications.
reload_loaded_input_job() {
    local label="$1"
    local plist="$2"
    [ -f "$plist" ] || return 0
    if ! launchctl list "$label" >/dev/null 2>&1; then
        return 0
    fi
    launchctl unload "$plist" 2>/dev/null || true
    if ! launchctl load "$plist"; then
        echo "[ERROR] failed to reload live input job $label" >&2
        return 1
    fi
    echo "[INFO] reloaded live input job $label"
}

reload_loaded_input_job \
    'UIKitApplication:com.macwsguide.input' \
    '/var/jb/usr/macOS/LaunchDaemons/com.macwsguide.input.plist' || exit 1
reload_loaded_input_job \
    'com.macwsguide.dock' \
    '/var/jb/usr/macOS/gui-launchd/com.macwsguide.dock.plist' || exit 1
