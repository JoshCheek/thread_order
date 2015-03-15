require 'thread_order/mutex'

class ThreadOrder
  Error        = Class.new RuntimeError
  CannotResume = Class.new Error

  class ResumeThread
    def initialize(thread, resume_event)
      self.thread       = thread
      self.resume_event = resume_event
      self.resumed      = false
    end

    def run?
      :run == resume_event
    end

    def sleep?
      :sleep == resume_event
    end

    def exit?
      :exit == resume_event
    end

    def resumed?
      resumed
    end

    def watch(to_watch, enqueue)
      return if resumed?    # no op, job was already done
      return resume if run? # calling this method implies to_watch is running

      case to_watch.status
      when 'sleep'
        sleep? && resume
      when nil
        # raise the error from the child in in the parent
        begin
          to_watch.value
        rescue Exception => e
          thread.raise e
        end
      when false
        if exit?
          resume
        elsif sleep?
          message = "#{to_watch[:thread_order_name]} exited instead of sleeping"
          thread.raise CannotResume.new(message)
        end
      end

      resumed? || enqueue.call { watch to_watch, enqueue }
    end

    private

    attr_accessor :thread, :resume_event, :resumed

    def resume
      return if resumed?
      self.resumed = true
      thread.wakeup
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
    child  = nil
    parent = Thread.current
    resume = ResumeThread.new parent, extract_resume_event!(options)

    enqueue do
      Thread.new do
        child = Thread.current
        Thread.current[:thread_order_name] = name
        body = sync {
          @threads << child
          @bodies.fetch(name)
        }
        wait_until { parent.stop? }
        resume.watch child, method(:enqueue)
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
    resume_on
  end
end
