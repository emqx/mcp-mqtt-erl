%%%-------------------------------------------------------------------
%% @doc mcp_mqtt_erl public API
%% @end
%%%-------------------------------------------------------------------

-module(mcp_mqtt_erl_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    mcp_mqtt_erl_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
