%%%===================================================================
%%% Gun Application Manager
%%% Simple gen_server to manage Gun application lifecycle
%%%===================================================================
-module(gun_app_manager).
-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {}).

%%%===================================================================
%%% API functions
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    
    % Start Gun application
    case application:start(gun) of
        ok ->
            io:format("Gun application started successfully~n"),
            {ok, #state{}};
        {error, {already_started, gun}} ->
            io:format("Gun application already running~n"),
            {ok, #state{}};
        {error, Reason} ->
            io:format("Failed to start Gun application: ~p~n", [Reason]),
            {stop, {gun_start_failed, Reason}}
    end.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    % Stop Gun application gracefully
    case application:stop(gun) of
        ok ->
            io:format("Gun application stopped successfully~n");
        {error, Reason} ->
            io:format("Error stopping Gun application: ~p~n", [Reason])
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
