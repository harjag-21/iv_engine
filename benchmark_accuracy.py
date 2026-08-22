# =========================================================
# Enhanced RTL-Accurate Benchmark: IV Engine Accuracy Analysis
# =========================================================
# Benchmarks Q8.24 Fixed-Point Hardware Engine (matching RTL
# architecture with 5-term Horner CDF and 2nd-order exp)
# against Brent Analytical Solver across 10,000 synthetic option ticks.
# =========================================================

import math
import random
import time

# =====================================================
# Golden Reference (IEEE FP64)
# =====================================================
def std_norm_cdf(x):
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))

def std_norm_pdf(x):
    return (1.0 / math.sqrt(2.0 * math.pi)) * math.exp(-0.5 * x * x)

def bs_call_price(S, K, r, T, sigma):
    if sigma <= 0 or T <= 0:
        return max(S - K * math.exp(-r * T), 0.0)
    d1 = (math.log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * math.sqrt(T))
    d2 = d1 - sigma * math.sqrt(T)
    return S * std_norm_cdf(d1) - K * math.exp(-r * T) * std_norm_cdf(d2)

def brent_implied_volatility(S, K, C_market, r, T, tol=1e-5, max_iter=100):
    a, b = 1e-4, 5.0
    fa = bs_call_price(S, K, r, T, a) - C_market
    fb = bs_call_price(S, K, r, T, b) - C_market
    if fa * fb > 0:
        return None

    c = a; fc = fa; d = e = b - a
    for _ in range(max_iter):
        if (fb > 0 and fc > 0) or (fb < 0 and fc < 0):
            c = a; fc = fa; d = e = b - a
        if abs(fc) < abs(fb):
            a = b; b = c; c = a
            fa = fb; fb = fc; fc = fa
        tol1 = 2.0 * 1e-12 * abs(b) + 0.5 * tol
        xm = 0.5 * (c - b)
        if abs(xm) <= tol1 or fb == 0:
            return b
        if abs(e) >= tol1 and abs(fa) > abs(fb):
            s = fb / fa
            if a == c:
                p = 2.0 * xm * s; q = 1.0 - s
            else:
                q = fa / fc; r_val = fb / fc
                p = s * (2.0 * xm * q * (q - r_val) - (b - a) * (r_val - 1.0))
                q = (q - 1.0) * (r_val - 1.0) * (s - 1.0)
            if p > 0: q = -q
            p = abs(p)
            min1 = 3.0 * xm * q - abs(tol1 * q)
            min2 = abs(e * q)
            if 2.0 * p < min(min1, min2):
                e = d; d = p / q
            else:
                d = xm; e = d
        else:
            d = xm; e = d
        a = b; fa = fb
        if abs(d) > tol1: b += d
        else: b += tol1 if xm > 0 else -tol1
        fb = bs_call_price(S, K, r, T, b) - C_market
    return b

# =====================================================
# Q8.24 Fixed-Point Utilities
# =====================================================
Q24 = 2**24  # 16,777,216

def to_q24(val):
    v = int(round(val * Q24))
    return max(min(v, 2**31 - 1), -(2**31))

def from_q24(fixed_val):
    return float(fixed_val) / Q24

def q24_div(num, den):
    if den == 0:
        return 0
    sign = -1 if (num < 0) ^ (den < 0) else 1
    result = (abs(num) << 24) // abs(den)
    return sign * result

def q824_sqrt(T_q24):
    """Pipelined non-restoring fixed-point square root (matches iv_sqrt_q824.sv)."""
    if T_q24 <= 0:
        return 0
    val = T_q24 << 24
    res = 0
    bit = 1 << 54
    while bit > val:
        bit >>= 2
    while bit != 0:
        if val >= res + bit:
            val -= res + bit
            res = (res >> 1) + bit
        else:
            res >>= 1
        bit >>= 2
    return res

# =====================================================
# RTL-Accurate 5-Term Horner CDF/PDF (matches iv_norm_cdf.sv with exact t-divider)
# =====================================================
INV_SQRT_2PI_Q24 = 6693156
P_CONST_Q24      = 3886284
B1_Q24           = 5358908
B2_Q24           = -5982098
B3_Q24           = 29888258
B4_Q24           = -30555546
B5_Q24           = 22318398
Q24_ONE          = 16777216

