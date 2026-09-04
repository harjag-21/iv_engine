`timescale 1ns / 1ps

// =========================================================
// Multi-Core IV Engine Array Wrapper (Phase 2 Scaling)
// =========================================================
// Instantiates NUM_ENGINES parallel Implied Volatility cores
// behind a round-robin ingress demux and egress arbiter.
//
// Performance (converged new IV solutions/sec, assuming 3.5 avg NR iterations):
//   NUM_ENGINES = 1 @ 250 MHz ->  71.4 Million ops/sec  (250M pipeline-passes / 3.5)
//   NUM_ENGINES = 4 @ 250 MHz -> 250 Million ops/sec  (AXI bandwidth limit; 4x cores)
//   NUM_ENGINES = 8 @ 250 MHz -> ~500 Million ops/sec (8x cores; limited by 256-bit AXI II=1)
// =========================================================
module iv_multi_engine_top #(
    parameter integer NUM_ENGINES = 4
)(
    input  logic         aclk,
    input  logic         aresetn,

    // -----------------------------------------
    // Top-Level AXI4-Stream Ingress (Market Feed)
    // -----------------------------------------
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,
    input  logic [255:0] s_axis_tdata,
    input  logic         s_axis_tlast,

    // -----------------------------------------
    // Top-Level AXI4-Stream Egress (Volatility Output)
    // -----------------------------------------
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,
    output logic [63:0]  m_axis_tdata,
    output logic         m_axis_tlast
);

    // Internal bus signals for core array
    logic [NUM_ENGINES-1:0]        engine_s_valid;
    logic [NUM_ENGINES-1:0]        engine_s_ready;
    logic [NUM_ENGINES-1:0][255:0] engine_s_data;
    logic [NUM_ENGINES-1:0]        engine_s_last;

    logic [NUM_ENGINES-1:0]        engine_m_valid;
    logic [NUM_ENGINES-1:0]        engine_m_ready;
    logic [NUM_ENGINES-1:0][63:0]  engine_m_data;
    logic [NUM_ENGINES-1:0]        engine_m_last;

    // ---------------------------------------------------------
    // Ingress Round-Robin Distributor (Demux)
    // ---------------------------------------------------------
    logic [$clog2(NUM_ENGINES)-1:0] wr_ptr;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_ptr <= '0;
        end else if (s_axis_tvalid && s_axis_tready) begin
            wr_ptr <= (wr_ptr == NUM_ENGINES - 1) ? '0 : wr_ptr + 1'b1;
        end
    end

    genvar i;
    generate
        for (i = 0; i < NUM_ENGINES; i = i + 1) begin : demux_gen
            assign engine_s_valid[i] = (s_axis_tvalid && (wr_ptr == i[$clog2(NUM_ENGINES)-1:0]));
            assign engine_s_data[i]  = s_axis_tdata;
            assign engine_s_last[i]  = s_axis_tlast;
        end
    endgenerate

    assign s_axis_tready = engine_s_ready[wr_ptr];

    // ---------------------------------------------------------
    // Engine Core Instantiations
    // ---------------------------------------------------------
    generate
        for (i = 0; i < NUM_ENGINES; i = i + 1) begin : core_inst_gen
            iv_axis_wrapper u_engine_core (
                .aclk          (aclk),
                .aresetn       (aresetn),
                .s_axis_tvalid (engine_s_valid[i]),
                .s_axis_tready (engine_s_ready[i]),
                .s_axis_tdata  (engine_s_data[i]),
                .s_axis_tlast  (engine_s_last[i]),
                .m_axis_tvalid (engine_m_valid[i]),
                .m_axis_tready (engine_m_ready[i]),
                .m_axis_tdata  (engine_m_data[i]),
                .m_axis_tlast  (engine_m_last[i])
            );
        end
    endgenerate

    // ---------------------------------------------------------
    // Egress Work-Conserving Arbiter (Mux)
    // ---------------------------------------------------------
    // Scans all engines starting from rd_ptr; selects the first
    // engine with valid data. Prevents deadlock when engines
    // produce results out-of-order.
    // ---------------------------------------------------------
    logic [$clog2(NUM_ENGINES)-1:0] rd_ptr;
    logic [$clog2(NUM_ENGINES)-1:0] active_rd;
    logic                           any_valid;

    // Combinational priority scan: find first valid engine from rd_ptr
    always_comb begin
        active_rd = rd_ptr;
        any_valid = 1'b0;
        for (int j = 0; j < NUM_ENGINES; j++) begin
            automatic logic [$clog2(NUM_ENGINES)-1:0] idx;
            idx = (int'(rd_ptr) + j) % NUM_ENGINES;
            if (!any_valid && engine_m_valid[idx]) begin
                active_rd = idx;
                any_valid = 1'b1;
            end
        end
    end

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rd_ptr <= '0;
        end else if (any_valid && m_axis_tready) begin
            // Advance past the engine we just serviced
            rd_ptr <= (active_rd == NUM_ENGINES - 1) ? '0 : active_rd + 1'b1;
        end
    end

    generate
        for (i = 0; i < NUM_ENGINES; i = i + 1) begin : ready_gen
            assign engine_m_ready[i] = (m_axis_tready && (active_rd == i[$clog2(NUM_ENGINES)-1:0]) && any_valid);
        end
    endgenerate

    assign m_axis_tvalid = any_valid;
    assign m_axis_tdata  = engine_m_data[active_rd];
    assign m_axis_tlast  = engine_m_last[active_rd];

endmodule
