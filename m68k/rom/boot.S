| boot.S - boot ROM of the Tiny68K-compatible machine on the Tang Nano 20K.
| At reset the ROM ($FF0000) also shows at $000000 for the reset vectors;
| the first instruction fetched from $FF0000 on hides it again.
|
| It asks which disk slot to boot (0-3, default 0 after about 2 s; slot n
| starts at card sector n * $100000) and tells the IDE bridge where the
| disk starts. Then, if sector $8000 of the slot holds a boot header
| ("RS68BOOT", load address, entry, sector count; written by
| tools/mksd68k.py), it loads that many sectors after it and starts at the
| entry; otherwise it does what the Tiny68K monitor's CP/M boot loader
| does: sector 1 to $15000 and start there (FUZIX's loader).
| Sectors are read as words from the IDE data register, so the image on the
| card has its bytes swapped, like the board's disks.
	.equ	DUART, 0xfff000
	.equ	SRA, 3
	.equ	THRA, 7
	.equ	RHRA, 7
	.equ	IDE, 0xffe000
	.equ	IDE_DATA, 0
	.equ	IDE_COUNT, 5
	.equ	IDE_LBA0, 7
	.equ	IDE_LBA1, 9
	.equ	IDE_LBA2, 11
	.equ	IDE_HEAD, 13
	.equ	IDE_CMD, 15
	.equ	IDE_BASE, 0xffe800
	.equ	IDE_READY, 0xffe805
	.equ	HDR, 0x14000		| boot header buffer

	.text
	.long	0x00800000		| SSP: top of the 8 MiB RAM
	.long	start
start:
	move.w	#0x2700,sr
	lea	banner(pc),a0
	bsr	puts
1:	btst	#0,IDE_READY		| SD card initialised
	beq.s	1b
	lea	prompt(pc),a0
	bsr	puts
	moveq	#0,d1			| slot
	.ifdef	SIM
	move.l	#2000,d2		| simulation: hardly wait
	.else
	move.l	#600000,d2		| about 2 s of polling at 8 MHz
	.endif
2:	btst	#0,DUART+SRA
	bne.s	3f
	subq.l	#1,d2
	bne.s	2b
	bra.s	4f
3:	move.b	DUART+RHRA,d0
	cmp.b	#'0',d0
	blt.s	4f
	cmp.b	#'3',d0
	bgt.s	4f
	sub.b	#'0',d0
	move.b	d0,d1
4:	move.b	d1,d0
	add.b	#'0',d0
	bsr	putc
	lea	crlf(pc),a0
	bsr	puts
	move.l	d1,d0
	swap	d0			| slot * $10000 ...
	lsl.l	#4,d0			| ... * 16 = slot * $100000
	move.l	d0,IDE_BASE		| big-endian: $FFE800-$FFE803
	| boot header?
	move.l	#0x8000,d0
	lea	HDR,a1
	bsr	readsec
	lea	HDR,a1
	cmp.l	#0x52533638,(a1)	| "RS68"
	bne.s	sector1
	cmp.l	#0x424f4f54,4(a1)	| "BOOT"
	bne.s	sector1
	move.l	8(a1),a2		| load address
	move.l	12(a1),a3		| entry
	move.l	16(a1),d3		| sectors
	lea	imgmsg(pc),a0
	bsr	puts
	move.l	#0x8001,d0
5:	move.l	a2,a1
	bsr	readsec
	add.l	#512,a2
	addq.l	#1,d0
	subq.l	#1,d3
	bne.s	5b
	jmp	(a3)
sector1:
	lea	secmsg(pc),a0
	bsr	puts
	moveq	#1,d0
	lea	0x15000,a1
	bsr	readsec
	jmp	0x15000

| Read sector d0 (of the slot) to a1 (512 bytes, as words).
readsec:
	lea	IDE,a0
1:	btst	#7,IDE_CMD(a0)		| BSY
	bne.s	1b
	move.b	#1,IDE_COUNT(a0)
	move.b	d0,IDE_LBA0(a0)
	move.l	d0,d4
	lsr.l	#8,d4
	move.b	d4,IDE_LBA1(a0)
	lsr.l	#8,d4
	move.b	d4,IDE_LBA2(a0)
	lsr.l	#8,d4
	and.b	#0x0f,d4
	or.b	#0xe0,d4
	move.b	d4,IDE_HEAD(a0)
	move.b	#0x20,IDE_CMD(a0)
2:	btst	#7,IDE_CMD(a0)
	bne.s	2b
	btst	#3,IDE_CMD(a0)		| DRQ
	beq.s	2b
	move.w	#255,d4
3:	move.w	IDE_DATA(a0),(a1)+
	dbra	d4,3b
	rts

puts:	move.b	(a0)+,d0
	beq.s	1f
	bsr.s	putc
	bra.s	puts
1:	rts
putc:	btst	#2,DUART+SRA
	beq.s	putc
	move.b	d0,DUART+THRA
	rts

banner:	.asciz	"\r\nrs6809-fpga Tiny68K (8 MiB) boot ROM\r\n"
prompt:	.asciz	"Boot slot [0-3, 0]: "
crlf:	.asciz	"\r\n"
imgmsg:	.asciz	"Loading the boot image\r\n"
secmsg:	.asciz	"Starting sector 1 at $15000\r\n"
	.even
