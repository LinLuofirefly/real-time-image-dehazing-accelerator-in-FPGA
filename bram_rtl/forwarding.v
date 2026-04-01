// ============================================================
//  前递单元 (Forwarding Unit)
//  功能:
//    检测流水线中的数据相关 (RAW Hazard)，将最新的计算结果
//    旁路到 EX 级的操作数输入端，避免程序在不插入 stall 的前提
//    下读到过时的寄存器值。
//
//  支持的前递路径:
//    1. EX/MEM → EX  (前一条指令在 EX 级产生的结果 → 当前指令)
//    2. MEM/WB → EX  (前两条指令在 MEM 级产生的结果 → 当前指令)
//
//  优先级: EX/MEM 路径优先于 MEM/WB 路径。
//
//  注意: Load-Use 冒险（Load 紧跟使用同一寄存器的指令）无法
//    通过前递完全消除，仍需由冒险检测单元插入 1 个气泡 (bubble)
//    并暂停流水线。本单元负责在暂停后的那一拍完成 MEM/WB→EX 前递。
// ============================================================

`include "defines.v"

module forwarding (
    // ----------------------------------------------------------
    // 1. 当前处于 ID/EX 阶段的指令信息
    //    (已经过 ID 级译码，即将进入 EX 级执行)
    // ----------------------------------------------------------
    input  wire [31:0] id_ex_inst_i,       // ID/EX 级寄存器锁存的指令机器码
    input  wire [31:0] id_ex_op1_i,        // ID/EX 级传来的操作数 1 (原始，来自 Regfile)
    input  wire [31:0] id_ex_op2_i,        // ID/EX 级传来的操作数 2 (原始，来自 Regfile)
    input  wire [31:0] id_ex_base_addr_i,  // ID/EX 级传来的访存基地址 (Load/Store/Branch)
    input  wire [31:0] id_ex_addr_offset_i,// ID/EX 级传来的地址偏移量

    // ----------------------------------------------------------
    // 2. EX/MEM 级的结果 (前一条指令刚在 EX 级执行完毕)
    //    EX → EX 前递来源
    // ----------------------------------------------------------
    input  wire [4:0]  ex_mem_rd_addr_i,   // EX/MEM 级目标寄存器地址
    input  wire [31:0] ex_mem_rd_data_i,   // EX/MEM 级 ALU 计算结果
    input  wire        ex_mem_rd_wen_i,    // EX/MEM 级寄存器写使能
  
   
    input  wire [4:0]  mem1_mem2_rd_addr_i,   // EX/MEM 级传给 MEM1/MEM2 级的目标寄存器地址
    input  wire [31:0] mem1_mem2_rd_data_i,   // EX/MEM 级传给 MEM1/MEM2 级的 ALU 计算结果
    input  wire        mem1_mem2_rd_wen_i,    // EX/MEM 级传给 MEM1/MEM2 级的寄存器写使能

    // ----------------------------------------------------------
    // 3. MEM/WB 级的结果 (前两条指令已完成 MEM 级)
    //    MEM → EX 前递来源
    // ----------------------------------------------------------
    input  wire [4:0]  mem_wb_rd_addr_i,   // MEM/WB 级目标寄存器地址
    input  wire [31:0] mem_wb_rd_data_i,   // MEM/WB 级写回数据 (可能来自 Load 或 ALU)
    input  wire        mem_wb_rd_wen_i,    // MEM/WB 级寄存器写使能

    // ----------------------------------------------------------
    // 4. 前递后的操作数输出 (送入 EX 级 ALU 前的最终操作数)
    // ----------------------------------------------------------
    output reg  [31:0] fwd_op1_o,          // 前递修正后的操作数 1
    output reg  [31:0] fwd_op2_o,          // 前递修正后的操作数 2
    output reg  [31:0] fwd_base_addr_o,    // 前递修正后的访存基地址
    output reg  [31:0] fwd_addr_offset_o,   // 前递后的地址偏移量 (通常不前递，直接透传)
    input  wire        ex_mem_is_load_i   //mem1里可能为load指令，要等到mem2完成后才能够把数据前递
);

    // ----------------------------------------------------------
    // 从指令机器码中提取 rs1 / rs2 索引
    // RISC-V 所有需要读寄存器的格式，rs1 始终在 [19:15]，rs2 在 [24:20]
    // ----------------------------------------------------------
    wire [6:0] opcode = id_ex_inst_i[6:0];
    wire [4:0] rs1    = id_ex_inst_i[19:15];
    wire [4:0] rs2    = id_ex_inst_i[24:20];

    // ----------------------------------------------------------
    // 判断当前指令是否使用 rs1 / rs2
    // 减少对 x0 寄存器（硬连线 0）的无效前递检测
    // ----------------------------------------------------------
    // 使用 rs1 的指令类型: I / R / B / L / S / JALR
    wire use_rs1 = (opcode == `INST_TYPE_I)   ||
                   (opcode == `INST_TYPE_R_M)  ||
                   (opcode == `INST_TYPE_B)    ||
                   (opcode == `INST_TYPE_L)    ||
                   (opcode == `INST_TYPE_S)    ||
                   (opcode == `INST_JALR);

    // 使用 rs2 的指令类型: R / B / S
    wire use_rs2 = (opcode == `INST_TYPE_R_M)  ||
                   (opcode == `INST_TYPE_B)    ||
                   (opcode == `INST_TYPE_S);
    // 新增：只有这三兄弟，它们的基地址才依赖 rs1，才需要前递！
    wire use_base_addr = (opcode == `INST_TYPE_L) ||
                         (opcode == `INST_TYPE_S) ||
                         (opcode == `INST_JALR);
    // ----------------------------------------------------------
    // 前递选择逻辑 (组合逻辑)
    //
    // 优先级 (高 → 低):
    //   ① EX/MEM → EX  (最新结果，距离最近)
    //   ② MEM/WB → EX  (次新结果)
    //   ③ 无相关，使用 ID/EX 寄存器中的原始操作数
    // ----------------------------------------------------------
    always @(*) begin

        // ---- 操作数 1 (rs1) ----
        if (use_rs1 && (rs1 != 5'b0) && ex_mem_rd_wen_i && (ex_mem_rd_addr_i == rs1)&&!ex_mem_is_load_i) begin
            // EX/MEM → EX 前递：上一条指令写的寄存器就是当前 rs1
            fwd_op1_o = ex_mem_rd_data_i;
        end
        else if (use_rs1 && (rs1 != 5'b0) && mem1_mem2_rd_wen_i && (mem1_mem2_rd_addr_i == rs1)) begin
            // EX/MEM → EX 前递：前两条指令写的寄存器就是当前 rs1
            fwd_op1_o = mem1_mem2_rd_data_i;
        end
        else if (use_rs1 && (rs1 != 5'b0) && mem_wb_rd_wen_i && (mem_wb_rd_addr_i == rs1)) begin
            // MEM/WB → EX 前递：前两条指令写的寄存器就是当前 rs1
            fwd_op1_o = mem_wb_rd_data_i;
        end
        else begin
            // 无相关，原样透传
            fwd_op1_o = id_ex_op1_i;
        end

        // ---- 操作数 2 (rs2) ----
        if (use_rs2 && (rs2 != 5'b0) && ex_mem_rd_wen_i && (ex_mem_rd_addr_i == rs2)&&!ex_mem_is_load_i) begin
            // EX/MEM → EX 前递
            fwd_op2_o = ex_mem_rd_data_i;
        end
        else if (use_rs2 && (rs2 != 5'b0) && mem1_mem2_rd_wen_i && (mem1_mem2_rd_addr_i == rs2)) begin
            // MEM1/MEM2 → EX 前递
            fwd_op2_o = mem1_mem2_rd_data_i;
        end
        else if (use_rs2 && (rs2 != 5'b0) && mem_wb_rd_wen_i && (mem_wb_rd_addr_i == rs2)) begin
            // MEM/WB → EX 前递
            fwd_op2_o = mem_wb_rd_data_i;
        end
        else begin
            // 无相关，原样透传
            fwd_op2_o = id_ex_op2_i;
        end

        // ---- 访存基地址 (base_addr，来自 rs1 用于 Load/Store/JALR) ----
        // Load 指令: base_addr = rs1_data,  op1/op2 已置 0，不含 rs1 信息
        // Store 指令: base_addr 与 op1 均来自 rs1，两路都需前递
        // JALR 指令: base_addr = rs1_data
        // 因此对 base_addr 单独做 rs1 相关检测
        if (use_base_addr && (rs1 != 5'b0) && ex_mem_rd_wen_i && (ex_mem_rd_addr_i == rs1)&&!ex_mem_is_load_i) begin
            fwd_base_addr_o = ex_mem_rd_data_i;
        end
        else if (use_base_addr && (rs1 != 5'b0) && mem1_mem2_rd_wen_i && (mem1_mem2_rd_addr_i == rs1)) begin
            fwd_base_addr_o = mem1_mem2_rd_data_i;
        end
        else if (use_base_addr && (rs1 != 5'b0) && mem_wb_rd_wen_i && (mem_wb_rd_addr_i == rs1)) begin
            fwd_base_addr_o = mem_wb_rd_data_i;
        end
        else begin
            fwd_base_addr_o = id_ex_base_addr_i;
        end

        // ---- 地址偏移量 (addr_offset) ----
        // 偏移量来自立即数，不依赖寄存器，直接透传
        fwd_addr_offset_o = id_ex_addr_offset_i;

    end // always

endmodule
