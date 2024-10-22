/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (C) 2019 Regents of the University of California
 */

/*
 * Arguments:
 *	a0: dest
 *	a1: src
 *	a2: n
 *
 * The including file must define the assembler macro:
 *
 *	access insn, reg, addr
 *
 * where 'insn' is a load or store instruction mnemonic, 'reg' is the
 * register holding data, and 'addr' is the memory address.
 *
 * In addition, the macro 'exit' must be defined with the function
 * epilogue.
 *
 * Must also define a temporary variable Ltempvar that can be used for the accelerator if enabled.
 *
 * The following caller-saved registers are clobbered by this routine:
 * a0-a1, a3-a7, t0-t5 (a2 and t6 are preserved)
 */

#include <asm/asm.h>

	.altmacro
	.macro __copy_template

	/*
	 * Save the terminal address which will be used to compute the number
	 * of bytes copied in case of a access exception.
	 */
	add	t5, a0, a2

#define MEMCPY_ACC
#ifdef  MEMCPY_ACC
	// if size is less than heuristic, use the cpu code
	// same as below
	li	a3, 9*SZREG /* size must be larger than size in word_copy */
	bltu	a2, a3, .Lcpu_memcpy

	// check if they are overlapping
	beq a0, a1, .Lcpu_memcpy
	// have t0 be the lesser value
	add t0, a0, x0
	add t1, a1, x0
	bltu t0, t1, .Lskip_swap
	// swap
	xor t0, t0, t1
	xor t1, t0, t1
	xor t0, t0, t1

.Lskip_swap:
	add t0, t0, a2
	bgtu t0, t1, .Lcpu_memcpy

	// memcpy accelerator here
	// a0 - dst, a1 - src, a2 - sz

	li a6, 4096

	// touch/pagein dst
	add a4, a0, 0 // dst copy
	add a5, a0, a2 // dst + size
	bleu a5, a4, .Lskip_dst_pgin
.Lpgin_loop0:
	access lb      x0, 0(a4)
	add a4, a4, a6
	bltu a4, a5, .Lpgin_loop0

.Lskip_dst_pgin:
	// touch/pagein now src
	add a4, a1, 0 // src copy
	add a5, a1, a2 // src + size
	bleu a5, a4, .Lskip_src_pgin
.Lpgin_loop1:
	access lb      x0, 0(a4)
	add a4, a4, a6
	bltu a4, a5, .Lpgin_loop1
.Lskip_src_pgin:

	// assumes no other accels, assumes no contention
	// cfg=0, accelid=0
	// rerocc acq
	li a6, 0x100
	csrw 0x810, a6 //0x100 //<-  (0x100 | (0 & 0xff))
	csrr a3, 0x810
	andi a3, a3, 0x100 // -> mask with 0x100
	beq x0, a3, .Lcpu_memcpy

	// set opc
	csrw 0x800, x0

	// fence (clear accel TLB)
	//ROCC_INSTRUCTION(/*OPC*/0, /*FUNCT*/0)
	.insn r CUSTOM_0, 0, 0, x0, x0, x0

	// start xact
	//ROCC_INSTRUCTION_SS(/*OPC*/0, a1, a2, /*FUNCT*/1)
	.insn r CUSTOM_0, 3, 1, x0, a1, a2
	// defined in main .S
	la a3, .Ltempvar
	access REG_S x0, 0(a3) // clear temp
	// ROCC_INSTRUCTION_SS(/*OPC*/0, a0, a3, /*FUNCT*/2)
	.insn r CUSTOM_0, 3, 2, x0, a0, a3

	// blocking
	//ROCC_INSTRUCTION_D(/*OPC*/0, a4, /*FUNCT*/3)
	.insn r CUSTOM_0, 4, 3, a4, x0, x0
.Lwait:
	fence
	access REG_L a4, 0(a3)
	beq x0, a4, .Lwait

	// release (and clear rerocc TLB)
	csrw 0x810, x0

	exit

#endif

.Lcpu_memcpy:

	/*
	 * Register allocation for code below:
	 * a0 - start of uncopied dst
	 * a1 - start of uncopied src
	 * a2 - size
	 * t0 - end of uncopied dst
	 */
	add	t0, a0, a2

	/*
	 * Use byte copy only if too small.
	 * SZREG holds 4 for RV32 and 8 for RV64
	 */
	li	a3, 9*SZREG /* size must be larger than size in word_copy */
	bltu	a2, a3, .Lbyte_copy_tail

	/*
	 * Copy first bytes until dst is aligned to word boundary.
	 * a0 - start of dst
	 * t1 - start of aligned dst
	 */
	addi	t1, a0, SZREG-1
	andi	t1, t1, ~(SZREG-1)
	/* dst is already aligned, skip */
	beq	a0, t1, .Lskip_align_dst
