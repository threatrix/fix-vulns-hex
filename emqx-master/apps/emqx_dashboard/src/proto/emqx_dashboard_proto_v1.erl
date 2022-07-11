%%--------------------------------------------------------------------
%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_dashboard_proto_v1).

-behaviour(emqx_bpapi).

-export([
    introduced_in/0,
    do_sample/2,
    current_rate/1
]).

-include("emqx_dashboard.hrl").
-include_lib("emqx/include/bpapi.hrl").

introduced_in() ->
    "5.0.0".

-spec do_sample(node(), Latest :: pos_integer() | infinity) -> list(map()) | emqx_rpc:badrpc().
do_sample(Node, Latest) ->
    rpc:call(Node, emqx_dashboard_monitor, do_sample, [Node, Latest], ?RPC_TIMEOUT).

-spec current_rate(node()) -> {ok, map()} | emqx_rpc:badrpc().
current_rate(Node) ->
    rpc:call(Node, emqx_dashboard_monitor, current_rate, [Node], ?RPC_TIMEOUT).
