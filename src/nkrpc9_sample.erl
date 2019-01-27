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
-module(nkrpc9_sample).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include_lib("nkserver/include/nkserver_module.hrl").

-export([start/0, stop/0]).
-export([to_server/0, to_client/0, server_times/0, client_times/0, http/0]).
-export([rpc9_parse/4, rpc9_allow/4, rpc9_request/4, rpc9_event/4]).

-dialyzer({nowarn_function, start/0}).

%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts the service
start() ->
    {ok, _} = nkrpc9_server:start_link(server, #{
        use_module => ?MODULE,
        url => "https://node:9010/test1, wss:node:9010/test1/ws;idle_timeout=60000",
        opts => #{
            % Look for 'starting Ranch' debug message
            % nkpacket_cowboy:init/1
            idle_timeout => 60001,
            http_max_headers => 100,
            http_inactivity_timeout => 60000,
            http_request_timeout => 120000
        },
        cmd_timeout => 600,
        ext_cmd_timeout => 1200,
        ping_interval => 10000,
        debug => [nkpacket, protocol, msgs]
    }),
    timer:sleep(500),
    {ok, _} = nkrpc9_client:start_link(client, #{
        use_module => ?MODULE,
        url => "wss:127.0.0.1:9010/test1/ws",
        cmd_timeout => 500,
        ext_cmd_timeout => 1000,
        debug => [protocol, msgs]
    }).



%% @doc Stops the service
stop() ->
    nkrpc9_client:stop(client),
    nkrpc9_server:stop(server).



