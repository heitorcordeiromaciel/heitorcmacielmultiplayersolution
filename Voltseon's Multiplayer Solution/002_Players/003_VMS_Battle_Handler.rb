module VMS
  def self.start_battle(player, type = :single, size = 6, seed = nil)
    begin
      # In start_battle
      if seed.nil?
        seed_str = VMS.get_cluster_id.to_s
        if $player.id < player.id
          seed_str += hash_pokemon($player.party).to_s
          seed_str += hash_pokemon(player.party).to_s
        else
          seed_str += hash_pokemon(player.party).to_s
          seed_str += hash_pokemon($player.party).to_s
        end
        seed = VMS.string_to_integer(seed_str)
      end

      $game_temp.vms[:seed] = seed
      $game_temp.vms[:battle_player] = player
      $game_temp.vms[:battle_type] = type
      
      # Party Selection Phase
      new_party = nil
      # Always show selection screen for ordering, unless party is empty (which shouldn't happen)
      if $player.party.length > 0
        ruleset = PokemonRuleSet.new
        if size.nil?
          ruleset.setNumberRange(1, 6)
        else
          ruleset.setNumber(size)
        end
        ruleset.addPokemonRule(AblePokemonRestriction.new)
        pbFadeOutIn {
          scene = PokemonParty_Scene.new
          screen = PokemonPartyScreen.new(scene, $player.party)
          new_party = screen.pbPokemonMultipleEntryScreenEx(ruleset)
        }
        if !new_party
          $game_temp.vms[:state] = [:idle, nil]
          return
        end
      end

      # Sync selection - send the party array directly (no serialization)
      $game_temp.vms[:state] = [:battle_selection, player.id, new_party]
      if !VMS.await_player_state(player, :battle_selection, _INTL("Waiting for {1} to select Pokémon...", player.name), true, true)
        $game_temp.vms[:state] = [:idle, nil]
        return
      end
      # Receive the party array directly (no deserialization needed)
      filtered_opponent_party = player.state[2]

      # Validate opponent party
      if filtered_opponent_party.nil? || !filtered_opponent_party.is_a?(Array) || filtered_opponent_party.empty?
        VMS.message(_INTL("Unable to start battle - opponent has no valid Pokémon."))
        $game_temp.vms[:state] = [:idle, nil]
        return
      end

      old_party = $player.party
      $player.party = new_party if new_party

      trainer = NPCTrainer.new(player.name, player.trainer_type, 0)
      trainer.party = filtered_opponent_party

      srand($game_temp.vms[:seed])

      TrainerBattle.start_core_VMS(trainer)

      $player.party = old_party
      $player.party.each { |pkmn| pkmn.heal if pkmn }
      
      $game_temp.vms[:battle_player] = nil
      $game_temp.vms[:battle_type] = nil
      $game_temp.vms[:state] = [:idle, nil]
      VMS.sync_seed
    rescue StandardError => e
      VMS.message(_INTL("An error has occurred: {1}", e.message))
      $player.party = old_party if old_party
      $game_temp.vms[:state] = [:idle, nil]
    end
  end
end

