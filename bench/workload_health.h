/* Pipeline workload: every user asks for /v1/health, then waits 5-15 s. It exercises the
 * transport, request framing, routing and one read transaction per batch. */
typedef struct { char unused; } wl_user;

#define WL_NOMINAL_RPS (1.0 / 10.0)

static void wl_init(const char *arg) { (void)arg; }
static double wl_first_delay_ms(u32 *rng) { return between(rng, 0, 5000); }
static int wl_request(wl_user *u, u32 *rng, char *buf, int cap) {
  (void)u; (void)rng;
  return snprintf(buf, (size_t)cap, "GET /v1/health HTTP/1.1\r\nHost: mina\r\nUser-Agent: mina-loadgen\r\n\r\n");
}
static double wl_response(wl_user *u, u32 *rng, int status, const char *body, u32 len, int *ok) {
  (void)u; (void)body; (void)len;
  *ok = status == 200;
  return between(rng, 5000, 15000);
}
