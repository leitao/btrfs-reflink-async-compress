#!/bin/sh
# Reproduce btrfs going read-only after a transaction abort (-EUCLEAN in
# btrfs_unpin_extent_cache()) in a virtme-ng guest.  See README.md.
#
# Exit status: 1 reproduced, 0 not reproduced, 2 setup error.

HERE=$(dirname "$(readlink -f "$0")")
KERNEL=.
MODE=clone
RUNTIME=240
COPIES=
CPUS=8
DELAYS=0
KEEP=0

usage() {
	cat <<EOF
usage: $0 [-k kernel] [-m mode] [-t seconds] [-n copies] [-c cpus] [-d] [-K]
  -k  kernel tree or image to boot (default: current directory)
  -m  clone: reproducer, compress-force, v7.0 or later (default);
      late: reflink onto the second async extent of the folio, compress-force,
      v6.16 to v6.19; compress: -o compress with an incompressible block,
      v6.16 or later; inline: clone from an inline extent, which deadlocks
      instead (pages of 32K or more); stress-ng: stress-ng --fd-abuse, which
      hits the same race
  -t  give up after this many seconds (default: $RUNTIME)
  -n  copies of the reproducer (default: 4), or stress-ng instances
      (default: one per guest CPU)
  -c  guest CPUs (default: $CPUS)
  -d  widen the race with bpftrace delays (needs bpftrace)
  -K  keep the work directory and the disk image
EOF
	exit 2
}

while getopts k:m:t:n:c:dKh opt; do
	case $opt in
	k) KERNEL=$OPTARG ;;
	m) MODE=$OPTARG ;;
	t) RUNTIME=$OPTARG ;;
	n) COPIES=$OPTARG ;;
	c) CPUS=$OPTARG ;;
	d) DELAYS=1 ;;
	K) KEEP=1 ;;
	*) usage ;;
	esac
done
case $MODE in clone|late|compress|inline|stress-ng) ;; *) usage ;; esac
if [ -z "$COPIES" ]; then
	[ "$MODE" = stress-ng ] && COPIES=$CPUS || COPIES=4
fi
for n in "$RUNTIME" "$COPIES" "$CPUS"; do
	case $n in ''|*[!0-9]*) echo "-t, -n and -c take a number"; exit 2 ;; esac
done
for tool in vng mkfs.btrfs gcc script; do
	command -v $tool > /dev/null || { echo "missing $tool"; exit 2; }
done
[ -e "$KERNEL" ] || { echo "no kernel at $KERNEL"; exit 2; }
KERNEL=$(readlink -f "$KERNEL")

WORK=$(mktemp -d /tmp/btrfs-reflink-repro.XXXXXX)
cp "$HERE/guest.sh" "$HERE/delay.bt" "$HERE/delay-late.bt" "$WORK/"
gcc -O2 -Wall -o "$WORK/repro" "$HERE/repro.c" || exit 2
truncate -s 8G "$WORK/disk.img"
mkfs.btrfs -q -f -s 4096 "$WORK/disk.img" || exit 2

# Prefer the locally built qemu, if there is one.
QEMU=/usr/local/bin/qemu-system-$(uname -m)
[ -x "$QEMU" ] && QEMU_OPT="--qemu $QEMU" || QEMU_OPT=

echo "kernel: $KERNEL"
echo "work:   $WORK (console log in console.log)"
echo "running for up to ${RUNTIME}s after boot..."

# vng needs a terminal, so run it under script(1), which gives it one.  Keep
# script(1) off our terminal: timeout(1) runs it in a background process
# group, where touching the terminal would stop it with SIGTTIN/SIGTTOU.
timeout $((RUNTIME + 300)) script -qfec "vng --run $KERNEL --disk $WORK/disk.img \
	--cpus $CPUS --memory 4G --user root --rwdir $WORK $QEMU_OPT \
	--exec 'MODE=$MODE RUNTIME=$RUNTIME COPIES=$COPIES DELAYS=$DELAYS sh $WORK/guest.sh'" \
	"$WORK/console.log" < /dev/null > /dev/null 2>&1

echo
if [ -s "$WORK/result.txt" ]; then
	cat "$WORK/result.txt"
else
	echo "VERDICT=ERROR"
	echo "REASON=the guest wrote no result, see $WORK/console.log"
fi

case $(sed -n 's/^VERDICT=//p' "$WORK/result.txt" 2>/dev/null) in
REPRODUCED) rc=1 ;;
NOT_REPRODUCED) rc=0 ;;
*) rc=2; KEEP=1 ;;
esac
if [ $KEEP = 1 ]; then
	echo "kept $WORK"
else
	rm -rf "$WORK"
fi
exit $rc
