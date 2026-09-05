#include <iostream>
#include <vector>
#include <cmath>
#include <chrono>
#include <random>
#include <iomanip>
#include <omp.h>

static inline double norm_cdf(double x) {
    return 0.5 * std::erfc(-x * 0.70710678118654752440);
}

static inline double phi(double x) {
    return std::exp(-0.5 * x * x) * 0.39894228040143267794;
}

static inline double bs_call_price(double S, double K, double r, double T, double sigma) {
    if (sigma <= 1e-8 || T <= 1e-8) return std::max(S - K * std::exp(-r * T), 0.0);
    double sqrt_T = std::sqrt(T);
    double d1 = (std::log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * sqrt_T);
    double d2 = d1 - sigma * sqrt_T;
    return S * norm_cdf(d1) - K * std::exp(-r * T) * norm_cdf(d2);
}

static inline double bs_vega(double S, double K, double r, double T, double sigma) {
    if (sigma <= 1e-8 || T <= 1e-8) return 0.0;
    double sqrt_T = std::sqrt(T);
    double d1 = (std::log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * sqrt_T);
    return S * sqrt_T * phi(d1);
}

static inline double solve_iv_nr(double S, double K, double C_market, double r, double T) {
    double avg_sk = 0.5 * (S + K);
    double sqrt_T = std::sqrt(T);
    double sigma_0 = (C_market * 2.5066282746310002) / (avg_sk * sqrt_T);
    if (sigma_0 < 0.05) sigma_0 = 0.05;
    if (sigma_0 > 3.00) sigma_0 = 0.20;

    double sigma = sigma_0;
    for (int iter = 0; iter < 8; ++iter) {
        double price = bs_call_price(S, K, r, T, sigma);
        double err = price - C_market;
        if (std::abs(err) < 0.01) break;

        double vega = bs_vega(S, K, r, T, sigma);
        if (std::abs(vega) < 1e-8) break;

        double delta = err / vega;
        sigma -= delta;
        if (sigma < 0.001) sigma = 0.001;
        if (sigma > 5.000) sigma = 5.000;
    }
    return sigma;
}

struct OptionContract {
    double S, K, C, r, T, true_sigma;
};

