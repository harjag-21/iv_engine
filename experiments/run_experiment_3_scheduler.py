#!/usr/bin/env python3
"""
================================================================================
EXPERIMENT 3: Priority-Loopback Scheduler Stress, Throughput Reference Model,
             and Bounded Queueing Analysis
Target Venue: ACM/SIGDA FPGA 2027
================================================================================

This module provides cycle-accurate simulation and formal validation of the
priority-loopback scheduling microarchitecture:
  1. Datapath Pipeline Capacity Validation:
     Validates the closed-form throughput reference model across loopback sweep:
       T(p) = T_peak / (1 + p) = 400.00 / (1 + p) MOps/s
     Proving that priority-loopback scheduling achieves 100.0% of theoretical
     capacity without bubble insertion.
  2. RTL Scoreboard & Flow Control Evaluation:
     Simulates the exact 64-entry distributed LUTRAM context scoreboard,
     4-slot headroom reservation policy (throttles ingress when active >= 60),
     and strict loopback preemption, verifying deadlock-free operation.
  3. Burst Injection Stress:
     Subjecting the engine to line-rate bursts of 16 to 256 contracts requiring
     multi-pass iteration, measuring queue depth, backpressure recovery, and latency.
  4. Empirical Market Workloads:
     Evaluating liquid and extended options regimes using empirical pass distributions.

Outputs:
  - experiments/data/scheduler_stress_results.json
  - Publication Table V (Scheduler Stress & Queueing Performance)
================================================================================
"""

import os
import sys
import json
import math
import time
from collections import deque
import numpy as np

# Hardware Constants
CLOCK_FREQ_MHZ = 100.00          # 100.00 MHz signoff clock (Artix-7 200T)
NUM_CORES = 4                    # 4 cores
T_PEAK_MOPS = 400.00             # 4 cores * 100 MHz = 400 MOps/s peak ingress rate

STAGE1_LATENCY = 1               # Ingress register
STAGE2_LATENCY = 64              # Analytical guess seeder & sqrt(T)
STAGE3_LATENCY = 126             # Black-Scholes core datapath
STAGE4_LATENCY = 33              # NR & Greek dividers
STAGE5_LATENCY = 2               # Egress packing & arbitration
LOOPBACK_LATENCY = STAGE3_LATENCY + STAGE4_LATENCY  # 159 cycles
COLD_PATH_LATENCY = STAGE1_LATENCY + STAGE2_LATENCY + 1 + STAGE3_LATENCY + STAGE4_LATENCY + STAGE5_LATENCY  # 227 cycles

SCOREBOARD_CAPACITY = 64         # Total slots per core
HEADROOM_THRESHOLD = 60          # Ingress throttled when active >= 60 (4-slot headroom)
INGRESS_FIFO_CAPACITY = 64       # Ingress FIFO depth


