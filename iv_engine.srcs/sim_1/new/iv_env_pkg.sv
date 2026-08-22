`timescale 1ns / 1ps

package iv_env_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import iv_agent_pkg::*;

    // DPI-C function imports
    import "DPI-C" context function void  init_python_env();
    import "DPI-C" context function void  close_python_env();
    import "DPI-C" context function int   get_golden_iv(int S, int K, int C, int r, int T);

    // =======================================================
    // Scoreboard (with functional coverage)
    // =======================================================
    class iv_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(iv_scoreboard)

        uvm_analysis_imp #(iv_transaction, iv_scoreboard) mon_export;
        int passes = 0;
        int fails  = 0;

        // Tolerance: allow +/- 1 LSB for fixed-point rounding
        localparam int TOLERANCE = 1;

        // ---------------------------------------------------
        // Functional Coverage Model
        // ---------------------------------------------------
        // Tracks which input space regions have been exercised.
        // ---------------------------------------------------
        int cov_mode;
        int cov_x_sign;
        int cov_y_sign;
        int cov_z_sign;
        int cov_result_sign;

        covergroup cordic_cg;
            mode_cp: coverpoint cov_mode {
                bins rotation  = {1};
                bins vectoring = {0};
            }
            x_sign_cp: coverpoint cov_x_sign {
                bins positive = {0};
                bins negative = {1};
            }
            y_sign_cp: coverpoint cov_y_sign {
                bins positive = {0};
                bins negative = {1};
            }
            z_sign_cp: coverpoint cov_z_sign {
                bins positive = {0};
                bins negative = {1};
            }
            result_sign_cp: coverpoint cov_result_sign {
                bins positive = {0};
                bins negative = {1};
            }
            // Cross coverage: mode × input sign combinations
            mode_x_y_cross: cross mode_cp, x_sign_cp, y_sign_cp;
            mode_z_cross:   cross mode_cp, z_sign_cp;
        endgroup

        function new(input string name, input uvm_component parent);
            super.new(name, parent);
            mon_export = new("mon_export", this);
            cordic_cg = new();
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            init_python_env();
            `uvm_info("SCOREBOARD", "Python golden model initialized", UVM_LOW)
        endfunction

        virtual function void final_phase(uvm_phase phase);
            super.final_phase(phase);
            close_python_env();
            `uvm_info("SCOREBOARD", $sformatf("===== FINAL RESULTS: Pass=%0d  Fail=%0d =====", passes, fails), UVM_LOW)
            `uvm_info("COVERAGE", $sformatf("Functional coverage: %.1f%%", cordic_cg.get_coverage()), UVM_LOW)
        endfunction

        virtual function void write(iv_transaction tx);
            int expected;
            int diff;

            // Sample functional coverage
            cov_mode        = tx.r_q8[0];
            cov_x_sign      = tx.S_q16[31];
            cov_y_sign      = tx.K_q16[31];
            cov_z_sign      = tx.C_q16[31];
            cov_result_sign = tx.sigma_out_q16[31];
            cordic_cg.sample();

            // Golden model comparison
            expected = get_golden_iv(tx.S_q16, tx.K_q16, tx.C_q16, tx.r_q8, tx.T_q8);
            diff = (tx.sigma_out_q16 > expected) ? (tx.sigma_out_q16 - expected)
                                                 : (expected - tx.sigma_out_q16);
            if (diff <= TOLERANCE) begin
                passes++;
                `uvm_info("PASS", $sformatf("TID %0d | HW=0x%08h  Golden=0x%08h  mode=%0d",
                    tx.tid_out, tx.sigma_out_q16, expected, tx.r_q8[0]), UVM_MEDIUM)
            end else begin
                fails++;
                `uvm_error("FAIL", $sformatf("TID %0d | HW=0x%08h  Golden=0x%08h  diff=%0d  mode=%0d",
                    tx.tid_out, tx.sigma_out_q16, expected, diff, tx.r_q8[0]))
            end
        endfunction
    endclass

    // =======================================================
    // Environment
    // =======================================================
    class iv_env extends uvm_env;
        `uvm_component_utils(iv_env)

        iv_agent      agt;
        iv_scoreboard scb;

        function new(input string name, input uvm_component parent);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agt = iv_agent::type_id::create("agt", this);
            scb = iv_scoreboard::type_id::create("scb", this);
        endfunction

        virtual function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            agt.mon.mon_ap.connect(scb.mon_export);
        endfunction
    endclass

    // =======================================================
    // SEQUENCE 1: Firehose (100 rotation-mode transactions)
    // =======================================================
    class iv_firehose_seq extends uvm_sequence #(iv_transaction);
        `uvm_object_utils(iv_firehose_seq)

        function new(input string name = "iv_firehose_seq");
            super.new(name);
        endfunction

        virtual task body();
            iv_transaction tx;
            `uvm_info("SEQ", "Starting firehose sequence: 100 rotation transactions", UVM_LOW)
            for (int i = 0; i < 100; i++) begin
                tx = iv_transaction::type_id::create($sformatf("tx_%0d", i));
                start_item(tx);
                if (!tx.randomize())
                    `uvm_fatal("SEQ", "Randomization failed")
                finish_item(tx);
            end
            `uvm_info("SEQ", "Firehose sequence complete", UVM_LOW)
        endtask
    endclass

    // =======================================================
    // SEQUENCE 2: Vectoring Mode (100 vectoring transactions)
    // =======================================================
    class iv_vectoring_seq extends uvm_sequence #(iv_transaction);
        `uvm_object_utils(iv_vectoring_seq)

        function new(input string name = "iv_vectoring_seq");
            super.new(name);
        endfunction

        virtual task body();
            iv_vectoring_transaction tx;
            `uvm_info("SEQ", "Starting vectoring sequence: 100 vectoring transactions", UVM_LOW)
            for (int i = 0; i < 100; i++) begin
                tx = iv_vectoring_transaction::type_id::create($sformatf("vtx_%0d", i));
                start_item(tx);
                if (!tx.randomize())
                    `uvm_fatal("SEQ", "Vectoring randomization failed")
                finish_item(tx);
            end
            `uvm_info("SEQ", "Vectoring sequence complete", UVM_LOW)
        endtask
    endclass

    // =======================================================
    // SEQUENCE 3: Corner-Case Directed Tests
    // =======================================================
    class iv_corner_seq extends uvm_sequence #(iv_transaction);
        `uvm_object_utils(iv_corner_seq)

        function new(input string name = "iv_corner_seq");
            super.new(name);
        endfunction

        virtual task body();
            `uvm_info("SEQ", "Starting corner-case directed sequence", UVM_LOW)

            // Q8.24 constants
            // 1.0 = 16_777_216,  0.5 = 8_388_608,  2.0 = 33_554_432
            // 1.1181 ~= 18_760_000,  1.5 = 25_165_824

            // --- ROTATION MODE CORNER CASES ---

            // TC1: Identity — x=1.0, y=0, z=0 → output = K_n * 1.0
            send_directed(32'sd16_777_216, 32'sd0, 32'sd0, 32'sd1, "ROT: Identity x=1.0");

            // TC2: Max positive z — x=1.0, y=0, z=+1.1
            send_directed(32'sd16_777_216, 32'sd0, 32'sd18_454_938, 32'sd1, "ROT: Max +z=1.1");

            // TC3: Max negative z — x=1.0, y=0, z=-1.1
            send_directed(32'sd16_777_216, 32'sd0, -32'sd18_454_938, 32'sd1, "ROT: Max -z=1.1");

            // TC4: Negative y — x=1.0, y=-0.5, z=0.5
            send_directed(32'sd16_777_216, -32'sd8_388_608, 32'sd8_388_608, 32'sd1, "ROT: Neg y");

            // TC5: Small inputs — x=0.01, y=0.01, z=0.01
            send_directed(32'sd167_772, 32'sd167_772, 32'sd167_772, 32'sd1, "ROT: Small values");

            // TC6: Equal x and y — x=1.0, y=1.0, z=0
            send_directed(32'sd16_777_216, 32'sd16_777_216, 32'sd0, 32'sd1, "ROT: x=y=1.0");

            // --- VECTORING MODE CORNER CASES ---

            // TC7: Vectoring identity — x=1.0, y=0, z=0 → z_out = atanh(0) = 0
            send_directed(32'sd16_777_216, 32'sd0, 32'sd0, 32'sd0, "VEC: Identity y=0");

            // TC8: Vectoring with positive y — x=1.5, y=0.3
            send_directed(32'sd25_165_824, 32'sd5_033_165, 32'sd0, 32'sd0, "VEC: y/x=0.2");

            // TC9: Vectoring with negative y — x=1.5, y=-0.3
            send_directed(32'sd25_165_824, -32'sd5_033_165, 32'sd0, 32'sd0, "VEC: y/x=-0.2");

            // TC10: All zeros (pipeline flush)
            send_directed(32'sd0, 32'sd0, 32'sd0, 32'sd1, "ROT: All zeros");

            `uvm_info("SEQ", "Corner-case sequence complete: 10 directed tests", UVM_LOW)
        endtask

        task send_directed(int s, int k, int c, int r, string label);
            iv_transaction tx;
            tx = iv_transaction::type_id::create("dtx");
            start_item(tx);
            tx.S_q16 = s;
            tx.K_q16 = k;
            tx.C_q16 = c;
            tx.r_q8  = r;
            tx.T_q8  = 32'sd0;
            finish_item(tx);
            `uvm_info("CORNER", $sformatf("Sent: %s | S=0x%08h K=0x%08h C=0x%08h mode=%0d",
                label, s, k, c, r), UVM_MEDIUM)
        endtask
    endclass

    // =======================================================
    // SEQUENCE 4: Mixed Mode (interleaved rotation+vectoring)
    // Tests the mode pipeline fix — ensures in-flight
    // transactions with different modes don't corrupt each other.
    // =======================================================
    class iv_mixed_mode_seq extends uvm_sequence #(iv_transaction);
        `uvm_object_utils(iv_mixed_mode_seq)

        function new(input string name = "iv_mixed_mode_seq");
            super.new(name);
        endfunction

        virtual task body();
            `uvm_info("SEQ", "Starting mixed-mode sequence: 100 interleaved transactions", UVM_LOW)
            for (int i = 0; i < 100; i++) begin
                if (i % 2 == 0) begin
                    // Even: rotation mode
                    iv_transaction tx;
                    tx = iv_transaction::type_id::create($sformatf("rtx_%0d", i));
                    start_item(tx);
                    if (!tx.randomize())
                        `uvm_fatal("SEQ", "Rotation randomization failed")
                    finish_item(tx);
                end else begin
                    // Odd: vectoring mode
                    iv_vectoring_transaction vtx;
                    vtx = iv_vectoring_transaction::type_id::create($sformatf("vtx_%0d", i));
                    start_item(vtx);
                    if (!vtx.randomize())
                        `uvm_fatal("SEQ", "Vectoring randomization failed")
                    finish_item(vtx);
                end
            end
            `uvm_info("SEQ", "Mixed-mode sequence complete", UVM_LOW)
        endtask
    endclass

    // =======================================================
    // TEST 1: Base Test (Rotation Only — backward compatible)
    // =======================================================
    class iv_base_test extends uvm_test;
        `uvm_component_utils(iv_base_test)

        iv_env env;

        function new(input string name, input uvm_component parent);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = iv_env::type_id::create("env", this);
        endfunction

        virtual task run_phase(uvm_phase phase);
            iv_firehose_seq seq;
            phase.raise_objection(this, "iv_base_test running");
            seq = iv_firehose_seq::type_id::create("seq");
            seq.start(env.agt.sqr);
            #200;
            phase.drop_objection(this, "iv_base_test done");
        endtask
    endclass

    // =======================================================
    // TEST 2: Vectoring Mode Test
    // =======================================================
    class iv_vectoring_test extends uvm_test;
        `uvm_component_utils(iv_vectoring_test)

        iv_env env;

        function new(input string name, input uvm_component parent);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = iv_env::type_id::create("env", this);
        endfunction

        virtual task run_phase(uvm_phase phase);
            iv_vectoring_seq seq;
            phase.raise_objection(this, "iv_vectoring_test running");
            seq = iv_vectoring_seq::type_id::create("seq");
            seq.start(env.agt.sqr);
            #200;
            phase.drop_objection(this, "iv_vectoring_test done");
        endtask
    endclass

    // =======================================================
    // TEST 3: Directed Corner-Case Test
    // =======================================================
    class iv_directed_test extends uvm_test;
        `uvm_component_utils(iv_directed_test)

        iv_env env;

        function new(input string name, input uvm_component parent);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = iv_env::type_id::create("env", this);
        endfunction

        virtual task run_phase(uvm_phase phase);
            iv_corner_seq seq;
            phase.raise_objection(this, "iv_directed_test running");
            seq = iv_corner_seq::type_id::create("seq");
            seq.start(env.agt.sqr);
            #200;
            phase.drop_objection(this, "iv_directed_test done");
        endtask
    endclass

    // =======================================================
    // TEST 4: Full Regression (all sequences back-to-back)
    // =======================================================
    class iv_regression_test extends uvm_test;
        `uvm_component_utils(iv_regression_test)

        iv_env env;

        function new(input string name, input uvm_component parent);
            super.new(name, parent);
        endfunction

        virtual function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = iv_env::type_id::create("env", this);
        endfunction

        virtual task run_phase(uvm_phase phase);
            iv_firehose_seq    rot_seq;
            iv_vectoring_seq   vec_seq;
            iv_corner_seq      corner_seq;
            iv_mixed_mode_seq  mixed_seq;

            phase.raise_objection(this, "iv_regression_test running");

            `uvm_info("REGR", "===== Phase 1: Rotation Mode =====", UVM_LOW)
            rot_seq = iv_firehose_seq::type_id::create("rot_seq");
            rot_seq.start(env.agt.sqr);
            #200;

            `uvm_info("REGR", "===== Phase 2: Vectoring Mode =====", UVM_LOW)
            vec_seq = iv_vectoring_seq::type_id::create("vec_seq");
            vec_seq.start(env.agt.sqr);
            #200;

            `uvm_info("REGR", "===== Phase 3: Corner Cases =====", UVM_LOW)
            corner_seq = iv_corner_seq::type_id::create("corner_seq");
            corner_seq.start(env.agt.sqr);
            #200;

            `uvm_info("REGR", "===== Phase 4: Mixed Mode Interleave =====", UVM_LOW)
            mixed_seq = iv_mixed_mode_seq::type_id::create("mixed_seq");
            mixed_seq.start(env.agt.sqr);
            #200;

            `uvm_info("REGR", "===== Full Regression Complete =====", UVM_LOW)
            phase.drop_objection(this, "iv_regression_test done");
        endtask
    endclass

endpackage