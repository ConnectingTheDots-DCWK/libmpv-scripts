#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
impacket's SMB2 server for network_test.sh: share SHARE, read only, user u
with password p, NTLM as libsmb2.c asks for. impacket also lets in a URL
with no password, as an anonymous login. It listens on a free port of
127.0.0.1 and prints "ready <port>".

A read at the end of a file gets the error reply Windows and Samba send.
impacket sends an empty read reply with STATUS_END_OF_FILE, which libsmb2
cannot parse, so the stream would end with an I/O error instead.

Usage: smb_server.py <share dir>
"""
import sys

from impacket import smb3structs as smb2
from impacket import smbserver
from impacket.nt_errors import STATUS_END_OF_FILE
from impacket.ntlm import compute_lmhash, compute_nthash

server = smbserver.SimpleSMBServer(listenAddress='127.0.0.1', listenPort=0)
server.addShare('SHARE', sys.argv[1], '', readOnly='yes')
server.setSMB2Support(True)
server.addCredential('u', 0, compute_lmhash('p'), compute_nthash('p'))
server.setSMBChallenge('')


def read(conn, smb_server, packet):
    replies, files, status = impacket_read(conn, smb_server, packet)
    if status == STATUS_END_OF_FILE:
        replies = [smb2.SMB2Error()]
    return replies, files, status


impacket_read = server.getServer().hookSmb2Command(smb2.SMB2_READ, read)
print('ready', server.getServer().server_address[1], flush=True)
server.start()
