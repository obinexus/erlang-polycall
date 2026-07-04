CC ?= gcc
AR ?= ar
ERL ?= erl
ERLC ?= erlc

CPPFLAGS ?=
CPPFLAGS += -Iinclude -Igenerated
CFLAGS ?= -O2
CFLAGS += -std=c11 -Wall -Wextra -Wpedantic
NIF_CFLAGS ?= -fPIC
ERL_INCLUDE ?= $(shell $(ERL) -noshell -eval "io:format(\"~s\", [filename:join([code:root_dir(), \"erts-\" ++ erlang:system_info(version), \"include\"])]), halt()." 2>NUL)

BUILD_DIR := build
EBIN_DIR := ebin
LIB_DIR := lib
PRIV_DIR := priv
ADAPTER_OBJ := $(BUILD_DIR)/erlang_polycall.o
STATIC_LIB := $(LIB_DIR)/liberlang_polycall.a
TEST_BIN := $(BUILD_DIR)/erlang_polycall_adapter_test

ifeq ($(OS),Windows_NT)
EXE_EXT := .exe
NIF_EXT := .dll
TEST_BIN := $(TEST_BIN)$(EXE_EXT)
else
EXE_EXT :=
NIF_EXT := .so
endif

NIF_LIB := $(PRIV_DIR)/erlang_polycall_nif$(NIF_EXT)

.DEFAULT_GOAL := all

.PHONY: all
all: $(STATIC_LIB)

$(BUILD_DIR) $(EBIN_DIR) $(LIB_DIR) $(PRIV_DIR):
ifeq ($(OS),Windows_NT)
	@if not exist "$@" mkdir "$@"
else
	@mkdir -p $@
endif

$(ADAPTER_OBJ): c_src/erlang_polycall.c include/erlang_polycall.h generated/polycall/polycall_ffi.h | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@

$(STATIC_LIB): $(ADAPTER_OBJ) | $(LIB_DIR)
	$(AR) rcs $@ $^

$(TEST_BIN): c_src/erlang_polycall.c tests/polycall_ffi_mock.c tests/erlang_polycall_adapter_test.c | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) -Itests $(CFLAGS) $^ -o $@

.PHONY: test
test: $(TEST_BIN)
	$(TEST_BIN)

.PHONY: nif
nif: | $(PRIV_DIR) $(EBIN_DIR)
ifeq ($(OS),Windows_NT)
	@if "$(strip $(ERL_INCLUDE))"=="" (echo ERL_INCLUDE could not be detected; install Erlang or set it explicitly & exit /b 2)
	@if "$(strip $(POLYCALL_LDFLAGS))"=="" (echo Set POLYCALL_LDFLAGS to the libpolycall v1.5 linker flags & exit /b 2)
else
	@test -n "$(ERL_INCLUDE)" || (echo "Install Erlang or set ERL_INCLUDE explicitly" && exit 2)
	@test -n "$(POLYCALL_LDFLAGS)" || (echo "Set POLYCALL_LDFLAGS to the libpolycall v1.5 linker flags" && exit 2)
endif
	$(CC) $(CPPFLAGS) -I"$(ERL_INCLUDE)" $(CFLAGS) $(NIF_CFLAGS) -shared \
		c_src/erlang_polycall.c c_src/erlang_polycall_nif.c \
		$(POLYCALL_LDFLAGS) -o $(NIF_LIB)
	$(ERLC) -o $(EBIN_DIR) src/erlang_polycall.erl
ifeq ($(OS),Windows_NT)
	@copy /Y src\erlang_polycall.app.src ebin\erlang_polycall.app >NUL
else
	cp src/erlang_polycall.app.src ebin/erlang_polycall.app
endif

.PHONY: test-erlang
test-erlang: test | $(PRIV_DIR) $(EBIN_DIR)
ifeq ($(OS),Windows_NT)
	@if "$(strip $(ERL_INCLUDE))"=="" (echo ERL_INCLUDE could not be detected; install Erlang or set it explicitly & exit /b 2)
else
	@test -n "$(ERL_INCLUDE)" || (echo "Install Erlang or set ERL_INCLUDE explicitly" && exit 2)
endif
	$(CC) $(CPPFLAGS) -Itests -I"$(ERL_INCLUDE)" $(CFLAGS) $(NIF_CFLAGS) -shared \
		c_src/erlang_polycall.c c_src/erlang_polycall_nif.c \
		tests/polycall_ffi_mock.c -o $(NIF_LIB)
	$(ERLC) -o $(EBIN_DIR) src/erlang_polycall.erl tests/erlang_polycall_smoke.erl
	$(ERL) -noshell -pa $(EBIN_DIR) \
		-eval "erlang_polycall_smoke:main(), halt(0)."

.PHONY: verify-dry
verify-dry:
ifeq ($(OS),Windows_NT)
	powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-dry.ps1
else
	sh scripts/verify-dry.sh
endif

.PHONY: clean
clean:
ifeq ($(OS),Windows_NT)
	@if exist "$(BUILD_DIR)" rmdir /s /q "$(BUILD_DIR)"
	@if exist "$(EBIN_DIR)" rmdir /s /q "$(EBIN_DIR)"
	@if exist "$(LIB_DIR)" rmdir /s /q "$(LIB_DIR)"
	@if exist "$(PRIV_DIR)" rmdir /s /q "$(PRIV_DIR)"
else
	rm -rf $(BUILD_DIR) $(EBIN_DIR) $(LIB_DIR) $(PRIV_DIR)
endif

-include $(ADAPTER_OBJ:.o=.d)
