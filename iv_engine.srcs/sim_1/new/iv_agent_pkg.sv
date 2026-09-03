`timescale 1ns / 1ps

// =============================================================
// IV Agent Package
// =============================================================
// Contains: transaction, driver, monitor, agent
// Plus vectoring-mode transaction variant and coverage model.
// =============================================================
package iv_agent_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // =======================================================
    // Transaction (Rotation Mode — default)
    // =======================================================
    class iv_transaction extends uvm_sequence_item;
        `uvm_object_utils(iv_transaction)

        rand int S_q16;    // CORDIC x_in  (Q8.24)
        rand int K_q16;    // CORDIC y_in  (Q8.24)
        rand int C_q16;    // CORDIC z_in  (Q8.24)
        rand int r_q8;     // mode: 1=Rotation, 0=Vectoring
        rand int T_q8;     // unused in Phase 1
        rand bit [5:0] tid_in;

        // Output fields (captured by monitor)
        int sigma_out_q16;
        int tid_out;

        // Default constraint: Rotation mode with convergence-safe ranges
        // Marked soft so derived transaction classes can override
        constraint cordic_rotation_c {
            soft S_q16 inside { [32'sd5_000_000 : 32'sd40_000_000] };
            soft K_q16 inside { [32'sd5_000_000 : 32'sd40_000_000] };
            soft C_q16 inside { [-32'sd16_000_000 : 32'sd16_000_000] };
            soft r_q8  == 32'sd1;  // Rotation mode
            soft T_q8  == 32'sd0;
        }

        function new(input string name = "iv_transaction");
            super.new(name);
        endfunction
    endclass

    // =======================================================
    // Vectoring Mode Transaction
    // =======================================================
    // Extends base transaction, applies vectoring-safe constraints: |y| < |x|, z=0
    // =======================================================
    class iv_vectoring_transaction extends iv_transaction;
        `uvm_object_utils(iv_vectoring_transaction)

        constraint cordic_vectoring_c {
            S_q16 inside { [32'sd8_388_608 : 32'sd33_554_432] };   // x: 0.5..2.0, must be positive
            K_q16 inside { [-32'sd6_000_000 : 32'sd6_000_000] };   // |y| < x_min for convergence
            C_q16 == 32'sd0;                                        // z: start at 0 for vectoring
            r_q8  == 32'sd0;                                        // Vectoring mode
            T_q8  == 32'sd0;
        }

        function new(input string name = "iv_vectoring_transaction");
            super.new(name);
        endfunction
    endclass

    // =======================================================
    // Driver
    // =======================================================
    class iv_driver extends uvm_driver #(iv_transaction);
        `uvm_component_utils(iv_driver)

        virtual iv_if1 vif;

        function new(input string name, input uvm_component parent);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual iv_if1)::get(this, "", "vif", vif))
                `uvm_fatal("DRIVER", "Failed to get virtual interface from config_db")
        endfunction

        virtual task run_phase(uvm_phase phase);
            iv_transaction tx;
            
            // Initialize interface signals to zero
            vif.valid_in <= 1'b0;
            vif.S_in     <= 32'd0;
            vif.K_in     <= 32'd0;
            vif.C_in     <= 32'd0;
            vif.r_in     <= 32'd0;
            vif.T_in     <= 32'd0;
            vif.tid_in   <= 6'd0;

            // Wait for reset to deassert before driving transactions
            wait(vif.rst_n === 1'b1);
            @(posedge vif.clk);

            forever begin
                seq_item_port.get_next_item(tx);

                @(posedge vif.clk);
                vif.valid_in <= 1'b1;
                vif.S_in     <= tx.S_q16;
                vif.K_in     <= tx.K_q16;
                vif.C_in     <= tx.C_q16;
                vif.r_in     <= tx.r_q8;
                vif.T_in     <= tx.T_q8;
                vif.tid_in   <= tx.tid_in;

                @(posedge vif.clk);
                vif.valid_in <= 1'b0;

                seq_item_port.item_done();
            end
        endtask
    endclass

    // =======================================================
    // Monitor — captures input & output sides with reset gating
    // =======================================================
    class iv_monitor extends uvm_monitor;
        `uvm_component_utils(iv_monitor)

        virtual iv_if1 vif;
        uvm_analysis_port #(iv_transaction) mon_ap;

        // In-flight tracking: store input transactions by TID
        iv_transaction inflight_q[$];

        function new(input string name, input uvm_component parent);
            super.new(name, parent);
            mon_ap = new("mon_ap", this);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual iv_if1)::get(this, "", "vif", vif))
                `uvm_fatal("MONITOR", "Failed to get virtual interface from config_db")
        endfunction

        virtual task run_phase(uvm_phase phase);
            fork
                capture_inputs();
                capture_outputs();
            join
        endtask

        virtual task capture_inputs();
            iv_transaction tx;
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n === 1'b1 && vif.valid_in === 1'b1) begin
                    tx = iv_transaction::type_id::create("mon_tx");
                    tx.S_q16 = vif.S_in;
                    tx.K_q16 = vif.K_in;
                    tx.C_q16 = vif.C_in;
                    tx.r_q8  = vif.r_in;
                    tx.T_q8  = vif.T_in;
                    inflight_q.push_back(tx);
                    @(negedge vif.clk);
                end
            end
        endtask

        virtual task capture_outputs();
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n === 1'b1 && vif.iv_done_valid === 1'b1) begin
                    if (inflight_q.size() > 0) begin
                        iv_transaction tx = inflight_q.pop_front();
                        tx.sigma_out_q16 = vif.iv_done_sigma;
                        tx.tid_out       = vif.iv_done_tid;
                        mon_ap.write(tx);
                    end else begin
                        `uvm_warning("MONITOR", "Output received but no in-flight transaction to match")
                    end
                end
            end
        endtask
    endclass

    // =======================================================
    // Agent
    // =======================================================
    class iv_agent extends uvm_agent;
        `uvm_component_utils(iv_agent)

        iv_driver              drv;
        iv_monitor             mon;
        uvm_sequencer #(iv_transaction) sqr;

        function new(input string name, input uvm_component parent);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv = iv_driver::type_id::create("drv", this);
            mon = iv_monitor::type_id::create("mon", this);
            sqr = uvm_sequencer #(iv_transaction)::type_id::create("sqr", this);
        endfunction

        virtual function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

endpackage