with Ada.Containers.Indefinite_Ordered_Sets;
with GNAT.SHA256;

with Landin.Devices.Policies;
with Landin.Xml;

package body Landin.Devices.Projection is

   package X renames Landin.Xml;
   package P renames Landin.Devices.Policies;

   package Name_Sets is new Ada.Containers.Indefinite_Ordered_Sets
     (Element_Type => String);

   use type Interfaces.Unsigned_64;
   use type US.Unbounded_String;
   use type P.Read_Policy;
   use type P.Write_Policy;
   use type P.Reserved_Policy;

   LF : constant Character := ASCII.LF;

   Refused : exception;

   function Under (Directory, Path : String) return String is
     (if Directory = "." then Path else Directory & "/" & Path);

   ------------------------------------------------------------------
   --  Python's json.dumps (indent=2, sort_keys=True): the bytes the
   --  correspondence and the manifest were first written in, kept.
   ------------------------------------------------------------------

   function Json_String (Item : String) return String;

   function Json_String (Item : String) return String is
      Text : US.Unbounded_String := US.To_Unbounded_String ("""");
      Hex_Digits : constant String := "0123456789abcdef";
      Index : Integer := Item'First;

      procedure Escape (Point : Natural);

      procedure Escape (Point : Natural) is
      begin
         US.Append (Text, "\u"
           & Hex_Digits (Point / 4096 mod 16 + 1)
           & Hex_Digits (Point / 256 mod 16 + 1)
           & Hex_Digits (Point / 16 mod 16 + 1)
           & Hex_Digits (Point mod 16 + 1));
      end Escape;
   begin
      while Index <= Item'Last loop
         declare
            C : constant Character := Item (Index);
            Code : constant Natural := Character'Pos (C);
         begin
            case C is
               when '"' => US.Append (Text, "\""");
               when '\' => US.Append (Text, "\\");
               when ASCII.LF => US.Append (Text, "\n");
               when ASCII.CR => US.Append (Text, "\r");
               when ASCII.HT => US.Append (Text, "\t");
               when ASCII.BS => US.Append (Text, "\b");
               when ASCII.FF => US.Append (Text, "\f");
               when others =>
                  if Code < 32 or else Code = 127 then
                     if Code = 127 then
                        US.Append (Text, C);
                     else
                        Escape (Code);
                     end if;
                  elsif Code < 128 then
                     US.Append (Text, C);
                  else
                     --  UTF-8, already validated by the reader, as \u
                     --  escapes, a surrogate pair above the basic plane.
                     declare
                        Count : constant Natural :=
                          (if Code >= 16#F0# then 4
                           elsif Code >= 16#E0# then 3 else 2);
                        Point : Natural :=
                          Code mod (case Count is
                                      when 4 => 8, when 3 => 16,
                                      when others => 32);
                     begin
                        for Next in Index + 1 .. Index + Count - 1 loop
                           Point := Point * 64
                             + Character'Pos (Item (Next)) mod 64;
                        end loop;
                        if Point >= 16#1_0000# then
                           Escape (16#D800# + (Point - 16#1_0000#) / 1024);
                           Escape (16#DC00# + (Point - 16#1_0000#) mod 1024);
                        else
                           Escape (Point);
                        end if;
                        Index := Index + Count - 1;
                     end;
                  end if;
            end case;
         end;
         Index := Index + 1;
      end loop;
      US.Append (Text, """");
      return US.To_String (Text);
   end Json_String;

   type Open_Kind is (In_Array, In_Object);

   type Emptiness is array (1 .. 16) of Boolean;

   type Writer is record
      Text : US.Unbounded_String;
      Depth : Natural := 0;
      Empty : Emptiness := [others => True];
      After_Key : Boolean := False;
   end record;

   procedure Item_Prefix (Into : in out Writer);

   procedure Item_Prefix (Into : in out Writer) is
   begin
      if Into.After_Key then
         Into.After_Key := False;
      elsif Into.Depth > 0 then
         if not Into.Empty (Into.Depth) then
            US.Append (Into.Text, ",");
         end if;
         Into.Empty (Into.Depth) := False;
         US.Append (Into.Text, LF & [1 .. 2 * Into.Depth => ' ']);
      end if;
   end Item_Prefix;

   procedure Open (Into : in out Writer; Kind : Open_Kind);

   procedure Open (Into : in out Writer; Kind : Open_Kind) is
   begin
      Item_Prefix (Into);
      US.Append (Into.Text, (if Kind = In_Array then "[" else "{"));
      Into.Depth := Into.Depth + 1;
      Into.Empty (Into.Depth) := True;
   end Open;

   procedure Close (Into : in out Writer; Kind : Open_Kind);

   procedure Close (Into : in out Writer; Kind : Open_Kind) is
   begin
      if not Into.Empty (Into.Depth) then
         US.Append (Into.Text, LF & [1 .. 2 * (Into.Depth - 1) => ' ']);
      end if;
      Into.Depth := Into.Depth - 1;
      US.Append (Into.Text, (if Kind = In_Array then "]" else "}"));
   end Close;

   procedure Member (Into : in out Writer; Name : String);

   procedure Member (Into : in out Writer; Name : String) is
   begin
      Item_Prefix (Into);
      US.Append (Into.Text, Json_String (Name) & ": ");
      Into.After_Key := True;
   end Member;

   procedure Raw (Into : in out Writer; Text : String);

   procedure Raw (Into : in out Writer; Text : String) is
   begin
      Item_Prefix (Into);
      US.Append (Into.Text, Text);
   end Raw;

   procedure Number_Value (Into : in out Writer; Value : Word);

   procedure Number_Value (Into : in out Writer; Value : Word) is
   begin
      Raw (Into, Decimal (Value));
   end Number_Value;

   procedure String_Value (Into : in out Writer; Value : String);

   procedure String_Value (Into : in out Writer; Value : String) is
   begin
      Raw (Into, Json_String (Value));
   end String_Value;

   ------------------------------------------------------------------
   --  The projection.
   ------------------------------------------------------------------

   function Sha256 (Text : String) return String is
     (GNAT.SHA256.Digest (Text));

   type Encoding is record
      Name : US.Unbounded_String;
      Value : Word := 0;
   end record;

   package Encoding_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Encoding);

   type Interrupt is record
      Value : Word := 0;
      Name : US.Unbounded_String;
   end record;

   package Interrupt_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Interrupt);

   procedure Project
     (Svd_Text, Policy_Text : String;
      Made : out Result;
      Problem : out Fault)
   is
      Chosen : P.Policy;
      Document : X.Document;
      Device : X.Element;
      Rows : Writer;
      --  Each selected field whose enumerated values are named otherwise
      --  than an identifier, with the first such name, so that one refusal
      --  names them all (D557) rather than one a run.
      Unnamed : US.Unbounded_String;
      Unnamed_Count : Natural := 0;
      First_Unnamed : X.Element := X.No_Element;

      procedure Fail
        (Kind : Fault_Kind; Message : String;
         At_Element : X.Element := X.No_Element;
         At_Text : Boolean := False)
        with No_Return;

      procedure Fail
        (Kind : Fault_Kind; Message : String;
         At_Element : X.Element := X.No_Element;
         At_Text : Boolean := False) is
      begin
         Problem :=
           (Kind => Kind,
            Within => (if Kind = Invalid_Policy then Policy_Input
                       else Svd_Input),
            Offset =>
              (if not X.Is_Present (At_Element) then 0
               elsif At_Text then X.Text_Offset (Document, At_Element)
               else X.Offset (Document, At_Element)),
            Has_Offset => X.Is_Present (At_Element),
            Message => US.To_Unbounded_String (Message));
         raise Refused;
      end Fail;

      function Child (Item : X.Element; Name : String) return X.Element is
        (if X.Is_Present (Item) then X.Child (Document, Item, Name)
         else X.No_Element);

      function Has (Item : X.Element; Name : String) return Boolean is
        (X.Is_Present (Child (Item, Name)));

      --  The trimmed text of Item's child Name, or "".
      function Value_Of (Item : X.Element; Name : String) return String is
        (if Has (Item, Name)
         then Trimmed (X.Text (Document, Child (Item, Name)))
         else "");

      function Number_Of (Item : X.Element; What : String) return Word;

      function Number_Of (Item : X.Element; What : String) return Word is
         Said : constant String := X.Text (Document, Item);
      begin
         if not Is_Number (Said) then
            Fail (Unsupported_Form,
                  What & " is """ & Trimmed (Said) & """, which is not a"
                  & " number refine svd reads: decimal, 0x hexadecimal or"
                  & " # binary, without a multiplier",
                  Item, At_Text => True);
         end if;
         return Number (Said);
      end Number_Of;

      function Child_Number
        (Item : X.Element; Name, What : String) return Word
      is (Number_Of (Child (Item, Name), What));

      function Lookup_Peripheral (Name : String) return X.Element;

      function Lookup_Peripheral (Name : String) return X.Element is
         Current : X.Element :=
           (if Has (Device, "peripherals")
            then X.First_Child (Document, Child (Device, "peripherals"))
            else X.No_Element);
      begin
         while X.Is_Present (Current) loop
            if X.Name (Document, Current) = "peripheral"
              and then Value_Of (Current, "name") = Name
            then
               return Current;
            end if;
            Current := X.Next_Sibling (Document, Current);
         end loop;
         return X.No_Element;
      end Lookup_Peripheral;

      --  Each name a module declares, so that two vendor names that
      --  normalize to one are refused rather than declared twice.
      Declared : Name_Sets.Set;

      procedure Declare_Name (Name : String; Source : X.Element);

      procedure Declare_Name (Name : String; Source : X.Element) is
      begin
         if Declared.Contains (Name) then
            Fail (Inconsistent_Device,
                  "two of the SVD's names become the one Landin name "
                  & Name & " once lowercased and joined", Source);
         end if;
         Declared.Insert (Name);
      end Declare_Name;

      Manifest_Entries : Output_Vectors.Vector;

      procedure Add (Path, Content : String; In_Manifest : Boolean);

      procedure Add (Path, Content : String; In_Manifest : Boolean) is
         Whole : constant String :=
           (if In_Manifest then Under (US.To_String (Chosen.Modules), Path)
            else Path);
      begin
         for Existing of Made.Outputs loop
            if US.To_String (Existing.Path) = Whole then
               Fail (Inconsistent_Device,
                     "two outputs are both written to " & Whole);
            end if;
         end loop;
         Made.Outputs.Append
           (Output'(Path => US.To_Unbounded_String (Whole),
             Content => US.To_Unbounded_String (Content)));
         if In_Manifest then
            Manifest_Entries.Append
              (Output'(Path => US.To_Unbounded_String (Path),
                Content => US.To_Unbounded_String (Sha256 (Content))));
         end if;
      end Add;

      --  The module of the peripheral being projected, line by line.
      Lines : US.Unbounded_String;

      procedure Line (Text : String);

      procedure Line (Text : String) is
      begin
         US.Append (Lines, Text & LF);
      end Line;

      --  A property's element, from the register, its peripheral, the
      --  peripheral that one is derived from, or the device.
      function Inherited
        (Property, Key : String; Register, Instance, Template : X.Element)
         return X.Element;

      function Inherited
        (Property, Key : String; Register, Instance, Template : X.Element)
         return X.Element is
      begin
         if Has (Register, Property) then
            return Child (Register, Property);
         elsif Has (Instance, Property) then
            return Child (Instance, Property);
         elsif Has (Template, Property) then
            return Child (Template, Property);
         elsif Has (Device, Property) then
            return Child (Device, Property);
         end if;
         Fail (Inconsistent_Device, "the SVD gives " & Key & " no "
               & Property & ", at the register, its peripheral or the"
               & " device", Register);
      end Inherited;

      --  Where a field lies: its bitRange, its bitOffset and bitWidth, or
      --  its lsb and msb.
      procedure Field_Bits
        (Field : X.Element; Where : String; Low, High : out Natural);

      procedure Field_Bits
        (Field : X.Element; Where : String; Low, High : out Natural) is
      begin
         Low := 0;
         High := 0;
         if Has (Field, "bitRange") then
            declare
               Said : constant String := Value_Of (Field, "bitRange");
               Colon : Natural := 0;
               function All_Digits (Part : String) return Boolean is
                 (Part'Length in 1 .. 2
                  and then (for all C of Part => C in '0' .. '9'));
            begin
               for Index in Said'Range loop
                  if Said (Index) = ':' then
                     Colon := Index;
                  end if;
               end loop;
               if Said'Length < 5 or else Colon = 0
                 or else Said (Said'First) /= '['
                 or else Said (Said'Last) /= ']'
                 or else not All_Digits (Said (Said'First + 1 .. Colon - 1))
                 or else not All_Digits (Said (Colon + 1 .. Said'Last - 1))
               then
                  Fail (Unsupported_Form, Where & "'s bitRange is not"
                        & " [HIGH:LOW]", Child (Field, "bitRange"),
                        At_Text => True);
               end if;
               High := Natural'Value (Said (Said'First + 1 .. Colon - 1));
               Low := Natural'Value (Said (Colon + 1 .. Said'Last - 1));
            end;
         elsif Has (Field, "bitOffset") and then Has (Field, "bitWidth") then
            declare
               First_Bit : constant Word :=
                 Child_Number (Field, "bitOffset", Where & "'s bitOffset");
               Count : constant Word :=
                 Child_Number (Field, "bitWidth", Where & "'s bitWidth");
            begin
               if Count = 0 or else First_Bit + Count > 32 then
                  Fail (Inconsistent_Device, Where & " lies outside its"
                        & " 32-bit register", Field);
               end if;
               Low := Natural (First_Bit);
               High := Natural (First_Bit + Count - 1);
            end;
         elsif Has (Field, "lsb") and then Has (Field, "msb") then
            declare
               Least : constant Word :=
                 Child_Number (Field, "lsb", Where & "'s lsb");
               Most : constant Word :=
                 Child_Number (Field, "msb", Where & "'s msb");
            begin
               if Most > 31 or else Least > Most then
                  Fail (Inconsistent_Device, Where & " lies outside its"
                        & " 32-bit register", Field);
               end if;
               Low := Natural (Least);
               High := Natural (Most);
            end;
         else
            Fail (Inconsistent_Device, Where & " gives no bitRange,"
                  & " bitOffset and bitWidth, or lsb and msb", Field);
         end if;
         if Low > High or else High > 31 then
            Fail (Inconsistent_Device, Where & " lies outside its 32-bit"
                  & " register", Field);
         end if;
      end Field_Bits;

      --  Every enumeratedValue of every enumeratedValues block, in order.
      procedure Read_Encodings
        (Field : X.Element; Where : String; Width : Natural;
         Values : out Encoding_Vectors.Vector);

      procedure Read_Encodings
        (Field : X.Element; Where : String; Width : Natural;
         Values : out Encoding_Vectors.Vector)
      is
         Block : X.Element := X.First_Child (Document, Field);
      begin
         Values.Clear;
         while X.Is_Present (Block) loop
            if X.Name (Document, Block) = "enumeratedValues" then
               if X.Attribute_Count (Document, Block) /= 0 then
                  Fail (Unsupported_Form, Where & "'s enumeratedValues"
                        & " are derived from others, which is not"
                        & " resolved", Block);
               end if;
               declare
                  Item : X.Element := X.First_Child (Document, Block);
               begin
                  while X.Is_Present (Item) loop
                     if X.Name (Document, Item) = "enumeratedValue" then
                        if Has (Item, "isDefault") then
                           Fail (Unsupported_Form, Where & " has a default"
                                 & " enumerated value, which is not read",
                                 Item);
                        elsif not Has (Item, "name")
                          or else not Has (Item, "value")
                        then
                           Fail (Inconsistent_Device, Where & " has an"
                                 & " enumerated value without a name and a"
                                 & " value", Item);
                        end if;
                        Values.Append
                          (Encoding'(Name => US.To_Unbounded_String
                              (Value_Of (Item, "name")),
                            Value => Child_Number
                              (Item, "value",
                               Where & "'s enumerated value")));
                     end if;
                     Item := X.Next_Sibling (Document, Item);
                  end loop;
               end;
            end if;
            Block := X.Next_Sibling (Document, Block);
         end loop;
         for A in 1 .. Values.Last_Index loop
            if Values (A).Value >= Interfaces.Shift_Left (1, Width) then
               Fail (Inconsistent_Device, Where & "'s enumerated value "
                     & US.To_String (Values (A).Name)
                     & " does not fit its field", Field);
            end if;
            for B in A + 1 .. Values.Last_Index loop
               if Values (A).Value = Values (B).Value then
                  Fail (Inconsistent_Device, Where & " encodes "
                        & Decimal (Values (A).Value) & " twice", Field);
               end if;
            end loop;
         end loop;
      end Read_Encodings;

      type Owners is array (1 .. 4) of X.Element;

      --  What a register's fields have made so far.
      type Register_State is record
         Key : US.Unbounded_String;
         Reg : US.Unbounded_String;
         Register_Access : US.Unbounded_String;
         Named_Mask : Word := 0;
         Field_Lines : US.Unbounded_String;
         Field_Names : Name_Sets.Set;
         Field_Count : Natural := 0;
         --  Every field the SVD gives, by its vendor name, and those a
         --  correction omits, with the correction's source.
         Seen : Name_Sets.Set;
         Omitted : P.Text_Vectors.Vector;
         Omitted_Sources : P.Text_Vectors.Vector;
      end record;

      procedure Project_Field
        (Field : X.Element; State : in out Register_State);

      procedure Project_Field
        (Field : X.Element; State : in out Register_State)
      is
         Key : constant String := US.To_String (State.Key);
         Reg : constant String := US.To_String (State.Reg);
         Field_Name : constant String := Value_Of (Field, "name");
         Where : constant String := Key & "." & Field_Name;
         Spelling : constant String := "f_" & Lowered (Field_Name);
         Low, High : Natural;
         Bits : Word;
         Values : Encoding_Vectors.Vector;
         Numeric : constant Boolean := P.Is_Numeric (Chosen, Where);
         Field_Type : US.Unbounded_String;
         Correction : constant Natural := P.Correction_Of (Chosen, Where);
         Svd_Low, Svd_High : Natural := 0;
         Unreadable : Boolean;
      begin
         if not State.Seen.Contains (Field_Name) then
            State.Seen.Insert (Field_Name);
         end if;
         if Correction /= 0 and then Chosen.Fields (Correction).Omit then
            State.Omitted.Append (Field_Name);
            State.Omitted_Sources.Append
              (US.To_String (Chosen.Fields (Correction).Source));
            return;
         end if;
         State.Field_Count := State.Field_Count + 1;
         if X.Attribute_Count (Document, Field) /= 0 then
            Fail (Unsupported_Form, Where & " has the attribute "
                  & X.Attribute_Name (Document, Field, 1) & "; a field"
                  & " derived from another is not resolved", Field);
         elsif Has (Field, "dim") then
            Fail (Unsupported_Form, Where & " is an array (dim), which is"
                  & " not expanded", Child (Field, "dim"));
         elsif not Is_Vendor_Name (Field_Name) then
            Fail (Unsupported_Form, "the field name """ & Field_Name
                  & """ of " & Key & " is not an ASCII letter followed by"
                  & " letters, digits and underscores", Field);
         elsif State.Field_Names.Contains (Spelling) then
            Fail (Inconsistent_Device, "two of " & Key & "'s fields are"
                  & " both " & Spelling & " once lowercased", Field);
         end if;
         State.Field_Names.Insert (Spelling);
         Field_Bits (Field, Where, Low, High);
         if Correction /= 0 then
            Svd_Low := Low;
            Svd_High := High;
            Low := Chosen.Fields (Correction).Low;
            High := Chosen.Fields (Correction).High;
         end if;
         Bits := Interfaces.Shift_Left
           (Interfaces.Shift_Left (1, High - Low + 1) - 1, Low);
         if (State.Named_Mask and Bits) /= 0 then
            Fail (Inconsistent_Device, Where & " overlaps another of its"
                  & " fields", Field);
         end if;
         State.Named_Mask := State.Named_Mask or Bits;
         Read_Encodings (Field, Where, High - Low + 1, Values);
         Field_Type := US.To_Unbounded_String
           ("u" & Decimal (Word (High - Low + 1)));
         if not Numeric then
            Unreadable := False;
            for Value of Values loop
               if not Is_Vendor_Name (US.To_String (Value.Name)) then
                  US.Append
                    (Unnamed, (if Unnamed_Count = 0 then "" else ", ")
                     & Where & " (""" & US.To_String (Value.Name) & """)");
                  Unnamed_Count := Unnamed_Count + 1;
                  if not X.Is_Present (First_Unnamed) then
                     First_Unnamed := Field;
                  end if;
                  Unreadable := True;
                  exit;
               end if;
            end loop;
            --  Read as a number meanwhile; the refusal comes once every
            --  selected field has been read.
            if Unreadable then
               Values.Clear;
            end if;
         end if;
         if not Values.Is_Empty and then not Numeric then
            declare
               Type_Name : constant String :=
                 Reg & "_" & Lowered (Field_Name) & "_value";
               Alternatives : US.Unbounded_String;
            begin
               for Value of Values loop
                  declare
                     Said : constant String := US.To_String (Value.Name);
                     Atom : constant String :=
                       Reg & "_" & Lowered (Field_Name) & "_"
                       & Lowered (Said);
                  begin
                     Declare_Name (Atom, Field);
                     Line ("public " & Atom & ": atom");
                     US.Append (Alternatives,
                                (if US.Length (Alternatives) = 0 then ""
                                 else " | ")
                                & Atom & " = " & Decimal (Value.Value));
                  end;
               end loop;
               Declare_Name (Type_Name, Field);
               Line ("public " & Type_Name & ": type = "
                     & US.To_String (Field_Type) & " ("
                     & US.To_String (Alternatives) & ")");
               Field_Type := US.To_Unbounded_String (Type_Name);
            end;
         end if;
         US.Append (State.Field_Lines,
                    "    " & Spelling & ": " & US.To_String (Field_Type)
                    & " at " & Decimal (Word (Low)) & ".."
                    & Decimal (Word (High)) & LF);
         Open (Rows, In_Object);
         Member (Rows, "access");
         if Has (Field, "access") then
            String_Value (Rows, Value_Of (Field, "access"));
         elsif US.Length (State.Register_Access) > 0 then
            String_Value (Rows, US.To_String (State.Register_Access));
         else
            Fail (Inconsistent_Device, "the SVD gives " & Where & " no"
                  & " access, at the field, its register, its peripheral or"
                  & " the device", Field);
         end if;
         if Correction /= 0 then
            Member (Rows, "correction");
            Open (Rows, In_Object);
            Member (Rows, "source");
            String_Value
              (Rows, US.To_String (Chosen.Fields (Correction).Source));
            Member (Rows, "svd_high");
            Number_Value (Rows, Word (Svd_High));
            Member (Rows, "svd_low");
            Number_Value (Rows, Word (Svd_Low));
            Close (Rows, In_Object);
         end if;
         Member (Rows, "encodings");
         Open (Rows, In_Array);
         for Value of Values loop
            Open (Rows, In_Array);
            String_Value (Rows, US.To_String (Value.Name));
            Number_Value (Rows, Value.Value);
            Close (Rows, In_Array);
         end loop;
         Close (Rows, In_Array);
         Member (Rows, "high");
         Number_Value (Rows, Word (High));
         Member (Rows, "low");
         Number_Value (Rows, Word (Low));
         Member (Rows, "mask");
         Number_Value (Rows, Bits);
         Member (Rows, "modified_write");
         if Has (Field, "modifiedWriteValues") then
            String_Value (Rows, Value_Of (Field, "modifiedWriteValues"));
         else
            Raw (Rows, "null");
         end if;
         Member (Rows, "name");
         String_Value (Rows, Field_Name);
         Member (Rows, "read_action");
         if Has (Field, "readAction") then
            String_Value (Rows, Value_Of (Field, "readAction"));
         else
            Raw (Rows, "null");
         end if;
         Member (Rows, "representation");
         String_Value (Rows, (if Numeric or else Values.Is_Empty
                              then "unsigned" else "encoded"));
         Close (Rows, In_Object);
      end Project_Field;

      --  The selected register's element in Template, refusing what it
      --  cannot find by name: a register of a cluster or an array.
      function Find_Register
        (Template : X.Element; Name, Key : String) return X.Element;

      function Find_Register
        (Template : X.Element; Name, Key : String) return X.Element
      is
         Found : X.Element := X.No_Element;
         In_Cluster : Boolean := False;
         Arrays : Natural := 0;

         procedure Search_Cluster (Cluster : X.Element);

         procedure Search_Cluster (Cluster : X.Element) is
            Inner : X.Element := X.First_Child (Document, Cluster);
         begin
            while X.Is_Present (Inner) loop
               if X.Name (Document, Inner) = "register"
                 and then Value_Of (Inner, "name") = Name
               then
                  In_Cluster := True;
               elsif X.Name (Document, Inner) = "cluster" then
                  Search_Cluster (Inner);
               end if;
               Inner := X.Next_Sibling (Document, Inner);
            end loop;
         end Search_Cluster;

         Current : X.Element :=
           (if Has (Template, "registers")
            then X.First_Child (Document, Child (Template, "registers"))
            else X.No_Element);
      begin
         while X.Is_Present (Current) loop
            if X.Name (Document, Current) = "register" then
               if not X.Is_Present (Found)
                 and then Value_Of (Current, "name") = Name
               then
                  Found := Current;
               end if;
               if Has (Current, "dim") then
                  Arrays := Arrays + 1;
               end if;
            elsif X.Name (Document, Current) = "cluster" then
               Search_Cluster (Current);
            end if;
            Current := X.Next_Sibling (Document, Current);
         end loop;
         if not X.Is_Present (Found) then
            if In_Cluster then
               Fail (Unsupported_Form, Key & " is in a cluster, which"
                     & " refine svd does not expand", Template);
            end if;
            Fail (Not_In_Svd, "the policy selects " & Key & ", which the"
                  & " SVD does not have"
                  & (if Arrays > 0
                     then "; its arrays (dim) are not expanded, so a"
                       & " register of one is not found by name"
                     else ""), Template);
         end if;
         return Found;
      end Find_Register;

      procedure Project_Register
        (Policy : P.Register_Choice;
         Instance, Template : X.Element;
         Parent_Name : String;
         Base : Word);

      procedure Project_Register
        (Policy : P.Register_Choice;
         Instance, Template : X.Element;
         Parent_Name : String;
         Base : Word)
      is
         Register_Name : constant String := US.To_String (Policy.Register);
         Key : constant String :=
           US.To_String (Policy.Peripheral) & "." & Register_Name;
         Reg : constant String := Lowered (Register_Name);
         Element : constant X.Element :=
           Find_Register (Template, Register_Name, Key);
         Offset, Width, Reset_Value, Reset_Mask : Word;
         Known_Mask, Known_Value, Write_Mask : Word;
         Alternate : US.Unbounded_String;
         State : Register_State;

         procedure Refuse_Form (Form, Why : String);

         procedure Refuse_Form (Form, Why : String) is
         begin
            if Has (Element, Form) then
               Fail (Unsupported_Form, Key & " has " & Form & Why,
                     Child (Element, Form));
            end if;
         end Refuse_Form;
      begin
         if X.Attribute_Count (Document, Element) /= 0 then
            Fail (Unsupported_Form, Key & " has the attribute "
                  & X.Attribute_Name (Document, Element, 1) & "; a register"
                  & " derived from another is not resolved", Element);
         end if;
         Refuse_Form ("dim", ", an array, which is not expanded");
         Refuse_Form ("alternateGroup", ", which refine svd does not read");
         Width := Number_Of
           (Inherited ("size", Key, Element, Instance, Template),
            Key & "'s size");
         if Width /= 32 then
            Fail (Unsupported_Form, Key & " is " & Decimal (Width)
                  & " bits wide; refine svd generates 32-bit registers",
                  Inherited ("size", Key, Element, Instance, Template));
         elsif not Has (Element, "addressOffset") then
            Fail (Inconsistent_Device, Key & " has no addressOffset",
                  Element);
         end if;
         Offset := Child_Number (Element, "addressOffset",
                                 Key & "'s addressOffset");
         if Offset mod 4 /= 0 or else Base + Offset > 16#FFFF_FFFF# then
            Fail (Inconsistent_Device, Key & "'s address is not a"
                  & " word-aligned 32-bit address",
                  Child (Element, "addressOffset"));
         end if;
         if Has (Element, "alternateRegister") then
            Alternate := US.To_Unbounded_String
              (Value_Of (Element, "alternateRegister"));
            declare
               Other : constant X.Element :=
                 Find_Register (Template, US.To_String (Alternate),
                                Key & "'s alternate");
            begin
               if not Has (Other, "addressOffset")
                 or else Child_Number (Other, "addressOffset",
                                       "an alternate's addressOffset")
                   /= Offset
               then
                  Fail (Inconsistent_Device, Key & " is an alternate of "
                        & US.To_String (Alternate) & ", which is at"
                        & " another address",
                        Child (Element, "alternateRegister"));
               end if;
            end;
         end if;
         Reset_Value := Number_Of
           (Inherited ("resetValue", Key, Element, Instance, Template),
            Key & "'s resetValue");
         Reset_Mask := Number_Of
           (Inherited ("resetMask", Key, Element, Instance, Template),
            Key & "'s resetMask");
         State.Key := US.To_Unbounded_String (Key);
         State.Reg := US.To_Unbounded_String (Reg);
         --  A register may leave its access to its fields, which must
         --  then each say theirs.
         for Owner of Owners'(Element, Instance, Template, Device) loop
            if US.Length (State.Register_Access) = 0
              and then Has (Owner, "access")
            then
               State.Register_Access := US.To_Unbounded_String
                 (Value_Of (Owner, "access"));
            end if;
         end loop;
         Open (Rows, In_Object);
         Member (Rows, "address");
         Number_Value (Rows, Base + Offset);
         Member (Rows, "alignment");
         Number_Value (Rows, 4);
         if US.Length (Alternate) > 0 then
            Member (Rows, "alternate_register");
            String_Value (Rows, US.To_String (Alternate));
         end if;
         Member (Rows, "derived_from");
         if Parent_Name /= "" then
            String_Value (Rows, Parent_Name);
         else
            Raw (Rows, "null");
         end if;
         Member (Rows, "fields");
         Open (Rows, In_Array);
         declare
            Container : X.Element := X.First_Child (Document, Element);
            Field : X.Element;
         begin
            while X.Is_Present (Container) loop
               if X.Name (Document, Container) = "fields" then
                  Field := X.First_Child (Document, Container);
                  while X.Is_Present (Field) loop
                     if X.Name (Document, Field) = "field" then
                        Project_Field (Field, State);
                     end if;
                     Field := X.Next_Sibling (Document, Field);
                  end loop;
               end if;
               Container := X.Next_Sibling (Document, Container);
            end loop;
         end;
         Close (Rows, In_Array);
         if State.Field_Count = 0 then
            Fail (Inconsistent_Device, "the selected register " & Key
                  & " has no fields", Element);
         end if;
         --  The SVD claims reset knowledge by inheritance even of reserved
         --  bits; what is promised is only that of named fields, or what a
         --  reviewer says instead.
         Known_Mask := (if Policy.Has_Reset_Mask then Policy.Reset_Mask
                        else State.Named_Mask and Reset_Mask);
         if (Known_Mask and not State.Named_Mask) /= 0 then
            Fail (Invalid_Policy, "reset_mask_overrides." & Key & " claims"
                  & " reset knowledge outside the register's named fields");
         end if;
         Known_Value := (if Policy.Has_Reset_Value then Policy.Reset_Value
                         else Reset_Value) and Known_Mask;
         Member (Rows, "known_reset_mask");
         Number_Value (Rows, Known_Mask);
         Member (Rows, "known_reset_value");
         Number_Value (Rows, Known_Value);
         Member (Rows, "named_mask");
         Number_Value (Rows, State.Named_Mask);
         Member (Rows, "offset");
         Number_Value (Rows, Offset);
         if not State.Omitted.Is_Empty then
            Member (Rows, "omitted_fields");
            Open (Rows, In_Array);
            for Index in 1 .. State.Omitted.Last_Index loop
               Open (Rows, In_Object);
               Member (Rows, "name");
               String_Value (Rows, State.Omitted (Index));
               Member (Rows, "source");
               String_Value (Rows, State.Omitted_Sources (Index));
               Close (Rows, In_Object);
            end loop;
            Close (Rows, In_Array);
         end if;
         for Correction of Chosen.Fields loop
            declare
               Named : constant String := US.To_String (Correction.Key);
            begin
               if Named'Length > Key'Length + 1
                 and then Named (Named'First .. Named'First + Key'Length)
                   = Key & "."
                 and then not State.Seen.Contains
                   (Named (Named'First + Key'Length + 1 .. Named'Last))
               then
                  Fail (Not_In_Svd, "field_corrections." & Named
                        & " names a field " & Key & " does not have",
                        Element);
               end if;
            end;
         end loop;
         Member (Rows, "policy");
         Open (Rows, In_Object);
         Member (Rows, "read");
         String_Value (Rows, (case Policy.Read is
                                 when P.Normal_Read => "normal",
                                 when P.Modify_Read => "modify",
                                 when P.Refused_Read => "refused"));
         Member (Rows, "reserved");
         String_Value (Rows, (case Policy.Reserved is
                                 when P.Write_Zero => "zero",
                                 when P.Preserve => "preserve"));
         Member (Rows, "write");
         String_Value (Rows, (case Policy.Write is
                                 when P.Normal_Write => "normal",
                                 when P.One_Clears_Write => "one_clears",
                                 when P.Refused_Write => "refused"));
         if Policy.Has_Write_Mask then
            Member (Rows, "write_mask");
            String_Value (Rows, US.To_String (Policy.Write_Mask_Text));
         end if;
         Close (Rows, In_Object);
         Member (Rows, "register_access");
         if US.Length (State.Register_Access) > 0 then
            String_Value (Rows, US.To_String (State.Register_Access));
         else
            Raw (Rows, "null");
         end if;
         if Policy.Has_Reset_Value then
            Member (Rows, "reset_correction");
            Open (Rows, In_Object);
            Member (Rows, "source");
            String_Value (Rows, US.To_String (Policy.Reset_Source));
            Member (Rows, "value");
            Number_Value (Rows, Policy.Reset_Value);
            Close (Rows, In_Object);
         end if;
         Member (Rows, "source");
         String_Value (Rows, Key);
         Member (Rows, "svd_reset_mask");
         Number_Value (Rows, Reset_Mask);
         Member (Rows, "svd_reset_value");
         Number_Value (Rows, Reset_Value);
         Member (Rows, "width");
         Number_Value (Rows, Width);
         Close (Rows, In_Object);
         Declare_Name (Reg & "_offset", Element);
         Declare_Name (Reg & "_address", Element);
         Declare_Name (Reg & "_named_mask", Element);
         Declare_Name (Reg & "_reset_mask", Element);
         Declare_Name (Reg & "_reset_value", Element);
         Declare_Name (Reg & "_image", Element);
         Declare_Name (Reg & "_decode", Element);
         Declare_Name (Reg & "_encode", Element);
         Declare_Name (Reg & "_read", Element);
         Declare_Name (Reg & "_write", Element);
         Line ("public " & Reg & "_offset: usize = " & Hex (Offset));
         Line ("public " & Reg & "_address: usize = " & Hex8 (Base + Offset));
         Line ("public " & Reg & "_named_mask: u32 = "
               & Hex8 (State.Named_Mask));
         Line ("public " & Reg & "_reset_mask: u32 = " & Hex8 (Known_Mask));
         Line ("public " & Reg & "_reset_value: u32 = "
               & Hex8 (Known_Value));
         Line ("public " & Reg & "_image: type = layout(packed, u32) struct");
         US.Append (Lines, State.Field_Lines);
         Line ("end " & Reg & "_image");
         Line ("");
         Line ("public " & Reg & "_decode: (raw: u32) -> (image: " & Reg
               & "_image) =");
         Line ("    image = zeroed");
         Line ("    bits: ptr mut u32 = ptr(usize(addr image))");
         Line ("    bits.val = raw");
         Line ("end " & Reg & "_decode");
         Line ("");
         Line ("public " & Reg & "_encode: (image: " & Reg
               & "_image) -> (raw: u32) =");
         Line ("    bits: ptr u32 = ptr(usize(addr image))");
         Line ("    raw = bits.val");
         Line ("end " & Reg & "_encode");
         Line ("");
         if Policy.Read /= P.Refused_Read then
            --  modify is a FIFO's consumption, not a clear on read: one
            --  volatile load reads it exactly once.
            Line ("public " & Reg & "_read: (device_base: usize) -> (raw:"
                  & " u32) =");
            Line ("    port: ptr u32 = ptr(device_base + " & Reg
                  & "_offset)");
            Line ("    raw = " & (if Policy.Read = P.Modify_Read
                                  then "compiler.volatile_load(port)"
                                  else "compiler.register_read(port,"
                                    & " compiler.normal_read)"));
            Line ("end " & Reg & "_read");
            Line ("");
         end if;
         if Policy.Write /= P.Refused_Write then
            Write_Mask := (if Policy.Has_Write_Mask then Policy.Write_Mask
                           else State.Named_Mask);
            if (Write_Mask and not State.Named_Mask) /= 0 then
               Fail (Invalid_Policy, "policies." & Key & ".write_mask"
                     & " admits bits outside the register's named fields");
            end if;
            Line ("public " & Reg & "_write: (device_base: usize, raw: u32)"
                  & " -> none =");
            Line ("    port: ptr mut u32 = ptr(device_base + " & Reg
                  & "_offset)");
            Line ("    compiler.register_write(port, raw, compiler."
                  & (if Policy.Write = P.One_Clears_Write then "one_clears"
                     else "normal_write") & ",");
            Line ("                            compiler."
                  & (if Policy.Reserved = P.Write_Zero then "write_zero"
                     else "preserve")
                  & ", " & Hex8 (Write_Mask) & ")");
            Line ("end " & Reg & "_write");
            Line ("");
         end if;
      end Project_Register;

      procedure Project_Peripheral (Choice : P.Peripheral_Choice);

      procedure Project_Peripheral (Choice : P.Peripheral_Choice) is
         Peripheral_Name : constant String := US.To_String (Choice.Name);
         Instance : constant X.Element := Lookup_Peripheral (Peripheral_Name);
         Template : X.Element := Instance;
         Parent_Name : US.Unbounded_String;
         Base : Word;
      begin
         Declared.Clear;
         Lines := US.Null_Unbounded_String;
         if not X.Is_Present (Instance) then
            Fail (Not_In_Svd, "the policy selects the peripheral "
                  & Peripheral_Name & ", which the SVD does not have");
         elsif Has (Instance, "dim") then
            Fail (Unsupported_Form, "the peripheral " & Peripheral_Name
                  & " is an array (dim), which refine svd does not expand",
                  Child (Instance, "dim"));
         end if;
         for Position in 1 .. X.Attribute_Count (Document, Instance) loop
            if X.Attribute_Name (Document, Instance, Position)
              /= "derivedFrom"
            then
               Fail (Unsupported_Form, "the peripheral " & Peripheral_Name
                     & " has the attribute "
                     & X.Attribute_Name (Document, Instance, Position)
                     & ", which refine svd does not read", Instance);
            end if;
         end loop;
         if X.Has_Attribute (Document, Instance, "derivedFrom") then
            Parent_Name := US.To_Unbounded_String
              (Trimmed (X.Attribute (Document, Instance, "derivedFrom")));
            Template := Lookup_Peripheral (US.To_String (Parent_Name));
            if not X.Is_Present (Template) then
               Fail (Inconsistent_Device, Peripheral_Name
                     & " is derived from " & US.To_String (Parent_Name)
                     & ", which the SVD does not have", Instance);
            elsif X.Has_Attribute (Document, Template, "derivedFrom") then
               Fail (Unsupported_Form, Peripheral_Name & " is derived from "
                     & US.To_String (Parent_Name) & ", which is itself"
                     & " derived; refine svd resolves one derivation",
                     Instance);
            elsif Has (Instance, "registers") then
               Fail (Unsupported_Form, Peripheral_Name & " is derived from "
                     & US.To_String (Parent_Name) & " and gives registers"
                     & " of its own, which refine svd does not merge",
                     Child (Instance, "registers"));
            elsif Has (Template, "dim") then
               Fail (Unsupported_Form, "the peripheral "
                     & US.To_String (Parent_Name) & " is an array (dim),"
                     & " which refine svd does not expand",
                     Child (Template, "dim"));
            end if;
         end if;
         if not Has (Instance, "baseAddress") then
            Fail (Inconsistent_Device, "the peripheral " & Peripheral_Name
                  & " has no baseAddress", Instance);
         end if;
         Base := Child_Number (Instance, "baseAddress",
                               Peripheral_Name & "'s baseAddress");
         if Base > 16#FFFF_FFFF# then
            Fail (Inconsistent_Device, Peripheral_Name & "'s baseAddress"
                  & " is beyond 32 bits", Child (Instance, "baseAddress"));
         end if;
         for Notice of Chosen.Notice loop
            Line ("-- " & Notice);
         end loop;
         Line ("-- Reset metadata performs no initialization."
               & " No device RMW is implicit.");
         Line ("compiler.assert(compiler.byte_order == little)");
         Line ("compiler.assert(sizeof u32 == 4 and alignof u32 == 4)");
         Line ("public base: usize = " & Hex8 (Base));
         Line ("");
         Declare_Name ("base", Instance);
         for Index in Choice.First .. Choice.Last loop
            Project_Register (Chosen.Registers (Index), Instance, Template,
                              US.To_String (Parent_Name), Base);
         end loop;
         --  The lines were joined by LF, the last of them empty.
         Add (US.To_String (Chosen.Prefix) & "/" & Lowered (Peripheral_Name)
              & "/device.ldn", US.Slice (Lines, 1, US.Length (Lines) - 1),
              In_Manifest => True);
      end Project_Peripheral;

      procedure Project_Interrupts;

      --  D542's generated half of the description, from the SVD alone.
      procedure Project_Interrupts is
         Text : US.Unbounded_String;
         Pairs : Interrupt_Vectors.Vector;
         Cpu : constant X.Element := Child (Device, "cpu");
         Name : constant String := Value_Of (Device, "name");
         Vendor : constant String := Value_Of (Device, "vendor");
         Version : constant String := Value_Of (Device, "version");
         Clauses : US.Unbounded_String;
         Notes : US.Unbounded_String;
         Declared_Count : Word := 0;
         Highest : Word := 0;

         procedure Line (Item : String);

         procedure Line (Item : String) is
         begin
            if (for some C of Item =>
                  Character'Pos (C) < 32 or else Character'Pos (C) > 126)
            then
               Fail (Unsupported_Form, "interrupts.ldn is ASCII, and the"
                     & " SVD's name, vendor, version, licence or interrupt"
                     & " names would put a byte outside it there", Device);
            end if;
            US.Append (Text, Item & LF);
         end Line;

         Core : constant String := Value_Of (Cpu, "name");
      begin
         if Vendor /= "" then
            US.Append (Clauses, "vendor " & Vendor);
         end if;
         if Version /= "" then
            US.Append (Clauses, (if Vendor /= "" then ", " else "")
                       & "version " & Version);
         end if;
         Line ("-- Interrupts of the " & Name & ", from its SVD"
               & (if US.Length (Clauses) > 0
                  then ": " & US.To_String (Clauses) else "") & ".");
         Line ("-- SVD SHA-256 " & Sha256 (Svd_Text) & ".");
         if Has (Device, "licenseText") then
            declare
               Licence : constant String :=
                 X.Text (Document, Child (Device, "licenseText"));
               First : Integer := Licence'First;
            begin
               for Index in Licence'First .. Licence'Last + 1 loop
                  if Index > Licence'Last or else Licence (Index) = LF then
                     declare
                        Part : constant String :=
                          Trimmed (Licence (First .. Index - 1));
                     begin
                        if Part /= "" then
                           Line ("-- " & Part);
                        end if;
                     end;
                     First := Index + 1;
                  end if;
               end loop;
            end;
         end if;
         if not X.Is_Present (Cpu) then
            Fail (Inconsistent_Device, "the SVD names no cpu, so the"
                  & " description's core is not known", Device);
         elsif Core not in "CM0" | "CM0PLUS" | "CM3" | "CM4" | "CM7" then
            Fail (Unsupported_Form, "the SVD's cpu is " & Core & ", which"
                  & " is none of CM0, CM0PLUS, CM3, CM4 and CM7",
                  Child (Cpu, "name"));
         end if;
         if Has (Cpu, "deviceNumInterrupts") then
            Declared_Count := Child_Number
              (Cpu, "deviceNumInterrupts", "the cpu's deviceNumInterrupts");
         end if;
         declare
            Current : X.Element :=
              (if Has (Device, "peripherals")
               then X.First_Child (Document, Child (Device, "peripherals"))
               else X.No_Element);
         begin
            while X.Is_Present (Current) loop
               if X.Name (Document, Current) = "peripheral" then
                  declare
                     Item : X.Element := X.First_Child (Document, Current);
                  begin
                     while X.Is_Present (Item) loop
                        if X.Name (Document, Item) = "interrupt" then
                           declare
                              Pair : constant Interrupt :=
                                (Value => Child_Number
                                   (Item, "value", "an interrupt's value"),
                                 Name => US.To_Unbounded_String
                                   (Value_Of (Item, "name")));
                              Said : constant String :=
                                US.To_String (Pair.Name);
                              Place : Natural := 0;
                           begin
                              if not Is_Vendor_Name (Said)
                                or else Said'Length > 64
                              then
                                 Fail (Unsupported_Form, "the interrupt"
                                       & " name """ & Said & """ is not an"
                                       & " ASCII letter and then at most 63"
                                       & " letters, digits and underscores",
                                       Item);
                              elsif Pair.Value > 16#FFFF# then
                                 Fail (Inconsistent_Device, "the interrupt "
                                       & Said & " is numbered beyond any"
                                       & " vector table", Item);
                              end if;
                              --  Kept in order of value, then of name.
                              for Index in 1 .. Pairs.Last_Index loop
                                 if Pairs (Index).Value = Pair.Value
                                   and then Pairs (Index).Name = Pair.Name
                                 then
                                    Place := Natural'Last;
                                    exit;
                                 elsif Pairs (Index).Value > Pair.Value
                                   or else (Pairs (Index).Value = Pair.Value
                                            and then US.To_String
                                              (Pairs (Index).Name) > Said)
                                 then
                                    Place := Index;
                                    exit;
                                 end if;
                              end loop;
                              if Place = 0 then
                                 Pairs.Append (Pair);
                              elsif Place /= Natural'Last then
                                 Pairs.Insert (Place, Pair);
                              end if;
                           end;
                        end if;
                        Item := X.Next_Sibling (Document, Item);
                     end loop;
                  end;
               end if;
               Current := X.Next_Sibling (Document, Current);
            end loop;
         end;
         --  D542: the policy's reviewed corrections, each said in a line.
         for Correction of Chosen.Interrupts loop
            declare
               Named : constant String := US.To_String (Correction.Name);
               Source : constant String := US.To_String (Correction.Source);
               Where : constant String := "interrupt_corrections." & Named;
               Old : Interrupt_Vectors.Vector;
               Index : Positive := 1;
               Place : Positive;
               Olds : US.Unbounded_String;
            begin
               while Index <= Pairs.Last_Index loop
                  if Pairs (Index).Name = Correction.Name then
                     Old.Append (Pairs (Index));
                     Pairs.Delete (Index);
                  else
                     Index := Index + 1;
                  end if;
               end loop;
               for Pair of Old loop
                  US.Append (Olds, (if US.Length (Olds) = 0 then ""
                                    else " and ") & Decimal (Pair.Value));
               end loop;
               if Correction.Omit then
                  if Old.Is_Empty then
                     Fail (Not_In_Svd, Where & " removes an interrupt the SVD"
                           & " does not name");
                  end if;
                  US.Append (Notes, "-- The policy removes " & Named & " at "
                             & US.To_String (Olds) & ": " & Source & "." & LF);
               else
                  if Natural (Old.Length) = 1
                    and then Old.First_Element.Value = Correction.Value
                  then
                     Fail (Invalid_Policy, Where & " gives the value the SVD"
                           & " already gives it");
                  end if;
                  Place := Pairs.Last_Index + 1;
                  for At_Index in 1 .. Pairs.Last_Index loop
                     if Pairs (At_Index).Value = Correction.Value then
                        Fail (Invalid_Policy, Where & " numbers it "
                              & Decimal (Correction.Value) & ", which the SVD"
                              & " gives "
                              & US.To_String (Pairs (At_Index).Name)
                              & "; correct that one too");
                     elsif Pairs (At_Index).Value > Correction.Value
                       and then Place > Pairs.Last_Index
                     then
                        Place := At_Index;
                     end if;
                  end loop;
                  Pairs.Insert (Place, Interrupt'(Value => Correction.Value,
                                                   Name => Correction.Name));
                  US.Append (Notes, "-- The policy "
                             & (if Old.Is_Empty
                                then "adds " & Named & " at "
                                else "moves " & Named & " from "
                                  & US.To_String (Olds) & " to ")
                             & Decimal (Correction.Value) & ": " & Source
                             & "." & LF);
               end if;
            end;
         end loop;
         Line ("-- Generated from the SVD; memory.ldn beside it is written"
               & " by hand.");
         declare
            First : Positive := 1;
            Text_Of_Notes : constant String := US.To_String (Notes);
         begin
            for At_Index in Text_Of_Notes'Range loop
               if Text_Of_Notes (At_Index) = LF then
                  Line (Text_Of_Notes (First .. At_Index - 1));
                  First := At_Index + 1;
               end if;
            end loop;
         end;
         Line ("");
         if not Pairs.Is_Empty then
            Highest := Pairs.Last_Element.Value + 1;
         end if;
         Line ("compiler.device(""" & Lowered (Name) & """)");
         Line ("compiler.core("""
               & (if Core = "CM0" then "cortex-m0"
                  elsif Core = "CM0PLUS" then "cortex-m0plus"
                  elsif Core = "CM3" then "cortex-m3"
                  elsif Core = "CM4" then "cortex-m4"
                  else "cortex-m7") & """)");
         Line ("compiler.vectors("
               & Decimal (16 + Word'Max (Declared_Count, Highest)) & ")");
         for Pair of Pairs loop
            Line ("compiler.interrupt(""" & US.To_String (Pair.Name)
                  & """, " & Decimal (Pair.Value) & ")");
         end loop;
         Add (US.To_String (Chosen.Description) & "/interrupts.ldn",
              US.To_String (Text), In_Manifest => False);
      end Project_Interrupts;

   begin
      Made := (others => <>);
      P.Read (Policy_Text, Chosen, Problem);
      if Problem.Kind /= No_Fault then
         return;
      end if;
      Made.Modules := Chosen.Modules;
      Made.Manifest := US.To_Unbounded_String
        (Under (US.To_String (Chosen.Modules),
                US.To_String (Chosen.Manifest)));
      if Sha256 (Svd_Text) /= US.To_String (Chosen.Svd_Sha256) then
         Fail (Input_Mismatch, "the SVD's SHA-256 is " & Sha256 (Svd_Text)
               & ", and the policy was reviewed against "
               & US.To_String (Chosen.Svd_Sha256)
               & "; fetch the SVD it names, or review the policy against"
               & " this one and give its hash");
      end if;
      X.Parse (Document, Svd_Text);
      if not X.Ok (Document) then
         Problem :=
           (Kind => Malformed_Svd, Within => Svd_Input,
            Offset => X.Fault_At (Document), Has_Offset => True,
            Message => US.To_Unbounded_String
              ("the SVD is not XML refine svd reads: "
               & X.Fault (Document)));
         Made := (others => <>);
         return;
      end if;
      Device := X.Root (Document);
      if X.Name (Document, Device) /= "device" then
         Fail (Unsupported_Form, "the SVD's root element is <"
               & X.Name (Document, Device) & ">, not <device>", Device);
      elsif Value_Of (Device, "name") /= US.To_String (Chosen.Device)
        or else Value_Of (Device, "version")
          /= US.To_String (Chosen.Svd_Version)
      then
         Fail (Input_Mismatch, "the SVD describes "
               & Value_Of (Device, "name") & " version "
               & Value_Of (Device, "version") & ", and the policy "
               & US.To_String (Chosen.Device) & " version "
               & US.To_String (Chosen.Svd_Version),
               Child (Device, "name"));
      end if;
      Open (Rows, In_Array);
      for Choice of Chosen.Peripherals loop
         Project_Peripheral (Choice);
      end loop;
      if Unnamed_Count > 0 then
         Fail (Unsupported_Form,
               (if Unnamed_Count = 1 then "a field's enumerated values are"
                else Decimal (Word (Unnamed_Count))
                & " fields' enumerated values are")
               & " named otherwise than an ASCII letter followed by"
               & " letters, digits and underscores: " & US.To_String (Unnamed)
               & "; the policy's numeric_enums reads such a field as a plain"
               & " number", First_Unnamed);
      end if;
      Close (Rows, In_Array);
      Add (US.To_String (Chosen.Correspondence),
           US.To_String (Rows.Text) & LF, In_Manifest => True);
      declare
         Manifest : Writer;
         Order : array (1 .. Manifest_Entries.Last_Index) of Positive;
      begin
         for Index in Order'Range loop
            Order (Index) := Index;
         end loop;
         for Index in 2 .. Order'Last loop
            declare
               Moving : constant Positive := Order (Index);
               Place : Natural := Index - 1;
            begin
               while Place >= 1
                 and then US.To_String (Manifest_Entries (Order (Place)).Path)
                   > US.To_String (Manifest_Entries (Moving).Path)
               loop
                  Order (Place + 1) := Order (Place);
                  Place := Place - 1;
               end loop;
               Order (Place + 1) := Moving;
            end;
         end loop;
         Open (Manifest, In_Object);
         for Index of Order loop
            Member (Manifest, US.To_String (Manifest_Entries (Index).Path));
            String_Value
              (Manifest, US.To_String (Manifest_Entries (Index).Content));
         end loop;
         Close (Manifest, In_Object);
         Add (US.To_String (Chosen.Manifest),
              US.To_String (Manifest.Text) & LF, In_Manifest => False);
         --  Add placed it outside the modules' root; it is under it.
         Made.Outputs (Made.Outputs.Last_Index).Path := Made.Manifest;
      end;
      Project_Interrupts;
   exception
      when Refused =>
         Made := (others => <>);
   end Project;

end Landin.Devices.Projection;
