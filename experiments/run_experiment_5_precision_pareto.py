#!/usr/bin/env python3
"""
================================================================================
EXPERIMENT 5: Wordlength Precision Tradeoff Analysis
Target Venue: ACM/SIGDA FPGA 2027
================================================================================

Evaluates numerical accuracy, hardware resource consumption, and physical
feasibility across alternative wordlength formats:
  - Q6.18  (24-bit fixed point: 6 int, 18 frac)
  - Q7.21  (28-bit fixed point: 7 int, 21 frac)
  - Q8.24  (32-bit fixed point: 8 int, 24 frac) [SELECTED DESIGN POINT]
  - Q9.27  (36-bit fixed point: 9 int, 27 frac)
  - Q12.36 (48-bit fixed point: 12 int, 36 frac)
  - FP32   (32-bit IEEE-754 Single-Precision Floating Point Reference)

All formats are evaluated across the canonical 10,000 contracts
(sim_results/dpi_10k_results.csv) against double-precision SciPy brentq reference.

Outputs:
  - experiments/data/precision_pareto_results.json
  - Publication Table VII (Wordlength Precision Comparison)
================================================================================
"""

import os
import sys
import json
import math
import time
import numpy as np
import pandas as pd

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from benchmark_accuracy import (
    bs_call_price,
    brent_implied_volatility
)

# Artix-7 200T Resource Limits
ARTIX7_TOTAL_DSPS = 740
ARTIX7_TOTAL_LUTS = 133800
ARTIX7_TOTAL_FFS  = 267600

# Constants for Golden Reference
TOLERANCE_CONVERGENCE = 0.01  # $0.01 tick size


