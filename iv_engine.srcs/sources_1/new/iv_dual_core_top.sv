`timescale 1ns / 1ps

// =============================================================================
// Dual-Core IV Engine Array Wrapper (Experiment 4 Spatial Scaling Baseline)
// =============================================================================
// Instantiates exactly 2 parallel Implied Volatility cores behind a 2-way
// round-robin ingress demux and work-conserving egress arbiter.
//
// Target: AMD Artix-7 xc7a200tffg1156-3 @ 100 MHz (10.000 ns)
// Peak Ingress Throughput: 2 cores * 100 MHz = 200 MOps/s
// =============================================================================

module iv_dual_core_top (
    input  logic         aclk,
    input  logic         aresetn,

    // Top-Level AXI4-Stream Ingress (Market Feed)
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,
    input  logic [255:0] s_axis_tdata,
    input  logic         s_axis_tlast,

    // Top-Level AXI4-Stream Egress (Volatility & Greeks Output)
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,
    output logic [127:0] m_axis_tdata,
    output logic         m_axis_tlast
);

    // Instantiate 2-engine core array via parameterized iv_multi_engine_top
    iv_multi_engine_top #(
        .NUM_ENGINES(2)
    ) u_dual_engine_array (
        .aclk          (aclk),
        .aresetn       (aresetn),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tlast  (s_axis_tlast),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tlast  (m_axis_tlast)
    );

endmodule
