##
# Implements OWL API operations.
# See: http://wiki.openstreetmap.org/wiki/OWL_(OpenStreetMap_Watch_List)/API
#
class ApiController < ApplicationController
  include ApiHelper

  def changesets_tile_json
    @changesets = find_changesets_by_tile('json')
    render :json => JSON[@changesets], :callback => params[:callback]
  end

  def changesets_tile_geojson
    @changesets = find_changesets_by_tile('geojson')
    render :json => changesets_to_geojson(@changesets, @x, @y, @zoom), :callback => params[:callback]
  end

  def changesets_tile_atom
    @changesets = find_changesets_by_tile('atom')
    render :template => 'api/changesets'
  end

  def changesets_tilerange_json
    @changesets = find_changesets_by_range('json')
    render :json => JSON[@changesets], :callback => params[:callback]
  end

  def changesets_tilerange_geojson
    @changesets = find_changesets_by_range('geojson')
    render :json => changesets_to_geojson(@changesets, @x, @y, @zoom), :callback => params[:callback]
  end

  def changesets_tilerange_atom
    @changesets = find_changesets_by_range('atom')
    render :template => 'api/changesets'
  end

  def summary_tile
    @summary = generate_summary_tile || {'num_changesets' => 0, 'latest_changeset' => nil}
    render :json => @summary.as_json, :callback => params[:callback]
  end

  def summary_tilerange
    @summary_list = generate_summary_tilerange || [{'num_changesets' => 0, 'latest_changeset' => nil}]
    render :json => @summary_list.as_json, :callback => params[:callback]
  end

private
  def find_changesets_by_tile(format)
    @x, @y, @zoom = get_xyz(params)
    rows = ActiveRecord::Base.connection.select_all("
      SELECT cs.*,
        #{format == 'geojson' ? '(SELECT array_agg(ST_AsGeoJSON(g)) FROM unnest(t.geom) AS g) AS geojson,' : ''}
        (SELECT ST_Extent(g) FROM unnest(t.geom) AS g)::text AS tile_bbox,
        cs.bbox::box2d::text AS total_bbox,
        (SELECT array_agg(g) FROM unnest(t.changes) AS g) AS changes
      FROM tiles t
      INNER JOIN changesets cs ON (cs.id = t.changeset_id)
      WHERE x = #{@x} AND y = #{@y} AND zoom = #{@zoom}
      #{get_timelimit_sql(params)}
      GROUP BY cs.id, t.geom, t.changes
      ORDER BY cs.created_at DESC
      #{get_limit_sql(params)}")
    load_changes(rows)
    rows
  end

  def find_changesets_by_range(format)
    @zoom, @x1, @y1, @x2, @y2 = get_range(params)
    rows = ActiveRecord::Base.connection.select_all("
      SELECT
        changeset_id,
        MAX(tstamp) AS max_tstamp,
        array_agg((SELECT ST_Extent(x.geom) FROM (SELECT unnest(t.geom)::box2d AS geom) x)::text) AS tile_bboxes,
        cs.*,
        cs.bbox AS total_bbox,
        array_accum(t.changes) AS changes
      FROM tiles t
      INNER JOIN changesets cs ON (cs.id = t.changeset_id)
      WHERE x >= #{@x1} AND x <= #{@x2} AND y >= #{@y1} AND y <= #{@y2} AND zoom = #{@zoom}
        AND changeset_id IN (
          SELECT DISTINCT changeset_id
          FROM tiles
          WHERE x >= #{@x1} AND x <= #{@x2} AND y >= #{@y1} AND y <= #{@y2} AND zoom = #{@zoom}
          #{get_timelimit_sql(params)}
          ORDER BY changeset_id DESC
          #{get_limit_sql(params)}
        )
      GROUP BY changeset_id, cs.id
      ORDER BY created_at DESC")
    load_changes(rows)
    rows
  end

  def generate_summary_tile
    @x, @y, @zoom = get_xyz(params)
    rows = ActiveRecord::Base.connection.select_all("WITH agg AS (
        SELECT changeset_id, MAX(tstamp) AS max_tstamp
        FROM tiles
        WHERE x = #{@x} AND y = #{@y} AND zoom = #{@zoom}
        #{get_timelimit_sql(params)}
        GROUP BY changeset_id
      ) SELECT * FROM
      (SELECT COUNT(*) AS num_changesets FROM agg) a,
      (SELECT changeset_id FROM agg ORDER BY max_tstamp DESC NULLS LAST LIMIT 1) b")
    return if rows.empty?
    row = rows[0]
    summary_tile = {'num_changesets' => row['num_changesets']}
    summary_tile['latest_changeset'] =
        ActiveRecord::Base.connection.select_all("SELECT *, NULL AS tile_bbox,
            bbox::box2d::text AS total_bbox
            FROM changesets WHERE id = #{row['changeset_id']}")[0]
    summary_tile
  end

  def generate_summary_tilerange
    @zoom, @x1, @y1, @x2, @y2 = get_range(params)
    rows = ActiveRecord::Base.connection.execute("
        SELECT x, y, COUNT(*) AS num_changesets, MAX(tstamp) AS max_tstamp, MAX(changeset_id) AS changeset_id
        FROM tiles
        INNER JOIN changesets cs ON (cs.id = changeset_id)
        WHERE x >= #{@x1} AND x <= #{@x2} AND y >= #{@y1} AND y <= #{@y2} AND zoom = #{@zoom}
        #{get_timelimit_sql(params)}
        GROUP BY x, y").to_a
    rows.to_a
  end

  def load_changes(changesets)
    change_ids = Set.new
    changesets.each {|changeset| change_ids.merge(pg_string_to_array(changeset['changes']).map(&:to_i))}
    changes = {}

    for change in ActiveRecord::Base.connection.select_all("SELECT * FROM changes WHERE id IN
        (#{change_ids.to_a.join(',')})")
      change['tags'] = eval("{#{change['tags']}}")
      change['prev_tags'] = eval("{#{change['prev_tags']}}") if change['prev_tags']
      changes[change['id'].to_i] = change
    end

    for changeset in changesets
      changeset['changes'] = pg_string_to_array(changeset['changes']).uniq.collect {|change_id| changes[change_id.to_i]}
    end
  end

  def changesets_to_geojson(changesets, x, y, zoom)
    geojson = { "type" => "FeatureCollection", "features" => []}
    for changeset in changesets
      changeset_geojson = {"type" => "FeatureCollection", "properties" => changeset.as_json, "features" => []}
      if changeset.geojson
        for change_geojson in pg_string_to_array(changeset.geojson)
          next if change_geojson.nil?
          feature = {"type" => "Feature", "id" => "#{changeset.id}_#{x}_#{y}_#{zoom}}"}
          feature['geometry'] = JSON[change_geojson] if change_geojson
          changeset_geojson['features'] << feature
        end
      end
      geojson['features'] << changeset_geojson
    end
    geojson
  end

  def pg_string_to_array(str)
    dup = str.dup
    dup[0] = '['
    dup[-1] = ']'
    dup.gsub!('NULL', 'nil')
    eval(dup)
  end
end
