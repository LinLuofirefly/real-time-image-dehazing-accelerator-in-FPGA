`timescale 1ns/1ps

module airlight_rgb_dynamic_topn #(
    // ============================================================
    // 模块参数定义 (Parameters)
    // ============================================================
    parameter DATA_WIDTH = 8,   // 颜色数据位宽
    parameter MAX_TOP_N  = 502, // 最大Top-N数量（即内部RAM的深度）
    parameter SUM_WIDTH  = 32   // RGB累加求和时的位宽，防止溢出
)(
    input  wire                  clk,          // 系统时钟
    input  wire                  rst_n,        // 全局异步复位，低电平有效
    
    // ------ 图像配置接口 ------
    input  wire                  start,        // 一帧图像处理开始信号（通常接vsync上升沿）
    input  wire [31:0]           total_pixels, // 图像总像素数 (IMG_WIDTH * IMG_HEIGHT)
    
    // ------ 流式像素数据接口 ------
    input  wire                  pixel_valid,  // 输入像素有效标志
    input  wire [DATA_WIDTH-1:0] pixel_dark,   // 当前像素的暗通道值
    input  wire [DATA_WIDTH-1:0] pixel_r,      // 当前像素的 R 分量
    input  wire [DATA_WIDTH-1:0] pixel_g,      // 当前像素的 G 分量
    input  wire [DATA_WIDTH-1:0] pixel_b,      // 当前像素的 B 分量
    output reg                   pixel_ready,  // 模块准备好接收数据标志（流控用）

    // ------ 控制接口 ------
    input  wire                  frame_done,   // 帧结束标志（所有像素均已输入完毕）

    // ------ 大气光计算结果输出 ------
    output reg                   result_valid, // 最终大气光计算完成且结果有效
    output reg  [DATA_WIDTH-1:0] airlight_r,   // 计算得到的大气光 R 分量
    output reg  [DATA_WIDTH-1:0] airlight_g,   // 计算得到的大气光 G 分量
    output reg  [DATA_WIDTH-1:0] airlight_b,   // 计算得到的大气光 B 分量
    
    // ------ 运行时统计/调试输出 ------
    output reg  [15:0]           runtime_top_n // 实际计算出的Top-N数量 (总像素的0.1%)
);

    // 计算内部RAM的地址位宽
    localparam ADDR_WIDTH = $clog2(MAX_TOP_N);  //log2函数计算地址位宽，确保能寻址MAX_TOP_N个位置,localparam是局部参数，不能被外部模块访问或覆盖

     // ============================================================

    // ============================================================
    // 1. 存储资源 (Storage Resources)
    // ============================================================
    // 内部 RAM，用于保存当前找出的前 N 个最亮暗通道像素及其 RGB 值
    // 32位结构：[31:24] 暗通道值, [23:16] R, [15:8] G, [7:0] B
    reg [31:0] top_mem [0:MAX_TOP_N-1];

    // ============================================================
    // 2. 内部寄存器 (Internal Registers)
    // ============================================================
    reg [DATA_WIDTH-1:0] current_min_dark;   // 记录当前RAM中暗通道值最小的那个值
    reg [ADDR_WIDTH-1:0] current_min_addr;   // 记录当前RAM中暗通道值最小的那个值的地址

    reg [DATA_WIDTH-1:0] scan_min_dark_temp; // 扫描RAM时用于寻找最小值的临时变量
    reg [ADDR_WIDTH-1:0] scan_min_addr_temp; // 扫描RAM时用于寻找最小地址的临时变量
    reg [ADDR_WIDTH-1:0] scan_cnt;           // 扫描RAM的地址计数器
    reg [ADDR_WIDTH-1:0] scan_cnt_d;         // 扫描RAM地址计数器打一拍（匹配RAM读取延迟）

    reg [SUM_WIDTH-1:0]  sum_r, sum_g, sum_b; // RGB 通道的累加器寄存器
    reg [ADDR_WIDTH-1:0] sum_cnt;             // 求和时的地址计数器
    
    reg frame_done_latched;                  // 帧结束标志的锁存寄存器

    // ============================================================
    // 3. 除法器 IP 信号定义 (Divider Signals)
    // ============================================================
    reg         div_input_valid; // 触发除法器计算的有效信号
    reg  [31:0] div_dividend;    // 被除数 (Dividend)
    reg  [15:0] div_divisor;     // 除数 (Divisor)
    
    // 【注】当前除法器 IP 配置为 Non-Blocking（非阻塞）模式，因此移除了 tready 握手信号
    // output wire divisor_tready;  <-- 移除
    // output wire dividend_tready; <-- 移除
    
    wire        div_out_valid;   // 除法器计算完成，输出结果有效
    wire [47:0] div_out_data;    // 除法器输出的原始数据
    wire [31:0] div_quotient;    // 提取出的商
    
    // 商存放在数据的高位 [47:16] (根据 Xilinx Div IP 核的默认非阻塞配置)
    assign div_quotient = div_out_data[47:16]; 

    reg [1:0]   div_stage;       // 记录除法计算阶段（0:算R均值, 1:算G均值, 2:算B均值）

    // ============================================================
    // 4. 状态机定义 (FSM Definition)
    // ============================================================
    localparam [3:0] S_IDLE        = 4'd0;  // 空闲状态
    localparam [3:0] S_CLEAR_MEM   = 4'd1;  // 清空内部 RAM
    localparam [3:0] S_CALC_N_SEND = 4'd2;  // 发送求 N 的除法请求 (总像素 / 1000)
    localparam [3:0] S_CALC_N_WAIT = 4'd3;  // 等待 N 计算完成
    localparam [3:0] S_STREAM      = 4'd4;  // 接收并处理视频数据流
    localparam [3:0] S_UPDATE_WR   = 4'd5;  // 发现更大的暗通道值，覆盖写入 RAM
    localparam [3:0] S_SCAN_INIT   = 4'd6;  // 初始化 RAM 扫描过程
    localparam [3:0] S_SCANNING    = 4'd7;  // 扫描 RAM，寻找新的最小值并记录其地址
    localparam [3:0] S_SUM_INIT    = 4'd8;  // 初始化求和过程
    localparam [3:0] S_SUM_LOOP    = 4'd9;  // 遍历 RAM 累加所有的 RGB 值
    localparam [3:0] S_AVG_SEND    = 4'd10; // 依次发送 R, G, B 求平均值的除法请求
    localparam [3:0] S_AVG_WAIT    = 4'd11; // 等待均值除法结果
    localparam [3:0] S_DONE        = 4'd12; // 一帧处理结束，输出有效结果

    reg [3:0] state_reg, state_next; // 现态与次态寄存器

    // 内部 RAM 的控制信号
    reg [ADDR_WIDTH-1:0] mem_addr;
    reg                  mem_we;
    reg [31:0]           mem_wdata;
    reg [31:0]           mem_data_out;

    // RAM 同步读写逻辑
    always @(posedge clk) begin
        if (mem_we) top_mem[mem_addr] <= mem_wdata; // 写操作
        mem_data_out <= top_mem[mem_addr];          // 读操作（有 1 周期延迟）
    end
    
    // 解析 RAM 读出的数据
    wire [7:0] mem_out_dark = mem_data_out[31:24];
    wire [7:0] mem_out_r    = mem_data_out[23:16];
    wire [7:0] mem_out_g    = mem_data_out[15:8];
    wire [7:0] mem_out_b    = mem_data_out[7:0];

    // ============================================================
    // 5. 实例化除法器 (Divisor IP, 使用 Non-Blocking 配置)
    // ============================================================
    div_gen_0 u_div_gen (
        .aclk                   (clk),
        // 输入通道：非阻塞模式下只有 Valid 和 Data
        .s_axis_divisor_tvalid  (div_input_valid),
        .s_axis_divisor_tdata   (div_divisor),     
        .s_axis_dividend_tvalid (div_input_valid),
        .s_axis_dividend_tdata  (div_dividend),    
        // 输出通道：输出有效信号和结果数据
        .m_axis_dout_tvalid     (div_out_valid),
        .m_axis_dout_tdata      (div_out_data)     
    );

    // ============================================================
    // 6. 帧结束打拍逻辑 (Frame Done Latch)
    // ============================================================
    // 为了防止在处理过程中漏掉短促的 frame_done 脉冲
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) 
            frame_done_latched <= 1'b0;
        else if (state_reg == S_IDLE)
            frame_done_latched <= 1'b0; // 一帧开始前清零
        else if (frame_done)
            frame_done_latched <= 1'b1; // 接收到帧结束信号后锁存
    end

    // ============================================================
    // 7. FSM 组合逻辑 (次态与输出控制)
    // ============================================================
    always @(*) begin
        // 默认赋初值，防止生成意外的锁存器 (Latch)
        state_next      = state_reg;
        mem_we          = 1'b0;
        mem_addr        = 0;
        mem_wdata       = 0;
        div_input_valid = 1'b0;
        div_dividend    = 0;
        div_divisor     = 1; 

        case (state_reg)
            S_IDLE: begin
                if (start) state_next = S_CLEAR_MEM; // 收到 start 信号，准备清空 RAM
            end
            
            S_CLEAR_MEM: begin
                mem_we    = 1'b1;
                mem_addr  = scan_cnt; 
                mem_wdata = 0; // 全部清零
                if (scan_cnt == MAX_TOP_N - 1) state_next = S_CALC_N_SEND;
            end

            // --- 计算运行时的 Top N (通常为图像总像素的 0.1%) ---
            S_CALC_N_SEND: begin
                div_input_valid = 1'b1;
                div_dividend    = total_pixels; // 被除数：总像素
                div_divisor     = 16'd1000;     // 除数：1000 (即求 0.1%)
                
                // 修改：Non-Blocking 模式下，默认 IP 始终 Ready
                // 给出一个周期的 Valid 后直接进入等待状态
                state_next = S_CALC_N_WAIT;
            end

            S_CALC_N_WAIT: begin
                if (div_out_valid) state_next = S_STREAM; // 除法完成，进入视频流处理
            end

            // --- 处理像素流 (核心比对逻辑) ---
            S_STREAM: begin
                if (frame_done_latched) begin
                    state_next = S_SUM_INIT; // 帧结束，准备进入求和阶段
                end
                else if (pixel_valid && pixel_ready) begin
                    // 如果新进来的像素的暗通道值，大于当前RAM里存的最小值
                    if (pixel_dark > current_min_dark) 
                        state_next = S_UPDATE_WR; // 去踢掉并覆盖那个最小值
                end
            end

            S_UPDATE_WR: begin
                mem_we    = 1'b1;
                mem_addr  = current_min_addr; // 覆盖在原最小值的地址上
                mem_wdata = {pixel_dark, pixel_r, pixel_g, pixel_b};
                state_next = S_SCAN_INIT;     // 写入后，必须重新扫描一遍RAM，找出新的最小值
            end

            S_SCAN_INIT: state_next = S_SCANNING;

            S_SCANNING: begin
                mem_addr = scan_cnt;
                // 当读取的地址计数器和延迟一拍的计数器都达到 N-1 时，扫描完毕返回数据流状态
                if (scan_cnt == runtime_top_n - 1 && scan_cnt_d == runtime_top_n - 1) 
                    state_next = S_STREAM;
            end

            S_SUM_INIT: state_next = S_SUM_LOOP;

            S_SUM_LOOP: begin
                mem_addr = sum_cnt; // 逐个地址读出数据
                if (sum_cnt == runtime_top_n + 1) 
                    state_next = S_AVG_SEND; // 读完且累加完成后转去求平均值
            end

            // --- 分时复用除法器，计算 R, G, B 的均值 ---
            S_AVG_SEND: begin
                div_input_valid = 1'b1;
                div_divisor     = runtime_top_n; // 除以总个数 N
                
                case (div_stage)
                    0: div_dividend = sum_r; // 阶段0：算R
                    1: div_dividend = sum_g; // 阶段1：算G
                    2: div_dividend = sum_b; // 阶段2：算B
                endcase
                
                // 修改：发送数据后直接转入等待（无 Ready 握手）
                state_next = S_AVG_WAIT;
            end

            S_AVG_WAIT: begin
                if (div_out_valid) begin
                    // 如果已经是最后一步 B 的除法，计算结束，跳去 S_DONE
                    if (div_stage == 2) state_next = S_DONE;
                    else state_next = S_AVG_SEND; // 否则循环计算下一个颜色通道
                end
            end

            S_DONE: begin 
                if (start) state_next = S_CLEAR_MEM; // 保持输出，直到下一帧开始
            end
            
            default: state_next = S_IDLE;
        endcase
    end

    // ============================================================
    // 8. FSM 时序逻辑 (状态流转与寄存器更新)
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg          <= S_IDLE;
            pixel_ready        <= 0;
            result_valid       <= 0;
            runtime_top_n      <= 1;  
            
            current_min_dark   <= 0; 
            current_min_addr   <= 0;
            scan_cnt           <= 0; 
            scan_cnt_d         <= 0;
            sum_cnt            <= 0;
            sum_r <= 0; sum_g <= 0; sum_b <= 0;
            div_stage          <= 0;
            
            airlight_r <= 0; airlight_g <= 0; airlight_b <= 0;
            scan_min_dark_temp <= 0; 
            scan_min_addr_temp <= 0;
            
        end else begin
            state_reg <= state_next;

            case (state_reg)
                S_IDLE: begin
                    pixel_ready  <= 0;
                    result_valid <= 0;
                    scan_cnt     <= 0; 
                end
                
                S_CLEAR_MEM: begin
                   if (scan_cnt < MAX_TOP_N - 1) 
                       scan_cnt <= scan_cnt + 1;
                   else 
                       scan_cnt <= 0; 
                   current_min_dark <= 0; 
                   current_min_addr <= 0;
                end

                S_CALC_N_WAIT: begin
                    if (div_out_valid) begin
                        // 保护机制：防止 N 等于 0，且限制最大不超过 MAX_TOP_N
                        if (div_quotient == 0) 
                            runtime_top_n <= 1;
                        else if (div_quotient > MAX_TOP_N) 
                            runtime_top_n <= MAX_TOP_N[15:0];
                        else 
                            runtime_top_n <= div_quotient[15:0];
                        
                        current_min_dark <= 0;
                        current_min_addr <= 0;
                    end
                end

                S_STREAM:    pixel_ready <= 1; // 处于流接收状态时准备好接收数据
                S_UPDATE_WR: pixel_ready <= 0; // 更新和扫描期间暂停接收数据

                S_SCAN_INIT: begin
                    scan_cnt <= 0; scan_cnt_d <= 0;
                    scan_min_dark_temp <= {DATA_WIDTH{1'b1}}; // 初始化为最大值 (例如 8'hFF)
                    scan_min_addr_temp <= 0;
                end

                S_SCANNING: begin
                    if (scan_cnt < runtime_top_n - 1) scan_cnt <= scan_cnt + 1;
                    scan_cnt_d <= scan_cnt; // 打一拍对齐 RAM 的读取延迟
                    
                    // 比对找最小值：将 RAM 读出的暗通道值与临时极小值进行比较
                    if (mem_out_dark < scan_min_dark_temp) begin
                        scan_min_dark_temp <= mem_out_dark;
                        scan_min_addr_temp <= scan_cnt_d;
                    end
                    
                    // 扫描结束时，将临时存放的最小值赋给 current_min_dark，用于后续与新进像素比对
                    if (scan_cnt == runtime_top_n - 1 && scan_cnt_d == runtime_top_n - 1) begin
                         if (mem_out_dark < scan_min_dark_temp) begin
                             current_min_dark <= mem_out_dark;
                             current_min_addr <= scan_cnt_d;
                         end else begin
                             current_min_dark <= scan_min_dark_temp;
                             current_min_addr <= scan_min_addr_temp;
                         end
                    end
                end

                S_SUM_INIT: begin
                    pixel_ready <= 0;
                    sum_cnt     <= 0;
                    sum_r <= 0; sum_g <= 0; sum_b <= 0;
                end

                S_SUM_LOOP: begin
                    if (sum_cnt <= runtime_top_n) sum_cnt <= sum_cnt + 1;
                    // 注意：由于 RAM 读取有一拍延迟，所以在 sum_cnt 为 1 时，取到的是地址 0 的数据
                    if (sum_cnt >= 1 && sum_cnt <= runtime_top_n + 1) begin
                        if (sum_cnt - 1 < runtime_top_n) begin
                            sum_r <= sum_r + mem_out_r; // 累加 R
                            sum_g <= sum_g + mem_out_g; // 累加 G
                            sum_b <= sum_b + mem_out_b; // 累加 B
                        end
                    end
                end
                
                S_AVG_WAIT: begin
                    if (div_out_valid) begin
                        case (div_stage)
                            0: airlight_r <= div_quotient[DATA_WIDTH-1:0]; // 保存大气光 R
                            1: airlight_g <= div_quotient[DATA_WIDTH-1:0]; // 保存大气光 G
                            2: airlight_b <= div_quotient[DATA_WIDTH-1:0]; // 保存大气光 B
                        endcase
                        div_stage <= div_stage + 1; // 切换到下一个颜色的除法阶段
                    end
                end

                S_DONE: begin
                    result_valid <= 1; // 计算完成，结果有效
                    div_stage    <= 0;
                end
            endcase
        end
    end

endmodule