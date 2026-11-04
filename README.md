# btrfs forced read-only after a transaction abort (virtme-ng reproducer)

This reproduces a btrfs issue we were seeing in production. A btrfs filesystem
mounted with compression suddenly goes read-only, and the kernel log shows:

    WARNING: fs/btrfs/extent_map.c:<line> at btrfs_unpin_extent_cache+<off>
    BTRFS warning (device <dev>): no extent map found for inode <ino> (root <root>) when unpinning extent range [<start>, <end>), generation <gen>
    WARNING: fs/btrfs/inode.c:<line> at btrfs_finish_one_ordered+<off>
    BTRFS: Transaction aborted (error -2)
    BTRFS info (device <dev> state EA): forced readonly

When the reflink covers only part of the extent, the warning reads "found
extent map for inode <ino> (root <root>) with unexpected start offset <off>
when unpinning extent range ...", and the error is -EUCLEAN (-117).

The disk is not corrupt. After a reboot the filesystem mounts fine, but all
writes fail with EROFS until then.

## Cause

The cause is a race between a reflink (`copy_file_range()`, `FICLONERANGE`)
and async compressed writeback of the range the reflink replaces. It needs:

1. A filesystem mounted with `compress` or `compress-force`.
2. A folio that holds more than one block: 64K (or 16K) pages with 4K blocks,
   or 4K pages once the file uses large folios (the default since v7.2).
3. v6.16 or later, where btrfs compresses ranges that do not fill a folio
   (d03e3a9370c8), or v6.13 or later with `CONFIG_BTRFS_EXPERIMENTAL`
   (1d2fbb7f1f9e).

The race goes like this:

1. A writeback pass sends a range of a folio to async compression.
2. Another part of the same folio starts writeback first, which clears the
   folio's dirty tag. That part is either:
   - a block written right away: any single block with `compress-force`
     since v7.0 (59615e2c1f63), or a block that does not compress with
     `compress` (`-m clone`, `-m compress`);
   - or another async extent of the folio, submitted first (`-m late`). This
     is the trigger on v6.16 to v6.19 with `compress-force`, where single
     blocks still go through async compression.
3. The reflink waits for writeback with `btrfs_wait_ordered_range()`. That
   relies on the dirty tag to find the folio, so it returns before the
   compressed extent has an ordered extent.

Depending on who wins the race, one of three things happens:

1. The reflink drops or splits the pinned extent map of the compressed
   extent. When that extent completes, the transaction aborts and the
   filesystem goes read-only. This is the production symptom.
2. The compressed write lands after the reflink and silently replaces the
   reflinked data (stale reads).
3. If the reflink source is an inline extent, `copy_inline_to_page()` and the
   async worker deadlock (`-m inline`).

Reported at https://lore.kernel.org/all/ause7k_HjzUWT3D-@gmail.com/. The fix is
in `patches/`, see [Fix](#fix).

## Files

- `run.sh`: host side. It builds the reproducer, creates a 4K-block btrfs
  image, boots the kernel with virtme-ng and prints the verdict.
- `guest.sh`: guest side. It mounts with `compress-force=zstd:3` (or
  `compress=zstd:3` for `-m compress`), runs the reproducer, and watches for
  the forced read-only, stale reads or a hang.
- `repro.c`: the reproducer. Each iteration does:
  1. rewrite blocks 1-2 (async compressed) and block 5 of one folio;
  2. `copy_file_range()` block 0 onto block 1 (block 5 with `-m late`, right
     after starting writeback with `sync_file_range()`);
  3. read the reflinked block back.

  With pages smaller than 32K, each iteration first truncates the file and
  rewrites its first 32K, so that the blocks share a large folio.
- `delay.bt`, `delay-late.bt`: optional bpftrace delays (`-d`) that make the
  race hit almost at once.
- `patches/`: the fix, see [Fix](#fix).

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
    ./run.sh -k arch/arm64/boot/Image -m late          # v6.16 to v6.19, compress-force
    ./run.sh -k arch/arm64/boot/Image -m compress      # -o compress, v6.16 or later
    ./run.sh -k arch/arm64/boot/Image -m inline        # deadlock variant
    ./run.sh -k arch/arm64/boot/Image -m stress-ng     # stress-ng --fd-abuse, same race

The default mode (`-m clone`) needs v7.0 or later with `compress-force`. Use
`-m late` or `-m compress` on older kernels.

Options: `-t` gives up after N seconds (default 240), `-n` sets the number of
reproducer copies (default 4, or one stress-ng instance per CPU), `-c` sets the
guest CPUs (default 8), and `-K` keeps the work directory in `/tmp`.

`run.sh` runs vng under `script(1)`, so it also works without a terminal, for
example from an agent or cron. It exits with 1 when the issue reproduced, 0
when it did not, and 2 on a setup error. Run it from sh or bash.

## Fix

"btrfs: wait for pending async extents in btrfs_fdatawrite_range()" makes
the reflink wait for the folios of any delalloc left in the range, which an
async extent keeps locked until its ordered extent exists. Apply it with
`git am`:

- `patches/0001-*.patch`: v7.0 or later and linux-next (made against
  next-20261102).
- `patches/v6.16-v6.19/0001-*.patch`: the same fix for v6.16 to v6.19, with
  `folio_next_pos()` open-coded. Tested on v6.16.

## Results (arm64, 8 vCPUs)

These are `run.sh` runs against the same base, without and with the fix. The
v6.16 runs use the fix backported, with `folio_next_pos()` open-coded.

| kernel                         | mode          | without the fix                       | with the fix |
|--------------------------------|---------------|---------------------------------------|--------------|
| next-20261102, 64K pages       | clone         | stale read after 2s, read-only at 6s  | clean, 120s  |
| next-20261102, 64K pages       | clone, `-d`   | read-only after 2s                    | clean, 120s  |
| next-20261102, 64K pages       | inline        | deadlock after 32s (30s watchdog)     | clean, 120s  |
| next-20261102, 64K pages       | stress-ng (8) | read-only after 44s                   | clean, 120s  |
| next-20261102, 4K large folios | clone         | stale read after 22s                  | clean, 240s  |
| next-20261102, 4K large folios | clone, `-d`   | read-only after 2s                    | clean, 120s  |
| v6.16, 64K pages               | clone         | clean, 240s (needs v7.0)              |              |
| v6.16, 64K pages               | late          | stale read after 8s, read-only at 18s | clean, 240s  |
| v6.16, 64K pages               | late, `-d`    | read-only after 2s                    | clean, 240s  |
| v6.16, 64K pages               | compress      | read-only after 2s                    | clean, 240s  |

On v6.16, `-m late` fails exactly like the production hosts did: "no extent
map found ... when unpinning extent range [20480, 24576)" and error -2.

The race is timing dependent. Hit times vary between runs (the 4K clone
case has taken from 22s to about 2 minutes), and `-d` makes it near certain.
# btrfs-reflink-async-compress
