--  The language's types.
--
--  `spec.md` [1790] is the authority: the kernel's types are the eleven
--  scalar names and nothing else.  This package is that rule made
--  addressable, and it is meant to be the only place in the compiler where
--  the eleven are written down, which is what lets `check.py` keep
--  comparing the column below with the tour's own `type` rule.
--
--  It is the mirror of Landin.Targets, and it is the sentence that
--  package's header asks for.  Landin.Targets holds machine facts and says
--  there is deliberately no list of Landin's scalar types there, because
--  "which types exist, and how each one maps onto a machine width, is the
--  specification's business and arrives with the frontend".  This is that
--  list and that mapping.  Nothing here holds a machine fact of its own: a
--  width is a function of a type *and* a description, because usize and
--  isize are [0160]'s pointer-width integers, and a 32-bit description has
--  to stay 32-bit on a 64-bit host.
--
--  One flat enumeration and no variant record, which is the shape
--  Landin.Syntax.Node_Kind already argued for: a variant would make the
--  element type of a side table indefinite, and a case over a contiguous
--  band is exhaustive, so a type this package forgets is a compile error
--  under -gnatwe rather than a fall-through.
--
--  The first five values are not one of the eleven, and each is a value
--  rather than an absence for the reason Landin.Resolution.Verdict gives:
--  one number meaning both "no type here" and "no type yet" is how a
--  missing type becomes a cascade.
--
--    Undecided        the pass has not reached this node yet.  It is the
--                     enumeration's first value so that it is also the
--                     default of any array of these.
--    Not_Typed        a node that is not a thing with a type: a block, a
--                     statement, the program itself.
--    Ill_Typed        a node this pass refused, or one standing under a
--                     hole, so that a parent declines to complain twice.
--    No_Value         what a call to a `-> none` function hands back
--                     [1800].  Not Not_Typed: the call *is* an expression
--                     and it is the message that differs.
--    Untyped_Integer  an integer literal, or a run of operators over
--                     nothing else, that no context has fixed yet [0190].
--
--  Nothing here reads a tree, a token or a snapshot.  What type each node
--  has is Landin.Checking's, for the same reason a Declaration_Id lives in
--  Landin.Provenance and what it means lives in Landin.Resolution.

with Landin.Targets;
with Landin.Tokens;

