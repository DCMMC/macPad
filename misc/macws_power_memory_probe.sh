# No shebang: invoke with `bash misc/macws_power_memory_probe.sh [seconds] [interval]`.
# The jailbreak's AMFI policy rejects execve of text files with a shebang.

set -u
export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin:/sbin

duration=${1:-600}
interval=${2:-30}
case "$duration:$interval" in
    *[!0-9:]*|:*|*:0) echo "usage: bash $0 [duration-seconds] [interval-seconds]" >&2; exit 64 ;;
esac

started=$(date +%s)
deadline=$((started + duration))

snapshot_process() {
    name=$1
    include_footprint=${2:-0}
    pid=$(/bin/ps -axo pid=,comm= | awk -v target="$name" '
        { executable=$2; sub(/^.*\//, "", executable) }
        executable == target { print $1; exit }')
    [ -n "$pid" ] || return 0
    /bin/ps -p "$pid" -o pid=,state=,etime=,%cpu=,rss=,comm= |
        awk '{$1=$1; print "process " $0}'
    [ "$include_footprint" -eq 1 ] || return 0
    # footprint briefly inspects every VM region in the target. Bound it so a
    # diagnostic sample can never hold up the device indefinitely.
    timeout 15 /usr/bin/footprint -p "$pid" 2>/dev/null |
        awk -v pid="$pid" -v name="$name" '
            /IOSurface/ || /IOAccelerator/ || /phys_footprint/ ||
            /Physical footprint/ || /Peak footprint/ || /MALLOC_[A-Z]+/ {
                sub(/^[[:space:]]+/, "")
                print "footprint pid=" pid " name=" name " " $0
            }'
}

while :; do
    now=$(date +%s)
    if [ -e /var/mnt/rootfs/private/tmp/macws_workspace_sleeping ]; then
        workspace_sleeping=1
    else
        workspace_sleeping=0
    fi
    echo "sample epoch=$now elapsed=$((now - started)) workspace_sleeping=$workspace_sleeping"
    if [ -x /var/jb/usr/macOS/bin/macwsthermal ]; then
        /var/jb/usr/macOS/bin/macwsthermal 2>&1 || true
    fi
    snapshot_process MacWSHost 1
    snapshot_process WindowServer 1
    snapshot_process Finder
    snapshot_process ControlCenter
    snapshot_process macwsdisplayd
    echo
    [ "$now" -ge "$deadline" ] && break
    sleep "$interval"
done
