-module(mcp_mqtt_erl_client_demo).

-behaviour(mcp_mqtt_erl_client_session).

-export([
    client_name/0,
    client_version/0,
    client_capabilities/0,
    received_non_mcp_message/3
]).
-export([start_link/0]).

client_name() ->
    <<"emqx_tools/cli_demo">>.

client_version() ->
    <<"1.0">>.

client_capabilities() -> #{}.

received_non_mcp_message(MqttClient, Msg, State) ->
    io:format("~p Received non-MCP message: ~p~n", [MqttClient, Msg]),
    State.

start_link() ->
    mcp_mqtt_erl_client:start_link(
        #{
            server_name_filter => <<"#">>,
            callback_mod => ?MODULE,
            broker_address => {"127.0.0.1", 1883},
            mqtt_options => #{
                clientid => <<"emqx_tools_cli_demo">>,
                username => <<"emqx">>,
                password => <<"public">>
            }
        }).
