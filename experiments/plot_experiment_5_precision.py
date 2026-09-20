#!/usr/bin/env python3
"""
================================================================================
Plot Generator for Experiment 5: Wordlength Precision Tradeoff Analysis
Target Venue: ACM/SIGDA FPGA 2027
================================================================================

Generates publication-quality dual-panel figure:
  1. (a) Numerical Error vs Wordlength: Implied Volatility MAE (vol-bps)
         across Q6.18, Q7.21, Q8.24, Q9.27, Q12.36, and FP32 reference.
  2. (b) Hardware Resource Cost vs Device Capacity: 4-Core DSP48E1 utilization
         annotating the 740 DSP physical limit of Artix-7 200T and highlighting
         Q8.24 as the uniquely feasible, high-precision Pareto knee.

Outputs:
  - paper/figures/fig4_precision_pareto.pdf
  - paper/figures/fig4_precision_pareto.png
================================================================================
"""

import os
import sys
import json
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# Styling for ACM/SIGDA publication
plt.rcParams.update({
    'font.family': 'serif',
    'font.size': 10,
    'axes.labelsize': 11,
    'axes.titlesize': 11,
    'xtick.labelsize': 9,
    'ytick.labelsize': 9,
    'legend.fontsize': 8.5,
    'figure.titlesize': 12,
    'figure.autolayout': True,
    'grid.alpha': 0.35,
    'grid.linestyle': '--'
})

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RESULTS_JSON = os.path.join(REPO_ROOT, "experiments", "data", "precision_pareto_results.json")

if not os.path.exists(RESULTS_JSON):
    print(f"Error: {RESULTS_JSON} not found. Please run run_experiment_5_precision_pareto.py first.")
    sys.exit(1)

with open(RESULTS_JSON, "r") as f:
    data = json.load(f)

formats = ["Q6.18", "Q7.21", "Q8.24", "Q9.27", "Q12.36", "FP32"]
labels = ["Q6.18\n(24b)", "Q7.21\n(28b)", "Q8.24\n(32b)*", "Q9.27\n(36b)", "Q12.36\n(48b)", "FP32\n(32b)"]

liq_maes = [data[f]["liquid_domain"]["mae_vol_bps"] for f in formats]
liq_p95s = [data[f]["liquid_domain"]["p95_vol_bps"] for f in formats]
dsps_4c  = [data[f]["hardware"]["four_core_dsps"] for f in formats]

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10.5, 3.9), dpi=300)

# ------------------------------------------------------------------------------
# Panel (a): Numerical Accuracy (Log Scale)
# ------------------------------------------------------------------------------
x = np.arange(len(formats))
width = 0.35

b1 = ax1.bar(x - width/2, liq_maes, width, label='Liquid MAE (vol-bps)',
             color='#1f77b4', edgecolor='black', alpha=0.85)
b2 = ax1.bar(x + width/2, liq_p95s, width, label='Liquid P95 Error (vol-bps)',
             color='#ff7f0e', edgecolor='black', alpha=0.85)

ax1.set_yscale('log')
ax1.set_ylabel('Error [vol-bps] (Log Scale)')
ax1.set_title('(a) Numerical Accuracy Across Wordlengths')
ax1.set_xticks(x)
ax1.set_xticklabels(labels)
ax1.set_ylim([1, 15000])
ax1.grid(True, which='both', axis='y')
ax1.legend(loc='upper right', framealpha=0.92)

# Highlight accuracy threshold (< 10 bps)
ax1.axhline(10.0, color='#d62728', linestyle=':', lw=1.5)
ax1.text(0.1, 12.0, '10 vol-bps Market Threshold', color='#d62728', fontsize=8.0, fontweight='bold')

# ------------------------------------------------------------------------------
# Panel (b): Hardware Resource Scaling & Device Capacity
# ------------------------------------------------------------------------------
colors = ['#2ca02c' if d <= 740 else '#d62728' for d in dsps_4c]
bars = ax2.bar(x, dsps_4c, width=0.55, color=colors, edgecolor='black', alpha=0.85)

# Capacity line for Artix-7 200T
ax2.axhline(740, color='#d62728', linestyle='--', lw=2.0, label='Artix-7 200T Capacity (740 DSPs)')

ax2.set_ylabel('Total 4-Core DSP48E1 Slices')
ax2.set_title('(b) Physical DSP Consumption vs. Device Capacity')
ax2.set_xticks(x)
ax2.set_xticklabels(labels)
ax2.set_ylim([0, 1300])
ax2.grid(True, axis='y')

# Annotate Q8.24 selected knee
ax2.annotate('Selected Design Point\n608 DSPs (82.2%)\nFeasible + <6 bps MAE',
             xy=(2, 608), xytext=(1.0, 850),
             arrowprops=dict(facecolor='black', shrink=0.08, width=0.8, headwidth=4),
             fontsize=8.0, fontweight='bold',
             bbox=dict(boxstyle="round,pad=0.3", fc="#e6f2ff", ec="#1f77b4", lw=1))

# Overrun label
for i, d in enumerate(dsps_4c):
    if d > 740:
        ax2.text(i, d + 25, f'{d}\n(OVER)', ha='center', va='bottom', fontsize=7.5, color='#d62728', fontweight='bold')
    else:
        ax2.text(i, d + 25, f'{d}', ha='center', va='bottom', fontsize=8.0, color='#2ca02c', fontweight='bold')

ax2.legend(loc='upper left', framealpha=0.92)

# Save figure
figures_dir = os.path.join(REPO_ROOT, "paper", "figures")
paper_dir = os.path.join(REPO_ROOT, "paper")
os.makedirs(figures_dir, exist_ok=True)

pdf_path = os.path.join(figures_dir, "fig4_precision_pareto.pdf")
png_path = os.path.join(figures_dir, "fig4_precision_pareto.png")
paper_pdf = os.path.join(paper_dir, "fig4_precision_pareto.pdf")
paper_png = os.path.join(paper_dir, "fig4_precision_pareto.png")

plt.savefig(pdf_path, bbox_inches='tight')
plt.savefig(png_path, bbox_inches='tight')
plt.savefig(paper_pdf, bbox_inches='tight')
plt.savefig(paper_png, bbox_inches='tight')
plt.close()

print(f"Figure 4 successfully generated at:")
print(f"  - {pdf_path}")
print(f"  - {png_path}")
print(f"  - {paper_pdf}")
print(f"  - {paper_png}")
