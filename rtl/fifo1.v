`timescale 1ns/1ps

module fifo_sync1 #(
    // ============================================================
    // 模块参数定义 (Parameters)
    // ============================================================
    parameter DEPTH       = 4096, // FIFO 深度，用于缓存大量的图像流水线数据
    parameter WIDTH       = 32,   // 数据位宽 (8位暗通道 + 8位R + 8位G + 8位B = 32位)
    parameter PROG_THRESH = 256   // Programmable Threshold (可编程阈值)，用于提前触发 prog_full
)(
    // ============================================================
    // 端口定义 (Ports)
    // ============================================================
    input  wire             clk,       // 系统时钟
    input  wire             rst_n,     // 异步复位，低电平有效
    
    // 写端口
    input  wire             wr_en,     // 写使能
    input  wire [WIDTH-1:0] din,       // 写入的 32-bit 数据
    
    // 读端口
    input  wire             rd_en,     // 读使能
    output reg  [WIDTH-1:0] dout,      // 读出的 32-bit 数据
    
    // 状态标志
    output wire             empty,     // FIFO 空标志，为 1 时不可读
    output wire             full,      // FIFO 满标志，为 1 时不可写
    output wire             prog_full  // FIFO 将满标志 (当余量不足 PROG_THRESH 时拉高，用于流控报忙)
);

    // ============================================================
    // 1. 内存定义 (强制使用 Block RAM)
    // ============================================================
    // 语法原语 (* ram_style = "block" *) 告诉综合工具 (如 Vivado) 强制将此二维数组映射为 BRAM。
    // 【关键】它必须与下方的异步复位逻辑完全剥离开，否则综合工具会报错或妥协使用 LUTRAM。
    (* ram_style = "block" *) reg [WIDTH-1:0] mem [0:DEPTH-1];

    // ============================================================
    // 2. 指针与计数器定义 (Pointers & Counter)
    // ============================================================
    // 使用 $clog2 自动计算位宽。例如 DEPTH=4096 时，$clog2(4096)=12，位宽为 [11:0]
    reg [$clog2(DEPTH)-1:0]   wr_ptr; // 写指针
    reg [$clog2(DEPTH)-1:0]   rd_ptr; // 读指针
    
    // 计数器需要多一位来表示满载状态。例如 DEPTH=4096 时，需要能表示 0~4096，位宽为 [12:0]
    reg [$clog2(DEPTH+1)-1:0] cnt;    // 元素个数计数器

    // ============================================================
    // 3. 内存读写逻辑 (无复位！纯同步！)
    // ============================================================
    // 这是一个标准的双口 RAM 推断模板。纯同步设计，无 rst_n。
    always @(posedge clk) begin
        // 写操作：只要要求写且 FIFO 未满，就将数据写入 RAM
        if (wr_en && !full) begin
            mem[wr_ptr] <= din;
        end
        
        // 读操作：只要要求读且 FIFO 未空，就从 RAM 读出数据。
        // 【注意】这种写法下，Block RAM 会隐含 1 个时钟周期的读出潜伏期 (Read Latency)。
        if (rd_en && !empty) begin
            dout <= mem[rd_ptr];
        end
    end

    // ============================================================
    // 4. 指针与计数控制逻辑 (带异步复位)
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 异步复位时，清零指针和计数器
            wr_ptr <= 0;
            rd_ptr <= 0;
            cnt    <= 0;
            // dout 不在这里复位，因为它直接跟随 RAM 的数据输出端，强行复位会导致 BRAM 推断失败
        end else begin
            
            // --- 写指针更新 ---
            // 成功写入一次，指针加一；到达底部则回绕 (Wrap around) 到 0
            if (wr_en && !full) begin
                wr_ptr <= (wr_ptr == DEPTH - 1) ? 0 : wr_ptr + 1;
            end
            
            // --- 读指针更新 ---
            // 成功读取一次，指针加一；到达底部则回绕到 0
            if (rd_en && !empty) begin
                rd_ptr <= (rd_ptr == DEPTH - 1) ? 0 : rd_ptr + 1;
            end

            // --- 计数器更新 (极致优雅的 Case 写法) ---
            // 拼接 {实际写成功, 实际读成功} 组成 2-bit 状态量进行判断
            case ({wr_en && !full, rd_en && !empty})
                2'b10: cnt <= cnt + 1; // 仅写操作：数量加 1
                2'b01: cnt <= cnt - 1; // 仅读操作：数量减 1
                // 包含 2'b11 (同时读写，数量不变) 和 2'b00 (均未操作，数量不变)
                default: cnt <= cnt;   
            endcase
        end
    end

    // ============================================================
    // 5. 状态输出 (Status Flags)
    // ============================================================
    assign empty     = (cnt == 0);
    assign full      = (cnt == DEPTH);
    
    // 【流控核心】Prog_full 标志：当 FIFO 里的数据量达到或超过 (最大深度 - 安全阈值) 时拉高。
    // 这给前级模块留出了 256 个时钟周期的反应时间来停止发送数据，防止因为流水线惯性导致数据溢出丢失。
    assign prog_full = (cnt >= DEPTH - PROG_THRESH);

endmodule