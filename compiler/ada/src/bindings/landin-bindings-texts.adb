with Ada.Strings.Fixed;
with Landin.Tokens;
with Landin.Types;

package body Landin.Bindings.Texts is

   use type US.Unbounded_String;

   --  Contextual syntax and builtin names, poor generated identifiers too.
   Contextual : constant String_Vectors.Vector :=
     ["as", "assembler", "bool",
      "caller", "compiler",
      "concept", "consume",
      "layout", "link", "linker",
      "packed", "range", "symbol",
      "text", "variant"];

   function Listed (Name : String; Words : String_Vectors.Vector)
     return Boolean is (Words.Contains (Name));

   --  The keyword production of spec.md's [1760] is Landin.Tokens'
   --  reserved words, which check.py holds to it.  The scalar names of
   --  [1790] are Landin.Types': they are not keywords, so a module that
   --  declared one would take it from every later line of the module, and
   --  the generated declarations write `u8` and `usize` meaning Landin's.
   function Is_Avoided (Name : String) return Boolean is
     ((for some Word in Landin.Tokens.Reserved_Word =>
         Landin.Tokens.Spelling (Word) = Name)
      or else (for some Scalar in Landin.Types.Scalar_Name =>
                 Landin.Types.Spelling (Scalar) = Name)
      or else Listed (Name, Contextual));

   --  The length of the UTF-8 sequence Text (Index) begins, one for a
   --  byte that begins none.
   function Sequence_Length (Text : String; Index : Positive) return Positive;

   function Sequence_Length (Text : String; Index : Positive) return Positive
   is
      Lead : constant Natural := Character'Pos (Text (Index));
      Length : constant Positive :=
        (if Lead < 16#C0# then 1 elsif Lead < 16#E0# then 2
         elsif Lead < 16#F0# then 3 else 4);
   begin
      if Index + Length - 1 > Text'Last then
         return 1;
      end if;
      for Next in Index + 1 .. Index + Length - 1 loop
         if Character'Pos (Text (Next)) not in 16#80# .. 16#BF# then
            return 1;
         end if;
      end loop;
      return Length;
   end Sequence_Length;

   function Sanitize_Landin (Name : String) return String is
      Result : US.Unbounded_String;
      Index : Natural := Name'First;
   begin
      while Index <= Name'Last loop
         declare
            Item : constant Character := Name (Index);
         begin
            if Item in 'A' .. 'Z' then
               US.Append
                 (Result,
                  Character'Val (Character'Pos (Item) + 32));
               Index := Index + 1;
            elsif Item in 'a' .. 'z' | '0' .. '9' | '_' then
               US.Append (Result, Item);
               Index := Index + 1;
            else
               US.Append (Result, '_');
               Index := Index + Sequence_Length (Name, Index);
            end if;
         end;
      end loop;
      declare
         Candidate : US.Unbounded_String := Result;
      begin
         if US.Length (Candidate) = 0
           or else US.Element (Candidate, 1) not in 'a' .. 'z'
         then
            Candidate := "c_" & Candidate;
         end if;
         if US.To_String (Candidate) = "_"
           or else Is_Avoided (US.To_String (Candidate))
         then
            Candidate := "c_" & Candidate;
         end if;
         return US.To_String (Candidate);
      end;
   end Sanitize_Landin;

   function Is_Landin_Identifier (Text : String) return Boolean is
     (Text'Length > 0 and then Text (Text'First) in 'a' .. 'z'
      and then (for all Item of Text =>
                  Item in 'a' .. 'z' | '0' .. '9' | '_'));

   function Symbol_Part (Part : String) return String is
      Result : US.Unbounded_String;
      Index : Natural := Part'First;
   begin
      while Index <= Part'Last loop
         if Part (Index) in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' then
            US.Append (Result, Part (Index));
            Index := Index + 1;
         else
            US.Append (Result, '_');
            Index := Index + Sequence_Length (Part, Index);
         end if;
      end loop;
      return US.To_String (Result);
   end Symbol_Part;

   function Image (Value : Long_Long_Integer) return String is
      Text : constant String := Long_Long_Integer'Image (Value);
   begin
      return (if Text (Text'First) = ' '
              then Text (Text'First + 1 .. Text'Last) else Text);
   end Image;

   function Upper (Text : String) return String is
      Result : String := Text;
   begin
      for Item of Result loop
         if Item in 'a' .. 'z' then
            Item := Character'Val (Character'Pos (Item) - 32);
         end if;
      end loop;
      return Result;
   end Upper;

   function Starts_With (Text, Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1)
               = Prefix);

   function Ends_With (Text, Suffix : String) return Boolean is
     (Text'Length >= Suffix'Length
      and then Text (Text'Last - Suffix'Length + 1 .. Text'Last) = Suffix);

   function Contains (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) /= 0);

   function Is_Space (Item : Character) return Boolean is
     (Item in ' ' | ASCII.HT | ASCII.LF | ASCII.VT | ASCII.FF | ASCII.CR
        | Character'Val (16#1C#) .. Character'Val (16#1F#));

   function Strip (Text : String) return String is
      First : Positive := Text'First;
      Last : Natural := Text'Last;
   begin
      while First <= Last and then Is_Space (Text (First)) loop
         First := First + 1;
      end loop;
      while Last >= First and then Is_Space (Text (Last)) loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Strip;

   function Words (Text : String) return String_Vectors.Vector is
      Result : String_Vectors.Vector;
      Index : Natural := Text'First;
   begin
      while Index <= Text'Last loop
         if Is_Space (Text (Index)) then
            Index := Index + 1;
         else
            declare
               First : constant Positive := Index;
            begin
               while Index <= Text'Last and then not Is_Space (Text (Index))
               loop
                  Index := Index + 1;
               end loop;
               Result.Append (Text (First .. Index - 1));
            end;
         end if;
      end loop;
      return Result;
   end Words;

   function Join
     (Items : String_Vectors.Vector; Separator : String) return String
   is
      Result : US.Unbounded_String;
   begin
      for Position in 1 .. Natural (Items.Length) loop
         if Position > 1 then
            US.Append (Result, Separator);
         end if;
         US.Append (Result, Items (Position));
      end loop;
      return US.To_String (Result);
   end Join;

   function Collapse (Text : String) return String is
     (Join (Words (Text), " "));

   function Is_Digits (Text : String) return Boolean is
     (Text'Length > 0 and then (for all Item of Text => Item in '0' .. '9'));

   function Is_Decimal (Text : String) return Boolean is
     (Is_Digits (Text)
      or else (Text'Length > 1 and then Text (Text'First) = '-'
               and then Is_Digits (Text (Text'First + 1 .. Text'Last))));

   function Canonical (Text : String) return String is
      Negative : constant Boolean := Text (Text'First) = '-';
      Digits_First : Positive :=
        (if Negative then Text'First + 1 else Text'First);
   begin
      while Digits_First < Text'Last and then Text (Digits_First) = '0' loop
         Digits_First := Digits_First + 1;
      end loop;
      declare
         Magnitude : constant String := Text (Digits_First .. Text'Last);
      begin
         return (if Negative and then Magnitude /= "0" then "-" & Magnitude
                 else Magnitude);
      end;
   end Canonical;

   function Successor (Text : String) return String is
      Value : constant String := Canonical (Text);

      --  Magnitude plus one, or minus one when Down.
      function Step (Magnitude : String; Down : Boolean) return String;

      function Step (Magnitude : String; Down : Boolean) return String is
         Result : String := Magnitude;
      begin
         for Index in reverse Result'Range loop
            if Down then
               if Result (Index) = '0' then
                  Result (Index) := '9';
               else
                  Result (Index) := Character'Pred (Result (Index));
                  return Canonical (Result);
               end if;
            else
               if Result (Index) = '9' then
                  Result (Index) := '0';
               else
                  Result (Index) := Character'Succ (Result (Index));
                  return Result;
               end if;
            end if;
         end loop;
         return "1" & Result;
      end Step;
   begin
      if Value (Value'First) = '-' then
         declare
            Smaller : constant String :=
              Step (Value (Value'First + 1 .. Value'Last), Down => True);
         begin
            return (if Smaller = "0" then "0" else "-" & Smaller);
         end;
      end if;
      return Step (Value, Down => False);
   end Successor;

   ---------------------------------------------------------------------
   --  Python's repr
   ---------------------------------------------------------------------

   Hex : constant String := "0123456789abcdef";

   function Hex_Byte (Value : Natural) return String is
     ([Hex (Value / 16 + 1), Hex (Value mod 16 + 1)]);

   function Repr (Text : String) return String is
      Quote : constant Character :=
        (if Contains (Text, "'") and then not Contains (Text, """")
         then '"' else ''');
      Result : US.Unbounded_String := US.To_Unbounded_String ([1 => Quote]);
      Index : Natural := Text'First;
   begin
      while Index <= Text'Last loop
         declare
            Item : constant Character := Text (Index);
            Code : constant Natural := Character'Pos (Item);
         begin
            if Item = '\' then
               US.Append (Result, "\\");
               Index := Index + 1;
            elsif Item = Quote then
               US.Append (Result, "\" & Quote);
               Index := Index + 1;
            elsif Item = ASCII.HT then
               US.Append (Result, "\t");
               Index := Index + 1;
            elsif Item = ASCII.LF then
               US.Append (Result, "\n");
               Index := Index + 1;
            elsif Item = ASCII.CR then
               US.Append (Result, "\r");
               Index := Index + 1;
            elsif Code < 16#20# or else Code = 16#7F# then
               US.Append (Result, "\x" & Hex_Byte (Code));
               Index := Index + 1;
            elsif Code < 16#80# then
               US.Append (Result, Item);
               Index := Index + 1;
            else
               declare
                  Length : constant Positive := Sequence_Length (Text, Index);
                  Point : Natural := 0;
               begin
                  if Length = 1 then
                     US.Append (Result, "\x" & Hex_Byte (Code));
                  else
                     Point := Code mod (2 ** (7 - Length));
                     for Next in Index + 1 .. Index + Length - 1 loop
                        Point := Point * 64
                          + Character'Pos (Text (Next)) mod 64;
                     end loop;
                     if Point <= 16#A0# or else Point = 16#AD# then
                        US.Append (Result, "\x" & Hex_Byte (Point));
                     elsif Point in 16#2000# .. 16#200F# | 16#2028# .. 16#202F#
                         | 16#205F# .. 16#2064# | 16#3000# | 16#FEFF#
                         | 16#1680# | 16#180E#
                     then
                        US.Append
                          (Result, "\u" & Hex_Byte (Point / 256)
                           & Hex_Byte (Point mod 256));
                     else
                        US.Append (Result, Text (Index .. Index + Length - 1));
                     end if;
                  end if;
                  Index := Index + Length;
               end;
            end if;
         end;
      end loop;
      US.Append (Result, Quote);
      return US.To_String (Result);
   end Repr;

   function Value_Repr (From : J.Document; Item : J.Value) return String is
   begin
      if not J.Is_Present (Item) then
         return "None";
      end if;
      case J.Kind (From, Item) is
         when J.Null_Value => return "None";
         when J.True_Value => return "True";
         when J.False_Value => return "False";
         when J.Number_Value => return J.Text (From, Item);
         when J.String_Value => return Repr (J.Text (From, Item));
         when J.Array_Value =>
            declare
               Parts : String_Vectors.Vector;
            begin
               for Position in 1 .. J.Length (From, Item) loop
                  Parts.Append
                    (Value_Repr (From, J.Element (From, Item, Position)));
               end loop;
               return "[" & Join (Parts, ", ") & "]";
            end;
         when J.Object_Value =>
            declare
               Parts : String_Vectors.Vector;
            begin
               for Position in 1 .. J.Length (From, Item) loop
                  Parts.Append
                    (Repr (J.Key (From, Item, Position)) & ": "
                     & Value_Repr
                         (From, J.Member_Value (From, Item, Position)));
               end loop;
               return "{" & Join (Parts, ", ") & "}";
            end;
      end case;
   end Value_Repr;

   ---------------------------------------------------------------------
   --  The metadata tree
   ---------------------------------------------------------------------

   function Add (Within : Handle; Node : Meta_Node) return Meta_Id;

   function Add (Within : Handle; Node : Meta_Node) return Meta_Id is
   begin
      Within.Meta.Append (Node);
      return Within.Meta.Last_Index;
   end Add;

   function Null_Meta (Within : Handle) return Meta_Id is
     (Add (Within, (Kind => Meta_Null, others => <>)));

   function Boolean_Meta
     (Within : Handle; Item : Boolean) return Meta_Id
   is (Add (Within, (Kind => (if Item then Meta_True else Meta_False),
                     others => <>)));

   function Number_Meta
     (Within : Handle; Text : String) return Meta_Id
   is (Add (Within, (Kind => Meta_Number,
                     Text => US.To_Unbounded_String (Text), others => <>)));

   function Integer_Meta
     (Within : Handle; Item : Long_Long_Integer) return Meta_Id
   is (Number_Meta (Within, Image (Item)));

   function String_Meta
     (Within : Handle; Text : String) return Meta_Id
   is (Add (Within, (Kind => Meta_String,
                     Text => US.To_Unbounded_String (Text), others => <>)));

   function List_Meta (Within : Handle) return Meta_Id is
     (Add (Within, (Kind => Meta_List, others => <>)));

   function Object_Meta (Within : Handle) return Meta_Id is
     (Add (Within, (Kind => Meta_Object, others => <>)));

   procedure Append
     (Within : Handle; List : Meta_Id; Item : Meta_Id) is
   begin
      Within.Meta (List).Members.Append
        (Meta_Member'(Key => US.Null_Unbounded_String, Item => Item));
   end Append;

   function Strings_Meta
     (Within : Handle; Items : String_Vectors.Vector)
      return Meta_Id
   is
      List : constant Meta_Id := List_Meta (Within);
   begin
      for Item of Items loop
         Append (Within, List, String_Meta (Within, Item));
      end loop;
      return List;
   end Strings_Meta;

   procedure Put
     (Within : Handle; Object : Meta_Id; Key : String;
      Item : Meta_Id)
   is
   begin
      for Position in 1 .. Natural (Within.Meta (Object).Members.Length) loop
         if US.To_String (Within.Meta (Object).Members (Position).Key) = Key
         then
            Within.Meta (Object).Members (Position).Item := Item;
            return;
         end if;
      end loop;
      Within.Meta (Object).Members.Append
        (Meta_Member'(Key => US.To_Unbounded_String (Key), Item => Item));
   end Put;

   function Member
     (Within : Handle; Object : Meta_Id; Key : String) return Meta_Id is
   begin
      for Each of Within.Meta (Object).Members loop
         if US.To_String (Each.Key) = Key then
            return Each.Item;
         end if;
      end loop;
      raise Program_Error with "no metadata member " & Key;
   end Member;

   function Text_Of (Within : Handle; Item : Meta_Id) return String is
     (US.To_String (Within.Meta (Item).Text));

   function Kind_Of (Within : Handle; Item : Meta_Id) return Meta_Kind is
     (Within.Meta (Item).Kind);

   function Json_String (Text : String) return String;

   function Json_String (Text : String) return String is
      Result : US.Unbounded_String := US.To_Unbounded_String ("""");
   begin
      for Item of Text loop
         case Item is
            when '"' => US.Append (Result, "\""");
            when '\' => US.Append (Result, "\\");
            when ASCII.LF => US.Append (Result, "\n");
            when ASCII.CR => US.Append (Result, "\r");
            when ASCII.HT => US.Append (Result, "\t");
            when ASCII.BS => US.Append (Result, "\b");
            when ASCII.FF => US.Append (Result, "\f");
            when Character'Val (0) .. Character'Val (7) | ASCII.VT
               | Character'Val (16#0E#) .. Character'Val (16#1F#) =>
               US.Append
                 (Result, "\u00" & Hex_Byte (Character'Pos (Item)));
            when others => US.Append (Result, Item);
         end case;
      end loop;
      US.Append (Result, '"');
      return US.To_String (Result);
   end Json_String;

   function Pretty (Within : Handle; Item : Meta_Id) return String is
      Result : US.Unbounded_String;

      procedure Write (Node : Meta_Id; Level : Natural);

      procedure Write (Node : Meta_Id; Level : Natural) is
         Indent : constant String := [1 .. 2 * (Level + 1) => ' '];
         Closing : constant String := [1 .. 2 * Level => ' '];
         Held : constant Meta_Node := Within.Meta (Node);
         Count : constant Natural := Natural (Held.Members.Length);
      begin
         case Held.Kind is
            when Meta_Null => US.Append (Result, "null");
            when Meta_True => US.Append (Result, "true");
            when Meta_False => US.Append (Result, "false");
            when Meta_Number => US.Append (Result, Held.Text);
            when Meta_String =>
               US.Append (Result, Json_String (US.To_String (Held.Text)));
            when Meta_List =>
               if Count = 0 then
                  US.Append (Result, "[]");
                  return;
               end if;
               US.Append (Result, "[" & ASCII.LF);
               for Position in 1 .. Count loop
                  US.Append (Result, Indent);
                  Write (Held.Members (Position).Item, Level + 1);
                  US.Append
                    (Result, (if Position < Count then "," else "")
                     & ASCII.LF);
               end loop;
               US.Append (Result, Closing & "]");
            when Meta_Object =>
               if Count = 0 then
                  US.Append (Result, "{}");
                  return;
               end if;
               declare
                  Order : array (1 .. Count) of Positive;
               begin
                  for Position in Order'Range loop
                     Order (Position) := Position;
                  end loop;
                  --  Insertion sort by name: members are few, and names
                  --  are unique.
                  for Position in 2 .. Count loop
                     declare
                        Moving : constant Positive := Order (Position);
                        Place : Natural := Position - 1;
                     begin
                        while Place >= 1
                          and then US.">"
                            (Held.Members (Order (Place)).Key,
                             Held.Members (Moving).Key)
                        loop
                           Order (Place + 1) := Order (Place);
                           Place := Place - 1;
                        end loop;
                        Order (Place + 1) := Moving;
                     end;
                  end loop;
                  US.Append (Result, "{" & ASCII.LF);
                  for Position in 1 .. Count loop
                     US.Append
                       (Result, Indent & Json_String
                          (US.To_String
                             (Held.Members (Order (Position)).Key)) & ": ");
                     Write (Held.Members (Order (Position)).Item, Level + 1);
                     US.Append
                       (Result, (if Position < Count then "," else "")
                        & ASCII.LF);
                  end loop;
                  US.Append (Result, Closing & "}");
               end;
         end case;
      end Write;
   begin
      Write (Item, 0);
      US.Append (Result, ASCII.LF);
      return US.To_String (Result);
   end Pretty;

end Landin.Bindings.Texts;
