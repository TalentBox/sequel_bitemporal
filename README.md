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

* Declare bitemporality inside your model:

        class HotelPriceVersion < Sequel::Model
        end

        class HotelPrice < Sequel::Model
          plugin :bitemporal, version_class: HotelPriceVersion
        end

* You can now create a hotel price with bitemporal versions:

        price = HotelPrice.new
        price.update_attributes price: 18

* To show all versions:

        price.versions

* To get current version:

        price.current_version

* Look at the specs for more usage patterns.

Thanks
------

Thanks to Evgeniy L (@fiscal-cliff) for his contributions:
- skip plugin initialization process if versions table does not exist

Thanks to Ksenia Zalesnaya (@ksenia-zalesnaya) for her contributions:
- define setter methods for versioned columns

Thanks to Denis Kalesnikov (@DenisKem) for his contributions:
- allow composite primary key

License
-------

sequel_bitemporal is Copyright © 2011 TalentBox SA. It is free software, and may be redistributed under the terms specified in the LICENSE file.

[Sequel]: http://sequel.jeremyevans.net/
