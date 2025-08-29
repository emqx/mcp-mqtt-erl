%%--------------------------------------------------------------------
%% Copyright (c) 2017-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(mcp_mqtt_erl_server_session).
-feature(maybe_expr, enable).

-include("mcp_mqtt_erl_errors.hrl").
-include("mcp_mqtt_erl_types.hrl").
-include("mcp_mqtt_erl.hrl").

-export_type([
    t/0
]).

-export([
    maybe_call/3,
    maybe_call/4
]).

-export([
    init/4,
    destroy/1,
    handle_rpc_msg/2,
    handle_rpc_timeout/2,
    send_client_request/3
]).

-type t() :: #{
    mod := module(),
    state := created | initialized,
    protocol_version := binary(),
    client_info := map(),
    client_capabilities := map(),
    server_id := binary(),
    server_name := binary(),
    mcp_client_id := binary(),
    loop_data := map(),
    pending_requests := pending_requests(),
    client_roots => [map()]
}.

-type server_info() :: #{
    server_id := binary(),
    server_name := binary(),
    presence_params := #{
        _ => _
    }
}.

-type pending_requests() :: #{
    integer() => #{
        method := binary(),
        caller := pid(),
        timestamp := integer()
    }
}.

-type error_details() :: #{
    reason := term(),
    _ => _
}.

-type loop_data() :: any().

-callback client_name() -> binary().
-callback client_version() -> binary().
-callback client_capabilities() -> map().

-callback initialize(ServerId :: binary(), client_params()) ->
    {ok, loop_data()} | {error, error_response()}.

-define(MAX_PAGE_SIZE, 10).
-define(LOG_T(LEVEL, REPORT), logger:log(LEVEL, maps:put(tag, "MCP_SERVER_SESSION", REPORT))).

-spec maybe_call(module(), atom(), [term()], Default :: term()) -> Default :: term().
maybe_call(Mod, Fun, Args) ->
    Arity = length(Args),
    case erlang:function_exported(Mod, Fun, Arity) of
        true ->
            apply(Mod, Fun, Args);
        false ->
            {error, #{
                code => ?ERR_C_NOT_IMPLEMENTED_METHOD,
                message => <<"Method not implemented">>,
                data => #{module => Mod, function => Fun, arg_num => Arity}
            }}
    end.
maybe_call(Mod, Fun, Args, Default) ->
    case erlang:function_exported(Mod, Fun, length(Args)) of
        true -> apply(Mod, Fun, Args);
        false -> Default
    end.

-spec init(binary(), module(), binary(), server_info()) -> {ok, t()} | {error, error_details()}.
init(
    MqttClient,
    Mod,
    McpClientId,
    _ServerInfo = #{
        server_id := ServerId,
        server_name := ServerName,
        presence_params := PresenceParams
    }
) ->
    Capabilities = Mod:client_capabilities(),
    ClientInfo = #{<<"name">> => Mod:client_name(), <<"version">> => Mod:client_version()},
    maybe
        {ok, ServerParams} ?=
            verify_server_precense_params(PresenceParams),
        %% send initialize request to server
        Initialize = mcp_mqtt_erl_msg:initialize_request(
            ClientInfo, Capabilities
        ),
        Info = #{
            mcp_client_id => McpClientId,
            server_id => ServerId,
            server_name => ServerName
        },
        ok = subscribe_session_topics(MqttClient, Info),
        ok ?=
            mcp_mqtt_erl_msg:publish_mcp_client_message(
                MqttClient, ServerId, ServerName, McpClientId, rpc, #{}, Initialize
            ),
        {ok, ServerParams#{
            state => created,
            mqtt_client => MqttClient,
            mod => Mod,
            server_id => ServerId,
            server_name => ServerName,
            mcp_client_id => McpClientId,
            pending_requests => #{}
        }}
    else
        {error, _} = Err ->
            Err
    end.

