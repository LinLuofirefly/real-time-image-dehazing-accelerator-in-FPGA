module rom(
    input wire          clk,
    input wire          rst,
    input wire [3:0]    w_en,
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
//module rom (
//    input r_en,
//    input  wire [11:0] r_addr_i,
//    output wire [31:0] r_data_o
//);
//    // 定义一个足够装下测试程序的数组
//    reg [31:0] rom_mem [0:4095]; 
//
//    // 使用初始块把你的 .bin 或 .txt 测试代码加载进来
//    initial begin
//        $readmemh("C:/Users/hp/Desktop/risc-v/sim/generated/inst_data.txt", rom_mem); 
//    end
//
//    // 🚨 极其关键的一句：组合逻辑瞬间输出，0 延迟！
//    // 右移 2 位是因为 RISC-V 的 PC 是按字节寻址 (每次 +4)，而我们的数组是按字寻址 (每次 +1)
//    assign r_data_o = rom_mem[r_addr_i]; 
//
//endmodule


//3月27日日志，整出来了forward和预测，问题主要出在连线复杂的一笔，看着眼睛累，好多个连线连错了，靠ai修改了好几次，然后是rom不能用dual_ram了，如果有打拍的话流水线会出错。
//如果rom要复用dualram的话，可能需要if_id模块写个ifelse？
//debug日志：如果跑不通，看看指令的反汇编代码，打印CPU里的指令和pc的地址，还有一些关键信号的值，判断是哪里出了问题


//3月31日日志，试图将五级流水线改成六级流水线，异步读改成同步读。