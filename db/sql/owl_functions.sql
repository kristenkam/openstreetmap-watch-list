CREATE OR REPLACE FUNCTION OWL_LatLonToTile(int, geometry) RETURNS table (x int, y int) AS $$
  SELECT
    floor((POW(2, $1) * ((ST_X($2) + 180) / 360)))::int AS tile_x,
    floor((1.0 - ln(tan(radians(ST_Y($2))) + 1.0 / cos(radians(ST_Y($2)))) / pi()) / 2.0 * POW(2, $1))::int AS tile_y;
$$ LANGUAGE SQL;

--
-- Returns index of an element in given array.
--
-- Source: http://wiki.postgresql.org/wiki/Array_Index
--
CREATE OR REPLACE FUNCTION idx(anyarray, anyelement)
  RETURNS int AS
$$
  SELECT i FROM (
     SELECT generate_series(array_lower($1,1),array_upper($1,1))
  ) g(i)
  WHERE $1[i] = $2
  LIMIT 1;
$$ LANGUAGE sql IMMUTABLE;

--
-- Returns the intersection of two arrays.
--
CREATE OR REPLACE FUNCTION array_intersect(anyarray, anyarray)
  RETURNS anyarray
  language sql
as $FUNCTION$
    SELECT ARRAY(
        SELECT UNNEST($1)
        INTERSECT
        SELECT UNNEST($2)
    );
$FUNCTION$;

CREATE OR REPLACE FUNCTION OWL_IsPolygon(hstore) RETURNS boolean AS
$$
  SELECT $1 IS NOT NULL AND
    ($1 ? 'area' OR $1 ? 'landuse' OR $1 ? 'leisure' OR $1 ? 'amenity' OR $1 ? 'building')
$$ LANGUAGE sql IMMUTABLE;

--
-- OWL_MakeLine
--
-- Creates a linestring from given list of node ids. If timestamp is given,
-- the node versions used are filtered by this timestamp (are no newer than).
-- This is useful for creating way geometry for historic versions.
--
-- Note that it returns NULL when it cannot recreate the geometry, e.g. when
-- there is not enough historical node versions in the database.
--
CREATE OR REPLACE FUNCTION OWL_MakeLine(bigint[], timestamp without time zone) RETURNS geometry(GEOMETRY, 4326) AS $$
DECLARE
  way_geom geometry(GEOMETRY, 4326);

BEGIN
  way_geom := (SELECT ST_MakeLine(q.geom ORDER BY x.seq)
    FROM (SELECT row_number() OVER () AS seq, n AS node_id FROM unnest($1) n) x
    INNER JOIN (
      SELECT DISTINCT ON (id) id, geom
      FROM nodes n
      WHERE n.id IN (SELECT unnest($1))
      AND tstamp <= $2 AND visible
      ORDER BY id, tstamp DESC) q ON (q.id = x.node_id));

  -- Now check if the linestring has exactly the right number of points.
  IF ST_NumPoints(way_geom) != array_length($1, 1) THEN
    RETURN NULL;
  END IF;

  RETURN ST_MakeValid(way_geom);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION OWL_MakeLineFromTmpNodes(bigint[]) RETURNS geometry(GEOMETRY, 4326) AS $$
DECLARE
  way_geom geometry(GEOMETRY, 4326);

BEGIN
  way_geom := (SELECT ST_MakeLine(geom ORDER BY seq) FROM _tmp_current_nodes);

  -- Now check if the linestring has exactly the right number of points.
  IF ST_NumPoints(way_geom) != array_length($1, 1) THEN
    --raise notice '--------------- %, %', $1, (select array_agg(id) from _tmp_nodes);
    RETURN NULL;
  END IF;

  RETURN ST_MakeValid(way_geom);
END;
$$ LANGUAGE plpgsql VOLATILE;

--
-- OWL_MakeMinimalLine
--
-- Creates a line from given nodes just as OWL_MakeLine does but also
-- considers additional array of "minimal" nodes. If it's possible to
-- build a shorter line using this subset of all nodes then do it.
--
-- $1 - all nodes
-- $2 - tstamp to use for constructing geometry
-- $3 - "minimal" nodes (needs to be a subset of $1)
--
CREATE OR REPLACE FUNCTION OWL_MakeMinimalLine(bigint[], timestamp without time zone, bigint[]) RETURNS geometry(GEOMETRY, 4326) AS $$
BEGIN
  RETURN OWL_MakeLine(
    (SELECT $1[MIN(idx($1, minimal_node)) - 2:MAX(idx($1, minimal_node)) + 2]
    FROM unnest($3) AS minimal_node), $2);
