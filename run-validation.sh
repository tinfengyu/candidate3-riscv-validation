#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
CC=${CC:-gcc}
MARCH=${MARCH:-rv64gc_zbs}
MABI=${MABI:-lp64d}
ITERS=${ITERS:-10000000}
ROUNDS=${ROUNDS:-20}
CPU=${CPU:-1}
fail() { echo "ERROR: $*" >&2; exit 1; }
positive() {
  [[ $2 =~ ^[1-9][0-9]*$ && ${#2} -le ${#3} ]] || fail "$1 must be an integer in 1..$3"
  [[ ${#2} -lt ${#3} || $2 < $3 || $2 == "$3" ]] || fail "$1 exceeds $3"
}
positive ITERS "$ITERS" 1000000000000
positive ROUNDS "$ROUNDS" 10000
[[ $CPU =~ ^(0|[1-9][0-9]*)$ && ${#CPU} -le 9 ]] || fail 'CPU must be a nonnegative CPU number'
[[ $(uname -m) == riscv64 ]] || fail 'Run this script natively on an RV64 RISC-V server'
[[ $MABI == lp64d ]] || fail 'The supplied objects require MABI=lp64d'
for tool in sha256sum file readelf awk diff mktemp find; do
  command -v "$tool" >/dev/null || fail "Required tool missing: $tool"
done
command -v "$CC" >/dev/null || fail "Compiler missing: $CC (use an executable name/path)"
if [[ -d results ]]; then
  [[ -z $(find results -mindepth 1 -maxdepth 1 -print -quit) ]] || fail "results is nonempty; preserve or move it before a new run"
fi
mkdir -p results/tmp
RESULTS=results
TMPDIR=$(mktemp -d results/tmp/build-XXXXXXXX)
export TMPDIR
cleanup() {
  for scratch in header.txt probe.txt probe.err disassembly.txt; do
    [[ ! -f $TMPDIR/$scratch ]] || rm -- "$TMPDIR/$scratch"
  done
  rmdir -- "$TMPDIR" 2>/dev/null || true
  rmdir -- results/tmp 2>/dev/null || true
}
trap cleanup EXIT
sha256sum -c SHA256SUMS | tee "$RESULTS/sha256-check.txt"
{
  uname -a
  uname -m
  if command -v lscpu >/dev/null; then lscpu; fi
  if [[ -r /proc/cpuinfo ]]; then cat /proc/cpuinfo; fi
  "$CC" --version
  "$CC" -dumpmachine || echo 'Compiler target query unavailable'
  printf 'CC=%s MARCH=%s MABI=%s ITERS=%s ROUNDS=%s CPU=%s\n' "$CC" "$MARCH" "$MABI" "$ITERS" "$ROUNDS" "$CPU"
} | tee "$RESULTS/system.txt"
check_elf() {
  local target=$1
  local required_type=${2:-}
  file "$target" | tee -a "$RESULTS/file.txt"
  readelf -h "$target" > "$TMPDIR/header.txt"
  cat "$TMPDIR/header.txt" >> "$RESULTS/elf.txt"
  readelf -A "$target" >> "$RESULTS/elf.txt"
  awk -v required_type="$required_type" '/Class:/ && /ELF64/ {c=1} /Machine:/ && /RISC-V/ {m=1} /Flags:/ && /double-float ABI/ {a=1} /Type:/ {type=$2} END {exit !(c && m && a && (!required_type || type==required_type))}' "$TMPDIR/header.txt" || fail "$target must be ELF64 RISC-V with the double-float ABI and expected ELF type"
}
check_elf baseline.o REL
check_elf candidate3.o REL
"$CC" -O2 -fno-lto -march="$MARCH" -mabi="$MABI" -c runner.c -o runner.o
for name in baseline candidate3; do
  "$CC" -fno-lto -march="$MARCH" -mabi="$MABI" -Wl,--no-relax runner.o "$name.o" -o "$name-run"
  check_elf "$name-run"
done
if [[ -z ${OBJDUMP:-} ]]; then
  for tool in objdump llvm-objdump riscv64-linux-gnu-objdump; do
    if command -v "$tool" >/dev/null && "$tool" -d --no-show-raw-insn baseline-run > "$TMPDIR/probe.txt" 2> "$TMPDIR/probe.err"; then
      OBJDUMP=$tool
      break
    fi
  done
fi
[[ -n ${OBJDUMP:-} ]] || fail 'No usable disassembler; set OBJDUMP to a RISC-V capable objdump/llvm-objdump'
printf 'OBJDUMP=%s\n' "$OBJDUMP" >> "$RESULTS/system.txt"
for name in baseline candidate3; do
  "$OBJDUMP" -d --no-show-raw-insn "$name-run" > "$TMPDIR/disassembly.txt"
  symbol=$(readelf -sW "$name-run" | awk '$4=="FUNC" && $8=="candidate3_kernel" && !found {address=$2; size=$3; found=1} END {if(found) print address, size}')
  [[ $symbol =~ ^[[:xdigit:]]+[[:space:]][1-9][0-9]*$ ]] || fail "Missing sized $name kernel symbol"
  read -r symbol_address symbol_size <<< "$symbol"
  awk -v start="$symbol_address" -v size="$symbol_size" '
    function hex(s, value,j,digit) {
      s=tolower(s); value=0
      for(j=1;j<=length(s);j++) {
        digit=index("0123456789abcdef",substr(s,j,1))-1
        value=value*16+digit
      }
      return value
    }
    BEGIN {first=hex(start); last=first+size}
    /^[[:xdigit:]]+ <candidate3_kernel>:/ {p=1; print; next}
    p && /^[[:space:]]*[[:xdigit:]]+:/ {
      address=$1; sub(/:$/, "", address)
      if(hex(address)>=last) exit
      if(hex(address)>=first) print
    }' "$TMPDIR/disassembly.txt" > "$RESULTS/$name-kernel.txt"
  [[ -s $RESULTS/$name-kernel.txt ]] || fail "Missing $name linked kernel"
  cat "$RESULTS/$name-kernel.txt"
  # Resolve branch destinations to instruction ordinals after removing the one
  # expected baseline sign extension. This checks control flow as well as ops.
  awk -v baseline="$([[ $name == baseline ]] && echo 1 || echo 0)" '
    function key(s) {sub(/^0x/, "", s); sub(/^0+/, "", s); return tolower(s)}
    /^[[:space:]]*[[:xdigit:]]+:/ {
      line=$0; sub(/^[[:space:]]*/, "", line)
      addr=line; sub(/:.*/, "", addr)
      sub(/^[^:]*:[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*/, "", line)
      op=line; sub(/[[:space:]].*/, "", op)
      args=line; sub(/^[^[:space:]]+[[:space:]]*/, "", args)
      if (args==op) args=""
      gsub(/[[:space:]]+/, "", args)
      sext=((op=="sext.w" && args=="a1,a1") || (op=="addiw" && args=="a1,a1,0") || (op=="c.addiw" && args=="a1,0"))
      if (sext) {removed++; if (!baseline) bad=1; next}
      n++; addresses[key(addr)]=n; ops[n]=op; operands[n]=args
      if (op=="bext") bext++
    }
    END {
      if (bad || bext!=1 || (baseline && removed!=1) || (!baseline && removed!=0) || n!=6) exit 1
      for (i=1;i<=n;i++) {
        arg=operands[i]
        if (ops[i] ~ /^(c\.)?b(eq|ne|lt|ge|gt|le)/) {
          count=split(arg,parts,","); dest=parts[count]; sub(/<.*/, "", dest)
          if (!(key(dest) in addresses)) exit 1
          sub(/[^,]+$/, "target" addresses[key(dest)], arg)
        }
        print ops[i] " " arg
      }
    }' "$RESULTS/$name-kernel.txt" > "$RESULTS/$name-kernel.canonical" || fail "Unexpected $name kernel instruction shape"
done
diff -u "$RESULTS/baseline-kernel.txt" "$RESULTS/candidate3-kernel.txt" > "$RESULTS/final-codegen.diff" || [[ $? == 1 ]]
diff -u "$RESULTS/baseline-kernel.canonical" "$RESULTS/candidate3-kernel.canonical" > "$RESULTS/canonical.diff" || fail 'Linked kernels differ beyond the expected index sign extension'
RUNNER=()
if command -v taskset >/dev/null; then
  taskset -c "$CPU" true || fail "CPU=$CPU is unavailable in the current affinity mask"
  RUNNER=(taskset -c "$CPU")
else
  echo 'taskset unavailable: measurements are unpinned' | tee "$RESULTS/affinity.txt"
fi
for name in baseline candidate3; do
  "${RUNNER[@]}" "./$name-run" correctness | tee "$RESULTS/correctness-$name.txt"
  [[ $(cat "$RESULTS/correctness-$name.txt") == correctness=PASS ]] || fail "$name correctness did not report PASS"
done
# Each benchmark invocation checks against a reference checksum outside timing.
validate_output() {
  local path=$1 expected_iters=$2
  awk -v iterations="$expected_iters" '
    /^correctness=PASS$/ {pass++}
    /^mode=benchmark correctness=PASS iterations=[0-9]+ checksum=[0-9]+ expected_checksum=[0-9]+ elapsed_ns=[0-9]+$/ {
      split($3,i,"="); split($4,c,"="); split($5,e,"="); split($6,t,"=")
      if (i[2]!=iterations || c[2]!=e[2] || t[2]+0<=0) bad=1
      rows++
    }
    END {exit !(pass==1 && rows==1 && !bad)}' "$path" || fail "Invalid benchmark output in $path"
}
checksum() { awk '/^mode=benchmark correctness=PASS iterations=[0-9]+ checksum=[0-9]+ expected_checksum=[0-9]+ elapsed_ns=[0-9]+$/ {split($4,a,"="); print a[2]}' "$1"; }
for name in baseline candidate3; do
  "${RUNNER[@]}" "./$name-run" benchmark 100000 | tee "$RESULTS/checksum-$name.txt"
  validate_output "$RESULTS/checksum-$name.txt" 100000
  "${RUNNER[@]}" "./$name-run" benchmark "$ITERS" > "$RESULTS/warmup-$name.txt"
  validate_output "$RESULTS/warmup-$name.txt" "$ITERS"
done
[[ $(checksum "$RESULTS/checksum-baseline.txt") == "$(checksum "$RESULTS/checksum-candidate3.txt")" ]] || fail 'Moderate-run checksum mismatch'
EXPECTED=$(checksum "$RESULTS/warmup-baseline.txt")
[[ $EXPECTED == "$(checksum "$RESULTS/warmup-candidate3.txt")" ]] || fail 'Warm-up checksum mismatch'
for ((round=1; round<=ROUNDS; round++)); do
  names=(baseline candidate3)
  if ((round % 2 == 0)); then names=(candidate3 baseline); fi
  for name in "${names[@]}"; do
    output="$RESULTS/$name-round-$round.txt"
    "${RUNNER[@]}" "./$name-run" benchmark "$ITERS" | tee "$output"
    validate_output "$output" "$ITERS"
    [[ $(checksum "$output") == "$EXPECTED" ]] || fail "Round $round $name checksum mismatch"
    cat "$output" >> "$RESULTS/$name-runs.txt"
  done
done
average() {
  awk -v rounds="$ROUNDS" '/ elapsed_ns=[0-9]+$/ {split($NF,a,"="); sum+=a[2]; n++} END {if(n!=rounds) exit 1; printf "%.3f",sum/n}' "$1"
}
BASE_AVG=$(average "$RESULTS/baseline-runs.txt")
CAND_AVG=$(average "$RESULTS/candidate3-runs.txt")
awk -v b="$BASE_AVG" -v c="$CAND_AVG" 'BEGIN {
  printf "baseline_avg_ns=%.3f\ncandidate3_avg_ns=%.3f\ncandidate3_time_reduction_percent=%.6f\nspeedup_factor=%.6f\n",b,c,100*(b-c)/b,b/c
}' | tee "$RESULTS/summary.txt"
if command -v perf >/dev/null; then
  for name in baseline candidate3; do
    if perf stat -r 10 -e cycles,instructions,task-clock "${RUNNER[@]}" "./$name-run" benchmark "$ITERS" > "$RESULTS/perf-$name.stdout.txt" 2> "$RESULTS/perf-$name.txt"; then
      echo 'perf_status=PASS' >> "$RESULTS/perf-$name.txt"
    else
      echo 'perf_status=UNAVAILABLE_OR_FAILED (see diagnostic above; no privilege escalation)' >> "$RESULTS/perf-$name.txt"
    fi
  done
else
  echo 'perf not installed; counters skipped' > "$RESULTS/perf-status.txt"
fi
printf 'Measurements complete. Results: %s/%s\n' "$PWD" "$RESULTS"