# ==============================================================================
# 1. Datapath Priority-Loopback Scheduler (Reference Model Validation)
# ==============================================================================
class DatapathSchedulerSimulator:
    """
    Simulates the core priority-loopback datapath scheduler across 4 cores,
    evaluating sustained contract throughput under continuous line-rate demand.
    Each core's Stage 3 datapath (159 cycles) serves either a priority loopback
    or a new ingress contract on every cycle (II=1).
    """

    def __init__(self, num_cores=NUM_CORES):
        self.num_cores = num_cores

    def run_workload(self, workload):
        """
        Executes priority loopback scheduling across 4 cores.
        workload is a list of tuples: (contract_id, total_passes)
        """
        total_contracts = len(workload)
        workload_queue = deque(workload)

        # 4 independent pipelines, each of depth LOOPBACK_LATENCY (159 cycles)
        # Each pipeline slot holds None or (contract_id, total_passes, current_pass, admit_cycle)
        pipelines = [[None] * LOOPBACK_LATENCY for _ in range(self.num_cores)]
        loopback_lanes = [None] * self.num_cores

        completed = []
        cycle = 0
        admitted = 0
        core_ptr = 0

        steady_completed = 0
        steady_start_cycle = 500
        steady_end_cycle = None

        while len(completed) < total_contracts:
            cycle += 1
            if len(workload_queue) == 0 and steady_end_cycle is None:
                steady_end_cycle = cycle

            # Step each core
            for c in range(self.num_cores):
                # 1. Output from Stage 4
                out = pipelines[c][-1]
                pipelines[c][-1] = None

                if out is not None:
                    cid, tot_p, curr_p, adm_cyc = out
                    if curr_p >= tot_p:
                        # Converged: emit to egress
                        total_lat = (cycle - adm_cyc) + STAGE1_LATENCY + STAGE2_LATENCY + 1 + STAGE5_LATENCY
                        completed.append({
                            "contract_id": cid,
                            "core_id": c,
                            "passes": tot_p,
                            "latency_cycles": total_lat,
                        })
                        if cycle >= steady_start_cycle and steady_end_cycle is None:
                            steady_completed += 1
                    else:
                        # Re-enter loopback lane
                        assert loopback_lanes[c] is None
                        loopback_lanes[c] = (cid, tot_p, curr_p + 1, adm_cyc)

                # 2. Shift pipeline
                for i in range(LOOPBACK_LATENCY - 1, 0, -1):
                    pipelines[c][i] = pipelines[c][i - 1]
                pipelines[c][0] = None

                # 3. Schedule slot: Priority 1 = Loopback, Priority 2 = Ingress
                if loopback_lanes[c] is not None:
                    pipelines[c][0] = loopback_lanes[c]
                    loopback_lanes[c] = None
                elif len(workload_queue) > 0:
                    cid, tot_p = workload_queue.popleft()
                    pipelines[c][0] = (cid, tot_p, 1, cycle)
                    admitted += 1

        if steady_end_cycle is None:
            steady_end_cycle = cycle
        steady_cycles = max(1, steady_end_cycle - steady_start_cycle)
        steady_tput = (steady_completed / (steady_cycles / (CLOCK_FREQ_MHZ * 1e6))) / 1e6

        total_time_s = cycle / (CLOCK_FREQ_MHZ * 1e6)
        batch_tput = (total_contracts / total_time_s) / 1e6
        latencies = [c["latency_cycles"] for c in completed]
        passes = [c["passes"] for c in completed]

        return {
            "total_contracts": total_contracts,
            "total_clock_cycles": cycle,
            "sustained_throughput_mops": float(steady_tput),
            "batch_throughput_mops": float(batch_tput),
            "avg_passes": float(np.mean(passes)),
            "latency_cycles": {
                "mean": float(np.mean(latencies)),
                "median": float(np.percentile(latencies, 50)),
                "p95": float(np.percentile(latencies, 95)),
                "p99": float(np.percentile(latencies, 99)),
                "max": int(np.max(latencies)),
                "min": int(np.min(latencies)),
            },
        }


