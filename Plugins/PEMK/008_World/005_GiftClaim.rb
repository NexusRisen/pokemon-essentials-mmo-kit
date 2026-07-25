#===============================================================================
# PEMK :: GiftClaim  (client side — NPC gift / event-item acquisition report)
#-------------------------------------------------------------------------------
# Layer C gates item BALLS only (pbItemBall). Every other acquisition — NPC gifts,
# TMs, HMs, key items, story rewards — funnels through the single seam
# pbReceiveItem, which was hooked NOWHERE. Combined with client-owned self-switches
# (a rewind re-arms every one-shot event), that made all of it re-farmable with no
# trace at all.
#
# This is a fire-and-forget REPORT, not a gate: it names which map/event granted
# what, so a re-farm leaves a record. It never blocks or delays the gift — the bag
# is blob-authoritative and a blocking round-trip inside an event script is exactly
# the kind of thing that hangs a save. Dormant unless the server advertises the
# flag shadow (PEMK_FLAG_STATE), and silent when offline.
#===============================================================================
module PEMK
  module GiftClaim
    module_function

    # The event that is running right now, so the server can key the one-shot.
    # -> [map_id, event_id] | nil when there is no event context (debug, script call).
    def context
      map = ($game_map && $game_map.map_id) rescue nil
      return nil unless map

      # The running event IS the one-shot key. Interpreter exposes NO public accessor
      # for @event_id (verified — a `.event_id` call would raise, my rescue would eat
      # it, and this whole feature would be silently dead), so read the ivar, exactly
      # as PEMK::Flags reads the switch/variable @data wrappers. 0 = no event running.
      interp = pbMapInterpreter
      id = interp && interp.instance_variable_get(:@event_id)
      return nil unless id.is_a?(Integer) && id.positive?

      [map, id]
    rescue StandardError
      nil
    end

    def report(item, quantity)
      return unless (PEMK::Flags.active? rescue false)
      return unless PEMK.enabled? && PEMK.self_id

      ctx = context
      return unless ctx   # no event context -> not a one-shot we can key

      PEMK.send_message(:type => :gift_claim, :map => ctx[0], :event => ctx[1],
                        :item => item.to_s, :quantity => quantity)
    rescue StandardError => e
      PEMK.log("gift: report error #{e.class}: #{e.message}")
    end
  end
end

# The ONE acquisition seam outside item balls. Guarded so it aliases at most once and
# loads cleanly in a headless harness (pbReceiveItem undefined there). The report is
# fire-and-forget AFTER the original ran — it never changes the outcome.
if defined?(pbReceiveItem) && !defined?(pemk_orig_pbReceiveItem)
  alias pemk_orig_pbReceiveItem pbReceiveItem
  def pbReceiveItem(item, quantity = 1)
    ret = pemk_orig_pbReceiveItem(item, quantity)
    (PEMK::GiftClaim.report(item, quantity) rescue nil) if ret
    ret
  end
end
