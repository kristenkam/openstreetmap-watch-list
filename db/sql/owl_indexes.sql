-- OWL is meant to be very conservative with indexes because of the amount of data it processes (indexes are expensive).
-- So we only create indexes that we really use and need - for every index there needs to be a short explanation.

-- Used for looking up ways that a node belongs to (@> operator for the "nodes" column).
CREATE INDEX idx_ways_nodes_id ON ways USING gin (nodes);

-- Used for selecting changeset elements.
CREATE INDEX idx_nodes_changeset_id ON nodes USING btree (changeset_id);
CREATE INDEX idx_relations_changeset_id ON relations USING btree (changeset_id);
CREATE INDEX idx_ways_changeset_id ON ways USING btree (changeset_id);

-- Used for selecting nodes (by id) for a specific way when constructing way geometry.
CREATE INDEX idx_nodes_node_id ON nodes USING btree (id);

-- Used by the changeset API to locate tiles by specific tile or tile range.
CREATE INDEX idx_changeset_tiles_xyz ON changeset_tiles USING btree (zoom, x, y);
CREATE INDEX idx_changeset_tiles_xcyz ON changeset_tiles USING btree (zoom, changeset_id, x, y);

-- Used during replication to select latest objects.
--CREATE INDEX idx_nodes_tstamp ON nodes USING btree (tstamp);
--CREATE INDEX idx_ways_tstamp ON ways USING btree (tstamp);

-- Used by the vector tiles API.
CREATE INDEX idx_nodes_geom ON nodes USING gist (geom) WHERE visible AND current;