# ==============================================================================
# 2. RTL Scoreboard & Flow Control Simulator (Physical Hardware Constraints)
# ==============================================================================
class RTLScoreboardSimulator:
    """
    Simulates the physical hardware array including:
      - 64-entry distributed LUTRAM context memory per core
      - 4-slot headroom reservation (throttles ingress when active >= 60)
      - Stage 1/2 analytical seeder latency (65 cycles)
      - Ingress FIFO (depth 64, almost-full at 48)
      - Loopback preemption and deadlock resilience
    """

    def __init__(self, num_cores=NUM_CORES):
        self.num_cores = num_cores
        self.reset()

    def reset(self):
        self.active_slots = [0] * self.num_cores
        self.seeder_pipes = [[] for _ in range(self.num_cores)]  # (cid, rem, tot_p, ing_cyc)
        self.ingress_fifos = [deque() for _ in range(self.num_cores)]
        self.datapath_pipes = [[None] * LOOPBACK_LATENCY for _ in range(self.num_cores)]
        self.loopback_slots = [None] * self.num_cores
        self.egress_fifos = [deque() for _ in range(self.num_cores)]

        self.peak_active = [0] * self.num_cores
        self.peak_q = [0] * self.num_cores
        self.backpressure_cycles = 0

    def can_accept(self, core_id):
        headroom_ok = self.active_slots[core_id] < HEADROOM_THRESHOLD
        fifo_ok = len(self.ingress_fifos[core_id]) < 48
        return headroom_ok and fifo_ok

    def run_workload(self, workload, max_cycles=10_000_000):
        self.reset()
        total_contracts = len(workload)
        workload_queue = deque(workload)
        completed = []
        cycle = 0
        wr_ptr = 0
        egress_rd = 0

        while len(completed) < total_contracts and cycle < max_cycles:
            cycle += 1

            # Ingress Injection
            if len(workload_queue) > 0:
                if self.can_accept(wr_ptr):
                    cid, passes = workload_queue.popleft()
                    self.active_slots[wr_ptr] += 1
                    if self.active_slots[wr_ptr] > self.peak_active[wr_ptr]:
                        self.peak_active[wr_ptr] = self.active_slots[wr_ptr]
                    self.seeder_pipes[wr_ptr].append((cid, STAGE1_LATENCY + STAGE2_LATENCY, passes, cycle))
                    wr_ptr = (wr_ptr + 1) % self.num_cores
                else:
                    self.backpressure_cycles += 1

            # Step each core
            for c in range(self.num_cores):
                # Seeder progression
                new_seeder = []
                for cid, rem, tot_p, ing_cyc in self.seeder_pipes[c]:
                    if rem > 1:
                        new_seeder.append((cid, rem - 1, tot_p, ing_cyc))
                    else:
                        self.ingress_fifos[c].append((cid, tot_p, 1, ing_cyc))
                        if len(self.ingress_fifos[c]) > self.peak_q[c]:
                            self.peak_q[c] = len(self.ingress_fifos[c])
                self.seeder_pipes[c] = new_seeder

                # Datapath Stage 4 output
                stg4_out = self.datapath_pipes[c][-1]
                self.datapath_pipes[c][-1] = None

                if stg4_out is not None:
                    cid, tot_p, curr_p, ing_cyc = stg4_out
                    if curr_p >= tot_p:
                        # Converged
                        self.egress_fifos[c].append((cid, tot_p, ing_cyc, cycle))
                    else:
                        # Loopback
                        assert self.loopback_slots[c] is None
                        self.loopback_slots[c] = (cid, tot_p, curr_p + 1, ing_cyc)

                # Shift datapath
                for i in range(LOOPBACK_LATENCY - 1, 0, -1):
                    self.datapath_pipes[c][i] = self.datapath_pipes[c][i - 1]
                self.datapath_pipes[c][0] = None

                # Priority Arbitration: Loopback > Ingress FIFO
                if self.loopback_slots[c] is not None:
                    self.datapath_pipes[c][0] = self.loopback_slots[c]
                    self.loopback_slots[c] = None
                elif len(self.ingress_fifos[c]) > 0:
                    self.datapath_pipes[c][0] = self.ingress_fifos[c].popleft()

            # Egress Drain (work-conserving)
            for j in range(self.num_cores):
                idx = (egress_rd + j) % self.num_cores
                if len(self.egress_fifos[idx]) > 0:
                    cid, tot_p, ing_cyc, eg_cyc = self.egress_fifos[idx].popleft()
                    self.active_slots[idx] -= 1
                    tot_lat = (cycle - ing_cyc) + STAGE5_LATENCY
                    completed.append({
                        "contract_id": cid,
                        "core_id": idx,
                        "passes": tot_p,
                        "latency_cycles": tot_lat,
                    })
                    egress_rd = (idx + 1) % self.num_cores
                    break

        assert len(completed) == total_contracts, "Deadlock occurred!"
        for c in range(self.num_cores):
            assert self.active_slots[c] == 0, "Scoreboard leak!"
            assert self.peak_active[c] <= SCOREBOARD_CAPACITY, "Scoreboard overflow!"

        total_time_s = cycle / (CLOCK_FREQ_MHZ * 1e6)
        sustained_tput = (total_contracts / total_time_s) / 1e6
        latencies = [c["latency_cycles"] for c in completed]
        passes = [c["passes"] for c in completed]

        return {
            "total_contracts": total_contracts,
            "total_clock_cycles": cycle,
            "sustained_throughput_mops": float(sustained_tput),
            "avg_passes": float(np.mean(passes)),
            "backpressure_duty_cycle_pct": float((self.backpressure_cycles / cycle) * 100.0),
            "peak_active_slots_per_core": int(max(self.peak_active)),
            "peak_ingress_queue_depth": int(max(self.peak_q)),
            "latency_cycles": {
                "mean": float(np.mean(latencies)),
                "median": float(np.percentile(latencies, 50)),
                "p95": float(np.percentile(latencies, 95)),
                "p99": float(np.percentile(latencies, 99)),
                "max": int(np.max(latencies)),
                "min": int(np.min(latencies)),
            },
        }


