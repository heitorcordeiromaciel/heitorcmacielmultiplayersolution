##############################################################################
# VMS Multibattle Handler
# ----------------------------------------------------------------------------
# Implements 4-player 2v2 multibattles.
# Two teams of two players each select 3 Pokémon. Each player controls
# exactly one battler in a standard double battle.
#
# Battle layout (local indices — same for all clients):
#   Battler 0 = self (always)
#   Battler 2 = ally
#   Battler 1 = opponent A
#   Battler 3 = opponent B
#
# Global battler index canonical mapping:
#   [team=0, slot=0] → global 0
#   [team=0, slot=1] → global 2
#   [team=1, slot=0] → global 1
#   [team=1, slot=1] → global 3
#
# ALL multibattle state values have this fixed layout:
#   state[0] = state symbol
#   state[1] = lobby_id
#   state[2] = team_idx  (0 or 1)
#   state[3] = slot_idx  (0 or 1)
#   state[4..] = state-specific payload
#
# State values:
#   [:multibattle_lobby,     lobby_id, team, slot]
#   [:multibattle_ready,     lobby_id, team, slot]
#   [:multibattle_selection, lobby_id, team, slot, party_or_nil]
#   [:multibattle_command,   lobby_id, team, slot, turn_count, pick, mega, z, dyna, tera]
#   [:multibattle_switch,    lobby_id, team, slot, global_battler_idx, new_party_index]
##############################################################################

