initial_loaded_features = $LOADED_FEATURES.dup.freeze

require 'thread_order'

RSpec.describe ThreadOrder do
  let(:order) { described_class.new }
  after { order.apocalypse! }

  it 'allows thread behaviour to be declared and run by name' do
    seen = []
    order.declare(:third)  { seen << :third }
    order.declare(:first)  { seen << :first;  order.pass_to :second, :resume_on => :exit }
    order.declare(:second) { seen << :second; order.pass_to :third,  :resume_on => :exit }
    expect(seen).to eq []
    order.pass_to :first, :resume_on => :exit
    expect(seen).to eq [:first, :second, :third]
  end

  it 'sleeps the thread which passed' do
    main_thread = Thread.current
    order.declare(:thread) { :noop until main_thread.status == 'sleep' }
    order.pass_to :thread, :resume_on => :exit # passes if it doesn't lock up
  end

  context 'resume events' do
    def self.test_status(name, statuses, *args, &threadmaker)
      it "can resume the thread when the called thread enters #{name}", *args do
        thread   = instance_eval(&threadmaker)
        statuses = Array statuses
        expect(statuses).to include thread.status
      end
    end

    test_status ':run', 'run' do
      order.declare(:t) { loop { 1 } }
      order.pass_to :t, :resume_on => :run
    end

    test_status ':sleep', 'sleep' do
      order.declare(:t) { sleep }
      order.pass_to :t, :resume_on => :sleep
    end

    # can't reproduce 'dead', but apparently JRuby 1.7.19 returned
    # this on CI https://travis-ci.org/rspec/rspec-core/jobs/51933739
    test_status ':exit', [false, 'aborting', 'dead'] do
      order.declare(:t) { Thread.exit }
      order.pass_to :t, :resume_on => :exit
    end

    it 'passes the parent to the thread' do
      parent = nil
      order.declare(:t) { |p| parent = p }
      order.pass_to :t, :resume_on => :exit
      expect(parent).to eq Thread.current
    end

    it 'sleeps until woken if it does not provide a :resume_on key' do
      order.declare(:t) { |parent|
        order.enqueue {
          expect(parent.status).to eq 'sleep'
          parent.wakeup
        }
      }
      order.pass_to :t
    end

    it 'blows up if it is waiting on another thread to sleep and that thread exits instead' do
      expect {
        order.declare(:t1) { :exits_instead_of_sleeping }
        order.pass_to :t1, :resume_on => :sleep
      }.to raise_error ThreadOrder::CannotResume, /t1 exited/
    end
  end

  describe 'error types' do
    it 'has a toplevel lib error: ThreadOrder::Error which is a RuntimeError' do
      expect(ThreadOrder::Error.superclass).to eq RuntimeError
    end

    specify 'all behavioural errors it raises inherit from ThreadOrder::Error' do
      expect(ThreadOrder::CannotResume.superclass).to eq ThreadOrder::Error
    end
  end

  describe 'errors in children' do
    specify 'are raised in the child' do
      order.declare(:err) { sleep }
      child = order.pass_to :err, :resume_on => :sleep
      begin
        child.raise RuntimeError.new('the roof')
        sleep
      rescue RuntimeError => e
        expect(e.message).to eq 'the roof'
      else
        raise 'expected an error'
      end
    end

    specify 'are raised in the parent' do
      expect {
        order.declare(:err) { raise Exception, "to the rules" }
        order.pass_to :err, :resume_on => :exit
        sleep
      }.to raise_error Exception, 'to the rules'
    end

    specify 'even if the parent is asleep' do
      order.declare(:err) { sleep }
      parent = Thread.current
      child  = order.pass_to :err, :resume_on => :sleep
      expect {
        order.enqueue {
          expect(parent.status).to eq 'sleep'
          child.raise Exception.new 'to the rules'
        }
        sleep
      }.to raise_error Exception, 'to the rules'
    end
  end

  it 'knows which thread is running' do
    thread_names = []
    order.declare(:a) {
      thread_names << order.current
      order.pass_to :b, :resume_on => :exit
      thread_names << order.current
    }
    order.declare(:b) {
      thread_names << order.current
    }
    order.pass_to :a, :resume_on => :exit
    expect(thread_names.map(&:to_s).sort).to eq ['a', 'a', 'b']
  end

  it 'returns nil when asked for the current thread by one it did not define' do
    thread_names = []
    order.declare(:a) {
      thread_names << order.current
      Thread.new { thread_names << order.current }.join
    }
    expect(order.current).to eq nil
    order.pass_to :a, :resume_on => :exit
    expect(thread_names).to eq [:a, nil]
  end

  define_method :not_loaded! do |filename|
    # newer versions of Ruby require thread.rb somewhere, so if it was required
    # before any of our code was required, then don't bother with the assertion
    # there's no obvious way to deal with it, and it wasn't us who required it
    next if initial_loaded_features.include? filename
    loaded_filenames = $LOADED_FEATURES.map { |filepath| File.basename filepath }
    expect(loaded_filenames).to_not include filename
  end

  it 'is implemented without depending on the stdlib' do
    begin
      not_loaded! 'monitor.rb'
      not_loaded! 'thread.rb'
      not_loaded! 'thread.bundle'
    rescue RSpec::Expectations::ExpectationNotMetError
      pending if defined?(RUBY_ENGINE) && RUBY_ENGINE == 'jruby' # somehow this still gets loaded in some JRubies
      raise
    end
  end

  describe 'incorrect interface usage' do
    it 'raises ArgumentError when told to resume on an unknown status' do
      order.declare(:t) { }
      expect { order.pass_to :t, :resume_on => :bad_status }.
        to raise_error(ArgumentError, /bad_status/)
    end

    it 'raises an ArgumentError when you give it unknown keys (ie you spelled resume_on wrong)' do
      order.declare(:t) { }
      expect { order.pass_to :t, :bad_key => :t }.
        to raise_error(ArgumentError, /bad_key/)
    end
  end

  describe 'join_all' do
    it 'joins with all the child threads' do
      parent   = Thread.current
      children = []

      order.declare(:t1) do
        order.pass_to :t2, :resume_on => :run
        children << Thread.current
      end

      order.declare(:t2) do
        children << Thread.current
      end

      order.pass_to :t1, :resume_on => :run
      order.join_all
      statuses = children.map { |th| th.status }
      expect(statuses).to eq [false, false] # none are alive
    end
  end

  describe 'synchronization' do
    it 'allows any thread to enqueue work' do
      seen = []

      order.declare :enqueueing do |parent|
        order.enqueue do
          order.enqueue { seen << 2 }
          order.enqueue { seen << 3 }
          order.enqueue { parent.wakeup }
          seen << 1
        end
      end

      order.pass_to :enqueueing
      expect(seen).to eq [1, 2, 3]
    end

    it 'allows a thread to put itself to sleep until some condition is met' do
      i = 0
      increment = lambda do
        i += 1
        order.enqueue(&increment)
      end
      increment.call
      order.wait_until { i > 20_000 } # 100k is too slow on 1.8.7, but 10k is too fast on 2.2.0
      expect(i).to be > 20_000
    end
  end

  describe 'apocalypse!' do
    it 'kills threads that are still alive' do
      order.declare(:t) { sleep }
      child = order.pass_to :t, :resume_on => :sleep
      expect(child).to receive(:kill).and_call_original
      expect(child).to_not receive(:join)
      order.apocalypse!
    end

    it 'can be overridden to call a different method than kill' do
      # for some reason, the mock calling original join doesn't work
      order.declare(:t) { sleep }
      child = order.pass_to :t, :resume_on => :run
      expect(child).to_not receive(:kill)
      joiner = Thread.new { order.apocalypse! :join }
      Thread.pass until child.status == 'sleep' # can't use wait_until b/c that occurs within the worker, which is apocalypsizing
      child.wakeup
      joiner.join
    end

    it 'can call apocalypse! any number of times without harm' do
      order.declare(:t) { sleep }
      order.pass_to :t, :resume_on => :sleep
      100.times { order.apocalypse! }
    end

    it 'does not enqueue events after the apocalypse' do
      order.apocalypse!
      thread = Thread.current
      order.enqueue { thread.raise "Should not happen" }
    end
  end
end
