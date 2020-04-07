# Laser
# Copyright (c) 2018 Mamy André-Ratsimbazafy
# Distributed under the Apache v2 License (license terms are at http://www.apache.org/licenses/LICENSE-2.0).
# This file may not be copied, modified, or distributed except according to those terms.

import
  ../photon_types,
  ./x86_base

# ################################################################
#
#                  Calls and Stack related ops
#
# ################################################################

# Push and Pop for registers are defined in "jit_x86_base"
# as they are needed for function cleanup.

func push*(a: var Assembler[X86], reg: static RegX86_32) {.inline.}=
  ## Push a register on the stack
  a.code.add push(reg)


func pop*(a: var Assembler[X86], reg: static RegX86_32) {.inline.}=
  ## Pop the stack into a register
  a.code.add push(reg)

func syscall*(a: var Assembler[X86], clean_registers: static bool = false) {.inline.}=
  ## Syscall opcode
  ## `rax` will determine which syscall is called.
  ##   - Write syscall (0x01 on Linux, 0x02000004 on OSX):
  ##       - os.write(rdi, rsi, rdx) equivalent to
  ##       - os.write(file_descriptor, str_pointer, str_length)
  ##       - The file descriptor for stdout is 0x01
  ## As syscall clobbers rcx and r11 registers
  ## You can optionally set true `clean_registers`
  ## to clean those.
  when clean_registers:
    a.code.add static(
      push(edi) & [push(esi)] & # clobbered by syscall
      [byte 0xcd, 0x80] &           # actual syscall
      [pop(edi)] & pop(esi)
    )
  else:
    a.code.add [byte 0xcd, 0x80]

func ret*(a: var Assembler[X86]) {.inline.}=
  ## Return from function opcode
  ## If the assembler autocleans the clobbered registers
  ## this will restore them to their previous state
  if a.clean_regs:
    a.code.add a.restore_regs
  a.code.add byte 0xC3
