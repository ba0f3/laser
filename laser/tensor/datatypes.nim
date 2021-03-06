# Laser & Arraymancer
# Copyright (c) 2017-2018 Mamy André-Ratsimbazafy
# Distributed under the Apache v2 License (license terms are at http://www.apache.org/licenses/LICENSE-2.0).
# This file may not be copied, modified, or distributed except according to those terms.

# Types and low level primitives for tensors

import
  ../dynamic_stack_arrays, ../compiler_optim_hints,
  sugar, typetraits

type
  RawImmutableView*[T] = distinct ptr UncheckedArray[T]
  RawMutableView*[T] = distinct ptr UncheckedArray[T]

  Metadata* = DynamicStackArray[int]

  Tensor*[T] = object                    # Total stack: 128 bytes = 2 cache-lines
    shape*: Metadata                     # 56 bytes
    strides*: Metadata                   # 56 bytes
    offset*: int                         # 8 bytes
    storage*: CpuStorage[T]              # 8 bytes

  CpuStorage*{.shallow.}[T] = ref object # Total heap: 25 bytes = 1 cache-line
    when supportsCopyMem(T):
      raw_buffer*: ptr UncheckedArray[T] # 8 bytes
      memalloc*: pointer                 # 8 bytes
      memowner*: bool                    # 1 byte
    else: # Tensors of strings, other ref types or non-trivial destructors
      raw_buffer*: seq[T]                # 8 bytes (16 for seq v2 backed by destructors?)

func rank*(t: Tensor): range[0 .. LASER_MAXRANK] {.inline.} =
  t.shape.len

func size*(t: Tensor): Natural =
  t.shape.product

func is_C_contiguous*(t: Tensor): bool =
  ## Check if the tensor follows C convention / is row major
  var cur_size = 1
  for i in countdown(t.rank - 1,0):
    # 1. We should ignore strides on dimensions of size 1
    # 2. Strides always must have the size equal to the product of the next dimensions
    if t.shape[i] != 1 and t.strides[i] != cur_size:
        return false
    cur_size *= t.shape[i]
  return true

# ##################
# Raw pointer access
# ##################

# RawImmutableView and RawMutableView make sure that a non-mutable tensor
# is not mutated through it's raw pointer.
#
# Unfortunately there is no way to also prevent those from escaping their scope
# and outliving their source tensor (via `lent` destructors)
# and keeping the `restrict` and `alignment`
# optimization hints https://github.com/nim-lang/Nim/issues/7776
#
# Another anti-escape could be the "var T from container" and "lent T from container"
# mentionned here: https://nim-lang.org/docs/manual.html#var-return-type-future-directions

template unsafe_raw_data_impl() {.dirty.} =

  when T.supportsCopyMem:
    withCompilerOptimHints()
    when aligned:
      let raw_pointer{.restrict.} = assume_aligned t.storage.raw_buffer
    else:
      let raw_pointer{.restrict.} = t.storage.raw_buffer
    result = cast[type result](raw_pointer[t.offset].addr)
  else:
    result = cast[type result](t.storage.raw_buffer[t.offset].addr)

func unsafe_raw_data*[T](t: Tensor[T], aligned: static bool = true): RawImmutableView[T] {.inline.} =
  ## Unsafe: the pointer can outlive the input tensor
  ## For optimization purposes, Laser will hint the compiler that
  ## while the pointer is valid, all data accesses will be through it (no aliasing)
  ## and that the data is aligned by LASER_MEM_ALIGN (default 64).
  unsafe_raw_data_impl()

func unsafe_raw_data*[T](t: var Tensor[T], aligned: static bool = true): RawMutableView[T] {.inline.} =
  ## Unsafe: the pointer can outlive the input tensor
  ## For optimization purposes, Laser will hint the compiler that
  ## while the pointer is valid, all data accesses will be through it (no aliasing)
  ## and that the data is aligned by LASER_MEM_ALIGN (default 64).
  unsafe_raw_data_impl()

macro raw_data_unaligned*(body: untyped): untyped =
  ## Within this code block, all raw data accesses will not be
  ## assumed aligned by default (LASER_MEM_ALIGN is 64 by default).
  ## Use this when interfacing with external buffers of unknown alignment.
  ##
  ## ⚠️ Warning:
  ##     At the moment Nim's builtin term-rewriting macros are not scoped.
  ##     All processing within the file this is called will be considered
  ##     unaligned. https://github.com/nim-lang/Nim/issues/7214#issuecomment-431567894.
  block:
    template trmUnsafeRawData{unsafe_raw_data(x, aligned)}(x, aligned): auto =
      {.noRewrite.}: unsafe_raw_data(x, false)
    body

template `[]`*[T](v: RawImmutableView[T], idx: int): T =
  distinctBase(type v)(v)[idx]

template `[]`*[T](v: RawMutableView[T], idx: int): var T =
  distinctBase(type v)(v)[idx]

template `[]=`*[T](v: RawMutableView[T], idx: int, val: T) =
  distinctBase(type v)(v)[idx] = val
