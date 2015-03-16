require 'thread_order/mutex'

class ThreadOrder
  Error        = Class.new RuntimeError
  CannotResume = Class.new Error

  class ResumeThread
    # states
    Dead    = :dead
    Ran     = :ran
    Initial = :initial
    Errored = :errored

    # events
    None       = :none
    Run        = :run
    Sleep      = :sleep
    Exit       = :exit
    Error      = :error
    Unknown    = :unknown # ie 'aborting' where we don't yet know what's going on
    ParentDied = :parent_died

    module Any
      class << self
        def ==(*) true end
        alias === ==
      end
    end

    def self.call(thread, resume_event, to_watch, enqueue)
      new(thread, resume_event, to_watch, enqueue).call
    end

    def initialize(thread, resume_event, to_watch, enqueue)
      self.thread       = thread
      self.resume_event = resume_event
      self.to_watch     = to_watch
      self.enqueue      = enqueue
      self.state        = :initial
    end

    def call
      condition = [state, resume_event, get_event(to_watch)]
      case condition
      when [ Any     , None  , Error      ] then error!(to_watch)
      when [ Any     , None  , Any        ] then :noop
      when [ Any     , Any   , Unknown    ] then :noop
      when [ Any     , Any   , ParentDied ] then self.state = Dead
      when [ Errored , Any   , Any        ] then :noop
      when [ Dead    , Any   , Any        ] then :noop
      when [ Initial , Run   , Any        ] then run!
      when [ Initial , Sleep , Run        ] then :noop
      when [ Initial , Sleep , Sleep      ] then run!
      when [ Initial , Sleep , Exit       ] then never_slept!(to_watch)
      when [ Initial , Sleep , Error      ] then error!(to_watch)
      when [ Initial , Exit  , Run        ] then :noop
      when [ Initial , Exit  , Sleep      ] then :noop
      when [ Initial , Exit  , Exit       ] then run!
      when [ Initial , Exit  , Error      ] then error!(to_watch)
      when [ Ran     , Run   , Run        ] then :noop
      when [ Ran     , Run   , Sleep      ] then :noop
      when [ Ran     , Run   , Exit       ] then :noop
      when [ Ran     , Run   , Error      ] then error!(to_watch)
      when [ Ran     , Sleep , Run        ] then :noop
      when [ Ran     , Sleep , Sleep      ] then :noop
      when [ Ran     , Sleep , Exit       ] then :noop
      when [ Ran     , Sleep , Error      ] then error!(to_watch)
      when [ Ran     , Exit  , Run        ] then :noop
      when [ Ran     , Exit  , Sleep      ] then :noop
      when [ Ran     , Exit  , Exit       ] then :noop
      when [ Ran     , Exit  , Error      ] then error!(to_watch)
      else raise "Shouldn't be possible: #{condition}"
      end
      # continue watching for more events unless we are in a final state: errored or dead
      errored? || dead? || enqueue.call { call }
    end

    private

    attr_accessor :thread, :resume_event, :to_watch, :enqueue, :state

    def errored?
      state == Errored
    end

    def dead?
      state == Dead
    end

    def state
      return Dead unless thread.alive?
      @state
    end

    def get_event(to_watch)
      case to_watch.status
      when 'run'   then Run
      when 'sleep' then Sleep
      when nil     then Error
      when false   then Exit
      else              Unknown
      end
    end

    def run!
      self.state = Ran
      thread.wakeup
    end

    def error!(errored_thread)
      errored_thread.value
    rescue Exception => error
      thread.raise error
    end

    def never_slept!(to_watch)
      message = "#{to_watch[:thread_order_name]} exited instead of sleeping"
      thread.raise CannotResume.new(message)
    end
  end

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
    resume_event = extract_resume_event!(options)
    enqueue do
      Thread.new do
        child = Thread.current
        Thread.current[:thread_order_name] = name
        body = sync {
          @threads << child
          @bodies.fetch(name)
        }
        wait_until { parent.stop? }
        enqueue do
          ResumeThread.call parent,
                            resume_event,
                            child,
                            method(:enqueue)
        end
        body.call parent
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
