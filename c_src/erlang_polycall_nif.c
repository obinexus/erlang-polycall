/*
 * erlang_polycall_nif.c -- Erlang NIF over the Polycall binding ABI v1
 * (<polycall.h>, docs/BINDING_ABI.md in https://github.com/obinexus/polycall).
 *
 * Rules this file follows:
 *   - Every call that can block (run_config, describe, call, peer open /
 *     close / ping / send and the waiting part of recv) runs on a dirty I/O
 *     scheduler (ERL_NIF_DIRTY_JOB_IO_BOUND), never on a normal scheduler.
 *   - recv never holds a dirty scheduler for long: it waits in slices of at
 *     most EP_RECV_SLICE_MS and re-schedules itself between slices
 *     (enif_schedule_nif). Receivers waiting with `infinity` therefore cannot
 *     starve file I/O and code loading (which also run on dirty I/O
 *     schedulers), and a killed receiver releases its scheduler within one
 *     slice. close/1 and cancel/1 are seen between slices as well as inside
 *     the core's own wait.
 *   - recv takes its cancel snapshot on the calling process's normal
 *     scheduler at call time, so cancel/1 wakes every recv/3 that was called
 *     before it -- also one still queued for a dirty scheduler.
 *   - A peer node is a NIF resource with an OPEN -> CLOSING -> CLOSED state.
 *     The core handle is closed exactly once: by close/1, or by the resource
 *     destructor (on a private closer thread, because polycall_peer_close()
 *     can take one accept poll, ~200 ms) when the last reference is dropped.
 *     After close the handle number is never passed to the core again:
 *     double close and use after close answer POLYCALL_E_INVALID_HANDLE here
 *     (the core recycles a slot's handle numbers after 2^23 reopenings).
 *   - The calling thread's polycall_last_error() is read inside the same NIF
 *     call that failed (it is thread-local), and returned with the status.
 *   - Nothing returned by the library is freed here (it returns nothing to
 *     free); every output goes into a buffer this file owns.
 */

#include <erl_nif.h>
#include <polycall.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "erlang_polycall.h"

#define EP_TEXT_INITIAL 4096
#define EP_RECV_SLICE_MS 200   /* longest single wait inside the core      */
#define EP_RECV_RETRIES 8      /* exact-size takes before using the caller's
                                  whole buffer (racing receivers)           */

/* ------------------------------------------------------------------------ */
/* atoms                                                                     */

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_undefined;
static ERL_NIF_TERM atom_null;
static ERL_NIF_TERM atom_infinity;

/* ------------------------------------------------------------------------ */
/* peer resource + closer thread                                             */

enum { EP_OPEN = 0, EP_CLOSING = 1, EP_CLOSED = 2 };

typedef struct {
    polycall_peer_t handle;   /* immutable after open                       */
    int state;                /* EP_OPEN/CLOSING/CLOSED, guarded by g_state_mu */
    unsigned cancel_gen;      /* bumped by cancel/1, guarded by g_state_mu  */
} ep_peer;

typedef struct ep_close_item {
    polycall_peer_t handle;
    struct ep_close_item *next;
} ep_close_item;

static ErlNifResourceType *g_peer_type;
static ErlNifMutex *g_state_mu;      /* ep_peer.state / cancel_gen          */
static ErlNifMutex *g_q_mu;          /* closer queue                        */
static ErlNifCond *g_q_cv;
static ep_close_item *g_q_head;
static int g_q_stop;
static ErlNifTid g_closer;
static int g_closer_started;         /* guarded by g_q_mu after load        */

static void *closer_main(void *arg)
{
    (void)arg;
    for (;;) {
        ep_close_item *item;
        enif_mutex_lock(g_q_mu);
        while (!g_q_head && !g_q_stop) enif_cond_wait(g_q_cv, g_q_mu);
        item = g_q_head;
        if (item) g_q_head = item->next;
        enif_mutex_unlock(g_q_mu);
        if (!item) break;                    /* stop requested, queue drained */
        (void)polycall_peer_close(item->handle);
        enif_free(item);
    }
    return NULL;
}

/* The last reference is gone: close the node unless close/1 already did. */
static void peer_dtor(ErlNifEnv *env, void *obj)
{
    ep_peer *p = (ep_peer *)obj;
    ep_close_item *item;
    int open;
    (void)env;
    enif_mutex_lock(g_state_mu);
    open = p->state == EP_OPEN && p->handle > 0;
    p->state = EP_CLOSED;
    enif_mutex_unlock(g_state_mu);
    if (!open) return;

    item = (ep_close_item *)enif_alloc(sizeof *item);
    enif_mutex_lock(g_q_mu);
    if (item && g_closer_started) {
        item->handle = p->handle;
        item->next = g_q_head;
        g_q_head = item;
        enif_cond_signal(g_q_cv);
        enif_mutex_unlock(g_q_mu);
        return;
    }
    enif_mutex_unlock(g_q_mu);
    if (item) enif_free(item);
    (void)polycall_peer_close(p->handle);    /* no memory / no thread: inline */
}

/* ------------------------------------------------------------------------ */
/* helpers                                                                   */

static ERL_NIF_TERM mk_bin(ErlNifEnv *env, const char *s, size_t n)
{
    ERL_NIF_TERM t;
    unsigned char *p = enif_make_new_binary(env, n, &t);
    if (n) memcpy(p, s, n);
    return t;
}

static ERL_NIF_TERM mk_cstr(ErlNifEnv *env, const char *s)
{
    return mk_bin(env, s, strlen(s));
}

static ERL_NIF_TERM last_error_term(ErlNifEnv *env)
{
    char detail[1024];
    detail[0] = '\0';
    (void)polycall_last_error(detail, sizeof detail);
    detail[sizeof detail - 1] = '\0';
    return mk_cstr(env, detail);
}

/* {error, Code, Detail} -- Detail is polycall_last_error() of this thread */
static ERL_NIF_TERM err3(ErlNifEnv *env, int rc)
{
    return enif_make_tuple3(env, atom_error, enif_make_int(env, rc), last_error_term(env));
}

/* {error, Code, Detail, Info} */
static ERL_NIF_TERM err4(ErlNifEnv *env, int rc, ERL_NIF_TERM info)
{
    return enif_make_tuple4(env, atom_error, enif_make_int(env, rc),
                            last_error_term(env), info);
}

/* binding-side failures carry their own detail */
static ERL_NIF_TERM err3_msg(ErlNifEnv *env, int rc, const char *msg)
{
    return enif_make_tuple3(env, atom_error, enif_make_int(env, rc), mk_cstr(env, msg));
}

static ERL_NIF_TERM err4_msg(ErlNifEnv *env, int rc, const char *msg, ERL_NIF_TERM info)
{
    return enif_make_tuple4(env, atom_error, enif_make_int(env, rc), mk_cstr(env, msg), info);
}

static ERL_NIF_TERM ok_or_err(ErlNifEnv *env, int rc)
{
    return rc == POLYCALL_OK ? atom_ok : err3(env, rc);
}

/*
 * iodata / binary -> freshly allocated NUL-terminated string. The Erlang
 * layer has already encoded text as UTF-8. The atoms 'undefined' and 'null'
 * give NULL when allow_null. Returns 1 on success, 0 on badarg (embedded
 * NUL, wrong type).
 */
static int get_cstr(ErlNifEnv *env, ERL_NIF_TERM t, int allow_null, char **out)
{
    ErlNifBinary bin;
    *out = NULL;
    if (allow_null && (enif_is_identical(t, atom_undefined) || enif_is_identical(t, atom_null))) {
        return 1;
    }
    if (!enif_inspect_iolist_as_binary(env, t, &bin)) return 0;
    if (bin.size && memchr(bin.data, '\0', bin.size) != NULL) return 0;
    *out = (char *)enif_alloc(bin.size + 1);
    if (!*out) return 0;
    if (bin.size) memcpy(*out, bin.data, bin.size);
    (*out)[bin.size] = '\0';
    return 1;
}

static void free_cstr(char *s)
{
    if (s) enif_free(s);
}

/* 0..4294967295 | infinity -> uint32. UINT32_MAX (and infinity) is the
 * ABI's "wait indefinitely" for recv; anything outside uint32 is badarg. */
static int get_timeout(ErlNifEnv *env, ERL_NIF_TERM t, uint32_t *out)
{
    ErlNifUInt64 v;
    if (enif_is_identical(t, atom_infinity)) {
        *out = UINT32_MAX;
        return 1;
    }
    if (!enif_get_uint64(env, t, &v) || v > (ErlNifUInt64)UINT32_MAX) return 0;
    *out = (uint32_t)v;
    return 1;
}

static int get_peer(ErlNifEnv *env, ERL_NIF_TERM t, ep_peer **out)
{
    return enif_get_resource(env, t, g_peer_type, (void **)out);
}

/* The core handle while the resource is open; 0 once close/1 started. */
static int open_handle(ep_peer *p, polycall_peer_t *h)
{
    int open;
    enif_mutex_lock(g_state_mu);
    open = p->state == EP_OPEN;
    *h = p->handle;
    enif_mutex_unlock(g_state_mu);
    return open;
}

static const char *closed_detail(ep_peer *p, char *buf, size_t cap)
{
    snprintf(buf, cap, "peer handle %ld was closed by close/1", (long)p->handle);
    return buf;
}

static ERL_NIF_TERM closed_err3(ErlNifEnv *env, ep_peer *p)
{
    char buf[96];
    return err3_msg(env, POLYCALL_E_INVALID_HANDLE, closed_detail(p, buf, sizeof buf));
}

static ERL_NIF_TERM closed_err4(ErlNifEnv *env, ep_peer *p)
{
    char buf[96];
    return err4_msg(env, POLYCALL_E_INVALID_HANDLE, closed_detail(p, buf, sizeof buf),
                    atom_undefined);
}

typedef int (*text_fn)(polycall_peer_t h, char *buf, size_t cap, size_t *out_len);

/* Read a snprintf-rules text output, growing the buffer on E_TOO_LARGE. */
static ERL_NIF_TERM text_result(ErlNifEnv *env, polycall_peer_t h, text_fn fn)
{
    size_t cap = EP_TEXT_INITIAL, need = 0;
    int attempt;
    for (attempt = 0; attempt < 4; ++attempt) {
        char *buf = (char *)enif_alloc(cap);
        int rc;
        if (!buf) return err3_msg(env, POLYCALL_E_NO_MEMORY, "enif_alloc failed");
        need = 0;
        rc = fn(h, buf, cap, &need);
        if (rc == POLYCALL_OK) {
            ERL_NIF_TERM t = mk_bin(env, buf, strlen(buf));
            enif_free(buf);
            return enif_make_tuple2(env, atom_ok, t);
        }
        if (rc != POLYCALL_E_TOO_LARGE) {
            ERL_NIF_TERM e = err3(env, rc);
            enif_free(buf);
            return e;
        }
        enif_free(buf);
        cap = need + 1;
    }
    return err3(env, POLYCALL_E_TOO_LARGE);
}

static int endpoint_fn(polycall_peer_t h, char *buf, size_t cap, size_t *out_len)
{
    int rc = polycall_peer_endpoint(h, buf, cap);
    if (out_len) *out_len = rc == POLYCALL_OK ? strlen(buf) : POLYCALL_ENDPOINT_MAX;
    return rc;
}

static int node_id_fn(polycall_peer_t h, char *buf, size_t cap, size_t *out_len)
{
    int rc = polycall_peer_node_id(h, buf, cap);
    if (out_len) *out_len = rc == POLYCALL_OK ? strlen(buf) : POLYCALL_PEER_ID_MAX;
    return rc;
}

/* ------------------------------------------------------------------------ */
/* library                                                                   */

static ERL_NIF_TERM nif_abi_version(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc; (void)argv;
    return enif_make_int(env, polycall_ffi_abi_version());
}

static ERL_NIF_TERM nif_version(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char buf[64];
    int n;
    (void)argc; (void)argv;
    n = polycall_ffi_version(buf, (int)sizeof buf);
    if (n < 0) return err3(env, n);
    return mk_cstr(env, buf);
}

static ERL_NIF_TERM nif_strerror(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int code;
    (void)argc;
    if (!enif_get_int(env, argv[0], &code)) return enif_make_badarg(env);
    return mk_cstr(env, polycall_strerror(code));
}

/* ------------------------------------------------------------------------ */
/* configuration                                                             */

static ERL_NIF_TERM nif_run_config(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char *path;
    int run, rc;
    (void)argc;
    if (!enif_get_int(env, argv[1], &run)) return enif_make_badarg(env);
    if (!get_cstr(env, argv[0], 1, &path)) return enif_make_badarg(env);
    /* run != 0 goes through the C adapter's documented strict entry point */
    rc = run ? erlang_polycall_run_config(path) : polycall_ffi_run_config(path, 0);
    free_cstr(path);
    return ok_or_err(env, rc);
}

