#!/usr/bin/env python3
"""
================================================================================
Plot Generator for Experiment 6: Boundary Stress Surface & SPX Replay
Target Venue: ACM/SIGDA FPGA 2027
================================================================================

Generates publication-quality dual-panel figure:
  1. (a) 2D Numerical Stress Heatmap: Implied Volatility MAE (vol-bps)
         across Moneyness S/K in [0.70, 1.40] and Expiry T in [1d, 2y],
         annotating the Low-Vega boundary (T < 14d) and Padé transition zones.
  2. (b) Empirical SPX Scale-Invariance Replay: Error distribution and passes
         across 1,382 real CBOE SPX contracts, proving dynamic range preservation.

Outputs:
  - paper/figures/fig5_boundary_stress_surface.pdf
  - paper/figures/fig5_boundary_stress_surface.png
================================================================================
"""

import os
import sys
import json
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.colors import LogNorm

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
DATA_6A = os.path.join(REPO_ROOT, "experiments", "data", "stress_map_2d.json")
DATA_6B = os.path.join(REPO_ROOT, "experiments", "data", "spx_scale_invariance.json")

if not os.path.exists(DATA_6A) or not os.path.exists(DATA_6B):
    print(f"Error: Data files not found. Please run run_experiment_6_stress_map.py first.")
    sys.exit(1)

with open(DATA_6A, "r") as f:
    data_6a = json.load(f)

with open(DATA_6B, "r") as f:
    data_6b = json.load(f)

mny = np.array(data_6a["grid_axes"]["moneyness_SK"])
t_years = np.array(data_6a["grid_axes"]["maturity_T_years"])
t_days = t_years * 365.25
err_matrix = np.array(data_6a["error_matrix_bps"])

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11.0, 4.0), dpi=300)

# ------------------------------------------------------------------------------
# Panel (a): 2D Boundary Stress Heatmap
# ------------------------------------------------------------------------------
# Clip lower bound for log norm display
err_display = np.clip(err_matrix, 1.0, 25000.0)

# Create 2D meshgrid
M, T_d = np.meshgrid(mny, t_days)

c = ax1.pcolormesh(M, T_d, err_display.T, norm=LogNorm(vmin=1.0, vmax=10000.0),
                   cmap='viridis', shading='auto')
cbar = fig.colorbar(c, ax=ax1, fraction=0.046, pad=0.04)
cbar.set_label('Absolute Error [vol-bps] (Log Scale)')

# Annotations for physical & numerical boundaries
ax1.axhline(14.0, color='red', linestyle='--', lw=1.5)
ax1.text(0.72, 16.0, 'Low-Vega Boundary (T < 14d)', color='red', fontsize=8.0, fontweight='bold')

ax1.axvline(0.85, color='white', linestyle=':', lw=1.5)
ax1.axvline(1.15, color='white', linestyle=':', lw=1.5)
ax1.text(0.86, 400.0, 'Padé Log [1/1] Domain\n(0.85 <= S/K <= 1.15)', color='white',
         fontsize=8.0, fontweight='bold', bbox=dict(boxstyle="round,pad=0.2", fc="#000000", alpha=0.5))

ax1.set_yscale('log')
ax1.set_xlabel('Moneyness ($S / K$)')
ax1.set_ylabel('Maturity $T$ (Days, Log Scale)')
ax1.set_title('(a) 2D Parameter Boundary Stress Surface ($N=2{,}500$)')
ax1.set_xlim([0.70, 1.40])
ax1.set_ylim([1.0, 730.0])

# ------------------------------------------------------------------------------
# Panel (b): Real-World CBOE SPX Scale-Invariance Replay
# ------------------------------------------------------------------------------
subsets = [data_6b["subsets"]["liquid_ntm"], data_6b["subsets"]["liquid_range"], data_6b["subsets"]["global_spx"]]
labels = ['Liquid NTM\n($0.95 \\leq S/K \\leq 1.05$)', 'Liquid Range\n($0.85 \\leq S/K \\leq 1.15$)', 'Global SPX Quotes\n($0.70 \\leq S/K \\leq 1.40$)']

maes = [s["mae_vol_bps"] for s in subsets]
medians = [s["median_vol_bps"] for s in subsets]
p95s = [s["p95_vol_bps"] for s in subsets]
single_pass_pcts = [s["single_pass_rate_pct"] for s in subsets]

x = np.arange(len(subsets))
width = 0.28

b1 = ax2.bar(x - width, medians, width, label='Median Error (vol-bps)', color='#1f77b4', edgecolor='black', alpha=0.85)
b2 = ax2.bar(x, maes, width, label='MAE (vol-bps)', color='#ff7f0e', edgecolor='black', alpha=0.85)
b3 = ax2.bar(x + width, p95s, width, label='P95 Error (vol-bps)', color='#d62728', edgecolor='black', alpha=0.85)

ax2.set_ylabel('Empirical Error [vol-bps]')
ax2.set_title('(b) CBOE European SPX Scale-Invariance ($N=1{,}382$)')
ax2.set_xticks(x)
ax2.set_xticklabels(labels)
ax2.set_ylim([0, 2500])
ax2.grid(True, axis='y')

# Annotate single pass rate and spot scale
ax2.text(0, 1950, f'Single-Pass: {single_pass_pcts[0]:.1f}%\nAvg Passes: {subsets[0]["avg_passes"]:.2f}',
         ha='center', fontsize=7.5, fontweight='bold',
         bbox=dict(boxstyle="round,pad=0.25", fc="#e6f2ff", ec="#1f77b4", lw=1))
ax2.text(1, 2150, f'Single-Pass: {single_pass_pcts[1]:.1f}%\nAvg Passes: {subsets[1]["avg_passes"]:.2f}',
         ha='center', fontsize=7.5, fontweight='bold',
         bbox=dict(boxstyle="round,pad=0.25", fc="#fff2e6", ec="#ff7f0e", lw=1))

raw_spot = data_6b["metadata"]["max_raw_spot"]
norm_spot = data_6b["metadata"]["max_normalized_spot"]
ax2.annotate(f'Spot: \\${raw_spot:.0f} \\rightarrow \\tilde{{S}} = {norm_spot:.2f}\n(0 Fixed-Point Overflows)',
             xy=(2, 700), xytext=(1.05, 1400),
             arrowprops=dict(facecolor='black', shrink=0.08, width=0.8, headwidth=4),
             fontsize=7.8, fontweight='bold',
             bbox=dict(boxstyle="round,pad=0.3", fc="#f0fff0", ec="#2ca02c", lw=1))

ax2.legend(loc='upper left', framealpha=0.92)

# Save figure
figures_dir = os.path.join(REPO_ROOT, "paper", "figures")
os.makedirs(figures_dir, exist_ok=True)
pdf_path = os.path.join(figures_dir, "fig5_boundary_stress_surface.pdf")
png_path = os.path.join(figures_dir, "fig5_boundary_stress_surface.png")

plt.savefig(pdf_path, bbox_inches='tight')
plt.savefig(png_path, bbox_inches='tight')
plt.close()

print(f"Figure 5 successfully generated at:")
print(f"  - {pdf_path}")
print(f"  - {png_path}")
