#!/usr/bin/env python3
#
# Copyright 2017 Jeff Bush
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implieconn.
# See the License for the specific language governing permissions and
# limitations under the License.
#

import socket
import subprocess
import sys
import time
import struct
import os

sys.path.insert(0, '..')
import test_harness


DEBUG = True
CONTROL_PORT = 8541

class VerilatorProcess(object):

    """
    Manages spawning the emulator and automatically stopping it at the
    end of the test. It supports __enter__ and __exit__ methods so it
    can be used in the 'with' construct.
    """

    def __init__(self, hexfile):
        self.hexfile = hexfile
        self.process = None
        self.output = None

    def __enter__(self):
        verilator_args = [
            test_harness.BIN_DIR + 'verilator_model',
            '+bin=' + self.hexfile,
            '+jtag_port=' + str(CONTROL_PORT),
            self.hexfile
        ]

        if DEBUG:
            self.output = None
        else:
            self.output = open(os.devnull, 'w')

        self.process = subprocess.Popen(verilator_args, stdout=self.output,
                                        stderr=subprocess.STDOUT)
        return self

    def __exit__(self, *unused):
        self.process.kill()
        if self.output:
            self.output.close()

class DebugConnection(object):

    """
    Encapsulates control socket connection to JTAG port on verilator. It supports
    __enter__ and __exit__ methods so it can be used in the 'with' construct
    to automatically close the socket when the test is done.
    """

    def __init__(self):
        self.sock = None

    def __enter__(self):
        # Retry loop
        for _ in range(10):
            try:
                time.sleep(0.3)
                self.sock = socket.socket()
                self.sock.connect(('localhost', CONTROL_PORT))
                self.sock.settimeout(5)
                break
            except socket.error:
                pass

        return self

    def __exit__(self, *unused):
        self.sock.close()

    def jtag_transfer(self, instruction_length, instruction, data_length, data):
        self.sock.send(struct.pack('<BIBQ', instruction_length, instruction,
                                   data_length, data))
        data_val = struct.unpack('<Q', self.sock.recv(8))[0]
        return data_val & ((1 << data_length) - 1)

@test_harness.test
def jtag(_):
    hexfile = test_harness.build_program(['test_program.S'])

    with VerilatorProcess(hexfile), DebugConnection() as conn:
        print('response1: ' + hex(conn.jtag_transfer(4, 0xa, 32, 0x12345678)))
        print('response2: ' + hex(conn.jtag_transfer(4, 0x3, 32, 0xdeadbeef)))

test_harness.execute_tests()
