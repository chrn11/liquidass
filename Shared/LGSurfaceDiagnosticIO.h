#pragma once
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Atomic replacement, not mmap/seqlock: a crashed writer cannot leave readers
 * waiting for an odd sequence. Bounded exact-size IO; never follow symlinks.
 * A same-UID attacker can still forge diagnostics. Do not use as a render ACK. */
static inline int LGSurfaceDiagnosticWriteAtomic(const char *path,
                                                 const void *bytes, size_t size) {
    if (!path || !bytes || !size || strlen(path) > 900) return 0;
    char temporary[1024];
    int length = snprintf(temporary, sizeof(temporary), "%s.XXXXXX.tmp", path);
    if (length < 0 || (size_t)length >= sizeof(temporary)) return 0;
    int fd = mkstemps(temporary, 4);
    if (fd < 0) return 0;
    (void)fcntl(fd, F_SETFD, FD_CLOEXEC);
    int ok = 1;
    size_t offset = 0;
    while (offset < size) {
        ssize_t n = write(fd, (const uint8_t *)bytes + offset, size - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { ok = 0; break; }
        offset += (size_t)n;
    }
    if (ok && fchmod(fd, 0644) != 0) ok = 0;
    if (close(fd) != 0) ok = 0;
    // Diagnostic heartbeats are not durability-critical; avoid per-second fsync.
    if (ok && rename(temporary, path) != 0) ok = 0;
    if (!ok) unlink(temporary);
    return ok;
}

static inline int LGSurfaceDiagnosticReadExact(const char *path, void *bytes,
                                               size_t size, uid_t expectedOwner) {
    if (!path || !bytes || !size) return 0;
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return 0;
    struct stat info;
    int ok = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) &&
        info.st_size == (off_t)size && info.st_nlink <= 1 &&
        info.st_uid == expectedOwner && !(info.st_mode & 0022);
    // A reader may hold the previous inode after atomic rename removed its
    // last directory link. nlink==0 is still a complete immutable snapshot;
    // nlink>1 indicates an unexpected hard-linked input and is rejected.
    size_t offset = 0;
    while (ok && offset < size) {
        ssize_t n = read(fd, (uint8_t *)bytes + offset, size - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { ok = 0; break; }
        offset += (size_t)n;
    }
    if (ok) {
        uint8_t extra;
        ssize_t n;
        do { n = read(fd, &extra, 1); } while (n < 0 && errno == EINTR);
        ok = n == 0;
    }
    close(fd);
    return ok;
}
