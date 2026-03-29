module top #(
    // ============================================================
    // 模块参数定义
    // ============================================================
    parameter IMG_WIDTH  = 640, // 图像宽度
    parameter IMG_HEIGHT = 451  // 图像高度
)(
    input  wire        clk,
    input  wire        rst_n,      // 异步复位，低电平有效
    input  wire        clken,      // 全局时钟使能 (流控)
    input  wire        href,       // 行有效信号
    input  wire [23:0] pixel_data, // 24-bit RGB 输入像素数据
    output wire [7:0]  dc_data,    // 输出的暗通道数据
    output reg         dc_valid    // 输出的数据有效信号
);

    // ============================================================
    // 1. 像素坐标计数器 (Pixel Coordinate Counters)
    // ============================================================
    reg [9:0] col_cnt, row_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin 
            col_cnt <= 0; 
            row_cnt <= 0; 
        end else if (clken && href) begin
            if (col_cnt == IMG_WIDTH - 1) begin
                col_cnt <= 0; // 一行结束，列清零
                row_cnt <= (row_cnt == IMG_HEIGHT - 1) ? 0 : row_cnt + 1; // 行累加
            end else begin
                col_cnt <= col_cnt + 1;
            end
        end else if (!href) begin
            col_cnt <= 0; // href 无效期间，列计数器保持为 0
        end
    end

    // ============================================================
    // 2. 阶段 1: 预处理 (dark_pre 消耗 1 拍延迟)
    // ============================================================
    wire [7:0] dark_pre;
    dark_channel_pre u_pre (
        .clk        (clk), 
        .rst_n      (rst_n), 
        .clken      (clken), 
        .href       (href),
        .pixel_data (pixel_data), 
        .dark_pre   (dark_pre)
    );

    // ============================================================
    // 2b. 控制信号对齐 (延迟 1 拍以匹配 dark_pre)
    // ============================================================
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
    // 3. 阶段 2: 行缓存 Line Buffer (生成 3x3 窗口)
    // ============================================================
    // 此处的输入已经是延迟 1 拍的数据了。
    // u_buf 内部由于输出寄存器打拍，会再产生 1 拍延迟。
    // 所以这里的输出窗口相对最原始的输入，总延迟 = 1 (pre) + 1 (buffer) = 2 拍
    wire [7:0] w00, w01, w02, w10, w11, w12, w20, w21, w22;
    wire       buf_href; // 伴随窗口输出的 href (相对原始输入延迟 2 拍)
    wire [9:0] buf_x;    // 窗口中心对应的 X 坐标 (相对原始输入延迟 2 拍)
    wire [9:0] buf_y;    // 窗口中心对应的 Y 坐标 (相对原始输入延迟 2 拍)

    line_buffer_3xN #(.IMG_WIDTH(IMG_WIDTH)) u_buf (
        .clk      (clk), 
        .rst_n    (rst_n), 
        .clken    (clken), 
        .href     (href_dly1),  // 送入延迟 1 拍的控制信号
        .dark_pre (dark_pre),   // 送入延迟 1 拍的数据
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
    // 4. 阶段 3: 边缘填充逻辑 (Padding MUX)
    // ============================================================
    // 利用 line_buffer 提供的中心坐标 (buf_x, buf_y) 进行边界判断。
    // 注：此版本为 Causal (因果) 填充，未处理右边界 (buf_x == IMG_WIDTH-1)。
    reg [7:0] p00, p01, p02, p10, p11, p12, p20, p21, p22;
    
    always @(*) begin
        // --- 默认传递 (Causal) ---
        // 默认 p1=w1, p0=w0
        p10=w10; p11=w11; p12=w12;
        p00=w00; p01=w01; p02=w02;
        
        // --- 垂直填充 (Y轴) ---
        if (buf_y == 0) begin       // 第 0 行 (仅 w2x 是刚进来的有效数据)
            p10=w20; p11=w21; p12=w22; // 用最新的 w2 覆盖 p1
            p00=w20; p01=w21; p02=w22; // 用最新的 w2 覆盖 p0
        end else if (buf_y == 1) begin // 第 1 行 (w2x, w1x 有效)
            p00=w10; p01=w11; p02=w12; // 用 w1 覆盖 p0
        end
        
        // p2 始终是当前行最新数据，无需覆盖
        p20=w20; p21=w21; p22=w22;

        // --- 水平填充 (X轴) ---
        if (buf_x == 0) begin       // 第 0 列 (仅 wX2 是刚进来的有效数据)
            p01=p02; p11=p12; p21=p22; // 用 wX2 覆盖 pX1
            p00=p02; p10=p12; p20=p22; // 用 wX2 覆盖 pX0
        end else if (buf_x == 1) begin // 第 1 列 (wX2, wX1 有效)
            p00=p01; p10=p11; p20=p21; // 用刚刚处理好的 pX1 覆盖 pX0
        end
    end

    // ============================================================
    // 5. 阶段 4: 求 3x3 最小值 (min_9x1 消耗 2 拍延迟)
    // ============================================================
    wire [7:0] min_result;
    min_9x1 u_min (
        .clk     (clk),
        .rst_n   (rst_n),
        .win_p00 (p00), .win_p01 (p01), .win_p02 (p02),
        .win_p10 (p10), .win_p11 (p11), .win_p12 (p12),
        .win_p20 (p20), .win_p21 (p21), .win_p22 (p22),
        .win_en  (buf_href), // 使用缓冲器对齐后的有效信号
        .dc_data (min_result)
    );

    // ============================================================
    // 6. 最终输出延迟对齐
    // ============================================================
    // buf_href 相对系统输入延迟了 2 拍
    // min_result 内部计算又消耗了 2 拍
    // 所以我们需要将 buf_href 再打 2 拍，才能作为最终 dc_valid 输出。
    reg val_dly1;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            val_dly1 <= 0;
            dc_valid <= 0;
        end else if (clken) begin
            val_dly1 <= buf_href;   // 第 1 拍延迟 (对应 min 模块流水线第 1 级)
            dc_valid <= val_dly1;   // 第 2 拍延迟 (对应 min 模块流水线第 2 级，最终有效输出)
        end
    end
    
    // 连接最终求得的暗通道数据
    assign dc_data = min_result;

endmodule