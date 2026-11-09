// Minimal native harness: feeds a byte file to libghostty-vt in fixed chunks
// and reports throughput, minor faults and user/sys time. No Dart, no FFI.
// usage: scrollback <file> <chunk> <runs> <mode> [n]
//   mode: default | unlimited | lines N | bytes N   (bytes: other limit unlimited)
#include <ghostty/vt.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static int cmp(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return (x > y) - (x < y); }

int main(int argc, char **argv) {
  FILE *f = fopen(argv[1], "rb"); fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
  uint8_t *buf = malloc(n); if (fread(buf, 1, n, f) != (size_t)n) return 1; fclose(f);
  size_t chunk = strtoul(argv[2], 0, 10); int runs = atoi(argv[3]); const char *mode = argv[4];
  size_t arg = argc > 5 ? strtoull(argv[5], 0, 10) : 0, unl = SIZE_MAX;
  double mbs[64]; long flt[64]; double us[64], sy[64];
  for (int r = -1; r < runs; r++) {
    GhosttyTerminal t; if (ghostty_terminal_new(NULL, &t, 200, 50) != GHOSTTY_SUCCESS) return 2;
    if (!strcmp(mode, "unlimited")) {
      ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &unl);
      ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &unl);
    } else if (!strcmp(mode, "lines")) {
      ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &unl);
      ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &arg);
    } else if (!strcmp(mode, "bytes")) {
      ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &arg);
    }
    struct rusage a, b; getrusage(RUSAGE_SELF, &a); double t0 = now();
    for (long i = 0; i < n; i += chunk) ghostty_terminal_vt_write(t, buf + i, (size_t)(i + (long)chunk > n ? n - i : (long)chunk));
    double dt = now() - t0; getrusage(RUSAGE_SELF, &b);
    ghostty_terminal_free(t);
    if (r < 0) continue;
    mbs[r] = n / dt / 1e6; flt[r] = b.ru_minflt - a.ru_minflt;
    us[r] = (b.ru_utime.tv_sec - a.ru_utime.tv_sec) * 1e3 + (b.ru_utime.tv_usec - a.ru_utime.tv_usec) / 1e3;
    sy[r] = (b.ru_stime.tv_sec - a.ru_stime.tv_sec) * 1e3 + (b.ru_stime.tv_usec - a.ru_stime.tv_usec) / 1e3;
  }
  double s[64]; memcpy(s, mbs, sizeof(double) * runs); qsort(s, runs, sizeof(double), cmp);
  int m = 0; for (int i = 0; i < runs; i++) if (mbs[i] == s[runs / 2]) m = i;
  printf("C %s %zu chunk=%zu median %.1f MB/s minflt=%ld user=%.0fms sys=%.0fms\n", mode, arg, chunk, mbs[m], flt[m], us[m], sy[m]);
  return 0;
}
