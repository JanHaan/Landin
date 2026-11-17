"""A remote-protocol stub that stalls the way a loaded emulator does.

It answers the requests GDB 16 makes on `target remote` against an Arm
executable, but holds back both the acknowledgement and the reply of its
`vCont?` probe for STALL seconds, as an emulator does when its host does not
schedule it.  GDB's default `remotetimeout` gives up after three waits of two
seconds and reads the late reply as the answer to `vMustReplyEmpty`, its next
request, the failure loaded hosts met.  `Run.stalled_stub` holds the shared debugger
server to it.
"""
import contextlib
import socket
import threading
import time

#  GDB's default Arm register file without a target description: sixteen
#  core registers, eight FPA registers of twelve bytes, FPS and CPSR.
REGISTERS = b'00' * (16 * 4 + 8 * 12 + 4 + 4)


def serve(listener, stall):
    """Answer one connection on LISTENER in a thread of its own."""
    def answer(request):
        if request.startswith(b'qSupported'):
            return b'PacketSize=1000'
        if request == b'vCont?':
            return b'vCont;c;C;s;S'
        if request == b'?':
            return b'S05'
        if request.startswith((b'H', b'D')):
            return b'OK'
        if request.startswith(b'qAttached'):
            return b'1'
        if request == b'g':
            return REGISTERS
        if request.startswith(b'm'):
            return b'00' * int(request.split(b',')[1], 16)
        return b''

    def run():
        connection, _ = listener.accept()
        #  GDB under the default gives up on the session and may close the
        #  connection before the late reply is written.
        with connection, contextlib.suppress(OSError):
            connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            pending = b''
            while True:
                data = connection.recv(4096)
                if not data:
                    return
                pending += data
                while b'$' in pending and b'#' in pending[pending.index(b'$'):]:
                    start = pending.index(b'$')
                    end = pending.index(b'#', start)
                    if len(pending) < end + 3:
                        break
                    request, pending = pending[start + 1:end], pending[end + 3:]
                    if request == b'vCont?':
                        time.sleep(stall)
                    reply = answer(request)
                    connection.sendall(b'+$%s#%02x' % (reply, sum(reply) & 0xff))
                    if request.startswith(b'D'):
                        return

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread
