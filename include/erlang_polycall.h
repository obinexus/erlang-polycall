#ifndef ERLANG_POLYCALL_H
#define ERLANG_POLYCALL_H

#ifdef __cplusplus
extern "C" {
#endif

/* Forward the configuration path to libpolycall with run enabled. */
int erlang_polycall_run_config(const char *config_path);

#ifdef __cplusplus
}
#endif

#endif /* ERLANG_POLYCALL_H */
