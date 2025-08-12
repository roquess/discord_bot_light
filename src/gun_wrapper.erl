%%%===================================================================
%%% Gun Wrapper
%%% Provides Gun functions with proper timeouts to avoid infinite blocking
%%%===================================================================
-module(gun_wrapper).
-behaviour(gen_server).

%% API
-export([start_link/0, open_with_timeout/3, open_with_timeout/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(DEFAULT_TIMEOUT, 15000). % 15 seconds

%% @doc Start the gun wrapper service
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Open Gun connection with default timeout
-spec open_with_timeout(string(), pos_integer(), map()) -> {ok, pid()} | {error, term()}.
open_with_timeout(Host, Port, Opts) ->
    open_with_timeout(Host, Port, Opts, ?DEFAULT_TIMEOUT).

%% @doc Open Gun connection with custom timeout
-spec open_with_timeout(string(), pos_integer(), map(), pos_integer()) -> {ok, pid()} | {error, term()}.
open_with_timeout(Host, Port, Opts, Timeout) ->
    gen_server:call(?MODULE, {open, Host, Port, Opts, Timeout}, Timeout + 1000).

init([]) ->
    {ok, #{}}.

handle_call({open, Host, Port, Opts, Timeout}, _From, State) ->
    io:format("Opening Gun connection to ~s:~p with timeout ~pms~n", [Host, Port, Timeout]),
    
    Parent = self(),
    Ref = make_ref(),
    
    % Spawn worker process
    Worker = spawn_link(fun() ->
        try
            Result = gun:open(Host, Port, Opts),
            Parent ! {Ref, Result}
        catch
            Class:Error:Stack ->
                Parent ! {Ref, {error, {exception, Class, Error, Stack}}}
        end
    end),
    
    % Wait for result with timeout
    Result = receive
        {Ref, Res} ->
            case Res of
                {ok, ConnPid} when is_pid(ConnPid) ->
                    io:format("Gun connection successful to ~s:~p~n", [Host, Port]),
                    {ok, ConnPid};
                {error, Reason} ->
                    io:format("Gun connection failed to ~s:~p: ~p~n", [Host, Port, Reason]),
                    {error, Reason}
            end
    after Timeout ->
        % Kill the worker
        unlink(Worker),
        exit(Worker, kill),
        io:format("Gun connection timeout to ~s:~p after ~pms~n", [Host, Port, Timeout]),
        {error, timeout}
    end,
    
    {reply, Result, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
