module VMS
  # ====================
  # Online variables
  # ====================

  # Usage: VMS.get_variable(id #<Integer>) (returns the value of the specified variable)
  def self.get_variable(id)
    return nil if !VMS.is_connected? || VMS.get_self.nil?
    return $game_temp.vms[:online_variables][id]
  end

  # Usage: VMS.set_variable(id #<Integer>, value #<Object>) (sets the value of the specified variable)
  def self.set_variable(id, value)
    return if !VMS.is_connected? || VMS.get_self.nil?
    $game_temp.vms[:online_variables][id] = value
  end

  # ====================
  # Methodical functions
  # ====================

  # Usage: VMS.ping (returns the ping of the player in seconds)
  def self.ping
    return -1 if !VMS.is_connected? || VMS.get_self.nil?
    return Time.now - $game_temp.vms[:ping_stamp]
  end

  # Usage: VMS.sync_seed (syncs the seed with the server)
  def self.sync_seed
    if VMS.is_connected?
      seed = "#{VMS.get_cluster_id}"
      players = VMS.get_players.sort_by { |player| player.id }
      players.each { |player| seed << player.id.to_s; seed << player.name }
      srand(VMS.string_to_integer(seed))
    else
      srand
    end
  end

  # Usage: VMS.see_party(id #<Integer>) (opens the party screen of the player with the specified ID
  def self.see_party(id)
    return if !VMS.is_connected?
    player = VMS.get_player(id)
    return if player.nil?
    party = VMS.update_party(player)
    return if party.nil? || party.empty?
    pbFadeOutIn do
      sscene = PokemonParty_Scene.new
      sscreen = PokemonPartyScreen.new(sscene, party)
      sscreen.pbPokemonScreen
    end
  end

  # Usage: VMS.teleport_to(id #<Integer>) (teleports the player to the player with the specified ID)
  def self.teleport_to(id)
    return if !VMS.is_connected?
    player = VMS.get_player(id)
    return if player.nil?
    pbCancelVehicles
    Followers.clear
    $game_temp.player_new_map_id = player.map_id
    $game_temp.player_new_x = player.x
    $game_temp.player_new_y = player.y
    $game_temp.player_new_direction = player.direction
    pbDismountBike
    $scene.transfer_player if $scene.is_a?(Scene_Map)
    $game_map.refresh
  end

  # ====================
  # State functions
  # ====================

  # Usages: VMS.is_connected? (returns true if the player is connected to the server)
  def self.is_connected?
    return !$game_temp.nil? && !$game_temp.vms[:socket].nil? && $game_temp.vms[:cluster] != -1
  end

  # Usage: VMS.get_self (returns the player object of the current player)
  def self.get_self
    return VMS.get_player($player.id)
  end

  # Usage: VMS.get_player(id #<Integer>) (returns the player object of the player with the specified ID)
  def self.get_player(id)
    return nil if !VMS.is_connected?
    return $game_temp.vms[:players][id]
  end

  # Usage: VMS.get_players (returns an array of all the player objects connected to the server)
  def self.get_players
    return [] if !VMS.is_connected?
    return $game_temp.vms[:players].values
  end

  # Usage: VMS.get_player_count (returns the number of players connected to the server)
  def self.get_player_count
    return 0 if !VMS.is_connected?
    return $game_temp.vms[:players].length
  end

  # Usage: VMS.get_cluster_id (returns the ID of the cluster the player is connected to)
  def self.get_cluster_id
    return $game_temp.vms[:cluster]
  end

  # ====================
  # Technical functions
  # ====================

  # Usage: VMS.interaction_possible? (returns true if the player is not busy)
  def self.interaction_possible?
    return !pbMapInterpreterRunning? && !$game_temp.in_menu && !$game_temp.in_battle && !$game_temp.message_window_showing && !$PokemonGlobal.fishing
  end

  # Usage: VMS.get_interaction_time (returns the number of frames to wait for another player to check for interactions)
  def self.get_interaction_time
    return VMS::INTERACTION_WAIT > 0 ? (VMS::INTERACTION_WAIT / Graphics.delta).ceil : 4611686018427387903
  end

  # Usage: VMS.hash_pokemon(pokemon #<::Pokemon>) (returns a hash of the specified Pokémon)
  def self.hash_pokemon(pokemon)
    hash = VMS.encrypt(pokemon)
    return "#{hash}"
  end

  # Usage: VMS.dehash_pokemon(hash #<Hash>) (returns a Pokémon from the specified hash)
  def self.dehash_pokemon(hash)
    pokemon = VMS.decrypt(eval(hash))
    pokemon.calc_stats
    return pokemon
  end

  # Usage: VMS.clean_up_basic_array(array #<Array>) (removes all non-basic types from the specified array)
  def self.clean_up_basic_array(array)
    if array.is_a?(Array)
      array.each_with_index do |a, i|
        if a.is_a?(Array)
          array[i] = VMS.clean_up_basic_array(a)
        else
          array[i] = nil unless VMS.basic_type?(a)
        end
      end
    else
      array = nil unless VMS.basic_type?(array)
    end
    return array
  end

  # Usage: VMS.scene_update (updates the scene)
  def self.scene_update(update_vms = true)
    Graphics.update(update_vms)
    Input.update
    $scene.miniupdate
  end

  # Usage: VMS.event_deletion_possible?(player #<VMS::Player>) (returns true if the player's event can be deleted)
  def self.event_deletion_possible?(player)
    return false if player.rf_event.nil?
    return false unless $map_factory.areConnected?(player.map_id, $game_map.map_id) && $scene.is_a?(Scene_Map)
    return false if $scene.spriteset(player.rf_event[:map_id]).nil?
    return false unless $scene.is_a?(Scene_Map)
    return true
  end

  # Usage: VMS.get_cluster_list (requests and returns a list of available clusters from the server)
  def self.get_cluster_list
    begin
      # Determine connection parameters based on runtime server type
      host = $game_temp.vms[:using_external_server] ? VMS::EXTERNALHOST : VMS.target_host
      port = $game_temp.vms[:using_external_server] ? VMS::EXTERNALPORT : VMS::PORT
      # Create temporary socket
      if VMS::USE_TCP
        socket = TCPSocket.new(host, port)
      else
        socket = UDPSocket.new
        socket.connect(host, port)
      end
      
      # Send list request
      message = Zlib::Deflate.deflate(Marshal.dump(["list_clusters"]), Zlib::BEST_SPEED)
      socket.send(message, 0)
      
      # Wait for response (with timeout)
      timeout = 3.0 # 3 seconds timeout
      start_time = Time.now
      cluster_list = nil
      
      loop do
        data = socket.read_nonblock(65536, exception: false)
        
        if data != :wait_readable && data != :wait_writable && !data.nil?
          data = Marshal.load(Zlib::Inflate.inflate(data))
          if data.is_a?(Array) && data[0] == :cluster_list
            cluster_list = data[1]
            break
          end
        end
        
        # Timeout check
        if Time.now - start_time > timeout
          VMS.log("Cluster list request timed out", true)
          break
        end
        
        sleep(0.01) # Small delay to prevent busy waiting
      end
      
      socket.close
      return cluster_list || []
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET
      VMS.log("Server is not active", true)
      return []
    rescue => e
      VMS.log("Failed to get cluster list: #{e.message}", true)
      return []
    end
  end
end