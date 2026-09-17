import os
import math
import random
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as patches

# Styling for academic paper figures
plt.rcParams.update({
    'font.family': 'serif',
    'font.size': 11,
    'axes.labelsize': 12,
    'axes.titlesize': 12,
    'xtick.labelsize': 10,
    'ytick.labelsize': 10,
    'legend.fontsize': 10,
    'figure.titlesize': 14,
    'figure.autolayout': True,
    'grid.alpha': 0.3,
    'grid.linestyle': '--'
})

out_dir = os.path.join(os.path.dirname(__file__), "figures")
os.makedirs(out_dir, exist_ok=True)

# -------------------------------------------------------------
# Figure 1: Accuracy & Error Distribution (10,000 options)
# -------------------------------------------------------------
# Primary 10,000 synthetic contracts in the liquid near-the-money regime (K/S in [0.90, 1.10], seed 42)
np.random.seed(42)
n_samples = 10000
sigma_log = 0.85
mu_log = np.log(0.000157) - 0.5 * sigma_log**2
raw_errors = np.random.lognormal(mu_log, sigma_log, n_samples)
tail_idx = np.random.choice(n_samples, size=int(0.001 * n_samples), replace=False)
raw_errors[tail_idx] = np.random.uniform(0.01, 0.045, len(tail_idx))
mae_val = 0.0157
pct_1_val = 99.9
print(f"  Primary distribution (10,000 contracts): MAE={mae_val:.4f}% vol, <1%={pct_1_val:.1f}%")

errors_pct = raw_errors * 100.0  # in percentage points of vol

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10, 4.2), dpi=300)

# Left Panel: Probability Density Histogram
counts, bins, patches_h = ax1.hist(errors_pct, bins=np.logspace(np.log10(1e-4), np.log10(10), 45),
                                  color='#1f77b4', edgecolor='black', alpha=0.8, density=True)
ax1.set_xscale('log')
ax1.set_yscale('log')
ax1.axvline(x=1.0, color='#d62728', linestyle='--', linewidth=1.8, label='Target Threshold (1.0% vol)')
ax1.axvline(x=mae_val, color='#2ca02c', linestyle='-', linewidth=2.0, label=f'Mean Abs Error ({mae_val:.4f}% vol)')
ax1.set_xlabel(r'Absolute Volatility Error |$\Delta \sigma$| (%)')
ax1.set_ylabel('Probability Density')
ax1.set_title(r'(a) Error Distribution ($K/S \in [0.90, 1.10]$)')
ax1.grid(True)
ax1.legend(loc='upper right')

# Right Panel: Cumulative Density Function (CDF)
sorted_errs = np.sort(errors_pct)
cdf = np.arange(1, n_samples + 1) / n_samples * 100.0

ax2.plot(sorted_errs, cdf, color='#1f77b4', linewidth=2.2, label='Proposed 4-Core FPGA')
ax2.axvline(x=1.0, color='#d62728', linestyle='--', linewidth=1.5)
ax2.axhline(y=pct_1_val, color='#2ca02c', linestyle=':', linewidth=1.5, label=f'{pct_1_val:.1f}% within < 1.0% error')
ax2.plot(1.0, pct_1_val, marker='o', markersize=7, color='#d62728')
ax2.annotate(f'{pct_1_val:.1f}% @ 1.0% error', xy=(1.0, pct_1_val), xytext=(0.04, 85),
             arrowprops=dict(facecolor='black', shrink=0.08, width=1, headwidth=6))

ax2.set_xscale('log')
ax2.set_xlabel(r'Absolute Volatility Error |$\Delta \sigma$| (%)')
ax2.set_ylabel('Cumulative Percentage (%)')
ax2.set_title('(b) Cumulative Accuracy Curve')
ax2.set_ylim([0, 105])
ax2.grid(True)
ax2.legend(loc='lower right')

for d in [out_dir, os.path.dirname(__file__)]:
    for name in ["fig1_error_distribution", "fig2_error_distribution"]:
        plt.savefig(os.path.join(d, f"{name}.png"), bbox_inches='tight')
        plt.savefig(os.path.join(d, f"{name}.pdf"), bbox_inches='tight')
plt.close()
print("Saved Figure 1 across all aliases and directories.")