class Battle
  attr_accessor :battleAI, :party1starts, :party2starts, :ally_items
  alias vms_initialize initialize unless method_defined?(:vms_initialize)
  def initialize(*args)
    vms_initialize(*args)
    @vms_random_calls = 0
  end

  def pbRandom(x)
    in_vms_battle = VMS.is_connected? && !@internalBattle &&
                    (!$game_temp.vms[:battle_player].nil? || $game_temp.vms[:mb_in_battle])
    if in_vms_battle
      seed = $game_temp.vms[:seed]
      seed = seed.to_i unless seed.is_a?(Integer)
      @vms_random_calls ||= 0
      @vms_random_calls += 1
      # Use turnCount and call counter to ensure unique but synced results
      srand(seed + (@turnCount * 1000) + @vms_random_calls)
      return rand(x)
    end
    return rand(x)
  end

  alias vms_pbCommandPhaseLoop pbCommandPhaseLoop unless method_defined?(:vms_pbCommandPhaseLoop)
  def pbCommandPhaseLoop(isPlayer)
    @vms_random_calls = 0 if isPlayer # Reset counter for the new turn
    vms_pbCommandPhaseLoop(isPlayer)
    if VMS.is_connected? && isPlayer && !VMS.multibattle_active?
      is_single = $game_temp.vms[:battle_type] != :double
      battler_indices = is_single ? [0] : [0, 2]
      picks = []
      battler_indices.each do |idx|
        choice = @choices[idx]
        if choice.nil?
          picks << nil
        else
          picks << [choice[0], choice[1], nil, choice[3], choice[4]]
        end
      end

      mega_idx_0 = -1
      mega_idx_2 = -1
      z_idx_0 = -1
      z_idx_2 = -1
      dyna_idx_0 = -1
      dyna_idx_2 = -1
      tera_idx_0 = -1
      tera_idx_2 = -1

      @battlers.each do |battler|
        next if !battler || !pbOwnedByPlayer?(battler.index)
        owner = pbGetOwnerIndexFromBattlerIndex(battler.index)
        battler_idx = battler.index

        if @megaEvolution[0][owner] >= 0 && @megaEvolution[0][owner] == battler_idx
          if battler_idx == 0
            mega_idx_0 = 0
          elsif battler_idx == 2
            mega_idx_2 = 2
          end
        end
        begin
          if @zMove[0][owner] >= 0 && @zMove[0][owner] == battler_idx
            if battler_idx == 0
              z_idx_0 = 0
            elsif battler_idx == 2
              z_idx_2 = 2
            end
          end
        rescue
        end
        begin
          if @dynamax[0][owner] >= 0 && @dynamax[0][owner] == battler_idx
            if battler_idx == 0
              dyna_idx_0 = 0
            elsif battler_idx == 2
              dyna_idx_2 = 2
            end
          end
        rescue
        end
        begin
          if @terastallize[0][owner] >= 0 && @terastallize[0][owner] == battler_idx
            if battler_idx == 0
              tera_idx_0 = 0
            elsif battler_idx == 2
              tera_idx_2 = 2
            end
          end
        rescue
        end
      end

      $game_temp.vms[:state] = [:battle_command, $game_temp.vms[:state][1], @turnCount, picks, mega_idx_0, mega_idx_2, z_idx_0, z_idx_2, dyna_idx_0, dyna_idx_2, tera_idx_0, tera_idx_2]
    end

    # --- Multibattle branch: each player controls only battler 0 (local layout) ---
    if VMS.is_connected? && isPlayer && VMS.multibattle_active?
      choice = @choices[0]
      raw_target = choice ? choice[3] : nil
      global_target = VMS.mb_local_to_global_target(raw_target)
      pick = choice ? [choice[0], choice[1], nil, choice[3], global_target] : nil
      mega = false; z_move = false; dyna = false; tera = false
      begin
        owner = pbGetOwnerIndexFromBattlerIndex(0)
        mega     = (@megaEvolution[0][owner] == 0)      rescue false
        z_move   = (@zMove[0][owner] == 0)              rescue false
        dyna     = (@dynamax[0][owner] == 0)            rescue false
        tera     = (@terastallize[0][owner] == 0)       rescue false
      rescue
      end
      $game_temp.vms[:state] = [:multibattle_command, $game_temp.vms[:mb_lobby_id], $game_temp.vms[:mb_team_idx], $game_temp.vms[:mb_slot_idx], @turnCount, pick, mega, z_move, dyna, tera]
    end
  end

  alias vms_pbConsumeItemInBag pbConsumeItemInBag unless method_defined?(:vms_pbConsumeItemInBag)
  def pbConsumeItemInBag(item, idxBattler)
    return if !item
    return if !GameData::Item.get(item).consumed_after_use?
    return if VMS.is_connected? && (@battleAI.is_a?(Battle::VMS_AI) || @battleAI.is_a?(Battle::VMS_Multibattle_AI))
    vms_pbConsumeItemInBag(item, idxBattler)
  end

  alias vms_pbItemMenu pbItemMenu unless method_defined?(:vms_pbItemMenu)
  def pbItemMenu(idxBattler, firstAction)
    is_vms = VMS.is_connected? && (@battleAI.is_a?(Battle::VMS_AI) || @battleAI.is_a?(Battle::VMS_Multibattle_AI))
    @internalBattle = true if is_vms
    ret = vms_pbItemMenu(idxBattler, firstAction)
    @internalBattle = false if is_vms
    return ret
  end

  def pbSwitchInBetween(idxBattler, checkLaxOnly = false, canCancel = false)
    if !@controlPlayer && pbOwnedByPlayer?(idxBattler)
      newIndex = pbPartyScreen(idxBattler, checkLaxOnly, canCancel)
      if VMS.is_connected?
        if VMS.multibattle_active?
          global_idx = $game_temp.vms[:mb_local_to_global][idxBattler]
          $game_temp.vms[:state] = [:multibattle_switch, $game_temp.vms[:mb_lobby_id], $game_temp.vms[:mb_team_idx], $game_temp.vms[:mb_slot_idx], global_idx, newIndex]
        else
          $game_temp.vms[:state] = [:battle_new_switch, $game_temp.vms[:state][1], idxBattler, newIndex]
        end
      end
      return newIndex
    end
    return @battleAI.pbDefaultChooseNewEnemy(idxBattler)
  end

  class VMS_AI < AI
    def pbDefaultChooseNewEnemy(idxBattler)
      set_up(idxBattler)
      player_name = $game_temp.vms[:state][1] ? VMS.get_player($game_temp.vms[:state][1])&.name : "Unknown"
      msgwindow = @battle.scene.sprites["messageWindow"]
      loop do
        player = VMS.get_player($game_temp.vms[:state][1])
        if player.nil?
          @battle.pbDisplayPaused(_INTL("{1} has disconnected...", player_name))
          @battle.decision = 1
          msgwindow.visible = false
          msgwindow.setText("")
          return -1
        end
        if !VMS.is_connected?
          @battle.pbDisplayPaused(_INTL("You have disconnected..."))
          @battle.decision = 2
          msgwindow.visible = false
          msgwindow.setText("")
          return -1
        end
        if player.state&.length >= 4 && player.state[0] == :battle_new_switch
          is_single = $game_temp.vms[:battle_type] != :double
          opp_idx = is_single ? 0 : ((idxBattler == 1) ? 0 : 2)
          if player.state[2] == opp_idx
            msgwindow.visible = false
            msgwindow.setText("")
            return player.state[3]
          end
        end
        if msgwindow.text == ""
          @battle.scene.pbShowWindow(Battle::Scene::MESSAGE_BOX)
          msgwindow.visible = true
          msgwindow.setText(_INTL("Waiting for {1} to select a new Pokémon...", player.name))
          while msgwindow.busy?
            @battle.scene.pbUpdate(msgwindow)
          end
        end
        @battle.scene.pbUpdate
      end
    end

    def pbDefaultChooseEnemyCommand(idxBattler)
      set_up(idxBattler)
      ret = false
      player_info = $game_temp.vms[:battle_player]
      player_name = player_info.name
      msgwindow = @battle.scene.sprites["messageWindow"]

      loop do
        player = VMS.get_player(player_info.id)
        if player.nil?
          @battle.pbDisplayPaused(_INTL("{1} has disconnected...", player_name))
          @battle.decision = 1
          msgwindow.visible = false
          msgwindow.setText("")
          return
        end
        if !VMS.is_connected?
          @battle.pbDisplayPaused(_INTL("You have disconnected..."))
          @battle.decision = 2
          msgwindow.visible = false
          msgwindow.setText("")
          return
        end
        if player.state&.length >= 1 && player.state[0] == :idle
          msgwindow.visible = false
          msgwindow.setText("")
          @battle.pbDisplayPaused(_INTL("{1} has forfeited.", player_name))
          @battle.decision = 1
          return
        end

        if player.state&.length >= 3 && player.state[0] == :battle_command
          opp_turn = player.state[2]

          if opp_turn == @battle.turnCount
            msgwindow.visible = false
            msgwindow.setText("")
            is_single = $game_temp.vms[:battle_type] != :double
            picks_idx = is_single ? 0 : ((idxBattler == 1) ? 0 : 1)
            if player.state.length >= 4 && player.state[3]&.length > picks_idx && player.state[3][picks_idx]&.length >= 1
              case player.state[3][picks_idx][0]
              when :SwitchOut
                @battle.pbRegisterSwitch(idxBattler, player.state[3][picks_idx][1])
                return
              when :UseItem
                @battle.pbRegisterItem(idxBattler, player.state[3][picks_idx][1], player.state[3][picks_idx][2], player.state[3][picks_idx][3])
                return
              when :UseMove
                target = player.state[3][picks_idx][3]
                if @battle.pbSideSize(0) > 1 && target.is_a?(Integer) && target >= 0
                  target = case target
                           when 0 then 1
                           when 1 then 0
                           when 2 then 3
                           when 3 then 2
                           else target
                           end
                end
                @battle.pbRegisterMove(idxBattler, player.state[3][picks_idx][1], false)
                @battle.pbRegisterTarget(idxBattler, target)
                # New format: player.state[4-11] = [mega_0, mega_2, z_0, z_2, dyna_0, dyna_2, tera_0, tera_2]
                # Their battler 0 (left) → our idxBattler 1, their battler 2 (right) → our idxBattler 3
                if player.state.length >= 12
                  mega_0 = player.state[4]
                  mega_2 = player.state[5]
                  z_0 = player.state[6]
                  z_2 = player.state[7]
                  dyna_0 = player.state[8]
                  dyna_2 = player.state[9]
                  tera_0 = player.state[10]
                  tera_2 = player.state[11]

                  # Map: their battler 0 (L) → our battler 1 (L), their battler 2 (R) → our battler 3 (R)
                  if idxBattler == 1
                    # Processing their battler 0 (their left = our left when facing them)
                    @battle.pbRegisterMegaEvolution(idxBattler) if mega_0 == 0
                    @battle.pbRegisterZMove(idxBattler) if z_0 == 0
                    @battle.pbRegisterDynamax(idxBattler) if dyna_0 == 0
                    if tera_0 == 0
                      VMS.log("DEBUG: Registering Terastallize for idxBattler=#{idxBattler} (their battler 0)")
                      @battle.pbRegisterTerastallize(idxBattler)
                    end
                  elsif idxBattler == 3
                    # Processing their battler 2 (their right = our right when facing them)
                    @battle.pbRegisterMegaEvolution(idxBattler) if mega_2 == 2
                    @battle.pbRegisterZMove(idxBattler) if z_2 == 2
                    @battle.pbRegisterDynamax(idxBattler) if dyna_2 == 2
                    if tera_2 == 2
                      VMS.log("DEBUG: Registering Terastallize for idxBattler=#{idxBattler} (their battler 2)")
                      @battle.pbRegisterTerastallize(idxBattler)
                    end
                  end
                end
                return
              end
            end
          elsif opp_turn < @battle.turnCount
            # Opponent is behind, we must wait for them to catch up
            # This shouldn't happen often if both are in sync
          end
        end

        if msgwindow.text == ""
          @battle.scene.pbShowWindow(Battle::Scene::MESSAGE_BOX)
          msgwindow.visible = true
          msgwindow.setText(_INTL("Waiting for {1} to select a move...", player_name))
          while msgwindow.busy?
            @battle.scene.pbUpdate(msgwindow)
          end
        end
        @battle.scene.pbUpdate
      end
    end
  end
