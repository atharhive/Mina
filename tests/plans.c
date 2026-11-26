/* The query plan of every statement in gen/queries.sql, from the SQLite version the server is
 * built with. No statement may scan a table or an index, or sort in a temporary B-tree: the
 * one exception is the startup query for the stream heads, which reads the index once.
 *   plans <schema.sql> <queries.sql> */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sqlite3.h"

static char *slurp(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); exit(2); }
  static char buf[2][65536];
  static int which;
  char *b = buf[which++ & 1];
  size_t n = fread(b, 1, sizeof buf[0] - 1, f);
  b[n] = 0;
  fclose(f);
  return b;
}

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  sqlite3 *db;
  char *err = 0;
  if (sqlite3_open(":memory:", &db) || sqlite3_exec(db, slurp(argv[1]), 0, 0, &err)) { fprintf(stderr, "schema: %s\n", err); return 2; }
  int statements = 0, bad = 0, region_searches = 0;
  for (char *line = strtok(slurp(argv[2]), "\n"); line; line = strtok(0, "\n")) {
    if (!strncmp(line, "--", 2) || !*line) continue;
    size_t n = strlen(line);
    if (line[n - 1] == ';') line[n - 1] = 0;
    int startup = strstr(line, "GROUP BY region, vis") != 0;
    char sql[4096];
    snprintf(sql, sizeof sql, "EXPLAIN QUERY PLAN %s", line);
    sqlite3_stmt *s;
    if (sqlite3_prepare_v2(db, sql, -1, &s, 0)) { fprintf(stderr, "  FAIL does not prepare: %s\n       %s\n", sqlite3_errmsg(db), line); bad++; continue; }
    statements++;
    while (sqlite3_step(s) == SQLITE_ROW) {
      const char *d = (const char *)sqlite3_column_text(s, 3);
      if (strstr(d, "events_region_vis (region=? AND vis=? AND rowid>?)")) region_searches++;
      int scan = !strncmp(d, "SCAN events", 11) || !strncmp(d, "SCAN incidents", 14) || strstr(d, "TEMP B-TREE") || !strncmp(d, "SCAN i", 6) || !strncmp(d, "SCAN e", 6);
      if (scan && !(startup && strstr(d, "COVERING INDEX events_region_vis"))) { printf("  FAIL %s\n       %s\n", d, line); bad++; }
    }
    sqlite3_finalize(s);
  }
  if (region_searches != 3) { printf("  FAIL expected 3 seeks of the region index past a cursor, found %d\n", region_searches); bad++; }
  printf("plans: %d statements, SQLite %s: %s\n", statements, sqlite3_libversion(), bad ? "FAILED" : "ok");
  return bad || statements < 10;
}
