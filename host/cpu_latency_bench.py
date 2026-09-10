"""
CPU Implied Volatility Latency Benchmark
Single-threaded, warm-cache, iterative Newton-Raphson IV solver.
Measures per-contract latency distribution (p50, p95, p99, p99.9).
This matches the hardware single-contract latency measurement basis.
"""

import time
import math
import statistics
import os

# ────────────────────────────────────────────────────────────────────────────
# Black-Scholes utilities (pure Python, no vectorisation, matches hardware eval)
# ────────────────────────────────────────────────────────────────────────────

def norm_cdf(x):
    """Abramowitz & Stegun 5th-order rational poly approximation, same as Horner CDF in hardware."""
    t = 1.0 / (1.0 + 0.2316419 * abs(x))
    poly = t * (0.319381530 + t * (-0.356563782 + t * (1.781477937 + t * (-1.821255978 + t * 1.330274429))))
    cdf = 1.0 - (1.0 / math.sqrt(2.0 * math.pi)) * math.exp(-0.5 * x * x) * poly
    return cdf if x >= 0 else 1.0 - cdf

def bs_price(S, K, T, r, sigma):
    sqrtT = math.sqrt(T)
    d1 = (math.log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * sqrtT)
    d2 = d1 - sigma * sqrtT
    return S * norm_cdf(d1) - K * math.exp(-r * T) * norm_cdf(d2), norm_cdf(d1), S * sqrtT * norm_cdf_pdf(d1)

def norm_cdf_pdf(x):
    return math.exp(-0.5 * x * x) / math.sqrt(2.0 * math.pi)

def bs_vega(S, T, d1):
    return S * math.sqrt(T) * norm_cdf_pdf(d1)

def implied_vol_nr(S, K, T, r, C_mkt, max_iter=50, tol=1e-4):
    """Newton-Raphson IV solver with B-S seed, matching hardware algorithm."""
    # Brenner-Subrahmanyam seed
    sigma = (math.sqrt(2 * math.pi) / math.sqrt(T)) * (C_mkt / ((S + K) / 2.0))
    sigma = max(0.05, min(3.0, sigma))

    for _ in range(max_iter):
        sqrtT = math.sqrt(T)
        try:
            d1 = (math.log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * sqrtT)
        except ValueError:
            break
        d2 = d1 - sigma * sqrtT
        C_bs = S * norm_cdf(d1) - K * math.exp(-r * T) * norm_cdf(d2)
        vega = S * sqrtT * norm_cdf_pdf(d1)
        err = C_bs - C_mkt
        if abs(err) <= tol:
            break
        if abs(vega) < 1e-10:
            break
        step = err / vega
        step = max(-0.25, min(0.25, step))
        sigma = sigma - step
        sigma = max(0.01, min(5.0, sigma))
    return sigma


# ────────────────────────────────────────────────────────────────────────────
# Benchmark
# ────────────────────────────────────────────────────────────────────────────

import random

def benchmark(N=100_000, seed=42):
    rng = random.Random(seed)

    # Generate contracts (same distribution as DPI-C simulation)
    contracts = []
    for _ in range(N):
        S   = rng.uniform(20.0, 80.0)
        mny = rng.uniform(0.70, 1.40)
        K   = S * mny
        T   = rng.uniform(0.05, 1.5)
        r   = rng.uniform(0.02, 0.06)
        sv  = rng.uniform(0.15, 0.55)
        # Ground-truth price
        sqrtT = math.sqrt(T)
        d1 = (math.log(S / K) + (r + 0.5 * sv * sv) * T) / (sv * sqrtT)
        d2 = d1 - sv * sqrtT
        C  = S * norm_cdf(d1) - K * math.exp(-r * T) * norm_cdf(d2)
        contracts.append((S, K, T, r, max(C, 0.001)))

    # Warm-up pass (cache warmup)
    for contract in contracts[:1000]:
        implied_vol_nr(*contract)

    # Timed pass — measure per-contract latency
    latencies_ns = []
    for contract in contracts:
        t0 = time.perf_counter_ns()
        implied_vol_nr(*contract)
        t1 = time.perf_counter_ns()
        latencies_ns.append(t1 - t0)

    latencies_us = [l / 1000.0 for l in latencies_ns]
    latencies_us.sort()

    n = len(latencies_us)
    p50   = latencies_us[int(n * 0.500)]
    p95   = latencies_us[int(n * 0.950)]
    p99   = latencies_us[int(n * 0.990)]
    p999  = latencies_us[int(n * 0.999)]
    mean_ = statistics.mean(latencies_us)

    print("=" * 60)
    print("CPU IV Latency Benchmark (Single-Threaded, Warm Cache)")
    print(f"  N = {N:,} contracts")
    print(f"  Python iterative NR (B-S seed, same alg as hardware)")
    print("=" * 60)
    print(f"  Mean:    {mean_:.3f} µs")
    print(f"  p50:     {p50:.3f} µs")
    print(f"  p95:     {p95:.3f} µs")
    print(f"  p99:     {p99:.3f} µs")
    print(f"  p99.9:   {p999:.3f} µs")
    print(f"  Max:     {max(latencies_us):.3f} µs")
    print("=" * 60)
    print(f"\nNote: This is Python, not a compiled C/C++ benchmark.")
    print(f"A compiled AVX2 C benchmark would be ~10-20x faster.")
    print(f"The 14.22 MOps/s throughput figure from the OpenMP/AVX2")
    print(f"benchmark implies ~{1e6/14.22:.1f} ns per-contract latency")
    print(f"at full throughput (not cold latency).")

    return p50, p95, p99, p999

if __name__ == "__main__":
    benchmark()
