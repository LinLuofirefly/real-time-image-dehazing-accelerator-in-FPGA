`timescale 1ns/1ps

/**
 * @module   fifo_sync_pixel_delay
 * @brief    同步 FIFO 缓存模块 (用于像素延迟补偿)
 * @details  本模块使用单一时钟域，通过内部计数器和读写指针管理数据流。
 * 建议深度设计为：深度 > (行缓存延迟 + 流水线计算延迟)。
 * 例如：对于 640x480 图像，如果使用 15x15 的大窗口计算暗通道，
 * 建议将深度设为 4096 或 8192 以防止数据溢出或覆盖。
 */
module fifo_sync_pixel_delay #(
    // ============================================================
    // 模块参数定义 (Parameters)
    // ============================================================
    parameter WIDTH = 24,   // 数据位宽，默认 24-bit 对应 {R, G, B} 像素数据
    parameter DEPTH = 4096  // FIFO 深度，表示最多可以缓存多少个像素
)(
    // ============================================================
    // 端口定义 (Ports)
    // ============================================================
    input  wire             clk,   // 系统时钟 (读写共用同一个时钟，即同步 FIFO)
    input  wire             rst,   // 【注意】这里是高电平有效的异步复位信号
    
    // 写端口 (Write Port)
    input  wire             wr_en, // 写使能信号
    input  wire [WIDTH-1:0] din,   // 写入的数据输入
    
    // 读端口 (Read Port)
    input  wire             rd_en, // 读使能信号
    output reg  [WIDTH-1:0] dout,  // 读出的数据输出
    
    // 状态标志 (Status Flags)
    output wire             full,  // FIFO 满标志，为 1 时不可再写入
    output wire             empty  // FIFO 空标志，为 1 时不可再读取
);

    // ============================================================
    // 内部寄存器与连线定义 (Internal Signals)
    // ============================================================
    
    // 声明一个二维数组作为存储介质，综合工具 (Synthesis Tool) 会尝试将其推断为 BRAM (块RAM)
    reg [WIDTH-1:0] mem [0:DEPTH-1]; 
    
    // 读写指针位宽计算：使用内置系统函数 $clog2 自动计算出需要的地址位宽
    // 例如 DEPTH=4096，则 $clog2(4096) = 12，所以指针位宽为 [11:0]
    reg [$clog2(DEPTH)-1:0] w_ptr; // 写指针 (Write Pointer)，指向下一个要写入的地址
    reg [$clog2(DEPTH)-1:0] r_ptr; // 读指针 (Read Pointer)，指向下一个要读取的地址
    
    // 元素计数器：位宽需要比指针多出 1 位，才能表示满载状态 (例如 4096 需要 13 位才能表示)
    reg [$clog2(DEPTH):0]   count; // 记录当前 FIFO 中存在的数据个数

    // ============================================================
    // 状态标志赋值 (Status Assignment)
    // ============================================================
    // 组合逻辑直接判断：当计数值等于最大深度时满，等于 0 时空
    assign full  = (count == DEPTH);
    assign empty = (count == 0);

    // ============================================================
    // 核心读写与计数器更新逻辑 (Core Logic)
    // ============================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            // 异步复位：清空指针、计数器和输出寄存器
            w_ptr <= 0;
            r_ptr <= 0;
            count <= 0;
            dout  <= 0;
            // 注意：通常不需要（也无法在一个周期内）清空整个 mem 数组
        end else begin
            
            // --- 写入逻辑 (Write Logic) ---
            if (wr_en && !full) begin
                mem[w_ptr] <= din; // 将输入数据写入当前写指针指向的地址
                w_ptr <= w_ptr + 1; // 写指针自增。当达到最大值时会自动回绕 (Wrap around) 到 0
            end

            // --- 读取逻辑 (Read Logic) ---
            // 注意：标准的 BRAM 读取有 1 个时钟周期的潜伏期 (Latency)
            if (rd_en && !empty) begin
                dout <= mem[r_ptr]; // 将当前读指针指向的地址数据赋给输出寄存器
                r_ptr <= r_ptr + 1; // 读指针自增。满量程时同样会自动回绕
            end

            // --- 计数器更新逻辑 (Counter Logic) ---
            // 处理同时读写的冲突情况：
            if (wr_en && !full && !(rd_en && !empty))
                // 只写不读：计数器加 1
                count <= count + 1;
            else if (!(wr_en && !full) && (rd_en && !empty))
                // 只读不写：计数器减 1
                count <= count - 1;
            // 如果同时成功读和写，一增一减互相抵消，count 保持不变（省略了 else 逻辑）
        end
    end

endmodule