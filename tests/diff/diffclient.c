/* Sends one random request sequence to two servers, one after the other, and compares their
 * answers byte for byte. Timestamps assigned during the run differ between servers, so numbers
 * at or after the starting time are masked.
 *
 *   diffclient <portA> <portB> <requests> <seed> <head> <admin> <responder 1,2,3> <citizen> */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define RESP_MAX (1 << 21)
#define REQ_MAX 4096
#define HISTORY 256

static unsigned long long state;
static unsigned long long rnd(void) {
  unsigned long long z = (state += 0x9E3779B97F4A7C15ULL);
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
  return z ^ (z >> 31);
}
static long long below(long long n) { return (long long)(rnd() % (unsigned long long)n); }
static void die(const char *what) { perror(what); exit(2); }

static int dial(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((unsigned short)port)};
  inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
  if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a)) die("connect");
  return fd;
}
/* One request and its whole response. */
static size_t exchange(int fd, const char *req, size_t n, char *resp) {
  if (write(fd, req, n) != (ssize_t)n) die("write");
  size_t got = 0, want = 0;
  for (;;) {
    ssize_t r = read(fd, resp + got, RESP_MAX - 1 - got);
    if (r <= 0) die("read");
    got += (size_t)r;
    resp[got] = 0;
    if (!want) {
      char *end = strstr(resp, "\r\n\r\n"), *len = strstr(resp, "Content-Length: ");
      if (end && len) want = (size_t)(end + 4 - resp) + strtoul(len + 16, 0, 10);
    }
    if (want && got >= want) return got;
  }
}
/* Replace every number >= since with '#', and the Content-Length with it (digits are equal
 * in count, so lengths still agree). */
static size_t mask(char *s, size_t n, long long since) {
  size_t o = 0;
  for (size_t i = 0; i < n;) {
    if (s[i] >= '0' && s[i] <= '9') {
      size_t j = i;
      long long v = 0;
      while (j < n && s[j] >= '0' && s[j] <= '9') { if (v < 100000000000000LL) v = v * 10 + (s[j] - '0'); j++; }
      if (v >= since && v < since + 100000) s[o++] = '#';
      else { memmove(s + o, s + i, j - i); o += j - i; }
      i = j;
    } else s[o++] = s[i++];
  }
  return o;
}

