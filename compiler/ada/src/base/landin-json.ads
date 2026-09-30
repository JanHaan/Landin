--  JSON, read and written, for a protocol and never for a program.
--
--  A language server reads what an editor sends, and an editor is not
--  trusted to send anything in particular, so the reader is strict and
--  bounded rather than forgiving.  It accepts exactly RFC 8259's grammar and
--  refuses everything else with an offset and a reason, and it never raises:
--  a message that is not JSON is data the server answers, not a defect.
--
--  What it bounds, and why each bound is what it is:
--
--  * Nesting is at most Maximum_Depth.  The protocol nests a handful of
--    levels; a reader that recursed as deep as a hostile document asked
--    would let one message exhaust the stack.
--  * A number is checked against the grammar and kept as its text.  One is
--    an integer only when it has no fraction or exponent and lies within
--    +/- (2**53 - 1), the integers every JSON reader agrees on; nothing here
--    ever converts a floating-point value, because nothing the protocol
--    sends needs one.
--  * A string is decoded to UTF-8.  Its escapes are the six single-letter
--    ones, '/', and \uXXXX, whose surrogates must pair; a raw control
--    character, invalid UTF-8, an overlong form or an encoded surrogate is
--    refused.
--  * An object may not name one key twice, because two readers disagree on
--    which one wins and the protocol never needs both.
--  * The input's own length is the caller's bound: the transport refuses a
--    message longer than it will read before this sees it.
--
--  A document is a flat table of values, freed with the document.  A value
--  is found by index, its members and elements by position or key, so
--  nothing a reader holds outlives the document it came from.
--
--  The writer is a builder that emits canonical JSON: no insignificant
--  space, members in the order they were written, and every string escaped
--  the way the reader decodes it.  Text that is not valid UTF-8 -- a
--  source's bytes quoted in a message -- has each invalid byte written as
--  U+FFFD, since JSON cannot carry it.  The two build and source-map writers
--  keep their own spelling: their bytes are pinned by the determinism
--  closures and nothing here is allowed to move them.

private with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Landin.Json is

   Maximum_Depth : constant := 64;

   type Value_Kind is
     (Null_Value, False_Value, True_Value, Number_Value, String_Value,
      Array_Value, Object_Value);

   type Document is limited private;

   type Value is private;

   No_Value : constant Value;

   --  Parse Text.  Ok says whether it was one JSON value with nothing but
   --  white space around it; when it was not, Fault_At and Fault say where
   --  and why, and the document holds nothing.
   procedure Parse (Into : in out Document; Text : String);

   function Ok (Of_Document : Document) return Boolean;

   function Fault (Of_Document : Document) return String;

   --  A zero-based byte offset into the text parsed.
   function Fault_At (Of_Document : Document) return Natural;

   function Root (Of_Document : Document) return Value
     with Pre => Ok (Of_Document);

   function Is_Present (Item : Value) return Boolean;

   function Kind (Of_Document : Document; Item : Value) return Value_Kind
     with Pre => Is_Present (Item);

   function Is_Kind
     (Of_Document : Document; Item : Value; Wanted : Value_Kind)
      return Boolean
     is (Is_Present (Item) and then Kind (Of_Document, Item) = Wanted);

   --  The decoded bytes of a string, or the written text of a number.
   function Text (Of_Document : Document; Item : Value) return String
     with Pre => Kind (Of_Document, Item) in Number_Value | String_Value;

   function Is_Integer (Of_Document : Document; Item : Value) return Boolean;

   Largest_Integer : constant := 2 ** 53 - 1;

   type Integer_Value is range -Largest_Integer .. Largest_Integer;

   function Integer_Of
     (Of_Document : Document; Item : Value) return Integer_Value
     with Pre => Is_Integer (Of_Document, Item);

   --  An array's elements or an object's members.
   function Length (Of_Document : Document; Item : Value) return Natural
     with Pre => Kind (Of_Document, Item) in Array_Value | Object_Value;

   function Element
     (Of_Document : Document; Item : Value; Position : Positive)
      return Value
     with Pre => Kind (Of_Document, Item) = Array_Value
                 and then Position <= Length (Of_Document, Item);

   function Key
     (Of_Document : Document; Item : Value; Position : Positive)
      return String
     with Pre => Kind (Of_Document, Item) = Object_Value
                 and then Position <= Length (Of_Document, Item);

   function Member_Value
     (Of_Document : Document; Item : Value; Position : Positive)
      return Value
     with Pre => Kind (Of_Document, Item) = Object_Value
                 and then Position <= Length (Of_Document, Item);

   --  The member named Name, or No_Value when Item is not an object or has
   --  no such member.  Anything may be asked, so a request of the wrong
   --  shape is answered by what is absent rather than by a precondition.
   function Member
     (Of_Document : Document; Item : Value; Name : String) return Value;

   ---------------------------------------------------------------------
   --  Writing
   ---------------------------------------------------------------------

   type Builder is limited private;

   procedure Begin_Object (Into : in out Builder);
   procedure End_Object (Into : in out Builder);
   procedure Begin_Array (Into : in out Builder);
   procedure End_Array (Into : in out Builder);

   --  A member's name; its value is whatever is written next.
   procedure Name (Into : in out Builder; Key : String);

   procedure Write_String (Into : in out Builder; Item : String);
   procedure Write_Integer (Into : in out Builder; Item : Long_Long_Integer);
   procedure Write_Boolean (Into : in out Builder; Item : Boolean);
   procedure Write_Null (Into : in out Builder);

   --  Text that is already one JSON value, copied as it is.  The caller
   --  vouches for it; a value read by Copy is the usual source.
   procedure Write_Raw (Into : in out Builder; Item : String);

   --  The value Item of a parsed document, written canonically.
   procedure Copy
     (Into : in out Builder; From : Document; Item : Value)
     with Pre => Is_Present (Item);

   function Result (Of_Builder : Builder) return String;

   --  Item as a JSON string literal, quotes included.
   function Quoted (Item : String) return String;

private

   type Value is new Natural;

   No_Value : constant Value := 0;

   type Node is record
      Kind       : Value_Kind := Null_Value;
      --  Strings: the decoded bytes; numbers: the written text; object
      --  members: the key, held on the member's own value node.
      First_Text : Natural := 0;
      Text_Last  : Natural := 0;
      Key_First  : Natural := 0;
      Key_Last   : Natural := 0;
      Whole      : Integer_Value := 0;
      Integral   : Boolean := False;
      --  Arrays and objects: their children are the Count values that
      --  follow First_Child in Children.
      First_Child : Natural := 0;
      Count      : Natural := 0;
   end record;

   package Node_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Node);

   package Index_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Positive);

   type Document is limited record
      Nodes     : Node_Vectors.Vector;
      Children  : Index_Vectors.Vector;
      Bytes     : Ada.Strings.Unbounded.Unbounded_String;
      Parsed    : Boolean := False;
      Reason    : Ada.Strings.Unbounded.Unbounded_String;
      Offset    : Natural := 0;
      Top       : Value := No_Value;
   end record;

   package Flag_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Boolean);

   type Builder is limited record
      Text  : Ada.Strings.Unbounded.Unbounded_String;
      --  One entry per open array or object: whether anything has been
      --  written inside it yet, so the next value knows to add a comma.
      Open  : Flag_Vectors.Vector;
      Named : Boolean := False;
   end record;

end Landin.Json;
