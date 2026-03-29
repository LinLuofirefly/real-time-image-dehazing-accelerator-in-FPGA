/*
 * 模块：raw_transmission_estimator (透射率估计器)
 *
 * 核心架构：复用用户提供的 8-bit 'top' 模块 (暗通道计算)
 * 流水线分为三个阶段：
 * 1. [mod1_scaler]  : 8-bit RGB -> 8-bit Scaled RGB (除以大气光 A)
 * 2. [mod2_dark]    : 8-bit Scaled RGB -> 8-bit Scaled DC (寻找缩放后的暗通道)
 * 3. [mod3_restore] : 8-bit Scaled DC -> 16-bit Q1.15 t(x) (解算最终透射率)
 */
module raw_transmission_estimator #(
    // ============================================================
    // 模块参数定义
    // ============================================================
    // --- 图像参数 ---
    parameter IMG_WIDTH     = 640,
    parameter IMG_HEIGHT    = 451,

    // --- 算法常量 (阶段 1: Scaler 使用) ---
    parameter SHIFT_BITS    = 7,

    // --- 算法常量 (阶段 3: Restore 使用) ---
    parameter DATA_WIDTH    = 16,       // 数据位宽 Q1.15
    parameter OMEGA_FIXED   = 16'h6CCD, // 去雾系数 0.85
    parameter ONE_FIXED     = 16'h7FFF, // 常数 1.0
    parameter ZERO_FIXED    = 16'h0000  // 常数 0.0
) (
    // ---------------- 系统与控制信号 ----------------
    input  wire                  clk,
    input  wire                  rst_n, // 异步复位，低电平有效
    input  wire                  clken, // 全局时钟使能 (流控)
    
    // 全局大气光输入
    input  wire [7:0]            atm_r, 
    input  wire [7:0]            atm_g,
    input  wire [7:0]            atm_b,
    
    // ---------------- 视频数据流输入 (8-bit RGB) ----------------
    input  wire                  href,       // 数据有效使能
    input  wire [23:0]           pixel_data, // 原始输入像素 {R[7:0], G[7:0], B[7:0]}
    
    // ---------------- 输出透射率数据 (16-bit Q1.15) ----------------
    output wire [DATA_WIDTH-1:0] t_out,      // 计算得到的透射率 t(x)
    output wire                  t_valid     // 透射率数据有效标志
);

    // ============================================================
    // 内部流水线互联信号 (Interconnect Signals)
    // ============================================================
    
    // 模块 1 -> 模块 2 的连接线
    wire [23:0] scaled_pixel_data; // 缩放并截断后的像素 {r, g, b}
    wire        mod1_valid_out;    // 模块 1 的数据有效标志
    wire        mod1_href_out;     // 延迟对齐后的行有效信号

    // 模块 2 -> 模块 3 的连接线
    wire [7:0]  scaled_dc_out;     // 提取出的缩放暗通道值
    wire        mod2_valid_out;    // 模块 2 的数据有效标志
    
    // ============================================================
    // 模块 1: 整数缩放器 (8bit -> 8bit, 饱和裁剪)
    // ============================================================
    // 负责计算 I(x) / A 的近似值
    integer_scaler #(
        .SHIFT_BITS(SHIFT_BITS)
    ) mod1_scaler (
        .clk                   (clk), 
        .rst_n                 (rst_n), 
        .clken                 (clken),
        
        .href_in               (href),
        .pixel_data_in         (pixel_data),
        .A_r                   (atm_r),
        .A_g                   (atm_g),
        .A_b                   (atm_b),
        
        .scaled_pixel_data_out (scaled_pixel_data),
        .href_out              (mod1_href_out),  // 延迟对齐后的 href，传给后级
        .valid_out             (mod1_valid_out)
    );

    // ============================================================
    // 模块 2: 暗通道提取器 (调用精简版的 8-bit 'top' 模块)
    // ============================================================
    // 在缩放后的像素矩阵中寻找 3x3 窗口的最小值
    top #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT)
    ) mod2_dark (
        .clk        (clk), 
        .rst_n      (rst_n), 
        .clken      (clken),             // clken 控制整个内部流水线的挂起/恢复
        
        .href       (mod1_href_out),     // 严格使用来自 mod1 延迟对齐后的 href
        .pixel_data (scaled_pixel_data), // 接收 mod1 缩放后的像素数据
        
        .dc_data    (scaled_dc_out),     // 输出暗通道结果
        .dc_valid   (mod2_valid_out)     // 输出伴随的有效信号
    );
    
    // ============================================================
    // 模块 3: 透射率还原与计算 (8bit -> Q1.15)
    // ============================================================
    // 负责计算最终公式 t(x) = 1 - w * DC
    restore_and_calc_t #(
        .DATA_WIDTH  (DATA_WIDTH),
        .OMEGA_FIXED (OMEGA_FIXED),
        .ONE_FIXED   (ONE_FIXED),
        .ZERO_FIXED  (ZERO_FIXED)
    ) mod3_restore (
        .clk          (clk), 
        .rst_n        (rst_n), 
        .clken        (clken),
        
        .scaled_dc_in (scaled_dc_out),   // 接收来自 mod2 的 8-bit 暗通道结果
        .valid_in     (mod2_valid_out),  // 接收来自 mod2 的有效信号
        
        .t_out        (t_out),           // 最终输出：Q1.15 格式的透射率
        .t_valid      (t_valid)          // 最终输出：有效信号
    );

endmodule