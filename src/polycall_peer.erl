%% Polycall peer node (polycall_peer_* of the binding ABI v1;
%% wire protocol polycall-peer/1).
%%
%% A peer is an opaque NIF resource. Dropping the last reference closes the
%% node (on a background thread); close/1 closes it at once. The core handle
%% is closed exactly once: double close and use after close are defined,
%% {error, #polycall_error{reason = invalid_handle}}.
%% Blocking calls (open, close, ping, send, recv) run on dirty I/O
%% schedulers. recv waits there in slices of at most 200 ms and yields in
%% between, so any number of receivers waiting with infinity never starve
%% file I/O or code loading, and a killed receiver frees its scheduler.
%% ping/send block for at most their timeout.
%%
%% Ids, endpoints, tokens and message ids are text (string or UTF-8 binary,
%% see erlang_polycall:text/1); payloads are raw iodata, sent byte for byte.
-module(polycall_peer).

-include("erlang_polycall.hrl").

-export([
    open/1, open/2, close/1,
    endpoint/1, node_id/1,
    register/3, unregister/2, list/1,
    ping/2, ping/3,
    send/3, send/4,
    recv/1, recv/2, recv/3,
    cancel/1, health/1,
    handle/1
]).

-opaque peer() :: reference().
-type id() :: unicode:chardata().
-type target() :: unicode:chardata().     %% registered id or "host:port"
%% milliseconds, 0..4294967295 (4294967295 = infinity); larger is badarg
-type timeout_ms() :: 0..4294967295 | infinity.
-type open_opts() :: #{bind => unicode:chardata() | undefined,
                       token => unicode:chardata() | undefined}.
