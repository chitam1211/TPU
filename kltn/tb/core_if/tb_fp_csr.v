`timescale 1ns/1ps
module tb_fp_csr;
    reg clk=0,rst=0,write_en=0,flags_en=0;
    reg [11:0] read_addr=0,write_addr=0;
    reg [1:0] write_op=0;
    reg [31:0] write_data=0;
    reg [4:0] flags_in=0;
    wire [31:0] read_data;
    wire [2:0] frm;
    wire [4:0] fflags;
    fp_csr dut(.*);
    always #5 clk=~clk;
    integer old,addr,op,m,n=0;
    reg [31:0] operand,field_value,new_field;
    reg [7:0] expected;
    task inspect;
        begin
            read_addr=3; #1; if(read_data !== {24'b0,expected}) $fatal(1,"FCSR got=%h expected=%h",read_data,expected);
            read_addr=2; #1; if(read_data !== {29'b0,expected[7:5]}) $fatal(1,"FRM alias");
            read_addr=1; #1; if(read_data !== {27'b0,expected[4:0]}) $fatal(1,"FFLAGS alias");
            if({frm,fflags} !== expected) $fatal(1,"Outputs inconsistent");
        end
    endtask
    initial begin
        repeat(2) @(negedge clk); rst=1; expected=0; inspect;
        for(old=0;old<256;old=old+1)
          for(addr=1;addr<=3;addr=addr+1)
            for(op=1;op<=3;op=op+1)
              for(m=0;m<4;m=m+1) begin
                @(negedge clk); write_en=1; write_addr=3; write_op=1; write_data=old; flags_en=0;
                @(negedge clk);
                case(m)
                    0: operand=0; 1: operand=32'hffffffff;
                    2: operand=32'h55555555; 3: operand=32'haaaaaaaa;
                endcase
                field_value=addr==1 ? old & 31 : (addr==2 ? old >> 5 : old);
                case(op)
                    1: new_field=operand; 2: new_field=field_value | operand;
                    3: new_field=field_value & ~operand;
                endcase
                expected=old;
                case(addr)
                    1: expected[4:0]=new_field[4:0];
                    2: expected[7:5]=new_field[2:0];
                    3: expected=new_field[7:0];
                endcase
                write_addr=addr; write_op=op; write_data=operand;
                @(negedge clk); write_en=0; inspect; n=n+1;
              end
        // Accrual preserves old flags; hardware flags survive simultaneous clear.
        @(negedge clk); write_en=1; write_addr=3; write_op=1; write_data=8'h81;
        @(negedge clk); write_en=0; flags_en=1; flags_in=16;
        @(negedge clk); flags_en=0; expected=8'h91; inspect;
        @(negedge clk); write_en=1; write_addr=1; write_op=1; write_data=0; flags_en=1; flags_in=5;
        @(negedge clk); write_en=0; flags_en=0; expected=8'h85; inspect;
        @(negedge clk); rst=0; expected=0; #1; inspect;
        $display("FP_CSR_TEST_PASS alias_operations=%0d",n); $finish;
    end
endmodule
