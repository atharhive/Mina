/* GENERATED from the Lean specification in spec/ (Mina.Emit.appGen). Do not edit:
 * change the specification and run `lake exe derive ../gen` in spec/. */
#include "rt.h"
#include <stdio.h>
#include <sys/random.h>
#include "domain.h"

/* ---- wire constants: Mina.Contract ----------------------------------------------------- */
static const u8 HDR_200[] = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ";
static const u8 HDR_201[] = "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: ";
static const u8 HDR_503[] = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: ";

static const u8 E_NOT_FOUND[] = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 21\r\n\r\n{\"error\":\"not found\"}";  /* 404 not found */
static const u8 E_UNAVAILABLE[] = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: 23\r\n\r\n{\"error\":\"unavailable\"}";  /* 503 unavailable */
static const u8 E_NO_BEARER[] = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: 32\r\n\r\n{\"error\":\"missing bearer token\"}";  /* 401 missing bearer token */
static const u8 E_BAD_TOKEN[] = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: 25\r\n\r\n{\"error\":\"invalid token\"}";  /* 401 invalid token */
static const u8 E_BAD_JSON[] = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 24\r\n\r\n{\"error\":\"invalid json\"}";  /* 400 invalid json */
static const u8 E_BAD_EID[] = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 28\r\n\r\n{\"error\":\"invalid event id\"}";  /* 400 invalid event id */
static const u8 E_BAD_KIND[] = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 24\r\n\r\n{\"error\":\"invalid kind\"}";  /* 400 invalid kind */
static const u8 E_BAD_FIELDS[] = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 39\r\n\r\n{\"error\":\"missing or unexpected field\"}";  /* 400 missing or unexpected field */
static const u8 E_BAD_REGION[] = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 26\r\n\r\n{\"error\":\"invalid region\"}";  /* 400 invalid region */
static const u8 E_BAD_CATEGORY[] = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 28\r\n\r\n{\"error\":\"invalid category\"}";  /* 400 invalid category */
static const u8 E_BAD_STATUS[] = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 26\r\n\r\n{\"error\":\"invalid status\"}";  /* 400 invalid status */
static const u8 E_BAD_INCIDENT[] = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 28\r\n\r\n{\"error\":\"invalid incident\"}";  /* 400 invalid incident */
static const u8 E_BAD_LOCATION[] = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 28\r\n\r\n{\"error\":\"invalid location\"}";  /* 400 invalid location */
static const u8 E_BAD_TIME[] = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 24\r\n\r\n{\"error\":\"invalid time\"}";  /* 400 invalid time */
static const u8 E_BAD_BODY[] = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 24\r\n\r\n{\"error\":\"invalid body\"}";  /* 400 invalid body */
static const u8 E_FORBIDDEN[] = "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: 25\r\n\r\n{\"error\":\"not permitted\"}";  /* 403 not permitted */
static const u8 E_BAD_AREA[] = "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: 33\r\n\r\n{\"error\":\"region not authorized\"}";  /* 403 region not authorized */
static const u8 E_EID_USED[] = "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 33\r\n\r\n{\"error\":\"event id already used\"}";  /* 409 event id already used */
static const u8 E_NO_INCIDENT[] = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 28\r\n\r\n{\"error\":\"no such incident\"}";  /* 404 no such incident */
static const u8 E_BAD_TRANSITION[] = "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 30\r\n\r\n{\"error\":\"invalid transition\"}";  /* 409 invalid transition */
static const u8 E_BAD_QUERY[] = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 25\r\n\r\n{\"error\":\"invalid query\"}";  /* 400 invalid query */
static const u8 E_RESYNC[] = "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 18\r\n\r\n{\"error\":\"resync\"}";  /* 409 resync */
static const u8 E_INTERNAL[] = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: 26\r\n\r\n{\"error\":\"internal error\"}";  /* 500 internal error */
#define ERR(name) obuf_static(E_##name, sizeof E_##name - 1)


enum { K_NONE = 0, K_HEALTH, K_SESSION, K_EVENT, K_SYNC, K_INCIDENT };

/* ---- stored layout: Mina.Schema --------------------------------------------------------- */
static int schema_check(void) {
  return table_layout("events", "seq:INTEGER:1,eid:BLOB:0,region:INTEGER:0,vis:INTEGER:0,kind:INTEGER:0,incident:INTEGER:0,category:INTEGER:0,status:INTEGER:0,actor:INTEGER:0,ts:INTEGER:0,at:INTEGER:0,lat:INTEGER:0,lon:INTEGER:0,body:TEXT:0") &&
         table_layout("incidents", "id:INTEGER:1,owner:INTEGER:0,region:INTEGER:0,category:INTEGER:0,status:INTEGER:0,updated_seq:INTEGER:0") &&
         index_layout("events_region_vis", "region,vis");
}

static sqlite3_stmt *Q_health, *Q_by_eid, *Q_event_insert, *Q_incident_insert, *Q_incident_state, *Q_incident_update;
static sqlite3_stmt *Q_sync_public, *Q_sync_all, *Q_head, *Q_incident;
static i64 started_at;

static void app_init(void) {
  if (!schema_check()) { fprintf(stderr, "fatal: the database does not have the MINA schema\n"); exit(1); }
  Q_health = db_prepare("SELECT 1");
  Q_by_eid = db_prepare("SELECT seq, incident, actor FROM events WHERE eid = ?1");
  /* seq is assigned here, in the writing transaction; a new report opens the incident of the
   * same number. */
  Q_event_insert = db_prepare(
      "INSERT INTO events (seq, eid, region, vis, kind, incident, category, status, actor, ts, at, lat, lon, body) "
      "SELECT s, ?1, ?2, ?3, ?4, CASE WHEN ?4 = 1 THEN s ELSE ?5 END, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13 "
      "FROM (SELECT coalesce(max(seq), 0) + 1 AS s FROM events) WHERE true RETURNING seq, incident");
  Q_incident_insert = db_prepare(
      "INSERT INTO incidents (id, owner, region, category, status, updated_seq) VALUES (?1, ?2, ?3, ?4, ?5, ?1)");
  Q_incident_state = db_prepare("SELECT region, category, status FROM incidents WHERE id = ?1");
  Q_incident_update = db_prepare("UPDATE incidents SET status = ?2, updated_seq = ?3 WHERE id = ?1");
  Q_sync_public = db_prepare("SELECT seq, kind, ts, incident, category, status, body, lat, lon, at FROM events WHERE region = \?1 AND vis = 0 AND seq > \?2 ORDER BY seq LIMIT \?3");
  Q_sync_all = db_prepare("SELECT seq, kind, ts, incident, category, status, body, lat, lon, at FROM events WHERE region = \?1 AND vis = 0 AND seq > \?2 UNION ALL SELECT seq, kind, ts, incident, category, status, body, lat, lon, at FROM events WHERE region = \?1 AND vis = 1 AND seq > \?2 ORDER BY 1 LIMIT \?3");
  Q_head = db_prepare("SELECT coalesce(max(seq), 0) FROM events");
  Q_incident = db_prepare("SELECT i.region, i.category, i.status, i.updated_seq, i.owner, e.ts, e.at, e.body, e.lat, e.lon FROM incidents i JOIN events e ON e.seq = i.id WHERE i.id = \?1");
  started_at = time(0);
}

/* ---- request data ------------------------------------------------------------------------ */

/* Data that must outlive the receive buffer until the batch completes. */
static u8 arena[1 << 22];
static u32 arena_used;
static void *arena_get(u32 n) {
  if (n > sizeof arena - arena_used) return 0;
  void *p = arena + arena_used;
  arena_used += (n + 7) & ~7u;
  return p;
}

/* "Authorization: Bearer <token>" with a role this application knows. */
static int authenticate(const req_t *rq, job_t *j, claims_t *c) {
  if (!rq->has_auth || rq->auth_len < 7 || memcmp(rq->auth, "Bearer ", 7)) { j->resp = ERR(NO_BEARER); return 0; }
  if (jwt_verify(rq->auth + 7, rq->auth_len - 7, now_s, c) != JWT_OK || c->role < ROLE_CITIZEN || c->role > ROLE_ADMIN) {
    j->resp = ERR(BAD_TOKEN);
    return 0;
  }
  return 1;
}
static int in_region(const claims_t *c, i64 region) {
  if (c->role == ROLE_ADMIN) return 1;
  for (int i = 0; i < c->nregions; i++) if (c->regions[i] == region) return 1;
  return 0;
}

/* A JSON integer in [lo, hi]: no fraction, no exponent. */
static int json_int(const jmember *m, i64 lo, i64 hi, i64 *out) {
  if (m->type != JT_NUMBER || m->v_len > 16) return 0;
  const u8 *p = m->v, *e = p + m->v_len;
  int neg = *p == '-';
  p += neg;
  i64 v = 0;
  for (; p < e; p++) {
    if (*p < '0' || *p > '9') return 0;
    v = v * 10 + (*p - '0');
  }
  if (neg) v = -v;
  if (v < lo || v > hi) return 0;
  *out = v;
  return 1;
}

/* ---- sessions --------------------------------------------------------------------------- */

/* POST /v1/session: a new citizen device identity. No database access, so the response is
 * written while decoding and no job is queued. Always returns 0. */
static int issue_session(const req_t *rq, job_t *j) {
  (void)rq;
  u64 r;
  if (getrandom(&r, sizeof r, 0) != sizeof r) { j->resp = ERR(UNAVAILABLE); return 0; }
  claims_t c = {.uid = (i64)(r % 999999999999999ULL) + 1, .role = ROLE_CITIZEN};
  i64 exp = now_s + 2592000;
  u8 token[JWT_MAX], sub[24];
  u32 token_len = jwt_sign(&c, exp, token), sub_len = fmt_u64(sub, (u64)c.uid);
  out_t o0, *o = &o0;
  out_begin(o);
  out_need(o, 44 + JSTR_ROOM(token_len) + JSTR_ROOM(sub_len));
  out_lit(o, "{\"token\":", 9);
  out_jstr(o, token, token_len);
  out_lit(o, ",\"sub\":", 7);
  out_jstr(o, sub, sub_len);
  out_lit(o, ",\"exp\":", 7);
  out_i64(o, exp);
  out_lit(o, "}", 1);
  j->resp = out_finish(o, HDR_201, sizeof HDR_201 - 1);
  return 0;
}

/* ---- event submissions: Mina.Domain ------------------------------------------------------ */

typedef struct {
  claims_t who;
  u8 eid[16];
  u8 kind, has;                          /* has: F_* bits of the fields present */
  i64 region, category, status, incident, lat, lon, at;
  const u8 *body; u32 body_len;
} event_t;

static int hex16(const u8 *s, u8 out[16]) {
  for (int i = 0; i < 32; i++) {
    u8 c = s[i], v;
    if (c >= '0' && c <= '9') v = (u8)(c - '0');
    else if (c >= 'a' && c <= 'f') v = (u8)(c - 'a' + 10);
    else return 0;
    out[i / 2] = (u8)(i & 1 ? out[i / 2] | v : v << 4);
  }
  return 1;
}

/* String.prototype.trim whitespace */
static int js_space(u32 cp) {
  return (cp >= 9 && cp <= 13) || cp == 32 || cp == 0xA0 || cp == 0x1680 || (cp >= 0x2000 && cp <= 0x200A) ||
         cp == 0x2028 || cp == 0x2029 || cp == 0x202F || cp == 0x205F || cp == 0x3000 || cp == 0xFEFF;
}
static u32 cp_at(const u8 *p, u32 *len) {
  u8 c = p[0];
  if (c < 0x80) { *len = 1; return c; }
  if (c < 0xE0) { *len = 2; return (u32)(c & 0x1F) << 6 | (p[1] & 0x3F); }
  if (c < 0xF0) { *len = 3; return (u32)(c & 0x0F) << 12 | (u32)(p[1] & 0x3F) << 6 | (p[2] & 0x3F); }
  *len = 4;
  return (u32)(c & 0x07) << 18 | (u32)(p[1] & 0x3F) << 12 | (u32)(p[2] & 0x3F) << 6 | (p[3] & 0x3F);
}
/* The text of a report: unescaped into the arena and trimmed. Control characters other than
 * tab and newline are refused, as is anything over MAX_BODY_CHARS characters. An empty result
 * leaves the field absent. Returns 0 if refused, -1 if the arena is full. */
static int decode_text(const jmember *m, event_t *ev) {
  if (m->type != JT_STRING) return 0;
  u8 *t = arena_get(m->v_len + 1);
  if (!t) return -1;
  u32 n = m->escaped ? json_unescape(m->v, m->v_len, t) : (memcpy(t, m->v, m->v_len), m->v_len);
  u32 a = 0, b = n, l;
  while (a < b && js_space(cp_at(t + a, &l))) a += l;
  while (b > a) {
    u32 k = b - 1;
    while (k > a && (t[k] & 0xC0) == 0x80) k--;
    if (!js_space(cp_at(t + k, &l))) break;
    b = k;
  }
  u32 chars = 0;
  for (u32 i = a; i < b; i++) {
    if (t[i] < 0x20 && t[i] != '\n' && t[i] != '\t') return 0;
    chars += (t[i] & 0xC0) != 0x80;
  }
  if (chars > MAX_BODY_CHARS) return 0;
  if (a < b) { ev->body = t + a; ev->body_len = b - a; ev->has |= F_BODY; }
  return 1;
}

static int decode_event(const req_t *rq, job_t *j) {
  claims_t who;
  if (!authenticate(rq, j, &who)) return 0;
  enum { J_EID, J_KIND, J_REGION, J_CATEGORY, J_STATUS, J_INCIDENT, J_BODY, J_LAT, J_LON, J_AT, J_COUNT };
  jmember m[J_COUNT] = {
    {"eid", 3, 0, 0, 0, 0}, {"kind", 4, 0, 0, 0, 0}, {"region", 6, 0, 0, 0, 0}, {"category", 8, 0, 0, 0, 0},
    {"status", 6, 0, 0, 0, 0}, {"incident", 8, 0, 0, 0, 0}, {"body", 4, 0, 0, 0, 0}, {"lat", 3, 0, 0, 0, 0},
    {"lon", 3, 0, 0, 0, 0}, {"at", 2, 0, 0, 0, 0}};
  int rc = json_members(rq->body, rq->body_len, m, J_COUNT);
  if (rc < 0) { j->resp = ERR(BAD_JSON); return 0; }
  if (rc > 0) { j->resp = ERR(BAD_JSON); return 0; }
  event_t *ev = arena_get(sizeof *ev);
  if (!ev) { j->resp = ERR(UNAVAILABLE); return 0; }
  memset(ev, 0, sizeof *ev);
  ev->who = who;
  if (m[J_EID].type != JT_STRING || m[J_EID].v_len != 32 || !hex16(m[J_EID].v, ev->eid)) { j->resp = ERR(BAD_EID); return 0; }
  i64 kind;
  if (!json_int(&m[J_KIND], 0, KIND_COUNT - 1, &kind) || !KIND_SPECS[kind].roles) { j->resp = ERR(BAD_KIND); return 0; }
  const kind_spec *spec = &KIND_SPECS[kind];
  ev->kind = (u8)kind;
  if (!(spec->roles >> who.role & 1)) { j->resp = ERR(FORBIDDEN); return 0; }

  u8 present = 0;
  static const struct { u8 member, field; } F[] = {
    {J_REGION, F_REGION}, {J_CATEGORY, F_CATEGORY}, {J_STATUS, F_STATUS}, {J_INCIDENT, F_INCIDENT},
    {J_BODY, F_BODY}, {J_LAT, F_LOCATION}, {J_LON, F_LOCATION}, {J_AT, F_AT}};
  for (unsigned i = 0; i < sizeof F / sizeof *F; i++) if (m[F[i].member].type != JT_NONE) present |= F[i].field;
  if ((present & ~spec->allow) || (spec->need & ~present)) { j->resp = ERR(BAD_FIELDS); return 0; }

  if ((present & F_REGION) && !json_int(&m[J_REGION], 1, MAX_REGION, &ev->region)) { j->resp = ERR(BAD_REGION); return 0; }
  if ((present & F_CATEGORY) && !json_int(&m[J_CATEGORY], 1, CATEGORY_MAX, &ev->category)) { j->resp = ERR(BAD_CATEGORY); return 0; }
  if ((present & F_STATUS) && !json_int(&m[J_STATUS], spec->status_lo, spec->status_hi, &ev->status)) { j->resp = ERR(BAD_STATUS); return 0; }
  if ((present & F_INCIDENT) && !json_int(&m[J_INCIDENT], 1, 999999999999999LL, &ev->incident)) { j->resp = ERR(BAD_INCIDENT); return 0; }
  if ((present & F_LOCATION) && !(json_int(&m[J_LAT], -MAX_LAT, MAX_LAT, &ev->lat) && json_int(&m[J_LON], -MAX_LON, MAX_LON, &ev->lon))) { j->resp = ERR(BAD_LOCATION); return 0; }
  if ((present & F_AT) && !json_int(&m[J_AT], 0, MAX_TIME, &ev->at)) { j->resp = ERR(BAD_TIME); return 0; }
  ev->has = present & (u8)~F_BODY;
  if (present & F_BODY) {
    int t = decode_text(&m[J_BODY], ev);
    if (t <= 0) { j->resp = t < 0 ? ERR(UNAVAILABLE) : ERR(BAD_BODY); return 0; }
    if ((spec->need & F_BODY) && !(ev->has & F_BODY)) { j->resp = ERR(BAD_BODY); return 0; }
  }
  /* Responders act inside their regions; a citizen may report from anywhere. */
  if ((present & F_REGION) && who.role != ROLE_CITIZEN && !in_region(&who, ev->region)) { j->resp = ERR(BAD_AREA); return 0; }
  j->data = ev;
  return 1;
}

/* ---- synchronisation requests ------------------------------------------------------------ */

typedef struct { i64 region, after, limit; u8 restricted; } sync_t;

/* A query parameter holding an integer in [lo, hi]. Absent: *out keeps its value unless the
 * parameter is required. */
static int query_int(const req_t *rq, const char *name, int required, i64 lo, i64 hi, i64 *out) {
  const u8 *v; u32 n;
  if (!query_param(rq->query, rq->query_len, name, &v, &n)) return !required;
  jmember m = {0, 0, JT_NUMBER, v, n, 0};
  return n && json_int(&m, lo, hi, out);
}

static int decode_sync(const req_t *rq, job_t *j) {
  claims_t who;
  if (!authenticate(rq, j, &who)) return 0;
  sync_t *q = arena_get(sizeof *q);
  if (!q) { j->resp = ERR(UNAVAILABLE); return 0; }
  q->after = 0;
  q->limit = 64;
  if (!query_int(rq, "region", 1, 1, MAX_REGION, &q->region) || !query_int(rq, "after", 0, 0, 999999999999999LL, &q->after) ||
      !query_int(rq, "limit", 0, 1, 256, &q->limit)) { j->resp = ERR(BAD_QUERY); return 0; }
  q->restricted = who.role != ROLE_CITIZEN;
  if (q->restricted && !in_region(&who, q->region)) { j->resp = ERR(BAD_AREA); return 0; }
  j->data = q;
  return 1;
}

typedef struct { claims_t who; i64 id; } incident_t;

/* GET /v1/incidents/:id. Anything that is not a positive decimal number names no incident. */
static int decode_incident(const req_t *rq, job_t *j, const u8 *id, u32 id_n) {
  claims_t who;
  if (!authenticate(rq, j, &who)) return 0;
  incident_t *q = arena_get(sizeof *q);
  if (!q) { j->resp = ERR(UNAVAILABLE); return 0; }
  q->who = who;
  jmember m = {0, 0, JT_NUMBER, id, id_n, 0};
  if (!json_int(&m, 1, 999999999999999LL, &q->id)) { j->resp = ERR(NO_INCIDENT); return 0; }
  j->data = q;
  return 1;
}

/* ---- request decoding: Mina.Contract.routes --------------------------------------------- */
static void app_decode(const req_t *rq, job_t *j) {
  const u8 *p = rq->path;
  u32 n = rq->path_len;
  if (rq->method == M_GET) {
    const u8 *s = p, *e = p + n, *id_p = 0; u32 id_n = 0;
    (void)id_p; (void)id_n;
    if (path_lit(&s, e, "/v1", 3) && path_lit(&s, e, "/health", 7) && s == e) {
      j->kind = K_HEALTH; j->is_write = 0;
      return;
    }
  }
  if (rq->method == M_POST) {
    const u8 *s = p, *e = p + n, *id_p = 0; u32 id_n = 0;
    (void)id_p; (void)id_n;
    if (path_lit(&s, e, "/v1", 3) && path_lit(&s, e, "/session", 8) && s == e) {
      if (!issue_session(rq, j)) return;
      j->kind = K_SESSION; j->is_write = 0;
      return;
    }
  }
  if (rq->method == M_POST) {
    const u8 *s = p, *e = p + n, *id_p = 0; u32 id_n = 0;
    (void)id_p; (void)id_n;
    if (path_lit(&s, e, "/v1", 3) && path_lit(&s, e, "/events", 7) && s == e) {
      if (!decode_event(rq, j)) return;
      j->kind = K_EVENT; j->is_write = 1;
      return;
    }
  }
  if (rq->method == M_GET) {
    const u8 *s = p, *e = p + n, *id_p = 0; u32 id_n = 0;
    (void)id_p; (void)id_n;
    if (path_lit(&s, e, "/v1", 3) && path_lit(&s, e, "/sync", 5) && s == e) {
      if (!decode_sync(rq, j)) return;
      j->kind = K_SYNC; j->is_write = 0;
      return;
    }
  }
  if (rq->method == M_GET) {
    const u8 *s = p, *e = p + n, *id_p = 0; u32 id_n = 0;
    (void)id_p; (void)id_n;
    if (path_lit(&s, e, "/v1", 3) && path_lit(&s, e, "/incidents", 10) && path_param(&s, e, &id_p, &id_n) && s == e) {
      if (!decode_incident(rq, j, id_p, id_n)) return;
      j->kind = K_INCIDENT; j->is_write = 0;
      return;
    }
  }
  j->resp = ERR(NOT_FOUND);
}

/* ---- reads ------------------------------------------------------------------------------ */

/* One element of the "events" array, from a row of Query.eventColumns. */
static void put_event(out_t *o, sqlite3_stmt *s) {
  i64 seq = sqlite3_column_int64(s, 0), kind = sqlite3_column_int64(s, 1), ts = sqlite3_column_int64(s, 2);
#define COL(i, name) int has_##name = sqlite3_column_type(s, i) != SQLITE_NULL; i64 name = sqlite3_column_int64(s, i);
  COL(3, incident) COL(4, category) COL(5, status)
  int has_body = sqlite3_column_type(s, 6) != SQLITE_NULL;
  const u8 *body = sqlite3_column_text(s, 6);
  u32 body_len = (u32)sqlite3_column_bytes(s, 6);
  COL(7, lat) COL(8, lon) COL(9, at)
#undef COL
  out_need(o, 191 + JSTR_ROOM(body_len));
  out_lit(o, "[", 1);
  out_i64(o, seq);
  out_lit(o, ",", 1);
  out_i64(o, kind);
  out_lit(o, ",", 1);
  out_i64(o, ts);
  out_lit(o, ",", 1);
  if (has_incident) out_i64(o, incident); else out_lit(o, "null", 4);
  out_lit(o, ",", 1);
  if (has_category) out_i64(o, category); else out_lit(o, "null", 4);
  out_lit(o, ",", 1);
  if (has_status) out_i64(o, status); else out_lit(o, "null", 4);
  out_lit(o, ",", 1);
  if (has_body) out_jstr(o, body, body_len); else out_lit(o, "null", 4);
  out_lit(o, ",", 1);
  if (has_lat) out_i64(o, lat); else out_lit(o, "null", 4);
  out_lit(o, ",", 1);
  if (has_lon) out_i64(o, lon); else out_lit(o, "null", 4);
  out_lit(o, ",", 1);
  if (has_at) out_i64(o, at); else out_lit(o, "null", 4);
  out_lit(o, "]", 1);
}

/* GET /v1/sync: Mina.Query.syncPublic or syncAll. One row past the limit tells "more". */
static void exec_sync(job_t *j) {
  const sync_t *q = j->data;
  int rc = sqlite3_step(Q_head);
  i64 head = rc == SQLITE_ROW ? sqlite3_column_int64(Q_head, 0) : 0;
  sqlite3_reset(Q_head);
  if (rc != SQLITE_ROW) { j->resp = ERR(INTERNAL); return; }
  if (q->after > head) { j->resp = ERR(RESYNC); return; }
  sqlite3_stmt *s = q->restricted ? Q_sync_all : Q_sync_public;
  sqlite3_bind_int64(s, 1, q->region);
  sqlite3_bind_int64(s, 2, q->after);
  sqlite3_bind_int64(s, 3, q->limit + 1);
  out_t o0, *o = &o0;
  out_begin(o);
  out_need(o, 39);
  out_lit(o, "{\"head\":", 8);
  out_i64(o, head);
  out_lit(o, ",\"events\":[", 11);
  i64 next = q->after, count = 0;
  int more = 0;
  while ((rc = sqlite3_step(s)) == SQLITE_ROW) {
    if (count == q->limit) { more = 1; break; }
    if (count++) { out_need(o, 1); out_lit(o, ",", 1); }
    next = sqlite3_column_int64(s, 0);
    put_event(o, s);
  }
  sqlite3_reset(s);
  if (rc != SQLITE_ROW && rc != SQLITE_DONE) { out_abort(o); j->resp = ERR(INTERNAL); return; }
  out_need(o, 43);
  out_lit(o, "],\"next\":", 9);
  out_i64(o, next);
  out_lit(o, ",\"more\":", 8);
  if (more) out_lit(o, "true", 4); else out_lit(o, "false", 5);
  out_lit(o, "}", 1);
  j->resp = out_finish(o, HDR_200, sizeof HDR_200 - 1);
}

/* GET /v1/incidents/:id: the report for responders of the region, the summary for the person
 * who made it, nothing for anyone else. */
static void exec_incident(job_t *j) {
  const incident_t *q = j->data;
  sqlite3_stmt *s = Q_incident;
  sqlite3_bind_int64(s, 1, q->id);
  int rc = sqlite3_step(s);
  if (rc != SQLITE_ROW) {
    sqlite3_reset(s);
    j->resp = rc == SQLITE_DONE ? ERR(NO_INCIDENT) : ERR(INTERNAL);
    return;
  }
  i64 id = q->id, region = sqlite3_column_int64(s, 0), category = sqlite3_column_int64(s, 1),
      status = sqlite3_column_int64(s, 2), updated_seq = sqlite3_column_int64(s, 3), owner = sqlite3_column_int64(s, 4);
  int responder = q->who.role != ROLE_CITIZEN && in_region(&q->who, region);
  if (!responder && owner != q->who.uid) { sqlite3_reset(s); j->resp = ERR(NO_INCIDENT); return; }
  out_t o0, *o = &o0;
  out_begin(o);
  if (responder) {
    i64 ts = sqlite3_column_int64(s, 5);
#define COL(i, name) int has_##name = sqlite3_column_type(s, i) != SQLITE_NULL; i64 name = sqlite3_column_int64(s, i);
    COL(6, at)
    int has_body = sqlite3_column_type(s, 7) != SQLITE_NULL;
    const u8 *body = sqlite3_column_text(s, 7);
    u32 body_len = (u32)sqlite3_column_bytes(s, 7);
    COL(8, lat) COL(9, lon)
#undef COL
    out_need(o, 279 + JSTR_ROOM(body_len));
  out_lit(o, "{\"id\":", 6);
  out_i64(o, id);
  out_lit(o, ",\"region\":", 10);
  out_i64(o, region);
  out_lit(o, ",\"category\":", 12);
  out_i64(o, category);
  out_lit(o, ",\"status\":", 10);
  out_i64(o, status);
  out_lit(o, ",\"updated_seq\":", 15);
  out_i64(o, updated_seq);
  out_lit(o, ",\"report\":{\"ts\":", 16);
  out_i64(o, ts);
  out_lit(o, ",\"at\":", 6);
  if (has_at) out_i64(o, at); else out_lit(o, "null", 4);
  out_lit(o, ",\"body\":", 8);
  if (has_body) out_jstr(o, body, body_len); else out_lit(o, "null", 4);
  out_lit(o, ",\"lat\":", 7);
  if (has_lat) out_i64(o, lat); else out_lit(o, "null", 4);
  out_lit(o, ",\"lon\":", 7);
  if (has_lon) out_i64(o, lon); else out_lit(o, "null", 4);
  out_lit(o, "}}", 2);
  } else {
    out_need(o, 154);
  out_lit(o, "{\"id\":", 6);
  out_i64(o, id);
  out_lit(o, ",\"region\":", 10);
  out_i64(o, region);
  out_lit(o, ",\"category\":", 12);
  out_i64(o, category);
  out_lit(o, ",\"status\":", 10);
  out_i64(o, status);
  out_lit(o, ",\"updated_seq\":", 15);
  out_i64(o, updated_seq);
  out_lit(o, "}", 1);
  }
  sqlite3_reset(s);
  j->resp = out_finish(o, HDR_200, sizeof HDR_200 - 1);
}

static void exec_read(job_t *j) {
  if (j->kind == K_SYNC) { exec_sync(j); return; }
  if (j->kind == K_INCIDENT) { exec_incident(j); return; }
  out_t o0, *o = &o0;
  out_begin(o);
  switch (j->kind) {
  case K_HEALTH: {
    int rc = sqlite3_step(Q_health);
    sqlite3_reset(Q_health);
    if (rc == SQLITE_ROW) {
      i64 uptime = now_s - started_at;
      out_need(o, 57);
  out_lit(o, "{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":", 36);
  out_i64(o, uptime);
  out_lit(o, "}", 1);
      j->resp = out_finish(o, HDR_200, sizeof HDR_200 - 1);
    } else {
      const u8 *msg = (const u8 *)sqlite3_errmsg(db);
      u32 msg_len = (u32)strlen((const char *)msg);
      out_need(o, 49 + JSTR_ROOM(msg_len));
  out_lit(o, "{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":", 48);
  out_jstr(o, msg, msg_len);
  out_lit(o, "}", 1);
      j->resp = out_finish(o, HDR_503, sizeof HDR_503 - 1);
    }
    return;
  }
  }
  out_abort(o);
}

/* ---- writes ------------------------------------------------------------------------------ */

/* Set when a write statement fails unexpectedly: the whole batch is rolled back and every
 * write in it is answered with an error, so a client retries (submissions are idempotent). */
static int batch_failed;

static void bind_opt(sqlite3_stmt *s, int i, int present, i64 v) {
  if (present) sqlite3_bind_int64(s, i, v); else sqlite3_bind_null(s, i);
}

static void stored_response(job_t *j, i64 seq, i64 incident, int duplicate) {
  out_t o0, *o = &o0;
  out_begin(o);
  if (duplicate) {
    out_need(o, 77);
  out_lit(o, "{\"seq\":", 7);
  out_i64(o, seq);
  out_lit(o, ",\"incident\":", 12);
  if (incident) out_i64(o, incident); else out_lit(o, "null", 4);
  out_lit(o, ",\"duplicate\":true}", 18);
    j->resp = out_finish(o, HDR_200, sizeof HDR_200 - 1);
  } else {
    out_need(o, 60);
  out_lit(o, "{\"seq\":", 7);
  out_i64(o, seq);
  out_lit(o, ",\"incident\":", 12);
  if (incident) out_i64(o, incident); else out_lit(o, "null", 4);
  out_lit(o, "}", 1);
    j->resp = out_finish(o, HDR_201, sizeof HDR_201 - 1);
  }
}

/* An update about an incident takes its region and category from the incident and must be a
 * permitted transition (Mina.Domain.transitions). Responders see only their regions. Returns 0
 * if the response has been decided. */
static int apply_transition(job_t *j, event_t *ev) {
  sqlite3_bind_int64(Q_incident_state, 1, ev->incident);
  int rc = sqlite3_step(Q_incident_state);
  i64 region = 0, category = 0, status = 0;
  if (rc == SQLITE_ROW) {
    region = sqlite3_column_int64(Q_incident_state, 0);
    category = sqlite3_column_int64(Q_incident_state, 1);
    status = sqlite3_column_int64(Q_incident_state, 2);
  }
  sqlite3_reset(Q_incident_state);
  if (rc != SQLITE_ROW && rc != SQLITE_DONE) { batch_failed = 1; return 0; }
  if (rc == SQLITE_DONE || !in_region(&ev->who, region)) { j->resp = ERR(NO_INCIDENT); return 0; }
  i64 target = KIND_SPECS[ev->kind].target ? KIND_SPECS[ev->kind].target : ev->status;
  if (status < STATUS_OPEN || status > STATUS_RESOLVED || !(TRANSITIONS[ev->kind][status] >> target & 1)) {
    j->resp = ERR(BAD_TRANSITION);
    return 0;
  }
  ev->region = region;
  ev->category = category;
  ev->status = target;
  ev->has |= F_REGION | F_CATEGORY | F_STATUS;
  return 1;
}

/* One submission, inside the batch transaction. A known event id is answered with what was
 * stored for it and changes nothing. */
static void exec_event(job_t *j) {
  event_t *ev = j->data;
  sqlite3_bind_blob(Q_by_eid, 1, ev->eid, 16, SQLITE_STATIC);
  int rc = sqlite3_step(Q_by_eid);
  if (rc == SQLITE_ROW) {
    i64 seq = sqlite3_column_int64(Q_by_eid, 0), incident = sqlite3_column_int64(Q_by_eid, 1),
        actor = sqlite3_column_int64(Q_by_eid, 2);
    sqlite3_reset(Q_by_eid);
    if (actor != ev->who.uid) j->resp = ERR(EID_USED);
    else stored_response(j, seq, incident, 1);
    return;
  }
  sqlite3_reset(Q_by_eid);
  if (rc != SQLITE_DONE) { batch_failed = 1; return; }
  int updates_incident = (KIND_SPECS[ev->kind].need & F_INCIDENT) != 0;
  if (updates_incident && !apply_transition(j, ev)) return;

  sqlite3_stmt *s = Q_event_insert;
  sqlite3_bind_blob(s, 1, ev->eid, 16, SQLITE_STATIC);
  sqlite3_bind_int64(s, 2, ev->region);
  sqlite3_bind_int(s, 3, KIND_SPECS[ev->kind].restricted);
  sqlite3_bind_int(s, 4, ev->kind);
  bind_opt(s, 5, ev->has & F_INCIDENT, ev->incident);
  bind_opt(s, 6, ev->has & F_CATEGORY, ev->category);
  bind_opt(s, 7, ev->has & F_STATUS, ev->status);
  sqlite3_bind_int64(s, 8, ev->who.uid);
  sqlite3_bind_int64(s, 9, now_s);
  bind_opt(s, 10, ev->has & F_AT, ev->at);
  bind_opt(s, 11, ev->has & F_LOCATION, ev->lat);
  bind_opt(s, 12, ev->has & F_LOCATION, ev->lon);
  if (ev->has & F_BODY) sqlite3_bind_text(s, 13, (const char *)ev->body, (int)ev->body_len, SQLITE_STATIC);
  else sqlite3_bind_null(s, 13);
  rc = sqlite3_step(s);
  i64 seq = 0, incident = 0;
  if (rc == SQLITE_ROW) { seq = sqlite3_column_int64(s, 0); incident = sqlite3_column_int64(s, 1); }
  sqlite3_reset(s);
  if (rc != SQLITE_ROW) { batch_failed = 1; return; }
  if (ev->kind == KIND_SOS_CREATED) {
    s = Q_incident_insert;
    sqlite3_bind_int64(s, 1, seq);
    sqlite3_bind_int64(s, 2, ev->who.uid);
    sqlite3_bind_int64(s, 3, ev->region);
    sqlite3_bind_int64(s, 4, ev->category);
    sqlite3_bind_int(s, 5, STATUS_OPEN);
    if (step_reset(s) != SQLITE_DONE) { batch_failed = 1; return; }
  } else if (updates_incident) {
    s = Q_incident_update;
    sqlite3_bind_int64(s, 1, ev->incident);
    sqlite3_bind_int64(s, 2, ev->status);
    sqlite3_bind_int64(s, 3, seq);
    if (step_reset(s) != SQLITE_DONE) { batch_failed = 1; return; }
  }
  stored_response(j, seq, incident, 0);
}

/* One batch = one transaction: reads (snapshot at batch start), then writes, then COMMIT.
 * No response leaves before the batch has committed. */
static void app_batch(job_t *js, int n) {
  int reads = 0, writes = 0;
  for (int i = 0; i < n; i++) if (js[i].kind) { if (js[i].is_write) writes++; else reads++; }
  if (reads || writes) {
    batch_failed = 0;
    db_batch_begin();
    for (int i = 0; i < n; i++) if (js[i].kind && !js[i].is_write) exec_read(&js[i]);
    for (int i = 0; i < n && !batch_failed; i++)
      if (js[i].kind && js[i].is_write) {
        exec_event(&js[i]);
        if (sqlite3_get_autocommit(db)) batch_failed = 1;   /* SQLite rolled the transaction back */
      }
    if (batch_failed) { fprintf(stderr, "batch rolled back: %s\n", sqlite3_errmsg(db)); db_batch_abort(); }
    else if (db_batch_end()) batch_failed = 1;
    if (batch_failed)
      for (int i = 0; i < n; i++)
        if (js[i].kind && js[i].is_write) { if (js[i].resp) obuf_release(js[i].resp); js[i].resp = ERR(INTERNAL); }
  }
  arena_used = 0;
}