int main(int argc, char **argv) {
  if (argc != 9) { fprintf(stderr, "usage: see the top of diffclient.c\n"); return 2; }
  int a = dial(atoi(argv[1])), b = dial(atoi(argv[2]));
  long long total = atoll(argv[3]), head = atoll(argv[5]), since = (long long)time(0) - 5;
  state = strtoull(argv[4], 0, 10);
  const char *tokens[3] = {argv[6], argv[7], argv[8]}, *admin = argv[6];
  static char ra[RESP_MAX], rb[RESP_MAX], req[REQ_MAX], history[HISTORY][REQ_MAX];
  static long long incidents[4096];
  long long nincidents = 0, nhistory = 0, eid = 1;
  long long full = 0, empty = 0, resync = 0, refused = 0, stored = 0, duplicate = 0, fetched = 0;
  static const char *texts[] = {"water rising", "say \\\"go\\\" \\\\ now", "line one\\nline two", "\xe2\x86\x92 north ridge \xc3\xa9\xc3\xa9"};
  for (long long i = 0; i < total; i++) {
    long long dice = below(100);
    size_t n;
    if (dice < 70) {                                                       /* synchronise */
      int region = (int)below(10) + 1;
      long long after;
      switch (below(6)) {
      case 0: after = 0; break;
      case 1: after = below(head + 1); break;
      case 2: case 3: after = head - below(40); break;
      case 4: after = head; break;
      default: after = head + 1 + below(3); break;
      }
      if (after < 0) after = 0;
      static const int limits[] = {0, 1, 2, 7, 64, 256};
      int limit = limits[below(6)];
      char lim[24] = "";
      if (limit) snprintf(lim, sizeof lim, "&limit=%d", limit);
      n = (size_t)snprintf(req, sizeof req, "GET /v1/sync?region=%d&after=%lld%s HTTP/1.1\r\nAuthorization: Bearer %s\r\n\r\n",
                           region, after, lim, tokens[below(3)]);
    } else if (dice < 75) {                                                /* one incident */
      long long id = nincidents && below(4) ? incidents[below(nincidents)] : below(head + 5) + 1;
      n = (size_t)snprintf(req, sizeof req, "GET /v1/incidents/%lld HTTP/1.1\r\nAuthorization: Bearer %s\r\n\r\n", id, tokens[below(3)]);
    } else if (dice < 80 && nhistory) {                                    /* a retry */
      strcpy(req, history[below(nhistory < HISTORY ? nhistory : HISTORY)]);
      n = strlen(req);
    } else {                                                               /* a submission */
      char body[512];
      int region = (int)below(8) + 1, kind = (int)below(6) + 1;
      long long inc = nincidents ? incidents[below(nincidents)] : 1;
      int k = snprintf(body, sizeof body, "{\"eid\":\"%032llx\",\"kind\":%d", (unsigned long long)(0x1000000 + eid++), kind);
      if (kind == 1) k += snprintf(body + k, sizeof body - (size_t)k, ",\"region\":%d,\"category\":%d,\"body\":\"%s\",\"lat\":%lld,\"lon\":%lld,\"at\":5",
                                   region, (int)below(5) + 1, texts[below(4)], below(200000) - 100000, below(200000) - 100000);
      else if (kind == 5) k += snprintf(body + k, sizeof body - (size_t)k, ",\"region\":%d,\"status\":%d", region, (int)below(2) + 1);
      else if (kind == 6) k += snprintf(body + k, sizeof body - (size_t)k, ",\"region\":%d,\"body\":\"%s\"", region, texts[below(4)]);
      else {
        k += snprintf(body + k, sizeof body - (size_t)k, ",\"incident\":%lld", inc);
        if (kind == 3) k += snprintf(body + k, sizeof body - (size_t)k, ",\"status\":%d", (int)below(2) + 2);
      }
      k += snprintf(body + k, sizeof body - (size_t)k, "}");
      n = (size_t)snprintf(req, sizeof req, "POST /v1/events HTTP/1.1\r\nAuthorization: Bearer %s\r\nContent-Length: %d\r\n\r\n%s", admin, k, body);
      strcpy(history[nhistory++ % HISTORY], req);
    }
    size_t na = exchange(a, req, n, ra), nb = exchange(b, req, n, rb);
    if (!strncmp(req, "POST", 4) && strstr(ra, "HTTP/1.1 201")) {
      char *s = strstr(ra, "\"seq\":"), *in = strstr(ra, "\"incident\":");
      long long seq = s ? atoll(s + 6) : 0;
      if (seq > head) head = seq;
      if (strstr(req, "\"kind\":1,") && in && nincidents < 4096) incidents[nincidents++] = atoll(in + 11);
      stored++;
    } else if (strstr(ra, "\"duplicate\":true")) duplicate++;
    else if (strstr(ra, "\"events\":[]")) empty++;
    else if (strstr(ra, "\"events\":[[")) full++;
    else if (strstr(ra, "\"resync\"")) resync++;
    else if (strstr(ra, "\"updated_seq\"")) fetched++;
    else refused++;
    na = mask(ra, na, since);
    nb = mask(rb, nb, since);
    if (na != nb || memcmp(ra, rb, na)) {
      printf("MISMATCH at request %lld\n--- request\n%s\n--- first server\n%.*s\n--- second server\n%.*s\n",
             i, req, (int)(na < 2000 ? na : 2000), ra, (int)(nb < 2000 ? nb : 2000), rb);
      return 1;
    }
  }
  printf("requests %lld: pages %lld, empty %lld, resync %lld, incidents %lld, stored %lld, duplicates %lld, refused %lld; mismatches 0\n",
         total, full, empty, resync, fetched, stored, duplicate, refused);
  /* every kind of answer must have occurred, or the run proves little */
  return full && empty && resync && fetched && stored && duplicate && refused ? 0 : 1;
}
