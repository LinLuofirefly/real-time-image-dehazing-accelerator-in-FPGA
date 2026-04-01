`include "defines.v"

module ex(
    // ==========================================================
    // 1. 模块接口定义 (Ports Definition)
    // ==========================================================
    // --- 从 ID/EX 流水线寄存器接收的输入 ---
    input  wire [31:0] inst_i,         // 当前执行的 32 位机器指令
    input  wire [31:0] inst_addr_i,    // 当前指令的 PC 地址
    input  wire [31:0] op1_i,          // 操作数 1 (已由 ID 级准备好)
    input  wire [31:0] op2_i,          // 操作数 2 (已由 ID 级准备好)
    input  wire [4:0]  rd_addr_i,      // 目标寄存器地址输入
    input  wire        rd_wen_i,       // 目标寄存器写使能输入
    // --- 写回阶段 (Write Back) 输出信号 ---
    output reg  [4:0]  rd_addr_o,      // 最终要写回的目标寄存器地址
    output reg  [31:0] rd_data_o,      // ALU 计算得出的最终结果 (准备写入寄存器)
    output reg         rd_wen_o,       // 最终的寄存器写使能信号

    // --- 分支跳转控制输出 (连接至 PC 寄存器和 Ctrl 控制器) ---
    output reg  [31:0] jump_addr_o,    // 计算得出的跳转目标地址
    output reg         jump_en_o,      // 跳转使能信号 (1 表示需要跳转)
    output wire [31:0]inst_o,         // 直接传递给 EX/MEM 寄存器的指令机器码
    // --- 内存访问接口 (用于 Load/Store 指令) ---
    input  wire [31:0] base_addr_i,    // 访存基地址
    input  wire [31:0] addr_offset_i,  // 访存地址偏移量
    output reg  [31:0] mem_rd_addr_o,  // 最终计算出的内存读物理地址 (传给 MEM 级)
    output reg  [3:0]  mem_wd_reg_o,   // 内存写掩码 (指示写字节/半字/字)
    output reg  [31:0] mem_wd_addr_o,  // 最终计算出的内存写物理地址
    output reg  [31:0] mem_wd_data_o,  // 最终要写入内存的数据 (通常来自寄存器)
    output reg   is_load_o          // 是否为 Load 指令 (用于控制后续 MEM 级的行为)
);

    // ==========================================================
    // 2. 指令字段拆解 (Instruction Field Extraction)
    // ==========================================================
    wire [6:0]  opcode;
    wire [2:0]  func3;
    wire [6:0]  func7;
    wire [4:0]  rd;
    wire [4:0]  rs1;
    wire [4:0]  rs2;
    wire [11:0] imm;
    wire [4:0]  shamt;     // 移位量 (Shift Amount)
    wire [31:0] jump_imm;  // B型指令专用跳转立即数

    assign opcode = inst_i[6:0];
    assign func3  = inst_i[14:12];
    assign rd     = inst_i[11:7];
    assign rs1    = inst_i[19:15];
    assign rs2    = inst_i[24:20];
    assign imm    = inst_i[31:20];
    assign func7  = inst_i[31:25];
    assign shamt  = op2_i[4:0];    // 移位操作的位数通常是 op2 的低 5 位

    // B型指令的立即数需要重新组合，并且末尾补 0 (因为指令地址是 2/4 字节对齐的)
    assign jump_imm = {{20{inst_i[31]}}, inst_i[7], inst_i[30:25], inst_i[11:8], 1'b0};
    assign inst_o = inst_i;  // 直接透传指令码给 EX/MEM

    // ==========================================================
    // 3. ALU 算术逻辑运算预处理 (Pre-calculate all ALU results)
    // 硬件设计的核心思想：空间换时间。在这里把所有可能的运算结果
    // 都并行算出来，后面再通过选择器挑出需要的一个。
    // ==========================================================
    // --- 比较器 (Comparators) ---
    wire        op1_i_equal_op2_i;
    wire        op1_i_less_op2_i_signed;
    wire        op1_i_less_op2_i_unsigned;
    assign op1_i_equal_op2_i         = (op1_i == op2_i);                         // 相等比较
    assign op1_i_less_op2_i_signed   = ($signed(op1_i) < $signed(op2_i));        // 有符号小于
    assign op1_i_less_op2_i_unsigned = (op1_i < op2_i);                          // 无符号小于

    // --- 算术与逻辑运算 (Arithmetic & Logic) ---
    wire [31:0] op1_i_add_op2_i;
    wire [31:0] op1_i_and_op2_i;
    wire [31:0] op1_i_xor_op2_i;
    wire [31:0] op1_i_or_op2_i;
    assign op1_i_add_op2_i = op1_i + op2_i;                                      // 加法
    assign op1_i_and_op2_i = op1_i & op2_i;                                      // 按位与
    assign op1_i_xor_op2_i = op1_i ^ op2_i;                                      // 按位异或
    assign op1_i_or_op2_i  = op1_i | op2_i;                                      // 按位或

    // --- 移位运算 (Shift Operations) ---
    wire [31:0] op1_i_shift_left_op2_i;
    wire [31:0] op1_i_shift_right_op2_i;
    wire [31:0] SRA_mask;
    assign op1_i_shift_left_op2_i  = op1_i << op2_i[4:0];                        // 逻辑左移
    assign op1_i_shift_right_op2_i = op1_i >> op2_i[4:0];                        // 逻辑右移 (不带符号位)
    // 算术右移 (SRA) 的符号位掩码：用于保持负数右移时高位补 1
    assign SRA_mask = (32'hffffffff >> shamt[4:0]);                              

    // --- 地址运算 (Address Calculation) ---
    wire [31:0] base_addr_add_addr_offset;
    assign base_addr_add_addr_offset = base_addr_i + addr_offset_i;              // 访存/跳转目标地址计算


    // ==========================================================
    // 4. 执行级主控逻辑 (Execution Routing Logic)
    // 根据 Opcode 选择正确的计算结果输出
    // ==========================================================
    always @(*) begin
        // --- 默认赋值 (防止生成未预期锁存器 Latch) ---
        rd_data_o     = 32'b0;
        rd_addr_o     = 5'b0;
        rd_wen_o      = 1'b0;
        jump_addr_o   = 32'b0;
        jump_en_o     = 1'b0;
        mem_wd_reg_o  = 4'b0000;
        mem_wd_addr_o = 32'b0;
        mem_wd_data_o = 32'b0;
        is_load_o      = 1'b0;
        mem_rd_addr_o  =32'b0;
        case(opcode)
            // >>>>> I 型指令 (立即数运算) <<<<<
            `INST_TYPE_I: begin
                
                case(func3)
                    `INST_ADDI:  begin rd_data_o = op1_i_add_op2_i;                              rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end
                    `INST_SLTI:  begin rd_data_o = {31'b0, op1_i_less_op2_i_signed};             rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end
                    `INST_SLTIU: begin rd_data_o = {31'b0, op1_i_less_op2_i_unsigned};           rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end
                    `INST_ANDI:  begin rd_data_o = op1_i_and_op2_i;                              rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end
                    `INST_ORI:   begin rd_data_o = op1_i_or_op2_i;                               rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end
                    `INST_XORI:  begin rd_data_o = op1_i_xor_op2_i;                              rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end
                    `INST_SLLI:  begin rd_data_o = op1_i_shift_left_op2_i;                       rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end
                    `INST_SRI:   begin
                        if(func7[5] == 1'b0) // SRLI (逻辑右移，高位补0)
                            begin rd_data_o = op1_i_shift_right_op2_i;                           rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end 
                        else                 // SRAI (算术右移，高位补符号位)
                            begin rd_data_o = (op1_i_shift_right_op2_i) & SRA_mask | ({32{op1_i[31]}} & ~SRA_mask); rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end 
                    end
                    default:     begin rd_data_o = 32'b0; rd_addr_o = 5'b0; rd_wen_o = 1'b0; end
                endcase
            end

            // >>>>> R/M 型指令 (寄存器算术逻辑运算) <<<<<
            `INST_TYPE_R_M: begin
             
                case(func3)
                    `INST_ADD_SUB: begin
                        if(func7 == 7'b0000_000) // ADD
                            begin rd_data_o = op1_i_add_op2_i;                                   rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end 
                        else                     // SUB
                            begin rd_data_o = op1_i - op2_i;                                     rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end 
                    end
                    `INST_SLL:  begin rd_data_o = op1_i_shift_left_op2_i;                        rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end
                    `INST_SLT:  begin rd_data_o = {31'b0, op1_i_less_op2_i_signed};              rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end
                    `INST_SLTU: begin rd_data_o = {31'b0, op1_i_less_op2_i_unsigned};            rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end
                    `INST_OR:   begin rd_data_o = op1_i_or_op2_i;                                rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end
                    `INST_XOR:  begin rd_data_o = op1_i_xor_op2_i;                               rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end
                    `INST_AND:  begin rd_data_o = op1_i_and_op2_i;                               rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end
                    `INST_SR:   begin
                        if(func7[5] == 1'b0) // SRL
                            begin rd_data_o = op1_i_shift_right_op2_i;                           rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end 
                        else                 // SRA
                            begin rd_data_o = (op1_i_shift_right_op2_i) & SRA_mask | ({32{op1_i[31]}} & ~SRA_mask); rd_addr_o = rd_addr_i; rd_wen_o = 1'b1; end 
                    end
                    default:    begin rd_data_o = 32'b0; rd_addr_o = 5'b0; rd_wen_o = 1'b0; end
                endcase
            end

            // >>>>> B 型指令 (条件分支) <<<<<
            `INST_TYPE_B: begin
             
                case (func3)
                    `INST_BNE:  begin jump_addr_o = base_addr_add_addr_offset; jump_en_o = ~op1_i_equal_op2_i;              end 
                    `INST_BEQ:  begin jump_addr_o = base_addr_add_addr_offset; jump_en_o = op1_i_equal_op2_i;               end
                    `INST_BLT:  begin jump_addr_o = base_addr_add_addr_offset; jump_en_o = op1_i_less_op2_i_signed;         end
                    `INST_BGE:  begin jump_addr_o = base_addr_add_addr_offset; jump_en_o = ~op1_i_less_op2_i_signed;        end
                    `INST_BLTU: begin jump_addr_o = base_addr_add_addr_offset; jump_en_o = op1_i_less_op2_i_unsigned;       end
                    `INST_BGEU: begin jump_addr_o = base_addr_add_addr_offset; jump_en_o = ~op1_i_less_op2_i_unsigned;      end
                    default:    begin jump_addr_o = 32'b0;                     jump_en_o = 1'b0;                            end
                endcase
            end
            `INST_TYPE_L: begin
                is_load_o = 1'b1; // 标记这是一个 Load 指令，供 MEM 级使用
                rd_addr_o = rd_addr_i;
                rd_wen_o = 1'b1;
                mem_rd_addr_o = base_addr_add_addr_offset; // 计算 Load 指令的内存读地址
            end
            `INST_TYPE_S: begin
                mem_wd_addr_o = base_addr_add_addr_offset; 
                case(func3)
                    `INST_SB:  begin
                            case(base_addr_add_addr_offset[1:0]) // 根据地址最低两位判断是读哪个字节
                            2'b00: begin   mem_wd_reg_o = 4'b0001; mem_wd_data_o = {{24{1'b0}}, op2_i[7:0]}; end
                            2'b01: begin   mem_wd_reg_o = 4'b0010; mem_wd_data_o = {{16{1'b0}}, op2_i[7:0],{8{1'b0}}}; end
                            2'b10: begin   mem_wd_reg_o = 4'b0100; mem_wd_data_o = {{8{1'b0}}, op2_i[7:0],{16{1'b0}}}; end
                            2'b11: begin   mem_wd_reg_o = 4'b1000; mem_wd_data_o = {op2_i[7:0],{24{1'b0}}}; end
                            default: begin mem_wd_reg_o = 4'b0000; mem_wd_data_o = 32'b0; end
                        endcase end
                    `INST_SH:  begin
                        case(base_addr_add_addr_offset[1]) // 根据地址最低位判断是读哪个半字，读取半字时，最后一位必须是0，否则会跨边界，假设地址是0x1003，读半字就会跨过0x1004边界，因为一个字从0x0000，到0x0003为32位四个字节，从0x1004到0x1007为下一个字的四个字节，所以读半字时地址最低位必须是0，才能保证在同一个字内读取
                            1'b1: begin  mem_wd_reg_o = 4'b1100; mem_wd_data_o = {op2_i[15:0],{16{1'b0}}}; end
                            1'b0: begin  mem_wd_reg_o = 4'b0011; mem_wd_data_o = {{16{1'b0}}, op2_i[15:0]}; end
                            default: begin  mem_wd_reg_o = 4'b0000; mem_wd_data_o = 32'b0; end
                        endcase
                    end
                    `INST_SW:  begin   mem_wd_reg_o = 4'b1111; mem_wd_data_o = op2_i; end
                    default:    begin  mem_wd_reg_o = 4'b0000; mem_wd_data_o = 32'b0; end
                endcase
            end
            // >>>>> 绝对跳转指令 (JAL, JALR) <<<<<
            `INST_JAL: begin
                rd_data_o   = op1_i_add_op2_i;             // JAL 的 op1 是 PC, op2 是 4。计算出 PC+4 作为返回地址
                rd_addr_o   = rd_addr_i;
                rd_wen_o    = 1'b1;                        // 保存返回地址到 rd
                jump_addr_o = base_addr_add_addr_offset;   // 跳转基址为当前PC，偏移量为立即数
                jump_en_o   = 1'b1;                        // 触发跳转
                
            end
            
            `INST_JALR: begin
                rd_data_o   = inst_addr_i+32'd4;             // 计算 PC+4
                rd_addr_o   = rd_addr_i;
                rd_wen_o    = 1'b1;
                jump_addr_o = base_addr_add_addr_offset & ~32'd1; // 跳转地址为 rs1 + 立即数，RISC-V 规范要求最低位清零
                jump_en_o   = 1'b1;
                
            end

            // >>>>> U 型指令 (长立即数运算) <<<<<
            `INST_AUIPC: begin
                rd_data_o   = op1_i_add_op2_i;             // rd = PC + 立即数的高 20 位
                rd_addr_o   = rd_addr_i;
                rd_wen_o    = 1'b1;
                jump_addr_o = 32'b0;                       // 不跳转
                jump_en_o   = 1'b0;
                
            end
            
            `INST_LUI: begin
                rd_data_o   = op1_i;                       // rd = 立即数的高 20 位 (此时 op1 已在 ID 级组装好)
                rd_addr_o   = rd_addr_i;
                rd_wen_o    = 1'b1;
                jump_addr_o = 32'b0; 
                jump_en_o   = 1'b0;
                
            end

            // >>>>> 异常 / 缺省处理 <<<<<
            default: begin
                rd_data_o   = 32'b0;
                rd_addr_o   = 5'b0;
                rd_wen_o    = 1'b0;
                jump_en_o   = 1'b0;
                jump_addr_o = 32'b0;
                mem_wd_addr_o = 32'b0;
                mem_wd_data_o = 32'b0;
                mem_wd_reg_o  = 4'b0000;

            end
        endcase
    end

endmodule