module VMS
  # -------------------------------------------------------------------------
  # Fixed canonical mappings (never change at runtime)
  # -------------------------------------------------------------------------
  GLOBAL_BATTLER_OWNER = { [0,0]=>0, [0,1]=>2, [1,0]=>1, [1,1]=>3 }
  SLOT_FOR_GLOBAL      = GLOBAL_BATTLER_OWNER.invert   # {0=>[0,0], 2=>[0,1], 1=>[1,0], 3=>[1,1]}

  # Local-to-global battler index map keyed by [team, slot].
  # Each player sets up the battle with themselves at local index 0.
  MB_INDEX_MAPS = {
    [0,0] => { 0=>0, 1=>1, 2=>2, 3=>3 },
    [0,1] => { 0=>2, 1=>1, 2=>0, 3=>3 },
    [1,0] => { 0=>1, 1=>0, 2=>3, 3=>2 },
    [1,1] => { 0=>3, 1=>0, 2=>1, 3=>2 }
  }

  MB_SLOT_LABELS = {
    [0,0] => "Team 0 (Slot A)",
    [0,1] => "Team 0 (Slot B)",
    [1,0] => "Team 1 (Slot A)",
    [1,1] => "Team 1 (Slot B)"
  }

  # -------------------------------------------------------------------------
  # State helpers
  # -------------------------------------------------------------------------

  # Returns true when the local player is currently in any multibattle state.
  def self.multibattle_active?
    return false if $game_temp.nil? || $game_temp.vms.nil?
    st = $game_temp.vms[:state]
    return st.is_a?(Array) && st[0].to_s.start_with?("multibattle")
  end

  # Returns the VMS::Player in the cluster whose state has the given
  # team_idx (state[2]) and slot_idx (state[3]) in any multibattle state.
  def self.mb_get_player_for_global_battler(global_idx)
    target_team, target_slot = VMS::SLOT_FOR_GLOBAL[global_idx]
    return nil if target_team.nil?
    VMS.get_players.each do |player|
      st = player.state
      next unless st.is_a?(Array) && st.length >= 4
      next unless st[0].to_s.start_with?("multibattle")
      return player if st[2] == target_team && st[3] == target_slot
    end
    return nil
  end

  # Returns the VMS::Player in the lobby slot [team_idx, slot_idx].
  def self.mb_get_player_for_slot(lobby_id, team_idx, slot_idx)
    VMS.get_players.each do |player|
      st = player.state
      next unless st.is_a?(Array) && st.length >= 4
      next unless st[0].to_s.start_with?("multibattle")
      next unless st[1] == lobby_id
      return player if st[2] == team_idx && st[3] == slot_idx
    end
    return nil
  end

  # Converts a local battler target index to the global index.
  def self.mb_local_to_global_target(local_target)
    return nil unless local_target.is_a?(Integer) && local_target >= 0
    l2g = $game_temp.vms[:mb_local_to_global]
    return l2g[local_target] || local_target
  end

  # Resets all multibattle-specific keys in the vms hash.
  def self.mb_clear_local_state
    $game_temp.vms[:mb_lobby_id]           = nil
    $game_temp.vms[:mb_team_idx]           = nil
    $game_temp.vms[:mb_slot_idx]           = nil
    $game_temp.vms[:mb_local_battler_idx]  = nil
    $game_temp.vms[:mb_local_to_global]    = {}
    $game_temp.vms[:mb_global_to_local]    = {}
  end

  # -------------------------------------------------------------------------
  # Lobby discovery
  # -------------------------------------------------------------------------

  # Scans all visible players for active multibattle lobby states.
  # Returns array of lobby descriptor hashes:
  #   { lobby_id:, slots: {[team,slot]=>{player_id:,player_name:,ready:} or nil},
  #     full:, all_ready: }
  def self.get_multibattle_lobbies
    lobby_map = {}
    VMS.get_players.each do |player|
      st = player.state
      next unless st.is_a?(Array) && st.length >= 4
      next unless [:multibattle_lobby, :multibattle_ready].include?(st[0])
      lid  = st[1]
      team = st[2]
      slot = st[3]
      next if lid.nil? || team.nil? || slot.nil?
      lobby_map[lid] ||= {
        lobby_id: lid,
        slots: { [0,0]=>nil, [0,1]=>nil, [1,0]=>nil, [1,1]=>nil }
      }
      lobby_map[lid][:slots][[team, slot]] = {
        player_id:   player.id,
        player_name: player.name,
        ready:       st[0] == :multibattle_ready
      }
    end
    lobby_map.each_value do |lobby|
      lobby[:full]      = lobby[:slots].values.none?(&:nil?)
      lobby[:all_ready] = lobby[:full] && lobby[:slots].values.all? { |s| s[:ready] }
    end
    return lobby_map.values
  end

  # -------------------------------------------------------------------------
  # Slot conflict resolution
  # -------------------------------------------------------------------------

  # If another player with a lower ID claims the same [team, slot], yield the
  # slot to them and auto-reassign to a free one.
  def self.mb_resolve_slot_conflict
    my_team  = $game_temp.vms[:mb_team_idx]
    my_slot  = $game_temp.vms[:mb_slot_idx]
    lobby_id = $game_temp.vms[:mb_lobby_id]
    return if my_team.nil? || my_slot.nil? || lobby_id.nil?
    VMS.get_players.each do |player|
      next if player.id == $player.id
      st = player.state
      next unless st.is_a?(Array) && st.length >= 4
      next unless [:multibattle_lobby, :multibattle_ready].include?(st[0])
      next unless st[1] == lobby_id && st[2] == my_team && st[3] == my_slot
      # They have the same slot — lower ID wins
      if player.id < $player.id
        VMS.mb_auto_reassign_slot(lobby_id, my_team)
        return
      end
    end
  end

  # Find a free slot and claim it.
  def self.mb_auto_reassign_slot(lobby_id, preferred_team)
    taken = []
    VMS.get_players.each do |player|
      next if player.id == $player.id
      st = player.state
      next unless st.is_a?(Array) && st.length >= 4
      next unless [:multibattle_lobby, :multibattle_ready].include?(st[0])
      next unless st[1] == lobby_id
      taken << [st[2], st[3]]
    end
    other_slot = 1 - $game_temp.vms[:mb_slot_idx].to_i
    other_team = 1 - preferred_team
    candidate_order = [
      [preferred_team, other_slot],
      [other_team, 0],
      [other_team, 1]
    ]
    new_key = candidate_order.find { |pair| !taken.include?(pair) }
    if new_key.nil?
      VMS.message(VMS::MB_LOBBY_FULL_MESSAGE)
      $game_temp.vms[:state] = [:idle, nil]
      VMS.mb_clear_local_state
      return
    end
    new_team, new_slot = new_key
    $game_temp.vms[:mb_team_idx] = new_team
    $game_temp.vms[:mb_slot_idx] = new_slot
    $game_temp.vms[:state] = [:multibattle_lobby, lobby_id, new_team, new_slot]
    label = VMS::MB_SLOT_LABELS[[new_team, new_slot]] || "Team #{new_team} Slot #{new_slot}"
    VMS.log("MB: Slot conflict resolved, moved to #{label}")
  end

  # -------------------------------------------------------------------------
  # Lobby UI
  # -------------------------------------------------------------------------

  # Entry point called from the pause menu.
  def self.open_multibattle_menu
    unless VMS.is_connected?
      VMS.message(VMS::MB_NOT_CONNECTED_MESSAGE)
      return
    end
    lobbies = VMS.get_multibattle_lobbies
    if lobbies.empty?
      if pbConfirmMessage(VMS::MB_NO_LOBBIES_MESSAGE)
        VMS.create_multibattle_lobby
      end
      return
    end
    choices = lobbies.map do |lb|
      filled = lb[:slots].values.count { |s| !s.nil? }
      "Lobby #{lb[:lobby_id]} (#{filled}/4)"
    end
    choices << VMS::MB_CREATE_LOBBY_OPTION << _INTL("Cancel")
    choice = VMS.message(VMS::MB_MENU_TITLE, choices)
    return if choice.nil? || choice == choices.length - 1
    if choice < lobbies.length
      VMS.join_multibattle_lobby(lobbies[choice])
    else
      VMS.create_multibattle_lobby
    end
  end

  # Create a new lobby. The creator picks their team and always takes slot 0.
  def self.create_multibattle_lobby
    lobby_id = rand(10000...99999)
    team_choices = [VMS::MB_TEAM_0_SLOT_0, VMS::MB_TEAM_1_SLOT_0, _INTL("Cancel")]
    choice = VMS.message(VMS::MB_SELECT_TEAM_MESSAGE, team_choices)
    return if choice.nil? || choice == 2
    team_idx = choice   # 0 → Team 0, 1 → Team 1
    slot_idx = 0
    $game_temp.vms[:mb_lobby_id] = lobby_id
    $game_temp.vms[:mb_team_idx] = team_idx
    $game_temp.vms[:mb_slot_idx] = slot_idx
    $game_temp.vms[:state] = [:multibattle_lobby, lobby_id, team_idx, slot_idx]
    VMS.log("MB: Created lobby #{lobby_id} on team #{team_idx}, slot 0")
    VMS.mb_lobby_wait_loop(lobby_id)
  end

  # Join an existing lobby. Shows open slots for the player to choose from.
  def self.join_multibattle_lobby(lobby_data)
    lobby_id = lobby_data[:lobby_id]
    if lobby_data[:full]
      VMS.message(VMS::MB_LOBBY_FULL_MESSAGE)
      return
    end
    open_slots = [[0,0],[0,1],[1,0],[1,1]].select { |pair| lobby_data[:slots][pair].nil? }
    slot_choices = open_slots.map { |t,s| VMS::MB_SLOT_LABELS[[t,s]] || "Team #{t} Slot #{s}" }
    slot_choices << _INTL("Cancel")
    choice = VMS.message(VMS::MB_SELECT_TEAM_MESSAGE, slot_choices)
    return if choice.nil? || choice == open_slots.length
    team_idx, slot_idx = open_slots[choice]
    $game_temp.vms[:mb_lobby_id] = lobby_id
    $game_temp.vms[:mb_team_idx] = team_idx
    $game_temp.vms[:mb_slot_idx] = slot_idx
    $game_temp.vms[:state] = [:multibattle_lobby, lobby_id, team_idx, slot_idx]
    VMS.log("MB: Joined lobby #{lobby_id} on team #{team_idx}, slot #{slot_idx}")
    VMS.mb_lobby_wait_loop(lobby_id)
  end

  # Polling loop shown while waiting for all 4 lobby slots to fill.
  def self.mb_lobby_wait_loop(lobby_id)
    start_time = Time.now
    msgwindow  = pbCreateMessageWindow
    msgwindow.letterbyletter = false
    loop do
      VMS.scene_update
      VMS.mb_resolve_slot_conflict
      lobby = VMS.get_multibattle_lobbies.find { |lb| lb[:lobby_id] == lobby_id }
      # Build live display
      lines = ["Multi Battle Lobby #{lobby_id}"]
      [[0,0],[0,1],[1,0],[1,1]].each do |pair|
        entry      = lobby&.dig(:slots, pair)
        slot_label = VMS::MB_SLOT_LABELS[pair] || "Team #{pair[0]} Slot #{pair[1]}"
        if entry
          ready_str = entry[:ready] ? " (Ready)" : ""
          name = (entry[:player_id] == $player.id) ? "#{entry[:player_name]} (You)" : entry[:player_name]
          lines << "#{slot_label}: #{name}#{ready_str}"
        else
          lines << "#{slot_label}: <empty>"
        end
      end
      lines << "" << "Press BACK to leave"
      msgwindow.setText(lines.join("\n"))
      msgwindow.update
      # Cancel
      if Input.trigger?(Input::BACK)
        pbDisposeMessageWindow(msgwindow)
        $game_temp.vms[:state] = [:idle, nil]
        VMS.mb_clear_local_state
        return
      end
      # Timeout
      if Time.now - start_time > VMS::MB_LOBBY_TIMEOUT
        pbDisposeMessageWindow(msgwindow)
        VMS.message(VMS::MB_LOBBY_TIMEOUT_MESSAGE)
        $game_temp.vms[:state] = [:idle, nil]
        VMS.mb_clear_local_state
        return
      end
      # Lobby vanished
      if lobby.nil? && (Time.now - start_time) > 5
        pbDisposeMessageWindow(msgwindow)
        VMS.message(VMS::MB_LOBBY_TIMEOUT_MESSAGE)
        $game_temp.vms[:state] = [:idle, nil]
        VMS.mb_clear_local_state
        return
      end
      break if lobby&.[](:full)
    end
    pbDisposeMessageWindow(msgwindow)
    VMS.mb_ready_phase(lobby_id)
  end

  # Ready-up phase: player confirms readiness, then waits for all 4 to be ready.
  def self.mb_ready_phase(lobby_id)
    ready = pbConfirmMessage(VMS::MB_READY_CONFIRM_MESSAGE)
    unless ready
      $game_temp.vms[:state] = [:idle, nil]
      VMS.mb_clear_local_state
      return
    end
    team_idx = $game_temp.vms[:mb_team_idx]
    slot_idx = $game_temp.vms[:mb_slot_idx]
    $game_temp.vms[:state] = [:multibattle_ready, lobby_id, team_idx, slot_idx]
    start_time = Time.now
    msgwindow  = pbCreateMessageWindow
    msgwindow.letterbyletter = false
    msgwindow.setText(VMS::MB_READY_WAIT_MESSAGE)
    loop do
      VMS.scene_update
      msgwindow.update
      lobby = VMS.get_multibattle_lobbies.find { |lb| lb[:lobby_id] == lobby_id }
      if Time.now - start_time > VMS::MB_READY_TIMEOUT || lobby.nil?
        pbDisposeMessageWindow(msgwindow)
        VMS.message(VMS::MB_LOBBY_TIMEOUT_MESSAGE)
        $game_temp.vms[:state] = [:idle, nil]
        VMS.mb_clear_local_state
        return
      end
      break if lobby[:all_ready]
    end
    pbDisposeMessageWindow(msgwindow)
    lobby = VMS.get_multibattle_lobbies.find { |lb| lb[:lobby_id] == lobby_id }
    VMS.start_multibattle(lobby)
  end

  # -------------------------------------------------------------------------
  # Battle setup
  # -------------------------------------------------------------------------

  # Main entry point once all 4 players are ready. Every client runs this.
  def self.start_multibattle(lobby_data)
    old_party = nil
    begin
      lobby_id = lobby_data[:lobby_id]
      my_team  = $game_temp.vms[:mb_team_idx]
      my_slot  = $game_temp.vms[:mb_slot_idx]

      # Compute index maps
      l2g = VMS::MB_INDEX_MAPS[[my_team, my_slot]]
      g2l = l2g.invert
      $game_temp.vms[:mb_local_battler_idx] = 0
      $game_temp.vms[:mb_local_to_global]   = l2g
      $game_temp.vms[:mb_global_to_local]   = g2l

      # Check able Pokémon
      if $player.able_pokemon_count < 1
        VMS.message(VMS::MB_NO_ELIGIBLE_POKEMON)
        $game_temp.vms[:state] = [:idle, nil]
        VMS.mb_clear_local_state
        return
      end

      # Party selection (exactly 3 Pokémon)
      new_party = nil
      $game_temp.vms[:state] = [:multibattle_selection, lobby_id, my_team, my_slot, nil]
      ruleset = PokemonRuleSet.new
      ruleset.setNumber(3)
      ruleset.addPokemonRule(AblePokemonRestriction.new)
      pbFadeOutIn do
        scene  = PokemonParty_Scene.new
        screen = PokemonPartyScreen.new(scene, $player.party)
        new_party = screen.pbPokemonMultipleEntryScreenEx(ruleset)
      end
      unless new_party
        $game_temp.vms[:state] = [:idle, nil]
        VMS.mb_clear_local_state
        return
      end
      $game_temp.vms[:state] = [:multibattle_selection, lobby_id, my_team, my_slot, new_party]

      # Wait for all 4 selections
      unless VMS.mb_await_all_selections(lobby_id)
        $game_temp.vms[:state] = [:idle, nil]
        VMS.mb_clear_local_state
        return
      end

      # Collect parties keyed by global battler index
      parties_by_global = VMS.mb_collect_all_parties(lobby_data, lobby_id)
      unless parties_by_global
        VMS.message(VMS::BASIC_ERROR_MESSAGE)
        $game_temp.vms[:state] = [:idle, nil]
        VMS.mb_clear_local_state
        return
      end

      # Generate deterministic seed identical on all 4 clients
      seed = VMS.mb_generate_seed(lobby_id, parties_by_global)
      $game_temp.vms[:seed] = seed
      srand(seed)

      # Resolve global battler indices for ally and both enemies
      ally_global    = l2g[2]
      enemy_a_global = l2g[1]
      enemy_b_global = l2g[3]

      ally_player    = VMS.mb_get_player_for_global_battler(ally_global)
      enemy_a_player = VMS.mb_get_player_for_global_battler(enemy_a_global)
      enemy_b_player = VMS.mb_get_player_for_global_battler(enemy_b_global)

      # Two separate foe NPCTrainers — one per enemy player
      enemy_a_trainer       = NPCTrainer.new(enemy_a_player&.name || "???", enemy_a_player&.trainer_type || :POKEMONTRAINER_Red, 0)
      enemy_a_trainer.party = parties_by_global[enemy_a_global] || []
      enemy_b_trainer       = NPCTrainer.new(enemy_b_player&.name || "???", enemy_b_player&.trainer_type || :POKEMONTRAINER_Red, 0)
      enemy_b_trainer.party = parties_by_global[enemy_b_global] || []

      # Set partner data directly — bypasses pbRegisterPartner, which tries to load
      # the trainer from the database (fails for VMS player names).
      # Format expected by Deluxe Battle Kit: [tr_type, tr_name, tr_id, party, items]
      ally_type = ally_player&.trainer_type || :POKEMONTRAINER_Red
      begin; ally_type = GameData::TrainerType.get(ally_type).id; rescue; end
      $PokemonGlobal.partner = [ally_type, ally_player&.name || "???", 0, parties_by_global[ally_global] || [], []]

      # Temporarily replace local party with selected 3 Pokémon
      old_party = $player.party
      $player.party = new_party

      VMS.log("MB: Starting battle. lobby=#{lobby_id} team=#{my_team} slot=#{my_slot}")
      $game_temp.vms[:mb_in_battle] = true
      TrainerBattle.start_core_VMS_multibattle(enemy_a_trainer, enemy_b_trainer)
    rescue StandardError => e
      VMS.log("MB: Error during multibattle: #{e.message}", true)
      VMS.message(VMS::BASIC_ERROR_MESSAGE)
    ensure
      $game_temp.vms[:mb_in_battle] = false
      pbDeregisterPartner
      $player.party = old_party if old_party
      $player.party.each { |pkmn| pkmn.heal if pkmn }
      $game_temp.vms[:state] = [:idle, nil]
      VMS.mb_clear_local_state
      VMS.sync_seed
    end
  end

  # Wait until all 4 players have a non-nil party in :multibattle_selection.
  # state[4] is the party (may be nil while selecting, non-nil when done).
  def self.mb_await_all_selections(lobby_id)
    start_time = Time.now
    msgwindow  = pbCreateMessageWindow
    msgwindow.letterbyletter = false
    msgwindow.setText(VMS::MB_SELECTION_WAIT_MESSAGE)
    loop do
      VMS.scene_update
      msgwindow.update
      if Time.now - start_time > VMS::MB_READY_TIMEOUT
        pbDisposeMessageWindow(msgwindow)
        VMS.message(VMS::MB_LOBBY_TIMEOUT_MESSAGE)
        return false
      end
      ready_count = 0
      [[0,0],[0,1],[1,0],[1,1]].each do |pair|
        player = VMS.mb_get_player_for_slot(lobby_id, pair[0], pair[1])
        next if player.nil?
        st = player.state
        if st.is_a?(Array) && st[0] == :multibattle_selection && !st[4].nil?
          ready_count += 1
        end
      end
      break if ready_count == 4
    end
    pbDisposeMessageWindow(msgwindow)
    return true
  end

  # Collect all 4 parties keyed by global battler index.
  # Returns nil if any party cannot be retrieved.
  def self.mb_collect_all_parties(lobby_data, lobby_id)
    parties = {}
    [[0,0],[0,1],[1,0],[1,1]].each do |pair|
      global_idx = VMS::GLOBAL_BATTLER_OWNER[pair]
      entry      = lobby_data[:slots][pair]
      next unless entry
      if entry[:player_id] == $player.id
        st = $game_temp.vms[:state]
        return nil unless st.is_a?(Array) && st[0] == :multibattle_selection && st[4].is_a?(Array)
        parties[global_idx] = st[4]
      else
        player = VMS.mb_get_player_for_slot(lobby_id, pair[0], pair[1])
        return nil if player.nil?
        st = player.state
        return nil unless st.is_a?(Array) && st[0] == :multibattle_selection && st[4].is_a?(Array)
        parties[global_idx] = st[4]
      end
    end
    return parties
  end

  # Build player_party (self+ally) and foe_party (enemy0+enemy1) for this client.
  def self.mb_build_battle_parties(parties_by_global)
    l2g          = $game_temp.vms[:mb_local_to_global]
    player_party = (parties_by_global[l2g[0]] || []) + (parties_by_global[l2g[2]] || [])
    foe_party    = (parties_by_global[l2g[1]] || []) + (parties_by_global[l2g[3]] || [])
    return player_party, foe_party
  end

  # Deterministic seed: hash of lobby_id + all 4 parties in global order 0-3.
  def self.mb_generate_seed(lobby_id, parties_by_global)
    seed_str = lobby_id.to_s
    [0, 1, 2, 3].each do |g|
      party = parties_by_global[g]
      next unless party.is_a?(Array)
      party.each { |pkmn| seed_str += VMS.hash_pokemon(pkmn) if pkmn }
    end
    return VMS.string_to_integer(seed_str)
  end

  # -------------------------------------------------------------------------
  # Command application helper (called by VMS_Multibattle_AI)
  # -------------------------------------------------------------------------

  # Apply a remote player's move pick to the local battle for +local_battler_idx+.
  # pick = [choice_type, move_or_switch_idx, nil, item_target, global_target]
  # remote_state = full state array; [5..9] = mega,z,dyna,tera booleans
  # g2l = this client's global-to-local map
  def self.mb_apply_command(battle, local_battler_idx, pick, remote_state, g2l)
    return if pick.nil?
    case pick[0]
    when :SwitchOut
      raw_index = pick[1]
      begin
        trainer_idx = battle.pbGetOwnerIndexFromBattlerIndex(local_battler_idx)
        offset = local_battler_idx.even? ? (battle.party1starts[trainer_idx] || 0) : (battle.party2starts[trainer_idx] || 0)
        raw_index = offset + raw_index
      rescue
      end
      battle.pbRegisterSwitch(local_battler_idx, raw_index)
    when :UseItem
      battle.pbRegisterItem(local_battler_idx, pick[1], pick[2], pick[3])
    when :UseMove
      battle.pbRegisterMove(local_battler_idx, pick[1], false)
      raw_global = pick[4]
      if raw_global.is_a?(Integer) && raw_global >= 0
        local_target = g2l[raw_global]
        battle.pbRegisterTarget(local_battler_idx, local_target) if local_target
      end
      # Special move flags (state indices 5..8 = mega, z, dyna, tera)
      begin; battle.pbRegisterMegaEvolution(local_battler_idx)  if remote_state[6]; rescue; end
      begin; battle.pbRegisterZMove(local_battler_idx)          if remote_state[7]; rescue; end
      begin; battle.pbRegisterDynamax(local_battler_idx)        if remote_state[8]; rescue; end
      begin; battle.pbRegisterTerastallize(local_battler_idx)   if remote_state[9]; rescue; end
    end
  end
