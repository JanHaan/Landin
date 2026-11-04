with Ada.Strings.Fixed;

with Landin.Json;

package body Landin.Devices.Policies is

   package J renames Landin.Json;

   use type J.Value_Kind;
   use type Interfaces.Unsigned_64;
   use type J.Integer_Value;
   use type US.Unbounded_String;

   Refused : exception;

   procedure Read
     (Text : String; Into : out Policy; Problem : out Fault)
   is
      Document : J.Document;
      Root : J.Value;

      procedure Fail (Message : String) with No_Return;

      procedure Fail (Message : String) is
      begin
         Problem :=
           (Kind => Invalid_Policy, Within => Policy_Input, Offset => 0,
            Has_Offset => False,
            Message => US.To_Unbounded_String (Message));
         raise Refused;
      end Fail;

      function Member_String
        (Item : J.Value; Name, Where : String; Default : String := "";
         Required : Boolean := True) return String;

      function Member_String
        (Item : J.Value; Name, Where : String; Default : String := "";
         Required : Boolean := True) return String
      is
         Found : constant J.Value := J.Member (Document, Item, Name);
      begin
         if not J.Is_Present (Found) then
            if Required then
               Fail (Where & " has no member """ & Name & """");
            end if;
            return Default;
         elsif J.Kind (Document, Found) /= J.String_Value then
            Fail (Where & "." & Name & " is not a string");
         end if;
         return J.Text (Document, Found);
      end Member_String;

      function Path_Member
        (Name, Default : String) return String;

      function Path_Member
        (Name, Default : String) return String
      is
         Said : constant String :=
           Member_String (Root, Name, "the policy", Default,
                          Required => False);
      begin
         if Said /= "." and then not Is_Relative_Path (Said) then
            Fail ("the policy's " & Name & " is """ & Said & """, which is"
              & " not a relative path without . or .. parts");
         end if;
         return Said;
      end Path_Member;

      function Mask_Of (Said, Where : String) return Word;

      function Mask_Of (Said, Where : String) return Word is
      begin
         if Said'Length < 3
           or else Said (Said'First .. Said'First + 1) /= "0x"
           or else not Is_Number (Said)
           or else Number (Said) > 16#FFFF_FFFF#
         then
            Fail (Where & " is """ & Said & """, not a 32-bit 0x mask");
         end if;
         return Number (Said);
      end Mask_Of;

      function Find (Key : String) return Natural;

      --  The selected register Key, `PERIPHERAL.REGISTER`, or zero.
      function Find (Key : String) return Natural is
      begin
         for Index in 1 .. Into.Registers.Last_Index loop
            if US.To_String (Into.Registers (Index).Peripheral) & "."
                 & US.To_String (Into.Registers (Index).Register) = Key
            then
               return Index;
            end if;
         end loop;
         return 0;
      end Find;

      --  D705: each peripheral a reviewer adds, written as the SVD's own
      --  XML so that the projection reads it as it reads the SVD's.
      procedure Read_Additions;

      procedure Read_Additions is
         Additions : constant J.Value :=
           J.Member (Document, Root, "peripheral_additions");

         --  A field's bits, [HIGH:LOW] in decimal within 32, as the SVD
         --  writes a bitRange.
         function Bits_Of (Said, Where : String) return String;

         function Bits_Of (Said, Where : String) return String is
            Colon : Natural := 0;

            function Plain (Part : String) return Boolean is
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
              or else not Plain (Said (Said'First + 1 .. Colon - 1))
              or else not Plain (Said (Colon + 1 .. Said'Last - 1))
              or else Natural'Value (Said (Said'First + 1 .. Colon - 1)) > 31
              or else Natural'Value (Said (Colon + 1 .. Said'Last - 1))
                > Natural'Value (Said (Said'First + 1 .. Colon - 1))
            then
               Fail (Where & ".bits is '" & Said & "', not [HIGH:LOW] in"
                 & " decimal within 32 bits");
            end if;
            return Said;
         end Bits_Of;

         function Access_Of (Said, Where : String) return String;

         function Access_Of (Said, Where : String) return String is
         begin
            if Said not in "read-write" | "read-only" | "write-only"
              | "writeOnce" | "read-writeOnce"
            then
               Fail (Where & ".access is '" & Said & "', not one of the"
                 & " SVD's read-write, read-only, write-only, writeOnce or"
                 & " read-writeOnce");
            end if;
            return Said;
         end Access_Of;

         --  Item's members are among Allowed, which the refusal lists.
         procedure Only (Item : J.Value; Where, Allowed : String);

         procedure Only (Item : J.Value; Where, Allowed : String) is
         begin
            for Member in 1 .. J.Length (Document, Item) loop
               if Ada.Strings.Fixed.Index
                   (" " & Allowed & ",",
                    " " & J.Key (Document, Item, Member) & ",") = 0
               then
                  Fail (Where & " has the member '"
                    & J.Key (Document, Item, Member) & "'; it says "
                    & Allowed);
               end if;
            end loop;
         end Only;

         --  A register's name, or an array's with one %s, which the
         --  projection expands as it expands the SVD's (D703).
         function Is_Register_Name (Name : String) return Boolean;

         function Is_Register_Name (Name : String) return Boolean is
            At_Index : constant Natural :=
              Ada.Strings.Fixed.Index (Name, "%s");
         begin
            if At_Index = 0 then
               return Is_Vendor_Name (Name);
            end if;
            return Is_Vendor_Name
              (Name (Name'First .. At_Index - 1)
               & Name (At_Index + 2 .. Name'Last))
              and then At_Index > Name'First
              and then Ada.Strings.Fixed.Index
                (Name (At_Index + 2 .. Name'Last), "%") = 0;
         end Is_Register_Name;
      begin
         if not J.Is_Present (Additions) then
            return;
         elsif not J.Is_Kind (Document, Additions, J.Object_Value) then
            Fail ("the policy's peripheral_additions is not an object");
         end if;
         for Position in 1 .. J.Length (Document, Additions) loop
            declare
               Name : constant String := J.Key (Document, Additions, Position);
               Item : constant J.Value :=
                 J.Member_Value (Document, Additions, Position);
               Where : constant String := "peripheral_additions." & Name;
               Made : Peripheral_Addition;
               Xml : US.Unbounded_String;
               Registers : J.Value;
            begin
               if not Is_Vendor_Name (Name) then
                  Fail (Where & " does not name a peripheral: an ASCII"
                    & " letter, then letters, digits and underscores");
               elsif not J.Is_Kind (Document, Item, J.Object_Value) then
                  Fail (Where & " is not an object of base, registers and"
                    & " source");
               end if;
               Only (Item, Where, "base, registers, source");
               Made.Name := US.To_Unbounded_String (Name);
               Made.Source := US.To_Unbounded_String
                 (Member_String (Item, "source", Where));
               if Made.Source = "" then
                  Fail (Where & ".source is empty: an addition says where"
                    & " its reviewer read it");
               end if;
               US.Append (Xml, "<peripheral><name>" & Name & "</name>"
                 & "<baseAddress>"
                 & Hex8 (Mask_Of (Member_String (Item, "base", Where),
                                  Where & ".base"))
                 & "</baseAddress><registers>");
               Registers := J.Member (Document, Item, "registers");
               if not J.Is_Kind (Document, Registers, J.Object_Value)
                 or else J.Length (Document, Registers) = 0
               then
                  Fail (Where & ".registers is not an object naming each"
                    & " register it adds");
               end if;
               for Index in 1 .. J.Length (Document, Registers) loop
                  declare
                     Register : constant String :=
                       J.Key (Document, Registers, Index);
                     Spec : constant J.Value :=
                       J.Member_Value (Document, Registers, Index);
                     At_Register : constant String :=
                       Where & ".registers." & Register;
                     Arrayed : constant Boolean :=
                       Ada.Strings.Fixed.Index (Register, "%s") /= 0;
                     Fields : J.Value;
                  begin
                     if not Is_Register_Name (Register) then
                        Fail (At_Register & " is not a register's name, or"
                          & " an array's with one %s after its first"
                          & " letter");
                     elsif not J.Is_Kind (Document, Spec, J.Object_Value)
                     then
                        Fail (At_Register & " is not an object");
                     end if;
                     Only (Spec, At_Register,
                           "offset, access, reset, fields, dim, increment");
                     if Arrayed /= J.Is_Present
                         (J.Member (Document, Spec, "dim"))
                       or else Arrayed /= J.Is_Present
                         (J.Member (Document, Spec, "increment"))
                     then
                        Fail (At_Register & " is an array exactly when its"
                          & " name has %s, and an array gives dim and"
                          & " increment");
                     end if;
                     US.Append (Xml, "<register><name>" & Register
                       & "</name>");
                     if Arrayed then
                        declare
                           Count : constant J.Value :=
                             J.Member (Document, Spec, "dim");
                        begin
                           if not J.Is_Integer (Document, Count)
                             or else J.Integer_Of (Document, Count) not in
                               1 .. 1024
                           then
                              Fail (At_Register & ".dim is not a count from"
                                & " 1 to 1024");
                           end if;
                           US.Append (Xml, "<dim>"
                             & Decimal (Word (J.Integer_Of (Document, Count)))
                             & "</dim><dimIncrement>"
                             & Hex (Mask_Of (Member_String
                                (Spec, "increment", At_Register),
                                At_Register & ".increment"))
                             & "</dimIncrement>");
                        end;
                     end if;
                     US.Append (Xml, "<addressOffset>"
                       & Hex (Mask_Of (Member_String
                          (Spec, "offset", At_Register),
                          At_Register & ".offset"))
                       & "</addressOffset><size>32</size><access>"
                       & Access_Of (Member_String
                          (Spec, "access", At_Register), At_Register)
                       & "</access><resetValue>"
                       & Hex8 (Mask_Of (Member_String
                          (Spec, "reset", At_Register),
                          At_Register & ".reset"))
                       & "</resetValue><resetMask>0xffffffff</resetMask>"
                       & "<fields>");
                     Fields := J.Member (Document, Spec, "fields");
                     if not J.Is_Kind (Document, Fields, J.Object_Value)
                       or else J.Length (Document, Fields) = 0
                     then
                        Fail (At_Register & ".fields is not an object"
                          & " naming each field");
                     end if;
                     for Field in 1 .. J.Length (Document, Fields) loop
                        declare
                           Field_Name : constant String :=
                             J.Key (Document, Fields, Field);
                           Field_Spec : constant J.Value :=
                             J.Member_Value (Document, Fields, Field);
                           At_Field : constant String :=
                             At_Register & ".fields." & Field_Name;
                        begin
                           if not Is_Vendor_Name (Field_Name) then
                              Fail (At_Field & " is not a field's name");
                           elsif not J.Is_Kind
                               (Document, Field_Spec, J.Object_Value)
                           then
                              Fail (At_Field & " is not an object of bits"
                                & " and access");
                           end if;
                           Only (Field_Spec, At_Field, "bits, access");
                           US.Append (Xml, "<field><name>" & Field_Name
                             & "</name><bitRange>"
                             & Bits_Of (Member_String
                                (Field_Spec, "bits", At_Field), At_Field)
                             & "</bitRange>");
                           if J.Is_Present
                               (J.Member (Document, Field_Spec, "access"))
                           then
                              US.Append (Xml, "<access>"
                                & Access_Of (Member_String
                                   (Field_Spec, "access", At_Field),
                                   At_Field)
                                & "</access>");
                           end if;
                           US.Append (Xml, "</field>");
                        end;
                     end loop;
                     US.Append (Xml, "</fields></register>");
                  end;
               end loop;
               US.Append (Xml, "</registers></peripheral>");
               Made.Xml := Xml;
               Into.Additions.Append (Made);
            end;
         end loop;
      end Read_Additions;

   begin
      Into := (others => <>);
      Problem := No_Problem;
      J.Parse (Document, Text);
      if not J.Ok (Document) then
         Problem :=
           (Kind => Invalid_Policy, Within => Policy_Input,
            Offset => J.Fault_At (Document), Has_Offset => True,
            Message => US.To_Unbounded_String
              ("the policy is not JSON: " & J.Fault (Document)));
         return;
      end if;
      Root := J.Root (Document);
      if J.Kind (Document, Root) /= J.Object_Value then
         Fail ("the policy is not a JSON object");
      end if;
      for Position in 1 .. J.Length (Document, Root) loop
         declare
            Name : constant String := J.Key (Document, Root, Position);
         begin
            if Name not in "provenance" | "schema" | "device"
              | "svd_version" | "svd_sha256" | "notice" | "modules"
              | "prefix" | "correspondence" | "manifest" | "description"
              | "selection" | "policies" | "numeric_enums"
              | "reset_mask_overrides" | "reset_corrections"
              | "field_corrections" | "interrupt_corrections"
              | "identity" | "core" | "register_corrections"
              | "peripheral_additions"
            then
               Fail ("the policy's member """ & Name & """ is not one"
                 & " refine svd reads; the reviewer's notes go under"
                 & " ""provenance""");
            end if;
         end;
      end loop;
      declare
         Schema : constant J.Value := J.Member (Document, Root, "schema");
      begin
         if not J.Is_Integer (Document, Schema)
           or else J.Integer_Of (Document, Schema) /= 2
         then
            Fail ("the policy's schema is not 2");
         end if;
      end;
      Into.Device := US.To_Unbounded_String
        (Member_String (Root, "device", "the policy"));
      Into.Svd_Version := US.To_Unbounded_String
        (Member_String (Root, "svd_version", "the policy"));
      Into.Svd_Sha256 := US.To_Unbounded_String
        (Member_String (Root, "svd_sha256", "the policy"));
      if US.Length (Into.Svd_Sha256) /= 64
        or else (for some C of US.To_String (Into.Svd_Sha256) =>
                   C not in '0' .. '9' | 'a' .. 'f')
      then
         Fail ("the policy's svd_sha256 is not 64 lowercase hexadecimal"
           & " digits");
      end if;
      --  D700: Espressif names its devices with a hyphen, ESP32-C3, which
      --  no module path holds, so such a policy says its prefix and
      --  description.
      if US.Length (Into.Device) = 0
        or else US.Element (Into.Device, 1) not in 'A' .. 'Z' | 'a' .. 'z'
        or else (for some C of US.To_String (Into.Device) =>
                   C not in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_'
                     | '-')
      then
         Fail ("the policy's device is not a vendor name: an ASCII letter,"
           & " then letters, digits, underscores and hyphens");
      end if;
      Into.Identity := US.To_Unbounded_String
        (Member_String (Root, "identity", "the policy",
                        Lowered (US.To_String (Into.Device)),
                        Required => False));
      if US.Length (Into.Identity) not in 1 .. 32
        or else US.Element (Into.Identity, 1) not in 'a' .. 'z'
        or else (for some C of US.To_String (Into.Identity) =>
                   C not in 'a' .. 'z' | '0' .. '9' | '-')
      then
         Fail ("the description's identity is '"
           & US.To_String (Into.Identity) & "', which D542 does not admit:"
           & " lowercase ASCII letters, digits and hyphens, beginning with"
           & " a letter, at most 32 bytes; the policy's identity names"
           & " another");
      end if;
      declare
         Said : constant String :=
           Member_String (Root, "core", "the policy", Required => False);
      begin
         if Said = "hazard3" then
            Into.Core := Hazard3;
         elsif Said = "esp-rv32imc" then
            Into.Core := Esp_Rv32imc;
         elsif Said = "esp-rv32imac-clic" then
            Into.Core := Esp_Rv32imac_Clic;
         elsif Said = "xtensa-lx6" then
            Into.Core := Xtensa_LX6;
         elsif Said = "xtensa-lx7" then
            Into.Core := Xtensa_LX7;
         elsif J.Is_Present (J.Member (Document, Root, "core")) then
            Fail ("the policy's core is '" & Said & "', not hazard3,"
              & " esp-rv32imc, esp-rv32imac-clic, xtensa-lx6 or xtensa-lx7;"
              & " a Cortex-M core is the SVD's cpu");
         end if;
      end;
      declare
         Notice : constant J.Value := J.Member (Document, Root, "notice");
      begin
         if not J.Is_Kind (Document, Notice, J.Array_Value) then
            Fail ("the policy has no notice: a list of the lines each"
              & " generated module begins with");
         end if;
         for Position in 1 .. J.Length (Document, Notice) loop
            declare
               Line : constant J.Value :=
                 J.Element (Document, Notice, Position);
            begin
               if not J.Is_Kind (Document, Line, J.String_Value)
                 or else (for some C of J.Text (Document, Line) =>
                            Character'Pos (C) < 32
                            or else Character'Pos (C) > 126)
               then
                  Fail ("each line of the policy's notice is printable"
                    & " ASCII text");
               end if;
               Into.Notice.Append (J.Text (Document, Line));
            end;
         end loop;
      end;
      declare
         Default_Prefix : constant String :=
           Lowered (US.To_String (Into.Device));
      begin
         Into.Modules := US.To_Unbounded_String (Path_Member ("modules", "."));
         Into.Prefix := US.To_Unbounded_String
           (Path_Member ("prefix", Default_Prefix));
         Into.Correspondence := US.To_Unbounded_String
           (Path_Member ("correspondence",
                         US.To_String (Into.Prefix) & "/correspondence.json"));
         Into.Manifest := US.To_Unbounded_String
           (Path_Member ("manifest",
                         US.To_String (Into.Prefix) & "/outputs.json"));
         Into.Description := US.To_Unbounded_String
           (Path_Member ("description", "descriptions/" & Default_Prefix));
         if Into.Prefix = "." or else Into.Correspondence = "."
           or else Into.Manifest = "." or else Into.Description = "."
           or else Into.Correspondence = Into.Manifest
         then
            Fail ("the policy's prefix, correspondence, manifest and"
              & " description name distinct paths below the output"
              & " directory");
         end if;
      end;
      declare
         Selection : constant J.Value :=
           J.Member (Document, Root, "selection");
      begin
         if not J.Is_Kind (Document, Selection, J.Object_Value)
           or else J.Length (Document, Selection) = 0
         then
            Fail ("the policy's selection is not an object naming each"
              & " selected peripheral's registers");
         end if;
         for Position in 1 .. J.Length (Document, Selection) loop
            declare
               Peripheral : constant String :=
                 J.Key (Document, Selection, Position);
               Names : constant J.Value :=
                 J.Member_Value (Document, Selection, Position);
               Chosen : Peripheral_Choice :=
                 (Name => US.To_Unbounded_String (Peripheral),
                  First => Into.Registers.Last_Index + 1, Last => 0);
            begin
               if not Is_Vendor_Name (Peripheral) then
                  Fail ("the selected peripheral """ & Peripheral & """ is"
                    & " not a vendor name");
               elsif not J.Is_Kind (Document, Names, J.Array_Value)
                 or else J.Length (Document, Names) = 0
               then
                  Fail ("selection." & Peripheral & " is not a nonempty list"
                    & " of register names");
               end if;
               for Index in 1 .. J.Length (Document, Names) loop
                  declare
                     Register : constant J.Value :=
                       J.Element (Document, Names, Index);
                  begin
                     if not J.Is_Kind (Document, Register, J.String_Value)
                       or else not Is_Vendor_Name
                         (J.Text (Document, Register))
                     then
                        Fail ("selection." & Peripheral & " holds something"
                          & " other than a register's name");
                     elsif Find (Peripheral & "."
                                 & J.Text (Document, Register)) /= 0
                     then
                        Fail ("selection." & Peripheral & " names "
                          & J.Text (Document, Register) & " twice");
                     end if;
                     Into.Registers.Append
                       (Register_Choice'
                          (Peripheral => US.To_Unbounded_String (Peripheral),
                           Register => US.To_Unbounded_String
                             (J.Text (Document, Register)),
                           others => <>));
                  end;
               end loop;
               Chosen.Last := Into.Registers.Last_Index;
               Into.Peripherals.Append (Chosen);
            end;
         end loop;
      end;
      declare
         Policies : constant J.Value := J.Member (Document, Root, "policies");
      begin
         if not J.Is_Kind (Document, Policies, J.Object_Value) then
            Fail ("the policy's policies is not an object of each selected"
              & " register's access policy");
         end if;
         for Position in 1 .. J.Length (Document, Policies) loop
            if Find (J.Key (Document, Policies, Position)) = 0 then
               Fail ("policies." & J.Key (Document, Policies, Position)
                 & " names no selected register");
            end if;
         end loop;
         for Index in 1 .. Into.Registers.Last_Index loop
            declare
               Choice : Register_Choice renames Into.Registers (Index);
               Key : constant String := US.To_String (Choice.Peripheral)
                 & "." & US.To_String (Choice.Register);
               Item : constant J.Value :=
                 J.Member (Document, Policies, Key);
               Where : constant String := "policies." & Key;
            begin
               if not J.Is_Kind (Document, Item, J.Object_Value) then
                  Fail ("the selected register " & Key & " has no policy");
               end if;
               for Member in 1 .. J.Length (Document, Item) loop
                  if J.Key (Document, Item, Member)
                    not in "read" | "write" | "reserved" | "write_mask"
                  then
                     Fail (Where & " has the member """
                       & J.Key (Document, Item, Member) & """; a policy"
                       & " says read, write, reserved and write_mask");
                  end if;
               end loop;
               declare
                  Read_Text : constant String :=
                    Member_String (Item, "read", Where);
                  Write_Text : constant String :=
                    Member_String (Item, "write", Where);
                  Reserved_Text : constant String :=
                    Member_String (Item, "reserved", Where);
               begin
                  if Read_Text = "normal" then
                     Choice.Read := Normal_Read;
                  elsif Read_Text = "modify" then
                     Choice.Read := Modify_Read;
                  elsif Read_Text = "refused" then
                     Choice.Read := Refused_Read;
                  else
                     Fail (Where & ".read is """ & Read_Text & """, not"
                       & " normal, modify or refused");
                  end if;
                  if Write_Text = "normal" then
                     Choice.Write := Normal_Write;
                  elsif Write_Text = "one_clears" then
                     Choice.Write := One_Clears_Write;
                  elsif Write_Text = "refused" then
                     Choice.Write := Refused_Write;
                  else
                     Fail (Where & ".write is """ & Write_Text & """, not"
                       & " normal, one_clears or refused");
                  end if;
                  if Reserved_Text = "zero" then
                     Choice.Reserved := Write_Zero;
                  elsif Reserved_Text = "preserve" then
                     Choice.Reserved := Preserve;
                  else
                     Fail (Where & ".reserved is """ & Reserved_Text
                       & """, not zero or preserve");
                  end if;
               end;
               if J.Is_Present (J.Member (Document, Item, "write_mask")) then
                  declare
                     Said : constant String :=
                       Member_String (Item, "write_mask", Where);
                  begin
                     Choice.Has_Write_Mask := True;
                     Choice.Write_Mask :=
                       Mask_Of (Said, Where & ".write_mask");
                     Choice.Write_Mask_Text := US.To_Unbounded_String (Said);
                  end;
               end if;
            end;
         end loop;
      end;
      declare
         Numeric : constant J.Value :=
           J.Member (Document, Root, "numeric_enums");
      begin
         if J.Is_Present (Numeric) then
            if not J.Is_Kind (Document, Numeric, J.Array_Value) then
               Fail ("the policy's numeric_enums is not a list of fields");
            end if;
            for Position in 1 .. J.Length (Document, Numeric) loop
               declare
                  Field : constant J.Value :=
                    J.Element (Document, Numeric, Position);
               begin
                  if not J.Is_Kind (Document, Field, J.String_Value) then
                     Fail ("numeric_enums holds something other than a"
                       & " field's PERIPHERAL.REGISTER.FIELD");
                  end if;
                  declare
                     Said : constant String := J.Text (Document, Field);
                     Last_Dot : Natural := 0;
                  begin
                     for Index in Said'Range loop
                        if Said (Index) = '.' then
                           Last_Dot := Index;
                        end if;
                     end loop;
                     if Last_Dot = 0
                       or else Find (Said (Said'First .. Last_Dot - 1)) = 0
                     then
                        Fail ("numeric_enums names " & Said & ", a field of"
                          & " no selected register");
                     end if;
                     Into.Numeric.Append (Said);
                  end;
               end;
            end loop;
         end if;
      end;
      declare
         Overrides : constant J.Value :=
           J.Member (Document, Root, "reset_mask_overrides");
      begin
         if J.Is_Present (Overrides) then
            if not J.Is_Kind (Document, Overrides, J.Object_Value) then
               Fail ("the policy's reset_mask_overrides is not an object");
            end if;
            for Position in 1 .. J.Length (Document, Overrides) loop
               declare
                  Key : constant String :=
                    J.Key (Document, Overrides, Position);
                  Index : constant Natural := Find (Key);
                  Said : constant J.Value :=
                    J.Member_Value (Document, Overrides, Position);
               begin
                  if Index = 0 then
                     Fail ("reset_mask_overrides." & Key & " names no"
                       & " selected register");
                  elsif not J.Is_Kind (Document, Said, J.String_Value) then
                     Fail ("reset_mask_overrides." & Key & " is not a"
                       & " string");
                  end if;
                  Into.Registers (Index).Has_Reset_Mask := True;
                  Into.Registers (Index).Reset_Mask :=
                    Mask_Of (J.Text (Document, Said),
                             "reset_mask_overrides." & Key);
               end;
            end loop;
         end if;
      end;
      declare
         Corrections : constant J.Value :=
           J.Member (Document, Root, "reset_corrections");
      begin
         if J.Is_Present (Corrections) then
            if not J.Is_Kind (Document, Corrections, J.Object_Value) then
               Fail ("the policy's reset_corrections is not an object");
            end if;
            for Position in 1 .. J.Length (Document, Corrections) loop
               declare
                  Key : constant String :=
                    J.Key (Document, Corrections, Position);
                  Index : constant Natural := Find (Key);
                  Item : constant J.Value :=
                    J.Member_Value (Document, Corrections, Position);
                  Where : constant String := "reset_corrections." & Key;
               begin
                  if Index = 0 then
                     Fail (Where & " names no selected register");
                  elsif not J.Is_Kind (Document, Item, J.Object_Value) then
                     Fail (Where & " is not an object of value and source");
                  end if;
                  for Member in 1 .. J.Length (Document, Item) loop
                     if J.Key (Document, Item, Member) not in "value"
                       | "source"
                     then
                        Fail (Where & " has the member """
                          & J.Key (Document, Item, Member) & """; a"
                          & " correction says value and source");
                     end if;
                  end loop;
                  Into.Registers (Index).Has_Reset_Value := True;
                  Into.Registers (Index).Reset_Value :=
                    Mask_Of (Member_String (Item, "value", Where),
                             Where & ".value");
                  Into.Registers (Index).Reset_Source :=
                    US.To_Unbounded_String
                      (Member_String (Item, "source", Where));
                  if Into.Registers (Index).Reset_Source = "" then
                     Fail (Where & ".source is empty: a correction says"
                       & " where its reviewer read it");
                  end if;
               end;
            end loop;
         end if;
      end;
      declare
         Corrections : constant J.Value :=
           J.Member (Document, Root, "field_corrections");
      begin
         if J.Is_Present (Corrections) then
            if not J.Is_Kind (Document, Corrections, J.Object_Value) then
               Fail ("the policy's field_corrections is not an object");
            end if;
            for Position in 1 .. J.Length (Document, Corrections) loop
               declare
                  Key : constant String :=
                    J.Key (Document, Corrections, Position);
                  Item : constant J.Value :=
                    J.Member_Value (Document, Corrections, Position);
                  Where : constant String := "field_corrections." & Key;
                  Last_Dot : Natural := 0;
                  Made : Field_Correction;
               begin
                  for Index in Key'Range loop
                     if Key (Index) = '.' then
                        Last_Dot := Index;
                     end if;
                  end loop;
                  if Last_Dot = 0
                    or else Find (Key (Key'First .. Last_Dot - 1)) = 0
                  then
                     Fail (Where & " names a field of no selected register");
                  elsif not J.Is_Kind (Document, Item, J.Object_Value) then
                     Fail (Where & " is not an object of bits or omit, and"
                       & " source");
                  end if;
                  for Member in 1 .. J.Length (Document, Item) loop
                     if J.Key (Document, Item, Member) not in "bits" | "omit"
                       | "add" | "access" | "source"
                     then
                        Fail (Where & " has the member '"
                          & J.Key (Document, Item, Member) & "'; a"
                          & " correction says bits or omit, or add with"
                          & " bits and access, and source");
                     end if;
                  end loop;
                  if J.Is_Present (J.Member (Document, Item, "add")) then
                     if not J.Is_Kind
                         (Document, J.Member (Document, Item, "add"),
                          J.True_Value)
                       or else J.Is_Present (J.Member (Document, Item, "omit"))
                       or else not J.Is_Present
                         (J.Member (Document, Item, "bits"))
                     then
                        Fail (Where & " says add: true with bits and"
                          & " access, and no omit");
                     end if;
                     Made.Add := True;
                     Made.Field_Access := US.To_Unbounded_String
                       (Member_String (Item, "access", Where));
                     if US.To_String (Made.Field_Access) not in
                       "read-write" | "read-only" | "write-only"
                       | "writeOnce" | "read-writeOnce"
                     then
                        Fail (Where & ".access is '"
                          & US.To_String (Made.Field_Access) & "', not one"
                          & " of the SVD's read-write, read-only,"
                          & " write-only, writeOnce or read-writeOnce");
                     end if;
                  elsif J.Is_Present (J.Member (Document, Item, "access")) then
                     Fail (Where & " gives access, which only a field it"
                       & " adds says");
                  end if;
                  Made.Key := US.To_Unbounded_String (Key);
                  Made.Source := US.To_Unbounded_String
                    (Member_String (Item, "source", Where));
                  if Made.Source = "" then
                     Fail (Where & ".source is empty: a correction says"
                       & " where its reviewer read it");
                  end if;
                  if J.Is_Present (J.Member (Document, Item, "omit")) then
                     if not J.Is_Kind
                         (Document, J.Member (Document, Item, "omit"),
                          J.True_Value)
                       or else J.Is_Present (J.Member (Document, Item, "bits"))
                     then
                        Fail (Where & " says omit: true, or gives bits");
                     end if;
                     Made.Omit := True;
                  else
                     declare
                        Said : constant String :=
                          Member_String (Item, "bits", Where);
                        Colon : Natural := 0;
                     begin
                        for Index in Said'Range loop
                           if Said (Index) = ':' then
                              Colon := Index;
                           end if;
                        end loop;
                        if Said'Length < 5 or else Colon = 0
                          or else Said (Said'First) /= '['
                          or else Said (Said'Last) /= ']'
                          or else not Is_Number
                            (Said (Said'First + 1 .. Colon - 1))
                          or else not Is_Number
                            (Said (Colon + 1 .. Said'Last - 1))
                          or else Number (Said (Said'First + 1 .. Colon - 1))
                            > 31
                          or else Number (Said (Colon + 1 .. Said'Last - 1))
                            > Number (Said (Said'First + 1 .. Colon - 1))
                        then
                           Fail (Where & ".bits is '" & Said & "', not"
                             & " [HIGH:LOW] within 32 bits");
                        end if;
                        Made.High := Natural
                          (Number (Said (Said'First + 1 .. Colon - 1)));
                        Made.Low := Natural
                          (Number (Said (Colon + 1 .. Said'Last - 1)));
                     end;
                  end if;
                  Into.Fields.Append (Made);
               end;
            end loop;
         end if;
      end;
      declare
         Corrections : constant J.Value :=
           J.Member (Document, Root, "register_corrections");
      begin
         if J.Is_Present (Corrections) then
            if not J.Is_Kind (Document, Corrections, J.Object_Value) then
               Fail ("the policy's register_corrections is not an object");
            end if;
            for Position in 1 .. J.Length (Document, Corrections) loop
               declare
                  Key : constant String :=
                    J.Key (Document, Corrections, Position);
                  Index : constant Natural := Find (Key);
                  Item : constant J.Value :=
                    J.Member_Value (Document, Corrections, Position);
                  Where : constant String := "register_corrections." & Key;
               begin
                  if Index = 0 then
                     Fail (Where & " names no selected register");
                  elsif not J.Is_Kind (Document, Item, J.Object_Value) then
                     Fail (Where & " is not an object of offset and source");
                  end if;
                  for Member in 1 .. J.Length (Document, Item) loop
                     if J.Key (Document, Item, Member) not in "offset"
                       | "source"
                     then
                        Fail (Where & " has the member '"
                          & J.Key (Document, Item, Member) & "'; a"
                          & " correction says offset and source");
                     end if;
                  end loop;
                  Into.Registers (Index).Has_Offset := True;
                  Into.Registers (Index).Offset :=
                    Mask_Of (Member_String (Item, "offset", Where),
                             Where & ".offset");
                  Into.Registers (Index).Offset_Source :=
                    US.To_Unbounded_String
                      (Member_String (Item, "source", Where));
                  if Into.Registers (Index).Offset mod 4 /= 0 then
                     Fail (Where & ".offset is not a multiple of four");
                  elsif Into.Registers (Index).Offset_Source = "" then
                     Fail (Where & ".source is empty: a correction says"
                       & " where its reviewer read it");
                  end if;
               end;
            end loop;
         end if;
      end;
      Read_Additions;
      declare
         Corrections : constant J.Value :=
           J.Member (Document, Root, "interrupt_corrections");
      begin
         if J.Is_Present (Corrections) then
            if not J.Is_Kind (Document, Corrections, J.Object_Value) then
               Fail ("the policy's interrupt_corrections is not an object");
            end if;
            for Position in 1 .. J.Length (Document, Corrections) loop
               declare
                  Name : constant String :=
                    J.Key (Document, Corrections, Position);
                  Item : constant J.Value :=
                    J.Member_Value (Document, Corrections, Position);
                  Where : constant String := "interrupt_corrections." & Name;
                  Made : Interrupt_Correction;
               begin
                  if not Is_Vendor_Name (Name) or else Name'Length > 64 then
                     Fail (Where & " does not name an interrupt as D542"
                       & " spells one: an ASCII letter and then at most 63"
                       & " letters, digits and underscores");
                  elsif not J.Is_Kind (Document, Item, J.Object_Value) then
                     Fail (Where & " is not an object of value or omit, and"
                       & " source");
                  end if;
                  for Member in 1 .. J.Length (Document, Item) loop
                     if J.Key (Document, Item, Member) not in "value" | "omit"
                       | "source"
                     then
                        Fail (Where & " has the member '"
                          & J.Key (Document, Item, Member) & "'; a"
                          & " correction says value or omit, and source");
                     end if;
                  end loop;
                  Made.Name := US.To_Unbounded_String (Name);
                  Made.Source := US.To_Unbounded_String
                    (Member_String (Item, "source", Where));
                  if Made.Source = ""
                    or else (for some C of US.To_String (Made.Source) =>
                               Character'Pos (C) < 32
                               or else Character'Pos (C) > 126)
                  then
                     Fail (Where & ".source is not printable ASCII text"
                       & " saying where its reviewer read it");
                  end if;
                  if J.Is_Present (J.Member (Document, Item, "omit")) then
                     if not J.Is_Kind
                         (Document, J.Member (Document, Item, "omit"),
                          J.True_Value)
                       or else J.Is_Present
                         (J.Member (Document, Item, "value"))
                     then
                        Fail (Where & " says omit: true, or gives a value");
                     end if;
                     Made.Omit := True;
                  else
                     declare
                        Said : constant J.Value :=
                          J.Member (Document, Item, "value");
                     begin
                        if not J.Is_Integer (Document, Said)
                          or else J.Integer_Of (Document, Said) < 0
                          or else J.Integer_Of (Document, Said) > 495
                        then
                           Fail (Where & ".value is not an interrupt number"
                             & " from 0 to 495");
                        end if;
                        Made.Value := Word (J.Integer_Of (Document, Said));
                     end;
                  end if;
                  Into.Interrupts.Append (Made);
               end;
            end loop;
         end if;
      end;
   exception
      when Refused =>
         Into := (others => <>);
   end Read;

   function Correction_Of (Of_Policy : Policy; Key : String) return Natural
   is
   begin
      for Index in 1 .. Of_Policy.Fields.Last_Index loop
         if US.To_String (Of_Policy.Fields (Index).Key) = Key then
            return Index;
         end if;
      end loop;
      return 0;
   end Correction_Of;

   function Core_Name (Core : Core_Choice) return String is
     (case Core is
         when From_Svd => "",
         when Hazard3 => "hazard3",
         when Esp_Rv32imc => "esp-rv32imc",
         when Esp_Rv32imac_Clic => "esp-rv32imac-clic",
         when Xtensa_LX6 => "xtensa-lx6",
         when Xtensa_LX7 => "xtensa-lx7");

   function Is_Numeric (Of_Policy : Policy; Key : String) return Boolean is
     (for some Field of Of_Policy.Numeric => Field = Key);

end Landin.Devices.Policies;
