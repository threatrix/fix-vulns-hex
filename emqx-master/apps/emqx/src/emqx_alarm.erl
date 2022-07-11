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

-module(emqx_alarm).

-behaviour(gen_server).

-include("emqx.hrl").
-include("logger.hrl").

%% Mnesia bootstrap
-export([mnesia/1]).

-boot_mnesia({mnesia, [boot]}).

-export([start_link/0]).
%% API
-export([
    activate/1,
    activate/2,
    activate/3,
    deactivate/1,
    deactivate/2,
    deactivate/3,
    ensure_deactivated/1,
    ensure_deactivated/2,
    ensure_deactivated/3,
    delete_all_deactivated_alarms/0,
    get_alarms/0,
    get_alarms/1,
    format/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

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

-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.

%%--------------------------------------------------------------------
%% Mnesia bootstrap
%%--------------------------------------------------------------------

mnesia(boot) ->
    ok = mria:create_table(
        ?ACTIVATED_ALARM,
        [
            {type, set},
            {storage, disc_copies},
            {local_content, true},
            {record_name, activated_alarm},
            {attributes, record_info(fields, activated_alarm)}
        ]
    ),
    ok = mria:create_table(
        ?DEACTIVATED_ALARM,
        [
            {type, ordered_set},
            {storage, disc_copies},
            {local_content, true},
            {record_name, deactivated_alarm},
            {attributes, record_info(fields, deactivated_alarm)}
        ]
    ).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

activate(Name) ->
    activate(Name, #{}).

activate(Name, Details) ->
    activate(Name, Details, <<"">>).

activate(Name, Details, Message) ->
    gen_server:call(?MODULE, {activate_alarm, Name, Details, Message}).

-spec ensure_deactivated(binary() | atom()) -> ok.
ensure_deactivated(Name) ->
    ensure_deactivated(Name, no_details).

-spec ensure_deactivated(binary() | atom(), atom() | map()) -> ok.
ensure_deactivated(Name, Data) ->
    ensure_deactivated(Name, Data, <<>>).

-spec ensure_deactivated(binary() | atom(), atom() | map(), iodata()) -> ok.
ensure_deactivated(Name, Data, Message) ->
    %% this duplicates the dirty read in handle_call,
    %% intention is to avoid making gen_server calls when there is no alarm
    case mnesia:dirty_read(?ACTIVATED_ALARM, Name) of
        [] ->
            ok;
        _ ->
            case deactivate(Name, Data, Message) of
                {error, not_found} -> ok;
                Other -> Other
            end
    end.

-spec deactivate(binary() | atom()) -> ok | {error, not_found}.
deactivate(Name) ->
    deactivate(Name, no_details, <<"">>).

deactivate(Name, Details) ->
    deactivate(Name, Details, <<"">>).

deactivate(Name, Details, Message) ->
    gen_server:call(?MODULE, {deactivate_alarm, Name, Details, Message}).

-spec delete_all_deactivated_alarms() -> ok.
delete_all_deactivated_alarms() ->
    gen_server:call(?MODULE, delete_all_deactivated_alarms).

get_alarms() ->
    get_alarms(all).

-spec get_alarms(all | activated | deactivated) -> [map()].
get_alarms(all) ->
    gen_server:call(?MODULE, {get_alarms, all});
get_alarms(activated) ->
    gen_server:call(?MODULE, {get_alarms, activated});
get_alarms(deactivated) ->
    gen_server:call(?MODULE, {get_alarms, deactivated}).

format(#activated_alarm{name = Name, message = Message, activate_at = At, details = Details}) ->
    Now = erlang:system_time(microsecond),
    %% mnesia db stored microsecond for high frequency alarm
    %% format for dashboard using millisecond
    #{
        node => node(),
        name => Name,
        message => Message,
        %% to millisecond
        duration => (Now - At) div 1000,
        activate_at => to_rfc3339(At),
        details => Details
    };
format(#deactivated_alarm{
    name = Name,
    message = Message,
    activate_at = At,
    details = Details,
    deactivate_at = DAt
}) ->
    #{
        node => node(),
        name => Name,
        message => Message,
        %% to millisecond
        duration => (DAt - At) div 1000,
        activate_at => to_rfc3339(At),
        deactivate_at => to_rfc3339(DAt),
        details => Details
    }.

to_rfc3339(Timestamp) ->
    %% rfc3339 accuracy to millisecond
    list_to_binary(calendar:system_time_to_rfc3339(Timestamp div 1000, [{unit, millisecond}])).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    ok = mria:wait_for_tables([?ACTIVATED_ALARM, ?DEACTIVATED_ALARM, ?TRIE]),
    deactivate_all_alarms(),
    {ok, #{}, get_validity_period()}.

handle_call({activate_alarm, Name, Details, Message}, _From, State) ->
    Res = mria:transaction(
        mria:local_content_shard(),
        fun create_activate_alarm/3,
        [Name, Details, Message]
    ),
    case Res of
        {atomic, Alarm} ->
            do_actions(activate, Alarm, emqx:get_config([alarm, actions])),
            {reply, ok, State, get_validity_period()};
        {aborted, Reason} ->
            {reply, Reason, State, get_validity_period()}
    end;
handle_call({deactivate_alarm, Name, Details, Message}, _From, State) ->
    case mnesia:dirty_read(?ACTIVATED_ALARM, Name) of
        [] ->
            {reply, {error, not_found}, State};
        [Alarm] ->
            deactivate_alarm(Alarm, Details, Message),
            {reply, ok, State, get_validity_period()}
    end;
handle_call(delete_all_deactivated_alarms, _From, State) ->
    clear_table(?DEACTIVATED_ALARM),
    {reply, ok, State, get_validity_period()};
handle_call({get_alarms, all}, _From, State) ->
    {atomic, Alarms} =
        mria:ro_transaction(
            mria:local_content_shard(),
            fun() ->
                [
                    normalize(Alarm)
                 || Alarm <-
                        ets:tab2list(?ACTIVATED_ALARM) ++
                            ets:tab2list(?DEACTIVATED_ALARM)
                ]
            end
        ),
    {reply, Alarms, State, get_validity_period()};
handle_call({get_alarms, activated}, _From, State) ->
    Alarms = [normalize(Alarm) || Alarm <- ets:tab2list(?ACTIVATED_ALARM)],
    {reply, Alarms, State, get_validity_period()};
handle_call({get_alarms, deactivated}, _From, State) ->
    Alarms = [normalize(Alarm) || Alarm <- ets:tab2list(?DEACTIVATED_ALARM)],
    {reply, Alarms, State, get_validity_period()};
handle_call(Req, From, State) ->
    ?SLOG(error, #{msg => "unexpected_call", call_req => Req, from => From}),
    {reply, ignored, State, get_validity_period()}.

handle_cast(Msg, State) ->
    ?SLOG(error, #{msg => "unexpected_cast", cast_req => Msg}),
    {noreply, State, get_validity_period()}.

handle_info(timeout, State) ->
    Period = get_validity_period(),
    delete_expired_deactivated_alarms(erlang:system_time(microsecond) - Period * 1000),
    {noreply, State, Period};
handle_info(Info, State) ->
    ?SLOG(error, #{msg => "unexpected_info", info_req => Info}),
    {noreply, State, get_validity_period()}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

get_validity_period() ->
    emqx:get_config([alarm, validity_period]).

create_activate_alarm(Name, Details, Message) ->
    case mnesia:read(?ACTIVATED_ALARM, Name) of
        [#activated_alarm{name = Name}] ->
            mnesia:abort({error, already_existed});
        [] ->
            Alarm = #activated_alarm{
                name = Name,
                details = Details,
                message = normalize_message(Name, iolist_to_binary(Message)),
                activate_at = erlang:system_time(microsecond)
            },
            ok = mnesia:write(?ACTIVATED_ALARM, Alarm, write),
            Alarm
    end.

deactivate_alarm(
    #activated_alarm{
        activate_at = ActivateAt,
        name = Name,
        details = Details0,
        message = Msg0
    },
    Details,
    Message
) ->
    SizeLimit = emqx:get_config([alarm, size_limit]),
    case SizeLimit > 0 andalso (mnesia:table_info(?DEACTIVATED_ALARM, size) >= SizeLimit) of
        true ->
            case mnesia:dirty_first(?DEACTIVATED_ALARM) of
                '$end_of_table' -> ok;
                ActivateAt2 -> mria:dirty_delete(?DEACTIVATED_ALARM, ActivateAt2)
            end;
        false ->
            ok
    end,
    HistoryAlarm = make_deactivated_alarm(
        ActivateAt,
        Name,
        Details0,
        Msg0,
        erlang:system_time(microsecond)
    ),
    DeActAlarm = make_deactivated_alarm(
        ActivateAt,
        Name,
        Details,
        normalize_message(Name, iolist_to_binary(Message)),
        erlang:system_time(microsecond)
    ),
    mria:dirty_write(?DEACTIVATED_ALARM, HistoryAlarm),
    mria:dirty_delete(?ACTIVATED_ALARM, Name),
    do_actions(deactivate, DeActAlarm, emqx:get_config([alarm, actions])).

make_deactivated_alarm(ActivateAt, Name, Details, Message, DeActivateAt) ->
    #deactivated_alarm{
        activate_at = ActivateAt,
        name = Name,
        details = Details,
        message = Message,
        deactivate_at = DeActivateAt
    }.

deactivate_all_alarms() ->
    lists:foreach(
        fun(
            #activated_alarm{
                name = Name,
                details = Details,
                message = Message,
                activate_at = ActivateAt
            }
        ) ->
            mria:dirty_write(
                ?DEACTIVATED_ALARM,
                #deactivated_alarm{
                    activate_at = ActivateAt,
                    name = Name,
                    details = Details,
                    message = Message,
                    deactivate_at = erlang:system_time(microsecond)
                }
            )
        end,
        ets:tab2list(?ACTIVATED_ALARM)
    ),
    clear_table(?ACTIVATED_ALARM).

%% Delete all records from the given table, ignore result.
clear_table(TableName) ->
    case mria:clear_table(TableName) of
        {aborted, Reason} ->
            ?SLOG(warning, #{
                msg => "fail_to_clear_table",
                table_name => TableName,
                reason => Reason
            });
        {atomic, ok} ->
            ok
    end.

