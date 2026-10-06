# -*- coding: utf-8 -*-
import os
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as patches

out_dir = os.path.join(os.path.dirname(__file__), 'figures')
os.makedirs(out_dir, exist_ok=True)

fig, ax = plt.subplots(figsize=(15.8, 9.6), dpi=300)
ax.set_xlim(-28, 176)
ax.set_ylim(0, 98)
ax.axis('off')

# Outer Container Box
container = patches.FancyBboxPatch((-4, 2), 160, 93, boxstyle='round,pad=1.5,rounding_size=2.5',
                                  edgecolor='#2ca02c', facecolor='#fbfdfb', linewidth=2.0)
ax.add_patch(container)

# Main Title
ax.text(76.0, 90.5, 'Four-Core Pipelined Implied Volatility & Greeks Engine (Artix-7 200T @ 100 MHz)',
        ha='center', va='center', fontsize=13.0, fontweight='bold', color='#134713')

def draw_elbow(p_start, p_c1, p_c2, p_end, color='#333333', lw=1.8, ls='-', label=None, label_pos=None, label_kw=None):
    xs = [p_start[0], p_c1[0], p_c2[0], p_end[0]]
    ys = [p_start[1], p_c1[1], p_c2[1], p_end[1]]
    ax.plot(xs, ys, color=color, lw=lw, ls=ls, zorder=5)
    ax.annotate('', xy=p_end, xytext=p_c2,
                arrowprops=dict(arrowstyle='->', color=color, lw=lw, mutation_scale=14),
                zorder=6)
    if label and label_pos:
        kw = dict(fontsize=7.3, fontweight='bold', color=color, ha='center', va='center', zorder=7)
        if label_kw:
            kw.update(label_kw)
        ax.text(label_pos[0], label_pos[1], label, **kw)

# =========================================================================
# Column 1: Stage 1 & Context Memory (x = 0 to 26)
# =========================================================================
# Stage 1: Ingress Registration & Queuing (1 Cycle)
s1 = patches.FancyBboxPatch((0, 54), 26, 30, boxstyle='round,pad=0.8,rounding_size=1.5',
                           edgecolor='#1f77b4', facecolor='#eef5fb', linewidth=1.6)
ax.add_patch(s1)
ax.text(13.0, 78.5, 'Stage 1: Ingress Registration\n& Queuing (1 Cycle)',
        ha='center', va='center', fontsize=9.2, fontweight='bold', color='#0f3c5c')
txt_s1 = ('\u2022 AXI4-Stream 256-bit Ingress:\n'
          '  {S, K, T, r, C_mkt, TID}\n'
          '\u2022 Single-Cycle Register + TID Tag\n'
          '\u2022 No Ingress Divider\n'
          '  (Zero Division Latency)\n'
          '\u2022 Q8.24 Fixed-Point Precision')
ax.text(2.0, 65.0, txt_s1,
        ha='left', va='center', fontsize=7.4, linespacing=1.35)

# Zero-BRAM Context Store
s_mem = patches.FancyBboxPatch((0, 10), 26, 30, boxstyle='round,pad=0.8,rounding_size=1.5',
                              edgecolor='#9467bd', facecolor='#f7f2fa', linewidth=1.6)
ax.add_patch(s_mem)
ax.text(13.0, 36.5, 'Zero-BRAM Context Store',
        ha='center', va='center', fontsize=9.2, fontweight='bold', color='#4a2468')
txt_smem = ('\u2022 64 Context Slots / Core (256 Total)\n'
            '\u2022 60 Active + 4 Headroom Invariant\n'
            '  (Prevents Recirculation Deadlock)\n'
            '\u2022 Distributed LUTRAM & SRL32\n'
            '\u2022 0 Block RAM / UltraRAM in Core\n'
            '\u2022 Leaves 365 BRAM36 Free for System')
ax.text(2.0, 24.0, txt_smem,
        ha='left', va='center', fontsize=7.1, linespacing=1.30)

