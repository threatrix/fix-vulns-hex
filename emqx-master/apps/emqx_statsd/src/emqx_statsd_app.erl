%%--------------------------------------------------------------------
%% Copyright (c) 2021-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_statsd_app).

-behaviour(application).

-include("emqx_statsd.hrl").

-export([
    start/2,
    stop/1
]).

start(_StartType, _StartArgs) ->
    {ok, Sup} = emqx_statsd_sup:start_link(),
    maybe_enable_statsd(),
    {ok, Sup}.
stop(_) ->
    ok.

maybe_enable_statsd() ->
    case emqx_conf:get([statsd, enable], false) of
        true ->
            emqx_statsd_sup:ensure_child_started(?APP, emqx_conf:get([statsd], #{}));
        false ->
            ok
    end.
