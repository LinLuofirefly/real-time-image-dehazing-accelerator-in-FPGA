`include "defines.v"

module ex_mem1(
    input  wire        clk,
    input  wire        rst,
    
    // 来自控制模块的流水线控制信号 (用于暂停或清空当前寄存器)
    input  wire       hold_flag_i,    
    input wire [31:0] inst_i,         // 从 EX 级接收的指令机器码 (用于调试或特定指令处理)
    // --- 从 EX 级接收的输入 ---
    input  wire [4:0]  rd_addr_i,      // 最终要写回的目标寄存器地址
    input  wire [31:0] rd_data_i,      // ALU 计算得出的最终结果
    input  wire        rd_wen_i,       // 最终的寄存器写使能信号
    input  wire [31:0] mem_rd_addr_i,   // 内存读地址
    output  wire [31:0] mem_rd_addr_o,  // 最终计算出的内存读物理地址
    input  wire [3:0]  mem_wd_reg_i,   // 内存写掩码 (指示写字节/半字/字)
    input  wire [31:0] mem_wd_addr_i,  // 最终计算出的内存写物理地址
    input  wire [31:0] mem_wd_data_i,  // 最终要写入内存的数据 
    input  wire  is_load_i,       // 是否是 load 指令 (用于区分写回数据来源)
    // --- 打一拍后，输出给 MEM 级的信号 ---
    output wire [4:0]  rd_addr_o,      
    output wire [31:0] rd_data_o,      
    output wire        rd_wen_o,       
    output wire is_load_o,       // 直接传递给 MEM/WB 寄存器，供 WB 级判断是否是 load 指令
    output wire [3:0]  mem_wd_reg_o,   
    output wire [31:0] mem_wd_addr_o,  
    output wire [31:0] mem_wd_data_o,
    output wire [31:0] inst_o          // 直接传递给 EX/MEM 寄存器的指令机器码
);
//跳转指令不需要打拍，防止跳转指令的目标地址和写寄存器地址被错误地保存在 ex_mem 寄存器中，导致后续指令错误地使用了这些值。而且还会导致流水线多取出一个错误指令，增加了错误指令的数量和调试难度。     
    // 假设你的 dff_set 端口顺序是: (clk, rst, hold/stall, default_val, data_in, data_out)
    dff_set #(5)  dff_rd_addr  (clk, rst, hold_flag_i,1'b0, 5'b0,  rd_addr_i,     rd_addr_o);
    dff_set #(32) dff_rd_data  (clk, rst, hold_flag_i,1'b0, 32'b0, rd_data_i,     rd_data_o);
    dff_set #(1)  dff_rd_wen   (clk, rst, hold_flag_i,1'b0, 1'b0,  rd_wen_i,      rd_wen_o);
    
    dff_set #(4)  dff_mem_wreg (clk, rst, hold_flag_i,1'b0, 4'b0,  mem_wd_reg_i,  mem_wd_reg_o);
    dff_set #(32) dff_mem_waddr(clk, rst, hold_flag_i,1'b0, 32'b0, mem_wd_addr_i, mem_wd_addr_o);
    dff_set #(32) dff_mem_wdata(clk, rst, hold_flag_i,1'b0, 32'b0, mem_wd_data_i, mem_wd_data_o);
    dff_set #(1)  dff_is_load  (clk, rst, hold_flag_i,1'b0, 1'b0,  is_load_i,     is_load_o);
    dff_set #(32) dff_inst     (clk, rst, hold_flag_i,1'b0, `INST_NOP, inst_i, inst_o);
    dff_set #(32) dff_mem_rd_addr(clk, rst, hold_flag_i,1'b0, 32'b0, mem_rd_addr_i, mem_rd_addr_o);
endmodule