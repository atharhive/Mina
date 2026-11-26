/* PID 1 of the virtual machine of tests/powerloss.mjs: mounts the disk, starts the server,
 * submits reports from several clients and writes every acknowledgement to the second console
 * (/dev/hvc0), which the host records. It only ever stops when the host cuts the power. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <fcntl.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <unistd.h>

#define CLIENTS 8
#define PORT 3000

static void die(const char *what) { perror(what); sleep(1); _exit(1); }  /* the kernel panics */

/* The value of key= on the kernel command line. */
static void boot_arg(const char *key, char *out, size_t n) {
  char line[2048] = " ";
  int fd = open("/proc/cmdline", O_RDONLY);
  if (fd < 0 || read(fd, line + 1, sizeof line - 2) < 0) die("cmdline");
  close(fd);
  char want[64];
  snprintf(want, sizeof want, " %s=", key);
  char *at = strstr(line, want);
  if (!at) die(key);
  at += strlen(want);
  snprintf(out, n, "%.*s", (int)strcspn(at, " \n"), at);
}

static int dial(void) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in to = {.sin_family = AF_INET, .sin_port = htons(PORT), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
  if (connect(fd, (struct sockaddr *)&to, sizeof to) == 0) return fd;
  close(fd);
  return -1;
}

static void client(unsigned boot, unsigned id, const char *token, int acks) {
  int fd;
  while ((fd = dial()) < 0) usleep(10000);
  for (unsigned n = 1;; n++) {
    char eid[33], body[256], req[2048], res[4096];
    snprintf(eid, sizeof eid, "%08x%08x%016x", boot, id, n);
    int blen = snprintf(body, sizeof body, "{\"eid\":\"%s\",\"kind\":1,\"region\":%u,\"category\":1,\"body\":\"power test\"}", eid, 1 + id % 4);
    int len = snprintf(req, sizeof req, "POST /v1/events HTTP/1.1\r\nHost: vm\r\nAuthorization: Bearer %s\r\nContent-Length: %d\r\n\r\n%s", token, blen, body);
    if (write(fd, req, (size_t)len) != len) die("send");
    size_t got = 0;
    for (;;) {                                           /* one whole answer */
      ssize_t r = read(fd, res + got, sizeof res - 1 - got);
      if (r <= 0) die("receive");
      got += (size_t)r;
      res[got] = 0;
      char *end = strstr(res, "\r\n\r\n"), *cl = strcasestr(res, "content-length:");
      if (end && cl && got >= (size_t)(end + 4 - res) + strtoul(cl + 15, 0, 10)) break;
    }
    char *seq = strstr(res, "\"seq\":");
    if (strncmp(res, "HTTP/1.1 201", 12) || !seq) { fprintf(stderr, "unexpected answer: %.300s\n", res); die("answer"); }
    char line[80];
    int k = snprintf(line, sizeof line, "A %s %lld\n", eid, strtoll(seq + 6, 0, 10));
    if (write(acks, line, (size_t)k) != k) die("console");
  }
}

int main(void) {
  mount("devtmpfs", "/dev", "devtmpfs", 0, 0);
  if (mount("proc", "/proc", "proc", 0, 0)) die("proc");
  int console = open("/dev/console", O_RDWR);
  if (console >= 0) { dup2(console, 1); dup2(console, 2); }
  for (int i = 0; i < 500 && (access("/dev/vda", F_OK) || access("/dev/hvc0", F_OK)); i++) usleep(10000);
  if (mount("/dev/vda", "/data", "ext4", 0, 0)) die("mount");

  struct ifreq lo = {.ifr_name = "lo"};
  int s = socket(AF_INET, SOCK_DGRAM, 0);
  if (ioctl(s, SIOCGIFFLAGS, &lo)) die("lo");
  lo.ifr_flags |= IFF_UP;
  if (ioctl(s, SIOCSIFFLAGS, &lo)) die("lo up");
  close(s);

  char sync[16], boot[16], token[1024] = "";
  boot_arg("mina.sync", sync, sizeof sync);
  boot_arg("mina.boot", boot, sizeof boot);
  int t = open("/token", O_RDONLY);
  if (t < 0 || read(t, token, sizeof token - 1) <= 0) die("token");
  token[strcspn(token, "\n")] = 0;

  if (fork() == 0) {
    char mode[32];
    snprintf(mode, sizeof mode, "MINA_SYNC=%s", sync);
    char *argv[] = {"/mina-server", 0};
    char *envp[] = {"MINA_DB=/data/m.db", "MINA_SECRET=0123456789abcdef0123456789abcdef", "MINA_PORT=3000", mode, 0};
    execve(argv[0], argv, envp);
    die("server");
  }
  int acks = open("/dev/hvc0", O_WRONLY | O_NOCTTY);
  if (acks < 0) die("hvc0");
  for (unsigned i = 0; i < CLIENTS; i++)
    if (fork() == 0) client((unsigned)strtoul(boot, 0, 10), i, token, acks);
  for (;;) pause();
}
