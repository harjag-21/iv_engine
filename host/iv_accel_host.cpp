// =========================================================
// C++ Host Accelerator Driver Implementation
// =========================================================
// Hardware mode: compile with -DXDMA_HARDWARE
//   Uses POSIX read()/write() on AMD XDMA character devices
//   (/dev/xdma0_h2c_0, /dev/xdma0_c2h_0) for PCIe DMA streaming.
//
// Simulation mode (default):
//   Returns 0.20 stub results for performance benchmarking only.
// =========================================================
#include "iv_accel_host.hpp"

// -------------------------------------------------------
// Constructor / Destructor
// -------------------------------------------------------
IvAcceleratorHost::IvAcceleratorHost() {
#ifdef XDMA_HARDWARE
    std::cout << "[HOST ACCELERATOR] XDMA Hardware mode. "
              << "Call open_xdma_device() before process_batch().\n";
#else
    std::cout << "[HOST ACCELERATOR] Simulation mode (no XDMA hardware). "
              << "Compile with -DXDMA_HARDWARE for real PCIe DMA.\n";
#endif
}

IvAcceleratorHost::~IvAcceleratorHost() {
    close_xdma_device();
    std::cout << "[HOST ACCELERATOR] Released PCIe Drivers.\n";
}

// -------------------------------------------------------
// open_xdma_device()
// Opens H2C and C2H XDMA character device file descriptors.
// Requires AMD XDMA kernel driver (xdma.ko) loaded.
// -------------------------------------------------------
void IvAcceleratorHost::open_xdma_device(
    const std::string& h2c_device,
    const std::string& c2h_device)
{
#ifdef XDMA_HARDWARE
    m_h2c_fd = open(h2c_device.c_str(), O_WRONLY);
    if (m_h2c_fd < 0) {
        throw std::runtime_error(
            "[XDMA] Failed to open H2C device '" + h2c_device +
            "': " + strerror(errno));
    }

    m_c2h_fd = open(c2h_device.c_str(), O_RDONLY);
    if (m_c2h_fd < 0) {
        close(m_h2c_fd);
        m_h2c_fd = -1;
        throw std::runtime_error(
            "[XDMA] Failed to open C2H device '" + c2h_device +
            "': " + strerror(errno));
    }

    std::cout << "[HOST ACCELERATOR] XDMA devices opened:\n"
              << "  H2C: " << h2c_device << " (fd=" << m_h2c_fd << ")\n"
              << "  C2H: " << c2h_device << " (fd=" << m_c2h_fd << ")\n";
#else
    (void)h2c_device;
    (void)c2h_device;
    std::cout << "[HOST ACCELERATOR] Simulation mode: open_xdma_device() is a no-op.\n"
              << "  Recompile with -DXDMA_HARDWARE for real DMA.\n";
#endif
}

// -------------------------------------------------------
// close_xdma_device()
// -------------------------------------------------------
void IvAcceleratorHost::close_xdma_device() {
#ifdef XDMA_HARDWARE
    if (m_h2c_fd >= 0) { close(m_h2c_fd); m_h2c_fd = -1; }
    if (m_c2h_fd >= 0) { close(m_c2h_fd); m_c2h_fd = -1; }
#endif
}

// -------------------------------------------------------
// is_hardware_mode()
// -------------------------------------------------------
bool IvAcceleratorHost::is_hardware_mode() const {
#ifdef XDMA_HARDWARE
    return (m_h2c_fd >= 0) && (m_c2h_fd >= 0);
#else
    return false;
#endif
}

