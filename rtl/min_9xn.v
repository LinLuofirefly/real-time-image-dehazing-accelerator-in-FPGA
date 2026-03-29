/*
 * @module   min_9x1
 * @brief    [核心] 9 输入最小值提取模块 (暗通道流水线阶段 3)
 * @details  本模块用于计算 3x3 图像窗口内的最小值 (即暗通道滤波)。
 *
 * [!! 关键流水线设计 !!]
 * 1. 本模块采用了 2 级流水线架构，以优化时序路径。
 * 2. 阶段 1 (计算 row_minX)：受输入信号 'win_en' 控制。
 * 3. 阶段 2 (计算 dc_data)：必须受 'win_en' 延迟 1 拍后的 'win_en_dly1' 控制。
 * 以此确保阶段 2 计算时，使用的是阶段 1 刚刚算出的最新行最小值。
 */
module min_9x1 (
    input  wire       clk,
    input  wire       rst_n,
    
    // --- 3x3 窗口像素输入 ---
    input  wire [7:0] win_p00, win_p01, win_p02, // 第 0 行
    input  wire [7:0] win_p10, win_p11, win_p12, // 第 1 行
    input  wire [7:0] win_p20, win_p21, win_p22, // 第 2 行
    
    input  wire       win_en,  // 窗口数据有效使能信号
    
    // --- 输出 ---
    output reg  [7:0] dc_data  // 最终的 3x3 窗口最小值 (暗通道值)
);

    // ============================================================
    // 内部寄存器定义
    // ============================================================
    // 阶段 1 的中间寄存器：存储每行的最小值
    reg [7:0] row_min0, row_min1, row_min2;
    
    // [!! 关键 !!] 阶段 2 的使能信号 (win_en 延迟 1 拍)
    reg       win_en_dly1;

    // ============================================================
    // 阶段 1: 计算每行的最小值 (Row Minimums)
    // ============================================================
    // 由输入的 win_en 信号直接控制
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {row_min0, row_min1, row_min2} <= 24'h0;
        end else if (win_en) begin
            // 调用组合逻辑函数 min3，并行计算 3 行的最小值
            row_min0 <= min3(win_p00, win_p01, win_p02);
            row_min1 <= min3(win_p10, win_p11, win_p12);
            row_min2 <= min3(win_p20, win_p21, win_p22);
        end
    end

    // ============================================================
    // [!! 关键 !!] 控制信号流水线对齐 (Delay Alignment)
    // ============================================================
    // 因为阶段 1 消耗了 1 个时钟周期，使其对应的使能信号也必须打一拍，
    // 从而保证数据流和控制流在时间上绝对同步。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_en_dly1 <= 1'b0;
        end else begin
            // [注意] 严格来说，如果外部有全局 clken，这里也应该受 clken 控制：
            // win_en_dly1 <= (clken) ? win_en : win_en_dly1;
            // 但为了简化或基于当前架构，这里直接将 win_en 延迟一拍。
            win_en_dly1 <= win_en; 
        end
    end

    // ============================================================
    // 阶段 2: 计算最终的最小值 (Final Minimum)
    // ============================================================
    // 由延迟对齐后的 [!! 关键 !!] win_en_dly1 信号控制
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dc_data <= 8'h0;
        end else if (win_en_dly1) begin // <-- 使用延迟后的使能信号
            // 此时 row_minX 寄存器里刚好是上一拍 (阶段1) 算出的有效数据
            dc_data <= min3(row_min0, row_min1, row_min2);
        end
    end

    // ============================================================
    // 组合逻辑函数: 3 输入求最小值 (Min3 Function)
    // ============================================================
    // 使用三目运算符构建的两级比较器。
    // 在综合时，会被展开为纯组合逻辑电路。
    function [7:0] min3;
        input [7:0] a, b, c;
        // 逻辑展开：先比较 a 和 b 选出较小者，再将较小者与 c 比较
        min3 = (a < b) ? ((a < c) ? a : c) : ((b < c) ? b : c);
    endfunction

endmodule