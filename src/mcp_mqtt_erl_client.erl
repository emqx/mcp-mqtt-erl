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

-module(mcp_mqtt_erl_client).

-feature(maybe_expr, enable).
-include("mcp_mqtt_erl_errors.hrl").
-include("mcp_mqtt_erl_types.hrl").

-behaviour(gen_statem).

%% API
-export([
    start_link/1,
    stop/1,
    process_name/1
]).

-export([
    send_request/3
]).

%% gen_statem callbacks
-export([init/1, callback_mode/0, terminate/3, code_change/4]).

%% gen_statem state functions
-export([idle/3, connected/3]).

-export_type([config/0]).

-type state_name() :: idle | connected.

-type mcp_client_id() :: binary().
-type server_name() :: binary().

-type broker_address() :: {emqtt:host(), integer()} | local.

-type config() :: #{
    broker_address := broker_address(),
    callback_mod := module(),
    mqtt_options => map()
}.

-type session() :: mcp_mqtt_erl_client_session:t().

-type sessions() ::
    #{
        mcp_client_id() => session()
    }
    | #{}.

-type loop_data() :: #{
    server_id := binary(),
    server_name := binary(),
    callback_mod := module(),
    mqtt_options => map(),
    mqtt_client => pid() | local,
    sessions => sessions()
}.

-type client_request() ::
    ping
    | list_tools
    | call_tool.