// -------------------------------------------------------
// process_batch()
// -------------------------------------------------------
std::vector<double> IvAcceleratorHost::process_batch(
    const std::vector<double>& spot_prices,
    const std::vector<double>& strike_prices,
    const std::vector<double>& market_prices,
    const std::vector<double>& rates,
    const std::vector<double>& maturities)
{
    size_t n = spot_prices.size();
    if (strike_prices.size() < n || market_prices.size() < n ||
        rates.size() < n || maturities.size() < n) {
        throw std::invalid_argument("Input vector size mismatch in process_batch!");
    }

    std::vector<double> results(n, 0.0);
    std::cout << "[HOST ACCELERATOR] Submitting batch of " << n
              << " option contracts...\n";
    auto start_time = std::chrono::high_resolution_clock::now();

    // -------------------------------------------------------
    // Pack Q8.24 payloads (both hardware and simulation paths)
    // -------------------------------------------------------
    std::vector<IvMarketTick> tx_buffer(n);
    for (size_t i = 0; i < n; ++i) {
        tx_buffer[i].S_fixed        = float_to_q824(spot_prices[i]);
        tx_buffer[i].K_fixed        = float_to_q824(strike_prices[i]);
        tx_buffer[i].C_market_fixed = float_to_q824(market_prices[i]);
        tx_buffer[i].r_fixed        = float_to_q824(rates[i]);
        tx_buffer[i].T_fixed        = float_to_q824(maturities[i]);
        tx_buffer[i].transaction_id = static_cast<uint8_t>(i & 0x3F);
        memset(tx_buffer[i].reserved, 0, sizeof(tx_buffer[i].reserved));
    }

#ifdef XDMA_HARDWARE
    // -------------------------------------------------------
    // XDMA Hardware Path: real PCIe DMA streaming
    // -------------------------------------------------------
    if (!is_hardware_mode()) {
        throw std::runtime_error(
            "[XDMA] open_xdma_device() must be called before process_batch() "
            "in hardware mode.");
    }

    const size_t tx_bytes = n * sizeof(IvMarketTick);
    const size_t rx_bytes = n * sizeof(IvResultPayload);

    // Stream all ticks to FPGA over H2C channel
    ssize_t written = write(m_h2c_fd, tx_buffer.data(), tx_bytes);
    if (written != static_cast<ssize_t>(tx_bytes)) {
        throw std::runtime_error(
            "[XDMA] H2C write underflow: expected " + std::to_string(tx_bytes) +
            " bytes, wrote " + std::to_string(written) + " bytes. "
            "Error: " + strerror(errno));
    }

    // Read IV results back over C2H channel (blocking read)
    std::vector<IvResultPayload> rx_buffer(n);
    ssize_t bytes_read = read(m_c2h_fd, rx_buffer.data(), rx_bytes);
    if (bytes_read != static_cast<ssize_t>(rx_bytes)) {
        throw std::runtime_error(
            "[XDMA] C2H read underflow: expected " + std::to_string(rx_bytes) +
            " bytes, read " + std::to_string(bytes_read) + " bytes. "
            "Error: " + strerror(errno));
    }

    // Unpack Q8.24 implied volatility results
    for (size_t i = 0; i < n; ++i) {
        results[i] = q824_to_float(rx_buffer[i].sigma_fixed);
    }

#else
    // -------------------------------------------------------
    // Simulation Stub: returns 20% IV for benchmark timing only
    // -------------------------------------------------------
    for (size_t i = 0; i < n; ++i) {
        results[i] = 0.20;   // 20.00% — placeholder; not RTL-accurate
    }
#endif

    auto end_time   = std::chrono::high_resolution_clock::now();
    double elapsed_ms = std::chrono::duration<double, std::milli>(
                            end_time - start_time).count();
    double M_ops_sec = (elapsed_ms > 0.0) ?
                        (static_cast<double>(n) / (elapsed_ms / 1000.0)) / 1e6 : 0.0;

    std::cout << "[HOST ACCELERATOR] Batch completed in " << elapsed_ms
              << " ms | Throughput: " << M_ops_sec << " Million Options/sec"
              << (is_hardware_mode() ? " [HARDWARE]" : " [SIMULATION STUB]")
              << "\n";
    return results;
}

// -------------------------------------------------------
// main() — Standalone Host Benchmark
// -------------------------------------------------------
int main(int argc, char* argv[]) {
    std::cout << "=========================================================\n"
              << "FPGA-Accelerated Implied Volatility Host Benchmark\n"
#ifdef XDMA_HARDWARE
              << "  Mode: XDMA Hardware (PCIe DMA to FPGA)\n"
#else
              << "  Mode: Simulation Stub (20% IV placeholder)\n"
              << "  Build with -DXDMA_HARDWARE for real PCIe DMA.\n"
#endif
              << "=========================================================\n";

    IvAcceleratorHost host;

#ifdef XDMA_HARDWARE
    // Open XDMA devices (optional custom paths via argv[1], argv[2])
    std::string h2c = (argc > 1) ? argv[1] : "/dev/xdma0_h2c_0";
    std::string c2h = (argc > 2) ? argv[2] : "/dev/xdma0_c2h_0";
    host.open_xdma_device(h2c, c2h);
#endif

    constexpr size_t TEST_SIZE = 1'000'000;   // 1 Million option contracts
    std::vector<double> S(TEST_SIZE, 100.0);
    std::vector<double> K(TEST_SIZE, 100.0);
    std::vector<double> C(TEST_SIZE,   5.0);
    std::vector<double> r(TEST_SIZE,  0.05);
    std::vector<double> T(TEST_SIZE,   1.0);

    auto results = host.process_batch(S, K, C, r, T);

    std::cout << "[HOST BENCHMARK] Sample Result[0]: Implied Volatility = "
              << (results[0] * 100.0) << "%\n"
              << "=========================================================\n";
    return 0;
}
