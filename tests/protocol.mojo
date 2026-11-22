"""Regression cases for protocol state independent of network scheduling."""
from std.collections import Optional
from std.memory import Pointer
from std.sys import argv
from std.testing import assert_equal, assert_true, assert_false
from mojolt.websockets.aliases import Bytes
from mojolt.websockets.frames import Frame, Close, OpCode
from mojolt.websockets.http import HTTPRequest, Headers, Header, HTTPResponse, has_token, encode
from mojolt.websockets.protocol import OPEN, CLOSING, CLOSED, CONNECTING
from mojolt.websockets.protocol.base import receive_data, receive_eof, send_text, send_binary, send_continuation, send_close
from mojolt.websockets.protocol.client import ClientProtocol
from mojolt.websockets.protocol.server import ServerProtocol
from mojolt.websockets.streams import StreamReader
from mojolt.websockets.utils.bytes import str_to_bytes, bytes_to_str, b64decode
from mojolt.websockets.utils.uri import URI
from mojolt.websockets.utils.utf8 import UTF8Validator


def open_server(size: Int = 1024) -> ServerProtocol:
    var protocol = ServerProtocol(max_size=size)
    protocol.set_state(OPEN)
    return protocol^


def deliver(mut protocol: ServerProtocol, opcode: Int, data: Bytes, fin: Bool = True) raises:
    receive_data(protocol, Frame(opcode, data, fin).serialize(mask=True))


def test_fragmented_utf8_state() raises:
    var protocol = open_server()
    var a: Bytes = [240]
    var b: Bytes = [159, 140, 141]
    deliver(protocol, 1, a, False)
    deliver(protocol, 9, str_to_bytes("ping"))
    deliver(protocol, 0, b)
    assert_false(Bool(protocol.get_parser_exc()))
    assert_false(Bool(protocol.get_curr_size()))
    assert_equal(protocol.incoming_utf8.remaining, 0)


def test_invalid_utf8_close_code() raises:
    var protocol = open_server()
    var invalid: Bytes = [255]
    deliver(protocol, 1, invalid)
    assert_true(Bool(protocol.get_parser_exc()))
    assert_equal(protocol.get_close_sent().value().code, UInt16(1007))


def test_fragmented_limit_close_code() raises:
    var protocol = open_server(3)
    deliver(protocol, 2, str_to_bytes("abc"), False)
    deliver(protocol, 0, str_to_bytes("d"))
    assert_equal(protocol.get_close_sent().value().code, UInt16(1009))


def test_ping_at_message_limit() raises:
    var protocol = open_server(1)
    deliver(protocol, 2, str_to_bytes("a"), False)
    deliver(protocol, 9, str_to_bytes("longer ping"))
    deliver(protocol, 0, Bytes())
    assert_false(Bool(protocol.get_parser_exc()))


def test_copy_retains_partial_input_events_and_output() raises:
    var original = open_server()
    deliver(original, 2, str_to_bytes("event"))
    send_text(original, str_to_bytes("pending"))
    var wire = Frame(2, str_to_bytes("partial")).serialize(mask=True)
    receive_data(original, Bytes(wire[:3]))
    var clone = original.copy()
    assert_equal(clone.reader.buffer, original.reader.buffer)
    assert_equal(clone.reader.offset, original.reader.offset)
    assert_equal(clone.writes, original.writes)
    assert_equal(len(clone.events), len(original.events))
    receive_data(clone, Bytes(wire[3:]))
    assert_equal(len(clone.events), 2)
    assert_equal(len(original.events), 1)


def test_client_copy_retains_input_and_output() raises:
    var original = ClientProtocol(URI.parse("ws://localhost/"))
    original.send_request(original.connect())
    original.reader.feed_data(str_to_bytes("partial HTTP"))
    var clone = original.copy()
    assert_equal(clone.reader.buffer, original.reader.buffer)
    assert_equal(clone.writes, original.writes)
    assert_equal(clone.key, original.key)


def test_outgoing_fragmentation_state() raises:
    var protocol = open_server()
    send_text(protocol, str_to_bytes("a"), fin=False)
    var failed = False
    try:
        send_binary(protocol, str_to_bytes("wrong"))
    except:
        failed = True
    assert_true(failed)
    send_continuation(protocol, str_to_bytes("b"), fin=True)
    assert_false(protocol.expect_continuation_frame())


def test_failed_outgoing_utf8_does_not_corrupt_state() raises:
    var protocol = open_server()
    var invalid: Bytes = [255]
    var failed = False
    try:
        send_text(protocol, invalid, fin=False)
    except:
        failed = True
    assert_true(failed)
    assert_false(protocol.expect_continuation_frame())
    assert_equal(len(protocol.writes), 0)
    send_text(protocol, str_to_bytes("valid"))


