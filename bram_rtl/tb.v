
module tb;
    reg clk;
    reg rst;
    wire [31:0]x3=tb.open_risc_v_soc_inst.open_risc_v_inst.regs_inst.regs[3];
    wire [31:0]x26=tb.open_risc_v_soc_inst.open_risc_v_inst.regs_inst.regs[26];
    wire [31:0]x27=tb.open_risc_v_soc_inst.open_risc_v_inst.regs_inst.regs[27];
    // 1. 生成时钟：每 10ns 翻转�?????�????? (周期 20ns, 频率 50MHz)
    always #10 clk = ~clk;

    // 2. 系统初始化与复位
    initial begin
        clk = 1'b1;         // 使用阻塞赋�?�初始化
        rst = 1'b0;         // �?????机时拉低，进入复位状态！
        #25 rst = 1'b1;     // 等待 25ns (确保经过至少�?????个完整的时钟周期) 后拉高，释放复位�?????
    end

 
    integer i;
    // 4. 实时监控内部寄存器的�?????
    initial begin
        // 延迟�?????下，等复位结束再�?????始监�?????
        wait(rst == 1'b1);
        //while(1) begin
        //    @(posedge clk);
        //    // 修复�????? %d 的语法错�?????
        //    $display("Time: %0t | x27=%d | x28=%d | x29=%d", 
        //              $time,
        //              tb.open_risc_v_soc_inst.open_risc_v_inst.regs_inst.regs[27],
        //              tb.open_risc_v_soc_inst.open_risc_v_inst.regs_inst.regs[28],
        //              tb.open_risc_v_soc_inst.open_risc_v_inst.regs_inst.regs[29]);
        //end
        wait(x26 == 1'b1);
        #200;
        if (x27 == 32'b1) begin
            $display("Test passed: x27 is 1");
        end
        else begin
            $display("Test failed: x27 should be 1 but is %d", x27);
            for ( i = 0; i < 31; i = i + 1) begin
                $display("x%d = %d", i, tb.open_risc_v_soc_inst.open_risc_v_inst.regs_inst.regs[i]);
            end
        end
        $finish();
    end
   
    // 5. 实例�????? SoC 顶层
    open_risc_v_soc open_risc_v_soc_inst(
        .clk(clk),
        .rst(rst)
    );

endmodule