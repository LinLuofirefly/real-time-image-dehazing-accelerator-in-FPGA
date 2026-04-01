`include "defines.v"
module mem2(
    input  wire [31:0] inst_i,        // 从 EX/MEM 接收的指令机器码
    input  wire [4:0]  rd_addr_i,     // 最终要写回的目标寄存器地址
    input  wire [31:0] rd_data_i,     // ALU 计算得出的最终结果
    input  wire        rd_wen_i,      // 最终的寄存器写使能信号
    input  wire [31:0] mem_rd_addr_i, // 内存访问地址
    input  wire        is_load_i,     // 是否是 load 指令
    input  wire [31:0] mem_rd_data_i, // 从外设 RAM 读取的数据 
    output wire [31:0] inst_o,         // 直接传递给 MEM/WB 寄存器的指令机器码
    output wire [4:0]  rd_addr_o,      
    output reg [31:0] rd_data_o,
    output wire        rd_wen_o
);
    wire [2:0] func3;
    assign func3 = inst_i[14:12];
    assign rd_addr_o     = rd_addr_i;       
    assign rd_wen_o      = rd_wen_i;
    assign inst_o        = inst_i;
    always @(*) begin
        if(is_load_i) begin
            case(func3)
                `INST_LB:  begin 
                    case(mem_rd_addr_i[1:0])
                        2'b00: rd_data_o = {{24{mem_rd_data_i[7]}},  mem_rd_data_i[7:0]};
                        2'b01: rd_data_o = {{24{mem_rd_data_i[15]}}, mem_rd_data_i[15:8]};
                        2'b10: rd_data_o = {{24{mem_rd_data_i[23]}}, mem_rd_data_i[23:16]};
                        2'b11: rd_data_o = {{24{mem_rd_data_i[31]}}, mem_rd_data_i[31:24]};
                        default: rd_data_o = 32'b0;
                    endcase 
                end
                `INST_LH:  begin
                    case(mem_rd_addr_i[1]) 
                        1'b0: rd_data_o = {{16{mem_rd_data_i[15]}}, mem_rd_data_i[15:0]};
                        1'b1: rd_data_o = {{16{mem_rd_data_i[31]}}, mem_rd_data_i[31:16]};
                        default: rd_data_o = 32'b0;
                    endcase
                end
                `INST_LW:  begin rd_data_o = mem_rd_data_i; end
                `INST_LBU: begin 
                    case(mem_rd_addr_i[1:0])
                        2'b00: rd_data_o = {{24{1'b0}}, mem_rd_data_i[7:0]};
                        2'b01: rd_data_o = {{24{1'b0}}, mem_rd_data_i[15:8]};
                        2'b10: rd_data_o = {{24{1'b0}}, mem_rd_data_i[23:16]};
                        2'b11: rd_data_o = {{24{1'b0}}, mem_rd_data_i[31:24]};
                        default: rd_data_o = 32'b0;
                    endcase 
                end
                `INST_LHU: begin 
                    case(mem_rd_addr_i[1]) 
                        1'b0: rd_data_o = {{16{1'b0}}, mem_rd_data_i[15:0]};
                        1'b1: rd_data_o = {{16{1'b0}}, mem_rd_data_i[31:16]};
                        default: rd_data_o = 32'b0;
                    endcase 
                end
                default: rd_data_o = 32'b0;
            endcase
        end else begin
            // 不是 Load 指令，直接使用 EX 级传来的数据
            rd_data_o = rd_data_i; 
        end
    end











endmodule