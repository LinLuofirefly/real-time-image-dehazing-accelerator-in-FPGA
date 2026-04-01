`include "defines.v"

module id(
    // ==========================================================
    // 1. 模块接口定义 (Ports Definition)
    // ==========================================================
    // --- 从 IF/ID 流水线寄存器接收的输入 ---
    input  wire[31:0] inst_i,        // 32位机器指令
    input  wire[31:0] inst_addr_i,   // 指令对应的 PC 地址

    // --- 向 通用寄存器堆 (Regfile) 发送的读请求 ---
    output reg [4:0]  rs1_addr_o,    // 源寄存器 1 地址
    output reg [4:0]  rs2_addr_o,    // 源寄存器 2 地址
    // --- 从 通用寄存器堆 (Regfile) 接收的读数据 ---
    input  wire[31:0] rs1_data_i,    // 源寄存器 1 读取到的数据
    input  wire[31:0] rs2_data_i,    // 源寄存器 2 读取到的数据

    // --- 传递给下一级 (ID/EX 流水线寄存器) 的数据与控制信号 ---
    output reg [31:0] inst_o,        // 原样透传的指令机器码
    output reg [31:0] inst_addr_o,   // 原样透传的指令 PC 地址
    output reg [31:0] op1_o,         // 给 ALU 的第一个操作数 (通常是 rs1)
    output reg [31:0] op2_o,         // 给 ALU 的第二个操作数 (通常是 rs2 或 立即数)
    output reg [4:0]  rd_addr_o,     // 目标寄存器地址 (计算结果写回哪里)
    output reg        reg_wen,       // 寄存器写使能 (1表示需要写回结果)
    
    // --- 内存访问及跳转辅助信号 ---
    output reg [31:0] base_addr_o,   // 基地址 (常用于访存或跳转计算)
    output reg [31:0] addr_offset_o, // 地址偏移量 (常用于访存或跳转计算)
    output reg        mem_rd_reg_o   // 内存读使能 (指示这是一条 Load 指令)
);  

    // ==========================================================
    // 2. 指令字段拆解 (Instruction Field Extraction)
    // 根据 RISC-V 规范，将 32 位指令固定位置的线网截取出来
    // ==========================================================
    wire [6:0]  opcode; // 操作码：决定了指令的基本大类
    wire [2:0]  func3;  // 功能码3：细分具体指令 (如 ADD 和 SUB)
    wire [6:0]  func7;  // 功能码7：进一步细分指令
    wire [4:0]  rd;     // 目标寄存器索引
    wire [4:0]  rs1;    // 源寄存器1索引
    wire [4:0]  rs2;    // 源寄存器2索引
    wire [11:0] imm;    // 12位立即数 (I型或S型)
    wire [4:0]  shamt;  // 移位位数 (用于移位指令，通常是 imm 的低5位)

    assign opcode = inst_i[6:0];
    assign rd     = inst_i[11:7];
    assign func3  = inst_i[14:12];
    assign rs1    = inst_i[19:15];
    assign rs2    = inst_i[24:20];
    assign func7  = inst_i[31:25]; // 注意：代码中这里原写为 [31:26]，标准 RISC-V 应为 [31:25]
    assign imm    = inst_i[31:20];
    assign shamt  = imm[4:0];

    // ==========================================================
    // 3. 译码主逻辑 (Combinational Logic)
    // ==========================================================
    always @(*) begin
        // ------------------------------------------------------
        // 3.1 默认输出赋值 (防止生成锁存器 Latch)
        // ------------------------------------------------------
        inst_o        = inst_i;      // 直接透传指令
        inst_addr_o   = inst_addr_i; // 直接透传地址
        mem_rd_reg_o  = 1'b0;        // 默认非 Load 指令
      

        // ------------------------------------------------------
        // 3.2 按照 Opcode 大类进行分支译码
        // ------------------------------------------------------
        case(opcode)
            
            // >>>>> I 型指令 (立即数算术逻辑运算) <<<<<
            `INST_TYPE_I: begin
                base_addr_o   = 32'b0;
                addr_offset_o = 32'b0;
                case(func3)
                    // 常规算术与逻辑运算 (ADDI, SLTI, ANDI 等)
                    `INST_ADDI,`INST_SLTI,`INST_SLTIU,`INST_ORI,`INST_XORI,`INST_ANDI: begin
                        rs1_addr_o = rs1;        // 读取 rs1 寄存器
                        rs2_addr_o = 5'b0;       // 不使用 rs2
                        op1_o      = rs1_data_i; // 操作数1：寄存器值
                        op2_o      = {{20{imm[11]}}, imm}; // 操作数2：12位立即数符号扩展至32位
                        rd_addr_o  = rd;         // 写回 rd 寄存器
                        reg_wen    = 1'b1;       // 开启写使能
                    end
                    // 移位指令 (SLLI, SRLI/SRAI)
                    `INST_SLLI,`INST_SRI: begin
                        rs1_addr_o = rs1;
                        rs2_addr_o = 5'b0;
                        op1_o      = rs1_data_i;
                        op2_o      = {27'b0, shamt}; // 移位指令特殊处理：操作数2为5位移位量
                        rd_addr_o  = rd;
                        reg_wen    = 1'b1;
                    end
                    default: begin
                        // 异常缺省处理
                        rs1_addr_o = 5'b0; rs2_addr_o = 5'b0;
                        op1_o = 32'b0; op2_o = 32'b0;
                        rd_addr_o = 5'b0; reg_wen = 1'b0;
                    end
                endcase
            end

            // >>>>> R/M 型指令 (寄存器-寄存器算术逻辑运算 / 乘除法) <<<<<
            `INST_TYPE_R_M: begin
                base_addr_o   = 32'b0;
                addr_offset_o = 32'b0;
                case(func3)
                    // 常规运算 (ADD, SUB, AND, OR 等)
                    `INST_ADD_SUB,`INST_SLT,`INST_SLTU,`INST_OR,`INST_XOR,`INST_AND: begin
                         rs1_addr_o = rs1;
                         rs2_addr_o = rs2;       // R型指令需要同时读取两个寄存器
                         op1_o      = rs1_data_i;
                         op2_o      = rs2_data_i; // 操作数2来自寄存器
                         rd_addr_o  = rd;
                         reg_wen    = 1'b1;
                    end
                    // 移位运算 (SLL, SRL/SRA)
                    `INST_SLL,`INST_SR: begin
                        rs1_addr_o = rs1;
                        rs2_addr_o = rs2;
                        op1_o      = rs1_data_i;
                        op2_o      = {27'b0, rs2_data_i[4:0]}; // 取 rs2 的低5位作为移位量
                        rd_addr_o  = rd;
                        reg_wen    = 1'b1;
                    end
                    default: begin
                        rs1_addr_o = 5'b0; rs2_addr_o = 5'b0;
                        op1_o = 32'b0; op2_o = 32'b0;
                        rd_addr_o = 5'b0; reg_wen = 1'b0;
                    end
                endcase
            end

            // >>>>> B 型指令 (条件分支跳转) <<<<<
            `INST_TYPE_B: begin
                case (func3)
                    `INST_BNE,`INST_BEQ,`INST_BLT,`INST_BGE,`INST_BLTU,`INST_BGEU: begin
                        rs1_addr_o    = rs1;
                        rs2_addr_o    = rs2;        // 比较两个寄存器的值
                        op1_o         = rs1_data_i;
                        op2_o         = rs2_data_i;
                        rd_addr_o     = 5'b0;       // 分支指令不写回寄存器
                        reg_wen       = 1'b0;
                        base_addr_o   = inst_addr_i; // 分支基地址为当前 PC
                        // 组装 B 型指令的特殊立即数格式
                        addr_offset_o = {{20{inst_i[31]}}, inst_i[7], inst_i[30:25], inst_i[11:8], 1'b0};
                    end 
                    default: begin
                        rs1_addr_o = 5'b0; rs2_addr_o = 5'b0;
                        op1_o = 32'b0; op2_o = 32'b0; rd_addr_o = 5'b0; reg_wen = 1'b0;
                        base_addr_o = 32'b0; addr_offset_o = 32'b0;
                    end
                endcase
            end

            // >>>>> L 型指令 (从内存加载数据到寄存器 Load) <<<<<
            `INST_TYPE_L: begin
                case (func3)
                    `INST_LB,`INST_LH,`INST_LW,`INST_LBU,`INST_LHU: begin
                        rs1_addr_o    = rs1;         // 提供基址的寄存器
                        rs2_addr_o    = 5'b0;
                        op1_o         = 32'b0;       // Load由专用的访存模块处理，EX级不需要算术操作
                        op2_o         = 32'b0;
                        rd_addr_o     = rd;          // 内存数据读出后写回到 rd
                        reg_wen       = 1'b1;
                        base_addr_o   = rs1_data_i;  // 基地址来自 rs1 寄存器的值
                        addr_offset_o = {{20{imm[11]}}, imm[11:0]};
                        mem_rd_reg_o  = 1'b1;        // 标记内存读操作激活
                        // 提前计算访存物理地址：寄存器值 + 符号扩展的12位立即数
                    end 
                    default: begin
                        rs1_addr_o = 5'b0; rs2_addr_o = 5'b0; op1_o = 32'b0; op2_o = 32'b0;
                        rd_addr_o = 5'b0; reg_wen = 1'b0; base_addr_o = 32'b0; addr_offset_o = 32'b0;
                        mem_rd_reg_o = 1'b0; 
                    end
                endcase
            end

            // >>>>> S 型指令 (将寄存器数据存储到内存 Store) <<<<<
            `INST_TYPE_S: begin
                case (func3)
                    `INST_SB,`INST_SH,`INST_SW: begin
                        rs1_addr_o    = rs1;         // rs1 提供基址
                        rs2_addr_o    = rs2;         // rs2 提供要写入内存的数据
                        op1_o         = rs1_data_i;  
                        op2_o         = rs2_data_i;
                        rd_addr_o     = 5'b0;        // Store不写回目标寄存器
                        reg_wen       = 1'b0;
                        base_addr_o   = rs1_data_i;  // 基地址
                        // 组装 S 型指令的特殊立即数格式作为偏移量
                        addr_offset_o = {{20{inst_i[31]}}, inst_i[31:25], inst_i[11:7]};
                        mem_rd_reg_o  = 1'b0;
                       
                    end 
                    default: begin
                        rs1_addr_o = 5'b0; rs2_addr_o = 5'b0; op1_o = 32'b0; op2_o = 32'b0;
                        rd_addr_o = 5'b0; reg_wen = 1'b0; base_addr_o = 32'b0; addr_offset_o = 32'b0;
                        mem_rd_reg_o = 1'b0;
                    end
                endcase
            end

            // >>>>> J 型指令 (无条件绝对跳转并链接) <<<<<
            `INST_JAL: begin
                rs1_addr_o    = 5'b0; 
                rs2_addr_o    = 5'b0;
                op1_o         = inst_addr_i; // 操作数1：当前PC
                op2_o         = 32'd4;       // 操作数2：4 (为了算出 PC+4 写回寄存器)
                rd_addr_o     = rd;          // 将 PC+4 保存到 rd (通常是 ra 寄存器)
                reg_wen       = 1'b1;
                base_addr_o   = inst_addr_i; // 跳转基址为当前 PC
                // 组装 J 型指令的特殊立即数格式
                addr_offset_o = {{12{inst_i[31]}}, inst_i[19:12], inst_i[20], inst_i[30:21], 1'b0};
                mem_rd_reg_o  = 1'b0;
            end

            // >>>>> JALR 指令 (无条件寄存器跳转并链接) <<<<<
            `INST_JALR: begin
                rs1_addr_o    = rs1;         // 读取 rs1 寄存器作为跳转基址
                rs2_addr_o    = 5'b0;
                op1_o         = inst_addr_i; // 操作数1：当前PC
                op2_o         = 32'd4;       // 操作数2：4 (算出 PC+4 保存)
                rd_addr_o     = rd;
                reg_wen       = 1'b1;
                base_addr_o   = rs1_data_i;  // 跳转基址为 rs1 寄存器的值
                addr_offset_o = {{20{imm[11]}}, imm[11:0]}; // 偏移量为常规立即数
                mem_rd_reg_o  = 1'b0;
            end

            // >>>>> U 型指令 (构建长立即数操作) <<<<<
            `INST_AUIPC: begin
                rs1_addr_o    = 5'b0; 
                rs2_addr_o    = 5'b0;
                op1_o         = inst_addr_i;  // 操作数1：指令的高20位立即数，低12位补0
                op2_o         = {inst_i[31:12], 12'b0};           // 操作数2：当前 PC
                rd_addr_o     = rd;                     // 结果 (PC + imm) 存入 rd
                reg_wen       = 1'b1;
                base_addr_o   = 32'b0;
                addr_offset_o = 32'b0;
                mem_rd_reg_o  = 1'b0;
            end

            `INST_LUI: begin
                rs1_addr_o    = 5'b0;
                rs2_addr_o    = 5'b0;
                op1_o         = {inst_i[31:12], 12'b0}; // 操作数1：直接取高20位立即数，低12位补0
                op2_o         = 32'b0;                  // 操作数2：0 (所以结果直接等于 imm)
                rd_addr_o     = rd;
                reg_wen       = 1'b1;
                base_addr_o   = 32'b0;
                addr_offset_o = 32'b0;
                mem_rd_reg_o  = 1'b0;
            end

            // >>>>> 异常 / 未知指令的缺省处理 <<<<<
            default: begin
                rs1_addr_o = 5'b0; rs2_addr_o = 5'b0; op1_o = 32'b0; op2_o = 32'b0;
                rd_addr_o = 5'b0; reg_wen = 1'b0; base_addr_o = 32'b0; addr_offset_o = 32'b0;
                mem_rd_reg_o = 1'b0;
            end

        endcase
    end

endmodule