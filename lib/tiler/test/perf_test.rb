$:.unshift File.absolute_path(File.dirname(__FILE__)) + '/../lib'

require 'pg'
require 'test/unit'
require 'yaml'
require 'changeset_tiler'

require './common'

class TilerTest < Test::Unit::TestCase
  include TestCommon

  def test_lots_of_tiles2
    setup_changeset_test(10822980)
    assert_equal(48043, @tiles.size)
  end

  def test_lots_of_tiles
    setup_changeset_test(8146963)
    assert_equal(2396, @tiles.size)
  end

  def test_lots_of_changes
    setup_changeset_test(8193200)
    assert_equal(111, @tiles.size)
  end

  def test_dateline
    setup_changeset_test(14483444)
  end

  def test_memory
    setup_changeset_test(3519977)
  end

  def test_oom
    setup_changeset_test(14806915)
  end
end