end

# =============================================================================
# Battle::VMS_Multibattle_AI
# Handles the 3 non-local battlers (local indices 1, 2, 3) by polling the
# corresponding remote players' multibattle_command / multibattle_switch states.
# =============================================================================
class Battle
  class VMS_Multibattle_AI < AI
    def pbDefaultChooseEnemyCommand(idxBattler)
      set_up(idxBattler)
      l2g        = $game_temp.vms[:mb_local_to_global]
      g2l        = $game_temp.vms[:mb_global_to_local]
      lobby_id   = $game_temp.vms[:mb_lobby_id]
      global_idx = l2g[idxBattler]

      remote_player = VMS.mb_get_player_for_global_battler(global_idx)
      remote_name   = remote_player&.name || "Unknown"
      msgwindow     = @battle.scene.sprites["messageWindow"]

      loop do
        VMS.scene_update rescue nil
        remote_player = VMS.mb_get_player_for_global_battler(global_idx)

        # Disconnect / forfeit detection
        if remote_player.nil? || remote_player.state[0] == :idle
          @battle.pbDisplayPaused(_INTL("{1} has disconnected.", remote_name))
          @battle.decision = 1
          msgwindow.visible = false
          msgwindow.setText("")
          return
        end
        unless VMS.is_connected?
          @battle.pbDisplayPaused(_INTL("You have disconnected..."))
          @battle.decision = 2
          msgwindow.visible = false
          msgwindow.setText("")
          return
        end

        st = remote_player.state
        # state layout: [:multibattle_command, lobby_id, team, slot, turn_count, pick, mega, z, dyna, tera]
        if st[0] == :multibattle_command && st[1] == lobby_id && st[4] == @battle.turnCount
          msgwindow.visible = false
          msgwindow.setText("")
          VMS.mb_apply_command(@battle, idxBattler, st[5], st, g2l)
          return
        end

        if msgwindow.text.to_s == ""
          @battle.scene.pbShowWindow(Battle::Scene::MESSAGE_BOX)
          msgwindow.visible = true
          msgwindow.setText(_INTL("Waiting for {1}...", remote_name))
          while msgwindow.busy?
            @battle.scene.pbUpdate(msgwindow)
          end
        end
        @battle.scene.pbUpdate
      end
    end

    def pbDefaultChooseNewEnemy(idxBattler)
      set_up(idxBattler)
      l2g        = $game_temp.vms[:mb_local_to_global]
      lobby_id   = $game_temp.vms[:mb_lobby_id]
      global_idx = l2g[idxBattler]

      remote_player = VMS.mb_get_player_for_global_battler(global_idx)
      remote_name   = remote_player&.name || "Unknown"
      msgwindow     = @battle.scene.sprites["messageWindow"]

      loop do
        VMS.scene_update rescue nil
        remote_player = VMS.mb_get_player_for_global_battler(global_idx)

        if remote_player.nil? || remote_player.state[0] == :idle
          @battle.pbDisplayPaused(_INTL("{1} has disconnected.", remote_name))
          @battle.decision = 1
          msgwindow.visible = false
          msgwindow.setText("")
          return -1
        end
        unless VMS.is_connected?
          @battle.pbDisplayPaused(_INTL("You have disconnected..."))
          @battle.decision = 2
          msgwindow.visible = false
          msgwindow.setText("")
          return -1
        end

        # state layout: [:multibattle_switch, lobby_id, team, slot, global_battler_idx, new_party_index]
        st = remote_player.state
        if st[0] == :multibattle_switch && st[1] == lobby_id && st[4] == global_idx
          msgwindow.visible = false
          msgwindow.setText("")
          raw_index = st[5]
          begin
            trainer_idx = @battle.pbGetOwnerIndexFromBattlerIndex(idxBattler)
            offset = idxBattler.even? ? (@battle.party1starts[trainer_idx] || 0) : (@battle.party2starts[trainer_idx] || 0)
            return offset + raw_index
          rescue
            return raw_index
          end
        end

        if msgwindow.text.to_s == ""
          @battle.scene.pbShowWindow(Battle::Scene::MESSAGE_BOX)
          msgwindow.visible = true
          msgwindow.setText(_INTL("Waiting for {1} to pick a Pokémon...", remote_name))
          while msgwindow.busy?
            @battle.scene.pbUpdate(msgwindow)
          end
        end
        @battle.scene.pbUpdate
      end
    end
  end
