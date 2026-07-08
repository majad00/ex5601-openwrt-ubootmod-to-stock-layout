#!/bin/sh

IMAGE="${IMAGE:-/tmp/initramfs_2.bin}"
LOG="${LOG:-/tmp/boot_matrix_recovery.log}"
CRASH_DELAY="${CRASH_DELAY:-5}"
DRY_RUN="${DRY_RUN:-0}"

EXPECTED_MTD5_SIZE_HEX="1da80000"

set -u

: > "$LOG" 2>/dev/null || {
	echo "ERROR: cannot write log $LOG"
	exit 1
}

say() {
	echo "$@" | tee -a "$LOG"
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

mtd_name() {
	n="$1"
	awk -v m="mtd${n}:" '$1 == m { gsub(/"/, "", $4); print $4; exit }' /proc/mtd
}

mtd_size_hex() {
	n="$1"
	awk -v m="mtd${n}:" '$1 == m { print $2; exit }' /proc/mtd
}

mtd_exists() {
	n="$1"
	awk -v m="mtd${n}:" '$1 == m { found=1 } END { exit found ? 0 : 1 }' /proc/mtd
}

check_mtd_name_ci() {
	n="$1"
	expected="$2"

	actual="$(mtd_name "$n")"
	[ -n "$actual" ] || fail "mtd$n missing; expected $expected"

	echo "$actual" | grep -iq "^${expected}$" || \
		fail "mtd$n name is '$actual'; expected '$expected'"
}

find_ubi_by_mtd() {
	mtdnum="$1"

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

find_volsys_by_name() {
	ubidev="$1"
	volname="$2"

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

schedule_crash() {
	delay="$1"

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
		echo c > /proc/sysrq-trigger
	) >/dev/null 2>&1 &
}

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
need_cmd fw_printenv

say "================================================"
say "MATRIX RECOVERY AUTO-BOOT STAGER"
say "================================================"
say "Image:       $IMAGE"
say "Log:         $LOG"
say "Crash delay: $CRASH_DELAY seconds"
say "Dry run:     $DRY_RUN"
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
say "[3] Checking EX5601-T0 ubootmod MTD layout"

[ -r /proc/mtd ] || fail "/proc/mtd missing"

say "/proc/mtd:"
cat /proc/mtd 2>&1 | tee -a "$LOG"

if [ -r /proc/device-tree/model ]; then
	say "device-tree model:"
	cat /proc/device-tree/model 2>/dev/null | tee -a "$LOG" || true
	say
	grep -qi "EX5601" /proc/device-tree/model 2>/dev/null || \
		fail "device-tree model does not contain EX5601"
	grep -qi "ubootmod" /proc/device-tree/model 2>/dev/null || \
		fail "device-tree model does not contain ubootmod"
else
	say "WARNING: /proc/device-tree/model missing"
fi

check_mtd_name_ci 0 "bl2"
check_mtd_name_ci 1 "u-boot-env"
check_mtd_name_ci 2 "factory"
check_mtd_name_ci 3 "fip"
check_mtd_name_ci 4 "zloader"
check_mtd_name_ci 5 "ubi"

S0="$(mtd_size_hex 0)"
S1="$(mtd_size_hex 1)"
S2="$(mtd_size_hex 2)"
S3="$(mtd_size_hex 3)"
S4="$(mtd_size_hex 4)"
S5="$(mtd_size_hex 5)"

say "mtd0 size=$S0 name=$(mtd_name 0)"
say "mtd1 size=$S1 name=$(mtd_name 1)"
say "mtd2 size=$S2 name=$(mtd_name 2)"
say "mtd3 size=$S3 name=$(mtd_name 3)"
say "mtd4 size=$S4 name=$(mtd_name 4)"
say "mtd5 size=$S5 name=$(mtd_name 5)"

[ "$S0" = "00100000" ] || fail "mtd0 size unexpected"
[ "$S1" = "00080000" ] || fail "mtd1 size unexpected"
[ "$S2" = "00200000" ] || fail "mtd2 size unexpected"

case "$S3" in
	001c0000|00200000)
		;;
	*)
		fail "mtd3 fip size unexpected: $S3"
		;;
esac

[ "$S4" = "00040000" ] || fail "mtd4 size unexpected"
[ "$S5" = "$EXPECTED_MTD5_SIZE_HEX" ] || fail "mtd5 is not expected large ubootmod ubi size"

