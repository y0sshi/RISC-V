.section ".boot", "ax"

.global boot
boot:
    addi x1, zero, 0
    la   sp, stack_top
    jal  main
    
    # loop forever
    j .

