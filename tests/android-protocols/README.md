# Isolated Android-core protocol traffic fixture

This optional module uses the locked Android Xray source, loopback-only
listeners/dialing and in-memory temporary TLS certificates. It never creates
a TUN, changes routes or accesses a production subscription/server.

The initial run on 2026-10-30 timed out in all 20 TCP/UDP cases. A diagnostic
trace showed the fixture server's default Xray freedom policy blackholing the
private loopback echo targets. The corrected fixture permits **only** the two
ephemeral TCP/UDP echo endpoints and then blocks everything else; production
policy was not weakened. After the owner resumed checks, all 20 positive
round-trips passed. The earlier failures remain documented here.

Run `go test -mod=readonly -count=1 -run TestIsolatedProtocol -v .`.
It must continue to refuse all non-loopback destinations.

`python run.py --go <go> --dart <dart>` also runs the tracked production Dart
exporter and checks all 13 generated profiles over TCP and UDP. The fixture
changes only endpoint/test certificate trust and uses the actual protocol,
transport and synthetic credentials. Seven negative cases reject wrong
credentials, TLS names or untrusted certificates. These checks passed.

This exercises the locked Android Go core on the build host. It does not create
Android VpnService/TUN, run an emulator/device or prove a live remote tunnel.
