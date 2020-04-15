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
-module(nkrpc9_server_protocol).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([send_request/3, send_async_request/3, reply/3, reply/4, send_event/3, server_event/2]).
-export([start_ping/2, stop_ping/1]).
-export([stop/1, stop/2, get_all/1]).
-export([find_user/1, find_session/1]).
-export([get_all_started/1, get_local_started/1]).

-export([transports/1, default_port/1, resolve_opts/0]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_handle_call/4,
         conn_handle_cast/3, conn_handle_info/3, conn_stop/3]).
-export([http_init/4]).
-import(nkserver_trace, [trace/1, trace/2, log/2, log/3]).

-define(SYNC_CALL_TIMEOUT, 5000).     % Maximum sync call time


-include_lib("nkserver/include/nkserver.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type tid() :: integer().


%% ===================================================================
%% Public
%% ===================================================================


%% @doc
send_request(Pid, Cmd, Data) ->
    do_call(Pid, {rpc9_send_req, Cmd, Data}).


%% @doc
send_async_request(Pid, Cmd, Data) ->
    do_cast(Pid, {rpc9_send_req, Cmd, Data}).


% Send an event to the client
send_event(Pid, Event, Data) ->
    do_cast(Pid, {rpc9_send_event, Event, Data}).


% Server has generated an event
server_event(Pid, Event) ->
    do_cast(Pid, {rpc9_server_event, Event}).


%% @doc
reply(Pid, TId, Reply) ->
    reply(Pid, TId, Reply, undefined).


%% @doc
reply(Pid, TId, {login, UserId, Reply}, StateFun) ->
    do_cast(Pid, {rpc9_reply_login, UserId, Reply, TId, StateFun});

reply(Pid, TId, {reply, Reply}, StateFun) ->
    do_cast(Pid, {rpc9_reply_ok, Reply, TId, StateFun});

reply(Pid, TId, {error, Error}, StateFun) ->
    do_cast(Pid, {rpc9_reply_error, Error, TId, StateFun});

reply(Pid, TId, {status, Status}, StateFun) ->
    do_cast(Pid, {rpc9_reply_status, Status, TId, StateFun});

reply(Pid, TId, {ack, AckPid}, StateFun) ->
    do_cast(Pid, {rpc9_reply_ack, AckPid, TId, StateFun});

reply(Pid, TId, {stop, Reason, Reply}, StateFun) ->
    do_cast(Pid, {rpc9_reply_ok, Reply, TId, StateFun}),
    stop(Pid, Reason).


%% @doc Start sending pings
start_ping(Pid, MSecs) ->
    do_cast(Pid, {rpc9_start_ping, MSecs}).


%% @doc Stop sending pings
stop_ping(Pid) ->
    do_cast(Pid, rpc9_stop_ping).


%% @doc
stop(Pid) ->
    stop(Pid, normal).


%% @doc
stop(Pid, Reason) ->
    do_cast(Pid, {rpc9_stop, Reason}).


%% @private
-spec get_all(rpc9:id()) ->
    [{User::binary(), SessId::binary(), pid()}].

get_all(SrvId) ->
    [{User, SessId, Pid} || {{User, SessId}, Pid} <- nklib_proc:values({?MODULE, SrvId})].


get_local_started(SrvId) ->
    pg2:get_local_members({nkrpc9_server, SrvId}).


get_all_started(SrvId) ->
    pg2:get_members({nkrpc9_server, SrvId}).



%% @private
-spec find_user(string()|binary()) ->
    [{SessId::binary(), Meta::map(), pid()}].

find_user(User) ->
    User2 = nklib_util:to_binary(User),
    [
        {SessId, Meta, Pid} ||
        {{SessId, Meta}, Pid} <- nklib_proc:values({?MODULE, user, User2})
    ].


%% @private
-spec find_session(binary()) ->
    {ok, User::binary(), pid()} | not_found.

find_session(SessId) ->
    case nklib_proc:values({?MODULE, session, SessId}) of
        [{User, Pid}] -> {ok, User, Pid};
        [] -> not_found
    end.




%% ===================================================================
%% Protocol
%% ===================================================================

-record(trans, {
    op :: term(),
    timer :: reference(),
    mon :: reference(),
    from :: {pid(), term()} | {async, pid(), term()}
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
    local_port :: integer(),
    remote :: binary(),
    remote_port :: integer(),
    transport :: atom(),
    user_id = <<>> :: nkservice:user_id(),
    user_state = #{} :: nkservice:user_state()
}).


%% @private
-spec transports(nklib:scheme()) ->
    [nkpacket:transport()].

transports(_) -> [wss, ws, https, http].

-spec default_port(nkpacket:transport()) ->
    inet:port_number() | invalid.

default_port(ws) -> 9010;
default_port(wss) -> 9011;
default_port(http) -> 9010;
default_port(https) -> 9011.


%% @private
resolve_opts() ->
    #{resolve_type=>listen}.


%% ===================================================================
%% WS Protocol callbacks
%% ===================================================================

-spec conn_init(nkpacket:nkport()) ->
    {ok, #state{}}.

conn_init(NkPort) ->
    {ok, _Class, {nkrpc9_server, SrvId}} = nkpacket:get_id(NkPort),
    {ok, {_, _, LocalIp, LocalPort}} = nkpacket:get_local(NkPort),
    {ok, {_Proto, Transp, RemIp, RemPort}} = nkpacket:get_remote(NkPort),
    Local = nklib_util:to_host(LocalIp),
    Remote = nklib_util:to_host(RemIp),
    {ok, Opts} = nkpacket:get_opts(NkPort),
    SessId = nklib_util:luid(),
    true = nklib_proc:reg({?MODULE, session, SessId}, <<>>),
    pg2:join({nkrpc9_server, SrvId}, self()),
    OpTime = nkserver:get_cached_config(SrvId, nkrpc9_server, cmd_timeout),
    ExtTime = nkserver:get_cached_config(SrvId, nkrpc9_server, ext_cmd_timeout),
    {ok, UserState} = nkpacket:get_user_state(NkPort),
    State1 = #state{
        srv_id = SrvId,
        session_id = SessId,
        local = Local,
        local_port = LocalPort,
        transport = Transp,
        remote = Remote,
        remote_port = RemPort,
        op_time = OpTime,
        ext_op_time = ExtTime,
        user_state = UserState
    },
    Idle = maps:get(idle_timeout, Opts),
    SpanOpts = #{
        metadata => #{
            session_id => SessId,
            local => Local,
            local_port => LocalPort,
            remote => Remote,
            remote_port => RemPort,
            transport => Transp
        }
    },
    nkserver_trace:new_span(SrvId, {trace_nkrpc9_server, connection}, infinity, SpanOpts),
    log(info, "new connection (~s, ~p) (Idle:~p)", [Remote, self(), Idle]),
    {ok, State2} = handle(rpc9_init, [SrvId, NkPort], NkPort, State1),
    log(debug, "connection initialized"),
    {ok, State2}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    log(debug, "connection closed"),
    {ok, State};

