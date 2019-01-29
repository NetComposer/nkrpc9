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
-module(nkrpc9_process).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([request/5, event/5]).
-include_lib("nkserver/include/nkserver.hrl").


-define(DEBUG(Txt, Args, State),
    case erlang:get(nkrpc9_debug) of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, Req),
    lager:Type(
        [
            {session_id, maps:get(session_id, Req)},
            {srv_id, maps:get(srv, Req)},
            {user_id, maps:get(user_id, Req, <<>>)}
        ],
        "RPC9 Server ~s (~s) (~s) "++Txt,
        [
            maps:get(session_id, Req),
            maps:get(srv, Req),
            maps:get(user_id, Req, <<>>)
            | Args
        ])).


%% @doc
request(SrvId, Cmd, Data, Req, State) ->
    request_parse(SrvId, Cmd, Data, Req, State).


%% @doc
event(SrvId, Event, Data, Req, State) ->
    event_parse(SrvId, Event, Data, Req, State).



%% @private
request_parse(SrvId, Cmd, Data, Req, State) ->
    case ?CALL_SRV(SrvId, rpc9_parse, [Cmd, Data, Req, State]) of
        {syntax, Syntax} ->
            case nklib_syntax:parse(Data, Syntax) of
                {ok, Data2, []} ->
                    request_allow(SrvId, Cmd, Data2, Req, State);
                {ok, Data2, Unknown} ->
                    Req2 = Req#{unknown_fields => Unknown},
                    request_allow(SrvId, Cmd, Data2, Req2, State);
                {error, Error} ->
                    {error, Error, State}
            end;
        {syntax, Syntax, State2} ->
            case nklib_syntax:parse(Data, Syntax) of
                {ok, Data2, []} ->
                    request_allow(SrvId, Cmd, Data2, Req, State2);
                {ok, Data2, Unknown} ->
                    Req2 = Req#{unknown_fields => Unknown},
                    request_allow(SrvId, Cmd, Data2, Req2, State2);
                {error, Error} ->
                    {error, Error, State2}
            end;
        {ok, Data2} ->
            request_allow(SrvId, Cmd, Data2, Req, State);
        {ok, Data2, State2} ->
            request_allow(SrvId, Cmd, Data2, Req, State2);
        {error, Error} ->
            {error, Error, State};
        {error, Error, State2} ->
            {error, Error, State2}
    end.


%% @private
request_allow(SrvId, Cmd, Data, Req, State) ->
    case ?CALL_SRV(SrvId, rpc9_allow, [Cmd, Data, Req, State]) of
        true ->
            request_process(SrvId, Cmd, Data, Req, State);
        {true, State2} ->
            request_process(SrvId, Cmd, Data, Req, State2);
        false ->
            ?DEBUG("request NOT allowed", [], Req),
            {error, unauthorized, State}
    end.


%% @private
request_process(SrvId, Cmd, Data, Req, State) ->
    ?DEBUG("request allowed", [], Req),
    case ?CALL_SRV(SrvId, rpc9_request, [Cmd, Data, Req, State]) of
        {login, UserId, Reply} ->
            Reply2 = case maps:find(unknown_fields, Req) of
                {ok, Fields} ->
                    Reply#{unknown_fields=>Fields};
                error ->
                    Reply
            end,
            {login, UserId, Reply2, State};
        {login, UserId, Reply, State2} ->
            Reply2 = case maps:find(unknown_fields, Req) of
                {ok, Fields} ->
                    Reply#{unknown_fields=>Fields};
                error ->
                    Reply
            end,
            {login, UserId, Reply2, State2};
        {reply, Reply, State2} ->
            Reply2 = case maps:find(unknown_fields, Req) of
                {ok, Fields} ->
                    Reply#{unknown_fields=>Fields};
                error ->
                    Reply
            end,
            {reply, Reply2, State2};
        {reply, Reply} ->
            Reply2 = case maps:find(unknown_fields, Req) of
                {ok, Fields} ->
                    Reply#{unknown_fields=>Fields};
                error ->
                    Reply
            end,
            {reply, Reply2, State};
        ack ->
            {ack, undefined, State};
        {ack, Pid} ->
            {ack, Pid, State};
        {ack, Pid, State2} ->
            {ack, Pid, State2};
        {error, Error} ->
            {error, Error, State};
        {error, Error, State2} ->
            {error, Error, State2}
    end.


%% @private
event_parse(SrvId, Event, Data, Req, State) ->
    case ?CALL_SRV(SrvId, rpc9_parse, [Event, Data, Req, State]) of
        {syntax, Syntax, State2} ->
            case nklib_syntax:parse(Data, Syntax) of
                {ok, Data2, _} ->
                    event_process(SrvId, Event, Data2, Req, State2);
                {error, Error} ->
                    {error, Error, State2}
            end;
        {syntax, Syntax} ->
            case nklib_syntax:parse(Data, Syntax) of
                {ok, Data2, _} ->
                    event_process(SrvId, Event, Data2, Req, State);
                {error, Error} ->
                    {error, Error, State}
            end;
        {ok, Data2} ->
            event_process(SrvId, Event, Data2, Req, State);
        {ok, Data2, State2} ->
            event_process(SrvId, Event, Data2, Req, State2);
        {error, Error} ->
            {error, Error, State};
        {error, Error, State2} ->
            {error, Error, State2}
    end.


%% @private
event_process(SrvId, Event, Data, Req, State) ->
    case ?CALL_SRV(SrvId, rpc9_event, [Event, Data, Req, State]) of
        ok ->
            {ok, State};
        {ok, State2} ->
            {ok, State2};
        {error, Error} ->
            {error, Error};
        {error, Error, State2} ->
            {error, Error, State2}
    end.
