--  Immutable source snapshots, byte offsets, spans and line maps.
--
--  Offsets are byte offsets, not character positions: the lexer is
--  byte-oriented and every later stage, including debug information, must
--  be able to point at the same byte.  A snapshot never changes after it
--  is created, so a span taken today still means the same bytes later in
--  the same compilation.
--
--  The text and the line map live on the heap.  A source file is not a
--  stack-sized thing: holding a megabyte of it in an automatic object is
--  how a compiler dies on a generated file instead of compiling it.

private with Ada.Strings.Unbounded;

package Landin.Source is

   --  A zero-based byte offset into a snapshot's text.  An offset equal to
   --  the length is the valid one-past-the-end position.
   type Byte_Offset is range 0 .. Integer'Last;

   type Line_Number   is range 1 .. Integer'Last;
   type Column_Number is range 1 .. Integer'Last;

   --  Stable identity of a snapshot inside one compilation.  No_Source is
   --  used by diagnostics that do not belong to any file.
   type Source_Id is range 0 .. Integer'Last;
   No_Source : constant Source_Id := 0;

   --  A half-open byte range [First, Last).  First = Last is a valid empty
   --  span and is how a diagnostic points between two bytes.
   type Span is record
      First : Byte_Offset := 0;
      Last  : Byte_Offset := 0;
   end record
     with Dynamic_Predicate => Span.First <= Span.Last;

   Empty_Span : constant Span := (First => 0, Last => 0);

   function Length (Item : Span) return Byte_Offset
     is (Item.Last - Item.First);

   function Contains (Outer, Inner : Span) return Boolean
     is (Inner.First >= Outer.First and then Inner.Last <= Outer.Last);

   --  A resolved human-facing position.  Column is a byte column so that it
   --  agrees with the offset it came from; presentation may widen it later,
   --  but the compiler never guesses an encoding here.
   type Position is record
      Line   : Line_Number   := 1;
      Column : Column_Number := 1;
   end record;

   --  An immutable snapshot.  A default-initialised one is empty and
   --  carries No_Source, so a Snapshot component can never be a dangling
   --  half-built thing.
   type Snapshot is private;

   function Create
     (Id : Source_Id; Name : String; Text : String) return Snapshot
     with Pre => Id /= No_Source;

   function Id     (Item : Snapshot) return Source_Id;
   function Name   (Item : Snapshot) return String;
   function Text   (Item : Snapshot) return String;
   function Length (Item : Snapshot) return Byte_Offset;

   function Full_Span (Item : Snapshot) return Span;

   function Is_Valid (Item : Snapshot; Offset : Byte_Offset) return Boolean
     is (Offset <= Length (Item));

   function Is_Valid (Item : Snapshot; Where : Span) return Boolean
     is (Where.Last <= Length (Item));

   function Slice (Item : Snapshot; Where : Span) return String
     with Pre => Is_Valid (Item, Where);

   function Line_Count (Item : Snapshot) return Line_Number;

   --  Line and column of a byte offset.  A one-past-the-end offset resolves
   --  to the position just after the last byte, which is what a diagnostic
   --  about a missing token needs.  An offset beyond that is a defect in
   --  the caller rather than a position, and raises Compiler_Defect in
   --  every build mode: a rule that only holds when assertions are on is
   --  not a rule the package keeps.
   --  Is_Valid answers the question; there is deliberately no precondition
   --  here.  A Pre is checked only when assertions are on, and then it is
   --  the assertion that raises rather than this package, which is exactly
   --  the mode-dependence the comment above rules out.
   function Position_Of
     (Item : Snapshot; Offset : Byte_Offset) return Position;

   function Line_Span (Item : Snapshot; Line : Line_Number) return Span
     with Pre => Line <= Line_Count (Item);

   --  The line's bytes without its terminator, so a caret line can be drawn
   --  under it without re-scanning for CR or LF.
   function Line_Text (Item : Snapshot; Line : Line_Number) return String
     with Pre => Line <= Line_Count (Item);

private

   package ASU renames Ada.Strings.Unbounded;

   type Offset_Array is array (Line_Number range <>) of Byte_Offset;

   type Text_Access     is access constant String;
   type Offsets_Access  is access constant Offset_Array;

   --  Named so the line map can be filled once, before it is handed over
   --  as the constant view the rest of the compiler sees.
   type Mutable_Offsets is access Offset_Array;

   Empty_Text : aliased constant String := "";
   Empty_Map  : aliased constant Offset_Array := [Line_Number'(1) => 0];

   --  Both designated objects are constant, so copying a Snapshot shares
   --  bytes that nobody can change.  A compilation owns its snapshots for
   --  its whole life and the process is short, so nothing here is freed;
   --  that is a decision, recorded in compiler/ada/README.md, not an
   --  oversight.
   type Snapshot is record
      Id          : Source_Id      := No_Source;
      Name        : ASU.Unbounded_String;
      Bytes       : Text_Access    := Empty_Text'Access;
      Line_Starts : Offsets_Access := Empty_Map'Access;
   end record;

end Landin.Source;
