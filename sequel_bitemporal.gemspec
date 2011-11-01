# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)

Gem::Specification.new do |s|
  s.name        = "sequel_bitemporal"
  s.version     = "0.1.0"
  s.authors     = ["Joseph HALTER"]
  s.email       = ["joseph.halter@thetalentbox.com"]
  s.description = "Bitemporal versioning for sequel."

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  s.add_development_dependency "sqlite3"
  s.add_development_dependency "rspec"
  s.add_development_dependency "timecop"
  s.add_runtime_dependency "sequel"
end