`include "defines.v"

// id_ex 流水线寄存器
// stall  (hold_flag_i=1)  : 不使用（Load-Use 时 ID/EX 应 flush，不 stall）
// flush  (flush_flag_i=1) : 清空 ID/EX，插入气泡（NOP）
//                          触发条件：Load-Use 冒险 或 跳转
module id_ex(
    input wire        clk,
    input wire        rst,
    input wire        hold_flag_i,    // stall（本级一般不冻结，保留接口）
    input wire        flush_flag_i,   // flush：Load-Use 或跳转时清空本级
    input wire [31:0] inst_i,
    input wire [31:0] inst_addr_i,
    input wire [31:0] op1_i,
    input wire [31:0] op2_i,
    input wire [4:0]  rd_addr_i,
    input wire        reg_wen_i,
    input wire [31:0] base_addr_i,
    input wire [31:0] addr_offset_i,
    output wire [31:0] inst_o,
    output wire [31:0] inst_addr_o,
    output wire [31:0] op1_o,
    output wire [31:0] op2_o,
    output wire [4:0]  rd_addr_o,
    output wire        reg_wen_o,
    output wire [31:0] base_addr_o,
    output wire [31:0] addr_offset_o
);

dff_set #(32) dff3  (clk, rst, hold_flag_i, flush_flag_i, `INST_NOP, inst_i,       inst_o);
dff_set #(32) dff4  (clk, rst, hold_flag_i, flush_flag_i, 32'b0,     inst_addr_i,  inst_addr_o);
dff_set #(32) dff5  (clk, rst, hold_flag_i, flush_flag_i, 32'b0,     op1_i,        op1_o);
dff_set #(32) dff6  (clk, rst, hold_flag_i, flush_flag_i, 32'b0,     op2_i,        op2_o);
dff_set #(5)  dff7  (clk, rst, hold_flag_i, flush_flag_i, 5'b0,      rd_addr_i,    rd_addr_o);
dff_set #(1)  dff8  (clk, rst, hold_flag_i, flush_flag_i, 1'b0,      reg_wen_i,    reg_wen_o);
dff_set #(32) dff9  (clk, rst, hold_flag_i, flush_flag_i, 32'b0,     base_addr_i,  base_addr_o);
dff_set #(32) dff10 (clk, rst, hold_flag_i, flush_flag_i, 32'b0,     addr_offset_i,addr_offset_o);

endmodule