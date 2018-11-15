# Laser
# Copyright (c) 2018 Mamy André-Ratsimbazafy
# Distributed under the Apache v2 License (license terms are at http://www.apache.org/licenses/LICENSE-2.0).
# This file may not be copied, modified, or distributed except according to those terms.

import
  ../../cpuinfo, ../../compiler_optim_hints,
  ./gemm_tiling, ./gemm_utils,
  ./gemm_ukernel_dispatch, ./gemm_packing

withCompilerOptimHints()

# ############################################################
#
#      Optimized GEMM (Generalized Matrix-Multiplication)
#
# ############################################################

# Features
#  - Arbitrary stride support
#  - Efficient implementation (within 90% of the speed of OpenBLAS, more tuning to expect)
#  - Parallel and scale linearly with number of cores
#
# Future
#  - Implementation extended to integers
#  - ARM Neon optimisation
#  - Small matrix multiply optimisation
#  - Pre-packing to when computing using the same matrix
#  - batched matrix multiplication

# Terminology
#   - M, Matrix: Both dimension are large or unknown
#   - P, Panel: one of the dimension is small
#   - B, Block: both dimension are small
#
#   - GEMM: GEneralized Matrix-Matrix multiplication
#   - GEPP: GEneralized Panel-Panel multiplication
#   - GEBP: Generalized Block-Panel multiplication (macrokernel)
#   - GEBB: GEneralized Block-Block multiplication (microkernel)
#   ...

# ############################################################
#
#                     GEBP Macrokernel
#
# ############################################################

proc gebp_mkernel[T; ukernel: static MicroKernel](
      mc, nc, kc: int,
      alpha, beta: T,
      mcncC: MatrixView[T],
      tiles: Tiles[T]
    ) =
  ## Macro kernel, multiply:
  ##  - a block A[mc, kc] * panel B[kc, N]

  # Since nr is small this the the good place to parallelize
  # See: Anatomy of High-Performance Many-Threaded Matrix Multiplication
  #      Smith et al
  #      - http://www.cs.utexas.edu/users/flame/pubs/blis3_ipdps14.pdf

  # ⚠ We need to ensure that loop variables and pointers
  # are private to each thread

  # Nim doesn't support arbitrary increment with OpenMP
  # So we store indexing/edge case data in tiles
  const MR = ukernel.extract_mr
  const NR = ukernel.extract_nr

  # #####################################
  # 4. for jr = 0,...,nc−1 in steps of nr
  for jrb in 0||(tiles.jr_num_nr_tiles - 1):
    let jr = jrb * NR
    let nr = min(nc - jr, NR)                        # C[ic:ic+mc, jc+jr:jc+jr+nr]

    # ###################################
    # 5. for ir = 0,...,m−1 in steps of mr
    for ir in countup(0, mc-1, MR):
      let mr = min(mc - ir, MR)
      let c_aux = mcncC.stride(ir, jr)               # C[ic+ir:ic+ir+mr, jc+jr:jc+jr+nr]

      # TODO save addr of next panel of A for prefetch
      # and if last iter, save addr of next panel of B

      if nr == NR and mr == MR:
        # General case
        gebb_ukernel[T, ukernel](                    # GEBB microkernel + epilogue
                kc,                                  #   C[ic+ir:ic+ir+mr, jc+jr:jc+jr+nr] =
          alpha, tiles.a + ir*kc, tiles.b + jr*kc,   #    αA[ic+ir:ic+ir+mr, pc:pc+kc] *
          beta, c_aux                                #     B[pc:pc+kc, jc+jr:jc+jr+nr] +
        )                                            #    βC[ic:ic+mc, jc:jc+nc]
      else:
        # Matrix edges
        gebb_ukernel_edge[T, ukernel](               # GEBB microkernel + epilogue
          mr, nr, kc,                                #   C[ic+ir:ic+ir+mr, jc+jr:jc+jr+nr] =
          alpha, tiles.a + ir*kc, tiles.b + jr*kc,   #    αA[ic+ir:ic+ir+mr, pc:pc+kc] *
          beta, c_aux                                #     B[pc:pc+kc, jc+jr:jc+jr+nr] +
        )                                            #    βC[ic:ic+mc, jc:jc+nc]

# ###########################################################################################
#
#              GEMM Internal Implementation
#
# ###########################################################################################

