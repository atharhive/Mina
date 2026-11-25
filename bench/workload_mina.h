/* MINA workload. Every virtual user waits 5-15 s between requests (about 0.1 request/s), except
 * that a sync answer with "more" is followed up after 0.2-0.8 s. One user in 500 is a responder
 * of one region; the rest are citizens spread over all regions. The mix is fixed:
 *
 *   citizen (per request)                      responder (per request)
 *   92 %  sync of the region from its cursor   60 %  sync of the region (all events)
 *    3 %  read its own incident (*)            25 %  move a known incident on: acknowledge,
 *    2 %  report safety status                       in progress, resolve (*)
 *    1 %  report an emergency                  10 %  read that incident (*)
 *    2 %  retry its last submission (*)         5 %  publish an alert
 *   (*) a sync instead, when there is nothing to act on yet
 *
 * Responders learn of incidents from their own sync answers. Argument:
 * "<token key>:<newest seq at start>:<regions>"; users start with their cursor there. Session
 * creation is not part of the workload: tokens are signed by the generator.
 *
 * Build: cc ... -Ibench -Iruntime -Igen -DWORKLOAD='"workload_mina.h"' bench/loadgen.c bench/sign.c */
#include <time.h>

void sign_key(const char *secret);
void sign_token(long long sub, int region, char *out);

typedef struct {
  char token[200], last[200];            /* last: the body of the last submission */
  long long uid, cursor, mine, target;   /* mine, target: incidents (0: none) */
  unsigned count;
  unsigned short region;
  unsigned char responder, stage, expect;
} wl_user;

#define WL_NOMINAL_RPS (1.0 / 10.0)
#define WL_HAS_REPORT

enum { X_SYNC, X_INCIDENT, X_STORED, X_REPORT, X_DUPLICATE, X_ACTION };
enum { C_EMPTY, C_PAGES, C_EVENTS, C_INCIDENT, C_REPORT, C_SAFETY, C_ALERT, C_DUPLICATE, C_ACTION, C_CONFLICT, C_UNEXPECTED, NCOUNT };
static const char *wl_names[NCOUNT] = {"sync_empty", "sync_pages", "events_received", "incident_reads", "emergencies", "safety",
                                       "alerts", "duplicate_retries", "incident_updates", "update_conflicts", "unexpected"};
static unsigned long long wl_count[NCOUNT], wl_nonce;
static long long wl_users, wl_head;
static int wl_regions;
#define COUNT(c, n) __atomic_add_fetch(&wl_count[c], (n), __ATOMIC_RELAXED)

static void wl_init(const char *arg) {
  static char key[128];
  if (!arg || sscanf(arg, "%127[^:]:%lld:%d", key, &wl_head, &wl_regions) != 3 || wl_regions < 1) {
    fprintf(stderr, "workload_mina needs \"<token key>:<head>:<regions>\"\n");
    exit(2);
  }
  sign_key(key);
  wl_nonce = (unsigned long long)time(0);
}
static double wl_first_delay_ms(u32 *rng) { return between(rng, 0, 5000); }

static void wl_start(wl_user *u) {
  long long id = __atomic_fetch_add(&wl_users, 1, __ATOMIC_RELAXED);
  u->uid = id + 1;
  u->responder = id % 500 == 0;
  u->region = (unsigned short)((u->responder ? id / 500 : id) % wl_regions + 1);
  u->cursor = wl_head;
  sign_token(u->uid, u->responder ? u->region : 0, u->token);
}
static int wl_get(wl_user *u, char *buf, int cap, int incident) {
  if (incident) {
    u->expect = X_INCIDENT;
    return snprintf(buf, (size_t)cap, "GET /v1/incidents/%lld HTTP/1.1\r\nHost: mina\r\nAuthorization: Bearer %s\r\n\r\n",
                    u->responder ? u->target : u->mine, u->token);
  }
  u->expect = X_SYNC;
  return snprintf(buf, (size_t)cap, "GET /v1/sync?region=%d&after=%lld HTTP/1.1\r\nHost: mina\r\nAuthorization: Bearer %s\r\n\r\n",
                  u->region, u->cursor, u->token);
}
static int wl_post(wl_user *u, char *buf, int cap) {
  return snprintf(buf, (size_t)cap, "POST /v1/events HTTP/1.1\r\nHost: mina\r\nAuthorization: Bearer %s\r\nContent-Length: %zu\r\n\r\n%s",
                  u->token, strlen(u->last), u->last);
}
/* A new submission: fields is the JSON after the event id. */
static int wl_submit(wl_user *u, char *buf, int cap, int expect, const char *fields) {
  snprintf(u->last, sizeof u->last, "{\"eid\":\"%016llx%08llx%08x\",%s}", wl_nonce, (unsigned long long)u->uid, ++u->count, fields);
  u->expect = (unsigned char)expect;
  return wl_post(u, buf, cap);
}

