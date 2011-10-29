sequel_bitemporal
=================

Bitemporal versioning for sequel.

Dependencies
------------

* Ruby >= 1.9.2
* gem "sequel"

Usage
-----

* Declare bitemporality inside your model:

        class HotelPrice < Sequel::Model
          plugin :bitemporal
        end

Build Status
------------

[![Build Status](http://travis-ci.org/TalentBox/sequel_bitemporal.png)](http://travis-ci.org/TalentBox/sequel_bitemporal)

License
-------

sequel_bitemporal is Copyright © 2011 TalentBox SA. It is free software, and may be redistributed under the terms specified in the LICENSE file.