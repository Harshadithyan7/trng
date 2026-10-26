# FPGA Ring-Oscillator TRNG and AES HSM

This project contains an FPGA true random number generator (TRNG) and a UART-connected AES-128 encryption/decryption demonstration.

The TRNG uses three ring oscillators, two-stage synchronizers, XOR sampling, and a Von Neumann corrector. The HSM top level collects 128 corrected bits for an AES key, receives a 1–16 byte request over UART, performs AES-128 inside the FPGA, and returns a 16-byte result over UART.

## Key and message flow

The HSM keeps one key for one encrypt/decrypt pair:

1. After reset, the FPGA collects a 128-bit key and expands the AES key schedule.
2. Send one `encrypt` request. The FPGA encrypts the zero-padded 16-byte block and returns 16 ciphertext bytes.
3. Send that ciphertext back in a `decrypt` request. Decryption must use the same key and the same running FPGA instance.
4. After decryption, the FPGA clears the old key and collects a fresh key. It then accepts the next `encrypt` request.

Only one encrypted message can be pending at a time. The FPGA ignores an encrypt request while a prior message is pending, and ignores a decrypt request when there is no pending message. The UART protocol has no error response for ignored commands, so send requests in the order above. Reset discards the current key and any pending message.

The payload is limited to 16 bytes. The RTL applies zero padding to shorter payloads and always returns one 16-byte AES block. The Python client removes trailing zero bytes when displaying decrypted text, so binary data or text ending with NUL bytes is not represented losslessly by that display behavior.

## Step-by-step: run the simulations

### 1. Install the tools

Install:

- Icarus Verilog (`iverilog` and `vvp`)
- Python 3
- GTKWave (optional, for waveform viewing)
- `pyserial` (only needed for the physical UART client)

On systems where pip is available:

```sh
python3 -m pip install pyserial
```

### 2. Open a terminal in the project directory

```sh
cd trng-fpga
```

### 3. Run the TRNG logic simulation

```sh
make test
```

This compiles and runs the ring oscillator and TRNG testbenches, captures 128 corrected bits in `build/random_bits.txt`, prints an XOR demonstration, and runs basic bitstream statistics. The statistics are descriptive only; they do not certify entropy quality.

To run only the full TRNG testbench:

```sh
make sim
```

To open the TRNG waveform (requires GTKWave):

```sh
make wave
```

### 4. Run the AES/UART HSM simulation

```sh
make test_hsm
```

This simulates a UART encrypt request followed by a decrypt request and checks the plaintext round trip. The simulation ring oscillator uses pseudo-random simulator delays, not physical FPGA noise.

To open the HSM waveform:

```sh
make wave_hsm
```

To remove generated simulation files:

```sh
make clean
```

## Step-by-step: use the UART client with an FPGA

1. Build and program the FPGA bitstream using the board-specific steps below.
2. Connect the board's USB-UART bridge or a compatible 3.3 V UART adapter to the computer. Use the board's documented UART pins, common ground, and the correct serial device name.
3. Keep the FPGA powered and programmed. Wait for the initial TRNG key collection to finish.
4. Encrypt a message of at most 16 UTF-8 bytes. For example:

   ```sh
   python3 tools/uart_client.py --port /dev/ttyUSB0 encrypt "Hello"
   ```

   On Windows, replace `/dev/ttyUSB0` with the appropriate COM port, such as `COM3`.

5. Copy the 32-character ciphertext printed by the client and decrypt it before sending another encryption request:

   ```sh
   python3 tools/uart_client.py --port /dev/ttyUSB0 decrypt CIPHERTEXT_HEX
   ```

6. After the decrypt response, the FPGA collects a fresh key. Send the next encryption request only after that collection has completed. The existing client protocol does not provide a ready/status command; allow time for key collection before the next request.

The serial settings are 115200 baud, 8 data bits, no parity, and 1 stop bit. The host sends command `0xEE` for encrypt or `0xDD` for decrypt, followed by a length byte and payload. The FPGA returns 16 bytes, most significant byte first.

## Implement on an AMD Spartan-7 board

This repository does not include a Vivado project, board-specific XDC constraints, or a particular Spartan-7 board definition. The exact FPGA part, oscillator frequency, I/O voltage, clock pin, reset pin, and UART pins vary by board. Use the manual and master XDC for the exact board model; do not copy pin numbers from another Spartan-7 board.

### 1. Identify the board configuration

From the board manual or master XDC, record:

- Exact FPGA part number (including package and speed grade)
- On-board clock frequency and clock input pin
- Active-low reset input pin, if used
- UART RX and TX pins or USB-UART bridge connections
- I/O bank voltage and supported I/O standard for those pins
- Whether the board's USB-UART bridge is already wired to FPGA pins

The RTL defaults to `CLK_FREQ=50_000_000` and `BAUD_RATE=115_200`. Set `CLK_FREQ` to the actual board oscillator frequency or UART timing will be wrong. This parameter can be changed in `src/top.v` or through a small board wrapper that instantiates `top` with the appropriate parameter.

