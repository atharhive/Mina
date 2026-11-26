#include "rt.h"
#include <strings.h>

/* A web application compiled into the server (assets_gen.h, from tools/embed-assets.mjs): each
 * answer is a complete constant response, sent without copying. Paths match exactly, so there
 * is nothing to normalise and no file system to escape from. */

typedef struct { const u8 *p; u32 n; } blob;
typedef struct {
  const char *path; u32 path_len;
  const char *etag;
  blob br, gzip, plain, unchanged;     /* br and gzip are absent if they would not be smaller */
} asset;

#include "assets_gen.h"

/* Does an Accept-Encoding value allow this encoding? Whole names only; q=0 refuses it. */
static int accepts(const u8 *p, u32 n, const char *name) {
  const u8 *end = p + n;
  u32 len = (u32)strlen(name);
  while (p < end) {
    const u8 *comma = memchr(p, ',', (size_t)(end - p)), *stop = comma ? comma : end;
    while (p < stop && (*p == ' ' || *p == '\t')) p++;
    const u8 *q = p;
    while (q < stop && *q != ';' && *q != ' ' && *q != '\t') q++;
    if ((u32)(q - p) == len && !strncasecmp((const char *)p, name, len)) {
      while (q < stop && *q != '=') q++;
      if (q == stop) return 1;
      for (q++; q < stop; q++) if (*q >= '1' && *q <= '9') return 1;
      return 0;
    }
    p = stop + 1;
  }
  return 0;
}

/* The response for a GET, or 0 if no file has this path. */
static obuf *asset_serve(const req_t *rq) {
  const u8 *path = rq->path;
  u32 n = rq->path_len;
  u8 index[256];                             /* "<directory>/" means its index.html */
  if (n && path[n - 1] == '/' && n + 10 <= sizeof index) {
    memcpy(index, path, n);
    memcpy(index + n, "index.html", 10);
    path = index;
    n += 10;
  }
  for (int i = 0; i < ASSET_COUNT; i++) {
    const asset *a = &ASSETS[i];
    if (a->path_len != n || memcmp(a->path, path, n)) continue;
    if (rq->if_none_match_len && memmem(rq->if_none_match, rq->if_none_match_len, a->etag, strlen(a->etag)))
      return obuf_static(a->unchanged.p, a->unchanged.n);
    blob b = a->br.n && accepts(rq->accept_encoding, rq->accept_encoding_len, "br") ? a->br
           : a->gzip.n && accepts(rq->accept_encoding, rq->accept_encoding_len, "gzip") ? a->gzip
           : a->plain;
    return obuf_static(b.p, b.n);
  }
  return 0;
}
