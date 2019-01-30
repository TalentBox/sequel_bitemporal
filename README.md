sequel_bitemporal
=================

[![Build Status](https://travis-ci.org/TalentBox/sequel_bitemporal.svg?branch=master)](https://travis-ci.org/TalentBox/sequel_bitemporal)

Bitemporal versioning for [Sequel].

Dependencies
------------

* Ruby >= 1.9.2
* gem "sequel", "~> 3.30.0"

Usage
-----

Declare bitemporality inside your model:

```ruby
class HotelPriceVersion < Sequel::Model
end

class HotelPrice < Sequel::Model
  plugin :bitemporal, version_class: HotelPriceVersion
end
```

You can now create a hotel price with bitemporal versions:

```ruby
price = HotelPrice.new
price.update_attributes price: 18
```

To show all versions:

```ruby
price.versions
```

To show current version:

```ruby
price.current_version
```

Look at the specs for more usage patterns.

Thanks
------

Thanks to Evgeniy L (@fiscal-cliff) for his contributions:
- skip plugin initialization process if versions table does not exist

Thanks to Ksenia Zalesnaya (@ksenia-zalesnaya) for her contributions:
- define setter methods for versioned columns

Thanks to Denis Kalesnikov (@DenisKem) for his contributions:
- add support for composite primary key
  [#8](https://github.com/TalentBox/sequel_bitemporal/pull/8)

Thanks to Olle Jonsson (@olleolleolle) for his contributions:
- update specs to work with RSpec: `config.disable_monkey_patching!`
  [#10](https://github.com/TalentBox/sequel_bitemporal/pull/10)
- update TravisCI matrix to include more Ruby versions
  [#11](https://github.com/TalentBox/sequel_bitemporal/pull/10)
- README improvements
  [#9](https://github.com/TalentBox/sequel_bitemporal/pull/9)
  [#12](https://github.com/TalentBox/sequel_bitemporal/pull/12)

License
-------

sequel_bitemporal is Copyright © 2011 TalentBox SA. It is free software, and may be redistributed under the terms specified in the LICENSE file.

[Sequel]: http://sequel.jeremyevans.net/
