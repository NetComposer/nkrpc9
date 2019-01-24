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
-module(nkserver_rpc9_client_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([plugin_deps/0, plugin_config/3, plugin_cache/3,
         plugin_start/3, plugin_update/4, plugin_stop/3]).
-export([connect_link/2]).

-include("nkserver_rpc9.hrl").
-include_lib("nkserver/include/nkserver.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").

%% ===================================================================
%% Default implementation
%% ===================================================================


plugin_deps() ->
	[nkserver].


%% @doc
plugin_config(_SrvId, Config, #{class:=?PACKAGE_CLASS_RPC9_CLIENT}) ->
    Syntax = #{
        url => binary,
        opts => nkpacket_syntax:safe_syntax(),
        debug => {list, {atom, [nkpacket, protocol, msgs]}},
        cmd_timeout => {integer, 5, none},
        ext_cmd_timeout => {integer, 5, none},
        user_state => map,
        '__mandatory' => [url],
        '__defaults' => #{
            cmd_timeout => 10000,
            ext_cmd_timeout => 180000,
            user_state => #{}
        }
    },
    case nklib_syntax:parse(Config, Syntax) of
        {ok, Config2, _} ->
            {ok, Config2};
        {error, Error} ->
            {error, Error}
    end.


plugin_cache(_SrvId, Config, _Service) ->
    Cache = #{
        debug => maps:get(debug, Config, []),
        cmd_timeout => maps:get(cmd_timeout, Config),
        ext_cmd_timeout => maps:get(ext_cmd_timeout, Config)
    },
    {ok, Cache}.


%% @doc
plugin_start(SrvId, #{url:=Url}=Config, Service) ->
    pg2:create({nkserver_rpc9_client, SrvId}),
    ConfigOpts = maps:get(opts, Config, #{}),
    Debug = maps:get(debug, Config, []),
    ConnOpts = ConfigOpts#{
        protocol => nkserver_rpc9_client_protocol,
        id => {nkserver_rpc9_client, SrvId},
        class => {?PACKAGE_CLASS_RPC9_CLIENT, SrvId},
        idle_timeout => 60000,
        user_state => maps:get(user_state, Config),
        debug => lists:member(nkpacket, Debug)
    },
    Spec = #{
        id => {nkserver_rpc9_client, SrvId},
        restart => permanent,
        start => {?MODULE, connect_link, [Url, ConnOpts]}
    },
    insert_listeners(SrvId, [Spec], Service).


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


connect_link(Url, Opts) ->
     case nkpacket:connect(Url, Opts) of
         {ok, #nkport{pid=Pid}} ->
             link(Pid),
             {ok, Pid};
         {error, Error} ->
             {error, Error}
     end.


%% @private
insert_listeners(SrvId, SpecList, Service) ->
    case nkserver_workers_sup:update_child_multi(SrvId, SpecList, #{}) of
        ok ->
            ?SRV_LOG(info, "clients started", [], Service),
            ok;
        not_updated ->
            ?SRV_LOG(debug, "clients didn't upgrade", [], Service),
            ok;
        upgraded ->
            ?SRV_LOG(info, "clients upgraded", [], Service),
            ok;
        {error, Error} ->
            ?SRV_LOG(notice, "clients start/update error: ~p", [Error], Service),
            {error, Error}
    end.
