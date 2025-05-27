%%%===================================================================
%%% Discord Bot Light Supervisor
%%% Supervises the Discord bot client with configurable command handler
%%%===================================================================
-module(discord_bot_light_sup).
-behaviour(supervisor).

%% API
-export([start_link/1, start_link/2]).

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

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%% @doc Initialize supervisor with child specifications
init([Token, Options]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 5,
                 period => 60},

    % Child specification for the Discord bot client
    ChildSpecs = [#{id => discord_bot_light_client,
                    start => {discord_bot_light_client, start_link, [Token, Options]},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [discord_bot_light_client]}],

    {ok, {SupFlags, ChildSpecs}}.
