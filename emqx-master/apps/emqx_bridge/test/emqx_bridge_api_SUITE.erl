%%--------------------------------------------------------------------
%% Copyright (c) 2020-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_bridge_api_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-import(emqx_dashboard_api_test_helpers, [request/4, uri/1]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-define(CONF_DEFAULT, <<"bridges: {}">>).
-define(BRIDGE_TYPE, <<"webhook">>).
-define(BRIDGE_NAME, <<"test_bridge">>).
-define(URL(PORT, PATH),
    list_to_binary(
        io_lib:format(
            "http://localhost:~s/~s",
            [integer_to_list(PORT), PATH]
        )
    )
).
-define(HTTP_BRIDGE(URL, TYPE, NAME), #{
    <<"type">> => TYPE,
    <<"name">> => NAME,
    <<"url">> => URL,
    <<"local_topic">> => <<"emqx_webhook/#">>,
    <<"method">> => <<"post">>,
    <<"ssl">> => #{<<"enable">> => false},
    <<"body">> => <<"${payload}">>,
    <<"headers">> => #{
        <<"content-type">> => <<"application/json">>
    }
}).

all() ->
    emqx_common_test_helpers:all(?MODULE).

groups() ->
    [].

suite() ->
    [{timetrap, {seconds, 60}}].

init_per_suite(Config) ->
    _ = application:load(emqx_conf),
    %% some testcases (may from other app) already get emqx_connector started
    _ = application:stop(emqx_resource),
    _ = application:stop(emqx_connector),
    ok = emqx_common_test_helpers:start_apps(
        [emqx_bridge, emqx_dashboard],
        fun set_special_configs/1
    ),
    ok = emqx_common_test_helpers:load_config(emqx_bridge_schema, ?CONF_DEFAULT),
    Config.

end_per_suite(_Config) ->
    emqx_common_test_helpers:stop_apps([emqx_bridge, emqx_dashboard]),
    ok.

set_special_configs(emqx_dashboard) ->
    emqx_dashboard_api_test_helpers:set_default_config(<<"bridge_admin">>);
set_special_configs(_) ->
    ok.

init_per_testcase(_, Config) ->
    {ok, _} = emqx_cluster_rpc:start_link(node(), emqx_cluster_rpc, 1000),
    Config.
end_per_testcase(_, _Config) ->
    clear_resources(),
    ok.

