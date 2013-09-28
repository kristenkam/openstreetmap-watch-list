require 'test_helper'

class ChangesetApiControllerTest < ActionController::TestCase
  test "Retrieving a JSON tile (simple node tags change)" do
    reset_db
    load_changeset(12917265)
    get(:changesets_tile_json, {:x => 36234, :y => 22917, :zoom => 16})
    changesets = assigns['changesets']
    verify_json_changesets(changesets)
    assert_equal(1, changesets.size)
    json = JSON[@response.body]
    assert_equal(1, json.size)
    verify_json_12917265(json[0])
  end

  test "Retrieving a JSON tile (multiple changes on one tile)" do
    reset_db
    load_changeset(12917265)
    load_changeset(12456522)
    get(:changesets_tile_json, {:x => 36234, :y => 22917, :zoom => 16})
    changesets = assigns['changesets']
    verify_json_changesets(changesets)
    assert_equal(2, changesets.size)
    json = JSON[@response.body]
    assert_equal(2, json.size)
    verify_json_12917265(json[0])
  end

  test "Retrieving a JSON tile range" do
    reset_db
    load_changeset(12917265)
    load_changeset(12456522)
    get(:changesets_tilerange_json, {:x1 => 36230, :y1 => 22910, :x2 => 36243, :y2 => 22927, :zoom => 16})
    changesets = assigns['changesets']
    verify_json_changesets(changesets)
    assert_equal(2, changesets.size)
    json = JSON[@response.body]
    assert_equal(2, json.size)
    verify_json_12917265(json[0])
    verify_json_12456522(json[1])
  end

  test "Retrieving a GeoJSON tile (multiple changes on one tile)" do
    reset_db
    load_changeset(12917265)
    load_changeset(12456522)
    get(:changesets_tile_geojson, {:x => 36234, :y => 22917, :zoom => 16})
    changesets = assigns['changesets']
    verify_json_changesets(changesets)
    assert_equal(2, changesets.size)
    json = JSON[@response.body]
    assert_equal(2, json.size)
    verify_geojson_12917265(json['features'][0])
  end

  test "Retrieving a GeoJSON tile range" do
    reset_db
    load_changeset(12917265)
    load_changeset(12456522)
    get(:changesets_tilerange_geojson, {:x1 => 36230, :y1 => 22910, :x2 => 36243, :y2 => 22927, :zoom => 16})
    changesets = assigns['changesets']
    verify_json_changesets(changesets)
    assert_equal(2, changesets.size)
    json = JSON[@response.body]
    assert_equal(2, json.size)
    verify_geojson_12917265(json['features'][0])
  end

  test "Retrieving a GeoJSON tile range (check geometry aggregation)" do
    reset_db
    load_changeset(12917265)
    load_changeset(12456522)
    load_changeset(13275351)
    get(:changesets_tilerange_geojson, {:x1 => 36156, :y1 => 22257, :x2 => 36161, :y2 => 22259, :zoom => 16})
    changesets = assigns['changesets']
    #assert_equal(2, changesets[0].geom_geojson.size)
    verify_json_changesets(changesets)
    assert_equal(1, changesets.size)
    json = JSON[@response.body]
    assert_equal(1, json['features'].size)
    p json['features'][0]['properties']['changes']
    assert_equal(2, json['features'][0]['properties']['changes'].size)
    assert_equal(2, json['features'][0]['features'].size)
#    assert_equal(1, json['features'][0]['features'][0]['features'].size)
    assert(@response.body.include?('49.882496'))
    assert(@response.body.include?('49.885183600000005'))
    assert(@response.body.include?('18.6273193359375'))
  end

  # Does some generic checks.
  def verify_json_changesets(changesets)
    for changeset in changesets
      assert(changeset.created_at <= changeset.closed_at)
      assert(changeset.created_at < Date.parse('2012-11-02'))
      assert(changeset.created_at > Date.parse('2011-11-02'))
      assert_equal(false, changeset.open)
      assert_equal('Hash', changeset.tags.class.name)
      assert(changeset.tags.size > 0)
      assert_equal('Fixnum', changeset.id.class.name)
      assert_equal('Fixnum', changeset.user_id.class.name)
    end
  end

  def verify_json_12917265(json)
    assert(!json.include?('geojson'))
    assert(json.include?('changes'))
    assert_equal(1, json['changes'].size)
    assert_equal('yes', json['changes'][0]['tags']['capital'])
    assert_equal('1702297', json['changes'][0]['tags']['population'])
    assert_equal('1702297', json['changes'][0]['prev_tags']['population'])
    assert_equal('2', json['changes'][0]['tags']['admin_level'])
    assert_equal(nil, json['changes'][0]['prev_tags']['admin_level'])
  end

  def verify_geojson_12917265(json)
    assert(json.include?('type'))
    assert_equal(1, json['features'].size)
    assert_equal(12917265, json['properties']['id'])
    assert(json['features'][0]['features'][0].include?('geometry'))
    assert(json['features'][0].include?('properties'))
    assert_equal(json['properties']['changes'][0]['id'], json['features'][0]['properties']['change_id'])
    assert_equal('yes', json['properties']['changes'][0]['tags']['capital'])
    assert_equal('1702297', json['properties']['changes'][0]['tags']['population'])
    assert_equal('1702297', json['properties']['changes'][0]['prev_tags']['population'])
    assert_equal('2', json['properties']['changes'][0]['tags']['admin_level'])
    assert_equal(nil, json['properties']['changes'][0]['prev_tags']['admin_level'])
  end

  def verify_json_12456522(json)
    assert(!json.include?('geojson'))
    assert(json.include?('changes'))
    assert_equal(12, json['changes'].size)
  end

  def load_changeset(changeset_id)
    system('psql -a -d owl_test -c "\copy changesets from ' + Rails.root.to_s + '/../testdata/' + changeset_id.to_s + '-changeset.csv"')
    system('psql -a -d owl_test -c "\copy nodes from ' + Rails.root.to_s + '/../testdata/' + changeset_id.to_s + '-nodes.csv"')
    system('psql -a -d owl_test -c "\copy ways from ' + Rails.root.to_s + '/../testdata/' + changeset_id.to_s + '-ways.csv"')

    tiler = Tiler::ChangesetTiler.new(conn = PGconn.open(:dbname => 'owl_test', :user => 'ppawel'))
    tiler.generate(16, changeset_id)
  end

  def reset_db
    system('psql -a -d owl_test -c "TRUNCATE changesets; TRUNCATE changeset_tiles; TRUNCATE nodes; TRUNCATE ways;"')
  end
end
