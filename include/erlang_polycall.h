#ifndef ERLANG_POLYCALL_H
#define ERLANG_POLYCALL_H

#ifdef __cplusplus
extern "C" {
#endif

/* Forward the configuration path to polycall_ffi_run_config(path, 1)
 * (strict: validate for running with this build). Returns a POLYCALL_*
 * status from <polycall.h>. */
int erlang_polycall_run_config(const char *config_path);

#ifdef __cplusplus
}
#endif

#endif /* ERLANG_POLYCALL_H */
