-module(discord_bot_light_watcher).
-behaviour(gen_server).

%% API
-export([start_link/0]).
%% gen_server callbacks
-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    %% On souscrit aux événements d'état de l'app gun
    Ref = application:monitor(gun),
    {ok, #{monitor_ref => Ref}}.

handle_info({'application', gun, down}, State) ->
    io:format("Watcher: Gun app is down! Restarting Discord bot...~n"),
    %% Relancer le bot via le superviseur local
    case supervisor:terminate_child(discord_bot_light_sup, discord_bot_light_client) of
        ok -> supervisor:restart_child(discord_bot_light_sup, discord_bot_light_client);
        {error, _} = Err -> Err
    end,
    {noreply, State};

handle_info({'application', gun, _Status}, State) ->
    %% Autres événements liés à gun, on ignore
    {noreply, State};

handle_info(_Msg, State) ->
    {noreply, State}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

