module ram(
    input wire          clk,
    input wire          rst,
    input wire   [3:0] w_en,
    input wire [11:0]   w_addr_i,
    input wire [31:0]  w_data_i,
    input wire          r_en,
    input wire [11:0]   r_addr_i,
    output wire [31:0] r_data_o
);


dual_ram#(
    .DW(32),
    .AW(12),
    .MEM_NUM(4096)
)
rom_mem(
    .clk      (clk),
    .rst      (rst),
    .w_en     (w_en),
    .w_addr_i (w_addr_i),
    .w_data_i (w_data_i),
    .r_en     (r_en),
    .r_addr_i (r_addr_i),
    .r_data_o (r_data_o)
   );

endmodule