static ERL_NIF_TERM nif_describe(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char *path, *buf;
    int n, m;
    ERL_NIF_TERM t;
    (void)argc;
    if (!get_cstr(env, argv[0], 1, &path)) return enif_make_badarg(env);
    n = polycall_ffi_describe(path, NULL, 0);
    if (n < 0) {
        free_cstr(path);
        return err3(env, n);
    }
    buf = (char *)enif_alloc((size_t)n + 1);
    if (!buf) {
        free_cstr(path);
        return err3_msg(env, POLYCALL_E_NO_MEMORY, "enif_alloc failed");
    }
    m = polycall_ffi_describe(path, buf, n + 1);
    free_cstr(path);
    if (m < 0) {
        t = err3(env, m);
    } else if (m > n) {           /* file changed between the two reads */
        t = err3_msg(env, POLYCALL_E_TOO_LARGE, "configuration changed while being described");
    } else {
        t = enif_make_tuple2(env, atom_ok, mk_bin(env, buf, (size_t)m));
    }
    enif_free(buf);
    return t;
}

/* ------------------------------------------------------------------------ */
/* RPC                                                                       */

static ERL_NIF_TERM nif_call(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char *endpoint = NULL, *service = NULL, *operation = NULL, *input = NULL;
    uint32_t timeout;
    ErlNifBinary out;
    size_t out_len = 0;
    int rc;
    (void)argc;

    if (!get_timeout(env, argv[4], &timeout)) return enif_make_badarg(env);
    if (!get_cstr(env, argv[0], 1, &endpoint) || !get_cstr(env, argv[1], 1, &service) ||
        !get_cstr(env, argv[2], 1, &operation) || !get_cstr(env, argv[3], 1, &input)) {
        free_cstr(endpoint); free_cstr(service); free_cstr(operation); free_cstr(input);
        return enif_make_badarg(env);
    }
    /* sized for the documented maximum (+ NUL): a too-small buffer would
       discard a result that already ran */
    if (!enif_alloc_binary((size_t)POLYCALL_CALL_MAX_OUTPUT + 1, &out)) {
        free_cstr(endpoint); free_cstr(service); free_cstr(operation); free_cstr(input);
        return err4_msg(env, POLYCALL_E_NO_MEMORY, "enif_alloc_binary failed", atom_undefined);
    }
    out.data[0] = '\0';
    rc = polycall_call(endpoint, service, operation, input, timeout,
                       (char *)out.data, out.size, &out_len);
    free_cstr(endpoint); free_cstr(service); free_cstr(operation); free_cstr(input);

    if (rc == POLYCALL_E_TOO_LARGE || out_len >= out.size) {
        enif_release_binary(&out);
        return err4(env, rc == POLYCALL_OK ? POLYCALL_E_TOO_LARGE : rc, atom_undefined);
    }
    out_len = strlen((const char *)out.data);
    if (rc != POLYCALL_OK && out_len == 0) {
        enif_release_binary(&out);
        return err4(env, rc, atom_undefined);
    }
    if (!enif_realloc_binary(&out, out_len)) {
        enif_release_binary(&out);
        return err4_msg(env, POLYCALL_E_NO_MEMORY, "enif_realloc_binary failed", atom_undefined);
    }
    if (rc == POLYCALL_OK) {
        return enif_make_tuple2(env, atom_ok, enif_make_binary(env, &out));
    }
    /* the remote error object {"code":..,"message":..} */
    {
        ERL_NIF_TERM detail = last_error_term(env);
        return enif_make_tuple4(env, atom_error, enif_make_int(env, rc), detail,
                                enif_make_binary(env, &out));
    }
}

/* ------------------------------------------------------------------------ */
/* peers                                                                     */

static ERL_NIF_TERM nif_peer_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char *node_id = NULL, *bind = NULL, *token = NULL;
    polycall_peer_t h = 0;
    ep_peer *p;
    ERL_NIF_TERM term;
    int rc;
    (void)argc;
    if (!get_cstr(env, argv[0], 1, &node_id) || !get_cstr(env, argv[1], 1, &bind) ||
        !get_cstr(env, argv[2], 1, &token)) {
        free_cstr(node_id); free_cstr(bind); free_cstr(token);
        return enif_make_badarg(env);
    }
    rc = polycall_peer_open(node_id, bind, token, &h);
    if (token) {                      /* do not leave the secret in our heap */
        volatile char *v = token;
        size_t i, n = strlen(token);
        for (i = 0; i < n; ++i) v[i] = 0;
    }
    free_cstr(node_id); free_cstr(bind); free_cstr(token);
    if (rc != POLYCALL_OK) return err3(env, rc);

    p = (ep_peer *)enif_alloc_resource(g_peer_type, sizeof *p);
    if (!p) {
        (void)polycall_peer_close(h);
        return err3_msg(env, POLYCALL_E_NO_MEMORY, "enif_alloc_resource failed");
    }
    p->handle = h;
    p->state = EP_OPEN;
    p->cancel_gen = 0;
    term = enif_make_resource(env, p);
    enif_release_resource(p);         /* the term now owns it */
    return enif_make_tuple2(env, atom_ok, term);
}