-define(LOG_T(LEVEL, REPORT), logger:log(LEVEL, maps:put(tag, "MCP_CLIENT", REPORT))).
-define(handle_common, ?FUNCTION_NAME(T, C, D) -> handle_common(?FUNCTION_NAME, T, C, D)).
-define(log_enter_state(OldState),
    ?LOG_T(debug, #{msg => enter_state, state => ?FUNCTION_NAME, previous => OldState})
).
-define(REQUEST_TIMEOUT, 15_000).
-define(T_RECONN, 3_000).

%%==============================================================================
%% API
%%==============================================================================
-spec start_link(config()) -> gen_statem:start_ret().
start_link(#{callback_mod := Mod, broker_address := BrokerAddr} = Conf) ->
    MqttOpts = maps:get(mqtt_options, Conf, #{}),
    ClientID = maps:get(clientid, MqttOpts, <<>>),
    ServerNameFilter = maps:get(server_name_filter, Conf, #{}),
    RegisterName = process_name(ClientID),
    gen_statem:start_link({local, RegisterName}, ?MODULE, {BrokerAddr, Mod, ServerNameFilter, MqttOpts}, []).

stop(Pid) ->
    gen_statem:cast(Pid, stop).

process_name(ClientID) ->
    binary_to_atom(<<"mcp_client:", ClientID/binary>>).

-spec send_request(pid(), server_name(), client_request()) -> Reply :: term().
send_request(Pid, ServerName, Req) ->
    gen_statem:call(Pid, {client_request, ServerName, Req}, {clean_timeout, ?REQUEST_TIMEOUT}).

%% gen_statem callbacks
-spec init({broker_address(), module(), binary(), map()}) ->
    {ok, state_name(), loop_data(), [gen_statem:action()]}.
init({BrokerAddr, Mod, ServerNameFilter, MqttOpts}) ->
    process_flag(trap_exit, true),
    ClientID = maps:get(clientid, MqttOpts, <<>>),
    LoopData = #{
        callback_mod => Mod,
        mcp_client_id => ClientID,
        server_name_filter => ServerNameFilter,
        sessions => #{}
    },
    case BrokerAddr of
        local ->
            %% Local mode, no need to connect to MQTT broker
            {ok, connected, LoopData#{mqtt_client => local}, []};
        {Host, Port} ->
            WillTopic = mcp_mqtt_erl_msg:get_topic(
                client_presence,
                #{mcp_client_id => ClientID}
            ),
            MqttOpts1 = MqttOpts#{
                host => Host,
                port => Port,
                proto_ver => v5,
                clientid => ClientID,
                will_topic => WillTopic,
                will_payload => <<>>,
                will_retain => true,
                will_qos => 0,
                clean_start => true
            },
            {ok, idle, LoopData#{mqtt_options => maps:remove(clientid_prefix, MqttOpts1)}, [
                {next_event, internal, connect_broker}
            ]}
    end.

callback_mode() ->
    [state_functions, state_enter].

-spec idle(enter | gen_statem:event_type(), state_name(), loop_data()) ->
    gen_statem:state_enter_result(state_name(), loop_data())
    | gen_statem:event_handler_result(state_name(), loop_data()).
idle(enter, _OldState, _LoopData) ->
    {keep_state_and_data, []};
idle(internal, connect_broker, LoopData) ->
    connect_broker(LoopData);
idle(state_timeout, connect_broker, LoopData) ->
    connect_broker(LoopData);
?handle_common.

-spec connected(enter | gen_statem:event_type(), state_name(), loop_data()) ->
    gen_statem:state_enter_result(state_name(), loop_data())
    | gen_statem:event_handler_result(state_name(), loop_data()).
connected(enter, OldState, #{
    callback_mod := _Mod, mqtt_client := MqttClient, server_name_filter := ServerNameFilter
}) ->
    ok = mcp_mqtt_erl_msg:subscribe_server_presence_topic(MqttClient, <<"+">>, ServerNameFilter),
    ?log_enter_state(OldState),
    keep_state_and_data;
connected({call, Caller}, {client_request, ServerName, Req}, #{sessions := Sessions} = LoopData) ->
    case maps:find(ServerName, Sessions) of
        {ok, Session} ->
            case mcp_mqtt_erl_client_session:send_client_request(Session, Caller, Req) of
                {ok, Session1} ->
                    %% we will reply the caller in the session
                    {keep_state, LoopData#{sessions => Sessions#{ServerName => Session1}}};
                {error, Reason} ->
                    ?LOG_T(error, #{msg => send_client_request_error, reason => Reason}),
                    {keep_state, LoopData};
                {terminated, Reason} ->
                    ?LOG_T(warning, #{
                        msg => session_terminated_on_send_client_request, reason => Reason
                    }),
                    {keep_state, LoopData#{sessions => destroy_session(ServerName, Sessions)}}
            end;
        error ->
            ?LOG_T(error, #{msg => send_client_request_failed, reason => session_not_found}),
            {keep_state, LoopData}
    end;
connected(
    info,
    {publish, #{topic := <<"$mcp-server/presence/", ServerIdAndName/binary>>, payload := <<>>}},
    #{sessions := Sessions} = LoopData
) ->
    {_ServerId, ServerName} = split_id_and_server_name(ServerIdAndName),
    ?LOG_T(debug, #{msg => remove_session, reason => server_disconnected}),
    {keep_state, LoopData#{sessions => destroy_session(ServerName, Sessions)}};
connected(
    info,
    {publish,
        #{topic := <<"$mcp-server/presence/", ServerIdAndName/binary>>, payload := Payload, properties := Props} = Msg},
    #{callback_mod := Mod, mqtt_client := MqttClient} = LoopData
) ->
    maybe
        ?LOG_T(debug, #{msg => received_server_online_msg, details => Msg}),
        {ServerId, ServerName} = split_id_and_server_name(ServerIdAndName),
        Sessions = maps:get(sessions, LoopData),
        McpClientId = maps:get(mcp_client_id, LoopData),
        {ok, mcp_server} ?= mcp_mqtt_erl_msg:get_mcp_component_type_from_mqtt_props(Props),
        {ok, #{method := <<"notifications/server/online">>, params := Params}} ?=
            mcp_mqtt_erl_msg:decode_rpc_msg(Payload),
        {ok, Sess} ?=
            mcp_mqtt_erl_client_session:init(
                MqttClient,
                Mod,
                McpClientId,
                #{
                    server_id => ServerId,
                    server_name => ServerName,
                    presence_params => Params
                }
            ),
        {keep_state, LoopData#{sessions => Sessions#{ServerName => Sess}}, []}
    else
        {ok, RpcMsg} ->
            ?LOG_T(debug, #{msg => unexpected_rpc_msg, details => RpcMsg}),
            {keep_state, LoopData};
        {error, #{reason := ?ERR_INVALID_JSON}} ->
            ?LOG_T(error, #{msg => non_json_msg, details => Msg}),
            {keep_state, LoopData};
        {error, Reason} ->
            ?LOG_T(error, #{msg => invalid_initialize_msg, details => Msg, reason => Reason}),
            {keep_state, LoopData}
    end;
connected(
    info,
    {publish, #{
        topic := <<"$mcp-rpc/", ClientIdAndServerName/binary>>, payload := Payload
    }},
    #{sessions := Sessions} = LoopData
) ->
    {_McpClientId, ServerIdAndName} = split_id_and_server_name(ClientIdAndServerName),
    {_ServerId, ServerName} = split_id_and_server_name(ServerIdAndName),
    case maps:find(ServerName, Sessions) of
        {ok, Session} ->
            case mcp_mqtt_erl_msg:decode_rpc_msg(Payload) of
                {ok, Msg} ->
                    case mcp_mqtt_erl_client_session:handle_rpc_msg(Session, Msg) of
                        {ok, Session1} ->
                            {keep_state, LoopData#{sessions => Sessions#{ServerName => Session1}}};
                        {error, Reason} ->
                            ?LOG_T(error, #{msg => handle_rpc_msg_failed, reason => Reason}),
                            {keep_state, LoopData};
                        {terminated, client_disconnected} ->
                            {keep_state, LoopData#{sessions => destroy_session(ServerName, Sessions)}};
                        {terminated, Reason} ->
                            ?LOG_T(warning, #{msg => session_terminated_on_rpc_msg, reason => Reason}),
                            {keep_state, LoopData#{sessions => destroy_session(ServerName, Sessions)}}
                    end;
                {error, Reason} ->
                    ?LOG_T(error, #{msg => decode_rpc_msg_failed, reason => Reason}),
                    {keep_state, LoopData}
            end;
        error ->
            ?LOG_T(error, #{msg => handle_rpc_failed, reason => session_not_found, server_name => ServerName}),
            {keep_state, LoopData}
    end;
connected(info, {publish, #{topic := Topic} = Msg}, #{callback_mod := Mod, mqtt_client := MqttClient} = LoopData) ->
    ?LOG_T(warning, #{msg => unsupported_topic, topic => Topic}),
    Mod:received_non_mcp_message(MqttClient, Msg, maps:get(app_state, LoopData, #{})),
    keep_state_and_data;
connected(info, {rpc_request_timeout, ServerName, ReqId}, #{sessions := Sessions} = LoopData) ->
    case maps:find(ServerName, Sessions) of
        {ok, Session} ->
            case mcp_mqtt_erl_client_session:handle_rpc_timeout(Session, ReqId) of
                {ok, Session1} ->
                    {keep_state, LoopData#{sessions => Sessions#{ServerName => Session1}}};
                {terminated, Reason} ->
                    ?LOG_T(warning, #{msg => session_terminated_on_rpc_timeout, reason => Reason}),
                    {keep_state, LoopData#{sessions => destroy_session(ServerName, Sessions)}}
            end;
        error ->
            ?LOG_T(error, #{msg => handle_rpc_timeout_failed, reason => session_not_found}),
            {keep_state, LoopData}
    end;
?handle_common.

terminate(_Reason, connected, #{
    mqtt_client := MqttClient, mcp_client_id := McpClientId
}) ->
    _ = send_client_offline_message(MqttClient, McpClientId);
terminate(_Reason, _State, _LoopData) ->
    ok.

code_change(_OldVsn, State, LoopData, _Extra) ->
    {ok, State, LoopData}.

handle_common(_State, state_timeout, TimeoutReason, _LoopData) ->
    shutdown(#{error => TimeoutReason});
handle_common(_State, info, {'EXIT', MqttClient, Reason}, #{mqtt_client := MqttClient}) ->
    ?LOG_T(error, #{msg => mqtt_client_exit, reason => Reason}),
    shutdown(#{error => Reason});
handle_common(_State, cast, stop, _LoopData) ->
    ?LOG_T(debug, #{msg => stop}),
    shutdown(#{error => normal});
handle_common(State, EventType, EventContent, _LoopData) ->
    ?LOG_T(error, #{
        msg => unexpected_msg,
        state => State,
        event_type => EventType,
        event_content => EventContent
    }),
    keep_state_and_data.

shutdown(ErrObj) ->
    shutdown(ErrObj, []).

shutdown(#{error := normal}, Actions) ->
    {stop, normal, Actions};
shutdown(#{error := Error} = ErrObj, Actions) ->
    ?LOG_T(warning, ErrObj#{msg => shutdown}),
    {stop, {shutdown, Error}, Actions}.

-define(WONT_RETRY_ERR(Reason),
    Reason =:= protocol_error;
    Reason =:= unsupported_protocol_version;
    Reason =:= bad_username_or_password;
    Reason =:= not_authorized;
    Reason =:= bad_authentication_method;
    Reason =:= topic_name_invalid;
    Reason =:= retain_not_supported;
    Reason =:= qos_not_supported
).
connect_broker(#{mqtt_options := MqttOpts} = LoopData) ->
    case emqtt:start_link(MqttOpts) of
        {ok, MqttClient} ->
            IsLocalhost = is_localhost(maps:get(host, MqttOpts)),
            case emqtt:connect(MqttClient) of
                {ok, _} ->
                    {next_state, connected, LoopData#{mqtt_client => MqttClient}};
                {error, {not_authorized, _Prop}} when IsLocalhost ->
                    %% Somethimes the authentication components has not been loaded yet,
                    %% so we retry to connect to the localhost broker on not_authorized error.
                    ?LOG_T(warning, #{
                        msg => retry_connect_to_localhost_broker, reason => not_authorized
                    }),
                    {keep_state, LoopData, [{state_timeout, ?T_RECONN, connect_broker}]};
                {error, {Reason, _Prop}} when ?WONT_RETRY_ERR(Reason) ->
                    ?LOG_T(error, #{msg => shutdown_on_connect_broker_failed, reason => Reason}),
                    shutdown(#{error => Reason});
                {error, Reason} ->
                    ?LOG_T(error, #{msg => connect_broker_failed, reason => Reason}),
                    {keep_state, LoopData, [{state_timeout, ?T_RECONN, connect_broker}]}
            end;
        {error, Reason} ->
            ?LOG_T(error, #{msg => start_emqtt_failed, reason => Reason}),
            shutdown(#{error => Reason})
    end.

%%==============================================================================
%% Internal functions
%%==============================================================================
destroy_session(McpClientId, Sessions) ->
    case maps:find(McpClientId, Sessions) of
        {ok, Session} ->
            ok = mcp_mqtt_erl_client_session:destroy(Session),
            maps:remove(McpClientId, Sessions);
        error ->
            Sessions
    end.

send_client_offline_message(MqttClient, McpClientId) ->
    mcp_mqtt_erl_msg:send_client_offline_message(MqttClient, McpClientId).

split_id_and_server_name(Str) ->
    %% Split the server ID and name from the topic
    case string:split(Str, <<"/">>) of
        [Id, ServerName] -> {Id, ServerName};
        _ -> throw({error, {invalid_id_and_server_name, Str}})
    end.

is_localhost(<<"localhost">>) -> true;
is_localhost(<<"127.0.0.", _/binary>>) -> true;
is_localhost(<<"::1">>) -> true;
is_localhost(_Host) -> false.
