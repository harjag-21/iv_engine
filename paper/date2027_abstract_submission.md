# DATE 2027 Abstract Submission Package
**Conference**: Design, Automation and Test in Europe (DATE 2027)  
**Submission Portal**: https://softconf.com/date27/conference/  
**Abstract Deadline**: September 13, 2026 (Anywhere on Earth)  
**Full Paper Deadline**: September 20, 2026 (Anywhere on Earth)  

---

## 1. Title

> **A Zero-BRAM FPGA Accelerator for Low-Latency Option Implied Volatility and Delta-Vega-Gamma Greeks**

---

## 2. Topic / Track Selection

In the Softconf submission form, select from:
* **Primary Track**: **Track D (Design, Methods & Tools)**
  * **Sub-track**: **D11 - Reconfigurable and Adaptive Architectures** (or D10: Architecture and Design of Multi-Core and Heterogeneous Systems)
* **Secondary Track**: **Track A (Application Design)**
  * **Sub-track**: **A4 - High-Performance and Emerging Applications**

---

## 3. Abstract (Text for Portal Form, synchronized with paper.tex)

In electronic options markets and high-frequency trading (HFT), real-time pricing and risk hedging demand continuous calculation of implied volatility (IV) and higher-order Greeks ($\Delta, \Gamma, \nu$) under strict low latency and deterministic throughput. Because the Black-Scholes model lacks a closed-form inverse, numerical solvers like Newton-Raphson are computationally intense and prone to divergent oscillation when Vega approaches zero. Software implementations on multi-core CPUs and GPUs suffer from non-deterministic OS scheduling jitter, kernel launch overheads, and prohibitive power consumption in thermal-constrained co-location racks.

This paper presents a fully pipelined, four-core FPGA acceleration engine for real-time implied volatility and Greeks calculation. The architecture introduces three key contributions: (1) a dedicated closed-form Brenner-Subrahmanyam analytical guess generator placing the initial estimate within the local quadratic convergence basin across near-the-money regimes; (2) scale-invariant fixed-point normalization ($\tilde{S} = S/K$) in Q8.24 precision, bounding dynamic range while avoiding costly multi-precision arithmetic; and (3) a zero-BRAM microarchitecture utilizing distributed LUTRAM and SRL32 shift registers for pipeline context storage, completely freeing on-chip block RAMs for network MAC and PCIe DMA infrastructure.

Physical implementation on an AMD Artix-7 200T FPGA (`xc7a200tffg1156-3`) achieves timing closure at 100 MHz, delivering 400.00 MOps/s peak throughput at 4.258 W total power (28.1x higher measured peak throughput and 297x energy efficiency over an edge AVX2 host CPU). On an AMD Alveo U50 card (`xcu50-fsvh2104-2-e`), the 4-core engine closes timing at 250 MHz, scaling throughput to 1.00 GOps/s at 9.56 nJ/op with 0.91 µs cold latency (227 cycles) while consuming strictly zero Block RAMs and zero UltraRAMs. Hardware co-simulation across 10,000 contracts confirms high accuracy with an MAE of 0.0157% volatility and 99.9% of contracts converging within 1.0% error under cycle-deterministic execution.

---

## 4. Keywords
`FPGA Acceleration`, `High-Frequency Trading`, `Implied Volatility`, `Option Greeks`, `Black-Scholes Model`, `Zero-BRAM Architecture`, `Newton-Raphson Solver`, `Energy Efficiency`

---

## 5. Author Information Checklist
- Author Names, Affiliations, and Email Addresses
- Designate Corresponding Author
- Indicate Student Paper (if applicable)
