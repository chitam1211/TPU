// =============================================================================
// rv32if_matrix_soc: RV32IF + matrix core (core_matrix) voi IMEM/DMEM, co cong host.
//
// Giong rv32if_matrix_microprocessor (giu nguyen file do cho testbench), them:
//   - cong host vao IMEM/DMEM: khi core dang bi giu reset (core_rst_n = 0) host
//     so huu ca hai bo nho (nap chuong trinh, nap/doc du lieu); khi core chay,
//     bo nho thuoc ve core va yeu cau cua host bi bo qua;
//   - phat hien dung (halted): chuong trinh ket thuc bang "jal x0, 0" (0x0000006F).
//     Khi lenh fetch gan nhat la lenh nay HALT_CYCLES chu ky lien tiep va matrix_busy = 0
//     thi pipeline da xa het, co halted bat va giu toi khi core bi reset lai.
// Bo nho: 256 word moi loai (dia chi byte 0x000-0x3FF), doc dong bo 1 chu ky.
// =============================================================================
module rv32if_matrix_soc #(
    parameter HALT_CYCLES = 64
)(
    input  wire        clk,
    input  wire        core_rst_n,

    // Host port vao IMEM/DMEM (chi co hieu luc khi core_rst_n = 0)
    input  wire        host_imem_req,
    input  wire        host_dmem_req,
    input  wire        host_we,
    input  wire [3:0]  host_wstrb,
    input  wire [7:0]  host_word_addr,
    input  wire [31:0] host_wdata,
    output wire [31:0] host_imem_rdata,
    output wire [31:0] host_dmem_rdata,

    // Host port vao thanh ghi ma tran
    input  wire        matrix_host_reg_we,
    input  wire [2:0]  matrix_host_reg_id,
    input  wire [2:0]  matrix_host_reg_row_idx,
    input  wire [2:0]  matrix_host_reg_beat_idx,
    input  wire [31:0] matrix_host_reg_wdata,
    input  wire [2:0]  matrix_host_read_id,
    input  wire [2:0]  matrix_host_read_row,
    input  wire [2:0]  matrix_host_read_beat,
    output wire [31:0] matrix_host_reg_rdata,
    output wire [31:0] matrix_debug_mtilem,
    output wire [31:0] matrix_debug_mtilen,
    output wire [31:0] matrix_debug_mtilek,
    output wire        matrix_busy,
    output wire        matrix_done,

    output wire [31:0] pc_address,
    output reg         halted
    );

    localparam [31:0] JAL_SELF = 32'h0000006F;   // jal x0, 0

    wire host_mode = !core_rst_n;

    wire [31:0] instruction_data;
    wire [31:0] load_data_out;
    wire [31:0] alu_out_address;
    wire [31:0] store_data;
    wire [3:0]  mask;
    wire [3:0]  instruc_mask_singal;
    wire instruction_mem_we_re;
    wire instruction_mem_request;
    wire instruc_mem_valid;
    wire data_mem_valid;
    wire data_mem_we_re;
    wire data_mem_request;
    wire load_signal;

    // INSTRUCTION MEMORY (core: chi doc; host: doc/ghi)
    instruc_mem_top #(
        .INIT_MEM(0)
    ) u_instruction_memory (
        .clk(clk),
        .rst(core_rst_n),
        .we_re(host_mode ? host_we : instruction_mem_we_re),
        .request(host_mode ? host_imem_req : instruction_mem_request),
        .mask(host_mode ? host_wstrb : instruc_mask_singal),
        .address(host_mode ? host_word_addr : pc_address[9:2]),
        .data_in(host_mode ? host_wdata : 32'h0),
        .valid(instruc_mem_valid),
        .data_out(instruction_data)
    );

    // CORE
    core_matrix u_core (
        .clk(clk),
        .rst(core_rst_n),
        .instruction(instruction_data),
        .load_data_in(load_data_out),
        .mask_singal(mask),
        .load_signal(load_signal),
        .instruc_mask_singal(instruc_mask_singal),
        .instruction_mem_we_re(instruction_mem_we_re),
        .instruction_mem_request(instruction_mem_request),
        .data_mem_we_re(data_mem_we_re),
        .data_mem_request(data_mem_request),
        .instruc_mem_valid(instruc_mem_valid),
        .data_mem_valid(data_mem_valid),
        .store_data_out(store_data),
        .pc_address(pc_address),
        .alu_out_address(alu_out_address),

        .matrix_host_reg_we(matrix_host_reg_we),
        .matrix_host_reg_id(matrix_host_reg_id),
        .matrix_host_reg_row_idx(matrix_host_reg_row_idx),
        .matrix_host_reg_beat_idx(matrix_host_reg_beat_idx),
        .matrix_host_reg_wdata(matrix_host_reg_wdata),
        .matrix_host_read_id(matrix_host_read_id),
        .matrix_host_read_row(matrix_host_read_row),
        .matrix_host_read_beat(matrix_host_read_beat),
        .matrix_host_reg_rdata(matrix_host_reg_rdata),
        .matrix_debug_mtilem(matrix_debug_mtilem),
        .matrix_debug_mtilen(matrix_debug_mtilen),
        .matrix_debug_mtilek(matrix_debug_mtilek),
        .matrix_busy(matrix_busy),
        .matrix_done(matrix_done)
    );

    // DATA MEMORY (dung chung cho load/store scalar va mld/mst cua core ma tran)
    data_mem_top u_data_memory (
        .clk(clk),
        .rst(core_rst_n),
        .we_re(host_mode ? host_we : data_mem_we_re),
        .request(host_mode ? host_dmem_req : data_mem_request),
        .address(host_mode ? host_word_addr : alu_out_address[9:2]),
        .data_in(host_mode ? host_wdata : store_data),
        .mask(host_mode ? host_wstrb : mask),
        .load(load_signal),
        .valid(data_mem_valid),
        .data_out(load_data_out)
    );

    assign host_imem_rdata = instruction_data;
    assign host_dmem_rdata = load_data_out;

    // HALT DETECT
    reg [7:0] halt_cnt;
    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            halt_cnt <= 8'd0;
            halted   <= 1'b0;
        end
        // data_out cua IMEM giu lenh fetch gan nhat (valid chi la xung moi lan fetch)
        else if (instruction_data == JAL_SELF && !matrix_busy) begin
            if (halt_cnt == HALT_CYCLES[7:0] - 8'd1)
                halted <= 1'b1;
            else
                halt_cnt <= halt_cnt + 8'd1;
        end
        else begin
            halt_cnt <= 8'd0;
        end
    end
endmodule