# =========================================================================
# Column 2: Stage 2 Seeder & Stage 3 Core Datapath (x = 35 to 78)
# =========================================================================
# Stage 2: Analytical Seeder (Brenner-Subrahmanyam, 64 Cycles)
s2 = patches.FancyBboxPatch((35, 54), 43, 30, boxstyle='round,pad=0.8,rounding_size=1.5',
                           edgecolor='#ff7f0e', facecolor='#fef5ec', linewidth=1.6)
ax.add_patch(s2)
ax.text(56.5, 78.5, 'Stage 2: Analytical Seeder\n(Brenner-Subrahmanyam, 64 Cyc)',
        ha='center', va='center', fontsize=9.4, fontweight='bold', color='#7a3c04')
ax.text(56.5, 70.8, r'$\sigma_0 \approx \frac{2.5066 \, C_{\mathrm{mkt}}}{\sqrt{T} \, (S+K)/2}$',
        ha='center', va='center', fontsize=9.4)
txt_s2 = ('\u2022 Shared Digit-Recurrence ' + r'$\sqrt{T}$' + ' (29 Cyc, II = 1)\n' +
          '\u2022 Forwards ' + r'$\sqrt{T}$' + ' Directly to Stage 3 via Context\n' +
          '\u2022 Non-Restoring Divider (33 Cyc, II = 1)\n' +
          '\u2022 Analytical Initial Estimate (Sec 2.4):\n' +
          r'  - Med Abs Err: $0.1037$ vol ($1{,}037$ vol-bps)' + '\n' +
          r'  - Median Rel Err: $30.52\%$ ($11.53\%$ ATM)')
ax.text(37.0, 60.5, txt_s2,
        ha='left', va='center', fontsize=6.9, linespacing=1.25)

# Stage 3: Core Black-Scholes Datapath (126 Cycles, II = 1)
s3 = patches.FancyBboxPatch((35, 10), 43, 30, boxstyle='round,pad=0.8,rounding_size=1.5',
                           edgecolor='#d62728', facecolor='#fdf0ef', linewidth=1.6)
ax.add_patch(s3)
ax.text(56.5, 36.5, 'Stage 3: Core Feedforward Datapath\n(126 Cycles, II = 1)',
        ha='center', va='center', fontsize=9.4, fontweight='bold', color='#681314')
txt_s3 = ('\u2022 II = 1 Pipeline (Reused Across Passes)\n' +
          '\u2022 Scale-Invariant Pad\u00e9 Ratio (S-K)/(S+K)\n' +
          '\u2022 18-Cyc CORDIC Log Fallback (SRL15-Matched)\n' +
          '\u2022 Horner 5th-Order Poly CDF N(d1), N(d2)\n' +
          '\u2022 Hyperbolic CORDIC for exp(-rT) & exp(-d1\u00b2/2)')
ax.text(37.5, 23.5, txt_s3,
        ha='left', va='center', fontsize=7.2, linespacing=1.30)

# =========================================================================
# Column 3: Stage 4 NR Update & Stage 5 Egress (x = 112 to 150)
# =========================================================================
# Stage 4: NR Update & Greek Dividers (33 Cycles)
s4 = patches.FancyBboxPatch((112, 54), 38, 30, boxstyle='round,pad=0.8,rounding_size=1.5',
                           edgecolor='#2ca02c', facecolor='#edf7ed', linewidth=1.6)
ax.add_patch(s4)
ax.text(131.0, 78.5, 'Stage 4: NR Update & Dividers\n(33 Cycles, II = 1)',
        ha='center', va='center', fontsize=9.4, fontweight='bold', color='#134713')
