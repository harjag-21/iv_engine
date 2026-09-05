`timescale 1ns / 1ps

module iv_axis_wrapper (
    input  logic         aclk,
    input  logic         aresetn,

    // -----------------------------------------
    // AXI4-Stream Slave (Input Market Data)
    // -----------------------------------------
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,
    input  logic [255:0] s_axis_tdata,
    input  logic         s_axis_tlast,

    // -----------------------------------------
    // AXI4-Stream Master (Output Volatility & Greeks)
    // -----------------------------------------
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,
    output logic [127:0] m_axis_tdata,
    output logic         m_axis_tlast
);

    // Internal signals to connect to the IV Engine
    logic        iv_valid_in;
    logic [31:0] iv_S_in;
    logic [31:0] iv_K_in;
    logic [31:0] iv_C_in;
    logic [31:0] iv_r_in;
    logic [31:0] iv_T_in;
    logic [5:0]  iv_tid_in;
    logic        iv_fifo_full;
    
    logic               iv_done_valid;
    logic signed [31:0] iv_done_sigma;
    logic [5:0]         iv_done_tid;
    logic signed [31:0] iv_done_delta;
    logic signed [31:0] iv_done_vega;
    logic signed [31:0] iv_done_gamma;

    // -----------------------------------------
    // Unpack the 256-bit AXI Input Stream
    // -----------------------------------------
    assign iv_S_in   = s_axis_tdata[31:0];
    assign iv_K_in   = s_axis_tdata[63:32];
    assign iv_C_in   = s_axis_tdata[95:64];
    assign iv_r_in   = s_axis_tdata[127:96];
    assign iv_T_in   = s_axis_tdata[159:128];
    assign iv_tid_in = s_axis_tdata[165:160]; // 6-bit Transaction ID
    // Bits [255:166] are zero-padded/reserved

    // -----------------------------------------
    // Pack the pipeline output into 128 bits
    // [31:0]   sigma (Q8.24)
    // [63:32]  delta (Q8.24)
    // [95:64]  vega  (Q8.24)
    // [121:96] gamma (Q8.24, 26 bits)
    // [127:122] tid   (6 bits)
    // -----------------------------------------
    wire [127:0] packed_output = {iv_done_tid, iv_done_gamma[25:0], iv_done_vega, iv_done_delta, iv_done_sigma};

    // -----------------------------------------
    // Output FIFO (AXI4-Stream Compliance & Data Loss Prevention)
    // -----------------------------------------
    localparam int FIFO_DEPTH = 64;
    // Force distributed LUTRAM inference (prevents BRAM18 inference that would
    // violate the "zero-BRAM" claim). 64x128b = 8Kbits.
    (* ram_style = "distributed" *) logic [127:0] fifo_mem [0:FIFO_DEPTH-1];
    logic [5:0]  wr_ptr;
    logic [5:0]  rd_ptr;
    logic [6:0]  fifo_count;

    logic [127:0] m_axis_tdata_reg;
    logic         m_axis_tvalid_reg;

    wire out_ready = !m_axis_tvalid_reg || (m_axis_tready && m_axis_tvalid_reg);
    wire fifo_write = iv_done_valid && (fifo_count < FIFO_DEPTH);
    wire fifo_read  = out_ready && (fifo_count > 0);

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_ptr            <= 6'd0;
            rd_ptr            <= 6'd0;
            fifo_count        <= 7'd0;
            m_axis_tvalid_reg <= 1'b0;
            m_axis_tdata_reg  <= 128'd0;
        end else begin
            if (fifo_write) begin
                fifo_mem[wr_ptr] <= packed_output;
                wr_ptr           <= wr_ptr + 6'd1;
            end
            if (fifo_read) begin
                rd_ptr           <= rd_ptr + 6'd1;
            end
            
            case ({fifo_write, fifo_read})
                2'b10: fifo_count <= fifo_count + 7'd1;
                2'b01: fifo_count <= fifo_count - 7'd1;
                default: ;
            endcase

            if (out_ready) begin
                if (fifo_count > 0) begin
                    m_axis_tvalid_reg <= 1'b1;
                    m_axis_tdata_reg  <= fifo_mem[rd_ptr];
                end else begin
                    m_axis_tvalid_reg <= 1'b0;
                end
            end
        end
    end

    assign m_axis_tvalid = m_axis_tvalid_reg;
    assign m_axis_tdata  = m_axis_tdata_reg;
    assign m_axis_tlast  = m_axis_tvalid_reg;

    // Almost-full threshold at 48 entries (matches max in-flight capacity of 60)
    wire fifo_almost_full = (fifo_count >= 7'd48);
    assign s_axis_tready = ~iv_fifo_full & ~fifo_almost_full;
    
    // Fire valid data into the core on valid AXI handshake
    assign iv_valid_in = s_axis_tvalid && s_axis_tready;

    // -----------------------------------------
    // Instantiate the Core Implied Volatility Engine
    // -----------------------------------------
    iv_top u_iv_top (
        .clk            (aclk),
        .rst_n          (aresetn),
        
        .valid_in       (iv_valid_in),
        .S_in           (iv_S_in),
        .K_in           (iv_K_in),
        .C_in           (iv_C_in),
        .r_in           (iv_r_in),
        .T_in           (iv_T_in),
        .tid_in         (iv_tid_in),
        
        .fifo_full      (iv_fifo_full),
        
        .iv_done_valid  (iv_done_valid),
        .iv_done_sigma  (iv_done_sigma),
        .iv_done_tid    (iv_done_tid),
        .iv_done_delta  (iv_done_delta),
        .iv_done_vega   (iv_done_vega),
        .iv_done_gamma  (iv_done_gamma)
    );

endmodule