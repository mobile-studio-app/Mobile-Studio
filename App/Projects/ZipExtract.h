#ifndef DUO_ZIP_EXTRACT_H
#define DUO_ZIP_EXTRACT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Extracts the zip archive at `zip_path` into `target_dir` (created if needed). Returns 0 on
 * success; otherwise 1 with the reason in `error` (`error_size` bytes, NUL-terminated). */
int dc_zip_extract(const char *zip_path, const char *target_dir, char *error, size_t error_size);

#ifdef __cplusplus
}
#endif

#endif
