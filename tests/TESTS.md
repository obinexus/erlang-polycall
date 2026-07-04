# Erlang tests

The native test verifies exact path, `run=1`, and status forwarding without
requiring OTP. When OTP is installed, `make test-erlang` builds a mock NIF and
verifies Erlang binary/list paths, result tuples, and exception behavior.
