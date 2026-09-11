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

Real-time option implied-volatility inversion requires iterative numerical solving and is challenging to implement under strict latency and FPGA resource constraints. This paper presents a four-core, fully pipelined FPGA accelerator for Black-Scholes implied volatility with concurrent Delta, Vega, and Gamma computation. The architecture combines a Brenner-Subrahmanyam analytical seed with a shared $\sqrt{T}$ datapath, scale-invariant $S/K$ normalization using Q8.24 fixed point, and a zero-BRAM context architecture based on distributed LUTRAM and SRL32 storage. Post-route implementation achieves 400 MOps/s at 100 MHz on an Artix-7 200T and 1.00 GOps/s at 250 MHz on an Alveo U50, using zero BRAM and zero UltraRAM on the latter. DPI-C validation against an IEEE-754 double-precision reference over 10,000 synthetic contracts yields an absolute volatility MAE of $1.57 \times 10^{-4}$ (0.0157 percentage points), with 99.9% of contracts within 1.0 percentage point error. The U50 implementation achieves 0.91-µs cold accelerator ingress-to-egress latency (227 cycles). These results demonstrate a resource-efficient FPGA architecture for low-latency streaming IV and Greeks computation.

---

## 4. Keywords
`FPGA Acceleration`, `High-Frequency Trading`, `Implied Volatility`, `Option Greeks`, `Black-Scholes Model`, `Zero-BRAM Architecture`, `Newton-Raphson Solver`, `Energy Efficiency`

---

## 5. Author Information Checklist
- Author Names, Affiliations, and Email Addresses
- Designate Corresponding Author
- Indicate Student Paper (if applicable)
