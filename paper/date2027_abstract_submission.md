# DATE 2027 Abstract Submission Package
**Conference**: Design, Automation and Test in Europe (DATE 2027)  
**Submission Portal**: https://softconf.com/date27/conference/  
**Abstract Deadline**: September 13, 2026 (Anywhere on Earth)  
**Full Paper Deadline**: September 20, 2026 (Anywhere on Earth)  

---

## 1. Title

> **A 400 MOps/sec Zero-BRAM FPGA Accelerator for Real-Time Option Implied Volatility and Full Greeks**

*Alternative Title*:  
> **FPGA-Accelerated Real-Time Implied Volatility Engine with Zero-BRAM Architecture and Full Greeks at 400 MOps/sec**

---

## 2. Topic / Track Selection

In the Softconf submission form, select from:
* **Primary Track**: **Track D (Design, Methods & Tools)**
  * **Sub-track**: **D11 - Reconfigurable and Adaptive Architectures** (or D10: Architecture and Design of Multi-Core and Heterogeneous Systems)
* **Secondary Track**: **Track A (Application Design)**
  * **Sub-track**: **A4 - High-Performance and Emerging Applications**

---

## 3. Abstract (Text for Portal Form, ~240 words)

In electronic options markets and high-frequency trading (HFT), real-time pricing and risk hedging demand continuous calculation of implied volatility (IV) and higher-order Greeks ($\Delta, \Gamma, \nu$) under strict sub-microsecond latency and deterministic throughput. Because the Black-Scholes model lacks a closed-form inverse, numerical solvers like Newton-Raphson are computationally intense and prone to divergent oscillation when derivative Vega approaches zero. Software implementations on multi-core CPUs and data-center GPUs suffer from non-deterministic operating system scheduling, long kernel launch overheads, and prohibitive power consumption in thermal-constrained co-location racks.

This paper presents a fully pipelined, four-core FPGA acceleration engine for real-time implied volatility and Greeks calculation. The architecture introduces three key contributions: (1) a dedicated closed-form Brenner-Subrahmanyam analytical guess generator providing quadratic Newton-Raphson convergence across near-the-money regimes; (2) scale-invariant fixed-point normalization ($\tilde{S} = S/K$) in Q8.24 precision, preventing dynamic range overflow while avoiding costly multi-precision arithmetic; and (3) an exclusive Zero-BRAM microarchitecture utilizing distributed LUTRAM and SRL32 shift registers for pipeline context storage, completely freeing on-chip block RAMs for network MAC and PCIe DMA infrastructure.

Implemented and physically placed-and-routed on an AMD Xilinx Artix-7 200T FPGA (`xc7a200tffg1156-3`), the 4-core engine achieves timing closure at 100 MHz with positive slack ($WNS = +0.005\text{ ns}$), delivering 400.00 MOps/sec sustained throughput at a deterministic 1.26 $\mu$s latency. Extensive DPI-C co-simulation over 10,000 synthetic option contracts demonstrates institutional-grade accuracy with a Mean Absolute Error of 0.0157% volatility (99.9% of contracts within 1% error). Operating at 4.258 W total power, the engine achieves 93,940 kOps/W—demonstrating a 28.1$\times$ throughput speedup and a 297$\times$ energy efficiency advantage over a 16-thread AVX2 host CPU.

---

## 4. Keywords
`FPGA Acceleration`, `High-Frequency Trading`, `Implied Volatility`, `Option Greeks`, `Black-Scholes Model`, `Zero-BRAM Architecture`, `Newton-Raphson Solver`, `Energy Efficiency`

---

## 5. Author Information Checklist
- Author Names, Affiliations, and Email Addresses
- Designate Corresponding Author
- Indicate Student Paper (if applicable)