END
$$ LANGUAGE plpgsql IMMUTABLE;

--
-- OWL_RemoveTags
--
-- Removes "not interesting" tags from given hstore.
--
CREATE OR REPLACE FUNCTION OWL_RemoveTags(hstore) RETURNS hstore AS $$
  SELECT $1 - ARRAY['created_by', 'source']
$$ LANGUAGE sql STRICT IMMUTABLE;

--
-- OWL_Equals
--
-- Determines if two geometries are the same or not in OWL sense. That is,
-- very small changes in node geometry are ignored as they are not really
-- useful to consider as data changes.
--
CREATE OR REPLACE FUNCTION OWL_Equals(geometry(GEOMETRY, 4326), geometry(GEOMETRY, 4326)) RETURNS boolean AS $$
BEGIN
  IF $1 IS NULL OR $2 IS NULL THEN
    RETURN NULL;
  END IF;

  IF GeometryType($1) = 'POINT' AND GeometryType($2) = 'POINT' THEN
    RETURN $1 = $2;
  END IF;

  IF ST_OrderingEquals($1, $2) THEN
    RETURN true;
  END IF;

  RETURN OWL_Equals_Simple($1, $2);
END
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION OWL_Equals_Buffer(geometry(GEOMETRY, 4326), geometry(GEOMETRY, 4326)) RETURNS boolean AS $$
DECLARE
  buf1 geometry(GEOMETRY, 4326);
  buf2 geometry(GEOMETRY, 4326);
  union_area float;
  intersection_area float;

BEGIN
  buf1 := ST_Buffer($1, 0.0002);
  buf2 := ST_Buffer($2, 0.0002);
  union_area := ST_Area(ST_Union(buf1, buf2));
  intersection_area := ST_Area(ST_Intersection(buf1, buf2));
  IF intersection_area = 0.0 THEN RETURN false; END IF;
  RETURN ABS(1.0 - union_area / intersection_area) < 0.0002;
END
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION OWL_Equals_Snap(geometry(GEOMETRY, 4326), geometry(GEOMETRY, 4326)) RETURNS boolean AS $$
  SELECT ST_Equals(ST_SnapToGrid(st_Segmentize($1, 0.00002), 0.0002), ST_SnapToGrid(st_Segmentize($2, 0.00002), 0.0002));
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION OWL_Equals_Simple(geometry(GEOMETRY, 4326), geometry(GEOMETRY, 4326)) RETURNS boolean AS $$
  SELECT ABS(ST_Area($1::box2d) - ST_Area($2::box2d)) < 0.0002 AND
    ABS(ST_Length($1) - ST_Length($2)) < 0.0002;
$$ LANGUAGE sql IMMUTABLE;

--
-- OWL_JoinTileGeometriesByChange
--
-- Merges (collects/unions in the spatial sense) geometries belonging
-- to the same change.
--
-- $1 - an array of changes
--
-- The two arrays are of the same size. Returns an array of GeoJSON strings.
--
CREATE OR REPLACE FUNCTION OWL_JoinTileGeometriesByChange(change[]) RETURNS text[] AS $$
  WITH joined_arrays AS (
    SELECT (c.unnest).id AS change_id, (c.unnest).geom, GeometryType((c.unnest).geom) AS geom_type
    FROM (SELECT unnest($1)) c
  )
  SELECT
    array_agg(CASE WHEN c.g IS NOT NULL AND NOT ST_IsEmpty(c.g) AND ST_NumGeometries(c.g) > 0 THEN ST_AsGeoJSON(ST_CollectionHomogenize(c.g)) ELSE NULL END order by c.change_id)
  FROM (
    SELECT ST_Collect(g) AS g, change_id
    FROM
      (SELECT NULL AS g, change_id
      FROM joined_arrays
      WHERE geom_type IS NULL
      GROUP BY change_id
        UNION
      SELECT ST_LineMerge(ST_Union(geom)) AS g, change_id
      FROM joined_arrays
      WHERE geom_type IS NOT NULL AND geom_type LIKE '%LINESTRING'
      GROUP BY change_id
        UNION
      SELECT ST_Union(geom) AS g, change_id
      FROM joined_arrays
      WHERE geom_type IS NOT NULL AND geom_type NOT LIKE '%LINESTRING'
      GROUP BY change_id) x
    GROUP BY change_id) c
$$ LANGUAGE sql IMMUTABLE;

