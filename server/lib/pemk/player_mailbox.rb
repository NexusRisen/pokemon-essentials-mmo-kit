# frozen_string_literal: true

module PEMK
  # Serializes a single account's mutations onto the shared worker pool: at most
  # ONE in-flight job per account, drained in arrival order. Fixes the concurrent
  # read-modify-write race (two economy frames for the same player racing on the
  # pool) without a thread per player — 500-CCU friendly.
  #
  # Reactor-thread only for the bookkeeping (@boxes): #submit is called from the
  # reactor; each job runs on a worker; its completion is re-entered on the reactor
  # thread via +post+ to advance the queue. So @boxes is never touched concurrently.
  class PlayerMailbox
    def initialize(pool:, post:, logger: nil)
      @pool  = pool             # WorkerPool
      @post  = post             # ->(&blk) runs blk on the reactor thread (reactor.post)
      @log   = logger || ->(_m) {}
      @boxes = {}               # account_id => { queue: [job,...], busy: bool }
    end

    # Depth ceiling per account. The per-connection frame budget already bounds the
    # inflow; this is the backstop that stops a queue from retaining megabytes of frame
    # bodies (a :save job closes over its whole blob) if a worker stalls (audit).
    MAX_QUEUE = 64

    # Enqueue a job (a no-arg proc, runs on a worker) for +account_id+. Reactor thread.
    # -> true if queued, false if dropped (the caller may nack).
    def submit(account_id, &job)
      box = (@boxes[account_id] ||= { queue: [], busy: false })
      if box[:queue].length >= MAX_QUEUE
        @log.call("mailbox: account #{account_id} queue full (#{MAX_QUEUE}) -> dropping job")
        return false
      end
      box[:queue] << job
      dispatch(account_id, box)
      true
    end

    def size
      @boxes.size
    end

    private

    def dispatch(account_id, box)
      return if box[:busy] || box[:queue].empty?

      box[:busy] = true
      job = box[:queue].shift
      @pool.submit do
        begin
          job.call
        rescue StandardError => e
          @log.call("mailbox: #{e.class}: #{e.message}")
        end
        @post.call do
          box[:busy] = false
          dispatch(account_id, box)
        end
      end
    end
  end
end
