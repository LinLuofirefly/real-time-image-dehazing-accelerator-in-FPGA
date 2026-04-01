module wb(
    input wire [4:0]  rd_addr_i,      // 最终要写回的目标寄存器地址
    input wire [31:0] rd_data_i,      // ALU 计算得出的最终结果
    input wire        rd_wen_i,       // 最终的寄存器写使能信号
    input wire [31:0]inst_i,         // 从 MEM 级接收的指令机器码 (用于调试或特定指令处理)
    output wire [31:0]inst_o,         // 直接传递给 MEM/WB 寄存器的指令机器码
    output wire [4:0]  rd_addr_o,      
    output wire [31:0] rd_data_o,
    output wire        rd_wen_o
);
assign rd_addr_o      = rd_addr_i;
assign rd_data_o      = rd_data_i;
assign rd_wen_o       = rd_wen_i;
assign inst_o         = inst_i;



endmodule