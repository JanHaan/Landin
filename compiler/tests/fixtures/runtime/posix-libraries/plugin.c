/* A shared object the fixture's harness builds and the Landin program
   loads: a function, a function that calls back into the program through
   a C function pointer it is given, and state that lives as long as the
   object stays loaded. */

int plugin_uses = 0;

int add(int a, int b) { return a + b; }

int apply(int (*callback)(int), int value) {
    plugin_uses += 1;
    return callback(value);
}
