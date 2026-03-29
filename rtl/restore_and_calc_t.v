/*
 * 模块：restore_and_calc_t
 * 功能：
 * 1. [还原] 将 8-bit (0-255) 的暗通道值映射为 Q1.15 定点数格式 (0.0 - 0.996)
 * 2. [计算] t_unclipped = ONE - (OMEGA * restored_dc)
 * 3. [裁剪] t_out = clip(t_unclipped, 0, 1) 防止透射率溢出越界
 */
module restore_and_calc_t #(
    // ============================================================
    // 模块参数定义 (Parameters)
    // ============================================================
    parameter DATA_WIDTH  = 16,       // 数据位宽，采用 Q1.15 格式 (1位符号位 + 15位小数位)
    parameter OMEGA_FIXED = 16'h799A, // 去雾保留系数 Omega，通常为 0.95 (0.95 * 32768 ≈ 31130 = 16'h799A)
    parameter ONE_FIXED   = 16'h7FFF, // 常数 1.0 的 Q1.15 格式近似值 (32767/32768 ≈ 0.9999)
    parameter ZERO_FIXED  = 16'h0000  // 常数 0.0 的 Q1.15 格式
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  clken,
    
    input  wire [7:0]            scaled_dc_in, // 输入：经过缩放和滤波后的 8-bit 暗通道值
    input  wire                  valid_in,     // 输入：数据有效信号
    
    output reg  [DATA_WIDTH-1:0] t_out,        // 输出：计算好的透射率 t(x)，Q1.15 格式
    output reg                   t_valid       // 输出：透射率有效信号
);

    // ============================================================
    // 包含 4 级流水线 (P1 还原 -> P2 乘法 -> P3 减法截断 -> P4 裁剪)
    // ============================================================
    
    // ------------------------------------------------------------
    // P1: 还原映射 (8-bit -> Q1.15)
    // ------------------------------------------------------------
    reg [DATA_WIDTH-1:0] dc_norm_q115_p1;
    reg                  valid_p1;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin 
            valid_p1 <= 0; 
        end else if (clken) begin
            // 巧妙的映射算术：输入范围是 0~255。将其左移 7 位 (相当于乘以 128)。
            // 最大值 255 * 128 = 32640。
            // 在 Q1.15 格式中，32640 / 32768 ≈ 0.996，完美将其映射到了 [0.0, 1.0) 区间。
            // 结构为：{1位符号(0正数), 8位数据, 7位补零}
            dc_norm_q115_p1 <= {1'b0, scaled_dc_in, 7'h00};
            valid_p1        <= valid_in;
        end
    end
    
    // ------------------------------------------------------------
    // P2: 乘法 (OMEGA * restored_dc)
    // ------------------------------------------------------------
    // 两个 16-bit (Q1.15) 相乘，结果为 32-bit。
    // 小数位数相加：15 + 15 = 30，所以乘积是 Q2.30 格式。
    reg [2*DATA_WIDTH-1:0] mul_full_p2;
    reg                    valid_p2;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin 
            valid_p2 <= 0; 
        end else if (clken) begin
            mul_full_p2 <= $signed(dc_norm_q115_p1) * $signed(OMEGA_FIXED);
            valid_p2    <= valid_p1;
        end
    end

    // ------------------------------------------------------------
    // P3: 减法与小数截断 (ONE - mul_result)
    // ------------------------------------------------------------
    reg [DATA_WIDTH-1:0] t_unclipped_p3;
    reg                  valid_p3;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin 
            valid_p3 <= 0; 
        end else if (clken) begin
            // 截断对齐：将 Q2.30 格式算术右移 15 位 (>>> 15)，变回 Q1.15 格式。
            // 然后用 1.0 (ONE_FIXED) 去减，完成 1 - w*I/A 的计算。
            t_unclipped_p3 <= ONE_FIXED - $signed(mul_full_p2 >>> 15);
            valid_p3       <= valid_p2;
        end
    end
    
    // ------------------------------------------------------------
    // P4: 裁剪与最终输出 (Clipping)
    // ------------------------------------------------------------
    // 防止透射率出现负数或大于 1 的异常情况 (溢出保护)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_out   <= 0;
            t_valid <= 0;
        end else if (clken) begin
            if (valid_p3) begin
                if ($signed(t_unclipped_p3) < $signed(ZERO_FIXED)) begin
                    t_out <= ZERO_FIXED; // 小于 0 则钳位到 0.0
                end else if ($signed(t_unclipped_p3) > $signed(ONE_FIXED)) begin
                    t_out <= ONE_FIXED;  // 大于 1 则钳位到 1.0
                end else begin
                    t_out <= t_unclipped_p3; // 正常区间，直接输出
                end
            end
            t_valid <= valid_p3;
        end else begin
            // clken 被拉低时，暂停输出 valid
            t_valid <= 1'b0;
        end
    end
    
endmodule