/* mina-admin seed: synthetic history as SQL on standard output, for an empty database. The same
 * arguments give the same bytes. Incidents follow the specification's transition table
 * (domain.h), so the data is a history the server could have produced. Nothing in it describes
 * a real person or place. */

#define SEED_EPOCH 1790000000LL

typedef struct { u32 id; u16 region; u8 category, status; u32 updated; } seed_incident;

static u64 seed_state;
static u64 rnd(void) {            /* splitmix64 */
  u64 z = (seed_state += 0x9E3779B97F4A7C15ULL);
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
  return z ^ (z >> 31);
}
static u64 below(u64 n) { return rnd() % n; }
/* Draws are sequenced in separate statements: C leaves the order of arguments open, and the
 * output must not depend on the compiler. */

static const char *SEED_TEXT[] = {
  "synthetic: need drinking water", "synthetic: road blocked by debris", "synthetic: two people on the roof",
  "synthetic: medical supplies running low", "synthetic: shelter open at the school", "synthetic: water level rising"};

static void seed_event(u32 seq, int region, int kind, u32 incident, int category, int status, int body, int location) {
  u64 a = rnd(), b = rnd();
  printf("INSERT INTO events VALUES(%u,x'%016llx%016llx',%d,%d,%d,", seq, a, b, region, KIND_SPECS[kind].restricted, kind);
  if (incident) printf("%u,", incident); else printf("NULL,");
  if (category) printf("%d,", category); else printf("NULL,");
  if (status) printf("%d,", status); else printf("NULL,");
  u64 actor = 1000 + below(100000);
  i64 ts = SEED_EPOCH + seq, age = (i64)below(600);
  printf("%llu,%lld,%lld,", actor, ts, ts - age);
  if (location) {
    i64 lat = (i64)below(2 * 100000 + 1) + 2800000;
    i64 lon = (i64)below(2 * 100000 + 1) + 7700000;
    printf("%lld,%lld,", lat, lon);
  } else printf("NULL,NULL,");
  if (body) printf("'%s');\n", SEED_TEXT[below(sizeof SEED_TEXT / sizeof *SEED_TEXT)]); else printf("NULL);\n");
}

static int seed_run(u32 events, u32 regions, u64 seed) {
  seed_incident *all = malloc(sizeof *all * events);
  u32 *open = malloc(sizeof *open * events), nall = 0, nopen = 0;
  if (!all || !open) { fprintf(stderr, "mina-admin: out of memory\n"); return 1; }
  seed_state = seed;
  printf("BEGIN;\n");
  for (u32 seq = 1; seq <= events; seq++) {
    u64 dice = below(100);
    int region = (int)below(regions) + 1;
    if (dice >= 75) {                                            /* alert: 10 %, safety: 15 % */
      if (dice >= 90) seed_event(seq, region, KIND_ALERT_PUBLISHED, 0, 0, 0, 1, 0);
      else {
        int safety = (int)below(2) + 1;
        int body = below(4) == 0;
        int location = below(2) == 0;
        seed_event(seq, region, KIND_SAFETY_REPORTED, 0, 0, safety, body, location);
      }
    } else if (dice >= 35 && nopen) {                            /* an incident moves on */
      u32 k = (u32)below(nopen);
      seed_incident *i = &all[open[k]];
      int kinds[16], targets[16], n = 0;
      for (int kind = 0; kind < KIND_COUNT; kind++)
        for (int t = STATUS_OPEN; t <= STATUS_RESOLVED; t++)
          if (TRANSITIONS[kind][i->status] >> t & 1) { kinds[n] = kind; targets[n++] = t; }
      int c = (int)below((u64)n);
      i->status = (u8)targets[c];
      i->updated = seq;
      seed_event(seq, i->region, kinds[c], i->id, i->category, i->status, 0, 0);
      if (i->status == STATUS_RESOLVED) open[k] = open[--nopen];
    } else {                                                     /* a new report */
      seed_incident *i = &all[nall];
      *i = (seed_incident){seq, (u16)region, (u8)(below(CATEGORY_MAX) + 1), STATUS_OPEN, seq};
      open[nopen++] = nall++;
      int body = below(3) != 0;
      int location = below(10) < 7;
      seed_event(seq, region, KIND_SOS_CREATED, seq, i->category, 0, body, location);
    }
  }
  /* owners are the actors of the opening reports */
  for (u32 k = 0; k < nall; k++)
    printf("INSERT INTO incidents SELECT %u,actor,%u,%u,%u,%u FROM events WHERE seq=%u;\n", all[k].id, all[k].region,
           all[k].category, all[k].status, all[k].updated, all[k].id);
  printf("COMMIT;\n");
  free(all);
  free(open);
  return fflush(stdout) || ferror(stdout) ? 1 : 0;
}
