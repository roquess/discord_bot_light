%%%===================================================================
%%% Discord Bot Light Client
%%% A lightweight Discord bot client with configurable command handlers
%%%===================================================================
-module(discord_bot_light_client).
-behaviour(gen_server).

%% API exports
-export([start_link/1, start_link/2, send_message/3, edit_message/4]).

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
          command_handler = undefined  % Command handler configuration
         }).

-define(GATEWAY_URL, "gateway.discord.gg").

%%%===================================================================
%%% Public API
%%%===================================================================

%% @doc Start the Discord bot client with just a token (no command handler)
-spec start_link(binary() | string()) -> {ok, pid()} | {error, term()}.
start_link(Token) ->
    start_link(Token, []).

%% @doc Start the Discord bot client with token and options
%% Options can include:
%% - {command_handler, Module} - Module implementing handle_message/3
%% - {command_handler, {Module, Function}} - MFA style handler
%% - {command_handler, Fun} - Function with arity 3
-spec start_link(binary() | string(), list()) -> {ok, pid()} | {error, term()}.
start_link(Token, Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Token, Options], []).

%% @doc Send a message to a Discord channel
-spec send_message(pid(), binary(), binary()) -> {ok, binary()} | {error, term()}.
send_message(Pid, ChannelId, Content) ->
    gen_server:call(Pid, {send_message, ChannelId, Content}).