1:
	/* a5 - one byte for copying data */
	access lb      a5, 0(a1)
	addi	a1, a1, 1	/* src */
	access sb      a5, 0(a0)
	addi	a0, a0, 1	/* dst */
	bltu	a0, t1, 1b	/* t1 - start of aligned dst */

.Lskip_align_dst:
	/*
	 * Now dst is aligned.
	 * Use shift-copy if src is misaligned.
	 * Use word-copy if both src and dst are aligned because
	 * can not use shift-copy which do not require shifting
	 */
	/* a1 - start of src */
	andi	a3, a1, SZREG-1
	bnez	a3, .Lshift_copy

.Lword_copy:
        /*
	 * Both src and dst are aligned, unrolled word copy
	 *
	 * a0 - start of aligned dst
	 * a1 - start of aligned src
	 * t0 - end of aligned dst
	 */
	addi	t0, t0, -(8*SZREG) /* not to over run */
2:
	access REG_L   a4,        0(a1)
	access REG_L   a5,    SZREG(a1)
	access REG_L   a6,  2*SZREG(a1)
	access REG_L   a7,  3*SZREG(a1)
	access REG_L   t1,  4*SZREG(a1)
	access REG_L   t2,  5*SZREG(a1)
	access REG_L   t3,  6*SZREG(a1)
	access REG_L   t4,  7*SZREG(a1)
	access REG_S   a4,        0(a0)
	access REG_S   a5,    SZREG(a0)
	access REG_S   a6,  2*SZREG(a0)
	access REG_S   a7,  3*SZREG(a0)
	access REG_S   t1,  4*SZREG(a0)
	access REG_S   t2,  5*SZREG(a0)
	access REG_S   t3,  6*SZREG(a0)
	access REG_S   t4,  7*SZREG(a0)
	addi	a0, a0, 8*SZREG
	addi	a1, a1, 8*SZREG
	bltu	a0, t0, 2b

	addi	t0, t0, 8*SZREG /* revert to original value */
	j	.Lbyte_copy_tail

.Lshift_copy:

	/*
	 * Word copy with shifting.
	 * For misaligned copy we still perform aligned word copy, but
	 * we need to use the value fetched from the previous iteration and
	 * do some shifts.
	 * This is safe because reading is less than a word size.
	 *
	 * a0 - start of aligned dst
	 * a1 - start of src
	 * a3 - a1 & mask:(SZREG-1)
	 * t0 - end of uncopied dst
	 * t1 - end of aligned dst
	 */
	/* calculating aligned word boundary for dst */
	andi	t1, t0, ~(SZREG-1)
	/* Converting unaligned src to aligned src */
	andi	a1, a1, ~(SZREG-1)

	/*
	 * Calculate shifts
	 * t3 - prev shift
	 * t4 - current shift
	 */
	slli	t3, a3, 3 /* converting bytes in a3 to bits */
	li	a5, SZREG*8
	sub	t4, a5, t3

	/* Load the first word to combine with second word */
	access REG_L   a5, 0(a1)

3:
	/* Main shifting copy
	 *
	 * a0 - start of aligned dst
	 * a1 - start of aligned src
	 * t1 - end of aligned dst
	 */

	/* At least one iteration will be executed */
	srl	a4, a5, t3
	access REG_L   a5, SZREG(a1)
	addi	a1, a1, SZREG
	sll	a2, a5, t4
	or	a2, a2, a4
	access REG_S   a2, 0(a0)
	addi	a0, a0, SZREG
	bltu	a0, t1, 3b

	/* Revert src to original unaligned value  */
	add	a1, a1, a3

.Lbyte_copy_tail:
	/*
	 * Byte copy anything left.
	 *
	 * a0 - start of remaining dst
	 * a1 - start of remaining src
	 * t0 - end of remaining dst
	 */
	bgeu	a0, t0, .Lout_copy_user  /* check if end of copy */
4:
	access lb      a5, 0(a1)
	addi	a1, a1, 1	/* src */
	access sb      a5, 0(a0)
	addi	a0, a0, 1	/* dst */
	bltu	a0, t0, 4b	/* t0 - end of dst */

.Lout_copy_user:
	exit

	.endm /* __copy_template */