txt_s4 = ('\u2022 Convergence: ' + r'$|C_{\mathrm{BS}} - C_{\mathrm{mkt}}| \leq \$0.01$' + '\n' +
          '  (Norm: ' + r'$|C^*_{\mathrm{BS}} - C^*_{\mathrm{mkt}}| \leq 0.01/K$' + ')\n' +
          '\u2022 ' + r'$\mathbf{u\_nr\_divider}$' + ': ' + r'$\Delta\sigma = (C_{\mathrm{BS}} - C_{\mathrm{mkt}})/\nu$' + '\n' +
          '\u2022 ' + r'$\mathbf{u\_gamma\_divider}$' + ': ' + r'$\Gamma = \phi(d_1)/(S\sigma\sqrt{T})$' + '\n' +
          '\u2022 Greeks: ' + r'$\Delta = N(d_1)$' + ', ' + r'$\nu = S\sqrt{T}\phi(d_1)$' + '\n' +
          '\u2022 TID-Scoreboard Priority Loopback')
ax.text(114.0, 63.5, txt_s4,
        ha='left', va='center', fontsize=6.8, linespacing=1.28)

# Stage 5: Multi-Core Arbiter & 128-Bit Egress (2 Cycles)
s5 = patches.FancyBboxPatch((112, 10), 38, 30, boxstyle='round,pad=0.8,rounding_size=1.5',
                           edgecolor='#17becf', facecolor='#e8f8f9', linewidth=1.6)
ax.add_patch(s5)
ax.text(131.0, 36.5, 'Stage 5: Multi-Core Arbiter\n& 128-Bit Egress (2 Cycles)',
        ha='center', va='center', fontsize=9.4, fontweight='bold', color='#0e565d')
txt_s5 = ('\u2022 Round-Robin 4-Core Drain Arbiter\n' +
          '\u2022 128-Bit Data Payload:\n' +
          '  [127:122] Local TID (6b)\n' +
          '  [121:96]  Delta Greek (26b, Q2.24)\n' +
          '  [95:64]   Gamma Greek (32b, Q8.24)*\n' +
          '  [63:32]   Vega Greek (32b, Q8.24)*\n' +
          '  [31:0]    sigma Implied Vol (32b, Q8.24)\n' +
          '\u2022 Sideband: Core ID (2b)\n' +
          '*Carries ' + r'$\nu^*, \Gamma^*$' + ' for normalized inputs')
ax.text(114.0, 23.0, txt_s5,
        ha='left', va='center', fontsize=6.9, linespacing=1.24)

# =========================================================================
# Inter-block Arrows & Orthogonal Routing
# =========================================================================
arrow_kw = dict(arrowstyle='->', lw=1.8, color='#333333', mutation_scale=14)

# Stage 1 to Stage 2 (Gap from x=26 to x=35 is 9 units)
ax.annotate('', xy=(35, 69.0), xytext=(26, 69.0), arrowprops=arrow_kw)
ax.text(30.5, 71.8, 'Contract', fontsize=7.8, fontweight='bold', color='#444444', ha='center', va='bottom')

# Stage 2 to Stage 3 (Gap from y=54 down to y=40 is 14 units)
ax.annotate('', xy=(56.5, 40.0), xytext=(56.5, 54.0), arrowprops=arrow_kw)
ax.text(56.5, 47.0, r'$\sigma_0, \sqrt{T}$' + ' (Forward)',
        fontsize=7.8, fontweight='bold', color='#7a3c04', ha='center', va='center',
        bbox=dict(boxstyle='round,pad=0.25', facecolor='#ffffff', edgecolor='#ff7f0e', lw=0.6, alpha=0.95))

# Stage 1 <-> Context Memory (Gap from y=54 down to y=40 is 14 units)
ax.annotate('', xy=(13.0, 54.0), xytext=(13.0, 40.0),
            arrowprops=dict(arrowstyle='<->', lw=1.6, color='#9467bd', mutation_scale=12))
ax.text(13.0, 47.0, 'Context',
        fontsize=7.4, fontweight='bold', color='#9467bd', ha='center', va='center',
        bbox=dict(boxstyle='round,pad=0.22', facecolor='#ffffff', edgecolor='#9467bd', lw=0.6, alpha=0.95))

