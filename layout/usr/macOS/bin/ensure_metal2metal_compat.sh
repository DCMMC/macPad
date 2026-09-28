# No shebang: invoke with bash. This jailbreak's AMFI rejects execve of
# shebang scripts.

# Provision the complete manifest-driven desktop Metal compatibility set.
# Every route is accepted only after the exact source and translated output
# both verify against its manifest. Existing valid routes are constant-time
# no-ops, so package upgrades and GUI cold starts share this one boundary
# without repeating LLVM work.
set -o pipefail

ROOTFS=/var/mnt/rootfs
METAL2METAL=/var/jb/usr/macOS/bin/metal2metal.py
OFFICE_PROVISIONER=/var/jb/usr/macOS/bin/ensure_office_metal2metal.py
LLVM_DIS=/var/jb/usr/lib/llvm-16/bin/llvm-dis
LLVM_AS=/var/jb/usr/lib/llvm-16/bin/llvm-as
APPLE_LLVM_DIS=/var/jb/usr/macOS/bin/macws-llvm-dis
APPLE_LLVM_AS=/var/jb/usr/macOS/bin/macws-llvm-as
ROUTE_DIR="$ROOTFS/usr/local/share/macws/metal2metal/routes"
BOOT_READY_MARKER=/tmp/macws-metal2metal.boot-ready

