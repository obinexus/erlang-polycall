#include "erlang_polycall.h"

#include <erl_nif.h>

#include <string.h>

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_out_of_memory;

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    (void)priv_data;
    (void)load_info;

    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_out_of_memory = enif_make_atom(env, "out_of_memory");
    return 0;
}

static ERL_NIF_TERM nif_run_config(
    ErlNifEnv *env,
    int argc,
    const ERL_NIF_TERM argv[]
) {
    ErlNifBinary path;
    char *config_path;
    int status;

    if (argc != 1 || !enif_inspect_iolist_as_binary(env, argv[0], &path)) {
        return enif_make_badarg(env);
    }
    if (memchr(path.data, '\0', path.size) != NULL) {
        return enif_make_badarg(env);
    }
    if (path.size == (size_t)-1) {
        return enif_make_tuple2(env, atom_error, atom_out_of_memory);
    }

    config_path = enif_alloc(path.size + 1);
    if (!config_path) {
        return enif_make_tuple2(env, atom_error, atom_out_of_memory);
    }

    memcpy(config_path, path.data, path.size);
    config_path[path.size] = '\0';
    status = erlang_polycall_run_config(config_path);
    enif_free(config_path);

    return enif_make_tuple2(
        env,
        status == 0 ? atom_ok : atom_error,
        enif_make_int(env, status));
}

static ErlNifFunc nif_functions[] = {
    {"run_config", 1, nif_run_config, ERL_NIF_DIRTY_JOB_IO_BOUND}
};

ERL_NIF_INIT(erlang_polycall, nif_functions, load, NULL, NULL, NULL)
