with Ada.Characters.Handling;
with Ada.Strings.Fixed;

package body Landin.Targets.Firmware is

   function To_Name (Text : String) return Name_Text is
      Result : Name_Text;
   begin
      Result.Length := Text'Length;
      Result.Text (1 .. Text'Length) := Text;
      return Result;
   end To_Name;

   function Spelling (Name : Name_Text) return String is
     (Name.Text (1 .. Name.Length));

   function Is_Core_Name (Text : String) return Boolean is
     (Text in "cortex-m0" | "cortex-m0plus" | "cortex-m3" | "cortex-m4"
        | "cortex-m7");

   function Core_Named (Text : String) return Core_Kind is
     (if Text = "cortex-m0" then Cortex_M0
      elsif Text = "cortex-m0plus" then Cortex_M0plus
      elsif Text = "cortex-m3" then Cortex_M3
      elsif Text = "cortex-m4" then Cortex_M4
      else Cortex_M7);

   function Spelling (Core : Core_Kind) return String is
     (case Core is
        when Cortex_M0 => "cortex-m0",
        when Cortex_M0plus => "cortex-m0plus",
        when Cortex_M3 => "cortex-m3",
        when Cortex_M4 => "cortex-m4",
        when Cortex_M7 => "cortex-m7");

   function Level_Name (Core : Core_Kind) return String is
     (case Core is
        when Cortex_M0 | Cortex_M0plus => "armv6-m",
        when Cortex_M3 => "armv7-m",
        when Cortex_M4 | Cortex_M7 => "armv7e-m");

   function Rank (Level : String) return Natural;
   function Rank (Level : String) return Natural is
     (if Level = "armv6-m" then 1
      elsif Level = "armv7-m" then 2
      elsif Level = "armv7e-m" then 3
      else 0);

   function Executes (Core : Core_Kind; Level : String) return Boolean is
     (Rank (Level) /= 0 and then Rank (Level) <= Rank (Level_Name (Core)));

   function Lower_Levels (Core : Core_Kind) return String is
     (case Rank (Level_Name (Core)) is
        when 3 => "armv7e-m, armv7-m or armv6-m",
        when 2 => "armv7-m or armv6-m",
        when others => "armv6-m alone");

   function Is_Boot_Name (Text : String) return Boolean is
     (Text in "vector-table" | "rp2040-boot2" | "rp2350-image-block"
        | "esp-app-image");

   function Boot_Named (Text : String) return Boot_Kind is
     (if Text = "vector-table" then Vector_Table
      elsif Text = "rp2040-boot2" then RP2040_Boot2
      elsif Text = "rp2350-image-block" then RP2350_Image_Block
      else ESP_App_Image);

   function Spelling (Boot : Boot_Kind) return String is
     (case Boot is
        when Vector_Table => "vector-table",
        when RP2040_Boot2 => "rp2040-boot2",
        when RP2350_Image_Block => "rp2350-image-block",
        when ESP_App_Image => "esp-app-image");

   function Stage_Checksum (Bytes : String) return Checksum is
      Result : Checksum := 16#FFFF_FFFF#;
   begin
      for Byte of Bytes loop
         Result := Result xor
           Checksum (Character'Pos (Byte)) * 2 ** 24;
         for Bit in 1 .. 8 loop
            Result :=
              (if (Result and 16#8000_0000#) /= 0
               then (Result * 2) xor 16#04C1_1DB7#
               else Result * 2);
         end loop;
      end loop;
      return Result;
   end Stage_Checksum;

   function Is_Section_Name (Word : String) return Boolean is
     (Word in "vectors" | "text" | "rodata" | "data" | "bss" | "stack");

   function Section_Named (Word : String) return Section_Kind is
     (if Word = "vectors" then Vectors
      elsif Word = "text" then Text
      elsif Word = "rodata" then Rodata
      elsif Word = "data" then Data
      elsif Word = "bss" then BSS
      else Stack);

   function Spelling (Section : Section_Kind) return String is
     (case Section is
        when Vectors => "vectors",
        when Text => "text",
        when Rodata => "rodata",
        when Data => "data",
        when BSS => "bss",
        when Stack => "stack");

   function Access_Named (Text : String) return Access_Kind is
     (if Text = "rx" then Read_Execute
      elsif Text = "rw" then Read_Write
      else Read_Write_Execute);

   function Region_Named
     (Of_Profile : Profile; Name : String) return Region_Count is
   begin
      for Index in 1 .. Of_Profile.Count loop
         if Spelling (Of_Profile.Regions (Index).Name) = Name then
            return Index;
         end if;
      end loop;
      return 0;
   end Region_Named;

   function Placed_Region
     (Of_Profile : Profile; Section : Section_Kind) return Region is
     (Of_Profile.Regions (Of_Profile.Placed (Section)));

   function Vector_Alignment (Of_Profile : Profile) return Byte_Count is
      Result : Byte_Count := 128;
   begin
      while Result < Vector_Bytes (Of_Profile) loop
         Result := Result * 2;
      end loop;
      return Result;
   end Vector_Alignment;

   function Vector_Address (Of_Profile : Profile) return Byte_Count is
     (Placed_Region (Of_Profile, Vectors).Origin
      + Boot_Prefix (Of_Profile.Boot));

   function Flash_Capacity (Of_Profile : Profile) return Byte_Count is
     (if Of_Profile.Placed (Text) = 0 then 0
      else Placed_Region (Of_Profile, Text).Length);

   function Static_RAM_Capacity (Of_Profile : Profile) return Byte_Count is
     (if Of_Profile.Placed (Data) = 0 then 0
      elsif Of_Profile.Placed (Stack) = Of_Profile.Placed (Data)
      then Placed_Region (Of_Profile, Data).Length - Of_Profile.Stack_Size
      else Placed_Region (Of_Profile, Data).Length);

   function Budget (Of_Profile : Profile) return Image_Budget is
     ((Initialized => Flash_Capacity (Of_Profile),
       Writable    => (if Of_Profile.Placed (Data) = 0 then 0
                       else Placed_Region (Of_Profile, Data).Length),
       Reserved    => Maximum_Object_Size (Cortex_M)));

   function Profile_Name (Of_Profile : Profile) return String is
     (if Of_Profile.Reference then "constrained reference profile"
      else Spelling (Of_Profile.Device) & " profile");

   function Assembly_Error
     (Text : String; Naked : Boolean;
      Level : Landin.Targets.Levels.Feature_Level) return String
   is
      Start : Integer := Text'First;
      Seen : Boolean := False;
      Thumb2 : constant Boolean := Landin.Targets.Levels.Has
        (Level, Landin.Targets.Levels.Thumb2);

      --  The assembler checks the selected .arch, but ordinary blocks must
      --  remain straight-line before emission at every level.  UDF and BKPT
      --  enter exception handling and are refused in ordinary blocks.
      function Transfers_Control (Mnemonic : String) return Boolean;

      function Transfers_Control (Mnemonic : String) return Boolean is
         Dot : constant Natural := Ada.Strings.Fixed.Index (Mnemonic, ".");
         Base : constant String :=
           (if Dot = 0 then Mnemonic
            else Mnemonic (Mnemonic'First .. Dot - 1));
      begin
         return Base in "b" | "beq" | "bne" | "bcs" | "bcc" | "bhs"
           | "blo" | "bmi" | "bpl" | "bvs" | "bvc" | "bhi" | "bls"
           | "bge" | "blt" | "bgt" | "ble" | "bal" | "bnv"
           | "bl" | "blx" | "bx"
           | "bxj" | "cbz" | "cbnz" | "tbb" | "tbh" | "pop" | "push"
           | "rfe" | "srs" | "eret" | "udf" | "bkpt"
           or else (Base'Length >= 2 and then Base (Base'First ..
             Base'First + 1) = "it");
      end Transfers_Control;

      function Check_Line (Line : String) return String;

      function Check_Line (Line : String) return String is
         Clean : constant String := Ada.Strings.Fixed.Trim
           (Ada.Characters.Handling.To_Lower (Line), Ada.Strings.Both);
         Stop : Natural := Clean'First;
      begin
         if Clean'Length = 0 then
            return "";
         end if;
         Seen := True;
         if Clean (Clean'First) = '.'
           or else Ada.Strings.Fixed.Index (Clean, ";") /= 0
           or else Ada.Strings.Fixed.Index (Clean, "@") /= 0
           or else Ada.Strings.Fixed.Index (Clean, "/*") /= 0
           or else Ada.Strings.Fixed.Index (Clean, "//") /= 0
         then
            return "assembly directives and statement separators refuse";
         end if;
         if Naked then
            declare
               Colon : constant Natural :=
                 Ada.Strings.Fixed.Index (Clean, ":");
            begin
               if Colon /= 0 then
                  if Colon = Clean'First or else
                    (for some C of Clean (Clean'First .. Colon - 1) =>
                       C not in 'a' .. 'z' | '0' .. '9' | '_')
                  then
                     return "a naked label requires an ASCII identifier";
                  end if;
                  return Check_Line (Clean (Colon + 1 .. Clean'Last));
               end if;
            end;
         end if;
         if not Naked and then Ada.Strings.Fixed.Index (Clean, ":") /= 0
         then
            return "ordinary assembly is straight-line and defines no label";
         end if;
         while Stop <= Clean'Last and then Clean (Stop) not in ' ' | ASCII.HT
         loop
            Stop := Stop + 1;
         end loop;
         declare
            Mnemonic : constant String := Clean (Clean'First .. Stop - 1);
            Dot : constant Natural := Ada.Strings.Fixed.Index (Mnemonic, ".");
            Base : constant String :=
              (if Dot = 0 then Mnemonic
               else Mnemonic (Mnemonic'First .. Dot - 1));
         begin
            if (not Thumb2
              and then Mnemonic not in "nop" | "wfi" | "wfe" | "sev" | "yield"
              | "cpsid" | "cpsie" | "dmb" | "dsb" | "isb" | "mrs" | "msr"
              | "mov" | "movs" | "ldr" | "ldrb" | "ldrh" | "ldrsb"
              | "ldrsh" | "str" | "strb" | "strh" | "adds" | "subs"
              | "ands" | "orrs" | "eors" | "bics" | "mvns" | "lsls"
              | "lsrs" | "asrs" | "rors" | "adcs" | "sbcs" | "muls"
              | "rsbs" | "cmp" | "cmn" | "tst" | "rev" | "rev16"
              | "revsh" | "sxtb" | "sxth" | "uxtb" | "uxth" | "svc"
              and then (not Naked or else Mnemonic not in
                "b" | "beq" | "bne" | "bcs" | "bcc" | "bhs" | "blo"
                | "bmi" | "bpl" | "bvs" | "bvc" | "bhi" | "bls"
                | "bge" | "blt" | "bgt" | "ble" | "bl" | "blx"
                | "bx" | "push" | "pop" | "udf" | "ldm" | "ldmia" | "stm"
                | "stmia"))
              or else (not Naked and then Transfers_Control (Mnemonic))
            then
               return
                 (if Thumb2
                  then "ordinary assembly requires straight-line control"
                    & " flow"
                  else "assembly requires enabled M0 instructions; ordinary"
                    & " blocks require straight-line control flow");
            end if;
            declare
               Tail : constant String := Ada.Strings.Fixed.Trim
                 (Clean (Stop .. Clean'Last), Ada.Strings.Both);
               Comma : constant Natural :=
                 Ada.Strings.Fixed.Index (Tail, ",");
            begin
               if Base in "cpsid" | "cpsie"
                 and then Tail /= "i"
                 and then (not Thumb2 or else Tail /= "f")
               then
                  return "Cortex-M CPS requires i or an enabled f mask";
               elsif Base in "dmb" | "dsb" | "isb"
                 and then Tail not in "" | "sy"
               then
                  return "Cortex-M0 barriers require the sy domain";
               elsif Base in "mrs" | "msr" and then Comma /= 0 then
                  declare
                     Register : constant String := Ada.Strings.Fixed.Trim
                       ((if Base = "mrs"
                         then Tail (Comma + 1 .. Tail'Last)
                         else Tail (Tail'First .. Comma - 1)),
                        Ada.Strings.Both);
                     Readable : constant Boolean := Register in
                       "apsr" | "ipsr" | "epsr" | "iapsr" | "eapsr"
                         | "iepsr" | "xpsr" | "primask"
                       or else (Thumb2 and then Register in
                         "basepri" | "faultmask");
                     Writable : constant Boolean :=
                       Register in "apsr_nzcvq" | "primask"
                       or else (Thumb2 and then Register in
                         "basepri" | "basepri_max" | "faultmask");
                  begin
                     if not ((Base = "mrs" and Readable)
                       or else (Base = "msr" and Writable)
                       or else (Naked and then Register in
                         "msp" | "psp" | "control"))
                     then
                        return "unsupported Cortex-M system register";
                     end if;
                  end;
               end if;
            end;
         end;
         if Naked then
            return "";
         end if;
         while Stop <= Clean'Last loop
            if Clean (Stop) in 'a' .. 'z' | '_' then
               declare
                  First : constant Natural := Stop;
               begin
                  while Stop <= Clean'Last
                    and then Clean (Stop) in 'a' .. 'z' | '0' .. '9' | '_'
                  loop
                     Stop := Stop + 1;
                  end loop;
                  declare
                     Word : constant String := Clean (First .. Stop - 1);
                  begin
                     if Word in "r8" | "r9" | "r10" | "r11" | "r12"
                       | "r13" | "r14" | "r15" | "sp" | "lr" | "pc"
                       | "fp" | "ip" | "sl" | "sb" | "msp" | "psp"
                       | "control" | "v1" | "v2" | "v3" | "v4" | "v5"
                       | "v6" | "v7" | "v8"
                     then
                        return "assembly cannot alter frame, stack or"
                          & " reserved registers outside a naked body";
                     end if;
                  end;
               end;
            else
               Stop := Stop + 1;
            end if;
         end loop;
         return "";
      end Check_Line;
   begin
      if Text'Length > 4096 then
         return "one assembly block exceeds 4096 bytes";
      end if;
      for Index in Text'Range loop
         if Text (Index) not in ASCII.HT | ASCII.LF | ' ' .. '~' then
            return "assembly text requires ASCII instructions and LF lines";
         end if;
         if Text (Index) = ASCII.LF then
            declare
               Fault : constant String :=
                 Check_Line (Text (Start .. Index - 1));
            begin
               if Fault /= "" then
                  return Fault;
               end if;
            end;
            Start := Index + 1;
         end if;
      end loop;
      declare
         Fault : constant String := Check_Line (Text (Start .. Text'Last));
      begin
         if Fault /= "" then
            return Fault;
         end if;
      end;
      return (if Seen then "" else "assembly block must contain instructions");
   end Assembly_Error;
end Landin.Targets.Firmware;
