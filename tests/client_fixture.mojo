from std.sys import argv
from std.testing import assert_equal
from mojolt.websockets.sync.client import Client
from mojolt.websockets.utils.bytes import str_to_bytes


def main() raises:
    var args = argv()
    with Client(args[1], timeout_ms=1000, close_timeout_ms=300) as client:
        client.send_text("Привет 🌍")
        assert_equal(client.recv_text(), "Привет 🌍")
        var binary = str_to_bytes("A")
        binary.append(0)
        client.send_binary(binary)
        assert_equal(client.recv(), binary)
    print("client ok")