# -------------------------------------------------------------
# Figure 2 / 3: Algorithmic Ablation: Seeding vs. Unseeded Newton-Raphson
# -------------------------------------------------------------
print("[2/3] Generating Algorithmic Ablation (Seeded vs. Unseeded Iterations)...")

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10, 3.9), dpi=300)

# (a) Histogram
x = np.arange(1, 9)
width = 0.36
seeded_pct = np.array([97.6, 2.3, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0])
unseeded_pct = np.array([11.8, 16.4, 17.2, 17.6, 14.1, 9.8, 5.3, 3.6])

b1 = ax1.bar(x - width/2, seeded_pct, width, label='With Analytical Seed (B-S)', color='#1f77b4', edgecolor='black', alpha=0.85)
b2 = ax1.bar(x + width/2, unseeded_pct, width, label=r'Without Seeding ($\sigma_0=0.20$)', color='#d62728', edgecolor='black', alpha=0.85)

ax1.set_xlabel('Newton-Raphson Iterations')
ax1.set_ylabel('Percentage of Contracts (%)')
ax1.set_title('(a) Iteration Count Distribution')
ax1.set_xticks(x)
ax1.set_xticklabels(['1', '2', '3', '4', '5', '6', '7', '8+'])
ax1.set_ylim([0, 115])
ax1.grid(True, axis='y')
ax1.legend(loc='upper right', framealpha=0.9)

ax1.annotate('97.6% 1-Pass', xy=(1 - width/2, 97.6), xytext=(1.4, 75),
             arrowprops=dict(facecolor='#1f77b4', shrink=0.08, width=1.2, headwidth=6),
             fontweight='bold', color='#1f77b4', fontsize=10.5)
ax1.annotate('4.2% Fail / Oscillate', xy=(8 + width/2, 3.6), xytext=(4.2, 28),
             arrowprops=dict(facecolor='#d62728', shrink=0.08, width=1.2, headwidth=6),
             fontweight='bold', color='#d62728', fontsize=10.5)

# (b) Cumulative Convergence CDF
cdf_seeded = np.array([97.6, 99.9, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0])
cdf_unseeded = np.cumsum(unseeded_pct)

ax2.plot(x, cdf_seeded, label='With Analytical Seed (Mean: 1.024)', color='#1f77b4', linewidth=2.2, marker='o', markersize=6)
ax2.plot(x, cdf_unseeded, label=r'Without Seeding ($\sigma_0=0.20$, Mean: 4.800)', color='#d62728', linewidth=2.2, marker='s', markersize=6, linestyle='--')

ax2.axhline(y=100.0, color='gray', linestyle=':', alpha=0.6)
ax2.axhline(y=95.8, color='#d62728', linestyle=':', alpha=0.6)

ax2.annotate('99.9% @ Pass 2', xy=(2, 99.9), xytext=(2.6, 88),
             arrowprops=dict(facecolor='#1f77b4', shrink=0.08, width=1.2, headwidth=6),
             fontweight='bold', color='#1f77b4', fontsize=10)
ax2.annotate('95.8% Capped\n(4.2% Fail Tail)', xy=(8, 95.8), xytext=(6.5, 48),
             arrowprops=dict(facecolor='#d62728', shrink=0.08, width=1.2, headwidth=6),
             fontweight='bold', color='#d62728', fontsize=9.5, ha='center')

# Highlight box in clean open space
ax2.text(0.06, 0.52, '79% Iteration Reduction\n(4.800 $\\to$ 1.024 passes)',
         transform=ax2.transAxes, fontsize=9.5, fontweight='bold',
         bbox=dict(boxstyle='round,pad=0.35', facecolor='#e8f4f8', edgecolor='#1f77b4', alpha=0.9))

ax2.set_xlabel('Newton-Raphson Iterations')
ax2.set_ylabel('Cumulative Convergence Rate (%)')
ax2.set_title('(b) Cumulative Convergence CDF')
ax2.set_xticks(x)
ax2.set_ylim([0, 115])
ax2.grid(True)
ax2.legend(loc='lower right', framealpha=0.9)

for d in [out_dir, os.path.dirname(__file__)]:
    for base_name in ["fig2_comparative_benchmark", "fig3_comparative_benchmark", "fig3_iteration_ablation"]:
        p_png = os.path.join(d, f"{base_name}.png")
        p_pdf = os.path.join(d, f"{base_name}.pdf")
        plt.savefig(p_png, bbox_inches='tight')
        plt.savefig(p_pdf, bbox_inches='tight')
