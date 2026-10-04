with Ada.Characters.Handling;
with Ada.Strings.Fixed;

package body Landin.Targets.Firmware is
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
                | "bx" | "push" | "pop" | "udf"))
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