--
-- OWL_MergeChanges
--
CREATE OR REPLACE FUNCTION OWL_MergeChanges(change[]) RETURNS change[] AS $$
  SELECT array_agg(x.ch ORDER BY (x.ch).id) FROM (
  SELECT DISTINCT ROW(
    id,
    tstamp,
    el_type,
    action,
    el_id,
    version,
    tags,
    prev_tags,
    NULL,
    NULL)::change ch
  FROM unnest($1) c
  GROUP BY c.id, c.tstamp, c.el_type, c.action, c.el_id, c.version, c.tags, c.prev_tags) x
$$ LANGUAGE sql;

--
-- OWL_GenerateChanges
--
CREATE OR REPLACE FUNCTION OWL_GenerateChanges(bigint) RETURNS change[] AS $$
DECLARE
  min_tstamp timestamp without time zone;
  max_tstamp timestamp without time zone;
  moved_nodes_ids bigint[];
  row_count int;

BEGIN
  RAISE NOTICE '% -- Generating changes for changeset %', clock_timestamp(), $1;

  CREATE TEMPORARY TABLE _tmp_changeset_nodes ON COMMIT DROP AS
  SELECT
    $1,
    n.tstamp,
    n.changeset_id,
    'N'::element_type AS type,
    n.id,
    n.version,
    CASE
      WHEN n.version = 1 THEN 'CREATE'::action
      WHEN n.version > 1 AND n.visible THEN 'MODIFY'::action
      WHEN NOT n.visible THEN 'DELETE'::action
    END AS el_action,
    NOT OWL_Equals(n.geom, prev.geom) AS geom_changed,
    n.tags != prev.tags AS tags_changed,
    NULL::boolean AS nodes_changed,
    NULL::boolean AS members_changed,
    CASE WHEN NOT n.visible THEN NULL ELSE n.geom END AS geom,
    CASE WHEN NOT n.visible OR NOT OWL_Equals(n.geom, prev.geom) THEN prev.geom ELSE NULL END AS prev_geom,
    n.tags,
    prev.tags AS prev_tags,
    NULL::bigint[] AS nodes,
    NULL::bigint[] AS prev_nodes
  FROM nodes n
  LEFT JOIN nodes prev ON (prev.id = n.id AND prev.version = n.version - 1)
  WHERE n.changeset_id = $1 AND (prev.version IS NOT NULL OR n.version = 1);

  CREATE TEMPORARY TABLE _tmp_moved_nodes ON COMMIT DROP AS
  SELECT * FROM _tmp_changeset_nodes n WHERE n.version > 1 AND n.geom_changed AND n.el_action != 'DELETE';

  SELECT MAX(x.tstamp), MIN(x.tstamp) - INTERVAL '1 second'
  INTO max_tstamp, min_tstamp
  FROM (
    SELECT n.tstamp
    FROM nodes n
    WHERE n.changeset_id = $1
    UNION
    SELECT w.tstamp
    FROM ways w
    WHERE w.changeset_id = $1
  ) x;

  moved_nodes_ids := (SELECT array_agg(id) FROM _tmp_moved_nodes);

  RAISE NOTICE '% --   Prepared data (min = %, max = %, moved nodes = %)', clock_timestamp(),
    min_tstamp, max_tstamp, (SELECT COUNT(*) FROM _tmp_moved_nodes);

  CREATE TEMPORARY TABLE _tmp_result ON COMMIT DROP AS
  SELECT *
  FROM _tmp_changeset_nodes n
  WHERE (n.el_action IN ('CREATE', 'DELETE') OR n.tags_changed OR n.geom_changed) AND
    (OWL_RemoveTags(n.tags) != ''::hstore OR OWL_RemoveTags(n.prev_tags) != ''::hstore);

  GET DIAGNOSTICS row_count = ROW_COUNT;
  RAISE NOTICE '% --   Nodes done (%)', clock_timestamp(), row_count;

  -- Created ways

  INSERT INTO _tmp_result
  SELECT
    $1,
    w.tstamp,
    w.changeset_id,
    'W'::element_type AS type,
    w.id,
    w.version,
    'CREATE',
    NULL,
    NULL,
    NULL,
    NULL,
    w.geom,
    NULL,
    w.tags,
    NULL,
    w.nodes,
    NULL
  FROM (
    SELECT w.*, OWL_MakeLine(w.nodes, max_tstamp) AS geom
    FROM ways w
    WHERE w.changeset_id = $1 AND w.version = 1) w
  WHERE w.geom IS NOT NULL;

  GET DIAGNOSTICS row_count = ROW_COUNT;
  RAISE NOTICE '% --   Created ways done (%)', clock_timestamp(), row_count;

  -- Modified ways

  INSERT INTO _tmp_result
  SELECT
    $1,
    w.tstamp,
    w.changeset_id,
    'W'::element_type AS type,
    w.id,
    w.version,
    'MODIFY',
    w.geom_changed,
    w.tags_changed,
    w.nodes_changed,
    NULL,
    CASE WHEN w.geom_changed AND NOT w.tags_changed AND NOT w.nodes_changed THEN
      OWL_MakeMinimalLine(w.nodes, max_tstamp, (SELECT array_agg(id) FROM _tmp_changeset_nodes n WHERE w.nodes @> ARRAY[n.id]))
    ELSE
      OWL_MakeLine(w.nodes, max_tstamp)
    END,
    CASE WHEN w.geom_changed AND NOT w.tags_changed AND NOT w.nodes_changed THEN
      OWL_MakeMinimalLine(w.prev_nodes, min_tstamp, (SELECT array_agg(id) FROM _tmp_changeset_nodes n WHERE w.prev_nodes @> ARRAY[n.id]))
    ELSE
      CASE WHEN w.visible AND NOT w.geom_changed THEN NULL ELSE OWL_MakeLine(w.prev_nodes, min_tstamp) END
    END,
    w.tags,
    w.prev_tags,
    w.nodes,
    CASE WHEN w.nodes = w.prev_nodes THEN NULL ELSE w.prev_nodes END
  FROM (
    SELECT w.*,
      prev.tags AS prev_tags,
      prev.nodes AS prev_nodes,
      NOT OWL_Equals(OWL_MakeLine(w.nodes, w.tstamp), OWL_MakeLine(prev.nodes, prev.tstamp)) AS geom_changed,
      CASE WHEN NOT w.visible OR w.version = 1 THEN NULL ELSE w.tags != prev.tags END AS tags_changed,
      w.nodes != prev.nodes AS nodes_changed
    FROM ways w
    INNER JOIN ways prev ON (prev.id = w.id AND prev.version = w.version - 1)
    WHERE w.changeset_id = $1 AND w.visible) w
  WHERE w.geom_changed IS NOT NULL AND (w.geom_changed OR w.tags_changed OR w.nodes_changed);

  GET DIAGNOSTICS row_count = ROW_COUNT;
  RAISE NOTICE '% --   Modified ways done (%)', clock_timestamp(), row_count;

  -- Deleted ways

  INSERT INTO _tmp_result
  SELECT
    $1,
    w.tstamp,
    w.changeset_id,
    'W'::element_type AS type,
    w.id,
    w.version,
    'DELETE',
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    w.prev_geom,
    w.tags,
    w.prev_tags,
    w.nodes,
    w.prev_nodes
  FROM (
    SELECT w.*,
      prev.tags AS prev_tags,
      prev.nodes AS prev_nodes,
      OWL_MakeLine(prev.nodes, max_tstamp) AS prev_geom
    FROM ways w
    INNER JOIN ways prev ON (prev.id = w.id AND prev.version = w.version - 1)
    WHERE w.changeset_id = $1 AND NOT w.visible) w
  WHERE w.prev_geom IS NOT NULL;

  GET DIAGNOSTICS row_count = ROW_COUNT;
  RAISE NOTICE '% --   Deleted ways done (%)', clock_timestamp(), row_count;

  -- Affected ways

  INSERT INTO _tmp_result
  SELECT
    $1,
    w.tstamp,
    w.changeset_id,
    'W'::element_type AS type,
    w.id,
    version,
    'AFFECT'::action,
    true,
    false,
    false,
    NULL,
    w.geom,
    w.prev_geom,
    w.tags,
    NULL,
    w.nodes,
    NULL
  FROM (
    SELECT
      *,
      OWL_MakeMinimalLine(w.nodes, max_tstamp, array_intersect(w.nodes, moved_nodes_ids)) AS geom,
      OWL_MakeMinimalLine(w.nodes, min_tstamp, array_intersect(w.nodes, moved_nodes_ids)) AS prev_geom
      --OWL_MakeLine(w.nodes, max_tstamp) AS geom,
      --OWL_MakeLine(w.nodes, min_tstamp) AS prev_geom
    FROM ways w
    WHERE w.nodes && moved_nodes_ids AND
      w.version = (SELECT version FROM ways WHERE id = w.id AND tstamp <= max_tstamp ORDER BY version DESC LIMIT 1) AND
      w.changeset_id != $1) w; -- AND
      --OWL_MakeLine(w.nodes, max_tstamp) IS NOT NULL AND
      --(w.version = 1 OR OWL_MakeLine(w.nodes, min_tstamp) IS NOT NULL)) w;

  GET DIAGNOSTICS row_count = ROW_COUNT;
  RAISE NOTICE '% --   Affected ways done (%)', clock_timestamp(), row_count;

  RAISE NOTICE '% -- Returning % change(s)', clock_timestamp(), (SELECT COUNT(*) FROM _tmp_result);

  RETURN (SELECT array_agg(x.c) FROM (SELECT ROW(
    (row_number() OVER ())::int,
    tstamp,
    type,
    el_action,
    id,
    version,
    tags,
    prev_tags,
    geom,
    prev_geom
  )::change AS c FROM _tmp_result ORDER BY tstamp) x);
