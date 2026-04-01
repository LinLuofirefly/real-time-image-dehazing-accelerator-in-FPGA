// dff_ctrl: 6端口触发器（stall 与 flush 分离，用于需要区分两种控制的场景）
// flush 优先级 > stall 优先级 > 正常流通
module dff_set
    #(parameter DW = 32)
    (
    input  wire           clk,
    input  wire           rst,
    input  wire           hold_flag_i,   // Stall：冻结，保持当前值
    input  wire           flush_flag_i,  // Flush：清空，输出 set_data（如 NOP）
    input  wire [DW-1:0]  set_data,      // flush/rst 时的默认值
    input  wire [DW-1:0]  data_i,
    output reg  [DW-1:0]  data_o
    );

    always @(posedge clk) begin
        if (rst == 1'b0 || flush_flag_i == 1'b1) begin
            // 复位或强制清空（塞入气泡 NOP）
            data_o <= set_data;
        end else if (hold_flag_i == 1'b1) begin
            // 冻结：保持当前值
            data_o <= data_o;
        end else begin
            // 正常流通
            data_o <= data_i;
        end
    end
endmodule