end

# =============================================================================
# TrainerBattle.start_core_VMS_multibattle
# Sets up and runs the multibattle with explicit parties. Always a double battle.
# =============================================================================
class TrainerBattle
  def self.start_core_VMS_multibattle(enemy_a, enemy_b)
    outcome_variable = $game_temp.battle_rules["outcomeVar"] || 1
    return BattleCreationHelperMethods.skip_battle(outcome_variable, true) if BattleCreationHelperMethods.skip_battle?

    EventHandlers.trigger(:on_start_battle)

    # Foe side: two separate trainers with their own parties
    foe_trainers     = [enemy_a, enemy_b]
    foe_party        = (enemy_a.party || []) + (enemy_b.party || [])
    foe_party_starts = [0, (enemy_a.party || []).length]
    foe_items        = [[], []]

    # Player side: local player + partner registered via pbRegisterPartner
    player_trainers, ally_items, player_party, player_party_starts =
      BattleCreationHelperMethods.set_up_player_trainers(foe_party)

    scene  = BattleCreationHelperMethods.create_battle_scene
    battle = Battle.new(scene, player_party, foe_party, player_trainers, foe_trainers)
    battle.battleAI      = Battle::VMS_Multibattle_AI.new(battle)
    battle.party1starts  = player_party_starts
    battle.party2starts  = foe_party_starts
    battle.ally_items    = ally_items
    battle.items         = foe_items
    battle.internalBattle = false

    setBattleRule("canLose")
    setBattleRule("noExp")
    setBattleRule("noMoney")
    setBattleRule("double")
    begin
      setBattleRule("noBag")
    rescue
    end

    can_lose = true
    BattleCreationHelperMethods.prepare_battle(battle)
    $game_temp.clear_battle_rules

    outcome = 0
    pbBattleAnimation(pbGetTrainerBattleBGM(foe_trainers), 3, foe_trainers) do
      pbSceneStandby { outcome = battle.pbStartBattle }
      BattleCreationHelperMethods.after_battle(outcome, can_lose)
    end
    Input.update
    BattleCreationHelperMethods.set_outcome(outcome, outcome_variable, true)
    return outcome
  end
end
