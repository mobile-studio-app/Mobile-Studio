#include "JITProbe.h"
#include <unistd.h>
#include <stdint.h>
#include <dlfcn.h>

#define CS_OPS_STATUS 0
#define CS_DEBUGGED   0x10000000

typedef int (*csops_fn)(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

int dc_process_is_debugged(void) {
    // Non-destructive kernel status query via csops.
    // NOTE: We NEVER call mprotect(PROT_EXEC) here. On jailed iOS, attempting
    // mprotect(..., PROT_EXEC) without CS_DEBUGGED triggers an instant AMFI SIGKILL.
    csops_fn csops_ptr = (csops_fn)dlsym(RTLD_DEFAULT, "csops");
    if (csops_ptr) {
        uint32_t flags = 0;
        if (csops_ptr(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) == 0) {
            return (flags & CS_DEBUGGED) ? 1 : 0;
        }
    }
    return 0;
}
