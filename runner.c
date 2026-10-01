#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

extern uint64_t candidate3_kernel(uint64_t data, uint64_t index, bool condition);

static uint64_t next_random(uint64_t *state) {
  *state ^= *state << 13;
  *state ^= *state >> 7;
  *state ^= *state << 17;
  return *state;
}

static uint64_t reference(uint64_t data, uint64_t index) {
  return (data >> (index & UINT64_C(63))) & UINT64_C(1);
}

static int check(uint64_t data, uint64_t index) {
  uint64_t expected = reference(data, index);
  uint64_t actual = candidate3_kernel(data, index, true);
  if (actual == expected)
    return 0;
  fprintf(stderr, "mismatch data=0x%016" PRIx64 " index=%" PRIu64
                  " expected=%" PRIu64 " actual=%" PRIu64 "\n",
          data, index, expected, actual);
  return 1;
}

static int correctness(void) {
  static const uint64_t data[] = {0, 1, UINT64_MAX,
                                 UINT64_C(0xaaaaaaaaaaaaaaaa),
                                 UINT64_C(0x5555555555555555),
                                 UINT64_C(0x8000000000000000)};
  /* All 64 indices include the important 0, 1, 31, 32, and 63 boundaries. */
  for (size_t i = 0; i < sizeof(data) / sizeof(data[0]); ++i)
    for (uint64_t index = 0; index < 64; ++index)
      if (check(data[i], index))
        return 1;
  uint64_t state = UINT64_C(0x6a09e667f3bcc909);
  for (unsigned i = 0; i < 4096; ++i) {
    uint64_t value = next_random(&state);
    for (uint64_t index = 0; index < 64; ++index)
      if (check(value, index))
        return 1;
  }
  puts("correctness=PASS");
  return 0;
}

static int parse_iterations(const char *text, uint64_t *iterations) {
  if (!*text)
    return 1;
  for (const char *p = text; *p; ++p)
    if (*p < '0' || *p > '9')
      return 1;
  errno = 0;
  char *end;
  unsigned long long value = strtoull(text, &end, 10);
  if (errno || *end || !value || value > UINT64_C(1000000000000))
    return 1;
  *iterations = (uint64_t)value;
  return 0;
}

int main(int argc, char **argv) {
  uint64_t iterations = 0;
  if (argc == 2 && strcmp(argv[1], "correctness") == 0)
    return correctness();
  if (argc != 3 || strcmp(argv[1], "benchmark") != 0 ||
      parse_iterations(argv[2], &iterations)) {
    fprintf(stderr, "usage: %s correctness | benchmark N (1..1000000000000)\n",
            argv[0]);
    return 2;
  }
  if (correctness())
    return 1;
  struct timespec start, finish;
  if (clock_gettime(CLOCK_MONOTONIC_RAW, &start)) {
    perror("clock_gettime");
    return 2;
  }
  uint64_t state = UINT64_C(0xbb67ae8584caa73b), checksum = 0;
  uint64_t expected_checksum = 0;
  for (uint64_t i = 0; i < iterations; ++i) {
    uint64_t data = next_random(&state);
    uint64_t index = i & UINT64_C(63);
    checksum += candidate3_kernel(data, index, true);
  }
  if (clock_gettime(CLOCK_MONOTONIC_RAW, &finish)) {
    perror("clock_gettime");
    return 2;
  }
  /* Compute the independent reference outside the measured region. */
  state = UINT64_C(0xbb67ae8584caa73b);
  for (uint64_t i = 0; i < iterations; ++i)
    expected_checksum += reference(next_random(&state), i & UINT64_C(63));
  if (checksum != expected_checksum) {
    fprintf(stderr, "checksum mismatch expected=%" PRIu64 " actual=%" PRIu64
                    "\n", expected_checksum, checksum);
    return 1;
  }
  if (finish.tv_sec < start.tv_sec ||
      (finish.tv_sec == start.tv_sec && finish.tv_nsec <= start.tv_nsec)) {
    fputs("non-positive monotonic elapsed time\n", stderr);
    return 2;
  }
  uint64_t seconds = (uint64_t)(finish.tv_sec - start.tv_sec);
  int64_t nanos = (int64_t)finish.tv_nsec - (int64_t)start.tv_nsec;
  if (nanos < 0) {
    --seconds;
    nanos += INT64_C(1000000000);
  }
  if (seconds > (UINT64_MAX - (uint64_t)nanos) / UINT64_C(1000000000)) {
    fputs("elapsed time overflow\n", stderr);
    return 2;
  }
  uint64_t elapsed = seconds * UINT64_C(1000000000) + (uint64_t)nanos;
  printf("mode=benchmark correctness=PASS iterations=%" PRIu64 " checksum=%" PRIu64
         " expected_checksum=%" PRIu64 " elapsed_ns=%" PRIu64 "\n",
         iterations, checksum, expected_checksum, elapsed);
  return 0;
}
