// 顶层模块：带前向转发逻辑（解决读写冲突）的双端口 RAM
module dual_ram#(
    parameter DW = 32,
    parameter AW = 12,
    parameter MEM_NUM = 4096 
)
(
    input  wire          clk,
    input  wire          rst,
    input  wire [3:0]    w_en,
    input  wire [AW-1:0] w_addr_i,
    input  wire [DW-1:0] w_data_i,
    input  wire          r_en,
    input  wire [AW-1:0] r_addr_i,
    output wire  [DW-1:0] r_data_o   
);
    reg [3:0] w_en_reg; // 存储写使能信号的寄存器
    reg              rd_wr_equ_flag;
    reg  [DW-1:0]    w_data_reg;
    wire [DW-1:0]    r_data_wire;
    
    // 多路选择器：发生冲突时输出寄存的写数据，否则输出 RAM 读出的数据   //sb指令时出错，不能32位全部前馈，因为可能只会修改一个字节
    //assign r_data_o = (rd_wr_equ_flag) ? w_data_reg : r_data_wire;    重复定义了r_data_o
    assign r_data_o[7:0]   = (rd_wr_equ_flag && w_en_reg[0]) ? w_data_reg[7:0]  : r_data_wire[7:0];
    assign r_data_o[15:8]  = (rd_wr_equ_flag && w_en_reg[1]) ? w_data_reg[15:8] : r_data_wire[15:8];
    assign r_data_o[23:16] = (rd_wr_equ_flag && w_en_reg[2]) ? w_data_reg[23:16] : r_data_wire[23:16];
    assign r_data_o[31:24] = (rd_wr_equ_flag && w_en_reg[3]) ? w_data_reg[31:24] : r_data_wire[31:24];
    // 写数据打一拍，为了与 RAM 读出的 1 周期延迟对齐
    always @(posedge clk) begin
        if(!rst) begin
            w_data_reg <= 32'b0;
            w_en_reg <= 4'b0000;
        end
        else begin
            w_data_reg <= w_data_i;
            w_en_reg <= w_en;    // 存下这一拍的掩码位，供下一拍的读数据选择使用
        end
    end
    
    // 读写冲突检测标志位生成
    always @(posedge clk) begin
        if(!rst)
            rd_wr_equ_flag <= 1'b0;
        else if(w_en && r_en && (w_addr_i == r_addr_i))
            rd_wr_equ_flag <= 1'b1;
        else if(r_en)
            rd_wr_equ_flag <= 1'b0;
    end
    
    // 例化底层 BRAM 模板
    dual_ram_template #(
        .DW(DW),
        .AW(AW),
        .MEM_NUM(MEM_NUM)
    ) dual_ram_template_inst (
        .clk      (clk),
        .rst      (rst),
        .w_en     (w_en),        
        .w_addr_i (w_addr_i),
        .w_data_i (w_data_i),
        .r_en     (r_en),        // 【修正3】端口名对齐
        .r_addr_i (r_addr_i),
        .r_data_o (r_data_wire)
    );

endmodule // 【修正4】顶层模块在此结束


// ---------------------------------------------------------
// 底层模块：标准同步双端口 RAM 模板 (易于综合为 BRAM)
// ---------------------------------------------------------
module dual_ram_template #(
    parameter DW = 32,
    parameter AW = 12,
    parameter MEM_NUM = 4096 
)
(
    input  wire          clk,
    input  wire          rst,
    input  wire [3:0]    w_en,
    input  wire [AW-1:0] w_addr_i,
    input  wire [DW-1:0] w_data_i,
    input  wire          r_en,
    input  wire [AW-1:0] r_addr_i,
    output reg  [DW-1:0] r_data_o
);

    reg [DW-1:0] mem [0:MEM_NUM-1]; // 存储阵列
    initial begin
       $readmemh("C:/Users/hp/Desktop/risc-v/sim/generated/inst_data.txt", mem); 
     
        //$readmemh("C:/Users/hp/Desktop/risc-v/sim/generated/rv32ui-p-lw.txt", mem); 
    end
    always @(posedge clk) begin
        // 4 个独立的 if 语句，完美对应 BRAM 硬件的 4 根 WE (Write Enable) 线
        // 只有当对应的掩码位为 1 时，才允许改写那 8 个 bit，其余位保持原样不变！
        if (w_en[0]) mem[w_addr_i][7:0]   <= w_data_i[7:0];
        if (w_en[1]) mem[w_addr_i][15:8]  <= w_data_i[15:8];
        if (w_en[2]) mem[w_addr_i][23:16] <= w_data_i[23:16];
        if (w_en[3]) mem[w_addr_i][31:24] <= w_data_i[31:24];
     
        if (r_en)  //改成同步读
            r_data_o <= mem[r_addr_i];
    end
    //assign r_data_o = (r_en == 1'b1) ? mem[r_addr_i] : 32'b0;
endmodule