#!/bin/sh
# Matrix recovery auto-boot stager for EX5601-T0 / similar MT7986 ubootmod layouts.
# written by majad qureshi

set -u

IMAGE="${IMAGE:-/tmp/initramfs_2.bin}"
LOG="${LOG:-/tmp/boot_matrix_recovery.log}"
WORK="${WORK:-/tmp/boot_matrix_recovery_work}"
LOCKDIR="${LOCKDIR:-/tmp/boot_matrix_recovery.lock}"
CRASH_DELAY="${CRASH_DELAY:-5}"
DRY_RUN="${DRY_RUN:-0}"

STRICT_LAYOUT="${STRICT_LAYOUT:-0}"
STRICT_MODEL="${STRICT_MODEL:-0}"
STRICT_ENV="${STRICT_ENV:-1}"
STRICT_PSTORE_CLEAR="${STRICT_PSTORE_CLEAR:-1}"


MIN_UBI_SIZE_HEX="${MIN_UBI_SIZE_HEX:-10000000}"
# Old exact ubootmod size seen on EX5601-T0. Only enforced with STRICT_LAYOUT=1.
EXPECTED_UBI_SIZE_HEX="${EXPECTED_UBI_SIZE_HEX:-1da80000}"

RECOVERY_VOL="${RECOVERY_VOL:-recovery}"

: > "$LOG" 2>/dev/null || {
	echo "ERROR: cannot write log $LOG"
	exit 1
}

say() {
	echo "$@" | tee -a "$LOG"
}

warn() {
	say "WARNING: $*"
}

