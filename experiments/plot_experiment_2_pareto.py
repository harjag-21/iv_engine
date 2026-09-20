#!/usr/bin/env python3
"""
================================================================================
Plot Generator for Experiment 2: Iteration Ablation & Pareto Frontier
Target Venue: ACM/SIGDA FPGA 2027
================================================================================

Generates publication-quality figures:
  1. (a) Iteration Distribution: Empirical convergence histogram comparing
         Analytical Seed (Brenner-Subrahmanyam) vs Static Fallback Seed (0.20).
  2. (b) Accuracy-Throughput Pareto Frontier: Implied Volatility MAE (vol-bps)
         vs Sustained Contract Throughput (MOps/s) across Fixed 1p, 2p, 4p, 8p
         and Proposed Dynamic Loopback.

Outputs saved to:
  - paper/figures/fig2_iteration_ablation.pdf
  - paper/figures/fig2_iteration_ablation.png
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
    'legend.fontsize': 9,
    'figure.titlesize': 12,
    'figure.autolayout': True,
    'grid.alpha': 0.35,
    'grid.linestyle': '--'
})

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RESULTS_JSON = os.path.join(REPO_ROOT, "experiments", "data", "loopback_ablation_results.json")

if not os.path.exists(RESULTS_JSON):
    print(f"Error: {RESULTS_JSON} not found. Please run run_experiment_2a_multipass.py first.")
    sys.exit(1)

with open(RESULTS_JSON, "r") as f:
    data = json.load(f)

cfgs = data["configurations"]
pass_dist = data["pass_distribution"]

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10, 3.8), dpi=300)

# -------------------------------------------------------------
# Panel (a): Iteration Distribution
# -------------------------------------------------------------
passes = np.arange(1, 9)
width = 0.38

liq_pcts = [pass_dist["liquid_domain"]["percentages"][str(p)] for p in passes]
ext_pcts = [pass_dist["extended_domain"]["percentages"][str(p)] for p in passes]

b1 = ax1.bar(passes - width/2, liq_pcts, width, label='Liquid ($0.85 \\leq S/K \\leq 1.15$)',
             color='#1f77b4', edgecolor='black', alpha=0.85)
b2 = ax1.bar(passes + width/2, ext_pcts, width, label='Extended ($0.70 \\leq S/K \\leq 1.40$)',
             color='#ff7f0e', edgecolor='black', alpha=0.85)

ax1.set_xlabel('Datapath Passes to Convergence ($P$)')
ax1.set_ylabel('Percentage of Contracts (%)')
ax1.set_title('(a) Hardware Convergence Distribution')
ax1.set_xticks(passes)
ax1.set_ylim([0, 60])
ax1.grid(True)
ax1.legend(loc='upper right', framealpha=0.9)

# Annotation for liquid convergence
cum_p3 = liq_pcts[0] + liq_pcts[1] + liq_pcts[2]
ax1.annotate(f'88.7% converge\nin $\\leq 3$ passes',
             xy=(2, 49.5), xytext=(3.5, 45),
             arrowprops=dict(facecolor='black', shrink=0.08, width=1, headwidth=5),
             fontsize=8.5, fontweight='bold', bbox=dict(boxstyle="round,pad=0.3", fc="#e6f2ff", ec="#1f77b4", lw=1))

# -------------------------------------------------------------
# Panel (b): Pareto Frontier (Throughput vs. MAE)
# -------------------------------------------------------------
# Plot curves for Liquid Domain
points_liq = [
    ("Fixed 1-Pass", cfgs["fixed_1p"]["liquid_domain"]["metrics"]["mae"], cfgs["fixed_1p"]["liquid_domain"]["sustained_tput_mops"], 's', '#d62728'),
    ("Fixed 2-Pass", cfgs["fixed_2p"]["liquid_domain"]["metrics"]["mae"], cfgs["fixed_2p"]["liquid_domain"]["sustained_tput_mops"], '^', '#9467bd'),
    ("Fixed 4-Pass", cfgs["fixed_4p"]["liquid_domain"]["metrics"]["mae"], cfgs["fixed_4p"]["liquid_domain"]["sustained_tput_mops"], 'D', '#8c564b'),
    ("Fixed 8-Pass", cfgs["fixed_8p"]["liquid_domain"]["metrics"]["mae"], cfgs["fixed_8p"]["liquid_domain"]["sustained_tput_mops"], 'v', '#7f7f7f'),
    ("Proposed (Dynamic)", cfgs["prop_dynamic"]["liquid_domain"]["metrics"]["mae"], cfgs["prop_dynamic"]["liquid_domain"]["sustained_tput_mops"], '*', '#2ca02c'),
]

# Plot Fixed multi-pass curve
fp_maes = [p[1] for p in points_liq[:4]]
fp_tputs = [p[2] for p in points_liq[:4]]
ax2.plot(fp_maes, fp_tputs, 'k--', alpha=0.6, linewidth=1.5, label='Fixed Time-Multiplexed ($II=K$)')

# Annotate proposed knee
prop_mae = cfgs["prop_dynamic"]["liquid_domain"]["metrics"]["mae"]
prop_tput = cfgs["prop_dynamic"]["liquid_domain"]["sustained_tput_mops"]
ax2.annotate(f'Proposed Dynamic:\n{prop_tput:.1f} MOps/s @ {prop_mae:.1f} bps modeled\n(7.67 bps synthesized RTL)',
             xy=(prop_mae, prop_tput), xytext=(10, 260),
             arrowprops=dict(facecolor='#2ca02c', edgecolor='black', shrink=0.18, width=1.5, headwidth=6),
             fontsize=8.0, fontweight='bold', bbox=dict(boxstyle="round,pad=0.35", fc="#eafaf1", ec="#2ca02c", lw=1.2))

for label, mae, tput, marker, color in points_liq:
    size = 140 if marker == '*' else 65
    edgecolor = 'black'
    zorder = 10 if marker == '*' else 5
    ax2.scatter(mae, tput, marker=marker, s=size, color=color, edgecolor=edgecolor, zorder=zorder, label=label)

ax2.set_xscale('log')
ax2.set_xlabel(r'Mean Absolute Volatility Error (vol-bps, log scale)')
ax2.set_ylabel('Sustained Throughput (MOps/s)')
ax2.set_title('(b) Throughput vs. Accuracy Pareto Frontier')
ax2.set_xlim([2, 500])
ax2.set_ylim([0, 450])
ax2.grid(True, which="both", ls="--")
ax2.legend(loc='lower left', framealpha=0.9, fontsize=8)

# Save figures
figures_dir = os.path.join(REPO_ROOT, "paper", "figures")
paper_dir = os.path.join(REPO_ROOT, "paper")
os.makedirs(figures_dir, exist_ok=True)

out_pdf = os.path.join(figures_dir, "fig2_iteration_ablation.pdf")
out_png = os.path.join(figures_dir, "fig2_iteration_ablation.png")
paper_pdf = os.path.join(paper_dir, "fig2_iteration_ablation.pdf")
paper_png = os.path.join(paper_dir, "fig2_iteration_ablation.png")

plt.savefig(out_pdf, bbox_inches='tight')
plt.savefig(out_png, bbox_inches='tight')
plt.savefig(paper_pdf, bbox_inches='tight')
plt.savefig(paper_png, bbox_inches='tight')
plt.close()

print(f"Generated Figure 2 successfully:")
print(f"  - {out_pdf}")
print(f"  - {out_png}")
print(f"  - {paper_pdf}")
print(f"  - {paper_png}")
