#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
A TCP connect that takes seconds, without root (no netem, no iptables), for
network_test.sh. It listens on a free port of 127.0.0.1 and holds its
listen queue full with a connection of its own, so the kernel drops the
client's SYN and the client sends it again (after 1 s, then every second
or two on Linux). After <delay> seconds the queue is drained and every
connection from then on is forwarded to 127.0.0.1:<target port>. Prints
"ready <port>" when the queue is full.

Usage: slow_connect.py <target port> <delay>
"""
import socket
import sys
import threading
import time

target, delay = int(sys.argv[1]), float(sys.argv[2])
ls = socket.socket()
ls.bind(('127.0.0.1', 0))
ls.listen(0)
port = ls.getsockname()[1]
filler = socket.create_connection(('127.0.0.1', port))
fillers = {filler.getsockname()}
time.sleep(0.2)
print('ready', port, flush=True)
time.sleep(delay)


def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    for s in (a, b):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


while True:
    c, addr = ls.accept()
    if addr in fillers:
        continue
    print('accepted %s' % (addr,), flush=True)
    t = socket.create_connection(('127.0.0.1', target))
    threading.Thread(target=pipe, args=(c, t), daemon=True).start()
    threading.Thread(target=pipe, args=(t, c), daemon=True).start()
