%%%===================================================================
%%% Gun Monitor - Simple
%%% Monitors gun_sup process and notifies supervisor when it dies
%%%===================================================================
-module(gun_monitor).

%% API
-export([start_link/0]).

%% @doc Start monitoring gun_sup
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    Pid = spawn_link(fun monitor_loop/0),
    {ok, Pid}.

%% @doc Simple monitoring loop
-spec monitor_loop() -> no_return().
monitor_loop() ->
    case whereis(gun_sup) of
        undefined ->
            % gun_sup not found, notify supervisor and wait a bit before checking again
            io:format("gun_sup not found, notifying supervisor...~n"),
            discord_bot_light_sup:restart_bot(),
            timer:sleep(2000),
            monitor_loop();
        GunSupPid when is_pid(GunSupPid) ->
            % Found gun_sup, monitor it
            io:format("Monitoring gun_sup (~p)~n", [GunSupPid]),
            MonitorRef = erlang:monitor(process, GunSupPid),
            receive
                {'DOWN', MonitorRef, process, GunSupPid, Reason} ->
                    io:format("gun_sup crashed with reason: ~p~n", [Reason]),
                    io:format("Notifying supervisor to restart bot~n"),
                    discord_bot_light_sup ! {gun_crash},
                    monitor_loop()
            end
    end.

