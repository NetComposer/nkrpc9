%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc
-module(nkrpc9_client_protocol).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([connect/3, stop/1]).
-export([send_request/3, send_async_request/3, reply/3, send_event/3]).
-export([get_all_started/1, get_local_started/1]).

-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_handle_call/4,
         conn_handle_cast/3, conn_handle_info/3, conn_stop/3]).

-define(DEBUG(Txt, Args, State),
    case erlang:get(nkrpc9_protocol) of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, State),
    lager:Type(
        [
            {session_id, State#state.session_id},
            {srv_id, State#state.srv_id},
            {user_id, State#state.user_id}
        ],
        "RPC9 Client ~s (~s) (~s) "++Txt,
        [
            State#state.session_id,
            State#state.srv_id,
            State#state.user_id
            | Args
        ])).

-define(MSG(Txt, Args, State),
    case erlang:get(nkrpc9_msgs) of
        true -> print(Txt, Args, State);
        _ -> ok
    end).


-define(SYNC_CALL_TIMEOUT, 5000).           % Maximum sync call time

-include_lib("nkserver/include/nkserver.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type tid() :: integer().


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new session
-spec connect(term(), binary(), nkpacket:connect_opts()) ->
    {ok, pid()} | {error, term()}.

connect(SrvId, Url, Opts) ->
    ConnOpts = Opts#{
        protocol => ?MODULE,
        class => {nkrpc9_client, SrvId}
    },
    nkpacket:connect(Url, ConnOpts).


%% @doc
stop(Pid) ->
    gen_server:cast(Pid, rpc9_stop).


%% @doc
send_request(Pid, Cmd, Data) when is_map(Data); is_list(Data) ->
    do_call(Pid, {rpc9_send_req, nklib_util:to_binary(Cmd), Data}).


%% @doc
send_async_request(Pid, Cmd, Data) when is_map(Data); is_list(Data) ->
    gen_server:cast(Pid, {rpc9_send_req, nklib_util:to_binary(Cmd), Data}).


% Send an event to the client
send_event(Pid, Event, Data) ->
    gen_server:cast(Pid, {rpc9_send_event, Event, Data}).


%% doc
reply(Pid, TId, {login, UserId, Reply}) when is_map(Reply); is_list(Reply) ->
    gen_server:cast(Pid, {rpc9_reply_login, nklib_util:to_binary(UserId), Reply, TId});

reply(Pid, TId, {reply, Reply}) when is_map(Reply); is_list(Reply) ->
    gen_server:cast(Pid, {rpc9_reply_ok, Reply, TId});

reply(Pid, TId, {error, Error}) ->
    gen_server:cast(Pid, {rpc9_reply_error, Error, TId});

reply(Pid, TId, {ack, AckPid}) ->
    gen_server:cast(Pid, {rpc9_reply_ack, AckPid, TId}).




%% @private
get_local_started(SrvId) ->
    pg2:get_local_members({nkrpc9_client, SrvId}).


%% @private
get_all_started(SrvId) ->
    pg2:get_members({nkrpc9_client, SrvId}).




%% ===================================================================
%% Protocol
%% ===================================================================

-record(trans, {
    op :: term(),
    timer :: reference(),
    mon :: reference(),
    from :: {pid(), term()} | {async, pid(), term()}
}).

-record(reg, {
    event :: term(),
    index :: integer(),
    mon :: reference()
}).

-record(state, {
    srv_id :: nkservice:id(),
    session_id :: nkservice:session_id(),
    trans = #{} :: #{tid() => #trans{}},
    tid = 1 :: integer(),
    ping :: integer() | undefined,
    op_time :: integer(),
    ext_op_time :: integer(),
    local :: binary(),
    remote :: binary(),
    regs = [] :: [#reg{}],
    user_id = <<>> :: nkservice:user_id(),
    user_state = #{} :: nkservice:user_state()
}).


%% @private
-spec transports(nklib:scheme()) ->
    [nkpacket:transport()].

transports(_) -> [wss, ws].

-spec default_port(nkpacket:transport()) ->
    inet:port_number() | invalid.

default_port(ws) -> 9010;
default_port(wss) -> 9011.


%% ===================================================================
%% WS Protocol callbacks
%% ===================================================================

-spec conn_init(nkpacket:nkport()) ->
    {ok, #state{}}.

conn_init(NkPort) ->
    {ok, _Class, {nkrpc9_client, SrvId}} = nkpacket:get_id(NkPort),
    {ok, Local} = nkpacket:get_local_bin(NkPort),
    {ok, Remote} = nkpacket:get_remote_bin(NkPort),
    SessId = <<"session-", (nklib_util:luid())/binary>>,
    true = nklib_proc:reg({?MODULE, session, SessId}, <<>>),
    pg2:join({nkrpc9_client, SrvId}, self()),
    OpTime = nkserver:get_plugin_config(SrvId, nkrpc9_client, cmd_timeout),
    ExtTime = nkserver:get_plugin_config(SrvId, nkrpc9_client, ext_cmd_timeout),
    {ok, UserState} = nkpacket:get_user_state(NkPort),
    State1 = #state{
        srv_id = SrvId,
        session_id = SessId,
        local = Local,
        remote = Remote,
        op_time = OpTime,
        ext_op_time = ExtTime,
        user_state = UserState
    },
    set_debug(State1),
    ?LLOG(info, "new connection (~s, ~p)", [Remote, self()], State1),
    {ok, State2} = handle(rpc9_init, [SrvId, NkPort], State1),
    {ok, State2}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

conn_parse({text, Text}, NkPort, State) ->
    Msg = nklib_json:decode(Text),
    case Msg of
        #{<<"cmd">> := <<"ping">>, <<"tid">> := TId} ->
            send_reply_ok(#{}, TId, NkPort, State);
        #{<<"cmd">> := Cmd, <<"tid">> := TId} ->
            ?MSG("received ~s", [Msg], State),
            Cmd2 = get_cmd(Cmd, Msg),
            Data = maps:get(<<"data">>, Msg, #{}),
            process_server_req(Cmd2, Data, TId, NkPort, State);
        #{<<"event">> := Event} ->
            ?MSG("received event ~s", [Event], State),
            Data = maps:get(<<"data">>, Msg, #{}),
            process_server_event(Event, Data, State);
        #{<<"result">> := Result, <<"tid">> := TId} when is_binary(Result) ->
            case extract_op(TId, State) of
                {Trans, State2} ->
                    Data = maps:get(<<"data">>, Msg, #{}),
                    process_server_resp(Result, Data, Trans, NkPort, State2);
                not_found ->
                    ?LLOG(info,
                        "received client response for unknown req: ~p, ~p, ~p",
                        [Msg, TId, State#state.trans], State),
                    {ok, State}
            end;
        #{<<"ack">> := TId} ->
            case extract_op(TId, State) of
                {Trans, State2} ->
                    {ok, extend_op(TId, Trans, State2)};
                not_found ->
                    ?LLOG(info, "received client ack for unknown req: ~p ",
                        [Msg], State),
                    {ok, State}
            end;
        _ ->
            ?LLOG(notice, "received unrecognized msg: ~p", [Msg], State),
            {stop, normal, State}
    end;

conn_parse({binary, _Bin}, _NkPort, State) ->
    ?LLOG(warning, "received binary frame", [], State),
    error(binary_frame).


-spec conn_encode(term(), nkpacket:nkport()) ->
    {ok, nkpacket:outcoming()} | continue | {error, term()}.

conn_encode(Msg, _NkPort) when is_map(Msg); is_list(Msg) ->
    case nklib_json:encode(Msg) of
        error ->
            lager:warning("invalid json in ~p: ~p", [?MODULE, Msg]),
            {error, invalid_json};
        Json ->
            {ok, {text, Json}}
    end;

conn_encode(Msg, _NkPort) when is_binary(Msg) ->
    {ok, {text, Msg}}.


-spec conn_handle_call(term(), {pid(), term()}, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_call({rpc9_send_req, Cmd, Data}, From, NkPort, State) ->
    send_request(Cmd, Data, From, NkPort, State);

conn_handle_call(get_state, From, _NkPort, State) ->
    gen_server:reply(From, lager:pr(State, ?MODULE)),
    {ok, State};

conn_handle_call(Msg, From, _NkPort, State) ->
    handle(rpc9_handle_call, [Msg, From], State).


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_cast({rpc9_send_req, Cmd, Data}, NkPort, State) ->
    send_request(Cmd, Data, undefined, NkPort, State);

conn_handle_cast({rpc9_send_event, Event, Data}, NkPort, State) ->
    send_event(Event, Data, NkPort, State);

conn_handle_cast({rpc9_reply_ok, Reply, TId}, NkPort, State) ->
    case extract_op(TId, State) of
        {#trans{op=ack}, State3} ->
            send_reply_ok(Reply, TId, NkPort, State3);
        not_found ->
            ?LLOG(notice, "received user reply_ok for unknown req: ~p ~p",
                [TId, State#state.trans], State),
            {ok, State}
    end;

conn_handle_cast({rpc9_reply_error, Error, TId}, NkPort, State) ->
    case extract_op(TId, State) of
        {#trans{op=ack}, State2} ->
            send_reply_error(Error, TId, NkPort, State2);
        not_found ->
            ?LLOG(notice, "received user reply_error for unknown req: ~p ~p",
                [TId, State#state.trans], State),
            {ok, State}
    end;

conn_handle_cast(rpc9_stop, _NkPort, State) ->
    ?LLOG(info, "user stop", [], State),
    {stop, normal, State};

conn_handle_cast({rpc9_start_ping, Time}, _NkPort, #state{ping=Ping}=State) ->
    case Ping of
        undefined ->
            self() ! rpc9_send_ping;
        _ ->
            ok
    end,
    {ok, State#state{ping=Time}};

conn_handle_cast(Msg, _NkPort, State) ->
    handle(rpc9_handle_cast, [Msg], State).


-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_info({timeout, _, {rpc9_op_timeout, TId}}, _NkPort, State) ->
    case extract_op(TId, State) of
        {#trans{op=Op, from=From}, State2} ->
            Msg = #{<<"code">> => <<"timeout">>, <<"error">> => <<"Opertion timeout">>},
            nklib_util:reply(From, {ok, <<"error">>, Msg}),
            ?LLOG(notice, "operation ~p (~p) timeout!", [Op, TId], State),
            {stop, normal, State2};
        not_found ->
            {ok, State}
    end;

conn_handle_info({'EXIT', _PId, normal}, _NkPort, State) ->
    {ok, State};

conn_handle_info({'DOWN', Ref, process, _Pid, _Reason}=Info, NkPort, State) ->
    case extract_op_mon(Ref, State) of
        {true, TId, #trans{op=Op}, State2} ->
            ?LLOG(notice, "operation ~p (~p) process down!", [Op, TId], State),
            send_reply_error(process_down, TId, NkPort, State2);
        false ->
            handle(rpc9_handle_info, [Info], State)
    end;

conn_handle_info(Info, _NkPort, State) ->
    handle(rpc9_handle_info, [Info], State).


%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), #state{}) ->
    ok.

conn_stop(Reason, _NkPort, State) ->
    catch handle(rpc9_terminate, [Reason], State).


%% ===================================================================
%% Requests
%% ===================================================================

%% @private
process_server_req(Cmd, Data, TId, NkPort, State) ->
    #state{srv_id=SrvId, user_state=UserState} = State,
    Req = make_req(TId, State),
    case nkrpc9_process:request(SrvId, Cmd, Data, Req, UserState) of
        {reply, Reply, UserState2} ->
            send_reply_ok(Reply, TId, NkPort, State#state{user_state=UserState2});
        {ack, Pid, UserState2} ->
            State2 = insert_ack(TId, Pid, State),
            send_ack(TId, #{}, NkPort, State2#state{user_state=UserState2});
        {error, Error, UserState2} ->
            send_reply_error(Error, TId, NkPort, State#state{user_state=UserState2})
    end.


%% @private
process_server_event(Event, Data, #state{srv_id=SrvId, user_state=UserState}=State) ->
    Req = make_req(<<>>, State),
    case nkrpc9_process:event(SrvId, Event, Data, Req, UserState) of
        {ok, UserState2} ->
            {ok, State#state{user_state=UserState2}};
        {error, _Error, UserState2} ->
            {ok, State#state{user_state=UserState2}}
    end.


%% @private
process_server_resp(Result, Data, #trans{from=From}, _NkPort, State) ->
    nklib_util:reply(From, {ok, Result, Data}),
    {ok, State}.


%%%% @private
%%process_server_event(Event, NkPort, State) ->
%%    Req = make_req(<<>>, State),
%%    case handle(rpc9_server_event, [Event, Req#{timeout_pending=>false}], State) of
%%        {ok, State2} ->
%%            {ok, State2};
%%        {forward, Data2} ->
%%            Msg = #{
%%                cmd => <<"event">>,
%%                data => Data2
%%            },
%%            send(Msg, NkPort, State)
%%    end.



%% ===================================================================
%% Util
%% ===================================================================

%% @private
get_cmd(Cmd, Msg) ->
    Cmd2 = case Msg of
        #{<<"subclass">> := Sub} ->
            <<Sub/binary, $/, Cmd/binary>>;
        _ ->
            Cmd
    end,
    case Msg of
        #{<<"class">> := Class} ->
            <<Class/binary, $/, Cmd2/binary>>;
        _ ->
            Cmd2
    end.


%% @private
make_req(TId, State) ->
    #state{
        srv_id = SrvId,
        session_id = SessId,
        user_id = UserId,
        local = Local,
        remote = Remote
    } = State,
    #{
        srv => SrvId,
        start => nklib_util:l_timestamp(),
        session_id => SessId,
        session_pid => self(),
        local=>Local,
        remote=>Remote,
        tid => TId,
        user_id => UserId,
        timeout_pending => true,
        debug => get(nkrpc9_msgs)
    }.


%% @private
do_call(Pid, Msg) ->
    case self() of
        Pid ->
            {error, blocking_request};
        _ ->
            nklib_util:call(Pid, Msg, ?SYNC_CALL_TIMEOUT)
    end.


%% @private
insert_op(TId, Op, From, #state{trans=AllTrans, op_time=Time}=State) ->
    Trans = #trans{
        op = Op,
        from = From,
        timer = erlang:start_timer(Time, self(), {rpc9_op_timeout, TId})
    },
    State#state{trans=maps:put(TId, Trans, AllTrans)}.


%% @private
insert_ack(TId, Pid, #state{trans=AllTrans, ext_op_time=Time}=State) ->
    Mon = case is_pid(Pid) of
        true -> monitor(process, Pid);
        false -> undefined
    end,
    Trans = #trans{
        op = ack,
        mon = Mon,
        timer = erlang:start_timer(Time, self(), {rpc9_op_timeout, TId})
    },
    State#state{trans=maps:put(TId, Trans, AllTrans)}.


%% @private
extract_op(TId, #state{trans=AllTrans}=State) ->
    case maps:find(TId, AllTrans) of
        {ok, #trans{mon=Mon, timer=Timer}=OldTrans} ->
            nklib_util:cancel_timer(Timer),
            nklib_util:demonitor(Mon),
            State2 = State#state{trans=maps:remove(TId, AllTrans)},
            {OldTrans, State2};
        error ->
            not_found
    end.

%% @private
extract_op_mon(Mon, #state{trans=AllTrans}=State) ->
    case [TId || {TId, #trans{mon=M}} <- maps:to_list(AllTrans), M==Mon] of
        [TId] ->
            {OldTrans, State2} = extract_op(TId, State),
            {true, TId, OldTrans, State2};
        [] ->
            false
    end.


%% @private
extend_op(TId, #trans{timer=Timer}=Trans, #state{trans=AllTrans, ext_op_time=Time}=State) ->
    nklib_util:cancel_timer(Timer),
    ?LLOG(warning, "extended op, new time: ~p", [Time], State),
    Timer2 = erlang:start_timer(Time, self(), {rpc9_op_timeout, TId}),
    Trans2 = Trans#trans{timer=Timer2},
    State#state{trans=maps:put(TId, Trans2, AllTrans)}.


%% @private
send_request(Cmd, Data, From, NkPort, #state{tid=TId}=State) ->
    Msg1 = #{
        cmd => Cmd,
        tid => TId
    },
    Msg2 = if
        is_map(Data), map_size(Data)>0  ->
            Msg1#{data=>Data};
        is_list(Data) ->
            Msg1#{data=>Data};
        true ->
            Msg1
    end,
    State2 = insert_op(TId, Msg2, From, State),
    send(Msg2, NkPort, State2#state{tid=TId+1}).


%% @private
send_reply_ok(Data, TId, NkPort, State) ->
    Msg1 = #{
        result => ok,
        tid => TId
    },
    Msg2 = case Data of
        #{} when map_size(Data)==0 ->
            Msg1;
        #{} ->
            Msg1#{data=>Data};
        List when is_list(List) ->
            Msg1#{data=>Data}
    end,
    send(Msg2, NkPort, State).


%% @private
send_reply_error(Error, TId, NkPort, #state{srv_id=SrvId}=State) ->
    {Code, Text} = nkserver_msg:msg(SrvId, Error),
    Msg = #{
        result => error,
        tid => TId,
        data => #{
            code => Code,
            error => Text
        }
    },
    send(Msg, NkPort, State).


%% @private
send_ack(TId, Meta, NkPort, State) ->
    Msg = Meta#{ack => TId},
    send(Msg, NkPort, State).


%% @private
send_event(Event, Data, NkPort, State) ->
    Msg = #{
        event => Event,
        data => Data
    },
    send(Msg, NkPort, State).


%% @private
send(Msg, NkPort, State) ->
    case catch send(Msg, NkPort) of
        ok ->
            {ok, State};
        _ ->
            ?LLOG(notice, "error sending reply: ~p", [Msg], State),
            {stop, normal, State}
    end.


%% @private
send(Msg, NkPort) ->
    nkpacket_connection:send(NkPort, Msg).


%% @private
print(_Txt, [#{cmd:=<<"ping">>}], _State) ->
    ok;
print(Txt, [#{}=Map], State) ->
    print(Txt, [nklib_json:encode_pretty(Map)], State);
print(Txt, Args, State) ->
    ?LLOG(debug, Txt, Args, State).


set_debug(#state{srv_id = SrvId}=State) ->
    Debug = nkserver:get_plugin_config(SrvId, nkrpc9_client, debug),
    Protocol = lists:member(protocol, Debug),
    Msgs = lists:member(msgs, Debug),
    put(nkrpc9_protocol, Protocol),
    put(nkrpc9_msgs, Msgs),
    ?DEBUG("debug system activated", [], State),
    ?MSG("msgs system activated", [], State).


%% @private
handle(Fun, Args, State) ->
    nkserver_util:handle_user_call(Fun, Args, State, #state.srv_id, #state.user_state).
