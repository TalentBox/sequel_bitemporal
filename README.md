sequel_bitemporal
=================

[![Build Status](https://travis-ci.org/TalentBox/sequel_bitemporal.png?branch=master)](https://travis-ci.org/TalentBox/sequel_bitemporal)

Bitemporal versioning for sequel.

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

License
-------

sequel_bitemporal is Copyright © 2011 TalentBox SA. It is free software, and may be redistributed under the terms specified in the LICENSE file.
