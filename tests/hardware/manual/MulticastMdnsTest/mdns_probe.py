import argparse
import socket
import struct
import time
from pathlib import Path


GROUP = "224.0.0.251"
PORT = 5353
HOSTNAME = "az3166-mdns-test.local"
SERVICE = "_http._tcp.local"
INSTANCE = b"az3166-mdns-test"
TXT = b"path=/hardware-validation"


def encode_name(name):
    return b"".join(
        bytes([len(part)]) + part.encode("ascii")
        for part in name.split(".")
    ) + b"\0"


def make_query(name, record_type):
    return (
        struct.pack("!HHHHHH", 0, 0, 1, 0, 0, 0)
        + encode_name(name)
        + struct.pack("!HH", record_type, 1)
    )


def open_multicast_socket(local_address):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", PORT))
    sock.setsockopt(
        socket.IPPROTO_IP,
        socket.IP_ADD_MEMBERSHIP,
        socket.inet_aton(GROUP) + socket.inet_aton(local_address),
    )
    sock.setsockopt(
        socket.IPPROTO_IP,
        socket.IP_MULTICAST_IF,
        socket.inet_aton(local_address),
    )
    sock.settimeout(0.3)
    return sock


def drain(sock):
    while True:
        try:
            sock.recvfrom(4096)
        except socket.timeout:
            return


def wait_for_response(sock, board, expected, timeout=8):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            data, source = sock.recvfrom(4096)
        except socket.timeout:
            continue
        if source[0] != board or len(data) < 12:
            continue
        flags = struct.unpack("!H", data[2:4])[0]
        if flags & 0x8000 and all(value in data for value in expected):
            return data
    raise RuntimeError("No matching mDNS response was received")


def probe(local_address, board, send_only):
    sock = open_multicast_socket(local_address)
    try:
        drain(sock)
        address_query = make_query(HOSTNAME, 1)
        service_query = make_query(SERVICE, 12)
        query = service_query if send_only else address_query
        for _ in range(3):
            sock.sendto(query, (GROUP, PORT))
            time.sleep(0.15)
        if send_only:
            time.sleep(3)
            return

        address = wait_for_response(
            sock,
            board,
            [socket.inet_aton(board)],
        )
        drain(sock)
        for _ in range(3):
            sock.sendto(service_query, (GROUP, PORT))
            time.sleep(0.15)
        service = wait_for_response(
            sock,
            board,
            [INSTANCE, TXT, struct.pack("!H", 8080), socket.inet_aton(board)],
        )
        txt_offset = service.index(TXT)
        if service[txt_offset - 1] != len(TXT):
            raise RuntimeError("TXT character-string length is invalid")
        _, flags, questions, answers, authority, additional = struct.unpack(
            "!HHHHHH", service[:12]
        )
        print(
            "MDNS_DNSSD_HARDWARE_PASS "
            f"address_bytes={len(address)} service_bytes={len(service)} "
            f"flags=0x{flags:04x} questions={questions} answers={answers} "
            f"authority={authority} additional={additional}"
        )
    finally:
        sock.close()


def iter_pcapng_packets(path):
    data = Path(path).read_bytes()
    offset = 0
    byte_order = "<"
    while offset + 12 <= len(data):
        block_type = struct.unpack_from(byte_order + "I", data, offset)[0]
        block_length = struct.unpack_from(byte_order + "I", data, offset + 4)[0]
        if block_length < 12 or offset + block_length > len(data):
            raise RuntimeError("Invalid PCAPNG block length")
        if block_type == 0x0A0D0D0A:
            magic = data[offset + 8:offset + 12]
            if magic == b"\x1a\x2b\x3c\x4d":
                byte_order = ">"
            elif magic == b"\x4d\x3c\x2b\x1a":
                byte_order = "<"
            else:
                raise RuntimeError("Invalid PCAPNG byte-order magic")
        elif block_type == 6 and block_length >= 32:
            captured_length = struct.unpack_from(
                byte_order + "I", data, offset + 20
            )[0]
            packet_start = offset + 28
            yield data[packet_start:packet_start + captured_length]
        offset += block_length


def verify_ttl(path, board):
    matches = []
    board_bytes = socket.inet_aton(board)
    for frame in iter_pcapng_packets(path):
        if len(frame) < 42 or frame[12:14] != b"\x08\x00":
            continue
        ip_offset = 14
        header_length = (frame[ip_offset] & 0x0F) * 4
        if header_length < 20 or len(frame) < ip_offset + header_length + 8:
            continue
        if frame[ip_offset + 9] != socket.IPPROTO_UDP:
            continue
        if frame[ip_offset + 12:ip_offset + 16] != board_bytes:
            continue
        udp_offset = ip_offset + header_length
        source_port = struct.unpack("!H", frame[udp_offset:udp_offset + 2])[0]
        if source_port == PORT:
            matches.append(frame[ip_offset + 8])
    if not matches:
        raise RuntimeError("No board mDNS responses were found in the capture")
    if any(ttl != 255 for ttl in matches):
        raise RuntimeError(f"Board mDNS TTL values were not all 255: {matches}")
    print(f"MDNS_TTL_255_HARDWARE_PASS packets={len(matches)}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--local")
    parser.add_argument("--board", required=True)
    parser.add_argument("--send-only", action="store_true")
    parser.add_argument("--pcap")
    args = parser.parse_args()
    if args.pcap:
        verify_ttl(args.pcap, args.board)
    elif args.local:
        probe(args.local, args.board, args.send_only)
    else:
        parser.error("--local is required unless --pcap is used")


if __name__ == "__main__":
    main()
