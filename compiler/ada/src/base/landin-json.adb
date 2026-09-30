with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Strings.Hash;

package body Landin.Json is

   package Unbounded renames Ada.Strings.Unbounded;

   package Name_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (Element_Type        => String,
      Hash                => Ada.Strings.Hash,
      Equivalent_Elements => "=");

   ---------------------------------------------------------------------
   --  Reading
   ---------------------------------------------------------------------

   --  Raised inside Parse only, and never out of it: the one way a fault
   --  deep in the descent reaches the procedure that records it.
   Refused : exception;

   procedure Parse (Into : in out Document; Text : String) is
      Cursor : Natural := Text'First;
      Depth  : Natural := 0;

      procedure Refuse (Reason : String; At_Byte : Natural)
        with No_Return;
      procedure Skip_Space;
      function Parse_Value return Positive;
      procedure Parse_String
        (First : out Natural; Last : out Natural);
      function Parse_Number return Positive;
      function Add (Item : Node) return Positive;
      procedure Expect (Word : String; At_Byte : Natural);

      procedure Refuse (Reason : String; At_Byte : Natural) is
      begin
         Into.Reason := Unbounded.To_Unbounded_String (Reason);
         Into.Offset := At_Byte - Text'First;
         raise Refused;
      end Refuse;

      procedure Skip_Space is
      begin
         while Cursor <= Text'Last
           and then Text (Cursor) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
         loop
            Cursor := Cursor + 1;
         end loop;
      end Skip_Space;

      function Add (Item : Node) return Positive is
      begin
         Into.Nodes.Append (Item);
         return Positive (Into.Nodes.Length);
      end Add;

      procedure Expect (Word : String; At_Byte : Natural) is
      begin
         if Text'Last - Cursor + 1 < Word'Length
           or else Text (Cursor .. Cursor + Word'Length - 1) /= Word
         then
            Refuse ("not a JSON value", At_Byte);
         end if;
         Cursor := Cursor + Word'Length;
      end Expect;

      --  One \uXXXX's four digits, Cursor on the first.
      function Hex_Unit return Natural;

      function Hex_Unit return Natural is
         Result : Natural := 0;
      begin
         if Text'Last - Cursor + 1 < 4 then
            Refuse ("a \u escape needs four hexadecimal digits", Cursor);
         end if;
         for Offset in 0 .. 3 loop
            declare
               C : constant Character := Text (Cursor + Offset);
               Digit : Natural;
            begin
               case C is
                  when '0' .. '9' =>
                     Digit := Character'Pos (C) - Character'Pos ('0');
                  when 'a' .. 'f' =>
                     Digit := Character'Pos (C) - Character'Pos ('a') + 10;
                  when 'A' .. 'F' =>
                     Digit := Character'Pos (C) - Character'Pos ('A') + 10;
                  when others =>
                     Refuse ("a \u escape needs four hexadecimal digits",
                             Cursor + Offset);
               end case;
               Result := Result * 16 + Digit;
            end;
         end loop;
         Cursor := Cursor + 4;
         return Result;
      end Hex_Unit;

      procedure Append_Code_Point (Code : Natural);

      procedure Append_Code_Point (Code : Natural) is
         procedure Put (Byte : Natural);
         procedure Put (Byte : Natural) is
         begin
            Unbounded.Append (Into.Bytes, Character'Val (Byte));
         end Put;
      begin
         if Code < 16#80# then
            Put (Code);
         elsif Code < 16#800# then
            Put (16#C0# + Code / 64);
            Put (16#80# + Code mod 64);
         elsif Code < 16#1_0000# then
            Put (16#E0# + Code / 4096);
            Put (16#80# + (Code / 64) mod 64);
            Put (16#80# + Code mod 64);
         else
            Put (16#F0# + Code / 262_144);
            Put (16#80# + (Code / 4096) mod 64);
            Put (16#80# + (Code / 64) mod 64);
            Put (16#80# + Code mod 64);
         end if;
      end Append_Code_Point;

      --  The length of the well-formed UTF-8 sequence at Cursor, or zero.
      --  Well-formed is Unicode's table 3-7: no overlong form, no encoded
      --  surrogate, nothing past U+10FFFF.
      function Sequence_Length return Natural;

      function Sequence_Length return Natural is
         function Byte (Offset : Natural) return Natural
           is (Character'Pos (Text (Cursor + Offset)));
         function Continues (Offset : Natural; Low, High : Natural)
           return Boolean
           is (Cursor + Offset <= Text'Last
               and then Byte (Offset) in Low .. High);
         Lead : constant Natural := Byte (0);
      begin
         case Lead is
            when 16#00# .. 16#7F# =>
               return 1;
            when 16#C2# .. 16#DF# =>
               return (if Continues (1, 16#80#, 16#BF#) then 2 else 0);
            when 16#E0# =>
               return (if Continues (1, 16#A0#, 16#BF#)
                         and then Continues (2, 16#80#, 16#BF#)
                       then 3 else 0);
            when 16#E1# .. 16#EC# | 16#EE# .. 16#EF# =>
               return (if Continues (1, 16#80#, 16#BF#)
                         and then Continues (2, 16#80#, 16#BF#)
                       then 3 else 0);
            when 16#ED# =>
               return (if Continues (1, 16#80#, 16#9F#)
                         and then Continues (2, 16#80#, 16#BF#)
                       then 3 else 0);
            when 16#F0# =>
               return (if Continues (1, 16#90#, 16#BF#)
                         and then Continues (2, 16#80#, 16#BF#)
                         and then Continues (3, 16#80#, 16#BF#)
                       then 4 else 0);
            when 16#F1# .. 16#F3# =>
               return (if Continues (1, 16#80#, 16#BF#)
                         and then Continues (2, 16#80#, 16#BF#)
                         and then Continues (3, 16#80#, 16#BF#)
                       then 4 else 0);
            when 16#F4# =>
               return (if Continues (1, 16#80#, 16#8F#)
                         and then Continues (2, 16#80#, 16#BF#)
                         and then Continues (3, 16#80#, 16#BF#)
                       then 4 else 0);
            when others =>
               return 0;
         end case;
      end Sequence_Length;

      procedure Parse_String (First : out Natural; Last : out Natural) is
         Opened : constant Natural := Cursor;
      begin
         Cursor := Cursor + 1;
         First := Unbounded.Length (Into.Bytes) + 1;
         loop
            if Cursor > Text'Last then
               Refuse ("a string is not closed", Opened);
            end if;
            declare
               C : constant Character := Text (Cursor);
            begin
               if C = '"' then
                  Cursor := Cursor + 1;
                  exit;
               elsif C = '\' then
                  Cursor := Cursor + 1;
                  if Cursor > Text'Last then
                     Refuse ("a string is not closed", Opened);
                  end if;
                  case Text (Cursor) is
                     when '"' | '\' | '/' =>
                        Unbounded.Append (Into.Bytes, Text (Cursor));
                        Cursor := Cursor + 1;
                     when 'b' =>
                        Unbounded.Append (Into.Bytes, ASCII.BS);
                        Cursor := Cursor + 1;
                     when 'f' =>
                        Unbounded.Append (Into.Bytes, ASCII.FF);
                        Cursor := Cursor + 1;
                     when 'n' =>
                        Unbounded.Append (Into.Bytes, ASCII.LF);
                        Cursor := Cursor + 1;
                     when 'r' =>
                        Unbounded.Append (Into.Bytes, ASCII.CR);
                        Cursor := Cursor + 1;
                     when 't' =>
                        Unbounded.Append (Into.Bytes, ASCII.HT);
                        Cursor := Cursor + 1;
                     when 'u' =>
                        declare
                           Escape : constant Natural := Cursor - 1;
                           Unit   : Natural;
                        begin
                           Cursor := Cursor + 1;
                           Unit := Hex_Unit;
                           if Unit in 16#DC00# .. 16#DFFF# then
                              Refuse ("a low surrogate stands alone",
                                      Escape);
                           elsif Unit in 16#D800# .. 16#DBFF# then
                              if Text'Last - Cursor + 1 < 6
                                or else Text (Cursor .. Cursor + 1) /= "\u"
                              then
                                 Refuse ("a high surrogate stands alone",
                                         Escape);
                              end if;
                              Cursor := Cursor + 2;
                              declare
                                 Low : constant Natural := Hex_Unit;
                              begin
                                 if Low not in 16#DC00# .. 16#DFFF# then
                                    Refuse ("a high surrogate stands alone",
                                            Escape);
                                 end if;
                                 Append_Code_Point
                                   (16#1_0000#
                                    + (Unit - 16#D800#) * 1024
                                    + (Low - 16#DC00#));
                              end;
                           else
                              Append_Code_Point (Unit);
                           end if;
                        end;
                     when others =>
                        Refuse ("not an escape JSON has", Cursor - 1);
                  end case;
               elsif Character'Pos (C) < 16#20# then
                  Refuse ("a control character must be escaped", Cursor);
               else
                  declare
                     Length : constant Natural := Sequence_Length;
                  begin
                     if Length = 0 then
                        Refuse ("not UTF-8", Cursor);
                     end if;
                     Unbounded.Append
                       (Into.Bytes, Text (Cursor .. Cursor + Length - 1));
                     Cursor := Cursor + Length;
                  end;
               end if;
            end;
         end loop;
         Last := Unbounded.Length (Into.Bytes);
      end Parse_String;

      function Parse_Number return Positive is
         Start    : constant Natural := Cursor;
         Integral : Boolean := True;

         procedure Digits_Run;
         procedure Digits_Run is
            Began : constant Natural := Cursor;
         begin
            while Cursor <= Text'Last and then Text (Cursor) in '0' .. '9'
            loop
               Cursor := Cursor + 1;
            end loop;
            if Cursor = Began then
               Refuse ("a number needs a digit here", Cursor);
            end if;
         end Digits_Run;
      begin
         if Text (Cursor) = '-' then
            Cursor := Cursor + 1;
         end if;
         if Cursor <= Text'Last and then Text (Cursor) = '0' then
            Cursor := Cursor + 1;
         else
            Digits_Run;
         end if;
         if Cursor <= Text'Last and then Text (Cursor) = '.' then
            Integral := False;
            Cursor := Cursor + 1;
            Digits_Run;
         end if;
         if Cursor <= Text'Last and then Text (Cursor) in 'e' | 'E' then
            Integral := False;
            Cursor := Cursor + 1;
            if Cursor <= Text'Last and then Text (Cursor) in '+' | '-' then
               Cursor := Cursor + 1;
            end if;
            Digits_Run;
         end if;

         declare
            Item  : Node := (Kind => Number_Value, others => <>);
            Magnitude : Long_Long_Integer := 0;
            First_Digit : constant Natural :=
              (if Text (Start) = '-' then Start + 1 else Start);
         begin
            Item.First_Text := Unbounded.Length (Into.Bytes) + 1;
            Unbounded.Append (Into.Bytes, Text (Start .. Cursor - 1));
            Item.Text_Last := Unbounded.Length (Into.Bytes);
            --  Sixteen digits exceed 2**53 already, so a longer run is
            --  never an integer and is never accumulated.
            if Integral and then Cursor - First_Digit <= 16 then
               for Index in First_Digit .. Cursor - 1 loop
                  Magnitude := Magnitude * 10
                    + Long_Long_Integer
                        (Character'Pos (Text (Index)) - Character'Pos ('0'));
               end loop;
               if Magnitude <= Largest_Integer then
                  Item.Integral := True;
                  Item.Whole := Integer_Value
                    (if Text (Start) = '-' then -Magnitude else Magnitude);
               end if;
            end if;
            return Add (Item);
         end;
      end Parse_Number;

      function Parse_Value return Positive is
      begin
         Skip_Space;
         if Cursor > Text'Last then
            Refuse ("a value is missing", Cursor);
         end if;
         case Text (Cursor) is
            when '{' | '[' =>
               declare
                  Is_Object : constant Boolean := Text (Cursor) = '{';
                  Closer : constant Character :=
                    (if Is_Object then '}' else ']');
                  Opened : constant Natural := Cursor;
                  Members : Index_Vectors.Vector;
                  Names   : Name_Sets.Set;
                  Result : Node :=
                    (Kind   => (if Is_Object then Object_Value
                                else Array_Value),
                     others => <>);
               begin
                  Depth := Depth + 1;
                  if Depth > Maximum_Depth then
                     Refuse ("nested deeper than"
                             & Natural'Image (Maximum_Depth), Cursor);
                  end if;
                  Cursor := Cursor + 1;
                  Skip_Space;
                  if Cursor <= Text'Last and then Text (Cursor) = Closer then
                     Cursor := Cursor + 1;
                  else
                     loop
                        declare
                           Key_First, Key_Last : Natural := 0;
                           Child : Positive;
                        begin
                           if Is_Object then
                              Skip_Space;
                              if Cursor > Text'Last
                                or else Text (Cursor) /= '"'
                              then
                                 Refuse ("a member needs a string name",
                                         Cursor);
                              end if;
                              declare
                                 Named_At : constant Natural := Cursor;
                              begin
                                 Parse_String (Key_First, Key_Last);
                                 declare
                                    Inserted : Boolean;
                                    Where    : Name_Sets.Cursor;
                                 begin
                                    Names.Insert
                                      (Unbounded.Slice
                                         (Into.Bytes, Key_First, Key_Last),
                                       Where, Inserted);
                                    if not Inserted then
                                       Refuse ("a member is named twice",
                                               Named_At);
                                    end if;
                                 end;
                              end;
                              Skip_Space;
                              if Cursor > Text'Last
                                or else Text (Cursor) /= ':'
                              then
                                 Refuse ("a member name needs a ':'",
                                         Cursor);
                              end if;
                              Cursor := Cursor + 1;
                           end if;
                           Child := Parse_Value;
                           if Is_Object then
                              declare
                                 Held : Node := Into.Nodes.Element (Child);
                              begin
                                 Held.Key_First := Key_First;
                                 Held.Key_Last := Key_Last;
                                 Into.Nodes.Replace_Element (Child, Held);
                              end;
                           end if;
                           Members.Append (Child);
                        end;
                        Skip_Space;
                        if Cursor > Text'Last then
                           Refuse ((if Is_Object then "an object"
                                    else "an array") & " is not closed",
                                   Opened);
                        elsif Text (Cursor) = ',' then
                           Cursor := Cursor + 1;
                        elsif Text (Cursor) = Closer then
                           Cursor := Cursor + 1;
                           exit;
                        else
                           Refuse ("expected ',' or '" & Closer & "'",
                                   Cursor);
                        end if;
                     end loop;
                  end if;
                  Depth := Depth - 1;
                  Result.First_Child := Natural (Into.Children.Length) + 1;
                  Result.Count := Natural (Members.Length);
                  Into.Children.Append (Members);
                  return Add (Result);
               end;
            when '"' =>
               declare
                  Result : Node := (Kind => String_Value, others => <>);
               begin
                  Parse_String (Result.First_Text, Result.Text_Last);
                  return Add (Result);
               end;
            when '-' | '0' .. '9' =>
               return Parse_Number;
            when 't' =>
               Expect ("true", Cursor);
               return Add ((Kind => True_Value, others => <>));
            when 'f' =>
               Expect ("false", Cursor);
               return Add ((Kind => False_Value, others => <>));
            when 'n' =>
               Expect ("null", Cursor);
               return Add ((Kind => Null_Value, others => <>));
            when others =>
               Refuse ("not a JSON value", Cursor);
         end case;
      end Parse_Value;
   begin
      Into.Nodes.Clear;
      Into.Children.Clear;
      Into.Bytes := Unbounded.Null_Unbounded_String;
      Into.Reason := Unbounded.Null_Unbounded_String;
      Into.Offset := 0;
      Into.Parsed := False;
      Into.Top := No_Value;
      declare
         Top : constant Positive := Parse_Value;
      begin
         Skip_Space;
         if Cursor <= Text'Last then
            Refuse ("text follows the value", Cursor);
         end if;
         Into.Top := Value (Top);
         Into.Parsed := True;
      end;
   exception
      when Refused =>
         Into.Nodes.Clear;
         Into.Children.Clear;
         Into.Bytes := Unbounded.Null_Unbounded_String;
         Into.Parsed := False;
   end Parse;

   function Ok (Of_Document : Document) return Boolean
     is (Of_Document.Parsed);

   function Fault (Of_Document : Document) return String
     is (Unbounded.To_String (Of_Document.Reason));

   function Fault_At (Of_Document : Document) return Natural
     is (Of_Document.Offset);

   function Root (Of_Document : Document) return Value
     is (Of_Document.Top);

   function Is_Present (Item : Value) return Boolean
     is (Item /= No_Value);

   function Held (Of_Document : Document; Item : Value) return Node;
   function Child
     (Of_Document : Document; Item : Value; Position : Positive)
      return Value;

   function Held (Of_Document : Document; Item : Value) return Node
     is (Of_Document.Nodes.Element (Positive (Item)));

   function Kind (Of_Document : Document; Item : Value) return Value_Kind
     is (Held (Of_Document, Item).Kind);

   function Text (Of_Document : Document; Item : Value) return String is
      Found : constant Node := Held (Of_Document, Item);
   begin
      return Unbounded.Slice
        (Of_Document.Bytes, Found.First_Text, Found.Text_Last);
   end Text;

   function Is_Integer (Of_Document : Document; Item : Value) return Boolean
     is (Is_Present (Item)
         and then Kind (Of_Document, Item) = Number_Value
         and then Held (Of_Document, Item).Integral);

   function Integer_Of
     (Of_Document : Document; Item : Value) return Integer_Value
     is (Held (Of_Document, Item).Whole);

   function Length (Of_Document : Document; Item : Value) return Natural
     is (Held (Of_Document, Item).Count);

   function Child
     (Of_Document : Document; Item : Value; Position : Positive)
      return Value
     is (Value (Of_Document.Children.Element
           (Held (Of_Document, Item).First_Child + Position - 1)));

   function Element
     (Of_Document : Document; Item : Value; Position : Positive)
      return Value
     is (Child (Of_Document, Item, Position));

   function Member_Value
     (Of_Document : Document; Item : Value; Position : Positive)
      return Value
     is (Child (Of_Document, Item, Position));

   function Key
     (Of_Document : Document; Item : Value; Position : Positive)
      return String
   is
      Found : constant Node :=
        Held (Of_Document, Child (Of_Document, Item, Position));
   begin
      return Unbounded.Slice
        (Of_Document.Bytes, Found.Key_First, Found.Key_Last);
   end Key;

   function Member
     (Of_Document : Document; Item : Value; Name : String) return Value
   is
   begin
      if not Is_Kind (Of_Document, Item, Object_Value) then
         return No_Value;
      end if;
      for Position in 1 .. Length (Of_Document, Item) loop
         if Key (Of_Document, Item, Position) = Name then
            return Member_Value (Of_Document, Item, Position);
         end if;
      end loop;
      return No_Value;
   end Member;

   ---------------------------------------------------------------------
   --  Writing
   ---------------------------------------------------------------------

   Hex : constant String := "0123456789abcdef";

   function Quoted (Item : String) return String is
      Result : Unbounded.Unbounded_String :=
        Unbounded.To_Unbounded_String ("""");
      Cursor : Natural := Item'First;

      --  Well-formed UTF-8 at Cursor, by the same table the reader keeps.
      function Sequence_Length return Natural;

      function Sequence_Length return Natural is
         function Byte (Offset : Natural) return Natural
           is (Character'Pos (Item (Cursor + Offset)));
         function Continues (Offset : Natural; Low, High : Natural)
           return Boolean
           is (Cursor + Offset <= Item'Last
               and then Byte (Offset) in Low .. High);
      begin
         case Byte (0) is
            when 16#00# .. 16#7F# =>
               return 1;
            when 16#C2# .. 16#DF# =>
               return (if Continues (1, 16#80#, 16#BF#) then 2 else 0);
            when 16#E0# =>
               return (if Continues (1, 16#A0#, 16#BF#)
                         and then Continues (2, 16#80#, 16#BF#)
                       then 3 else 0);
            when 16#E1# .. 16#EC# | 16#EE# .. 16#EF# =>
               return (if Continues (1, 16#80#, 16#BF#)
                         and then Continues (2, 16#80#, 16#BF#)
                       then 3 else 0);
            when 16#ED# =>
               return (if Continues (1, 16#80#, 16#9F#)
                         and then Continues (2, 16#80#, 16#BF#)
                       then 3 else 0);
            when 16#F0# =>
               return (if Continues (1, 16#90#, 16#BF#)
                         and then Continues (2, 16#80#, 16#BF#)
                         and then Continues (3, 16#80#, 16#BF#)
                       then 4 else 0);
            when 16#F1# .. 16#F3# =>
               return (if Continues (1, 16#80#, 16#BF#)
                         and then Continues (2, 16#80#, 16#BF#)
                         and then Continues (3, 16#80#, 16#BF#)
                       then 4 else 0);
            when 16#F4# =>
               return (if Continues (1, 16#80#, 16#8F#)
                         and then Continues (2, 16#80#, 16#BF#)
                         and then Continues (3, 16#80#, 16#BF#)
                       then 4 else 0);
            when others =>
               return 0;
         end case;
      end Sequence_Length;
   begin
      while Cursor <= Item'Last loop
         declare
            C : constant Character := Item (Cursor);
            Length : constant Natural := Sequence_Length;
         begin
            case C is
               when '"' =>
                  Unbounded.Append (Result, "\""");
               when '\' =>
                  Unbounded.Append (Result, "\\");
               when ASCII.LF =>
                  Unbounded.Append (Result, "\n");
               when ASCII.CR =>
                  Unbounded.Append (Result, "\r");
               when ASCII.HT =>
                  Unbounded.Append (Result, "\t");
               when ASCII.BS =>
                  Unbounded.Append (Result, "\b");
               when ASCII.FF =>
                  Unbounded.Append (Result, "\f");
               when others =>
                  if Character'Pos (C) < 16#20# then
                     Unbounded.Append
                       (Result, "\u00"
                        & Hex (Character'Pos (C) / 16 + 1)
                        & Hex (Character'Pos (C) mod 16 + 1));
                  elsif Length = 0 then
                     Unbounded.Append (Result, "\ufffd");
                  else
                     Unbounded.Append
                       (Result, Item (Cursor .. Cursor + Length - 1));
                  end if;
            end case;
            Cursor := Cursor + (if Length = 0 then 1 else Length);
         end;
      end loop;
      Unbounded.Append (Result, """");
      return Unbounded.To_String (Result);
   end Quoted;

   --  Whatever comes before a value: a comma after an earlier element,
   --  nothing after a member's name.
   procedure Before_Value (Into : in out Builder);

   procedure Before_Value (Into : in out Builder) is
   begin
      if Into.Named then
         Into.Named := False;
      elsif not Into.Open.Is_Empty then
         if Into.Open.Last_Element then
            Unbounded.Append (Into.Text, ",");
         end if;
         Into.Open.Replace_Element (Into.Open.Last_Index, True);
      end if;
   end Before_Value;

   procedure Begin_Object (Into : in out Builder) is
   begin
      Before_Value (Into);
      Unbounded.Append (Into.Text, "{");
      Into.Open.Append (False);
   end Begin_Object;

   procedure End_Object (Into : in out Builder) is
   begin
      Into.Open.Delete_Last;
      Unbounded.Append (Into.Text, "}");
   end End_Object;

   procedure Begin_Array (Into : in out Builder) is
   begin
      Before_Value (Into);
      Unbounded.Append (Into.Text, "[");
      Into.Open.Append (False);
   end Begin_Array;

   procedure End_Array (Into : in out Builder) is
   begin
      Into.Open.Delete_Last;
      Unbounded.Append (Into.Text, "]");
   end End_Array;

   procedure Name (Into : in out Builder; Key : String) is
   begin
      Before_Value (Into);
      Unbounded.Append (Into.Text, Quoted (Key) & ":");
      Into.Named := True;
   end Name;

   procedure Write_String (Into : in out Builder; Item : String) is
   begin
      Before_Value (Into);
      Unbounded.Append (Into.Text, Quoted (Item));
   end Write_String;

   procedure Write_Integer (Into : in out Builder; Item : Long_Long_Integer)
   is
      Image : constant String := Long_Long_Integer'Image (Item);
   begin
      Before_Value (Into);
      Unbounded.Append
        (Into.Text,
         (if Image (Image'First) = ' '
          then Image (Image'First + 1 .. Image'Last) else Image));
   end Write_Integer;

   procedure Write_Boolean (Into : in out Builder; Item : Boolean) is
   begin
      Before_Value (Into);
      Unbounded.Append (Into.Text, (if Item then "true" else "false"));
   end Write_Boolean;

   procedure Write_Null (Into : in out Builder) is
   begin
      Before_Value (Into);
      Unbounded.Append (Into.Text, "null");
   end Write_Null;

   procedure Write_Raw (Into : in out Builder; Item : String) is
   begin
      Before_Value (Into);
      Unbounded.Append (Into.Text, Item);
   end Write_Raw;

   procedure Copy (Into : in out Builder; From : Document; Item : Value) is
   begin
      case Kind (From, Item) is
         when Null_Value =>
            Write_Null (Into);
         when False_Value =>
            Write_Boolean (Into, False);
         when True_Value =>
            Write_Boolean (Into, True);
         when Number_Value =>
            Write_Raw (Into, Text (From, Item));
         when String_Value =>
            Write_String (Into, Text (From, Item));
         when Array_Value =>
            Begin_Array (Into);
            for Position in 1 .. Length (From, Item) loop
               Copy (Into, From, Element (From, Item, Position));
            end loop;
            End_Array (Into);
         when Object_Value =>
            Begin_Object (Into);
            for Position in 1 .. Length (From, Item) loop
               Name (Into, Key (From, Item, Position));
               Copy (Into, From, Member_Value (From, Item, Position));
            end loop;
            End_Object (Into);
      end case;
   end Copy;

   function Result (Of_Builder : Builder) return String
     is (Unbounded.To_String (Of_Builder.Text));

end Landin.Json;
