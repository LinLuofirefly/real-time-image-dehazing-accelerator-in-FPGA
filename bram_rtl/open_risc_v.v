`include "defines.v"

module open_risc_v (
    input  wire        clk,
    input  wire        rst_n,          // 外部传入的复位信号 (低电平有效)
    input  wire [31:0] inst_i,         // 从外部 ROM 读入的指令机器码
    input  wire [31:0] ram_data_i,     // 从外部 RAM 读入的数据
    
    output wire [31:0] pc_reg_pc_o,    // 输出给外部 ROM 的取指地址
    
    output wire        mem_rd_reg_o,   // 输出给外部 RAM 的读使能信号
    output wire [31:0] mem_rd_addr_o,  // 输出给外部 RAM 的读地址
    output wire [3:0]  w_en,           // 输出给外部 RAM 的写使能信号 (掩码)
    output wire [31:0] w_addr_i,       // 输出给外部 RAM 的写地址
    output wire [31:0] w_data_i        // 输出给外部 RAM 的写数据
);

    // ==========================================================
    // 0. 全局控制信号
    // ==========================================================
    wire rst = rst_n; // 统一复位信号命名（高电平有效）

    // --- CTRL（跳转控制器）输出 ---
    wire [31:0] ctrl_jump_addr_o;
    wire        ctrl_jump_en_o;
    wire        ctrl_flush_flag_o;   // 跳转时冲刷 IF/ID 和 ID/EX

    // --- HDU（冒险检测单元）输出 ---
    // Load-Use 冒险：PC 和 IF/ID 需要 stall（冻结），ID/EX 需要 flush（插 NOP）
    wire        hdu_hold_flag_o;     // stall 信号：冻结 PC 和 IF/ID
    wire        hdu_flush_flag_o;    // flush 信号：清空 ID/EX（插 NOP 气泡）

    // ==========================================================
    // 1. IF/ID (取指 / 译码 级间)
    // ==========================================================
    wire [31:0] if_id_inst_addr_o; 
    wire [31:0] if_id_inst_o;
  

    // ==========================================================
    // 2. ID (译码级)
    // ==========================================================
    wire [4:0]  id_rs1_addr_o;     
    wire [4:0]  id_rs2_addr_o;     
    wire [31:0] id_inst_o;         
    wire [31:0] id_inst_addr_o;    
    wire [31:0] id_op1_o;          
    wire [31:0] id_op2_o;          
    wire [4:0]  id_rd_addr_o;      
    wire        id_reg_wen;        
    wire [31:0] id_base_addr_o;
    wire [31:0] id_addr_offset_o;
    wire        data_read_en;           

    // ==========================================================
    // 3. Regfile (寄存器堆)
    // ==========================================================
    wire [31:0] regs_reg1_rdata_o; 
    wire [31:0] regs_reg2_rdata_o; 
    
    wire [4:0]  wb_rd_addr_o; // 来自 WB 级最终写回的地址
    wire [31:0] wb_rd_data_o; // 来自 WB 级最终写回的数据
    wire        wb_rd_wen_o;  // 来自 WB 级最终写回的使能

    // ==========================================================
    // 4. ID/EX (译码 / 执行 级间)
    // ==========================================================
    wire [31:0] id_ex_inst_o;      
    wire [31:0] id_ex_inst_addr_o; 
    wire [31:0] id_ex_op1_o;       
    wire [31:0] id_ex_op2_o;       
    wire [4:0]  id_ex_rd_addr_o;   
    wire        id_ex_reg_wen;     
    wire [31:0] id_ex_base_addr_o;
    wire [31:0] id_ex_addr_offset_o;

    // ==========================================================
    // 4b. MEM2 (访存级)
    // ==========================================================
    wire [31:0]mem2_inst_o;
    wire [4:0] mem2_rd_addr_o;
    wire [31:0] mem2_rd_data_o;
    wire mem2_rd_wen_o;

    // ==========================================================
    // 5. EX (执行级)
    // ==========================================================
    wire [4:0]  ex_rd_addr_o;      
    wire [31:0] ex_rd_data_o;      
    wire        ex_rd_wen_o; 
    wire [3:0]  ex_wd_reg_o;   
    wire [31:0] ex_wd_addr_o;  
    wire [31:0] ex_wd_data_o;
    wire        ex_is_load_o;  
    wire [31:0] ex_inst_o;     
    wire [31:0] ex_jump_addr_o;
    wire        ex_jump_en_o;

    // ==========================================================
    // 5b. Forwarding Unit (前递单元) 中间线网
    // ==========================================================
    wire [31:0] fwd_op1_o;          // 前递后传入 EX 的操作数 1
    wire [31:0] fwd_op2_o;          // 前递后传入 EX 的操作数 2
    wire [31:0] fwd_base_addr_o;    // 前递后传入 EX 的访存基地址
    wire [31:0] fwd_addr_offset_o;  // 透传的地址偏移量

    // ==========================================================
    // 6. EX/MEM (执行 / 访存 级间)
    // ==========================================================
    wire [4:0]  ex_mem_pipe_rd_addr_o;  // EX/MEM 输出的 rd 寄存器地址 (5-bit)
    wire [31:0] ex_mem_rd_data_o;
    wire        ex_mem_rd_wen_o;
    wire [3:0]  ex_mem_wd_reg_o;   
    wire [31:0] ex_mem_wd_addr_o;  
    wire [31:0] ex_mem_wd_data_o;  
    wire        ex_mem_is_load_o;
    wire [31:0] ex_mem_inst_o;

    // ==========================================================
    // 7. MEM (访存级)
    // ==========================================================
    wire [4:0]  mem_out_rd_addr_o; 
    wire [31:0] mem_out_rd_data_o;
    wire        mem_out_rd_wen_o;
    wire [31:0] mem_inst_o; 

    // ==========================================================
    // 8. MEM/WB (访存 / 写回 级间)
    // ==========================================================
    wire [4:0]  mem_wb_rd_addr_o;
    wire [31:0] mem_wb_rd_data_o;
    wire        mem_wb_rd_wen_o;
    wire [31:0] mem_wb_inst_o;

    wire [31:0] ex_rd_mem_addr_o;       // EX 输出的 Load 读地址 (32-bit)
    wire [31:0] ex_mem_mem_rd_addr_o;   // EX/MEM 输出的 Load 读地址 (32-bit)
    // ==========================================================
    // 顶层外部 RAM 接口连线
    // ==========================================================
    assign mem_rd_reg_o  = ex_mem_is_load_o; // Load 使能
    assign mem_rd_addr_o = ex_mem_mem_rd_addr_o; // Load 读地址


    // **********************************************************
    // 模块例化 (Module Instantiations)
    // **********************************************************

    // 1. PC 寄存器
    // hold_flag_i：Load-Use 冒险时 stall（冻结 PC，不推进）
    // 跳转由 jump_en + jump_addr 直接覆盖，不需要额外 flush
    pc_reg pc_reg_inst(
        .clk         (clk),
        .rst         (rst),
        .jump_en     (ctrl_jump_en_o), 
        .jump_addr_i (ctrl_jump_addr_o), 
        .hold_flag_i (hdu_hold_flag_o),  // Load-Use：冻结 PC
        .pc_o        (pc_reg_pc_o)
    );

    // 2. IF/ID 流水线寄存器
    // stall（hold）：Load-Use 冒险时冻结，保持当前取到的指令
    // flush：跳转时清空（冲刷错误指令，插入 NOP）
    if_id if_id_inst(
        .clk          (clk),
        .rst          (rst),
        .inst_i       (inst_i),       
        .inst_addr_i  (pc_reg_pc_o),  
        .inst_addr_o  (if_id_inst_addr_o),
        .inst_o       (if_id_inst_o),
        .hold_flag_i  (hdu_hold_flag_o),  // Load-Use：冻结 IF/ID
        .flush_flag_i (ctrl_flush_flag_o)  // 跳转：冲刷 IF/ID
    );

    // 3. 通用寄存器堆 (Register File)
    regs regs_inst(
        .clk         (clk),
        .rst         (rst),
        .reg1_raddr_i(id_rs1_addr_o),
        .reg2_raddr_i(id_rs2_addr_o),
        .reg1_rdata_o(regs_reg1_rdata_o),
        .reg2_rdata_o(regs_reg2_rdata_o),
        .reg_wen     (wb_rd_wen_o),
        .reg_waddr_i (wb_rd_addr_o),
        .reg_wdata_i (wb_rd_data_o)
    );

    // 4. 译码模块 (ID)
    id id_inst(
        .inst_i        (if_id_inst_o),
        .inst_addr_i   (if_id_inst_addr_o),
        .rs1_data_i    (regs_reg1_rdata_o),
        .rs2_data_i    (regs_reg2_rdata_o),
        .rs1_addr_o    (id_rs1_addr_o),
        .rs2_addr_o    (id_rs2_addr_o),
        .inst_o        (id_inst_o),
        .inst_addr_o   (id_inst_addr_o),
        .op1_o         (id_op1_o),
        .op2_o         (id_op2_o),
        .rd_addr_o     (id_rd_addr_o),
        .reg_wen       (id_reg_wen),
        .base_addr_o   (id_base_addr_o),
        .addr_offset_o (id_addr_offset_o),
        .mem_rd_reg_o  (data_read_en) 
    );

    // 5. ID/EX 流水线寄存器
    // flush：Load-Use 冒险 或 跳转时，清空 ID/EX（插入 NOP 气泡）
    // stall：本级不冻结（Load-Use 时应 flush 而非 stall）
    id_ex id_ex_inst(
        .clk           (clk),
        .rst           (rst),
        .hold_flag_i   (1'b0),                                   // ID/EX 不冻结
        .flush_flag_i  (hdu_flush_flag_o | ctrl_flush_flag_o),   // Load-Use 或跳转：清空
        .inst_i        (id_inst_o),
        .inst_addr_i   (id_inst_addr_o),
        .op1_i         (id_op1_o),
        .op2_i         (id_op2_o),
        .rd_addr_i     (id_rd_addr_o),
        .reg_wen_i     (id_reg_wen),
        .base_addr_i   (id_base_addr_o),
        .addr_offset_i (id_addr_offset_o),
        .inst_o        (id_ex_inst_o),
        .inst_addr_o   (id_ex_inst_addr_o),
        .op1_o         (id_ex_op1_o),
        .op2_o         (id_ex_op2_o),
        .rd_addr_o     (id_ex_rd_addr_o),
        .reg_wen_o     (id_ex_reg_wen),
        .base_addr_o   (id_ex_base_addr_o),
        .addr_offset_o (id_ex_addr_offset_o)
    );
    
    // 6a. 前递单元 (Forwarding Unit)
    //     检测 EX/MEM→EX 和 MEM/WB→EX 两条前递路径
    forwarding forwarding_inst (
        .id_ex_inst_i        (id_ex_inst_o),
        .id_ex_op1_i         (id_ex_op1_o),
        .id_ex_op2_i         (id_ex_op2_o),
        .id_ex_base_addr_i   (id_ex_base_addr_o),
        .id_ex_addr_offset_i (id_ex_addr_offset_o),
        .ex_mem_rd_addr_i    (ex_mem_pipe_rd_addr_o),
        .ex_mem_rd_data_i    (ex_mem_rd_data_o),
        .ex_mem_rd_wen_i     (ex_mem_rd_wen_o),
        .mem_wb_rd_addr_i    (mem_wb_rd_addr_o),
        .mem_wb_rd_data_i    (mem_wb_rd_data_o),
        .mem_wb_rd_wen_i     (mem_wb_rd_wen_o),
        .fwd_op1_o           (fwd_op1_o),
        .fwd_op2_o           (fwd_op2_o),
        .fwd_base_addr_o     (fwd_base_addr_o),
        .fwd_addr_offset_o   (fwd_addr_offset_o),
        .ex_mem_is_load_i    (ex_mem_is_load_o),
        .mem1_mem2_rd_addr_i (mem2_rd_addr_o),
        .mem1_mem2_rd_data_i (mem2_rd_data_o),
        .mem1_mem2_rd_wen_i  (mem2_rd_wen_o)
    );

    // 6b. 冒险检测单元 (Hazard Detection Unit)
    //     检测 Load-Use 冒险，发出 stall（冻结 PC/IF_ID）和 flush（清空 ID/EX）
    Hazard_detection_unit hdu_inst (
        .id_inst_i    (if_id_inst_o),    // ID 级指令（IF/ID 寄存器输出）
        .ex_inst_i    (id_ex_inst_o),    // EX 级指令（ID/EX 寄存器输出）
        //.mem1_inst_i  (ex_mem_inst_o),   // MEM 级指令（EX/MEM 寄存器输出）
        .hold_flag_o  (hdu_hold_flag_o), // → stall PC 和 IF/ID
        .flush_flag_o (hdu_flush_flag_o) // → flush ID/EX
    );

    // 6c. 执行模块 (EX)
    //     操作数来自前递单元，解决 RAW 数据相关
    ex ex_inst(
        .inst_i        (id_ex_inst_o),
        .inst_addr_i   (id_ex_inst_addr_o),
        .op1_i         (fwd_op1_o),          // ← 前递后的操作数 1
        .op2_i         (fwd_op2_o),          // ← 前递后的操作数 2
        .rd_addr_i     (id_ex_rd_addr_o),
        .rd_wen_i      (id_ex_reg_wen),
        .base_addr_i   (fwd_base_addr_o),    // ← 前递后的访存基地址
        .addr_offset_i (fwd_addr_offset_o),
        .rd_addr_o     (ex_rd_addr_o),
        .rd_wen_o      (ex_rd_wen_o),
        .rd_data_o     (ex_rd_data_o),
        .jump_addr_o   (ex_jump_addr_o),
        .jump_en_o     (ex_jump_en_o),
        .mem_wd_reg_o  (ex_wd_reg_o),
        .mem_wd_addr_o (ex_wd_addr_o),
        .mem_wd_data_o (ex_wd_data_o),
        .mem_rd_addr_o (ex_rd_mem_addr_o),
        .is_load_o     (ex_is_load_o),
        .inst_o        (ex_inst_o)
    );
  
    // 7. 中央控制器 (CTRL)
    //    职责：检测跳转，输出 flush_flag_o 冲刷流水线
    ctrl ctrl_inst(
        .clk          (clk),
        .rst          (rst),
        .jump_addr_i  (ex_jump_addr_o),
        .jump_en_i    (ex_jump_en_o),
        .jump_en_o    (ctrl_jump_en_o),
        .jump_addr_o  (ctrl_jump_addr_o),
        .flush_flag_o (ctrl_flush_flag_o)  // → flush IF/ID 和 ID/EX
    );

    // 8. EX/MEM 流水线寄存器
    ex_mem1 ex_mem_inst(
        .clk           (clk),
        .rst           (rst),
        .hold_flag_i   (1'b0),        // EX/MEM 不需要 stall 或 flush
        .inst_i        (ex_inst_o),
        .rd_addr_i     (ex_rd_addr_o),
        .rd_data_i     (ex_rd_data_o),
        .rd_wen_i      (ex_rd_wen_o),
        .mem_wd_reg_i  (ex_wd_reg_o),
        .mem_wd_addr_i (ex_wd_addr_o),
        .mem_wd_data_i (ex_wd_data_o),
        .mem_rd_addr_i (ex_rd_mem_addr_o),
        .is_load_i     (ex_is_load_o), 
        .rd_addr_o     (ex_mem_pipe_rd_addr_o),
        .rd_data_o     (ex_mem_rd_data_o),
        .rd_wen_o      (ex_mem_rd_wen_o),
        .mem_wd_reg_o  (ex_mem_wd_reg_o), 
        .mem_wd_addr_o (ex_mem_wd_addr_o),
        .mem_wd_data_o (ex_mem_wd_data_o),
        .mem_rd_addr_o (ex_mem_mem_rd_addr_o),
        .is_load_o     (ex_mem_is_load_o),
        .inst_o        (ex_mem_inst_o) 
    );
    wire [31:0] mem_out_mem_rd_addr_o;
    wire mem_out_is_load_o;
    // 9. 访存模块 (MEM)
    mem1 mem_inst(
        .inst_i        (ex_mem_inst_o),
        .rd_addr_i     (ex_mem_pipe_rd_addr_o),  // 5-bit rd 地址
        .rd_data_i     (ex_mem_rd_data_o),
        .rd_wen_i      (ex_mem_rd_wen_o),
        //.mem_rd_data_i (ram_data_i),
        .mem_rd_addr_i (ex_mem_mem_rd_addr_o),
        .mem_wd_reg_i  (ex_mem_wd_reg_o),  
        .mem_wd_addr_i (ex_mem_wd_addr_o), 
        .mem_wd_data_i (ex_mem_wd_data_o), 
        .is_load_i     (ex_mem_is_load_o), 
        .rd_addr_o     (mem_out_rd_addr_o),
        .rd_data_o     (mem_out_rd_data_o),
        .rd_wen_o      (mem_out_rd_wen_o),
        .mem_rd_addr_o (mem_out_mem_rd_addr_o), 
        .mem_wd_reg_o  (w_en),
        .mem_wd_addr_o (w_addr_i),
        .mem_wd_data_o (w_data_i),
        .inst_o        (mem_inst_o),
        .is_load_o     (mem_out_is_load_o) 
    );
    wire mem1_mem2_rd_wen_o;
    wire[31:0] mem1_mem2_rd_data_o;
    wire [4:0] mem1_mem2_rd_addr_o;
    wire [31:0] mem1_mem2_inst_o;
    wire [31:0] mem1_mem2_mem_rd_addr_o;
    wire mem1_mem2_is_load_o;
    // 9.5 MEM1/MEM2 流水线寄存器
    mem1_mem2 mem1_mem2_inst(
        .clk           (clk),
        .rst           (rst),
        .hold_flag_i   (1'b0),        // MEM/MEM2 不需要 stall 或 flush
        .flush_flag_i  (1'b0),        // MEM/MEM2 不需要 stall 或 flush
        .inst_i        (mem_inst_o),
        .rd_addr_i     (mem_out_rd_addr_o),
        .rd_data_i     (mem_out_rd_data_o),
        .rd_wen_i      (mem_out_rd_wen_o),
        .mem_rd_addr_i (mem_out_mem_rd_addr_o),
        .is_load_i     (mem_out_is_load_o), 
        .rd_addr_o     (mem1_mem2_rd_addr_o),
        .rd_data_o     (mem1_mem2_rd_data_o),
        .rd_wen_o      (mem1_mem2_rd_wen_o), 
        .mem_rd_addr_o (mem1_mem2_mem_rd_addr_o), 
        .is_load_o     (mem1_mem2_is_load_o), 
        .inst_o        (mem1_mem2_inst_o)  
    );

    // 9.75 MEM2 模块（处理 Load 数据对齐和扩展）
    mem2 mem2_inst(
        .inst_i        (mem1_mem2_inst_o),
        .rd_addr_i     (mem1_mem2_rd_addr_o),
        .rd_data_i     (mem1_mem2_rd_data_o),
        .rd_wen_i      (mem1_mem2_rd_wen_o),
        .mem_rd_addr_i (mem1_mem2_mem_rd_addr_o),
        .is_load_i     (mem1_mem2_is_load_o), 
        .mem_rd_data_i (ram_data_i),      // 从外部 RAM 接入的数据 (CRITICAL FIX)
        .rd_addr_o     (mem2_rd_addr_o),
        .rd_data_o     (mem2_rd_data_o),
        .rd_wen_o      (mem2_rd_wen_o), 
        .inst_o        (mem2_inst_o)  
    );
    // 10. MEM/WB 流水线寄存器
    mem2_wb mem_wb_inst(
        .clk         (clk),
        .rst         (rst),
        .hold_flag_i (1'b0),          // MEM/WB 不需要 stall 或 flush
        .inst_i      (mem2_inst_o),       
        .rd_addr_i   (mem2_rd_addr_o),
        .rd_data_i   (mem2_rd_data_o),
        .rd_wen_i    (mem2_rd_wen_o),
        .rd_addr_o   (mem_wb_rd_addr_o), 
        .rd_data_o   (mem_wb_rd_data_o), 
        .rd_wen_o    (mem_wb_rd_wen_o),   
        .inst_o      (mem_wb_inst_o)
    );

    // 11. 写回模块 (WB)
    wb wb_inst(
        .inst_i      (mem_wb_inst_o),    
        .rd_addr_i   (mem_wb_rd_addr_o),
        .rd_data_i   (mem_wb_rd_data_o),
        .rd_wen_i    (mem_wb_rd_wen_o),
        .inst_o      (),                 // 悬空
        .rd_addr_o   (wb_rd_addr_o), 
        .rd_data_o   (wb_rd_data_o), 
        .rd_wen_o    (wb_rd_wen_o)  
    );

endmodule
