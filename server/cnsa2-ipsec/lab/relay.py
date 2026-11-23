#!/usr/bin/env python3
"""UDP-over-TCP relay for the lab. Colima forwards TCP ports to the Mac but
not UDP, so IKE and ESP datagrams are carried as length-prefixed frames.

  in a sidecar container:         relay.py gateway 14500 cnsa2-devgw:4500
  on the Mac:                    relay.py host 127.0.0.1:14500 4500 [bind address, 0.0.0.0 to serve the LAN]
"""
import socket, struct, sys, threading

def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf

def pump_tcp_to_udp(conn, udp, dest_getter):
    try:
        while True:
            (n,) = struct.unpack("!H", recv_exact(conn, 2))
            data = recv_exact(conn, n)
            dest = dest_getter()
            if dest:
                udp.sendto(data, dest)
    except (ConnectionError, OSError):
        pass

def gateway(tcp_port, target):
    host, _, port = target.rpartition(":")
    host, udp_port = host or "127.0.0.1", int(port)
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", tcp_port)); srv.listen(4)
    while True:
        conn, _ = srv.accept()
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.connect((host, udp_port))
        dest = udp.getpeername()
        threading.Thread(target=pump_tcp_to_udp, args=(conn, udp, lambda: dest), daemon=True).start()
        def back(conn=conn, udp=udp):
            try:
                while True:
                    data = udp.recv(65535)
                    conn.sendall(struct.pack("!H", len(data)) + data)
            except OSError:
                pass
        threading.Thread(target=back, daemon=True).start()

def host(tcp_addr, udp_port, bind="127.0.0.1"):
    h, p = tcp_addr.split(":")
    conn = socket.create_connection((h, int(p)))
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind((bind, udp_port))
    peer = [None]
    threading.Thread(target=pump_tcp_to_udp, args=(conn, udp, lambda: peer[0]), daemon=True).start()
    while True:
        data, addr = udp.recvfrom(65535)
        if addr != peer[0]:
            print("client", addr, flush=True)
        peer[0] = addr
        conn.sendall(struct.pack("!H", len(data)) + data)

if __name__ == "__main__":
    if sys.argv[1] == "gateway":
        gateway(int(sys.argv[2]), sys.argv[3])
    else:
        host(sys.argv[2], int(sys.argv[3]), sys.argv[4] if len(sys.argv) > 4 else "127.0.0.1")
