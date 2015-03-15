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
      loop { work } # work until killed
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
    resume_event = extract_resume_event! options

    enqueue do
      Thread.new do
        child = Thread.current
        Thread.current[:thread_order_name] = name
        enqueue { @threads << child }
        wait_until { parent.stop? }
        :run == resume_event && parent.wakeup
        begin
          body = sync { @bodies.fetch(name) }
          :sleep == resume_event && enqueue { wake_on_sleep child, parent }
          body.call parent
        rescue Exception => error
          enqueue { parent.raise error }
          raise
        ensure
          :exit == resume_event && enqueue { parent.wakeup }
        end
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
      @worker.kill # seppuku!
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
      (thread.stop? && condition.call) ? thread.wakeup : enqueue(&wake_when_true)
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
    resume_on
  end

  def wake_on_sleep(to_watch, to_wake)
    if to_watch.status == false
      to_wake.raise CannotResume.new("#{to_watch[:thread_order_name]} exited instead of sleeping")
    elsif to_watch.status == nil
      # to_watch errored -- this will raise an error in the main thread
      # so we will simply exit
    elsif to_watch.status == 'sleep'
      to_wake.wakeup
    else
      enqueue { wake_on_sleep to_watch, to_wake }
    end
  end
end
