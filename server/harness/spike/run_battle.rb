# D7 STEP-0 GATE spike — build two parties, run one AI-vs-AI battle to decision.
# Mimics pbRuledBattle in 004_ChallengeGenerator_BattleSim.rb.
# Env knobs: SPIKE_SEED=<int>  SPIKE_PARTY=big  (3v3 lvl 50 instead of 1v1)

require "timeout"
require "digest"

seed = (ENV["SPIKE_SEED"] || "20260725").to_i
srand(seed)

T_B0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

t_type = GameData::TrainerType.keys.first
trainer1 = NPCTrainer.new("SIM-RED", t_type)
trainer2 = NPCTrainer.new("SIM-BLUE", t_type)

if ENV["SPIKE_PARTY"] == "big"
  [[trainer1, [:CHARIZARD, :BLASTOISE, :VENUSAUR]],
   [trainer2, [:DRAGONITE, :GENGAR, :SNORLAX]]].each do |tr, species|
    species.each { |sp| tr.party.push(Pokemon.new(sp, 50, tr)) }
  end
else
  trainer1.party.push(Pokemon.new(:PIKACHU, 20, trainer1))
  trainer2.party.push(Pokemon.new(:PIDGEY, 18, trainer2))
end

trainer1.party.each_with_index do |p, i|
  puts "Party 1[#{i}]: #{p.name} lv#{p.level} HP #{p.hp}/#{p.totalhp} moves=#{p.moves.map(&:id).inspect}"
end
trainer2.party.each_with_index do |p, i|
  puts "Party 2[#{i}]: #{p.name} lv#{p.level} HP #{p.hp}/#{p.totalhp} moves=#{p.moves.map(&:id).inspect}"
end

$game_temp.in_battle = true

scene = Battle::DebugSceneNoVisuals.new(true)   # log battle messages into PBDebug::LOG
battle = Battle.new(scene, trainer1.party, trainer2.party, [trainer1], [trainer2])
battle.debug          = true
battle.controlPlayer  = true    # AI plays BOTH sides
battle.internalBattle = false

decision = nil
Timeout.timeout(180) do
  decision = battle.pbStartBattle
end

T_B1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

transcript = PBDebug::LOG.join("\n")

puts "=" * 60
puts "SEED     = #{seed}  PARTY=#{ENV["SPIKE_PARTY"] || "small"}"
puts "DECISION = #{decision}  (1=side1 won, 2=side1 lost, 3=ran/forfeit, 5=draw)"
puts "ROUNDS   = #{battle.turnCount + 1} (turnCount=#{battle.turnCount})"
puts format("BATTLE TIME = %.3fs", T_B1 - T_B0)
puts format("TOTAL WALL  = %.2fs (scripts+data+battle)", T_B1 - T_START)
trainer1.party.each { |p| puts "P1 end: #{p.name} HP #{p.hp}/#{p.totalhp}" }
trainer2.party.each { |p| puts "P2 end: #{p.name} HP #{p.hp}/#{p.totalhp}" }
puts "TRANSCRIPT: #{PBDebug::LOG.length} lines, digest=#{Digest::MD5.hexdigest(transcript)}"
puts "=" * 60
if ENV["SPIKE_QUIET"] != "1"
  puts "CAPTURED BATTLE MESSAGES:"
  PBDebug::LOG.each_with_index do |line, i|
    puts "  #{line}"
    break if i >= 120
  end
  puts "  ... (#{PBDebug::LOG.length - 121} more)" if PBDebug::LOG.length > 121
end
puts "GATE: BATTLE COMPLETED OK"
