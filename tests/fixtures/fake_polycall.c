/*
 * TEST FIXTURE ONLY -- a fake libpolycall used to prove the binding fails
 * cleanly (a clear error, never a crash) when the installed library is not
 * usable. It is never linked into the binding.
 *
 *   -DFAKE_V10      an old 1.0 library: only the 1.0 API, no ABI v1 symbols
 *   -DFAKE_ABI=2    every ABI v1 symbol, but polycall_ffi_abi_version() == 2
 *
 *   cc -shared -fPIC -Wl,-soname,libpolycall.so.1 -DFAKE_ABI=2 \
 *      fake_polycall.c -o abi2/libpolycall.so.1
 */
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#  define FAKE_API __declspec(dllexport)
#else
#  define FAKE_API __attribute__((visibility("default")))
#endif

#define FAKE_E_INTERNAL (-18)

FAKE_API const char *polycall_get_version(void) { return "1.0.0"; }

#ifndef FAKE_V10
#ifndef FAKE_ABI
#  define FAKE_ABI 2
#endif
FAKE_API int polycall_ffi_abi_version(void) { return FAKE_ABI; }
FAKE_API int polycall_ffi_version(char *buf, int len)
{
    const char *v = "9.9.9";
    int i;
    if (len < 0) return -1;
    for (i = 0; buf && i + 1 < len && v[i]; ++i) buf[i] = v[i];
    if (buf && len > 0) buf[i] = '\0';
    return 5;
}
FAKE_API const char *polycall_strerror(int s) { (void)s; return "POLYCALL_E_INTERNAL: fake library"; }
FAKE_API int polycall_last_error(char *buf, size_t cap) { if (buf && cap) buf[0] = '\0'; return 0; }
FAKE_API int polycall_ffi_run_config(const char *p, int r) { (void)p; (void)r; return FAKE_E_INTERNAL; }
FAKE_API int polycall_ffi_describe(const char *p, char *b, int n) { (void)p; (void)b; (void)n; return FAKE_E_INTERNAL; }
FAKE_API int polycall_call(const char *e, const char *s, const char *o, const char *i, uint32_t t,
                           char *out, size_t cap, size_t *len)
{ (void)e; (void)s; (void)o; (void)i; (void)t; (void)out; (void)cap; (void)len; return FAKE_E_INTERNAL; }
FAKE_API int polycall_peer_open(const char *n, const char *b, const char *a, int32_t *h)
{ (void)n; (void)b; (void)a; if (h) *h = 0; return FAKE_E_INTERNAL; }
FAKE_API int polycall_peer_close(int32_t h) { (void)h; return FAKE_E_INTERNAL; }
FAKE_API int polycall_peer_endpoint(int32_t h, char *b, size_t c) { (void)h; (void)b; (void)c; return FAKE_E_INTERNAL; }
FAKE_API int polycall_peer_node_id(int32_t h, char *b, size_t c) { (void)h; (void)b; (void)c; return FAKE_E_INTERNAL; }
FAKE_API int polycall_peer_register(int32_t h, const char *p, const char *e) { (void)h; (void)p; (void)e; return FAKE_E_INTERNAL; }
FAKE_API int polycall_peer_unregister(int32_t h, const char *p) { (void)h; (void)p; return FAKE_E_INTERNAL; }
FAKE_API int polycall_peer_list(int32_t h, char *b, size_t c, size_t *l) { (void)h; (void)b; (void)c; (void)l; return FAKE_E_INTERNAL; }
FAKE_API int polycall_peer_ping(int32_t h, const char *p, uint32_t t) { (void)h; (void)p; (void)t; return FAKE_E_INTERNAL; }
FAKE_API int polycall_peer_send(int32_t h, const char *p, const void *d, size_t n, const char *m, uint32_t t)
{ (void)h; (void)p; (void)d; (void)n; (void)m; (void)t; return FAKE_E_INTERNAL; }
FAKE_API int polycall_peer_recv(int32_t h, uint32_t t, char *s, size_t sc, char *m, size_t mc,
                                void *p, size_t pc, size_t *pl)
{ (void)h; (void)t; (void)s; (void)sc; (void)m; (void)mc; (void)p; (void)pc; (void)pl; return FAKE_E_INTERNAL; }
FAKE_API int polycall_peer_cancel(int32_t h) { (void)h; return FAKE_E_INTERNAL; }
FAKE_API int polycall_peer_health(int32_t h, char *b, size_t c, size_t *l) { (void)h; (void)b; (void)c; (void)l; return FAKE_E_INTERNAL; }
#endif