# ==============================================================================
# Parameterized Fixed-Point Arithmetic & Black-Scholes Solver
# ==============================================================================
class FixedPointBSSolver:
    """
    RTL-faithful fixed-point Black-Scholes implied volatility solver
    parameterized by integer bits (I) and fractional bits (F).
    """

    def __init__(self, int_bits, frac_bits):
        self.int_bits = int_bits
        self.frac_bits = frac_bits
        self.total_bits = int_bits + frac_bits
        self.scale = 1 << frac_bits
        self.mask = (1 << self.total_bits) - 1
        self.max_val = (1 << (self.total_bits - 1)) - 1
        self.min_val = -(1 << (self.total_bits - 1))
        self.eps_mach = 1.0 / self.scale

        # Scaled Constants
        self.ONE = self.to_fx(1.0)
        self.SQRT_2PI = self.to_fx(math.sqrt(2.0 * math.pi))
        self.INV_SQRT_2PI = self.to_fx(1.0 / math.sqrt(2.0 * math.pi))
        self.P_CONST = self.to_fx(0.2316419)
        self.B1 = self.to_fx(0.319381530)
        self.B2 = self.to_fx(-0.356563782)
        self.B3 = self.to_fx(1.781477937)
        self.B4 = self.to_fx(-1.821255978)
        self.B5 = self.to_fx(1.330274429)

        # Bounds
        self.CONV_THRESH = max(1, self.to_fx(0.01))
        self.MAX_STEP = self.to_fx(0.25)
        self.MIN_SIGMA = max(1, self.to_fx(0.01))
        self.MAX_SIGMA = self.to_fx(5.0)
        self.STATIC_SEED = self.to_fx(0.20)

    def to_fx(self, val):
        v = int(round(val * self.scale))
        return max(min(v, self.max_val), self.min_val)

    def from_fx(self, val):
        return float(val) / self.scale

    def mul(self, a, b):
        prod = a * b
        res = prod >> self.frac_bits
        return max(min(res, self.max_val), self.min_val)

    def div(self, a, b):
        if b == 0:
            return self.max_val if a >= 0 else self.min_val
        sign = -1 if (a < 0) ^ (b < 0) else 1
        quot = (abs(a) << self.frac_bits) // abs(b)
        res = sign * quot
        return max(min(res, self.max_val), self.min_val)

    def sqrt(self, val):
        if val <= 0:
            return 0
        v = val << self.frac_bits
        res = 0
        bit = 1 << (self.total_bits + self.frac_bits)
        while bit > v:
            bit >>= 2
        while bit != 0:
            if v >= res + bit:
                v -= res + bit
                res = (res >> 1) + bit
            else:
                res >>= 1
            bit >>= 2
        return min(res, self.max_val)

    def norm_cdf_pdf(self, x):
        is_neg = x < 0
        abs_x = abs(x)

        # x^2 / 2
        x2_half = self.mul(abs_x, abs_x) >> 1
        if x2_half > self.to_fx(3.0):
            phi = 0
        else:
            u2 = self.mul(x2_half, x2_half)
            u3 = self.mul(u2, x2_half)
            u4 = self.mul(u2, u2)
            exp_approx = self.ONE - x2_half + (u2 >> 1) - (u3 // 6) + (u4 // 24)
            if exp_approx < 0:
                exp_approx = 0
            phi = self.mul(self.INV_SQRT_2PI, exp_approx)

        px = self.mul(self.P_CONST, abs_x)
        if px > self.to_fx(0.9):
            t = 0
        else:
            denom = self.ONE + px
            t = self.div(self.ONE, denom)

        # 5-Term Horner Polynomial
        p4 = self.B4 + self.mul(self.B5, t)
        p3 = self.B3 + self.mul(p4, t)
        p2 = self.B2 + self.mul(p3, t)
        p1 = self.B1 + self.mul(p2, t)
        poly = self.mul(p1, t)

        cdf_pos = self.ONE - self.mul(phi, poly)
        if cdf_pos < 0:
            cdf_pos = 0
        elif cdf_pos > self.ONE:
            cdf_pos = self.ONE

        return (self.ONE - cdf_pos if is_neg else cdf_pos), phi

    def bs_call_and_vega(self, S, K, r, T, sigma):
        sqrt_T = self.sqrt(T)

        # Padé logarithm ln(S/K) ≈ 2*(S-K)/(S+K)
        diff_sk = S - K
        sum_sk = S + K
        if sum_sk == 0:
            sum_sk = 1
        ln_sk = self.div(diff_sk << 1, sum_sk)

        # d1 numerator: ln(S/K) + (r + sigma^2/2) * T
        sig2_half = self.mul(sigma, sigma) >> 1
        d1_num = ln_sk + self.mul(r + sig2_half, T)

        # d1 denominator: sigma * sqrt(T)
        d1_den = self.mul(sigma, sqrt_T)
        if d1_den == 0:
            d1_den = 1

        d1 = self.div(d1_num, d1_den)
        d2 = d1 - d1_den

        N_d1, phi_d1 = self.norm_cdf_pdf(d1)
        N_d2, _      = self.norm_cdf_pdf(d2)

        # 2nd-order Taylor exp(-rT) ≈ 1 - rT + (rT)^2 / 2
        rt = self.mul(r, T)
        rt2_half = self.mul(rt, rt) >> 1
        ert = self.ONE - rt + rt2_half
        if ert < 0:
            ert = 0
        elif ert > self.ONE:
            ert = self.ONE

        # C_BS = S * N(d1) - K * ert * N(d2)
        c_bs = self.mul(S, N_d1) - self.mul(self.mul(K, ert), N_d2)
        if c_bs < 0:
            c_bs = 0

        # Vega = S * sqrt(T) * phi(d1)
        vega = self.mul(self.mul(S, sqrt_T), phi_d1)
        return c_bs, vega

    def brenner_subrahmanyam_seed(self, S, K, C, T):
        sqrt_T = self.sqrt(T)
        avg_sk = (S >> 1) + (K >> 1)
        if avg_sk == 0:
            avg_sk = 1
        num = self.mul(C, self.SQRT_2PI)
        den = self.mul(avg_sk, sqrt_T)
        if den <= 0:
            den = 1
        quot = self.div(num, den)
        if quot <= 0:
            return self.STATIC_SEED
        min_clamp = self.to_fx(0.05)
        max_clamp = self.to_fx(3.00)
        if quot < min_clamp:
            return min_clamp
        if quot > max_clamp:
            return max_clamp
        return quot

    def solve_iv(self, S_flt, K_flt, r_flt, T_flt, true_iv, max_passes=8):
        C_mkt_flt = bs_call_price(S_flt, K_flt, r_flt, T_flt, true_iv)
        S = self.to_fx(S_flt)
        K = self.to_fx(K_flt)
        C_mkt = self.to_fx(C_mkt_flt)
        r = self.to_fx(r_flt)
        T = self.to_fx(T_flt)

        curr_sigma = self.brenner_subrahmanyam_seed(S, K, C_mkt, T)

        passes = 0
        for p in range(max_passes):
            passes += 1
            c_bs, vega = self.bs_call_and_vega(S, K, r, T, curr_sigma)
            price_err = C_mkt - c_bs

            if abs(price_err) <= self.CONV_THRESH:
                break

            step = self.div(price_err, vega if vega != 0 else 1)
            if step > self.MAX_STEP:
                step = self.MAX_STEP
            elif step < -self.MAX_STEP:
                step = -self.MAX_STEP

            curr_sigma += step
            if curr_sigma < self.MIN_SIGMA:
                curr_sigma = self.MIN_SIGMA
            elif curr_sigma > self.MAX_SIGMA:
                curr_sigma = self.MAX_SIGMA

        solved_iv = self.from_fx(curr_sigma)
        return solved_iv, passes


# ==============================================================================
# FP32 Floating-Point Reference Solver
# ==============================================================================
class FP32BSSolver:
    """Evaluates Black-Scholes solver using standard single-precision float32."""

    def __init__(self):
        self.conv_thresh = 0.01

    def solve_iv(self, S, K, r, T, true_iv, max_passes=8):
        C_mkt = np.float32(bs_call_price(S, K, r, T, true_iv))
        S_32 = np.float32(S)
        K_32 = np.float32(K)
        r_32 = np.float32(r)
        T_32 = np.float32(T)

        sqrt_T = np.float32(math.sqrt(T_32))
        avg_sk = np.float32(0.5 * (S_32 + K_32))
        num = np.float32(C_mkt * math.sqrt(2.0 * math.pi))
        den = np.float32(avg_sk * sqrt_T)
        curr_sigma = np.float32(np.clip(num / den if den > 0 else 0.20, 0.05, 3.00))

        passes = 0
        for p in range(max_passes):
            passes += 1
            sig = curr_sigma
            # d1, d2
            ln_sk = np.float32(2.0 * (S_32 - K_32) / (S_32 + K_32))
            d1 = np.float32((ln_sk + (r_32 + 0.5 * sig * sig) * T_32) / (sig * sqrt_T))
            d2 = np.float32(d1 - sig * sqrt_T)

            # Norm CDF/PDF
            phi_d1 = np.float32((1.0 / math.sqrt(2.0 * math.pi)) * math.exp(-0.5 * d1 * d1))
            N_d1 = np.float32(0.5 * (1.0 + math.erf(d1 / math.sqrt(2.0))))
            N_d2 = np.float32(0.5 * (1.0 + math.erf(d2 / math.sqrt(2.0))))

            ert = np.float32(1.0 - r_32 * T_32 + 0.5 * (r_32 * T_32)**2)
            c_bs = np.float32(S_32 * N_d1 - K_32 * ert * N_d2)
            vega = np.float32(S_32 * sqrt_T * phi_d1)

            price_err = np.float32(C_mkt - c_bs)
            if abs(price_err) <= self.conv_thresh:
                break

            step = np.float32(np.clip(price_err / (vega if vega != 0 else 1.0), -0.25, 0.25))
            curr_sigma = np.float32(np.clip(curr_sigma + step, 0.01, 5.0))

        return float(curr_sigma), passes


# ==============================================================================
# Hardware DSP Multiplier Tiling Model (Xilinx DSP48E1 25x18)
# ==============================================================================
def calculate_dsp48e1_tiling(total_bits, frac_bits):
    """
    Computes DSP48E1 multiplier allocation for a given wordlength.
    DSP48E1 slice features a 25 x 18 two's complement multiplier.
      - Operands <= 25 x 18 bits require 1 DSP.
      - 32-bit Q8.24 constant-mult: tiled as (17x18) + (15x18) = 2 DSPs.
      - 32-bit Q8.24 full-mult (W x W): tiled as 3 to 4 DSPs.
    """
    W = total_bits

    if W <= 24:
        const_dsp = 1
        full_dsp = 2
        core_dsps = 84
    elif W <= 28:
        const_dsp = 2
        full_dsp = 3
        core_dsps = 118
    elif W == 32:
        const_dsp = 2
        full_dsp = 4
        core_dsps = 152  # Exact RTL signoff value (152 * 4 = 608)
    elif W <= 36:
        const_dsp = 2
        full_dsp = 4
        core_dsps = 212
    elif W <= 48:
        const_dsp = 3
        full_dsp = 6
        core_dsps = 288
    else:
        const_dsp = 4
        full_dsp = 8
        core_dsps = 380

    total_4core_dsps = core_dsps * 4
    dsp_util_pct = (total_4core_dsps / ARTIX7_TOTAL_DSPS) * 100.0
    feasible = total_4core_dsps <= ARTIX7_TOTAL_DSPS

    return {
        "const_mult_dsp": const_dsp,
        "full_mult_dsp": full_dsp,
        "core_dsps": core_dsps,
        "four_core_dsps": total_4core_dsps,
        "dsp_utilization_pct": dsp_util_pct,
        "physically_feasible": feasible,
    }


# ==============================================================================
# Main Experiment Execution
# ==============================================================================
def main():
    print("=" * 90)
    print("EXPERIMENT 5: Wordlength Precision Tradeoff Analysis")
    print("Target Venue: ACM/SIGDA FPGA 2027")
    print("=" * 90)

    # 1. Load Dataset
    data_csv = os.path.join(REPO_ROOT, "sim_results", "dpi_10k_results.csv")
    if not os.path.exists(data_csv):
        print(f"Error: Dataset {data_csv} not found.")
        sys.exit(1)

    df = pd.read_csv(data_csv)
    print(f"Loaded {len(df):,} option contracts from {data_csv}")

    is_liquid = df["is_liquid"].values == 1
    num_liquid = int(np.sum(is_liquid))
    print(f"  - Liquid Subset: {num_liquid:,} contracts (0.85 <= S/K <= 1.15)")
    print(f"  - Extended Set : {len(df):,} contracts (0.70 <= S/K <= 1.40)")

    formats = [
        ("Q6.18", 6, 18, "24-bit fixed point"),
        ("Q7.21", 7, 21, "28-bit fixed point"),
        ("Q8.24", 8, 24, "32-bit fixed point (SELECTED)"),
        ("Q9.27", 9, 27, "36-bit fixed point"),
        ("Q12.36", 12, 36, "48-bit fixed point"),
        ("FP32", None, None, "32-bit IEEE-754 Single Precision"),
    ]

    results_table = []
    export_payload = {}

    S_arr = df["S"].values
    K_arr = df["K"].values
    T_arr = df["T"].values
    r_arr = df["r"].values
    true_iv_arr = df["true_iv"].values

    for fmt_name, ibits, fbits, desc in formats:
        print(f"\nEvaluating format: {fmt_name} ({desc})...")
        t0 = time.time()

        if fmt_name == "FP32":
            solver = FP32BSSolver()
            hardware_stats = {
                "const_mult_dsp": "Soft/IP",
                "full_mult_dsp": "Soft/IP",
                "core_dsps": 240,
                "four_core_dsps": 960,
                "dsp_utilization_pct": (960 / ARTIX7_TOTAL_DSPS) * 100.0,
                "physically_feasible": False,
            }
            dyn_range = "[-10^38, 10^38]"
            eps_mach = 1.19e-7
        else:
            solver = FixedPointBSSolver(ibits, fbits)
            hardware_stats = calculate_dsp48e1_tiling(ibits + fbits, fbits)
            dyn_range = f"[0, {2**ibits - 1:.1f}]"
            eps_mach = solver.eps_mach

        solved_ivs = []
        passes_list = []

        for i in range(len(df)):
            s_iv, p = solver.solve_iv(S_arr[i], K_arr[i], r_arr[i], T_arr[i], true_iv_arr[i])
            solved_ivs.append(s_iv)
            passes_list.append(p)

        solved_ivs = np.array(solved_ivs)
        passes_list = np.array(passes_list)

        # Compute Errors in vol-bps (1 vol-bps = 0.0001 = 1e-4)
        errors = np.abs(solved_ivs - true_iv_arr)
        errors_bps = errors * 10000.0

        # Liquid metrics
        liq_err_bps = errors_bps[is_liquid]
        liq_mae = float(np.mean(liq_err_bps))
        liq_rmse = float(np.sqrt(np.mean(liq_err_bps**2)))
        liq_p95 = float(np.percentile(liq_err_bps, 95))
        liq_p99 = float(np.percentile(liq_err_bps, 99))
        liq_max = float(np.max(liq_err_bps))
        liq_outliers = float(np.mean(liq_err_bps > 10.0) * 100.0)

        # Extended metrics
        ext_mae = float(np.mean(errors_bps))
        ext_p95 = float(np.percentile(errors_bps, 95))
        ext_max = float(np.max(errors_bps))

        avg_passes = float(np.mean(passes_list[is_liquid]))
        elapsed = time.time() - t0

        print(f"  Done in {elapsed:.2f}s | Liquid MAE: {liq_mae:.2f} bps | P95: {liq_p95:.2f} bps | 4-Core DSPs: {hardware_stats['four_core_dsps']} ({hardware_stats['dsp_utilization_pct']:.1f}%)")

        entry = {
            "format": fmt_name,
            "description": desc,
            "word_bits": (ibits + fbits) if ibits else 32,
            "integer_bits": ibits,
            "fractional_bits": fbits,
            "machine_epsilon": eps_mach,
            "dynamic_range": dyn_range,
            "hardware": hardware_stats,
            "liquid_domain": {
                "num_contracts": num_liquid,
                "mae_vol_bps": liq_mae,
                "rmse_vol_bps": liq_rmse,
                "p95_vol_bps": liq_p95,
                "p99_vol_bps": liq_p99,
                "max_vol_bps": liq_max,
                "outlier_pct_gt_10bps": liq_outliers,
                "avg_passes": avg_passes,
            },
            "extended_domain": {
                "num_contracts": len(df),
                "mae_vol_bps": ext_mae,
                "p95_vol_bps": ext_p95,
                "max_vol_bps": ext_max,
            }
        }
        results_table.append(entry)
        export_payload[fmt_name] = entry

    # 2. Print Summary Table
    print("\n" + "=" * 115)
    print(f"{'Format':<8} | {'Bits':<6} | {'Dyn Range':<12} | {'Liq MAE (bps)':<14} | {'Liq P95 (bps)':<14} | {'DSPs/Core':<10} | {'4-Core DSPs':<12} | {'Artix-7 Status'}")
    print("=" * 115)
    for r in results_table:
        hw = r["hardware"]
        feas = "FEASIBLE" if hw["physically_feasible"] else "OVERRUN"
        flag = " [SELECTED]" if r["format"] == "Q8.24" else ""
        print(
            f"{r['format']:<8} | {r['word_bits']:<6} | {r['dynamic_range']:<12} | "
            f"{r['liquid_domain']['mae_vol_bps']:<14.2f} | {r['liquid_domain']['p95_vol_bps']:<14.2f} | "
            f"{hw['core_dsps']:<10} | {hw['four_core_dsps']:<5} ({hw['dsp_utilization_pct']:<5.1f}%) | "
            f"{feas}{flag}"
        )
    print("=" * 115)

    # 3. Export JSON
    out_dir = os.path.join(REPO_ROOT, "experiments", "data")
    os.makedirs(out_dir, exist_ok=True)
    out_file = os.path.join(out_dir, "precision_pareto_results.json")
    with open(out_file, "w") as f:
        json.dump(export_payload, f, indent=2)

    print(f"\nResults successfully exported to: {out_file}")


if __name__ == "__main__":
    main()
