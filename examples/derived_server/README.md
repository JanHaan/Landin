# Derived server

The executable derivative of prototype 5's hosted half: a server that
answers one request per line, two kinds of them.

```text
WAIT 200 a      answered "a done" after 200 milliseconds
NOW b           answered "b done" at once
```

Any other line is answered `malformed`. Build and run it on a hosted
target with the pinned compiler:

```sh
./scripts/dev-build.sh
compiler/ada/build/nix-x86_64-linux/debug/bin/refine --root=. --emit=exe \
  examples/derived_server -o compiler/ada/build/derived-server
compiler/ada/build/derived-server --io=blocking --port=7070
```

The build directory is named for the host's build tag, `linux-amd64` in
the container and `nix-x86_64-linux` under `nix develop`. The server
listens on 127.0.0.1, at the port `--port` gives, 7070 when it is not
given and one the system picks for 0, and its first line of output says
where: `listening on 127.0.0.1:7070`.

`--io=` chooses the provider the server runs over, and `app/app.ldn`'s two
minting routines are the only code that knows which one it got. Over
`--io=blocking`, the default, each connection is served to its end before
the next is accepted, so a `NOW` sent after a `WAIT` on another connection
is answered after it, and SIGTERM ends the process by its default
disposition. Over `--io=events`, the provider whose waits switch fibres,
two connections are served at once, so `NOW b` is answered while `a`
waits, and a fibre that waits for SIGTERM stops the server cleanly and
prints `stopped after N requests`.

`app/protocol` reads and answers one request and knows nothing of sockets
or fibres, so the firmware counterpart can share it. `app/session` serves
one connection; `app/server` serves a listener, stops on SIGTERM, and has
the prototype's client, `ask_both`, which needs a provider that takes
turns.

The source-to-prototype mapping, the departures from the sketch and what
each fixture checks are in
[DERIVATION.md](../../compiler/tests/fixtures/runtime/derived-server-two-process/DERIVATION.md).