proc gemm_impl[T; ukernel: static MicroKernel](
      M, N, K: int,
      alpha: T, vA: MatrixView[T], vB: MatrixView[T],
      beta: T, vC: MatrixView[T],
      tiles: Tiles[T]
    ) =
                                                      # A[0:M, 0:K]
  # ####################################################################
  # 1. for jc = 0,...,n−1 in steps of nc
  # not partitioned currently nc = N
  let nc = N                                          # B[0:K, jc:jc+nc]
                                                      # C[0:M, jc:jc+nc]
  # ######################################
  # 2.   for pc = 0,...,k−1 in steps of kc
  for pc in countup(0, K-1, tiles.kc):
    let kc = min(K - pc, tiles.kc) # Deal with edges  # A[0:M, pc:pc+kc]

    let kcncB = vB.stride(pc, 0)                      # B[pc:pc+kc, jc:jc+nc]
    pack_B_kc_nc[T, ukernel](tiles, kc, nc, kcncB)    # PackB panel [kc, nc] (nc is large or unknown)

    # First time writing to C, we scale it, otherwise accumulate
    let beta = if pc == 0: beta else: 1.T

    # ####################################
    # 3. for ic = 0,...,m−1 in steps of mc
    for ic in countup(0, M-1, tiles.mc):
      let mc = min(M-ic, tiles.mc)                    # C[ic:ic+mc, jc:jc+nc]

      let mckcA = vA.stride(ic, pc)                   # A[ic:ic+mc, pc:pc+kc]
      pack_A_mc_kc[T, ukernel](tiles, mc, kc, mckcA)  # PackA block [mc, kc]

      gebp_mkernel[T, ukernel](                       # GEBP macrokernel:
          mc, nc, kc,                                 #   C[ic:ic+mc, jc:jc+nc] =
          alpha, beta, vC.stride(ic, 0),              #    αA[ic:ic+mc, pc:pc+kc] * B[pc:pc+kc, jc:jc+nc] +
          tiles                                       #    βC[ic:ic+mc, jc:jc+nc]
        )

# ############################################################
#
#   Exported function and dispatch with CPU runtime detection
#
# ############################################################

proc gemm_strided*[T: SomeNumber](
      M, N, K: int,
      alpha: T,
      A: ptr T,
      rowStrideA, colStrideA: int,
      B: ptr T,
      rowStrideB, colStrideB: int,
      beta: T,
      C: ptr T,
      rowStrideC, colStrideC: int) =

    # TODO: shortcut alpha = 0 or K = 0
    # TODO: elementwise epilogue fusion like relu/tanh/sigmoid
    # TODO: shortcut for small gemm

    # Create a view to abstract deling with strides
    # and passing those in each proc
    let vA = A.toMatrixView(rowStrideA, colStrideA)
    let vB = B.toMatrixView(rowStrideB, colStrideB)
    let vC = C.toMatrixView(rowStrideC, colStrideC)

    # Cache hierarchy:
    #   - block C: mr*nr registers
    #   - block B: kc*nr L1 cache
    #   - block A: mc*kc L2 cache
    #   - panel B: kc*nc L3 cache

    template dispatch(cpu_features: static CPUFeatureX86){.dirty.} =
      const ukernel = cpu_features.x86_ukernel(T)
      let tiles = ukernel.newTiles(T, M, N, K)
      gemm_impl[T, ukernel](
        M, N, K,
        alpha, vA, vB,
        beta, vC,
        tiles
      )
      return

    when defined(i386) or defined(amd64):
      when T is SomeFloat:
        if cpuinfo_has_x86_avx512f():  dispatch(x86_AVX512)
        elif cpuinfo_has_x86_avx2():   dispatch(x86_AVX2)
        elif cpuinfo_has_x86_avx():    dispatch(x86_AVX)
        elif cpuinfo_has_x86_sse2():   dispatch(x86_SSE2)
        elif cpuinfo_has_x86_sse():    dispatch(x86_SSE)
      else: # Integers are taking advantage of wider registers later (in SSE2 and AVX2)
        if cpuinfo_has_x86_avx512f():  dispatch(x86_AVX512)
        elif cpuinfo_has_x86_avx2():   dispatch(x86_AVX2)
        elif cpuinfo_has_x86_sse2():   dispatch(x86_SSE2)
    dispatch(x86_Generic)

# ############################################################
#
#                       Private tests
#
# ############################################################