END
$$ LANGUAGE plpgsql;

--
-- OWL_UpdateChangeset
--
CREATE OR REPLACE FUNCTION OWL_UpdateChangeset(bigint) RETURNS void AS $$
DECLARE
  row record;
  idx int;
  result int[9];
  result_bbox geometry;
BEGIN
  result := ARRAY[0, 0, 0, 0, 0, 0, 0, 0, 0];
  FOR row IN
    SELECT
      CASE el_type WHEN 'N' THEN 0 WHEN 'W' THEN 1 WHEN 'R' THEN 2 END AS el_type_idx,
      CASE action WHEN 'CREATE' THEN 0 WHEN 'MODIFY' THEN 1 WHEN 'DELETE' THEN 2 END AS action_idx,
      COUNT(*) as cnt
    FROM changes
    WHERE changeset_id = $1
    GROUP BY el_type, action
  LOOP
    result[row.el_type_idx * 3 + row.action_idx + 1] := row.cnt;
  END LOOP;

  result_bbox := (SELECT ST_Envelope(ST_Collect(ST_Collect(current_geom, new_geom))) FROM changes WHERE changeset_id = $1);

  UPDATE changesets cs SET entity_changes = result, bbox = result_bbox
  WHERE cs.id = $1;
END;
$$ LANGUAGE plpgsql;

