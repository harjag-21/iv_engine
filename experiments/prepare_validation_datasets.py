# Dataset preparation script
import os, sys, json, math, hashlib
import numpy as np
import pandas as pd
from scipy.stats import norm
from scipy.optimize import brentq

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
DATA_DIR = os.path.join(REPO_ROOT, 'experiments', 'data')
os.makedirs(DATA_DIR, exist_ok=True)

def bs_call_price(S, K, r, T, sigma):
    if sigma <= 1e-8 or T <= 1e-8:
        return max(0.0, S - K * math.exp(-r * T))
    sqrt_T = math.sqrt(T)
    d1 = (math.log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * sqrt_T)
    d2 = d1 - sigma * sqrt_T
    return S * norm.cdf(d1) - K * math.exp(-r * T) * norm.cdf(d2)

def bs_greeks(S, K, r, T, sigma):
    if sigma <= 1e-8 or T <= 1e-8:
        delta = 1.0 if S >= K else 0.0
        return delta, 0.0, 0.0
    sqrt_T = math.sqrt(T)
    d1 = (math.log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * sqrt_T)
    pdf_d1 = norm.pdf(d1)
    delta = norm.cdf(d1)
    vega = S * sqrt_T * pdf_d1
    gamma = pdf_d1 / (S * sigma * sqrt_T) if (S * sigma * sqrt_T) > 1e-10 else 0.0
    return delta, vega, gamma

def scipy_solve_iv(S, K, C_mkt, r, T):
    disc_intrinsic = max(0.0, S - K * math.exp(-r * T))
    if C_mkt <= disc_intrinsic or C_mkt >= S:
        return None
    sqrt_T = math.sqrt(T)
    def obj(sig):
        d1 = (math.log(S / K) + (r + 0.5 * sig * sig) * T) / (sig * sqrt_T)
        d2 = d1 - sig * sqrt_T
        return S * norm.cdf(d1) - K * math.exp(-r * T) * norm.cdf(d2) - C_mkt
    try:
        return brentq(obj, 0.001, 5.0, xtol=1e-8, maxiter=100)
    except Exception:
        return None

def compute_sha256(filepath):
    h = hashlib.sha256()
    with open(filepath, 'rb') as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

def generate_dataset_a():
    out_csv = os.path.join(DATA_DIR, 'dataset_a_canonical_10k.csv')
    print('Generating Dataset A (10,000 Canonical)...')
    np.random.seed(42)
    N = 10000
    rows = []
    for i in range(N):
        S = float(np.random.uniform(20.0, 80.0))
        k_ratio = float(np.random.uniform(0.70, 1.40))
        K = S * k_ratio
        T = float(np.random.uniform(0.10, 1.50))
        r = float(np.random.uniform(0.02, 0.06))
        true_iv = float(np.random.uniform(0.15, 0.55))
        C = bs_call_price(S, K, r, T, true_iv)
        delta, vega, gamma = bs_greeks(S, K, r, T, true_iv)
        is_liq = 1 if (0.85 <= (S / K) <= 1.15) else 0
        rows.append({
            'tick': i, 'S': S, 'K': K, 'C': C, 'r': r, 'T': T,
            'true_iv': true_iv, 'true_delta': delta, 'true_vega': vega, 'true_gamma': gamma,
            'is_liquid': is_liq
        })
    df = pd.DataFrame(rows)
    df.to_csv(out_csv, index=False, float_format='%.6f')
    sha = compute_sha256(out_csv)
    print(f'  -> {out_csv} ({len(df)} rows, SHA-256: {sha[:16]}...)')
    return {'path': out_csv, 'count': len(df), 'sha256': sha}

def generate_dataset_b():
    out_csv = os.path.join(DATA_DIR, 'dataset_b_random_100k.csv')
    print('Generating Dataset B (100,000 Randomized)...')
    np.random.seed(42)
    N = 100000
    rows = []
    for i in range(N):
        S = float(np.random.uniform(20.0, 80.0))
        k_ratio = float(np.random.uniform(0.70, 1.40))
        K = S * k_ratio
        T = float(np.random.uniform(0.05, 2.00))
        r = float(np.random.uniform(0.01, 0.08))
        true_iv = float(np.random.uniform(0.10, 0.70))
        C = bs_call_price(S, K, r, T, true_iv)
        delta, vega, gamma = bs_greeks(S, K, r, T, true_iv)
        is_liq = 1 if (0.85 <= (S / K) <= 1.15) else 0
        rows.append({
            'tick': i, 'S': S, 'K': K, 'C': C, 'r': r, 'T': T,
            'true_iv': true_iv, 'true_delta': delta, 'true_vega': vega, 'true_gamma': gamma,
            'is_liquid': is_liq
        })
    df = pd.DataFrame(rows)
    df.to_csv(out_csv, index=False, float_format='%.6f')
    sha = compute_sha256(out_csv)
    print(f'  -> {out_csv} ({len(df)} rows, SHA-256: {sha[:16]}...)')
    return {'path': out_csv, 'count': len(df), 'sha256': sha}

