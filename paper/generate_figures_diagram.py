# -*- coding: utf-8 -*-
import os
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as patches

out_dir = os.path.join(os.path.dirname(__file__), 'figures')
os.makedirs(out_dir, exist_ok=True)

fig, ax = plt.subplots(figsize=(14.8, 8.0), dpi=300)
ax.set_xlim(-24, 156)
ax.set_ylim(0, 84)
ax.axis('off')

# Outer Container Box
container = patches.FancyBboxPatch((-3, 2), 138, 76, boxstyle='round,pad=1.5,rounding_size=2.5',
                                  edgecolor='#2ca02c', facecolor='#fbfdfb', linewidth=2.0)
ax.add_patch(container)

# Main Title
ax.text(66, 73.2, 'Four-Core Pipelined Implied Volatility & Greeks Engine (Artix-7 200T @ 100 MHz)',
        ha='center', va='center', fontsize=13, fontweight='bold', color='#134713')

def draw_elbow(p_start, p_c1, p_c2, p_end, color='#333333', lw=1.8, ls='-', label=None, label_pos=None, label_kw=None):
    xs = [p_start[0], p_c1[0], p_c2[0], p_end[0]]
    ys = [p_start[1], p_c1[1], p_c2[1], p_end[1]]
    ax.plot(xs, ys, color=color, lw=lw, ls=ls, zorder=5)
    ax.annotate('', xy=p_end, xytext=p_c2,
                arrowprops=dict(arrowstyle='->', color=color, lw=lw, mutation_scale=14),
                zorder=6)
    if label and label_pos:
        kw = dict(fontsize=7.4, fontweight='bold', color=color, ha='center', va='center', zorder=7)
        if label_kw:
            kw.update(label_kw)
        ax.text(label_pos[0], label_pos[1], label, **kw)

# =========================================================================
# Column 1: Stage 1 & Context Memory (x = 0 to 26)
# =========================================================================
# Stage 1: Ingress Registration & Queuing (1 Cycle)
s1 = patches.FancyBboxPatch((0, 40), 26, 28, boxstyle='round,pad=0.8,rounding_size=1.5',
                           edgecolor='#1f77b4', facecolor='#eef5fb', linewidth=1.6)
ax.add_patch(s1)
ax.text(13, 62.8, 'Stage 1: Ingress Registration\n& Queuing (1 Cycle)',
        ha='center', va='center', fontsize=9.0, fontweight='bold', color='#0f3c5c')
ax.text(13, 49.5, '\u2022 AXI4-Stream 256-bit Ingress:\n  {S, K, T, r, C_mkt, TID}\n\u2022 Single-Cycle Register + TID Tag\n\u2022 No Ingress Divider\n  (Zero Division Latency)\n\u2022 Q8.24 Fixed-Point Precision',
        ha='center', va='center', fontsize=7.4, linespacing=1.35)

# Zero-BRAM Context Store
s_mem = patches.FancyBboxPatch((0, 6), 26, 28, boxstyle='round,pad=0.8,rounding_size=1.5',
                              edgecolor='#9467bd', facecolor='#f7f2fa', linewidth=1.6)
ax.add_patch(s_mem)
ax.text(13, 28.5, 'Zero-BRAM Context Store',
        ha='center', va='center', fontsize=9.0, fontweight='bold', color='#4a2468')
ax.text(13, 16.5, '\u2022 64 x 32-bit Distributed LUTRAM\n\u2022 SRL32 Delay Shift Registers\n\u2022 0 Block RAMs / UltraRAMs\n\u2022 Leaves on-chip block memory\n  for external packet & DMA buffering',
        ha='center', va='center', fontsize=7.4, linespacing=1.35)

# =========================================================================
# Column 2: Stage 2 Seeder & Stage 3 Core Datapath (x = 38 to 78)
# =========================================================================
# Stage 2: Analytical Seeder (Brenner-Subrahmanyam, 64 Cycles)
s2 = patches.FancyBboxPatch((38, 40), 40, 28, boxstyle='round,pad=0.8,rounding_size=1.5',
                           edgecolor='#ff7f0e', facecolor='#fef5ec', linewidth=1.6)
