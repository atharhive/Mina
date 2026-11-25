/* GENERATED from the Lean specification in spec/ (Mina.Emit.appGen). Do not edit:
 * change the specification and run `lake exe derive ../gen` in spec/. */
#include "rt.h"
#include <stdio.h>

/* ---- wire constants: Mina.Contract ----------------------------------------------------- */
@{HEADERS}
@{ERRORS}

@{KINDS}

static sqlite3_stmt *Q_health;
static i64 started_at;

static void app_init(void) {
  Q_health = db_prepare("SELECT 1");
  started_at = time(0);
}

/* ---- request decoding: Mina.Contract.routes --------------------------------------------- */
@{DECODE}
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
      @{HEALTH_BODY}
      j->resp = out_finish(o, @{HDR_OK}, sizeof @{HDR_OK} - 1);
    } else {
      const u8 *msg = (const u8 *)sqlite3_errmsg(db);
      u32 msg_len = (u32)strlen((const char *)msg);
      @{DEGRADED_BODY}
      j->resp = out_finish(o, @{HDR_UNAVAILABLE}, sizeof @{HDR_UNAVAILABLE} - 1);
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
