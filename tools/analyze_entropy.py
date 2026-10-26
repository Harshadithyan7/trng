#!/usr/bin/env python3
"""Report basic statistics for a text file containing 0/1 bits."""

import argparse
import math
from pathlib import Path


def load_bits(path: Path) -> list[int]:
    text = path.read_text(encoding="ascii")
    invalid = set(text) - {"0", "1", " ", "\t", "\r", "\n"}
    if invalid:
        raise ValueError(f"unexpected character(s): {''.join(sorted(invalid))!r}")
    bits = [int(char) for char in text if char in "01"]
    if not bits:
        raise ValueError("input contains no bits")
    return bits


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bitstream", type=Path)
    parser.add_argument("--offset", type=int, default=1, help="autocorrelation lag (default: 1)")
    args = parser.parse_args()

    bits = load_bits(args.bitstream)
    if args.offset < 1 or args.offset >= len(bits):
        parser.error("--offset must be between 1 and the number of bits minus 1")

    ones = sum(bits)
    zeros = len(bits) - ones
    runs = 1 + sum(left != right for left, right in zip(bits, bits[1:]))
    lagged = [1 if bit else -1 for bit in bits]
    correlation = sum(lagged[index] * lagged[index - args.offset] for index in range(args.offset, len(bits)))
    correlation /= len(bits) - args.offset
    p_one = ones / len(bits)
    entropy = 0.0
    for probability in (p_one, 1 - p_one):
        if probability:
            entropy -= probability * math.log2(probability)

    print(f"bits: {len(bits)}")
    print(f"zeros: {zeros}")
    print(f"ones: {ones}")
    print(f"one proportion: {p_one:.6f}")
    print(f"runs: {runs}")
    print(f"autocorrelation (lag {args.offset}): {correlation:.6f}")
    print(f"Shannon entropy: {entropy:.6f} bits/bit")
    print("Note: descriptive checks only; this is not NIST SP 800-22 or AIS-31 validation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())