delete_expired_deactivated_alarms(Checkpoint) ->
    delete_expired_deactivated_alarms(mnesia:dirty_first(?DEACTIVATED_ALARM), Checkpoint).

delete_expired_deactivated_alarms('$end_of_table', _Checkpoint) ->
    ok;
delete_expired_deactivated_alarms(ActivatedAt, Checkpoint) ->
    case ActivatedAt =< Checkpoint of
        true ->
            mria:dirty_delete(?DEACTIVATED_ALARM, ActivatedAt),
            NActivatedAt = mnesia:dirty_next(?DEACTIVATED_ALARM, ActivatedAt),
            delete_expired_deactivated_alarms(NActivatedAt, Checkpoint);
        false ->
            ok
    end.

do_actions(_, _, []) ->
    ok;
do_actions(activate, Alarm = #activated_alarm{name = Name, message = Message}, [log | More]) ->
    ?SLOG(warning, #{
        msg => "alarm_is_activated",
        name => Name,
        message => Message
    }),
    do_actions(activate, Alarm, More);
do_actions(deactivate, Alarm = #deactivated_alarm{name = Name}, [log | More]) ->
    ?SLOG(warning, #{
        msg => "alarm_is_deactivated",
        name => Name
    }),
    do_actions(deactivate, Alarm, More);
