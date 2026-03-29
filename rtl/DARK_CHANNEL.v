module darkchanneltop #(
    // ============================================================
    // 模块参数定义 (Parameters)
    // ============================================================
    parameter IMG_WIDTH  = 640, // 图像宽度
    parameter IMG_HEIGHT = 451  // 图像高度
)(
    input  wire        clk,        // 系统时钟
    input  wire        rst_n,      // 异步复位，低电平有效
    input  wire        clken,      // 内部逻辑时钟使能 (受流控影响)
    input  wire        href,       // 行有效信号
    input  wire [23:0] pixel_data, // 24-bit 原始 RGB 输入
    output wire [7:0]  dc_data,    // 输出：最终的暗通道结果
    output reg         dc_valid    // 输出：暗通道结果有效信号
);

    // ============================================================
    // 1. 像素坐标计数器 (Pixel Coordinate Counters)
    // ============================================================
    // 用于跟踪当前输入的像素在图像中的具体坐标 (X, Y)
    reg [9:0] col_cnt, row_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin 
            col_cnt <= 0; 
            row_cnt <= 0; 
        end else if (clken && href) begin
            if (col_cnt == IMG_WIDTH - 1) begin
                col_cnt <= 0; // 一行结束，列计数器清零
                row_cnt <= (row_cnt == IMG_HEIGHT - 1) ? 0 : row_cnt + 1; // 行计数器累加
            end else begin
                col_cnt <= col_cnt + 1; // 列计数器累加
            end
        end else if (!href) begin
            col_cnt <= 0; // 行无效期间保持列为0
        end
    end

    // ============================================================
    // 2. 阶段 1: 预处理 (提取单像素RGB最小值)
    // ============================================================
    wire [7:0] dark_pre;
    // 实例化上一级模块：输出当前像素 R、G、B 中的最小值。耗时 1 个时钟周期。
    dark_channel_pre u_pre (
        .clk        (clk), 
        .rst_n      (rst_n), 
        .clken      (clken), 
        .href       (href),
        .pixel_data (pixel_data), 
        .dark_pre   (dark_pre)
    );

    // ============================================================
    // 2b. 阶段 1b: 坐标与控制信号对齐
    // ============================================================
    // 因为 u_pre 模块消耗了 1 个时钟周期，这里的 href 和坐标也必须打 1 拍，
    // 保证它们与 dark_pre 数据绝对对齐，然后再一起送入行缓存 (Line Buffer)。
    reg href_dly1;
    reg [9:0] col_dly1, row_dly1;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            href_dly1 <= 0; 
            col_dly1  <= 0; 
            row_dly1  <= 0;
        end else if (clken) begin
            href_dly1 <= href;
            col_dly1  <= col_cnt;
            row_dly1  <= row_cnt;
        end
    end

    // ============================================================
    // 3. 阶段 2: 3x3 缓存 (Line Buffer 生成滑动窗口)
    // ============================================================
    // 实例化行缓存模块，输出 3x3 的滑动窗口 (w00~w22)
    wire [7:0] w00, w01, w02, w10, w11, w12, w20, w21, w22;
    wire       buf_href; // 伴随 3x3 窗口输出的有效信号
    wire [9:0] buf_x;    // 当前窗口中心像素对应的 X 坐标
    wire [9:0] buf_y;    // 当前窗口中心像素对应的 Y 坐标

    line_buffer_3xN #(.IMG_WIDTH(IMG_WIDTH)) u_buf (
        .clk      (clk), 
        .rst_n    (rst_n), 
        .clken    (clken), 
        .href     (href_dly1),  // 延迟 1 拍的使能
        .dark_pre (dark_pre),   // 延迟 1 拍的预暗通道数据
        .col_cnt  (col_dly1), 
        .row_cnt  (row_dly1),
        
        // --- 窗口输出 ---
        .win_p00(w00), .win_p01(w01), .win_p02(w02),
        .win_p10(w10), .win_p11(w11), .win_p12(w12),
        .win_p20(w20), .win_p21(w21), .win_p22(w22),
        
        .out_href (buf_href),
        .out_x    (buf_x),
        .out_y    (buf_y)
    );

    // ============================================================
    // 4. 阶段 3: 边界填充逻辑 (Clamp-to-Edge Padding MUX)
    // ============================================================
    // 为了防止图像边缘的暗通道计算出现黑边或异常，这里采用了边缘像素复制策略。
    reg [7:0] p00, p01, p02, p10, p11, p12, p20, p21, p22;
    
    always @(*) begin
        // 默认将原始窗口数据赋给处理后的窗口变量 (Causal 逻辑)
        p10=w10; p11=w11; p12=w12;
        p00=w00; p01=w01; p02=w02;
        
        // --- 垂直边界填充 (Y 轴) ---
        if (buf_y == 0) begin       // 图像顶部第 0 行
            p10=w20; p11=w21; p12=w22; // 用最新的第2行覆盖第1行
            p00=w20; p01=w21; p02=w22; // 用最新的第2行覆盖第0行
        end else if (buf_y == 1) begin // 图像顶部第 1 行
            p00=w10; p01=w11; p02=w12; // 用第1行覆盖第0行
        end
        
        // p2 永远是最新进来的数据，不需要覆盖
        p20=w20; p21=w21; p22=w22;

        // --- 水平边界填充 (X 轴) ---
        if (buf_x == 0) begin       // 图像左侧第 0 列
            p01=p02; p11=p12; p21=p22; // 用右侧列覆盖中间列
            p00=p02; p10=p12; p20=p22; // 用右侧列覆盖左侧列
        end else if (buf_x == 1) begin // 图像左侧第 1 列
            p00=p01; p10=p11; p20=p21; // 用中间列覆盖左侧列
        end
        else if (buf_x == IMG_WIDTH - 1) begin // 图像最右侧列
            p02=p01; // 用中间列覆盖右侧列
            p12=p11; 
            p22=p21; 
        end
    end

    // ============================================================
    // 5. 阶段 4: 3x3 窗口最小值计算 (Dark Channel 最终提取)
    // ============================================================
    // 寻找 3x3 窗口内 9 个像素的最小值。该模块存在 2 个时钟周期的延迟。
    wire [7:0] min_result;
    min_9x1 u_min (
        .clk     (clk),
        .rst_n   (rst_n),
        .win_p00 (p00), .win_p01 (p01), .win_p02 (p02),
        .win_p10 (p10), .win_p11 (p11), .win_p12 (p12),
        .win_p20 (p20), .win_p21 (p21), .win_p22 (p22),
        .win_en  (buf_href), // 将 buffer 送出的有效信号输入供参考
        .dc_data (min_result)
    );

    // ============================================================
    // 6. 控制信号延迟对齐 (匹配 min_9x1 的处理延迟)
    // ============================================================
    // 因为 min_9x1 消耗了多个时钟周期，为了让输出的 valid 信号与结果数据完全对齐，
    // 需要对 buf_href 建立一个移位寄存器链 (Shift Register) 来打拍延迟。
    reg val_dly1; 
    reg val_dly2; 
    
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            val_dly1 <= 0;
            dc_valid <= 0;
            val_dly2 <= 0;
        end else if (clken) begin
            // 数据移位延迟，对齐最终的暗通道结果
            val_dly2 <= buf_href;   
            val_dly1 <= val_dly2; 
            dc_valid <= val_dly1;   
        end
    end
    
    // 最终输出：将计算结果连接到输出端口
    assign dc_data = min_result;

endmodule