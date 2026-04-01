module pc_reg(
    input wire clk,
    input wire rst,
    input wire hold_flag_i,
    input wire [31:0] jump_addr_i,
    input wire jump_en,
    output reg[31:0] pc_o
);
    always @(posedge clk) begin
        if (rst == 1'b0) begin
            pc_o <= 32'h0000_3000;
        end else begin
            if (jump_en) begin
                pc_o <= jump_addr_i;
            end else if (!hold_flag_i) begin
                pc_o <= pc_o + 4;
            end
        end
    end





endmodule
