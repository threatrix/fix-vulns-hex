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

-module(emqx_alarm_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("eunit/include/eunit.hrl").

all() -> emqx_common_test_helpers:all(?MODULE).

init_per_testcase(t_size_limit, Config) ->
    emqx_common_test_helpers:boot_modules(all),
    emqx_common_test_helpers:start_apps([]),
    {ok, _} = emqx:update_config([alarm], #{
        <<"size_limit">> => 2
    }),
    Config;
init_per_testcase(_, Config) ->
    emqx_common_test_helpers:boot_modules(all),
    emqx_common_test_helpers:start_apps([]),
    {ok, _} = emqx:update_config([alarm], #{
        <<"validity_period">> => <<"1s">>
    }),
    Config.

end_per_testcase(_, _Config) ->
    emqx_common_test_helpers:stop_apps([]).

t_alarm(_) ->
    ok = emqx_alarm:activate(unknown_alarm),
    {error, already_existed} = emqx_alarm:activate(unknown_alarm),
    ?assertNotEqual({error, not_found}, get_alarm(unknown_alarm, emqx_alarm:get_alarms())),
    ?assertNotEqual({error, not_found}, get_alarm(unknown_alarm, emqx_alarm:get_alarms(activated))),
    ?assertEqual({error, not_found}, get_alarm(unknown_alarm, emqx_alarm:get_alarms(deactivated))),

    ok = emqx_alarm:deactivate(unknown_alarm),
    {error, not_found} = emqx_alarm:deactivate(unknown_alarm),
    ?assertEqual({error, not_found}, get_alarm(unknown_alarm, emqx_alarm:get_alarms(activated))),
    ?assertNotEqual(
        {error, not_found}, get_alarm(unknown_alarm, emqx_alarm:get_alarms(deactivated))
    ),

    emqx_alarm:delete_all_deactivated_alarms(),
    ?assertEqual({error, not_found}, get_alarm(unknown_alarm, emqx_alarm:get_alarms(deactivated))).

t_deactivate_all_alarms(_) ->
    ok = emqx_alarm:activate(unknown_alarm),
    {error, already_existed} = emqx_alarm:activate(unknown_alarm),
    ?assertNotEqual({error, not_found}, get_alarm(unknown_alarm, emqx_alarm:get_alarms(activated))),

    emqx_alarm:deactivate_all_alarms(),
    ?assertNotEqual(
        {error, not_found}, get_alarm(unknown_alarm, emqx_alarm:get_alarms(deactivated))
    ),

    emqx_alarm:delete_all_deactivated_alarms(),
    ?assertEqual({error, not_found}, get_alarm(unknown_alarm, emqx_alarm:get_alarms(deactivated))).

t_size_limit(_) ->
    ok = emqx_alarm:activate(a),
    ok = emqx_alarm:deactivate(a),
    ok = emqx_alarm:activate(b),
    ok = emqx_alarm:deactivate(b),
    ?assertNotEqual({error, not_found}, get_alarm(a, emqx_alarm:get_alarms(deactivated))),
    ?assertNotEqual({error, not_found}, get_alarm(b, emqx_alarm:get_alarms(deactivated))),
    ok = emqx_alarm:activate(c),
    ok = emqx_alarm:deactivate(c),
    ?assertNotEqual({error, not_found}, get_alarm(c, emqx_alarm:get_alarms(deactivated))),
    ?assertEqual({error, not_found}, get_alarm(a, emqx_alarm:get_alarms(deactivated))),
    emqx_alarm:delete_all_deactivated_alarms().

t_validity_period(_Config) ->
    ok = emqx_alarm:activate(a, #{msg => "Request frequency is too high"}, <<"Reach Rate Limit">>),
    ok = emqx_alarm:deactivate(a, #{msg => "Request frequency returns to normal"}),
    ?assertNotEqual({error, not_found}, get_alarm(a, emqx_alarm:get_alarms(deactivated))),
    %% call with unknown msg
    ?assertEqual(ignored, gen_server:call(emqx_alarm, unknown_alarm)),
    ct:sleep(3000),
    ?assertEqual({error, not_found}, get_alarm(a, emqx_alarm:get_alarms(deactivated))).

t_validity_period_1(_Config) ->
    ok = emqx_alarm:activate(a, #{msg => "Request frequency is too high"}, <<"Reach Rate Limit">>),
    ok = emqx_alarm:deactivate(a, #{msg => "Request frequency returns to normal"}),
    ?assertNotEqual({error, not_found}, get_alarm(a, emqx_alarm:get_alarms(deactivated))),
    %% info with unknown msg
    erlang:send(emqx_alarm, unknown_alarm),
    ct:sleep(3000),
    ?assertEqual({error, not_found}, get_alarm(a, emqx_alarm:get_alarms(deactivated))).

t_validity_period_2(_Config) ->
    ok = emqx_alarm:activate(a, #{msg => "Request frequency is too high"}, <<"Reach Rate Limit">>),
    ok = emqx_alarm:deactivate(a, #{msg => "Request frequency returns to normal"}),
    ?assertNotEqual({error, not_found}, get_alarm(a, emqx_alarm:get_alarms(deactivated))),
    %% cast with unknown msg
    gen_server:cast(emqx_alarm, unknown_alarm),
    ct:sleep(3000),
    ?assertEqual({error, not_found}, get_alarm(a, emqx_alarm:get_alarms(deactivated))).

-record(activated_alarm, {
    name :: binary() | atom(),
    details :: map() | list(),
    message :: binary(),
    activate_at :: integer()
}).

-record(deactivated_alarm, {
    activate_at :: integer(),
    name :: binary() | atom(),
    details :: map() | list(),
    message :: binary(),
    deactivate_at :: integer() | infinity
}).

t_format(_Config) ->
    Name = test_alarm,
    Message = "test_msg",
    At = erlang:system_time(microsecond),
    Details = "test_details",
    Node = node(),
    Activate = #activated_alarm{
        name = Name, message = Message, activate_at = At, details = Details
    },
    #{
        node := Node,
        name := Name,
        message := Message,
        duration := 0,
        details := Details
    } = emqx_alarm:format(Activate),
    Deactivate = #deactivated_alarm{
        name = Name,
        message = Message,
        activate_at = At,
        details = Details,
        deactivate_at = At
    },
    #{
        node := Node,
        name := Name,
        message := Message,
        duration := 0,
        details := Details
    } = emqx_alarm:format(Deactivate),
    ok.

get_alarm(Name, [Alarm = #{name := Name} | _More]) ->
    Alarm;
get_alarm(Name, [_Alarm | More]) ->
    get_alarm(Name, More);
get_alarm(_Name, []) ->
    {error, not_found}.
