#ifndef DUOCODE_CRASHLOGGER_H
#define DUOCODE_CRASHLOGGER_H

#ifdef __cplusplus
extern "C" {
#endif

void dc_install_crash_handlers(void);
const char *dc_get_last_crash_log(void);
void dc_clear_last_crash_log(void);

#ifdef __cplusplus
}
#endif

#endif
