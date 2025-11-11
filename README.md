# HeitorMaciel's Multiplayer Solution
### Fork of [Voltseon’s Multiplayer Solution](https://eeveeexpo.com/resources/1453/) for Pokémon Essentials v21.1

Since the original plugin is no longer maintained, this fork aims to:
- Keep compatibility with current Essentials versions and plugins  
- Fix bugs and security issues  
- Implement modern gameplay features
- Improve ease of use for self-hosted servers (no Ruby installation required)

---

## Feature Progress

- [x] Z-Move Support (DBK Z-Power)
- [x] Dynamax Support (DBK Dynamax)
- [x] Terastal Support (DBK Terastallization)
- [ ] Following Pokémon Support
- [ ] Overworld Encounters Support
- [ ] Additional Battle Formats
- [ ] Server Security Improvements
- [ ] General Bug Fixes

> More features will be added as development continues.

---

## Installation and Setup

### 1. Downloading the plugin

Download the latest version of the plugin from the **[Releases](../../releases)** page.

### 2. Adding it to your project (client)

Extract the downloaded `.zip` file and move the following into your game project:

Client/ → [YourGame]/Plugins/

multiplayer.ini → [YourGame]/


Your final project structure should look like this:

YourGame/

├── Game.exe

├── Data/

├── Plugins/

│ ├── OtherPlugins/

│ └── Multiplayer/ # The client folder from this plugin

└── multiplayer.ini

#### 2.1 Client Connection configuration

The game reads connection settings from the `multiplayer.ini` file located in your game’s root folder.  
Edit it with any text editor to configure the connection

If this file is missing, the client defaults to `127.0.0.1:25565`.

## Server Setup

Pre-packaged server builds are included for both **Windows** and **Linux**, and include a standalone Ruby installation

### Folder Structure

Server/

├── ruby/ # standalone ruby installation for the server to run on

├── Server.rb

├── Config.rb

├── Player.rb

├── Cluster.rb

├── config.ini

├── start.bat # For Windows

└── start.sh # For Linux

### ⚙️ Configuration
The server reads settings from `config.ini`.  
You can edit it with any text editor:

1. ‘host’: This is the hostname or IP address of your server that is used for people
to connect to the server.
2. ‘port’: This is the port of the server. It is an identifier for your machine to let it
know that all incoming and outbound data through that port is for and from the
server. It is important that the port is open for public networks as otherwise you
wouldn’t be able to join from outside the server’s network.
3. ‘check_game_and_version’: Whether the server should check for players’ game
and version. This is useful to ensure players from different games or versions of
your game don’t try to connect to the server and crash other players.
4. ‘game_name’: The name of your game, the server will only accept players who
are trying to connect to the server from a game with this name. The name of
your game can be seen and changed in RPG Maker XP by clicking on ‘Game’ on
the top bar and clicking on ‘Change Title…’.
5. ‘game_version’: The version of your game, the server will only accept players
who are trying to connect to the server from a game with this version. You can
change the version of your game by going into your game’s scripts and changing
the ‘GAME_VERSION’ configuration under ‘001_Settings.rb’.
6. ‘max_players’: This is how many players are allowed onto one cluster. This does
not mean a total of allowed players connected to the server. If too many players
are connected to each other in the same cluster, it could cause lag for all players.
Setting it to 4, or anything below 8 is recommended.
7. ‘log’: Whether the server should log to the console. Setting this to ‘true’ means
you will receive logs about server events. Set this to ‘false’ to not receive any
logs.
8. ‘heartbeat_timeout’: How many seconds a player can be idle for before being
kicked. Idle means not receiving any data from this player. By default, this is set
to 5 seconds, but it is not recommended to set this too low or too high.
9. ‘use_tcp’: Whether the server uses TCP or UDP. These are protocols used to
transfer data. TCP is reliable but slow, while UDP is generally faster but less
reliable. By default, this is set to ‘false’ but for some games TCP would be
beneficial. Make sure when you change this to also change the plugin
configuration to use the same protocol
10. ‘threading’: Whether the server should use threading for each cluster. This will
make all clusters run asynchronously but will cost more memory. By default, this
is set to ‘true’.
11. ‘tick_rate’: This is how many times per second the server will send data. This
should be between 20-80. The higher the number, the more frequent the
updates are sent. Anything higher than 80 would be too much data/ overkill.
While anything under 20 is usually not enough data (depending on your type of
game). By default, this is set to 60 ticks per second.

When changing the configuration of the server make sure to restart your server.
Making changes to the config file can either crash the server or leave it on an
outdated version (depending on your sever hosting solution).

---

## Credits

All credit goes to **Voltseon** for the original plugin.  
This fork is **not intended to replace** the official plugin, it only exists because the original is no longer being updated.  
If an official update is released that adds these features, I strongly recommend using the official version instead.
