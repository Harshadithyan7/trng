# True Random Number Generator (TRNG) based on Ring Oscillators (RO)
## Implementation & Verification Plan for FPGA (Verilog)

This document outlines the design, architecture, and step-by-step implementation plan for a hardware-based True Random Number Generator (TRNG) targeting FPGAs. The generator leverages the physical phase jitter (thermal/shot noise) of Ring Oscillators as an entropy source to produce cryptographically secure random bits.

---

## 1. Physical Principle & Architecture

### 1.1 Entropy Source: Ring Oscillator Jitter
A Ring Oscillator (RO) consists of an odd number of inverters connected in a closed loop. Because there is no stable state, the loop oscillates at a frequency determined by the propagation delay of the gates and routing:

$$f_{RO} \approx \frac{1}{2 \cdot N \cdot \tau_{inv}}$$

where $N$ is the number of inverters (odd) and $\tau_{inv}$ is the propagation delay of a single inverter. 

Due to thermal noise, flicker noise, and power supply fluctuations in the FPGA fabric, the oscillation period exhibits tiny fluctuations called **phase jitter**. Over time, this jitter accumulates.

### 1.2 Sampling Mechanism
By sampling the high-frequency jittery RO output with a slower, stable system clock ($f_{clk}$), we capture the random drift of the RO transition edges. 
* If the RO transition occurs close to the sampling edge of the clock, the sampled value (0 or 1) becomes highly unpredictable due to accumulated jitter.
* Since we are sampling an asynchronous signal, **metastability** is a significant risk. A two-stage synchronizer (back-to-back D Flip-Flops) is required to resolve metastability before the bit is processed.

### 1.3 Multi-RO Entropy Accumulation
A single RO might suffer from:
* Frequency locking (injection locking) to the system clock or adjacent oscillators.
* High bias (unequal probability of 0 and 1).

To enhance entropy and robustness, we will implement **$M$ parallel Ring Oscillators** with slightly different frequencies (e.g., by varying the number of inverters or routing) and XOR their sampled outputs together.

### 1.4 Post-Processing (Von Neumann Corrector)
Even with multi-RO accumulation, the raw bitstream may have a bias ($P(1) \neq 0.5$). We will implement a hardware-efficient **Von Neumann Corrector** to eliminate bias:
1. Group the incoming raw bitstream into non-overlapping pairs: $(b_{2k}, b_{2k+1})$.
2. Apply the following mapping:
   - `01` $\rightarrow$ output `0` (transition 0 to 1)
   - `10` $\rightarrow$ output `1` (transition 1 to 0)
   - `00` $\rightarrow$ discard
   - `11` $\rightarrow$ discard
3. This guarantees $P(0) = P(1) = 0.5$ as long as consecutive bits are independent, at the cost of a variable output bit rate (maximum 25% efficiency).

---

## 2. Block Diagram

```
+--------------------------------------------------------------------------------+
| FPGA TRNG Core                                                                 |
|                                                                                |
|  +------------------+                                                          |
|  | Ring Osc 1 (N=3) |---+                                                      |
|  +------------------+   |                                                      |
|  +------------------+   |   +--------------+     +-------------+               |
|  | Ring Osc 2 (N=5) |---+-->| Synchronizer |---->|    XOR      |               |
|  +------------------+   |   |  & Sampler   |     | Accumulator |               |
|  +------------------+   |   +--------------+     +------+------+               |
|  | Ring Osc M (N=7) |---+                               |                      |
|  +------------------+                                   v                      |
|                                                  +--------------+              |
|                                                  | Raw Bit Reg  |              |
|                                                  +------+-------+              |
|                                                         |                      |
|                                                         v  (Raw bit stream)    |
|                                                  +--------------+              |
|                                                  | Von Neumann  |              |
|                                                  |  Corrector   |              |
|                                                  +------+-------+              |
|                                                         |                      |
|                                                         v                      |
|                                                    [ TRNG_OUT ]                |
|                                                    [ TRNG_VALID]               |
+--------------------------------------------------------------------------------+
```