package Landin.Types is

   use type Landin.Targets.Bit_Width;

   ------------------------------------------------------------------
   --  What a type is
   ------------------------------------------------------------------

   type Type_Kind is
     (Undecided,
      Not_Typed,
      Ill_Typed,
      No_Value,
      Untyped_Integer,
      --  [1790]'s eleven, in the order the grammar writes them, so that a
      --  reader can check the column against spec.md by running down it.
      U8, U16, U32, U64,
      I8, I16, I32, I64,
      Usize, Isize,
      Bool,
      --  A type a program declared a body for [1795], laid out by
      --  [0750].  Which one is not here: this package holds what a type
      --  *is* and an aggregate's identity is which declaration wrote it,
      --  which is Landin.Checking's to keep for the same reason what
      --  every node has is.  Two aggregates are one type when they came
      --  from one declaration and never otherwise [0710].
      Aggregate,
      --  [0520]'s array, whose length is part of it.  Which one is not
      --  here either, and for the opposite reason: D17 makes an array
      --  structural, so its identity is a length and an element type and
      --  those are two more facts than a Type_Kind holds.
      Fixed_Array,
      --  [0870]/[1000]: a runtime code address.  D113 first carries the
      --  signature declaration separately in Landin.Checking, as aggregate
      --  nominal identity is carried separately above.
      Function_Value);

   subtype Scalar_Name is Type_Kind range U8 .. Bool;

   --  The ten that hold a number.  bool is last in [1790]'s own order,
   --  which is what makes this band contiguous without reordering it.
   subtype Integer_Name is Type_Kind range U8 .. Isize;

   --  A type a value can actually have, which is what an expression node
   --  must end the pass with when its subtree is sound.
   subtype Settled is Type_Kind range Untyped_Integer .. Function_Value;

   function Spelling (Item : Scalar_Name) return String
     is (case Item is
            when U8    => "u8",
            when U16   => "u16",
            when U32   => "u32",
            when U64   => "u64",
            when I8    => "i8",
            when I16   => "i16",
            when I32   => "i32",
            when I64   => "i64",
            when Usize => "usize",
            when Isize => "isize",
            when Bool  => "bool");

   --  [0200]: with no context, an integer literal defaults to i32.  Named
   --  rather than written at each site, because it is one decision of the
   --  tour's and a checker applies it in five places.
   Default_Integer : constant Scalar_Name := I32;

   function Is_Signed (Item : Integer_Name) return Boolean
     is (Item in I8 | I16 | I32 | I64 | Isize);

   ------------------------------------------------------------------
   --  How wide one is
   ------------------------------------------------------------------

   --  A width is not a property of a type alone.  usize and isize are
   --  [0160]'s pointer-width integers, so they are as wide as a
   --  *description* says and no wider, and there is exactly one place a
   --  description can come from: Landin.Targets, whose Target_Facts is
   --  private and has no defaults for this reason.  Asking the host is not
   --  available here and must not become available.
   --
   --  bool is absent on purpose.  [0150] says a one-bit field is spelt
   --  bool and that outside a packed struct one occupies the next machine
   --  width, which makes bool's storage a layout question and layout is
   --  R2.10's.  Its value domain is the two literals and needs no width.
   function Width
     (Item : Integer_Name; Facts : Landin.Targets.Target_Facts)
     return Landin.Targets.Bit_Width
     is (case Item is
            when U8 | I8       => 8,
            when U16 | I16     => 16,
            when U32 | I32     => 32,
            when U64 | I64     => 64,
            when Usize | Isize => Landin.Targets.Pointer_Width (Facts));

   --  How much ordinary, unpacked storage one scalar needs.  This is shared
   --  by frame and aggregate layout: [0150]'s bool occupies the next machine
   --  width above one bit, a byte, while every integer follows Width above.
   function Storage_Size
     (Item  : Scalar_Name;
      Facts : Landin.Targets.Target_Facts) return Landin.Targets.Scalar_Size;

   ------------------------------------------------------------------
   --  What a literal says
   ------------------------------------------------------------------

   --  The magnitude of an integer literal.  Every literal the grammar
   --  spells is non-negative -- `integer ::= decimal | hex | octal |
   --  binary` [1770], and `-` is a unary operator [1820] and not part of
   --  the literal -- so the widest value that ever has to be held is the
   --  largest an enabled type can hold, which is u64's.
   --
   --  The bound is written out for exactly the reason
   --  Landin.Targets.Byte_Count's is: it comes from the language and not
   --  from the machine running the compiler, so a host that cannot
   --  represent it fails to build instead of silently truncating.  This is
   --  not a host width leaking in.  A host width leaking in would be
   --  Long_Long_Integer, whose range is a fact about this machine; 2**64-1
   --  is a fact about u64.
   type Magnitude is range 0 .. 2 ** 64 - 1;

   --  A count of significant bits.  Not Natural, for Byte_Count's reason
   --  again, and bounded by the widest type the kernel has.  Landin.Targets
   --  lets a Bit_Width reach 1024, so a target whose pointer is wider than
   --  this is a description this package cannot answer for -- and it says
   --  so by contract rather than by wrapping.
   type Bit_Count is range 0 .. 64;

   Widest : constant Bit_Count := 64;

   --  Can a literal of this magnitude be a value of this type?  Negated
   --  says the unary minus of [1820] stands over it, because -128 is an i8
   --  and 128 is not, and because a negative literal is no unsigned type's
   --  value at all.
   --
   --  This is [0190]'s "checked at that point" and [0310]'s "if the value
   --  is known at compile time, an impossible conversion is a compile
   --  error", for the one case the kernel can meet: a literal written into
   --  a place whose type is declared.
   function Fits
     (Value   : Magnitude;
      Item    : Integer_Name;
      Facts   : Landin.Targets.Target_Facts;
      Negated : Boolean) return Boolean
     with Pre => Width (Item, Facts) <= Landin.Targets.Bit_Width (Widest);

   --  A value a module-level fold can hold, signed and symmetric about
   --  zero at the width of the widest enabled type.  [1940] needs it and
   --  Magnitude cannot serve: `x: i32 = 1 - 2` is negative, and Magnitude
   --  is unsigned because a *literal* never is.
   --
   --  The bound is written out for Magnitude's reason.  It comes from u64,
   --  the widest type the kernel enables, and from the negation of it, so
   --  a host that cannot represent it fails to build rather than silently
   --  truncating.  A host width leaking in would be Long_Long_Integer.
   type Folded is range -(2 ** 64 - 1) .. 2 ** 64 - 1;

   --  A run of Folded values, in source order.  Used to carry an array
   --  datum's initial image, D24's per-position fold, between the checker
   --  and the backend without either learning what a target width is.
   type Folded_Array is array (Positive range <>) of Folded;

   --  Whether a folded value is one of that type's, which is [1940]'s
   --  refusal made answerable.  Separate from Fits because a fold has a
   --  sign of its own rather than a unary minus standing over it.
   function Holds
     (Value : Folded;
      Item  : Integer_Name;
      Facts : Landin.Targets.Target_Facts) return Boolean
     with Pre => Width (Item, Facts)
                 <= Landin.Targets.Bit_Width (Widest);

   --  The value of an integer literal's digits [1770], separators and all
   --  [0220].  Overflowed is an answer and not an exception because it is
   --  foreseeable: 18446744073709551616 is something a program can be
   --  written with, and no enabled type holds it.
   --
   --  Every byte must be `_` or a digit of Base.  The scan already
   --  guarantees that -- a digit outside its base is L0011 -- so a byte
   --  that is neither is a compiler defect and is raised as one.
   procedure Evaluate
     (Text       : String;
      Base       : Landin.Tokens.Integer_Base;
      Value      : out Magnitude;
      Overflowed : out Boolean);

end Landin.Types;
