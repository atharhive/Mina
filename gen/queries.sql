-- GENERATED from spec/Mina/Query.lean. Do not edit.
SELECT seq, kind, ts, incident, category, status, body, lat, lon, at FROM events WHERE region = ?1 AND vis = 0 AND seq > ?2 ORDER BY seq LIMIT ?3;
SELECT seq, kind, ts, incident, category, status, body, lat, lon, at FROM events WHERE region = ?1 AND vis = 0 AND seq > ?2 UNION ALL SELECT seq, kind, ts, incident, category, status, body, lat, lon, at FROM events WHERE region = ?1 AND vis = 1 AND seq > ?2 ORDER BY 1 LIMIT ?3;
SELECT coalesce(max(seq), 0) FROM events;
SELECT i.region, i.category, i.status, i.updated_seq, i.owner, e.ts, e.at, e.body, e.lat, e.lon FROM incidents i JOIN events e ON e.seq = i.id WHERE i.id = ?1;
SELECT region, vis, max(seq) FROM events GROUP BY region, vis;
SELECT seq, incident, actor FROM events WHERE eid = ?1;
INSERT INTO events (seq, eid, region, vis, kind, incident, category, status, actor, ts, at, lat, lon, body) SELECT s, ?1, ?2, ?3, ?4, CASE WHEN ?4 = 1 THEN s ELSE ?5 END, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13 FROM (SELECT coalesce((SELECT max(seq) FROM events), 0) + 1 AS s) WHERE true RETURNING seq, incident;
INSERT INTO incidents (id, owner, region, category, status, updated_seq) VALUES (?1, ?2, ?3, ?4, ?5, ?1);
SELECT region, category, status FROM incidents WHERE id = ?1;
UPDATE incidents SET status = ?2, updated_seq = ?3 WHERE id = ?1;
