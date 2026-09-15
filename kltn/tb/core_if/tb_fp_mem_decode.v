module tb_fp_mem_decode;

    reg  [6:0] opcode;
    reg  [2:0] fun3;
    reg        fun7;
    reg        valid;
    reg        load_control;

    wire       reg_write;
    wire       fp_reg_write;
    wire [2:0] imm_sel;
    wire       operand_b;
    wire       operand_a;
    wire [1:0] mem_to_reg;
    wire       Load;
    wire       Store;
    wire       fp_load;
    wire       fp_store;
    wire       jalr_out;
    wire       Branch;
    wire       mem_en;
    wire       next_sel;
    wire [3:0] alu_control;
    wire       matrix_decode;

    integer errors;
    integer gate_case;
    integer format_case;

    controlunit dut (
        .opcode(opcode),
        .fun3(fun3),
        .fun7(fun7),
        .valid(valid),
        .load_control(load_control),

        .reg_write(reg_write),
        .fp_reg_write(fp_reg_write),

        .imm_sel(imm_sel),
        .operand_b(operand_b),
        .operand_a(operand_a),
        .mem_to_reg(mem_to_reg),

        .Load(Load),
        .Store(Store),
        .fp_load(fp_load),
        .fp_store(fp_store),

        .jalr_out(jalr_out),
        .Branch(Branch),
        .mem_en(mem_en),
        .next_sel(next_sel),
        .alu_control(alu_control),
        .matrix_decode(matrix_decode)
    );

    task check_bit;
        input actual;
        input expected;
        input [8*64-1:0] name;
        begin
            if (actual !== expected) begin
                $display("[FAIL] %s expected=%b actual=%b", name, expected, actual);
                errors = errors + 1;
            end
            else begin
                $display("[PASS] %s = %b", name, actual);
            end
        end
    endtask

    task check3;
        input [2:0] actual;
        input [2:0] expected;
        input [8*64-1:0] name;
        begin
            if (actual !== expected) begin
                $display("[FAIL] %s expected=%b actual=%b", name, expected, actual);
                errors = errors + 1;
            end
            else begin
                $display("[PASS] %s = %b", name, actual);
            end
        end
    endtask

    task check4;
        input [3:0] actual;
        input [3:0] expected;
        input [8*64-1:0] name;
        begin
            if (actual !== expected) begin
                $display("[FAIL] %s expected=%b actual=%b", name, expected, actual);
                errors = errors + 1;
            end
            else begin
                $display("[PASS] %s = %b", name, actual);
            end
        end
    endtask

    initial begin
        errors       = 0;
        valid        = 1'b0;
        load_control = 1'b0;
        fun7         = 1'b0;

        // ------------------------------------------------------------
        // FLW: opcode 0000111, funct3 010
        // ------------------------------------------------------------
        $display("\nTEST FLW");
        opcode = 7'b0000111;
        fun3   = 3'b010;
        #1;

        check_bit(Load,         1'b1, "FLW Load");
        check_bit(Store,        1'b0, "FLW Store");
        check_bit(fp_load,      1'b1, "FLW fp_load");
        check_bit(fp_store,     1'b0, "FLW fp_store");
        check_bit(reg_write,    1'b0, "FLW integer reg_write");
        check_bit(fp_reg_write, 1'b1, "FLW fp_reg_write");
        check_bit(mem_en,       1'b0, "FLW must not write memory");
        check_bit(operand_a,    1'b0, "FLW address base from GPR");
        check_bit(mem_to_reg == 2'b01, 1'b1, "FLW memory result selection");
        check_bit(operand_b,    1'b1, "FLW operand_b immediate");
        check3(imm_sel,         3'b000, "FLW I immediate");
        check4(alu_control,     4'b0000, "FLW address ADD");

        // ------------------------------------------------------------
        // FSW: opcode 0100111, funct3 010
        // ------------------------------------------------------------
        $display("\nTEST FSW");
        opcode = 7'b0100111;
        fun3   = 3'b010;
        #1;

        check_bit(Load,         1'b0, "FSW Load");
        check_bit(Store,        1'b1, "FSW Store");
        check_bit(fp_load,      1'b0, "FSW fp_load");
        check_bit(fp_store,     1'b1, "FSW fp_store");
        check_bit(reg_write,    1'b0, "FSW integer reg_write");
        check_bit(fp_reg_write, 1'b0, "FSW fp_reg_write");
        check_bit(mem_en,       1'b1, "FSW mem_en");
        check_bit(operand_a,    1'b0, "FSW address base from GPR");
        check_bit(operand_b,    1'b1, "FSW operand_b immediate");
        check3(imm_sel,         3'b001, "FSW S immediate");
        check4(alu_control,     4'b0000, "FSW address ADD");

        // ------------------------------------------------------------
        // Regression: integer LW must still be integer write-back.
        // ------------------------------------------------------------
        $display("\nTEST LW regression");
        opcode = 7'b0000011;
        fun3   = 3'b010;
        #1;

        check_bit(Load,         1'b1, "LW Load");
        check_bit(fp_load,      1'b0, "LW fp_load");
        check_bit(reg_write,    1'b1, "LW integer reg_write");
        check_bit(fp_reg_write, 1'b0, "LW fp_reg_write");
        check_bit(fp_store,     1'b0, "LW clears previous FP store");
        check_bit(Store,        1'b0, "LW must not retain FSW Store");
        check_bit(mem_en,       1'b0, "LW must not retain FSW mem_en");
        check3(imm_sel,         3'b000, "LW I immediate");

        // ------------------------------------------------------------
        // Regression: integer SW must still be normal STORE.
        // ------------------------------------------------------------
        $display("\nTEST SW regression");
        opcode = 7'b0100011;
        fun3   = 3'b010;
        #1;

        check_bit(Store,        1'b1, "SW Store");
        check_bit(fp_store,     1'b0, "SW fp_store");
        check_bit(reg_write,    1'b0, "SW reg_write");
        check_bit(mem_en,       1'b1, "SW mem_en");
        check3(imm_sel,         3'b001, "SW S immediate");

        // ------------------------------------------------------------
        // Invalid LOAD-FP funct3 must not become FLW.
        // ------------------------------------------------------------
        $display("\nTEST invalid LOAD-FP funct3");
        opcode = 7'b0000111;
        fun3   = 3'b001;
        #1;

        check_bit(Load,         1'b0, "invalid FP Load");
        check_bit(fp_load,      1'b0, "invalid fp_load");
        check_bit(fp_reg_write, 1'b0, "invalid fp_reg_write");

        // ------------------------------------------------------------
        // Invalid STORE-FP funct3 must not become FSW.
        // ------------------------------------------------------------
        $display("\nTEST invalid STORE-FP funct3");
        opcode = 7'b0100111;
        fun3   = 3'b001;
        #1;

        check_bit(Store,        1'b0, "invalid FP Store");
        check_bit(fp_store,     1'b0, "invalid fp_store");

        // Check every unsupported width, immediately after a legal FP op.
        // This also verifies that changing funct3 cannot retain write enables.
        $display("\nTEST all unsupported FP memory formats");
        for (format_case = 0; format_case < 8; format_case = format_case + 1) begin
            if (format_case != 2) begin
                opcode = 7'b0000111;
                fun3 = 3'b010;
                #1;
                fun3 = format_case[2:0];
                #1;
                check_bit(Load,         1'b0, "unsupported FP Load");
                check_bit(fp_load,      1'b0, "unsupported fp_load");
                check_bit(fp_reg_write, 1'b0, "unsupported FP write-back");
                check_bit(reg_write,    1'b0, "unsupported FP GPR write-back");

                opcode = 7'b0100111;
                fun3 = 3'b010;
                #1;
                fun3 = format_case[2:0];
                #1;
                check_bit(Store,        1'b0, "unsupported FP Store");
                check_bit(fp_store,     1'b0, "unsupported fp_store");
                check_bit(mem_en,       1'b0, "unsupported FP memory write");
            end
        end

        // Preserve the legacy load gating for both LW and FLW.
        // load_control still contributes to integer reg_write independently;
        // classification of a completed FP load belongs to the later pipeline step.
        $display("\nTEST load gating and release");
        for (gate_case = 1; gate_case < 4; gate_case = gate_case + 1) begin
            opcode = 7'b0000111;
            fun3 = 3'b010;
            valid = 1'b0;
            load_control = 1'b0;
            #1;
            check_bit(fp_load, 1'b1, "FLW before gating");
            valid = gate_case[0];
            load_control = gate_case[1];
            #1;
            check_bit(Load,         1'b0, "gated FLW Load");
            check_bit(fp_load,      1'b0, "gated fp_load");
            check_bit(fp_reg_write, 1'b0, "gated FP write-back");
            check_bit(reg_write, load_control, "legacy load_control GPR enable");

            opcode = 7'b0000011;
            #1;
            check_bit(Load,    1'b0, "gated LW Load");
            check_bit(fp_load, 1'b0, "gated LW not FP");
            valid = 1'b0;
            load_control = 1'b0;
            #1;
            check_bit(Load,      1'b1, "LW after gate release");
            check_bit(reg_write, 1'b1, "LW write-back after gate release");
            opcode = 7'b0000111;
            #1;
            check_bit(fp_load,      1'b1, "FLW after gate release");
            check_bit(fp_reg_write, 1'b1, "FLW write-back after gate release");
            check_bit(reg_write,    1'b0, "FLW after release must not write GPR");
        end

        // A normal integer instruction must clear the preceding FP load.
        $display("\nTEST FLW to ADDI transition");
        opcode = 7'b0010011;
        fun3 = 3'b000;
        #1;
        check_bit(Load,         1'b0, "ADDI Load");
        check_bit(Store,        1'b0, "ADDI Store");
        check_bit(fp_load,      1'b0, "ADDI fp_load");
        check_bit(fp_store,     1'b0, "ADDI fp_store");
        check_bit(fp_reg_write, 1'b0, "ADDI FP write-back");
        check_bit(reg_write,    1'b1, "ADDI GPR write-back");

        $display("\nTEST FSW to matrix transition");
        opcode = 7'b0100111;
        fun3 = 3'b010;
        #1;
        opcode = 7'b0101011;
        #1;
        check_bit(matrix_decode, 1'b1, "matrix decode preserved");
        check_bit(Load,          1'b0, "matrix Load");
        check_bit(Store,         1'b0, "matrix clears FSW Store");
        check_bit(fp_load,       1'b0, "matrix fp_load");
        check_bit(fp_store,      1'b0, "matrix clears fp_store");
        check_bit(fp_reg_write,  1'b0, "matrix FP write-back");
        check_bit(reg_write,     1'b0, "matrix GPR write-back");
        check_bit(mem_en,        1'b0, "matrix clears FSW memory write");

        $display("\nTEST FLW to unknown opcode transition");
        opcode = 7'b0000111;
        #1;
        opcode = 7'b1111111;
        #1;
        check_bit(matrix_decode, 1'b0, "unknown opcode matrix decode");
        check_bit(Load,          1'b0, "unknown opcode Load");
        check_bit(Store,         1'b0, "unknown opcode Store");
        check_bit(fp_load,       1'b0, "unknown opcode fp_load");
        check_bit(fp_store,      1'b0, "unknown opcode fp_store");
        check_bit(fp_reg_write,  1'b0, "unknown opcode FP write-back");
        check_bit(reg_write,     1'b0, "unknown opcode GPR write-back");
        check_bit(mem_en,        1'b0, "unknown opcode memory write");

        if (errors == 0) begin
            $display("\nFP_MEM_DECODE_TEST_PASS");
        end
        else begin
            $fatal(1, "\nFP_MEM_DECODE_TEST_FAIL: %0d error(s)", errors);
        end

        $finish;
    end

endmodule
