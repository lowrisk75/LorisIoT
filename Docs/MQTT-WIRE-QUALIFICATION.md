# CocoaMQTT socket qualification

`python3 Scripts/mqtt/run-loopback-tests.py` builds the test targets, starts an
MQTT 5 fixture on an ephemeral IPv4 loopback port, and runs six opt-in socket
contracts against the actual CocoaMQTT transport:

- CONNECT, SUBSCRIBE, QoS 1 publish and receipt;
- retained replay to a later subscriber;
- QoS 2 PUBREC/PUBREL/PUBCOMP completion;
- denied SUBACK retires the transport;
- retained metadata reaches `MQTTObservation`;
- socket interruption followed by automatic reconnect, subscription replay and
  delivery on the original subscription.

The fixture accepts only exact `lorisiot/test/*` topics, rejects credentials,
bounds packets to 64 KiB and connections to thirty seconds of inactivity, and
exits after three minutes. It binds only `127.0.0.1`; it does not forward traffic,
configure a server, connect to devices or read credentials. It is deliberately
not a complete MQTT broker. The runner terminates its own broker in `finally`,
bounds compilation to fifteen minutes and tests to 150 seconds, and treats
fixture protocol errors as failure. Set `LORISIOT_TEST_SCRATCH` to reuse a build.

The normal unit suite skips these opt-in tests. CI separately runs the loopback
contracts after the full unit suite, with the same build directory. The existing
live tests can still target an explicitly selected broker; the loopback-only
suite additionally requires `LORISIOT_MQTT_LOOPBACK=1` and refuses a non-loopback
host.

This proves the real CocoaMQTT socket path against a controlled fixture. It does
not qualify a signed app's Keychain/local-network/background lifecycle, TLS,
EMQX authentication/ACLs, or physical Zigbee/Matter devices. Physical Matter
pairing is separately deferred; no pairing is needed for this test.