### 2. Create a Vivado project

In AMD Vivado, create an RTL project and select the exact Spartan-7 part. Add these synthesizable source files:

```text
src/ring_osc.v
src/synchronizer.v
src/von_neumann.v
src/trng_top.v
src/key_gen.v
src/aes128.v
src/uart_rx.v
src/uart_tx.v
src/top.v
```

Set `top` as the top-level module. Do not add the `tb/` files to the synthesis sources. Add a new XDC file for the board constraints. AMD documents the Vivado project flow in [UG895](https://docs.amd.com/r/en-US/ug895-vivado-system-level-design-entry/Creating-a-Project).

### 3. Add board-specific XDC constraints

Use the actual pin names and I/O standard from the board documentation. The following is only a template; replace every placeholder before running implementation:

```tcl
set_property PACKAGE_PIN <CLOCK_PIN> [get_ports i_clk]
set_property IOSTANDARD <BOARD_IOSTANDARD> [get_ports i_clk]
create_clock -name sys_clk -period <CLOCK_PERIOD_NS> [get_ports i_clk]

set_property PACKAGE_PIN <RESET_PIN> [get_ports i_reset_n]
set_property IOSTANDARD <BOARD_IOSTANDARD> [get_ports i_reset_n]

set_property PACKAGE_PIN <UART_RX_PIN> [get_ports i_uart_rx]
set_property IOSTANDARD <BOARD_IOSTANDARD> [get_ports i_uart_rx]

set_property PACKAGE_PIN <UART_TX_PIN> [get_ports o_uart_tx]
set_property IOSTANDARD <BOARD_IOSTANDARD> [get_ports o_uart_tx]
```

For a 50 MHz clock, `<CLOCK_PERIOD_NS>` is `20.000`; for another frequency calculate `1e9 / frequency_in_hz`. Follow the board's voltage requirements. AMD documents XDC timing and pin constraints in [UG903](https://docs.amd.com/r/en-US/ug903-vivado-using-constraints/Supported-SDC-Commands) and the [`PACKAGE_PIN` property](https://docs.amd.com/r/2024.1-English/ug912-vivado-properties/PACKAGE_PIN).

### 4. Synthesize and inspect the ring oscillators

Run Synthesis, then review the log and synthesized design. `ring_osc.v` selects a combinational inverter loop when synthesized and includes preservation attributes, but a ring oscillator is an intentional combinational feedback loop. Vivado may report or optimize such loops, and successful synthesis alone does not prove that the routed oscillators work. Confirm that all three loops remain in the synthesized and implemented netlist, inspect the loop-related warnings, and check that the design meets timing on the system-clocked logic. Do not suppress broad timing checks to hide unrelated errors.

The mapped oscillator frequencies and jitter depend on FPGA family, placement, routing, voltage, and temperature. The simulation's randomized delays do not predict those hardware properties. Validate the actual bitstream statistically and electrically on the target board before treating its output as entropy.

### 5. Implement and generate the bitstream

In Vivado, run Implementation, review timing and DRC reports, then generate the `.bit` programming file. Resolve pin, I/O standard, timing, and implementation errors for the selected board before programming it. Vivado's supported project and implementation flow is described in [UG895](https://docs.amd.com/r/en-US/ug895-vivado-system-level-design-entry/Creating-a-Project).

### 6. Program and connect to the board

Connect the board over its JTAG programmer, open Vivado Hardware Manager, open the hardware target, select the generated bitstream, and program the FPGA. Confirm the device reports successful programming. See AMD's [UG908 programming instructions](https://docs.amd.com/r/en-US/ug908-vivado-programming-debugging/Programming-the-Hardware-Device).

Connect the PC to the board's UART bridge and follow the [UART client steps](#step-by-step-use-the-uart-client-with-an-fpga). Ensure that the PC serial port is not open in another terminal program at the same time.

## Entropy analysis

Analyze a simulated or captured bitstream with:

```sh
python3 tools/analyze_entropy.py build/random_bits.txt
```

The script reports bit counts, one proportion, run count, autocorrelation at lag 1, and empirical Shannon entropy. These are basic descriptive checks, not NIST SP 800-22 or AIS-31 certification. A hardware evaluation needs large samples and an appropriate entropy assessment for the target device and operating conditions.

## Security and implementation limits

- The simulator uses pseudo-random delay variation; it does not model physical FPGA noise or demonstrate a cryptographically secure random source.
- The Von Neumann corrector removes bias only under assumptions about consecutive samples; it does not prove that the sampled stream has sufficient entropy or independence.
- The AES path uses ECB mode, zero padding, and no authentication. It is a functional demonstration, not a secure production encryption protocol.
- The AES key is never sent over UART, but the project has not been evaluated for side-channel leakage, fault attacks, tampering, or production key management.
- Spartan-7 implementation requires board-specific constraints and validation. No specific board or `.xdc` file is included in this repository.
