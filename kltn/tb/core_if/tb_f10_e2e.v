`timescale 1ns/1ps
// The only writes from this TB are program/data RAM initialization and reset.
// Every retired instruction is compared with a sequential architectural model.
module tb_f10_e2e;
    reg clk=0,rst=0,active=0;
    always #5 clk=~clk;
`ifdef DELAYED_MEMORY
    core_if_delayed_test_system dut(.clk(clk),.rst(rst),.instruction(32'b0));
`else
    microprocessor dut(.clk(clk),.rst(rst),.instruction(32'b0));
`endif
    reg [2047:0] case_path,wave_path;
    integer fd,status,nret,nmem,i,retired=0,requests=0,cycles=0;
    reg [31:0] pc[0:511],insn[0:511],wx[0:511],wf[0:511];
    reg [31:0] rd[0:511],value[0:511],csr_value[0:511];
    reg [31:0] mw[0:511],ma[0:511],md[0:511],final_mem[0:255];
    reg [31:0] want_csr;
    reg check_csr;
    integer trace_fd=0;
    reg [2047:0] trace_path;
    task check;
        input [31:0] actual,expected;
        input [8*64-1:0] label;
        begin
            if(actual !== expected) $fatal(1,"%0s retire=%0d request=%0d got=%h expected=%h",label,retired,requests,actual,expected);
        end
    endtask
    always @(posedge clk) begin
        check_csr=0;
        if(rst && active) begin
            cycles=cycles+1;
            if((^{dut.data_mem_request,dut.u_core.wb_valid,dut.u_core.reg_write_wb,dut.u_core.fp_reg_write_wb}) === 1'bx)
                $fatal(1,"Unknown control");
            if(dut.u_core.reg_write_wb && dut.u_core.fp_reg_write_wb) $fatal(1,"Both register banks written");
            if(!dut.u_core.wb_valid && (dut.u_core.reg_write_wb || dut.u_core.fp_reg_write_wb)) $fatal(1,"Write outside retirement");
            if(dut.data_mem_request) begin
                if(requests>=nmem) $fatal(1,"Extra memory request");
                check(dut.data_mem_we_re,mw[requests],"Memory direction");
                check(dut.alu_out_address,ma[requests],"Memory address");
                if(mw[requests]) begin
                    check(dut.store_data,md[requests],"Memory write data");
                    check(dut.mask,15,"Memory mask");
                end
                requests=requests+1;
            end
            if(dut.u_core.wb_valid) begin
                if(retired>=nret) $fatal(1,"Extra retirement");
                check(dut.u_core.pre_pc_addr_wb,pc[retired],"Retirement PC");
                check(dut.u_core.instruction_wb,insn[retired],"Retirement instruction");
                check(dut.u_core.reg_write_wb,wx[retired],"GPR write enable");
                check(dut.u_core.fp_reg_write_wb,wf[retired],"FPR write enable");
                if(wx[retired] || wf[retired]) begin
                    check(dut.u_core.instruction_wb[11:7],rd[retired],"Destination register");
                    check(dut.u_core.rd_wb_data,value[retired],"Writeback bits");
                end
                want_csr=csr_value[retired]; check_csr=1;
                if(trace_fd) $fdisplay(trace_fd,"%0d,%08h,%08h,%0d,%0d,%0d,%08h,%02h",cycles,pc[retired],insn[retired],wx[retired],wf[retired],rd[retired],dut.u_core.rd_wb_data,want_csr);
                retired=retired+1;
            end
        end
        #1;
        if(check_csr) check({24'b0,dut.u_core.frm,dut.u_core.fflags},want_csr,"FCSR after retirement");
    end
    initial begin
        if(!$value$plusargs("case=%s",case_path)) $fatal(1,"Missing +case=file");
        if($value$plusargs("vcd=%s",wave_path)) begin $dumpfile(wave_path); $dumpvars(0,dut); end
        if($value$plusargs("trace_csv=%s",trace_path)) begin
            trace_fd=$fopen(trace_path,"w");
            if(!trace_fd) $fatal(1,"Cannot open trace CSV");
            $fdisplay(trace_fd,"cycle,pc,instruction,gpr_we,fpr_we,rd,wb_bits,fcsr_after");
        end
        fd=$fopen(case_path,"r"); if(!fd) $fatal(1,"Cannot open case %0s",case_path);
        status=$fscanf(fd,"%d %d\n",nret,nmem);
        if(status!=2 || nret>512 || nmem>512) $fatal(1,"Bad case header");
        for(i=0;i<256;i=i+1) begin status=$fscanf(fd,"%h\n",dut.u_instruction_memory.u_memory.mem[i]); if(status!=1) $fatal(1,"Bad imem"); end
        for(i=0;i<256;i=i+1) begin status=$fscanf(fd,"%h\n",dut.u_data_memory.u_memory.mem[i]); if(status!=1) $fatal(1,"Bad dmem"); end
        for(i=0;i<nret;i=i+1) begin
            status=$fscanf(fd,"%h %h %h %h %h %h %h\n",pc[i],insn[i],wx[i],wf[i],rd[i],value[i],csr_value[i]);
            if(status!=7) $fatal(1,"Bad retirement row");
        end
        for(i=0;i<nmem;i=i+1) begin status=$fscanf(fd,"%h %h %h\n",mw[i],ma[i],md[i]); if(status!=3) $fatal(1,"Bad memory row"); end
        for(i=0;i<256;i=i+1) begin status=$fscanf(fd,"%h\n",final_mem[i]); if(status!=1) $fatal(1,"Bad final memory"); end
        $fclose(fd);
        repeat(3) @(negedge clk); rst=1; active=1;
        while(retired<nret && cycles<30000) @(negedge clk);
        if(retired!=nret) $fatal(1,"CPU timeout retired=%0d/%0d pc=%h",retired,nret,dut.pc_address);
        active=0;
        check(requests,nmem,"Memory request count");
        for(i=0;i<256;i=i+1) check(dut.u_data_memory.u_memory.mem[i],final_mem[i],"Final memory");
        $display("F10_E2E_TEST_PASS retired=%0d requests=%0d cycles=%0d",retired,requests,cycles);
        if(trace_fd) $fclose(trace_fd);
        if($test$plusargs("reset_test")) begin
            // Cancel FSUB f0,f1,f2 while normalization is busy.
            rst=0;
            for(i=0;i<256;i=i+1) dut.u_instruction_memory.u_memory.mem[i]=32'h0000006f;
            dut.u_data_memory.u_memory.mem[0]=32'h3f800001;
            dut.u_data_memory.u_memory.mem[1]=32'h3f800000;
            dut.u_instruction_memory.u_memory.mem[0]=32'h00002087; // flw f1,0(x0)
            dut.u_instruction_memory.u_memory.mem[1]=32'h00402107; // flw f2,4(x0)
            dut.u_instruction_memory.u_memory.mem[2]=32'h08208053; // fsub.s f0,f1,f2,rne
            repeat(3) @(negedge clk); rst=1;
            wait(dut.u_core.fp_start); @(negedge clk);
            repeat(5) @(negedge clk);
            if(!dut.u_core.fp_busy) $fatal(1,"Reset test missed busy operation");
            rst=0; #1;
            check(dut.u_core.fp_busy,0,"Busy reset");
            check({24'b0,dut.u_core.frm,dut.u_core.fflags},0,"FCSR reset");
            for(i=0;i<32;i=i+1) begin
                check(dut.u_core.u_decodestage.u_fp_regfile0.register[i],0,"FPR reset");
                check(dut.u_core.u_decodestage.u_regfile0.register[i],0,"GPR reset");
            end
            // New program stores f0 and exits. A stale nonzero result is fatal.
            dut.u_instruction_memory.u_memory.mem[0]=32'h20002027; // fsw f0,512(x0)
            dut.u_instruction_memory.u_memory.mem[1]=32'h12300f93; // addi x31,x0,0x123
            dut.u_instruction_memory.u_memory.mem[2]=32'h3ff02e23; // sw x31,1020(x0)
            dut.u_data_memory.u_memory.mem[128]=32'hdeadbeef;
            dut.u_data_memory.u_memory.mem[255]=0;
            repeat(3) @(negedge clk); rst=1;
            while(dut.u_data_memory.u_memory.mem[255] !== 32'h123) @(negedge clk);
            repeat(40) @(negedge clk);
            check(dut.u_data_memory.u_memory.mem[128],0,"No stale store after reset");
            check(dut.u_core.u_decodestage.u_fp_regfile0.register[0],0,"No stale FP completion");
            check({24'b0,dut.u_core.frm,dut.u_core.fflags},0,"No stale flags");
            $display("F10_RESET_BUSY_TEST_PASS");
        end
        $finish;
    end
    initial begin #2000000; $fatal(1,"Global timeout"); end
endmodule
