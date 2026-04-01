module open_risc_v_soc(
    input wire clk,
    input wire rst
);
wire [31:0]open_risc_v_inst_addr_o;
wire[31:0]rom_inst_o;
wire [31:0]data_addr_o;
wire [31:0]ram_data_i;
wire r_en;
wire [3:0]w_en;
wire [31:0]w_addr_i;
wire [31:0]w_data_i;
open_risc_v open_risc_v_inst(
    .clk(clk),
    .rst_n(rst),
    .pc_reg_pc_o(open_risc_v_inst_addr_o),
    .inst_i(rom_inst_o),
    .mem_rd_reg_o(r_en),
    .mem_rd_addr_o(data_addr_o),
    .ram_data_i(ram_data_i),
    .w_en(w_en),
    .w_addr_i(w_addr_i),
    .w_data_i(w_data_i)
);

rom rom_inst(
    .clk(clk),
    .rst(rst),
    .w_en(4'b0),
    .w_addr_i(12'b0),
    .w_data_i(32'b0),
    .r_en(1'b1),
    .r_addr_i(open_risc_v_inst_addr_o[13:2]), // 取指地址右移两位，得到字地址
    .r_data_o(rom_inst_o)
);



ram ram_data(
    .clk(clk),
    .rst(rst),
    .w_en(w_en),
    .w_addr_i(w_addr_i[13:2]), // 写地址右移两位，得到字地址
    .w_data_i(w_data_i),
    .r_en(r_en),
    .r_addr_i(data_addr_o[13:2]), // CPU认识的是字节地址，一个地址对应8bit，而 RAM 是以 32bit (4字节) 为一个地址单位的，所以需要右移两位除以4，得到字地址
    .r_data_o(ram_data_i)//低位的两位作为偏移量，在load的时候指引取哪个字节，读取内存时读取32位，根据偏移量选择其中的8位返回给CPU
);

endmodule