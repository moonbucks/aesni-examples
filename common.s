# Make a Linux syscall.
.macro linux_syscall NR ARG1 ARG2 ARG3
    mov \NR,   %rax
    mov \ARG1, %rdi
.ifnb \ARG2
    mov \ARG2, %rsi
.ifnb \ARG3
    mov \ARG3, %rdx
.endif
.endif
    syscall
.endm

# Syscall numbers.
.equ NR_read,   0
.equ NR_write,  1
.equ NR_exit,  60

# Compute one AES round key.
#
# in  RCON   = round constant immediate
#     DEST   = register to store the (possibly inverse) key
#     INV    = if 1, use the AESIMC instruction to compute
#              a key for the Equivalent Inverse Cipher
#
#     %xmm0  = previous round key, non-inverse
#              (initially, user key)
#     %xmm2  = first word is 0
#
# out DEST  <- round key
#     %xmm0 <- round key, non-inverse
#     %xmm2 <- first word is still 0
.macro key_expand RCON DEST INV=0
    aeskeygenassist \RCON, %xmm0, %xmm1
    call key_combine
.if \INV
    aesimc %xmm0, \DEST
.else
    movaps %xmm0, \DEST
.endif
.endm

.text

# XOR together previous round key bytes and the output of
# AESKEYGENASSIST to get a new round key.
#
# Based on clever code from Linux:
# http://lxr.linux.no/linux+v3.7.4/arch/x86/crypto/aesni-intel_asm.S#L1707
#
# in  %xmm0  = previous round key, non-inverse
#     %xmm1  = AESKEYGENASSIST result
#     %xmm2  = first word is 0
#
# out %xmm0 <- round key
#     %xmm2 <- first word is still 0
key_combine:

    # %xmm0 = P0 P1 P2 P3
    # %xmm2 = 0  ?  ?  ?
    # %xmm1 = ?  ?  ?  V  where
    #     V = RotWord(SubWord(X3)) xor RCON

    pshufd $0b11111111, %xmm1, %xmm1
    # %xmm1 = V      V      V      V

    shufps $0b00010000, %xmm0, %xmm2
    # %xmm2 = 0      0      P1     P0

    pxor   %xmm2, %xmm0
    # %xmm0 = P0     P1     P2^P1  P3^P0

    shufps $0b10001100, %xmm0, %xmm2
    # %xmm2 = 0      P0     P0     P2^P1

    pxor   %xmm2, %xmm0
    # %xmm0 = P0     P1^P0  P2^P1  P3^P2
    #                        ^P0    ^P1^P0

    pxor   %xmm1, %xmm0
    # %xmm0 = P0^V   P1^P0  P2^P1  P3^P2
    #                 ^V     ^P0^V  ^P1^P0^V

    ret

# Read 16 bytes from stdin to %xmm0.
read_block:
    linux_syscall $NR_read,  $0, $buf, $16
    movaps buf, %xmm0
    ret

# Write 16 bytes from %xmm0 to stdout.
write_block:
    movaps %xmm0, buf
    linux_syscall $NR_write, $1, $buf, $16
    ret

.data
    # A 16-byte, 16-byte-aligned buffer, used to transfer
    # data between stdin/stdout and XMM registers.
    .comm buf, 16, 16