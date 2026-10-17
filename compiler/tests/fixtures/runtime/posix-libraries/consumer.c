/* Refers to a symbol it does not define, which the loader binds as the
   object is loaded: from provider.c's object when that was loaded with
   global symbols, and from nowhere otherwise. */

int provided_value(void);

int consume(void) { return provided_value() * 6; }
