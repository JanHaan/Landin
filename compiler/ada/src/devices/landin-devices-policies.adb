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
      if not Is_Vendor_Name (US.To_String (Into.Device)) then
         Fail ("the policy's device is not a vendor name: an ASCII letter,"
           & " then letters, digits and underscores");
      end if;
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
   exception
      when Refused =>
         Into := (others => <>);
   end Read;

   function Is_Numeric (Of_Policy : Policy; Key : String) return Boolean is
     (for some Field of Of_Policy.Numeric => Field = Key);

end Landin.Devices.Policies;
