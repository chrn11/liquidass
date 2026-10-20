#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include "LGSurfaceDiagnostics.h"
#include "LGSurfaceDiagnosticIO.h"

static void init(LGSurfaceDiagnosticPacketV1 *p) {
    memset(p, 0, sizeof(*p));
    p->magic = LG_SURFACE_DIAGNOSTICS_MAGIC;
    p->version = LG_SURFACE_DIAGNOSTICS_VERSION;
    p->byteSize = sizeof(*p); p->capacity = LG_SURFACE_DIAGNOSTICS_CAPACITY;
    p->count = 2; p->producerPID = 12; p->producerEpoch = 123;
    p->serial = 1; p->monotonicMilliseconds = 10000;
    p->flags = LG_SURFACE_DIAGNOSTICS_ONLY;
    for (unsigned i = 0; i < p->count; i++) {
        p->entries[i].surfaceIdentifier = i+1;
        p->entries[i].surface = LGSurfaceDescriptorV1MakeDefault(LGSurfaceRolePanel, i+5);
        p->entries[i].surface.captureOwnerGeneration = i+5;
        p->entries[i].surface.captureGroup = LGHostIdentifierQuickActions;
        p->entries[i].surface.captureOwnerGroup = LGHostIdentifierQuickActions;
    }
}
#define REJECT(field, value) do { init(p); p->field = (value); assert(!LGSurfaceDiagnosticPacketIsValid(p, sizeof(*p), 12000)); } while (0)

