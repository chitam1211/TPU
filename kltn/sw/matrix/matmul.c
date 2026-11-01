/* Tiled matrix multiply on the matrix unit: C = A * B for any M, N, K.
 *
 * The hardware computes one tile per instruction: M, N <= 4 and K <= 16 for int8, K <= 4 for
 * fp32. These routines loop over 4-row x 4-column blocks of C and, inside a block, over chunks
 * of K, accumulating into ACC0 (C += A_block * B_block). Tail blocks set a smaller
 * mtilem/mtilen/mtilek, so any size works.
 *
 * Layout: A is M x K and Bt (B transposed) is N x K, both row-major with a row stride of `ld`
 * elements; C is M x N row-major. The tile load/store unit reads whole 32-bit words, so every
 * row must start on a word boundary: for int8, ld must be a multiple of 4.
 *
 * Built for RV32I without the M extension: no multiplication, only shifts and additions.
 */
#include <stdint.h>
#include "matrix.h"

#define MIN(a, b) ((a) < (b) ? (a) : (b))

void matmul_i8(const int8_t *A, const int8_t *Bt, int32_t *C, int M, int N, int K, int ld)
{
    const int8_t *a_rows = A;
    int32_t *c_rows = C;
    int c_stride = N << 2;                     /* bytes per row of C */

    for (int i = 0; i < M; i += 4, a_rows += ld << 2, c_rows += N << 2) {
        const int8_t *b_rows = Bt;
        for (int j = 0; j < N; j += 4, b_rows += ld << 2) {
            MZERO(ACC0);
            MSETTILEM(MIN(M - i, 4));
            MSETTILEN(MIN(N - j, 4));
            for (int k = 0; k < K; k += 16) {
                MSETTILEK(MIN(K - k, 16));
                MLAE8(TR0, a_rows + k, ld);
                MLBE8(TR1, b_rows + k, ld);
                MMACC_W_B(ACC0, TR0, TR1);
            }
            MSCE32(ACC0, c_rows + j, c_stride);
        }
    }
}

/* FP32 values are passed as their bit patterns (uint32_t): the routine does no float
 * arithmetic of its own. */
void matmul_f32(const uint32_t *A, const uint32_t *Bt, uint32_t *C, int M, int N, int K, int ld)
{
    const uint32_t *a_rows = A;
    uint32_t *c_rows = C;
    int ab_stride = ld << 2;                   /* bytes per row of A and Bt */
    int c_stride = N << 2;

    for (int i = 0; i < M; i += 4, a_rows += ld << 2, c_rows += N << 2) {
        const uint32_t *b_rows = Bt;
        for (int j = 0; j < N; j += 4, b_rows += ld << 2) {
            MZERO(ACC0);
            MSETTILEM(MIN(M - i, 4));
            MSETTILEN(MIN(N - j, 4));
            for (int k = 0; k < K; k += 4) {
                MSETTILEK(MIN(K - k, 4));
                MLAE32(TR0, a_rows + k, ab_stride);
                MLBE32(TR1, b_rows + k, ab_stride);
                MFMACC_S(ACC0, TR0, TR1);
            }
            MSCE32(ACC0, c_rows + j, c_stride);
        }
    }
}
