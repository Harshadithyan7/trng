#!/usr/bin/env python3
"""
uart_client.py -- FPGA AES-128 HSM client.
Key is generated inside the FPGA (TRNG) and never transmitted externally.

Usage:
  python3 tools/uart_client.py --port /dev/ttyUSB0 encrypt "Hello, World!"
  python3 tools/uart_client.py --port /dev/ttyUSB0 decrypt <32-hex-char ciphertext>

Protocol (PC -> FPGA):
  Byte 0 : CMD  0xEE=encrypt  0xDD=decrypt
  Byte 1 : LEN  1-16 (payload byte count)
  Byte 2+ : DATA  LEN bytes (zero-padded to 16 on the FPGA)

Response (FPGA -> PC):
  16 bytes (AES block output, MSB first)
"""

import argparse
import sys

try:
    import serial
except ImportError:
    print("Error: pyserial not installed.  Run: pip install pyserial")
    sys.exit(1)

CMD_ENCRYPT = 0xEE
CMD_DECRYPT = 0xDD
BAUD_RATE   = 115200
TIMEOUT_SEC = 10.0
BLOCK_SIZE  = 16


def open_port(port: str) -> "serial.Serial":
    return serial.Serial(
        port     = port,
        baudrate = BAUD_RATE,
        bytesize = serial.EIGHTBITS,
        parity   = serial.PARITY_NONE,
        stopbits = serial.STOPBITS_ONE,
        timeout  = TIMEOUT_SEC,
    )


def send_request(ser: "serial.Serial", cmd: int, data: bytes) -> bytes:
    if len(data) < 1 or len(data) > BLOCK_SIZE:
        raise ValueError(f"Data must be 1-{BLOCK_SIZE} bytes, got {len(data)}")
    frame = bytes([cmd, len(data)]) + data
    ser.write(frame)
    response = ser.read(BLOCK_SIZE)
    if len(response) != BLOCK_SIZE:
        raise TimeoutError(f"Expected {BLOCK_SIZE} bytes, received {len(response)}")
    return response


def cmd_encrypt(args):
    message = args.message.encode("utf-8")
    if len(message) > BLOCK_SIZE:
        print(f"Error: message too long ({len(message)} bytes; max {BLOCK_SIZE})")
        sys.exit(1)
    with open_port(args.port) as ser:
        print(f"[+] Encrypting: {args.message!r}")
        ct = send_request(ser, CMD_ENCRYPT, message)
        print(f"[+] Ciphertext : {ct.hex()}")
    print("    (Send this back for decryption before encrypting another message)")


def cmd_decrypt(args):
    try:
        ct = bytes.fromhex(args.hexdata)
    except ValueError as e:
        print(f"Error: invalid hex -- {e}")
        sys.exit(1)
    if len(ct) != BLOCK_SIZE:
        print(f"Error: ciphertext must be exactly {BLOCK_SIZE*2} hex chars ({BLOCK_SIZE} bytes)")
        sys.exit(1)
    with open_port(args.port) as ser:
        print(f"[+] Decrypting: {args.hexdata}")
        pt_raw = send_request(ser, CMD_DECRYPT, ct)
        pt = pt_raw.rstrip(b"\x00")
        print(f"[+] Plaintext  : {pt_raw.hex()}")
        try:
            print(f"[+] As text    : {pt.decode('utf-8')!r}")
        except UnicodeDecodeError:
            print("[+] As text    : <binary / non-UTF-8>")


def main():
    parser = argparse.ArgumentParser(
        description="FPGA AES-128 HSM client -- the key never leaves the FPGA."
    )
    parser.add_argument("--port", default="/dev/ttyUSB0",
                        help="Serial port (default /dev/ttyUSB0)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    ep = sub.add_parser("encrypt", help="Encrypt a plaintext string")
    ep.add_argument("message", help="Plaintext (max 16 bytes)")
    ep.set_defaults(func=cmd_encrypt)

    dp = sub.add_parser("decrypt", help="Decrypt a 32-char hex ciphertext")
    dp.add_argument("hexdata", help="Ciphertext as 32 hex characters")
    dp.set_defaults(func=cmd_decrypt)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
