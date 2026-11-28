/* MINA load generator: N virtual users, one keep-alive HTTP/1.1 connection each, closed loop
 * with think times. The traffic is defined by a workload header chosen at compile time:
 *
 *   cc -O2 -pthread -DWORKLOAD='"workload_health.h"' -Ibench -o loadgen bench/loadgen.c
 *   loadgen <ip> <port> <users> <ramp_s> <hold_s> <rampdown_s> [threads] [source_ips] [workload_arg]
 *
 * A workload provides:
 *   wl_user                    per-user state
 *   WL_NOMINAL_RPS             requests per second per user at zero latency
 *   wl_init(arg)               load fixtures
 *   wl_first_delay_ms(rng)     delay between the user's arrival and its first request
 *   wl_request(u, rng, buf, cap) -> length of the next request
 *   wl_response(u, rng, status, body, len, &ok) -> think time in ms before the next request
 *   wl_report()                optional (define WL_HAS_REPORT): print more JSON members, each
 *                              starting with a comma
 *
 * Latency and throughput are measured over the hold phase only and printed as one JSON line.
 * source_ips spreads connections over several source addresses, so that one destination does
 * not exhaust the ephemeral port range: either a count (loopback targets only: that many
 * addresses from 127.0.0.2 up) or a comma-separated list of this machine's addresses. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

typedef uint64_t u64;
typedef uint32_t u32;

static inline u32 rnd(u32 *s) { *s ^= *s << 13; *s ^= *s >> 17; *s ^= *s << 5; return *s; }
static inline double between(u32 *s, double lo, double hi) { return lo + (hi - lo) * (rnd(s) / 4294967296.0); }

#ifndef WORKLOAD
#define WORKLOAD "workload_health.h"
#endif
#include WORKLOAD

#define WHEEL 65536            /* 1 ms slots; every delay is shorter than this */
#define RDBUF 65536
#define TIMEOUT_NS 60000000000ull
#define NHIST 3200

enum { U_NEW, U_CONNECTING, U_THINKING, U_WAITING, U_DONE };
enum { E_CONNECT, E_CLOSED, E_SEND, E_PROTOCOL, E_STATUS, E_TIMEOUT, NERR };
static const char *err_name[NERR] = {"connect", "closed", "send", "protocol", "status", "timeout"};

typedef struct user {
  struct user *next;           /* timer wheel chain */
  u64 sent_ns;
  char *part; u32 plen, pcap;  /* a response not yet complete */
  int fd;
  u32 rng, id;
  uint8_t state;
  wl_user w;
} user_t;

typedef struct {
  int ep, idx, n;
  user_t *users;
  user_t *wheel[WHEEL];
  u64 tick;                    /* next wheel slot to run, in ms since t0 */
  u64 due, done, sent_total, done_total, err[NERR], err_hold, hist[NHIST], max_us;
  long open, open_min_hold;
} thr_t;

static struct sockaddr_in dst;
static int nusers, nthreads, nsrc;
#define MAXSRC 64
static struct in_addr src[MAXSRC];
static double ramp_ms, hold_ms, down_ms;
static u64 t0;

static u64 now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (u64)t.tv_sec * 1000000000ull + (u64)t.tv_nsec; }
static inline double ms_since(u64 ns) { return (double)(ns - t0) / 1e6; }
static inline int in_hold(double ms) { return ms >= ramp_ms && ms < ramp_ms + hold_ms; }

/* log-linear histogram of microseconds: exact below 128, then 64 buckets per power of two */
static inline u32 hist_idx(u64 v) {
  if (v < 128) return (u32)v;
  int shift = 63 - __builtin_clzll(v) - 6;
  u32 i = 128 + (u32)(shift - 1) * 64 + (u32)((v >> shift) - 64);
  return i < NHIST ? i : NHIST - 1;
}
static inline u64 hist_val(u32 i) {
  if (i < 128) return i;
  u32 shift = (i - 128) / 64 + 1, sub = (i - 128) % 64;
  return (u64)(64 + sub + 1) << shift;
}

static void timer_add(thr_t *t, user_t *u, double delay_ms) {
  u64 at = (u64)(ms_since(now_ns()) + delay_ms);
  if (at < t->tick) at = t->tick;
  u->next = t->wheel[at % WHEEL];
  t->wheel[at % WHEEL] = u;
}

