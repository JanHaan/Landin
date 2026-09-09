# Landin C binding generator

`generate.py` is the repository-owned, standard-library-only binding generator
for R4.40. It asks an external Clang for a JSON AST; it does not parse C header
text and it does not make `refine` a header parser. Its one supported ABI is
Linux x86-64 ELF System V AMD64 LP64 with signed plain `char` and ordinary
(non-short) C11 enums.

The generator writes exactly four files:

- `bindings.ldn` contains `layout(c)` records, exact enum integer aliases and
  constants, direct `extern(c)` declarations, and declarations for generated
  adapters;
- `adapters.c` contains C-owned union/bitfield storage, object/TLS accessors,
  nullable-callback cells, by-value wrappers, and incoming-varargs entries;
- `exports.h` includes the selected headers and declares every generated C
  adapter and incoming fixed Landin handler;
- `bindings.json` records the selected ABI, content hashes, policies,
  representations, adapter symbols, and output hashes without timestamps,
  AST addresses, or absolute host paths.

Generation stages all four files, checks the target facts, validates every
selected declaration and policy, and compiles `adapters.c` with the same Clang
invocation before replacing any destination file. Destination entries are
preflighted; a replacement failure rolls back the replaced prefix from backups.
If rollback itself fails, the error names the retained recovery backup rather
than claiming the old set was restored. This is failure recovery, not an atomic
four-file snapshot for concurrent readers; do not consume outputs during generation.

## Invocation

```sh
python3 bindings/generate.py \
  --clang /absolute/path/to/clang \
  --target x86_64-pc-linux-gnu \
  --sysroot /absolute/path/to/sysroot \
  --header api/public.h=/checkout/include/public.h \
  --header api/detail.h=/checkout/include/detail.h \
  --policy /checkout/bindings-policy.json \
  --out-dir /checkout/generated \
  --include-dir /checkout/include \
  --system-include-dir "$(clang -print-resource-dir)/include" \
  --define FEATURE_LEVEL=3
```

Every option shown through `--out-dir` is required; `--header` is repeatable.
A header argument is either `LOGICAL=PATH` or `PATH`, in which case its basename
is the logical name. Logical names are the relocatable spellings emitted in
`exports.h`. They must be unique relative include paths.

The generator passes `-nostdinc`. It sees only the named headers, explicit
`--include-dir`/`--system-include-dir` roots, and explicit `--define` values.
No development-host header directory is inherited: every Clang process receives
a controlled environment, excluding `CPATH`, `C_INCLUDE_PATH`, driver-option
overrides and default driver configuration files. File-prefix maps cover explicit
include/system/sysroot roots, so transitive `__FILE__` constants survive relocation.
Preprocessing outside those roots is refused; time-sensitive macros are errors.
The sysroot is required
even for self-contained headers; an empty directory is valid when no target
system header is needed. Clang's resource include directory must be named
explicitly when a selected incoming-varargs adapter needs `<stdarg.h>`.
Opaque-object and nullable-callback allocation uses `calloc`/`free`, so the
explicit include configuration must provide `<stdlib.h>` when those adapters
are generated.

Compile `adapters.c` with `-std=c11` and the same logical header mapping and
preprocessor environment. The ABI fixture harness additionally uses
`-Wall -Wextra -Werror`; generated adapters are validated with those warnings
before publication.

`bindings.ldn` imports `core/c`, whose aliases and
`compiler.assert(compiler.c_sysv_lp64)` guard are canonical. It also repeats
that assertion visibly. `landin/compiler` is implicit and is never imported.

## Policy

A policy is UTF-8 JSON. Unknown and missing keys are errors. The top-level
shape is:

```json
{
  "schema_version": 1,
  "namespace": "sample",
  "abi": {
    "target": "x86_64-pc-linux-gnu",
    "data_model": "lp64",
    "plain_char": "signed",
    "enum_policy": "clang-default"
  },
  "declarations": []
}
```

`namespace` prefixes generated C symbols. Generated declaration order is stable,
and every selected name must exist in Clang's AST. The metadata digest records
the policy's exact bytes, so rearranging otherwise equivalent JSON is still a
changed input. A declaration removed from a header produces a stale-policy
error; it is never silently skipped.

All entries accept `kind`, `name`, and an optional `landin_name`. The default
Landin name is a safe form of the C name. Names that would collide in Landin
must be disambiguated explicitly. Opaque-object, callback-cell, variable and
by-value-wrapper C locals and parameters are allocated independently of public
Landin names, avoiding every identifier in
the header AST (including nested typedefs and existing suffix variants) and
already allocated helper symbols. Thus typedefs named `object`, `value`,
`source`, or `target` remain usable in casts, accessors and by-value wrappers,
including with explicit namespace and `landin_name` choices. A conflicting
preprocessor macro can still cause generated-C validation to fail; no output
is replaced in that case.