# ==============================================================================
# 3. Experimental Test Suites
# ==============================================================================
def run_parametric_loopback_validation(num_contracts=50_000, seed=42):
    """Evaluates throughput reference model T(p) = 400 / (1 + p) across loopback probabilities."""
    np.random.seed(seed)
    p_values = [0.00, 0.10, 0.25, 0.50, 0.75, 0.90, 1.00]
    results = []

    print("-" * 90)
    print(f"EXPERIMENT 3A: THROUGHPUT REFERENCE MODEL VALIDATION (N={num_contracts:,} contracts/point)")
    print("-" * 90)
    print(f"{'p (Loopback)':<14} | {'P_bar':<6} | {'T_theory (MOps/s)':<18} | {'T_steady (MOps/s)':<18} | {'Match Error (%)':<16} | {'P95 Lat (cyc)':<12}")
    print("-" * 90)

    sim = DatapathSchedulerSimulator(num_cores=NUM_CORES)

    for p in p_values:
        workload = []
        for i in range(num_contracts):
            passes = 2 if (np.random.rand() < p) else 1
            workload.append((i, passes))

        res = sim.run_workload(workload)
        t_theory = 400.00 / (1.0 + p)
        delta_pct = ((res["sustained_throughput_mops"] - t_theory) / t_theory) * 100.0

        point = {
            "loopback_probability_p": p,
            "theoretical_avg_passes": 1.0 + p,
            "simulated_avg_passes": res["avg_passes"],
            "theoretical_throughput_mops": t_theory,
            "simulated_throughput_mops": res["sustained_throughput_mops"],
            "simulated_steady_throughput_mops": res["sustained_throughput_mops"],
            "simulated_batch_throughput_mops": res["batch_throughput_mops"],
            "match_error_pct": delta_pct,
            "latency_cycles": res["latency_cycles"],
        }
        results.append(point)

        print(
            f"{p:<14.2f} | {res['avg_passes']:<6.2f} | {t_theory:<18.2f} | "
            f"{res['sustained_throughput_mops']:<18.2f} | {delta_pct:<+16.2f}% | "
            f"{res['latency_cycles']['p95']:<12.1f}"
        )

    return results


def run_burst_stress_evaluation():
    """Evaluates backpressure and queue bounds under multi-pass line-rate bursts."""
    burst_sizes = [16, 32, 48, 60, 80, 128, 256]
    results = []

    print("\n" + "-" * 90)
    print("EXPERIMENT 3B: BURST INJECTION STRESS SUITE (RTL Scoreboard & Flow Control)")
    print("-" * 90)
    print(f"{'Burst Size':<12} | {'Peak Active':<14} | {'Peak Q Depth':<14} | {'Backpressure Cyc':<18} | {'Total Cycles':<14} | {'Deadlock Free'}")
    print("-" * 90)

    sim = RTLScoreboardSimulator(num_cores=NUM_CORES)

    for b in burst_sizes:
        # Each contract demands 2 passes
        workload = [(i, 2) for i in range(b)]
        res = sim.run_workload(workload)

        entry = {
            "burst_size": b,
            "peak_active_slots_per_core": res["peak_active_slots_per_core"],
            "peak_ingress_queue_depth": res["peak_ingress_queue_depth"],
            "backpressure_cycles": int(res["total_clock_cycles"] * (res["backpressure_duty_cycle_pct"] / 100.0)),
            "drain_cycles": res["total_clock_cycles"],
            "deadlock_free": True,
            "latency_cycles": res["latency_cycles"],
        }
        results.append(entry)

        print(
            f"{b:<12} | {res['peak_active_slots_per_core']:<14} | {res['peak_ingress_queue_depth']:<14} | "
            f"{entry['backpressure_cycles']:<18} | {res['total_clock_cycles']:<14} | PASS (0 deadlocks)"
        )

    return results


