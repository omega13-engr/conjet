"""Unimplemented conformance contracts; replace each failure with its real fixture."""
import unittest


class CompatibilityTests(unittest.TestCase):
    def test_attach_reconnect(self):
        'DC-015: StdinOnce false survives attach disconnect and reconnect without premature EOF.'
        self.fail('UNIMPLEMENTED DC-015; no runtime compatibility evidence')

    def test_tty_resize(self):
        'DC-016: TTY allocation and resize update guest dimensions; non-TTY stdout and stderr remain separate.'
        self.fail('UNIMPLEMENTED DC-016; no runtime compatibility evidence')

    def test_detach_keys(self):
        'DC-017: Detach sequence split across reads detaches without dropping ordinary input or stopping container.'
        self.fail('UNIMPLEMENTED DC-017; no runtime compatibility evidence')

    def test_websocket_attach(self):
        'DC-018: WebSocket masking, ping, close, backpressure and disconnect have bounded memory and correct stream behavior.'
        self.fail('UNIMPLEMENTED DC-018; no runtime compatibility evidence')