# Full manifest verification reads and hashes six source/output metallib
# pairs and starts Python once per route. That remains the authoritative
# deployment/update boundary. During one live iPad boot, reuse its success
# only while the exact scripts, sources, outputs and manifests retain their
# filesystem identities. APFS replacement changes inode/ctime even when an
# installer preserves mtime, while a reboot changes the first stamp field.
# Keep fractional timestamps: same-inode, same-size corruption in one second
# must not reuse an earlier successful verification from that second.
metal2metal_runtime_stamp() {
	local boot_id="" path=""
	boot_id=$(/var/jb/usr/sbin/sysctl -n kern.bootsessionuuid 2>/dev/null |
		/var/jb/usr/bin/tr -d '[:space:]')
	[ -n "$boot_id" ] || return 1
	{
		printf 'schema=3 boot=%s\n' "$boot_id"
		for path in \
			/var/jb/usr/macOS/bin/ensure_metal2metal_compat.sh \
			/var/jb/usr/macOS/bin/ensure_quartzcore_compat.sh \
			"$METAL2METAL" \
			"$OFFICE_PROVISIONER" \
			"$APPLE_LLVM_DIS" "$APPLE_LLVM_AS" \
			"$ROOTFS/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib" \
			"$ROOTFS/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib.macws-macos13.4-original" \
			"$ROOTFS/usr/local/share/macws/quartzcore/default-desktop-effects-macabi.metallib" \
			"$ROUTE_DIR/quartzcore-default.route.plist" \
			"$ROOTFS/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/SkyLightShaders.air64.metallib" \
			"$ROOTFS/usr/local/share/macws/skylight/SkyLightShaders-desktop-effects-macabi.metallib" \
			"$ROUTE_DIR/skylight-shaders.route.plist" \
			"$ROOTFS/System/Library/Frameworks/MetalPerformanceShaders.framework/Versions/A/Frameworks/MPSImage.framework/Versions/A/Resources/default.metallib" \
			"$ROOTFS/usr/local/share/macws/mpsimage/default-desktop-effects-macabi.metallib" \
			"$ROUTE_DIR/mpsimage-default.route.plist" \
			"$ROOTFS/System/Library/Frameworks/MetalFX.framework/Versions/A/Resources/default.metallib" \
			"$ROOTFS/usr/local/share/macws/metalfx/default-temporal-macabi.metallib" \
			"$ROUTE_DIR/metalfx-default.route.plist" \
			"$ROOTFS/System/Library/Frameworks/MetalPerformanceShaders.framework/Versions/A/Frameworks/MPSCore.framework/Versions/A/Resources/default.metallib" \
			"$ROOTFS/usr/local/share/macws/mpscore/default-compute-macabi.metallib" \
			"$ROUTE_DIR/mpscore-default.route.plist" \
			"$ROOTFS/System/Library/Frameworks/MetalPerformanceShaders.framework/Versions/A/Frameworks/MPSNDArray.framework/Versions/A/Resources/default.metallib" \
			"$ROOTFS/usr/local/share/macws/mpsndarray/default-compute-macabi.metallib" \
			"$ROUTE_DIR/mpsndarray-default.route.plist"; do
			[ -f "$path" ] || return 1
			/var/jb/usr/bin/stat -c '%d:%i:%s:%y:%z' "$path" || return 1
		done
		# Optional installed application resources belong in this cache key too.
		# Installing/updating Office or replacing/removing a generated artifact
		# must invalidate the same-boot shortcut, without an enable sentinel.
		for path in \
			"$ROOTFS/Applications/Microsoft Word.app/Contents/Resources/Arc.bundle/Metal2DShaders.metallib.zip" \
			"$ROOTFS/Applications/Microsoft PowerPoint.app/Contents/Resources/Arc.bundle/Metal2DShaders.metallib.zip" \
			"$ROOTFS/Applications/Microsoft Excel.app/Contents/Resources/Arc.bundle/Metal2DShaders.metallib.zip" \
			"$ROUTE_DIR"/office-metal2d-*.route.plist \
			"$ROOTFS/usr/local/share/macws/metal2metal/office"/*/*.metallib; do
			printf 'optional=%s\n' "$path"
			if [ -f "$path" ]; then
				/var/jb/usr/bin/stat -c '%d:%i:%s:%y:%z' "$path" || return 1
			else
				printf 'absent\n'
			fi
		done
	} | /var/jb/usr/bin/sha256sum | /var/jb/usr/bin/awk '{print $1}'
}

metal2metal_sha256() {
	sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

metal2metal_hash_allowed() {
	local path="$1" allowed="$2" actual="" candidate=""
	[ -z "$allowed" ] && return 0
	actual=$(metal2metal_sha256 "$path")
	for candidate in $allowed; do
		[ "$actual" = "$candidate" ] && return 0
	done
	return 1
}

if [ ! -f "$METAL2METAL" ] || [ ! -x "$LLVM_DIS" ] ||
   [ ! -x "$LLVM_AS" ] || [ ! -x "$APPLE_LLVM_DIS" ] || [ ! -x "$APPLE_LLVM_AS" ]; then
	echo "[ERROR] metal2metal or its packaged LLVM tools are unavailable." >&2
	exit 1
fi

runtime_stamp=$(metal2metal_runtime_stamp 2>/dev/null || true)
if [ -n "$runtime_stamp" ] && [ -f "$BOOT_READY_MARKER" ] &&
   [ "$(/var/jb/usr/bin/sed -n '1p' "$BOOT_READY_MARKER" 2>/dev/null)" = "$runtime_stamp" ]; then
	echo '[INFO] complete metal2metal runtime verification reused for this bootsession'
	exit 0
fi

# QuartzCore also owns restoration of a diagnostically replaced system
# default.metallib, so retain that focused provisioner as the source owner.
bash /var/jb/usr/macOS/bin/ensure_quartzcore_compat.sh || exit 1

provision_route() {
	name="$1"
	source="$2"
	expected_source_sha256="$3"
	output="$4"
	manifest="$5"
	runtime_source="$6"
	runtime_output="$7"
	expected_output_sha256="$8"
	auto_lower="$9"
	local route_dis="${10:-$LLVM_DIS}" route_as="${11:-$LLVM_AS}"

	if python3 "$METAL2METAL" verify-runtime-manifest "$manifest" \
	     --source "$source" --output "$output" >/dev/null 2>&1 &&
	   metal2metal_hash_allowed "$output" "$expected_output_sha256"; then
		echo "[INFO] complete $name metal2metal route already installed"
		return 0
	fi
	if [ "$(metal2metal_sha256 "$source")" != "$expected_source_sha256" ]; then
		echo "[ERROR] $name source metallib is not the supported macOS 13.4 library." >&2
		return 1
	fi

	mkdir -p "$(dirname "$output")" "$ROUTE_DIR" || return 1
	output_tmp="$output.new.$$"
	manifest_tmp="$manifest.new.$$"
	args=(translate "$source" "$output_tmp"
		--llvm-dis "$route_dis" --llvm-as "$route_as"
		--runtime-manifest "$manifest_tmp"
		--runtime-source-path "$runtime_source"
		--runtime-output-path "$runtime_output")
	if [ "$auto_lower" = 1 ]; then
		args+=(--auto-lower-known-air)
	fi
	python3 "$METAL2METAL" "${args[@]}" || {
		rm -f "$output_tmp" "$manifest_tmp"
		return 1
	}
	python3 "$METAL2METAL" verify-runtime-manifest "$manifest_tmp" \
		--source "$source" --output "$output_tmp" || {
		rm -f "$output_tmp" "$manifest_tmp"
		return 1
	}
	if ! metal2metal_hash_allowed "$output_tmp" "$expected_output_sha256"; then
		echo "[ERROR] Generated $name metal2metal output has an unsupported identity: $(metal2metal_sha256 "$output_tmp")" >&2
		rm -f "$output_tmp" "$manifest_tmp"
		return 1
	fi
	chmod 0644 "$output_tmp" "$manifest_tmp" || return 1
	mv -f "$output_tmp" "$output" || return 1
	mv -f "$manifest_tmp" "$manifest" || return 1
	echo "[INFO] installed complete $name metal2metal route"
}

provision_route \
	SkyLight \
	"$ROOTFS/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/SkyLightShaders.air64.metallib" \
	378174fcbf7fc639aa737cad7a765690b2d76fa3a66c7a8e71018441f3ac3184 \
	"$ROOTFS/usr/local/share/macws/skylight/SkyLightShaders-desktop-effects-macabi.metallib" \
	"$ROUTE_DIR/skylight-shaders.route.plist" \
	"/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/SkyLightShaders.air64.metallib" \
	"/usr/local/share/macws/skylight/SkyLightShaders-desktop-effects-macabi.metallib" \
	bfe93e8146325a912a0db9fc1ed28a2de32aa9ccb4065148398be12ac0644df1 \
	0 || exit 1

provision_route \
	MPSImage \
	"$ROOTFS/System/Library/Frameworks/MetalPerformanceShaders.framework/Versions/A/Frameworks/MPSImage.framework/Versions/A/Resources/default.metallib" \
	376ded7ee154429f6950656eb668b26af27fc6149b734b11dd48a33d68fe4285 \
	"$ROOTFS/usr/local/share/macws/mpsimage/default-desktop-effects-macabi.metallib" \
	"$ROUTE_DIR/mpsimage-default.route.plist" \
	"/System/Library/Frameworks/MetalPerformanceShaders.framework/Versions/A/Frameworks/MPSImage.framework/Versions/A/Resources/default.metallib" \
	"/usr/local/share/macws/mpsimage/default-desktop-effects-macabi.metallib" \
	"84973060c51620471389178f7f00d6bde68f3fdf1609cda48072db46f7663916 342738608c912eab663879868288299e38147ea64d45b74f57bc0dd12761b2de" \
	1 "$APPLE_LLVM_DIS" "$APPLE_LLVM_AS" || exit 1

# Ventura MetalFX ships its temporal scaler network as one desktop-targeted
# library.  Route the complete library through the same manifest contract as
# QuartzCore/SkyLight/MPSImage: every source function must be translated and
# both metallibs must retain their exact identities before runtime accepts it.
# This is deliberately library-wide; no BRNet shader-name allowlist belongs
# in either the provisioner or libmachook.
provision_route \
	MetalFX \
	"$ROOTFS/System/Library/Frameworks/MetalFX.framework/Versions/A/Resources/default.metallib" \
	bb07e6ce97acf56caa32f8c69b8ebcc94bc74991ff51d76db8460791c7728534 \
	"$ROOTFS/usr/local/share/macws/metalfx/default-temporal-macabi.metallib" \
	"$ROUTE_DIR/metalfx-default.route.plist" \
	"/System/Library/Frameworks/MetalFX.framework/Versions/A/Resources/default.metallib" \
	"/usr/local/share/macws/metalfx/default-temporal-macabi.metallib" \
	"" \
	1 || exit 1

# MPS DAG input must retain the installed Apple compiler's AIR dialect.
# Runtime: upstream LLVM16 writes bitcode rejected as Invalid value / Unknown
# attribute kind (71). Do not replace the already validated image/effect
# routes' backend; use matching native reader/writer only for these complete
# compute libraries. Pinned outputs also reject older, self-consistent but
# compiler-incompatible manifests. Conversion is offline, never per launch.
provision_route \
	MPSCore \
	"$ROOTFS/System/Library/Frameworks/MetalPerformanceShaders.framework/Versions/A/Frameworks/MPSCore.framework/Versions/A/Resources/default.metallib" \
	ff2cca382dc21e3cdb4f5b567d6770917a32f388d36e64dffae595ea1601322b \
	"$ROOTFS/usr/local/share/macws/mpscore/default-compute-macabi.metallib" \
	"$ROUTE_DIR/mpscore-default.route.plist" \
	"/System/Library/Frameworks/MetalPerformanceShaders.framework/Versions/A/Frameworks/MPSCore.framework/Versions/A/Resources/default.metallib" \
	"/usr/local/share/macws/mpscore/default-compute-macabi.metallib" \
	"bc05c6dfc851d5d6acf760c9edde8bb3f449af5e0834cdab81f9e2f4092a0187 8744686cc7981601f52f658578b9cd94cf9127c86530ee03a1e68883d2e3bb0c" \
	1 "$APPLE_LLVM_DIS" "$APPLE_LLVM_AS" || exit 1

provision_route \
	MPSNDArray \
	"$ROOTFS/System/Library/Frameworks/MetalPerformanceShaders.framework/Versions/A/Frameworks/MPSNDArray.framework/Versions/A/Resources/default.metallib" \
	575c89ae7415c58fb39d41f5278c25458d62bc0cf622e09bae44cf661f1075d1 \
	"$ROOTFS/usr/local/share/macws/mpsndarray/default-compute-macabi.metallib" \
	"$ROUTE_DIR/mpsndarray-default.route.plist" \
	"/System/Library/Frameworks/MetalPerformanceShaders.framework/Versions/A/Frameworks/MPSNDArray.framework/Versions/A/Resources/default.metallib" \
	"/usr/local/share/macws/mpsndarray/default-compute-macabi.metallib" \
	"ff2d5117039292640d234037b4bc6f0081bb10d79d63a152ea72b1ec0de71ab1 fa6c9b109e9ab2a7356654bd16ba66715d4ac5a04eea75dec220418a01f90736" \
	1 "$APPLE_LLVM_DIS" "$APPLE_LLVM_AS" || exit 1

# Office embeds a desktop-target library inside an archive rather than a
# system-framework URL. Generate its complete native-compatible companion
# from the installed original, preserving every shader/constant interface.
# This is ordinary production data provisioning; /tmp is only a speed cache.
# An unsupported optional app must not prevent Terminal/the desktop starting.
# Do not publish a success stamp on failure, so the next preflight retries.
office_ready=1
if ! python3 "$OFFICE_PROVISIONER"; then
	echo '[WARN] Office Metal compatibility provisioning failed; desktop startup remains available.' >&2
	office_ready=0
fi

runtime_stamp=$(metal2metal_runtime_stamp 2>/dev/null || true)
if [ "$office_ready" = 1 ] && [ -n "$runtime_stamp" ]; then
	marker_tmp="$BOOT_READY_MARKER.new.$$"
	printf '%s\n' "$runtime_stamp" > "$marker_tmp" || exit 1
	chmod 0644 "$marker_tmp" || exit 1
	mv -f "$marker_tmp" "$BOOT_READY_MARKER" || exit 1
fi