static ERL_NIF_TERM nif_peer_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ep_peer *p;
    polycall_peer_t h;
    int rc, state;
    (void)argc;
    if (!get_peer(env, argv[0], &p)) return enif_make_badarg(env);
    enif_mutex_lock(g_state_mu);
    state = p->state;
    if (state == EP_OPEN) p->state = EP_CLOSING;   /* exactly one closer */
    h = p->handle;
    enif_mutex_unlock(g_state_mu);
    if (state != EP_OPEN) return closed_err3(env, p);

    rc = polycall_peer_close(h);    /* wakes blocked receivers (E_CLOSED) */
    enif_mutex_lock(g_state_mu);
    p->state = EP_CLOSED;           /* the core no longer knows h either way */
    enif_mutex_unlock(g_state_mu);
    return ok_or_err(env, rc);
}

static ERL_NIF_TERM nif_peer_handle(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ep_peer *p;
    (void)argc;
    if (!get_peer(env, argv[0], &p)) return enif_make_badarg(env);
    return enif_make_int(env, (int)p->handle);
}

static ERL_NIF_TERM nif_peer_endpoint(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ep_peer *p;
    polycall_peer_t h;
    (void)argc;
    if (!get_peer(env, argv[0], &p)) return enif_make_badarg(env);
    if (!open_handle(p, &h)) return closed_err3(env, p);
    return text_result(env, h, endpoint_fn);
}

static ERL_NIF_TERM nif_peer_node_id(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ep_peer *p;
    polycall_peer_t h;
    (void)argc;
    if (!get_peer(env, argv[0], &p)) return enif_make_badarg(env);
    if (!open_handle(p, &h)) return closed_err3(env, p);
    return text_result(env, h, node_id_fn);
}

static ERL_NIF_TERM nif_peer_register(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ep_peer *p;
    polycall_peer_t h;
    char *id = NULL, *ep = NULL;
    int rc;
    (void)argc;
    if (!get_peer(env, argv[0], &p)) return enif_make_badarg(env);
    if (!get_cstr(env, argv[1], 1, &id) || !get_cstr(env, argv[2], 1, &ep)) {
        free_cstr(id); free_cstr(ep);
        return enif_make_badarg(env);
    }
    if (!open_handle(p, &h)) {
        free_cstr(id); free_cstr(ep);
        return closed_err3(env, p);
    }
    rc = polycall_peer_register(h, id, ep);   /* syntax checks + a mutex: fast */
    free_cstr(id); free_cstr(ep);
    return ok_or_err(env, rc);
}

static ERL_NIF_TERM nif_peer_unregister(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ep_peer *p;
    polycall_peer_t h;
    char *id = NULL;
    int rc;
    (void)argc;
    if (!get_peer(env, argv[0], &p)) return enif_make_badarg(env);
    if (!get_cstr(env, argv[1], 1, &id)) return enif_make_badarg(env);
    if (!open_handle(p, &h)) {
        free_cstr(id);
        return closed_err3(env, p);
    }
    rc = polycall_peer_unregister(h, id);
    free_cstr(id);
    return ok_or_err(env, rc);
}

static ERL_NIF_TERM nif_peer_list(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ep_peer *p;
    polycall_peer_t h;
    (void)argc;
    if (!get_peer(env, argv[0], &p)) return enif_make_badarg(env);
    if (!open_handle(p, &h)) return closed_err3(env, p);
    return text_result(env, h, polycall_peer_list);
}

static ERL_NIF_TERM nif_peer_health(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ep_peer *p;
    polycall_peer_t h;
    (void)argc;
    if (!get_peer(env, argv[0], &p)) return enif_make_badarg(env);
    if (!open_handle(p, &h)) return closed_err3(env, p);
    return text_result(env, h, polycall_peer_health);
}

static ERL_NIF_TERM nif_peer_ping(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ep_peer *p;
    polycall_peer_t h;
    char *peer = NULL;
    uint32_t timeout;
    int rc;
    (void)argc;
    if (!get_peer(env, argv[0], &p) || !get_timeout(env, argv[2], &timeout)) {
        return enif_make_badarg(env);
    }
    if (!get_cstr(env, argv[1], 1, &peer)) return enif_make_badarg(env);
    if (!open_handle(p, &h)) {
        free_cstr(peer);
        return closed_err3(env, p);
    }
    rc = polycall_peer_ping(h, peer, timeout);
    free_cstr(peer);
    return ok_or_err(env, rc);
}

