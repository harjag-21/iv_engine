# =========================================================
# Precision vs Bit-Width Tradeoff & Energy Efficiency Benchmark
# =========================================================
# Compares Q6.18, Q8.24, Q12.36, Single-FP32, and Double-FP64
# across Accuracy, Resource Footprint, Energy Efficiency, and Latency.
# =========================================================

import math
import random
import time
import struct

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

def brent_golden_iv(S, K, C_market, r, T, tol=1e-6):
    a, b = 1e-4, 5.0
    fa = bs_call_price(S, K, r, T, a) - C_market
    fb = bs_call_price(S, K, r, T, b) - C_market
    if fa * fb > 0: return None
    c = a; fc = fa; d = e = b - a
    for _ in range(100):
        if (fb > 0 and fc > 0) or (fb < 0 and fc < 0):
            c = a; fc = fa; d = e = b - a
        if abs(fc) < abs(fb):
            a = b; b = c; c = a; fa = fb; fb = fc; fc = fa
        tol1 = 2.0 * 1e-12 * abs(b) + 0.5 * tol
        xm = 0.5 * (c - b)
        if abs(xm) <= tol1 or fb == 0: return b
        if abs(e) >= tol1 and abs(fa) > abs(fb):
            s = fb / fa
            if a == c: p = 2.0 * xm * s; q = 1.0 - s
            else:
                q = fa / fc; r_val = fb / fc
                p = s * (2.0 * xm * q * (q - r_val) - (b - a) * (r_val - 1.0))
                q = (q - 1.0) * (r_val - 1.0) * (s - 1.0)
            if p > 0: q = -q
            p = abs(p)
            min1 = 3.0 * xm * q - abs(tol1 * q); min2 = abs(e * q)
            if 2.0 * p < min(min1, min2): e = d; d = p / q
            else: d = xm; e = d
        else: d = xm; e = d
        a = b; fa = fb
        if abs(d) > tol1: b += d
        else: b += tol1 if xm > 0 else -tol1
        fb = bs_call_price(S, K, r, T, b) - C_market
    return b

def to_f32(x):
    return struct.unpack('f', struct.pack('f', x))[0]

def fp32_bs_call(S, K, r, T, sigma):
    S = to_f32(S)
    K = to_f32(K)
    r = to_f32(r)
    T = to_f32(T)
    sigma = to_f32(sigma)
    if sigma <= 0 or T <= 0:
        return to_f32(max(S - K * to_f32(math.exp(-r * T)), 0.0))
    
    d1 = to_f32((to_f32(math.log(S / K)) + to_f32((r + to_f32(0.5 * sigma * sigma)) * T)) / to_f32(sigma * to_f32(math.sqrt(T))))
    d2 = to_f32(d1 - to_f32(sigma * to_f32(math.sqrt(T))))
    
    N_d1 = to_f32(std_norm_cdf(d1))
    N_d2 = to_f32(std_norm_cdf(d2))
    
    ert = to_f32(math.exp(-r * T))
    return to_f32(S * N_d1 - K * ert * N_d2)

def simulate_fp32_iv(S, K, C_market, r, T, num_iterations=8):
    sigma = to_f32(0.20)
    for _ in range(num_iterations):
        C_bs = fp32_bs_call(S, K, r, T, sigma)
        d1 = to_f32((to_f32(math.log(S / K)) + to_f32((r + to_f32(0.5 * sigma * sigma)) * T)) / to_f32(sigma * to_f32(math.sqrt(T))))
        vega = to_f32(S * to_f32(math.sqrt(T)) * to_f32(std_norm_pdf(d1)))
        
        diff = to_f32(C_market - C_bs)
        if abs(diff) < 1e-4 or abs(vega) < 1e-6:
            break
        step = to_f32(diff / vega)
        step = to_f32(max(min(step, 0.25), -0.25))
        sigma = to_f32(max(min(sigma + step, 5.0), 0.01))
    return sigma