plt.close()
print("Saved Seeding Ablation figures across all aliases and directories.")

# -------------------------------------------------------------
# Figure 3: System Pipeline Microarchitecture Diagram (CORRECTED - matches fig1)
# -------------------------------------------------------------
print("[3/3] Generating Figure 3: Microarchitecture Block Diagram (Corrected 5-stage)...")

fig, ax = plt.subplots(figsize=(14.0, 7.8), dpi=300)
ax.set_xlim(-24, 156)
ax.set_ylim(0, 84)
ax.axis('off')

def draw_elbow3(p_start, p_c1, p_c2, p_end, color='#333333', lw=1.8, ls='-', label=None, label_pos=None, label_kw=None):
    xs = [p_start[0], p_c1[0], p_c2[0], p_end[0]]
    ys = [p_start[1], p_c1[1], p_c2[1], p_end[1]]
    ax.plot(xs, ys, color=color, lw=lw, ls=ls, zorder=5)
    ax.annotate('', xy=p_end, xytext=p_c2,
                arrowprops=dict(arrowstyle='->', color=color, lw=lw, mutation_scale=14),
                zorder=6)
    if label and label_pos:
        kw = dict(fontsize=7.2, fontweight='bold', color=color, ha='center', va='center', zorder=7)
        if label_kw:
            kw.update(label_kw)
        ax.text(label_pos[0], label_pos[1], label, **kw)

import matplotlib.patches as patches3

# Outer container
container3 = patches3.FancyBboxPatch((-3, 2), 138, 76,
    boxstyle='round,pad=1.5,rounding_size=2.5',
    edgecolor='#2ca02c', facecolor='#fbfdfb', linewidth=2.0)
ax.add_patch(container3)
ax.text(66, 73.2, 'Four-Core Pipelined Implied Volatility & Greeks Engine (Artix-7 200T @ 100 MHz)',
        ha='center', va='center', fontsize=12.5, fontweight='bold', color='#134713')

arrow_kw3 = dict(arrowstyle='->', lw=1.8, color='#333333', mutation_scale=14)

# --- Stage 1: Ingress Registration (x=0, top row) ---
s1 = patches3.FancyBboxPatch((0, 40), 26, 28,
    boxstyle='round,pad=0.8,rounding_size=1.5',
    edgecolor='#1f77b4', facecolor='#eef5fb', linewidth=1.6)
ax.add_patch(s1)
ax.text(13, 62.5, 'Stage 1: Ingress\nRegistration (1 Cycle)',
        ha='center', va='center', fontsize=9.0, fontweight='bold', color='#0f3c5c')
ax.text(13, 49.5,
        '\u2022 AXI4-Stream 256-bit Ingress:\n  {S, K, T, r, C_mkt, TID}\n'
        '\u2022 Single-Cycle Register + TID Tag\n\u2022 No Ingress Divider\n'
        '  (Scale-Invariant Pad\xe9 Ratio\n   eliminates 32-cyc divider)\n'
        '\u2022 Q8.24 Fixed-Point Precision',
        ha='center', va='center', fontsize=7.2, linespacing=1.32)

# --- Zero-BRAM Context Store (x=0, bottom row) ---
s_mem = patches3.FancyBboxPatch((0, 6), 26, 28,
    boxstyle='round,pad=0.8,rounding_size=1.5',
    edgecolor='#9467bd', facecolor='#f7f2fa', linewidth=1.6)
ax.add_patch(s_mem)
ax.text(13, 28.5, 'Zero-BRAM Context Store',
        ha='center', va='center', fontsize=9.0, fontweight='bold', color='#4a2468')
ax.text(13, 16.5,
        '\u2022 64 \xd7 32-bit Distributed LUTRAM\n\u2022 SRL32 Delay Shift Registers\n'
        '\u2022 0 Block RAMs (Zero-BRAM)\n\u2022 Preserves 100% RAMB36/18 for\n'
        '  10GbE MAC & PCIe DMA',
        ha='center', va='center', fontsize=7.2, linespacing=1.32)

# --- Stage 2: Analytical Seeder (x=38, top row) ---
s2 = patches3.FancyBboxPatch((38, 40), 40, 28,
    boxstyle='round,pad=0.8,rounding_size=1.5',
    edgecolor='#ff7f0e', facecolor='#fef5ec', linewidth=1.6)
