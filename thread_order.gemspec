Gem::Specification.new do |s|
  s.name        = 'thread_order'
  s.version     = '0.1.0'
  s.licenses    = ['MIT']
  s.summary     = "Test helper for ordering threaded code (does not depend on stdlib)"
  s.description = "Test helper for ordering threaded code (does not depend on stdlib)."
  s.authors     = ["Josh Cheek"]
  s.email       = 'josh.cheek@gmail.com'
  s.files       = `git ls-files`.split("\n")
  s.test_files  = `git ls-files -- spec/*`.split("\n")
  s.homepage    = 'https://github.com/JoshCheek/thread_order'
  s.add_development_dependency 'rspec', '~> 3.0'
end
