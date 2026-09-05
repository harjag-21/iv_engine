import os
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as patches

out_dir = os.path.join(os.path.dirname(__file__), "figures")

fig, ax = plt.subplots(figsize=(12, 6.2), dpi=300)
ax.set_xlim(-12, 118)
ax.set_ylim(0, 72)
ax.axis('off')

# Outer Container Box - clean, large, plenty of padding
container = patches.FancyBboxPatch((2, 2), 108, 66, boxstyle="round,pad=1.5",
                                  edgecolor="#2ca02c", facecolor="#fbfdfb", linewidth=2.0)
ax.add_patch(container)

# Clean title - no intersecting inner box
ax.text(56, 64.0, "Four-Core Pipelined Implied Volatility & Greeks Engine (Artix-7 200T @ 100 MHz)",
        ha='center', va='center', fontsize=12, fontweight='bold', color="#134713")

# Stage 1: Scale Invariance & Ingress
s1 = patches.FancyBboxPatch((6, 33), 27, 24, boxstyle="round,pad=0.8",
                           edgecolor="#1f77b4", facecolor="#eef5fb", linewidth=1.5)
ax.add_patch(s1)
ax.text(19.5, 52, "Stage 1: Scale Invariance\n& Input Ingress", ha='center', va='center', fontsize=9.5, fontweight='bold', color="#0f3c5c")
ax.text(19.5, 41.5, "AXI4-Stream 256-bit Ingress\nS_tilde = S / K,  K_tilde = 1.0\nC_tilde = C_mkt / K\nQ8.24 Dynamic Protection",
        ha='center', va='center', fontsize=8.2)

# Stage 2: Analytical Seeder
s2 = patches.FancyBboxPatch((39, 33), 32, 24, boxstyle="round,pad=0.8",
                           edgecolor="#ff7f0e", facecolor="#fef5ec", linewidth=1.5)
ax.add_patch(s2)
ax.text(55, 52, "Stage 2: Analytical Seeder\n(Brenner-Subrahmanyam)", ha='center', va='center', fontsize=9.5, fontweight='bold', color="#7a3c04")
ax.text(55, 41.5, "sigma_0 = sqrt(2*pi/T) * (C / S)\nShared sqrt(T) Generator\nCompact 32-bit Restoring Div\nEliminates 2nd sqrt core",
        ha='center', va='center', fontsize=8.2)

# Stage 3: Zero-BRAM Context Memory
s_mem = patches.FancyBboxPatch((6, 6), 27, 23, boxstyle="round,pad=0.8",
                              edgecolor="#9467bd", facecolor="#f7f2fa", linewidth=1.5)
ax.add_patch(s_mem)
ax.text(19.5, 23.5, "Zero-BRAM Context Store", ha='center', va='center', fontsize=9.5, fontweight='bold', color="#4a2468")
ax.text(19.5, 14.5, "64 x 32-bit Distributed LUTRAM\nSRL32 Shift Register Pipeline\nZero RAMB36/18 Consumed\nMAC/DMA BRAM Preserved",
        ha='center', va='center', fontsize=8.2)

# Stage 4: Newton-Raphson Datapath
s4 = patches.FancyBboxPatch((39, 6), 32, 23, boxstyle="round,pad=0.8",
                           edgecolor="#d62728", facecolor="#fdf0ef", linewidth=1.5)
ax.add_patch(s4)
ax.text(55, 23.5, "Stage 3: Newton-Raphson\nPipelined Datapath", ha='center', va='center', fontsize=9.5, fontweight='bold', color="#681314")
ax.text(55, 14.5, "Padé Log: ln(S/K) ~ 2*(S-K)/(S+K)\nHyperbolic CORDIC exp(x)\nHorner 5th-order Poly CDF N(d)\nDelta = (C_model - C_mkt) / Vega",
        ha='center', va='center', fontsize=8.0)

# Stage 5: Greeks Output & Arbitration Egress
s5 = patches.FancyBboxPatch((77, 12), 29, 39, boxstyle="round,pad=0.8",
                           edgecolor="#2ca02c", facecolor="#edf7ed", linewidth=1.5)
ax.add_patch(s5)
ax.text(91.5, 44.5, "Stage 4: Multi-Core Arb\n& 128-bit Egress Bus", ha='center', va='center', fontsize=9.5, fontweight='bold', color="#134713")
ax.text(91.5, 29.5, "Round-Robin Core Arbiter\n[31:0]   sigma (Implied Vol)\n[63:32]  Delta (First Order)\n[95:64]  Vega (Vol Sens)\n[121:96] Gamma (Second Order)\n[127:122] TID Transaction ID",
        ha='center', va='center', fontsize=8.0)

# Inter-block Arrows
arrow_kw = dict(arrowstyle="->", lw=1.8, color="#333333")
ax.annotate("", xy=(39, 45), xytext=(33, 45), arrowprops=arrow_kw)
ax.annotate("", xy=(55, 29), xytext=(55, 33), arrowprops=arrow_kw)
ax.annotate("", xy=(19.5, 33), xytext=(19.5, 29), arrowprops=dict(arrowstyle="<->", lw=1.6, color="#9467bd"))
ax.annotate("", xy=(77, 36), xytext=(71, 45), arrowprops=arrow_kw)
ax.annotate("", xy=(77, 26), xytext=(71, 17.5), arrowprops=arrow_kw)

# Ingress & Egress External Arrows
ax.annotate("AXI4-Stream Ingress\n(256-bit S, K, T, r, C, TID)", xy=(6, 45), xytext=(-9, 45),
            ha='right', va='center', fontsize=8.8, fontweight='bold',
            arrowprops=dict(arrowstyle="->", lw=2.0, color="#1f77b4"))

ax.annotate("AXI4-Stream Egress\n(128-bit sigma + Greeks)", xy=(118, 31.5), xytext=(106, 31.5),
            ha='left', va='center', fontsize=8.8, fontweight='bold',
            arrowprops=dict(arrowstyle="<-", lw=2.0, color="#2ca02c"))

fig3_png = os.path.join(out_dir, "fig3_architecture_block_diagram.png")
fig3_pdf = os.path.join(out_dir, "fig3_architecture_block_diagram.pdf")
plt.savefig(fig3_png, bbox_inches='tight')
plt.savefig(fig3_pdf, bbox_inches='tight')
plt.close()
print("Clean Fig 3 generated!")
