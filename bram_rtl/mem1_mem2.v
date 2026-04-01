`include "defines.v"
module mem1_mem2(
    input  wire clk,
    input wire rst,
    input  wire [31:0] inst_i,        // 从 EX/MEM 接收的指令机器码
    input  wire [4:0]  rd_addr_i,     // 最终要写回的目标寄存器地址
    input  wire [31:0] rd_data_i,     // ALU 计算得出的最终结果
    input  wire        rd_wen_i,      // 最终的寄存器写使能信号
    input  wire          hold_flag_i,    // 来自控制单元的流水线暂停信号
    input wire          flush_flag_i,
    input  wire [31:0] mem_rd_addr_i, // 内存访问地址
    input  wire        is_load_i,     // 是否是 load 指令
    output wire [4:0]  rd_addr_o,      
    output wire [31:0] rd_data_o,     
    output wire        rd_wen_o,  
    output wire [31:0] inst_o,   
    output wire is_load_o,
    output wire [31:0]mem_rd_addr_o  
);

dff_set #(32) dff3  (clk, rst, hold_flag_i, flush_flag_i, `INST_NOP, inst_i,       inst_o);
dff_set #(32) dff6  (clk, rst, hold_flag_i, flush_flag_i, 32'b0,     rd_data_i,    rd_data_o);
dff_set #(5)  dff7  (clk, rst, hold_flag_i, flush_flag_i, 5'b0,      rd_addr_i,    rd_addr_o);
dff_set #(1)  dff8  (clk, rst, hold_flag_i, flush_flag_i, 1'b0,      rd_wen_i,     rd_wen_o);
dff_set #(32) dff10 (clk, rst, hold_flag_i, flush_flag_i, 32'b0,    mem_rd_addr_i, mem_rd_addr_o);
dff_set #(1) dff11 (clk, rst, hold_flag_i, flush_flag_i, 1'b0,    is_load_i, is_load_o);






endmodule
