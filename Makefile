# erlang-polycall -- Erlang NIF over the Polycall binding ABI v1.
#
#   make nif            build priv/erlang_polycall_nif.so against libpolycall
#                       (flags from `pkg-config polycall`)
#   make beams          compile the Erlang modules into ebin/ (without rebar3)
#   make test           adapter unit test (mock core) + EUnit against the REAL
#                       library (rebar3 eunit); a missing toolchain is a SKIP
#                       (exit 77), never a pass
#   make test-adapter   only the C adapter unit test (mock core, labelled)
#   make test-asan      NIF with ASan + UBSan (scripts/test-memory.sh asan)
#   make test-valgrind  memcheck in OTP's valgrind emulator
#   make test-package   npm pack -> clean install -> build + run the NIF
#
# Override POLYCALL_CFLAGS / POLYCALL_LIBS instead of pkg-config if needed.

CC ?= cc
ERL ?= erl
ERLC ?= erlc
REBAR3 ?= rebar3
PKG_CONFIG ?= pkg-config

ifeq ($(OS),Windows_NT)
NULL_DEVICE := NUL
NIF_EXT := .dll
EXE_EXT := .exe
else
NULL_DEVICE := /dev/null
NIF_EXT := .so
EXE_EXT :=
UNAME_S := $(shell uname -s)
endif

ERL_INCLUDE ?= $(shell $(ERL) -noshell -eval "io:format(\"~s\", [filename:join([code:root_dir(), \"erts-\" ++ erlang:system_info(version), \"include\"])]), halt()." 2>$(NULL_DEVICE))
POLYCALL_CFLAGS ?= $(shell $(PKG_CONFIG) --cflags polycall 2>$(NULL_DEVICE))
POLYCALL_LIBS ?= $(shell $(PKG_CONFIG) --libs polycall 2>$(NULL_DEVICE))

CPPFLAGS += -Iinclude
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra -Wpedantic
NIF_CFLAGS ?= -fPIC
NIF_LDFLAGS ?= -shared
ifeq ($(UNAME_S),Darwin)
NIF_LDFLAGS += -undefined dynamic_lookup
endif

BUILD_DIR := build
EBIN_DIR := ebin
PRIV_DIR := priv
NIF_LIB := $(PRIV_DIR)/erlang_polycall_nif$(NIF_EXT)
ADAPTER_TEST := $(BUILD_DIR)/erlang_polycall_adapter_test$(EXE_EXT)
NIF_SOURCES := c_src/erlang_polycall.c c_src/erlang_polycall_nif.c

.DEFAULT_GOAL := all

.PHONY: all
all: nif

$(BUILD_DIR) $(EBIN_DIR) $(PRIV_DIR):
	@mkdir -p $@

.PHONY: check-polycall
check-polycall:
	@test -n "$(strip $(POLYCALL_LIBS))" || { echo "libpolycall not found: install polycall >= 1.1.0 (pkg-config polycall) or set POLYCALL_CFLAGS/POLYCALL_LIBS" >&2; exit 2; }

.PHONY: check-erts
check-erts:
	@test -n "$(strip $(ERL_INCLUDE))" || { echo "Erlang/OTP not found: install it or set ERL_INCLUDE" >&2; exit 2; }

.PHONY: nif
nif: $(NIF_LIB)

$(NIF_LIB): $(NIF_SOURCES) include/erlang_polycall.h | $(PRIV_DIR)
	@$(MAKE) --no-print-directory check-erts check-polycall
	$(CC) $(CPPFLAGS) -I"$(ERL_INCLUDE)" $(POLYCALL_CFLAGS) $(CFLAGS) $(NIF_CFLAGS) \
		$(NIF_SOURCES) $(NIF_LDFLAGS) $(POLYCALL_LIBS) $(LDFLAGS) -o $@

.PHONY: beams
beams: nif | $(EBIN_DIR)
	$(ERLC) -I include -o $(EBIN_DIR) src/*.erl
	cp src/erlang_polycall.app.src $(EBIN_DIR)/erlang_polycall.app

# Adapter unit test: c_src/erlang_polycall.c against a MOCK of
# polycall_ffi_run_config (tests/polycall_ffi_mock.c). Not a core test.
$(ADAPTER_TEST): c_src/erlang_polycall.c tests/polycall_ffi_mock.c tests/erlang_polycall_adapter_test.c | $(BUILD_DIR)
	@$(MAKE) --no-print-directory check-polycall
	$(CC) $(CPPFLAGS) -Itests $(POLYCALL_CFLAGS) $(CFLAGS) $^ -o $@

.PHONY: test-adapter
test-adapter: $(ADAPTER_TEST)
	$(ADAPTER_TEST)

.PHONY: test-eunit
test-eunit: nif
	@command -v $(REBAR3) >/dev/null 2>&1 || { echo "SKIP: rebar3 not found; EUnit tests against libpolycall did not run" >&2; exit 77; }
	$(REBAR3) eunit

.PHONY: test
test: test-adapter test-eunit

.PHONY: test-asan test-valgrind test-package
test-asan:
	sh scripts/test-memory.sh asan
test-valgrind:
	sh scripts/test-memory.sh valgrind
test-package:
	sh scripts/test-package.sh

.PHONY: verify-dry
verify-dry:
ifeq ($(OS),Windows_NT)
	powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-dry.ps1
else
	sh scripts/verify-dry.sh
endif

.PHONY: clean
clean:
	rm -rf $(BUILD_DIR) $(EBIN_DIR) $(PRIV_DIR) _build

