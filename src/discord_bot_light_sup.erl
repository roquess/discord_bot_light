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

start_link(Token) ->
    start_link(Token, []).

start_link(Token, Options) ->
    % Ensure Gun app is running before starting the supervisor
    ensure_gun_running(),
    supervisor:start_link({local, ?SERVER}, ?MODULE, [Token, Options]).

get_bot_status() ->
    case whereis(discord_bot_light_client) of
        undefined -> {error, not_found};
        Pid when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> {ok, Pid};
                false -> {error, not_found}
            end
    end.

restart_bot() ->
    ensure_gun_running(),
    case supervisor:terminate_child(?SERVER, discord_bot_light_client) of
        ok ->
            case supervisor:restart_child(?SERVER, discord_bot_light_client) of
                {ok, _} ->
                    io:format("Discord bot restarted successfully~n"),
                    ok;
                {ok, _, _} ->
                    io:format("Discord bot restarted successfully~n"),
                    ok;
                {error, _} ->
                    io:format("Failed to restart Discord bot~n"),
                    {error, failed_to_restart}
            end;
        {error, _} ->
            io:format("Failed to terminate Discord bot~n"),
            {error, failed_to_terminate}
    end.

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

init([Token, Options]) ->
    SupFlags = {one_for_one, 5, 60},
    ChildSpecs = [
        % Gun monitor - process that monitors gun_sup
        #{
            id => gun_monitor,
            start => {gun_monitor, start_link, []},
            restart => permanent,
            shutdown => 2000,
            type => worker,
            modules => [gun_monitor]
        },
        % Gun wrapper helper
        #{
            id => gun_wrapper,
            start => {gun_wrapper, start_link, []},
            restart => permanent,
            shutdown => 1000,
            type => worker,
            modules => [gun_wrapper]
        },
        % Discord bot client
        #{
            id => discord_bot_light_client,
            start => {discord_bot_light_client, start_link, [Token, Options]},
            restart => transient,
            shutdown => 10000,
            type => worker,
            modules => [discord_bot_light_client]
        }
    ],
    io:format("Discord bot supervisor started~n"),
    {ok, {SupFlags, ChildSpecs}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec ensure_gun_running() -> ok.
ensure_gun_running() ->
    case whereis(gun_sup) of
        undefined ->
            io:format("gun_sup not found, restarting Gun application...~n"),
            % Stop Gun app first (in case it's in bad state)
            case application:stop(gun) of
                ok -> io:format("Gun app stopped~n");
                {error, {not_started, gun}} -> io:format("Gun app was not started~n");
                {error, _} -> io:format("Gun stop error (ignoring)~n")
            end,
            % Small delay
            timer:sleep(500),
            % Start Gun app
            case application:start(gun) of
                ok ->
                    io:format("Gun app started successfully~n"),
                    % Wait longer and verify Gun is really ready
                    timer:sleep(2000),
                    wait_for_gun_ready(),
                    ok;
                {error, {already_started, gun}} ->
                    io:format("Gun was already started~n"),
                    wait_for_gun_ready(),
                    ok;
                {error, _} ->
                    io:format("Failed to start Gun~n"),
                    ok % Continue anyway
            end;
        _ ->
            wait_for_gun_ready(),
            ok
    end.

-spec wait_for_gun_ready() -> ok.
wait_for_gun_ready() ->
    wait_for_gun_ready(5).

-spec wait_for_gun_ready(non_neg_integer()) -> ok.
wait_for_gun_ready(0) ->
    io:format("Gun readiness check timed out, continuing anyway~n"),
    ok;
wait_for_gun_ready(Attempts) ->
    io:format("Testing Gun readiness (~p attempts left)...~n", [Attempts]),
    try
        case gun:open("httpbin.org", 80, #{protocols => [http]}) of
            {ok, _} ->
                io:format("Gun is ready!~n"),
                ok;
            {error, _} ->
                timer:sleep(1000),
                wait_for_gun_ready(Attempts - 1)
        end
    catch
        _:_ ->
            timer:sleep(1000),
            wait_for_gun_ready(Attempts - 1)
    end.

