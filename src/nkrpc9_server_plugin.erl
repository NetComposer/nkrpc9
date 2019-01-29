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

%% @doc Default callbacks for plugin definitions
-module(nkrpc9_server_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([plugin_deps/0, plugin_config/3, plugin_cache/3,
          plugin_start/3, plugin_update/4, plugin_stop/3]).


-include("nkrpc9.hrl").
-include_lib("nkserver/include/nkserver.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").

%% ===================================================================
%% Default implementation
%% ===================================================================


plugin_deps() ->
	[nkserver].


%% @doc
plugin_config(SrvId, Config, #{class:=?PACKAGE_CLASS_RPC9_SRV}=Service) ->
    Syntax = #{
        url => binary,
        opts => nkpacket_syntax:safe_syntax(),
        debug => {list, {atom, [nkpacket, protocol, msgs]}},
        ping_interval => {integer, 5, none},
        cmd_timeout => {integer, 5, none},
        ext_cmd_timeout => {integer, 5, none},
        http_max_body => {integer, 1024, none},
        user_state => any,
        '__mandatory' => [url],
        '__defaults' => #{
            ping_interval => 10000,
            cmd_timeout => 30000,
            ext_cmd_timeout => 180000,
            http_max_body => 10*1024*1024
        }
    },
    case nklib_syntax:parse(Config, Syntax) of
        {ok, Config2, _} ->
            case get_listen(SrvId, Config2, Service) of
                {ok, _Conns} ->
                    {ok, Config2};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


plugin_cache(_SrvId, Config, _Service) ->
    Cache = #{
        debug => maps:get(debug, Config, []),
        ping_interval => maps:get(ping_interval, Config),
        cmd_timeout => maps:get(cmd_timeout, Config),
        ext_cmd_timeout => maps:get(ext_cmd_timeout, Config),
        http_max_body => maps:get(http_max_body, Config)
    },
    {ok, Cache}.


%% @doc
plugin_start(SrvId, Config, Service) ->
    pg2:create({nkrpc9_server, SrvId}),
    {ok, Conns} = get_listen(SrvId, Config, Service),
    {ok, Listeners} = make_listen_transps(SrvId, Conns),
    insert_listeners(SrvId, Listeners, Service).


plugin_stop(SrvId, _Config, _Service) ->
    nkserver_workers_sup:remove_all_childs(SrvId).


%% @doc
plugin_update(SrvId, NewConfig, OldConfig, Service) ->
    case NewConfig of
        OldConfig ->
            ok;
        _ ->
            plugin_start(SrvId, NewConfig, Service)
    end.



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
get_listen(SrvId, #{url:=Url}=Config, _Service) ->
    ResolveOpts = #{protocol=>nkrpc9_server_protocol},
    ConfigOpts = maps:get(opts, Config, #{}),
    case nkpacket_resolve:resolve(Url, ResolveOpts) of
        {ok, Conns} ->
            Debug = maps:get(debug, Config, []),
            Opts = ConfigOpts#{
                id => {nkrpc9_server, SrvId},
                class => {?PACKAGE_CLASS_RPC9_SRV, SrvId},
                debug => lists:member(nkpacket, Debug),
                get_headers => [<<"user-agent">>],
                user_state => maps:get(user_state, Config, undefined)
            },
            do_get_listen(Conns, Opts, []);
        {error, Error} ->
            {error, Error}
    end.


%% @private
do_get_listen([], _Opts, Acc) ->
    {ok, Acc};

do_get_listen([#nkconn{protocol=nkrpc9_server_protocol}=Conn|Rest], Opts, Acc) ->
    #nkconn{opts=ConnOpts} = Conn,
    Opts2 = maps:merge(ConnOpts, Opts),
    Opts3 = Opts2#{
        path => maps:get(path, Opts2, <<"/">>)
    },
    Conn2 = Conn#nkconn{opts=Opts3},
    do_get_listen(Rest, Opts, [Conn2|Acc]);

do_get_listen(_, _Opts, _Acc) ->
    {error, protocol_invalid}.


%% @private
make_listen_transps(SrvId, Conns) ->
    make_listen_transps(SrvId, Conns, []).


%% @private
make_listen_transps(_PkgId, [], Acc) ->
    {ok, Acc};

make_listen_transps(SrvId, [Conn|Rest], Acc) ->
    case nkpacket:get_listener(Conn) of
        {ok, _Id, Spec} ->
            make_listen_transps(SrvId, Rest, [Spec|Acc]);
        {error, Error} ->
            {error, Error}
    end.


%% @private
insert_listeners(SrvId, SpecList, Service) ->
    case nkserver_workers_sup:update_child_multi(SrvId, SpecList, #{}) of
        ok ->
            ?SRV_LOG(info, "listeners started", [], Service),
            ok;
        not_updated ->
            ?SRV_LOG(debug, "listeners didn't upgrade", [], Service),
            ok;
        upgraded ->
            ?SRV_LOG(info, "listeners upgraded", [], Service),
            ok;
        {error, Error} ->
            ?SRV_LOG(notice, "listeners start/update error: ~p", [Error], Service),
            {error, Error}
    end.