def test_frame_limit_is_configurable() raises:
    var reader = StreamReader()
    var header: Bytes = [130, 127, 0, 0, 0, 0, 0, 160, 0, 1]
    reader.feed_data(header)
    var partial = Frame.parse(Pointer(to=reader), mask=False, max_size=20*1024*1024)
    assert_false(Bool(partial))
    assert_equal(reader.offset, 0)


def test_nonminimal_extended_length() raises:
    var protocol = open_server()
    var header: Bytes = [130, 255, 0, 0, 0, 0, 0, 0, 0, 126]
    receive_data(protocol, header)
    assert_equal(protocol.get_close_sent().value().code, UInt16(1002))


def test_close_code_cannot_wrap() raises:
    var protocol = open_server()
    var failed = False
    try:
        send_close(protocol, 66536)
    except:
        failed = True
    assert_true(failed)
    assert_equal(protocol.get_state(), OPEN)
    assert_equal(len(protocol.writes), 0)


def test_eof_before_handshake_closes_state() raises:
    var protocol = ServerProtocol()
    receive_eof(protocol)
    assert_equal(protocol.get_state(), CLOSED)
    assert_true(Bool(protocol.get_handshake_exc()))


def test_server_does_not_parse_handshake_twice() raises:
    var server = ServerProtocol()
    var client = ClientProtocol(URI.parse("ws://localhost/"))
    client.send_request(client.connect())
    receive_data(server, client.data_to_send())
    receive_data(server, Bytes())
    assert_equal(len(server.events), 1)


def test_http_tokens() raises:
    assert_true(has_token("keep-alive, UpGrAdE", "upgrade"))
    assert_false(has_token("notupgrade", "upgrade"))


def test_base64_rejects_excess_padding() raises:
    for encoded in ["AAAA====", "====", "A===", "AA=A", "AAA=====", "AAAB==AA"]:
        var failed = False
        try:
            _ = b64decode(encoded)
        except:
            failed = True
        assert_true(failed)


def test_uri_query_and_ipv6() raises:
    var uri = URI.parse("ws://example.com?token=abc")
    assert_equal(uri.get_hostname(), "example.com")
    assert_equal(uri.get_path(), "/?token=abc")
    uri = URI.parse("ws://user:pass@[::1]:8080/path")
    assert_equal(uri.get_hostname(), "::1")
    assert_equal(uri.get_port(), 8080)
    assert_equal(uri.get_user_info().value()[1], "pass")


def test_uri_rejects_invalid_authority() raises:
    for uri in ["ws://", "ws://localhost:", "ws://localhost:-1", "ws://localhost:65536", "ws://::1/", "ws://[::1]oops/", "ws://localhost/#fragment", "ws://a\r\nb"]:
        var failed = False
        try:
            _ = URI.parse(uri)
        except:
            failed = True
        assert_true(failed)


def test_http_header_injection_rejected() raises:
    var uri = URI.parse("ws://localhost/")
    var headers = Headers(Header("X", "value\r\nInjected: yes"))
    var request = HTTPRequest(uri, headers=headers)
    var failed = False
    try:
        _ = encode(request^)
    except:
        failed = True
    assert_true(failed)


def test_invalid_response_negotiation() raises:
    var client = ClientProtocol(URI.parse("ws://localhost/"))
    var headers = Headers(Header("Connection", "Upgrade"), Header("Upgrade", "websocket"), Header("Sec-WebSocket-Accept", "bad"))
    var response = HTTPResponse(101, "Switching Protocols", headers, Bytes())
    var failed = False
    try:
        client.process_response(response)
    except:
        failed = True
    assert_true(failed)
    assert_equal(client.get_state(), CONNECTING)


def test_utf8_rejects_overlong_surrogate_and_out_of_range() raises:
    var payloads: List[Bytes] = [[192,128], [237,160,128], [244,144,128,128]]
    for wire in payloads:
        var validator = UTF8Validator()
        var failed = False
        try:
            validator.feed(wire, True)
        except:
            failed = True
        assert_true(failed)


def test_eof_is_idempotent() raises:
    var protocol = open_server()
    receive_eof(protocol)
    var first = String(protocol.get_parser_exc().value())
    receive_eof(protocol)
    assert_equal(String(protocol.get_parser_exc().value()), first)
    assert_equal(protocol.get_state(), CLOSED)


def test_outgoing_message_limit() raises:
    var protocol = open_server(3)
    send_binary(protocol, str_to_bytes("abc"), fin=False)
    var failed = False
    try:
        send_continuation(protocol, str_to_bytes("d"), fin=True)
    except:
        failed = True
    assert_true(failed)
    assert_true(protocol.expect_continuation_frame())


