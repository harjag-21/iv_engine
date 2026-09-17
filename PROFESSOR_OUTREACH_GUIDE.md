# Professor Communication, Outreach & Project Pitch Guide

This document archives all email drafts, strategic talking points, project stage roadmaps, and meeting cheat-sheets for pitching and executing this FPGA research project under academic faculty supervision.

---

## 1. Final Approved Email Drafts

### Option A: The Recommended Short Version (45-Second Read)
*Use this for your initial outreach email. It is concise, respectful, and highlights capability without sounding like a finished product.*

**Subject:** Project Proposal Follow-up: FPGA Hardware Acceleration — [Your Full Name]

Dear Professor [Professor's Last Name],

I hope you are doing well.

I am writing to follow up on our discussion regarding my project topic. I apologize for the delay—over the past two and a half weeks, I was dealing with a severe illness, but I am now fully recovered and back on campus.

Taking your feedback to heart, I spent time investigating whether this topic could be formulated purely as a **digital microarchitecture and custom arithmetic challenge**, rather than a financial modeling problem. Specifically, the core question is: *how to pipeline deeply iterative non-linear root-finding algorithms (involving transcendentals like $\ln x, \sqrt{x}, e^x$, and division) without stalling the datapath or consuming dedicated Block RAMs.*

To confirm this was technically viable, I built an initial proof-of-concept:
* **Pipelined Datapath:** Implemented fixed-point CORDIC, Padé, and Horner polynomial units in SystemVerilog.
* **Zero-BRAM Memory:** Prototyped a distributed LUTRAM/SRL context store that leaves Block RAMs completely free for networking.
* **Initial Feasibility:** Ran preliminary Vivado implementation runs on Artix-7, confirming 100 MHz timing is realistic.

While this confirms basic physical feasibility, **the core architectural research is still ahead**, and I would greatly value your academic guidance on:
1. **Precision vs. Resource Pareto Trade-offs:** Formally analyzing 24-bit vs. 32-bit Q8.24 vs. 48-bit fixed-point scaling.
2. **Loopback Feedback Arbitration:** Resolving contention when variable-iteration contracts re-enter the streaming pipeline.
3. **Cross-Platform Signoff & Benchmarking:** Extending evaluation to 16nm FinFET (Alveo) and comparing against CPU/GPU baselines.

I am more than happy to drive all the RTL coding and experimentation myself, but your mentorship on hardware methodology and academic framing would be invaluable.

Could I drop by for 10 minutes during your office hours (or at a convenient time this Thursday or Friday)? I would love to show you a quick 1-page block diagram and get your thoughts.

Thank you very much for your time and guidance.

Sincerely,  

[Your Name]  
[Your Roll / Student ID Number]  
[Department / Program]

---

### Option B: The Detailed Alternative (If He Asks for More Details)
*Use this if the professor replies asking for an expanded summary before scheduling a meeting.*

**Subject:** Re: Project Proposal Follow-up: FPGA Hardware Acceleration — [Your Full Name]

Dear Professor [Professor's Last Name],

Thank you for your response. To provide more context on the technical scope and research roadmap:

The project tackles real-time inversion of non-linear root-finding problems on FPGAs. In streaming workloads, iterative algorithms like Newton-Raphson are notoriously difficult to pipeline because the loop iteration count is unknown at ingress, and transcendental units have deep latencies (33 to 64 cycles).

The planned research roadmap comprises four milestones:
1. **Algorithmic Modeling & Word-Length Analysis (Completed):** Formulated an analytical guess seeder (Brenner-Subrahmanyam) and evaluated fixed-point dynamic ranges using scale-invariance normalization.
2. **RTL Prototyping & Distributed Memory Design (Completed):** Developed a SystemVerilog prototype mapping in-flight context exclusively to distributed slice logic (LUTRAM/SRLs), verifying that Block RAMs can be 100% spared for network interfaces.
3. **Numerical Stress-Testing & Arbitration Modeling (In Progress):** Evaluating boundary behaviors when option sensitivities approach zero ($\nu \to 0$), refining hardware clamping, and modeling multi-pass feedback scheduling.
4. **Cross-Platform Physical Signoff & Comparative Benchmarking (Planned):** Performing multi-corner timing closure across 28nm planar (Artix-7) and 16nm FinFET (Alveo U50), profiling energy efficiency (nJ/op), and establishing formal speedup baselines against multi-threaded AVX2 host processors.

I would appreciate 10 minutes of your time to review the 1-page block diagram and confirm whether this structure satisfies your project and academic expectations.

Best regards,  
[Your Name]

---

## 2. Strategic Narrative: The 4-Stage Roadmap

When presenting the project to the professor or department review panel, use this breakdown:

| Stage | Status | What Has Been Accomplished / What Remains |
| :--- | :---: | :--- |
| **Stage 1: Algorithmic & Datapath Modeling** | **Completed** | Fixed-point Q8.24 selection, Padé [1/1] log, Horner 5th-order normal CDF, Hyperbolic CORDIC for exponentials. |
| **Stage 2: RTL Prototyping & Baseline Timing** | **Completed** | Full SystemVerilog RTL, Zero-BRAM context memory, Artix-7 100 MHz timing feasibility verified. |
| **Stage 3: Advanced Verification & Error Profiling** | **In Progress** | 10,000-contract DPI-C co-sim, SPX market data replay, wing boundary clamping, error-budget analysis. |
| **Stage 4: Cross-Platform Signoff & Benchmarking** | **Open / Under Mentorship** | 16nm Alveo U50 scaling (250 MHz), multi-threaded AVX2 CPU benchmarking, conference manuscript drafting. |

---

## 3. Meeting Cheat-Sheet: Answers in Your Back Pocket

If the professor asks challenging technical questions during your meeting, here are your exact, data-backed answers:

### Q1: "Why did you choose 32-bit Q8.24 fixed-point instead of standard floating point (FP32) or 64-bit?"
> **Answer:** *"We conducted a Pareto trade-off study across 5,000 contracts: A narrower 24-bit (Q6.18) format failed with 44.6% volatility error due to severe underflow when Vega drops near zero. A wider 48-bit (Q12.36) format doubled slice LUT usage (from 1,711 to 3,240 LUTs) and dropped maximum clock frequency from 250 MHz to 185 MHz without yielding any accuracy gain under the $0.01 price threshold. Single-precision float (FP32) required 2.8x higher logic density and incurred variable latency. 32-bit Q8.24 was mathematically proven as the exact Pareto-optimal point."*

### Q2: "How does your loopback work without stalling the pipeline or causing deadlock?"
> **Answer:** *"We implemented an active 64-bit Transaction ID (TID) scoreboard and an in-flight counter per core. Ingress asserts backpressure when active contracts reach 60 out of 64 slots, ensuring at least 4 headroom slots. Loopback contracts have strict priority over new ingress and retain their pre-allocated context slot. Because loopbacks complete asynchronously, retiring results are matched via their 6-bit TID tag, eliminating the need for a hardware Reorder Buffer (ROB)."*

### Q3: "Why is Zero-BRAM so important? What's wrong with using Block RAM?"
> **Answer:** *"In high-frequency trading (HFT) and fintech SmartNICs, Block RAMs are severely constrained because they are monopolized by 10GbE/100GbE MAC and PHY ring buffers, PCIe DMA descriptors, and order book depth tracking. By mapping all context storage to distributed LUTRAM and SRL32s, our accelerator consumes strictly 0 BRAM and 0 URAM, leaving 100% of dedicated block memory free for the networking subsystems."*

### Q4: "What happens if a stock or index trades above $255, since Q8.24 only has 8 integer bits?"
> **Answer:** *"We exploit Black-Scholes linear homogeneity (scale invariance): C(S, K, T, r, sigma) = K * C(S/K, 1.0, T, r, sigma). At ingress, inputs are pre-normalized by dividing by Strike K. This bounds normalized spot to approximately 1.0, keeping all values safely within the compact Q8.24 range without widening multipliers or losing precision, even for $7,500+ S&P 500 contracts."*

### Q5: "If the prototype is working, what do you need me to supervise?"
> **Answer:** *"I want to make sure this meets rigorous academic research standards rather than just being an engineering build. Specifically, I need your mentorship on: (1) formal hardware-vs-software baseline methodology, (2) analyzing routing congestion and multi-corner timing closure under high device density, and (3) structuring the technical contributions for a competitive publication or thesis defense."*

---

## 4. Post-Email Follow-Up Strategies

### If He Agrees to Meet:
Reply promptly with:
> *"Thank you, Professor [Last Name]. I will see you on [Day] at [Time] in your office. I will bring a 1-page summary and microarchitecture block diagram so we can quickly review the roadmap. Looking forward to our discussion."*

### If He Has Not Replied in 4–5 Business Days:
Send a polite bump:
> *"Dear Professor [Last Name], I hope you are having a good week. I just wanted to gently follow up on my email below regarding the FPGA accelerator project proposal. I would love to drop by briefly during your office hours if you have 5–10 minutes. Thank you!"*