--
-- OWL_UpdateChangeset
--
CREATE OR REPLACE FUNCTION OWL_UpdateChangeset(bigint) RETURNS void AS $$
DECLARE
  row record;
  idx int;
  result int[9];
  result_bbox geometry;
BEGIN
  result := ARRAY[0, 0, 0, 0, 0, 0, 0, 0, 0];
  FOR row IN
    SELECT
      CASE el_type WHEN 'N' THEN 0 WHEN 'W' THEN 1 WHEN 'R' THEN 2 END AS el_type_idx,
      CASE action WHEN 'CREATE' THEN 0 WHEN 'MODIFY' THEN 1 WHEN 'DELETE' THEN 2 END AS action_idx,
      COUNT(*) as cnt
    FROM changes
    WHERE changeset_id = $1
    GROUP BY el_type, action
  LOOP
    result[row.el_type_idx * 3 + row.action_idx + 1] := row.cnt;
  END LOOP;

  result_bbox := (SELECT ST_Envelope(ST_Collect(ST_Collect(current_geom, new_geom))) FROM changes WHERE changeset_id = $1);

  UPDATE changesets cs SET entity_changes = result, bbox = result_bbox
  WHERE cs.id = $1;
END;
$$ LANGUAGE plpgsql;

--
-- OWL_AggregateChangeset
--
CREATE OR REPLACE FUNCTION OWL_AggregateChangeset(bigint, int, int) RETURNS void AS $$
DECLARE
  subtiles_per_tile bigint;

BEGIN
  subtiles_per_tile := POW(2, $2) / POW(2, $3);

  DELETE FROM changeset_tiles WHERE changeset_id = $1 AND zoom = $3;

  INSERT INTO changeset_tiles (changeset_id, tstamp, x, y, zoom, geom, prev_geom, changes)
  SELECT
  $1,
  MAX(tstamp),
  x/subtiles_per_tile * subtiles_per_tile,
  y/subtiles_per_tile * subtiles_per_tile,
  $3,
  CASE
    WHEN $3 >= 14 THEN array_accum(geom)
    ELSE array_accum((SELECT array_agg(ST_Envelope(unnest)) FROM unnest(geom)))
  END,
  CASE
    WHEN $3 >= 14 THEN array_accum(prev_geom)
    ELSE array_accum((SELECT array_agg(ST_Envelope(unnest)) FROM unnest(prev_geom)))
  END,
  array_accum(changes)
  FROM changeset_tiles
  WHERE changeset_id = $1 AND zoom = $2
  GROUP BY x/subtiles_per_tile, y/subtiles_per_tile;
END;
$$ LANGUAGE plpgsql;
