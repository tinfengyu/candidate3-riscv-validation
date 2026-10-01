	.attribute	4, 16
	.attribute	5, "rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_zicsr2p0_zmmul1p0_zaamo1p0_zalrsc1p0_zca1p0_zcd1p0_zbs1p0"
	.file	"benchmark.ll"
	.text
	.globl	candidate3_kernel               # -- Begin function candidate3_kernel
	.p2align	1
	.type	candidate3_kernel,@function
candidate3_kernel:                      # @candidate3_kernel
	.cfi_startproc
# %bb.0:                                # %entry
	andi	a2, a2, 1
	beqz	a2, .LBB0_2
# %bb.1:                                # %extract
	bext	a0, a0, a1
	ret
.LBB0_2:                                # %other
	li	a0, 0
	ret
.Lfunc_end0:
	.size	candidate3_kernel, .Lfunc_end0-candidate3_kernel
	.cfi_endproc
                                        # -- End function
	.section	".note.GNU-stack","",@progbits
