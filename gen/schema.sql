-- GENERATED from spec/Mina/Schema.lean. Do not edit.
CREATE TABLE events (
  seq INTEGER PRIMARY KEY,
  eid BLOB NOT NULL UNIQUE CHECK (length(eid) = 16),
  region INTEGER NOT NULL,
  vis INTEGER NOT NULL CHECK (vis IN (0, 1)),
  kind INTEGER NOT NULL,
  incident INTEGER,
  category INTEGER,
  status INTEGER,
  actor INTEGER NOT NULL,
  ts INTEGER NOT NULL,
  at INTEGER,
  lat INTEGER,
  lon INTEGER,
  body TEXT CHECK (length(body) <= 280)
);
CREATE TABLE incidents (
  id INTEGER PRIMARY KEY,
  owner INTEGER NOT NULL,
  region INTEGER NOT NULL,
  category INTEGER NOT NULL,
  status INTEGER NOT NULL,
  updated_seq INTEGER NOT NULL
);
CREATE INDEX events_region_vis ON events (region, vis);