clear_resources() ->
    lists:foreach(
        fun(#{type := Type, name := Name}) ->
            {ok, _} = emqx_bridge:remove(Type, Name)
        end,
        emqx_bridge:list()
    ).

%%------------------------------------------------------------------------------
%% HTTP server for testing
%%------------------------------------------------------------------------------
start_http_server(HandleFun) ->
    Parent = self(),
    spawn_link(fun() ->
        {Port, Sock} = listen_on_random_port(),
        Parent ! {port, Port},
        loop(Sock, HandleFun, Parent)
    end),
    receive
        {port, Port} -> Port
    after 2000 -> error({timeout, start_http_server})
    end.

listen_on_random_port() ->
    Min = 1024,
    Max = 65000,
    Port = rand:uniform(Max - Min) + Min,
    case gen_tcp:listen(Port, [{active, false}, {reuseaddr, true}, binary]) of
        {ok, Sock} -> {Port, Sock};
        {error, eaddrinuse} -> listen_on_random_port()
    end.

loop(Sock, HandleFun, Parent) ->
    {ok, Conn} = gen_tcp:accept(Sock),
    Handler = spawn(fun() -> HandleFun(Conn, Parent) end),
    gen_tcp:controlling_process(Conn, Handler),
    loop(Sock, HandleFun, Parent).

make_response(CodeStr, Str) ->
    B = iolist_to_binary(Str),
    iolist_to_binary(
        io_lib:fwrite(
            "HTTP/1.0 ~s\r\nContent-Type: text/html\r\nContent-Length: ~p\r\n\r\n~s",
            [CodeStr, size(B), B]
        )
    ).

handle_fun_200_ok(Conn, Parent) ->
    case gen_tcp:recv(Conn, 0) of
        {ok, ReqStr} ->
            ct:pal("the http handler got request: ~p", [ReqStr]),
            Req = parse_http_request(ReqStr),
            Parent ! {http_server, received, Req},
            gen_tcp:send(Conn, make_response("200 OK", "Request OK")),
            handle_fun_200_ok(Conn, Parent);
        {error, closed} ->
            gen_tcp:close(Conn)
    end.

parse_http_request(ReqStr0) ->
    [Method, ReqStr1] = string:split(ReqStr0, " ", leading),
    [Path, ReqStr2] = string:split(ReqStr1, " ", leading),
    [_ProtoVsn, ReqStr3] = string:split(ReqStr2, "\r\n", leading),
    [_HeaderStr, Body] = string:split(ReqStr3, "\r\n\r\n", leading),
    #{method => Method, path => Path, body => Body}.

%%------------------------------------------------------------------------------
%% Testcases
%%------------------------------------------------------------------------------

t_http_crud_apis(_) ->
    Port = start_http_server(fun handle_fun_200_ok/2),
    %% assert we there's no bridges at first
    {ok, 200, <<"[]">>} = request(get, uri(["bridges"]), []),

    %% then we add a webhook bridge, using POST
    %% POST /bridges/ will create a bridge
    URL1 = ?URL(Port, "path1"),
    {ok, 201, Bridge} = request(
        post,
        uri(["bridges"]),
        ?HTTP_BRIDGE(URL1, ?BRIDGE_TYPE, ?BRIDGE_NAME)
    ),

    %ct:pal("---bridge: ~p", [Bridge]),
    #{
        <<"type">> := ?BRIDGE_TYPE,
        <<"name">> := ?BRIDGE_NAME,
        <<"enable">> := true,
        <<"status">> := _,
        <<"node_status">> := [_ | _],
        <<"metrics">> := _,
        <<"node_metrics">> := [_ | _],
        <<"url">> := URL1
    } = jsx:decode(Bridge),

    BridgeID = emqx_bridge_resource:bridge_id(?BRIDGE_TYPE, ?BRIDGE_NAME),
    %% send an message to emqx and the message should be forwarded to the HTTP server
    Body = <<"my msg">>,
    emqx:publish(emqx_message:make(<<"emqx_webhook/1">>, Body)),
    ?assert(
        receive
            {http_server, received, #{
                method := <<"POST">>,
                path := <<"/path1">>,
                body := Body
            }} ->
                true;
            Msg ->
                ct:pal("error: http got unexpected request: ~p", [Msg]),
                false
        after 100 ->
            false
        end
    ),
    %% update the request-path of the bridge
    URL2 = ?URL(Port, "path2"),
    {ok, 200, Bridge2} = request(
        put,
        uri(["bridges", BridgeID]),
        ?HTTP_BRIDGE(URL2, ?BRIDGE_TYPE, ?BRIDGE_NAME)
    ),
    ?assertMatch(
        #{
            <<"type">> := ?BRIDGE_TYPE,
            <<"name">> := ?BRIDGE_NAME,
            <<"enable">> := true,
            <<"status">> := _,
            <<"node_status">> := [_ | _],
            <<"metrics">> := _,
            <<"node_metrics">> := [_ | _],
            <<"url">> := URL2
        },
        jsx:decode(Bridge2)
    ),

    %% list all bridges again, assert Bridge2 is in it
    {ok, 200, Bridge2Str} = request(get, uri(["bridges"]), []),
    ?assertMatch(
        [
            #{
                <<"type">> := ?BRIDGE_TYPE,
                <<"name">> := ?BRIDGE_NAME,
                <<"enable">> := true,
                <<"status">> := _,
                <<"node_status">> := [_ | _],
                <<"metrics">> := _,
                <<"node_metrics">> := [_ | _],
                <<"url">> := URL2
            }
        ],
        jsx:decode(Bridge2Str)
    ),

    %% get the bridge by id
    {ok, 200, Bridge3Str} = request(get, uri(["bridges", BridgeID]), []),
    ?assertMatch(
        #{
            <<"type">> := ?BRIDGE_TYPE,
            <<"name">> := ?BRIDGE_NAME,
            <<"enable">> := true,
            <<"status">> := _,
            <<"node_status">> := [_ | _],
            <<"metrics">> := _,
            <<"node_metrics">> := [_ | _],
            <<"url">> := URL2
        },
        jsx:decode(Bridge3Str)
    ),

    %% send an message to emqx again, check the path has been changed
    emqx:publish(emqx_message:make(<<"emqx_webhook/1">>, Body)),
    ?assert(
        receive
            {http_server, received, #{path := <<"/path2">>}} ->
                true;
            Msg2 ->
                ct:pal("error: http got unexpected request: ~p", [Msg2]),
                false
        after 100 ->
            false
        end
    ),

    %% delete the bridge
    {ok, 204, <<>>} = request(delete, uri(["bridges", BridgeID]), []),
    {ok, 200, <<"[]">>} = request(get, uri(["bridges"]), []),

    %% update a deleted bridge returns an error
    {ok, 404, ErrMsg2} = request(
        put,
        uri(["bridges", BridgeID]),
        ?HTTP_BRIDGE(URL2, ?BRIDGE_TYPE, ?BRIDGE_NAME)
    ),
    ?assertMatch(
        #{
            <<"code">> := _,
            <<"message">> := <<"bridge not found">>
        },
        jsx:decode(ErrMsg2)
    ),
    ok.

