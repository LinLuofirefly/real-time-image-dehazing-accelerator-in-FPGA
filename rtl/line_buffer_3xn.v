module line_buffer_3xN #(
    // ============================================================
    // 模块参数定义
    // ============================================================
    parameter IMG_WIDTH = 640 // 图像宽度，决定了内部 FIFO 的深度
)(
    input  wire       clk,
    input  wire       rst_n,      // 异步复位，低电平有效
    input  wire       clken,      // 全局时钟使能 (流控)
    
    // --- 输入视频流 ---
    input  wire       href,       // 行有效信号
    input  wire [7:0] dark_pre,   // 当前输入的预暗通道像素值
    input  wire [9:0] col_cnt,    // 当前像素的 X 坐标
    input  wire [9:0] row_cnt,    // 当前像素的 Y 坐标

    // --- 3x3 滑动窗口输出 (并行) ---
    // p[y][x] 格式：p00 代表左上角，p11 代表中心，p22 代表右下角 (最新输入)
    output reg  [7:0] win_p00, win_p01, win_p02, 
    output reg  [7:0] win_p10, win_p11, win_p12, 
    output reg  [7:0] win_p20, win_p21, win_p22, 

    // --- 同步控制信号输出 ---
    // 与窗口中心像素 (win_p11) 对齐的控制信号
    output reg        out_href,   // 输出行有效信号 (总延迟 2 拍)
    output reg  [9:0] out_x,      // 输出 X 坐标 (总延迟 2 拍)
    output reg  [9:0] out_y       // 输出 Y 坐标 (总延迟 2 拍)
);

    // ============================================================
    // 1. 行缓存 FIFO (Line Buffers)
    // ============================================================
    wire [7:0] f0_data, f1_data;
    
    // 写使能：只要数据有效就写入
    wire fifo_wr_en  = clken && href; 
    
    // 读使能保护机制：
    // 第 0 行时，FIFO 内无数据，禁止读取，防止读空报错；
    // 第 1 行及以后，允许读取 FIFO 0；第 2 行及以后，允许读取 FIFO 1。
    wire fifo0_rd_en = clken && href && (row_cnt > 0);
    wire fifo1_rd_en = clken && href && (row_cnt > 1);
    
    // 实例化两个深度为图像宽度的同步 FIFO
    // fifo0 缓存上一行 (Row-1) 的数据
    fifo_sync #(.DEPTH(IMG_WIDTH)) fifo0 (
        .clk(clk), .rst_n(rst_n), .wr_en(fifo_wr_en), .rd_en(fifo0_rd_en),
        .din(dark_pre), .dout(f0_data), .empty(), .full()
    );
    
    // fifo1 缓存上上行 (Row-2) 的数据
    fifo_sync #(.DEPTH(IMG_WIDTH)) fifo1 (
        .clk(clk), .rst_n(rst_n), .wr_en(fifo_wr_en), .rd_en(fifo1_rd_en),
        .din(f0_data), .dout(f1_data), .empty(), .full()
    );

    // ============================================================
    // 2. 水平移位寄存器 (Horizontal Shift Registers)
    // ============================================================
    // 用于在同一行内缓存前两个像素
    reg [7:0] r2_c1, r2_c0; // 对应当前行 (Row 2) 的延迟像素
    reg [7:0] r1_c1, r1_c0; // 对应上一行 (Row 1) 的延迟像素
    reg [7:0] r0_c1, r0_c0; // 对应上上行 (Row 0) 的延迟像素

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {r2_c1, r2_c0, r1_c1, r1_c0, r0_c1, r0_c0} <= 48'h0;
        end else if (clken && href) begin
            // 第 1 级打拍 (延迟 1 个周期)
            r2_c1 <= dark_pre; // 当前行最新数据
            r1_c1 <= f0_data;  // 上一行最新数据
            r0_c1 <= f1_data;  // 上上行最新数据
            
            // 第 2 级打拍 (延迟 2 个周期)
            r2_c0 <= r2_c1;    
            r1_c0 <= r1_c1;   
            r0_c0 <= r0_c1;
        end
    end

    // ============================================================
    // 3. 组装 3x3 窗口 (Window Output Registers)
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            {win_p00, win_p01, win_p02} <= 24'h0;
            {win_p10, win_p11, win_p12} <= 24'h0;
            {win_p20, win_p21, win_p22} <= 24'h0;
        end else if (clken) begin
            // 注意：为了改善时序，这里将组合好的窗口数据统一打入输出寄存器。
            // 这使得窗口输出整体有了 1 拍的硬延迟。
            
            // Col 2: 最新输入的一列 (数据延迟 = 1拍)
            win_p02 <= f1_data; 
            win_p12 <= f0_data; 
            win_p22 <= dark_pre;
            
            // Col 1: 窗口的中心列 (数据延迟 = 2拍)
            win_p01 <= r0_c1;   
            win_p11 <= r1_c1;   
            win_p21 <= r2_c1;
            
            // Col 0: 窗口的最左侧列 (数据延迟 = 3拍)
            win_p00 <= r0_c0;   
            win_p10 <= r1_c0;   
            win_p20 <= r2_c0;
        end
    end

    // ============================================================
    // 4. 控制信号同步 (Delay Alignment)
    // ============================================================
    // 【核心修正】：因为上述窗口的 Col 1 (中心列) 经历了 2 拍延迟：
    // (输入 -> 移位寄存器rx_c1 -> 窗口寄存器win_px1)。
    // 为了让坐标和 href 严格对齐到 3x3 窗口的中心，控制信号必须严格打两拍！
    
    reg       href_dly1;  // 第一级延迟寄存器
    reg [9:0] x_dly1, y_dly1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_href  <= 0;
            href_dly1 <= 0;
            out_x     <= 0;
            out_y     <= 0;
        end else if (clken) begin
            // 第 1 拍
            href_dly1 <= href;   
            x_dly1    <= col_cnt;
            y_dly1    <= row_cnt;
            
            // 第 2 拍 (最终输出，完美对齐 win_px1)
            out_href  <= href_dly1; 
            out_x     <= x_dly1;
            out_y     <= y_dly1;
        end
    end

endmodule