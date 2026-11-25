-- GENERATED from spec/Mina/Query.lean. Do not edit.
SELECT seq, kind, ts, incident, category, status, body, lat, lon, at FROM events WHERE region = ?1 AND vis = 0 AND seq > ?2 ORDER BY seq LIMIT ?3;
SELECT seq, kind, ts, incident, category, status, body, lat, lon, at FROM events WHERE region = ?1 AND vis = 0 AND seq > ?2 UNION ALL SELECT seq, kind, ts, incident, category, status, body, lat, lon, at FROM events WHERE region = ?1 AND vis = 1 AND seq > ?2 ORDER BY 1 LIMIT ?3;
SELECT coalesce(max(seq), 0) FROM events;
SELECT i.region, i.category, i.status, i.updated_seq, i.owner, e.ts, e.at, e.body, e.lat, e.lon FROM incidents i JOIN events e ON e.seq = i.id WHERE i.id = ?1;
SELECT region, vis, max(seq) FROM events GROUP BY region, vis;