fail() {
	say "ERROR: $*"
	say "Log: $LOG"
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

filesize() {
	wc -c < "$1" | awk '{print $1}'
}

fit_magic() {
	dd if="$1" bs=4 count=1 2>/dev/null | hexdump -v -e '1/1 "%02x"'
}

vol_magic() {
	dd if="$1" bs=4 count=1 2>/dev/null | hexdump -v -e '1/1 "%02x"'
}

hex_to_dec() {
	# BusyBox ash supports 0x arithmetic, which is available on OpenWrt.
	echo $((0x$1))
}

mtd_num_by_name() {
	local want="$1"

	awk -v want="$want" '
		BEGIN { want = tolower(want) }
		/^mtd[0-9]+:/ {
			name = $4
			gsub(/"/, "", name)
			if (tolower(name) == want) {
				gsub(/^mtd/, "", $1)
				gsub(/:$/, "", $1)
				print $1
				exit
			}
		}
	' /proc/mtd
}

mtd_name() {
	local n="$1"
	awk -v m="mtd${n}:" '$1 == m { gsub(/"/, "", $4); print $4; exit }' /proc/mtd
}

mtd_size_hex() {
	local n="$1"
	awk -v m="mtd${n}:" '$1 == m { print $2; exit }' /proc/mtd
}

mtd_exists() {
	local n="$1"
	awk -v m="mtd${n}:" '$1 == m { found=1 } END { exit found ? 0 : 1 }' /proc/mtd
}

check_mtd_present() {
	local varname="$1"
	local num="$2"
	[ -n "$num" ] || fail "MTD partition named $varname missing"
}

find_ubi_by_mtd() {
	local mtdnum="$1"
	local d

	for d in /sys/class/ubi/ubi[0-9]*; do
		[ -d "$d" ] || continue
		[ -f "$d/mtd_num" ] || continue
		if [ "$(cat "$d/mtd_num" 2>/dev/null)" = "$mtdnum" ]; then
			basename "$d"
			return 0
		fi
	done

	return 1
}

attach_mtd_if_needed() {
	local mtdnum="$1"
	local ubi

	ubi="$(find_ubi_by_mtd "$mtdnum" || true)"
	if [ -n "$ubi" ]; then
		echo "$ubi"
		return 0
	fi

	say "Attaching /dev/mtd$mtdnum as UBI"
	ubiattach -p "/dev/mtd$mtdnum" >/dev/null 2>&1 || \
		ubiattach /dev/ubi_ctrl -m "$mtdnum" >/dev/null 2>&1 || \
		fail "cannot attach /dev/mtd$mtdnum as UBI"

	sleep 1
	ubi="$(find_ubi_by_mtd "$mtdnum" || true)"
	[ -n "$ubi" ] || fail "attached mtd$mtdnum but could not find UBI device"
	echo "$ubi"
}

find_volsys_by_name() {
	local ubidev="$1"
	local volname="$2"
	local d

	for d in /sys/class/ubi/${ubidev}_*; do
		[ -d "$d" ] || continue
		[ -f "$d/name" ] || continue
		if [ "$(cat "$d/name" 2>/dev/null)" = "$volname" ]; then
			echo "$d"
			return 0
		fi
	done

	return 1
}

ubi_leb_size() {
	local ubi="$1"
	local v=""

	[ -f "/sys/class/ubi/$ubi/usable_eb_size" ] && \
		v="$(cat "/sys/class/ubi/$ubi/usable_eb_size" 2>/dev/null || true)"
	[ -n "$v" ] && { echo "$v"; return 0; }

	[ -f "/sys/class/ubi/$ubi/eraseblock_size" ] && \
		v="$(cat "/sys/class/ubi/$ubi/eraseblock_size" 2>/dev/null || true)"
	[ -n "$v" ] && { echo "$v"; return 0; }

	ubinfo "/dev/$ubi" 2>/dev/null | awk -F: '/Logical eraseblock size/ {
		gsub(/ bytes.*/, "", $2);
		gsub(/ /, "", $2);
		print $2;
		exit;
	}'
}

mount_pstore() {
	[ -d /sys/fs/pstore ] || fail "/sys/fs/pstore missing"
	mount | grep -q ' on /sys/fs/pstore ' 2>/dev/null || \
		mount -t pstore pstore /sys/fs/pstore 2>/dev/null || true
}

pstore_count() {
	find /sys/fs/pstore -type f 2>/dev/null | wc -l | awk '{print $1}'
}

clear_pstore() {
	local count

	mount_pstore
	rm -f /sys/fs/pstore/* 2>/dev/null || true
	sync
	count="$(pstore_count)"
	if [ "$count" != "0" ]; then
		if [ "$STRICT_PSTORE_CLEAR" = "1" ]; then
			fail "could not clear old pstore records; remaining files=$count"
		else
			warn "could not clear all pstore records; remaining files=$count"
		fi
	fi
}

schedule_crash() {
	local delay="$1"

	say
	say "================================================"
	say "RECOVERY BOOT TRIGGER ARMED"
	say "================================================"
	say "A controlled kernel crash will be triggered in $delay seconds."
	say "This is intentional."
	say "U-Boot should detect pstore and boot the recovery volume."
	say
	say "Recovery /init MUST clear /sys/fs/pstore/* immediately."
	say "================================================"

	(
		sleep "$delay"
		sync
		echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
		echo s > /proc/sysrq-trigger 2>/dev/null || true
		echo c > /proc/sysrq-trigger
	) >/dev/null 2>&1 &
}

verify_env_or_fail() {
	local env_out="$1"
	local bad=0

	echo "$env_out" | grep -q '^bootcmd=.*pstore' || bad=1
	echo "$env_out" | grep -q '^bootcmd=.*boot_recovery' || bad=1
	echo "$env_out" | grep -q '^boot_recovery=.*ubi_read_recovery' || bad=1
	echo "$env_out" | grep -q '^boot_recovery=.*bootm' || bad=1

	if [ "$bad" = "1" ]; then
		if [ "$STRICT_ENV" = "1" ]; then
			fail "U-Boot env does not clearly show pstore -> boot_recovery -> ubi_read_recovery -> bootm"
		else
			warn "U-Boot env does not clearly show pstore recovery chain; continuing because STRICT_ENV=0"
		fi
	fi
}

cleanup() {
	rm -rf "$LOCKDIR"
}
trap cleanup EXIT

need_cmd awk
need_cmd cat
need_cmd grep
need_cmd dd
need_cmd hexdump
need_cmd wc
need_cmd tee
need_cmd sync
need_cmd sleep
need_cmd rm
need_cmd mount
need_cmd ubiupdatevol
need_cmd ubinfo
need_cmd ubiattach
need_cmd fw_printenv
need_cmd cmp
need_cmd mkdir
need_cmd find
need_cmd basename
need_cmd id

mkdir "$LOCKDIR" 2>/dev/null || fail "another recovery staging process is already running"
rm -rf "$WORK"
mkdir -p "$WORK" || fail "cannot create work directory: $WORK"

say "================================================"
say "MATRIX RECOVERY AUTO-BOOT STAGER - HARDENED"
say "================================================"
say "Image:              $IMAGE"
say "Log:                $LOG"
say "Work:               $WORK"
say "Crash delay:        $CRASH_DELAY seconds"
say "Dry run:            $DRY_RUN"
say "Strict layout:      $STRICT_LAYOUT"
say "Strict model:       $STRICT_MODEL"
say "Strict env:         $STRICT_ENV"
say "Strict pstore clear:$STRICT_PSTORE_CLEAR"
say "Recovery volume:    $RECOVERY_VOL"
say "================================================"
say "This script writes ONLY the ubootmod recovery UBI volume."
say "It does NOT touch fit/rootfs_data/BL2/FIP/factory/zloader."
say "It then creates a controlled pstore crash to force recovery boot."
say "================================================"

[ "$(id -u 2>/dev/null)" = "0" ] || fail "must run as root"

say
say "[1] Checking OpenWrt userspace"

if [ -r /etc/openwrt_release ]; then
	say "/etc/openwrt_release:"
	cat /etc/openwrt_release 2>&1 | tee -a "$LOG" || true
else
	fail "/etc/openwrt_release missing; refusing because this does not look like OpenWrt"
fi

grep -qi "OpenWrt" /etc/openwrt_release /etc/os-release 2>/dev/null || \
	fail "OpenWrt marker not found in /etc/openwrt_release or /etc/os-release"

say
say "[2] Checking current boot mode"
[ -r /proc/cmdline ] || fail "/proc/cmdline missing"
CMDLINE="$(cat /proc/cmdline 2>/dev/null)"
say "cmdline: $CMDLINE"

echo "$CMDLINE" | grep -q "root=/dev/fit0" || \
	fail "current system is not booted from ubootmod production fit root=/dev/fit0"

say
say "[3] Checking ubootmod MTD layout"
[ -r /proc/mtd ] || fail "/proc/mtd missing"
say "/proc/mtd:"
cat /proc/mtd 2>&1 | tee -a "$LOG"

if [ -r /proc/device-tree/model ]; then
	MODEL="$(tr '\000' '\n' < /proc/device-tree/model 2>/dev/null | head -n1 || true)"
	say "device-tree model: $MODEL"
	case "$MODEL" in
		*EX5601*|*ex5601*|*T56*|*t56*)
			;;
		*)
			if [ "$STRICT_MODEL" = "1" ]; then
				fail "device-tree model does not look like EX5601/T56: $MODEL"
			else
				warn "device-tree model does not look like EX5601/T56: $MODEL"
			fi
			;;
	esac
else
	warn "/proc/device-tree/model missing"
fi

MTD_BL2="$(mtd_num_by_name bl2 || true)"
MTD_ENV="$(mtd_num_by_name u-boot-env || true)"
MTD_FACTORY="$(mtd_num_by_name factory || true)"
MTD_FIP="$(mtd_num_by_name fip || true)"
MTD_ZLOADER="$(mtd_num_by_name zloader || true)"
MTD_UBI="$(mtd_num_by_name ubi || true)"

check_mtd_present bl2 "$MTD_BL2"
check_mtd_present u-boot-env "$MTD_ENV"
check_mtd_present factory "$MTD_FACTORY"
check_mtd_present fip "$MTD_FIP"
check_mtd_present zloader "$MTD_ZLOADER"
check_mtd_present ubi "$MTD_UBI"

S_BL2="$(mtd_size_hex "$MTD_BL2")"
S_ENV="$(mtd_size_hex "$MTD_ENV")"
S_FACTORY="$(mtd_size_hex "$MTD_FACTORY")"
S_FIP="$(mtd_size_hex "$MTD_FIP")"
S_ZLOADER="$(mtd_size_hex "$MTD_ZLOADER")"
S_UBI="$(mtd_size_hex "$MTD_UBI")"

say "mtd$MTD_BL2 size=$S_BL2 name=$(mtd_name "$MTD_BL2")"
say "mtd$MTD_ENV size=$S_ENV name=$(mtd_name "$MTD_ENV")"
say "mtd$MTD_FACTORY size=$S_FACTORY name=$(mtd_name "$MTD_FACTORY")"
say "mtd$MTD_FIP size=$S_FIP name=$(mtd_name "$MTD_FIP")"
say "mtd$MTD_ZLOADER size=$S_ZLOADER name=$(mtd_name "$MTD_ZLOADER")"
say "mtd$MTD_UBI size=$S_UBI name=$(mtd_name "$MTD_UBI")"

[ "$S_BL2" = "00100000" ] || fail "bl2 size unexpected: $S_BL2"
[ "$S_ENV" = "00080000" ] || fail "u-boot-env size unexpected: $S_ENV"
[ "$S_FACTORY" = "00200000" ] || fail "factory size unexpected: $S_FACTORY"
case "$S_FIP" in
	001c0000|00200000) ;;
	*) fail "fip size unexpected: $S_FIP" ;;
esac
[ "$S_ZLOADER" = "00040000" ] || fail "zloader size unexpected: $S_ZLOADER"

UBI_DEC="$(hex_to_dec "$S_UBI")"
MIN_UBI_DEC="$(hex_to_dec "$MIN_UBI_SIZE_HEX")"
if [ "$UBI_DEC" -lt "$MIN_UBI_DEC" ]; then
	fail "combined UBI partition too small: $S_UBI; minimum $MIN_UBI_SIZE_HEX"
fi

if [ "$STRICT_LAYOUT" = "1" ] && [ "$S_UBI" != "$EXPECTED_UBI_SIZE_HEX" ]; then
	fail "ubi size is $S_UBI; expected exact $EXPECTED_UBI_SIZE_HEX because STRICT_LAYOUT=1"
fi

if mtd_exists 6; then
	if [ "$STRICT_LAYOUT" = "1" ]; then
		fail "mtd6 exists; not expected in strict ubootmod single-UBI layout"
	else
		warn "mtd6 exists; continuing because STRICT_LAYOUT=0"
	fi
fi

say "ubootmod MTD layout check passed."

say
say "[4] Checking U-Boot recovery env"
ENV_OUT="$(fw_printenv bootcmd boot_recovery boot_ubi ubi_read_recovery bootconf loadaddr 2>&1)" || {
	if [ "$STRICT_ENV" = "1" ]; then
		fail "fw_printenv failed"
	else
		warn "fw_printenv failed; continuing because STRICT_ENV=0"
		ENV_OUT=""
	fi
}

echo "$ENV_OUT" | tee -a "$LOG"
[ -n "$ENV_OUT" ] && verify_env_or_fail "$ENV_OUT"
say "U-Boot pstore recovery env check completed."

say
say "[5] Checking pstore/sysrq trigger support"
[ -d /sys/fs/pstore ] || fail "/sys/fs/pstore missing"
[ -e /proc/sysrq-trigger ] || fail "/proc/sysrq-trigger missing"
[ -w /proc/sysrq-trigger ] || fail "/proc/sysrq-trigger is not writable"

SYSRQ="$(cat /proc/sys/kernel/sysrq 2>/dev/null || echo missing)"
say "kernel.sysrq=$SYSRQ"

say "Mounting pstore if needed..."
mount_pstore

say "Current pstore files before clear:"
ls -l /sys/fs/pstore 2>&1 | tee -a "$LOG" || true

say "Clearing old pstore records..."
clear_pstore

say "Current pstore files after clear:"
ls -l /sys/fs/pstore 2>&1 | tee -a "$LOG" || true

say
say "[6] Finding ubootmod recovery volume"
UBI="$(attach_mtd_if_needed "$MTD_UBI")"
[ -n "$UBI" ] || fail "cannot find UBI device attached to mtd$MTD_UBI"

REC_SYS="$(find_volsys_by_name "$UBI" "$RECOVERY_VOL" || true)"
[ -n "$REC_SYS" ] || fail "cannot find $RECOVERY_VOL volume on $UBI"

REC_BASE="$(basename "$REC_SYS")"
REC_DEV="/dev/$REC_BASE"
[ -e "$REC_DEV" ] || fail "$REC_DEV missing"

REC_NAME="$(cat "$REC_SYS/name" 2>/dev/null)"
REC_EBS="$(cat "$REC_SYS/reserved_ebs" 2>/dev/null)"
LEB_SIZE="$(ubi_leb_size "$UBI")"

[ "$REC_NAME" = "$RECOVERY_VOL" ] || fail "$REC_DEV is not named $RECOVERY_VOL"
[ -n "$REC_EBS" ] || fail "cannot read recovery reserved_ebs"
[ -n "$LEB_SIZE" ] || fail "cannot read $UBI LEB size"

REC_CAPACITY=$((REC_EBS * LEB_SIZE))

say "UBI device:        $UBI"
say "Recovery sysfs:    $REC_SYS"
say "Recovery device:   $REC_DEV"
say "Recovery LEB size: $LEB_SIZE bytes"
say "Recovery reserved: $REC_EBS LEBs"
say "Recovery capacity: $REC_CAPACITY bytes"

say
say "[7] Checking recovery image"
[ -f "$IMAGE" ] || fail "image missing: $IMAGE"
[ -s "$IMAGE" ] || fail "image empty: $IMAGE"

IMG_SIZE="$(filesize "$IMAGE")"
IMG_MAGIC="$(fit_magic "$IMAGE")"

say "Image size:  $IMG_SIZE bytes"
say "Image magic: $IMG_MAGIC"

[ "$IMG_MAGIC" = "d00dfeed" ] || fail "image is not FIT/ITB magic d00dfeed"
[ "$IMG_SIZE" -le "$REC_CAPACITY" ] || fail "image does not fit recovery volume"

if command -v strings >/dev/null 2>&1; then
	say "Interesting image strings:"
	strings "$IMAGE" | grep -Ei 'OpenWrt|Linux|recovery|EX5601|T56|OEM|ubi|nand|mtd|factory' | head -n 80 | tee -a "$LOG" || true
fi

say
say "[8] Current UBI state before write"
ubinfo -a 2>&1 | tee -a "$LOG" || true

if [ "$DRY_RUN" = "1" ]; then
	say
	say "DRY_RUN=1, not writing image and not triggering crash."
	say "Log: $LOG"
	exit 0
fi

say
say "[9] Writing recovery image"
say "+ ubiupdatevol $REC_DEV $IMAGE"
ubiupdatevol "$REC_DEV" "$IMAGE" >>"$LOG" 2>&1 || fail "ubiupdatevol failed"

say
say "[10] Syncing"
sync
sleep 2
sync

say
say "[11] Verifying recovery volume after write"
REC_MAGIC="$(vol_magic "$REC_DEV")"
say "Recovery volume magic: $REC_MAGIC"
[ "$REC_MAGIC" = "d00dfeed" ] || fail "recovery volume does not start with FIT magic after write"

READBACK="$WORK/recovery.readback.bin"
dd if="$REC_DEV" of="$READBACK" bs="$IMG_SIZE" count=1 >/dev/null 2>&1 || \
	fail "could not read recovery image back from $REC_DEV"
cmp "$IMAGE" "$READBACK" >/dev/null || fail "recovery image readback mismatch"
say "RECOVERY_IMAGE_READBACK_OK"

say
say "[12] UBI state after write"
ubinfo -a 2>&1 | tee -a "$LOG" || true

say
say "[13] Final pstore clear before controlled crash"
clear_pstore

say
say "[14] Enabling sysrq"
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || fail "failed to enable sysrq"

schedule_crash "$CRASH_DELAY"

say
say "Script completed. Controlled crash is scheduled."
say "The LuCI request may return before the router reboots."
say "Log until crash: $LOG"

exit 0