def test_integer_pack_rejects_overflow() raises:
    from mojolt.websockets.utils.bytes import pack
    for value in [-1, 256, 1000]:
        var failed = False
        try:
            _ = pack["!B"](value)
        except:
            failed = True
        assert_true(failed)


def test_percent_encoded_credentials() raises:
    var uri = URI.parse("ws://user%40name:p%3Ass@localhost/")
    assert_equal(uri.get_user_info().value()[0], "user@name")
    assert_equal(uri.get_user_info().value()[1], "p:ss")


def test_nonminimal_length_precedes_size_policy() raises:
    var protocol = open_server(1)
    var wire: Bytes = [130,254,0,2]
    receive_data(protocol, wire)
    assert_equal(protocol.get_close_sent().value().code, UInt16(1002))


def test_http_chunk_terminator_inside_payload() raises:
    from mojolt.websockets.http import parse_chunked_body
    var data = str_to_bytes("a\r\nX\r\n0\r\n\r\nYZ\r\n0\r\nX-Test: yes\r\n\r\n")
    var body = parse_chunked_body(data[:])
    assert_true(Bool(body))
    assert_equal(bytes_to_str(body.value()), "X\r\n0\r\n\r\nYZ")
    for i in range(len(data)):
        var partial = parse_chunked_body(data[:i])
        assert_false(Bool(partial))


def test_http_chunk_rejects_invalid_size_and_delimiter() raises:
    from mojolt.websockets.http import parse_chunked_body
    for encoded in ["z\r\nx\r\n0\r\n\r\n", "1\r\nxXX", "1000000000000000000000\r\n"]:
        var data = str_to_bytes(encoded)
        var failed = False
        try:
            _ = parse_chunked_body(data[:])
        except:
            failed = True
        assert_true(failed)

comptime TestCase = def() raises thin -> None

def main() raises:
    var cases: List[Tuple[String, TestCase]] = [
        ("test_fragmented_utf8_state", test_fragmented_utf8_state),
        ("test_invalid_utf8_close_code", test_invalid_utf8_close_code),
        ("test_fragmented_limit_close_code", test_fragmented_limit_close_code),
        ("test_ping_at_message_limit", test_ping_at_message_limit),
        ("test_copy_retains_partial_input_events_and_output", test_copy_retains_partial_input_events_and_output),
        ("test_client_copy_retains_input_and_output", test_client_copy_retains_input_and_output),
        ("test_outgoing_fragmentation_state", test_outgoing_fragmentation_state),
        ("test_failed_outgoing_utf8_does_not_corrupt_state", test_failed_outgoing_utf8_does_not_corrupt_state),
        ("test_frame_limit_is_configurable", test_frame_limit_is_configurable),
        ("test_nonminimal_extended_length", test_nonminimal_extended_length),
        ("test_close_code_cannot_wrap", test_close_code_cannot_wrap),
        ("test_eof_before_handshake_closes_state", test_eof_before_handshake_closes_state),
        ("test_server_does_not_parse_handshake_twice", test_server_does_not_parse_handshake_twice),
        ("test_http_tokens", test_http_tokens),
        ("test_base64_rejects_excess_padding", test_base64_rejects_excess_padding),
        ("test_uri_query_and_ipv6", test_uri_query_and_ipv6),
        ("test_uri_rejects_invalid_authority", test_uri_rejects_invalid_authority),
        ("test_http_header_injection_rejected", test_http_header_injection_rejected),
        ("test_invalid_response_negotiation", test_invalid_response_negotiation),
        ("test_utf8_rejects_overlong_surrogate_and_out_of_range", test_utf8_rejects_overlong_surrogate_and_out_of_range),
        ("test_eof_is_idempotent", test_eof_is_idempotent),
        ("test_outgoing_message_limit", test_outgoing_message_limit),
        ("test_integer_pack_rejects_overflow", test_integer_pack_rejects_overflow),
        ("test_percent_encoded_credentials", test_percent_encoded_credentials),
        ("test_nonminimal_length_precedes_size_policy", test_nonminimal_length_precedes_size_policy),
        ("test_http_chunk_terminator_inside_payload", test_http_chunk_terminator_inside_payload),
        ("test_http_chunk_rejects_invalid_size_and_delimiter", test_http_chunk_rejects_invalid_size_and_delimiter),
    ]
    var args = argv()
    var selected = args[1] if len(args) > 1 else String("all")
    for test_case in cases:
        if selected == "all" or selected == test_case[0]:
            test_case[1]()
            print("ok", test_case[0])
