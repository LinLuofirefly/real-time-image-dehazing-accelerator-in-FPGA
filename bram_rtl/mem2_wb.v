`include "defines.v"


module mem2_wb(
    input  wire        clk,
    input  wire        rst,
    input wire        hold_flag_i,
    input wire [4:0]  rd_addr_i,      // 最终要写回的目标寄存器地址
    input wire [31:0] rd_data_i,      // ALU 计算得出的最终结果
    input wire        rd_wen_i,       // 最终的寄存器写使能信号
    input wire [31:0]inst_i,         // 从 MEM 级接收的指令机器码 (用于调试或特定指令处理)
    output wire [31:0]inst_o,         // 直接传递给 MEM/WB 寄存器的指令机器码
    output wire [4:0]  rd_addr_o,      
    output wire [31:0] rd_data_o,
    output wire        rd_wen_o
);
dff_set #(5)  dff_rd_addr  (clk, rst, hold_flag_i,1'b0, 5'b0,  rd_addr_i,     rd_addr_o);
dff_set #(32) dff_rd_data  (clk, rst, hold_flag_i,1'b0, 32'b0, rd_data_i,     rd_data_o);
dff_set #(1)  dff_rd_wen   (clk, rst, hold_flag_i,1'b0, 1'b0,  rd_wen_i,      rd_wen_o);
dff_set #(32) dff_inst     (clk, rst, hold_flag_i,1'b0, `INST_NOP, inst_i, inst_o);
endmodule