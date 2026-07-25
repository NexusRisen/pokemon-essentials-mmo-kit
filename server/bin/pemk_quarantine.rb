# frozen_string_literal: true

# M4 Layer D D8 — the operator's quarantine console. Reversibility is D8's spine:
# every consequence is one UPDATE, and this is where a human undoes a false
# positive. NEVER destroys anything.
#
# Usage (WSL, from server/):
#   DATABASE_URL=... bundle exec ruby bin/pemk_quarantine.rb list [account_id]
#   DATABASE_URL=... bundle exec ruby bin/pemk_quarantine.rb show <uid>
#   DATABASE_URL=... bundle exec ruby bin/pemk_quarantine.rb pardon <uid> [reason...]
#   DATABASE_URL=... bundle exec ruby bin/pemk_quarantine.rb reports        # open review queue

require "sequel"

db  = Sequel.connect(ENV.fetch("DATABASE_URL"))
cmd = ARGV.shift

def audit(db, account_id, kind, uid, detail)
  db[:enforcement_events].insert(account_id: account_id, kind: kind, monster_uid: uid,
                                 detail: detail, created_at: Time.now)
end

case cmd
when "list"
  ds = db[:monsters].where(status: "quarantined")
  ds = ds.where(owner_account_id: ARGV[0].to_i) if ARGV[0]
  rows = ds.order(:quarantined_at).all
  puts "#{rows.length} quarantined mon(s):"
  rows.each do |m|
    puts format("  uid %-8d acct %-6d %-14s reason=%-14s at %s (evidence record #%s)",
                m[:id], m[:owner_account_id], m[:species], m[:quarantine_reason],
                m[:quarantined_at], m[:quarantine_record_id] || "-")
  end

when "show"
  uid = ARGV.shift.to_i
  m = db[:monsters].where(id: uid).first
  abort "no such mon uid #{uid}" unless m
  puts "uid #{uid}: #{m[:species]} acct=#{m[:owner_account_id]} status=#{m[:status]} verify=#{m[:verify_state]}"
  puts "  reason=#{m[:quarantine_reason]} at=#{m[:quarantined_at]} evidence=record##{m[:quarantine_record_id]}"
  roll = db[:encounter_rolls].where(claimed_monster_uid: uid).first
  if roll
    puts "  roll ##{roll[:id]} seed=#{roll[:battle_seed]} condemned_at=#{roll[:condemned_at] || '-'}"
    rec = db[:battle_records].where(encounter_roll_id: roll[:id]).order(Sequel.desc(:id)).first
    puts "  record ##{rec[:id]} replay_status=#{rec[:replay_status]} enforcement=#{rec[:enforcement_action]}" if rec
  end
  puts "  audit trail:"
  db[:enforcement_events].where(monster_uid: uid).order(:created_at).each do |e|
    puts "    #{e[:created_at]} #{e[:kind]} — #{e[:detail]}"
  end

when "pardon"
  uid    = ARGV.shift.to_i
  reason = ARGV.join(" ")
  reason = "operator pardon" if reason.empty?
  m = db[:monsters].where(id: uid).first
  abort "no such mon uid #{uid}" unless m
  unless m[:status] == "quarantined"
    abort "uid #{uid} is not quarantined (status=#{m[:status]})"
  end
  db.transaction do
    db[:monsters].where(id: uid).update(status: "active", quarantine_reason: nil,
                                        quarantined_at: nil, quarantine_record_id: nil,
                                        updated_at: Time.now)
    # also un-poison the roll so a re-mint / re-verify won't re-quarantine it
    db[:encounter_rolls].where(claimed_monster_uid: uid).update(condemned_at: nil)
    audit(db, m[:owner_account_id], "pardon", uid, reason)
  end
  puts "pardoned uid #{uid} (#{m[:species]}, acct #{m[:owner_account_id]}) — now active. reason: #{reason}"

when "reports"
  rows = db[:anomaly_reports].where(reviewed_at: nil).order(Sequel.desc(:updated_at)).limit(100).all
  puts "#{rows.length} open review report(s):"
  rows.each do |r|
    puts format("  acct %-6d %-22s score=%-4d %s", r[:account_id], r[:kind], r[:score], r[:detail])
  end

else
  puts <<~USAGE
    PEMK quarantine console (D8). Commands:
      list [account_id]        quarantined mons (optionally one account)
      show <uid>               full evidence + audit trail for a mon
      pardon <uid> [reason]    un-quarantine (one UPDATE; reversal is the design's spine)
      reports                  open D5/D8 review queue
  USAGE
  exit 1
end