-spec destroy(t()) -> ok.
destroy(#{mqtt_client := MqttClient} = Session) ->
    %% unsubscribe topics
    unsubscribe_session_topics(MqttClient, Session).

subscribe_session_topics(MqttClient, Info) ->
    ServerCapaTopic = mcp_mqtt_erl_msg:get_topic(server_capability_changed, Info),
    RpcTopic = mcp_mqtt_erl_msg:get_topic(rpc, Info),
    ok = mcp_mqtt_erl_msg:subscribe_topic(MqttClient, ServerCapaTopic, #{}),
    ok = mcp_mqtt_erl_msg:subscribe_topic(MqttClient, RpcTopic, #{nl => true}).

unsubscribe_session_topics(MqttClient, Info) ->
    ServerCapaTopic = mcp_mqtt_erl_msg:get_topic(server_capability_changed, Info),
    RpcTopic = mcp_mqtt_erl_msg:get_topic(rpc, Info),
    ok = mcp_mqtt_erl_msg:unsubscribe_topic(MqttClient, ServerCapaTopic),
    ok = mcp_mqtt_erl_msg:unsubscribe_topic(MqttClient, RpcTopic).

send_client_request(Session, Caller, #{method := <<"ping">>} = Req) ->
    do_send_client_request(Session, Caller, Req);
send_client_request(#{state := initialized} = Session, Caller, Req) ->
    do_send_client_request(Session, Caller, Req);
send_client_request(Session, Caller, Req) ->
    maybe_reply_to_caller(
        Session, Caller, Req, {error, #{reason => ?ERR_NOT_INITIALIZED, request => Req}}
    ).

do_send_client_request(
    #{pending_requests := Pendings, timers := Timers, server_name := ServerName} = Session,
    Caller,
    #{id := ReqId, method := Method, params := Params}
) ->
    Payload = mcp_mqtt_erl_msg:json_rpc_request(ReqId, Method, Params),
    case publish_mcp_client_message(Session, rpc, #{}, Payload) of
        ok ->
            Pendings1 = Pendings#{
                ReqId => #{method => Method, timestamp => ts_now(), caller => Caller}
            },
            Timers1 = Timers#{ReqId => start_rpc_timer(ServerName, ReqId)},
            {ok, Session#{pending_requests => Pendings1, timers := Timers1}};
        {error, _} = Err ->
            Err
    end.

handle_rpc_msg(Session, #{type := json_rpc_notification, method := Method, params := Params}) ->
    handle_json_rpc_notification(Session, Method, Params);
handle_rpc_msg(Session, #{type := json_rpc_response, id := ReqId, result := Result}) ->
    handle_json_rpc_response(Session, ReqId, Result);
handle_rpc_msg(Session, #{type := json_rpc_error, id := ReqId, error := Error}) ->
    handle_json_rpc_error(Session, ReqId, Error);
handle_rpc_msg(_Session, Msg) ->
    {error, #{reason => ?ERR_MALFORMED_JSON_RPC, message => Msg}}.

handle_json_rpc_error(#{pending_requests := Pendings0, timers := Timers} = Session, ReqId, ErrMsg) ->
    case maps:take(ReqId, Pendings0) of
        {#{caller := Caller} = PendingReq, Pendings} ->
            {TRef, Timers1} = maps:take(ReqId, Timers),
            _ = erlang:cancel_timer(TRef),
            Session1 = maybe_reply_to_caller(
                Session,
                Caller,
                PendingReq,
                {error, #{reason => mcp_rpc_error, error_msg => ErrMsg}}
            ),
            {ok, Session1#{pending_requests => Pendings, timers := Timers1}};
        {_, Pendings} ->
            {TRef, Timers1} = maps:take(ReqId, Timers),
            _ = erlang:cancel_timer(TRef),
            ?LOG_T(error, #{msg => no_caller_to_reply, id => ReqId}),
            {ok, Session#{pending_requests => Pendings, timers := Timers1}};
        error ->
            {terminated, #{reason => ?ERR_WRONG_RPC_ID}}
    end.

handle_rpc_timeout(#{pending_requests := Pendings0, timers := Timers} = Session, ReqId) ->
    case maps:take(ReqId, Pendings0) of
        {#{caller := Caller}, Pendings} ->
            gen_statem:reply(Caller, {error, #{reason => ?ERR_TIMEOUT}}),
            {ok, Session#{pending_requests => Pendings, timers := maps:remove(ReqId, Timers)}};
        {_, Pendings} ->
            ?LOG_T(error, #{msg => no_caller_to_reply, id => ReqId}),
            {ok, Session#{pending_requests => Pendings, timers := maps:remove(ReqId, Timers)}};
        error ->
            {terminated, #{reason => ?ERR_WRONG_RPC_ID}}
    end.

%%==============================================================================
%% Handle JSON-RPC requests/responses/notifications
%%==============================================================================

handle_json_rpc_notification(Session, <<"notifications/disconnected">>, _) ->
    ?LOG_T(info, #{msg => server_disconnected, server_name => maps:get(server_name, Session)}),
    {terminated, server_disconnected}.

handle_json_rpc_response(
    #{pending_requests := Pendings0, timers := Timers} = Session, ReqId, Result
) ->
    case maps:take(ReqId, Pendings0) of
        {#{caller := Caller} = PendingReq, Pendings} ->
            {TRef, Timers1} = maps:take(ReqId, Timers),
            _ = erlang:cancel_timer(TRef),
            Session1 = maybe_reply_to_caller(Session, Caller, PendingReq, {ok, Result}),
            {ok, Session1#{pending_requests => Pendings, timers := Timers1}};
        {_, Pendings} ->
            {TRef, Timers1} = maps:take(ReqId, Timers),
            _ = erlang:cancel_timer(TRef),
            ?LOG_T(error, #{msg => no_caller_to_reply, id => ReqId}),
            {ok, Session#{pending_requests => Pendings, timers := Timers1}};
        error ->
            {terminated, #{reason => ?ERR_WRONG_RPC_ID}}
    end.

%%==============================================================================
%% Internal Functions
%%==============================================================================
publish_mcp_client_message(Session, TopicType, Flags, Payload) ->
    MqttClient = maps:get(mqtt_client, Session),
    ServerId = maps:get(server_id, Session),
    ServerName = maps:get(server_name, Session),
    McpClientId = maps:get(mcp_client_id, Session),
    mcp_mqtt_erl_msg:publish_mcp_client_message(
        MqttClient, ServerId, ServerName, McpClientId, TopicType, Flags, Payload
    ).

verify_server_precense_params(Params) ->
    maybe
        {ok, Description} ?= maps:find(<<"description">>, Params),
        {ok, Meta} ?= maps:find(<<"meta">>, Params),
        {ok, #{
            description => Description,
            client_capabilities => Meta
        }}
    else
        error ->
            {error, #{
                reason => ?ERR_REQUIRED_FILED_MISSING,
                required_fields => [<<"description">>, <<"meta">>]
            }}
    end.

maybe_reply_to_caller(Session, Caller, _, Result) ->
    gen_statem:reply(Caller, Result),
    Session.

start_rpc_timer(ServerName, ReqId) ->
    erlang:send_after(?RPC_TIMEOUT, self(), {rpc_request_timeout, ServerName, ReqId}).

ts_now() ->
    erlang:system_time(microsecond).
