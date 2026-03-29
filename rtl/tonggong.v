module topn2_twopass #(
    // ============================================================
    // 模块参数定义 (Parameters)
    // ============================================================
    // --- 图像参数 ---
    parameter IMG_WIDTH         = 640,     // 图像宽度
    parameter IMG_HEIGHT        = 451,     // 图像高度
    parameter DATA_WIDTH        = 8,       // 颜色通道数据位宽
    
    // --- Airlight (分析) 参数 ---
    parameter MAX_TOP_N         = 2000,    // 提取暗通道前 N 个像素的最大值 (RAM 深度)
    parameter RGB_DELAY_CYCLES  = 5,       // RGB 信号与暗通道对齐的延迟周期
    
    // --- Dehaze (去雾处理) 参数 ---
    parameter SHIFT_BITS        = 7,       // 除法模拟乘法移位位数
    parameter CALC_WIDTH        = 16,      // 去雾计算的数据位宽 (Q1.15)
    parameter OMEGA_FIXED       = 16'h799A,// 去雾保留系数 Omega (0.95)
    parameter ONE_FIXED         = 16'h7FFF,// 1.0 的定点数表示
    parameter ZERO_FIXED        = 16'h0000,// 0.0 的定点数表示
    parameter ESTIMATOR_LATENCY = 47       // 透射率估计器的延时周期数
)(
    input  wire        clk,
    input  wire        rst_n,
    
    // --- 工作模式控制信号 (Core Control) ---
    // 0: 分析模式 (Pass 1) -> 仅计算全局大气光 A，挂起输出
    // 1: 处理模式 (Pass 2) -> 锁定大气光 A，执行去雾并输出清晰图像
    input  wire        i_mode, 
    
    // --- 视频流输入接口 (Video Input) ---
    input  wire        clken,      // 视频数据流使能控制
    input  wire        vsync,      // 场同步信号 (表示一帧的开始)
    input  wire        href,       // 行/数据有效信号
    input  wire [23:0] pixel_data, // 24-bit 原始输入像素 {R, G, B}
    
    // --- 状态与交互输出 (Status Output) ---
    output wire        o_busy,         // 流控信号：告诉外部数据源 "我忙不过来了，请暂停发送"
    output reg         o_param_ready,  // 握手信号：告诉外部 "全局大气光已算好，你可以切换到 Mode 1 发送第二遍数据了"
    
    // --- 视频流输出接口 (Video Output) ---
    output wire        valid_out,      // 输出去雾像素的有效信号
    output wire [23:0] pixel_data_out  // 输出去雾后的清晰像素 {R, G, B}
);

    // ============================================================
    // 1. 内部连线与寄存器声明
    // ============================================================
    // 分析模块输出的动态大气光结果
    wire [7:0] w_new_airlight_r;
    wire [7:0] w_new_airlight_g;
    wire [7:0] w_new_airlight_b;
    wire       w_airlight_valid; // 分析模块完成一帧计算的脉冲标志
    wire       w_analyzer_busy;  // 分析模块发出的流控忙信号

    // 大气光锁存寄存器 (跨 Pass 传递参数用)
    reg [7:0]  r_atm_r;
    reg [7:0]  r_atm_g;
    reg [7:0]  r_atm_b;

    // ============================================================
    // 2. 实例化 Airlight 分析模块 (Pass 1 Core)
    // ============================================================
    
    // 【流控路由】只有在 i_mode == 0 (分析模式) 时，外部才需要关心分析模块的 busy 信号；
    // 在处理模式下，分析模块的内部 FIFO 可能已经满了或混乱，但我们不再关心，直接屏蔽掉它的 busy，防止阻塞处理。
    assign o_busy = (i_mode == 1'b0) ? w_analyzer_busy : 1'b0;
    
    dark_airlight_top #(
        .IMG_WIDTH        (IMG_WIDTH),
        .IMG_HEIGHT       (IMG_HEIGHT),
        .DATA_WIDTH       (DATA_WIDTH),
        .MAX_TOP_N        (MAX_TOP_N),
        .RGB_DELAY_CYCLES (RGB_DELAY_CYCLES)
    ) u_analyzer (
        .clk          (clk),
        .rst_n        (rst_n),
        .clken        (clken),   // 分析模块始终运行接收数据
        .href         (href),
        .vsync        (vsync),
        .pixel_rgb    (pixel_data),
        
        .result_valid (w_airlight_valid),
        .airlight_r   (w_new_airlight_r),
        .airlight_g   (w_new_airlight_g),
        .airlight_b   (w_new_airlight_b),
        
        .o_busy       (w_analyzer_busy), // 导出其流控信号
        .top_n_ready  (),                // 内部信号，顶层无需关心
        .dc_data_out  ()                 // 内部测试信号，留空
    );

    // ============================================================
    // 3. 智能参数锁存与更新逻辑
    // ============================================================
    // 负责在 Pass 1 结束时，抓取大气光参数并保持到 Pass 2 结束。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 复位时设置默认大气光为纯白 (防止在未分析完成时误操作导致除 0 或黑屏)
            r_atm_r <= 8'd255; 
            r_atm_g <= 8'd255;
            r_atm_b <= 8'd255;
            o_param_ready <= 1'b0;
        end else begin
            // 更新条件：仅在 Mode 0 (分析模式) 下，且分析模块算完了 (valid 拉高)
            if (i_mode == 1'b0 && w_airlight_valid) begin
                r_atm_r <= w_new_airlight_r;
                r_atm_g <= w_new_airlight_g;
                r_atm_b <= w_new_airlight_b;
                o_param_ready <= 1'b1; // 举旗：参数算好了，通知外部控制系统
            end
            
            // 可选的清零逻辑：当在分析模式下遇到新的一帧起始 (vsync)，撤销 ready 信号
            // if (i_mode == 1'b0 && vsync) begin
            //    o_param_ready <= 1'b0; 
            // end
        end
    end

    // ============================================================
    // 4. 实例化 Dehaze 去雾处理模块 (Pass 2 Core)
    // ============================================================
    
    wire        w_dehaze_valid_raw;
    wire [23:0] w_dehaze_pixel_raw;

    dehaze_top #(
        .IMG_WIDTH         (IMG_WIDTH),
        .IMG_HEIGHT        (IMG_HEIGHT),
        .SHIFT_BITS        (SHIFT_BITS),
        .DATA_WIDTH        (CALC_WIDTH),
        .OMEGA_FIXED       (OMEGA_FIXED),
        .ONE_FIXED         (ONE_FIXED),
        .ZERO_FIXED        (ZERO_FIXED),
        .ESTIMATOR_LATENCY (ESTIMATOR_LATENCY)
    ) u_processor (
        .clk            (clk),
        .rst_n          (rst_n),
        .clken          (clken),
        
        // 传入由阶段 1 (Pass 1) 计算并锁存好的大气光 A
        .atm_r          (r_atm_r),
        .atm_g          (r_atm_g),
        .atm_b          (r_atm_b),
        
        .href_in        (href),
        .pixel_data_in  (pixel_data),
        
        // 去雾处理输出
        .valid_out      (w_dehaze_valid_raw),
        .pixel_data_out (w_dehaze_pixel_raw)
    );

    // ============================================================
    // 5. 输出安全门控 (Output Gating)
    // ============================================================
    // 安全机制：只允许在 Mode 1 (处理模式) 下向外输出有效数据。
    // 在 Mode 0 (分析模式) 下，外部可能正在高速灌入视频流算大气光，
    // 此时 u_processor 也会被动跟着瞎算。为了防止外部接收到这些错误/未去雾的图像，
    // 我们强制将 valid_out 截断为 0。
    
    assign valid_out      = (i_mode == 1'b1) ? w_dehaze_valid_raw : 1'b0;
    assign pixel_data_out = w_dehaze_pixel_raw;

endmodule