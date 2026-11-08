| stub.S - the ICE's debug monitor for the 68000 machine. It lives in the
| debug window at $FFD000, which only exists while the debug unit has the
| CPU (dbg68k.v); the debug unit enters it through the vector fetch of a
| level-7 interrupt it raised (stop, watchpoint), of a breakpoint (an
| ILLEGAL it showed in place of the instruction) or of the trace exception
| after a step. The stub saves the registers into the mailbox, tells the
| debug unit, and waits for the host's command:
|   1 continue, 2 step (trace one instruction), 3 enter the original
|   exception handler at the address in MB_ARG (not one of our breakpoints)
| Before going on it takes the registers back from the mailbox, so the host
| changes them by writing there. The exception frame is rebuilt below the
| saved SSP.
	.equ	MB, 0xffd800		| mailbox
	.equ	MB_USP, MB+0x3c
	.equ	MB_SSP, MB+0x40
	.equ	MB_SR, MB+0x44
	.equ	MB_PC, MB+0x48
	.equ	MB_CMD, MB+0x51		| byte, written by the host
	.equ	MB_ARG, MB+0x54
	.equ	CTL_STATE, 0xffdc00	| write: the registers are saved
	.equ	CTL_EXIT, 0xffdc02	| write: 0 continue, 1 step

	.text
	.globl	entry
entry:
	move.w	#0x2700,sr
	movem.l	d0-d7/a0-a6,MB
	move.l	usp,a0
	move.l	a0,MB_USP
	move.w	(sp),MB_SR
	and.w	#0x7fff,MB_SR		| a step's trace bit is ours, not the program's
	move.l	2(sp),MB_PC
	lea	6(sp),a0
	move.l	a0,MB_SSP
	clr.b	MB_CMD
	move.w	#1,CTL_STATE
wait:
	move.b	MB_CMD,d0
	beq.s	wait
	clr.b	MB_CMD
	cmp.b	#3,d0
	beq.s	chain
	| continue or step: rebuild the frame and return to it
	move.l	MB_SSP,a0
	move.l	MB_PC,-(a0)
	move.w	MB_SR,-(a0)
	cmp.b	#2,d0
	bne.s	1f
	or.w	#0x8000,(a0)		| T: trace one instruction
	move.l	a0,sp
	move.l	MB_USP,a0
	move.l	a0,usp
	movem.l	MB,d0-d7/a0-a6
	move.w	#1,CTL_EXIT
	rte
1:	move.l	a0,sp
	move.l	MB_USP,a0
	move.l	a0,usp
	movem.l	MB,d0-d7/a0-a6
	move.w	#0,CTL_EXIT
	rte
chain:
	| as if the exception had gone to its handler: frame, registers, jump
	move.l	MB_SSP,a0
	move.l	MB_PC,-(a0)
	move.w	MB_SR,-(a0)
	move.l	MB_ARG,-(a0)
	move.l	a0,sp
	move.l	MB_USP,a0
	move.l	a0,usp
	movem.l	MB,d0-d7/a0-a6
	move.w	#0,CTL_EXIT
	rts
