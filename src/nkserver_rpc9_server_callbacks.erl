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
-module(nkserver_rpc9_server_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([msg/1]).
-export([request/3]).
-export([rpc9_parse/4, rpc9_allow/4, rpc9_request/4, rpc9_event/3]).
-export([rpc9_subscribe/2, rpc9_unsubscribe/2]).
-export([rpc9_init/3, rpc9_handle_call/3, rpc9_handle_cast/2, rpc9_handle_info/2,
         rpc9_terminate/2]).

-include("nkserver_rpc9.hrl").


-define(DEBUG(Txt, Args),
    case erlang:get(nkserver_rpc9_debug) of
        true -> ?LLOG(debug, Txt, Args);
        _ -> ok
    end).


-define(LLOG(Type, Txt, Args),lager:Type("NkSERVER RPC9 Server "++Txt, Args)).


%% ===================================================================
%% Types
%% ===================================================================

-type request() :: nkserver_rpc9_server:request().


%% ===================================================================
%% Msg Callbacks
%% ===================================================================

msg(invalid_login_request) -> "Invalid login request";
msg(_)   		           -> continue.


%% ===================================================================
%% REST Callbacks
%% ===================================================================

-type cmd() :: nkserver_rpc9_server:cmd().
-type data() :: nkserver_rpc9_server:data().
-type state() :: nkapi_server:user_state().
-type continue() :: nkserver_callbacks:continue().
-type id() :: nkserver:module_id().
-type http_method() :: nkserver_rpc9_server_http:method().
-type http_path() :: nkserver_rpc9_server_http:path().
-type http_req() :: nkserver_rpc9_server_http:req().
-type http_reply() :: nkserver_rpc9_server_http:http_reply().
-type nkport() :: nkpacket:nkport().


%% @doc called when a new http request has been received
-spec request(http_method(), http_path(), http_req()) ->
    http_reply() |
    {redirect, Path::binary(), http_req()} |
    {cowboy_static, cowboy_static:opts()} |
    {cowboy_rest, Callback::module(), State::term()}.

request(Method, Path, #{srv:=SrvId}=Req) ->
    #{peer:=Peer} = Req,
    ?LLOG(debug, "path not found (~p, ~s): ~p from ~s", [SrvId, Method, Path, Peer]),
    {http, 404, [], <<"NkSERVER RPC9: Path Not Found">>, Req}.

%%request(SrvId, Method, Path, #{srv:=SrvId}=Req) ->
%%    case nkserver:get_plugin_config(SrvId, nkserver_rpc9, requestCallBack) of
%%        #{class:=luerl, luerl_fun:=_}=CB ->
%%            case nkserver_luerl_instance:spawn_callback_spec(SrvId, CB) of
%%                {ok, Pid} ->
%%                    process_luerl_req(SrvId, CB, Pid, Req);
%%                {error, too_many_instances} ->
%%                    {http, 429, [], <<"NkSERVER RPC9: Too many requests">>, Req}
%%            end;
%%        _ ->
%%            % There is no callback defined
%%            #{peer:=Peer} = Req,
%%            ?LLOG(debug, "path not found (~p, ~s): ~p from ~s", [SrvId, Method, Path, Peer]),
%%            {http, 404, [], <<"NkSERVER RPC9: Path Not Found">>, Req}
%%    end.



%% ===================================================================
%% WS Callbacks
%% ===================================================================


%% @doc Called for each request, to check its syntax
-spec rpc9_parse(cmd(), data(), request(), state()) -> 
    {ok, data(), state()} | {syntax, nklib_syntax:syntax(), state()} | {error, term()}.
    
rpc9_parse(_Cmd, Data, _Req, State) ->
    {ok, Data, State}.


%% @doc Called for each request, to check its syntax
-spec rpc9_allow(cmd(), data(), request(), state()) ->
    true | {true, state()} | false.

rpc9_allow(_Cmd, _Data, _Req, _State) ->
    false.


%% @doc Called when then client sends a request
-spec rpc9_request(cmd(), data(), request(), state()) ->
    {login, UserId::binary(), data(), state()} |
    {reply, data(), state()} |
    {ack, pid()|undefined, state()} |
    {error, nkserver:msg(), state()}.

rpc9_request(_Cmd, _Data, _Req, State) ->
    {error, not_implemented, State}.


%% @doc Called when then client sends a request
-spec rpc9_event(data(), request(), state()) ->
    {ok, state()} |
    {error, nkserver:msg(), state()}.

rpc9_event(_Data, _Req, State) ->
    {ok, State}.


%% @doc
-spec rpc9_subscribe(term(), state()) ->
    {ok, state()}.

rpc9_subscribe(_Event, State) ->
    {ok, State}.


%% @doc Called when a new connection starts
-spec rpc9_unsubscribe(term(), state()) ->
    {ok, state()}.

rpc9_unsubscribe(_Event, State) ->
    {ok, State}.


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
    ?LLOG(error, "unexpected cast ~p", [Msg]),
    {ok, State}.


%% @doc Called when a service is stopped
-spec rpc9_terminate(term(), state()) ->
    {ok, state()}.

rpc9_terminate(_Reason, State) ->
    {ok, State}.




%% ===================================================================
%% Internal
%% ===================================================================