to_server() ->
    % Command not yet authorized
    {ok, <<"error">>, #{<<"code">>:=<<"unauthorized">>}} =
        nkrpc9_client:send_request(client, cmd1, #{}),

    % Successful login
    {ok, <<"ok">>, #{<<"meta">>:=2, <<"unknown_fields">>:=[<<"other">>]}} =
        nkrpc9_client:send_request(client, login, #{name=>name1, other=>1}),
    [{ServerSess1, undefined, ServerPid1}] = nkrpc9_server_protocol:find_user(<<"name1">>),
    {ok, <<"name1">>, ServerPid1} = nkrpc9_server_protocol:find_session(ServerSess1),

    % Missing field
    {ok, <<"error">>, #{<<"code">>:=<<"field_missing">>, <<"error">>:=<<"Missing field: 'name'">>}} =
        nkrpc9_client:send_request(client, login, #{name1=>name1, other=>1}),

    % Re-login with a different user
    {ok, <<"error">>, #{<<"code">>:=<<"invalid_login_request">>}} =
        nkrpc9_client:send_request(client, login, #{name=>name2}),

    % Command is now authorized
    {ok, <<"ok">>, #{<<"out">>:=1}} =
        nkrpc9_client:send_request(client, cmd1, #{}),

    % Send event to server
    Ref = make_ref(),
    Event = #{ref=>base64:encode(term_to_binary({self(), Ref}))},
    ok = nkrpc9_client:send_event(client, event1, Event),
    receive Ref -> ok after 1000 -> error(?LINE) end,
    ok.


client_times() ->
    {ok, <<"ok">>, #{}} = nkrpc9_client:send_request(client, login, #{name=>name1}),
    [Pid1] = nkrpc9_client_protocol:get_local_started(client),
    {ok, <<"error">>, #{<<"code">>:=<<"timeout">>}} =
        nkrpc9_client:send_request(client, slow1, #{}),
    % The client has stopped, supervisor will start it again
    % Ensure it stopped
    timer:sleep(500),
    [Pid2] = nkrpc9_client_protocol:get_local_started(client),
    false = Pid1 == Pid2,

    {ok, <<"ok">>, #{}} = nkrpc9_client:send_request(client, login, #{name=>name1}),
    {ok, <<"ok">>, #{}} = nkrpc9_client:send_request(client, slow2, #{}),

    {ok, <<"error">>, #{<<"code">>:=<<"timeout">>}} =
        nkrpc9_client:send_request(client, slow3, #{}),
    timer:sleep(500),
    [Pid3] = nkrpc9_client_protocol:get_local_started(client),
    false = Pid2 == Pid3,

    {ok, <<"ok">>, #{}} = nkrpc9_client:send_request(client, login, #{name=>name1}),
    % The server will monitor the ack process, and it will fail
    {ok, <<"error">>, #{<<"code">>:=<<"process_down">>}} = nkrpc9_client:send_request(client, slow4, #{}),
    ok.


to_client() ->
    {ok, <<"error">>, #{<<"error">>:=<<"Missing field: 'data'">>}} =
        nkrpc9_server:send_request(server, cmd10, #{name=>name1}),
    {ok, <<"error">>, #{<<"code">>:=<<"unauthorized">>}} =
        nkrpc9_server:send_request(server, cmd10, #{data=>#{a=>1}}),
    {ok, <<"ok">>, #{}} =
        nkrpc9_server:send_request(server, login, #{name=>name2}),
    {ok, <<"ok">>, #{<<"data2">>:=#{<<"a">>:=1}}} =
        nkrpc9_server:send_request(server, cmd10, #{data=>#{a=>1}}),
    {ok, <<"ok">>, #{<<"data2">>:=#{<<"a">>:=1}}} =
        nkrpc9_server:send_request(server, cmd10, #{data=>#{a=>1}}),

    % Send event to client
    Ref = make_ref(),
    Event = #{ref=>base64:encode(term_to_binary({self(), Ref}))},
    ok = nkrpc9_server:send_event(server, event2, Event),
    receive {Ref, <<"name2">>} -> ok after 1000 -> error(?LINE) end,
    ok.


server_times() ->
    % First we need to increase the times on client so that server fires first,
    % and connect again
    ok = nkserver:update(client, #{cmd_timeout=>10000, ext_cmd_timeout=>180000}),
    [ClientPid] = nkrpc9_client_protocol:get_local_started(client),
    nkrpc9_client_protocol:stop(ClientPid),
    timer:sleep(500),

    {ok, <<"ok">>, #{}} = nkrpc9_server:send_request(server, login, #{name=>name2}),
    [Pid1] = nkrpc9_server_protocol:get_local_started(server),
    {ok, <<"error">>, #{<<"code">>:=<<"timeout">>}} =
        nkrpc9_server:send_request(server, slow11, #{}),
    % The server has stopped, supervisor will start it again
    % Ensure it stopped
    timer:sleep(500),
    [Pid2] = nkrpc9_server_protocol:get_local_started(server),
    false = Pid1 == Pid2,

    {ok, <<"ok">>, #{}} = nkrpc9_server:send_request(server, login, #{name=>name2}),
    {ok, <<"ok">>, #{}} = nkrpc9_server:send_request(server, slow12, #{}),

    {ok, <<"error">>, #{<<"code">>:=<<"timeout">>}} =
        nkrpc9_server:send_request(server, slow13, #{}),
    timer:sleep(500),
    [Pid3] = nkrpc9_server_protocol:get_local_started(server),
    false = Pid2 == Pid3,

    {ok, <<"ok">>, #{}} = nkrpc9_server:send_request(server, login, #{name=>name1}),
    % The server will monitor the ack process, and it will fail
    {ok, <<"error">>, #{<<"code">>:=<<"process_down">>}} = nkrpc9_server:send_request(server, slow14, #{}),
    ok.


http() ->
    {ok, <<"error">>, #{<<"code">>:=<<"unauthorized">>}} = http_request(cmd1, #{}, #{}),
    {ok, <<"ok">>, #{<<"out">>:=1}} = http_request(cmd1, #{}, #{<<"x-token">>=><<"t1">>}),
    {ok, <<"ok">>, #{}} = http_request(http1, #{}, #{<<"x-token">>=><<"t1">>}),
    {ok, <<"error">>, #{<<"code">>:=<<"process_down">>}} = http_request(http2, #{}, #{<<"x-token">>=><<"t1">>}),
    ok.


http_request(Cmd, Data, Hds) ->
    Url = "https://127.0.0.1:9010/test1?b=1&c=2",
    Msg = #{
        cmd => Cmd,
        data => Data
    },
    Body = nklib_json:encode(Msg),
    Hds2 = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- maps:to_list(Hds)],
    case httpc:request(post, {Url, Hds2, "application/json", Body}, [], []) of
        {ok, {{_, 200, _}, _RepHds, RepReply}} ->
            RepReply2 = nklib_json:decode(RepReply),
            #{<<"result">>:=Result} = RepReply2,
            RespData = maps:get(<<"data">>, RepReply2, #{}),
            {ok, Result, RespData};
        {ok, {{_, Code, _}, _RepHds, RepReply}} ->
            {error, Code, RepReply}
    end.


%% ===================================================================
%% API callbacks
%% ===================================================================


%% @doc
rpc9_parse(<<"login">>, _Data, _Req, State) ->
    {syntax, #{name => binary, '__mandatory' => [name]}, State};

rpc9_parse(<<"event1">>, _Data, _Req, State) ->
    {syntax, #{ref => binary}, State};

rpc9_parse(<<"event2">>, _Data, _Req, State) ->
    {syntax, #{ref => binary}, State};

rpc9_parse(<<"cmd10">>, _Data, _Req, State) ->
    {syntax, #{data => map, '__mandatory' => [data]}, State};

rpc9_parse(_Cmd, _Data, _Req, _State) ->
    continue.


%% @doc
rpc9_allow(<<"login">>, _Data, _Req, _State) ->
    true;

rpc9_allow(_Cmd, _Data, #{srv:=server, user_id:=UserId}, _State) when UserId /= <<>> ->
    true;

rpc9_allow(_Cmd, _Data, #{srv:=server}=Req, _State) ->
    case nkrpc9_server_http:get_headers(Req) of
        #{<<"x-token">>:=<<"t1">>} ->
            true;
        _ ->
            false
    end;

rpc9_allow(_Cmd, _Data, #{srv:=client}, #{user:=_}) ->
    true;

rpc9_allow(_Cmd, _Data, Req, State) ->
    lager:error("NKLOG CONT ~p ~p ~p", [_Cmd, Req, State]),
    continue.


%% @doc
%% Server requests
rpc9_request(<<"login">>, #{name:=Name}, #{srv:=server}, State) ->
    {login, Name, #{meta=>2}, State};

rpc9_request(<<"cmd1">>, _, #{srv:=server}, State) ->
    {reply, #{out=>1}, State};

rpc9_request(<<"cmd2">>, _, #{srv:=server}, State) ->
    {error, invalid_parameters, State};

rpc9_request(<<"slow1">>, _, #{srv:=server}, State) ->
    timer:sleep(600),
    {reply, #{}, State};

rpc9_request(<<"slow2">>, _, #{srv:=server}=Req, State) ->
    spawn_link(
        fun() ->
            timer:sleep(600),
            nkrpc9_server:reply(Req, {reply, #{}})
        end),
    {ack, undefined, State};

rpc9_request(<<"slow3">>, _, #{srv:=server}=Req, State) ->
    spawn_link(
        fun() ->
            timer:sleep(1000),
            nkrpc9_server:reply(Req, {reply, #{}})
        end),
    {ack, undefined, State};

rpc9_request(<<"slow4">>, _, #{srv:=server}, State) ->
    Pid = spawn_link(
        fun() ->
            timer:sleep(600)
        end),
    {ack, Pid, State};

rpc9_request(<<"http1">>, _, #{srv:=server}=Req, State) ->
    Pid = spawn_link(
        fun() ->
            nkrpc9_server:reply(Req, {reply, #{}})
        end),
    {ack, Pid, State};

rpc9_request(<<"http2">>, _, #{srv:=server}, State) ->
    Pid = spawn_link(
        fun() ->
            timer:sleep(200)
        end),
    {ack, Pid, State};



%% Client requests
rpc9_request(<<"login">>, #{name:=Name}, #{srv:=client}, State) ->
    {reply, #{meta=>3}, State#{user=>Name}};

rpc9_request(<<"cmd10">>, #{data:=Data}, #{srv:=client}, State) ->
    {reply, #{data2=>Data}, State};

rpc9_request(<<"slow11">>, _, #{srv:=client}, State) ->
    timer:sleep(700),
    {reply, #{}, State};

rpc9_request(<<"slow12">>, _, #{srv:=client}=Req, State) ->
    spawn_link(
        fun() ->
            timer:sleep(700),
            nkrpc9_client:reply(Req, {reply, #{}})
        end),
    {ack, undefined, State};

rpc9_request(<<"slow13">>, _, #{srv:=client}=Req, State) ->
    spawn_link(
        fun() ->
            timer:sleep(1300),
            nkrpc9_client:reply(Req, {reply, #{}})
        end),
    {ack, undefined, State};

rpc9_request(<<"slow14">>, _, #{srv:=client}, State) ->
    Pid = spawn_link(
        fun() ->
            timer:sleep(700)
        end),
    {ack, Pid, State};

%% Fallback
rpc9_request(Cmd, Data, Req, _State) ->
    lager:error("NKLOG REQ ~p ~p ~p", [Cmd, Data, Req]),
    continue.


%% @doc
rpc9_event(<<"event1">>, #{ref:=Bin}, #{srv:=server}, State) ->
    {Pid, Ref} = binary_to_term(base64:decode(Bin)),
    Pid ! Ref,
    {ok, State};

rpc9_event(<<"event2">>, #{ref:=Bin}, #{srv:=client}, #{user:=User}=State) ->
    {Pid, Ref} = binary_to_term(base64:decode(Bin)),
    Pid ! {Ref, User},
    {ok, State};

rpc9_event(Event, _Data, Req, _State) ->
    lager:error("NKLOG EV ~p ~p ~p", [Event, Req]),
    continue.
