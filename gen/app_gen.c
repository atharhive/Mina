/* GENERATED from the Lean specification in spec/ (Mina.Emit.appGen). Do not edit:
 * change the specification and run `lake exe derive ../gen` in spec/. */
#include "rt.h"
#include <stdio.h>
#include "domain.h"

/* ---- wire constants: Mina.Contract ----------------------------------------------------- */
static const u8 HDR_200[] = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ";
static const u8 HDR_503[] = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: ";

static const u8 E_NOT_FOUND[] = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 21\r\n\r\n{\"error\":\"not found\"}";  /* 404 not found */
#define ERR(name) obuf_static(E_##name, sizeof E_##name - 1)


enum { K_NONE = 0, K_HEALTH };

/* ---- stored layout: Mina.Schema --------------------------------------------------------- */
static int schema_check(void) {
  return table_layout("events", "seq:INTEGER:1,eid:BLOB:0,region:INTEGER:0,vis:INTEGER:0,kind:INTEGER:0,incident:INTEGER:0,category:INTEGER:0,status:INTEGER:0,actor:INTEGER:0,ts:INTEGER:0,at:INTEGER:0,lat:INTEGER:0,lon:INTEGER:0,body:TEXT:0") &&
         table_layout("incidents", "id:INTEGER:1,owner:INTEGER:0,region:INTEGER:0,category:INTEGER:0,status:INTEGER:0,updated_seq:INTEGER:0") &&
         index_layout("events_region_vis", "region,vis");
}

static sqlite3_stmt *Q_health;
static i64 started_at;

static void app_init(void) {
  if (!schema_check()) { fprintf(stderr, "fatal: the database does not have the MINA schema\n"); exit(1); }
  Q_health = db_prepare("SELECT 1");
  started_at = time(0);
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
  j->resp = ERR(NOT_FOUND);
}

/* ---- reads ------------------------------------------------------------------------------ */

static void exec_read(job_t *j) {
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

/* One batch = one transaction. No response leaves before the batch has ended. The contract
 * has no writes yet. */
static void app_batch(job_t *js, int n) {
  int reads = 0;
  for (int i = 0; i < n; i++) if (js[i].kind) reads++;
  if (!reads) return;
  db_batch_begin();
  for (int i = 0; i < n; i++) if (js[i].kind) exec_read(&js[i]);
  db_batch_end();
}