static ERL_NIF_TERM nif_peer_send(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ep_peer *p;
    polycall_peer_t h;
    char *peer = NULL, *msg_id = NULL;
    ErlNifBinary payload;
    uint32_t timeout;
    int rc;
    (void)argc;
    if (!get_peer(env, argv[0], &p) || !get_timeout(env, argv[4], &timeout)) {
        return enif_make_badarg(env);
    }
    if (!enif_inspect_iolist_as_binary(env, argv[2], &payload)) return enif_make_badarg(env);
    if (!get_cstr(env, argv[1], 1, &peer) || !get_cstr(env, argv[3], 1, &msg_id)) {
        free_cstr(peer); free_cstr(msg_id);
        return enif_make_badarg(env);
    }
    if (!open_handle(p, &h)) {
        free_cstr(peer); free_cstr(msg_id);
        return closed_err3(env, p);
    }
    /* exact bytes, binary-safe; over 1 MiB the core answers E_TOO_LARGE */
    rc = polycall_peer_send(h, peer, payload.size ? payload.data : (const void *)"",
                            payload.size, msg_id, timeout);
    free_cstr(peer); free_cstr(msg_id);
    return ok_or_err(env, rc);
}

static ERL_NIF_TERM ok_message(ErlNifEnv *env, const char *sender, const char *msg_id,
                               ERL_NIF_TERM payload)
{
    return enif_make_tuple4(env, atom_ok, mk_cstr(env, sender), mk_cstr(env, msg_id), payload);
}

/*
 * One receive attempt on h waiting at most `wait` ms. It waits with a
 * zero-length payload buffer: an empty message is taken at once, a non-empty
 * one stays queued and reports its size (E_TOO_LARGE), and is then taken with
 * a buffer of exactly that size. So an idle receiver allocates nothing, and a
 * message larger than `cap` stays queued, as the ABI requires.
 * Returns the core status; *out is set for every status except E_TIMEOUT.
 */
static int recv_once(ErlNifEnv *env, polycall_peer_t h, uint32_t wait, size_t cap,
                     ERL_NIF_TERM *out)
{
    char sender[POLYCALL_PEER_ID_MAX], msg_id[POLYCALL_MESSAGE_ID_MAX];
    unsigned char spare[1];
    ErlNifBinary bin;
    size_t need = 0, got, size;
    int rc, attempt;

    sender[0] = msg_id[0] = '\0';
    rc = polycall_peer_recv(h, wait, sender, sizeof sender, msg_id, sizeof msg_id,
                            spare, 0, &need);
    if (rc == POLYCALL_OK) {                     /* an empty message */
        *out = ok_message(env, sender, msg_id, mk_bin(env, "", 0));
        return rc;
    }
    if (rc == POLYCALL_E_TIMEOUT) return rc;
    if (rc != POLYCALL_E_TOO_LARGE) {
        *out = err4(env, rc, atom_undefined);
        return rc;
    }

    for (attempt = 0;; ++attempt) {
        if (need > cap) {           /* the oldest message does not fit: queued */
            *out = err4(env, POLYCALL_E_TOO_LARGE, enif_make_uint64(env, (ErlNifUInt64)need));
            return POLYCALL_E_TOO_LARGE;
        }
        /* another receiver of this node may take that message first; after a
           few exact-size tries use the caller's whole buffer, which settles it */
        size = attempt < EP_RECV_RETRIES ? need : cap;
        if (!enif_alloc_binary(size, &bin)) {
            *out = err4_msg(env, POLYCALL_E_NO_MEMORY, "enif_alloc_binary failed", atom_undefined);
            return POLYCALL_E_NO_MEMORY;
        }
        got = 0;
        sender[0] = msg_id[0] = '\0';
        rc = polycall_peer_recv(h, 0, sender, sizeof sender, msg_id, sizeof msg_id,
                                size ? (void *)bin.data : (void *)spare, size, &got);
        if (rc == POLYCALL_OK) {
            if (got > size || (got < size && !enif_realloc_binary(&bin, got))) {
                enif_release_binary(&bin);
                *out = err4_msg(env, POLYCALL_E_INTERNAL, "payload length exceeds the buffer",
                                atom_undefined);
                return POLYCALL_E_INTERNAL;
            }
            *out = ok_message(env, sender, msg_id, enif_make_binary(env, &bin));
            return rc;
        }
        enif_release_binary(&bin);
        if (rc == POLYCALL_E_TOO_LARGE && size < cap) {   /* a bigger one is first now */
            need = got;
            continue;
        }
        if (rc == POLYCALL_E_TIMEOUT) return rc;          /* someone emptied the inbox */
        *out = err4(env, rc, rc == POLYCALL_E_TOO_LARGE
                                 ? enif_make_uint64(env, (ErlNifUInt64)got) : atom_undefined);
        return rc;
    }
}

