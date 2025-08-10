%%%===================================================================
%%% Discord Bot Light Client
%%% A lightweight Discord bot client with configurable command handlers
%%% Fixed for Gun 2.1.0 compatibility
%%%===================================================================
-module(discord_bot_light_client).
-behaviour(gen_server).

%% API exports
-export([start_link/1, start_link/2, send_message/3, send_message_with_files/4, edit_message/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% State record definition
-record(state, {
          token,                    % Discord bot token
          conn,                     % Gun connection handle
          seq = null,              % Gateway sequence number
          session_id = null,       % Discord session ID
          heartbeat_ref,           % Heartbeat timer reference
          stream_ref = undefined,  % WebSocket stream reference
          bot_id = undefined,      % Bot's user ID
          command_handler = undefined,  % Command handler configuration
          ws_connected = false     % WebSocket connection status
         }).

%%%===================================================================
%%% Public API
%%%===================================================================

%% @doc Start the Discord bot client with just a token (no command handler)
-spec start_link(binary() | string()) -> {ok, pid()} | {error, term()}.
start_link(Token) ->
    start_link(Token, []).

%% @doc Start the Discord bot client with token and options
%% Options can include:
%% - {command_handler, Module} - Module implementing handle_message/4
%% - {command_handler, {Module, Function}} - MFA style handler
%% - {command_handler, Fun} - Function with arity 4
-spec start_link(binary() | string(), list()) -> {ok, pid()} | {error, term()}.
start_link(Token, Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Token, Options], []).

%%%===================================================================
%%% gen_server Callbacks
%%%===================================================================

%% @doc Initialize the gen_server with token and command handler
init([Token, Options]) ->
    process_flag(trap_exit, true),
    CommandHandler = proplists:get_value(command_handler, Options, undefined),
    self() ! connect,
    {ok, #state{token = Token, command_handler = CommandHandler}}.

%% @doc Handle connection initiation
handle_info(connect, State) ->
    io:format("Connecting to Discord Gateway...~n"),
    % Configure TLS options for secure connection to Discord Gateway
    TLSOpts = [
               {verify, verify_peer},
               {cacerts, certifi:cacerts()},
               {server_name_indication, "gateway.discord.gg"},
               {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
              ],
    ConnOpts = #{transport => tls, tls_opts => TLSOpts, protocols => [http]},

    % Open connection to Discord Gateway
    case gun:open("gateway.discord.gg", 443, ConnOpts) of
        {ok, Conn} ->
            io:format("Connection opened: ~p~n", [Conn]),
            % Wait for connection to be established FIRST
            case gun:await_up(Conn, 10000) of
                {ok, Protocol} ->
                    io:format("Connection established with protocol: ~p~n", [Protocol]),
                    % NOW upgrade to WebSocket
                    StreamRef = gun:ws_upgrade(Conn, "/?v=10&encoding=json"),
                    io:format("WebSocket upgrade initiated, stream ref: ~p~n", [StreamRef]),
                    {noreply, State#state{conn=Conn, stream_ref=StreamRef}};
                {error, Reason} ->
                    io:format("Failed to establish connection: ~p~n", [Reason]),
                    gun:close(Conn),
                    erlang:send_after(5000, self(), connect),
                    {noreply, State}
            end;
        {error, Reason} ->

            io:format("Unable to open connection: ~p~n", [Reason]),
            erlang:send_after(5000, self(), connect),
            {noreply, State}
    end;

%% @doc Handle WebSocket upgrade confirmation
handle_info({gun_upgrade, Conn, StreamRef, [<<"websocket">>], _Headers}, State) ->
    io:format("WebSocket upgrade confirmed~n"),
    {noreply, State#state{conn=Conn, stream_ref=StreamRef, ws_connected=true}};

%% @doc Handle incoming WebSocket messages from Discord Gateway
handle_info({gun_ws, Conn, StreamRef, {text, Frame}}, State) ->
    try
        % Decode JSON message from Discord
        Decoded = jsone:decode(Frame),
        handle_gateway_message(Decoded, State#state{conn=Conn, stream_ref=StreamRef})
    catch
        Class:Reason:Stacktrace ->
            io:format("Error decoding message: ~p:~p~n~p~n", [Class, Reason, Stacktrace]),
            {noreply, State}
    end;

%% @doc Handle WebSocket connection drops
handle_info({gun_down, Conn, ws, Reason, _, _}, State = #state{conn = Conn}) ->
    io:format("WebSocket disconnection detected: ~p~n", [Reason]),
    maybe_cancel_heartbeat(State),
    erlang:send_after(2000, self(), connect),
    {noreply, State#state{conn = undefined, stream_ref = undefined, heartbeat_ref = undefined, ws_connected = false}};

%% @doc Handle connection errors
handle_info({gun_error, Conn, StreamRef, Reason}, State = #state{conn = Conn, stream_ref = StreamRef}) ->
    io:format("Gun error: ~p~n", [Reason]),
    maybe_cancel_heartbeat(State),
    gun:close(Conn),
    erlang:send_after(2000, self(), connect),
    {noreply, State#state{conn = undefined, stream_ref = undefined, heartbeat_ref = undefined, ws_connected = false}};

%% @doc Handle reconnection attempts
handle_info(reconnect, State) ->
    io:format("Attempting reconnection...~n"),
    erlang:send_after(2000, self(), connect),
    {noreply, State};

%% @doc Handle heartbeat when no connection is active
handle_info(heartbeat, State = #state{ws_connected = false}) ->
    io:format("No active WebSocket connection for heartbeat~n"),
    {noreply, State};

%% @doc Send heartbeat to Discord to maintain connection
handle_info(heartbeat, State = #state{conn = Conn, stream_ref = StreamRef, seq = Seq, ws_connected = true}) ->
    Payload = #{op => 1, d => Seq},
    case gun:ws_send(Conn, StreamRef, {text, jsone:encode(Payload)}) of
        ok -> 
            io:format("Heartbeat sent~n");
        Error -> 
            io:format("Error sending heartbeat: ~p~n", [Error])
    end,
    {noreply, State};

%% @doc Handle unexpected messages
handle_info(Info, State) ->
    io:format("Unexpected message in handle_info: ~p~n", [Info]),
    {noreply, State}.

%%%===================================================================
%%% Gateway Message Handling
%%%===================================================================

%% @doc Handle Discord Gateway HELLO message (opcode 10)
%% This initiates the heartbeat and identification process
handle_gateway_message(#{<<"op">> := 10, <<"d">> := #{<<"heartbeat_interval">> := Interval}},
                      State = #state{conn=Conn, stream_ref=StreamRef, token=Token, ws_connected=true}) ->
    io:format("Received Hello, heartbeat interval: ~p ms~n", [Interval]),

    % Cancel any existing heartbeat and start new one
    maybe_cancel_heartbeat(State),
    {ok, HeartbeatRef} = timer:send_interval(Interval, heartbeat),

    % Send identification to Discord
    identify(Conn, StreamRef, Token),
    {noreply, State#state{heartbeat_ref = HeartbeatRef}};

%% @doc Handle READY event (opcode 0, type READY)
%% This confirms successful authentication and provides bot information
handle_gateway_message(#{<<"op">> := 0, <<"t">> := <<"READY">>, <<"d">> := Data, <<"s">> := Seq}, State) ->
    SessionId = maps:get(<<"session_id">>, Data),
    User = maps:get(<<"user">>, Data),
    Username = maps:get(<<"username">>, User),
    BotId = maps:get(<<"id">>, User),
    io:format("Bot ready! Connected as ~s (id=~s)~n", [Username, BotId]),
    {noreply, State#state{seq = Seq, session_id = SessionId, bot_id = BotId}};

%% @doc Handle MESSAGE_CREATE event - new messages in channels
handle_gateway_message(#{<<"op">> := 0, <<"t">> := <<"MESSAGE_CREATE">>, <<"d">> := Data, <<"s">> := Seq}, State) ->
    Content = maps:get(<<"content">>, Data),
    ChannelId = maps:get(<<"channel_id">>, Data),
    Author = maps:get(<<"author">>, Data, #{}),
    UserId = maps:get(<<"id">>, Author, <<"unknown">>),
    BotId = State#state.bot_id,

    % Ignore messages from the bot itself to prevent loops
    case UserId =:= BotId of
        true ->
            {noreply, State#state{seq = Seq}};
        false ->
            io:format("DEBUG: MESSAGE_CREATE from ~p: ~p in ~p~n", [UserId, Content, ChannelId]),
            % Dispatch to command handler
            handle_user_message(Content, ChannelId, Author, State),
            {noreply, State#state{seq = Seq}}
    end;

%% @doc Handle MESSAGE_UPDATE event - edited messages
handle_gateway_message(#{<<"op">> := 0, <<"t">> := <<"MESSAGE_UPDATE">>, <<"d">> := Data, <<"s">> := Seq}, State) ->
    Content = maps:get(<<"content">>, Data, <<"(no content)">>),
    ChannelId = maps:get(<<"channel_id">>, Data, <<"unknown">>),
    Author = maps:get(<<"author">>, Data, #{}),
    UserId = maps:get(<<"id">>, Author, <<"unknown">>),
    BotId = State#state.bot_id,

    % Log message updates but don't process them as commands
    case UserId =:= BotId of
        true ->
            {noreply, State#state{seq = Seq}};
        false ->
            io:format("DEBUG: MESSAGE_UPDATE from ~p: ~p in ~p~n", [UserId, Content, ChannelId]),
            {noreply, State#state{seq = Seq}}
    end;

%% @doc Handle heartbeat ACK (opcode 11)
handle_gateway_message(#{<<"op">> := 11}, State) ->
    io:format("Heartbeat ACK received~n"),
    {noreply, State};

%% @doc Handle any unrecognized Gateway messages
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

%%%===================================================================
%%% Command Handler Dispatch
%%%===================================================================

%% @doc Dispatch user messages to the configured command handler
handle_user_message(Content, ChannelId, Author, State) ->
    io:format("Dispatching message to command handler: ~p~n", [State#state.command_handler]),
    case State#state.command_handler of
        undefined ->
            % No handler configured - do nothing
            ok;
        Handler when is_atom(Handler) ->
            % Handler is a module name - call Module:handle_message/4
            try
                io:format("Calling handler: ~p:handle_message/4~n", [Handler]),
                Handler:handle_message(Content, ChannelId, Author, State#state.token)
            catch
                Class:Reason ->
                    io:format("Error in command handler ~p: ~p:~p~n", [Handler, Class, Reason])
            end;
        {Module, Function} ->
            % Handler is {Module, Function} tuple
            try
                io:format("Calling handler: ~p:~p/4~n", [Module, Function]),
                Module:Function(Content, ChannelId, Author, State#state.token)
            catch
                Class:Reason ->
                    io:format("Error in command handler ~p:~p: ~p:~p~n", [Module, Function, Class, Reason])
            end;
        Fun when is_function(Fun, 4) ->
            % Handler is a function with arity 4
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

%%%===================================================================
%%% Discord API Functions
%%%===================================================================

%% @doc Send identification payload to Discord Gateway
identify(Conn, StreamRef, Token) ->
    BinToken = if
        is_binary(Token) -> Token;
        is_list(Token) -> list_to_binary(Token)
    end,
    Payload = #{
        op => 2,  % IDENTIFY opcode
        d => #{
            token => BinToken,
            intents => 33536,  % MESSAGE_CONTENT + GUILD_MESSAGES intents
            properties => #{
                <<"os">> => <<"linux">>,
                <<"browser">> => <<"erlang">>,
                <<"device">> => <<"erlang">>
            }
        }
    },
    case gun:ws_send(Conn, StreamRef, {text, jsone:encode(Payload)}) of
        ok -> 
            io:format("Identification sent~n");
        Error -> 
            io:format("Error sending identification: ~p~n", [Error])
    end.

%% @doc Send a message to a Discord channel
-spec send_message(binary(), binary(), binary()) -> {ok, binary()} | {error, term()}.
send_message(ChannelId, Content, Token) ->
    % Ensure token is binary
    BinToken = if
        is_binary(Token) -> Token;
        is_list(Token) -> list_to_binary(Token)
    end,

    % Configure TLS for Discord API
    TLSOpts = [
        {verify, verify_peer},
        {cacerts, certifi:cacerts()},
        {server_name_indication, "discord.com"},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ],
    ConnOpts = #{
        transport => tls,
        tls_opts => TLSOpts,
        connect_timeout => 10000,
        protocols => [http]
    },

    io:format("DEBUG: Sending message to ~p: ~p~n", [ChannelId, Content]),

    % Open connection to Discord API
    case gun:open("discord.com", 443, ConnOpts) of
        {ok, Conn} ->
            case gun:await_up(Conn, 10000) of
                {ok, _Protocol} ->
                    % Build API request
                    URL = "/api/v10/channels/" ++ binary_to_list(ChannelId) ++ "/messages",
                    Headers = [
                        {<<"authorization">>, <<"Bot ", BinToken/binary>>},
                        {<<"content-type">>, <<"application/json">>}
                    ],
                    Payload = jsone:encode(#{content => Content}),

                    % Send POST request
                    StreamRef = gun:post(Conn, URL, Headers, Payload),
                    case gun:await(Conn, StreamRef, 10000) of
                        {response, nofin, 200, _Headers} ->
                            case gun:await_body(Conn, StreamRef, 10000) of
                                {ok, Body} ->
                                    gun:close(Conn),
                                    % Extract message ID from response
                                    case jsone:decode(Body) of
                                        #{<<"id">> := MessageId} ->
                                            {ok, MessageId};
                                        _ ->
                                            {error, no_message_id}
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
        connect_timeout => 10000,
        protocols => [http]
    },
    URL = "/api/v10/channels/" ++ binary_to_list(ChannelId) ++ "/messages",
    case gun:open("discord.com", 443, ConnOpts) of
        {ok, Conn} ->
            case gun:await_up(Conn, 10000) of
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
                    case gun:await(Conn, StreamRef, 10000) of
                        {response, nofin, 200, _} ->
                            case gun:await_body(Conn, StreamRef, 10000) of
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

%% @doc Edit an existing message in a Discord channel
-spec edit_message(binary(), binary(), binary(), binary()) -> {ok, integer(), binary()} | {error, term()}.
edit_message(ChannelId, MessageId, Content, Token) ->
    % Ensure token is binary
    BinToken = if
        is_binary(Token) -> Token;
        is_list(Token) -> list_to_binary(Token)
    end,

    % Configure TLS for Discord API
    TLSOpts = [
        {verify, verify_peer},
        {cacerts, certifi:cacerts()},
        {server_name_indication, "discord.com"},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ],
    ConnOpts = #{
        transport => tls,
        tls_opts => TLSOpts,
        connect_timeout => 10000,
        protocols => [http]
    },

    io:format("DEBUG: Editing message ~p in channel ~p to: ~p~n", [MessageId, ChannelId, Content]),

    % Open connection to Discord API
    case gun:open("discord.com", 443, ConnOpts) of
        {ok, Conn} ->
            case gun:await_up(Conn, 10000) of
                {ok, _Protocol} ->
                    % Build API request
                    URL = "/api/v10/channels/" ++ binary_to_list(ChannelId) ++ "/messages/" ++ binary_to_list(MessageId),
                    Headers = [
                        {<<"authorization">>, <<"Bot ", BinToken/binary>>},
                        {<<"content-type">>, <<"application/json">>}
                    ],
                    Payload = jsone:encode(#{content => Content}),

                    % Send PATCH request
                    StreamRef = gun:patch(Conn, URL, Headers, Payload),
                    case gun:await(Conn, StreamRef, 10000) of
                        {response, nofin, Status, _Headers} ->
                            case gun:await_body(Conn, StreamRef, 10000) of
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

%%%===================================================================
%%% Utility Functions
%%%===================================================================

%% @doc Cancel existing heartbeat timer if one exists
maybe_cancel_heartbeat(State) ->
    case State#state.heartbeat_ref of
        undefined -> ok;
        Ref -> timer:cancel(Ref)
    end.

%%%===================================================================
%%% gen_server Boilerplate
%%%===================================================================

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    maybe_cancel_heartbeat(State),
    case State#state.conn of
        undefined -> ok;
        Conn -> gun:close(Conn)
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