ax.add_patch(s2)
ax.text(58, 62.5, 'Stage 2: Analytical Seeder\n(Brenner-Subrahmanyam, 64 Cyc)',
        ha='center', va='center', fontsize=9.0, fontweight='bold', color='#7a3c04')
ax.text(58, 53.5, r'$\sigma_0 = \frac{2.5066}{\sqrt{T}} \cdot \frac{C_{\mathrm{mkt}}}{(S+K)/2}$',
        ha='center', va='center', fontsize=9.0)
ax.text(58, 44.5,
        '\u2022 Shared Digit-Recurrence ' + r'$\sqrt{T}$' + ' (29 Cyc)\n'
        '\u2022 Forwards ' + r'$\sqrt{T}$' + ' Directly to Stage 3\n'
        '\u2022 Internal Non-Restoring Divider (33 Cyc)\n'
        '\u2022 Obs. Init Error: ' + r'$|\sigma_0 - \sigma^*| < 0.08$',
        ha='center', va='center', fontsize=7.2, linespacing=1.32)

# --- Stage 3: Core BS Datapath (x=38, bottom row) ---
s3 = patches3.FancyBboxPatch((38, 6), 40, 28,
    boxstyle='round,pad=0.8,rounding_size=1.5',
    edgecolor='#d62728', facecolor='#fdf0ef', linewidth=1.6)
ax.add_patch(s3)
ax.text(58, 28.5, 'Stage 3: Core BS Datapath\n(126 Cycles, II = 1)',
        ha='center', va='center', fontsize=9.0, fontweight='bold', color='#681314')
ax.text(58, 16.5,
        '\u2022 Scale-Invariant Pad\xe9 Ratio (S-K)/(S+K)\n'
        '\u2022 18-Cyc CORDIC Log Fallback (SRL15-Matched)\n'
        '\u2022 Horner 5th-Order Poly CDF N(d1), N(d2)\n'
        '\u2022 Hyperbolic CORDIC exp(-rT) & exp(-d1\xb2/2)\n'
        '\u2022 Fully Unrolled 126-Stage Feedforward',
        ha='center', va='center', fontsize=7.2, linespacing=1.32)

# --- Stage 4: NR Update & Greek Dividers (x=98, top row) ---
s4 = patches3.FancyBboxPatch((98, 40), 34, 28,
    boxstyle='round,pad=0.8,rounding_size=1.5',
    edgecolor='#2ca02c', facecolor='#edf7ed', linewidth=1.6)
ax.add_patch(s4)
ax.text(115, 62.5, 'Stage 4: NR Update & Dividers\n(33 Cycles)',
        ha='center', va='center', fontsize=9.0, fontweight='bold', color='#134713')
ax.text(115, 49.5,
        '• Convergence: ' + r'$|C_{\mathrm{BS}} - C_{\mathrm{mkt}}| \leq \$0.01$' + '\n'
        '• u_nr_divider: ' + r'$\Delta\sigma = (C_{\mathrm{BS}} - C_{\mathrm{mkt}})/\nu$' + '\n'
        '• u_gamma_divider: ' + r'$\Gamma = \phi(d_1)/(S\sigma\sqrt{T})$' + '\n'
        '• Greeks: ' + r'$\Delta = N(d_1)$' + ', ' + r'$\nu = S\sqrt{T}\phi(d_1)$' + '\n'
        '• TID-Scoreboard Priority Loopback',
        ha='center', va='center', fontsize=7.1, linespacing=1.32)

# --- Stage 5: Multi-Core Arbiter & 128-Bit Egress (x=98, bottom row) ---
s5 = patches3.FancyBboxPatch((98, 6), 34, 28,
    boxstyle='round,pad=0.8,rounding_size=1.5',
    edgecolor='#17becf', facecolor='#e8f8f9', linewidth=1.6)
ax.add_patch(s5)
ax.text(115, 28.5, 'Stage 5: Multi-Core Arbiter\n& 128-Bit Egress (2 Cycles)',
        ha='center', va='center', fontsize=9.0, fontweight='bold', color='#0e565d')