/*
 * Dirty part of recv: argv = {Peer, Deadline (Erlang monotonic ms; it can
 * be negative), Capacity, CancelGen0, TimeoutMs (UINT32_MAX = no deadline)}.
 * Waits at most EP_RECV_SLICE_MS, then re-schedules itself so the dirty
 * scheduler is shared.
 */
static ERL_NIF_TERM nif_peer_recv_wait(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ep_peer *p;
    ErlNifSInt64 deadline;
    ErlNifUInt64 cap;
    unsigned gen0, gen, timeout;
    polycall_peer_t h;
    uint32_t slice = EP_RECV_SLICE_MS;
    ERL_NIF_TERM out = atom_undefined;
    int state, rc;

    if (argc != 5 || !get_peer(env, argv[0], &p) || !enif_get_int64(env, argv[1], &deadline) ||
        !enif_get_uint64(env, argv[2], &cap) || !enif_get_uint(env, argv[3], &gen0) ||
        !enif_get_uint(env, argv[4], &timeout)) {
        return enif_make_badarg(env);
    }
    enif_mutex_lock(g_state_mu);
    state = p->state;
    gen = p->cancel_gen;
    h = p->handle;
    enif_mutex_unlock(g_state_mu);
    if (state != EP_OPEN) {
        return err4_msg(env, POLYCALL_E_CLOSED, "peer node closed while waiting", atom_undefined);
    }
    if (gen != gen0) {
        return err4_msg(env, POLYCALL_E_CANCELLED, "receive was cancelled", atom_undefined);
    }
    if (timeout != UINT32_MAX) {
        ErlNifTime now = enif_monotonic_time(ERL_NIF_MSEC);
        ErlNifSInt64 left = deadline > now ? deadline - now : 0;
        if (left < (ErlNifSInt64)slice) slice = (uint32_t)left;
    }

    rc = recv_once(env, h, slice, (size_t)cap, &out);
    if (rc == POLYCALL_E_INVALID_HANDLE) {      /* closed between two slices */
        return err4_msg(env, POLYCALL_E_CLOSED, "peer node closed while waiting", atom_undefined);
    }
    if (rc != POLYCALL_E_TIMEOUT) return out;   /* message, cancelled, closed, ... */

    if (timeout != UINT32_MAX && enif_monotonic_time(ERL_NIF_MSEC) >= deadline) {
        char msg[64];
        snprintf(msg, sizeof msg, "no message within %u ms", timeout);
        return err4_msg(env, POLYCALL_E_TIMEOUT, msg, atom_undefined);
    }
    if (!enif_is_current_process_alive(env)) return atom_undefined;  /* killed */
    return enif_schedule_nif(env, "nif_peer_recv", ERL_NIF_DIRTY_JOB_IO_BOUND,
                             nif_peer_recv_wait, argc, argv);
}

/* recv(Peer, Timeout, Capacity) ->
 *   {ok, Sender, MessageId, Payload} | {error, Code, Detail, NeededOrUndefined}
 * Runs on the caller's normal scheduler only to validate and take the
 * cancel snapshot; the wait happens in nif_peer_recv_wait (dirty). */
static ERL_NIF_TERM nif_peer_recv(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ep_peer *p;
    uint32_t timeout;
    ErlNifUInt64 cap;
    ERL_NIF_TERM wargv[5];
    unsigned gen0;
    int state;
    (void)argc;
    if (!get_peer(env, argv[0], &p) || !get_timeout(env, argv[1], &timeout) ||
        !enif_get_uint64(env, argv[2], &cap) ||
        cap > (ErlNifUInt64)POLYCALL_PEER_MAX_PAYLOAD) {
        return enif_make_badarg(env);
    }
    enif_mutex_lock(g_state_mu);
    state = p->state;
    gen0 = p->cancel_gen;
    enif_mutex_unlock(g_state_mu);
    if (state != EP_OPEN) return closed_err4(env, p);

    wargv[0] = argv[0];
    wargv[1] = enif_make_int64(env, (ErlNifSInt64)enif_monotonic_time(ERL_NIF_MSEC) +
                                    (timeout == UINT32_MAX ? 0 : (ErlNifSInt64)timeout));
    wargv[2] = argv[2];
    wargv[3] = enif_make_uint(env, gen0);
    wargv[4] = enif_make_uint(env, timeout);
    return enif_schedule_nif(env, "nif_peer_recv", ERL_NIF_DIRTY_JOB_IO_BOUND,
                             nif_peer_recv_wait, 5, wargv);
}