conn_parse({text, Text}, NkPort, State) ->
    Msg = nklib_json:decode(Text),
    case Msg of
        #{<<"cmd">> := Cmd, <<"tid">> := TId} ->
            Msg2 = nkserver_trace:clean(Msg),
            log(info, "cmd received ~p", [Msg2]),
            Cmd2 = get_cmd(Cmd, Msg),
            Data = maps:get(<<"data">>, Msg, #{}),
            process_client_req(Cmd2, Data, TId, NkPort, State);
        #{<<"event">> := Event} ->
            Data = maps:get(<<"data">>, Msg, #{}),
            log(info, "event received ~s", [Msg]),
            process_client_event(Event, Data, State);
        #{<<"result">> := Result, <<"tid">> := TId} when is_binary(Result) ->
            case extract_op(TId, State) of
                {Trans, State2} ->
                    case Trans of
                        #trans{op=#{cmd:=<<"ping">>}} ->
                            ok;
                        _ ->
                            log(info, "result received ~s", [Msg])
                    end,
                    Data = maps:get(<<"data">>, Msg, #{}),
                    process_client_resp(Trans, Result, Data, State2);
                not_found ->
                    log(info, "received client response for unknown req: ~p, ~p, ~p",
                        [Msg, TId, State#state.trans]),
                    {ok, State}
            end;
        #{<<"ack">> := TId} ->
            trace("ack received ~s", [TId]),
            case extract_op(TId, State) of
                {Trans, State2} ->
                    {ok, extend_op(TId, Trans, State2)};
                not_found ->
                    log(info, "received client ack for unknown req: ~p ", [Msg]),
                    {ok, State}
            end;
        _ ->
            log(notice, "received unrecognized msg: ~p", [Msg]),
            {stop, normal, State}
    end;

conn_parse({binary, _Bin}, _NkPort, _State) ->
    log(warning, "received binary frame", []),
    error(binary_frame).


-spec conn_encode(term(), nkpacket:nkport()) ->
    {ok, nkpacket:outcoming()} | continue | {error, term()}.

conn_encode(Msg, _NkPort) when is_map(Msg); is_list(Msg) ->
    case nklib_json:encode(Msg) of
        error ->
            log(warning, "invalid json in ~p: ~p", [?MODULE, Msg]),
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

conn_handle_call(Msg, From, NkPort, State) ->
    handle(rpc9_handle_call, [Msg, From], NkPort, State).


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_cast({rpc9_send_req, Cmd, Data}, NkPort, State) ->
    send_request(Cmd, Data, undefined, NkPort, State);

conn_handle_cast({rpc9_send_event, Event, Data}, NkPort, State) ->
    send_event(Event, Data, NkPort, State);

conn_handle_cast({rpc9_reply_login, UserId2, Reply, TId, StateFun}, NkPort, State) ->
    #state{user_id=UserId} = State,
    case extract_op(TId, State) of
        {#trans{op=ack}, State2} ->
            State3 = apply_user_state(StateFun, State2),
            case UserId == <<>> andalso UserId2 /= <<>> of
                true ->
                    process_login(UserId2, Reply, TId, NkPort, State3);
                false when UserId /= UserId2 ->
                    send_reply_error(invalid_login_request, TId, NkPort, State3);
                false ->
                    send_reply_ok(Reply, TId, NkPort, State3)
            end;
        not_found ->
            log(notice, "received user reply_ok for unknown req: ~p ~p",
                [TId, State#state.trans]),
            {ok, State}
    end;

conn_handle_cast({rpc9_reply_ok, Reply, TId, StateFun}, NkPort, State) ->
    case extract_op(TId, State) of
        {#trans{op=ack}, State2} ->
            State3 = apply_user_state(StateFun, State2),
            send_reply_ok(Reply, TId, NkPort, State3);
        not_found ->
            log(notice, "received user reply_ok for unknown req: ~p ~p",
                [TId, State#state.trans]),
            {ok, State}
    end;

conn_handle_cast({rpc9_reply_status, Status, TId, StateFun}, NkPort, State) ->
    case extract_op(TId, State) of
        {#trans{op=ack}, State2} ->
            State3 = apply_user_state(StateFun, State2),
            send_reply_status(Status, TId, NkPort, State3);
        not_found ->
            log(notice, "received user reply_error for unknown req: ~p ~p",
                [TId, State#state.trans]),
            {ok, State}
    end;

conn_handle_cast({rpc9_reply_error, Error, TId, StateFun}, NkPort, State) ->
    case extract_op(TId, State) of
        {#trans{op=ack}, State2} ->
            State3 = apply_user_state(StateFun, State2),
            send_reply_error(Error, TId, NkPort, State3);
        not_found ->
            log(notice, "received user reply_error for unknown req: ~p ~p",
                [TId, State#state.trans]),
            {ok, State}
    end;

conn_handle_cast({rpc9_reply_ack, Pid, TId, Meta, StateFun}, NkPort, State) ->
    case extract_op(TId, State) of
        {#trans{op=ack}, State2} ->
            State3 = insert_ack(TId, Pid, State2),
            State4 = apply_user_state(StateFun, State3),
            send_ack(TId, Meta, NkPort, State4);
        not_found ->
            log(notice, "received user reply_ack for unknown req", []),
            {ok, State}
    end;

conn_handle_cast({rpc9_stop, Reason}, _NkPort, State) ->
    log(info, "user stop: ~p", [Reason]),
    {stop, normal, State};

conn_handle_cast({rpc9_start_ping, MSecs}, _NkPort, #state{ping=Ping}=State) ->
    case Ping of
        undefined ->
            self() ! rpc9_send_ping;
        _ ->
            ok
    end,
    {ok, State#state{ping=MSecs}};

conn_handle_cast(rpc9_stop_ping, _NkPort, State) ->
    {ok, State#state{ping=undefined}};

conn_handle_cast(Msg, NkPort, State) ->
    handle(rpc9_handle_cast, [Msg], NkPort, State).


-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_info(rpc9_send_ping, _NkPort, #state{ping=undefined}=State) ->
    {ok, State};

conn_handle_info(rpc9_send_ping, NkPort, #state{ping=Time}=State) ->
    erlang:send_after(Time, self(), rpc9_send_ping),
    send_request(<<"ping">>, #{time=>Time}, undefined, NkPort, State);

conn_handle_info({timeout, _, {rpc9_op_timeout, TId}}, _NkPort, State) ->
    case extract_op(TId, State) of
        {#trans{op=Op, from=From}, State2} ->
            Msg = #{<<"code">> => <<"timeout">>, <<"error">> => <<"Operation timeout">>},
            nklib_util:reply(From, {ok, <<"error">>, Msg}),
            log(info, "operation ~p (~p) timeout!", [Op, TId]),
            {stop, normal, State2};
        not_found ->
            {ok, State}
    end;

conn_handle_info({'EXIT', _Pid, _}, _NkPort, State) ->
    % We don't care about linked process with us that fail or stop
    {ok, State};

conn_handle_info({'DOWN', Ref, process, Pid, Reason}=Info, NkPort, State) ->
    case extract_op_mon(Ref, State) of
        {true, TId, #trans{op=Op}, State2} ->
            log(info, "operation ~p (~p) process down! (~p, ~p)",
                  [Op, TId, Pid, Reason]),
            send_reply_error(process_down, TId, NkPort, State2);
        false ->
            handle(rpc9_handle_info, [Info], NkPort, State)
    end;

conn_handle_info(Info, NkPort, State) ->
    handle(rpc9_handle_info, [Info], NkPort, State).


%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), #state{}) ->
    ok.

conn_stop(Reason, NkPort, State) ->
    catch handle(rpc9_terminate, [Reason], NkPort, State),
    nkserver_trace:finish_span(),
    ok.

%% ===================================================================
%% HTTP Protocol callbacks
%% ===================================================================

%% For HTTP based connections, http_init is called
%% See nkpacket_protocol

http_init(Paths, CowReq, _Env, NkPort) ->
    Method = cowboy_req:method(CowReq),
    nkrpc9_server_http:init(Method, Paths, CowReq, NkPort).



%% ===================================================================
%% Requests
%% ===================================================================

%% @private
process_client_req(Cmd, Data, TId, NkPort, State) ->
    #state{
        srv_id = SrvId,
        user_id = UserId,
        user_state = UserState,
        session_id = SessId,
        transport = Transp
    } = State,
    Fun = fun() ->
        Req = make_req(TId, State),
        case nkrpc9_process:request(SrvId, Cmd, Data, Req, UserState) of
            {login, UserId2, Reply, UserState2} ->
                State2 = apply_user_state(UserState2, State),
                case UserId == <<>> andalso UserId2 /= <<>> of
                    true ->
                        process_login(UserId2, Reply, TId, NkPort, State2);
                    false when UserId /= UserId2 ->
                        send_reply_error(invalid_login_request, TId, NkPort, State2);
                    false ->
                        send_reply_ok(Reply, TId, NkPort, State2)
                end;
            {reply, Reply, UserState2} ->
                send_reply_ok(Reply, TId, NkPort, apply_user_state(UserState2, State));
            {ack, Pid, UserState2} ->
                State2 = insert_ack(TId, Pid, apply_user_state(UserState2, State)),
                send_ack(TId, #{}, NkPort, State2#state{user_state=UserState2});
            {status, Status, UserState2} ->
                send_reply_status(Status, TId, NkPort, apply_user_state(UserState2, State));
            {error, Error, UserState2} ->
                send_reply_error(Error, TId, NkPort, apply_user_state(UserState2, State));
            {stop, _Reason, Reply, UserState2} ->
                stop(self()),
                send_reply_ok(Reply, TId, NkPort, apply_user_state(UserState2, State))
        end
    end,
    Opts = #{
        parent=>none,
        metadata => #{user_uid=>UserId, session_id=>SessId, transport=>Transp}
    },
    nkserver_trace:new_span(SrvId, {trace_nkrpc9_server_ws, request, Cmd}, Fun, Opts).


%% @private
process_client_event(Event, Data, #state{srv_id=SrvId, user_state=UserState}=State) ->
    Req = make_req(<<>>, State),
    case nkrpc9_process:event(SrvId, Event, Data, Req, UserState) of
        {ok, UserState2} ->
            {ok, State#state{user_state=UserState2}};
        {error, _Error, UserState2} ->
            {ok, State#state{user_state=UserState2}};
        {stop, _Reason, UserState2} ->
            {ok, State#state{user_state=UserState2}}
    end.


%% @private
process_client_resp(#trans{op=Op, from=From}, Result, Data, State) ->
    #state{srv_id = SrvId, user_state = UserState} = State,
    {ok, UserState2} = nkrpc9_process:result(SrvId, Result, Data, Op, From, UserState),
    {ok, State#state{user_state = UserState2}}.



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
        class => nkrpc9_server_ws,
        srv => SrvId,
        start => nklib_util:l_timestamp(),
        session_id => SessId,
        session_pid => self(),
        local => Local,
        remote => Remote,
        tid => TId,
        user_id => UserId,
        timeout_pending => true,
        debug => get(nkrpc9_msgs)
    }.


%% @private
process_login(UserId, Reply, TId, NkPort, State) ->
    #state{
        srv_id = SrvId,
        session_id = SessId,
        user_state = UserState
    } = State,
    PingTime = nkserver:get_cached_config(SrvId, nkrpc9_server, ping_interval),
    nklib_proc:put({?MODULE, user, UserId}, {SessId, UserState}),
    nklib_proc:put({?MODULE, session, SessId}, UserId),
    start_ping(self(), PingTime),
    send_reply_ok(Reply, TId, NkPort, State#state{user_id = UserId}).


%% @private
do_call(Pid, Msg) ->
    case self() of
        Pid ->
            {error, blocking_request};
        _ ->
            nklib_util:call(Pid, Msg, ?SYNC_CALL_TIMEOUT)
    end.


%% @private
do_cast(Pid, Msg) ->
    gen_server:cast(Pid, Msg).


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
    log(debug, "extended op, new time: ~p", [Time]),
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
send_reply_error(#{status:=Error}=Status, TId, NkPort, State) ->
    Msg = #{
        result => error,
        tid => TId,
        data => #{
            code => maps:get(code, Status, 400),
            error => Error,
            info => maps:get(info, Status, <<>>),
            data => maps:get(data, Status, #{})
        }
    },
    send(Msg, NkPort, State);

send_reply_error(Error, TId, NkPort, #state{srv_id=SrvId}=State) ->
    #{status:=_} = Error2 = nkserver_status:status(SrvId, Error),
    send_reply_error(Error2, TId, NkPort, State).


%% @private
send_reply_status(#{status:=Result}=Status, TId, NkPort, State) ->
    Msg = #{
        result => status,
        tid => TId,
        data => #{
            code => maps:get(code, Status, 200),
            status => Result,
            info => maps:get(info, Status, <<>>),
            data => maps:get(data, Status, #{})
        }
    },
    send(Msg, NkPort, State);

send_reply_status(Status, TId, NkPort, #state{srv_id=SrvId}=State) ->
    #{status:=_} = Status2 = nkserver_status:status(SrvId, Status),
    send_reply_status(Status2, TId, NkPort, State).


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
    log(debug, "sending ~p", [Msg]),
    case catch send(Msg, NkPort) of
        ok ->
            {ok, State};
        _ ->
            log(notice, "error sending reply: ~p", [Msg]),
            {stop, normal, State}
    end.


%% @private
send(Msg, NkPort) ->
    nkpacket_connection:send(NkPort, Msg).


%%%% @private
%%print(_Txt, [#{cmd:=<<"ping">>}], _State) ->
%%    ok;
%%print(Txt, [#{}=Map], State) ->
%%    print(Txt, [nklib_json:encode_pretty(Map)], State);
%%print(Txt, Args, _State) ->
%%    log(debug, Txt, Args).



%%%% @private
%%set_debug(#state{srv_id = SrvId}) ->
%%    Debug = nkserver:get_cached_config(SrvId, nkrpc9_server, debug),
%%    Protocol = lists:member(protocol, Debug),
%%    Msgs = lists:member(msgs, Debug),
%%    put(nkrpc9_protocol, Protocol),
%%    put(nkrpc9_msgs, Msgs).


%% @private
%% Will call the service's functions
handle(Fun, Args, NkPort, #state{srv_id=SrvId, user_state=UserState}=State) ->
    case ?CALL_SRV(SrvId, Fun, Args++[UserState]) of
        {reply, Reply, UserState2} ->
            {reply, Reply, State#state{user_state=UserState2}};
        {reply, Reply, UserState2, Time} ->
            {reply, Reply, State#state{user_state=UserState2}, Time};
        {noreply, UserState2} ->
            {noreply, State#state{user_state=UserState2}};
        {noreply, UserState2, Time} ->
            {noreply, State#state{user_state=UserState2}, Time};
        {stop, Reason, Reply, UserState2} ->
            {stop, Reason, Reply, State#state{user_state=UserState2}};
        {stop, Reason, UserState2} ->
            {stop, Reason, State#state{user_state=UserState2}};
        {ok, UserState2} ->
            {ok, State#state{user_state=UserState2}};
        {send_request, Cmd, Data, From,UserState2} ->
            send_request(Cmd, Data, From, NkPort, State#state{user_state=UserState2});
        {send_request, Cmd, Data, UserState2} ->
            send_request(Cmd, Data, undefined, NkPort, State#state{user_state=UserState2});
        {send_event, Cmd, Data, UserState2} ->
            send_event(Cmd, Data, NkPort, State#state{user_state=UserState2});
        continue ->
            continue;
        Other ->
            lager:warning("invalid response for ~p:~p(~p): ~p", [SrvId, Fun, Args, Other]),
            error(invalid_handle_response)
    end.


%% @private
apply_user_state(undefined, State) ->
    State;

apply_user_state(Map, State) when is_map(Map)->
    State#state{user_state = Map};

apply_user_state(Fun, #state{user_state=UserState}=State) when is_function(Fun, 1) ->
    State#state{user_state = Fun(UserState)}.
