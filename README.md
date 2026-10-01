# Candidate 3: RV64 BEXT index sign extension

This package compares two supplied RV64 objects from the pinned LLVM revision
and the candidate 3 patch recorded in `metadata.txt`. The baseline kernel has
one `sext.w a1, a1` before `bext`; the patched kernel removes it. Both preserve
the cross-block branch and the third `i1` condition from the regression case.
The objects use RV64GC + Zbs and the LP64D ABI. No LLVM checkout or LLVM build
is needed on the server.

The benchmark exports `uint64_t candidate3_kernel(uint64_t data, uint64_t
index, _Bool condition)`. Every call passes `condition=true` and an index in
0..63, where the unsigned reference is `(data >> (index & 63)) & 1`. This
focused input domain avoids the original IR's shift poison for larger indices.
The workload does not measure the false-condition path or general application
performance. Local code-generation evidence is not a hardware speed claim.

On an X60 server, first confirm that the CPU implements RV64 and Zbs. The
compiler must support `-march=rv64gc_zbs -mabi=lp64d`, and the installed
binutils must decode BEXT. GNU GCC, Bash, GNU coreutils (`sha256sum`,
`mktemp`), `file`, `readelf`, `awk`, `find`, and `diff` are needed. A RISC-V capable GNU objdump
or llvm-objdump is required. `taskset` and `perf` are optional. When taskset is
present, CPU 1 must be usable in the process affinity mask, or select another
CPU explicitly. This script requires native `uname -m=riscv64`.

Keep the package under `~/llvm-project` on the server. From any directory run:

```sh
~/llvm-project/candidate3-riscv-server-validation/run-validation.sh
```

Defaults are `CC=gcc MARCH=rv64gc_zbs MABI=lp64d ITERS=10000000 ROUNDS=20 CPU=1`.
Overrides use environment variables; CC and OBJDUMP are executable names or
paths, not commands with embedded flags. For example:

```sh
CC=gcc OBJDUMP=objdump CPU=2 ITERS=10000000 ROUNDS=20 \
  ~/llvm-project/candidate3-riscv-server-validation/run-validation.sh
```

The script verifies `SHA256SUMS` before compiling or measuring and records
system, compiler, ISA options, and ELF ABI information. It compiles one shared
runner at `-O2 -fno-lto`, links each supplied object with `--no-relax`, and
extracts only `candidate3_kernel` from each final executable. It checks that
both contain BEXT and that removing exactly the baseline index sign extension
leaves identical instructions and branch destinations. Linked kernel listings,
canonical listings, and their diff are retained. Failure stops validation.

Correctness checks cover 0, 1, UINT64_MAX, both alternating-bit patterns, the
high bit, and 4096 deterministic random words, each at all 64 bit indices.
Both executables must pass before timing. A 100000-iteration comparison and
full-size warm-ups establish equal reference-checked checksums. Each measured
round repeats correctness checks, checks its checksum against an independent
reference computed outside the timer, and must match the warm-up checksum.
Odd rounds run baseline first; even rounds run candidate first. If available,
taskset pins all validation, warm-up, timing, and perf processes to the same CPU.

`CLOCK_MONOTONIC_RAW` measures only the varied-input external-kernel call loop.
Each successful benchmark ends with `mode=benchmark correctness=PASS`,
iterations, actual and reference checksums, and a final `elapsed_ns` field.
Timing includes random-input generation, call and loop overhead. This may
dilute a small kernel difference. `summary.txt` reports arithmetic mean times,
`candidate3_time_reduction_percent=100*(baseline-candidate)/baseline`, and
`speedup_factor=baseline/candidate`. Negative reductions are retained. Interpret the
individual rounds and system conditions alongside the averages; this package
does not declare that either version is faster.

When perf is installed, the script separately requests ten repetitions of
cycles, instructions, and task-clock for each version at the same iteration
count and affinity. Perf measures the whole process, including correctness,
reference work, and startup, whereas `elapsed_ns` covers the timed loop only.
Permission or counter failures are recorded without sudo and do not discard
the timing results. Check perf diagnostics before interpreting counters.

Results are written directly into `results/`; the script refuses to start if
that directory is nonempty. Preserve or move previous results before a rerun.
The compiler scratch directory is below `results/tmp/`, and supplied objects
are retained. The generated runner
object, executables, and results are ignored by the package `.gitignore`.
Preserve the results directory together with the package metadata and hashes
when reporting hardware measurements. The user may manually create or update
a separate Git repository for this package; the script does not initialize a
repository, commit, push, or contact a remote server.