int main(int argc, char* argv[]) {
    size_t N = (argc > 1) ? std::stoull(argv[1]) : 2000000;
    std::cout << "=========================================================" << std::endl;
    std::cout << " CPU Benchmark: Black-Scholes Implied Volatility Solver " << std::endl;
    std::cout << " Contracts: " << N << std::endl;
    std::cout << " Hardware Threads: " << omp_get_max_threads() << std::endl;
    std::cout << "=========================================================" << std::endl;

    std::vector<OptionContract> contracts(N);
    std::mt19937 rng(42);
    std::uniform_real_distribution<double> dist_S(20.0, 80.0);
    std::uniform_real_distribution<double> dist_m(0.90, 1.10);
    std::uniform_real_distribution<double> dist_T(0.10, 1.50);
    std::uniform_real_distribution<double> dist_r(0.02, 0.06);
    std::uniform_real_distribution<double> dist_v(0.15, 0.55);

    for (size_t i = 0; i < N; ++i) {
        double S = dist_S(rng);
        double K = S * dist_m(rng);
        double T = dist_T(rng);
        double r = dist_r(rng);
        double sig = dist_v(rng);
        double C = bs_call_price(S, K, r, T, sig);
        contracts[i] = {S, K, C, r, T, sig};
    }

    std::vector<double> results(N);

    size_t n_st = std::min(N, (size_t)200000);
    auto t0 = std::chrono::high_resolution_clock::now();
    for (size_t i = 0; i < n_st; ++i) {
        results[i] = solve_iv_nr(contracts[i].S, contracts[i].K, contracts[i].C, contracts[i].r, contracts[i].T);
    }
    auto t1 = std::chrono::high_resolution_clock::now();
    double dt_st = std::chrono::duration<double>(t1 - t0).count();
    double ops_st = n_st / dt_st;
    double lat_st_us = (dt_st / n_st) * 1e6;

    std::cout << "\n--- SINGLE-THREADED EXECUTION ---" << std::endl;
    std::cout << "Evaluated       : " << n_st << " contracts" << std::endl;
    std::cout << "Execution Time  : " << std::fixed << std::setprecision(4) << dt_st << " s" << std::endl;
    std::cout << "Throughput      : " << std::fixed << std::setprecision(2) << (ops_st / 1e6) << " MOps/sec" << std::endl;
    std::cout << "Average Latency : " << std::fixed << std::setprecision(3) << lat_st_us << " us / contract" << std::endl;

    auto t2 = std::chrono::high_resolution_clock::now();
    #pragma omp parallel for schedule(static)
    for (size_t i = 0; i < N; ++i) {
        results[i] = solve_iv_nr(contracts[i].S, contracts[i].K, contracts[i].C, contracts[i].r, contracts[i].T);
    }
    auto t3 = std::chrono::high_resolution_clock::now();
    double dt_mt = std::chrono::duration<double>(t3 - t2).count();
    double ops_mt = N / dt_mt;
    double lat_mt_us = (dt_mt / N) * 1e6;

    std::cout << "\n--- MULTI-THREADED EXECUTION (" << omp_get_max_threads() << " THREADS) ---" << std::endl;
    std::cout << "Evaluated       : " << N << " contracts" << std::endl;
    std::cout << "Execution Time  : " << std::fixed << std::setprecision(4) << dt_mt << " s" << std::endl;
    std::cout << "Throughput      : " << std::fixed << std::setprecision(2) << (ops_mt / 1e6) << " MOps/sec" << std::endl;
    std::cout << "Effective Rate  : " << std::fixed << std::setprecision(3) << lat_mt_us << " us / contract (amortized)" << std::endl;

    double sum_err = 0.0, max_err = 0.0;
    for (size_t i = 0; i < N; ++i) {
        double err = std::abs(results[i] - contracts[i].true_sigma);
        sum_err += err;
        if (err > max_err) max_err = err;
    }
    std::cout << "Mean Abs Error  : " << std::fixed << std::setprecision(6) << (sum_err / N) << std::endl;
    std::cout << "Max Abs Error   : " << std::fixed << std::setprecision(6) << max_err << std::endl;

    double cpu_power_w = 45.0; 
    double cpu_eff = (ops_mt / 1e3) / cpu_power_w;

    double fpga_thru = 400.0 * 1e6;
    double fpga_power = 4.258;
    double fpga_eff = (fpga_thru / 1e3) / fpga_power;

    std::cout << "\n=========================================================" << std::endl;
    std::cout << " HETEROGENEOUS EFFICIENCY COMPARISON " << std::endl;
    std::cout << "=========================================================" << std::endl;
    std::cout << " Metric                  | Host CPU (i5-12500H)  | Proposed 4-Core FPGA" << std::endl;
    std::cout << "-------------------------+-----------------------+----------------------" << std::endl;
    std::cout << " Throughput              | " << std::setw(15) << (ops_mt / 1e6) << " MOps/s | " << std::setw(14) << "400.00 MOps/s" << std::endl;
    std::cout << " Power                   | " << std::setw(15) << cpu_power_w << " W      | " << std::setw(14) << "4.26 W" << std::endl;
    std::cout << " Energy Efficiency       | " << std::setw(15) << (int)cpu_eff << " kOps/W | " << std::setw(14) << (int)fpga_eff << " kOps/W" << std::endl;
    std::cout << " Efficiency Advantage    |               Baseline| " << std::setw(11) << std::setprecision(1) << (fpga_eff / cpu_eff) << "x higher" << std::endl;
    std::cout << " Single-Tick Latency     | " << std::setw(15) << std::setprecision(3) << lat_st_us << " us   | " << std::setw(14) << "1.26 us (det)" << std::endl;
    std::cout << "=========================================================" << std::endl;

    return 0;
}
