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
-module(nkserver_rpc9_server_http).
-export([is_http/1, get_headers/1, get_qs/1, get_basic_auth/1]).
-export([init/4, terminate/3]).
-export_type([method/0, reply/0, code/0, headers/0, body/0, req/0, path/0, http_qs/0]).


-define(DEBUG(Txt, Args, State),
    case erlang:get(nkserver_rpc9_debug) of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, Req),
    lager:Type("NkSERVER RPC9 HTTP (~s, ~s) "++Txt,
               [maps:get(srv, Req), maps:get(remote, Req)|Args])).

-include_lib("nkserver/include/nkserver.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").
-include("nkserver_rpc9.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type method() :: binary().         %% <<"GET">> ...

-type code() :: 100 .. 599.

-type headers() :: #{binary() => iolist()}.

-type body() ::  Body::binary()|map().

-type http_qs() ::
    [{binary(), binary()|true}].

-type path() :: [binary()].

-type req() ::
    #{
        srv => nkserver:id(),
        method => method(),
        path => [binary()],
        peer => binary(),
        external_url => binary(),
        content_type => binary(),
        cowboy_req => term()
    }.


-type reply() ::
    {http, code(), headers(), body(), req()}.


%% ===================================================================
%% Public functions
%% ===================================================================


-spec is_http(req()) ->
    headers().

