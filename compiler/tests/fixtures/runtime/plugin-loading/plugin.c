/* A plugin: two functions a program finds by name once it has loaded
   this file's shared object. */

int add(int a, int b) { return a + b; }

int apply(int (*callback)(int), int value) { return callback(value); }
