package body Landin.Packed is

   function Mask (Bits : Width) return Image is
     (if Bits = 64 then Image'Last else 2 ** Bits - 1);

   function Fits (Value : Image; Bits : Width) return Boolean is
     (Value <= Mask (Bits));

   function Fits (Part : Field; Bits : Width) return Boolean is
     (Part.First < Bits
      and then Part.Count <= (Bits - Part.First) / Part.Bits);

   function Field_Mask (Part : Field) return Image;

   function Field_Mask (Part : Field) return Image is
   begin
      if not Fits (Part, 64) then
         raise Landin.Compiler_Defect with "invalid packed field extent";
      end if;
      return Mask (Part.Bits * Part.Count) * 2 ** Part.First;
   end Field_Mask;

   function Valid (Fields : Field_Array; Bits : Width) return Boolean is
      Used : Image := 0;
   begin
      if Fields'Length = 0 then
         return False;
      end if;
      for Part of Fields loop
         if not Fits (Part, Bits) then
            return False;
         end if;
         declare
            Selected : constant Image := Field_Mask (Part);
         begin
            if (Selected and Used) /= 0 then
               return False;
            end if;
            Used := Used or Selected;
         end;
      end loop;
      return True;
   end Valid;

   function Claimed (Fields : Field_Array; Bits : Width) return Image is
      Used : Image := 0;
   begin
      if not Valid (Fields, Bits) then
         raise Landin.Compiler_Defect with "invalid packed layout";
      end if;
      for Part of Fields loop
         Used := Used or Field_Mask (Part);
      end loop;
      return Used;
   end Claimed;

   function Element_Position (Part : Field; Index : Natural) return Position;

   function Element_Position (Part : Field; Index : Natural) return Position is
   begin
      if not Fits (Part, 64) or else Index >= Part.Count then
         raise Landin.Compiler_Defect with "invalid packed element index";
      end if;
      return Part.First + Part.Bits * Index;
   end Element_Position;

   function Extract
     (Raw : Image; Part : Field; Index : Natural := 0) return Image
   is
      Shift : constant Position := Element_Position (Part, Index);
   begin
      return (Raw / 2 ** Shift) and Mask (Part.Bits);
   end Extract;

   function Insert
     (Raw, Value : Image; Part : Field; Index : Natural := 0) return Image
   is
      Shift : constant Position := Element_Position (Part, Index);
      Selected : constant Image := Mask (Part.Bits) * 2 ** Shift;
   begin
      if not Fits (Value, Part.Bits) then
         raise Landin.Compiler_Defect with "packed insertion would truncate";
      end if;
      return (Raw and not Selected) or Value * 2 ** Shift;
   end Insert;

   function Valid_Encodings
     (Values : Encoding_Array; Bits : Width) return Boolean is
   begin
      if Values'Length = 0 then
         return False;
      end if;
      for I in Values'Range loop
         if not Fits (Values (I), Bits) then
            return False;
         end if;
         for J in Values'First .. I - 1 loop
            if Values (I) = Values (J) then
               return False;
            end if;
         end loop;
      end loop;
      return True;
   end Valid_Encodings;

   function Contains (Values : Encoding_Array; Raw : Image) return Boolean is
   begin
      for Value of Values loop
         if Value = Raw then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

   function Valid_Contract (Contract : Register_Contract) return Boolean;

   function Valid_Contract (Contract : Register_Contract) return Boolean is
     (Contract.Bits in 8 | 16 | 32 | 64
      and then Fits (Contract.Named, Contract.Bits)
      and then (Contract.Write /= One_Clears
                or else Contract.Reserved = Write_Zero));

   function Plan
     (Contract : Register_Contract; Form : Access_Form) return Access_Plan is
   begin
      if not Valid_Contract (Contract) then
         return (others => <>);
      end if;
      case Form is
         when Read_Image =>
            if Contract.Read /= No_Read then
               return (Allowed => True, Reads => 1, Writes => 0);
            end if;
         when Write_Image =>
            if Contract.Write /= No_Write then
               return (Allowed => True, Reads => 0, Writes => 1);
            end if;
         when Update_Field =>
            null;
      end case;
      return (others => <>);
   end Plan;

   function Legal_Write
     (Contract : Register_Contract; Raw : Image) return Boolean
   is
      Unnamed : constant Image := Mask (Contract.Bits) and not Contract.Named;
   begin
      if not Plan (Contract, Write_Image).Allowed
        or else not Fits (Raw, Contract.Bits)
      then
         return False;
      end if;
      case Contract.Reserved is
         when Preserve => return True;
         when Write_Zero => return (Raw and Unnamed) = 0;
         when Write_One => return (Raw and Unnamed) = Unnamed;
      end case;
   end Legal_Write;

end Landin.Packed;
