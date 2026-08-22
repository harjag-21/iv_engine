// =========================================================
// C++ Host Accelerator Driver API (PCIe XDMA / QDMA Interface)
// =========================================================
// Provides high-throughput, low-latency streaming user-space driver
// for host quantitative trading algorithms.
// =========================================================

#ifndef IV_ACCEL_HOST_HPP
#define IV_ACCEL_HOST_HPP

#include <iostream>
#include <vector>
#include <cstdint>
#include <cmath>
#include <chrono>

#pragma pack(push, 1)
// 256-bit Market Tick Payload (Host to Card)
struct IvMarketTick {
    uint32_t S_fixed;       // Q8.24 Fixed-Point Spot Price
    uint32_t K_fixed;       // Q8.24 Fixed-Point Strike Price
    uint32_t C_market_fixed;// Q8.24 Fixed-Point Market Option Price
    uint32_t r_fixed;       // Q8.24 Fixed-Point Risk-free Rate
    uint32_t T_fixed;       // Q8.24 Fixed-Point Time-to-Maturity
    uint8_t  transaction_id;// 6-bit Transaction ID
    uint8_t  reserved[11];  // Padding to align to 32 bytes (256 bits)
};

// 64-bit Volatility Output Payload (Card to Host)
struct IvResultPayload {
    uint32_t sigma_fixed;   // Q8.24 Fixed-Point Implied Volatility
    uint8_t  transaction_id;// 6-bit Transaction ID
    uint8_t  reserved[3];   // Padding to align to 8 bytes (64 bits)
};
#pragma pack(pop)

class IvAcceleratorHost {
public:
    IvAcceleratorHost();
    ~IvAcceleratorHost();

    // Helper functions for fixed-point Q8.24 conversion
    static inline uint32_t float_to_q824(double val) {
        return static_cast<uint32_t>(round(val * 16777216.0));
    }

    static inline double q824_to_float(uint32_t fixed_val) {
        return static_cast<double>(fixed_val) / 16777216.0;
    }

    // Process a batch of option market ticks through the hardware engine
    std::vector<double> process_batch(
        const std::vector<double>& spot_prices,
        const std::vector<double>& strike_prices,
        const std::vector<double>& market_prices,
        const std::vector<double>& rates,
        const std::vector<double>& maturities
    );
};

#endif // IV_ACCEL_HOST_HPP
