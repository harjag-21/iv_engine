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

    // -----------------------------------------
    // AXI4-Stream Master (Output Volatility)
    // -----------------------------------------
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,
    output logic [63:0]  m_axis_tdata
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
    
    logic        iv_done_valid;
    logic [31:0] iv_done_sigma;
    logic [5:0]  iv_done_tid;

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
    // Pack the pipeline output into 64 bits
    // -----------------------------------------
    wire [63:0] packed_output = {26'b0, iv_done_tid, iv_done_sigma};

    // -----------------------------------------
    // Output Skid Buffer (AXI4-Stream Compliance)
    // -----------------------------------------
    // The AXI4-Stream spec requires the master to hold
    // TDATA and TVALID stable until TREADY is asserted.
    // Without a skid buffer, pipeline results are lost
    // when the downstream consumer de-asserts TREADY.
    // -----------------------------------------
    logic        skid_valid;
    logic [63:0] skid_data;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            skid_valid <= 1'b0;
            skid_data  <= '0;
        end else begin
            if (skid_valid) begin
                // Skid buffer occupied — waiting for consumer
                if (m_axis_tready) begin
                    // Consumer accepted the skid data
                    if (iv_done_valid) begin
                        // Simultaneous new pipeline output — refill skid
                        skid_data  <= packed_output;
                        // skid_valid stays 1'b1
                    end else begin
                        skid_valid <= 1'b0;
                    end
                end
                // else: consumer still not ready, hold skid data
            end else begin
                // Skid buffer empty — pass-through mode
                if (iv_done_valid && !m_axis_tready) begin
                    // Pipeline produced but consumer blocked — capture
                    skid_valid <= 1'b1;
                    skid_data  <= packed_output;
                end
            end
        end
    end

    // Output mux: skid buffer takes priority over direct path
    assign m_axis_tvalid = skid_valid ? 1'b1 : iv_done_valid;
    assign m_axis_tdata  = skid_valid ? skid_data : packed_output;

    // -----------------------------------------
    // Handshake Control Logic
    // -----------------------------------------
    // Accept new data if internal FIFO is not full AND
    // skid buffer is not occupied (backpressure propagation)
    assign s_axis_tready = ~iv_fifo_full & ~skid_valid;
    
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
        
        .fifo_full      (iv_fifo_full),
        
        .iv_done_valid  (iv_done_valid),
        .iv_done_sigma  (iv_done_sigma),
        .iv_done_tid    (iv_done_tid)
    );

endmodule