def run_empirical_workload_evaluation(seed=42):
    """Evaluates throughput and latency under empirical market pass distributions."""
    np.random.seed(seed)
    # Empirical distributions from Exp 2A:
    liquid_passes = [1, 2, 3, 4, 5, 6, 7, 8]
    liquid_probs = [0.0039, 0.4952, 0.3883, 0.1008, 0.0071, 0.0005, 0.0001, 0.0041]
    liquid_probs = np.array(liquid_probs) / np.sum(liquid_probs)

    ext_passes = [1, 2, 3, 4, 5, 6, 7, 8]
    ext_probs = [0.0118, 0.2229, 0.3213, 0.2657, 0.0632, 0.0255, 0.0101, 0.0795]
    ext_probs = np.array(ext_probs) / np.sum(ext_probs)

    num_contracts = 50_000
    results = {}

    print("\n" + "-" * 90)
    print(f"EXPERIMENT 3C: EMPIRICAL MARKET WORKLOAD EVALUATION (N={num_contracts:,} contracts each)")
    print("-" * 90)

    sim = DatapathSchedulerSimulator(num_cores=NUM_CORES)

    for regime_name, passes_arr, probs_arr in [
        ("liquid_regime", liquid_passes, liquid_probs),
        ("extended_domain", ext_passes, ext_probs),
    ]:
        sampled = np.random.choice(passes_arr, size=num_contracts, p=probs_arr)
        workload = [(i, int(p)) for i, p in enumerate(sampled)]

        res = sim.run_workload(workload)
        t_theory = 400.00 / res["avg_passes"]

        results[regime_name] = {
            "workload_regime": regime_name,
            "num_contracts": num_contracts,
            "avg_passes": res["avg_passes"],
            "theoretical_throughput_mops": float(t_theory),
            "simulated_throughput_mops": res["sustained_throughput_mops"],
            "simulated_steady_throughput_mops": res["sustained_throughput_mops"],
            "simulated_batch_throughput_mops": res["batch_throughput_mops"],
            "match_error_pct": float(((res["sustained_throughput_mops"] - t_theory) / t_theory) * 100.0),
            "latency_cycles": res["latency_cycles"],
            "latency_us": {k: float(v * 0.010) for k, v in res["latency_cycles"].items()},
        }

        print(f"Regime: {regime_name}")
        print(f"  Avg Passes (P_bar)        : {res['avg_passes']:.4f}")
        print(f"  Theoretical Tput (MOps/s) : {t_theory:.2f}")
        print(f"  Simulated Tput (MOps/s)   : {res['sustained_throughput_mops']:.2f}")
        print(f"  Match Error               : {results[regime_name]['match_error_pct']:+.2f}%")
        print(f"  Mean Latency              : {res['latency_cycles']['mean']:.1f} cycles ({res['latency_cycles']['mean']*0.010:.2f} us)")
        print(f"  P95 Latency               : {res['latency_cycles']['p95']:.1f} cycles ({res['latency_cycles']['p95']*0.010:.2f} us)")
        print(f"  P99 Latency               : {res['latency_cycles']['p99']:.1f} cycles ({res['latency_cycles']['p99']*0.010:.2f} us)")
        print(f"  Max Latency               : {res['latency_cycles']['max']:.1f} cycles ({res['latency_cycles']['max']*0.010:.2f} us)")

    return results


def main():
    print("=" * 90)
    print("EXPERIMENT 3: Priority-Loopback Scheduler Stress, Reference Model, & Queueing")
    print("Target Venue: ACM/SIGDA FPGA 2027")
    print("=" * 90)

    # 1. Run parametric sweep
    parametric_sweep = run_parametric_loopback_validation(num_contracts=10_000)

    # 2. Run burst stress
    burst_stress = run_burst_stress_evaluation()

    # 3. Run empirical market workloads
    market_workloads = run_empirical_workload_evaluation()

    # 4. Compile comprehensive payload
    output_payload = {
        "metadata": {
            "title": "Experiment 3: Priority-Loopback Scheduler Stress & Bounded Queueing",
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
            "target_clock_mhz": CLOCK_FREQ_MHZ,
            "num_cores": NUM_CORES,
            "peak_ingress_capacity_mops": T_PEAK_MOPS,
            "scoreboard_capacity_per_core": SCOREBOARD_CAPACITY,
            "headroom_reservation_slots": SCOREBOARD_CAPACITY - HEADROOM_THRESHOLD,
            "pipeline_latencies": {
                "cold_path_cycles": COLD_PATH_LATENCY,
                "loopback_cycles": LOOPBACK_LATENCY,
                "stage1_ingress": STAGE1_LATENCY,
                "stage2_seeder": STAGE2_LATENCY,
                "stage3_datapath": STAGE3_LATENCY,
                "stage4_divider": STAGE4_LATENCY,
                "stage5_egress": STAGE5_LATENCY,
            },
        },
        "parametric_sweep": parametric_sweep,
        "burst_stress": burst_stress,
        "empirical_market_workloads": market_workloads,
    }

    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    out_dir = os.path.join(repo_root, "experiments", "data")
    os.makedirs(out_dir, exist_ok=True)
    out_file = os.path.join(out_dir, "scheduler_stress_results.json")

    with open(out_file, "w") as f:
        json.dump(output_payload, f, indent=2)

    print("\n" + "=" * 90)
    print(f"Results successfully exported to: {out_file}")
    print("=" * 90)


if __name__ == "__main__":
    main()