t_start_stop_bridges(_) ->
    lists:foreach(
        fun(Type) ->
            do_start_stop_bridges(Type)
        end,
        [node, cluster]
    ).

do_start_stop_bridges(Type) ->
    %% assert we there's no bridges at first
    {ok, 200, <<"[]">>} = request(get, uri(["bridges"]), []),

    Port = start_http_server(fun handle_fun_200_ok/2),
    URL1 = ?URL(Port, "abc"),
    {ok, 201, Bridge} = request(
        post,
        uri(["bridges"]),
        ?HTTP_BRIDGE(URL1, ?BRIDGE_TYPE, ?BRIDGE_NAME)
    ),
    %ct:pal("the bridge ==== ~p", [Bridge]),
    #{
        <<"type">> := ?BRIDGE_TYPE,
        <<"name">> := ?BRIDGE_NAME,
        <<"enable">> := true,
        <<"status">> := <<"connected">>,
        <<"node_status">> := [_ | _],
        <<"metrics">> := _,
        <<"node_metrics">> := [_ | _],
        <<"url">> := URL1
    } = jsx:decode(Bridge),
    BridgeID = emqx_bridge_resource:bridge_id(?BRIDGE_TYPE, ?BRIDGE_NAME),
    %% stop it
    {ok, 200, <<>>} = request(post, operation_path(Type, stop, BridgeID), <<"">>),
    {ok, 200, Bridge2} = request(get, uri(["bridges", BridgeID]), []),
    ?assertMatch(#{<<"status">> := <<"disconnected">>}, jsx:decode(Bridge2)),
    %% start again
    {ok, 200, <<>>} = request(post, operation_path(Type, restart, BridgeID), <<"">>),
    {ok, 200, Bridge3} = request(get, uri(["bridges", BridgeID]), []),
    ?assertMatch(#{<<"status">> := <<"connected">>}, jsx:decode(Bridge3)),
    %% restart an already started bridge
    {ok, 200, <<>>} = request(post, operation_path(Type, restart, BridgeID), <<"">>),
    {ok, 200, Bridge3} = request(get, uri(["bridges", BridgeID]), []),
    ?assertMatch(#{<<"status">> := <<"connected">>}, jsx:decode(Bridge3)),
    %% stop it again
    {ok, 200, <<>>} = request(post, operation_path(Type, stop, BridgeID), <<"">>),
    %% restart a stopped bridge
    {ok, 200, <<>>} = request(post, operation_path(Type, restart, BridgeID), <<"">>),
    {ok, 200, Bridge4} = request(get, uri(["bridges", BridgeID]), []),
    ?assertMatch(#{<<"status">> := <<"connected">>}, jsx:decode(Bridge4)),
    %% delete the bridge
    {ok, 204, <<>>} = request(delete, uri(["bridges", BridgeID]), []),
    {ok, 200, <<"[]">>} = request(get, uri(["bridges"]), []).

t_enable_disable_bridges(_) ->
    %% assert we there's no bridges at first
    {ok, 200, <<"[]">>} = request(get, uri(["bridges"]), []),

    Port = start_http_server(fun handle_fun_200_ok/2),
    URL1 = ?URL(Port, "abc"),
    {ok, 201, Bridge} = request(
        post,
        uri(["bridges"]),
        ?HTTP_BRIDGE(URL1, ?BRIDGE_TYPE, ?BRIDGE_NAME)
    ),
    %ct:pal("the bridge ==== ~p", [Bridge]),
    #{
        <<"type">> := ?BRIDGE_TYPE,
        <<"name">> := ?BRIDGE_NAME,
        <<"enable">> := true,
        <<"status">> := <<"connected">>,
        <<"node_status">> := [_ | _],
        <<"metrics">> := _,
        <<"node_metrics">> := [_ | _],
        <<"url">> := URL1
    } = jsx:decode(Bridge),
    BridgeID = emqx_bridge_resource:bridge_id(?BRIDGE_TYPE, ?BRIDGE_NAME),
    %% disable it
    {ok, 200, <<>>} = request(post, operation_path(cluster, disable, BridgeID), <<"">>),
    {ok, 200, Bridge2} = request(get, uri(["bridges", BridgeID]), []),
    ?assertMatch(#{<<"status">> := <<"disconnected">>}, jsx:decode(Bridge2)),
    %% enable again
    {ok, 200, <<>>} = request(post, operation_path(cluster, enable, BridgeID), <<"">>),
    {ok, 200, Bridge3} = request(get, uri(["bridges", BridgeID]), []),
    ?assertMatch(#{<<"status">> := <<"connected">>}, jsx:decode(Bridge3)),
    %% enable an already started bridge
    {ok, 200, <<>>} = request(post, operation_path(cluster, enable, BridgeID), <<"">>),
    {ok, 200, Bridge3} = request(get, uri(["bridges", BridgeID]), []),
    ?assertMatch(#{<<"status">> := <<"connected">>}, jsx:decode(Bridge3)),
    %% disable it again
    {ok, 200, <<>>} = request(post, operation_path(cluster, disable, BridgeID), <<"">>),

    {ok, 403, Res} = request(post, operation_path(node, restart, BridgeID), <<"">>),
    ?assertEqual(
        <<"{\"code\":\"FORBIDDEN_REQUEST\",\"message\":\"forbidden operation: bridge disabled\"}">>,
        Res
    ),

    %% enable a stopped bridge
    {ok, 200, <<>>} = request(post, operation_path(cluster, enable, BridgeID), <<"">>),
    {ok, 200, Bridge4} = request(get, uri(["bridges", BridgeID]), []),
    ?assertMatch(#{<<"status">> := <<"connected">>}, jsx:decode(Bridge4)),
    %% delete the bridge
    {ok, 204, <<>>} = request(delete, uri(["bridges", BridgeID]), []),
    {ok, 200, <<"[]">>} = request(get, uri(["bridges"]), []).

t_reset_bridges(_) ->
    %% assert we there's no bridges at first
    {ok, 200, <<"[]">>} = request(get, uri(["bridges"]), []),

    Port = start_http_server(fun handle_fun_200_ok/2),
    URL1 = ?URL(Port, "abc"),
    {ok, 201, Bridge} = request(
        post,
        uri(["bridges"]),
        ?HTTP_BRIDGE(URL1, ?BRIDGE_TYPE, ?BRIDGE_NAME)
    ),
    %ct:pal("the bridge ==== ~p", [Bridge]),
    #{
        <<"type">> := ?BRIDGE_TYPE,
        <<"name">> := ?BRIDGE_NAME,
        <<"enable">> := true,
        <<"status">> := <<"connected">>,
        <<"node_status">> := [_ | _],
        <<"metrics">> := _,
        <<"node_metrics">> := [_ | _],
        <<"url">> := URL1
    } = jsx:decode(Bridge),
    BridgeID = emqx_bridge_resource:bridge_id(?BRIDGE_TYPE, ?BRIDGE_NAME),
    {ok, 200, <<"Reset success">>} = request(put, uri(["bridges", BridgeID, "reset_metrics"]), []),

    %% delete the bridge
    {ok, 204, <<>>} = request(delete, uri(["bridges", BridgeID]), []),
    {ok, 200, <<"[]">>} = request(get, uri(["bridges"]), []).

request(Method, Url, Body) ->
    request(<<"bridge_admin">>, Method, Url, Body).

operation_path(node, Oper, BridgeID) ->
    uri(["nodes", node(), "bridges", BridgeID, "operation", Oper]);
operation_path(cluster, Oper, BridgeID) ->
    uri(["bridges", BridgeID, "operation", Oper]).

str(S) when is_list(S) -> S;
str(S) when is_binary(S) -> binary_to_list(S).
