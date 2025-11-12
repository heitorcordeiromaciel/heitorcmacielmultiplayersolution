module VMS
  def self.start_battle(player)
    begin
      # In start_battle
      seed_str = VMS.get_cluster_id.to_s
      if $player.id < player.id
        seed_str += hash_pokemon($player.party).to_s
        seed_str += hash_pokemon(player.party).to_s
      else
        seed_str += hash_pokemon(player.party).to_s
        seed_str += hash_pokemon($player.party).to_s
      end

      seed_int = VMS.string_to_integer(seed_str)  # already integer
      srand(seed_int)
      $game_temp.vms[:seed] = seed_int  # MUST store integer
      $game_temp.vms[:battle_player] = player
      trainer = NPCTrainer.new(player.name, player.trainer_type, 0)
      trainer.id = player.id
      trainer.party = VMS.update_party(player)
      TrainerBattle.start_core_VMS(trainer)
      $game_temp.vms[:battle_player] = nil
      $game_temp.vms[:state] = [:idle, nil]
      VMS.sync_seed
    rescue
      VMS.log("An error occurred whilst battling.", true)
      VMS.message(VMS::BASIC_ERROR_MESSAGE)
    end
  end
end

class Battle
  def battleAI=(value)
    @battleAI = value
  end

  def pbRandom(x)
    if VMS.is_connected? && !@internalBattle && !$game_temp.vms[:battle_player].nil?
      seed = $game_temp.vms[:seed]
      seed = seed.to_i unless seed.is_a?(Integer)  # force integer just in case
      srand(seed + @turnCount)
      return rand(x)
    end
    return rand(x)
  end

  alias vms_pbCommandPhaseLoop pbCommandPhaseLoop unless method_defined?(:vms_pbCommandPhaseLoop)
  def pbCommandPhaseLoop(isPlayer)
    vms_pbCommandPhaseLoop(isPlayer)
    if VMS.is_connected? && isPlayer
      picks = @choices.map(&:dup)
      picks.map! { |pick| VMS.clean_up_basic_array(pick) }
      owner = pbGetOwnerIndexFromBattlerIndex(@battlers[0].index)
      will_mega = @megaEvolution[0][owner] == @battlers[0].index
      will_zmove = @zMove[0][owner] == @battlers[0].index rescue false
      will_dynamax = @dynamax[0][owner] == @battlers[0].index rescue false
      will_tera = @terastallize[0][owner] == @battlers[0].index rescue false
      $game_temp.vms[:state] = [:battle_command, $game_temp.vms[:state][1], @turnCount, @battlers[0].index, picks, will_mega, will_zmove, will_dynamax, will_tera]
    end
  end

  alias vms_pbConsumeItemInBag pbConsumeItemInBag unless method_defined?(:vms_pbConsumeItemInBag)
  def pbConsumeItemInBag(item, idxBattler)
    return if !item
    return if !GameData::Item.get(item).consumed_after_use?
    return if VMS.is_connected? && @battleAI.is_a?(Battle::VMS_AI)
    vms_pbConsumeItemInBag(item, idxBattler)
  end

  alias vms_pbItemMenu pbItemMenu unless method_defined?(:vms_pbItemMenu)
  def pbItemMenu(idxBattler, firstAction)
    @internalBattle = true if VMS.is_connected? && @battleAI.is_a?(Battle::VMS_AI)
    ret = vms_pbItemMenu(idxBattler, firstAction)
    @internalBattle = false if VMS.is_connected? && @battleAI.is_a?(Battle::VMS_AI)
    return ret
  end

  # For choosing a replacement Pokémon when prompted in the middle of other
  # things happening (U-turn, Baton Pass, in def pbEORSwitch).
  def pbSwitchInBetween(idxBattler, checkLaxOnly = false, canCancel = false)
    if !@controlPlayer && pbOwnedByPlayer?(idxBattler)
      newIndex = pbPartyScreen(idxBattler, checkLaxOnly, canCancel)
      $game_temp.vms[:state] = [:battle_new_switch, $game_temp.vms[:state][1], newIndex] if VMS.is_connected?
      return newIndex
    end
    return @battleAI.pbDefaultChooseNewEnemy(idxBattler)
  end

  class VMS_AI < AI
    # Choosing a new switch in pokémon
    def pbDefaultChooseNewEnemy(idxBattler)
      set_up(idxBattler)
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
        if player.state[0] == :battle_new_switch
          msgwindow.visible = false
          msgwindow.setText("")
          return player.state[2]
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

    # Choose an action.
    def pbDefaultChooseEnemyCommand(idxBattler)
      set_up(idxBattler)
      ret = false
      player = $game_temp.vms[:battle_player]
      player_name = player.name
      msgwindow = @battle.scene.sprites["messageWindow"]
      loop do
        player = VMS.get_player(player.id)
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
        if player.state[2] == @battle.turnCount
          msgwindow.visible = false
          msgwindow.setText("")
          case player.state[4][0][0]
          when :SwitchOut
            @battle.pbRegisterSwitch(idxBattler, player.state[4][0][1])
            return
          when :UseItem
            @battle.pbRegisterItem(idxBattler, player.state[4][0][1], player.state[4][0][2], player.state[4][0][3])
            return
          when :UseMove
            @battle.pbRegisterMove(idxBattler, player.state[4][0][1], false)
            @battle.pbRegisterTarget(idxBattler, player.state[4][0][3])
            @battle.pbRegisterMegaEvolution(idxBattler) if player.state[5]
            @battle.pbRegisterZMove(idxBattler) if player.state[6]
            @battle.pbRegisterDynamax(idxBattler) if player.state[7]
            @battle.pbRegisterTerastallize(idxBattler) if player.state[8]
            return
          else
            @battle.pbDisplayPaused(_INTL("{1} has forfeited.", player_name))
            @battle.decision = 1
            return
          end
        end
        if msgwindow.text == ""
          @battle.scene.pbShowWindow(Battle::Scene::MESSAGE_BOX)
          msgwindow.visible = true
          msgwindow.setText(_INTL("Waiting for {1} to select a move...", player.name))
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
    can_lose         = $game_temp.battle_rules["canLose"] || false
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
    # Set various other properties in the battle class
    setBattleRule("canLose")
    setBattleRule("#{foe_trainers.length}v#{foe_trainers.length}") if $game_temp.battle_rules["size"].nil?
    BattleCreationHelperMethods.prepare_battle(battle)
    $game_temp.clear_battle_rules
    # Perform the battle itself
    outcome = 0
    pbBattleAnimation(pbGetTrainerBattleBGM(foe_trainers), (battle.singleBattle?) ? 1 : 3, foe_trainers) do
      pbSceneStandby { outcome = battle.pbStartBattle }
      BattleCreationHelperMethods.after_battle(outcome, can_lose)
    end
    Input.update
    # Save the result of the battle in a Game Variable (1 by default)
    BattleCreationHelperMethods.set_outcome(outcome, outcome_variable, true)
    return outcome
  end
end
