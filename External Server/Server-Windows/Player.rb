##############################################################################
# VMS Player
# ----------------------------------------------------------------------------
# This class is used to store information about a player.
# Make sure to update the same script in the server/plugin when making changes.
# ----------------------------------------------------------------------------
##############################################################################

module VMS
  # Mapping for integer-keyed serialization to reduce bandwidth
  # Stable follower-sync baseline only:
  #   follower_active
  #   follower_graphic
  #   follower_direction
  PACKET_KEYS = {
    id: 1,
    heartbeat: 2,
    name: 3,
    map_id: 4,
    x: 5,
    y: 6,
    real_x: 7,
    real_y: 8,
    trainer_type: 9,
    direction: 10,
    pattern: 11,
    graphic: 12,
    party: 13,
    animation: 14,
    offset_x: 15,
    offset_y: 16,
    opacity: 17,
    stop_animation: 18,
    rf_event: 19,
    jump_offset: 20,
    jumping_on_spot: 21,
    surfing: 22,
    diving: 23,
    surf_base_coords: 24,
    state: 25,
    busy: 26,
    cluster_id: 27,
    online_variables: 28,
    game_name: 29,
    game_version: 30,
    follower_active: 31,
    follower_graphic: 32,
    follower_direction: 33
  }

  REVERSE_KEYS = PACKET_KEYS.invert

  class Player
    attr_reader :id, :address, :port, :heartbeat
    attr_accessor :socket, :dirty, :name

    def initialize(id, address, port)
      @id = id
      @address = address
      @port = port
      @heartbeat = Time.now
      @dirty = true
      @name = ""
      @data = {}
    end

    def update(data)
      hb_key = PACKET_KEYS[:heartbeat]
      if data[hb_key]
        return if data[hb_key] < @heartbeat
        @heartbeat = data[hb_key]
      end

      data.each do |k, v|
        next if k == hb_key
        @data[k] = v
      end

      name_key = PACKET_KEYS[:name]
      @name = data[name_key] if data[name_key]
      @dirty = true
    end

    def to_hash(full = true)
      hash = {
        PACKET_KEYS[:id] => @id,
        PACKET_KEYS[:heartbeat] => @heartbeat
      }
      return hash unless full
      hash.merge!(@data)
      hash
    end
  end
end