### Reference policy

Every selected pointer or callback position, and every aggregate position
containing references recursively through aliases, records and fixed arrays,
requires all four annotations. An aggregate annotation describes the whole
value's origin/retention; it does not replace its reference-field annotations:

```json
{
  "ownership": "borrowed",
  "nullability": "nonnullable",
  "from": [],
  "retention": "call"
}
```

`ownership` is one of `borrowed`, `caller_owned`, `c_owned`, `static`, or
`transferred`; `nullability` is `nonnullable` or `nullable`; `retention` is
`call`, `returned`, `static`, or `stored`; and `from` is an ordered array of
header parameter names. Function and callback parameters, record fields,
variables, and incoming-tail policies require an empty `from`. A reference
result may name reference-bearing fixed parameters. Direct results (including
native record results and direct-result inline wrappers) retain that ordered
Landin `from` clause. Inputs retained as `stored`, `returned`, or `static`
become `escaping` Landin parameters. The complete policy is also retained in
`bindings.json` so ownership and release promises are not inferred from header
spelling.

Output-pointer adapters need a stricter interface: Landin cannot attach a
result's `from` clause to a store through an ordinary output parameter. When an
opaque-record result, nullable-callback result cell, or nullable callback's
`invoke` writes a reference result, each named `from` source becomes an
`escaping` input to that adapter. The direct callback callable type keeps its
original `from`; its `invoke` adapter is deliberately more restrictive. The
metadata keeps the original policy unchanged and records these additional
obligations in `adapter_output_escaping_sources`. This is derived from the
adapter's known output store, not a claim that the unknown foreign function
retains arguments internally. Unrelated call-only inputs remain nonescaping.

Likewise, opaque shallow copies require an escaping source object when the
copied value contains references; opaque member getters returning through an
output pointer require an escaping source object when the member contains
references. Direct reference-valued member getters instead return `from object`.
Global/TLS output reads have no caller-supplied source origin to preserve.
These restrictions are conservative: even a frame-resident aggregate containing
only static pointers cannot be passed to an escaping opaque copy/getter, and a
frame-local source cannot be used with an output adapter even when its output
will be consumed before the frame ends. Use a direct result interface where
available; the generator does not cast away the origin or claim to track
out-parameter contents precisely.

Generator-owned writable global/TLS accessors and opaque reference-member
setters reject `retention: call`: their bodies necessarily store the reference
past the call. Supply an explicit `stored`, `returned`, or `static` policy,
which produces an escaping setter input. This includes references nested in
aggregate values and arrays. Native record fields have no generated setters,
so their call-only policies are not rejected on that basis; a generated store
of the whole native value still needs a retaining whole-value policy. Read-only
variables and ordinary foreign call-only functions remain supported without
inventing retention facts about their implementations.

A scalar position must not carry reference policy. That catches policies left
behind after a header type changes.

### Records

```json
{
  "kind": "record",
  "name": "Pair",
  "landin_name": "pair",
  "representation": "auto",
  "fields": {}
}
```

`name` may be a typedef, `struct Tag`, or `union Tag`. `representation` is
`auto`, `native`, or `opaque`. `fields` supplies reference policy by C field
name. `native` requires a complete nonempty ordinary struct containing only
supported native fields and positive fixed arrays. `auto` makes such a struct
a Landin `layout(c)` type and otherwise chooses C-owned opaque storage.
`opaque` always keeps a complete record on the C side.

Native records receive generated `_Static_assert`s for `sizeof`, `_Alignof`,
and every `offsetof`. Unions and records containing bitfields never become
byte-array Landin surrogates. They receive explicit nullable allocation,
release, copy, size/alignment, and member accessor APIs. Named signed and
unsigned bitfields are read and written through the compiler's member access;
unnamed and zero-width fields remain in the real C layout and are recorded in
metadata. Setters touch only their named member, preserving neighbours.
By-value functions involving opaque records receive pointer-based C wrappers.
Incomplete records remain opaque pointer targets and do not receive an
invented size or allocator.

### Enums and aliases

```json
{"kind": "enum", "name": "Mode", "landin_name": "mode"}
{"kind": "alias", "name": "size_type", "landin_name": "size_type"}
```

A named enum may be selected by typedef or tag. An anonymous enum is selected
as `@FIRST_CONSTANT`. Clang's actual compatible integer type (queried using
`__builtin_types_compatible_p`, not an enumerator's expression type) becomes an
exact Landin C integer alias, preserving width, signedness and unnamed high-bit
values. Named enums also receive compatible-type static assertions. Every enumerator is emitted, including negative values,
repeated-value aliases, implicit values, and values from anonymous enums. Its
exact C spelling remains `c_name` in metadata; the Landin declaration is
normalized to the language's required lower-case identifier spelling.
Packed/short or attributed enums are refused rather than guessed.