static void fail(thr_t *t, user_t *u, int kind) {
  t->err[kind]++;
  if (in_hold(ms_since(now_ns()))) t->err_hold++;
  if (u->fd >= 0) {
    if (u->state != U_CONNECTING) t->open--;
    close(u->fd);
    u->fd = -1;
  }
  free(u->part); u->part = 0; u->plen = u->pcap = 0;
  /* A user in U_THINKING already has a timer; the others need one to reconnect. */
  if (u->state != U_THINKING) { u->state = U_NEW; timer_add(t, u, 1000); }
}

static void do_connect(thr_t *t, user_t *u) {
  u->fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
  if (u->fd < 0) { u->state = U_CONNECTING; fail(t, u, E_CONNECT); return; }
  int one = 1;
  setsockopt(u->fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  if (nsrc > 0) {
    setsockopt(u->fd, IPPROTO_IP, IP_BIND_ADDRESS_NO_PORT, &one, sizeof one);
    struct sockaddr_in a = {.sin_family = AF_INET};
    a.sin_addr = src[u->id % (u32)nsrc];
    if (bind(u->fd, (struct sockaddr *)&a, sizeof a)) { u->state = U_CONNECTING; fail(t, u, E_CONNECT); return; }
  }
  u->state = U_CONNECTING;
  if (connect(u->fd, (struct sockaddr *)&dst, sizeof dst) && errno != EINPROGRESS) { fail(t, u, E_CONNECT); return; }
  struct epoll_event ev = {.events = EPOLLOUT, .data.ptr = u};
  epoll_ctl(t->ep, EPOLL_CTL_ADD, u->fd, &ev);
}

static void do_send(thr_t *t, user_t *u) {
  char req[2048];
  int n = wl_request(&u->w, &u->rng, req, sizeof req);
  u->sent_ns = now_ns();
  double ms = ms_since(u->sent_ns);
  t->sent_total++;
  if (in_hold(ms)) t->due++;
  u->state = U_WAITING;
  if (send(u->fd, req, (size_t)n, MSG_NOSIGNAL) != n) fail(t, u, E_SEND);
}

static void on_response(thr_t *t, user_t *u, const char *p, u32 hlen, u32 blen) {
  u64 now = now_ns();
  int status = atoi(p + 9), ok = 0;
  double think = wl_response(&u->w, &u->rng, status, p + hlen, blen, &ok);
  t->done_total++;
  if (!ok) { t->err[E_STATUS]++; if (in_hold(ms_since(now))) t->err_hold++; }
  if (in_hold(ms_since(now))) {
    u64 us = (now - u->sent_ns) / 1000;
    t->done++;
    t->hist[hist_idx(us)]++;
    if (us > t->max_us) t->max_us = us;
  }
  u->state = U_THINKING;
  timer_add(t, u, think);
}

static void do_recv(thr_t *t, user_t *u, char *buf) {
  u32 have = u->plen;
  if (have) memcpy(buf, u->part, have);
  ssize_t k = recv(u->fd, buf + have, RDBUF - 1 - have, 0);
  if (k < 0 && errno == EAGAIN) return;
  if (k <= 0) { fail(t, u, E_CLOSED); return; }
  have += (u32)k;
  buf[have] = 0;
  if (u->state != U_WAITING) { fail(t, u, E_PROTOCOL); return; }
  char *he = memmem(buf, have, "\r\n\r\n", 4);
  if (he) {
    u32 hlen = (u32)(he - buf) + 4;
    char *cl = memmem(buf, hlen, "Content-Length: ", 16);
    u32 blen = cl ? (u32)atoi(cl + 16) : 0;
    if (have >= hlen + blen) {
      if (have != hlen + blen || hlen < 12) { fail(t, u, E_PROTOCOL); return; }
      free(u->part); u->part = 0; u->plen = u->pcap = 0;
      on_response(t, u, buf, hlen, blen);
      return;
    }
  }
  if (have >= RDBUF - 1) { fail(t, u, E_PROTOCOL); return; }
  if (have > u->pcap) {
    u->pcap = have * 2;
    u->part = realloc(u->part, u->pcap);
    if (!u->part) { perror("realloc"); exit(1); }
  }
  memcpy(u->part, buf, have);
  u->plen = have;
}

static void on_timer(thr_t *t, user_t *u, double ms) {
  /* ramp-down: users leave evenly over down_ms after the hold */
  double leave = ramp_ms + hold_ms + down_ms * u->id / nusers;
  if (ms >= leave) {
    if (u->fd >= 0) { t->open--; close(u->fd); u->fd = -1; }
    u->state = U_DONE;
    return;
  }
  if (u->state == U_NEW) do_connect(t, u);
  else if (u->state == U_THINKING) {
    if (u->fd >= 0) do_send(t, u);
    else { u->state = U_NEW; do_connect(t, u); }
  }
}

static void *worker(void *arg) {
  thr_t *t = arg;
  char *buf = malloc(RDBUF);
  struct epoll_event evs[1024];
  /* Arrivals are spread over the ramp in id order. Those beyond one turn of the wheel are
   * inserted as their window comes up. */
  int late = 0;
  for (; late < t->n; late++) {
    user_t *u = &t->users[late];
    u64 at = (u64)(ramp_ms * u->id / nusers);
    if (at >= WHEEL) break;
    u->next = t->wheel[at];
    t->wheel[at] = u;
  }
  double end = ramp_ms + hold_ms + down_ms + 2000;
  u64 last_sweep = 0;
  t->open_min_hold = -1;
  for (;;) {
    int n = epoll_wait(t->ep, evs, 1024, 1);
    for (int i = 0; i < n; i++) {
      user_t *u = evs[i].data.ptr;
      if (u->fd < 0) continue;
      if (u->state == U_CONNECTING) {
        int err = 0; socklen_t l = sizeof err;
        getsockopt(u->fd, SOL_SOCKET, SO_ERROR, &err, &l);
        if (err || (evs[i].events & (EPOLLERR | EPOLLHUP))) { fail(t, u, E_CONNECT); continue; }
        struct epoll_event ev = {.events = EPOLLIN, .data.ptr = u};
        epoll_ctl(t->ep, EPOLL_CTL_MOD, u->fd, &ev);
        t->open++;
        u->state = U_THINKING;
        timer_add(t, u, wl_first_delay_ms(&u->rng));
      } else if (evs[i].events & (EPOLLIN | EPOLLERR | EPOLLHUP)) do_recv(t, u, buf);
    }
    double ms = ms_since(now_ns());
    while (late < t->n && ramp_ms * t->users[late].id / nusers < ms + WHEEL / 2) {
      user_t *u = &t->users[late++];
      timer_add(t, u, ramp_ms * u->id / nusers - ms);
    }
    while ((double)t->tick <= ms) {
      user_t *u = t->wheel[t->tick % WHEEL];
      t->wheel[t->tick % WHEEL] = 0;
      t->tick++;
      while (u) { user_t *nx = u->next; on_timer(t, u, ms); u = nx; }
    }
    if ((u64)(ms / 1000) != last_sweep) {
      last_sweep = (u64)(ms / 1000);
      if (in_hold(ms) && (t->open_min_hold < 0 || t->open < t->open_min_hold)) t->open_min_hold = t->open;
      u64 now = now_ns();
      for (int i = 0; i < t->n; i++)
        if (t->users[i].state == U_WAITING && now - t->users[i].sent_ns > TIMEOUT_NS) fail(t, &t->users[i], E_TIMEOUT);
    }
    if (ms >= end) break;
  }
  free(buf);
  return 0;
}

/* the source_ips argument into src[]; 0 when it is neither a count nor a list of addresses */
static int parse_sources(const char *arg) {
  char *end;
  long count = strtol(arg, &end, 10);
  if (end != arg && !*end) {
    if (count < 0 || count > MAXSRC) return 0;
    for (nsrc = 0; nsrc < count; nsrc++) src[nsrc].s_addr = htonl(0x7f000002u + (u32)nsrc);
    return 1;
  }
  for (const char *p = arg; ; p++) {
    char one[INET_ADDRSTRLEN];
    size_t n = strcspn(p, ",");
    if (n >= sizeof one || nsrc == MAXSRC) return 0;
    memcpy(one, p, n); one[n] = 0;
    if (inet_pton(AF_INET, one, &src[nsrc++]) != 1) return 0;
    p += n;
    if (!*p) return 1;
  }
}

int main(int argc, char **argv) {
  if (argc < 7) { fprintf(stderr, "usage: loadgen ip port users ramp_s hold_s rampdown_s [threads] [source_ips] [workload_arg]\n"); return 2; }
  dst.sin_family = AF_INET;
  if (inet_pton(AF_INET, argv[1], &dst.sin_addr) != 1) { fprintf(stderr, "bad ip\n"); return 2; }
  dst.sin_port = htons((uint16_t)atoi(argv[2]));
  nusers = atoi(argv[3]);
  ramp_ms = atof(argv[4]) * 1000; hold_ms = atof(argv[5]) * 1000; down_ms = atof(argv[6]) * 1000;
  nthreads = argc > 7 ? atoi(argv[7]) : 4;
  if (argc > 8 && !parse_sources(argv[8])) { fprintf(stderr, "bad source_ips\n"); return 2; }
  wl_init(argc > 9 ? argv[9] : 0);
  if (nusers < 1 || nthreads < 1 || nthreads > 64) { fprintf(stderr, "bad arguments\n"); return 2; }
  struct rlimit rl; getrlimit(RLIMIT_NOFILE, &rl); rl.rlim_cur = rl.rlim_max; setrlimit(RLIMIT_NOFILE, &rl);

  thr_t *th = calloc((size_t)nthreads, sizeof *th);
  pthread_t *id = calloc((size_t)nthreads, sizeof *id);
  user_t *all = calloc((size_t)nusers, sizeof *all);
  if (!th || !id || !all) { perror("calloc"); return 1; }
  /* users are interleaved across threads so each thread ramps at the same pace */
  int pos = 0;
  for (int k = 0; k < nthreads; k++) {
    th[k].idx = k; th[k].users = all + pos; th[k].ep = epoll_create1(0);
    for (int uid = k; uid < nusers; uid += nthreads) {
      user_t *u = &all[pos++];
      u->id = (u32)uid; u->fd = -1; u->rng = (u32)uid * 2654435761u + 1;
      rnd(&u->rng);
      th[k].n++;
    }
  }
  t0 = now_ns();
  for (int k = 0; k < nthreads; k++) pthread_create(&id[k], 0, worker, &th[k]);
  for (int k = 0; k < nthreads; k++) pthread_join(id[k], 0);

  static u64 hist[NHIST];
  u64 due = 0, done = 0, sent = 0, dt = 0, err[NERR] = {0}, eh = 0, mx = 0;
  long open_min = 0;
  for (int k = 0; k < nthreads; k++) {
    for (int i = 0; i < NHIST; i++) hist[i] += th[k].hist[i];
    for (int i = 0; i < NERR; i++) err[i] += th[k].err[i];
    due += th[k].due; done += th[k].done; sent += th[k].sent_total; dt += th[k].done_total; eh += th[k].err_hold;
    if (th[k].max_us > mx) mx = th[k].max_us;
    open_min += th[k].open_min_hold > 0 ? th[k].open_min_hold : 0;
  }
  double pct[4] = {0.50, 0.95, 0.99, 0.999}, val[4] = {0};
  u64 acc = 0;
  for (int i = 0, p = 0; i < NHIST && p < 4; i++) {
    acc += hist[i];
    while (p < 4 && done && (double)acc >= pct[p] * (double)done) val[p++] = (double)hist_val((u32)i) / 1000.0;
  }
  double hs = hold_ms / 1000;
  printf("{\"users\":%d,\"ramp_s\":%.0f,\"hold_s\":%.0f,\"rampdown_s\":%.0f,\"nominal_rps\":%.0f,"
         "\"sent_rps\":%.0f,\"achieved_rps\":%.0f,\"requests_in_hold\":%llu,\"open_conns_min_in_hold\":%ld,"
         "\"p50_ms\":%.3f,\"p95_ms\":%.3f,\"p99_ms\":%.3f,\"p999_ms\":%.3f,\"max_ms\":%.3f,"
         "\"requests_total\":%llu,\"responses_total\":%llu,\"errors_in_hold\":%llu,\"errors\":{",
         nusers, ramp_ms / 1000, hs, down_ms / 1000, nusers * WL_NOMINAL_RPS, (double)due / hs, (double)done / hs,
         (unsigned long long)done, open_min, val[0], val[1], val[2], val[3], (double)mx / 1000.0,
         (unsigned long long)sent, (unsigned long long)dt, (unsigned long long)eh);
  for (int i = 0; i < NERR; i++) printf("%s\"%s\":%llu", i ? "," : "", err_name[i], (unsigned long long)err[i]);
  printf("}");
#ifdef WL_HAS_REPORT
  wl_report();
#endif
  printf("}\n");
  return 0;
}
