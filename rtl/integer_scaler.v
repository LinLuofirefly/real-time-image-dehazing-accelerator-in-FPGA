/*
 * 模块：integer_scaler
 * 功能：
 * 1. 计算自适应缩放系数 K = 32640 / A (调用除法器 IP，存在 DIV_LATENCY 的延迟)
 * 2. 缩放计算 I_scaled_unclipped = (I_in * K) >>> SHIFT_BITS
 * 3. 饱和截断 I_scaled_out = Saturate(I_scaled_unclipped)
 * * 延迟说明：总流水线延迟 = DIV_LATENCY (计算K) + 1 (乘法阶段) + 1 (移位与截断阶段)
 */
module integer_scaler #(
    parameter SHIFT_BITS  = 7,
    parameter DIV_LATENCY = 36 // 除法器 IP 的潜伏期延迟，必须与 Xilinx/Altera IP 设置保持绝对一致
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clken,
    
    input  wire        href_in,
    input  wire [23:0] pixel_data_in,
    
    input  wire [7:0]  A_r, // 传入的大气光 R 分量
    input  wire [7:0]  A_g, // 传入的大气光 G 分量
    input  wire [7:0]  A_b, // 传入的大气光 B 分量
    
    output wire [23:0] scaled_pixel_data_out, // 缩放并截断后的输出像素
    output reg         href_out,              // 伴随输出的行有效信号
    output reg         valid_out              // 数据有效标志
);

    // 局部常数定义
    // 32640 = 255 * 128，隐含了 SHIFT_BITS (2^7=128) 的数学关系
    localparam [31:0] NUMERATOR = 32'd32640; 

    // ============================================================
    // 1. 数据延迟流水线 (Data Delay Line)
    // ============================================================
    // 为了让原始像素数据等待除法器计算完成，需要将其打拍延迟 DIV_LATENCY 个周期
    reg [23:0] pixel_dly   [0:DIV_LATENCY-1];
    reg        href_dly    [0:DIV_LATENCY-1];
    reg        valid_dly   [0:DIV_LATENCY-1]; 
    
    // 记录 A 是否为 0 的标志，也需要跟随流水线延迟，用于后续的除零异常保护
    reg        ar_zero_dly [0:DIV_LATENCY-1];
    reg        ag_zero_dly [0:DIV_LATENCY-1];
    reg        ab_zero_dly [0:DIV_LATENCY-1];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i=0; i<DIV_LATENCY; i=i+1) begin
                pixel_dly[i]   <= 0;
                href_dly[i]    <= 0;
                valid_dly[i]   <= 0;
                ar_zero_dly[i] <= 0;
                ag_zero_dly[i] <= 0;
                ab_zero_dly[i] <= 0;
            end
        end else if (clken) begin
            // 移位寄存器输入端 (第 0 级)
            pixel_dly[0]   <= pixel_data_in;
            href_dly[0]    <= href_in;
            valid_dly[0]   <= href_in; // 只有 href 有效时，数据才视为有效
            ar_zero_dly[0] <= (A_r == 0);
            ag_zero_dly[0] <= (A_g == 0);
            ab_zero_dly[0] <= (A_b == 0);
            
            // 移位操作 (第 1 到 N-1 级)
            for (i=1; i<DIV_LATENCY; i=i+1) begin
                pixel_dly[i]   <= pixel_dly[i-1];
                href_dly[i]    <= href_dly[i-1];
                valid_dly[i]   <= valid_dly[i-1];
                ar_zero_dly[i] <= ar_zero_dly[i-1];
                ag_zero_dly[i] <= ag_zero_dly[i-1];
                ab_zero_dly[i] <= ab_zero_dly[i-1];
            end
        end
    end

    // 提取延迟对齐后的数据供后续使用
    wire [23:0] pixel_aligned = pixel_dly[DIV_LATENCY-1];
    wire        href_aligned  = href_dly[DIV_LATENCY-1];
    wire [7:0]  r_aligned     = pixel_aligned[23:16];
    wire [7:0]  g_aligned     = pixel_aligned[15:8];
    wire [7:0]  b_aligned     = pixel_aligned[7:0];

    // ============================================================
    // 2. 除法器实例化 (Parallel Dividers)
    // ============================================================
    // 基于 Xilinx div_gen 接口: 
    // Dividend=32bit, Divisor=16bit, Output=48bit (商Quot位于 [47:16])
    // 虽然传入的是无符号数，但为了适配 Signed 接口，高位补 0 保证计算安全。
    
    wire [47:0] dout_r, dout_g, dout_b;
    wire        div_out_valid; // 仅需取其中一个通道的 valid 作为标志即可

    // R 通道除法： K_r = 32640 / A_r
    div_gen_0 u_div_k_r (
        .aclk                   (clk),
        .s_axis_dividend_tvalid (href_in),
        .s_axis_dividend_tdata  (NUMERATOR),   // 被除数: 32640
        .s_axis_divisor_tvalid  (href_in),
        .s_axis_divisor_tdata   ({8'b0, A_r}), // 除数: 扩展为 16位
        .m_axis_dout_tvalid     (div_out_valid),
        .m_axis_dout_tdata      (dout_r)
    );

    // G 通道除法： K_g = 32640 / A_g
    div_gen_0 u_div_k_g (
        .aclk                   (clk),
        .s_axis_dividend_tvalid (href_in),
        .s_axis_dividend_tdata  (NUMERATOR),
        .s_axis_divisor_tvalid  (href_in),
        .s_axis_divisor_tdata   ({8'b0, A_g}),
        .m_axis_dout_tvalid     (),            // 省略，复用 r 通道的 valid
        .m_axis_dout_tdata      (dout_g)
    );

    // B 通道除法： K_b = 32640 / A_b
    div_gen_0 u_div_k_b (
        .aclk                   (clk),
        .s_axis_dividend_tvalid (href_in),
        .s_axis_dividend_tdata  (NUMERATOR),
        .s_axis_divisor_tvalid  (href_in),
        .s_axis_divisor_tdata   ({8'b0, A_b}),
        .m_axis_dout_tvalid     (),
        .m_axis_dout_tdata      (dout_b)
    );

    // ============================================================
    // 3. K 值后处理 (Post-Processing & Exception Handling)
    // ============================================================
    // 从 48位 数据中提取 32位 商 (Quotient)
    wire [31:0] quot_r = dout_r[47:16];
    wire [31:0] quot_g = dout_g[47:16];
    wire [31:0] quot_b = dout_b[47:16];
    
    reg [8:0] K_r, K_g, K_b;

    // 组合逻辑处理溢出与除零异常 (利用刚才延迟对齐的标志位)
    // 注意：这里是纯组合逻辑，不会增加流水线延迟周期
    always @(*) begin
        // --- 处理 R 通道 ---
        if (ar_zero_dly[DIV_LATENCY-1]) K_r = 9'd511;       // 除0保护，赋予最大值
        else if (quot_r > 32'd511)      K_r = 9'd511;       // 饱和截断，防止系数过大
        else                            K_r = quot_r[8:0];  // 正常取值

        // --- 处理 G 通道 ---
        if (ag_zero_dly[DIV_LATENCY-1]) K_g = 9'd511;
        else if (quot_g > 32'd511)      K_g = 9'd511;
        else                            K_g = quot_g[8:0];

        // --- 处理 B 通道 ---
        if (ab_zero_dly[DIV_LATENCY-1]) K_b = 9'd511;
        else if (quot_b > 32'd511)      K_b = 9'd511;
        else                            K_b = quot_b[8:0];
    end

    // ============================================================
    // 4. 阶段 1: 乘法 (Pixel * K)
    // ============================================================
    reg [16:0] r_mul_p1, g_mul_p1, b_mul_p1;
    reg        href_p1, valid_p1;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_mul_p1 <= 0; g_mul_p1 <= 0; b_mul_p1 <= 0;
            href_p1  <= 0; valid_p1 <= 0;
        end else if (clken) begin
            // 使用延迟对齐后的原始像素 * 刚计算出的 K 值
            if (div_out_valid) begin
                r_mul_p1 <= r_aligned * K_r;
                g_mul_p1 <= g_aligned * K_g;
                b_mul_p1 <= b_aligned * K_b;
                href_p1  <= href_aligned;
                valid_p1 <= 1'b1;
            end else begin
                href_p1  <= 0;
                valid_p1 <= 0;
            end
        end
    end

    // ============================================================
    // 5. 阶段 2: 移位和裁剪 (Shift & Saturate)
    // ============================================================
    reg [7:0] r_scaled, g_scaled, b_scaled;
    
    // 算术右移，等效于除以 2^SHIFT_BITS
    wire [16:0] r_shifted_raw = r_mul_p1 >>> SHIFT_BITS;
    wire [16:0] g_shifted_raw = g_mul_p1 >>> SHIFT_BITS;
    wire [16:0] b_shifted_raw = b_mul_p1 >>> SHIFT_BITS;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_scaled <= 0; g_scaled <= 0; b_scaled <= 0;
            href_out <= 0; valid_out <= 0;
        end else if (clken) begin
            // R 通道饱和截断 (Clipping to 255)
            if (r_shifted_raw > 17'd255) r_scaled <= 8'd255;
            else                         r_scaled <= r_shifted_raw[7:0];

            // G 通道饱和截断
            if (g_shifted_raw > 17'd255) g_scaled <= 8'd255;
            else                         g_scaled <= g_shifted_raw[7:0];

            // B 通道饱和截断
            if (b_shifted_raw > 17'd255) b_scaled <= 8'd255;
            else                         b_scaled <= b_shifted_raw[7:0];

            href_out  <= href_p1;
            valid_out <= valid_p1;
        end else begin
            // clken 无效时，为了安全起见输出清零 (或者设计为保持当前状态)
             valid_out <= 0; 
             href_out  <= 0;
        end
    end

    // 拼接最终输出
    assign scaled_pixel_data_out = {r_scaled, g_scaled, b_scaled};

endmodule