-type send_opts() :: #{message_id => unicode:chardata() | undefined, timeout => timeout_ms()}.
-type message() :: #{sender := binary(), message_id := binary(), payload := binary()}.
-type error() :: {error, #polycall_error{}}.

-export_type([peer/0, message/0, open_opts/0, send_opts/0]).

-define(DEFAULT_BIND, <<"127.0.0.1:0">>).
-define(DEFAULT_TIMEOUT, 5000).

%% @doc Open a node listening on 127.0.0.1 with an ephemeral port, no token.
-spec open(id()) -> {ok, peer()} | error().
open(NodeId) ->
    open(NodeId, #{}).

%% @doc Open a node. bind => "host:port" (port 0 = ephemeral; default
%% "127.0.0.1:0"), or undefined for a send-only node. token => shared secret
%% (undefined/"" = no authentication). A non-loopback bind needs a token.
-spec open(id(), open_opts()) -> {ok, peer()} | error().
open(NodeId, Opts) when is_map(Opts) ->
    Bind = maps:get(bind, Opts, ?DEFAULT_BIND),
    Token = maps:get(token, Opts, undefined),
    wrap(erlang_polycall:nif(nif_peer_open, [text(NodeId), text(Bind), text(Token)])).

%% @doc Stop the listener, wake blocked receivers ({error, closed}).
-spec close(peer()) -> ok | error().
close(Peer) ->
    wrap(erlang_polycall:nif(nif_peer_close, [Peer])).

%% @doc Bound "host:port" (<<>> for a send-only node).
-spec endpoint(peer()) -> {ok, binary()} | error().
endpoint(Peer) ->
    wrap(erlang_polycall:nif(nif_peer_endpoint, [Peer])).

-spec node_id(peer()) -> {ok, binary()} | error().
node_id(Peer) ->
    wrap(erlang_polycall:nif(nif_peer_node_id, [Peer])).

%% @doc Add or replace Id -> Endpoint in THIS node's registry.
-spec register(peer(), id(), iodata()) -> ok | error().
register(Peer, Id, Endpoint) ->
    wrap(erlang_polycall:nif(nif_peer_register, [Peer, text(Id), text(Endpoint)])).

%% @doc Remove Id ({error, #polycall_error{reason = not_found}} if absent).
-spec unregister(peer(), id()) -> ok | error().
unregister(Peer, Id) ->
    wrap(erlang_polycall:nif(nif_peer_unregister, [Peer, text(Id)])).

%% @doc THIS node's registry as JSON text {"id":"host:port",...}.
-spec list(peer()) -> {ok, binary()} | error().
list(Peer) ->
    wrap(erlang_polycall:nif(nif_peer_list, [Peer])).

-spec ping(peer(), target()) -> ok | error().
ping(Peer, Target) ->
    ping(Peer, Target, ?DEFAULT_TIMEOUT).

%% @doc GET /health on Target; ok only when it answers healthy (and, for a
%% registered id, under that id).
-spec ping(peer(), target(), timeout_ms()) -> ok | error().
ping(Peer, Target, Timeout) ->
    wrap(erlang_polycall:nif(nif_peer_ping, [Peer, text(Target), Timeout])).

-spec send(peer(), target(), iodata()) -> ok | error().
send(Peer, Target, Payload) ->
    send(Peer, Target, Payload, #{}).

%% @doc Deliver Payload (binary-safe, at most 1 MiB) with exactly one
%% delivery attempt. ok means the receiver stored and acknowledged it.
%% Retry with the same message_id after {error, timeout|transport|busy}:
%% the receiver drops duplicates.
-spec send(peer(), target(), iodata(), send_opts()) -> ok | error().
send(Peer, Target, Payload, Opts) when is_map(Opts) ->
    MessageId = maps:get(message_id, Opts, undefined),
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    wrap(erlang_polycall:nif(nif_peer_send, [Peer, text(Target), Payload, text(MessageId), Timeout])).

%% @doc Wait (indefinitely) for the next message, or cancel/1 / close/1.
-spec recv(peer()) -> {ok, message()} | error().
recv(Peer) ->
    recv(Peer, infinity).

%% @doc Take the oldest message; Timeout 0 polls, infinity waits until a
%% message, cancel/1 ({error, cancelled}) or close/1 ({error, closed}).
%% The default payload buffer is 1 MiB (the protocol maximum), so every
%% message fits; no buffer is allocated while waiting.
-spec recv(peer(), timeout_ms()) -> {ok, message()} | error().
recv(Peer, Timeout) ->
    recv(Peer, Timeout, ?POLYCALL_PEER_MAX_PAYLOAD).

%% @doc As recv/2 with a payload buffer of MaxPayload bytes (0..1048576;
%% larger is badarg). A larger message gives
%% {error, #polycall_error{reason = too_large, info = Needed}} and stays queued.
-spec recv(peer(), timeout_ms(), 0..1048576) -> {ok, message()} | error().
recv(Peer, Timeout, MaxPayload) ->
    wrap(erlang_polycall:nif(nif_peer_recv, [Peer, Timeout, MaxPayload])).

%% @doc Wake every recv/2,3 called on Peer before this call (waiting, or
%% still queued for a dirty scheduler) with {error, cancelled}. Later calls
%% wait normally.
-spec cancel(peer()) -> ok | error().
cancel(Peer) ->
    wrap(erlang_polycall:nif(nif_peer_cancel, [Peer])).

%% @doc This node's health as JSON text.
-spec health(peer()) -> {ok, binary()} | error().
health(Peer) ->
    wrap(erlang_polycall:nif(nif_peer_health, [Peer])).

%% @doc The core's integer handle (diagnostics only).
-spec handle(peer()) -> integer().
handle(Peer) ->
    erlang_polycall:nif(nif_peer_handle, [Peer]).

%%% internal

text(T) -> erlang_polycall:text(T).

wrap(ok) -> ok;
wrap({ok, Sender, MessageId, Payload}) ->
    {ok, #{sender => Sender, message_id => MessageId, payload => Payload}};
wrap({ok, Value}) -> {ok, Value};
wrap({error, Code, Detail}) ->
    {error, erlang_polycall:error_from(Code, Detail, undefined)};
wrap({error, Code, Detail, Info}) ->
    {error, erlang_polycall:error_from(Code, Detail, Info)}.
