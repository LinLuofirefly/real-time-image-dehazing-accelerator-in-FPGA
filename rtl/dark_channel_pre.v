/**
 * @module   dark_channel_pre
 * @brief    暗通道预处理模块 (流水线阶段 1)
 * @details  本模块是暗通道计算流水线的第一级。
 * 它的功能是接收一个 24-bit 的 RGB 像素数据，并实时提取
 * R, G, B 三个通道中的 *最小值*。
 * 这个最小值被称为"预暗通道值" (dark_pre)，并送入下一个排序或滤波模块。
 */
module dark_channel_pre (
    // ---------------- 系统信号 ----------------
    input  wire        clk,        // 系统时钟
    input  wire        rst_n,      // 异步复位，低电平有效
    
    // ---------------- 使能/同步信号 ----------------
    input  wire        clken,      // 内部逻辑的时钟使能 (高电平有效)
    input  wire        href,       // 行有效信号 (高电平表示当前输入的像素有效)
    
    // ---------------- 数据输入 ----------------
    input  wire [23:0] pixel_data, // 输入的 24-bit RGB 像素数据
                                   // (默认格式为 {R[7:0], G[7:0], B[7:0]})
    
    // ---------------- 数据输出 ----------------
    output reg  [7:0]  dark_pre    // 输出计算得到的 R,G,B 最小值 (8-bit)
);

    // --- 内部连线：从 24-bit 像素数据中提取 R, G, B 三个通道 ---

    // 提取 Red 通道 (高 8 位)
    wire [7:0] r = pixel_data[23:16];
    // 提取 Green 通道 (中间 8 位)
    wire [7:0] g = pixel_data[15:8];
    // 提取 Blue 通道 (低 8 位)
    wire [7:0] b = pixel_data[7:0];

    /**
     * @brief    计算 R, G, B 最小值的同步逻辑
     * @details  这是一个带异步复位的标准同步寄存器块。
     * - 当复位 (rst_n) 低电平时，输出清零。
     * - 当 clken (时钟使能) 和 href (行有效) 都有效时，
     * 在时钟上升沿计算 R, G, B 的最小值，并存入 dark_pre 寄存器。
     * - 如果 clken 或 href 无效 (例如处于消隐区或被流控暂停)，
     * dark_pre 寄存器保持上一个周期的值不变 (数据保持)。
     */
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dark_pre <= 8'h0; // 复位时输出清零
        end 
        else if (clken && href) begin // 关键控制：只有使能和行有效均有效时才进行计算和更新
            
            // 核心逻辑：使用嵌套的三目运算符 (Ternary Operator) 实现 min(R, G, B)
            // 综合器 (Synthesizer) 会将其优化为比较器 (Comparator) 和
            // 多路选择器 (Multiplexer / MUX) 组成的组合逻辑电路。
            
            // 逻辑拆解:
            // if (r < g) then
            //    // (r 是 r 和 g 中较小的)
            //    if (r < b) then dark_pre <= r; // r 最小
            //    else            dark_pre <= b; // b 最小
            // else // (r >= g)
            //    // (g 是 r 和 g 中较小或相等的)
            //    if (g < b) then dark_pre <= g; // g 最小
            //    else            dark_pre <= b; // b 最小
            
            dark_pre <= (r < g) ? ((r < b) ? r : b) : ((g < b) ? g : b);
        end
    end

endmodule