ax.add_patch(s2)
ax.text(58, 62.8, 'Stage 2: Analytical Seeder\n(Brenner-Subrahmanyam, 64 Cyc)',
        ha='center', va='center', fontsize=9.2, fontweight='bold', color='#7a3c04')
ax.text(58, 52.8, r'$\sigma_0 \approx \frac{2.5066 \, C_{\mathrm{mkt}}}{\sqrt{T} \, (S+K)/2}$',
        ha='center', va='center', fontsize=9.2)
ax.text(58, 44.8, '\u2022 Shared Digit-Recurrence ' + r'$\sqrt{T}$' + ' (29 Cyc)\n\u2022 Forwards ' + r'$\sqrt{T}$' + ' Directly to Stage 3\n\u2022 Non-Restoring Divider (33 Cyc)\n\u2022 Obs. Liquid Error: ' + r'$|\sigma_0 - \sigma^*| / \sigma^* < 0.5\%$' + '\n  ' + r'(obs. $< 0.08$ vol in wings)',
        ha='center', va='center', fontsize=7.2, linespacing=1.35)

# Stage 3: Core Black-Scholes Datapath (126 Cycles, II = 1)
s3 = patches.FancyBboxPatch((38, 6), 40, 28, boxstyle='round,pad=0.8,rounding_size=1.5',
                           edgecolor='#d62728', facecolor='#fdf0ef', linewidth=1.6)
ax.add_patch(s3)
ax.text(58, 28.5, 'Stage 3: Core BS Datapath\n(126 Cycles, II = 1)',
        ha='center', va='center', fontsize=9.2, fontweight='bold', color='#681314')
ax.text(58, 16.5, '• Scale-Invariant Padé Ratio (S-K)/(S+K)\n• 18-Cyc CORDIC Log Fallback (SRL15-Matched)\n• Horner 5th-Order Poly CDF N(d1), N(d2)\n• Hyperbolic CORDIC for exp(-rT) & exp(-d1²/2)\n• Fully Unrolled 126-Stage Feedforward',
        ha='center', va='center', fontsize=7.4, linespacing=1.35)

# =========================================================================
# Column 3: Stage 4 NR Update & Stage 5 Egress (x = 98 to 132)
# =========================================================================
# Stage 4: NR Update & Greek Dividers (33 Cycles)
s4 = patches.FancyBboxPatch((98, 40), 34, 28, boxstyle='round,pad=0.8,rounding_size=1.5',
                           edgecolor='#2ca02c', facecolor='#edf7ed', linewidth=1.6)
ax.add_patch(s4)
ax.text(115, 62.8, 'Stage 4: NR Update & Dividers\n(33 Cycles)',
        ha='center', va='center', fontsize=9.2, fontweight='bold', color='#134713')
ax.text(115, 49.5, '• Convergence: ' + r'$|C_{\mathrm{BS}} - C_{\mathrm{mkt}}| \leq \$0.01$' + '\n• ' + r'$\mathbf{u\_nr\_divider}$' + ': ' + r'$\Delta\sigma = (C_{\mathrm{BS}} - C_{\mathrm{mkt}})/\nu$' + '\n• ' + r'$\mathbf{u\_gamma\_divider}$' + ': ' + r'$\Gamma = \phi(d_1)/(S\sigma\sqrt{T})$' + '\n• Greeks: ' + r'$\Delta = N(d_1)$' + ', ' + r'$\nu = S\sqrt{T}\phi(d_1)$' + '\n• TID-Scoreboard Priority Loopback',
        ha='center', va='center', fontsize=7.1, linespacing=1.35)

# Stage 5: Multi-Core Arbiter & 128-Bit Egress (2 Cycles)
s5 = patches.FancyBboxPatch((98, 6), 34, 28, boxstyle='round,pad=0.8,rounding_size=1.5',
                           edgecolor='#17becf', facecolor='#e8f8f9', linewidth=1.6)
ax.add_patch(s5)
ax.text(115, 28.5, 'Stage 5: Multi-Core Arbiter\n& 128-Bit Egress (2 Cycles)',
        ha='center', va='center', fontsize=9.2, fontweight='bold', color='#0e565d')
