/* Reference matrix multiply with scalar instructions only (no matrix unit), same layout as
 * matmul.c: A is M x K, Bt (B transposed) is N x K, row stride `ld` elements; C is M x N.
 *
 * int8: the core is RV32IF without the M extension, so each product is a call to libgcc's
 *       __mulsi3 (shift-and-add loop), the code GCC generates for any C multiplication here.
 * fp32: one fused multiply-add (fmadd.s) per product, accumulated in order k = 0 .. K-1
 *       starting from +0.0, with the dynamic rounding mode (frm, round to nearest even).
 */
#include <stdint.h>

void matmul_i8_scalar(const int8_t *A, const int8_t *Bt, int32_t *C, int M, int N, int K, int ld)
{
    const int8_t *a = A;
    int32_t *c = C;
    for (int i = 0; i < M; i++, a += ld, c += N) {
        const int8_t *b = Bt;
        for (int j = 0; j < N; j++, b += ld) {
            int32_t acc = 0;
            for (int k = 0; k < K; k++)
                acc += a[k] * b[k];
            c[j] = acc;
        }
    }
}

void matmul_f32_scalar(const float *A, const float *Bt, float *C, int M, int N, int K, int ld)
{
    const float *a = A;
    float *c = C;
    for (int i = 0; i < M; i++, a += ld, c += N) {
        const float *b = Bt;
        for (int j = 0; j < N; j++, b += ld) {
            float acc = 0.0f;
            for (int k = 0; k < K; k++)
                acc = __builtin_fmaf(a[k], b[k], acc);
            c[j] = acc;
        }
    }
}