is_http(#{'_cowreq':=_}) -> true;
is_http(_) -> false.


-spec get_headers(req()) ->
    headers().

get_headers(#{'_cowreq':=CowReq}) ->
    cowboy_req:headers(CowReq);

get_headers(_) ->
    #{}.


%% @doc
-spec get_qs(req()) ->
    http_qs().

get_qs(#{'_cowreq':=CowReq}) ->
    cowboy_req:parse_qs(CowReq);

get_qs(_) ->
    #{}.


%% @doc
-spec get_basic_auth(req()) ->
    {ok, binary(), binary()} | undefined.

get_basic_auth(#{'_cowreq':=CowReq}) ->
    case cowboy_req:parse_header(<<"authorization">>, CowReq) of
        {basic, User, Pass} ->
            {ok, User, Pass};
        _ ->
            undefined
    end;

get_basic_auth(_) ->
    undefined.



%% ===================================================================
%% Callbacks
%% ===================================================================


%% @private
%% Called from nkpacket_transport_http:cowboy_init/5
init(<<"POST">>, [], CowReq, NkPort) ->
    Local = nkpacket:get_local_bin(NkPort),
    {Ip, Port} = cowboy_req:peer(CowReq),
    Remote = <<
        (nklib_util:to_host(Ip))/binary, ":",
        (to_bin(Port))/binary
    >>,
    {ok, _Class, {nkserver_rpc9_server, SrvId}} = nkpacket:get_id(NkPort),
    set_debug(SrvId),
    try
        case cowboy_req:method(CowReq) of
            <<"POST">> ->
                ok;
            _ ->
                throw({400, #{}, <<"Only POST is supported">>})
        end,
        {ok, Cmd, Data, CowReq2} = get_body(SrvId, CowReq),
        SessionId = nklib_util:luid(),
        Req = #{
            srv => SrvId,
            start => nklib_util:l_timestamp(),
            session_id => SessionId,
            session_pid => self(),
            local => Local,
            remote => Remote,
            tid => erlang:phash2(SessionId),
            cmd => Cmd,
            data => Data,
            timeout_pending => false,
            debug => get(nkserver_rpc9_debug),
            '_cowreq' => CowReq2
        },
        case nkserver_rpc9_process:request(SrvId, Cmd, Data, Req, #{}) of
            {login, _UserId, Reply, _State} ->
                send_msg_ok(Reply, CowReq2);
            {reply, Reply, _State} ->
                send_msg_ok(Reply, CowReq2);
            {ack, Pid, _State} ->
                Mon = case is_pid(Pid) of
                    true ->
                        monitor(process, Pid);
                    false ->
                        undefined
                end,
                wait_ack(Req, Mon);
            {error, Error, _State} ->
                send_msg_error(SrvId, Error, CowReq2)
        end
    catch
        throw:{Code, Hds, TReply} ->
            send_http_reply(Code, Hds, TReply, CowReq)
    end;

init(_, [], CowReq, _NkPort) ->
    send_http_reply(400, #{}, <<"Only POST is supported">>, CowReq);

init(_, _Path, CowReq, _NkPort) ->
    lager:error("NKLOG HTTP2"),
    send_http_reply(404, #{}, <<"Path not found">>, CowReq).



%% @private
terminate(_Reason, _Req, _Opts) ->
    ok.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
set_debug(SrvId) ->
    Debug = nkserver:get_plugin_config(SrvId, nkserver_rpc9_server, debug),
    Http = lists:member(protocol, Debug),
    put(nkserver_rpc9_debug, Http).


%% @private
get_body(SrvId, CowReq) ->
    MaxBody = nkserver:get_plugin_config(SrvId, nkserver_rpc9_server, http_max_body),
    case cowboy_req:body_length(CowReq) of
        BL when is_integer(BL), BL =< MaxBody ->
            %% https://ninenines.eu/docs/en/cowboy/2.1/guide/req_body/
            {ok, Body, CowReq2} = cowboy_req:read_body(CowReq, #{length=>infinity}),
              case cowboy_req:header(<<"content-type">>, CowReq) of
                <<"application/json">> ->
                    case nklib_json:decode(Body) of
                        error ->
                            throw({400, #{}, <<"Invalid json">>});
                        #{<<"cmd">>:=Cmd}=Json ->
                            Data = maps:get(<<"data">>, Json, #{}),
                            {ok, Cmd, Data, CowReq2};
                        _ ->
                            throw({400, <<"Invalid API body">>})
                    end;
                _ ->
                    throw({400, #{}, <<"Invalid Content-Type">>})
            end;
        BL ->
            lager:error("NKLOG Body is too large ~p", [BL]),
            throw({500, #{}, <<"Body too large">>})
    end.


%% @private
wait_ack(#{srv:=SrvId, tid:=TId, '_cowreq':=CowReq}=Req, Mon) ->
    ExtTime = nkserver:get_plugin_config(SrvId, nkserver_rpc9_server, ext_cmd_timeout),
    receive
        {'$gen_cast', {rpc9_reply_login, _UserId, Reply, TId}} ->
            nklib_util:demonitor(Mon),
            send_msg_ok(Reply, CowReq);
        {'$gen_cast', {rpc9_reply_ok, Reply, TId}} ->
            nklib_util:demonitor(Mon),
            send_msg_ok(Reply, CowReq);
        {'$gen_cast', {rpc9_reply_error, Error, TId}} ->
            nklib_util:demonitor(Mon),
            send_msg_error(SrvId, Error, CowReq);
        {'$gen_cast', {rpc9_reply_ack, undefined, TId}} ->
            wait_ack(Req, Mon);
        {'$gen_cast', {rpc9_reply_ack, Pid, TId}} when is_pid(Pid) ->
            nklib_util:demonitor(Mon),
            Mon2 = monitor(process, Pid),
            wait_ack(Req, Mon2);
        {'DOWN', Mon, process, _Pid, _Reason} ->
            send_msg_error(SrvId, process_down, CowReq);
        {'$gen_cast', rpc9_stop} ->
            ok;
        Other ->
            ?LLOG(warning, "unexpected msg in wait_ack: ~p", [Other], Req),
            wait_ack(Req, Mon)
    after
        ExtTime ->
            nklib_util:demonitor(Mon),
            send_msg_error(timeout, Req, CowReq)
    end.


%% @private
send_msg_ok(Reply, CowReq) ->
    Msg1 = #{result=>ok},
    Msg2 = case Reply of
        #{} when map_size(Reply)==0 -> Msg1;
        #{} -> Msg1#{data=>Reply};
        List when is_list(List) -> Msg1#{data=>Reply}
    end,
    send_http_reply(200, #{}, Msg2, CowReq).


%% @private
send_msg_error(SrvId, Error, CowReq) ->
    {Code, Text} = nkserver_msg:msg(SrvId, Error),
    Msg = #{
        result => error,
        data => #{
            code => Code,
            error => Text
        }
    },
    send_http_reply(200, #{}, Msg, CowReq).


%% @private
send_http_reply(Code, Hds, Body, CowReq) ->
    {Hds2, Body2} = case is_map(Body) orelse is_list(Body) of
        true ->
            {
                Hds#{<<"content-type">> => <<"application/json">>},
                nklib_json:encode(Body)
            };
        false ->
            {
                Hds,
                to_bin(Body)
            }
    end,
    {ok, cowboy_req:reply(Code, Hds2, Body2, CowReq), []}.




%% @private
to_bin(Term) when is_binary(Term) -> Term;
to_bin(Term) -> nklib_util:to_binary(Term).
