module fifo_sync #(
    // ============================================================
    // 模块参数定义 (Parameters)
    // ============================================================
    parameter DEPTH = 640,  // FIFO 深度 (例如：等于图像的一行像素数)
    parameter WIDTH = 8     // 数据位宽 (8-bit 对应单个颜色通道或灰度值)
)(
    input  wire             clk,
    input  wire             rst_n,      // 异步复位，低电平有效
    
    input  wire             wr_en,      // 写使能
    input  wire             rd_en,      // 读使能 (在行缓存应用中，rd_en 通常跟随 wr_en)
    input  wire [WIDTH-1:0] din,        // 写入的数据
    
    output reg  [WIDTH-1:0] dout,       // 读出的数据
    output wire             empty,      // 空标志
    output wire             full        // 满标志
);

    // ============================================================
    // 内部寄存器定义 (Internal Registers)
    // ============================================================
    
    // 存储器阵列 (RAM)
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    // 读写指针
    // 自动计算位宽：$clog2(640) = 10，所以位宽为 [9:0]
    reg [$clog2(DEPTH)-1:0] wr_ptr;
    reg [$clog2(DEPTH)-1:0] rd_ptr;

    // 元素计数器
    // 需要能表示 0 到 DEPTH (即包含 0 到 640 共 641 个状态)
    // 自动计算位宽：$clog2(640+1) = 10，所以位宽为 [9:0]
    reg [$clog2(DEPTH+1)-1:0] cnt;

    // ============================================================
    // 状态标志输出 (Status Flags)
    // ============================================================
    assign empty = (cnt == 0);
    assign full  = (cnt == DEPTH);

    // ============================================================
    // 核心 FIFO 读写逻辑 (带时序控制)
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 异步复位：清空指针、计数器和输出数据
            wr_ptr <= 0;
            rd_ptr <= 0;
            cnt    <= 0;
            dout   <= 0;
        end else begin
            
            // [!! 关键逻辑 !!]
            // 将原先的并行 'if' 更改为 'if-else if' 结构。
            // 这样能严格划分出 4 种互斥的读写组合，防止逻辑冲突。
            
            // --- Case 1: 同时读写 (行缓存中最主要的模式) ---
            // 条件：(要求写且未满) 且 (要求读且未空)
            if (wr_en && !full && rd_en && !empty) begin
                // 1. 写操作
                mem[wr_ptr] <= din;
                wr_ptr      <= (wr_ptr == DEPTH - 1) ? 0 : wr_ptr + 1'b1;
                
                // 2. 读操作
                dout        <= mem[rd_ptr];
                rd_ptr      <= (rd_ptr == DEPTH - 1) ? 0 : rd_ptr + 1'b1;
                
                // 3. 计数器更新 (写入一个同时读出一个，总数保持不变)
                cnt         <= cnt;
            end
            
            // --- Case 2: 仅写操作 ---
            // 条件：(要求写且未满)
            else if (wr_en && !full) begin
                // 1. 写操作
                mem[wr_ptr] <= din;
                wr_ptr      <= (wr_ptr == DEPTH - 1) ? 0 : wr_ptr + 1'b1;
                
                // 2. 计数器更新 (数量 + 1)
                cnt         <= cnt + 1'b1;
                
                // (读指针 rd_ptr 和 输出 dout 保持不变)
            end
            
            // --- Case 3: 仅读操作 ---
            // 条件：(要求读且未空)
            else if (rd_en && !empty) begin
                // 1. 读操作
                dout        <= mem[rd_ptr];
                rd_ptr      <= (rd_ptr == DEPTH - 1) ? 0 : rd_ptr + 1'b1;
                
                // 2. 计数器更新 (数量 - 1)
                cnt         <= cnt - 1'b1;
                
                // (写指针 wr_ptr 保持不变)
            end
            
            // --- Case 4: 无操作 (空闲状态) ---
            // 条件：(未触发读写，或者因为满/空导致读写无效)
            else begin
                // 所有寄存器 (wr_ptr, rd_ptr, cnt, dout) 自动保持当前值不变
            end
            
        end
    end

endmodule