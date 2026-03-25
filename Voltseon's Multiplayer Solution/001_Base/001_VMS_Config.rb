module VMS
  # ===========
  # Debug
  # ===========

  # If true, the menu will show "Local Play" and "Online Play" options.
  # If false, only integrated server (local play) options will be available.
  USE_EXTERNAL_SERVER = true

  # External server connection settings (used when "Online Play" is selected)
  EXTERNALHOST = "gamingwithgoose.ddns.net"
  EXTERNALPORT = 25889

  # Default port for hosting, integrated server is always hosted on 0.0.0.0:PORT.
  PORT = 25565

  # The current target IP for connecting. Can be changed at runtime.
  class << self
    attr_accessor :target_host
  end

  # Whether or not to log messages to the console.
  LOG_TO_CONSOLE = true
  # Whether or not to show yourself from the server's perspective. This is useful for testing.
  SHOW_SELF = false

  # ===========
  # Server
  # ===========
  # Whether or not to use TCP instead of UDP. TCP is more reliable, but UDP is faster.
  USE_TCP = false
  # The maximum number of players allowed in the integrated server.
  MAX_PLAYERS = 4
  
  # ===========
  # Connection
  # ===========
  # How many times per second to send packets. (can't be higher than the server's tick rate) (set to 0 to disable)
  TICK_RATE = 30
  # Whether or not to handle more packets. If this is set to false you will only receive the latest packet, being faster but more snappy.
  HANDLE_MORE_PACKETS = true
  # This is the delay where packet recency bias will be offset. Meaning if HANDLE_MORE_PACKETS is false, you will receive the latest packet that was sent within this delay. (in seconds)
  ADDED_DELAY = 0.09
  # The timeout in seconds. If the server does not respond within this time, the client will disconnect.
  TIMEOUT_SECONDS = 30
  # Whether or not to sync the seed with the server. This means that all players will have the same random numbers.
  HEARTBEAT_TIMEOUT = 30
  SEED_SYNC = false
  
  # ===========
  # Events
  # ===========
  # Whether other players can be walked through.
  THROUGH = false
  # What happens when interacting with another player. (set to 'proc { }' to disable) (yields: player_id #<Integer>, player #<VMS::Player>, event #<Game_Event>)
  INTERACTION_PROC = proc { |player_id, player, event| VMS.interact_with_player(player_id) }
  # How long to wait for another player to check for interactions. (in seconds) (set to 0 to instead wait until confirmed or denied)
  INTERACTION_WAIT = 30
  # IDs of animations that should be synced. (set to [] to sync all animations, set to [0] to sync no animations)
  SYNC_ANIMATIONS = [2, 3, 4]
  # How far away a player can be from the player before it is considered out of range. (in tiles) (out of range players will not be visible)
  CULL_DISTANCE = 10
  # Whether or not players their movement should be smoothed. This will make positions less accurate, but will make movement look smoother.
  SMOOTH_MOVEMENT = true
  # How accurate the movement should be. (closer to 0 means smoother, closer to 1 means more accurate) (only used if SMOOTH_MOVEMENT is true)
  SMOOTH_MOVEMENT_ACCURACY = 0.5
  # How far away a player has to move before they are teleported to the server's position. (in pixels) (only used if SMOOTH_MOVEMENT is true)
  SNAP_DISTANCE = 192

  # ===========
  # Menu
  # ===========
  # Whether or not VMS is accessible from the pause menu.
  ACCESSIBLE_FROM_PAUSE_MENU = true
  # Whether or not VMS is accessible. (set to 'proc { next true }' to always be accessible) (only used if ACCESSIBLE_FROM_PAUSE_MENU is true)
  ACCESSIBLE_PROC = proc { next true }
  # The name of the VMS option in the pause menu. (only used if ACCESSIBLE_FROM_PAUSE_MENU is true)
  MENU_NAME = "Link Play"
  # Whether or not to show the cluster ID in the pause menu.
  SHOW_CLUSTER_ID_IN_PAUSE_MENU = true
  
  # ===========
  # Other
  # ===========
  # Whether or not to show the ping in the window title.
  SHOW_PING = true
  # Whether or not to show other players on the region map.
  SHOW_PLAYERS_ON_REGION_MAP = true
  # Default values for encryption.
  ENCRYPTION_DEFAULTS = {
    "Pokemon" => [:BULBASAUR, 5],
    "Pokemon::Owner" => [0, "", 0, 0],
    "Pokemon::Move" => [:TACKLE],
    "Battle::Move" => [:TACKLE]
  }
  
  # ===========
  # Multi Battle
  # ===========
  # Maximum seconds to wait in a lobby for all 4 players to join before auto-cancelling.
  MB_LOBBY_TIMEOUT = 120
  # Maximum seconds to wait for all players to ready up once 4 slots are filled.
  MB_READY_TIMEOUT = 60
  # The name of the Multi Battle option in the pause menu.
  MB_MENU_NAME = "Multi Battle"

  # ===========
  # Methods
  # ===========
  # Mapping for integer-keyed serialization to reduce bandwidth
  PACKET_KEYS = {
    id: 1, heartbeat: 2, name: 3, map_id: 4, x: 5, y: 6, real_x: 7, real_y: 8,
    trainer_type: 9, direction: 10, pattern: 11, graphic: 12, party: 13,
    animation: 14, offset_x: 15, offset_y: 16, opacity: 17, stop_animation: 18,
    rf_event: 19, jump_offset: 20, jumping_on_spot: 21, surfing: 22, diving: 23,
    surf_base_coords: 24, state: 25, busy: 26, cluster_id: 27,
    online_variables: 28, game_name: 29, game_version: 30,
	follower_active: 31, follower_graphic: 32, follower_direction: 33
  }
  REVERSE_KEYS = PACKET_KEYS.invert

  # Usage: VMS.log("message", true) (logs a message to the console, with optional warning flag)
  def self.log(message="", warning=false)
    return unless LOG_TO_CONSOLE
    echoln Console.markup_style("VMS: " + message, text: warning ? :red : :blue)
  end
  # Usage: VMS.message("message", ["choice 1", "choice 2", "choice 3"], 0) (displays a message, with optional choices and default choice)
  def self.message(message="", choices=nil, default_choice=0)
    return if message.empty?
    return unless VMS::SHOW_PLAYER_MESSAGES
    return pbMessage(message, choices, default_choice)
  end
end