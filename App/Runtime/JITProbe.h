#ifndef DUOCODE_JITPROBE_H
#define DUOCODE_JITPROBE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Returns 1 if executable memory / JIT can be used (e.g. debugger or JIT enabler
 * such as StikDebug / SideJITServer attached, or unrestricted environment), else 0. */
int dc_process_is_debugged(void);

#ifdef __cplusplus
}
#endif

#endif
