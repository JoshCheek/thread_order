require 'thread_order/mutex'

class ThreadOrder
  Error        = Class.new RuntimeError
  CannotResume = Class.new Error

  # Note that this must tbe initialized in a threadsafe environment
  # Otherwise, syncing may occur before the mutex is set
  def initialize
    @mutex   = Mutex.new
    @bodies  = {}
    @threads = []
    @queue   = [] # Queue is in stdlib, but half the purpose of this lib is to avoid such deps, so using an array in a Mutex
    @worker  = Thread.new do
      Thread.current.abort_on_exception = true
      Thread.current[:thread_order_name] = :internal_worker
      loop { break if :shutdown == work() }
    end
  end

  def declare(name, &block)
    sync { @bodies[name] = block }
  end

  def current
    Thread.current[:thread_order_name]
  end

  def pass_to(name, options={})
    child        = nil
    parent       = Thread.current
    resume_event = extract_resume_event!(options)
    enqueue do
      sync do
        @threads << Thread.new {
          child = Thread.current
          child[:thread_order_name] = name
          body = sync { @bodies.fetch(name) }
          wait_until { parent.stop? }
          :run == resume_event && parent.wakeup
          wake_on_sleep = lambda do
            child.status == 'sleep' ? parent.wakeup :
            child.status == nil     ? :noop         :
            child.status == false   ? parent.raise(CannotResume.new "#{name} exited instead of sleeping") :
                                      enqueue(&wake_on_sleep)
          end
          :sleep == resume_event && enqueue(&wake_on_sleep)
          begin
            body.call parent
          rescue Exception => e
            enqueue { parent.raise e }
            raise
          ensure
            :exit == resume_event && enqueue { parent.wakeup }
          end
        }
      end
    end
    sleep
    child
  end

  def join_all
    sync { @threads }.each { |th| th.join }
  end

  def apocalypse!(thread_method=:kill)
    enqueue do
      @threads.each(&thread_method)
      @queue.clear
      :shutdown
    end
    @worker.join
  end

  def enqueue(&block)
    sync { @queue << block if @worker.alive? }
  end

  def wait_until(&condition)
    return if condition.call
    thread = Thread.current
    wake_when_true = lambda do
      if thread.stop? && condition.call
        thread.wakeup
      else
        enqueue(&wake_when_true)
      end
    end
    enqueue(&wake_when_true)
    sleep
  end

  private

  def sync(&block)
    @mutex.synchronize(&block)
  end

  def work
    task = sync { @queue.shift }
    task ||= lambda { Thread.pass }
    task.call
  end

  def extract_resume_event!(options)
    resume_on = options.delete :resume_on
    options.any? &&
      raise(ArgumentError, "Unknown options: #{options.inspect}")
    resume_on && ![:run, :exit, :sleep, nil].include?(resume_on) and
      raise(ArgumentError, "Unknown status: #{resume_on.inspect}")
    resume_on || :none
  end
end
