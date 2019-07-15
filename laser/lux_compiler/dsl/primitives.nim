# Laser
# Copyright (c) 2018 Mamy André-Ratsimbazafy
# Distributed under the Apache v2 License (license terms are at http://www.apache.org/licenses/LICENSE-2.0).
# This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  macros,
  # Internal
  # ./primitives_helpers,
  ../../private/ast_utils,
  ../core/[lux_types, lux_core_helpers],
  # Debug
  ../core/lux_print

# ###########################################
#
#         Lux DSL Primitive Routines
#
# ###########################################

proc dim_size*(function: Function, axis: int): LuxNode =
  DimSize.newTree(
    newLux function,
    newLux axis
  )

proc `+`*(a, b: LuxNode): LuxNode =
  assert(a.kind in LuxExpr)
  assert(b.kind in LuxExpr)
  BinOp.newTree(
    newLux Add,
    a, b
  )

proc `*`*(a, b: LuxNode): LuxNode =
  assert(a.kind in LuxExpr)
  assert(b.kind in LuxExpr)
  BinOp.newTree(
    newLux Mul,
    a, b
  )

proc `*`*(a: LuxNode, b: SomeInteger): LuxNode =
  assert(a.kind in LuxExpr)
  assert(b.kind in LuxExpr)
  BinOp.newTree(
    newLux Add,
    a, newLux b
  )

proc `+=`*(a: var LuxNode, b: LuxNode) =
  discard

proc `[]`*(function: Function, indices: varargs[Iter]): Call =
  ## Access a tensor/function
  ## For example
  ##   - A[i, j, k] on a rank 3 tensor
  ##   - A[0, i+j] on a rank 2 tensor (matrix)
  # TODO
  # - Handle the "_" joker for whole dimension
  # - Handle combinations of Iter, LuxNodes, IntParams and literals
  # - Get a friendly function symbol
  new result
  result.function = function
  for iter in indices:
    result.params.add newLux(iter)

proc `[]`*(function: var Function, indices: varargs[Iter]): Call =
  ## Access a tensor/function
  ## For example
  ##   - A[i, j, k] on a rank 3 tensor
  ##   - A[0, i+j] on a rank 2 tensor (matrix)
  # TODO
  # - Handle the "_" joker for whole dimension
  # - Handle combinations of Iter, LuxNodes, IntParams and literals
  # - Get a friendly function symbol
  new result
  result.function = function
  for iter in indices:
    result.params.add newLux(iter)

proc `[]=`*(
        function: var Function,
        indices: varargs[Iter],
        expression: LuxNode) =
  ## Mutate a Func/tensor element
  ## at specified indices
  ##
  ## For example
  ##   - A[i, j, k] on a rank 3 tensor
  ##   - A[0, i+j] on a rank 2 tensor (matrix)
  ##
  ## Used for A[i, j] = foo(i, j)
  # TODO
  # - Handle the "_" joker for whole dimension
  # - Handle combinations of Iter, LuxNodes, IntParams and literals
  # - Get a friendly function symbol
  if function.isNil:
    new function

  let stageId = function.stages.len
  # if stageId = 0: assert that indices are the full function domain.
  function.stages.setLen(stageId+1)
  new function.stages[stageId]
  for iter in indices:
    function.stages[stageId].params.add newLux(iter)
  function.stages[stageId].definition = expression

converter toLuxNode*(call: Call): LuxNode =
  # Implicit conversion of function/tensor indexing
  # to allow seamless:
  # A[i,j] = myParam + B[i,j]
  result = Access.newTree(
    newLux call.function
  )
  result.add call.params