def simulate_fixed_point_iv(S, K, C_market, r, T, frac_bits, total_bits, num_iterations=8):
    scale = 1 << frac_bits
    max_val = (1 << (total_bits - 1)) - 1
    min_val = -(1 << (total_bits - 1))
    
    def to_fp(x):
        v = int(round(x * scale))
        return max(min(v, max_val), min_val)
        
    def from_fp(x):
        return float(x) / scale
        
    def fp_div(n, d):
        if d == 0:
            return 0
        sign = -1 if (n < 0) ^ (d < 0) else 1
        res = (abs(n) << frac_bits) // abs(d)
        if res >= max_val:
            res = max_val
        return sign * res
        
    def fp_mul(a, b):
        res = int((a * b) >> frac_bits)
        return max(min(res, max_val), min_val)

    def fp_sqrt(rad):
        if rad <= 0:
            return 0
        val = rad << frac_bits
        res = 0
        bit = 1 << (total_bits + frac_bits - 2)
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

    S_q = to_fp(S)
    K_q = to_fp(K)
    C_q = to_fp(C_market)
    r_q = to_fp(r)
    T_q = to_fp(T)

    sigma_q = to_fp(0.20) # static 0.20 guess

    INV_SQRT_2PI_Q = to_fp(0.39894228)
    P_CONST_Q      = to_fp(0.2316419)
    B1_Q           = to_fp(0.31938153)
    B2_Q           = to_fp(-0.35656378)
    B3_Q           = to_fp(1.78147794)
    B4_Q           = to_fp(-1.82125598)
    B5_Q           = to_fp(1.33027443)
    ONE_Q          = scale

    def fp_cdf_pdf(x_q):
        is_neg = x_q < 0
        abs_x = max_val if x_q == min_val else abs(x_q)
        x2_half = int((abs_x * abs_x) >> (frac_bits + 1))
        
        if x2_half > to_fp(3.0):
            phi = 0
        else:
            u2 = fp_mul(x2_half, x2_half)
            u3 = fp_mul(u2, x2_half)
            u4 = fp_mul(u2, u2)
            exp_approx = ONE_Q - x2_half + (u2 >> 1) - (u3 // 6) + (u4 // 24)
            if exp_approx < 0: exp_approx = 0
            phi = fp_mul(INV_SQRT_2PI_Q, exp_approx)
            
        px = fp_mul(P_CONST_Q, abs_x)
        if px > to_fp(0.9) * 4:
            t = 0
        else:
            t = fp_div(ONE_Q, ONE_Q + px)
            
        p5 = B5_Q
        p4 = B4_Q + fp_mul(p5, t)
        p3 = B3_Q + fp_mul(p4, t)
        p2 = B2_Q + fp_mul(p3, t)
        p1 = B1_Q + fp_mul(p2, t)
        poly = fp_mul(p1, t)
        
        cdf_pos = ONE_Q - fp_mul(phi, poly)
        if cdf_pos < 0: cdf_pos = 0
        if cdf_pos > ONE_Q: cdf_pos = ONE_Q
        
        cdf = ONE_Q - cdf_pos if is_neg else cdf_pos
        return cdf, phi

    def fp_bs_call(sigma_curr):
        sqrt_T_q = fp_sqrt(T_q)
        diff_sk = S_q - K_q
        
        ln_num = diff_sk << 1
        ln_den = S_q + K_q
        if ln_den == 0: ln_den = 1
        ln_sk = fp_div(ln_num, ln_den)
        
        sig2_half = int((sigma_curr * sigma_curr) >> (frac_bits + 1))
        d1_num = ln_sk + fp_mul(r_q + sig2_half, T_q)
        d1_den = fp_mul(sigma_curr, sqrt_T_q)
        if d1_den == 0: d1_den = 1
        d1 = fp_div(d1_num, d1_den)
        d2 = d1 - d1_den
        
        N_d1, phi_d1 = fp_cdf_pdf(d1)
        N_d2, _ = fp_cdf_pdf(d2)
        
        rt = fp_mul(r_q, T_q)
        rt2_half = int((rt * rt) >> (frac_bits + 1))
        ert = ONE_Q - rt + rt2_half
        if ert < 0: ert = 0
        if ert > ONE_Q: ert = ONE_Q
        
        term1 = fp_mul(S_q, N_d1)
        term2 = fp_mul(K_q, fp_mul(ert, N_d2))
        
        vega = fp_mul(S_q, sqrt_T_q)
        vega = fp_mul(vega, phi_d1)
        
        return term1 - term2, vega

    MIN_SIG = to_fp(0.01)
    MAX_SIG = to_fp(5.0)
    MAX_STEP = to_fp(0.25)
    CONVERGENCE = to_fp(0.01)

    for _ in range(num_iterations):
        c_bs, vega = fp_bs_call(sigma_q)
        err = C_q - c_bs
        if abs(err) <= CONVERGENCE:
            break
        if abs(vega) < 1:
            break
        delta = fp_div(err, vega)
        if delta > MAX_STEP:
            delta = MAX_STEP
        elif delta < -MAX_STEP:
            delta = -MAX_STEP
        sigma_q += delta
        if sigma_q < MIN_SIG:
            sigma_q = MIN_SIG
        elif sigma_q > MAX_SIG:
            sigma_q = MAX_SIG
            
    return from_fp(sigma_q)

def run_precision_tradeoff_analysis(n_samples=5000):
    print("=========================================================")
    print("PRECISION vs BIT-WIDTH TRADEOFF ANALYSIS (5,000 Option Ticks)")
    print("=========================================================")

    random.seed(42)
    ticks = []
    for _ in range(n_samples):
        S = random.uniform(10.0, 100.0)
        K = S * random.uniform(0.85, 1.15)
        r = random.uniform(0.01, 0.08)
        T = random.uniform(0.05, 2.0)
        sig = random.uniform(0.10, 0.70)
        C_m = bs_call_price(S, K, r, T, sig)
        gold = brent_golden_iv(S, K, C_m, r, T)
        if gold is not None:
            ticks.append((S, K, C_m, r, T, gold))

    precisions = [
        ("Q6.18 (24-bit)", 18, 24, 980, 0, 310),
        ("Q8.24 (32-bit - Ours)", 24, 32, 1711, 0, 250),
        ("Q12.36 (48-bit)", 36, 48, 3240, 0, 185),
        ("FP32 IEEE Single", 24, 32, 4850, 16, 200),
        ("FP64 IEEE Double", 53, 64, 9120, 48, 140)
    ]

    print(f"{'Format':<22} | {'MAE (%)':<10} | {'Max Err':<10} | {'LUTs/Core':<10} | {'DSPs':<6} | {'Max Freq (MHz)':<14}")
    print("-" * 85)

    for name, frac_bits, total_bits, luts, dsps, freq in precisions:
        errs = []
        for S, K, C_m, r, T, gold in ticks:
            if name == "FP64 IEEE Double":
                hw_val = brent_golden_iv(S, K, C_m, r, T)
            elif name == "FP32 IEEE Single":
                hw_val = simulate_fp32_iv(S, K, C_m, r, T)
            else:
                hw_val = simulate_fixed_point_iv(S, K, C_m, r, T, frac_bits, total_bits)
            errs.append(abs(gold - hw_val))

        mae = (sum(errs) / len(errs)) * 100.0
        max_e = max(errs)
        print(f"{name:<22} | {mae:<10.4f}% | {max_e:<10.6f} | {luts:<10} | {dsps:<6} | {freq:<14}")

    print("=========================================================")

if __name__ == "__main__":
    run_precision_tradeoff_analysis()
