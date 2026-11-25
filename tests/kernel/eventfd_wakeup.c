/* Does a registered eventfd fire for every new batch of deferred task work? */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <linux/io_uring.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>
int main(void) {
  struct io_uring_params p; memset(&p, 0, sizeof p);
  p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_TASKRUN_FLAG;
  int fd = (int)syscall(__NR_io_uring_setup, 64, &p); if (fd < 0) { perror("setup"); return 2; }
  size_t sz = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
  size_t s2 = p.sq_off.array + p.sq_entries * 4; if (s2 > sz) sz = s2;
  char *m = mmap(0, sz, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, fd, IORING_OFF_SQ_RING);
  struct io_uring_sqe *sqes = mmap(0, p.sq_entries * sizeof *sqes, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_POPULATE, fd, IORING_OFF_SQES);
  unsigned *sqtail = (void*)(m + p.sq_off.tail), *sqflags = (void*)(m + p.sq_off.flags), *sqarr = (void*)(m + p.sq_off.array);
  unsigned *cqhead = (void*)(m + p.cq_off.head), *cqtail = (void*)(m + p.cq_off.tail);
  int efd = eventfd(0, EFD_NONBLOCK);
  if (syscall(__NR_io_uring_register, fd, IORING_REGISTER_EVENTFD, &efd, 1) < 0) { perror("reg"); return 2; }
  int l = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in a = {.sin_family = AF_INET}; a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  socklen_t al = sizeof a; bind(l, (void*)&a, al); listen(l, 64); getsockname(l, (void*)&a, &al);
  sqarr[0] = 0; struct io_uring_sqe *s = &sqes[0]; memset(s, 0, sizeof *s);
  s->opcode = IORING_OP_ACCEPT; s->fd = l; s->ioprio = IORING_ACCEPT_MULTISHOT;
  __atomic_store_n(sqtail, 1, __ATOMIC_RELEASE);
  syscall(__NR_io_uring_enter, fd, 1, 0, IORING_ENTER_GETEVENTS, 0, 0);
  int lost = 0;
  for (int i = 1; i <= 8; i++) {
    unsigned long long v; while (read(efd, &v, 8) == 8) {}
    int c = socket(AF_INET, SOCK_STREAM, 0);
    if (connect(c, (void*)&a, sizeof a)) { perror("connect"); return 2; }
    struct pollfd pf = {efd, POLLIN, 0};
    int r = poll(&pf, 1, 300);
    unsigned f = __atomic_load_n(sqflags, __ATOMIC_ACQUIRE);
    printf("connection %d: eventfd %s, SQ_TASKRUN %s\n", i, r > 0 ? "fired" : "SILENT", f & IORING_SQ_TASKRUN ? "pending" : "clear");
    lost += r <= 0 && (f & IORING_SQ_TASKRUN) != 0;
    syscall(__NR_io_uring_enter, fd, 0, 0, IORING_ENTER_GETEVENTS, 0, 0);
    unsigned t = __atomic_load_n(cqtail, __ATOMIC_ACQUIRE);
    __atomic_store_n(cqhead, t, __ATOMIC_RELEASE);
    usleep(100000);   /* let any deferred (RCU) signal land before draining */
    close(c);
  }
  printf("lost wakeups: %d of 8\n", lost);
  return lost ? 1 : 0;
}
