package body Landin.Xml is

   package US renames Ada.Strings.Unbounded;

   --  Raised only inside Parse, to leave a refused document, and never
   --  propagated out of it.
   Refused : exception;

   LF : constant Character := ASCII.LF;
   CR : constant Character := ASCII.CR;
   HT : constant Character := ASCII.HT;

   function Slice (Pool : US.Unbounded_String; First, Last : Natural)
     return String
   is (if Last < First then "" else US.Slice (Pool, First, Last));

   function Is_Space (C : Character) return Boolean is
     (C in ' ' | LF | CR | HT);

   function Is_Name_Start (C : Character) return Boolean is
     (C in 'A' .. 'Z' | 'a' .. 'z' | '_' | ':'
      or else Character'Pos (C) >= 16#80#);

   function Is_Name_Char (C : Character) return Boolean is
     (Is_Name_Start (C) or else C in '0' .. '9' | '-' | '.');

   function Is_Xml_Character (Point : Natural) return Boolean is
     (Point in 16#9# | 16#A# | 16#D# | 16#20# .. 16#D7FF#
         | 16#E000# .. 16#FFFD# | 16#1_0000# .. 16#10_FFFF#);

   function Encoded (Point : Natural) return String;

   function Encoded (Point : Natural) return String is
      function Byte (Value : Natural) return Character is
        (Character'Val (Value));
   begin
      if Point < 16#80# then
         return [1 => Byte (Point)];
      elsif Point < 16#800# then
         return [Byte (16#C0# + Point / 64), Byte (16#80# + Point mod 64)];
      elsif Point < 16#1_0000# then
         return [Byte (16#E0# + Point / 4096),
                 Byte (16#80# + (Point / 64) mod 64),
                 Byte (16#80# + Point mod 64)];
      else
         return [Byte (16#F0# + Point / 262_144),
                 Byte (16#80# + (Point / 4096) mod 64),
                 Byte (16#80# + (Point / 64) mod 64),
                 Byte (16#80# + Point mod 64)];
      end if;
   end Encoded;

   procedure Parse (Into : in out Document; Text : String) is
      Base : constant Integer := Text'First;
      Last : constant Integer := Text'Last;
      P : Integer := Text'First;
      Depth : Natural := 0;

      type Open_Element is record
         Item : Element := No_Element;
         Buffer : US.Unbounded_String;
         Has_Text : Boolean := False;
         Text_Offset : Natural := 0;
      end record;

      Open : array (1 .. Maximum_Depth) of Open_Element;

      procedure Fail (Message : String; At_Index : Integer)
        with No_Return;

      procedure Fail (Message : String; At_Index : Integer) is
      begin
         Into.Failure := US.To_Unbounded_String (Message);
         Into.Failure_At :=
           (if At_Index < Base then 0
            else Natural'Min (At_Index, Last + 1) - Base);
         raise Refused;
      end Fail;

      function At_Text (Expected : String) return Boolean is
        (P <= Last - Expected'Length + 1
         and then Text (P .. P + Expected'Length - 1) = Expected);

      function Position_Text (Offset : Natural) return String;

      function Position_Text (Offset : Natural) return String is
         Line_Image : constant String :=
           Positive'Image (Line_Of (Into, Offset));
         Column_Image : constant String :=
           Positive'Image (Column_Of (Into, Offset));
      begin
         return "line " & Line_Image (Line_Image'First + 1 .. Line_Image'Last)
           & ", column "
           & Column_Image (Column_Image'First + 1 .. Column_Image'Last);
      end Position_Text;

      procedure Store (Item : String; First, Last_Stored : out Natural);

      procedure Store (Item : String; First, Last_Stored : out Natural) is
      begin
         First := US.Length (Into.Pool) + 1;
         US.Append (Into.Pool, Item);
         Last_Stored := US.Length (Into.Pool);
      end Store;

      procedure Skip_Space;

      procedure Skip_Space is
      begin
         while P <= Last and then Is_Space (Text (P)) loop
            P := P + 1;
         end loop;
      end Skip_Space;

      function Read_Name (What : String) return String;

      function Read_Name (What : String) return String is
         First : constant Integer := P;
      begin
         if P > Last or else not Is_Name_Start (Text (P)) then
            Fail (What & " was expected", P);
         end if;
         while P <= Last and then Is_Name_Char (Text (P)) loop
            P := P + 1;
         end loop;
         return Text (First .. P - 1);
      end Read_Name;

      procedure Validate;

      --  Every byte is UTF-8 and every character one XML admits, so the
      --  scan below can be a scan of ASCII.
      procedure Validate is
         I : Integer := Text'First;
      begin
         while I <= Last loop
            declare
               Lead : constant Natural := Character'Pos (Text (I));
               Count : Natural;
               Point : Natural;
               Least : Natural;
            begin
               if Lead < 16#80# then
                  if not Is_Xml_Character (Lead) then
                     Fail ("a control character XML does not admit", I);
                  end if;
                  I := I + 1;
               else
                  if Lead in 16#C2# .. 16#DF# then
                     Count := 2;
                     Point := Lead - 16#C0#;
                     Least := 16#80#;
                  elsif Lead in 16#E0# .. 16#EF# then
                     Count := 3;
                     Point := Lead - 16#E0#;
                     Least := 16#800#;
                  elsif Lead in 16#F0# .. 16#F4# then
                     Count := 4;
                     Point := Lead - 16#F0#;
                     Least := 16#1_0000#;
                  else
                     Fail ("a byte that begins no UTF-8 character", I);
                  end if;
                  if I + Count - 1 > Last then
                     Fail ("the text ends inside a UTF-8 character", I);
                  end if;
                  for Next in I + 1 .. I + Count - 1 loop
                     if Character'Pos (Text (Next)) not in 16#80# .. 16#BF#
                     then
                        Fail ("a UTF-8 character is cut short", I);
                     end if;
                     Point :=
                       Point * 64 + Character'Pos (Text (Next)) - 16#80#;
                  end loop;
                  if Point < Least then
                     Fail ("an overlong UTF-8 form", I);
                  elsif not Is_Xml_Character (Point) then
                     Fail ("a character XML does not admit", I);
                  end if;
                  I := I + Count;
               end if;
            end;
         end loop;
      end Validate;

      procedure Read_Reference (Into_Buffer : in out US.Unbounded_String);

      --  At an `&`: the reference it begins, decoded into Into_Buffer.
      procedure Read_Reference (Into_Buffer : in out US.Unbounded_String) is
         Start : constant Integer := P;
         Advice : constant String :=
           "; write &amp; for an ampersand";
      begin
         P := P + 1;
         if P <= Last and then Text (P) = '#' then
            declare
               Hexadecimal : constant Boolean :=
                 P + 1 <= Last and then Text (P + 1) = 'x';
               Radix : constant Natural := (if Hexadecimal then 16 else 10);
               Point : Natural := 0;
               Digits_Read : Natural := 0;
               Digit : Natural;
            begin
               P := P + (if Hexadecimal then 2 else 1);
               while P <= Last and then Text (P) /= ';' loop
                  case Text (P) is
                     when '0' .. '9' =>
                        Digit :=
                          Character'Pos (Text (P)) - Character'Pos ('0');
                     when 'a' .. 'f' =>
                        Digit := Character'Pos (Text (P))
                          - Character'Pos ('a') + 10;
                     when 'A' .. 'F' =>
                        Digit := Character'Pos (Text (P))
                          - Character'Pos ('A') + 10;
                     when others =>
                        Fail ("a character reference holds something other"
                          & " than its digits" & Advice, Start);
                  end case;
                  if Digit >= Radix then
                     Fail ("a decimal character reference holds a"
                       & " hexadecimal digit" & Advice, Start);
                  end if;
                  if Point > 16#10_FFFF# then
                     Fail ("a character reference names no character",
                           Start);
                  end if;
                  Point := Point * Radix + Digit;
                  Digits_Read := Digits_Read + 1;
                  P := P + 1;
               end loop;
               if P > Last or else Digits_Read = 0 then
                  Fail ("a character reference is not ended by `;`"
                    & Advice, Start);
               elsif not Is_Xml_Character (Point) then
                  Fail ("a character reference names a character XML does"
                    & " not admit", Start);
               end if;
               P := P + 1;
               US.Append (Into_Buffer, Encoded (Point));
            end;
         else
            declare
               Name_First : constant Integer := P;
            begin
               while P <= Last and then Is_Name_Char (Text (P)) loop
                  P := P + 1;
               end loop;
               if P > Last or else Text (P) /= ';'
                 or else P = Name_First
               then
                  Fail ("`&` begins no reference" & Advice, Start);
               end if;
               declare
                  Entity : constant String := Text (Name_First .. P - 1);
               begin
                  if Entity = "lt" then
                     US.Append (Into_Buffer, '<');
                  elsif Entity = "gt" then
                     US.Append (Into_Buffer, '>');
                  elsif Entity = "amp" then
                     US.Append (Into_Buffer, '&');
                  elsif Entity = "apos" then
                     US.Append (Into_Buffer, ''');
                  elsif Entity = "quot" then
                     US.Append (Into_Buffer, '"');
                  else
                     Fail ("the entity &" & Entity & "; is not one of the"
                       & " five XML predefines, and no document type"
                       & " declares it", Start);
                  end if;
               end;
               P := P + 1;
            end;
         end if;
      end Read_Reference;

      procedure Skip_Comment;

      procedure Skip_Comment is
         Start : constant Integer := P;
      begin
         P := P + 4;
         loop
            if P > Last - 1 then
               Fail ("the comment is not closed by -->", Start);
            elsif Text (P .. P + 1) = "--" then
               if P + 2 <= Last and then Text (P + 2) = '>' then
                  P := P + 3;
                  return;
               end if;
               Fail ("-- inside a comment, which XML admits only as the"
                 & " end of it", P);
            end if;
            P := P + 1;
         end loop;
      end Skip_Comment;

      procedure Skip_Instruction;

      procedure Skip_Instruction is
         Start : constant Integer := P;
      begin
         P := P + 2;
         declare
            Target : constant String :=
              Read_Name ("a processing instruction's target");
         begin
            if Target'Length = 3
              and then Target (Target'First) in 'x' | 'X'
              and then Target (Target'First + 1) in 'm' | 'M'
              and then Target (Target'First + 2) in 'l' | 'L'
            then
               Fail ("an XML declaration belongs only at the document's"
                 & " start", Start);
            end if;
         end;
         loop
            if P > Last - 1 then
               Fail ("the processing instruction is not closed by ?>",
                     Start);
            elsif Text (P .. P + 1) = "?>" then
               P := P + 2;
               return;
            end if;
            P := P + 1;
         end loop;
      end Skip_Instruction;

      procedure Read_Declaration;

      --  `<?xml version="1.0" encoding="UTF-8" standalone="no"?>`, in
      --  that order, the version required and the others not.
      procedure Read_Declaration is
         Start : constant Integer := P;
         Seen : Natural := 0;
      begin
         P := P + 5;
         loop
            declare
               Spaced : constant Boolean :=
                 P <= Last and then Is_Space (Text (P));
            begin
               Skip_Space;
               if At_Text ("?>") then
                  P := P + 2;
                  exit;
               elsif not Spaced then
                  Fail ("the XML declaration is not closed by ?>", P);
               end if;
            end;
            declare
               Name_At : constant Integer := P;
               Pseudo : constant String := Read_Name ("a declaration's name");
               Value : US.Unbounded_String;
               Quote : Character;
               Order : constant Natural :=
                 (if Pseudo = "version" then 1
                  elsif Pseudo = "encoding" then 2
                  elsif Pseudo = "standalone" then 3 else 0);
            begin
               if Order = 0 then
                  Fail ("the XML declaration says " & Pseudo
                    & ", which is not version, encoding or standalone",
                    Name_At);
               elsif Order <= Seen then
                  Fail ("the XML declaration's " & Pseudo & " is out of"
                    & " order: version, encoding, then standalone",
                    Name_At);
               elsif Seen = 0 and then Order /= 1 then
                  Fail ("the XML declaration names its version first",
                        Name_At);
               end if;
               Seen := Order;
               Skip_Space;
               if P > Last or else Text (P) /= '=' then
                  Fail ("= was expected after " & Pseudo, P);
               end if;
               P := P + 1;
               Skip_Space;
               if P > Last or else Text (P) not in '"' | ''' then
                  Fail ("a quoted value was expected after " & Pseudo & "=",
                        P);
               end if;
               Quote := Text (P);
               P := P + 1;
               while P <= Last and then Text (P) /= Quote loop
                  US.Append (Value, Text (P));
                  P := P + 1;
               end loop;
               if P > Last then
                  Fail ("the value of " & Pseudo & " is not closed", Name_At);
               end if;
               P := P + 1;
               declare
                  Said : constant String := US.To_String (Value);
               begin
                  case Order is
                     when 1 =>
                        if Said'Length < 3
                          or else Said (Said'First .. Said'First + 1) /= "1."
                          or else (for some C of
                                     Said (Said'First + 2 .. Said'Last) =>
                                       C not in '0' .. '9')
                        then
                           Fail ("the XML declaration's version is " & Said
                             & ", not 1.0", Name_At);
                        end if;
                     when 2 =>
                        if Said'Length /= 5
                          or else Said (Said'First) not in 'u' | 'U'
                          or else Said (Said'First + 1) not in 't' | 'T'
                          or else Said (Said'First + 2) not in 'f' | 'F'
                          or else Said (Said'First + 3 .. Said'Last) /= "-8"
                        then
                           Fail ("the XML declaration names the encoding "
                             & Said & "; only UTF-8 is read", Name_At);
                        end if;
                     when others =>
                        if Said not in "yes" | "no" then
                           Fail ("standalone is yes or no, not " & Said,
                                 Name_At);
                        end if;
                  end case;
               end;
            end;
         end loop;
         if Seen = 0 then
            Fail ("the XML declaration names no version", Start);
         end if;
      end Read_Declaration;

      procedure Skip_Miscellany (After_Root : Boolean);

      procedure Skip_Miscellany (After_Root : Boolean) is
      begin
         loop
            Skip_Space;
            if At_Text ("<!--") then
               Skip_Comment;
            elsif At_Text ("<!DOCTYPE") then
               Fail ("a document type declaration is not read, and an SVD"
                 & " needs none", P);
            elsif At_Text ("<?") then
               Skip_Instruction;
            elsif After_Root and then P <= Last then
               Fail ("only comments, processing instructions and space"
                 & " may follow the root element", P);
            else
               exit;
            end if;
         end loop;
      end Skip_Miscellany;

      procedure Append_Text (Run : String; Run_At : Integer);

      procedure Append_Text (Run : String; Run_At : Integer) is
      begin
         if not Open (Depth).Has_Text then
            Open (Depth).Has_Text := True;
            Open (Depth).Text_Offset := Run_At - Base;
         end if;
         US.Append (Open (Depth).Buffer, Run);
      end Append_Text;

      procedure Read_Character_Data;

      --  Up to the next `<`, into the open element's text.
      procedure Read_Character_Data is
         Run_First : Integer := P;
      begin
         while P <= Last and then Text (P) /= '<' loop
            case Text (P) is
               when '&' =>
                  Append_Text (Text (Run_First .. P - 1), Run_First);
                  declare
                     Decoded : US.Unbounded_String;
                     Reference_At : constant Integer := P;
                  begin
                     Read_Reference (Decoded);
                     Append_Text (US.To_String (Decoded), Reference_At);
                  end;
                  Run_First := P;
               when CR =>
                  Append_Text (Text (Run_First .. P - 1) & LF, Run_First);
                  P := P + 1;
                  if P <= Last and then Text (P) = LF then
                     P := P + 1;
                  end if;
                  Run_First := P;
               when ']' =>
                  if At_Text ("]]>") then
                     Fail ("]]> in character data, where it ends nothing;"
                       & " write ]]&gt;", P);
                  end if;
                  P := P + 1;
               when others =>
                  P := P + 1;
            end case;
         end loop;
         Append_Text (Text (Run_First .. P - 1), Run_First);
      end Read_Character_Data;

      procedure Read_Cdata;

      procedure Read_Cdata is
         Start : constant Integer := P;
         Run_First : Integer;
      begin
         P := P + 9;
         Run_First := P;
         loop
            if P > Last - 2 then
               Fail ("the CDATA section is not closed by ]]>", Start);
            elsif Text (P .. P + 2) = "]]>" then
               Append_Text (Text (Run_First .. P - 1), Run_First);
               P := P + 3;
               return;
            elsif Text (P) = CR then
               Append_Text (Text (Run_First .. P - 1) & LF, Run_First);
               P := P + 1;
               if P <= Last and then Text (P) = LF then
                  P := P + 1;
               end if;
               Run_First := P;
            else
               P := P + 1;
            end if;
         end loop;
      end Read_Cdata;

      procedure Read_Start_Tag (Parent : Element);

      --  At `<` and a name: the element, linked under Parent, and opened
      --  unless it is empty.
      procedure Read_Start_Tag (Parent : Element) is
         Start : constant Integer := P;
         Made : Node;
         Item : Element;
      begin
         P := P + 1;
         declare
            Tag : constant String := Read_Name ("an element's name");
         begin
            Store (Tag, Made.Name_First, Made.Name_Last);
         end;
         Made.Offset := Start - Base;
         Made.First_Attribute := Into.Attributes.Last_Index + 1;
         loop
            declare
               Spaced : constant Boolean :=
                 P <= Last and then Is_Space (Text (P));
            begin
               Skip_Space;
               exit when At_Text ("/>") or else At_Text (">");
               if P > Last then
                  Fail ("the document ends inside a start tag", Start);
               elsif not Spaced then
                  Fail ("> or /> was expected, or space before another"
                    & " attribute", P);
               end if;
            end;
            declare
               Name_At : constant Integer := P;
               Attribute_Name : constant String :=
                 Read_Name ("an attribute's name");
               Value : US.Unbounded_String;
               Quote : Character;
               Added : Attribute_Entry;
            begin
               for Index in Made.First_Attribute .. Into.Attributes.Last_Index
               loop
                  if Slice (Into.Pool, Into.Attributes (Index).Name_First,
                            Into.Attributes (Index).Name_Last)
                    = Attribute_Name
                  then
                     Fail ("the attribute " & Attribute_Name & " is given"
                       & " twice", Name_At);
                  end if;
               end loop;
               Skip_Space;
               if P > Last or else Text (P) /= '=' then
                  Fail ("= was expected after the attribute "
                    & Attribute_Name, P);
               end if;
               P := P + 1;
               Skip_Space;
               if P > Last or else Text (P) not in '"' | ''' then
                  Fail ("a quoted value was expected for the attribute "
                    & Attribute_Name, P);
               end if;
               Quote := Text (P);
               P := P + 1;
               loop
                  if P > Last then
                     Fail ("the value of the attribute " & Attribute_Name
                       & " is not closed", Name_At);
                  end if;
                  exit when Text (P) = Quote;
                  case Text (P) is
                     when '<' =>
                        Fail ("< in an attribute value; write &lt;", P);
                     when '&' =>
                        Read_Reference (Value);
                     when CR =>
                        US.Append (Value, ' ');
                        P := P + 1;
                        if P <= Last and then Text (P) = LF then
                           P := P + 1;
                        end if;
                     when LF | HT =>
                        US.Append (Value, ' ');
                        P := P + 1;
                     when others =>
                        US.Append (Value, Text (P));
                        P := P + 1;
                  end case;
               end loop;
               P := P + 1;
               Store (Attribute_Name, Added.Name_First, Added.Name_Last);
               Store (US.To_String (Value),
                      Added.Value_First, Added.Value_Last);
               Into.Attributes.Append (Added);
            end;
         end loop;
         Made.Attributes :=
           Into.Attributes.Last_Index - Made.First_Attribute + 1;
         Into.Nodes.Append (Made);
         Item := Element (Into.Nodes.Last_Index);
         if Parent /= No_Element then
            declare
               Holder : Node renames Into.Nodes (Positive (Parent));
            begin
               if Holder.Last_Child = No_Element then
                  Holder.First_Child := Item;
               else
                  Into.Nodes (Positive (Holder.Last_Child)).Next_Sibling :=
                    Item;
               end if;
               Holder.Last_Child := Item;
            end;
         end if;
         if At_Text ("/>") then
            P := P + 2;
         else
            P := P + 1;
            if Depth = Maximum_Depth then
               Fail ("elements are nested deeper than"
                 & Natural'Image (Maximum_Depth), Start);
            end if;
            Depth := Depth + 1;
            Open (Depth) := (Item => Item, others => <>);
         end if;
      end Read_Start_Tag;

      procedure Close_Element;

      --  At `</`: the end tag, which must close the element open.
      procedure Close_Element is
         Start : constant Integer := P;
         Holder : Node renames Into.Nodes (Positive (Open (Depth).Item));
         Expected : constant String :=
           Slice (Into.Pool, Holder.Name_First, Holder.Name_Last);
      begin
         P := P + 2;
         declare
            Tag : constant String := Read_Name ("an end tag's name");
         begin
            Skip_Space;
            if P > Last or else Text (P) /= '>' then
               Fail ("> was expected to end the end tag </" & Tag, P);
            elsif Tag /= Expected then
               Fail ("</" & Tag & "> does not close <" & Expected
                 & ">, open since " & Position_Text (Holder.Offset), Start);
            end if;
         end;
         P := P + 1;
         if Open (Depth).Has_Text then
            Holder.Has_Text := True;
            Holder.Text_Offset := Open (Depth).Text_Offset;
            Store (US.To_String (Open (Depth).Buffer),
                   Holder.Text_First, Holder.Text_Last);
         else
            Holder.Text_Offset := Holder.Offset;
         end if;
         Open (Depth) := (others => <>);
         Depth := Depth - 1;
      end Close_Element;

   begin
      Into.Nodes.Clear;
      Into.Attributes.Clear;
      Into.Pool := US.Null_Unbounded_String;
      Into.Line_Starts.Clear;
      Into.Parsed := False;
      Into.Failure := US.Null_Unbounded_String;
      Into.Failure_At := 0;
      Into.Line_Starts.Append (0);
      for Index in Text'Range loop
         if Text (Index) = LF then
            Into.Line_Starts.Append (Index - Base + 1);
         end if;
      end loop;
      Validate;
      if At_Text ([Character'Val (16#EF#), Character'Val (16#BB#),
                   Character'Val (16#BF#)])
      then
         P := P + 3;
      end if;
      if At_Text ("<?xml")
        and then (P + 5 > Last or else Is_Space (Text (P + 5))
                  or else Text (P + 5) = '?')
      then
         Read_Declaration;
      end if;
      Skip_Miscellany (After_Root => False);
      if P > Last then
         Fail ("the document has no root element", P);
      elsif Text (P) /= '<' or else P = Last
        or else not Is_Name_Start (Text (P + 1))
      then
         Fail ("the root element was expected", P);
      end if;
      Read_Start_Tag (No_Element);
      while Depth > 0 loop
         if P > Last then
            declare
               Holder : constant Node :=
                 Into.Nodes (Positive (Open (Depth).Item));
            begin
               Fail ("<" & Slice (Into.Pool, Holder.Name_First,
                                  Holder.Name_Last)
                 & "> is not closed before the document ends",
                 Holder.Offset + Base);
            end;
         elsif Text (P) /= '<' then
            Read_Character_Data;
         elsif At_Text ("</") then
            Close_Element;
         elsif At_Text ("<!--") then
            Skip_Comment;
         elsif At_Text ("<![CDATA[") then
            Read_Cdata;
         elsif At_Text ("<?") then
            Skip_Instruction;
         elsif At_Text ("<!") then
            Fail ("<! begins nothing an element's content admits", P);
         elsif P < Last and then Is_Name_Start (Text (P + 1)) then
            Read_Start_Tag (Open (Depth).Item);
         else
            Fail ("< begins no tag; write &lt; for a less-than sign", P);
         end if;
      end loop;
      Skip_Miscellany (After_Root => True);
      Into.Parsed := True;
   exception
      when Refused =>
         Into.Nodes.Clear;
         Into.Attributes.Clear;
         Into.Pool := US.Null_Unbounded_String;
         Into.Parsed := False;
   end Parse;

   function Ok (Of_Document : Document) return Boolean is
     (Of_Document.Parsed);

   function Fault (Of_Document : Document) return String is
     (US.To_String (Of_Document.Failure));

   function Fault_At (Of_Document : Document) return Natural is
     (Of_Document.Failure_At);

   function Fault_Line (Of_Document : Document) return Positive is
     (Line_Of (Of_Document, Of_Document.Failure_At));

   function Fault_Column (Of_Document : Document) return Positive is
     (Column_Of (Of_Document, Of_Document.Failure_At));

   function Line_Of (Of_Document : Document; Offset : Natural)
     return Positive
   is
      Low : Positive := 1;
      High : Natural := Of_Document.Line_Starts.Last_Index;
   begin
      if High = 0 then
         return 1;
      end if;
      --  The last line whose start is at or before Offset.
      while Low < High loop
         declare
            Middle : constant Positive := (Low + High + 1) / 2;
         begin
            if Of_Document.Line_Starts (Middle) <= Offset then
               Low := Middle;
            else
               High := Middle - 1;
            end if;
         end;
      end loop;
      return Low;
   end Line_Of;

   function Column_Of (Of_Document : Document; Offset : Natural)
     return Positive
   is
      Line_Number : constant Positive := Line_Of (Of_Document, Offset);
   begin
      if Of_Document.Line_Starts.Is_Empty then
         return Offset + 1;
      end if;
      return Offset - Of_Document.Line_Starts (Line_Number) + 1;
   end Column_Of;

   function Root (Of_Document : Document) return Element is
     (if Of_Document.Nodes.Is_Empty then No_Element else 1);

   function Is_Present (Item : Element) return Boolean is
     (Item /= No_Element);

   function Name (Of_Document : Document; Item : Element) return String is
     (Slice (Of_Document.Pool, Of_Document.Nodes (Positive (Item)).Name_First,
             Of_Document.Nodes (Positive (Item)).Name_Last));

   function Offset (Of_Document : Document; Item : Element) return Natural
   is (Of_Document.Nodes (Positive (Item)).Offset);

   function Line (Of_Document : Document; Item : Element) return Positive is
     (Line_Of (Of_Document, Offset (Of_Document, Item)));

   function Column (Of_Document : Document; Item : Element) return Positive
   is (Column_Of (Of_Document, Offset (Of_Document, Item)));

   function Text (Of_Document : Document; Item : Element) return String is
     (if not Of_Document.Nodes (Positive (Item)).Has_Text then ""
      else Slice (Of_Document.Pool,
                  Of_Document.Nodes (Positive (Item)).Text_First,
                  Of_Document.Nodes (Positive (Item)).Text_Last));

   function Text_Offset (Of_Document : Document; Item : Element)
     return Natural
   is (Of_Document.Nodes (Positive (Item)).Text_Offset);

   function Attribute_Count (Of_Document : Document; Item : Element)
     return Natural
   is (Of_Document.Nodes (Positive (Item)).Attributes);

   function Attribute_Name
     (Of_Document : Document; Item : Element; Position : Positive)
      return String
   is
      Held : constant Attribute_Entry := Of_Document.Attributes
        (Of_Document.Nodes (Positive (Item)).First_Attribute + Position - 1);
   begin
      return Slice (Of_Document.Pool, Held.Name_First, Held.Name_Last);
   end Attribute_Name;

   function Attribute_Value
     (Of_Document : Document; Item : Element; Position : Positive)
      return String
   is
      Held : constant Attribute_Entry := Of_Document.Attributes
        (Of_Document.Nodes (Positive (Item)).First_Attribute + Position - 1);
   begin
      return Slice (Of_Document.Pool, Held.Value_First, Held.Value_Last);
   end Attribute_Value;

   function Has_Attribute
     (Of_Document : Document; Item : Element; Name : String) return Boolean
   is
   begin
      for Position in 1 .. Attribute_Count (Of_Document, Item) loop
         if Attribute_Name (Of_Document, Item, Position) = Name then
            return True;
         end if;
      end loop;
      return False;
   end Has_Attribute;

   function Attribute
     (Of_Document : Document; Item : Element; Name : String) return String
   is
   begin
      for Position in 1 .. Attribute_Count (Of_Document, Item) loop
         if Attribute_Name (Of_Document, Item, Position) = Name then
            return Attribute_Value (Of_Document, Item, Position);
         end if;
      end loop;
      return "";
   end Attribute;

   function First_Child (Of_Document : Document; Item : Element)
     return Element
   is (Of_Document.Nodes (Positive (Item)).First_Child);

   function Next_Sibling (Of_Document : Document; Item : Element)
     return Element
   is (Of_Document.Nodes (Positive (Item)).Next_Sibling);

   function Child
     (Of_Document : Document; Item : Element; Name : String) return Element
   is
      Current : Element := First_Child (Of_Document, Item);
   begin
      while Current /= No_Element loop
         if Xml.Name (Of_Document, Current) = Name then
            return Current;
         end if;
         Current := Next_Sibling (Of_Document, Current);
      end loop;
      return No_Element;
   end Child;

   function Child_Count
     (Of_Document : Document; Item : Element; Name : String) return Natural
   is
      Current : Element := First_Child (Of_Document, Item);
      Count : Natural := 0;
   begin
      while Current /= No_Element loop
         if Xml.Name (Of_Document, Current) = Name then
            Count := Count + 1;
         end if;
         Current := Next_Sibling (Of_Document, Current);
      end loop;
      return Count;
   end Child_Count;

end Landin.Xml;
