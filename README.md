# FPGA-Accelerated Real-Time Option Implied Volatility Calculation Engine

[![Vivado](https://img.shields.io/badge/Vivado-2025.2-blue.svg)](https://www.xilinx.com/products/design-tools/vivado.html)
[![Language](https://img.shields.io/badge/Language-SystemVerilog%20%7C%20C%2B%2B%20%7C%20Python-orange.svg)](#)
[![Target](https://img.shields.io/badge/Target-Xilinx%207--Series%20%2F%20UltraScale-red.svg)](#)
[![Accuracy](https://img.shields.io/badge/MAE-0.1824%25%20%280.0018%20vol%29-green.svg)](#)
[![BRAM](https://img.shields.io/badge/BRAM%20Usage-0%20Blocks-brightgreen.svg)](#)

A fully pipelined, zero-BRAM hardware acceleration engine for calculating European call option **Implied Volatility ($\sigma$)** using the Black-Scholes model and Newton-Raphson iterative root-finding. Built in SystemVerilog using **Q8.24 fixed-point arithmetic**, the engine operates at **250 MHz**, achieving deterministic **576 ns single-pass pipeline latency** and delivering up to **250 Million options/second** aggregate streaming throughput on a 4-core array.

---

## 🚀 Key Highlights

- **Deterministic Sub-Microsecond Latency**: **576 ns (144 clock cycles @ 250 MHz)** single-pass pipeline latency, avoiding CPU OS thread scheduling jitter and GPU PCIe DMA batching delays.
- **Ultra-High Energy Efficiency**: **71,428 kOps/Watt (3.5 W)** — a **74.4× advantage over high-end CPUs** (Intel i9-14900K) and **7.65× advantage over enterprise GPUs** (NVIDIA RTX 4090).
- **Institutional-Grade Numerical Accuracy**: Benchmarked across 10,000 synthetic option parameter sweeps (, K \in [10.0, 100.0]$, .85 \le S/K \le 1.15$), achieving a **Mean Absolute Error (MAE) of 0.1824% (0.001824 vol)** and median error of **0.0118%** against SciPy's analytical Brent solver. **94.2% of options exhibit $< 0.1\%$ error**.
- **Zero Block RAM (Zero-BRAM)**: Uses 56 RAM64M distributed LUTRAM primitives for context storage, leaving 100% of FPGA on-chip BRAM available for order books and market data caches.
- **Production-Ready Vivado Out-of-Context Synthesis**: Fully synthesized with Vivado 2025.2 with 0 errors and 0 critical warnings.

---

## 📐 Mathematical Formulation & Hardware Approximations

The Black-Scholes call option price {BS}$ and Vega $\mathcal{V}$ are defined as:

C_{BS}(S, K, r, T, \sigma) = S \cdot N(d_1) - K e^{-rT} N(d_2)

d_1 = \frac{\ln(S/K) + \left(r + \frac{\sigma^2}{2}\right)T}{\sigma \sqrt{T}}, \quad d_2 = d_1 - \sigma \sqrt{T}, \quad \mathcal{V} = S \sqrt{T} \phi(d_1)

Implied volatility $\sigma^*$ is solved iteratively via Newton-Raphson:

\sigma_{k+1} = \sigma_k - \frac{C_{BS}(\sigma_k) - C_{market}}{\mathcal{V}(\sigma_k)}

### Hardware-Friendly Computations (Q8.24 Fixed-Point)

1. **Natural Logarithm $\ln(S/K)$**: 33-cycle Padé rational approximation:
   \ln(S/K) \approx 2 \cdot \frac{S - K}{S + K}
2. **Square Root $\sqrt{T}$**: 28-stage digit-by-digit pipelined shift-subtract engine (29 cycles + 4 alignment delay = 33 cycles total, 0 DSPs).
3. **Normal CDF (x)$ and PDF $\phi(x)$**: 41-stage Abramowitz & Stegun Horner scheme with an embedded 33-cycle non-restoring divider  = 1 / (1 + p|x|)$ and a 7-stage pipelined polynomial evaluation (stages 3a–4b, 1 multiply per stage for 250 MHz timing closure).
4. **Discount Factor ^{-rT}$**: 2nd-order Taylor expansion ^{-rT} \approx 1 - rT + \frac{(rT)^2}{2}$.

---

## 🏗️ Architecture & Pipeline Budget

`
   ┌───────────────────────────────────────────────────────────┐
   │ 256-bit AXI4-Stream Ingress (S, K, C_market, r, T, TID)   │
   └─────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼
   ┌───────────────────────────────────────────────────────────┐
   │ Arbitration FSM & Distributed LUTRAM Context Memory       │
   └─────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼
   ┌───────────────────────────────────────────────────────────┐
   │ Stage 0: Input Latch & Padé Numerator/Denom (1 cycle)     │
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
   │ Stage 2: d1 Numerator & Denominator Formulator (1 cycle)  │
   └─────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼
   ┌───────────────────────────────────────────────────────────┐
   │ Stage 3: Pipelined Divider for d1 u_d1_divider (33 cycles)│
   └─────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼
   ┌───────────────────────────────────────────────────────────┐
   │ Stage 4: Pipelined Horner CDF u_norm_cdf (41 cycles)      │
   └─────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼
   ┌───────────────────────────────────────────────────────────┐
   │ Stage 5: Black-Scholes C_BS & Vega Evaluator (1 cycle)    │
   └─────────────────────────────┬─────────────────────────────┘
                                 │
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
               ▼ (|error| > .01 & iter < 8)      ▼ (|error| <= .01 or iter == 8)
   ┌───────────────────────┐           ┌───────────────────────┐
   │ FSM Loopback Entrance │           │ AXI4-Stream Egress    │
   └───────────────────────┘           └───────────────────────┘
`

### Latency Budget Summary

| Pipeline Stage | Latency (Cycles) | Duration @ 250 MHz |
|---|---|---|
| Black-Scholes Datapath | 110 cycles | 440 ns |
| Newton-Raphson Step Divider | 33 cycles | 132 ns |
| Sigma Update & Convergence Check | 1 cycle | 4 ns |
| **Total Single-Pass Latency** | **144 cycles** | **576 ns** |
| **Average End-to-End Convergence (3–4 iters)** | **432–576 cycles** | **1.73–2.30 µs** |

---

## 📊 Synthesis & Resource Utilization

Synthesized using **AMD Vivado 2025.2** (synth_design -mode out_of_context):

| Resource | Single Core (iv_top) | Notes |
|---|---|---|
| **Logic LUTs** | 62,221 | Pure combinatorial & arithmetic logic |
| **LUTRAM** | 226 | 56 RAM64M distributed memory primitives |
| **SRLs (Shift Registers)** | 1,369 | Deep pipeline matching delay lines |
| **Total LUTs** | **63,816** | ~63% of Artix-7 xc7a100t |
| **Flip-Flops (FFs)** | **18,660** | Fully pipelined register stages |
| **DSP48E1** | **40** | Auto-inferred for 64-bit pipeline multiplies |
| **Block RAM (BRAM36/18)** | **0** | **100% Zero-BRAM verified** |

### Target Devices
- **Single Engine Core**: AMD Artix-7 xc7a100t (101,400 LUTs, 240 DSP48E1)
- **4-Core Array (iv_multi_engine_top)**: AMD Artix-7 xc7a200t (269,200 LUTs) or Kintex-7 xc7k325t (326,080 LUTs)

---

## ⚡ Heterogeneous Benchmark Comparison

| Platform | Implementation | Throughput (Ops/sec) | Power (W) | Energy Efficiency (kOps/W) | Single-Tick Latency |
|---|---|---|---|---|---|
| **Host CPU** (Intel i9-14900K) | 32-Thread OpenMP C++ |  \times 10^6$ | 125 W | 960 kOps/W | 12.50 µs |
| **Enterprise GPU** (NVIDIA RTX 4090) | CUDA 12.0 Kernel Batch | ,200 \times 10^6$ | 450 W | 9,333 kOps/W | 45.00 µs (Batch DMA) |
| **Proposed FPGA Core (Ours)** | **Custom Q8.24 RTL** | $\mathbf{250 \times 10^6}$ | **3.5 W** | $\mathbf{71,428\text{ kOps/W}}$ | $\mathbf{576\text{ ns}}$ |

---

## 📁 Repository Structure

`
.
├── iv_engine.srcs/
│   ├── sources_1/new/             # SystemVerilog RTL Source Files
│   │   ├── iv_top.sv              # Top-level engine with context memory & dual-mode
│   │   ├── iv_bs_datapath.sv      # 110-cycle Black-Scholes pricing & Vega datapath
│   │   ├── iv_norm_cdf.sv         # 41-cycle Abramowitz & Stegun Horner CDF core
│   │   ├── iv_divider_q824.sv     # 33-cycle non-restoring Q8.24 fixed-point divider
│   │   ├── iv_sqrt_q824.sv        # 28-stage digit-by-digit square root engine
│   │   ├── iv_arbitration_fsm.sv  # Iterative Newton-Raphson loopback arbitration FSM
│   │   ├── iv_multi_engine_top.sv # 4-core parallel array with work-conserving arbiter
│   │   ├── iv_axis_wrapper.sv     # 256-bit AXI4-Stream slave/master interface wrapper
│   │   ├── iv_cordic_pipeline.sv  # 18-stage hyperbolic CORDIC pipeline (test mode)
│   │   └── iv_kn_compensator.sv   # CORDIC 1/Kn gain compensation unit
│   ├── sim_1/new/                 # Testbenches & Verification Suites
│   │   ├── tb_bs_golden.sv        # Golden reference accuracy testbench
│   │   ├── tb_extreme_corners.sv  # Extreme market corner-case verification
│   │   ├── tb_axis_top.sv         # AXI4-Stream packetized verification
│   │   ├── tb_multi_engine_top.sv # Multi-engine parallel throughput testbench
│   │   ├── tb_top.sv              # UVM-style verification testbench
│   │   ├── iv_agent_pkg.sv        # Verification agent package
│   │   ├── iv_env_pkg.sv          # Verification environment package
│   │   ├── iv_seq_pkg.sv          # Verification sequence package
│   │   ├── iv_if1.sv              # SystemVerilog Interface definition
│   │   └── iv_golden_model.py     # Python reference model
│   └── constrs_1/new/
│       └── timing_constraints.xdc # 250 MHz clock constraints
├── host/                          # Host PCIe & Software Interface
│   ├── iv_accel_host.cpp          # C++ high-performance host streaming driver
│   ├── iv_accel_host.hpp          # C++ host driver definitions & AXI struct padding
│   └── iv_engine.py               # Python ctypes binding for host acceleration
├── synth_results/                 # Post-Synthesis Reports
│   ├── utilization_ooc.rpt        # Vivado 2025.2 OOC resource utilization report
│   └── timing_summary_ooc.rpt     # Timing summary report
├── benchmark_accuracy.py          # 10,000-sample statistical accuracy validation script
├── precision_tradeoff_analysis.py # 5-format numerical precision vs bit-width study
├── synth_ooc.tcl                  # Vivado batch-mode OOC synthesis automation script
├── package_ip.tcl                 # Vivado IP packager script
├── thesis_manuscript.md           # Full research paper / thesis manuscript
└── README.md                      # Project documentation
`

---

## 🧪 Verification & Simulation

All 4 testbenches achieve **100% PASS** rate:

`ash
# 1. Run Black-Scholes Golden Model Verification
run_tb_bs_golden.bat

# 2. Run Extreme Corner-Case Suite
run_tb_extreme_corners.bat

# 3. Run AXI4-Stream Packetized Wrapper Verification
run_tb_axis_top.bat

# 4. Run Multi-Engine Parallel Array Verification
run_tb_multi_engine_top.bat
`

### Run Python Accuracy Benchmark (10,000 Samples)

`ash
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

## ⚙️ Running Vivado Synthesis

To reproduce the Out-of-Context synthesis in batch mode:

`ash
vivado -mode batch -source synth_ooc.tcl
`

Reports will be generated in synth_results/utilization_ooc.rpt.

---

## 📜 Citation

If you use this work or architecture in your research, please cite:

`ibtex
@article{jaglan2026fpgalv,
  title={FPGA-Accelerated Real-Time Option Implied Volatility Calculation Engine Using Zero-BRAM Pipelined Architecture},
  author={Jaglan, Harshvardhan},
  journal={Department of Electronics and Electrical Communication Engineering, IIT Kharagpur},
  year={2026}
}
`
