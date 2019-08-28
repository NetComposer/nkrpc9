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

%% @doc Default plugin callbacks
-module(nkrpc9_server_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([msg/1]).
-export([rpc9_parse/4, rpc9_allow/4, rpc9_request/4, rpc9_event/4, rpc9_result/5]).
-export([rpc9_init/3, rpc9_handle_call/3, rpc9_handle_cast/2, rpc9_handle_info/2,
         rpc9_terminate/2]).
-export([rpc9_http/3]).

-include("nkrpc9.hrl").


-define(DEBUG(Txt, Args),
    case erlang:get(nkrpc9_debug) of
        true -> ?LLOG(debug, Txt, Args);
        _ -> ok
    end).


-define(LLOG(Type, Txt, Args),lager:Type("NkSERVER RPC9 Server "++Txt, Args)).


%% ===================================================================
%% Types
%% ===================================================================

-type request() :: nkrpc9_server:request().


%% ===================================================================
%% Msg Callbacks
%% ===================================================================

msg(invalid_login_request) -> "Invalid login request";
msg(_)   		           -> continue.


%% ===================================================================
%% REST Callbacks
%% ===================================================================

-type cmd() :: nkrpc9_server:cmd().
-type event() :: nkrpc9_server:event().
-type data() :: nkrpc9_server:data().
-type state() :: map().
-type continue() :: nkserver_callbacks:continue().
-type id() :: nkserver:module_id().
-type http_method() :: nkrpc9_server_http:method().
-type http_path() :: nkrpc9_server_http:path().
-type http_req() :: nkrpc9_server_http:req().
-type http_reply() :: nkrpc9_server_http:http_reply().
-type nkport() :: nkpacket:nkport().
-type op() :: #{cmd=>cmd(), data=>data(), tid=>integer()}.
-type result() :: binary().
-type from() :: {pid(), reference()}.



%% ===================================================================
%% WS Callbacks
%% ===================================================================


%% @doc Called for each request, to check its syntax
-spec rpc9_parse(cmd(), data(), request(), state()) -> 
    {ok, data(), state()} | {syntax, nklib_syntax:syntax(), state()} |
    {status, nkserver:status(), state()} |{error, nkserver:status(), state()}.
    
rpc9_parse(_Cmd, Data, _Req, State) ->
    {ok, Data, State}.


%% @doc Called for each request, to check its syntax
-spec rpc9_allow(cmd(), data(), request(), state()) ->
    true | {true, state()} | false.

rpc9_allow(_Cmd, _Data, _Req, _State) ->
    false.


%% @doc Called when then server receives a request
-spec rpc9_request(cmd(), data(), request(), state()) ->
    {login, UserId::binary(), data(), state()} |
    {reply, data(), state()} |
    {ack, pid()|undefined, state()} |
    {status, nkserver:status(), state()} |{error, nkserver:status(), state()}.

rpc9_request(_Cmd, _Data, _Req, State) ->
    {error, not_implemented, State}.


%% @doc Called when then server receives a request
-spec rpc9_event(event(), data(), request(), state()) ->
    {ok, state()} |
    {error, nkserver:status(), state()}.

rpc9_event(_Event, _Data, _Req, State) ->
    {ok, State}.


%% @doc Called when a result has been received and must be sent to the caller
-spec rpc9_result(result(), data(), op(), from(), state()) ->
    {reply, result(), data(), state()} | {noreply, state()}.

rpc9_result(Result, Data, _Op, _From, State) ->
    {reply, Result, Data, State}.


%% @doc Called when a new connection starts
-spec rpc9_init(id(), nkport(), state()) ->
    {ok, state()} | {stop, term()}.

rpc9_init(_Id, _NkPort, State) ->
    {ok, State}.


%% @doc Called when the process receives a handle_call/3.
-spec rpc9_handle_call(term(), {pid(), reference()}, state()) ->
    {ok, state()} | continue().

rpc9_handle_call(Msg, _From, State) ->
    ?LLOG(error, "unexpected call ~p", [Msg]),
    {ok, State}.


%% @doc Called when the process receives a handle_cast/3.
-spec rpc9_handle_cast(term(), state()) ->
    {ok, state()} | continue().

rpc9_handle_cast(Msg, State) ->
    ?LLOG(error, "unexpected cast ~p", [Msg]),
    {ok, State}.


%% @doc Called when the process receives a handle_info/3.
-spec rpc9_handle_info(term(), state()) ->
    {ok, state()} | continue().

rpc9_handle_info(Msg, State) ->
    ?LLOG(error, "unexpected info ~p", [Msg]),
    {ok, State}.


%% @doc Called when a service is stopped
-spec rpc9_terminate(term(), state()) ->
    {ok, state()}.

rpc9_terminate(_Reason, State) ->
    {ok, State}.


%% @doc called when a new http request has been received
-spec rpc9_http(http_method(), http_path(), http_req()) ->
    http_reply() |
    {redirect, Path::binary(), http_req()} |
    {cowboy_static, cowboy_static:opts()} |
    {cowboy_rest, Callback::module(), State::term()}.

rpc9_http(Method, Path, #{srv:=SrvId}=Req) ->
    #{remote:=Remote} = Req,
    ?LLOG(debug, "path not found (~p, ~s): ~p from ~s", [SrvId, Method, Path, Remote]),
    {http, 404, #{}, <<"NkSERVER RPC9: Path Not Found">>, Req}.



%% ===================================================================
%% Internal
%% ===================================================================