Scalar, pointer, and fixed-array typedefs can be selected as aliases. Record,
enum, and function-pointer typedefs must instead use their matching `record`,
`enum`, or `callback` policy kind, which owns the needed representation policy.

### Callbacks

```json
{
  "kind": "callback",
  "name": "callback",
  "landin_name": "callback",
  "nullable": true,
  "parameters": {}
}
```

The name must be a prototyped C function-pointer typedef. `parameters` uses
`argument_1`, `argument_2`, and so on for reference annotations; a reference
result also needs `result` policy. Anonymous callbacks with inner reference
positions are refused with a request for an explicitly annotated named typedef;
nesting cannot bypass that policy. Both direct pointer-returning callbacks and
pointers to prototyped function typedefs are normalized structurally. The Landin
type is an `extern(c)` callable.
When `nullable` is true, generated C-owned cells provide allocate/release,
clear/set/present/access/invoke APIs. They store a function pointer in its real
C type and never cast code pointers to data pointers. `access` traps if the
cell is empty; `invoke` instead reports `false` and writes a result through an
explicit output pointer only when present.

A nullable callback position in a selected function must name a callback entry
with `nullable: true`. Its adapter accepts a cell and passes the cell's actual
possibly-null function pointer to C. Nullable callback results are written into
caller-provided cells.

### Functions and exports

```json
{
  "kind": "function",
  "name": "lookup",
  "landin_name": "lookup",
  "direction": "import",
  "parameters": {
    "context": {
      "ownership": "borrowed",
      "nullability": "nonnullable",
      "from": [],
      "retention": "call"
    }
  },
  "result": {
    "ownership": "borrowed",
    "nullability": "nullable",
    "from": ["context"],
    "retention": "returned"
  }
}
```

Signatures, parameter names, variadicness, and all type dependencies come from
the header. `direction: import` emits a direct external declaration when the
native C subset can carry it, and a generated wrapper for opaque by-value
records, nullable callbacks, or internal inline definitions. Direct variadic
imports remain variadic Landin declarations; a form that would need a wrapper
is refused with an explicit unsupported-`va_list`-forwarding error.

`direction: export` verifies and records a native-compatible, external, bodyless
header signature. A receiving variadic export must use `incoming_varargs`
instead. The selected header is included by `exports.h`; the Landin program
supplies the `public extern(c)` definition with that C symbol. The generator
does not invent a function body or import the exported function back into
Landin.

### Globals and thread-local objects

```json
{
  "kind": "variable",
  "name": "counter",
  "landin_name": "counter",
  "storage": "import",
  "writable": true
}
```

`storage` is `import` or `define`. `define` requires an `extern` header
declaration and emits a C-owned zero-initialized definition; a pointer/callback
definition must consequently be nullable. Selected object headers must contain
only external, uninitialized declarations. Const objects and objects selected
with `writable: false` expose read-only addresses; const objects cannot be
writable. Fixed array
objects are currently refused rather than copied through an untyped surrogate.
Generated address/read and, when allowed, write adapters name the real C type.
Opaque values are copied through C-owned storage. A `_Thread_local` definition
and every one of its accessors evaluate the TLS object on each call, so an
address is never cached across threads. Nullable callback variables also gain
clear/present operations and a checked read.

### Incoming varargs

```json
{
  "kind": "incoming_varargs",
  "name": "receive",
  "landin_name": "receive",
  "handler": "landin_receive_handler",
  "count_parameter": "count",
  "parameters": {},
  "schema": [
    {"name": "code", "promoted": "c_int"},
    {"name": "weight", "promoted": "c_double"}
  ]
}
```

`name` must be an existing variadic header declaration with at least one fixed
parameter. The fixed signature is derived from that declaration. `schema` is a
bounded, ordered extraction protocol, not a second copy of the declaration.
Its promoted tokens are `c_int`, `c_uint`, `c_long`, `c_ulong`, `c_longlong`,
`c_ulonglong`, `c_double`, and `pointer`. `pointer` means an actual `void *`
variadic argument; callers must cast typed or null pointer arguments to that
exact C type before the call because C does not promote pointer types. Pointer
entries additionally require a `policy` object. The generated real C entry
checks that `count_parameter`
equals the schema length, then performs `va_start`, one correctly typed
`va_arg` per entry, `va_end`, and a fixed call to `handler`. `exports.h`
declares that handler and `bindings.ldn` emits its fixed `extern(c)` function
type.

## Diagnostics and unsupported forms

