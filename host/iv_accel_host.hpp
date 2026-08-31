// =========================================================
// C++ Host Accelerator Driver API (PCIe XDMA / QDMA Interface)
// =========================================================
// Provides high-throughput, low-latency streaming user-space driver
// for host quantitative trading algorithms.
//
// Build modes:
//   Simulation (default):  compile without any extra flags.
//                          process_batch() returns stub results.
//   XDMA Hardware:         compile with -DXDMA_HARDWARE
//                          process_batch() performs real DMA I/O
//                          via /dev/xdma0_h2c_0 and /dev/xdma0_c2h_0.
// =========================================================

#ifndef IV_ACCEL_HOST_HPP
#define IV_ACCEL_HOST_HPP

#include <iostream>
#include <vector>
#include <string>
#include <stdexcept>
#include <cstdint>
#include <cmath>
#include <chrono>

#ifdef XDMA_HARDWARE
#   include <fcntl.h>
#   include <unistd.h>
#   include <sys/ioctl.h>
#   include <cerrno>
#   include <cstring>
#endif

#pragma pack(push, 1)
// 256-bit Market Tick Payload (Host to Card)
// Packed in the exact bit-field order expected by iv_axis_wrapper.sv:
//   [31:0]    S_fixed           Q8.24 Spot Price
//   [63:32]   K_fixed           Q8.24 Strike Price
//   [95:64]   C_market_fixed    Q8.24 Market Call Price
//   [127:96]  r_fixed           Q8.24 Risk-free Rate
//   [159:128] T_fixed           Q8.24 Time-to-Maturity
//   [165:160] transaction_id    6-bit Transaction ID (low 6 bits of byte)
//   [255:166] reserved          Zero-padded
struct IvMarketTick {
    uint32_t S_fixed;           // Q8.24 Fixed-Point Spot Price
    uint32_t K_fixed;           // Q8.24 Fixed-Point Strike Price
    uint32_t C_market_fixed;    // Q8.24 Fixed-Point Market Option Price
    uint32_t r_fixed;           // Q8.24 Fixed-Point Risk-free Rate
    uint32_t T_fixed;           // Q8.24 Fixed-Point Time-to-Maturity
    uint8_t  transaction_id;    // 6-bit Transaction ID (bits [5:0] used)
    uint8_t  reserved[11];      // Padding → total 32 bytes = 256 bits
};
static_assert(sizeof(IvMarketTick) == 32,
    "IvMarketTick must be exactly 256 bits (32 bytes) for AXI4-Stream alignment.");

// 64-bit Volatility Output Payload (Card to Host)
// Packed by iv_multi_engine_top / iv_axis_wrapper:
//   [31:0]  iv_done_sigma     Q8.24 Implied Volatility
//   [37:32] iv_done_tid       6-bit Transaction ID
//   [63:38] reserved          Zero
struct IvResultPayload {
    uint32_t sigma_fixed;       // Q8.24 Fixed-Point Implied Volatility
    uint8_t  transaction_id;    // 6-bit Transaction ID (bits [5:0] used)
    uint8_t  reserved[3];       // Padding → total 8 bytes = 64 bits
};
static_assert(sizeof(IvResultPayload) == 8,
    "IvResultPayload must be exactly 64 bits (8 bytes) for AXI4-Stream alignment.");
#pragma pack(pop)

class IvAcceleratorHost {
public:
    IvAcceleratorHost();
    ~IvAcceleratorHost();

    // ----------------------------------------------------------
    // XDMA Device Management (Linux character device interface)
    // Requires: AMD XDMA kernel driver (xdma.ko) loaded.
    //           Typically located at /dev/xdma0_h2c_0 (H2C channel 0)
    //                              and /dev/xdma0_c2h_0 (C2H channel 0)
    //
    // Only available when compiled with -DXDMA_HARDWARE.
    // ----------------------------------------------------------
    void open_xdma_device(
        const std::string& h2c_device = "/dev/xdma0_h2c_0",
        const std::string& c2h_device = "/dev/xdma0_c2h_0"
    );
    void close_xdma_device();

    // Returns true if XDMA device is open and ready for DMA transfers
    bool is_hardware_mode() const;

    // ----------------------------------------------------------
    // Fixed-Point Q8.24 Conversion Helpers
    // Q8.24: 32-bit signed (1 sign, 7 integer, 24 fractional bits)
    //   Resolution:    2^-24 ≈ 5.96e-8
    //   Dynamic range: [-128.0, +127.9999999]
    // ----------------------------------------------------------
    static inline uint32_t float_to_q824(double val) {
        return static_cast<uint32_t>(static_cast<int32_t>(round(val * 16777216.0)));
    }

    static inline double q824_to_float(uint32_t fixed_val) {
        // Interpret as signed 32-bit before dividing
        return static_cast<double>(static_cast<int32_t>(fixed_val)) / 16777216.0;
    }

    // ----------------------------------------------------------
    // Process a batch of option market ticks through the engine.
    //
    // Hardware mode  (-DXDMA_HARDWARE + open_xdma_device() called):
    //   - Packs ticks into IvMarketTick (Q8.24, 32 bytes each)
    //   - Streams to FPGA via write() on H2C character device
    //   - Reads back IvResultPayload via read() on C2H device
    //   - Unpacks sigma and converts Q8.24 → double
    //
    // Simulation mode (default):
    //   - Returns 0.20 stub results for benchmark timing only
    // ----------------------------------------------------------
    std::vector<double> process_batch(
        const std::vector<double>& spot_prices,
        const std::vector<double>& strike_prices,
        const std::vector<double>& market_prices,
        const std::vector<double>& rates,
        const std::vector<double>& maturities
    );

private:
#ifdef XDMA_HARDWARE
    int m_h2c_fd = -1;    // H2C (Host-to-Card) file descriptor
    int m_c2h_fd = -1;    // C2H (Card-to-Host) file descriptor
#endif
};

#endif // IV_ACCEL_HOST_HPP
