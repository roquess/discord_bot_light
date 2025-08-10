%%%===================================================================
%%% Discord Bot Light Supervisor
%%% Supervises the Discord bot client with configurable command handler
%%% Enhanced restart strategy and monitoring
%%%===================================================================
-module(discord_bot_light_sup).
-behaviour(supervisor).

%% API
-export([start_link/1, start_link/2, get_bot_status/0, restart_bot/0]).

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

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%% @doc Initialize supervisor with child specifications
%% Enhanced restart strategy for better resilience
init([Token, Options]) ->
    % More aggressive restart strategy for better reliability
    % - one_for_one: If the bot crashes, restart only the bot
    % - intensity 10: Allow up to 10 restarts
    % - period 60: Within 60 seconds (more lenient than default)
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,          % Allow more restarts
        period => 60              % Within 60 seconds
    },

    % Child specification for the Discord bot client
    % - permanent: Always restart if it terminates
    % - 10000ms shutdown: Give it time to clean up connections
    % - worker: It's a worker process
    ChildSpecs = [#{
        id => discord_bot_light_client,
        start => {discord_bot_light_client, start_link, [Token, Options]},
        restart => permanent,     % Always restart
        shutdown => 10000,        % Give 10 seconds for graceful shutdown
        type => worker,
        modules => [discord_bot_light_client]
    }],

    io:format("Discord bot supervisor started with enhanced restart strategy~n"),
    io:format("  - Strategy: one_for_one~n"),
    io:format("  - Max restarts: 10 in 60 seconds~n"),
    io:format("  - Shutdown timeout: 10 seconds~n"),

    {ok, {SupFlags, ChildSpecs}}.
