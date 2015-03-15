require File.expand_path('../lib/thread_order/version', __FILE__)

Gem::Specification.new do |s|
  s.name        = 'thread_order'
  s.version     = ThreadOrder::VERSION
  s.licenses    = ['MIT']
  s.summary     = "Test helper for ordering threaded code"
  s.description = "Test helper for ordering threaded code (does not depend on gems or stdlib, tested on 1.8.7 - 2.2, rbx, jruby)."
  s.authors     = ["Josh Cheek"]
  s.email       = 'josh.cheek@gmail.com'
  s.files       = `git ls-files`.split("\n")
  s.test_files  = `git ls-files -- spec/*`.split("\n")
  s.homepage    = 'https://github.com/JoshCheek/thread_order'
  s.add_development_dependency 'rspec', '~> 3.0'
end