when isMainModule:
  # Tests
  block:
    let a = [[1.0, 2, 3],
             [1.0, 1, 1],
             [1.0, 1, 1]]

    let b = [[1.0, 1],
             [1.0, 1],
             [1.0, 1]]

    let ab = [[6.0, 6],
              [3.0, 3],
              [3.0, 3]]

    var res_ab: array[3, array[2, float]]
    gemm_strided(
      3, 2, 3,
      1.0,  a[0][0].unsafeAddr, 3, 1,
            b[0][0].unsafeAddr, 2, 1,
      0.0,  res_ab[0][0].addr,  2, 1
      )

    # echo "expected: ", ab
    # echo "result: ", res_ab

    doAssert res_ab == ab
    # echo '\n'

  block:
    let a = [[1.0, 2, 3],
             [4.0, 5, 6],
             [7.0, 8, 9]]

    let b = [[1.0, 1],
             [1.0, 1],
             [1.0, 1]]

    let ab = [[ 6.0,  6],
              [15.0, 15],
              [24.0, 24]]

    var res_ab: array[3, array[2, float]]
    gemm_strided(
      3, 2, 3,
      1.0,  a[0][0].unsafeAddr, 3, 1,
            b[0][0].unsafeAddr, 2, 1,
      0.0,  res_ab[0][0].addr,  2, 1
      )

    # echo "expected: ", ab
    # echo "result: ", res_ab

    doAssert res_ab == ab
    # echo '\n'

  block:
    let a = [[1.0,2,3],
             [4.0,5,6]]

    let b = [[7.0,  8],
             [9.0, 10],
             [11.0,12]]

    let ab = [[ 58.0, 64],
              [139.0,154]]

    var res_ab: array[2, array[2, float]]
    gemm_strided(
      2, 2, 3,
      1.0,  a[0][0].unsafeAddr, 3, 1,
            b[0][0].unsafeAddr, 2, 1,
      0.0,  res_ab[0][0].addr,  2, 1
      )

    # echo "expected: ", ab
    # echo "result: ", res_ab

    doAssert res_ab == ab
    # echo '\n'

  block:
    # example from http://www.intmath.com/matrices-determinants/matrix-multiplication-examples.php
    echo "\n## (M x K) * (K x N) with M < N"
    let a = [[-2,-3,-1],
             [ 3, 0, 4]]
    let b = [[ 1, 5, 2,-1],
             [-3, 0, 3, 4],
             [ 6,-2, 7,-4]]

    let ab = [[ 1,-8,-20, -6],
              [27, 7, 34,-19]]

    var res_ab: array[2, array[4, int]]
    gemm_strided(
      2, 4, 3,
      1,  a[0][0].unsafeAddr, 3, 1,
          b[0][0].unsafeAddr, 4, 1,
      0,  res_ab[0][0].addr,  4, 1
      )

    # echo "expected: ", ab
    # echo "result: ", res_ab

    doAssert res_ab == ab
    # echo '\n'

  block:
    # from http://www.calcul.com/show/calculator/matrix-multiplication_;5;5;5;5?matrix1=[[%225%22,%226%22,%225%22,%228%22],[%228%22,%222%22,%228%22,%228%22],[%220%22,%225%22,%224%22,%220%22],[%224%22,%220%22,%225%22,%226%22],[%224%22,%225%22,%220%22,%223%22]]&matrix2=[[%225%22,%223%22,%226%22,%220%22],[%225%22,%222%22,%223%22,%223%22],[%228%22,%228%22,%222%22,%220%22],[%227%22,%227%22,%220%22,%220%22]]&operator=*
    echo "\n## (M x K) * (K x N) with M > N and M > block-size (4x4)"
    let a =  [[5,6,5,8],
              [8,2,8,8],
              [0,5,4,0],
              [4,0,5,6],
              [4,5,0,3]]
    let b =  [[5,3,6,0],
              [5,2,3,3],
              [8,8,2,0],
              [7,7,0,0]]

    let ab = [[151,123,58,18],
              [170,148,70, 6],
              [ 57, 42,23,15],
              [102, 94,34, 0],
              [ 66, 43,39,15]]

    var res_ab: array[5, array[4, int]]
    gemm_strided(
      5, 4, 4,
      1,  a[0][0].unsafeAddr, 4, 1,
          b[0][0].unsafeAddr, 4, 1,
      0,  res_ab[0][0].addr,  4, 1
      )

    # echo "expected: ", ab
    # echo "result: ", res_ab

    doAssert res_ab == ab
    # echo '\n'

  block:
    let a =  [[2, 4,  3,  1,  3,  1,  3,  1],
              [4, 3,  2,  4,  1,  0,  0,  0]]


    let b =  [[2, 2],
              [2, 1],
              [0, 3],
              [0, 1],
              [0, 2],
              [4, 3],
              [3, 3],
              [2, 1]]

    let ab = [[27,37],
              [14,23]]

    var res_ab: array[2, array[2, int]]
    gemm_strided(
      2, 2, 8,
      1,  a[0][0].unsafeAddr, 8, 1,
          b[0][0].unsafeAddr, 2, 1,
      0,  res_ab[0][0].addr,  2, 1
      )

    # echo "expected: ", ab
    # echo "result: ", res_ab

    doAssert res_ab == ab
    # echo '\n'

  block:
    let a =  [[2, 1],
              [1, 3],
              [2, 1],
              [1, 0],
              [3, 4],
              [2, 4],
              [3, 1],
              [4, 0]]


    let b =  [[2, 2,  0,  4,  0,  0,  4,  2],
              [2, 1,  2,  1,  2,  4,  4,  1]]

    let ab = [[ 6,  5,  2,  9,  2,  4, 12,  5],
              [ 8,  5,  6,  7,  6, 12, 16,  5],
              [ 6,  5,  2,  9,  2,  4, 12,  5],
              [ 2,  2,  0,  4,  0,  0,  4,  2],
              [14, 10,  8, 16,  8, 16, 28, 10],
              [12,  8,  8, 12,  8, 16, 24,  8],
              [ 8,  7,  2, 13,  2,  4, 16,  7],
              [ 8,  8,  0, 16,  0,  0, 16,  8]]

    var res_ab: array[8, array[8, int]]
    gemm_strided(
      8, 8, 2,
      1,  a[0][0].unsafeAddr, 2, 1,
          b[0][0].unsafeAddr, 8, 1,
      0,  res_ab[0][0].addr,  8, 1
      )

    # echo "expected: ", ab
    # echo "result: ",   res_ab

    doAssert res_ab == ab
    # echo '\n'

  block:
    # from http://www.calcul.com/show/calculator/matrix-multiplication?matrix1=[[%222%22,%224%22,%223%22,%221%22,%223%22,%221%22,%223%22,%221%22],[%221%22,%222%22,%221%22,%221%22,%222%22,%220%22,%224%22,%223%22],[%222%22,%220%22,%220%22,%223%22,%220%22,%224%22,%224%22,%221%22],[%221%22,%221%22,%224%22,%220%22,%223%22,%221%22,%223%22,%220%22],[%223%22,%224%22,%221%22,%221%22,%224%22,%222%22,%223%22,%224%22],[%222%22,%224%22,%220%22,%222%22,%223%22,%223%22,%223%22,%224%22],[%223%22,%220%22,%220%22,%223%22,%221%22,%224%22,%223%22,%221%22],[%224%22,%223%22,%222%22,%224%22,%221%22,%220%22,%220%22,%220%22]]&matrix2=[[%222%22,%222%22,%220%22,%224%22,%220%22,%220%22,%224%22,%222%22],[%222%22,%220%22,%220%22,%221%22,%221%22,%221%22,%223%22,%221%22],[%220%22,%222%22,%222%22,%220%22,%222%22,%222%22,%223%22,%223%22],[%220%22,%220%22,%221%22,%220%22,%224%22,%222%22,%224%22,%221%22],[%220%22,%220%22,%221%22,%223%22,%224%22,%222%22,%224%22,%222%22],[%224%22,%223%22,%224%22,%221%22,%224%22,%224%22,%220%22,%223%22],[%223%22,%223%22,%220%22,%222%22,%221%22,%222%22,%223%22,%223%22],[%222%22,%221%22,%222%22,%221%22,%222%22,%224%22,%224%22,%221%22]]&operator=*
    echo "\n## (N x N) * (N x N) with N multiple of block size"

    let a =  [[2, 4,  3,  1,  3,  1,  3,  1],
              [1, 2,  1,  1,  2,  0,  4,  3],
              [2, 0,  0,  3,  0,  4,  4,  1],
              [1, 1,  4,  0,  3,  1,  3,  0],
              [3, 4,  1,  1,  4,  2,  3,  4],
              [2, 4,  0,  2,  3,  3,  3,  4],
              [3, 0,  0,  3,  1,  4,  3,  1],
              [4, 3,  2,  4,  1,  0,  0,  0]]


    let b =  [[2, 2,  0,  4,  0,  0,  4,  2],
              [2, 0,  0,  1,  1,  1,  3,  1],
              [0, 2,  2,  0,  2,  2,  3,  3],
              [0, 0,  1,  0,  4,  2,  4,  1],
              [0, 0,  1,  3,  4,  2,  4,  2],
              [4, 3,  4,  1,  4,  4,  0,  3],
              [3, 3,  0,  2,  1,  2,  3,  3],
              [2, 1,  2,  1,  2,  4,  4,  1]]

    let ab = [[27,23,16,29,35,32,58,37],
              [24,19,11,23,26,30,49,27],
              [34,29,21,21,34,34,36,32],
              [17,22,15,21,28,25,40,33],
              [39,27,23,40,45,46,72,41],
              [41,26,25,34,47,48,65,38],
              [33,28,22,26,37,34,41,33],
              [14,12, 9,22,27,17,51,23]]

    var res_ab: array[8, array[8, int]]
    gemm_strided(
      8, 8, 8,
      1,  a[0][0].unsafeAddr, 8, 1,
          b[0][0].unsafeAddr, 8, 1,
      0,  res_ab[0][0].addr,  8, 1
      )

    # echo "expected: ", ab
    # echo "result: ",   res_ab

    doAssert res_ab == ab
    # echo '\n'
