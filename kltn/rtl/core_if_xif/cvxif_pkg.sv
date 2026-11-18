// CORE-V eXtension Interface (CV-X-IF) v1.0.0 types for this design (docs/xif_design.md,
// section 3). Field names follow the specification. Only the interfaces used here are
// declared: issue, register, commit, memory request/response, memory result, result
// (no compressed interface, no dual read/write, X_ISSUE_REGISTER_SPLIT = 0).
package cvxif_pkg;

    localparam int X_NUM_RS               = 2;
    localparam int X_ID_WIDTH             = 3;
    localparam int X_RFR_WIDTH            = 32;
    localparam int X_RFW_WIDTH            = 32;
    localparam int X_NUM_HARTS            = 1;
    localparam int X_HARTID_WIDTH         = 1;
    localparam int X_MEM_WIDTH            = 32;
    localparam int X_ISSUE_REGISTER_SPLIT = 0;

    typedef logic [X_ID_WIDTH-1:0]     x_id_t;
    typedef logic [X_HARTID_WIDTH-1:0] x_hartid_t;

    // Issue: core -> coprocessor (offloaded instruction).
    typedef struct packed {
        logic [31:0] instr;
        x_hartid_t   hartid;
        x_id_t       id;
    } x_issue_req_t;

    // Issue response: coprocessor -> core, valid with the issue handshake.
    typedef struct packed {
        logic                accept;         // the coprocessor executes the instruction
        logic                writeback;      // it will write a GPR (result.we = 1)
        logic [X_NUM_RS-1:0] register_read;  // which rs[] it reads
        logic                loadstore;      // it uses the memory interfaces
    } x_issue_resp_t;

    // Register: core -> coprocessor. With split = 0 it shares the issue handshake.
    typedef struct packed {
        x_hartid_t                             hartid;
        x_id_t                                 id;
        logic [X_NUM_RS-1:0][X_RFR_WIDTH-1:0]  rs;
        logic [X_NUM_RS-1:0]                   rs_valid;
    } x_register_t;

    // Commit: core -> coprocessor, once per offered instruction (no ready).
    typedef struct packed {
        x_hartid_t hartid;
        x_id_t     id;
        logic      commit_kill;
    } x_commit_t;

    // Memory request: coprocessor -> core.
    typedef struct packed {
        x_hartid_t                hartid;
        x_id_t                    id;
        logic [31:0]              addr;
        logic [1:0]               mode;      // privilege level (2'b11 = machine)
        logic                     we;
        logic [2:0]               size;      // log2 bytes
        logic [X_MEM_WIDTH/8-1:0] be;
        logic [1:0]               attr;
        logic [X_MEM_WIDTH-1:0]   wdata;
        logic                     last;
        logic                     spec;
    } x_mem_req_t;

    // Memory response: core -> coprocessor, with the memory request handshake.
    typedef struct packed {
        logic       exc;
        logic [5:0] exccode;
        logic       dbg;
    } x_mem_resp_t;

    // Memory result: core -> coprocessor, one per memory request, in order (no ready).
    typedef struct packed {
        x_hartid_t              hartid;
        x_id_t                  id;
        logic [X_MEM_WIDTH-1:0] rdata;
        logic                   err;
        logic                   dbg;
    } x_mem_result_t;

    // Result: coprocessor -> core, one per accepted and committed instruction.
    typedef struct packed {
        x_hartid_t              hartid;
        x_id_t                  id;
        logic [X_RFW_WIDTH-1:0] data;
        logic [4:0]             rd;
        logic                   we;
        logic                   exc;
        logic [5:0]             exccode;
        logic                   err;
        logic                   dbg;
    } x_result_t;

endpackage
