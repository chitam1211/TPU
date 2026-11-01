`timescale 1ns / 1ps

// Matrix extension configuration (RISC-V Matrix Specification Proposal v0.6.0).
//
// Only ELEN, TLEN and TRLEN are chosen by the implementation (proposal ch. 2).
// Every other size in rme_rtl is derived from them here, so changing the
// matrix geometry means editing these three values only.
package matrix_cfg_pkg;

    // =========================================================================
    // Implementation-defined constants (proposal ch. 2)
    // =========================================================================
    localparam int ELEN  = 32;   // widest element any matrix operation produces
    localparam int TLEN  = 512;  // bits per tile register
    localparam int TRLEN = 128;  // bits per tile register row

    // =========================================================================
    // Derived parameters (proposal ch. 2)
    // =========================================================================
    localparam int ROWNUM = TLEN / TRLEN;   // rows of every tile/acc register
    localparam int ARLEN  = ROWNUM * ELEN;  // bits per accumulation register row
    localparam int ALEN   = ARLEN * ROWNUM; // bits per accumulation register

    // =========================================================================
    // Register file layout (proposal 3.1)
    // =========================================================================
    // tr0-tr3 and acc0-acc3; reg_id[2] selects the bank, reg_id[1:0] the register.
    localparam int NUM_TILE_REGS = 4;
    localparam int NUM_ACC_REGS  = 4;
    localparam int REG_ID_W      = 3;

    // Storage is one 32-bit word ("beat") per access.
    localparam int WORD_W        = 32;
    localparam int TR_BEATS      = TRLEN / WORD_W;  // beats per tile row
    localparam int ACC_BEATS     = ARLEN / WORD_W;  // beats per accumulator row
    localparam int INT8_PER_WORD = WORD_W / 8;      // int8 elements in one beat

    // =========================================================================
    // Legal tile shapes (proposal 5.2): M, N <= TLEN/TRLEN, K <= TRLEN/SEW.
    // A larger mtilem/mtilen/mtilek is an illegal instruction in each unit.
    // =========================================================================
    localparam int TMMAX      = ROWNUM;
    localparam int TNMAX      = ROWNUM;
    localparam int TKMAX_INT8 = TRLEN / 8;   // mmacc*.w.b
    localparam int TKMAX_FP32 = TRLEN / 32;  // mfmacc.s

    // =========================================================================
    // Width helpers
    // =========================================================================
    // Bits needed to index 0..n-1.
    function automatic int idx_w(input int n);
        return (n > 1) ? $clog2(n) : 1;
    endfunction

    // Bits needed to hold a count 0..n (a size such as active_M = ROWNUM).
    function automatic int cnt_w(input int n);
        return $clog2(n + 1);
    endfunction

    function automatic int max2(input int a, input int b);
        return (a > b) ? a : b;
    endfunction

    // Regfile address widths shared by every unit port.
    localparam int ROW_W      = idx_w(ROWNUM);
    localparam int BEAT_W     = idx_w(max2(TR_BEATS, ACC_BEATS));
    // Linear 32-bit element index inside one tile register (mmovw).
    localparam int ELEM_IDX_W = idx_w(ROWNUM * TR_BEATS);

endpackage
