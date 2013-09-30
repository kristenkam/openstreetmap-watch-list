NOTE: Code rewrite is currently in progress, things probably don't work as described!

        OWL: OpenStreetMap Watch List
        =============================

OWL is a service that allows monitoring and analyzing changes in OpenStreetMap data.

Wiki: http://wiki.openstreetmap.org/wiki/OWL
Installation: http://wiki.openstreetmap.org/wiki/OWL/Installation
API: http://wiki.openstreetmap.org/wiki/OWL/API

Contents:
---------

osmosis-plugin/
  Git submodule containing a plugin for Osmosis that takes care of
  populating the database.

  See the `INSTALL.md` file for installation and usage instructions.

rails/
  A Rails project which hosts the API which allows applications
  to interface with OWL.

scripts/
  Miscellaneous scripts to keep bits of the database up-to-date,
  like the OWL changeset details scraper.

sql/
  SQL scripts for setting up a database with OWL schema.

tiler/
  A tool for creating geometry tiles that are served by the API.
