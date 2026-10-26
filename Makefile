IVERILOG ?= iverilog
VVP      ?= vvp
GTKWAVE  ?= gtkwave
BUILD_DIR := build

# Core TRNG RTL (unchanged from Phase 1)
TRNG_RTL := src/ring_osc.v src/synchronizer.v src/von_neumann.v src/trng_top.v

# New HSM RTL
HSM_RTL  := $(TRNG_RTL) \
             src/key_gen.v \
             src/uart_rx.v \
             src/uart_tx.v \
             src/aes128.v  \
             src/top.v

.PHONY: all test test_hsm sim wave wave_hsm clean

all: test test_hsm

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# ---- Phase-1 targets (unchanged) ----
$(BUILD_DIR)/tb_ring_osc: src/ring_osc.v tb/tb_ring_osc.v | $(BUILD_DIR)
	$(IVERILOG) -g2012 -s tb_ring_osc -o $@ src/ring_osc.v tb/tb_ring_osc.v

$(BUILD_DIR)/tb_trng_top: $(TRNG_RTL) tb/tb_trng_top.v | $(BUILD_DIR)
	$(IVERILOG) -g2012 -s tb_trng_top -o $@ $(TRNG_RTL) tb/tb_trng_top.v

sim: $(BUILD_DIR)/tb_trng_top
	$(VVP) $<

test: $(BUILD_DIR)/tb_ring_osc $(BUILD_DIR)/tb_trng_top
	$(VVP) $(BUILD_DIR)/tb_ring_osc
	$(VVP) $(BUILD_DIR)/tb_trng_top
	python3 tools/analyze_entropy.py $(BUILD_DIR)/random_bits.txt

wave: $(BUILD_DIR)/tb_trng_top
	$(VVP) $<
	$(GTKWAVE) $(BUILD_DIR)/trng.vcd

# ---- Phase-2 HSM targets ----
$(BUILD_DIR)/tb_top: $(HSM_RTL) tb/tb_top.v | $(BUILD_DIR)
	$(IVERILOG) -g2012 -s tb_top -o $@ $(HSM_RTL) tb/tb_top.v

test_hsm: $(BUILD_DIR)/tb_top
	$(VVP) $(BUILD_DIR)/tb_top

wave_hsm: $(BUILD_DIR)/tb_top
	$(VVP) $(BUILD_DIR)/tb_top
	$(GTKWAVE) $(BUILD_DIR)/trng_hsm.vcd

clean:
	rm -rf $(BUILD_DIR)
