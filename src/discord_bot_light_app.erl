%%%===================================================================
%%% Discord Bot Light Application
%%% Main application module that handles bot startup with configurable handlers
%%% Enhanced error handling and monitoring
%%%===================================================================
-module(discord_bot_light_app).
-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% Additional utility functions
-export([get_bot_pid/0, is_bot_running/0]).

%%%===================================================================
%%% Application callbacks
%%%===================================================================

%% @doc Start the Discord bot application
%% This function gets the Discord token from environment variables
%% and optionally configures a command handler module
start(_StartType, _StartArgs) ->
    io:format("Starting Discord Bot Light Application...~n"),
    
    % Get Discord token from environment variable
    Token = os:getenv("DISCORD_TOKEN"),
    if
        Token =:= false ->
            io:format("Error: Environment variable DISCORD_TOKEN is undefined~n"),
            io:format("Please set DISCORD_TOKEN environment variable with your bot token~n"),
            {error, no_token};
        Token =:= "" ->
            io:format("Error: Environment variable DISCORD_TOKEN is empty~n"),
            {error, empty_token};
        true ->
            % Validate token format (basic check)
            case validate_token_format(Token) of
                ok ->
                    % Get optional command handler from environment or application config
                    Options = get_bot_options(),
                    io:format("Starting Discord bot with options: ~p~n", [Options]),
                    
                    case discord_bot_light_sup:start_link(Token, Options) of
                        {ok, Pid} ->
                            io:format("Discord bot supervisor started successfully: ~p~n", [Pid]),
                            % Set up monitoring for the supervisor
                            monitor_supervisor(Pid),
                            {ok, Pid};
                        {error, Reason} ->
                            io:format("Failed to start Discord bot supervisor: ~p~n", [Reason]),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    io:format("Invalid token format: ~p~n", [Reason]),
                    {error, invalid_token}
            end
    end.

%% @doc Stop the Discord bot application
stop(_State) ->
    io:format("Stopping Discord Bot Light Application...~n"),
    
    % Try to get bot status before stopping
    case get_bot_pid() of
        {ok, Pid} ->
            io:format("Stopping bot process: ~p~n", [Pid]);
        {error, _} ->
            io:format("Bot process not found during shutdown~n")
    end,
    
    ok.

%%%===================================================================
%%% Public utility functions
%%%===================================================================

%% @doc Get the bot client process PID
-spec get_bot_pid() -> {ok, pid()} | {error, not_found}.
get_bot_pid() ->
    discord_bot_light_sup:get_bot_status().

%% @doc Check if the bot is currently running
-spec is_bot_running() -> boolean().
is_bot_running() ->
    case get_bot_pid() of
        {ok, _Pid} -> true;
        {error, _} -> false
    end.

%%%===================================================================
%%% Private functions
%%%===================================================================

%% @doc Basic validation of Discord bot token format
-spec validate_token_format(string()) -> ok | {error, atom()}.
validate_token_format(Token) when length(Token) < 50 ->
    {error, too_short};
validate_token_format(Token) when length(Token) > 100 ->
    {error, too_long};
validate_token_format(_Token) ->
    % Discord tokens are typically base64-encoded strings
    % This is a basic check - a real implementation might be more thorough
    ok.

%% @doc Set up monitoring for the supervisor process
monitor_supervisor(SupPid) ->
    spawn(fun() -> supervisor_monitor_loop(SupPid) end).

%% @doc Monitor loop for the supervisor
supervisor_monitor_loop(SupPid) ->
    timer:sleep(30000), % Check every 30 seconds
    
    case is_process_alive(SupPid) of
        true ->
            % Check bot status
            case get_bot_pid() of
                {ok, BotPid} ->
                    io:format("Bot health check: Supervisor ~p, Bot ~p - OK~n", [SupPid, BotPid]);
                {error, not_found} ->
                    io:format("Bot health check: Supervisor ~p running, but bot not found~n", [SupPid])
            end,
            supervisor_monitor_loop(SupPid);
        false ->
            io:format("Supervisor process ~p has died!~n", [SupPid])
            % The application will handle the restart
    end.

%% @doc Get bot configuration options from environment or application config
%% This allows users to configure the command handler without modifying code
-spec get_bot_options() -> list().
get_bot_options() ->
    Options = [],
    % Check for command handler in application environment
    Options1 = get_app_config_handler(Options),
    % Check for command handler in environment variable (overrides app config)
    get_env_config_handler(Options1).

%% @doc Get command handler from application configuration
-spec get_app_config_handler(list()) -> list().
get_app_config_handler(Options) ->
    case application:get_env(discord_bot_light, command_handler) of
        {ok, Handler} when is_atom(Handler) ->
            io:format("Using command handler from app config: ~p~n", [Handler]),
            [{command_handler, Handler} | Options];
        {ok, {Module, Function}} ->
            io:format("Using command handler from app config: ~p:~p~n", [Module, Function]),
            [{command_handler, {Module, Function}} | Options];
        undefined ->
            Options;
        {ok, Invalid} ->
            io:format("Warning: Invalid command handler in app config: ~p~n", [Invalid]),
            Options
    end.

%% @doc Get command handler from environment variable
-spec get_env_config_handler(list()) -> list().
get_env_config_handler(Options) ->
    case os:getenv("DISCORD_COMMAND_HANDLER") of
        false ->
            Options;
        HandlerStr ->
            case try_parse_handler(HandlerStr) of
                {ok, Handler} ->
                    io:format("Using command handler from environment: ~p~n", [Handler]),
                    lists:keystore(command_handler, 1, Options, {command_handler, Handler});
                error ->
                    io:format("Warning: Command handler module ~s does not exist~n", [HandlerStr]),
                    Options
            end
    end.

%% @doc Helper function to safely parse handler string to atom
-spec try_parse_handler(string()) -> {ok, atom()} | error.
try_parse_handler(HandlerStr) ->
    try
        Handler = list_to_existing_atom(HandlerStr),
        {ok, Handler}
    catch
        error:badarg ->
            error
    end.
