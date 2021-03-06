class Promiscuous::Subscriber::MessageProcessor::Regular < Promiscuous::Subscriber::MessageProcessor::Base
  include Promiscuous::Instrumentation
  delegate :write_dependencies, :read_dependencies, :dependencies, :to => :message

  def nodes_with_deps
    @nodes_with_deps ||= dependencies.group_by(&:redis_node)
  end

  def instance_dep
    @instance_dep ||= write_dependencies.first
  end

  def master_node
    @master_node ||= instance_dep.redis_node
  end

  def master_node_with_deps
    @master_node_with_deps ||= nodes_with_deps.select { |node| node == master_node }.first
  end

  def secondary_nodes_with_deps
    @secondary_nodes_with_deps ||= nodes_with_deps.reject { |node| node == master_node }.to_a
  end

  def recovery_key
    # We use a recovery_key unique to the operation to avoid any trouble of
    # touching another operation.
    @recovery_key ||= instance_dep.key(:sub).join(instance_dep.version_pass2).to_s
  end

  def get_current_instance_version
    master_node.get(instance_dep.key(:sub).join('rw').to_s).to_i
  end

  # XXX TODO Code is not tolerant to losing a lock.

  def update_dependencies_non_atomic_bootstrap(node, deps, options={})
    raise "Message should not have any read deps" if deps.any?(&:read?)

    argv = []
    argv << MultiJson.dump([deps.map { |dep| dep.key(:sub) },
                            deps.map { |dep| dep.version_pass2 + 1 }])

    # TODO Do the pass2 pending version thingy.

    @@update_script_bootstrap ||= Promiscuous::Redis::Script.new <<-SCRIPT
      local _args = cjson.decode(ARGV[1])
      local write_deps = _args[1]
      local write_versions = _args[2]

      for i, _key in ipairs(write_deps) do
        local key = _key .. ':rw'
        local v = write_versions[i]
        local current_version = tonumber(redis.call('get', key)) or 0
        if current_version < v then
          redis.call('set', key, v)
          redis.call('publish', key, v)
        end
      end
    SCRIPT

    @@update_script_bootstrap.eval(node, :argv => argv)
  end

  def update_dependencies_fast(node, deps, options={})
    keys = deps.map { |d| d.to_s(:raw => true) }
    argv = deps.map { |d| d.version_pass2 }
    argv << Promiscuous::Key.new(:sub).to_s
    argv << recovery_key if options[:with_recovery]

    @@update_script_fast ||= Promiscuous::Redis::Script.new <<-SCRIPT
      local deps = KEYS
      local versions = ARGV
      local prefix = ARGV[#deps+1] .. ':'
      local recovery_key = ARGV[#deps+2]

      if recovery_key and redis.call('exists', recovery_key) == 1 then
        return
      end

      for i, _key in ipairs(deps) do
        local key = prefix .. _key .. ':rw'
        local pending_key = key .. ':pending'
        local wanted_version = versions[i]
        local current_version = tonumber(redis.call('get', key)) or 0
        local queue_pending_version = true
        local token = nil

        while wanted_version and tonumber(wanted_version) <= current_version do
          queue_pending_version = false
          if token then redis.call('zrem', pending_key, token) end
          current_version = redis.call('incr', key)
          token, wanted_version = unpack(redis.call('zrange', pending_key, 0, 1, 'withscores'))
        end

        if queue_pending_version then
          token = redis.call('incr', 'promiscuous:pending_version_token')
          redis.call('zadd', pending_key, wanted_version, token)
        else
          redis.call('publish', key, current_version)
        end
      end

      if recovery_key then
        redis.call('set', recovery_key, 'done')
      end
    SCRIPT

    @@update_script_fast.eval(node, :keys => keys, :argv => argv)
  end

  def update_dependencies_on_node(node_with_deps, options={})
    # Read and write dependencies are not handled the same way:
    # * Read dependencies are just incremented (which allow parallelization).
    # * Write dependencies are set to be max(current_version, received_version).
    #   This allow the version bootstrapping process to be non-atomic.
    #   Publishers upgrade their reads dependencies to write dependencies
    #   during bootstrapping to permit the mechanism to function properly.

    # TODO Evaluate the performance hit of this heavy mechanism, and see if it's
    # worth optimizing it for the non-bootstrap case.

    if message.was_during_bootstrap?
      update_dependencies_non_atomic_bootstrap(node_with_deps[0], node_with_deps[1], options)
    else
      update_dependencies_fast(node_with_deps[0], node_with_deps[1], options)
    end
  end

  def update_dependencies_master(options={})
    update_dependencies_on_node(master_node_with_deps, options)
  end

  def update_dependencies_secondaries(options={})
    secondary_nodes_with_deps.map do |node_with_deps|
      Promiscuous::Redis::Async.enqueue_work_for(node_with_deps[0]) do
        update_dependencies_on_node(node_with_deps, options.merge(:with_recovery => true))
        after_secondary_update_hook
      end
    end.each(&:value)
  end

  def after_secondary_update_hook
    # Hook only used for testing
  end

  def cleanup_dependency_secondaries
    secondary_nodes_with_deps.map do |node, deps|
      Promiscuous::Redis::Async.enqueue_work_for(node) do
        node.del(recovery_key)
      end
    end.each(&:value)
  end

  def update_dependencies(options={})
    # With multi nodes, we have to do a 2pc for the lock recovery mechanism:
    # 1) We do the secondaries first, with a recovery token.
    # 2) Then we do the master.
    # 3) Then we cleanup the recovery token on secondaries.
    update_dependencies_secondaries(options)
    update_dependencies_master(options)
    cleanup_dependency_secondaries
  end

  def duplicate_message?
    instance_dep.version_pass2 < get_current_instance_version
  end

  LOCK_OPTIONS = { :timeout => 1.5.minute, # after 1.5 minute, we give up
                   :sleep   => 0.1,        # polling every 100ms.
                   :expire  => 1.minute }  # after one minute, we are considered dead

  def check_duplicate_and_update_dependencies
    if duplicate_message?
      # We happen to get a duplicate message, or we are recovering a dead
      # worker. During regular operations, we just need to cleanup the 2pc (from
      # the dead worker), and ack the message to rabbit.
      # TODO Test cleanup
      cleanup_dependency_secondaries

      # But, if the message was generated during bootstrap, we don't really know
      # if the other dependencies are up to date (because of the non-atomic
      # bootstrapping process), so we do the max() trick (see in update_dependencies_on_node).
      # Since such messages can come arbitrary late, we never really know if we
      # can assume regular operations, thus we always assume that such message
      # can originate from the bootstrapping period.
      # Note that we are not in the happy path. Such duplicates messages are
      # seldom: either (1) the publisher recovered a payload that didn't need
      # recovery, or (2) a subscriber worker died after # update_dependencies_master,
      # but before the message acking).
      update_dependencies if message.was_during_bootstrap?

      Promiscuous.debug "[receive] Skipping message (already processed) #{message}"
      return
    end

    yield

    update_dependencies
  end

  def with_instance_locked(&block)
    return yield unless message.has_dependencies?

    lock_options = LOCK_OPTIONS.merge(:node => master_node)
    mutex = Promiscuous::Redis::Mutex.new(instance_dep.key(:sub).to_s, lock_options)

    unless mutex.lock
      raise Promiscuous::Error::LockUnavailable.new(mutex.key)
    end

    begin
      yield
    ensure
      unless mutex.unlock
        # TODO Be safe in case we have a duplicate message and lost the lock on it
        raise "The subscriber lost the lock during its operation. It means that someone else\n"+
          "received a duplicate message, and we got screwed.\n"
      end
    end
  end

  def execute_operations
    instrument :app_callbacks do
      if defined?(ActiveRecord)
        ActiveRecord::Base.transaction { self.operations.each(&:execute) }
      else
        self.operations.each(&:execute)
      end
    end
  end

  def on_message
    with_instance_locked do
      if Promiscuous::Config.consistency == :causal && message.has_dependencies?
        self.check_duplicate_and_update_dependencies { execute_operations }
      else
        execute_operations
      end
    end
    message.ack
  end

  def operation_class
    Promiscuous::Subscriber::Operation::Regular
  end
end
