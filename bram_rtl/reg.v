module regs(
    input wire clk,
    input wire rst,
    input wire [4:0] reg1_raddr_i,
    input wire [4:0] reg2_raddr_i,

    output reg [31:0] reg1_rdata_o,
    output reg [31:0] reg2_rdata_o,

    input wire [4:0] reg_waddr_i,
    input wire [31:0] reg_wdata_i,
    input wire reg_wen
);
    reg[31:0]regs[0:31]; //【31:0】表示每个寄存器32位，regs[0:31]表示有32个寄存器
    //读寄存器是组合逻辑
    always@(*) begin
        if(rst ==1'b0)begin
            reg1_rdata_o=32'b0;   //复位时读寄存器输出0
        end
        else if(reg1_raddr_i == 5'b0)begin   //如果读寄存器地址是0，输出0，因为x0寄存器永远为0,这是为了节省资源，用ADD指令实现mov指令的特点
            reg1_rdata_o=32'b0;
        end
        else if(reg_wen == 1'b1 && reg1_raddr_i == reg_waddr_i)begin   //如果当前有写寄存器操作，并且写寄存器地址和读寄存器地址相同，说明要读的寄存器正在被写入，这时应该输出写入的数据，而不是寄存器文件中的旧数据，这样可以解决数据冒险问题
            reg1_rdata_o=reg_wdata_i;
        end
        else begin
            reg1_rdata_o=regs[reg1_raddr_i]; //读出第n个寄存器的数据
        end
    
    end
    always@(*) begin
        if(rst ==1'b0)begin
            reg2_rdata_o=32'b0;
        end
        else if(reg2_raddr_i == 5'b0)begin  //
            reg2_rdata_o=32'b0;
        end
        else if(reg_wen == 1'b1 && reg2_raddr_i == reg_waddr_i)begin
            reg2_rdata_o=reg_wdata_i;
        end
        else begin
            reg2_rdata_o=regs[reg2_raddr_i];

        end
    
    end
    //写入寄存器是时序逻辑
    integer i;
    always @(posedge clk) begin
        if(rst==1'b0)begin
         for (i =0 ;i<=31 ;i=i+1 ) begin
            regs[i] <= 32'b0;            
         end
        end
        else if(reg_wen == 1'b1 && reg_waddr_i != 5'b0)begin //写寄存器操作，并且写寄存器地址不为0，因为x0寄存器永远为0，不能被写入
            regs[reg_waddr_i] <= reg_wdata_i;   
        end        
    end


endmodule