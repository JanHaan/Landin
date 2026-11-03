--  The spellings a binding is written in: Landin and C identifiers made
--  from C names, the quoting every message uses, decimal integers wider
--  than a machine word, and the metadata's JSON, written as the outputs
--  have always been written: two-space indentation, members sorted by
--  name, and text that is not ASCII written as it is.

private package Landin.Bindings.Texts is

   --  A safe Landin identifier for a C name: lower case, every character
   --  other than a letter, digit or underscore an underscore, and `c_`
   --  before one that would not begin with a letter or would be a word
   --  Landin reserves or reads in context.
   function Sanitize_Landin (Name : String) return String;

   function Is_Landin_Identifier (Text : String) return Boolean;

   --  The keyword production of spec.md and the contextual words beside
   --  it.
   function Is_Avoided (Name : String) return Boolean;

   --  A part of a generated C symbol: every character other than an ASCII
   --  letter, digit or underscore an underscore.
   function Symbol_Part (Part : String) return String;

   function Image (Value : Long_Long_Integer) return String;

   function Upper (Text : String) return String;

   function Starts_With (Text, Prefix : String) return Boolean;

   function Ends_With (Text, Suffix : String) return Boolean;

   function Contains (Text, Part : String) return Boolean;

   --  White space as Python's str.split reads it, in ASCII.
   function Is_Space (Item : Character) return Boolean;

   function Strip (Text : String) return String;

   --  The words of Text, split at runs of white space.
   function Words (Text : String) return String_Vectors.Vector;

   --  Text's words joined by single spaces.
   function Collapse (Text : String) return String;

   function Join
     (Items : String_Vectors.Vector; Separator : String) return String;

   function Is_Digits (Text : String) return Boolean;

   --  A decimal integer of any width, as Clang writes an enumerator's
   --  value: Canonical reads one, Successor adds one.
   function Is_Decimal (Text : String) return Boolean;
   function Canonical (Text : String) return String
     with Pre => Is_Decimal (Text);
   function Successor (Text : String) return String
     with Pre => Is_Decimal (Text);

   --  Python's repr of a string, which is how every message quotes one.
   function Repr (Text : String) return String;

   --  A parsed JSON value as Python's repr would print it.
   function Value_Repr (From : J.Document; Item : J.Value) return String;

   ---------------------------------------------------------------------
   --  The metadata tree
   ---------------------------------------------------------------------

   function Null_Meta (Within : Handle) return Meta_Id;
   function Boolean_Meta
     (Within : Handle; Item : Boolean) return Meta_Id;
   function Number_Meta
     (Within : Handle; Text : String) return Meta_Id;
   function Integer_Meta
     (Within : Handle; Item : Long_Long_Integer) return Meta_Id;
   function String_Meta
     (Within : Handle; Text : String) return Meta_Id;
   function List_Meta (Within : Handle) return Meta_Id;
   function Object_Meta (Within : Handle) return Meta_Id;
   function Strings_Meta
     (Within : Handle; Items : String_Vectors.Vector)
      return Meta_Id;

   procedure Append
     (Within : Handle; List : Meta_Id; Item : Meta_Id);

   procedure Put
     (Within : Handle; Object : Meta_Id; Key : String;
      Item : Meta_Id);

   --  The member named Key of Object, which must have one.
   function Member
     (Within : Handle; Object : Meta_Id; Key : String) return Meta_Id;

   function Text_Of (Within : Handle; Item : Meta_Id) return String;

   function Kind_Of (Within : Handle; Item : Meta_Id) return Meta_Kind;

   --  Item as JSON with two-space indentation and sorted members, and a
   --  final line end.
   function Pretty (Within : Handle; Item : Meta_Id) return String;

end Landin.Bindings.Texts;
