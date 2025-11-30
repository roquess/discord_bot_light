-module(discord_bot_light_client).
-behaviour(gen_server).

%% API exports
-export([start_link/1, start_link/2, send_message/3, send_message_with_files/4, edit_message/4, get_stored_app_id/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([register_global_commands/2, register_global_command/3, register_global_command/4,
         register_guild_command/4, register_guild_command/5,
         respond_to_interaction/3, respond_to_interaction/4,
         respond_to_interaction_with_files/4, respond_to_interaction_with_files/5,
         edit_interaction_response/3, edit_interaction_response/4]).

%% State record definition
-record(state, {
          token,                    % Discord bot token
          conn,                     % Gun connection handle
          seq = null,               % Gateway sequence number
          session_id = null,        % Discord session ID
          heartbeat_ref = undefined,% Heartbeat timer reference
          stream_ref = undefined,   % WebSocket stream reference
          bot_id = undefined,       % Bot's user ID
          app_id = undefined,       % Application ID
          command_handler = undefined,  % Command handler configuration
          ws_connected = false,     % WebSocket connection status
          reconnect_attempts = 0,   % Number of reconnection attempts
          last_heartbeat_ack = true % Track if last heartbeat was ACKed
         }).

%% Maximum reconnection attempts before giving up
-define(MAX_RECONNECT_ATTEMPTS, 10).
-define(RECONNECT_DELAY_BASE, 1000). % Base delay in ms
-define(CONNECTION_TIMEOUT, 60000).   % 60 seconds timeout
-define(HEARTBEAT_TIMEOUT, 60000).    % 60 seconds for heartbeat operations

%%%===============
%%% Public API
%%%===============
-spec start_link(binary() | string()) -> {ok, pid()} | {error, term()}.
start_link(Token) ->
    start_link(Token, []).

-spec start_link(binary() | string(), list()) -> {ok, pid()} | {error, term()}.
start_link(Token, Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Token, Options], []).

%%%===============
%%% gen_server Callbacks
%%%===============
init([Token, Options]) ->
    process_flag(trap_exit, true),
    CommandHandler = proplists:get_value(command_handler, Options, undefined),
    BinToken = if is_binary(Token) -> Token; is_list(Token) -> list_to_binary(Token) end,
    AppId = case get_bot_application_id(BinToken) of
        {ok, Id} -> Id;
        _ -> undefined
    end,
    self() ! connect,
    {ok, #state{token = Token, command_handler = CommandHandler, app_id = AppId}}.

%% Get the stored application ID
-spec get_stored_app_id() -> {ok, binary()} | {error, not_available}.
get_stored_app_id() ->
    gen_server:call(?MODULE, get_app_id).

handle_info(connect, State) ->
    io:format("Connecting to Discord Gateway (attempt ~p)...~n", [State#state.reconnect_attempts + 1]),
    case State#state.reconnect_attempts >= ?MAX_RECONNECT_ATTEMPTS of
        true ->
            io:format("Max reconnection attempts (~p) exceeded. Stopping.~n", [?MAX_RECONNECT_ATTEMPTS]),
            {stop, max_reconnect_attempts_exceeded, State};
        false ->
            connect_to_gateway(State)
    end;

handle_info({gun_upgrade, Conn, StreamRef, [<<"websocket">>], _Headers}, State) ->
    io:format("WebSocket upgrade confirmed~n"),
    {noreply, State#state{conn=Conn, stream_ref=StreamRef, ws_connected=true, reconnect_attempts=0}};

handle_info({gun_ws, Conn, StreamRef, {text, Frame}}, State) ->
    try
        Decoded = jsone:decode(Frame),
        handle_gateway_message(Decoded, State#state{conn=Conn, stream_ref=StreamRef})
    catch
        Class:Reason:Stacktrace ->
            io:format("Error decoding message: ~p:~p~n~p~n", [Class, Reason, Stacktrace]),
            {noreply, State}
    end;

% Ignore HTTP connection up/down events (from API calls)
handle_info({gun_up, Conn, http}, State) when State#state.conn =/= Conn ->
    % This is from an HTTP API connection, ignore silently
    {noreply, State};

handle_info({gun_down, Conn, http, _Reason, _, _}, State) when State#state.conn =/= Conn ->
    % This is from an HTTP API connection, ignore silently
    {noreply, State};

handle_info({gun_down, Conn, ws, Reason, _, _}, State = #state{conn = Conn}) ->
    io:format("WebSocket disconnection detected: ~p~n", [Reason]),
    maybe_cancel_heartbeat(State),
    schedule_reconnect(State);

handle_info({gun_error, Conn, StreamRef, Reason}, State = #state{conn = Conn, stream_ref = StreamRef}) ->
    io:format("Gun error: ~p~n", [Reason]),
    maybe_cancel_heartbeat(State),
    cleanup_connection(State),
    schedule_reconnect(State);

% Gestion de la perte de connexion générale
handle_info({gun_down, Conn, _, Reason, _, _}, State = #state{conn = Conn}) ->
    io:format("Connection down: ~p~n", [Reason]),
    maybe_cancel_heartbeat(State),
    schedule_reconnect(State);

handle_info(reconnect, State) ->
    io:format("Attempting reconnection...~n"),
    self() ! connect,
    {noreply, State};

handle_info(heartbeat, State = #state{ws_connected = false}) ->
    io:format("No active WebSocket connection for heartbeat~n"),
    {noreply, State};

% Vérifier si le dernier heartbeat a été ACK avant d'envoyer le suivant
handle_info(heartbeat, State = #state{last_heartbeat_ack = false}) ->
    io:format("Previous heartbeat not ACKed, reconnecting...~n"),
    maybe_cancel_heartbeat(State),
    schedule_reconnect(State);

handle_info(heartbeat, State = #state{conn = Conn, stream_ref = StreamRef, seq = Seq, ws_connected = true}) ->
    Payload = #{op => 1, d => Seq},
    EncodedPayload = jsone:encode(Payload),
    case safe_ws_send(State, Conn, StreamRef, {text, EncodedPayload}) of
        ok ->
            io:format("Heartbeat sent (seq: ~p)~n", [Seq]),
            {noreply, State#state{last_heartbeat_ack = false}}; % Attendre l'ACK
        Error ->
            io:format("Error sending heartbeat: ~p~n", [Error]),
            maybe_cancel_heartbeat(State),
            schedule_reconnect(State)
    end;

% Timeout de heartbeat - si pas de réponse dans les temps
handle_info(heartbeat_timeout, State) ->
    io:format("Heartbeat timeout, reconnecting...~n"),
    maybe_cancel_heartbeat(State),
    schedule_reconnect(State);

handle_info(Info, State) ->
    io:format("Unexpected message in handle_info: ~p~n", [Info]),
    {noreply, State}.

%%%===============
%%% Connection Management
%%%===============
connect_to_gateway(State) ->
    cleanup_connection(State),
    TLSOpts = [
        {verify, verify_peer},
        {cacerts, certifi:cacerts()},
        {server_name_indication, "gateway.discord.gg"},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ],
    ConnOpts = #{
        transport => tls, 
        tls_opts => TLSOpts, 
        protocols => [http],
        retry => 3,
        retry_timeout => 5000,
        connect_timeout => ?CONNECTION_TIMEOUT,
        http_opts => #{keepalive => infinity}
    },
    case gun:open("gateway.discord.gg", 443, ConnOpts) of
        {ok, Conn} ->
            io:format("Connection opened: ~p~n", [Conn]),
            case gun:await_up(Conn, ?CONNECTION_TIMEOUT) of
                {ok, Protocol} ->
                    io:format("Connection established with protocol: ~p~n", [Protocol]),
                    StreamRef = gun:ws_upgrade(Conn, "/?v=10&encoding=json"),
                    io:format("WebSocket upgrade initiated, stream ref: ~p~n", [StreamRef]),
                    {noreply, State#state{conn=Conn, stream_ref=StreamRef}};
                {error, Reason} ->
                    io:format("Failed to establish connection (await_up): ~p~n", [Reason]),
                    gun:close(Conn),
                    schedule_reconnect(State)
            end;
        {error, Reason} ->
            io:format("Unable to open connection (gun:open): ~p~n", [Reason]),
            schedule_reconnect(State)
    end.

schedule_reconnect(State) ->
    NewAttempts = State#state.reconnect_attempts + 1,
    case NewAttempts >= ?MAX_RECONNECT_ATTEMPTS of
        true ->
            io:format("Max reconnection attempts exceeded. Stopping process.~n"),
            {stop, max_reconnect_attempts, reset_connection_state(State#state{reconnect_attempts = NewAttempts})};
        false ->
            % Exponential backoff with jitter
            Delay = min(?RECONNECT_DELAY_BASE * (1 bsl min(NewAttempts, 6)), 10000) + rand:uniform(5000),
            io:format("Scheduling reconnect in ~p ms (attempt ~p/~p)~n",
                     [Delay, NewAttempts, ?MAX_RECONNECT_ATTEMPTS]),
            erlang:send_after(Delay, self(), reconnect),
            {noreply, reset_connection_state(State#state{reconnect_attempts = NewAttempts})}
    end.

cleanup_connection(State) ->
    case State#state.conn of
        undefined -> ok;
        Conn ->
            try gun:close(Conn) catch _:_ -> ok end
    end.

reset_connection_state(State) ->
    State#state{
        conn = undefined,
        stream_ref = undefined,
        heartbeat_ref = undefined,
        ws_connected = false,
        seq = null,
        session_id = null,
        last_heartbeat_ack = true
    }.

%%%===============
%%% Gateway Message Handling
%%%===============
handle_gateway_message(#{<<"op">> := 10, <<"d">> := #{<<"heartbeat_interval">> := Interval}},
                      State = #state{conn=Conn, stream_ref=StreamRef, token=Token, ws_connected=true}) ->
    io:format("Received Hello, heartbeat interval: ~p ms~n", [Interval]),
    maybe_cancel_heartbeat(State),
    
    % Ajuster l'intervalle si nécessaire (minimum 5 secondes)
    AdjustedInterval = max(Interval, 5000),
    io:format("Using heartbeat interval: ~p ms~n", [AdjustedInterval]),
    
    {ok, HeartbeatRef} = timer:send_interval(AdjustedInterval, heartbeat),
    identify(State, Conn, StreamRef, Token),
    {noreply, State#state{heartbeat_ref = HeartbeatRef, last_heartbeat_ack = true}};

handle_gateway_message(#{<<"op">> := 0, <<"t">> := <<"READY">>, <<"d">> := Data, <<"s">> := Seq},
                      State) ->
    SessionId = maps:get(<<"session_id">>, Data),
    User = maps:get(<<"user">>, Data),
    Username = maps:get(<<"username">>, User),
    BotId = maps:get(<<"id">>, User),
    io:format("Bot ready! Connected as ~s (id=~s)~n", [Username, BotId]),
    
    case State#state.command_handler of
        undefined -> ok;
        Handler when is_atom(Handler) ->
            try
                Handler:on_ready(State#state.token)
            catch
                _:_ -> ok
            end;
        _ -> ok
    end,
    
    {noreply, State#state{seq = Seq, session_id = SessionId, bot_id = BotId}};

handle_gateway_message(#{<<"op">> := 0, <<"t">> := <<"MESSAGE_CREATE">>, <<"d">> := Data, <<"s">> := Seq}, State) ->
    Content = maps:get(<<"content">>, Data),
    ChannelId = maps:get(<<"channel_id">>, Data),
    Author = maps:get(<<"author">>, Data, #{}),
    UserId = maps:get(<<"id">>, Author, <<"unknown">>),
    BotId = State#state.bot_id,
    case UserId =:= BotId of
        true -> {noreply, State#state{seq = Seq}};
        false ->
            io:format("DEBUG: MESSAGE_CREATE from ~p: ~p in ~p~n", [UserId, Content, ChannelId]),
            handle_user_message(Content, ChannelId, Author, State),
            {noreply, State#state{seq = Seq}}
    end;

handle_gateway_message(#{<<"op">> := 0, <<"t">> := <<"MESSAGE_UPDATE">>, <<"d">> := Data, <<"s">> := Seq}, State) ->
    Content = maps:get(<<"content">>, Data, <<"(no content)">>),
    ChannelId = maps:get(<<"channel_id">>, Data, <<"unknown">>),
    Author = maps:get(<<"author">>, Data, #{}),
    UserId = maps:get(<<"id">>, Author, <<"unknown">>),
    BotId = State#state.bot_id,
    case UserId =:= BotId of
        true -> {noreply, State#state{seq = Seq}};
        false ->
            io:format("DEBUG: MESSAGE_UPDATE from ~p: ~p in ~p~n", [UserId, Content, ChannelId]),
            {noreply, State#state{seq = Seq}}
    end;

%% Handle INTERACTION_CREATE events (slash commands)
handle_gateway_message(#{<<"op">> := 0, <<"t">> := <<"INTERACTION_CREATE">>, <<"d">> := Data, <<"s">> := Seq}, State) ->
    InteractionType = maps:get(<<"type">>, Data),
    case InteractionType of
        2 -> % APPLICATION_COMMAND
            InteractionId = maps:get(<<"id">>, Data),
            InteractionToken = maps:get(<<"token">>, Data),
            CommandData = maps:get(<<"data">>, Data),
            CommandName = maps:get(<<"name">>, CommandData),
            Options = maps:get(<<"options">>, CommandData, []),
            User = maps:get(<<"user">>, maps:get(<<"member">>, Data, Data), #{}),
            
            io:format("Slash command received: /~s from ~p~n", [CommandName, maps:get(<<"id">>, User, <<"unknown">>)]),
            
            % Dispatch to command handler
            handle_slash_command(CommandName, Options, InteractionId, InteractionToken, User, State),
            {noreply, State#state{seq = Seq}};
        _ ->
            io:format("Unhandled interaction type: ~p~n", [InteractionType]),
            {noreply, State#state{seq = Seq}}
    end;

% Heartbeat ACK - marquer comme reçu
handle_gateway_message(#{<<"op">> := 11}, State) ->
    io:format("Heartbeat ACK received~n"),
    {noreply, State#state{last_heartbeat_ack = true}};

% Reconnect demandé par Discord
handle_gateway_message(#{<<"op">> := 7}, State) ->
    io:format("Discord requested reconnect~n"),
    maybe_cancel_heartbeat(State),
    schedule_reconnect(State);

% Invalid Session
handle_gateway_message(#{<<"op">> := 9, <<"d">> := false}, State) ->
    io:format("Invalid session, starting fresh connection~n"),
    maybe_cancel_heartbeat(State),
    NewState = reset_connection_state(State),
    schedule_reconnect(NewState);

handle_gateway_message(#{<<"op">> := 9, <<"d">> := true}, State) ->
    io:format("Invalid session but resumable~n"),
    maybe_cancel_heartbeat(State),
    schedule_reconnect(State);

handle_gateway_message(Msg, State) ->
    Op = maps:get(<<"op">>, Msg, undefined),
    Type = maps:get(<<"t">>, Msg, undefined),
    io:format("Unhandled Gateway message - op: ~p, type: ~p~n", [Op, Type]),
    NewSeq = case maps:get(<<"s">>, Msg, undefined) of
        null -> State#state.seq;
        undefined -> State#state.seq;
        Seq -> Seq
    end,
    {noreply, State#state{seq = NewSeq}}.

%%%===============
%%% Command Handler Dispatch
%%%===============
handle_user_message(Content, ChannelId, Author, State) ->
    io:format("Dispatching message to command handler: ~p~n", [State#state.command_handler]),
    case State#state.command_handler of
        undefined -> ok;
        Handler when is_atom(Handler) ->
            try
                io:format("Calling handler: ~p:handle_message/4~n", [Handler]),
                Handler:handle_message(Content, ChannelId, Author, State#state.token)
            catch
                Class:Reason ->
                    io:format("Error in command handler ~p: ~p:~p~n", [Handler, Class, Reason])
            end;
        {Module, Function} ->
            try
                io:format("Calling handler: ~p:~p/4~n", [Module, Function]),
                Module:Function(Content, ChannelId, Author, State#state.token)
            catch
                Class:Reason ->
                    io:format("Error in command handler ~p:~p: ~p:~p~n", [Module, Function, Class, Reason])
            end;
        Fun when is_function(Fun, 4) ->
            try
                io:format("Calling handler: function with arity 4~n"),
                Fun(Content, ChannelId, Author, State#state.token)
            catch
                Class:Reason ->
                    io:format("Error in command handler function: ~p:~p~n", [Class, Reason])
            end;
        Other ->
            io:format("Invalid command handler configuration: ~p~n", [Other])
    end.

%%%===============
%%% Discord API Functions
%%%===============
identify(State, Conn, StreamRef, Token) ->
    BinToken = if
        is_binary(Token) -> Token;
        is_list(Token) -> list_to_binary(Token)
    end,
    Payload = #{
        op => 2,  % IDENTIFY opcode
        d => #{
            token => BinToken,
            intents => 37633,  % MESSAGE_CONTENT + GUILD_MESSAGES + DIRECT_MESSAGES intents
            properties => #{
                <<"os">> => <<"linux">>,
                <<"browser">> => <<"erlang">>,
                <<"device">> => <<"erlang">>
            }
        }
    },
    EncodedPayload = jsone:encode(Payload),
    case safe_ws_send(State, Conn, StreamRef, {text, EncodedPayload}) of
        ok ->
            io:format("Identification sent~n");
        Error ->
            io:format("Error sending identification: ~p~n", [Error])
    end.

-spec send_message(binary(), binary(), binary()) -> {ok, binary()} | {error, term()}.
send_message(ChannelId, Content, Token) ->
    BinToken = if
        is_binary(Token) -> Token;
        is_list(Token) -> list_to_binary(Token)
    end,
    TLSOpts = [
        {verify, verify_peer},
        {cacerts, certifi:cacerts()},
        {server_name_indication, "discord.com"},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ],
    ConnOpts = #{
        transport => tls,
        tls_opts => TLSOpts,
        connect_timeout => ?CONNECTION_TIMEOUT,
        protocols => [http]
    },
    io:format("DEBUG: Sending message to ~p: ~p~n", [ChannelId, Content]),
    case gun:open("discord.com", 443, ConnOpts) of
        {ok, Conn} ->
            case gun:await_up(Conn, ?CONNECTION_TIMEOUT) of
                {ok, _Protocol} ->
                    URL = "/api/v10/channels/" ++ binary_to_list(ChannelId) ++ "/messages",
                    Headers = [
                        {<<"authorization">>, <<"Bot ", BinToken/binary>>},
                        {<<"content-type">>, <<"application/json">>}
                    ],
                    Payload = jsone:encode(#{content => Content}),
                    StreamRef = gun:post(Conn, URL, Headers, Payload),
                    case gun:await(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                        {response, nofin, 200, _Headers} ->
                            case gun:await_body(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                                {ok, Body} ->
                                    gun:close(Conn),
                                    case jsone:decode(Body) of
                                        #{<<"id">> := MessageId} -> {ok, MessageId};
                                        _ -> {error, no_message_id}
                                    end;
                                Error ->
                                    gun:close(Conn),
                                    Error
                            end;
                        {response, _, Status, _} ->
                            gun:close(Conn),
                            {error, {status, Status}};
                        {error, Reason} ->
                            gun:close(Conn),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    io:format("Error connecting to Discord API: ~p~n", [Reason]),
                    gun:close(Conn),
                    {error, connection_error}
            end;
        {error, Reason} ->
            io:format("Error opening connection to Discord API: ~p~n", [Reason]),
            {error, connection_error}
    end.

-spec send_message_with_files(binary(), binary(), binary(), [{binary(), binary()}]) -> {ok, binary()} | {error, term()}.
send_message_with_files(ChannelId, Content, Token, Files) ->
    BinToken = if is_binary(Token) -> Token; is_list(Token) -> list_to_binary(Token) end,
    TLSOpts = [
        {verify, verify_peer},
        {cacerts, certifi:cacerts()},
        {server_name_indication, "discord.com"},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ],
    ConnOpts = #{
        transport => tls,
        tls_opts => TLSOpts,
        connect_timeout => ?CONNECTION_TIMEOUT,
        protocols => [http]
    },
    URL = "/api/v10/channels/" ++ binary_to_list(ChannelId) ++ "/messages",
    case gun:open("discord.com", 443, ConnOpts) of
        {ok, Conn} ->
            case gun:await_up(Conn, ?CONNECTION_TIMEOUT) of
                {ok, _Protocol} ->
                    {Headers, Payload} =
                        case Files of
                            [] ->
                                {[{<<"authorization">>, <<"Bot ", BinToken/binary>>},
                                  {<<"content-type">>, <<"application/json">>}],
                                 jsone:encode(#{content => Content})};
                            _ ->
                                Boundary = <<"------------------------", (erlang:integer_to_binary(erlang:unique_integer([positive])))/binary>>,
                                {multipart_headers(BinToken, Boundary),
                                 build_multipart(Content, Files, Boundary)}
                        end,
                    StreamRef = gun:post(Conn, URL, Headers, Payload),
                    case gun:await(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                        {response, nofin, 200, _} ->
                            case gun:await_body(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                                {ok, Body} ->
                                    gun:close(Conn),
                                    case jsone:decode(Body) of
                                        #{<<"id">> := MessageId} -> {ok, MessageId};
                                        _ -> {error, no_message_id}
                                    end;
                                Error -> gun:close(Conn), Error
                            end;
                        {response, _, Status, _} -> gun:close(Conn), {error, {status, Status}};
                        {error, Reason} -> gun:close(Conn), {error, Reason}
                    end;
                {error, _Reason} -> gun:close(Conn), {error, connection_error}
            end;
        {error, _Reason} -> {error, connection_error}
    end.

multipart_headers(BinToken, Boundary) ->
    [
        {<<"authorization">>, <<"Bot ", BinToken/binary>>},
        {<<"content-type">>, <<"multipart/form-data; boundary=", Boundary/binary>>}
    ].

build_multipart(Content, Files, Boundary) ->
    PayloadJson = jsone:encode(#{content => Content}),
    Parts = [
        <<"--", Boundary/binary, "\r\n",
          "Content-Disposition: form-data; name=\"payload_json\"\r\n",
          "Content-Type: application/json\r\n\r\n",
          PayloadJson/binary, "\r\n">>
        | build_file_parts(Files, Boundary, 0)
    ],
    Parts2 = Parts ++ [<<"--", Boundary/binary, "--\r\n">>],
    iolist_to_binary(Parts2).

build_file_parts([], _Boundary, _Idx) -> [];
build_file_parts([{Filename, Data}|Rest], Boundary, Idx) ->
    [
        <<"--", Boundary/binary, "\r\n",
          "Content-Disposition: form-data; name=\"files[", (integer_to_binary(Idx))/binary, "]\"; filename=\"", Filename/binary, "\"\r\n",
          "Content-Type: application/octet-stream\r\n\r\n",
          Data/binary, "\r\n">>
        | build_file_parts(Rest, Boundary, Idx+1)
    ].

-spec edit_message(binary(), binary(), binary(), binary()) -> {ok, integer(), binary()} | {error, term()}.
edit_message(ChannelId, MessageId, Content, Token) ->
    BinToken = if
        is_binary(Token) -> Token;
        is_list(Token) -> list_to_binary(Token)
    end,
    TLSOpts = [
        {verify, verify_peer},
        {cacerts, certifi:cacerts()},
        {server_name_indication, "discord.com"},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ],
    ConnOpts = #{
        transport => tls,
        tls_opts => TLSOpts,
        connect_timeout => ?CONNECTION_TIMEOUT,
        protocols => [http]
    },
    io:format("DEBUG: Editing message ~p in channel ~p to: ~p~n", [MessageId, ChannelId, Content]),
    case gun:open("discord.com", 443, ConnOpts) of
        {ok, Conn} ->
            case gun:await_up(Conn, ?CONNECTION_TIMEOUT) of
                {ok, _Protocol} ->
                    URL = "/api/v10/channels/" ++ binary_to_list(ChannelId) ++ "/messages/" ++ binary_to_list(MessageId),
                    Headers = [
                        {<<"authorization">>, <<"Bot ", BinToken/binary>>},
                        {<<"content-type">>, <<"application/json">>}
                    ],
                    Payload = jsone:encode(#{content => Content}),
                    StreamRef = gun:patch(Conn, URL, Headers, Payload),
                    case gun:await(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                        {response, nofin, Status, _Headers} ->
                            case gun:await_body(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                                {ok, Body} ->
                                    gun:close(Conn),
                                    {ok, Status, Body};
                                Error ->
                                    gun:close(Conn),
                                    Error
                            end;
                        {response, fin, Status, _Headers} ->
                            gun:close(Conn),
                            {ok, Status, <<>>};
                        {error, Reason} ->
                            gun:close(Conn),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    io:format("Error connecting to Discord API: ~p~n", [Reason]),
                    gun:close(Conn),
                    {error, connection_error}
            end;
        {error, Reason} ->
            io:format("Error opening connection to Discord API: ~p~n", [Reason]),
            {error, connection_error}
    end.

%%%===============
%%% Utility Functions
%%%===============
maybe_cancel_heartbeat(State) ->
    case State#state.heartbeat_ref of
        undefined -> ok;
        Ref -> timer:cancel(Ref)
    end.

-spec safe_ws_send(#state{}, pid(), reference(), {atom(), binary()}) -> ok | {error, term()}.
safe_ws_send(State, Conn, StreamRef, Msg) ->
    case State#state.ws_connected of
        true ->
            Result = catch gun:ws_send(Conn, StreamRef, Msg),
            case Result of
                ok -> ok;
                Error -> {error, Error}
            end;
        false ->
            io:format("Attempted ws_send but WebSocket not connected~n"),
            {error, not_connected}
    end.

%%%===============
%%% gen_server boilerplate
%%%===============
handle_call(get_app_id, _From, State) ->
    case State#state.app_id of
        undefined -> {reply, {error, not_available}, State};
        AppId -> {reply, {ok, AppId}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, ok, State}.
handle_cast(_Msg, State) ->
    {noreply, State}.
terminate(_Reason, State) ->
    maybe_cancel_heartbeat(State),
    cleanup_connection(State),
    ok.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===============
%%% Slash Commands API
%%%===============
%% Register multiple global slash commands at once (bulk operation)
-spec register_global_commands(list(), binary()) -> {ok, list()} | {error, term()}.
register_global_commands(Commands, Token) ->
    BinToken = try
        if 
            is_binary(Token) -> 
                Token;
            is_list(Token) -> 
                list_to_binary(Token)
        end
    catch
        _ ->
            throw({error, token_conversion_failed})
    end,
    AppId = case get_bot_application_id(BinToken) of
        {ok, Id} -> 
            Id;
        {error, AppError} -> 
            throw({error, {app_id_fetch_failed, AppError}});
        UnexpectedApp ->
            throw({error, {unexpected_app_response, UnexpectedApp}})
    end,
    
    TLSOpts = [
        {verify, verify_peer},
        {cacerts, certifi:cacerts()},
        {server_name_indication, "discord.com"},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ],
    ConnOpts = #{
        transport => tls,
        tls_opts => TLSOpts,
        connect_timeout => ?CONNECTION_TIMEOUT,
        protocols => [http]
    },
    URL = "/api/v10/applications/" ++ binary_to_list(AppId) ++ "/commands",
    case gun:open("discord.com", 443, ConnOpts) of
        {ok, Conn} ->
            case gun:await_up(Conn, ?CONNECTION_TIMEOUT) of
                {ok, _Protocol} ->
                    Headers = [
                        {<<"authorization">>, <<"Bot ", BinToken/binary>>},
                        {<<"content-type">>, <<"application/json">>}
                    ],
                    FormattedCommands = lists:map(fun(Command) ->
                        Name = maps:get(<<"name">>, Command),
                        Description = maps:get(<<"description">>, Command),
                        Options = maps:get(<<"options">>, Command, []),
                        #{
                            name => Name,
                            description => Description,
                            options => Options
                        }
                    end, Commands),
                    Payload = try
                        P = jsone:encode(FormattedCommands),
                        P
                    catch
                        _ ->
                            gun:close(Conn),
                            throw({error, json_encoding_failed})
                    end,
                    StreamRef = gun:put(Conn, URL, Headers, Payload),
                    case gun:await(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                        {response, nofin, Status, _ResponseHeaders} when Status >= 200, Status < 300 ->
                            case gun:await_body(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                                {ok, Body} ->
                                    gun:close(Conn),
                                    Response = try
                                        R = jsone:decode(Body),
                                        R
                                    catch
                                        _ ->
                                            throw({error, response_decode_failed})
                                    end,
                                    {ok, Response};
                                    
                                {error, BodyError} ->
                                    gun:close(Conn),
                                    {error, {body_read_failed, BodyError}}
                            end;
                            
                        {response, nofin, Status, _Headers} ->
                            case gun:await_body(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                                {ok, Body} ->
                                    gun:close(Conn),
                                    {error, {status, Status, Body}};
                                _ ->
                                    gun:close(Conn),
                                    {error, {status, Status}}
                            end;
                            
                        {error, AwaitReason} ->
                            gun:close(Conn),
                            {error, {await_failed, AwaitReason}}
                    end;
                    
                {error, UpReason} ->
                    gun:close(Conn),
                    {error, {connection_up_failed, UpReason}}
            end;
            
        {error, OpenReason} ->
            {error, {connection_open_failed, OpenReason}}
    end.

%% Register a global slash command
-spec register_global_command(binary(), binary(), binary()) -> {ok, binary()} | {error, term()}.
register_global_command(CommandName, Description, Token) ->
    register_global_command(CommandName, Description, [], Token).

-spec register_global_command(binary(), binary(), list(), binary()) -> {ok, binary()} | {error, term()}.
register_global_command(CommandName, Description, Options, Token) ->
    BinToken = if is_binary(Token) -> Token; is_list(Token) -> list_to_binary(Token) end,
    
    % First get bot application ID
    case get_bot_application_id(BinToken) of
        {ok, AppId} ->
            TLSOpts = [
                {verify, verify_peer},
                {cacerts, certifi:cacerts()},
                {server_name_indication, "discord.com"},
                {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
            ],
            ConnOpts = #{
                transport => tls,
                tls_opts => TLSOpts,
                connect_timeout => ?CONNECTION_TIMEOUT,
                protocols => [http]
            },
            
            URL = "/api/v10/applications/" ++ binary_to_list(AppId) ++ "/commands",
            
            case gun:open("discord.com", 443, ConnOpts) of
                {ok, Conn} ->
                    case gun:await_up(Conn, ?CONNECTION_TIMEOUT) of
                        {ok, _Protocol} ->
                            Headers = [
                                {<<"authorization">>, <<"Bot ", BinToken/binary>>},
                                {<<"content-type">>, <<"application/json">>}
                            ],
                            Payload = jsone:encode(#{
                                name => CommandName,
                                description => Description,
                                options => Options
                            }),
                            StreamRef = gun:post(Conn, URL, Headers, Payload),
                            case gun:await(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                                {response, nofin, Status, _Headers} when Status >= 200, Status < 300 ->
                                    case gun:await_body(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                                        {ok, Body} ->
                                            gun:close(Conn),
                                            Response = jsone:decode(Body),
                                            CommandId = maps:get(<<"id">>, Response),
                                            {ok, CommandId};
                                        Error ->
                                            gun:close(Conn),
                                            Error
                                    end;
                                {response, nofin, Status, _Headers} ->
                                    case gun:await_body(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                                        {ok, Body} ->
                                            gun:close(Conn),
                                            {error, {status, Status, Body}};
                                        _ ->
                                            gun:close(Conn),
                                            {error, {status, Status}}
                                    end;
                                {error, Reason} ->
                                    gun:close(Conn),
                                    {error, Reason}
                            end;
                        {error, Reason} ->
                            gun:close(Conn),
                            {error, connection_error, Reason}
                    end;
                {error, Reason} ->
                    {error, connection_error, Reason}
            end;
        Error ->
            Error
    end.

%% Register a guild-specific slash command
-spec register_guild_command(binary(), binary(), binary(), binary()) -> {ok, binary()} | {error, term()}.
register_guild_command(GuildId, CommandName, Description, Token) ->
    register_guild_command(GuildId, CommandName, Description, [], Token).

-spec register_guild_command(binary(), binary(), binary(), list(), binary()) -> {ok, binary()} | {error, term()}.
register_guild_command(GuildId, CommandName, Description, Options, Token) ->
    BinToken = if is_binary(Token) -> Token; is_list(Token) -> list_to_binary(Token) end,
    
    case get_bot_application_id(BinToken) of
        {ok, AppId} ->
            TLSOpts = [
                {verify, verify_peer},
                {cacerts, certifi:cacerts()},
                {server_name_indication, "discord.com"},
                {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
            ],
            ConnOpts = #{
                transport => tls,
                tls_opts => TLSOpts,
                connect_timeout => ?CONNECTION_TIMEOUT,
                protocols => [http]
            },
            
            URL = "/api/v10/applications/" ++ binary_to_list(AppId) ++ "/guilds/" ++ binary_to_list(GuildId) ++ "/commands",
            
            case gun:open("discord.com", 443, ConnOpts) of
                {ok, Conn} ->
                    case gun:await_up(Conn, ?CONNECTION_TIMEOUT) of
                        {ok, _Protocol} ->
                            Headers = [
                                {<<"authorization">>, <<"Bot ", BinToken/binary>>},
                                {<<"content-type">>, <<"application/json">>}
                            ],
                            Payload = jsone:encode(#{
                                name => CommandName,
                                description => Description,
                                options => Options
                            }),
                            StreamRef = gun:post(Conn, URL, Headers, Payload),
                            case gun:await(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                                {response, nofin, Status, _Headers} when Status >= 200, Status < 300 ->
                                    case gun:await_body(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                                        {ok, Body} ->
                                            gun:close(Conn),
                                            Response = jsone:decode(Body),
                                            CommandId = maps:get(<<"id">>, Response),
                                            {ok, CommandId};
                                        Error ->
                                            gun:close(Conn),
                                            Error
                                    end;
                                {response, nofin, Status, _Headers} ->
                                    case gun:await_body(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                                        {ok, Body} ->
                                            gun:close(Conn),
                                            {error, {status, Status, Body}};
                                        _ ->
                                            gun:close(Conn),
                                            {error, {status, Status}}
                                    end;
                                {error, Reason} ->
                                    gun:close(Conn),
                                    {error, Reason}
                            end;
                        {error, Reason} ->
                            gun:close(Conn),
                            {error, connection_error, Reason}
                    end;
                {error, Reason} ->
                    {error, connection_error, Reason}
            end;
        Error ->
            Error
    end.

%% Respond to a slash command interaction
-spec respond_to_interaction(binary(), binary(), binary()) -> ok | {error, term()}.
respond_to_interaction(InteractionId, InteractionToken, Content) ->
    respond_to_interaction(InteractionId, InteractionToken, Content, #{}).

-spec respond_to_interaction(binary(), binary(), binary(), map()) -> ok | {error, term()}.
respond_to_interaction(InteractionId, InteractionToken, Content, Options) ->
    TLSOpts = [
        {verify, verify_peer},
        {cacerts, certifi:cacerts()},
        {server_name_indication, "discord.com"},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ],
    ConnOpts = #{
        transport => tls,
        tls_opts => TLSOpts,
        connect_timeout => ?CONNECTION_TIMEOUT,
        protocols => [http]
    },
    
    URL = "/api/v10/interactions/" ++ binary_to_list(InteractionId) ++ "/" ++ binary_to_list(InteractionToken) ++ "/callback",
    
    case gun:open("discord.com", 443, ConnOpts) of
        {ok, Conn} ->
            case gun:await_up(Conn, ?CONNECTION_TIMEOUT) of
                {ok, _Protocol} ->
                    Headers = [{<<"content-type">>, <<"application/json">>}],
                    
                    ResponseType = maps:get(type, Options, 4), % 4 = CHANNEL_MESSAGE_WITH_SOURCE
                    Data = maps:merge(#{content => Content}, maps:get(data, Options, #{})),
                    
                    Payload = jsone:encode(#{
                        type => ResponseType,
                        data => Data
                    }),
                    
                    StreamRef = gun:post(Conn, URL, Headers, Payload),
                    case gun:await(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                        {response, fin, 204, _Headers} ->
                            gun:close(Conn),
                            ok;
                        {response, nofin, Status, _Headers} ->
                            case gun:await_body(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                                {ok, Body} ->
                                    gun:close(Conn),
                                    {error, {status, Status, Body}};
                                _ ->
                                    gun:close(Conn),
                                    {error, {status, Status}}
                            end;
                        {error, Reason} ->
                            gun:close(Conn),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    gun:close(Conn),
                    {error, connection_error, Reason}
            end;
        {error, Reason} ->
            {error, connection_error, Reason}
    end.

%% Respond to a slash command interaction with files
-spec respond_to_interaction_with_files(binary(), binary(), binary(), [{binary(), binary()}]) -> ok | {error, term()}.
respond_to_interaction_with_files(InteractionId, InteractionToken, Content, Files) ->
    respond_to_interaction_with_files(InteractionId, InteractionToken, Content, Files, #{}).

-spec respond_to_interaction_with_files(binary(), binary(), binary(), [{binary(), binary()}], map()) -> ok | {error, term()}.
respond_to_interaction_with_files(InteractionId, InteractionToken, Content, Files, Options) ->
    TLSOpts = [
        {verify, verify_peer},
        {cacerts, certifi:cacerts()},
        {server_name_indication, "discord.com"},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ],
    ConnOpts = #{
        transport => tls,
        tls_opts => TLSOpts,
        connect_timeout => ?CONNECTION_TIMEOUT,
        protocols => [http]
    },

    URL = "/api/v10/interactions/" ++ binary_to_list(InteractionId) ++ "/" ++ binary_to_list(InteractionToken) ++ "/callback",

    case gun:open("discord.com", 443, ConnOpts) of
        {ok, Conn} ->
            case gun:await_up(Conn, ?CONNECTION_TIMEOUT) of
                {ok, _Protocol} ->
                    ResponseType = maps:get(type, Options, 4), % 4 = CHANNEL_MESSAGE_WITH_SOURCE
                    Data = maps:merge(#{content => Content}, maps:get(data, Options, #{})),

                    {Headers, Payload} = case Files of
                        [] ->
                            % No files, use JSON
                            {[{<<"content-type">>, <<"application/json">>}],
                             jsone:encode(#{
                                 type => ResponseType,
                                 data => Data
                             })};
                        _ ->
                            % With files, use multipart/form-data
                            Boundary = <<"------------------------", (erlang:integer_to_binary(erlang:unique_integer([positive])))/binary>>,
                            {[{<<"content-type">>, <<"multipart/form-data; boundary=", Boundary/binary>>}],
                             build_interaction_multipart(ResponseType, Data, Files, Boundary)}
                    end,

                    StreamRef = gun:post(Conn, URL, Headers, Payload),
                    case gun:await(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                        {response, fin, 204, _Headers} ->
                            gun:close(Conn),
                            ok;
                        {response, nofin, Status, _Headers} ->
                            case gun:await_body(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                                {ok, Body} ->
                                    gun:close(Conn),
                                    {error, {status, Status, Body}};
                                _ ->
                                    gun:close(Conn),
                                    {error, {status, Status}}
                            end;
                        {error, Reason} ->
                            gun:close(Conn),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    gun:close(Conn),
                    {error, connection_error, Reason}
            end;
        {error, Reason} ->
            {error, connection_error, Reason}
    end.

%% Build multipart payload for interaction responses with files
build_interaction_multipart(ResponseType, Data, Files, Boundary) ->
    PayloadJson = jsone:encode(#{
        type => ResponseType,
        data => Data
    }),
    Parts = [
        <<"--", Boundary/binary, "\r\n",
          "Content-Disposition: form-data; name=\"payload_json\"\r\n",
          "Content-Type: application/json\r\n\r\n",
          PayloadJson/binary, "\r\n">>
        | build_file_parts(Files, Boundary, 0)
    ],
    Parts2 = Parts ++ [<<"--", Boundary/binary, "--\r\n">>],
    iolist_to_binary(Parts2).

%% Helper to get bot application ID
-spec get_bot_application_id(binary()) -> {ok, binary()} | {error, term()}.
get_bot_application_id(BinToken) ->
    TLSOpts = [
        {verify, verify_peer},
        {cacerts, certifi:cacerts()},
        {server_name_indication, "discord.com"},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ],
    ConnOpts = #{
        transport => tls,
        tls_opts => TLSOpts,
        connect_timeout => ?CONNECTION_TIMEOUT,
        protocols => [http]
    },
    
    case gun:open("discord.com", 443, ConnOpts) of
        {ok, Conn} ->
            case gun:await_up(Conn, ?CONNECTION_TIMEOUT) of
                {ok, _Protocol} ->
                    Headers = [{<<"authorization">>, <<"Bot ", BinToken/binary>>}],
                    StreamRef = gun:get(Conn, "/api/v10/oauth2/applications/@me", Headers),
                    case gun:await(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                        {response, nofin, 200, _Headers} ->
                            case gun:await_body(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                                {ok, Body} ->
                                    gun:close(Conn),
                                    Response = jsone:decode(Body),
                                    AppId = maps:get(<<"id">>, Response),
                                    {ok, AppId};
                                Error ->
                                    gun:close(Conn),
                                    Error
                            end;
                        {response, _, Status, _} ->
                            gun:close(Conn),
                            {error, {status, Status}};
                        {error, Reason} ->
                            gun:close(Conn),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    gun:close(Conn),
                    {error, connection_error, Reason}
            end;
        {error, Reason} ->
            {error, connection_error, Reason}
    end.

%%%===============
%%% Slash Command Handler Dispatch
%%%===============
handle_slash_command(CommandName, Options, InteractionId, InteractionToken, User, State) ->
    case State#state.command_handler of
        undefined -> 
            respond_to_interaction(InteractionId, InteractionToken, <<"No command handler configured">>);
        Handler when is_atom(Handler) ->
            try
                Handler:handle_slash_command(CommandName, Options, InteractionId, InteractionToken, User, State#state.token)
            catch
                Class:Reason ->
                    io:format("Error in slash command handler ~p: ~p:~p~n", [Handler, Class, Reason]),
                    respond_to_interaction(InteractionId, InteractionToken, <<"An error occurred processing your command">>)
            end;
        {Module, Function} ->
            try
                Module:Function(CommandName, Options, InteractionId, InteractionToken, User, State#state.token)
            catch
                Class:Reason ->
                    io:format("Error in slash command handler ~p:~p: ~p:~p~n", [Module, Function, Class, Reason]),
                    respond_to_interaction(InteractionId, InteractionToken, <<"An error occurred processing your command">>)
            end;
        Fun when is_function(Fun, 6) ->
            try
                Fun(CommandName, Options, InteractionId, InteractionToken, User, State#state.token)
            catch
                Class:Reason ->
                    io:format("Error in slash command handler function: ~p:~p~n", [Class, Reason]),
                    respond_to_interaction(InteractionId, InteractionToken, <<"An error occurred processing your command">>)
            end;
        Other ->
            io:format("Invalid command handler configuration: ~p~n", [Other]),
            respond_to_interaction(InteractionId, InteractionToken, <<"Invalid command handler configuration">>)
    end.

%% Edit an interaction response (for updating messages after initial response)
-spec edit_interaction_response(binary(), binary(), binary()) -> ok | {error, term()}.
edit_interaction_response(InteractionToken, MessageId, Content) ->
    edit_interaction_response(InteractionToken, MessageId, Content, #{}).

-spec edit_interaction_response(binary(), binary(), binary(), map()) -> ok | {error, term()}.
edit_interaction_response(InteractionToken, MessageId, Content, Options) ->
    TLSOpts = [
        {verify, verify_peer},
        {cacerts, certifi:cacerts()},
        {server_name_indication, "discord.com"},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ],
    ConnOpts = #{
        transport => tls,
        tls_opts => TLSOpts,
        connect_timeout => ?CONNECTION_TIMEOUT,
        protocols => [http]
    },

    % For editing the original response, use "@original" as MessageId
    MsgId = case MessageId of
        <<"@original">> -> <<"@original">>;
        _ -> MessageId
    end,

    % Get the application ID from state - this should be the BOT's user ID
    AppId = case get_stored_app_id() of
        {ok, Id} -> 
            io:format("Got App ID: ~p~n", [Id]),
            Id;
        {error, not_ready} ->
            io:format("ERROR: Bot ID not available~n"),
            throw({error, bot_not_ready})
    end,

    % Webhook URL for interaction - IMPORTANT: No auth header needed!
    % The interaction token itself provides authentication
    URL = "/api/v10/webhooks/" ++ binary_to_list(AppId) 
          ++ "/" ++ binary_to_list(InteractionToken) ++ "/messages/" ++ binary_to_list(MsgId),
    
    case gun:open("discord.com", 443, ConnOpts) of
        {ok, Conn} ->
            case gun:await_up(Conn, ?CONNECTION_TIMEOUT) of
                {ok, _Protocol} ->
                    
                    % CRITICAL: Webhooks don't use Authorization header!
                    Headers = [{<<"content-type">>, <<"application/json">>}],
                    Data = maps:merge(#{content => Content}, Options),
                    Payload = jsone:encode(Data),
                    StreamRef = gun:patch(Conn, URL, Headers, Payload),
                    
                    case gun:await(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                        {response, nofin, Status, _ResponseHeaders} when Status >= 200, Status < 300 ->
                            case gun:await_body(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                                {ok, Body} ->
                                    gun:close(Conn),
                                    ok;
                                Error ->
                                    gun:close(Conn),
                                    io:format("Error reading body: ~p~n", [Error]),
                                    Error
                            end;
                        {response, fin, Status, _Headers} when Status >= 200, Status < 300 ->
                            gun:close(Conn),
                            ok;
                        {response, nofin, Status, _Headers} ->
                            io:format("ERROR! Status: ~p~n", [Status]),
                            case gun:await_body(Conn, StreamRef, ?CONNECTION_TIMEOUT) of
                                {ok, Body} ->
                                    gun:close(Conn),
                                    io:format("Error body: ~s~n", [Body]),
                                    {error, {status, Status, Body}};
                                _ ->
                                    gun:close(Conn),
                                    {error, {status, Status}}
                            end;
                        {response, fin, Status, _Headers} ->
                            gun:close(Conn),
                            io:format("ERROR (fin)! Status: ~p~n", [Status]),
                            {error, {status, Status}};
                        {error, Reason} ->
                            gun:close(Conn),
                            io:format("Error in gun:await: ~p~n", [Reason]),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    gun:close(Conn),
                    io:format("Error connection UP: ~p~n", [Reason]),
                    {error, connection_error, Reason}
            end;
        {error, Reason} ->
            io:format("Error opening connection: ~p~n", [Reason]),
            {error, connection_error, Reason}
    end.

