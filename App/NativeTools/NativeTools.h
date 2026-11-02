#ifndef DUOCODE_NATIVETOOLS_H
#define DUOCODE_NATIVETOOLS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Runs the macOS command-line programs VS Code extensions ship, inside DuoCode (see
 * NativeTools.mm). Programs are signed with the user's development certificate. */

/* The certificate (.p12) and its password. NULL/0 forgets it. */
void dc_native_tools_set_certificate(const void *p12, size_t length, const char *password);

/* Starts the loopback service Node.js asks to run programs through; returns its port, or 0. */
int dc_native_tools_start(void);

/* Signs an iOS library (a Python package's compiled module) in place with the certificate, so the
 * app can load it. 0 on success; 3 when there's no certificate; otherwise the reason is in `error`. */
int dc_native_tools_sign_library(const char *path, const char *identifier, char *error, size_t capacity);

/* The team ID of a .p12's certificate, or the reason it can't be used: returns 0 for a team ID,
 * 1 for a reason. Both go to `out`. */
int dc_native_tools_certificate_team(const void *p12, size_t length, const char *password, char *out, size_t capacity);

#ifdef __cplusplus
}
#endif

#endif