/* Wake every recv/3 called on this peer before now (also ones still
 * queued for a dirty scheduler or between two slices). */
static ERL_NIF_TERM nif_peer_cancel(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ep_peer *p;
    polycall_peer_t h;
    int state;
    (void)argc;
    if (!get_peer(env, argv[0], &p)) return enif_make_badarg(env);
    enif_mutex_lock(g_state_mu);
    state = p->state;
    if (state == EP_OPEN) p->cancel_gen++;
    h = p->handle;
    enif_mutex_unlock(g_state_mu);
    if (state != EP_OPEN) return closed_err3(env, p);
    return ok_or_err(env, polycall_peer_cancel(h));   /* wakes waits inside the core */
}

/* ------------------------------------------------------------------------ */
/* load / upgrade / unload                                                   */

static int setup(ErlNifEnv *env)
{
    ErlNifResourceFlags tried;
    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_undefined = enif_make_atom(env, "undefined");
    atom_null = enif_make_atom(env, "null");
    atom_infinity = enif_make_atom(env, "infinity");

    g_peer_type = enif_open_resource_type(env, NULL, "polycall_peer", peer_dtor,
                                          ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, &tried);
    if (!g_peer_type) return 1;
    if (!g_state_mu) g_state_mu = enif_mutex_create("polycall_peer_state");
    if (!g_q_mu) g_q_mu = enif_mutex_create("polycall_closer_queue");
    if (!g_q_cv) g_q_cv = enif_cond_create("polycall_closer_cv");
    if (!g_state_mu || !g_q_mu || !g_q_cv) return 2;
    if (!g_closer_started) {
        g_q_stop = 0;
        if (enif_thread_create("polycall_closer", &g_closer, closer_main, NULL, NULL) != 0) {
            return 3;
        }
        g_closer_started = 1;
    }
    return 0;
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    (void)priv_data; (void)load_info;
    return setup(env);
}

static int upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data, ERL_NIF_TERM load_info)
{
    (void)priv_data; (void)old_priv_data; (void)load_info;
    return setup(env);
}

static void unload(ErlNifEnv *env, void *priv_data)
{
    int started;
    (void)env; (void)priv_data;
    enif_mutex_lock(g_q_mu);
    started = g_closer_started;
    g_closer_started = 0;           /* later destructors close inline */
    g_q_stop = 1;
    enif_cond_broadcast(g_q_cv);
    enif_mutex_unlock(g_q_mu);
    if (started) enif_thread_join(g_closer, NULL);   /* drains the queue first */
}

#define DIRTY ERL_NIF_DIRTY_JOB_IO_BOUND

static ErlNifFunc nif_functions[] = {
    {"nif_abi_version", 0, nif_abi_version, 0},
    {"nif_version", 0, nif_version, 0},
    {"nif_strerror", 1, nif_strerror, 0},
    {"nif_run_config", 2, nif_run_config, DIRTY},
    {"nif_describe", 1, nif_describe, DIRTY},
    {"nif_call", 5, nif_call, DIRTY},
    {"nif_peer_open", 3, nif_peer_open, DIRTY},
    {"nif_peer_close", 1, nif_peer_close, DIRTY},
    {"nif_peer_handle", 1, nif_peer_handle, 0},
    {"nif_peer_endpoint", 1, nif_peer_endpoint, 0},
    {"nif_peer_node_id", 1, nif_peer_node_id, 0},
    {"nif_peer_register", 3, nif_peer_register, 0},
    {"nif_peer_unregister", 2, nif_peer_unregister, 0},
    {"nif_peer_list", 1, nif_peer_list, 0},
    {"nif_peer_health", 1, nif_peer_health, 0},
    {"nif_peer_ping", 3, nif_peer_ping, DIRTY},
    {"nif_peer_send", 5, nif_peer_send, DIRTY},
    /* validates + takes the cancel snapshot, then waits dirty in slices */
    {"nif_peer_recv", 3, nif_peer_recv, 0},
    {"nif_peer_cancel", 1, nif_peer_cancel, 0}
};

ERL_NIF_INIT(erlang_polycall_nif, nif_functions, load, NULL, upgrade, unload)