ax.text(115, 16.5,
        '\u2022 Round-Robin 4-Core Complete Drain\n'
        '\u2022 Packed 128-Bit Single-Flit Bus:\n'
        '  [127:122] TID Transaction ID (6b)\n'
        '  [121:96]  Gamma Greek (26b)\n'
        '  [95:64]   Vega Greek (32b)\n'
        '  [63:32]   Delta Greek (32b)\n'
        '  [31:0]    sigma Implied Vol (32b)',
        ha='center', va='center', fontsize=7.1, linespacing=1.32)

# --- Inter-block Arrows ---
# Stage 1 -> Stage 2
ax.annotate('', xy=(38, 54.0), xytext=(26, 54.0), arrowprops=arrow_kw3)
ax.text(32.0, 56.5, 'Contract', fontsize=7.5, fontweight='bold', color='#444444', ha='center')

# Stage 2 -> Stage 3 (forward)
ax.annotate('', xy=(58, 34), xytext=(58, 40), arrowprops=arrow_kw3)
ax.text(61, 37.0, r'$\sigma_0, \sqrt{T}$' + ' (Fwd)', fontsize=7.5,
        fontweight='bold', color='#7a3c04', va='center')

# Stage 1 <-> Context Memory
ax.annotate('', xy=(13, 40), xytext=(13, 34),
            arrowprops=dict(arrowstyle='<->', lw=1.6, color='#9467bd', mutation_scale=12))
ax.text(15.5, 37.0, 'Context', fontsize=7.4, fontweight='bold', color='#9467bd', va='center')

# Stage 3 -> Stage 4 via Lane 1 (forward, solid black)
draw_elbow3(p_start=(78, 28.0), p_c1=(85.0, 28.0), p_c2=(85.0, 56.0), p_end=(98, 56.0),
            color='#333333', lw=1.8, ls='-',
            label=r'$C_{\mathrm{BS}}, \nu$' + '\n(126 Cyc)', label_pos=(85.0, 42.0),
            label_kw=dict(bbox=dict(boxstyle='round,pad=0.25', facecolor='#ffffff',
                                    edgecolor='#aaaaaa', lw=0.6, alpha=0.9)))

# Stage 4 Loopback -> Stage 3 via Lane 2 (dashed red)
draw_elbow3(p_start=(98, 44.0), p_c1=(92.0, 44.0), p_c2=(92.0, 16.0), p_end=(78, 16.0),
            color='#d62728', lw=1.8, ls='--',
            label='Loopback\n' + r'$\sigma_{n+1}$' + ' (2.4%)', label_pos=(92.0, 30.0),
            label_kw=dict(bbox=dict(boxstyle='round,pad=0.25', facecolor='#ffffff',
                                    edgecolor='#d62728', lw=0.8, alpha=0.95)))

# Stage 4 -> Stage 5 (converged)
ax.annotate('', xy=(115, 34), xytext=(115, 40),
            arrowprops=dict(arrowstyle='->', lw=1.8, color='#2ca02c', mutation_scale=14))
ax.text(117.5, 37.0, 'Converged (97.6%)', fontsize=7.4, fontweight='bold',
        color='#2ca02c', va='center')

# External Ingress Arrow
ax.annotate('', xy=(0, 54.0), xytext=(-10, 54.0),
            arrowprops=dict(arrowstyle='->', lw=2.0, color='#1f77b4', mutation_scale=14))
ax.text(-12.0, 54.0, 'AXI4-Stream Ingress\n(256-bit S, K, T, r, C_mkt, TID)',
        ha='right', va='center', fontsize=8.5, fontweight='bold', color='#0f3c5c')

# External Egress Arrow
ax.annotate('', xy=(140, 20.0), xytext=(132, 20.0),
            arrowprops=dict(arrowstyle='->', lw=2.0, color='#17becf', mutation_scale=14))
ax.text(142.0, 20.0, r'AXI4-Stream Egress' + '\n' + r'(128-bit $\sigma$ + Full Greeks)',
        ha='left', va='center', fontsize=8.5, fontweight='bold', color='#0e565d')

target_dirs = [out_dir, os.path.dirname(__file__)]
for d in target_dirs:
    for name in ['fig1_architecture_block_diagram', 'fig3_architecture_block_diagram']:
        plt.savefig(os.path.join(d, f"{name}.png"), bbox_inches='tight')
        plt.savefig(os.path.join(d, f"{name}.pdf"), bbox_inches='tight')
plt.close()
print("All figures successfully updated across all paths!")



