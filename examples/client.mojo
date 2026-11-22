"""Send a text message to the local echo server."""
from mojolt.websockets.sync.client import Client


def main() raises:
    with Client("ws://127.0.0.1:8765/echo") as connection:
        connection.send_text("Hello from Mojo")
        print(connection.recv_text())
    # Leaving the context sends Close and waits for a bounded reply.