do_actions(Operation, Alarm, [publish | More]) ->
    Topic = topic(Operation),
    {ok, Payload} = emqx_json:safe_encode(normalize(Alarm)),
    Message = emqx_message:make(
        ?MODULE,
        0,
        Topic,
        Payload,
        #{sys => true},
        #{properties => #{'Content-Type' => <<"application/json">>}}
    ),
    _ = emqx_broker:safe_publish(Message),
    do_actions(Operation, Alarm, More).

topic(activate) ->
    emqx_topic:systop(<<"alarms/activate">>);
topic(deactivate) ->
    emqx_topic:systop(<<"alarms/deactivate">>).

normalize(#activated_alarm{
    name = Name,
    details = Details,
    message = Message,
    activate_at = ActivateAt
}) ->
    #{
        name => Name,
        details => Details,
        message => Message,
        activate_at => ActivateAt,
        deactivate_at => infinity,
        activated => true
    };
normalize(#deactivated_alarm{
    activate_at = ActivateAt,
    name = Name,
    details = Details,
    message = Message,
    deactivate_at = DeactivateAt
}) ->
    #{
        name => Name,
        details => Details,
        message => Message,
        activate_at => ActivateAt,
        deactivate_at => DeactivateAt,
        activated => false
    }.

normalize_message(Name, <<"">>) ->
    list_to_binary(io_lib:format("~p", [Name]));
normalize_message(_Name, Message) ->
    Message.
