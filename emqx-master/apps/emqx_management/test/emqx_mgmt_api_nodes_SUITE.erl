%%--------------------------------------------------------------------
%% Copyright (c) 2020-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-module(emqx_mgmt_api_nodes_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    emqx_mgmt_api_test_util:init_suite([emqx_conf]),
    Config.

end_per_suite(_) ->
    emqx_mgmt_api_test_util:end_suite([emqx_conf]).

init_per_testcase(t_log_path, Config) ->
    emqx_config_logger:add_handler(),
    Log = emqx_conf:get_raw([log], #{}),
    File = "log/emqx-test.log",
    Log1 = emqx_map_lib:deep_put([<<"file_handlers">>, <<"default">>, <<"enable">>], Log, true),
    Log2 = emqx_map_lib:deep_put([<<"file_handlers">>, <<"default">>, <<"file">>], Log1, File),
    {ok, #{}} = emqx_conf:update([log], Log2, #{rawconf_with_defaults => true}),
    Config;
init_per_testcase(_, Config) ->
    Config.

end_per_testcase(t_log_path, Config) ->
    Log = emqx_conf:get_raw([log], #{}),
    Log1 = emqx_map_lib:deep_put([<<"file_handlers">>, <<"default">>, <<"enable">>], Log, false),
    {ok, #{}} = emqx_conf:update([log], Log1, #{rawconf_with_defaults => true}),
    emqx_config_logger:remove_handler(),
    Config;
end_per_testcase(_, Config) ->
    Config.

t_nodes_api(_) ->
    NodesPath = emqx_mgmt_api_test_util:api_path(["nodes"]),
    {ok, Nodes} = emqx_mgmt_api_test_util:request_api(get, NodesPath),
    NodesResponse = emqx_json:decode(Nodes, [return_maps]),
    LocalNodeInfo = hd(NodesResponse),
    Node = binary_to_atom(maps:get(<<"node">>, LocalNodeInfo), utf8),
    ?assertEqual(Node, node()),

    NodePath = emqx_mgmt_api_test_util:api_path(["nodes", atom_to_list(node())]),
    {ok, NodeInfo} = emqx_mgmt_api_test_util:request_api(get, NodePath),
    NodeNameResponse =
        binary_to_atom(maps:get(<<"node">>, emqx_json:decode(NodeInfo, [return_maps])), utf8),
    ?assertEqual(node(), NodeNameResponse),

    BadNodePath = emqx_mgmt_api_test_util:api_path(["nodes", "badnode"]),
    ?assertMatch(
        {error, {_, 400, _}},
        emqx_mgmt_api_test_util:request_api(get, BadNodePath)
    ).

t_log_path(_) ->
    NodePath = emqx_mgmt_api_test_util:api_path(["nodes", atom_to_list(node())]),
    {ok, NodeInfo} = emqx_mgmt_api_test_util:request_api(get, NodePath),
    #{<<"log_path">> := Path} = emqx_json:decode(NodeInfo, [return_maps]),
    ?assertEqual(
        <<"log">>,
        filename:basename(Path)
    ).

t_node_stats_api(_) ->
    StatsPath = emqx_mgmt_api_test_util:api_path(["nodes", atom_to_binary(node(), utf8), "stats"]),
    SystemStats = emqx_mgmt:get_stats(),
    {ok, StatsResponse} = emqx_mgmt_api_test_util:request_api(get, StatsPath),
    Stats = emqx_json:decode(StatsResponse, [return_maps]),
    Fun =
        fun(Key) ->
            ?assertEqual(maps:get(Key, SystemStats), maps:get(atom_to_binary(Key, utf8), Stats))
        end,
    lists:foreach(Fun, maps:keys(SystemStats)),

    BadNodePath = emqx_mgmt_api_test_util:api_path(["nodes", "badnode", "stats"]),
    ?assertMatch(
        {error, {_, 400, _}},
        emqx_mgmt_api_test_util:request_api(get, BadNodePath)
    ).

t_node_metrics_api(_) ->
    MetricsPath =
        emqx_mgmt_api_test_util:api_path(["nodes", atom_to_binary(node(), utf8), "metrics"]),
    SystemMetrics = emqx_mgmt:get_metrics(),
    {ok, MetricsResponse} = emqx_mgmt_api_test_util:request_api(get, MetricsPath),
    Metrics = emqx_json:decode(MetricsResponse, [return_maps]),
    Fun =
        fun(Key) ->
            ?assertEqual(maps:get(Key, SystemMetrics), maps:get(atom_to_binary(Key, utf8), Metrics))
        end,
    lists:foreach(Fun, maps:keys(SystemMetrics)),

    BadNodePath = emqx_mgmt_api_test_util:api_path(["nodes", "badnode", "metrics"]),
    ?assertMatch(
        {error, {_, 400, _}},
        emqx_mgmt_api_test_util:request_api(get, BadNodePath)
    ).
