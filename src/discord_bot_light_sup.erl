%%%===================================================================
%%% Discord Bot Light Supervisor
%%% Supervises the Discord bot client with configurable command handler
%%% Enhanced restart strategy and monitoring
%%% Now includes Gun HTTP client supervision
%%%===================================================================
-module(discord_bot_light_sup).
-behaviour(supervisor).

%% API
-export([start_link/1, start_link/2, get_bot_status/0, restart_bot/0, get_gun_status/0, restart_gun/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

%% @doc Start supervisor with just token (no command handler)
-spec start_link(binary() | string()) -> {ok, pid()} | {error, term()}.
start_link(Token) ->
    start_link(Token, []).

%% @doc Start supervisor with token and options for command handler
%% Options are passed directly to the discord_bot_light_client
-spec start_link(binary() | string(), list()) -> {ok, pid()} | {error, term()}.
start_link(Token, Options) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [Token, Options]).

%% @doc Get the current status of the bot client
-spec get_bot_status() -> {ok, pid()} | {error, not_found}.
get_bot_status() ->
    case whereis(discord_bot_light_client) of
        undefined -> 
            {error, not_found};
        Pid when is_pid(Pid) -> 
            case is_process_alive(Pid) of
                true -> {ok, Pid};
                false -> {error, not_found}
            end
    end.

%% @doc Get the current status of Gun application
-spec get_gun_status() -> {ok, running} | {error, not_running}.
get_gun_status() ->
    case application:which_applications() of
        Apps when is_list(Apps) ->
            case lists:keyfind(gun, 1, Apps) of
                false -> {error, not_running};
                _ -> {ok, running}
            end;
        _ -> {error, not_running}
    end.

%% @doc Manually restart the bot client
-spec restart_bot() -> ok | {error, term()}.
restart_bot() ->
    case supervisor:terminate_child(?SERVER, discord_bot_light_client) of
        ok ->
            case supervisor:restart_child(?SERVER, discord_bot_light_client) of
                {ok, _Pid} -> 
                    io:format("Discord bot restarted successfully~n"),
                    ok;
                {ok, _Pid, _Info} -> 
                    io:format("Discord bot restarted successfully~n"),
                    ok;
                {error, Reason} -> 
                    io:format("Failed to restart Discord bot: ~p~n", [Reason]),
                    {error, Reason}
            end;
        {error, Reason} -> 
            io:format("Failed to terminate Discord bot: ~p~n", [Reason]),
            {error, Reason}
    end.

%% @doc Manually restart Gun application
-spec restart_gun() -> ok | {error, term()}.
restart_gun() ->
    case supervisor:terminate_child(?SERVER, gun_app_manager) of
        ok ->
            case supervisor:restart_child(?SERVER, gun_app_manager) of
                {ok, _Pid} -> 
                    io:format("Gun application restarted successfully~n"),
                    ok;
                {ok, _Pid, _Info} -> 
                    io:format("Gun application restarted successfully~n"),
                    ok;
                {error, Reason} -> 
                    io:format("Failed to restart Gun: ~p~n", [Reason]),
                    {error, Reason}
            end;
        {error, Reason} -> 
            io:format("Failed to terminate Gun: ~p~n", [Reason]),
            {error, Reason}
    end.

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%% @doc Initialize supervisor with child specifications
%% Enhanced restart strategy for better resilience
init([Token, Options]) ->
    % More aggressive restart strategy for better reliability
    % - rest_for_one: If Gun fails, restart Gun and bot (bot depends on Gun)
    % - intensity 10: Allow up to 10 restarts
    % - period 60: Within 60 seconds (more lenient than default)
    SupFlags = #{
        strategy => rest_for_one,  % Changed to rest_for_one for dependency handling
        intensity => 10,           % Allow more restarts
        period => 60               % Within 60 seconds
    },

    % Child specifications - Gun first (dependency), then Discord bot
    ChildSpecs = [
        % Gun application manager - starts and monitors Gun app
        #{
            id => gun_app_manager,
            start => {gun_app_manager, start_link, []},
            restart => permanent,     % Always restart
            shutdown => 5000,         % Give 5 seconds for graceful shutdown
            type => worker,
            modules => [gun_app_manager]
        },
        
        % Discord bot client - depends on Gun
        #{
            id => discord_bot_light_client,
            start => {discord_bot_light_client, start_link, [Token, Options]},
            restart => permanent,     % Always restart
            shutdown => 10000,        % Give 10 seconds for graceful shutdown
            type => worker,
            modules => [discord_bot_light_client]
        }
    ],

    io:format("Discord bot supervisor started with Gun supervision~n"),
    io:format("  - Strategy: rest_for_one (Gun -> Bot dependency)~n"),
    io:format("  - Max restarts: 10 in 60 seconds~n"),
    io:format("  - Gun shutdown timeout: 5 seconds~n"),
    io:format("  - Bot shutdown timeout: 10 seconds~n"),

    {ok, {SupFlags, ChildSpecs}}.
