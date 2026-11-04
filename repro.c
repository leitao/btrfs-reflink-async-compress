// SPDX-License-Identifier: GPL-2.0
/*
 * Reproduce btrfs going read-only after a transaction abort (-EUCLEAN) in
 * btrfs_unpin_extent_cache(), caused by a reflink racing with async
 * compressed writeback of the range it replaces.
 *
 * Every iteration dirties blocks 1-2 (sent to async compression) and block 5
 * (written right away) of one multi-block folio, reflinks block 0 onto block 1
 * with copy_file_range() and reads block 1 back.  On an unfixed kernel the
 * reflink does not wait for the async extent, so one of these happens:
 *
 *  - the transaction aborts and the filesystem is forced read-only,
 *  - block 1 reads back the overwritten data instead of the cloned data,
 *  - with INLINE_SRC=1, copy_inline_to_page() deadlocks against the worker.
 *
 * Needs a btrfs with 4K blocks mounted with compress-force.  With pages of 32K
 * or more the blocks share a page.  With smaller pages (4K, 16K) each iteration
 * truncates the file and rewrites its first 32K, so that they share a large
 * folio (btrfs uses large folios by default since v7.2).
 *
 * Usage: repro <file> [iterations]
 *   INLINE_SRC=1   clone from an inline extent (64K pages only)
 *   LARGE_FOLIO=0|1 override the large folio mode picked from the page size
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define BS 4096

static void fill(char *b, size_t n, unsigned int seed)
{
	for (size_t i = 0; i < n; i++)
		b[i] = (char)('a' + (seed + i / 512) % 26);
}

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "f";
	long iters = argc > 2 ? atol(argv[2]) : 100000000;
	char a[BS], b[2 * BS], c[BS], r[BS], big[8 * BS];
	const char *env = getenv("LARGE_FOLIO");
	int large = env ? atoi(env) : sysconf(_SC_PAGESIZE) < 8 * BS;
	int inline_src = getenv("INLINE_SRC") != NULL;
	long mismatches = 0;
	int fd, fd_ro;
	ssize_t ret;

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (inline_src && large) {
		fprintf(stderr, "INLINE_SRC needs pages of 32K or more\n");
		return 2;
	}
	printf("mode: %s source, %s\n", inline_src ? "inline" : "regular",
	       large ? "32K large folio rebuilt every iteration" : "one page");

	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) {
		perror("open");
		return 2;
	}
	fill(a, sizeof(a), 0);
	for (int k = 0; k < 8; k++)
		memcpy(big + k * BS, a, BS);

	/*
	 * The clone source is block 0: a lone 4K block at offset 0 of a new file
	 * becomes an inline extent, several blocks make a regular extent.
	 */
	ret = inline_src ? BS : (large ? 8 : 4) * BS;
	if (pwrite(fd, big, ret, 0) != ret || fsync(fd)) {
		perror("initial write");
		return 2;
	}
	fd_ro = open(path, O_RDONLY);
	if (fd_ro < 0) {
		perror("open ro");
		return 2;
	}

	for (long i = 0; i < iters; i++) {
		loff_t off_in = 0, off_out = BS;

		if (i % 200 == 0)
			printf("iter %ld t=%ld mismatches %ld\n", i,
			       (long)time(NULL), mismatches);

		/* The clone invalidates or splits the folio: build it again. */
		if (large && (ftruncate(fd, 0) ||
			      pwrite(fd, big, sizeof(big), 0) != sizeof(big) ||
			      fsync(fd))) {
			printf("iter %ld: refill: %s\n", i, strerror(errno));
			break;
		}
		/* Two blocks [4K, 12K): an async compressed extent. */
		fill(b, sizeof(b), 1 + i % 13);
		if (pwrite(fd, b, sizeof(b), BS) != sizeof(b)) {
			printf("iter %ld: pwrite: %s\n", i, strerror(errno));
			break;
		}
		/* A lone block [20K, 24K) of the same folio: written right away. */
		fill(c, sizeof(c), 7);
		if (pwrite(fd, c, BS, 5 * BS) != BS) {
			printf("iter %ld: pwrite: %s\n", i, strerror(errno));
			break;
		}
		ret = copy_file_range(fd_ro, &off_in, fd, &off_out, BS, 0);
		if (ret != BS) {
			printf("iter %ld: copy_file_range returned %zd: %s\n", i,
			       ret, strerror(errno));
			break;
		}
		if (pread(fd, r, BS, BS) != BS) {
			printf("iter %ld: pread: %s\n", i, strerror(errno));
			break;
		}
		if (memcmp(r, a, BS) && mismatches++ < 5)
			printf("iter %ld: STALE READ: [4K, 8K) holds '%c', not the cloned '%c'\n",
			       i, r[0], a[0]);
	}
	printf("done, mismatches %ld\n", mismatches);
	return mismatches ? 1 : 0;
}
