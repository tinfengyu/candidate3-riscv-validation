; Derived from opt-w-instrs-bext.ll::bext_index at the validated pinned base.
; The runner always passes condition=true and index in [0,63].
; Retain the cross-block shape that exercises RISCVOptWInstrs.
target triple = "riscv64-unknown-linux-gnu"

define i64 @candidate3_kernel(i64 %data, i64 %index, i1 %condition) {
entry:
  br i1 %condition, label %extract, label %other
extract:
  %narrow = trunc i64 %index to i32
  %signed = sext i32 %narrow to i64
  %shift = lshr i64 %data, %signed
  %bit = and i64 %shift, 1
  ret i64 %bit
other:
  ret i64 0
}