The generator reports the selected declaration and position for missing,
unsafe, or stale policies. It explicitly refuses selected extended/x87,
complex, vector, 128-bit, atomic/volatile, old-style, non-C-calling-convention,
attributed, flexible/zero-size, anonymous-aggregate, anonymous-unaliased, and
unsupported array forms. It also refuses any wrapper that would require
forwarding an unknown C variadic tail. A Clang parse or generated-C validation
failure is a hard error and publishes nothing.

Current deliberate limits are visible rather than completion shortcuts:

- outgoing variadic calls use the compiler's current promoted scalar tail;
  aggregate tail descriptors are not generated yet;
- incoming schemas are fixed bounded promoted scalar/pointer protocols, not
  format-string interpretation or arbitrary `va_list` forwarding;
- nested arrays and nullable-callback arrays inside opaque record accessors are
  refused; incomplete records have pointer-only interoperation;
- nested nullable callbacks and nullable callback fixed parameters/results on
  incoming-varargs handlers are refused rather than represented as non-null
  Landin function values; callback signatures cannot carry C-owned opaque
  records by value, and callback object/opaque-member adapters require a named
  function-pointer typedef;
- selected array globals are refused; scalar, pointer, callback, enum, native
  record, and opaque record globals have adapters;
- generated C-owned cells use `calloc`/`free`; allocator substitution and
  synchronization are caller integration concerns;
- export entries verify native signatures and generate C declarations/metadata,
  but the Landin definition remains application source;
- policy records manual ownership and emits `escaping`/`from`; it cannot infer a
  library-specific release function or prove a C implementation honors its
  retention promise.

## Tests

```sh
python3 bindings/test.py
```

The suite requires an external Clang. It uses an empty explicit Linux sysroot,
self-contained headers, and Clang's explicitly named resource headers. It
checks relocated byte-for-byte generation, path-free metadata, ABI guards,
precise refusal paths, and no replacement on failure. It compiles generated C
for `x86_64-pc-linux-gnu`, then compiles and executes the same adapters locally
to exercise union and signed/unsigned/zero-width bitfield access, by-value
wrappers, nullable callback cells, globals, real two-thread TLS isolation, and
a mixed register/stack-sized incoming-varargs schema. Regression inputs also pin
recursive retention and callback policy, unequal nested array extents, true enum
compatible types, declaration identity, reserved names, ambient-environment
exclusion, multi-seed anonymous-enum ordering, transitive path macros and injected
publication failures. Output-origin regressions assert exact direct/adapter
signatures and unchanged policy metadata, then execute pointer-identity witnesses;
store regressions reject contradictory call-only policies for globals, TLS and
opaque members, including reference-bearing aggregates. Opaque-name regressions
execute lifecycle, accessor and by-value operations for each colliding typedef
and explicit module policy spelling. Local adapter execution is host-C evidence,
not execution of emitted Linux Landin instructions or compiler-level rejection
of frame-origin arguments.

### Regenerating the committed ABI fixture

From the repository root, with `CLANG` naming the desired frontend (the Linux
gate uses `clang-19`):

```sh
CLANG=${CLANG:-clang}
fixture=compiler/tests/fixtures/abi/r440-bindings-generated
work=$(mktemp -d)
mkdir "$work/sysroot" "$work/includes"
printf 'typedef __SIZE_TYPE__ size_t;\nvoid *calloc(size_t, size_t);\nvoid free(void *);\n' > "$work/includes/stdlib.h"
python3 bindings/generate.py \
  --clang "$CLANG" --target x86_64-pc-linux-gnu --sysroot "$work/sysroot" \
  --header "r440-bindings.h=$fixture/r440-bindings.h" \
  --policy "$fixture/policy.json" --out-dir "$fixture" \
  --system-include-dir "$work/includes" \
  --system-include-dir "$("$CLANG" -print-resource-dir)/include"
rm -r "$work"
```

The small declaration-only `stdlib.h` supplies the same C ABI declarations used
by the test's empty-sysroot configuration; actual adapter linking uses libc.
Never edit the four generated outputs by hand. The suite regenerates all four
into a temporary directory and requires byte equality. The real
`abi/r440-bindings-generated` fixture additionally calls generated imports from
Landin and exported Landin definitions from C, including unequal matrix extents,
unnamed high-bit enum values, direct native reference results, opaque borrowed
output results, pointer-returning callback invocation (present and absent), and
a retaining global setter. Its reference-output calls use a static C source and
assert retained pointer identity, not just successful return. Linux execution
remains a separate, mandatory compiler gate; the Python suite does not run
`refine` or establish frame-origin negative diagnostics.

`check.py` remains standard-library-only and does not need Clang merely to run.
An environment that elects to run generator tests must provision Clang and, for
real system headers, the explicit target sysroot/include roots. Generated files
are ordinary build inputs; package/root arrangement and invoking this tool from
a future build design remain outside `refine`.
