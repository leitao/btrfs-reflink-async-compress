#!/bin/sh
# Guest side of run.sh, runs inside the virtme-ng guest.  It mounts the test
# disk with compression, runs the reproducer, watches for the filesystem
# going read-only, stale reads or a hang, writes the verdict to result.txt and
# powers off.
#
# Environment: MODE=clone|late|compress|inline|stress-ng  RUNTIME=<s>
#              COPIES=<n>  DELAYS=0|1

D=$(dirname "$(readlink -f "$0")")
MODE=${MODE:-clone}
RUNTIME=${RUNTIME:-240}
COPIES=${COPIES:-4}
STALL=30
R=$D/result.txt
: > "$R"

say() { echo "$*" | tee -a "$R"; }
finish() {
	say "VERDICT=$1"
	shift
	[ $# -gt 0 ] && say "REASON=$*"
	echo "===RESULT-END==="
	sync
	echo o > /proc/sysrq-trigger
	sleep 30
}

MOUNT_OPTS=compress-force=zstd:3
DELAY_BT=delay.bt
case $MODE in
late)
	# Reflink onto the second async extent of the folio, right after
	# starting writeback (hits before v7.0 too).
	export CLONE_BLOCK=5 PRE_WRITEBACK=500
	DELAY_BT=delay-late.bt
	;;
compress)
	# The heuristic of -o compress sends the random block 5 to a write
	# right away, as compress-force does for any single block since v7.0.
	MOUNT_OPTS=compress=zstd:3
	export LONE_RANDOM=1
	;;
inline)
	export INLINE_SRC=1
	;;
esac

say "kernel: $(uname -r)"
say "page size: $(getconf PAGESIZE), mode: $MODE, copies: $COPIES, runtime: ${RUNTIME}s, mount: $MOUNT_OPTS"

DEV=$(for b in /sys/block/vd* /sys/block/sd*; do [ -e "$b" ] && echo "/dev/${b##*/}"; done | head -1)
mkdir -p "$D/mnt"
if ! mount -o "$MOUNT_OPTS" "$DEV" "$D/mnt"; then
	finish ERROR "cannot mount $DEV as btrfs (CONFIG_BTRFS_FS?)"
fi

if [ "${DELAYS:-0}" = 1 ]; then
	bpftrace "$D/$DELAY_BT" > "$D/bpftrace.out" 2>&1 &
	for i in $(seq 1 60); do
		grep -q -E 'Attached|ERROR' "$D/bpftrace.out" 2>/dev/null && break
		sleep 1
	done
	say "bpftrace: $(grep -E 'Attached|ERROR' "$D/bpftrace.out" | head -1)"
fi

PIDS=""
if [ "$MODE" = stress-ng ]; then
	stress-ng --fd-abuse "$COPIES" --temp-path "$D/mnt" -t "$RUNTIME" > "$D/stress-ng.out" 2>&1 &
	PIDS=$!
else
	for n in $(seq 1 "$COPIES"); do
		taskset -c $(((n - 1) % $(nproc))) "$D/repro" "$D/mnt/f$n" > "$D/repro$n.out" 2>&1 &
		PIDS="$PIDS $!"
	done
fi

hit=""
stale=""
deadline=$RUNTIME
t=0
last=""
idle=0
while [ $t -lt "$deadline" ]; do
	sleep 2
	t=$((t + 2))
	if dmesg | grep -q -E 'when unpinning extent range|forced readonly'; then
		sleep 2
		hit="filesystem forced read-only (transaction abort) after ${t}s"
		break
	fi
	[ "$MODE" = stress-ng ] && continue
	# A stale read is enough, but give the abort a few more seconds to show.
	if [ -z "$stale" ] && cat "$D"/repro*.out | grep -q 'STALE READ'; then
		stale="stale read after ${t}s"
		deadline=$((t + 10))
	fi
	alive=0
	for p in $PIDS; do kill -0 "$p" 2>/dev/null && alive=1; done
	[ $alive = 0 ] && break
	cur=$(cat "$D"/repro*.out | wc -l)
	if [ "$cur" = "$last" ]; then idle=$((idle + 2)); else idle=0; fi
	last=$cur
	if [ $idle -ge $STALL ]; then
		for p in $PIDS; do cat "/proc/$p/stack"; done > "$D/stacks.txt" 2>/dev/null
		echo w > /proc/sysrq-trigger
		sleep 1
		if grep -q copy_inline_to_page "$D/stacks.txt"; then
			hit="deadlock in copy_inline_to_page() after ${t}s"
		else
			hit="no progress for ${STALL}s after ${t}s"
		fi
		break
	fi
done
[ -n "$stale" ] && hit="${stale}${hit:+, $hit}"

say "---- reproducer output ----"
if [ "$MODE" = stress-ng ]; then
	grep -E 'metrc|passed|failed' "$D/stress-ng.out" | tail -3 | tee -a "$R"
else
	for n in $(seq 1 "$COPIES"); do
		{ grep -v '^iter [0-9]* t=' "$D/repro$n.out" | head -6; tail -1 "$D/repro$n.out"; } |
			sed "s/^/copy $n: /" | uniq | tee -a "$R"
	done
fi
say "---- kernel log ----"
dmesg | grep -E 'WARNING|when unpinning|aborted|forced readonly|blocked for more' | head -12 | tee -a "$R"
dmesg | sed -n '/cut here/,/end trace/p' | head -40 >> "$R"
if [ -s "$D/stacks.txt" ]; then
	say "---- stacks of the stuck reproducers ----"
	head -40 "$D/stacks.txt" | tee -a "$R"
fi

if [ -n "$hit" ]; then
	finish REPRODUCED "$hit"
fi
finish NOT_REPRODUCED "nothing in ${t}s"
