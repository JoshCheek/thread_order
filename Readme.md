[![Build Status](https://travis-ci.org/JoshCheek/thread_order.svg)](https://travis-ci.org/JoshCheek/thread_order)

ThreadOrder
===========

A tool for testing threaded code.
Its purpose is to enable reasoning about thread order.

* Tested on 1.8.7 - 2.2, JRuby, Rbx
* It has no external dependencies
* It does not depend on the stdlib.

Example
-------

```ruby
# A somewhat contrived class we're going to test.
class MyQueue
  attr_reader :array

  def initialize
    @array, @mutex = [], Mutex.new
  end

  def enqueue
    @mutex.synchronize { @array << yield }
  end
end



require 'rspec/autorun'
require 'thread_order'

RSpec.describe MyQueue do
  let(:queue) { described_class.new }
  let(:order) { ThreadOrder.new }
  after { order.apocalypse! } # ensure everything gets cleaned up (technically redundant for our one example, but it's a good practice)

  it 'is threadsafe on enqueue' do
    # will execute in a thread, can be invoked by name
    order.declare :concurrent_enqueue do
      queue.enqueue { :concurrent }
    end

    # this enqueue will block until the mutex puts the other one to sleep
    queue.enqueue do
      order.pass_to :concurrent_enqueue, resume_on: :sleep
      :main
    end

    order.apocalypse! :join # wait for all its threads to finish (often unnecessary)
    expect(queue.array).to eq [:main, :concurrent]
  end
end

# >> MyQueue
# >>   is threadsafe on enqueue
# >>
# >> Finished in 0.00131 seconds (files took 0.08687 seconds to load)
# >> 1 example, 0 failures
```
