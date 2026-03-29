module dark_airlight_top #(
    // ============================================================
    // 模块参数定义 (Parameters)
    // ============================================================
    parameter IMG_WIDTH        = 640,  // 图像宽度（像素个数）
    parameter IMG_HEIGHT       = 451,  // 图像高度（像素个数）
    parameter DATA_WIDTH       = 8,    // 颜色数据位宽（通常为8位，即0-255）
    parameter MAX_TOP_N        = 2000, // 提取暗通道最亮的前N个像素的最大数量
    parameter RGB_DELAY_CYCLES = 5     // RGB数据延迟周期数，用于与暗通道计算的流水线延迟对齐
)(
    // ============================================================
    // 输入输出端口定义 (Ports)
    // ============================================================
    // 全局时钟与复位
    input  wire                  clk,          // 系统时钟
    input  wire                  rst_n,        // 全局异步复位，低电平有效

    // 图像输入接口 (Video Input)
    input  wire                  clken,        // 外部时钟使能信号（数据输入使能）
    input  wire                  href,         // 行有效信号 (Horizontal Reference)
    input  wire                  vsync,        // 场同步信号 (Vertical Sync)，通常高电平表示一帧开始
    input  wire [23:0]           pixel_rgb,    // 24位输入像素数据 (8位R + 8位G + 8位B)

    // 大气光计算结果输出接口 (Airlight Output)
    output wire                  result_valid, // 大气光计算结果有效标志
    output wire [DATA_WIDTH-1:0] airlight_r,   // 计算得到的大气光 R 分量
    output wire [DATA_WIDTH-1:0] airlight_g,   // 计算得到的大气光 G 分量
    output wire [DATA_WIDTH-1:0] airlight_b,   // 计算得到的大气光 B 分量

    // 状态与控制输出接口 (Control & Status)
    output wire                  o_busy,       // 【流控信号】输出忙信号，高电平通知前级暂停发送数据
    output wire                  top_n_ready,  // 后级Airlight模块准备好接收数据的标志
    output wire [7:0]            dc_data_out   // 输出当前的暗通道计算结果（供观测或调试）
);

    // 计算图像的总像素数，用于判断一帧数据是否处理完毕
    localparam [31:0] TOTAL_PIXELS = IMG_WIDTH * IMG_HEIGHT;

    // ============================================================
    // 0. 流控逻辑 (Backpressure Logic)
    // ============================================================
    wire fifo_full;       // FIFO 满标志
    wire fifo_prog_full;  // FIFO 将满标志 (Programmable Full)
    
    // 【流控核心】只要 FIFO 快满了，或者真满了，就对外输出高电平报忙，要求前级停发
    assign o_busy = fifo_prog_full || fifo_full;

    // 【内部时钟使能控制】
    // 只有当外部允许发送数据 (clken=1) 且 内部FIFO不满 (!o_busy) 时，内部流水线才继续运行。
    // 如果 o_busy=1，core_clken 变为 0，暗通道计算模块和RGB移位寄存器全部冻结，防止数据丢失。
    wire core_clken = clken && !o_busy;

    // ============================================================
    // 1. 暗通道计算模块 (Dark Channel Calculation)
    // ============================================================
    wire [7:0] dc_result; // 暗通道计算模块输出的暗通道值
    wire       dc_valid;  // 暗通道计算模块输出的有效标志
    
    // 实例化暗通道顶层模块
    darkchanneltop #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT)
    ) u_dark_channel (
        .clk        (clk),
        .rst_n      (rst_n),
        .clken      (core_clken), // 使用受流控限制的使能信号
        .href       (href),
        .pixel_data (pixel_rgb),  // 原始RGB输入
        .dc_data    (dc_result),  // 计算得出的暗通道结果
        .dc_valid   (dc_valid)    // 结果有效信号
    );
    
    // 将内部暗通道结果直接分配给输出端口
    assign dc_data_out = dc_result;

    // ============================================================
    // 2. RGB 对齐移位寄存器 (RGB Alignment Shift Register)
    // ============================================================
    // 目的：因为计算暗通道需要消耗一定时钟周期 (RGB_DELAY_CYCLES)，
    // 我们必须把原始RGB像素也打拍延迟同样的周期，这样输出时暗通道值和RGB值才能对齐。
    reg [23:0] rgb_pipe [0 : RGB_DELAY_CYCLES-1]; // 定义深度为延迟周期数的二维寄存器组
    integer i; // for 循环迭代变量

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 复位时清空所有寄存器
            for (i=0; i<RGB_DELAY_CYCLES; i=i+1) rgb_pipe[i] <= 0;
        end else if (core_clken) begin 
            // 仅在内部使能有效时才移位，冻结时数据保持不变，防止被覆盖
            rgb_pipe[0] <= pixel_rgb; // 第0级存入最新输入的RGB像素
            for (i=1; i<RGB_DELAY_CYCLES; i=i+1) begin
                rgb_pipe[i] <= rgb_pipe[i-1]; // 依次向下级移位
            end
        end
    end

    // 提取延迟对齐后的 RGB 数据
    wire [23:0] rgb_aligned = rgb_pipe[RGB_DELAY_CYCLES-1]; // 取出流水线最后一级
    wire [7:0]  r_dly = rgb_aligned[23:16];                 // 截取红色分量
    wire [7:0]  g_dly = rgb_aligned[15:8];                  // 截取绿色分量
    wire [7:0]  b_dly = rgb_aligned[7:0];                   // 截取蓝色分量

    // ============================================================
    // 3. FIFO 缓冲桥 (FIFO Buffer Bridge)
    // ============================================================
    // 目的：作为暗通道模块和后续 Airlight 模块之间的缓冲。解决前后级处理速率不一致的问题。
    
    // 将对齐后的暗通道结果和 RGB 拼接成 32位 写入 FIFO
    wire [31:0] fifo_din   = {dc_result, r_dly, g_dly, b_dly}; 
    wire        fifo_empty; // FIFO 空标志
    wire [31:0] fifo_dout;  // FIFO 读出的 32位 数据
    wire        fifo_rd_en; // FIFO 读使能
    
    // 【FIFO 写使能】数据有效 + FIFO未满 + 核心流水线未暂停
    // 加 core_clken 是为了防止因为暂停导致同一有效数据被重复写入 FIFO
    wire fifo_wr_en = dc_valid && !fifo_full && core_clken;

    wire airlight_ready; // 后级 Airlight 模块是否准备好接收数据的标志
    assign top_n_ready = airlight_ready; // 将 ready 信号引出到顶层
    
    // 【FIFO 读使能】只要 FIFO 不空 且 后级准备好接收，就读出数据
    assign fifo_rd_en  = !fifo_empty && airlight_ready;

    // 实例化同步 FIFO
    fifo_sync1 #(
        .WIDTH (32),  // 数据位宽 32 bit (8位DC + 8位R + 8位G + 8位B)
        .DEPTH (4096) // FIFO 深度 4096 
    ) u_bridge_fifo (
        .clk       (clk),
        .rst_n     (rst_n),
        .wr_en     (fifo_wr_en),      // 写使能
        .rd_en     (fifo_rd_en),      // 读使能
        .din       (fifo_din),        // 写入数据
        .dout      (fifo_dout),       // 读出数据
        .empty     (fifo_empty),      // 空状态输出
        .full      (fifo_full),       // 满状态输出
        .prog_full (fifo_prog_full)   // 将满状态输出（用于流控o_busy）
    );

    // ============================================================
    // 4. 智能帧结束逻辑与大气光计算 (Smart Frame End & Airlight)
    // ============================================================
    // 这部分用于检测一帧图像的结束，并确保FIFO里的数据被完全清空处理完后，再通知后级。
    reg vsync_d; // 用于打拍延迟以进行边沿检测
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) vsync_d <= 0;
        else        vsync_d <= vsync;
    end
    
    // 边沿检测
    wire phy_frame_end   = (!vsync && vsync_d); // 下降沿：物理上一帧图像输入结束
    wire phy_frame_start = (vsync && !vsync_d); // 上升沿：物理上一帧图像输入开始
    
    // 状态寄存器：标记物理帧已结束，但 FIFO 中的数据尚未处理完
    reg pending_finish;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pending_finish <= 0;
        else if (phy_frame_end) pending_finish <= 1;                  // 物理帧结束时置 1
        else if (pending_finish && fifo_empty) pending_finish <= 0;   // FIFO清空时复位为 0
    end
    
    // 逻辑帧结束条件：物理帧恰好结束且FIFO空，或者 处于等待结束状态且FIFO刚被清空
    wire logical_frame_done = (phy_frame_end && fifo_empty) || (pending_finish && fifo_empty);
    
    // FIFO 读出数据的 Valid 信号需要打一拍，以匹配 FIFO RAM 读取的 1 周期延迟
    reg fifo_valid_dly;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fifo_valid_dly <= 0;
        else        fifo_valid_dly <= fifo_rd_en;
    end
    
    // 从 FIFO 输出的 32 位数据中解包出各个通道的数据
    wire [7:0] al_dark_in = fifo_dout[31:24]; // 取高8位：暗通道值
    wire [7:0] al_r_in    = fifo_dout[23:16]; // 取次高8位：R值
    wire [7:0] al_g_in    = fifo_dout[15:8];  // 取中间8位：G值
    wire [7:0] al_b_in    = fifo_dout[7:0];   // 取低8位：B值

    // 实例化动态大气光计算模块
    airlight_rgb_dynamic_topn #(
        .DATA_WIDTH (DATA_WIDTH),
        .MAX_TOP_N  (MAX_TOP_N),
        .SUM_WIDTH  (32) // 用于累加像素的内部位宽，防止溢出
    ) u_airlight (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (phy_frame_start),    // 接收一帧开始信号
        .frame_done    (logical_frame_done), // 接收一帧结束（且数据排空）信号
        .total_pixels  (TOTAL_PIXELS),       // 传入图像总像素数
        .pixel_valid   (fifo_valid_dly),     // FIFO送来的像素数据有效标志
        .pixel_dark    (al_dark_in),         // 当前像素的暗通道值
        .pixel_r       (al_r_in),            // 当前像素的R值
        .pixel_g       (al_g_in),            // 当前像素的G值
        .pixel_b       (al_b_in),            // 当前像素的B值
        .pixel_ready   (airlight_ready),     // 模块输出给前级的 ready 信号
        .result_valid  (result_valid),       // 大气光计算完成，结果有效
        .airlight_r    (airlight_r),         // 输出的大气光 R 通道结果
        .airlight_g    (airlight_g),         // 输出的大气光 G 通道结果
        .airlight_b    (airlight_b),         // 输出的大气光 B 通道结果
        .runtime_top_n ()                    // （悬空）如果需要的话可以引出实际统计的Top N数值
    );

endmodule