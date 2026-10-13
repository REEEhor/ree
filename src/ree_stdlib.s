
# print_int(rdi = signed 64-bit integer): prints it in decimal + newline
print_int:
    push rbp
    mov  rbp, rsp
    sub  rsp, 32                # buffer: 20 digits + sign + newline fits

    mov  rax, rdi               # rax = value we keep dividing
    mov  r8, rdi                # r8  = original, to remember the sign
    mov  rsi, rbp               # rsi = write position, starts at buffer end

    dec  rsi
    mov  byte ptr [rsi], '\n'

    test rax, rax
    jns  1f
    neg  rax                    # work with the absolute value
1:
    mov  ecx, 10
2:
    xor  edx, edx               # div divides rdx:rax, so clear rdx
    div  rcx                    # rax = quotient, rdx = remainder (0-9)
    add  dl, '0'                # digit -> ASCII
    dec  rsi
    mov  [rsi], dl
    test rax, rax
    jnz  2b                     # loop until nothing is left

    test r8, r8
    jns  3f
    dec  rsi
    mov  byte ptr [rsi], '-'
3:
    mov  rdx, rbp
    sub  rdx, rsi               # length = buffer end - start of text
    mov  eax, 1                 # write
    mov  edi, 1                 # stdout
    syscall

    leave
    ret
