# Landin C binding generator

`refine bindings` is the binding generator for the C boundary (D820). It asks
an external Clang for a JSON AST; it does not parse C header text, and no
compilation reads a header. Its supported ABIs are Linux x86-64 ELF System V
AMD64 LP64 and Darwin arm64 with Apple's AAPCS64 platform differences, both
with signed plain `char`, Linux arm64's standard AAPCS64 LP64, whose
plain `char` is unsigned (D256), and Cortex-M's freestanding AAPCS32 ILP32,
in its base procedure call standard and its VFP variant, also with an
unsigned plain `char` ([Cortex-M](#cortex-m), D935), all with ordinary
(non-short) C11 enums.
Each is one row of `Landin.Bindings`' targets, which says its refine target
name, Clang triple, fact, calling convention, data model, plain `char` and
identifying macros, and a policy's `data_model` and `plain_char` must be its
target's. Clang's answers
are checked for the explicit triple, architecture, object format macros, data
model, byte order, the sign of plain `char` and, on Cortex-M, the procedure
call standard. Generated code asserts the
selected `compiler.c_sysv_lp64`, `compiler.c_darwin_lp64`,
`compiler.c_aapcs64_lp64` or `compiler.c_aapcs32` fact. The exact Apple binding target is
`arm64-apple-macos26.0.0`; native tools and SDK are pinned in
`environments/macos-arm64/policy.json`. The Linux arm64 target is
`aarch64-unknown-linux-gnu`, and `compiler/tests/linux-arm64/bindings.py`
regenerates the committed fixture's header and policy for it and runs the
result natively. [Target contracts](../docs/targets.md) explains the separate
compiler and generator guards.

`D820` names a decision recorded in `spec.md`; `refine explain D820` prints
it.

The generator writes exactly four files:

- `bindings.ldn` contains `layout(c)` and `layout(c, packed)` records, exact
  enum integer aliases and
  constants, direct `extern(c)` declarations, and declarations for generated
  adapters;
- `adapters.c` contains C-owned union/bitfield storage, object/TLS accessors,
  nullable-callback cells, by-value wrappers, and incoming-varargs entries;
- `exports.h` includes the selected headers and declares every generated C
  adapter and incoming fixed Landin handler;
- `bindings.json` records the selected ABI, content hashes, policies,
  representations, adapter symbols, and output hashes without timestamps,
  AST addresses, or absolute host paths.

Generation checks the target facts, validates every selected declaration and
policy, and compiles `adapters.c` with the same Clang invocation before
replacing any destination file. The output directory itself must not be a
symbolic link, and no output may be a directory or a link. Replacement is
`refine svd`'s shared Platform transaction (D558, D907): each new file is
written in exclusive private staging beside its destination and read back,
and only then is each destination replaced, its old version kept until the
group succeeds. Headers, policy, consumed response files, selected Clang and
known transitive headers are protected inputs, through aliases too. The
output root, generated output names, traversed components below the chosen
root, and staging refuse links, including dangling links. A changed
destination is restored without replacing a newly occupied name, or
retained at the recovery path the diagnostic names. An earlier retained
transaction must be inspected; a new invocation does not discard it.
A file whose bytes are already the new ones is left alone. This is
failure recovery, not an atomic four-file snapshot for concurrent readers; do
not consume outputs during generation. Output names can briefly be absent.
When the output directory or its parents do not exist, their first absent
component is reserved before generation and the new tree is built privately.
Invalid policy or a failed tool creates none of those public directories.
A directory created by someone else during generation is preserved and the
command refuses publication. An existing output directory keeps unrelated
files alongside the four generated files.
Concurrent writes through another descriptor to the same inode are
unsupported. Dependency filenames establish Clang's known input closure;
this does not sandbox arbitrary wrapper or implicit toolchain reads.
Clang runs in a pinned private workspace. A dependency reported relative to
that workspace may use `..` within it, but may not escape it, even if the
path later reenters. Such a dependency is refused: use an absolute include
path or a declared `--include-dir` so its physical input can be protected.

## Invocation

```sh
refine bindings \
  --clang=/absolute/path/to/clang \
  --target=linux-x86-64 \
  --sysroot=/absolute/path/to/sysroot \
  --policy=/checkout/bindings-policy.json \
  --out-dir=/checkout/generated \
  --include-dir=/checkout/include \
  --system-include-dir="$(clang -print-resource-dir)/include" \
  --define=FEATURE_LEVEL=3 \
  api/public.h=/checkout/include/public.h \
  api/detail.h=/checkout/include/detail.h
```

`--clang`, `--policy` and `--out-dir` are required, and at least one header;
`--target` is refine's target name, `linux-x86-64`, `linux-arm64`,
`darwin-arm64` or `cortex-m0`, and defaults to the host's as for every
command. `--sysroot` is required for the three hosted targets and refused for
`cortex-m0`, which is freestanding (D937). The policy's `abi.target` must be
a Clang triple that name selects: `cortex-m0` has two (D935). `--clang`
names a Clang by path or by a name found on PATH. Each header is an operand,
either `LOGICAL=PATH` or `PATH`, in which case its last component is the
logical name. Logical names are the relocatable spellings emitted in
`exports.h`. They must be unique relative include paths. `--include-dir`,
`--system-include-dir` and `--define` repeat; relative paths are taken from
the working directory without resolving links. `refine bindings --help` says
the same.

The generator passes `-nostdinc`, and on `cortex-m0` `-ffreestanding` and the
row's float ABI. It sees only the named headers, explicit
`--include-dir`/`--system-include-dir` roots, and explicit `--define` values.
No development-host header directory is inherited: every Clang process runs
in an environment of its own, `PATH`, `HOME` and the temporary directory with
`LC_ALL=C` and `TZ=UTC` (D821), so no `CPATH`, `C_INCLUDE_PATH` or
driver-option override reaches it, and `--no-default-config` excludes default
driver configuration files. Clang works in a private directory under
`TMPDIR`, removed afterwards. File-prefix maps cover explicit
include/system/sysroot roots, so transitive `__FILE__` constants survive
relocation. Preprocessing outside those roots is refused; time-sensitive
macros are errors. A hosted target's sysroot is required
even for self-contained headers; an empty directory is valid when no target
system header is needed. Clang's resource include directory must be named
explicitly when a selected incoming-varargs adapter needs `<stdarg.h>`, and
on `cortex-m0` whenever a header includes one of Clang's freestanding
headers. On a hosted target, opaque-object and nullable-callback allocation
uses `calloc`/`free`, so the explicit include configuration must provide
`<stdlib.h>` when those adapters are generated.

Each error the generator reports has a code `refine explain` describes:
L0002 for a request written wrong, such as `--sysroot` missing for a hosted
target or given for `cortex-m0`; L0003 for a header or policy that cannot be
read; L0579 for a policy that is not one; L0580 for a Clang that cannot be
used as asked; L0581 for a selection that cannot be bound; L0582 for outputs
in the way; and L0005 for a replacement that fails.

Compile `adapters.c` with `-std=c11` and the preprocessor environment the
generation used: the same target, include directories and defines, and on a
hosted target the same sysroot; [Cortex-M](#cortex-m) gives the flags its
two rows add.
`exports.h` includes each header by its logical name, so when a logical name
is not the header's path below an include directory, copy each header to its
logical name in a tree of its own and put that tree first on the include
path. For the invocation above:

```sh
mkdir -p stage/api
cp /checkout/include/public.h stage/api/public.h
cp /checkout/include/detail.h stage/api/detail.h
clang -std=c11 --target=x86_64-pc-linux-gnu \
    --sysroot=/absolute/path/to/sysroot \
    -Istage -I/checkout/include \
    -isystem "$(clang -print-resource-dir)/include" \
    -DFEATURE_LEVEL=3 \
    -c /checkout/generated/adapters.c -o adapters.o
```

The ABI fixture harness additionally uses `-Wall -Wextra -Werror`; generated
adapters are validated with those warnings before publication.

`bindings.ldn` imports `platform/c`, whose aliases admit the explicitly supported
`compiler.c_sysv_lp64`, `compiler.c_darwin_lp64`, `compiler.c_aapcs64_lp64`
and `compiler.c_aapcs32` ABIs. Each generated binding
visibly asserts only its selected ABI fact; equal LP64 widths do not establish
calling-convention compatibility. A Cortex-M binding asserts its float unit on
the next line, `not compiler.feature.fp` for the base standard and
`compiler.feature.fp_dp` for the VFP variant, since one fact covers both
(D936). `landin/compiler` is implicit and is never imported.

## Policy

A policy is UTF-8 JSON. Duplicate keys at any depth, unknown keys, and missing
keys are errors. The top-level
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
  "declarations": [
    {"kind": "alias", "name": "size_type", "landin_name": "size_type"}
  ]
}
```

`abi` restates the row: `data_model` is `lp64`, or `ilp32` for `cortex-m0`
alone, and `plain_char` is the row's sign. `abi.calling_convention`, the name
`bindings.json` records, may be given on any target and must then be the
row's; `cortex-m0` requires it, `aapcs` with `thumbv6m-unknown-none-eabi` or
`aapcs-vfp` with `thumbv7em-unknown-none-eabihf`, so the policy says which
of its two conventions it binds for ([Cortex-M](#cortex-m)).

At least one declaration is required. This example assumes the selected header
defines a `size_type` typedef; replace it with a declaration in your header.

`namespace` prefixes generated C symbols. Generated declaration order is stable,
and every selected name must exist in Clang's AST. The metadata digest records
the policy's exact bytes, so rearranging otherwise equivalent JSON is still a
changed input. A declaration removed from a header produces a stale-policy
error; it is never silently skipped.

All entries accept `kind`, `name`, and an optional `landin_name`. The default
Landin name is a safe form of the C name: lowercased, and given `c_` before
it when it is a Landin keyword, a contextual word such as `text` or
`layout`, or one of the scalar names `u8` to `u64`, `i8` to `i64`, `usize`,
`isize`, `f32`, `f64` and `bool` (D1066), so `typedef unsigned char u8;`
becomes `c_u8` and the module's own `u8` stays Landin's. A `landin_name` may
not be one of those. Names that would collide in Landin
must be disambiguated explicitly. Policy `name` values made only of whitespace
and `@` are rejected, including when `landin_name` is explicit.

Within a generated Landin signature, parameter and result names avoid all
identifiers referenced by its types and all other bindings in the signature.
Available normalized parameter names remain unchanged; conflicts gain trailing
underscores, reserving existing suffix names first. Origin `from` clauses and
parameter metadata use these same allocated names. Policy names and `c_name`
remain the header's. This applies to direct declarations, adapters, callback
types and incoming handlers; it does not replace the explicit `landin_name`
required for conflicting selected declarations.

Opaque-object, callback-cell, variable and
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

`name` may be a typedef, `struct Tag`, or `union Tag`. A tag declared more
than once is the one record its definition gives, wherever the definition
stands among the declarations: `struct S { ... }; struct S;` is complete.
`representation` is
`auto`, `native`, or `opaque`. `fields` supplies reference policy by C field
name. `native` requires a complete nonempty ordinary struct containing only
supported native fields and positive fixed arrays. `auto` makes such a struct
a Landin `layout(c)` type and otherwise chooses C-owned opaque storage.
`opaque` always keeps a complete record on the C side.

Native records receive generated `_Static_assert`s for `sizeof`, `_Alignof`,
and every `offsetof`. Layout is counted in the target's bytes (D1067): a
record past 2 GiB is laid out where the target holds one, and a record or
array larger than the target's greatest object is refused by name.

A struct carrying its own `__attribute__((packed))` becomes a
`layout(c, packed)` record (D410): every field at alignment one, no padding.
Its native form needs what D410 asks of it, so an array or record it holds
by value must itself have alignment one (an array of one-byte scalars or of
packed records, or a nested packed record); otherwise `auto` keeps it
C-owned and opaque, whose accessors copy fields and never take a member's
address. `#pragma pack`, a member's own `packed` attribute and an `aligned`
attribute beside `packed` remain refused. A struct whose last field, after at
least one other, is C's flexible array member (`T name[]`, or GNU's
`T name[0]`) becomes a `layout(c)` or `layout(c, packed)` record whose last
field is `[0]T` (D413); the member takes its element's alignment, or one in
a packed record, so size and offsets are C's. Its elements are not part of
the value: such a record has no opaque form, is no array element and no
field of another record, and is refused wherever C would copy it by value.

C reaches both kinds, and a record holding either by value, only through a
pointer (D414). A pointer to a record the generator writes as a Landin
record, ordinary, packed or flexible-member, is typed `ptr` or `ptr mut` to
that record rather than as an opaque byte pointer (D426). That holds wherever
the pointer appears: a function's or callback type's parameters and result,
a global's value and address, a native record's field and an opaque record's
member accessors. A caller
passes `addr sample` and reads `result.val.gain` without a conversion. A
pointer to an opaque, incomplete or unselected record is `ptr u8`, since no
Landin record describes it.
An imported function taking or returning a packed record by value gets a
generated wrapper that takes `ptr record` for the argument and writes the
result through a `ptr mut record` first parameter, as opaque records do; a
global of such a record gets typed `address`, `read` and `write` adapters
that copy through pointers. Exports, callbacks and incoming-varargs handlers
cannot carry one by value, because Landin's `extern(c)` signature cannot,
and are refused. Unions and records containing bitfields never become
byte-array Landin surrogates. They receive explicit nullable allocation,
release, copy, size/alignment, and member accessor APIs. Named signed and
unsigned bitfields are read and written through the compiler's member access;
unnamed and zero-width fields remain in the real C layout and are recorded in
metadata. Setters touch only their named member, preserving neighbours.
On `cortex-m0` there is no `allocate` or `release`: the caller supplies an
object's storage by its `size` and `alignment` (D938).
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
When `nullable` is true, generated cells provide allocate/release,
size/alignment/initialize, and clear/set/present/access/invoke APIs. A caller
can request `size` bytes with `alignment` from its own allocator or fixed
buffer, then pass that storage to `initialize` before using the cell. An
allocation failure is handled by the caller before initialization. The caller
owns this storage and must keep it alive while C may use the cell; `release`
is only for cells returned by `allocate`. `initialize` resets a cell to empty
and can be called again on live storage. The cells store a function pointer in
its real C type and never cast code pointers to data pointers. `access` traps
if the cell is empty; `invoke` instead reports `false` and writes a result
through an explicit output pointer only when present.

A nullable callback position in a selected function must name a callback entry
with `nullable: true`. Its adapter accepts a cell and passes the cell's actual
possibly-null function pointer to C. Nullable callback results are written into
caller-provided cells. A cell's `allocate` and `release` are `calloc` and
`free`, so `cortex-m0` refuses a nullable callback (D938): select it with
`nullable: false` and give its positions nonnullable policy.

### Functions and exports

A function whose parameters and result are all scalars takes no reference
policy, but its entry still has a `parameters` object, empty, and no
`result` key. For `extern int increment(int value);`:

```json
{"kind": "function", "name": "increment", "direction": "import",
 "parameters": {}}
```

`bindings.ldn` then declares:

```landin
public extern(c) link(symbol: "increment") increment: (value: c.c_int) -> (result: c.c_int)
```

A parameter or result that holds a reference names its policy:

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
the header. A pointer to a pointer, `char **argv` or `void **out`, is `ptr`
to `ptr` with each level's own `const`. A pointer to an array, which is
what `int m[][3]` decays to, and a pointer to an unnamed function pointer
type are refused, each by its form, `unsupported pointer to an array` and
`unsupported pointer to an unnamed function pointer type`; name the
function pointer with a typedef.

An attribute a header writes on a selected function is refused, whatever
it is. An attribute Clang adds itself to a declaration of one of its
library builtins is not the header's (D1065): `strlen`, `malloc`, `abs`,
`sqrt`, `memcpy` and `printf` declared plainly are bound. A C library that
writes attributes on its declarations, as glibc's `__THROW` and
`__nonnull` do, is refused for those; bind such a function from a header of
your own that declares it without them. `setjmp` and `vfork` stay refused,
because Clang knows they return twice, and `exit` and `abort` because it
knows they do not return. `direction: import` emits a direct external declaration when the
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
address is never cached across threads; `cortex-m0` refuses a
`_Thread_local` object, which Arm code reaches through the C library's
`__aeabi_read_tp` (D938). Nullable callback variables also gain
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
unsafe, or stale policies. A type is refused for what its own words say,
read as whole identifiers: a record, enum or typedef whose name merely
contains `complex`, `volatile`, `va_list`, `vector_size` or `__int128` is
that declaration and is bound. It explicitly refuses selected extended/x87,
complex, vector, 128-bit, atomic/volatile, old-style, non-C-calling-convention,
attributed (other than a record's own `packed`), misplaced flexible or
zero-size, anonymous-aggregate, anonymous-unaliased, and unsupported array
forms, and a flexible member's record by value. It also refuses any wrapper that would require
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
- generated cell `allocate`/`release` use `calloc`/`free`; callers can instead
  use `size`/`alignment`/`initialize` with their own storage. Synchronization
  remains a caller integration concern. On freestanding `cortex-m0`, objects
  have no `allocate`/`release` and nullable callbacks and thread-local
  objects are refused;
- export entries verify native signatures and generate C declarations/metadata,
  but the Landin definition remains application source;
- policy records manual ownership and emits `escaping`/`from`; it cannot infer a
  library-specific release function or prove a C implementation honors its
  retention promise.

## Cortex-M

`--target=cortex-m0` binds C for AAPCS32 on an M-profile Thumb core. A
description's float unit changes the C convention (D615), so the one refine
target has two rows, and the policy says which it binds for (D935):

| `abi.calling_convention` | `abi.target` | Clang is also given | the binding asserts |
|---|---|---|---|
| `aapcs`, the base procedure call standard | `thumbv6m-unknown-none-eabi` | `-ffreestanding -mfloat-abi=soft` | `compiler.c_aapcs32` and `not compiler.feature.fp` |
| `aapcs-vfp`, its VFP variant | `thumbv7em-unknown-none-eabihf` | `-ffreestanding -mfpu=fpv5-d16 -mfloat-abi=hard` | `compiler.c_aapcs32` and `compiler.feature.fp_dp` |

Both are ILP32, `"data_model": "ilp32"`, with an unsigned plain `char`. A
base binding imported by a program built for a description with a float
unit, or a VFP one by a program without one, is refused when the program is
compiled (D936). Clang's macros are held to the row: `__ILP32__`, four-byte
`long`, pointer, `size_t` and `ptrdiff_t`, `__arm__`, `__thumb__`,
`__ARM_EABI__`, an `'M'` profile, `__ELF__`, `__ARM_PCS`, int-sized enums
(`__ARM_SIZEOF_MINIMAL_ENUM` 4), `__STDC_HOSTED__` 0, and `__ARM_PCS_VFP`
with `__ARM_FP` `0xe` exactly for the VFP variant. `long double` is refused,
as on every target.

The target is freestanding (D937): there is no system root and no C
library. Name Clang's own headers, `<stdint.h>`, `<stddef.h>`,
`<stdbool.h>`, `<stdarg.h>` and the rest of its resource directory, with
`--system-include-dir="$(clang-19 -print-resource-dir)/include"`; a host
library's header is not found. Adapters are freestanding too (D938):
by-value wrappers, wrappers of `static inline` functions, object and
union/bitfield accessors and incoming-varargs entries are generated; a
C-owned object has no `allocate` or `release`, so its storage is the
caller's, by its `size` and `alignment`; a nullable callback and a
`_Thread_local` object are refused with L0581, whose message says what to
select instead.

Compile `adapters.c` for the row, with `-fno-short-enums` whatever the
compiler: Clang as `--target=TRIPLE -ffreestanding` with the row's float
options, or the pinned `arm-eabi-gcc` as `-mcpu=cortex-m0 -mthumb
-mfloat-abi=soft` or `-mcpu=cortex-m7 -mthumb -mfpu=fpv5-d16
-mfloat-abi=hard`. That GCC's own default is short enums, which the
generated compatible-type assertions refuse.

### The CMSIS example

`devices/inputs.json` pins the CMSIS headers two committed bindings read
(D939): pico-sdk's `RP2040.h` and the CMSIS-Core it includes as
`rp2040-cmsis/`, and the CMSIS-Core 5.9 that the pinned `stm32h753xx.h`
includes as `stm32h753-cmsis/`. `scripts/fetch_inputs.py` fetches them by
hash. `compiler/tests/fixtures/abi/cortex-cmsis-bindings` binds
`RP2040.h`'s `IRQn_Type` and its static inline NVIC and SysTick functions
for the base standard. CMSIS's `NVIC_EnableIRQ` is a macro naming
`__NVIC_EnableIRQ`, and the generator binds no macro, so its policy selects
`__NVIC_EnableIRQ` and names it `nvic_enable_irq`. The headers' `volatile`
register structs are not selected and refuse nothing.
`compiler/tests/fixtures/abi/cortex-vfp-bindings` binds the STM32H753's
`IRQn_Type`, NVIC functions and `SCB_GetFPUType` for the VFP variant; no
CMSIS inline function takes a float or a double, so the floats and doubles
come from the fixture's own `landin-vfp.h`. Both are regenerated, with the
hosted fixture, by [one command](#regenerating-the-committed-fixtures).

`bindings/test.py` fetches only the inputs it reads. Each fixture's
`NOTICE` names the licences its generated files are derived under.

## Tests

```sh
CLANG=clang-19 python3 bindings/test.py --refine PATH
```

`--refine`, or `$LANDIN_REFINE`, names the compiler under test. The
`bindings` suite (`./scripts/dev-test.sh --suite=bindings`) covers what needs
only a fake Clang: the target rows, the refusal of another triple before any
header work, a whole binding with every Clang run in its own environment,
each refusal by its code, and a replacement that fails after each of its
moves and puts every output back.

The suite requires an external Clang, and the gate and the development shell
run different builds of Clang 19. The gate's `bindings` job installs Ubuntu
24.04's `clang-19` at the version `environments/pins.sh` pins as
`LANDIN_CLANG_UBUNTU`, 19.1.1, and runs the debug compiler the gate built.
The Linux Nix development shell's `clang-19` is LLVM 19 from the package set
`flake.lock` fixes, 19.1.7 at the time of writing, which nothing pins to the
gate's. The suite passes with both, and the gate's is the one a regenerated
fixture is answered for. Syntax-only adapter checks keep C warnings fatal
while allowing unused command-line options from the Nix Clang wrapper to
remain warnings. It uses an empty explicit Linux sysroot,
self-contained headers, and Clang's explicitly named resource headers. It
checks relocated byte-for-byte generation, path-free metadata, ABI guards,
precise refusal paths, and no replacement on failure. It compiles generated C
for `x86_64-pc-linux-gnu`, then compiles and executes the same adapters locally
to exercise union and signed/unsigned/zero-width bitfield access, by-value
wrappers (packed records' through typed pointers at an odd address), nullable callback cells, globals, real two-thread TLS isolation, and
a mixed register/stack-sized incoming-varargs schema. Regression inputs also pin
recursive retention and callback policy, unequal nested array extents, true enum
compatible types, declaration identity, reserved names, a tag declared again
after its definition, records past 2 GiB, the attributes Clang adds to its
builtins, type words read whole, typedefs named as Landin's scalars,
pointers to pointers, ambient-environment
exclusion, repeated anonymous-enum ordering, transitive path macros and a
dependency chain deep enough to need each record classified once.
The Cortex-M cases bind both conventions,
hold the macro check to an LP64 Clang and to the other convention's, refuse
an LP64 or unnamed-convention policy, show that only Clang's named
freestanding headers are reached and a host library's are not, refuse the
adapters that need a C library, keep adapter-backed signature names
consistent, compile the generated C for each row to objects whose Arm
attributes name the convention and int-sized enums, and regenerate both
CMSIS fixtures byte for byte, fetching their pinned inputs, and compile
both with `refine check` for `cortex-m0` without a float unit and with the
AN500 lane's FPv5-D16 description, each refused by the other. The case that
builds the adapters with the pinned `arm-eabi-gcc` runs where it is on
PATH, or `$ARM_EABI_GCC` names it, as in `nix develop`, and is skipped,
visibly, where it is not, as in the gate's `bindings` job; the Cortex-M lanes
build firmware C with it.
Output-origin regressions assert exact direct/adapter
signatures and unchanged policy metadata, then execute pointer-identity witnesses;
store regressions reject contradictory call-only policies for globals, TLS and
opaque members, including reference-bearing aggregates. Opaque-name regressions
execute lifecycle, accessor and by-value operations for each colliding typedef
and explicit module policy spelling. Local adapter execution is host-C evidence,
not execution of emitted Linux Landin instructions or compiler-level rejection
of frame-origin arguments.

### Regenerating the committed fixtures

Three fixtures hold generated files: `abi/r440-bindings-generated`,
`abi/cortex-cmsis-bindings` and `abi/cortex-vfp-bindings`. One command
regenerates all three from the repository root, with `CLANG` naming the
desired frontend (the gate's `bindings` job uses Ubuntu 24.04's `clang-19`
at the version `environments/pins.sh` names; `nix develop` provides a
`clang-19` that `bindings/test.py` runs with, as the gate does) and a
built refine:

```sh
CLANG=clang-19 python3 bindings/test.py --refine PATH --write
```

It generates each fixture into a temporary directory exactly as the cases
that compare them do, and then writes each of the four generated files
that differs, `bindings.ldn`, `adapters.c`, `exports.h` and
`bindings.json`, into its fixture, saying `wrote` or `unchanged` for each.
When `refine bindings` refuses one fixture, none is written. What each
fixture is generated from:

| fixture | target | headers | include directories |
|---|---|---|---|
| `r440-bindings-generated` | `linux-x86-64`, with an empty sysroot | its own `r440-bindings.h` | a declaration-only `stdlib.h` the command writes, and Clang's resource headers |
| `cortex-cmsis-bindings` | `cortex-m0` | the pinned `rp2040-cmsis/RP2040.h` | the pinned `rp2040-cmsis`, and Clang's resource headers |
| `cortex-vfp-bindings` | `cortex-m0` | the pinned `stm32h753/stm32h753xx.h` and its own `landin-vfp.h` | the pinned `stm32h753-cmsis`, and Clang's resource headers |

The pinned headers come from the input cache, `$LANDIN_INPUTS` or
`~/.cache/landin/inputs`, and one the cache lacks is fetched by its hash,
as `scripts/fetch_inputs.py` fetches it; with `--offline` the command
refuses instead. The cases take `--offline` too, without `--write`, and the
ones that read a pinned header then fail on one the cache lacks.

The small declaration-only `stdlib.h` supplies the same C ABI declarations used
by the test's empty-sysroot configuration; actual adapter linking uses libc.
Never edit the four generated outputs by hand. The suite regenerates all four
into a temporary directory and requires byte equality. The real
`abi/r440-bindings-generated` fixture additionally calls generated imports from
Landin and exported Landin definitions from C, including unequal matrix extents,
unnamed high-bit enum values, direct native reference results, an ordinary
record passed by `addr` and read and written through the typed pointers
generated imports return, a generated callback type given a Landin routine,
opaque borrowed output results, pointer-returning callback invocation
(present and absent), and a retaining global setter. Its packed and flexible-member records are
compared with the C peer's `sizeof`, `_Alignof` and `offsetof`; C fills a
packed record one byte past an aligned address and Landin reads it, Landin
writes it and C checks it, the by-value wrappers and a packed global carry
one, C calls an exported Landin handler with a packed record at an odd
address, and Landin reads and writes a flexible member through the buffer's
bytes at the member's offset. Its reference-output calls use a static C source and
assert retained pointer identity, not just successful return. Linux execution
remains a separate, mandatory compiler gate; the Python suite runs
`refine bindings` and no compilation, and establishes no frame-origin
negative diagnostics.

`check.py` remains standard-library-only and needs neither Clang nor refine
merely to run. An environment that elects to run generator tests must provision
Clang, a built refine and, for real system headers, the explicit target
sysroot/include roots. Generated files are ordinary build inputs;
package/root arrangement and invoking this command from a future build design
remain outside the compiler.


## Native Darwin validation

`compiler/tests/darwin/bindings.py --refine PATH --output NEW_DIRECTORY`
regenerates the shared binding corpus with that refine, Apple Clang and SDK
include roots,
then compiles and executes its Landin/C differential program. It covers all
supported adapter categories and retains the generated outputs and command
logs. Linux golden files are not replaced by Darwin output. The runner also
checks exact static-archive selection in the presence of a same-named dylib.

SDK 26.5 mixes annotated and unannotated pointers in `_stdlib.h`. For Darwin
adapter validation only, `-Wno-nullability-completeness` suppresses those SDK
annotation warnings exposed by `-Wsystem-headers`; explicit adapter ownership,
nullability and origin policy is still required. Other warnings remain errors.
This exception does not change GNAT's warning policy.