ax.text(115, 16.5, '\u2022 Round-Robin 4-Core Drain Arbiter\n\u2022 128-Bit Data Payload:\n  [127:122] Local TID (6b)\n  [121:96]  Gamma Greek (26b)\n  [95:64]   Vega Greek (32b)\n  [63:32]   Delta Greek (32b)\n  [31:0]    sigma Implied Vol (32b)\n\u2022 Sideband: Core ID (2b)\n\u2022 Global Tag: {Core[1:0], TID[5:0]}',
        ha='center', va='center', fontsize=7.0, linespacing=1.30)

# =========================================================================
# Inter-block Arrows & Orthogonal Routing
# =========================================================================
arrow_kw = dict(arrowstyle='->', lw=1.8, color='#333333', mutation_scale=14)

# Stage 1 to Stage 2 (Gap from x=26 to x=38 is 12 units)
ax.annotate('', xy=(38, 54.0), xytext=(26, 54.0), arrowprops=arrow_kw)
ax.text(32.0, 56.5, 'Contract', fontsize=7.5, fontweight='bold', color='#444444', ha='center')

# Stage 2 to Stage 3
ax.annotate('', xy=(58, 34), xytext=(58, 40), arrowprops=arrow_kw)
ax.text(60.5, 37.0, r'$\sigma_0, \sqrt{T}$' + ' (Forward)', fontsize=7.8, fontweight='bold', color='#7a3c04', va='center')

# Stage 1 <-> Context Memory
ax.annotate('', xy=(13, 40), xytext=(13, 34),
            arrowprops=dict(arrowstyle='<->', lw=1.6, color='#9467bd', mutation_scale=12))
ax.text(15.5, 37.0, 'Context', fontsize=7.4, fontweight='bold', color='#9467bd', va='center')

# Stage 3 to Stage 4 via Lane 1 (x=85)
draw_elbow(p_start=(78, 28.0), p_c1=(85.0, 28.0), p_c2=(85.0, 56.0), p_end=(98, 56.0),
           color='#333333', lw=1.8, ls='-',
           label=r'$C_{\mathrm{BS}}, \nu$' + '\n(126 Cyc)', label_pos=(85.0, 42.0),
           label_kw=dict(bbox=dict(boxstyle='round,pad=0.25', facecolor='#ffffff', edgecolor='#aaaaaa', lw=0.6, alpha=0.9)))

# Stage 4 Loopback to Stage 3 via Lane 2 (x=92)
draw_elbow(p_start=(98, 44.0), p_c1=(92.0, 44.0), p_c2=(92.0, 16.0), p_end=(78, 16.0),
           color='#d62728', lw=1.8, ls='--',
           label='Priority Loopback\n' + r'$\sigma_{n+1}$ ($|C_{\mathrm{BS}}-C_{\mathrm{mkt}}| > \epsilon$)', label_pos=(92.0, 30.0),
           label_kw=dict(bbox=dict(boxstyle='round,pad=0.25', facecolor='#ffffff', edgecolor='#d62728', lw=0.8, alpha=0.95)))

# Stage 4 to Stage 5
ax.annotate('', xy=(115, 34), xytext=(115, 40),
            arrowprops=dict(arrowstyle='->', lw=1.8, color='#2ca02c', mutation_scale=14))
ax.text(117.5, 37.0, 'Converged IV & Greeks\n' + r'($|C_{\mathrm{BS}}-C_{\mathrm{mkt}}| \leq \epsilon$)', fontsize=6.8, fontweight='bold', color='#2ca02c', va='center')

# External Ingress Arrow
ax.annotate('', xy=(0, 54.0), xytext=(-10, 54.0),
            arrowprops=dict(arrowstyle='->', lw=2.0, color='#1f77b4', mutation_scale=14))
ax.text(-12.0, 54.0, 'AXI4-Stream Ingress\n(256-bit S, K, T, r, C_mkt, TID)',
        ha='right', va='center', fontsize=8.8, fontweight='bold', color='#0f3c5c')

# External Egress Arrow
ax.annotate('', xy=(140, 20.0), xytext=(132, 20.0),
            arrowprops=dict(arrowstyle='->', lw=2.0, color='#17becf', mutation_scale=14))
ax.text(142.0, 20.0, r'AXI4-Stream Egress' + '\n' + r'(128b Payload + 2b Core ID Sideband)',
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
print('Refined v6 diagram generated with perfect alignments!')
