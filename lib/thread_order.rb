require 'thread_order/mutex'

class ThreadOrder
  Error        = Class.new RuntimeError
  CannotResume = Class.new Error

  def initialize
    @bodies  = {}
    @threads = []
    @queue   = [] # Queue is in stdlib, but half the purpose of this lib is to avoid such deps, so using an array in a Mutex
    @mutex   = Mutex.new
    @worker  = Thread.new { loop { work } }
    @worker.abort_on_exception = true
  end

  def declare(name, &block)
    @bodies[name] = block
  end

  def current
    Thread.current[:thread_order_name]
  end

  def pass_to(name, options)
    parent       = Thread.current
    child        = nil
    resume_event = extract_resume_event! options
    resume_if    = lambda { |event| event == resume_event && parent.wakeup }

    enqueue do
      child = Thread.new do
        enqueue { @threads << child }
        :sleep == resume_event && enqueue { watch_for_sleep(child, parent) }
        begin
          resume_if.call :run
          Thread.current[:thread_order_name] = name
          @bodies.fetch(name).call
        rescue Exception => error
          enqueue { parent.raise error }
          raise
        ensure
          enqueue { resume_if.call :exit }
        end
      end
    end

    sleep
    child
  end

  def apocalypse!(thread_method=:kill)
    enqueue do
      @threads.each(&thread_method)
      @queue.clear
      @worker.kill # seppuku!
    end
    @worker.join
  end

  private

  def sync(&block)
    @mutex.synchronize(&block)
  end

  def enqueue(&block)
    sync { @queue << block }
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
    resume_on && ![:run, :exit, :sleep].include?(resume_on) and
      raise(ArgumentError, "Unknown status: #{resume_on.inspect}")
    resume_on
  end

  def watch_for_sleep(thread, to_wake)
    if thread.status == false
      to_wake.raise CannotResume.new("#{thread[:thread_order_name]} exited instead of sleeping")
    elsif thread.status == nil
      # the thread errored -- this will raise an error in the main thread
      # so we will simply exit
    elsif thread.status == 'sleep'
      to_wake.wakeup
    else
      enqueue { watch_for_sleep(thread, to_wake) }
    end
  end
end
