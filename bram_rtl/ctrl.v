module ctrl(
    input  wire        clk,        //  新增 clk 端口
    input  wire        rst,        //  新增 rst 端口
    input  wire [31:0] jump_addr_i,
    input  wire        jump_en_i,
    
    output wire        jump_en_o,
    output wire [31:0] jump_addr_o,
    output wire        flush_flag_o
);

    reg jump_en_delay;

    // 记录上一拍是否有跳转发生
    always @(posedge clk) begin
        if (!rst) begin
            jump_en_delay <= 1'b0;
        end else begin
            jump_en_delay <= jump_en_i;
        end
    end

    assign jump_en_o   = jump_en_i;
    assign jump_addr_o = jump_addr_i;
    
    // 终极绝杀：只要当前拍要求跳，或者上一拍跳过，都统统给我 Flush！
    // 这样就能击毙从同步 ROM 里延迟一拍漏出来的“幽灵指令”
    assign flush_flag_o = jump_en_i | jump_en_delay;
//4月1日笔记：由于rom是同步的，所以当跳转发起冲刷的时候，有个指令的地址进入了bram，然后在第二个拍输出到id，这个也是废指令，所以需要二次flush
//当检测到要求跳转的时候，就再冲刷一遍，这样就能把那个废指令冲掉。
endmodule