if mtd_exists 6; then
	fail "mtd6 exists; this is not expected ubootmod single-UBI layout"
fi

say "ubootmod MTD layout check passed."

say
say "[4] Checking U-Boot recovery env"

ENV_OUT="$(fw_printenv bootcmd boot_recovery boot_ubi ubi_read_recovery bootconf loadaddr 2>&1)" || \
	fail "fw_printenv failed"

echo "$ENV_OUT" | tee -a "$LOG"

echo "$ENV_OUT" | grep -q "bootcmd=.*pstore check" || \
	fail "bootcmd does not contain pstore check"

echo "$ENV_OUT" | grep -q "bootcmd=.*boot_recovery" || \
	fail "bootcmd does not reference boot_recovery"

echo "$ENV_OUT" | grep -q "boot_recovery=.*ubi_read_recovery" || \
	fail "boot_recovery does not use ubi_read_recovery"

echo "$ENV_OUT" | grep -q "boot_recovery=.*bootm" || \
	fail "boot_recovery does not bootm recovery image"

say "U-Boot pstore recovery env check passed."

say
say "[5] Checking pstore/sysrq trigger support"

[ -d /sys/fs/pstore ] || fail "/sys/fs/pstore missing"
[ -e /proc/sysrq-trigger ] || fail "/proc/sysrq-trigger missing"
[ -w /proc/sysrq-trigger ] || fail "/proc/sysrq-trigger is not writable"

SYSRQ="$(cat /proc/sys/kernel/sysrq 2>/dev/null || echo missing)"
say "kernel.sysrq=$SYSRQ"

say "Mounting pstore if needed..."
mount -t pstore pstore /sys/fs/pstore 2>/dev/null || true

say "Current pstore files before clear:"
ls -l /sys/fs/pstore 2>&1 | tee -a "$LOG" || true

say "Clearing old pstore records..."
rm -f /sys/fs/pstore/* 2>/dev/null || true
sync

say "Current pstore files after clear:"
ls -l /sys/fs/pstore 2>&1 | tee -a "$LOG" || true

say
say "[6] Finding ubootmod recovery volume"

UBI="$(find_ubi_by_mtd 5 || true)"
[ -n "$UBI" ] || fail "cannot find UBI device attached to mtd5"

REC_SYS="$(find_volsys_by_name "$UBI" recovery || true)"
[ -n "$REC_SYS" ] || fail "cannot find recovery volume on $UBI"

REC_BASE="$(basename "$REC_SYS")"
REC_DEV="/dev/$REC_BASE"

[ -e "$REC_DEV" ] || fail "$REC_DEV missing"

REC_NAME="$(cat "$REC_SYS/name" 2>/dev/null)"
REC_EBS="$(cat "$REC_SYS/reserved_ebs" 2>/dev/null)"
LEB_SIZE="$(cat "/sys/class/ubi/$UBI/eraseblock_size" 2>/dev/null)"

[ "$REC_NAME" = "recovery" ] || fail "$REC_DEV is not named recovery"
[ -n "$REC_EBS" ] || fail "cannot read recovery reserved_ebs"
[ -n "$LEB_SIZE" ] || fail "cannot read $UBI eraseblock_size"

REC_CAPACITY=$((REC_EBS * LEB_SIZE))

say "UBI device:        $UBI"
say "Recovery sysfs:    $REC_SYS"
say "Recovery device:   $REC_DEV"
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
say "[11] Verifying recovery volume magic after write"
REC_MAGIC="$(vol_magic "$REC_DEV")"
say "Recovery volume magic: $REC_MAGIC"
[ "$REC_MAGIC" = "d00dfeed" ] || fail "recovery volume does not start with FIT magic after write"

say
say "[12] UBI state after write"
ubinfo -a 2>&1 | tee -a "$LOG" || true

say
say "[13] Final pstore clear before controlled crash"
mount -t pstore pstore /sys/fs/pstore 2>/dev/null || true
rm -f /sys/fs/pstore/* 2>/dev/null || true
sync

say
say "[14] Enabling sysrq"
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || fail "failed to enable sysrq"

schedule_crash "$CRASH_DELAY"

say
say "Script completed. Controlled crash is scheduled."
say "The LuCI request may return before the router reboots."
say "Log until crash: $LOG"

exit 0
EOF
