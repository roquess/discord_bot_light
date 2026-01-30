# Discord Bot Light Client

A lightweight, modern Erlang library for building Discord bots using the Gateway and HTTP APIs.  
This library provides a simple, configurable client process that connects to Discord, listens for messages, and lets you define your own command handlers.

[![Hex.pm](https://img.shields.io/hexpm/v/discord_bot_light.svg)](https://hex.pm/packages/discord_bot_light)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/discord_bot_light)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

---

## Features

- **Lightweight**: Minimal dependencies, no heavy frameworks.
- **Flexible Command Handling**: Plug in your own module, function, or fun for command processing.
- **Modern Discord Gateway Support**: Connects via WebSocket, handles heartbeats, reconnection, and events.
- **Simple API**: Send and edit messages easily.

---

## Installation

Add the following to your `rebar.config` dependencies:

```erlang
{discord_bot_light, "2.0.0"}
```

Make sure you also depend on:
- gun (HTTP/WebSocket client)
- jsone (JSON library)
- certifi (CA certificates)
- public_key (comes with Erlang/OTP)

---

## Usage

### 1. Write a Command Handler Module

Create a module that exports `handle_message/3`:

```erlang
%%% example_bot_commands.erl
-module(example_bot_commands).
-export([handle_message/4]).

handle_message(<<"!hello">>, ChannelId, Author, Token) ->
    Username = maps:get(<<"username">>, Author, <<"Unknown">>),
    Response = <<"Hello, ", Username/binary, "!">>,
    discord_bot_light_client:send_message(ChannelId, Response, Token);

handle_message(<<"!ping">>, ChannelId, _Author, Token) ->
    discord_bot_light_client:send_message(ChannelId, <<"Pong!">>, Token);

handle_message(_, _, _, _) ->
    ok.
```

---

### 2. Start the Bot

You can start the bot from your application supervisor or shell:

```erlang
Token = <<"YOUR_DISCORD_BOT_TOKEN">>,
Handler = example_bot_commands,
{ok, Pid} = discord_bot_light_client:start_link(Token, [{command_handler, Handler}]).
```

---

### 3. Send Messages from Anywhere

You can send messages manually:

```erlang
discord_bot_light_client:send_message(<<"channel_id">>, <<"Hello, Discord!">>, <<"YOUR_TOKEN">>).
```

Or edit messages:

```erlang
discord_bot_light_client:edit_message(<<"channel_id">>, <<"message_id">>, <<"New content!">>, <<"YOUR_TOKEN">>).
```

---

## Command Handler Interface

Your handler should export:

```erlang
handle_message(Content, ChannelId, Author) -> ok | {error, Reason}.
```

- **Content**: binary, message text
- **ChannelId**: binary, Discord channel ID
- **Author**: map, info about the author (id, username, etc.)

---

## Notes

- **Do not respond to your own bot's messages**; the client ignores them by default.
- **Intents**: The client enables MESSAGE_CONTENT and GUILD_MESSAGES intents.
- **TLS**: Uses secure TLS options with hostname verification.
- **Reconnect**: Handles automatic reconnection if the connection drops.

---

## License

Licensed under the Apache License, Version 2.0. See the LICENSE file for details.

---

## Credits

- Inspired by the simplicity of the Discord API.

---

**Happy hacking!**

For questions or improvements, open an issue or PR on the repository.
