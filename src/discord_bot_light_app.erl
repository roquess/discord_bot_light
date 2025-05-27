%%%===================================================================
%%% Discord Bot Light Application
%%% Main application module that handles bot startup with configurable handlers
%%%===================================================================
-module(discord_bot_light_app).
-behaviour(application).
%% Application callbacks
-export([start/2, stop/1]).
%%%===================================================================
%%% Application callbacks
%%%===================================================================
%% @doc Start the Discord bot application
%% This function gets the Discord token from environment variables
%% and optionally configures a command handler module
start(_StartType, _StartArgs) ->
    % Get Discord token from environment variable
    Token = os:getenv("DISCORD_TOKEN"),
    if
        Token =:= false ->
            io:format("Error: Environment variable DISCORD_TOKEN is undefined~n"),
            {error, no_token};
        true ->
            % Get optional command handler from environment or application config
            Options = get_bot_options(),
            io:format("Starting Discord bot with options: ~p~n", [Options]),
            discord_bot_light_sup:start_link(Token, Options)
    end.
%% @doc Stop the Discord bot application
stop(_State) ->
    ok.
%%%===================================================================
%%% Private functions
%%%===================================================================
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