%% @doc Edit an existing message in a Discord channel
-spec edit_message(pid(), binary(), binary(), binary()) -> {ok, integer(), binary()} | {error, term()}.
edit_message(Pid, ChannelId, MessageId, Content) ->
    gen_server:call(Pid, {edit_message, ChannelId, MessageId, Content}).

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
    % Configure TLS options for secure connection to Discord Gateway
    TLSOpts = [
               {verify, verify_peer},
               {cacerts, certifi:cacerts()},
               {server_name_indication, ?GATEWAY_URL},
               {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
              ],
    ConnOpts = #{transport => tls, tls_opts => TLSOpts, protocols => [http]},

    % Open connection to Discord Gateway
    case gun:open(?GATEWAY_URL, 443, ConnOpts) of
        {ok, Conn} ->
            % Upgrade to WebSocket connection
            StreamRef = gun:ws_upgrade(Conn, "/?v=10&encoding=json"),
            io:format("Connection established: ~p, Process alive: ~p~n", [Conn, is_process_alive(Conn)]),
            io:format("Stream reference: ~p, Is reference: ~p~n", [StreamRef, is_reference(StreamRef)]),

            % Wait for connection to be established
            case gun:await_up(Conn, 10000) of
                {ok, _Proto} ->
                    io:format("WebSocket upgrade successful~n"),
                    {noreply, State#state{conn=Conn, stream_ref=StreamRef}};
                {error, Reason} ->
                    io:format("WebSocket upgrade failed: ~p~n", [Reason]),
                    gun:close(Conn),
                    {noreply, State}
            end;
        {error, Reason} ->
            io:format("Unable to open connection: ~p~n", [Reason]),
            {noreply, State}
    end;

%% @doc Handle WebSocket upgrade confirmation
handle_info({gun_upgrade, _Conn, StreamRef, [<<"websocket">>], _Headers}, State) ->
    io:format("WebSocket upgrade confirmed by gun~n"),
    {noreply, State#state{stream_ref=StreamRef}};

%% @doc Handle incoming WebSocket messages from Discord Gateway
handle_info({gun_ws, _Conn, StreamRef, {text, Frame}}, State) ->
    try
        % Decode JSON message from Discord
        Decoded = jsone:decode(Frame),
        handle_gateway_message(Decoded, State#state{stream_ref=StreamRef})
    catch
        Class:Reason:Stacktrace ->
            io:format("Error decoding message: ~p:~p~p~n", [Class, Reason, Stacktrace]),
            {noreply, State#state{stream_ref=StreamRef}}
    end;

%% @doc Handle WebSocket connection drops
handle_info({gun_down, Conn, ws, _Reason, _, _}, State = #state{conn = Conn}) ->
    io:format("WebSocket disconnection detected~n"),
    maybe_cancel_heartbeat(State),
    self() ! reconnect,
    {noreply, State#state{conn = undefined, stream_ref = undefined, heartbeat_ref = undefined}};

%% @doc Handle reconnection attempts
handle_info(reconnect, State) ->
    io:format("Attempting reconnection...~n"),
    erlang:send_after(2000, self(), connect),
    {noreply, State};

%% @doc Handle heartbeat when no connection is active
handle_info(heartbeat, State = #state{conn = undefined}) ->
    io:format("No active connection for heartbeat~n"),
    {noreply, State};

%% @doc Send heartbeat to Discord to maintain connection
handle_info(heartbeat, State = #state{conn = Conn, stream_ref = StreamRef, seq = Seq}) ->
    Payload = #{op => 1, d => Seq},
    gun:ws_send(Conn, StreamRef, {text, jsone:encode(Payload)}),
    {noreply, State};

%% @doc Handle unexpected messages
handle_info(_Info, State) ->
    io:format("Unexpected message in handle_info: ~p~n", [_Info]),
    {noreply, State}.

%%%===================================================================
%%% Gateway Message Handling
%%%===================================================================

%% @doc Handle Discord Gateway HELLO message (opcode 10)
%% This initiates the heartbeat and identification process
handle_gateway_message(#{<<"op">> := 10, <<"d">> := #{<<"heartbeat_interval">> := Interval}},
                      State = #state{conn=Conn, stream_ref=StreamRef, token=Token}) ->
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
    {noreply, State};

%% @doc Handle any unrecognized Gateway messages
handle_gateway_message(Msg, State) ->
    io:format("Unhandled Gateway message: ~p~n", [Msg]),
    {noreply, State}.

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
            % Handler is a module name - call Module:handle_message/3
            try
                io:format("Calling handler: ~p:handle_message/3~n", [Handler]),
                Handler:handle_message(Content, ChannelId, Author)
            catch
                Class:Reason ->
                    io:format("Error in command handler ~p: ~p:~p~n", [Handler, Class, Reason])
            end;
        {Module, Function} ->
            % Handler is {Module, Function} tuple
            try
                io:format("Calling handler: ~p:~p/3~n", [Module, Function]),
                Module:Function(Content, ChannelId, Author)
            catch
                Class:Reason ->
                    io:format("Error in command handler ~p:~p: ~p:~p~n", [Module, Function, Class, Reason])
            end;
        Fun when is_function(Fun, 3) ->
            % Handler is a function with arity 3
            try
                io:format("Calling handler: function with arity 3~n"),
                Fun(Content, ChannelId, Author)
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
    io:format("DEBUG: Token in identify/3: ~p (type: ~p)~n", [Token, erlang:is_binary(Token)]),

    % Ensure token is binary
    BinToken = if
        is_binary(Token) -> Token;
        is_list(Token) -> list_to_binary(Token)
    end,

    % Build identification payload
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
    io:format("IDENTIFY payload: ~s~n", [jsone:encode(Payload)]),
    gun:ws_send(Conn, StreamRef, {text, jsone:encode(Payload)}).

%% Handle send_message and edit_message calls in handle_call
handle_call({send_message, ChannelId, Content}, _From, State = #state{token = Token}) ->
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
                                            {reply, {ok, MessageId}, State};
                                        _ ->
                                            {reply, {error, no_message_id}, State}
                                    end;
                                Error ->
                                    gun:close(Conn),
                                    {reply, Error, State}
                            end;
                        {response, _, Status, _} ->
                            gun:close(Conn),
                            {reply, {error, {status, Status}}, State};
                        {error, Reason} ->
                            gun:close(Conn),
                            {reply, {error, Reason}, State}
                    end;
                {error, Reason} ->
                    io:format("Error connecting to Discord API: ~p~n", [Reason]),
                    gun:close(Conn),
                    {reply, {error, connection_error}, State}
            end;
        {error, Reason} ->
            io:format("Error opening connection to Discord API: ~p~n", [Reason]),
            {reply, {error, connection_error}, State}
    end;

handle_call({edit_message, ChannelId, MessageId, Content}, _From, State = #state{token = Token}) ->
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
                                    {reply, {ok, Status, Body}, State};
                                Error ->
                                    gun:close(Conn),
                                    {reply, Error, State}
                            end;
                        {response, fin, Status, _Headers} ->
                            gun:close(Conn),
                            {reply, {ok, Status, <<>>}, State};
                        {error, Reason} ->
                            gun:close(Conn),
                            {reply, {error, Reason}, State}
                    end;
                {error, Reason} ->
                    io:format("Error connecting to Discord API: ~p~n", [Reason]),
                    gun:close(Conn),
                    {reply, {error, connection_error}, State}
            end;
        {error, Reason} ->
            io:format("Error opening connection to Discord API: ~p~n", [Reason]),
            {reply, {error, connection_error}, State}
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