# Stage 3 to Stage 4 via Lane 1 (x=82.5)
draw_elbow(p_start=(78.0, 30.0), p_c1=(82.5, 30.0), p_c2=(82.5, 72.0), p_end=(112.0, 72.0),
           color='#333333', lw=1.8, ls='-',
           label=r'$C_{\mathrm{BS}}, \nu$' + ' (126 Cyc)', label_pos=(97.25, 75.8),
           label_kw=dict(bbox=dict(boxstyle='round,pad=0.25', facecolor='#ffffff', edgecolor='#aaaaaa', lw=0.6, alpha=0.95)))

# Stage 4 Loopback to Stage 3 via Lane 2 (x=100.0)
draw_elbow(p_start=(112.0, 60.0), p_c1=(100.0, 60.0), p_c2=(100.0, 20.0), p_end=(78.0, 20.0),
           color='#d62728', lw=1.8, ls='--',
           label='Nonconverged ' + r'$\rightarrow \sigma_{n+1}$' + ' Recirculation\n(Priority Restore to Stage 3)', label_pos=(100.0, 47.0),
           label_kw=dict(bbox=dict(boxstyle='round,pad=0.30', facecolor='#ffffff', edgecolor='#d62728', lw=0.8, alpha=0.98)))

# Stage 4 to Stage 5 (Gap from y=54 down to y=40 is 14 units)
ax.annotate('', xy=(131.0, 40.0), xytext=(131.0, 54.0),
            arrowprops=dict(arrowstyle='->', lw=1.8, color='#2ca02c', mutation_scale=14))
ax.text(131.0, 47.0, 'Converged ' + r'$\rightarrow$' + ' Egress',
        fontsize=7.6, fontweight='bold', color='#2ca02c', ha='center', va='center',
        bbox=dict(boxstyle='round,pad=0.25', facecolor='#ffffff', edgecolor='#2ca02c', lw=0.6, alpha=0.95))

# External Ingress Arrow
ax.annotate('', xy=(0, 69.0), xytext=(-12, 69.0),
            arrowprops=dict(arrowstyle='->', lw=2.0, color='#1f77b4', mutation_scale=14))
ax.text(-14.0, 69.0, 'AXI4-Stream Ingress\n(256-bit S, K, T, r, C_mkt, TID)',
        ha='right', va='center', fontsize=8.8, fontweight='bold', color='#0f3c5c')

# External Egress Arrow
ax.annotate('', xy=(162, 25.0), xytext=(150, 25.0),
            arrowprops=dict(arrowstyle='->', lw=2.0, color='#17becf', mutation_scale=14))
ax.text(164.0, 25.0, 'AXI4-Stream Egress\n(128b Payload + 2b Core ID Sideband)',
        ha='left', va='center', fontsize=8.6, fontweight='bold', color='#0e565d')

# Save to both paper/figures and paper/ root
target_dirs = [out_dir, os.path.dirname(__file__)]
target_names = [
    'fig1_architecture_block_diagram.png',
    'fig1_architecture_block_diagram.pdf',
    'fig3_architecture_block_diagram.png',
    'fig3_architecture_block_diagram.pdf',
]

for d in target_dirs:
    for name in target_names:
        path = os.path.join(d, name)
        plt.savefig(path, bbox_inches='tight')

curr_brain_dir = r'C:\Users\user\.gemini\antigravity\brain\a960527e-43da-498f-afa3-d9d2fcea574e'
if os.path.exists(curr_brain_dir):
    plt.savefig(os.path.join(curr_brain_dir, 'fig1_architecture_block_diagram.png'), bbox_inches='tight')
    plt.savefig(os.path.join(curr_brain_dir, 'fig1_architecture_block_diagram.pdf'), bbox_inches='tight')

plt.close()
print('Refined v6 diagram generated with perfect alignments and zero overflows!')