static int wl_request(wl_user *u, u32 *rng, char *buf, int cap) {
  if (!u->uid) wl_start(u);
  u32 dice = rnd(rng) % 100;
  char f[128];
  if (u->responder) {
    if (dice >= 95) {
      snprintf(f, sizeof f, "\"kind\":6,\"region\":%d,\"body\":\"synthetic: shelter open at the school\"", u->region);
      COUNT(C_ALERT, 1);
      return wl_submit(u, buf, cap, X_STORED, f);
    }
    if (dice >= 85 && u->target) return wl_get(u, buf, cap, 1);
    if (dice >= 60 && dice < 85 && u->target) {
      if (u->stage == 0) snprintf(f, sizeof f, "\"kind\":2,\"incident\":%lld", u->target);
      else if (u->stage == 1) snprintf(f, sizeof f, "\"kind\":3,\"incident\":%lld,\"status\":3", u->target);
      else snprintf(f, sizeof f, "\"kind\":4,\"incident\":%lld", u->target);
      return wl_submit(u, buf, cap, X_ACTION, f);
    }
    return wl_get(u, buf, cap, 0);
  }
  if (dice >= 98 && u->last[0]) { u->expect = X_DUPLICATE; COUNT(C_DUPLICATE, 1); return wl_post(u, buf, cap); }
  if (dice == 97) {
    snprintf(f, sizeof f, "\"kind\":1,\"region\":%d,\"category\":%u,\"body\":\"synthetic: two people on the roof\",\"lat\":2812345,\"lon\":7712345",
             u->region, rnd(rng) % 5 + 1);
    COUNT(C_REPORT, 1);
    return wl_submit(u, buf, cap, X_REPORT, f);
  }
  if (dice >= 95 && dice < 97) {
    snprintf(f, sizeof f, "\"kind\":5,\"region\":%d,\"status\":%u", u->region, rnd(rng) % 2 + 1);
    COUNT(C_SAFETY, 1);
    return wl_submit(u, buf, cap, X_STORED, f);
  }
  if (dice >= 92 && dice < 95 && u->mine) return wl_get(u, buf, cap, 1);
  return wl_get(u, buf, cap, 0);
}

/* The first incident reported in a responder's page: [seq,1,ts,incident,... */
static void wl_find_incident(wl_user *u, const char *body) {
  const char *p = strstr(body, "\"events\":[");
  for (p = p ? p + 10 : 0; p && *p == '['; ) {
    char *q;
    strtoll(p + 1, &q, 10);
    long long kind = strtoll(q + 1, &q, 10);
    strtoll(q + 1, &q, 10);
    if (kind == 1) { u->target = strtoll(q + 1, 0, 10); u->stage = 0; return; }
    p = strstr(q, "],[");
    if (p) p += 2;
  }
}

static double wl_response(wl_user *u, u32 *rng, int status, const char *body, u32 len, int *ok) {
  (void)len;
  double think = between(rng, 5000, 15000);
  *ok = 0;
  switch (u->expect) {
  case X_SYNC: {
    const char *next = strstr(body, "\"next\":");
    if (status != 200 || !next) break;
    long long n = strtoll(next + 7, 0, 10);
    if (n < u->cursor) break;
    if (strstr(body, "\"events\":[]")) COUNT(C_EMPTY, 1);
    else {
      COUNT(C_PAGES, 1);
      unsigned long long events = 1;
      for (const char *p = body; (p = strstr(p + 1, "],[")); ) events++;
      COUNT(C_EVENTS, events);
      if (u->responder && !u->target) wl_find_incident(u, body);
    }
    u->cursor = n;
    if (strstr(next, "\"more\":true")) think = between(rng, 200, 800);
    *ok = 1;
    break;
  }
  case X_INCIDENT: *ok = status == 200; COUNT(C_INCIDENT, 1); break;
  case X_STORED: *ok = status == 201; break;
  case X_REPORT: {
    const char *in = strstr(body, "\"incident\":");
    if (status == 201 && in) { u->mine = strtoll(in + 11, 0, 10); *ok = 1; }
    break;
  }
  case X_DUPLICATE: *ok = status == 200 && strstr(body, "\"duplicate\":true"); break;
  case X_ACTION:
    if (status == 201) { COUNT(C_ACTION, 1); if (++u->stage == 3) u->target = 0; *ok = 1; }
    else if (status == 409) { COUNT(C_CONFLICT, 1); u->target = 0; *ok = 1; }   /* another responder moved it */
    break;
  }
  if (!*ok) {
    if (COUNT(C_UNEXPECTED, 1) <= 5) fprintf(stderr, "unexpected answer (expect %d): %d %.200s\n", u->expect, status, body);
  }
  return think;
}

/* Counts over the whole run, not only the hold phase. */
static void wl_report(void) {
  printf(",\"workload\":{\"regions\":%d", wl_regions);
  for (int i = 0; i < NCOUNT; i++) printf(",\"%s\":%llu", wl_names[i], wl_count[i]);
  printf("}");
}