def generate_dataset_c():
    out_csv = os.path.join(DATA_DIR, 'dataset_c_boundary_2500.csv')
    print('Generating Dataset C (2,500 Boundary Surface)...')
    json_path = os.path.join(DATA_DIR, 'stress_map_2d.json')
    with open(json_path, 'r') as f:
        sdata = json.load(f)
    
    mny_grid = sdata['grid_axes']['moneyness_SK']
    t_grid = sdata['grid_axes']['maturity_T_years']
    fixed_r = sdata['metadata']['fixed_r']
    fixed_sigma = sdata['metadata']['fixed_sigma']
    spot = sdata['metadata']['spot']

    rows = []
    tick = 0
    for m in mny_grid:
        strike = spot / m
        for T in t_grid:
            C = bs_call_price(spot, strike, fixed_r, T, fixed_sigma)
            delta, vega, gamma = bs_greeks(spot, strike, fixed_r, T, fixed_sigma)
            is_liq = 1 if (0.85 <= m <= 1.15) else 0
            rows.append({
                'tick': tick, 'S': spot, 'K': strike, 'C': C, 'r': fixed_r, 'T': T,
                'true_iv': fixed_sigma, 'true_delta': delta, 'true_vega': vega, 'true_gamma': gamma,
                'is_liquid': is_liq
            })
            tick += 1
    df = pd.DataFrame(rows)
    df.to_csv(out_csv, index=False, float_format='%.6f')
    sha = compute_sha256(out_csv)
    print(f'  -> {out_csv} ({len(df)} rows, SHA-256: {sha[:16]}...)')
    return {'path': out_csv, 'count': len(df), 'sha256': sha}

def generate_dataset_d():
    out_csv = os.path.join(DATA_DIR, 'dataset_d_spx_1382.csv')
    print('Generating Dataset D (1,382 Real-World CBOE SPX)...')
    spx_csv = os.path.join(DATA_DIR, 'spx_1382_contracts.csv')
    df_raw = pd.read_csv(spx_csv)

    rows = []
    tick = 0
    for idx, row in df_raw.iterrows():
        S = float(row['S'])
        K = float(row['K'])
        C = float(row['C'])
        T = float(row['T'])
        r = float(row['r'])

        s_dim = S / K
        k_dim = 1.0
        c_dim = C / K

        true_iv = scipy_solve_iv(s_dim, k_dim, c_dim, r, T)
        if true_iv is None or true_iv <= 0.001 or true_iv > 3.0:
            true_iv = float(row['market_iv'])

        delta, vega, gamma = bs_greeks(s_dim, k_dim, r, T, true_iv)
        is_liq = 1 if (0.85 <= s_dim <= 1.15) else 0

        rows.append({
            'tick': tick, 'S': s_dim, 'K': k_dim, 'C': c_dim, 'r': r, 'T': T,
            'true_iv': true_iv, 'true_delta': delta, 'true_vega': vega, 'true_gamma': gamma,
            'is_liquid': is_liq
        })
        tick += 1

    df = pd.DataFrame(rows)
    df.to_csv(out_csv, index=False, float_format='%.6f')
    sha = compute_sha256(out_csv)
    print(f'  -> {out_csv} ({len(df)} rows, SHA-256: {sha[:16]}...)')
    return {'path': out_csv, 'count': len(df), 'sha256': sha}

def main():
    print('=' * 80)
    print('PREPARING REPRODUCIBLE BENCHMARK DATASETS (ACM/SIGDA FPGA 2027)')
    print('=' * 80)
    manifest = {}
    manifest['dataset_a'] = generate_dataset_a()
    manifest['dataset_b'] = generate_dataset_b()
    manifest['dataset_c'] = generate_dataset_c()
    manifest['dataset_d'] = generate_dataset_d()

    manifest_path = os.path.join(DATA_DIR, 'validation_datasets_manifest.json')
    with open(manifest_path, 'w') as f:
        json.dump(manifest, f, indent=2)
    print('\nManifest written to:', manifest_path)
    print('=' * 80)

if __name__ == '__main__':
    main()