---

## 3. FPGA-Specific Verilog Constraints

Modern FPGA synthesis tools (like AMD/Xilinx Vivado, Intel Quartus, or open-source Yosys) detect combinational loops as timing hazards and will attempt to optimize them away or flag errors. 

To prevent this, we must use **synthesis attributes** directly in the Verilog code:
* **Vivado/Yosys:** `(* dont_touch = "true" *)` or `(* keep = "true" *)`
* **Quartus:** `/* synthesis keep */`

### Conceptual Verilog Snippet for a Single Inverter Stage
```verilog
(* dont_touch = "true" *) wire [2:0] delay_chain;
(* dont_touch = "true" *) assign delay_chain[0] = ~delay_chain[2];
(* dont_touch = "true" *) assign delay_chain[1] = ~delay_chain[0];
(* dont_touch = "true" *) assign delay_chain[2] = ~delay_chain[1];
```

---

## 4. Implementation Steps

### Phase 1: Directory Setup & Structure
We will create a clean, modular directory structure:
```
trng-fpga/
├── PLAN.md                   # This implementation plan
├── src/                      # RTL Source code
│   ├── trng_top.v            # Top-level module
│   ├── ring_osc.v            # Parameterized Ring Oscillator module
│   ├── synchronizer.v        # Two-stage DFF synchronizer
│   └── von_neumann.v         # Von Neumann corrector
├── tb/                       # Simulation and Testbenches
│   ├── tb_trng_top.v         # Complete TRNG simulation
│   └── tb_ring_osc.v         # Ring oscillator behavioral testbench
└── tools/                    # Validation & analysis tools
    └── analyze_entropy.py    # Python script for statistical tests
```

### Phase 2: RTL Development
1. **`ring_osc.v`**: Create an inverter loop with a parameterized number of inverters `N` and an `enable` signal to start/stop the oscillator (saves power when TRNG is inactive).
2. **`synchronizer.v`**: A double-register sync circuit to sample the asynchronous RO output safely using the system clock.
3. **`von_neumann.v`**: A state machine that reads raw sampled bits and outputs a verified unbiased bit with a `valid` signal.
4. **`trng_top.v`**: Instantiate $M$ ring oscillators with varying $N$, XOR their synchronized outputs, feed the result into the Von Neumann corrector, and provide external handshake signals (`o_random_bit`, `o_valid`).

### Phase 3: Behavioral Simulation with Jitter Modeling
Since standard RTL simulation is deterministic (zero routing/thermal noise delay variations), a standard simulation of a Ring Oscillator will show a perfect, constant frequency. 
To verify our logic:
* We will construct a testbench `tb_trng_top.v` that injects artificial random phase noise into the RO model during simulation using `$random` or delay modulation in a `specify` block or `#` delays.
* Verify the functional correctness of the sampler, XOR, and Von Neumann state machine.

### Phase 4: Statistical Validation & Software Verification
1. Implement a Python script (`tools/analyze_entropy.py`) to parse simulated or hardware-collected bitstreams.
2. Implement key tests:
   - **Monobit Test (Frequency Test):** Measures proportion of 1s and 0s.
   - **Runs Test:** Measures frequency of consecutive identical bits.
   - **Autocorrelation:** Evaluates correlation between bits at offset $k$.
   - **Entropy Calculation:** Shannon entropy of the bitstream.
3. Provide instructions on running NIST SP 800-22 or AIS-31 test suites on large datasets (e.g., 1 million+ bits).

---

## 5. Next Immediate Action

Our first implementation step is to write the Verilog RTL modules. We will:
1. Implement `ring_osc.v` with synthesis guard rails.
2. Implement `synchronizer.v` for clock-domain safety.
3. Implement `von_neumann.v` to correct bias.
4. Integrate them in `trng_top.v`.

---
*Plan created on: Tuesday, September 15, 2026*