end

class TrainerBattle
  def self.start_core_VMS(*args)
    outcome_variable = $game_temp.battle_rules["outcomeVar"] || 1
    # Skip battle if the player has no able Pokémon, or if holding Ctrl in Debug mode
    if BattleCreationHelperMethods.skip_battle?
      return BattleCreationHelperMethods.skip_battle(outcome_variable, true)
    end
    # Record information about party Pokémon to be used at the end of battle (e.g.
    # comparing levels for an evolution check)
    EventHandlers.trigger(:on_start_battle)
    # Generate information for the foes
    foe_trainers, foe_items, foe_party, foe_party_starts = TrainerBattle.generate_foes(*args)
    # Generate information for the player and partner trainer(s)
    player_trainers, ally_items, player_party, player_party_starts = BattleCreationHelperMethods.set_up_player_trainers(foe_party)
    # Create the battle scene (the visual side of it)
    scene = BattleCreationHelperMethods.create_battle_scene
    # Create the battle class (the mechanics side of it)
    battle = Battle.new(scene, player_party, foe_party, player_trainers, foe_trainers)
    battle.battleAI     = Battle::VMS_AI.new(battle)
    battle.party1starts = player_party_starts
    battle.party2starts = foe_party_starts
    battle.ally_items   = ally_items
    battle.items        = foe_items
    battle.internalBattle = false
    setBattleRule("canLose")
    setBattleRule("noExp")
    setBattleRule("noMoney")
    begin
      setBattleRule("noBag")
    rescue
    end
    if $game_temp.vms[:battle_type] == :double
      setBattleRule("double")
    else
      setBattleRule("single") if $game_temp.battle_rules["size"].nil?
    end
    can_lose = $game_temp.battle_rules["canLose"] || false
    BattleCreationHelperMethods.prepare_battle(battle)
    $game_temp.clear_battle_rules
    outcome = 0
    pbBattleAnimation(pbGetTrainerBattleBGM(foe_trainers), (battle.singleBattle?) ? 1 : 3, foe_trainers) do
      pbSceneStandby { outcome = battle.pbStartBattle }
      BattleCreationHelperMethods.after_battle(outcome, can_lose)
    end
    Input.update
    BattleCreationHelperMethods.set_outcome(outcome, outcome_variable, true)
    return outcome
  end
end