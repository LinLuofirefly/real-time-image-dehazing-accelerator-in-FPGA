`include "defines.v"

module if_id(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] inst_i,       // 从 ROM 实时吐出的指令
    input  wire [31:0] inst_addr_i,
    input  wire        hold_flag_i,
    input  wire        flush_flag_i,
    output wire [31:0] inst_addr_o,
    output reg  [31:0] inst_o
);

    // ==========================================================
    //  核心部件：Skid Buffer (指令防滑缓冲器)
    // 用于解决同步 ROM 在 Stall 期间依然会输出下一条指令导致数据丢失的问题
    // ==========================================================
    reg [31:0] hold_inst_reg;  // 避难所：保存被拦截的指令
    reg        is_holding_reg; // 状态标记：当前是否正在使用避难所的数据

    always @(posedge clk) begin
        if (rst == 1'b0 || flush_flag_i == 1'b1) begin
            hold_inst_reg  <= 32'b0;
            is_holding_reg <= 1'b0;
        end 
        else if (hold_flag_i == 1'b1 && is_holding_reg == 1'b0) begin
            // 刚被罚站的第一拍：赶紧把 ROM 当前吐出的指令抢救进避难所！
            hold_inst_reg  <= inst_i;
            is_holding_reg <= 1'b1;
        end 
        else if (hold_flag_i == 1'b0) begin
            // 罚站结束：清空避难所，恢复正常
            is_holding_reg <= 1'b0;
        end
    end

    // ==========================================================
    // 输出路由选择 (组合逻辑)
    // ==========================================================
    always @(*) begin
        if (rst == 1'b0 || flush_flag_i == 1'b1) begin
            inst_o = `INST_NOP;      // 复位或冲刷，塞入气泡
        end 
        else if (is_holding_reg == 1'b1) begin
            inst_o = hold_inst_reg;  // 🚨 罚站期间，一直输出避难所里保存的指令！
        end 
        else begin
            inst_o = inst_i;         // 正常流通，直接透传 ROM 最新数据
        end
    end

    // PC 地址依然打一拍，保持与 ROM 输出节奏的绝对对齐，不需要改
    dff_set #(32) dff_inst_addr (clk, rst, hold_flag_i, 1'b0, 32'b0, inst_addr_i, inst_addr_o);

endmodule
//4月1日笔记：不能写inst_o=inst_o这种代码了，直接把课上学的都忘完了，还有一个lw mv冒险，为了解决冒险使得流水线暂停，
//lw指令在ex，mv指令在id，触发了暂停，然后因为inst_o=inst_o是组合逻辑非法，所以pc稳定+4送来的新指令覆盖了id里的MOV指令导致mv指令消失
//正确做法是将mv指令用时序逻辑打一拍存起来，然后用多路复用器判断究竟输出哪个指令，防止指令丢失
//解决问题的方法：首先查看各个寄存器的数值，对比dump文件，找出指令和pc地址，再通过波形图查看id的指令，ex的指令，冲刷信号，前馈的东西等等，综合判断是哪里出了问题
//PC地址在暂停时不能归零，跳转时的下一个指令如auipc需要这个pc地址，一旦清零就会进入错误的地方，指令冲刷了，但是地址不等你冲刷。