def hw_norm_cdf_pdf(x_q24):
    is_neg = x_q24 < 0
    abs_x = 2**31 - 1 if x_q24 == -(2**31) else abs(x_q24)

    # 64-bit multiplication context (matches 64'(signed'(safe_abs_x)) in iv_norm_cdf.sv)
    x2_half = (abs_x * abs_x) >> 25

    if x2_half > 50331648:
        phi = 0
    else:
        u2 = (x2_half * x2_half) >> 24
        u3 = (u2 * x2_half) >> 24
        u4 = (u2 * u2) >> 24
        exp_approx = Q24_ONE - x2_half + (u2 >> 1) - (u3 // 6) + (u4 // 24)
        if exp_approx < 0: exp_approx = 0
        phi = (INV_SQRT_2PI_Q24 * exp_approx) >> 24

    px = (P_CONST_Q24 * abs_x) >> 24
    if px > 15099494:
        t = 0
    else:
        # Exact Q8.24 division t = 1 / (1 + p*|x|) (matches iv_divider_q824 inside iv_norm_cdf.sv)
        denom = Q24_ONE + px
        t = q24_div(Q24_ONE, denom)

    # 5-Term Horner scheme evaluation (Abramowitz & Stegun 26.2.17)
    p5 = B5_Q24
    p4 = B4_Q24 + ((p5 * t) >> 24)
    p3 = B3_Q24 + ((p4 * t) >> 24)
    p2 = B2_Q24 + ((p3 * t) >> 24)
    p1 = B1_Q24 + ((p2 * t) >> 24)
    poly = (p1 * t) >> 24

    cdf_pos = Q24_ONE - ((phi * poly) >> 24)
    if cdf_pos < 0: cdf_pos = 0
    if cdf_pos > Q24_ONE: cdf_pos = Q24_ONE

    cdf = Q24_ONE - cdf_pos if is_neg else cdf_pos
    return cdf, phi

# =====================================================
# RTL-Accurate BS Call Price (matches iv_bs_datapath.sv)
# =====================================================
def hw_bs_call_price_q24(S_q, K_q, r_q, T_q, sigma_q):
    sqrt_T_q = q824_sqrt(T_q)

    # Padé ln(S/K) with saturation protection for S-K > 64 (matches iv_bs_datapath.sv)
    diff_sk = S_q - K_q
    if diff_sk > 1073741823:
        ln_num = 2147483647
    elif diff_sk < -1073741823:
        ln_num = -2147483647
    else:
        ln_num = diff_sk << 1

    ln_den = S_q + K_q
    if ln_den == 0: ln_den = 1
    ln_sk = q24_div(ln_num, ln_den)

    # d1 numerator: ln(S/K) + (r + sigma^2/2) * T
    sig2_half = (sigma_q * sigma_q) >> 25
    d1_num = ln_sk + (((r_q + sig2_half) * T_q) >> 24)

    # d1 denominator: sigma * sqrt(T)
    d1_den = (sigma_q * sqrt_T_q) >> 24
    if d1_den == 0: d1_den = 1

    d1 = q24_div(d1_num, d1_den)
    d2 = d1 - d1_den

    N_d1, phi_d1 = hw_norm_cdf_pdf(d1)
    N_d2, _      = hw_norm_cdf_pdf(d2)

    # 2nd-order Taylor exp(-rT) ≈ 1 - rT + (rT)^2 / 2
    rt = (r_q * T_q) >> 24
    rt2_half = (rt * rt) >> 25
    ert = Q24_ONE - rt + rt2_half
    if ert < 0: ert = 0
    if ert > Q24_ONE: ert = Q24_ONE

    # C_BS = S * N(d1) - K * ert * N(d2)
    term1 = (S_q * N_d1) >> 24
    term2 = (K_q * ((ert * N_d2) >> 24)) >> 24

    # Vega = S * sqrt(T) * phi(d1)
    vega = (S_q * sqrt_T_q) >> 24
    vega = (vega * phi_d1) >> 24

    c_bs = term1 - term2
    return c_bs, vega

# =====================================================
# RTL-Accurate Iterative NR IV Solver
# =====================================================
def hardware_q824_iv_model(S, K, C_market, r, T, max_iterations=8):
    S_q = to_q24(S)
    K_q = to_q24(K)
    C_q = to_q24(C_market)
    r_q = to_q24(r)
    T_q = to_q24(T)

    # Static 0.20 initial guess (matches RTL fallback value of 3355443)
    sigma_q = 3355443

    MIN_SIG_Q24 = 167772       # 0.01
    MAX_SIG_Q24 = 83886080     # 5.0
    MAX_STEP_Q24 = 4194304     # 0.25
    CONVERGENCE  = 167772      # $0.01

    for iteration in range(max_iterations):
        c_bs_q, vega_q = hw_bs_call_price_q24(S_q, K_q, r_q, T_q, sigma_q)
        price_err_q = C_q - c_bs_q

        if abs(price_err_q) <= CONVERGENCE:
            break

        if abs(vega_q) < 1:
            break
        delta_q = q24_div(price_err_q, vega_q)

        if delta_q > MAX_STEP_Q24:
            delta_q = MAX_STEP_Q24
        elif delta_q < -MAX_STEP_Q24:
            delta_q = -MAX_STEP_Q24

        sigma_q = sigma_q + delta_q

        if sigma_q < MIN_SIG_Q24:
            sigma_q = MIN_SIG_Q24
        elif sigma_q > MAX_SIG_Q24:
            sigma_q = MAX_SIG_Q24

    return from_q24(sigma_q)

# =====================================================
# Benchmark Runner
# =====================================================
def run_benchmark(n_samples=10000):
    print("=========================================================")
    print(f"Enhanced IV Engine RTL-Accurate Benchmark - {n_samples:,} Options")
    print("=========================================================")
    print("Architecture: Pipelined Q8.24 sqrt(T), Pade ln(S/K), 2nd-order exp, 5-term Horner CDF")
    print("NR: Iterative up to 8 iterations, static 0.20 initial guess")
    print("Dynamic Range: S, K in [10.0, 100.0] (Q8.24 max bound 127.99)")
    print()

    random.seed(42)
    golden_ivs = []
    hardware_ivs = []
    failed = 0

    start_t = time.time()
    for _ in range(n_samples):
        S = random.uniform(10.0, 100.0)
        K = S * random.uniform(0.85, 1.15)
        r = random.uniform(0.01, 0.08)
        T = random.uniform(0.05, 2.0)
        true_sigma = random.uniform(0.10, 0.70)

        C_market = bs_call_price(S, K, r, T, true_sigma)
        gold = brent_implied_volatility(S, K, C_market, r, T)
        hw = hardware_q824_iv_model(S, K, C_market, r, T)

        if gold is not None:
            golden_ivs.append(gold)
            hardware_ivs.append(hw)
        else:
            failed += 1

    elapsed = time.time() - start_t

    abs_errors = [abs(g - h) for g, h in zip(golden_ivs, hardware_ivs)]
    rel_errors = [abs(g - h) / max(abs(g), 1e-10) for g, h in zip(golden_ivs, hardware_ivs)]
    mae = sum(abs_errors) / len(abs_errors)
    max_err = max(abs_errors)
    rmse = math.sqrt(sum(e*e for e in abs_errors) / len(abs_errors))
    sorted_errs = sorted(abs_errors)
    p50_err = sorted_errs[int(0.50 * len(sorted_errs))]
    p95_err = sorted_errs[int(0.95 * len(sorted_errs))]
    p99_err = sorted_errs[int(0.99 * len(sorted_errs))]
    mean_rel_err = sum(rel_errors) / len(rel_errors)

    within_001 = sum(1 for e in abs_errors if e < 0.01) / len(abs_errors) * 100
    within_005 = sum(1 for e in abs_errors if e < 0.05) / len(abs_errors) * 100
    within_010 = sum(1 for e in abs_errors if e < 0.10) / len(abs_errors) * 100

    print("--- BENCHMARK ACCURACY RESULTS ---")
    print(f"Valid Evaluated       : {len(golden_ivs):,} / {n_samples:,} ({failed} failed)")
    print()
    print(f"Mean Absolute Error   : {mae:.6f} ({mae*100:.4f}% vol)")
    print(f"Root Mean Square Error: {rmse:.6f}")
    print(f"Mean Relative Error   : {mean_rel_err*100:.4f}%")
    print()
    print(f"Percentile Errors:")
    print(f"  50th (Median)       : {p50_err:.6f}")
    print(f"  95th                : {p95_err:.6f}")
    print(f"  99th                : {p99_err:.6f}")
    print(f"  Maximum             : {max_err:.6f}")
    print()
    print(f"Error Distribution:")
    print(f"  < 1% vol error      : {within_001:.1f}%")
    print(f"  < 5% vol error      : {within_005:.1f}%")
    print(f"  < 10% vol error     : {within_010:.1f}%")
    print()
    print(f"Execution Time        : {elapsed:.2f}s ({len(golden_ivs)/elapsed:.0f} ticks/sec)")
    print("=========================================================")

    if mae < 0.01:
        print("RESULT: SUCCESS - Hardware model accuracy meets institutional trading standards (< 1.0% MAE)!")
    else:
        print("RESULT: ACCURACY WARNING - Further tuning required.")

if __name__ == "__main__":
    run_benchmark(10000)
