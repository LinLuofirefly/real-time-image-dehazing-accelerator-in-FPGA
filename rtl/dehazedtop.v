module dehaze_top #(
    // ============================================================
    // 模块参数定义 (Parameters)
    // ============================================================
    // --- 图像参数 ---
    parameter IMG_WIDTH     = 640,      // 图像宽度
    parameter IMG_HEIGHT    = 451,      // 图像高度
    
    // --- 算法参数 (定点数配置) ---
    parameter SHIFT_BITS    = 7,        // 移位位数，用于定点数乘除法中的截断或缩放
    parameter DATA_WIDTH    = 16,       // 数据位宽，采用 Q1.15 格式 (1位符号位, 15位小数位)
    parameter OMEGA_FIXED   = 16'h6CCD, // 去雾保留系数 Omega，通常设为 0.95 (这里0.85的Q1.15定点数为 16'h6CCD)
    parameter ONE_FIXED     = 16'h7FFF, // 常数 1.0 的 Q1.15 定点数表示
    parameter ZERO_FIXED    = 16'h0000, // 常数 0.0 的 Q1.15 定点数表示
    
    // --- 关键参数：延时对齐参数 ---
    // 由于透射率估计模块 (Estimator) 需要一定时钟周期来计算，
    // 原始 RGB 像素必须经过同样周期的延迟，才能与计算出的透射率对齐。
    parameter ESTIMATOR_LATENCY = 47    // 透射率估计模块的流水线总延迟周期数
)(
    // ============================================================
    // 端口定义 (Ports)
    // ============================================================
    input          clk,           // 系统时钟
    input          rst_n,         // 全局异步复位，低电平有效
    
    // 全局控制
    input          clken,         // 系统时钟使能信号 (流控信号)
    
    // 大气光输入接口 (Airlight Input)
    // 采用标准的 8-bit 接口，方便对接外部总线控制或前级的 Airlight 计算模块
    input  [7:0]   atm_r,         // 全局大气光 R 分量
    input  [7:0]   atm_g,         // 全局大气光 G 分量
    input  [7:0]   atm_b,         // 全局大气光 B 分量
    
    // 视频输入流 (Video Input Stream)
    input          href_in,       // 输入行有效信号 (或数据有效信号)
    input  [23:0]  pixel_data_in, // 24-bit 输入原始像素数据 {R[7:0], G[7:0], B[7:0]}
    
    // 视频输出流 (Video Output Stream)
    output         valid_out,     // 最终去雾后的数据有效信号
    output [23:0]  pixel_data_out // 24-bit 去雾恢复后的像素数据 {R, G, B}
);

    // ============================================================
    // 转换层：8-bit 无符号数 (Unsigned) -> 9-bit 有符号数 (Signed)
    // ============================================================
    // 目的：恢复模块 (Recovery) 内部涉及减法运算 (I(x) - A)，
    // 为了防止溢出并保持符号计算正确，这里将 8位 的无符号大气光值，
    // 通过在最高位补 '0' 的方式，转换为 9位 的正数有符号数。
    wire signed [8:0] atm_r_s = {1'b0, atm_r};
    wire signed [8:0] atm_g_s = {1'b0, atm_g};
    wire signed [8:0] atm_b_s = {1'b0, atm_b};

    // ============================================================
    // 1. 实例化：透射率估计模块 (Raw Transmission Estimator)
    // ============================================================
    // 该模块负责根据输入图像和大气光，估算当前像素的透射率 t(x)
    wire [15:0] t_est_out;   // 估计出的透射率输出 (Q1.15 格式)
    wire        t_est_valid; // 透射率数据有效标志
    
    raw_transmission_estimator #(
        .IMG_WIDTH   (IMG_WIDTH),
        .IMG_HEIGHT  (IMG_HEIGHT),
        .SHIFT_BITS  (SHIFT_BITS),
        .DATA_WIDTH  (DATA_WIDTH),
        .OMEGA_FIXED (OMEGA_FIXED),
        .ONE_FIXED   (ONE_FIXED),
        .ZERO_FIXED  (ZERO_FIXED)
    ) u_estimator (
        .clk        (clk),
        .rst_n      (rst_n),
        .clken      (clken),
        .atm_r      (atm_r),         // 传入原始 8-bit 大气光值
        .atm_g      (atm_g),
        .atm_b      (atm_b),
        .href       (href_in),
        .pixel_data (pixel_data_in), // 传入原始图像流
        .t_out      (t_est_out),     // 输出透射率
        .t_valid    (t_est_valid)    // 输出透射率有效信号
    );

    // ============================================================
    // 2. 数据对齐延时线 (Delay Line / Shift Register)
    // ============================================================
    // 目的：打拍延迟原始的 RGB 像素，使其与经历过漫长计算的透射率 t(x) 汇合时，
    // 恰好是同一个像素的对应数据。
    reg [23:0] rgb_delay_pipeline [0:ESTIMATOR_LATENCY-1]; // 定义深度为 latency 的寄存器数组
    integer i;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 复位时清空所有移位寄存器
            for (i=0; i<ESTIMATOR_LATENCY; i=i+1) begin
                rgb_delay_pipeline[i] <= 24'd0;
            end
        end else if (clken) begin
            // 第一拍：存入当前最新的输入像素
            rgb_delay_pipeline[0] <= pixel_data_in;
            // 剩下的拍数：逐级向后传递 (流水线移位)
            for (i=1; i<ESTIMATOR_LATENCY; i=i+1) begin
                rgb_delay_pipeline[i] <= rgb_delay_pipeline[i-1];
            end
        end
    end
    
    // 取出延时线最后一级的数据，作为对齐后的原始 RGB 数据
    wire [7:0] delayed_r = rgb_delay_pipeline[ESTIMATOR_LATENCY-1][23:16];
    wire [7:0] delayed_g = rgb_delay_pipeline[ESTIMATOR_LATENCY-1][15:8];
    wire [7:0] delayed_b = rgb_delay_pipeline[ESTIMATOR_LATENCY-1][7:0];

    // ============================================================
    // 3. 实例化：去雾恢复模块 (Dehaze Recovery)
    // ============================================================
    // 基于大气散射模型：J(x) = (I(x) - A) / t(x) + A
    // 将对齐后的原始像素、透射率和大气光进行最终的代数运算，还原无雾图像。
    
    wire [7:0] rec_r, rec_g, rec_b; // 恢复后的 RGB 分量
    wire       rec_valid;           // 恢复结果有效信号
    
    dehaze_recovery u_recovery (
        .clk     (clk),
        .rst_n   (rst_n),
        
        .i_valid (t_est_valid), // 核心触发：依赖透射率计算模块送来的 Valid 信号
        .i_r     (delayed_r),   // 接入对齐后的原始 R 通道
        .i_g     (delayed_g),   // 接入对齐后的原始 G 通道
        .i_b     (delayed_b),   // 接入对齐后的原始 B 通道
        .i_t     (t_est_out),   // 接入计算好的透射率
        
        // 传入上方转换好的 9-bit Signed 大气光，防止减法溢出
        .atm_r   (atm_r_s),
        .atm_g   (atm_g_s),
        .atm_b   (atm_b_s),
        
        .o_valid (rec_valid),   // 输出有效信号
        .o_r     (rec_r),       // 输出去雾后的 R 通道
        .o_g     (rec_g),       // 输出去雾后的 G 通道
        .o_b     (rec_b)        // 输出去雾后的 B 通道
    );

    // ============================================================
    // 4. 顶层输出赋值 (Output Assignment)
    // ============================================================
    // 将底层恢复模块的计算结果映射到顶层的输出端口
    assign valid_out      = rec_valid;
    assign pixel_data_out = {rec_r, rec_g, rec_b};

endmodule