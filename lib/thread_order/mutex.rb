# On > 1.9, this is in core.
# On 1.8.7, it's in the stdlib.
# We don't want to load the stdlib, b/c this is a test tool, and can affect the test environment,
# causing tests to pass where they should fail.
#
# So we're transcribing it here, from.
# It is based on this implementation: https://github.com/ruby/ruby/blob/v1_8_7_374/lib/thread.rb#L56
# If it's not already defined. Some methods we don't need are deleted.
# Anything I don't understand is left in.
class ThreadOrder
  Mutex = if defined? ::Mutex
    ::Mutex
  else
    Class.new do
      def initialize
        @waiting = []
        @locked = false;
        @waiting.taint		# enable tainted comunication
        self.taint
      end

      def lock
        while (Thread.critical = true; @locked)
          @waiting.push Thread.current
          Thread.stop
        end
        @locked = true
        Thread.critical = false
        self
      end

      def unlock
        return unless @locked
        Thread.critical = true
        @locked = false
        begin
          t = @waiting.shift
          t.wakeup if t
        rescue ThreadError
          retry
        end
        Thread.critical = false
        begin
          t.run if t
        rescue ThreadError
        end
        self
      end

      def synchronize
        lock
        begin
          yield
        ensure
          unlock
        end
      end
    end
  end
end
