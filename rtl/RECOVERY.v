module dehaze_recovery (
    input  wire        clk,
    input  wire        rst_n,
    
    // --- 输入接口 ---
    // 输入的像素数据和透射率必须在时间上是绝对对齐的
    input  wire        i_valid, // 输入数据有效信号
    input  wire [7:0]  i_r,     // 原始图像 R 通道 (无符号)
    input  wire [7:0]  i_g,     // 原始图像 G 通道 (无符号)
    input  wire [7:0]  i_b,     // 原始图像 B 通道 (无符号)
    input  wire [15:0] i_t,     // 透射率 t(x)，采用 Q1.15 定点数格式
    
    // 已经转换为有符号数的大气光 A (防止减法溢出)
    input  signed [8:0] atm_r,
    input  signed [8:0] atm_g,
    input  signed [8:0] atm_b,
    
    // --- 输出接口 ---
    output reg         o_valid, // 输出数据有效信号
    output reg  [7:0]  o_r,     // 恢复后的图像 R 通道
    output reg  [7:0]  o_g,     // 恢复后的图像 G 通道
    output reg  [7:0]  o_b      // 恢复后的图像 B 通道
);

    // ==========================================
    // 常量定义
    // ==========================================
    // 为了防止除以极小的透射率导致画面出现严重噪点或纯白，设置透射率下限
    // 0.2 的 Q1.15 定点数表示：0.2 * 32768 = 6553.6 ≈ 6554
    localparam [15:0] T_MIN   = 16'd6554;  
    // 1.0 的 Q1.15 定点数表示
    localparam [15:0] ONE_Q15 = 16'd32768;

    // ==========================================
    // Stage 1: 预处理 (计算 I-A 并钳位透射率 t)
    // ==========================================
    // I(x) 是 8-bit(无符号)，A 是 9-bit(有符号)
    // 相减的结果可能为负数，因此需要使用 10-bit 有符号数来安全存放
    reg signed [9:0]  diff_r, diff_g, diff_b; 
    reg        [15:0] t_clamped; // 钳位后的透射率
    reg               valid_s1;  // 伴随的有效信号
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            diff_r    <= 0;
            diff_g    <= 0;
            diff_b    <= 0;
            t_clamped <= 0;
            valid_s1  <= 0;
        end else begin
            // 核心公式分子部分：(I(x) - A)
            // {1'b0, i_r} 是将无符号的 8-bit 零扩展为 9-bit 有符号数
            diff_r <= $signed({1'b0, i_r}) - atm_r;
            diff_g <= $signed({1'b0, i_g}) - atm_g;
            diff_b <= $signed({1'b0, i_b}) - atm_b;
            
            // 钳位透射率下限：防止除以极小数放大噪声
            if (i_t < T_MIN) t_clamped <= T_MIN;
            else             t_clamped <= i_t;
                
            // 流水线控制信号打拍
            valid_s1 <= i_valid;
        end
    end

    // ==========================================
    // Stage 2: 除法准备 (将被除数放大以适配 Q15 除数)
    // ==========================================
    // 因为分母透射率 t(x) 是 Q1.15 格式 (放大了 2^15 倍)
    // 根据除法法则：(Num * 2^15) / (Den * 2^15) = Num / Den
    // 我们需要将被除数左移 15 位，抵消掉除数的小数位，从而让商变回真实的整数
    reg signed [24:0] num_r, num_g, num_b; // 10-bit 左移 15 位 -> 25-bit
    reg        [15:0] den_t;
    reg               valid_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            num_r <= 0; num_g <= 0; num_b <= 0;
            den_t <= 0;
            valid_s2 <= 0;
        end else begin
            // 带符号算术左移 15 位 (等效于乘以 32768)
            num_r <= diff_r <<< 15; 
            num_g <= diff_g <<< 15;
            num_b <= diff_b <<< 15;
            // 传递除数 (透射率)
            den_t <= t_clamped;
            
            // 流水线控制信号打拍
            valid_s2 <= valid_s1;
        end
    end

    // ==========================================
    // Stage 3: 调用除法器 IP (并行计算 3 个通道)
    // ==========================================
    
    // 除法器输出信号声明
    wire        div_out_valid; // 只需要取其中一个通道的 valid 作为标志，因为三个除法器延时完全一致
    wire [47:0] div_dout_r, div_dout_g, div_dout_b;
    
    // 提取商 (Quotient)
    // 按照 Xilinx 除法 IP 默认配置: Dividend=32bit(Signed), Divisor=16bit(Unsigned)
    // 输出总宽度 48bit，商位于高 32 位 [47:16]，余数位于低 16 位 [15:0]
    wire signed [31:0] quot_r = div_dout_r[47:16];
    wire signed [31:0] quot_g = div_dout_g[47:16];
    wire signed [31:0] quot_b = div_dout_b[47:16];

    // ------------------------------------------------------
    // 实例化 R 通道除法器
    // ------------------------------------------------------
    div_gen_0 u_div_r (
        .aclk                   (clk),
        .s_axis_dividend_tvalid (valid_s2),
        // 被除数需要 32 位，我们将 25-bit 的 num_r 进行符号扩展补齐 32 位
        // {{7{num_r[24]}}, num_r} 意味着将最高位 (符号位) 复制 7 次填充高位
        .s_axis_dividend_tdata  ( {{7{num_r[24]}}, num_r} ), 
        .s_axis_divisor_tvalid  (valid_s2),
        .s_axis_divisor_tdata   (den_t), // 除数 (无符号数)
        .m_axis_dout_tvalid     (div_out_valid), // 提取 Valid 信号
        .m_axis_dout_tdata      (div_dout_r)
    );

    // ------------------------------------------------------
    // 实例化 G 通道除法器
    // ------------------------------------------------------
    div_gen_0 u_div_g (
        .aclk                   (clk),
        .s_axis_dividend_tvalid (valid_s2),
        .s_axis_dividend_tdata  ( {{7{num_g[24]}}, num_g} ),
        .s_axis_divisor_tvalid  (valid_s2),
        .s_axis_divisor_tdata   (den_t),
        .m_axis_dout_tvalid     (), // 省略悬空，复用 R 通道的 valid
        .m_axis_dout_tdata      (div_dout_g)
    );

    // ------------------------------------------------------
    // 实例化 B 通道除法器
    // ------------------------------------------------------
    div_gen_0 u_div_b (
        .aclk                   (clk),
        .s_axis_dividend_tvalid (valid_s2),
        .s_axis_dividend_tdata  ( {{7{num_b[24]}}, num_b} ),
        .s_axis_divisor_tvalid  (valid_s2),
        .s_axis_divisor_tdata   (den_t),
        .m_axis_dout_tvalid     (), // 省略悬空
        .m_axis_dout_tdata      (div_dout_b)
    );

    // ==========================================
    // Stage 4: 后处理 (加上大气光 A 并进行饱和截断)
    // ==========================================
    // 此时 div_out_valid 已经是经历了除法器数十拍延迟后的有效信号了。
    // 大气光 A 虽然没有打拍跟着流水线走，但因为它是每一帧全局不变的常数，
    // 所以直接在这里使用并不会产生时序或逻辑错误。
    
    // 使用 33-bit 有符号数存放相加结果，防止溢出
    reg signed [32:0] final_r, final_g, final_b; 
    reg               valid_s4;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            final_r <= 0; final_g <= 0; final_b <= 0;
            valid_s4 <= 0;
        end else begin
            // 恢复公式完整步骤: J = (I-A)/t + A
            // 上方 quot_r 已经算出了 (I-A)/t 的结果，加上 A 即可
            if (div_out_valid) begin
                final_r <= quot_r + atm_r;
                final_g <= quot_g + atm_g;
                final_b <= quot_b + atm_b;
            end
            
            // 流水线控制信号打拍
            valid_s4 <= div_out_valid;
        end
    end

    // 钳位逻辑函数：确保最终的 RGB 像素值处于 0~255 的合法区间内
    function [7:0] clamp;
        input signed [32:0] val;
        begin
            if (val < 0)
                clamp = 8'd0;       // 小于0截断为0 (变黑)
            else if (val > 255)
                clamp = 8'd255;     // 大于255截断为255 (变白)
            else
                clamp = val[7:0];   // 正常区间直接保留低 8 位
        end
    endfunction

    // 最终输出寄存器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_r <= 0; o_g <= 0; o_b <= 0;
            o_valid <= 0;
        end else begin
            // 调用函数进行安全钳位输出
            o_r <= clamp(final_r);
            o_g <= clamp(final_g);
            o_b <= clamp(final_b);
            o_valid <= valid_s4;
        end
    end

endmodule