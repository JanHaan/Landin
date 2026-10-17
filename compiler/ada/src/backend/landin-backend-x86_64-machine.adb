with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Landin.Types;

package body Landin.Backend.X86_64.Machine is

   package US renames Ada.Strings.Unbounded;
   use type Landin.Types.Folded;

   --  Record one token: its text joins the stream's spelling.
   procedure Add
     (Into : in out Stream; Kind : Token_Kind; Text : String;
      Identity : Natural := 0);

   procedure Add
     (Into : in out Stream; Kind : Token_Kind; Text : String;
      Identity : Natural := 0)
   is
      First : constant Positive := US.Length (Into.Spelled) + 1;
   begin
      US.Append (Into.Spelled, Text);
      Into.Tokens.Append
        (Token'(Kind => Kind, First => First,
                Last => First + Text'Length - 1, Identity => Identity));
   end Add;

   function Starts (Text, Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   function Fits_Arithmetic_Immediate
     (Value : Landin.Targets.Byte_Count) return Boolean
   is
      use type Landin.Targets.Byte_Count;
   begin
      return Value <= 2 ** 31 - 1;
   end Fits_Arithmetic_Immediate;

   function Selected (Text : String) return String is
      Comma : constant Natural := Ada.Strings.Fixed.Index (Text, ", ");
   begin
      if (Starts (Text, "movq ") or else Starts (Text, "movw ")
          or else Starts (Text, "movb ")) and then Comma > 0
      then
         declare
            From : constant String := Text (Text'First + 5 .. Comma - 1);
            To : constant String := Text (Comma + 2 .. Text'Last);
         begin
            if From = To and then From'Length > 0
              and then From (From'First) = '%'
            then
               return "";
            end if;
         end;
      elsif Starts (Text, "movabsq $") and then Comma > 0 then
         declare
            Number : constant String := Text (Text'First + 9 .. Comma - 1);
            Numeric : Boolean := Number'Length > 0;
         begin
            for Character_Of of Number loop
               Numeric := Numeric and then Character_Of in '0' .. '9' | '-';
            end loop;
            if Numeric then
               declare
                  Value : constant Landin.Types.Folded :=
                    Landin.Types.Folded'Value (Number);
               begin
                  if Value in -(2 ** 31) .. 2 ** 31 - 1 then
                     return "movq $" & Number & Text (Comma .. Text'Last);
                  end if;
               end;
            end if;
         end;
      end if;
      return Text;
   end Selected;

   procedure Start (Into : out Stream; Record_Body : Boolean := True) is
   begin
      Into := (Recording => Record_Body, others => <>);
   end Start;

   function Is_Recording (Of_Stream : Stream) return Boolean
     is (Of_Stream.Recording);

   function Retained_Tokens (Of_Stream : Stream) return Natural
     is (Natural (Of_Stream.Tokens.Length));

   function Retained_Labels (Of_Stream : Stream) return Natural
     is (Natural (Of_Stream.Labels.Length));

   procedure Instruction (Into : in out Stream; Text : String) is
      Position : Natural := Text'First;
      First_Token : Boolean := True;
      Space : constant Natural := Ada.Strings.Fixed.Index (Text, " ");
      Op : constant String :=
        (if Space = 0 then Text else Text (Text'First .. Space - 1));
      Operand_Start : Natural :=
        (if Space = 0 then Text'Last + 1 else Space + 1);
      Depth : Natural := 0;
      Quoted : Boolean := False;

      procedure Count_Operand (Last : Natural; Destination : Boolean);

      procedure Count_Operand (Last : Natural; Destination : Boolean) is
         Part : constant String := Text (Operand_Start .. Last);
         On_Stack : constant Boolean :=
           Ada.Strings.Fixed.Index (Part, "(%rbp") > 0
           or else Ada.Strings.Fixed.Index (Part, "(%rsp") > 0;
         Write_Only : constant Boolean := Starts (Op, "mov")
           or else Starts (Op, "set") or else Starts (Op, "pop");
         Read_Only : constant Boolean := Starts (Op, "cmp")
           or else Starts (Op, "test") or else Starts (Op, "call")
           or else Starts (Op, "push") or else Starts (Op, "j")
           or else Starts (Op, "div") or else Starts (Op, "idiv")
           or else Starts (Op, "mul") or else Starts (Op, "imul");
      begin
         if On_Stack and then not Starts (Op, "lea") then
            if not Destination or else not Write_Only then
               Into.Counts.Stack_Loads := Into.Counts.Stack_Loads + 1;
            end if;
            if Destination and then not Read_Only then
               Into.Counts.Stack_Stores := Into.Counts.Stack_Stores + 1;
            end if;
         end if;
      end Count_Operand;
   begin
      if Into.Sealed or else Text'Length = 0
        or else Text (Text'First) = '.'
      then
         raise Landin.Compiler_Defect with "invalid final machine instruction";
      end if;
      Into.Counts.Instructions := Into.Counts.Instructions + 1;
      if Op = "call" then
         Into.Counts.Stack_Stores := Into.Counts.Stack_Stores + 1;
         if Text (Operand_Start) = '*' then
            Into.Counts.Indirect_Calls := Into.Counts.Indirect_Calls + 1;
         else
            Into.Counts.Direct_Calls := Into.Counts.Direct_Calls + 1;
         end if;
      elsif Starts (Op, "push") then
         Into.Counts.Stack_Stores := Into.Counts.Stack_Stores + 1;
      elsif Starts (Op, "pop") or else Op = "ret" then
         Into.Counts.Stack_Loads := Into.Counts.Stack_Loads + 1;
      end if;
      for Index in Operand_Start .. Text'Last loop
         if Text (Index) = '"' then
            Quoted := not Quoted;
         elsif not Quoted then
            if Text (Index) = '(' then
               Depth := Depth + 1;
            elsif Text (Index) = ')' then
               Depth := Depth - 1;
            elsif Text (Index) = ',' and then Depth = 0 then
               Count_Operand (Index - 1, False);
               Operand_Start := Index + 1;
            end if;
         end if;
      end loop;
      Count_Operand (Text'Last, True);
      if not Into.Recording then
         return;
      end if;
      while Position <= Text'Last loop
         if Text (Position) = ' ' then
            Position := Position + 1;
         else
            declare
               First : constant Natural := Position;
               Kind : Token_Kind := Operand;
            begin
               if Text (Position) = '"' then
                  Position := Position + 1;
                  while Position <= Text'Last and then Text (Position) /= '"'
                  loop
                     Position := Position + 1;
                  end loop;
                  if Position > Text'Last then
                     raise Landin.Compiler_Defect with
                       "unterminated machine relocation spelling";
                  end if;
                  Position := Position + 1;
               elsif Text (Position) in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
                   | '_' | '.' | '$' | '%'
               then
                  while Position <= Text'Last
                    and then Text (Position) in 'a' .. 'z' | 'A' .. 'Z'
                      | '0' .. '9' | '_' | '.' | '$' | '%'
                  loop
                     Position := Position + 1;
                  end loop;
               else
                  Kind := Punctuation;
                  Position := Position + 1;
               end if;
               if First_Token then
                  Kind := Mnemonic;
                  First_Token := False;
               end if;
               Add (Into, Kind, Text (First .. Position - 1));
            end;
         end if;
      end loop;
      --  An instruction boundary is evidence, including for prefix opcodes.
      Add (Into, Punctuation, ";");
   end Instruction;

   procedure Define_Label (Into : in out Stream; Name : String) is
   begin
      if Into.Sealed then
         raise Landin.Compiler_Defect with "a sealed body gained a label";
      end if;
      if not Into.Recording then
         return;
      end if;
      Into.Labels.Append (US.To_Unbounded_String (Name));
      Add (Into, Definition, "", Identity => Into.Labels.Last_Index);
   end Define_Label;

   procedure Seal (Into : in out Stream) is
      package Maps is new Ada.Containers.Indefinite_Hashed_Maps
        (Key_Type => String, Element_Type => Positive,
         Hash => Ada.Strings.Hash, Equivalent_Keys => "=");
      Labels : Maps.Map;
   begin
      if Into.Sealed or else not Into.Recording then
         return;
      end if;
      for Index in Into.Labels.First_Index .. Into.Labels.Last_Index loop
         declare
            Name : constant String := US.To_String (Into.Labels (Index));
         begin
            if Labels.Contains (Name) then
               raise Landin.Compiler_Defect with "duplicate machine label";
            end if;
            Labels.Insert (Name, Index);
         end;
      end loop;
      declare
         Spelled : constant String := US.To_String (Into.Spelled);
      begin
         for Part of Into.Tokens loop
            if Part.Kind = Operand then
               declare
                  Found : constant Maps.Cursor :=
                    Labels.Find (Spelled (Part.First .. Part.Last));
               begin
                  if Maps.Has_Element (Found) then
                     Part := (Kind => Local, First => 1, Last => 0,
                              Identity => Maps.Element (Found));
                  end if;
               end;
            end if;
         end loop;
      end;
      Into.Sealed := True;
   end Seal;

   function Equivalent (Left, Right : Stream) return Boolean is
   begin
      if not Left.Recording or else not Right.Recording
        or else not Left.Sealed or else not Right.Sealed
      then
         raise Landin.Compiler_Defect with "unsealed machine body comparison";
      end if;
      if Natural (Left.Tokens.Length) /= Natural (Right.Tokens.Length) then
         return False;
      end if;
      declare
         Left_Text : constant String := US.To_String (Left.Spelled);
         Right_Text : constant String := US.To_String (Right.Spelled);
      begin
         for Index in Left.Tokens.First_Index .. Left.Tokens.Last_Index loop
            declare
               L : constant Token := Left.Tokens.Element (Index);
               R : constant Token := Right.Tokens.Element (Index);
            begin
               if L.Kind /= R.Kind or else L.Identity /= R.Identity
                 or else Left_Text (L.First .. L.Last)
                   /= Right_Text (R.First .. R.Last)
               then
                  return False;
               end if;
            end;
         end loop;
      end;
      return True;
   end Equivalent;

   function Digest (Of_Stream : Stream) return Ada.Containers.Hash_Type is
      use type Ada.Containers.Hash_Type;
      Result : Ada.Containers.Hash_Type := 0;
   begin
      if not Of_Stream.Recording or else not Of_Stream.Sealed then
         raise Landin.Compiler_Defect with "unsealed machine body digest";
      end if;
      declare
         Spelled : constant String := US.To_String (Of_Stream.Spelled);
      begin
         for Part of Of_Stream.Tokens loop
            Result := Result * 31
              + Ada.Containers.Hash_Type (Token_Kind'Pos (Part.Kind));
            Result := Result * 31
              + Ada.Strings.Hash (Spelled (Part.First .. Part.Last));
            Result := Result * 31 + Ada.Containers.Hash_Type (Part.Identity);
         end loop;
      end;
      return Result;
   end Digest;

   function Statistics (Of_Stream : Stream)
     return Landin.Build_Reports.Routine_Statistics is (Of_Stream.Counts);

end Landin.Backend.X86_64.Machine;
