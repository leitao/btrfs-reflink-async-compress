# btrfs forced read-only after a transaction abort (virtme-ng reproducer)

This reproduces a btrfs issue we were seeing in production. A btrfs filesystem
mounted with compression suddenly goes read-only, and the kernel log shows:

    WARNING: fs/btrfs/extent_map.c:<line> at btrfs_unpin_extent_cache+<off>
    BTRFS warning (device <dev>): found extent map for inode <ino> (root <root>) with unexpected start offset <off> when unpinning extent range [<start>, <end>), generation <gen>
    WARNING: fs/btrfs/inode.c:<line> at btrfs_finish_one_ordered+<off>
    BTRFS error (device <dev> state A): Transaction <gen> aborted (-EUCLEAN)
    BTRFS info (device <dev> state EA): forced readonly

The disk is not corrupt. After a reboot the filesystem mounts fine, but all
writes fail with EROFS until then.

## Cause

The cause is a race between a reflink (`copy_file_range()`, `FICLONERANGE`)
and async compressed writeback of the range the reflink replaces. Two things
are needed:

1. The filesystem is mounted with `compress` or `compress-force`.
2. A folio holds more than one block:
   - 64K pages with 4K blocks (arm64): since v6.16, or since v6.13 with
     `CONFIG_BTRFS_EXPERIMENTAL`;
   - 4K pages once the file uses large folios: since v7.2.

The race goes like this:

1. A writeback pass sends two or more blocks of a folio to async compression.
2. The same pass writes a lone dirty block of that folio right away.
3. Starting writeback on the lone block clears the folio's dirty tag.
4. The reflink waits for writeback with `btrfs_wait_ordered_range()`. That
   relies on the dirty tag to find the folio, so it returns before the
   compressed extent has an ordered extent.

Depending on who wins the race, one of three things happens:

1. The reflink splits the pinned extent map of the compressed extent. When
   that extent completes, the transaction aborts and the filesystem goes
   read-only. This is the production symptom.
2. The compressed write lands after the reflink and silently replaces the
   reflinked data (stale reads).
3. If the reflink source is an inline extent, `copy_inline_to_page()` and the
   async worker deadlock (`-m inline`).

Fix: "btrfs: wait for pending async extents in btrfs_fdatawrite_range()".

## Files

- `run.sh`: host side. It builds the reproducer, creates a 4K-block btrfs
  image, boots the kernel with virtme-ng and prints the verdict.
- `guest.sh`: guest side. It mounts with `compress-force=zstd:3`, runs the
  reproducer, and watches for the forced read-only, stale reads or a hang.
- `repro.c`: the reproducer. Each iteration does:
  1. rewrite blocks 1-2 (async compressed) and block 5 (written right away) of
     one folio;
  2. `copy_file_range()` block 0 onto block 1;
  3. read block 1 back.

  With pages smaller than 32K, each iteration first truncates the file and
  rewrites its first 32K, so that the blocks share a large folio.
- `delay.bt`: optional bpftrace delays (`-d`) that make the race hit almost at
  once.

## Requirements

- virtme-ng, qemu, btrfs-progs and gcc on the host. bpftrace and stress-ng are
  needed only for `-d` and `-m stress-ng`.
- A kernel built with `CONFIG_BTRFS_FS=y` that virtme-ng can boot, and either:
  - 64K pages (`CONFIG_ARM64_64K_PAGES=y`), which hit the race fastest, or
  - 4K pages on v7.2 or later, where btrfs uses large folios.

  For example:

      vng --kconfig --configitem CONFIG_BTRFS_FS=y --configitem CONFIG_ARM64_64K_PAGES=y
      make LLVM=1 -j$(nproc)

## Usage

    ./run.sh -k ~/Devel/linux-next                     # kernel tree or image
    ./run.sh -k arch/arm64/boot/Image -d               # with bpftrace delays
    ./run.sh -k arch/arm64/boot/Image -m inline        # deadlock variant
    ./run.sh -k arch/arm64/boot/Image -m stress-ng     # stress-ng --fd-abuse, same race

Options: `-t` gives up after N seconds (default 240), `-n` sets the number of
reproducer copies (default 4, or one stress-ng instance per CPU), `-c` sets the
guest CPUs (default 8), and `-K` keeps the work directory in `/tmp`.

`run.sh` runs vng under `script(1)`, so it also works without a terminal, for
example from an agent or cron. It exits with 1 when the issue reproduced, 0
when it did not, and 2 on a setup error. Run it from sh or bash.

## Results on next-20261102 (arm64, 8 vCPUs)

These are `run.sh` runs against the same base, without and with the fix.

| kernel                 | mode              | without the fix                       | with the fix |
|------------------------|-------------------|---------------------------------------|--------------|
| 64K pages              | clone             | stale read after 2s, read-only at 6s  | clean, 120s  |
| 64K pages              | clone, `-d`       | read-only after 2s                    | clean, 120s  |
| 64K pages              | inline            | deadlock after 32s (30s watchdog)     | clean, 120s  |
| 64K pages              | stress-ng (8)     | read-only after 44s                   | clean, 120s  |
| 4K pages, large folios | clone             | stale read after 22s                  | clean, 240s  |
| 4K pages, large folios | clone, `-d`       | read-only after 2s                    | clean, 120s  |

The race is timing dependent. Hit times vary between runs (the 4K clone
case has taken from 22s to about 2 minutes), and `-d` makes it near certain.
# btrfs-reflink-async-compress
