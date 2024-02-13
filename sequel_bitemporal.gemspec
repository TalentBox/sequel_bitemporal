# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)

Gem::Specification.new do |s|
  s.name        = "sequel_bitemporal"
  s.version     = "0.11.1"
  s.authors     = ["Joseph HALTER", "Jonathan TRON"]
  s.email       = ["joseph.halter@thetalentbox.com", "jonathan.tron@thetalentbox.com"]
  s.homepage    = "https://github.com/TalentBox/sequel_bitemporal"
  s.summary     = "Bitemporal versioning for sequel."
  s.description = "Bitemporal versioning for sequel, fully tested."
  s.license     = "MIT"

  s.files         = `git ls-files`.split("\n").reject{|f| f.start_with?(".github") || f.start_with?("ci") }
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  s.add_runtime_dependency "sequel", ">= 4.0", "< 6.0"

  s.add_development_dependency "rspec", "~> 3.13.0"
  s.add_development_dependency "timecop"
  s.add_development_dependency "rake"
end