int main(void) {
    LGSurfaceDiagnosticPacketV1 *p = calloc(1,sizeof(*p)), *r = calloc(1,sizeof(*r));
    assert(p && r);
    assert(sizeof(*p)==20536 && offsetof(LGSurfaceDiagnosticPacketV1, entries)==56);
    init(p); assert(LGSurfaceDiagnosticPacketIsValid(p, sizeof(*p), 12000));
    assert(!LGSurfaceDiagnosticPacketIsValid(p, sizeof(*p)-1, 12000));
    assert(!LGSurfaceDiagnosticPacketIsValid(p, sizeof(*p)+1, 12000));
    assert(!LGSurfaceDiagnosticPacketIsValid(p, sizeof(*p), 9999));
    assert(!LGSurfaceDiagnosticPacketIsValid(p, sizeof(*p), 15001));
    REJECT(magic,0); REJECT(version,2); REJECT(byteSize,10); REJECT(capacity,0);
    REJECT(count,129); REJECT(producerPID,0); REJECT(producerPID,UINT32_MAX);
    REJECT(producerEpoch,0); REJECT(serial,0); REJECT(flags,0); REJECT(flags,4); REJECT(reserved,1);
    REJECT(entries[1].surfaceIdentifier,1); REJECT(entries[0].surfaceIdentifier,0);
    REJECT(entries[1].surface.captureGroup,LGHostIdentifierCount);
    REJECT(entries[1].surface.captureOwnerGroup,0);
    REJECT(entries[1].surface.captureOwnerGeneration,99);
    REJECT(entries[1].surface.maskWidth,NAN);
    LGSurfaceDiagnosticCursor cursor = {0};
    init(p); assert(LGSurfaceDiagnosticAccept(p,sizeof(*p),12000,&cursor));
    LGSurfaceDiagnosticCursor saved=cursor;
    assert(!LGSurfaceDiagnosticAccept(p,sizeof(*p),12000,&cursor));
    assert(memcmp(&cursor,&saved,sizeof(cursor))==0);
    p->serial++; assert(LGSurfaceDiagnosticAccept(p,sizeof(*p),12000,&cursor));
    p->producerPID++; p->serial++; assert(!LGSurfaceDiagnosticAccept(p,sizeof(*p),12000,&cursor));
    init(p); p->producerEpoch++; assert(!LGSurfaceDiagnosticAccept(p,sizeof(*p),12000,&cursor));
    p->monotonicMilliseconds++; assert(LGSurfaceDiagnosticAccept(p,sizeof(*p),12000,&cursor));
    saved=cursor; p->version=2;
    assert(!LGSurfaceDiagnosticAccept(p,sizeof(*p),12000,&cursor));
    assert(memcmp(&cursor,&saved,sizeof(cursor))==0);
    char dir[]="/tmp/lg-diag-test-XXXXXX"; assert(mkdtemp(dir));
    char path[256], target[256]; snprintf(path,sizeof(path),"%s/state.bin",dir);
    snprintf(target,sizeof(target),"%s/target.bin",dir);
    init(p); assert(LGSurfaceDiagnosticWriteAtomic(path,p,sizeof(*p)));
    assert(LGSurfaceDiagnosticReadExact(path,r,sizeof(*r),getuid()));
    assert(memcmp(p,r,sizeof(*p))==0);
    assert(!LGSurfaceDiagnosticReadExact(path,r,sizeof(*r),getuid()+1));
    assert(chmod(path,0666)==0); assert(!LGSurfaceDiagnosticReadExact(path,r,sizeof(*r),getuid()));
    assert(chmod(path,0644)==0);
    assert(link(path,target)==0); assert(!LGSurfaceDiagnosticReadExact(path,r,sizeof(*r),getuid()));
    assert(unlink(target)==0);
    assert(rename(path,target)==0); assert(symlink(target,path)==0);
    assert(!LGSurfaceDiagnosticReadExact(path,r,sizeof(*r),getuid()));
    // Atomic publisher replaces a symlink rather than writing to its target.
    p->serial=22; assert(LGSurfaceDiagnosticWriteAtomic(path,p,sizeof(*p)));
    assert(LGSurfaceDiagnosticReadExact(target,r,sizeof(*r),getuid())); assert(r->serial==1);
    assert(LGSurfaceDiagnosticReadExact(path,r,sizeof(*r),getuid())); assert(r->serial==22);
    assert(unlink(target)==0);
    int fd=open(path,O_WRONLY|O_APPEND); assert(fd>=0); assert(write(fd,"x",1)==1); close(fd);
    assert(!LGSurfaceDiagnosticReadExact(path,r,sizeof(*r),getuid()));
    assert(truncate(path,10)==0); assert(!LGSurfaceDiagnosticReadExact(path,r,sizeof(*r),getuid()));
    assert(unlink(path)==0); assert(mkfifo(path,0600)==0);
    assert(!LGSurfaceDiagnosticReadExact(path,r,sizeof(*r),getuid())); assert(unlink(path)==0);
    init(p); assert(LGSurfaceDiagnosticWriteAtomic(path,p,sizeof(*p)));
    // Incomplete temporary bytes never replace the last complete snapshot.
    snprintf(target,sizeof(target),"%s/unfinished.tmp",dir);
    fd=open(target,O_WRONLY|O_CREAT|O_EXCL,0600); assert(fd>=0);
    assert(write(fd,p,10)==10); close(fd);
    assert(LGSurfaceDiagnosticReadExact(path,r,sizeof(*r),getuid())); assert(r->serial==1);
    assert(unlink(target)==0);
    // Readers observe only complete atomic versions during concurrent writes.
    pid_t child=fork(); assert(child>=0);
    if (!child) {
        for (unsigned i=1;i<=60;i++) {p->serial=i; p->entries[0].surface.interactionGeneration=i;
            assert(LGSurfaceDiagnosticWriteAtomic(path,p,sizeof(*p)));}
        _exit(0);
    }
    for (unsigned i=0;i<150;i++) {
        assert(LGSurfaceDiagnosticReadExact(path,r,sizeof(*r),getuid()));
        assert(LGSurfaceDiagnosticPacketIsValid(r,sizeof(*r),12000));
        assert(r->serial==1 || r->serial==r->entries[0].surface.interactionGeneration);
    }
    int status; assert(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==0);
    assert(unlink(path)==0); assert(rmdir(dir)==0);
    free(p); free(r);
    puts("PASS: bounded packet, freshness/replay/epoch, exact IO, symlink/FIFO/permissions, concurrent atomic snapshots");
    return 0;
}
