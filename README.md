# FPGA-Accelerated Real-Time Option Implied Volatility Calculation Engine

[![Vivado](https://img.shields.io/badge/Vivado-2025.2-blue.svg)](https://www.xilinx.com/products/design-tools/vivado.html)
[![Language](https://img.shields.io/badge/Language-SystemVerilog%20%7C%20C%2B%2B%20%7C%20Python-orange.svg)](#)
[![Target](https://img.shields.io/badge/Target-AMD%20Artix--7%20200T-red.svg)](#)
[![Accuracy](https://img.shields.io/badge/MAE-0.0129%25%20(DPI--C)%20%7C%200.1824%25%20(10k)-green.svg)](#)
[![BRAM](https://img.shields.io/badge/BRAM%20Usage-0%20Blocks%20(Zero--BRAM)-brightgreen.svg)](#)
[![Timing](https://img.shields.io/badge/Timing%20Closure-100%25%20PASS-brightgreen.svg)](#)

A fully pipelined, zero-BRAM hardware acceleration engine for calculating European call option **Implied Volatility ($\\sigma$)** using the Black-Scholes model and Newton-Raphson iterative root-finding. Built in SystemVerilog using **Q8.24 fixed-point arithmetic**, the engine operates at **100 MHz / 125 MHz**, achieving a deterministic **126-cycle single-pass pipeline latency** and delivering up to **400 Million options/second** aggregate streaming throughput on a 4-core array.

---

## :rocket: Key Highlights

- **Deterministic Low Latency**: **126 clock cycles (1.008 µs @ 125 MHz / 1.260 µs @ 100 MHz)** single-pass pipeline latency, avoiding CPU OS thread scheduling jitter and GPU PCIe DMA batching delays.
- **Ultra-High Energy Efficiency**: **86,188 kOps/Watt (4.64 W for 4-core array)** - over an **89.8x advantage over high-end CPUs** (Intel i9-14900K) and **9.2x advantage over enterprise GPUs** (NVIDIA RTX 4090).
- **Institutional-Grade Numerical Accuracy**: Hardware-to-software co-simulation against analytical models demonstrates a **Mean Absolute Error (MAE) of 0.000129 (0.0129% vol)** in 64-tick DPI-C co-sim, with **100.0% of contracts within < 1.0% volatility error**. Over a 10,000-option parameter sweep, statistical MAE is **0.1824% (0.001824 vol)**.
- **Robust Hardware Flow Control & Active Scoreboard**: Features an active 64-bit TID scoreboard (	id_busy_mask) preventing context collisions and loopback-priority flow control guaranteeing **zero packet drops** under continuous line-rate streaming.
- **Mathematical Scale Invariance**: Employs Black-Scholes linear price homogeneity ($\\tilde{S}=S/K, \\tilde{K}=1.0, \\tilde{C}=C/K$), ensuring zero fixed-point overflow for real-world asset prices from  to ,000+.
- **Zero Block RAM (Zero-BRAM)**: Uses distributed LUTRAM primitives for context storage, leaving 100% of FPGA on-chip BRAM available for order books and market data caches.
- **100% Timing Closure Across Silicon Grades**: Verified post-route timing closure on Artix-7 (xc7a200tffg1156-2 at 100 MHz, xc7a200tffg1156-3 at 125 MHz, and 4-core parallel array at 100 MHz).

---

## :triangular_ruler: Mathematical Formulation & Hardware Approximations

The Black-Scholes call option price {BS}$ and Vega $\\mathcal{V}$ are defined as:

C_{BS}(S, K, r, T, \\sigma) = S \\cdot N(d_1) - K e^{-rT} N(d_2)

d_1 = \\frac{\\ln(S/K) + \\left(r + \\frac{\\sigma^2}{2}\\right)T}{\\sigma \\sqrt{T}}, \\quad d_2 = d_1 - \\sigma \\sqrt{T}, \\quad \\mathcal{V} = S \\sqrt{T} \\phi(d_1)

Implied volatility $\\sigma^*$ is solved iteratively via Newton-Raphson:

\\sigma_{k+1} = \\sigma_k - \\frac{C_{BS}(\\sigma_k) - C_{market}}{\\mathcal{V}(\\sigma_k)}

### Hardware-Friendly Computations (Q8.24 Fixed-Point)

1. **Natural Logarithm ln(S/K)**: 33-cycle Padé rational approximation:
   `
   ln(S/K) ≈ 2 * (S - K) / (S + K)
   `
   Valid for liquid moneyness .85 \\le S/K \\le 1.15$ ($< 0.22\\%$ error).
2. **Square Root sqrt(T)**: 28-stage digit-by-digit pipelined shift-subtract engine (29 cycles + 4 alignment delay = 33 cycles total, 0 DSPs).
3. **Normal CDF N(x) and PDF phi(x)**: 49-stage Abramowitz & Stegun Horner scheme with an embedded 33-cycle non-restoring divider  = 1 / (1 + p|x|)$ and a 15-stage decomposed polynomial pipeline with symmetry identity logic.
4. **Discount Factor e^(-rT)**: 2nd-order Taylor expansion ^{-rT} \\approx 1 - rT + (rT)^2/2$.

---

## :classical_building: Architecture & Pipeline Budget

`
   ┌───────────────────────────────────────────────────────────┐
   │ 256-bit AXI4-Stream Ingress (S, K, C_market, r, T, TID)   │
   └─────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼
   ┌───────────────────────────────────────────────────────────┐
   │ Ingress Arbiter, Context RAM (RAM64M) & 64-bit TID Scoreboard
   └─────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼
   ┌───────────────────────────────────────────────────────────┐
   │ Stage 0: Input Latch & Padé Formulator (1 cycle)          │
   └──────────────┬─────────────────────────────┬──────────────┘
                  │                             │
                  ▼                             ▼
   ┌───────────────────────────┐  ┌────────────────────────────┐
   │ Stage 1A: Padé Divider    │  │ Stage 1B: iv_sqrt_q824     │
   │ u_ln_divider (33 cycles)  │  │ 29 cyc + 4 align = 33 cyc  │
   └──────────────┬────────────┘  └─────────────┬──────────────┘
                  │                             │
                  └──────────────┬──────────────┘
                                 │
                                 ▼
   ┌───────────────────────────────────────────────────────────┐
   │ Stage 2: d1 Num/Den Decomposed Formulator (4 cycles)      │
   └─────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼
   ┌───────────────────────────────────────────────────────────┐
   │ Stage 3: Pipelined Divider for d1 u_d1_divider (33 cycles)│
   └─────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼
   ┌───────────────────────────────────────────────────────────┐
   │ Stage 4a: Latch d1 and d2 = d1 - sigma * sqrt(T) (1 cycle)│
   └─────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼
   ┌───────────────────────────────────────────────────────────┐
   │ Stage 4b: Dual 49-Stage Horner CDF Engines (49 cycles)    │
   └─────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼
   ┌───────────────────────────────────────────────────────────┐
   │ Stage 5: Black-Scholes Call Price & Vega Evaluator (5 cyc)│
   └─────────────────────────────┬─────────────────────────────┘
                                 │  (Total BS Datapath: 126 cycles)
                                 ▼
   ┌───────────────────────────────────────────────────────────┐
   │ Stage 6: Newton-Raphson Step Divider u_nr_divider (33 cyc)│
   └─────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼
   ┌───────────────────────────────────────────────────────────┐
   │ Stage 7: Sigma Update & Convergence Check (1 cycle)       │
   └─────────────────────────────┬─────────────────────────────┘
                                 │
               ┌─────────────────┴─────────────────┐
               │                                   │
               ▼ (|error| > .01 & iter < 8)        ▼ (|error| <= .01 or iter == 8)
   ┌───────────────────────┐           ┌───────────────────────┐
   │ FSM Loopback Entrance │           │ AXI4-Stream Egress    │
   └───────────────────────┘           └───────────────────────┘
`

### Latency Budget Summary (BS_LATENCY = 126 cycles)

| Pipeline Stage | Latency (Cycles) | Duration @ 125 MHz | Duration @ 100 MHz |
|---|---|---|---|
| Stage 0: Input Latch & Padé Formulation | 1 cycle | 8 ns | 10 ns |
| Stage 1: Padé ln(S/K) & Digit-Recurrence sqrt(T) | 33 cycles | 264 ns | 330 ns |
| Stage 2: d1 Numerator/Denominator Decomposed | 4 cycles | 32 ns | 40 ns |
| Stage 3: d1 Non-Restoring Divider | 33 cycles | 264 ns | 330 ns |
| Stage 4a: Register d1 / d2 = d1 - σ√T | 1 cycle | 8 ns | 10 ns |
| Stage 4b: Dual Abramowitz & Stegun CDF Engines | 49 cycles | 392 ns | 490 ns |
| Stage 5: Black-Scholes Call & Vega Evaluator | 5 cycles | 40 ns | 50 ns |
| **Total Black-Scholes Datapath** | **126 cycles** | **1.008 µs** | **1.260 µs** |
| Newton-Raphson Step Divider | 33 cycles | 264 ns | 330 ns |
| Sigma Update & Convergence Check | 1 cycle | 8 ns | 10 ns |
| **Total Single-Pass NR Iteration** | **160 cycles** | **1.280 µs** | **1.600 µs** |
| **Average End-to-End Convergence (2.5–3.5 iters)** | **400–560 cycles** | **3.20–4.48 µs** | **4.00–5.60 µs** |

---

## :bar_chart: Physical Place-and-Route Implementation Results

Synthesized and fully implemented (routed) using **AMD Vivado 2025.2**:

| Metric | Single-Core Baseline | Single-Core Speed -3 | 4-Core Baseline | 4-Core Speed -3 (Audited) |
|---|:---:|:---:|:---:|:---:|
| **Target Device** | Artix-7 `xc7a200t-2` | Artix-7 `xc7a200t-3` | Artix-7 `xc7a200t-2` | Artix-7 `xc7a200t-3` |
| **Top Module** | `iv_axis_wrapper` | `iv_axis_wrapper` | `iv_multi_engine_top` | `iv_multi_engine_top` |
| **Clock Frequency** | **100.000 MHz** (10.0 ns) | **125.000 MHz** (8.0 ns) | **100.000 MHz** (10.0 ns) | **100.000 MHz** (10.0 ns) |
| **Setup Slack (WNS)** | **+0.658 ns (PASS)** | **+0.144 ns (PASS)** | **+0.016 ns (PASS)** | **+0.005 ns (PASS)** |
| **Total Negative Slack (TNS)** | **0.000 ns** | **0.000 ns** | **0.000 ns** | **0.000 ns** |
| **Hold Slack (WHS)** | **+0.037 ns** | **+0.062 ns** | **+0.027 ns** | **+0.058 ns** |
| **Total Hold Slack (THS)** | **0.000 ns** | **0.000 ns** | **0.000 ns** | **0.000 ns** |
| **Total Slice LUTs** | 26,284 / 134,600 (19.5%) | 26,311 / 134,600 (18.5%) | 105,441 / 134,600 (78.3%) | **106,298 / 133,800 (79.45%)** |
| **Flip-Flops (FFs)** | 34,465 / 269,200 (12.8%) | 34,465 / 269,200 (12.8%) | 137,433 / 269,200 (51.0%) | **129,786 / 267,600 (48.50%)** |
| **DSP48E1 Blocks** | 140 / 740 (18.9%) | 140 / 740 (18.9%) | 560 / 740 (75.7%) | **608 / 740 (82.16%)** |
| **Block RAM (BRAM)** | **0 / 730 (0.0%)** | **0 / 730 (0.0%)** | **0 / 730 (0.0%)** | **0 / 342 (0.00%)** |
| **Total On-Chip Power** | **1.238 W** | **1.520 W** | **4.641 W** | **4.258 W** |
| **Junction Temperature** | 26.8 °C | 27.2 °C | 31.7 °C | 31.2 °C |
| **Streaming Throughput** | **100 MOps/sec** | **125 MOps/sec** | **400 MOps/sec** | **400 MOps/sec** |
| **Energy Efficiency** | **80,775 kOps/Watt** | **82,236 kOps/Watt** | **86,188 kOps/Watt** | **93,940 kOps/Watt** |

---

## :zap: Heterogeneous Benchmark Comparison

| Platform | Implementation | Throughput (Ops/sec) | Power (W) | Energy Efficiency (kOps/W) | Single-Tick Latency |
|---|---|---|---|---|---|
| **Host CPU** (Intel i9-14900K) | 32-Thread OpenMP C++ | 120 × 10⁶ | 125 W | 960 kOps/W | 12.50 µs |
| **Enterprise GPU** (NVIDIA RTX 4090) | CUDA 12.0 Kernel Batch | 4,200 × 10⁶ | 450 W | 9,333 kOps/W | 45.00 µs (Batch DMA) |
| **Proposed 4-Core FPGA (Ours)** | **Custom Q8.24 Multi-Core** | **400 × 10⁶** | **4.26 W** | **93,940 kOps/W** | **1.26 µs** |

---

## :file_folder: Repository Structure

`
.
├── iv_engine.srcs/
│   ├── sources_1/new/             # SystemVerilog RTL Source Files
│   │   ├── iv_top.sv              # Top-level engine with 64-entry context memory & 64-bit TID scoreboard
│   │   ├── iv_bs_datapath.sv      # 126-cycle Black-Scholes pricing & Vega datapath
│   │   ├── iv_bs_initial_guess.sv # 64-cycle Brenner-Subrahmanyam analytical initial guess engine
│   │   ├── iv_norm_cdf.sv         # 49-stage Abramowitz & Stegun Horner CDF core (SRL32-optimized)
│   │   ├── iv_divider_q824.sv     # 33-cycle compact restoring Q8.24 fixed-point divider (0 DSPs)
│   │   ├── iv_sqrt_q824.sv        # 28-stage digit-by-digit square root engine
│   │   ├── iv_arbitration_fsm.sv  # Iterative Newton-Raphson loopback arbitration FSM
│   │   ├── iv_multi_engine_top.sv # 4-core parallel array with work-conserving arbiter
│   │   ├── iv_axis_wrapper.sv     # 128-bit AXI4-Stream egress wrapper ([sigma, delta, vega, gamma, tid])
│   │   ├── iv_cordic_pipeline.sv  # 18-stage hyperbolic CORDIC pipeline (auxiliary mode)
│   │   └── iv_kn_compensator.sv   # CORDIC 1/Kn gain compensation unit
│   ├── sim_1/new/                 # Testbenches & Verification Suites
│   │   ├── tb_bs_golden.sv        # Golden reference accuracy testbench (4/4 PASS)
│   │   ├── tb_normalization.sv    # Scale-invariance verification testbench (4/4 PASS)
│   │   ├── tb_extreme_corners.sv  # Extreme market corner-case verification (5/5 PASS)
│   │   ├── tb_axis_top.sv         # AXI4-Stream packetized verification (5/5 PASS)
│   │   ├── tb_multi_engine_top.sv # Multi-engine parallel throughput testbench (20/20 PASS)
│   │   ├── tb_top.sv              # UVM-style verification testbench
│   │   ├── iv_agent_pkg.sv        # Verification agent package
│   │   ├── iv_env_pkg.sv          # Verification environment package
│   │   ├── iv_seq_pkg.sv          # Verification sequence package
│   │   └── iv_if1.sv              # SystemVerilog Interface definition
│   └── constrs_1/new/
│       └── timing_constraints.xdc # 100/125 MHz clock constraints
├── host/                          # Host PCIe & Software Interface
│   ├── iv_accel_host.cpp          # C++ high-performance host streaming driver
│   ├── iv_accel_host.hpp          # C++ host driver definitions & AXI struct padding
│   └── iv_engine.py               # Python quant trading API for host acceleration
├── dpi_c/                         # Direct Programming Interface (DPI-C)
│   ├── dpi_bs_ref.c               # IEEE-754 double-precision reference model
│   └── tb_xdma_dpi.sv             # DPI-C co-simulation testbench
├── impl_results/                  # Post-Route Physical Implementation Reports
│   ├── artix7/                    # Artix-7 200T single-core baseline (100 MHz, WNS = +0.658 ns)
│   ├── artix7_speed3/             # Artix-7 200T single-core speed-3 (125 MHz, WNS = +0.144 ns)
│   └── artix7_4core/              # Artix-7 200T 4-core parallel array (100 MHz, WNS = +0.016 ns)
├── benchmark_accuracy.py          # 10,000-sample statistical accuracy validation script
├── precision_tradeoff_analysis.py # 5-format numerical precision vs bit-width study
├── run_dpi_sim.bat                # Automated DPI-C co-simulation batch script (64/64 PASS)
├── synth_ooc.tcl                  # Vivado batch-mode OOC synthesis automation script
├── package_ip.tcl                 # Vivado IP packager script
├── thesis_manuscript.md           # Full research paper / thesis manuscript
└── README.md                      # Project documentation
`

---

## :test_tube: Verification & Simulation

All 6 testbenches achieve a **100% PASS** rate:

```bash
# 1. Run Black-Scholes Golden Model Verification (4/4 PASS)
run_tb_bs_golden.bat

# 2. Run Normalization & Scale-Invariance Suite (4/4 PASS)
run_tb_normalization.bat

# 3. Run Extreme Corner-Case Suite (5/5 PASS)
run_tb_extreme_corners.bat

# 4. Run AXI4-Stream Packetized Wrapper Verification (5/5 PASS)
run_tb_axis_top.bat

# 5. Run Multi-Engine Parallel Array Verification (20/20 PASS)
run_tb_multi_engine_top.bat

# 6. Run DPI-C Hardware/Software Co-Simulation (64/64 PASS, MAE=0.0129%)
run_dpi_sim.bat
```

### Run Python Accuracy Benchmark (10,000 Samples)

` ash
python benchmark_accuracy.py
`

Expected output:
`
Mean Absolute Error   : 0.001824 (0.1824% vol)
Root Mean Square Error: 0.016355
50th Percentile Error : 0.000118 (0.0118% vol)
95th Percentile Error : 0.001692 (0.1692% vol)
Options with < 0.1% Err: 94.2%
Options with < 1.0% Err: 97.6%
RESULT: SUCCESS - Meets institutional quantitative standards (< 1.0% MAE)
`

---

## :gear: Running Vivado Physical Implementation & Synthesis

To reproduce the full physical Place-and-Route or out-of-context synthesis:

`ash
# Run 4-Core Physical Place-and-Route (Timing Closure & Power)
vivado -mode batch -source run_impl_artix7_4core.tcl

# Run Out-of-Context Synthesis
vivado -mode batch -source synth_ooc.tcl
`

---

## :scroll: Citation

If you use this work or architecture in your research, please cite:

`ibtex
@article{jaglan2026fpgalv,
  title={FPGA-Accelerated Real-Time Option Implied Volatility Calculation Engine Using Zero-BRAM Pipelined Architecture},
  author={Jaglan, Harshvardhan},
  journal={Department of Electronics and Electrical Communication Engineering, IIT Kharagpur},
  year={2026}
}
`
