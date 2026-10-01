#!/usr/bin/env python3
"""Bounded MQTT 5 loopback fixture, never a production broker.

Only lorisiot/test/* topics are accepted. No credentials, external listeners,
configuration files or network forwarding. Used by run-loopback-tests.sh.
"""
import json
import socket
import threading
import time
import sys

lock = threading.Lock()
clients = set()
retained = {}
MAX_PACKET = 65536

def remaining(n):
    out = bytearray()
    while True:
        digit = n % 128
        n //= 128
        out.append(digit | (128 if n else 0))
        if not n:
            return bytes(out)

def exact(conn, n):
    data = bytearray()
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            raise EOFError()
        data.extend(chunk)
    return bytes(data)

def packet(conn):
    header = exact(conn, 1)[0]
    length = 0
    for i in range(4):
        digit = exact(conn, 1)[0]
        length += (digit & 127) << (7 * i)
        if not digit & 128:
            if length > MAX_PACKET:
                raise ValueError('packet bound')
            return header, exact(conn, length)
    raise ValueError('remaining length')

def varint(data, offset):
    value = 0
    for i in range(4):
        digit = data[offset + i]
        value += (digit & 127) << (7 * i)
        if not digit & 128:
            return value, offset + i + 1
    raise ValueError('property length')

def string(data, offset):
    n = int.from_bytes(data[offset:offset+2], 'big')
    end = offset + 2 + n
    if end > len(data):
        raise ValueError('truncated string')
    return data[offset+2:end].decode('utf-8'), end

def allowed(topic):
    return topic.startswith('lorisiot/test/') and not any(c in topic for c in ('#', '+', '\x00'))

class Client:
    def __init__(self, conn):
        self.conn = conn
        self.send_lock = threading.Lock()
        self.topics = set()
        self.pending = {}
    def send(self, header, body):
        with self.send_lock:
            self.conn.sendall(bytes([header]) + remaining(len(body)) + body)
    def publish(self, topic, payload, retain=False):
        raw = topic.encode()
        self.send(0x31 if retain else 0x30, len(raw).to_bytes(2, 'big') + raw + b'\x00' + payload)
    def distribute(self, topic, payload, keep):
        with lock:
            if keep:
                if payload:
                    retained[topic] = payload
                else:
                    retained.pop(topic, None)
            recipients = [c for c in clients if topic in c.topics]
        for client in recipients:
            try:
                client.publish(topic, payload)
            except OSError:
                pass
    def run(self):
        try:
            header, body = packet(self.conn)
            protocol, pos = string(body, 0)
            if header != 0x10 or protocol != 'MQTT' or body[pos] != 5:
                raise ValueError('requires MQTT 5')
            if body[pos+1] & 0xc0:
                raise ValueError('credentials forbidden')
            self.send(0x20, b'\x00\x00\x00')
            with lock:
                clients.add(self)
            while True:
                header, body = packet(self.conn)
                kind = header >> 4
                if kind == 8:
                    ident = body[:2]
                    count, pos = varint(body, 2)
                    pos += count
                    grants, replay = [], []
                    while pos < len(body):
                        topic, pos = string(body, pos)
                        qos = body[pos] & 3
                        pos += 1
                        accept = allowed(topic) and '/denied/' not in topic and qos <= 2
                        grants.append(qos if accept else 0x87)
                        if accept:
                            with lock:
                                self.topics.add(topic)
                                if topic in retained:
                                    replay.append((topic, retained[topic]))
                    self.send(0x90, ident + b'\x00' + bytes(grants))
                    for topic, payload in replay:
                        self.publish(topic, payload, True)
                elif kind == 3:
                    topic, pos = string(body, 0)
                    if not allowed(topic):
                        raise ValueError('topic outside fixture')
                    qos = (header >> 1) & 3
                    ident = body[pos:pos+2] if qos else b''
                    pos += 2 if qos else 0
                    count, pos = varint(body, pos)
                    pos += count
                    payload = body[pos:]
                    if qos == 2:
                        self.pending[ident] = (topic, payload, bool(header & 1))
                        self.send(0x50, ident + b'\x00\x00')
                    else:
                        self.distribute(topic, payload, bool(header & 1))
                        if qos == 1:
                            self.send(0x40, ident + b'\x00\x00')
                        if '/drop/' in topic:
                            break
                elif kind == 6:
                    ident = body[:2]
                    self.distribute(*self.pending.pop(ident))
                    self.send(0x70, ident + b'\x00\x00')
                elif kind == 12:
                    self.send(0xd0, b'')
                elif kind == 14:
                    break
                else:
                    raise ValueError('unsupported fixture packet')
        except (EOFError, OSError):
            pass
        except Exception:
            print('fixture protocol rejected', file=sys.stderr, flush=True)
        finally:
            with lock:
                clients.discard(self)
            self.conn.close()

listener = socket.socket()
listener.bind(('127.0.0.1', 0))
listener.listen(8)
listener.settimeout(1)
print(json.dumps({'port': listener.getsockname()[1]}), flush=True)
deadline = time.monotonic() + 180
while time.monotonic() < deadline:
    try:
        conn, _ = listener.accept()
        conn.settimeout(30)
        threading.Thread(target=Client(conn).run, daemon=True).start()
    except socket.timeout:
        continue
listener.close()
