with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Types;

package body Landin.Backend.X86_64 is

   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Targets.Bit_Width;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.Scalar_Size;
   use type Landin.IR.Atom_Set_Id;
   use type Landin.IR.Block_Id;
   use type Landin.IR.Declaration_Id;
   use type Landin.IR.Item_Kind;
   use type Landin.IR.Item_Id;
   use type Landin.IR.Nominal_Type_Id;
   use type Landin.IR.Opcode;
   use type Landin.IR.Parameter_Convention;
   use type Landin.IR.Signature_Id;
   use type Landin.IR.Slot_Id;
   use type Landin.IR.Value_Id;
   use type Landin.IR.Element_Total;
   use type Landin.IR.Field_Image_Form;
   use type Landin.IR.Field_Shape_Kind;
   use type Landin.Types.Folded;
   use type Landin.Types.Magnitude;
   use type Landin.Types.Type_Kind;

   LF : constant Character := Character'Val (10);

   --  `Image` leads with a blank for a non-negative number and assembly
   --  is bytes, so the blank is a byte.  Landin.IR.Dump's trim, for the
   --  same reason.
   function Trimmed (Value : String) return String
     is (Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both));

   --  A source atom identity is neutral.  Linux x86-64 gives atoms dense,
   --  nonzero u32 codes in declaration-identity order; zero stays available
   --  for the successful half of R2.30's failing-call carrier.
   function Atom_Code
     (Of_Unit : Landin.IR.Unit;
      Identity : Landin.IR.Declaration_Id) return Positive;

   function Atom_Code
     (Of_Unit : Landin.IR.Unit;
      Identity : Landin.IR.Declaration_Id) return Positive
   is
      Result : Natural := 0;

      function Is_Atom
        (Candidate : Landin.IR.Declaration_Id) return Boolean;

      function Is_Atom
        (Candidate : Landin.IR.Declaration_Id) return Boolean
      is
      begin
         for Set_Index in 1 .. Landin.IR.Atom_Set_Count (Of_Unit) loop
            declare
               Set_Id : constant Landin.IR.Atom_Set_Id :=
                 Landin.IR.Atom_Set_Id (Set_Index);
            begin
               for Index in 1 .. Landin.IR.Atom_Count (Of_Unit, Set_Id) loop
                  if Landin.IR.Nth_Atom (Of_Unit, Set_Id, Index)
                    = Candidate
                  then
                     return True;
                  end if;
               end loop;
            end;
         end loop;
         return False;
      end Is_Atom;
   begin
      for Candidate in Landin.IR.Declaration_Id'(1) .. Identity loop
         if Is_Atom (Candidate) then
            Result := Result + 1;
         end if;
      end loop;
      if Result = 0 then
         raise Landin.Compiler_Defect with
           "an atom instruction names no atom-set member";
      end if;
      return Positive (Result);
   end Atom_Code;

   subtype Held_Size is Landin.Targets.Scalar_Size
     range Landin.Targets.Byte_1 .. Landin.Targets.Byte_8;

   --  A datum's value, held as the bit pattern the target will store.  A
   --  module value is folded rather than run [1940], and `Landin.IR`'s own
   --  header says why the folding lands here: the checker declines the
   --  bitwise and shift levels because [0320]'s zero-fill needs a width,
   --  and a width needs a target.  This is that width's side of the seam.
   --
   --  The widest enabled type is 64 bits, so one modular type covers every
   --  fold and narrower ones are masked back to their own width after each
   --  operation.  This asks the host nothing: the modulus is written out,
   --  exactly as `Landin.Types.Folded`'s bound is.
   type Pattern is mod 2 ** 64;

   function Mask
     (Value : Pattern; Bits : Landin.Targets.Bit_Width) return Pattern
     is (if Bits >= 64 then Value
         else Value and (2 ** Natural (Bits) - 1));

   --  Whether a pattern's top bit is set at that width, which for a signed
   --  type is what makes it negative.
   function Is_Negative
     (Value : Pattern; Bits : Landin.Targets.Bit_Width) return Boolean
     is ((Value and 2 ** (Natural (Bits) - 1)) /= 0);

   --  A number read as the pattern the target stores, and back again.  A
   --  fold works in numbers, because a module value has no moment in which
   --  to trap [1460] and so the whole expression is worked out before any
   --  type is asked to hold it; these two are for the operators that are
   --  about a width rather than about a number -- the wrapping forms, the
   --  bitwise set and the shifts.
   function To_Pattern
     (Value : Landin.Types.Folded;
      Bits  : Landin.Targets.Bit_Width) return Pattern
     is (if Value < 0
         then Mask (0 - Pattern (-Value), Bits)
         else Mask (Pattern (Value), Bits));

   function As_Number
     (Value  : Pattern;
      Bits   : Landin.Targets.Bit_Width;
      Signed : Boolean) return Landin.Types.Folded
     is (if Signed and then Is_Negative (Value, Bits)
         then -Landin.Types.Folded (Mask (0 - Value, Bits))
         else Landin.Types.Folded (Value));

   --  How wide a fold works at.  `Landin.Types.Width` answers for the
   --  enabled integers only, and a bool is [1870]'s zero or one in the byte
   --  `Landin.Backend` gives it, so it folds at that byte's width.
   function Fold_Width
     (Kind : Landin.Types.Scalar_Name;
      Facts : Landin.Targets.Target_Facts) return Landin.Targets.Bit_Width
     is (if Kind in Landin.Types.Integer_Name
         then Landin.Types.Width (Landin.Types.Integer_Name (Kind), Facts)
         else 8);

   --  The suffix that makes an instruction operate at one width, and the
   --  accumulator named at that width.  One accumulator is all this shape
   --  needs; see the header.
   function Suffix (Size : Held_Size) return String
     is (case Size is
            when Landin.Targets.Byte_1 => "b",
            when Landin.Targets.Byte_2 => "w",
            when Landin.Targets.Byte_4 => "l",
            when Landin.Targets.Byte_8 => "q");

   function Accumulator (Size : Held_Size) return String
     is (case Size is
            when Landin.Targets.Byte_1 => "%al",
            when Landin.Targets.Byte_2 => "%ax",
            when Landin.Targets.Byte_4 => "%eax",
            when Landin.Targets.Byte_8 => "%rax");

   --  The internal scalar convention uses the System V integer registers
   --  in their ordinary order, then one eight-byte stack slot per remaining
   --  argument.  R4.40 owns C's complete classification; this is only the
   --  scalar convention the enabled Landin kernel needs.  Naming the prefix
   --  once keeps caller and callee placement in agreement.
   Register_Arguments : constant := 6;

   function Argument_Register
     (Index : Positive; Size : Held_Size) return String
     is (case Index is
            when 1 =>
              (case Size is
                  when Landin.Targets.Byte_1 => "%dil",
                  when Landin.Targets.Byte_2 => "%di",
                  when Landin.Targets.Byte_4 => "%edi",
                  when Landin.Targets.Byte_8 => "%rdi"),
            when 2 =>
              (case Size is
                  when Landin.Targets.Byte_1 => "%sil",
                  when Landin.Targets.Byte_2 => "%si",
                  when Landin.Targets.Byte_4 => "%esi",
                  when Landin.Targets.Byte_8 => "%rsi"),
            when 3 =>
              (case Size is
                  when Landin.Targets.Byte_1 => "%dl",
                  when Landin.Targets.Byte_2 => "%dx",
                  when Landin.Targets.Byte_4 => "%edx",
                  when Landin.Targets.Byte_8 => "%rdx"),
            when 4 =>
              (case Size is
                  when Landin.Targets.Byte_1 => "%cl",
                  when Landin.Targets.Byte_2 => "%cx",
                  when Landin.Targets.Byte_4 => "%ecx",
                  when Landin.Targets.Byte_8 => "%rcx"),
            when 5 =>
              (case Size is
                  when Landin.Targets.Byte_1 => "%r8b",
                  when Landin.Targets.Byte_2 => "%r8w",
                  when Landin.Targets.Byte_4 => "%r8d",
                  when Landin.Targets.Byte_8 => "%r8"),
            when 6 =>
              (case Size is
                  when Landin.Targets.Byte_1 => "%r9b",
                  when Landin.Targets.Byte_2 => "%r9w",
                  when Landin.Targets.Byte_4 => "%r9d",
                  when Landin.Targets.Byte_8 => "%r9"),
            when others =>
              raise Compiler_Defect
                with "an argument register index is outside its ABI run");

   Stack_Argument_Bytes : constant Landin.Targets.Byte_Count := 8;

   ------------------------------------------------------------------
   --  Text
   ------------------------------------------------------------------

   function Frame_Is_Addressable
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts) return Boolean
   is
      Largest_Displacement : constant Landin.Targets.Byte_Count :=
        2 ** 31 - 1;
      Layout : Frame;
   begin
      if Landin.IR.Is_External (Of_Unit, Item) then
         return True;
      end if;
      Layout := Laid_Out (Of_Unit, Item, Facts);
      return Extent (Layout) <= Largest_Displacement;
   exception
      when Constraint_Error | Landin.Compiler_Defect =>
         --  Laid_Out uses target-width arithmetic.  Overflow says the frame
         --  does not fit even the target address space, and is a backend
         --  capability answer here rather than a compiler failure.  Align_Up
         --  names that overflow a defect in general; this preflight is the
         --  place where an accepted, too-wide frame makes it expected.
         return False;
   end Frame_Is_Addressable;

   function Text
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table;
      Facts    : Landin.Targets.Target_Facts;
      Hosted_Entry : Landin.IR.Item_Id := Landin.IR.No_Item) return String
   is
      Out_Text : Unbounded.Unbounded_String;

      procedure Put (Line : String);

      procedure Put (Line : String) is
      begin
         Unbounded.Append (Out_Text, Line & LF);
      end Put;

      procedure Emit (Instruction : String);

      procedure Emit (Instruction : String) is
      begin
         Put (Character'Val (9) & Instruction);
      end Emit;

      --  A unique declared item's symbol remains its readable source
      --  spelling.  Two modules may legally declare the same short name, so
      --  a collision receives a deterministic whole-program declaration
      --  prefix.  The same applies to names used by the compiler's hosted
      --  libc shims: a Landin declaration called `open` must not interpose on
      --  the shim's call to libc.  The selected hosted entry and C extern
      --  names retain their platform ABI spellings.  An anonymous routine
      --  instead receives one assembler-local name derived only from its
      --  Unit item identity.
      function Symbol (Item : Landin.IR.Item_Id) return String;
      function Evidence_Symbol (Id : Landin.IR.Evidence_Id) return String;
      function Is_Public_Item (Item : Landin.IR.Item_Id) return Boolean;

      function Is_Hosted_Dependency (Spelling : String) return Boolean
        is (Spelling = "strlen"
            or else Spelling = "open"
            or else Spelling = "read"
            or else Spelling = "write"
            or else Spelling = "close"
            or else Spelling = "__errno_location");

      function Symbol (Item : Landin.IR.Item_Id) return String is
         Declared : constant Landin.IR.Declaration_Id :=
           Landin.IR.Declares (Of_Unit, Item);
      begin
         if Declared = Landin.IR.No_Declaration then
            return ".Llandin_anonymous_"
              & Trimmed (Landin.IR.Item_Id'Image (Item));
         end if;
         declare
            Spelling : constant String :=
              Landin.Source.Names.Spelling
                (Names, Landin.Resolution.Name_Of (Meanings, Declared));
            Collides : Boolean :=
              Hosted_Entry /= Landin.IR.No_Item
              and then Is_Hosted_Dependency (Spelling);
         begin
            if Item = Hosted_Entry or else Landin.IR.Is_External
              (Of_Unit, Item)
            then
               return Spelling;
            end if;

            for Position in 1 .. Landin.IR.Item_Count (Of_Unit) loop
               declare
                  Other : constant Landin.IR.Item_Id :=
                    Landin.IR.Item_Id (Position);
                  Other_Declaration : constant Landin.IR.Declaration_Id :=
                    Landin.IR.Declares (Of_Unit, Other);
               begin
                  if Other /= Item
                    and then Other_Declaration /= Landin.IR.No_Declaration
                    and then Landin.Source.Names.Spelling
                      (Names,
                       Landin.Resolution.Name_Of
                         (Meanings, Other_Declaration)) = Spelling
                  then
                     Collides := True;
                     exit;
                  end if;
               end;
            end loop;

            if Collides then
               return "landin_"
                 & Trimmed (Landin.IR.Declaration_Id'Image (Declared))
                 & "_" & Spelling;
            end if;
            return Spelling;
         end;
      end Symbol;

      function Evidence_Symbol (Id : Landin.IR.Evidence_Id) return String
        is (".Llandin_evidence_"
            & Trimmed (Landin.IR.Evidence_Id'Image (Id)));

      function Is_Public_Item (Item : Landin.IR.Item_Id) return Boolean
      is
         Declared : constant Landin.IR.Declaration_Id :=
           Landin.IR.Declares (Of_Unit, Item);
      begin
         return Declared /= Landin.IR.No_Declaration
           and then Landin.Resolution.Is_Public (Meanings, Declared);
      end Is_Public_Item;

      --  Labels carry the item, because a Block_Id restarts at 1 in the
      --  next item and two blocks named `.L1` would be one label.
      function Label
        (Item : Landin.IR.Item_Id; Block : Landin.IR.Block_Id)
        return String
        is (".L" & Trimmed (Landin.IR.Item_Id'Image (Item))
            & "_" & Trimmed (Landin.IR.Block_Id'Image (Block)));

      --  R2.70's baseline sharing is representation-class sharing: two
      --  concrete views may use one machine body only when every retained
      --  operation has the same physical meaning.  Evidence identity may
      --  differ, because the hidden table parameter supplies that choice;
      --  signed arithmetic and every operation carrying another concrete
      --  identity remain separate rather than being guessed equivalent.
      Shared_With : array
        (1 .. Positive'Max (1, Landin.IR.Item_Count (Of_Unit))) of
          Landin.IR.Item_Id := [others => Landin.IR.No_Item];

      function Carriers_Agree
        (Left, Right : Landin.Types.Type_Kind) return Boolean;
      function Signatures_Have_One_ABI
        (Left, Right : Landin.IR.Signature_Id;
         Limit       : Natural) return Boolean;
      function Routines_Can_Share
        (Left, Right : Landin.IR.Item_Id) return Boolean;

      function Carriers_Agree
        (Left, Right : Landin.Types.Type_Kind) return Boolean
      is
      begin
         if Left = Right then
            return True;
         elsif Left in Landin.Types.Scalar_Name
           and then Right in Landin.Types.Scalar_Name
         then
            if Left in Landin.Types.Float_Name
              or else Right in Landin.Types.Float_Name
            then
               return False;
            end if;
            return Landin.Types.Storage_Size
              (Landin.Types.Scalar_Name (Left), Facts)
              = Landin.Types.Storage_Size
                  (Landin.Types.Scalar_Name (Right), Facts);
         end if;
         return False;
      end Carriers_Agree;

      function Signatures_Have_One_ABI
        (Left, Right : Landin.IR.Signature_Id;
         Limit       : Natural) return Boolean
      is
         function Parts_Agree
           (A, B : Landin.IR.Signature_Part) return Boolean;

         function Parts_Agree
           (A, B : Landin.IR.Signature_Part) return Boolean
         is
         begin
            if A.Convention /= B.Convention
              or else A.Escaping /= B.Escaping
              or else not Carriers_Agree (A.Kind, B.Kind)
            then
               return False;
            elsif A.Kind = Landin.Types.Function_Value then
               return Limit > 0
                 and then Signatures_Have_One_ABI
                   (A.Signature, B.Signature, Limit - 1);
            elsif A.Kind in Landin.Types.Aggregate
                                | Landin.Types.Fixed_Array
            then
               return A.Kind = B.Kind
                 and then A.Length = B.Length
                 and then A.Element = B.Element
                 and then A.Nominal = B.Nominal;
            end if;
            return True;
         end Parts_Agree;
      begin
         if Left = Right then
            return True;
         elsif Limit = 0
           or else Landin.IR.Signature_Parameter_Count (Of_Unit, Left)
             /= Landin.IR.Signature_Parameter_Count (Of_Unit, Right)
           or else Landin.IR.Signature_Result_Count (Of_Unit, Left)
             /= Landin.IR.Signature_Result_Count (Of_Unit, Right)
           or else
             ((Landin.IR.Signature_Errors (Of_Unit, Left)
                 = Landin.IR.No_Atom_Set)
              /= (Landin.IR.Signature_Errors (Of_Unit, Right)
                    = Landin.IR.No_Atom_Set))
         then
            return False;
         end if;
         if Landin.IR.Signature_Errors (Of_Unit, Left)
              /= Landin.IR.No_Atom_Set
           and then not Landin.IR.Atom_Sets_Agree
             (Of_Unit,
              Landin.IR.Signature_Errors (Of_Unit, Left),
              Landin.IR.Signature_Errors (Of_Unit, Right))
         then
            return False;
         end if;
         for Index in 1 .. Landin.IR.Signature_Parameter_Count
           (Of_Unit, Left)
         loop
            if not Parts_Agree
              (Landin.IR.Nth_Signature_Parameter (Of_Unit, Left, Index),
               Landin.IR.Nth_Signature_Parameter (Of_Unit, Right, Index))
            then
               return False;
            end if;
         end loop;
         for Index in 1 .. Landin.IR.Signature_Result_Count
           (Of_Unit, Left)
         loop
            if not Parts_Agree
              (Landin.IR.Nth_Signature_Result (Of_Unit, Left, Index),
               Landin.IR.Nth_Signature_Result (Of_Unit, Right, Index))
            then
               return False;
            end if;
         end loop;
         return True;
      end Signatures_Have_One_ABI;

      function Routines_Can_Share
        (Left, Right : Landin.IR.Item_Id) return Boolean
      is
      begin
         if Landin.IR.Generic_Template_Of (Of_Unit, Left)
              = Landin.IR.No_Declaration
           or else Landin.IR.Generic_Template_Of (Of_Unit, Left)
             /= Landin.IR.Generic_Template_Of (Of_Unit, Right)
           or else Landin.IR.Slot_Count (Of_Unit, Left)
             /= Landin.IR.Slot_Count (Of_Unit, Right)
           or else Landin.IR.Block_Count (Of_Unit, Left)
             /= Landin.IR.Block_Count (Of_Unit, Right)
           or else not Signatures_Have_One_ABI
             (Landin.IR.Signature_Of (Of_Unit, Left),
              Landin.IR.Signature_Of (Of_Unit, Right),
              Landin.IR.Signature_Count (Of_Unit) + 1)
         then
            return False;
         end if;
         for Slot in 1 .. Landin.IR.Slot_Count (Of_Unit, Left) loop
            if Landin.IR.Is_Aggregate
                 (Of_Unit, Left, Landin.IR.Slot_Id (Slot))
              or else Landin.IR.Is_Array
                (Of_Unit, Left, Landin.IR.Slot_Id (Slot))
              or else Landin.IR.Is_Address
                (Of_Unit, Left, Landin.IR.Slot_Id (Slot))
              or else Landin.IR.Is_Aggregate
                (Of_Unit, Right, Landin.IR.Slot_Id (Slot))
              or else Landin.IR.Is_Array
                (Of_Unit, Right, Landin.IR.Slot_Id (Slot))
              or else Landin.IR.Is_Address
                (Of_Unit, Right, Landin.IR.Slot_Id (Slot))
              or else not Carriers_Agree
                (Landin.IR.Type_Of
                   (Of_Unit, Left, Landin.IR.Slot_Id (Slot)),
                 Landin.IR.Type_Of
                   (Of_Unit, Right, Landin.IR.Slot_Id (Slot)))
            then
               return False;
            end if;
         end loop;
         for Block in 1 .. Landin.IR.Block_Count (Of_Unit, Left) loop
            if Landin.IR.Length
                 (Of_Unit, Left, Landin.IR.Block_Id (Block))
              /= Landin.IR.Length
                (Of_Unit, Right, Landin.IR.Block_Id (Block))
            then
               return False;
            end if;
            for Position in 1 .. Landin.IR.Length
              (Of_Unit, Left, Landin.IR.Block_Id (Block))
            loop
               declare
                  A : constant Landin.IR.Value_Id := Landin.IR.Nth_Value
                    (Of_Unit, Left, Landin.IR.Block_Id (Block), Position);
                  B : constant Landin.IR.Value_Id := Landin.IR.Nth_Value
                    (Of_Unit, Right, Landin.IR.Block_Id (Block), Position);
                  Op : constant Landin.IR.Opcode :=
                    Landin.IR.Op_Of (Of_Unit, Left, A);
               begin
                  if Op not in Landin.IR.Number | Landin.IR.Truth
                               | Landin.IR.Load | Landin.IR.Store
                               | Landin.IR.Evidence_Function
                               | Landin.IR.Indirect_Call
                               | Landin.IR.Failure_Test | Landin.IR.Jump
                               | Landin.IR.Branch | Landin.IR.Leave
                    or else Op /= Landin.IR.Op_Of (Of_Unit, Right, B)
                    or else not Carriers_Agree
                      (Landin.IR.Result_Of (Of_Unit, Left, A),
                       Landin.IR.Result_Of (Of_Unit, Right, B))
                    or else Landin.IR.Operand_Count (Of_Unit, Left, A)
                      /= Landin.IR.Operand_Count (Of_Unit, Right, B)
                  then
                     return False;
                  end if;
                  for Operand in 1 .. Landin.IR.Operand_Count
                    (Of_Unit, Left, A)
                  loop
                     if Landin.IR.Nth_Operand
                       (Of_Unit, Left, A, Operand)
                       /= Landin.IR.Nth_Operand
                         (Of_Unit, Right, B, Operand)
                     then
                        return False;
                     end if;
                  end loop;
                  if Op = Landin.IR.Number
                    and then
                      (Landin.IR.Number_Of (Of_Unit, Left, A)
                         /= Landin.IR.Number_Of (Of_Unit, Right, B)
                       or else Landin.IR.Is_Negated (Of_Unit, Left, A)
                         /= Landin.IR.Is_Negated (Of_Unit, Right, B))
                  then
                     return False;
                  elsif Op = Landin.IR.Truth
                    and then Landin.IR.Truth_Of (Of_Unit, Left, A)
                      /= Landin.IR.Truth_Of (Of_Unit, Right, B)
                  then
                     return False;
                  elsif Op in Landin.IR.Load | Landin.IR.Store
                    and then Landin.IR.Slot_Of (Of_Unit, Left, A)
                      /= Landin.IR.Slot_Of (Of_Unit, Right, B)
                  then
                     return False;
                  elsif Op = Landin.IR.Evidence_Function
                    and then Landin.IR.Evidence_Entry_Of
                      (Of_Unit, Left, A)
                      /= Landin.IR.Evidence_Entry_Of (Of_Unit, Right, B)
                  then
                     return False;
                  elsif Op = Landin.IR.Indirect_Call
                    and then
                      (not Signatures_Have_One_ABI
                         (Landin.IR.Call_Signature (Of_Unit, Left, A),
                          Landin.IR.Call_Signature (Of_Unit, Right, B),
                          Landin.IR.Signature_Count (Of_Unit) + 1)
                       or else Landin.IR.Failure_Slot_Of (Of_Unit, Left, A)
                         /= Landin.IR.Failure_Slot_Of (Of_Unit, Right, B))
                  then
                     return False;
                  elsif Op = Landin.IR.Jump
                    and then Landin.IR.Target_Of (Of_Unit, Left, A)
                      /= Landin.IR.Target_Of (Of_Unit, Right, B)
                  then
                     return False;
                  elsif Op = Landin.IR.Branch
                    and then
                      (Landin.IR.Target_Of (Of_Unit, Left, A)
                         /= Landin.IR.Target_Of (Of_Unit, Right, B)
                       or else Landin.IR.Alternative_Of (Of_Unit, Left, A)
                         /= Landin.IR.Alternative_Of (Of_Unit, Right, B))
                  then
                     return False;
                  end if;
               end;
            end loop;
         end loop;
         return True;
      end Routines_Can_Share;

      function Cell (Offset : Landin.Targets.Byte_Count) return String
        is ("-" & Trimmed (Landin.Targets.Byte_Count'Image (Offset))
            & "(%rbp)");

      --  Where a field of [0670]'s state sits, and how much room the
      --  whole of it takes.  Worked out here from the item's own field
      --  types rather than read from a table the IR would have had to
      --  carry, because an offset needs a target: this is
      --  Landin.Targets.Placement over the same run against the same
      --  description the checker used, so the two cannot disagree.
      procedure Place_Fields
        (Item   : Landin.IR.Item_Id;
         Placed : out Landin.Targets.Placement;
         Wanted : Landin.IR.Element_Total;
         Offset : out Landin.Targets.Byte_Count);

      function Has_Wide_Field
        (Item : Landin.IR.Item_Id) return Boolean;

      procedure Place_Fields
        (Item   : Landin.IR.Item_Id;
         Placed : out Landin.Targets.Placement;
         Wanted : Landin.IR.Element_Total;
         Offset : out Landin.Targets.Byte_Count) is
      begin
         Placed := Landin.Targets.Empty_Placement;
         Offset := 0;

         --  [0520]'s array is its element repeated, so where a part sits
         --  is one multiplication rather than a walk: the count reaches
         --  four billion and placing each in turn would take as long.
         if Landin.IR.Result_Of (Of_Unit, Item) = Landin.Types.Fixed_Array
         then
            declare
               --  D122 admits an aggregate element, so the stride is the
               --  element shape's own extent and not a scalar width.
               Size : Landin.Targets.Byte_Count;
               Alignment : Landin.Targets.Byte_Alignment;
            begin
               Landin.Backend.Field_Extent
                 (Of_Unit,
                  Landin.IR.Array_Element_Shape (Of_Unit, Item),
                  Facts, Size, Alignment);
               if Wanted > 0 then
                  Offset :=
                    Landin.Targets.Byte_Count (Wanted - 1) * Size;
               end if;
            end;

            return;
         end if;

         for Field in 1 .. Landin.IR.Field_Count (Of_Unit, Item) loop
            declare
               Shape : constant Landin.IR.Field_Shape :=
                 Landin.IR.Nth_Field_Shape (Of_Unit, Item, Field);
               Size : Landin.Targets.Byte_Count;
               Alignment : Landin.Targets.Byte_Alignment;
               At_Offset : Landin.Targets.Byte_Count;
            begin
               Landin.Backend.Field_Extent
                 (Of_Unit, Shape, Facts, Size, Alignment);
               Landin.Targets.Place
                 (Placed, Size, Alignment, At_Offset);

               if Landin.IR.Element_Total (Field) = Wanted then
                  Offset := At_Offset;
               end if;
            end;
         end loop;
      end Place_Fields;

      --  A compact array or unfolded variant can make a later module field's
      --  target-derived offset exceed a signed relocation displacement.
      function Has_Wide_Field (Item : Landin.IR.Item_Id) return Boolean is
      begin
         if Landin.IR.Result_Of (Of_Unit, Item) /= Landin.Types.Aggregate
         then
            return False;
         end if;

         for Field in 1 .. Landin.IR.Field_Count (Of_Unit, Item) loop
            if Landin.IR.Nth_Field_Shape (Of_Unit, Item, Field).Kind
                 in Landin.IR.Array_Field_Shape
                    | Landin.IR.Aggregate_Field_Shape
                    | Landin.IR.Variant_Field_Shape
            then
               return True;
            end if;
         end loop;
         return False;
      end Has_Wide_Field;

      function Field_Offset
        (Item : Landin.IR.Item_Id; Field : Landin.IR.Part_Position)
        return Landin.Targets.Byte_Count;

      function Field_Offset
        (Item : Landin.IR.Item_Id; Field : Landin.IR.Part_Position)
        return Landin.Targets.Byte_Count
      is
         Placed : Landin.Targets.Placement;
         Offset : Landin.Targets.Byte_Count;
      begin
         Place_Fields
           (Item, Placed, Landin.IR.Element_Total (Field), Offset);
         return Offset;
      end Field_Offset;

      procedure Emit_Routine (Item : Landin.IR.Item_Id);

      procedure Emit_Routine (Item : Landin.IR.Item_Id) is
         Layout : constant Frame := Laid_Out (Of_Unit, Item, Facts);
         Result : constant Landin.Types.Type_Kind :=
           Landin.IR.Result_Of (Of_Unit, Item);

         function Value_Cell (Value : Landin.IR.Value_Id) return String
           is (Cell (Value_Offset (Layout, Value)));

         function Slot_Cell (Slot : Landin.IR.Slot_Id) return String
           is (Cell (Slot_Offset (Layout, Slot)));

         function Size_Of_Value
           (Value : Landin.IR.Value_Id) return Held_Size
           is (Size_Of
                 (Landin.IR.Result_Of (Of_Unit, Item, Value), Facts));

         function Size_Of_Slot (Slot : Landin.IR.Slot_Id) return Held_Size
           is (Size_Of (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts));

         --  D49/D50/D53 ask three compact whole-array operations for the
         --  same target-derived shape and base address.  D57 reuses the base
         --  for the complete padded extent of aggregate storage.  Keep that
         --  replay in one place: a field is an IR identity, never an offset.
         function Array_Length_Of
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps)
            return Landin.IR.Element_Total;
         function Element_Shape_Of
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) return Landin.IR.Field_Shape;
         function Array_Element_Of
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps)
            return Landin.Types.Scalar_Name;
         function Element_Bytes_Of
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) return Landin.Targets.Byte_Count;
         procedure Storage_Address
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Register      : String;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps);
         function Whole_Clear_Extent
           (Place  : Landin.IR.Storage;
            Field  : Natural;
            Nested : Landin.IR.Path_Step_Array)
            return Landin.Targets.Byte_Count;
         function Stored_Field_Shape
           (Place : Landin.IR.Storage; Field : Positive)
            return Landin.IR.Field_Shape;
         --  D126: the part a variant operation reaches, which is its base
         --  field and then whatever run [0420] composed below it.
         function Root_Shape_Of
           (Place : Landin.IR.Storage; Field : Natural)
            return Landin.IR.Field_Shape;
         --  D127: the part a base position names.  For storage that is an
         --  array that is [0520]'s element, which is what a known index of
         --  a scalar array has always meant; for a struct it is [0750]'s
         --  field.
         function Part_Shape_Of
           (Place : Landin.IR.Storage; Which : Landin.IR.Part_Position)
            return Landin.IR.Field_Shape;
         function Reached_Shape
           (Place  : Landin.IR.Storage;
            Field  : Natural;
            Nested : Landin.IR.Path_Step_Array)
            return Landin.IR.Field_Shape;

         function Path_Offset
           (Shape : Landin.IR.Field_Shape;
            Path  : Landin.IR.Path_Step_Array)
            return Landin.Targets.Byte_Count;

         function Array_Length_Of
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) return Landin.IR.Element_Total
         is
         begin
            if Payload_Field > 0 then
               return Landin.IR.Nth_Variant_Case_Field
                 (Of_Unit, Reached_Shape (Place, Field, Nested),
                  Positive (Which), Positive (Payload_Field)).Length;
            end if;
            if Nested'Length > 0 then
               return Reached_Shape (Place, Field, Nested).Length;
            end if;
            return Root_Shape_Of (Place, Field).Length;
         end Array_Length_Of;

         --  D127: where a run starts.  A positive base field is that
         --  field's shape; base zero is storage that is itself an array,
         --  said as one shape so a run may start there too.
         function Root_Shape_Of
           (Place : Landin.IR.Storage; Field : Natural)
            return Landin.IR.Field_Shape
         is (if Field > 0
             then Part_Shape_Of (Place, Landin.IR.Part_Position (Field))
             else (case Place.Kind is
                      when Landin.IR.Module_Datum =>
                        Landin.IR.Whole_Array_Shape (Of_Unit, Place.Datum),
                      when Landin.IR.Frame_Slot =>
                        Landin.IR.Whole_Slot_Array_Shape
                          (Of_Unit, Item, Place.Slot),
                      when Landin.IR.Runtime_Address =>
                        Landin.IR.Address_Shape
                          (Of_Unit, Item, Place.Address)));

         function Part_Shape_Of
           (Place : Landin.IR.Storage; Which : Landin.IR.Part_Position)
            return Landin.IR.Field_Shape
         is (case Place.Kind is
                when Landin.IR.Module_Datum =>
                  (if Landin.IR.Result_Of (Of_Unit, Place.Datum)
                        = Landin.Types.Fixed_Array
                   then Landin.IR.Array_Element_Shape (Of_Unit, Place.Datum)
                   else Landin.IR.Nth_Field_Shape
                     (Of_Unit, Place.Datum, Positive (Which))),
                when Landin.IR.Frame_Slot =>
                  (if Landin.IR.Is_Array (Of_Unit, Item, Place.Slot)
                   then Landin.IR.Slot_Array_Element_Shape
                     (Of_Unit, Item, Place.Slot)
                   else Landin.IR.Nth_Slot_Field_Shape
                     (Of_Unit, Item, Place.Slot, Positive (Which))),
                when Landin.IR.Runtime_Address =>
                  (if Landin.IR.Address_Shape
                        (Of_Unit, Item, Place.Address).Kind
                        = Landin.IR.Array_Field_Shape
                   then Landin.IR.Array_Element_Shape
                     (Of_Unit,
                      Landin.IR.Address_Shape
                        (Of_Unit, Item, Place.Address))
                   else Landin.IR.Nth_Aggregate_Field
                     (Of_Unit,
                      Landin.IR.Address_Shape
                        (Of_Unit, Item, Place.Address),
                      Positive (Which))));

         --  D121: the shape of one element of the array an operation
         --  reaches.  A scalar element answers as itself, so every caller
         --  that only wants a width still gets one.
         function Reached_Shape
           (Place  : Landin.IR.Storage;
            Field  : Natural;
            Nested : Landin.IR.Path_Step_Array)
            return Landin.IR.Field_Shape
         is (Landin.IR.Shape_At
               (Of_Unit, Root_Shape_Of (Place, Field), Nested));

         function Element_Shape_Of
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) return Landin.IR.Field_Shape
         is
         begin
            if Payload_Field > 0 then
               return Landin.IR.Array_Element_Shape
                 (Of_Unit,
                  Landin.IR.Nth_Variant_Case_Field
                    (Of_Unit,
                     Reached_Shape (Place, Field, Nested),
                     Positive (Which), Positive (Payload_Field)));
            end if;
            if Nested'Length > 0 then
               return Landin.IR.Array_Element_Shape
                 (Of_Unit,
                  Reached_Shape (Place, Field, Nested));
            end if;
            case Place.Kind is
               when Landin.IR.Module_Datum =>
                  if Field = 0 then
                     return Landin.IR.Array_Element_Shape
                       (Of_Unit, Place.Datum);
                  end if;
                  return Landin.IR.Array_Element_Shape
                    (Of_Unit,
                     Landin.IR.Nth_Field_Shape
                       (Of_Unit, Place.Datum, Positive (Field)));
               when Landin.IR.Frame_Slot =>
                  if Field = 0 then
                     return Landin.IR.Slot_Array_Element_Shape
                       (Of_Unit, Item, Place.Slot);
                  end if;
                  return Landin.IR.Array_Element_Shape
                    (Of_Unit,
                     Landin.IR.Nth_Slot_Field_Shape
                       (Of_Unit, Item, Place.Slot, Positive (Field)));
               when Landin.IR.Runtime_Address =>
                  return Landin.IR.Array_Element_Shape
                    (Of_Unit, Root_Shape_Of (Place, Field));
            end case;
         end Element_Shape_Of;

         function Array_Element_Of
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) return Landin.Types.Scalar_Name
         is (Element_Shape_Of
               (Place, Field, Which, Payload_Field, Nested).Element);

         --  How many target bytes one element takes.
         function Element_Bytes_Of
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) return Landin.Targets.Byte_Count
         is
            Shape : constant Landin.IR.Field_Shape :=
              Element_Shape_Of (Place, Field, Which, Payload_Field, Nested);
            Size : Landin.Targets.Byte_Count;
            Alignment : Landin.Targets.Byte_Alignment;
         begin
            Landin.Backend.Field_Extent
              (Of_Unit, Shape, Facts, Size, Alignment);
            return Size;
         end Element_Bytes_Of;

         procedure Storage_Address
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Register      : String;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) is
         begin
            case Place.Kind is
               when Landin.IR.Module_Datum =>
                  Emit
                    ("leaq " & Symbol (Place.Datum) & "(%rip), " & Register);
                  if Field > 0 then
                     declare
                        At_Offset : constant Landin.Targets.Byte_Count :=
                          Field_Offset
                            (Place.Datum, Landin.IR.Part_Position (Field));
                     begin
                        if At_Offset > 0 then
                           Emit
                             ("movabsq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image (At_Offset))
                              & ", %rdx");
                           Emit ("addq %rdx, " & Register);
                        end if;
                     end;
                  end if;
               when Landin.IR.Frame_Slot =>
                  Emit
                    ("leaq "
                     & Cell
                         ((if Field = 0
                           then Landin.Backend.Slot_Offset
                             (Layout, Place.Slot)
                           else Landin.Backend.Field_Offset
                             (Of_Unit, Item, Layout, Place.Slot,
                              Landin.IR.Part_Position (Field), Facts)))
                     & ", " & Register);
               when Landin.IR.Runtime_Address =>
                  Emit ("movq " & Slot_Cell (Place.Address) & ", "
                        & Register);
                  if Field > 0 then
                     declare
                        At_Offset : constant Landin.Targets.Byte_Count :=
                          Path_Offset
                            (Landin.IR.Address_Shape
                               (Of_Unit, Item, Place.Address),
                             [1 =>
                                (Field => Landin.IR.Part_Position (Field),
                                 Case_Index => 0)]);
                     begin
                        if At_Offset > 0 then
                           Emit
                             ("movabsq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image (At_Offset))
                              & ", %rdx");
                           Emit ("addq %rdx, " & Register);
                        end if;
                     end;
                  end if;
            end case;

            --  The base field first, then D118's run down to the part the
            --  operation names, and then the case it selected inside that
            --  part.  D126 is what makes the run come before the case: the
            --  variant part may sit below the base field, and its payload
            --  offset is its own shape's and not the base field's.  A run
            --  *below* a selected payload is a Case_Index step of the same
            --  run, so nothing is ever added after the payload.
            if Nested'Length > 0 then
               declare
                  At_Offset : constant Landin.Targets.Byte_Count :=
                    Path_Offset (Root_Shape_Of (Place, Field), Nested);
               begin
                  if At_Offset > 0 then
                     Emit
                       ("movabsq $"
                        & Trimmed
                            (Landin.Targets.Byte_Count'Image (At_Offset))
                        & ", %rdx");
                     Emit ("addq %rdx, " & Register);
                  end if;
               end;
            end if;

            if Payload_Field > 0 then
               declare
                  At_Offset : constant Landin.Targets.Byte_Count :=
                    Landin.Backend.Variant_Payload_Field_Offset
                      (Of_Unit, Reached_Shape (Place, Field, Nested),
                       Positive (Which), Positive (Payload_Field), Facts);
               begin
                  if At_Offset > 0 then
                     Emit
                       ("movabsq $"
                        & Trimmed
                            (Landin.Targets.Byte_Count'Image (At_Offset))
                        & ", %rdx");
                     Emit ("addq %rdx, " & Register);
                  end if;
               end;
            end if;
         end Storage_Address;

         function Whole_Clear_Extent
           (Place  : Landin.IR.Storage;
            Field  : Natural;
            Nested : Landin.IR.Path_Step_Array)
            return Landin.Targets.Byte_Count
         is
            Whole_Aggregate : constant Boolean :=
              Field = 0 and then Nested'Length = 0
              and then
                (case Place.Kind is
                    when Landin.IR.Module_Datum =>
                      Landin.IR.Result_Of (Of_Unit, Place.Datum)
                        = Landin.Types.Aggregate,
                    when Landin.IR.Frame_Slot =>
                      Landin.IR.Is_Aggregate
                        (Of_Unit, Item, Place.Slot),
                    when Landin.IR.Runtime_Address =>
                      Landin.IR.Address_Shape
                        (Of_Unit, Item, Place.Address).Kind
                        = Landin.IR.Aggregate_Field_Shape);
         begin
            --  D91 clears one whole child; D119 clears one however far
            --  down the path went; D127 lets that run start at whole array
            --  storage, so an element is reached the same way.  Either way
            --  the extent is the reached part's own, replayed against this
            --  target.
            if (Field > 0 or else Nested'Length > 0)
              and then Reached_Shape (Place, Field, Nested).Kind
                         = Landin.IR.Aggregate_Field_Shape
            then
               declare
                  Size : Landin.Targets.Byte_Count;
                  Alignment : Landin.Targets.Byte_Alignment;
               begin
                  Landin.Backend.Field_Extent
                    (Of_Unit, Reached_Shape (Place, Field, Nested),
                     Facts, Size, Alignment);
                  return Size;
               end;
            end if;

            if not Whole_Aggregate then
               return
                 Landin.Targets.Byte_Count
                   (Array_Length_Of
                      (Place, Field, Nested => Nested))
                 * Element_Bytes_Of (Place, Field, Nested => Nested);
            end if;

            case Place.Kind is
               when Landin.IR.Module_Datum =>
                  declare
                     Placed : Landin.Targets.Placement;
                     Ignored : Landin.Targets.Byte_Count;
                  begin
                     Place_Fields (Place.Datum, Placed, 0, Ignored);
                     return Landin.Targets.Size_Of (Placed);
                  end;

               when Landin.IR.Frame_Slot =>
                  declare
                     Size : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Landin.Backend.Aggregate_Extent
                       (Of_Unit, Item, Place.Slot, Facts, Size, Alignment);
                     return Size;
                  end;
               when Landin.IR.Runtime_Address =>
                  declare
                     Size : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Landin.Backend.Field_Extent
                       (Of_Unit,
                        Landin.IR.Address_Shape
                          (Of_Unit, Item, Place.Address),
                        Facts, Size, Alignment);
                     return Size;
                  end;
            end case;
         end Whole_Clear_Extent;

         function Stored_Field_Shape
           (Place : Landin.IR.Storage; Field : Positive)
            return Landin.IR.Field_Shape
         is
           (case Place.Kind is
               when Landin.IR.Module_Datum =>
                 Landin.IR.Nth_Field_Shape
                   (Of_Unit, Place.Datum, Field),
               when Landin.IR.Frame_Slot =>
                 Landin.IR.Nth_Slot_Field_Shape
                   (Of_Unit, Item, Place.Slot, Field),
               when Landin.IR.Runtime_Address =>
                 Landin.IR.Nth_Aggregate_Field
                   (Of_Unit,
                    Landin.IR.Address_Shape
                      (Of_Unit, Item, Place.Address),
                    Field));

         --  How far into one field the whole of D118's path reaches.  Each
         --  ordinary step replays [0750]'s placement over the run the step
         --  before it reached; each selected-case step adds the payload
         --  offset the same tag-first rule gives.  The identities come from
         --  the IR and every byte of the answer is derived here.
         function Path_Offset
           (Shape : Landin.IR.Field_Shape;
            Path  : Landin.IR.Path_Step_Array)
            return Landin.Targets.Byte_Count
         is
            Reached : Landin.IR.Field_Shape := Shape;
            Total   : Landin.Targets.Byte_Count := 0;
         begin
            for Step of Path loop
               if Step.Case_Index = 0
                 and then Reached.Kind = Landin.IR.Array_Field_Shape
               then
                  --  D127: a step into an array names [0520]'s element
                  --  position, so the offset is one multiplication.
                  declare
                     Element : constant Landin.IR.Field_Shape :=
                       Landin.IR.Array_Element_Shape (Of_Unit, Reached);
                     Size : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Landin.Backend.Field_Extent
                       (Of_Unit, Element, Facts, Size, Alignment);
                     Total := Total
                       + Landin.Targets.Byte_Count
                           (Landin.IR.Element_Total (Step.Field) - 1)
                         * Size;
                     Reached := Element;
                  end;
               elsif Step.Case_Index = 0 then
                  declare
                     Placed : Landin.Targets.Placement :=
                       Landin.Targets.Empty_Placement;
                     At_Offset : Landin.Targets.Byte_Count := 0;
                  begin
                     for Which in 1 .. Positive (Step.Field) loop
                        declare
                           Part : constant Landin.IR.Field_Shape :=
                             Landin.IR.Nth_Aggregate_Field
                               (Of_Unit, Reached, Which);
                           Size : Landin.Targets.Byte_Count;
                           Alignment : Landin.Targets.Byte_Alignment;
                        begin
                           Landin.Backend.Field_Extent
                             (Of_Unit, Part, Facts, Size, Alignment);
                           Landin.Targets.Place
                             (Placed, Size, Alignment, At_Offset);
                        end;
                     end loop;
                     Total := Total + At_Offset;
                     Reached := Landin.IR.Nth_Aggregate_Field
                       (Of_Unit, Reached, Positive (Step.Field));
                  end;
               else
                  Total := Total
                    + Landin.Backend.Variant_Payload_Field_Offset
                        (Of_Unit, Reached, Step.Case_Index,
                         Positive (Step.Field), Facts);
                  Reached := Landin.IR.Nth_Variant_Case_Field
                    (Of_Unit, Reached, Step.Case_Index,
                     Positive (Step.Field));
               end if;
            end loop;
            return Total;
         end Path_Offset;

         --  A Value_Id restarts in each item, just as a Block_Id does.  The
         --  extra `V` keeps a continuation distinct from a block label.
         function Value_Label (Value : Landin.IR.Value_Id) return String
           is (".L" & Trimmed (Landin.IR.Item_Id'Image (Item))
               & "_V" & Trimmed (Landin.IR.Value_Id'Image (Value)));

         --  A move through the accumulator, at one width.  Every value
         --  that crosses an instruction crosses it this way.
         procedure Carry (Size : Held_Size; From, To : String);

         procedure Carry (Size : Held_Size; From, To : String) is
         begin
            Emit ("mov" & Suffix (Size) & " " & From & ", "
                  & Accumulator (Size));
            Emit ("mov" & Suffix (Size) & " " & Accumulator (Size)
                  & ", " & To);
         end Carry;

         procedure Emit_Epilogue;

         procedure Emit_Epilogue is
         begin
            Emit ("movq %rbp, %rsp");
            Emit ("popq %rbp");
            Emit ("ret");
         end Emit_Epilogue;

         procedure Emit_Instruction (Value : Landin.IR.Value_Id);

         procedure Emit_Instruction (Value : Landin.IR.Value_Id) is
            Op : constant Landin.IR.Opcode :=
              Landin.IR.Op_Of (Of_Unit, Item, Value);

            function Operand (Index : Positive) return Landin.IR.Value_Id
              is (Landin.IR.Nth_Operand (Of_Unit, Item, Value, Index));
         begin
            case Op is
               when Landin.IR.Number =>
                  declare
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Size : constant Landin.Types.Scalar_Name :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Digits_Of : constant Landin.Types.Magnitude :=
                       Landin.IR.Number_Of (Of_Unit, Item, Value);
                     Width : constant Landin.Targets.Bit_Width :=
                       (if Size in Landin.Types.Float_Name
                        then Landin.Types.Float_Width
                          (Landin.Types.Float_Name (Size))
                        else Landin.Types.Width
                          (Landin.Types.Integer_Name (Size), Facts));
                     Highest : constant Landin.Types.Magnitude :=
                       (if Width = 64
                        then Landin.Types.Magnitude'Last
                        else 2 ** Natural (Width) - 1);
                     --  [1770]'s magnitude and [1880]'s minus are carried
                     --  apart, so the two's complement pattern is formed
                     --  here, where a width finally exists.  The checker
                     --  has already refused a literal the type cannot
                     --  hold, so no masking is needed above the negation.
                     Pattern : constant Landin.Types.Magnitude :=
                       (if Size in Landin.Types.Float_Name
                        then Digits_Of
                        elsif not Landin.IR.Is_Negated (Of_Unit, Item, Value)
                          or else Digits_Of = 0
                        then Digits_Of
                        else Highest - Digits_Of + 1);
                  begin
                     Emit ("movabsq $"
                           & Trimmed
                               (Landin.Types.Magnitude'Image (Pattern))
                           & ", %rax");
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                  end;

               when Landin.IR.Measure_Size | Landin.IR.Measure_Align =>
                  --  [0370]: the answer is a target fact, and this is the
                  --  first place in the compiler that has one.
                  declare
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Size : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Measurement_Extent
                       (Of_Unit, Item, Value, Facts, Size, Alignment);
                     declare
                        Answer : constant String :=
                          (if Op = Landin.IR.Measure_Size
                           then Landin.Targets.Byte_Count'Image (Size)
                           else Landin.Targets.Byte_Alignment'Image
                                  (Alignment));
                     begin
                        Emit
                          ("movabsq $" & Trimmed (Answer) & ", %rax");
                        Emit
                          ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                     end;
                  end;

               when Landin.IR.Truth =>
                  --  [1870]'s two literals, and the one byte
                  --  Landin.Backend gives a bool.
                  Emit ("movb $"
                        & (if Landin.IR.Truth_Of (Of_Unit, Item, Value)
                           then "1" else "0")
                        & ", " & Value_Cell (Value));

               when Landin.IR.Atom =>
                  Emit
                    ("movl $"
                     & Trimmed
                         (Positive'Image
                            (Atom_Code
                               (Of_Unit,
                                Landin.IR.Atom_Of
                                  (Of_Unit, Item, Value))))
                     & ", " & Value_Cell (Value));

               when Landin.IR.Place_Address =>
                  declare
                     Place : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                  begin
                     Storage_Address
                       (Place, Field, "%rax", Nested => Nested);
                     Carry
                       (Landin.Targets.Byte_8, "%rax", Value_Cell (Value));
                  end;

               when Landin.IR.Storage_Address =>
                  declare
                     Place : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                  begin
                     if not Landin.IR.Storage_Address_Has_Index
                       (Of_Unit, Item, Value)
                     then
                        Storage_Address
                          (Place, Field, "%rax", Nested => Nested);
                        Carry
                          (Landin.Targets.Byte_8, "%rax",
                           Value_Cell (Value));
                     else
                        Storage_Address
                          (Place, Field, "%rcx", Nested => Nested);
                        declare
                           Index : constant Landin.IR.Value_Id :=
                             Operand (1);
                           Length : constant Landin.IR.Element_Total :=
                             Array_Length_Of
                               (Place, Field, Nested => Nested);
                           Stride : constant Landin.Targets.Byte_Count :=
                             Element_Bytes_Of
                               (Place, Field, Nested => Nested);
                           Safe : constant String :=
                             Value_Label (Value) & "_index";
                        begin
                           Emit ("movq " & Value_Cell (Index) & ", %rax");
                           Emit
                             ("movabsq $"
                              & Trimmed
                                  (Landin.IR.Element_Total'Image (Length))
                              & ", %rdx");
                           Emit ("cmpq %rdx, %rax");
                           Emit ("jb " & Safe);
                           Emit ("ud2");
                           Put (Safe & ":");
                           if Stride <= 2 ** 31 - 1 then
                              Emit
                                ("imulq $"
                                 & Trimmed
                                     (Landin.Targets.Byte_Count'Image
                                        (Stride))
                                 & ", %rax, %rax");
                           else
                              Emit
                                ("movabsq $"
                                 & Trimmed
                                     (Landin.Targets.Byte_Count'Image
                                        (Stride))
                                 & ", %rdx");
                              Emit ("imulq %rdx, %rax");
                           end if;
                           Emit ("addq %rax, %rcx");
                           Carry
                             (Landin.Targets.Byte_8, "%rcx",
                              Value_Cell (Value));
                        end;
                     end if;
                  end;

               when Landin.IR.Pointer_Address =>
                  Carry
                    (Landin.Targets.Byte_8,
                     Value_Cell (Operand (1)), Value_Cell (Value));

               when Landin.IR.Conversion =>
                  declare
                     Source : constant Landin.IR.Value_Id := Operand (1);
                     From_Kind : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Source);
                     Into_Kind : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                  begin
                     if From_Kind in Landin.Types.Float_Name
                       and then Into_Kind in Landin.Types.Float_Name
                     then
                        declare
                           From : constant Landin.Types.Float_Name :=
                             Landin.Types.Float_Name (From_Kind);
                           Into_Type : constant Landin.Types.Float_Name :=
                             Landin.Types.Float_Name (Into_Kind);
                        begin
                           if From = Into_Type then
                              Carry
                                (Size_Of (From, Facts), Value_Cell (Source),
                                 Value_Cell (Value));
                           elsif From = Landin.Types.F32 then
                              Emit
                                ("movss " & Value_Cell (Source)
                                 & ", %xmm0");
                              Emit ("cvtss2sd %xmm0, %xmm0");
                              Emit
                                ("movsd %xmm0, " & Value_Cell (Value));
                           else
                              declare
                                 Safe : constant String :=
                                   Value_Label (Value) & "_finite";
                              begin
                                 Emit
                                   ("movsd " & Value_Cell (Source)
                                    & ", %xmm0");
                                 Emit ("cvtsd2ss %xmm0, %xmm0");
                                 --  Infinity and NaN are values of both
                                 --  widths.  Only a finite source which
                                 --  rounded to infinity must trap [0310].
                                 Emit ("movd %xmm0, %eax");
                                 Emit ("andl $2139095040, %eax");
                                 Emit ("cmpl $2139095040, %eax");
                                 Emit ("jne " & Safe);
                                 Emit
                                   ("movq " & Value_Cell (Source)
                                    & ", %rdx");
                                 Emit
                                   ("movabsq $9218868437227405312, %rax");
                                 Emit ("movq %rdx, %rcx");
                                 Emit ("andq %rax, %rcx");
                                 Emit ("cmpq %rax, %rcx");
                                 Emit ("je " & Safe);
                                 Emit ("ud2");
                                 Put (Safe & ":");
                                 Emit
                                   ("movss %xmm0, " & Value_Cell (Value));
                              end;
                           end if;
                        end;
                     elsif From_Kind = Landin.Types.Bool
                       and then Into_Kind in Landin.Types.Float_Name
                     then
                        declare
                           Into_Type : constant Landin.Types.Float_Name :=
                             Landin.Types.Float_Name (Into_Kind);
                           Convert : constant String :=
                             (if Into_Type = Landin.Types.F32
                              then "cvtsi2ssq" else "cvtsi2sdq");
                           Store : constant String :=
                             (if Into_Type = Landin.Types.F32
                              then "movss" else "movsd");
                        begin
                           Emit ("movq $0, %rax");
                           Emit ("movb " & Value_Cell (Source) & ", %al");
                           Emit (Convert & " %rax, %xmm0");
                           Emit
                             (Store & " %xmm0, " & Value_Cell (Value));
                        end;
                     elsif Into_Kind in Landin.Types.Float_Name then
                        declare
                           From : constant Landin.Types.Integer_Name :=
                             Landin.Types.Integer_Name (From_Kind);
                           Into_Type : constant Landin.Types.Float_Name :=
                             Landin.Types.Float_Name (Into_Kind);
                           From_Size : constant Held_Size :=
                             Size_Of (From, Facts);
                           High_Unsigned : constant String :=
                             Value_Label (Value) & "_unsigned";
                           Converted : constant String :=
                             Value_Label (Value) & "_converted";
                           Convert : constant String :=
                             (if Into_Type = Landin.Types.F32
                              then "cvtsi2ssq" else "cvtsi2sdq");
                           Add : constant String :=
                             (if Into_Type = Landin.Types.F32
                              then "addss" else "addsd");
                           Store : constant String :=
                             (if Into_Type = Landin.Types.F32
                              then "movss" else "movsd");
                        begin
                           if Landin.Types.Is_Signed (From) then
                              Emit
                                ((case From_Size is
                                    when Landin.Targets.Byte_1 => "movsbq ",
                                    when Landin.Targets.Byte_2 => "movswq ",
                                    when Landin.Targets.Byte_4 => "movslq ",
                                    when Landin.Targets.Byte_8 => "movq ")
                                 & Value_Cell (Source) & ", %rax");
                           else
                              Emit ("movq $0, %rax");
                              Emit ("mov" & Suffix (From_Size) & " "
                                    & Value_Cell (Source) & ", "
                                    & Accumulator (From_Size));
                           end if;

                           if not Landin.Types.Is_Signed (From)
                             and then From_Size = Landin.Targets.Byte_8
                           then
                              --  SSE converts a signed qword.  For the upper
                              --  half of u64, convert the sticky half and
                              --  double it; this is the same nearest-even
                              --  answer as converting the unsigned value.
                              Emit ("testq %rax, %rax");
                              Emit ("js " & High_Unsigned);
                              Emit (Convert & " %rax, %xmm0");
                              Emit ("jmp " & Converted);
                              Put (High_Unsigned & ":");
                              Emit ("movq %rax, %rdx");
                              Emit ("shrq $1, %rax");
                              Emit ("andq $1, %rdx");
                              Emit ("orq %rdx, %rax");
                              Emit (Convert & " %rax, %xmm0");
                              Emit (Add & " %xmm0, %xmm0");
                              Put (Converted & ":");
                           else
                              Emit (Convert & " %rax, %xmm0");
                           end if;
                           Emit
                             (Store & " %xmm0, " & Value_Cell (Value));
                        end;
                     elsif Into_Kind = Landin.Types.Bool then
                        if From_Kind in Landin.Types.Float_Name then
                           declare
                              From : constant Landin.Types.Float_Name :=
                                Landin.Types.Float_Name (From_Kind);
                              False_Value : constant String :=
                                Value_Label (Value) & "_false";
                              True_Value : constant String :=
                                Value_Label (Value) & "_true";
                              Store : constant String :=
                                Value_Label (Value) & "_bool";
                              Magnitude_Mask : constant
                                Landin.Types.Magnitude :=
                                  (case From is
                                      when Landin.Types.F32 =>
                                        2_147_483_647,
                                      when Landin.Types.F64 =>
                                        9_223_372_036_854_775_807);
                              One : constant Landin.Types.Magnitude :=
                                (case From is
                                    when Landin.Types.F32 =>
                                      1_065_353_216,
                                    when Landin.Types.F64 =>
                                      4_607_182_418_800_017_408);
                           begin
                              Emit
                                ((if From = Landin.Types.F32
                                  then "movl " else "movq ")
                                 & Value_Cell (Source)
                                 & (if From = Landin.Types.F32
                                    then ", %eax" else ", %rax"));
                              Emit ("movq %rax, %rdx");
                              Emit
                                ("movabsq $"
                                 & Trimmed
                                     (Landin.Types.Magnitude'Image
                                        (Magnitude_Mask))
                                 & ", %rcx");
                              Emit ("andq %rcx, %rdx");
                              Emit ("testq %rdx, %rdx");
                              Emit ("jz " & False_Value);
                              Emit
                                ("movabsq $"
                                 & Trimmed
                                     (Landin.Types.Magnitude'Image (One))
                                 & ", %rcx");
                              Emit ("cmpq %rcx, %rax");
                              Emit ("je " & True_Value);
                              Emit ("ud2");
                              Put (False_Value & ":");
                              Emit ("movq $0, %rax");
                              Emit ("jmp " & Store);
                              Put (True_Value & ":");
                              Emit ("movq $1, %rax");
                              Put (Store & ":");
                              Emit
                                ("movb %al, " & Value_Cell (Value));
                           end;
                        else
                           declare
                              From : constant Landin.Types.Integer_Name :=
                                Landin.Types.Integer_Name (From_Kind);
                              From_Size : constant Held_Size :=
                                Size_Of (From, Facts);
                              Safe : constant String :=
                                Value_Label (Value) & "_bool";
                           begin
                              Emit ("movq $0, %rax");
                              Emit ("mov" & Suffix (From_Size) & " "
                                    & Value_Cell (Source) & ", "
                                    & Accumulator (From_Size));
                              Emit ("cmpq $1, %rax");
                              Emit ("jbe " & Safe);
                              Emit ("ud2");
                              Put (Safe & ":");
                              Emit
                                ("movb %al, " & Value_Cell (Value));
                           end;
                        end if;
                     elsif From_Kind = Landin.Types.Bool then
                        declare
                           Into_Type : constant Landin.Types.Integer_Name :=
                             Landin.Types.Integer_Name (Into_Kind);
                           Into_Size : constant Held_Size :=
                             Size_Of (Into_Type, Facts);
                        begin
                           Emit ("movq $0, %rax");
                           Emit
                             ("movb " & Value_Cell (Source) & ", %al");
                           Emit ("mov" & Suffix (Into_Size) & " "
                                 & Accumulator (Into_Size) & ", "
                                 & Value_Cell (Value));
                        end;
                     elsif From_Kind in Landin.Types.Float_Name then
                        declare
                           From : constant Landin.Types.Float_Name :=
                             Landin.Types.Float_Name (From_Kind);
                           Into_Type : constant Landin.Types.Integer_Name :=
                             Landin.Types.Integer_Name (Into_Kind);
                           Into_Size : constant Held_Size :=
                             Size_Of (Into_Type, Facts);
                           Into_Bits : constant Landin.Targets.Bit_Width :=
                             Landin.Types.Width (Into_Type, Facts);
                           Fraction_Bits : constant Natural :=
                             (case From is
                                 when Landin.Types.F32 => 23,
                                 when Landin.Types.F64 => 52);
                           Exponent_All : constant Natural :=
                             (case From is
                                 when Landin.Types.F32 => 255,
                                 when Landin.Types.F64 => 2_047);
                           Bias : constant Natural :=
                             (case From is
                                 when Landin.Types.F32 => 127,
                                 when Landin.Types.F64 => 1_023);
                           Sign_Shift : constant Natural :=
                             (case From is
                                 when Landin.Types.F32 => 31,
                                 when Landin.Types.F64 => 63);
                           Fraction_Mask : constant
                             Landin.Types.Magnitude :=
                               (case From is
                                   when Landin.Types.F32 => 8_388_607,
                                   when Landin.Types.F64 =>
                                     4_503_599_627_370_495);
                           Hidden : constant Landin.Types.Magnitude :=
                             2 ** Fraction_Bits;
                           Shift_Right : constant String :=
                             Value_Label (Value) & "_right";
                           Magnitude_Ready : constant String :=
                             Value_Label (Value) & "_magnitude";
                           Negative : constant String :=
                             Value_Label (Value) & "_negative";
                           Zero : constant String :=
                             Value_Label (Value) & "_zero";
                           Store : constant String :=
                             Value_Label (Value) & "_store";
                           Trap : constant String :=
                             Value_Label (Value) & "_trap";
                           Done : constant String :=
                             Value_Label (Value) & "_done";
                        begin
                           --  Decode the IEEE carrier rather than relying on
                           --  cvttss2si/cvttsd2si: those instructions cannot
                           --  distinguish every valid u64 result from their
                           --  indefinite overflow result.  This is exactly
                           --  the target-neutral truncation and range check.
                           Emit
                             ((if From = Landin.Types.F32
                               then "movl " else "movq ")
                              & Value_Cell (Source)
                              & (if From = Landin.Types.F32
                                 then ", %eax" else ", %rax"));
                           Emit ("movq %rax, %r8");
                           Emit
                             ("shrq $" & Trimmed (Natural'Image (Sign_Shift))
                              & ", %r8");
                           Emit ("movq %rax, %rcx");
                           Emit
                             ("shrq $"
                              & Trimmed (Natural'Image (Fraction_Bits))
                              & ", %rcx");
                           Emit
                             ("andq $"
                              & Trimmed (Natural'Image (Exponent_All))
                              & ", %rcx");
                           Emit ("movq %rax, %rdx");
                           Emit
                             ("movabsq $"
                              & Trimmed
                                  (Landin.Types.Magnitude'Image
                                     (Fraction_Mask))
                              & ", %r9");
                           Emit ("andq %r9, %rdx");

                           Emit
                             ("cmpq $"
                              & Trimmed (Natural'Image (Exponent_All))
                              & ", %rcx");
                           Emit ("je " & Trap);
                           Emit ("testq %rcx, %rcx");
                           Emit ("jz " & Zero);
                           Emit
                             ("cmpq $" & Trimmed (Natural'Image (Bias))
                              & ", %rcx");
                           Emit ("jb " & Zero);
                           Emit
                             ("subq $" & Trimmed (Natural'Image (Bias))
                              & ", %rcx");
                           Emit ("cmpq $63, %rcx");
                           Emit ("ja " & Trap);
                           Emit
                             ("movabsq $"
                              & Trimmed
                                  (Landin.Types.Magnitude'Image (Hidden))
                              & ", %r9");
                           Emit ("addq %r9, %rdx");
                           Emit
                             ("cmpq $"
                              & Trimmed (Natural'Image (Fraction_Bits))
                              & ", %rcx");
                           Emit ("jb " & Shift_Right);
                           Emit
                             ("subq $"
                              & Trimmed (Natural'Image (Fraction_Bits))
                              & ", %rcx");
                           Emit ("shlq %cl, %rdx");
                           Emit ("jmp " & Magnitude_Ready);
                           Put (Shift_Right & ":");
                           Emit
                             ("movq $"
                              & Trimmed (Natural'Image (Fraction_Bits))
                              & ", %r9");
                           Emit ("subq %rcx, %r9");
                           Emit ("movq %r9, %rcx");
                           Emit ("shrq %cl, %rdx");

                           Put (Magnitude_Ready & ":");
                           Emit ("testq %rdx, %rdx");
                           Emit ("jz " & Zero);
                           Emit ("testq %r8, %r8");
                           Emit ("jnz " & Negative);
                           if Landin.Types.Is_Signed (Into_Type)
                             or else Into_Bits < 64
                           then
                              declare
                                 Maximum : constant Landin.Types.Magnitude :=
                                   (if Landin.Types.Is_Signed (Into_Type)
                                    then 2 ** (Natural (Into_Bits) - 1) - 1
                                    else 2 ** Natural (Into_Bits) - 1);
                              begin
                                 Emit
                                   ("movabsq $"
                                    & Trimmed
                                        (Landin.Types.Magnitude'Image
                                           (Maximum))
                                    & ", %r9");
                                 Emit ("cmpq %r9, %rdx");
                                 Emit ("ja " & Trap);
                              end;
                           end if;
                           Emit ("jmp " & Store);

                           Put (Negative & ":");
                           if Landin.Types.Is_Signed (Into_Type) then
                              declare
                                 Maximum : constant Landin.Types.Magnitude :=
                                   2 ** (Natural (Into_Bits) - 1);
                              begin
                                 Emit
                                   ("movabsq $"
                                    & Trimmed
                                        (Landin.Types.Magnitude'Image
                                           (Maximum))
                                    & ", %r9");
                                 Emit ("cmpq %r9, %rdx");
                                 Emit ("ja " & Trap);
                                 Emit ("negq %rdx");
                                 Emit ("jmp " & Store);
                              end;
                           else
                              Emit ("jmp " & Trap);
                           end if;

                           Put (Zero & ":");
                           Emit ("xorq %rdx, %rdx");
                           Put (Store & ":");
                           Emit ("movq %rdx, %rax");
                           Emit ("mov" & Suffix (Into_Size) & " "
                                 & Accumulator (Into_Size) & ", "
                                 & Value_Cell (Value));
                           Emit ("jmp " & Done);
                           Put (Trap & ":");
                           Emit ("ud2");
                           Put (Done & ":");
                        end;
                     else
                        declare
                           From : constant Landin.Types.Integer_Name :=
                             Landin.Types.Integer_Name (From_Kind);
                           Into_Type : constant Landin.Types.Integer_Name :=
                             Landin.Types.Integer_Name (Into_Kind);
                           From_Size : constant Held_Size :=
                             Size_Of (From, Facts);
                           Into_Size : constant Held_Size :=
                             Size_Of (Into_Type, Facts);
                           Into_Bits : constant Landin.Targets.Bit_Width :=
                             Landin.Types.Width (Into_Type, Facts);
                           Safe_Lower : constant String :=
                             Value_Label (Value) & "_lower";
                           Safe_Upper : constant String :=
                             Value_Label (Value) & "_upper";
                        begin
                           if Landin.Types.Is_Signed (From) then
                              Emit
                                ((case From_Size is
                                    when Landin.Targets.Byte_1 => "movsbq ",
                                    when Landin.Targets.Byte_2 => "movswq ",
                                    when Landin.Targets.Byte_4 => "movslq ",
                                    when Landin.Targets.Byte_8 => "movq ")
                                 & Value_Cell (Source) & ", %rax");
                           else
                              Emit ("movq $0, %rax");
                              Emit ("mov" & Suffix (From_Size) & " "
                                    & Value_Cell (Source) & ", "
                                    & Accumulator (From_Size));
                           end if;

                           if Landin.Types.Is_Signed (Into_Type) then
                              declare
                                 Maximum : constant Landin.Types.Magnitude :=
                                   2 ** (Natural (Into_Bits) - 1) - 1;
                              begin
                                 if Landin.Types.Is_Signed (From) then
                                    Emit
                                      ("movabsq $-"
                                       & Trimmed
                                           (Landin.Types.Magnitude'Image
                                              (Maximum + 1))
                                       & ", %rcx");
                                    Emit ("cmpq %rcx, %rax");
                                    Emit ("jge " & Safe_Lower);
                                    Emit ("ud2");
                                    Put (Safe_Lower & ":");
                                 end if;
                                 Emit
                                   ("movabsq $"
                                    & Trimmed
                                        (Landin.Types.Magnitude'Image
                                           (Maximum))
                                    & ", %rcx");
                                 Emit ("cmpq %rcx, %rax");
                                 Emit
                                   ((if Landin.Types.Is_Signed (From)
                                     then "jle " else "jbe ")
                                    & Safe_Upper);
                                 Emit ("ud2");
                                 Put (Safe_Upper & ":");
                              end;
                           elsif Landin.Types.Is_Signed (From) then
                              Emit ("testq %rax, %rax");
                              Emit ("jns " & Safe_Lower);
                              Emit ("ud2");
                              Put (Safe_Lower & ":");
                           end if;

                           if not Landin.Types.Is_Signed (Into_Type)
                             and then Into_Bits < 64
                           then
                              declare
                                 Maximum : constant Landin.Types.Magnitude :=
                                   2 ** Natural (Into_Bits) - 1;
                              begin
                                 Emit
                                   ("movabsq $"
                                    & Trimmed
                                        (Landin.Types.Magnitude'Image
                                           (Maximum))
                                    & ", %rcx");
                                 Emit ("cmpq %rcx, %rax");
                                 Emit ("jbe " & Safe_Upper);
                                 Emit ("ud2");
                                 Put (Safe_Upper & ":");
                              end;
                           end if;
                           Emit ("mov" & Suffix (Into_Size) & " "
                                 & Accumulator (Into_Size) & ", "
                                 & Value_Cell (Value));
                        end;
                     end if;
                  end;

               when Landin.IR.Slice_Address =>
                  declare
                     Safe_Upper : constant String :=
                       Value_Label (Value) & "_upper";
                     Safe_Lower : constant String :=
                       Value_Label (Value) & "_lower";
                     Element : constant Landin.IR.Field_Shape :=
                       Landin.IR.Slice_Element_Shape
                         (Of_Unit, Item, Value);
                     Stride : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Landin.Backend.Field_Extent
                       (Of_Unit, Element, Facts, Stride, Alignment);
                     pragma Unreferenced (Alignment);
                     Emit ("movq " & Value_Cell (Operand (4)) & ", %rax");
                     Emit ("cmpq " & Value_Cell (Operand (2)) & ", %rax");
                     Emit
                       ((if Landin.IR.Slice_Is_Inclusive
                              (Of_Unit, Item, Value)
                         then "jb " else "jbe ") & Safe_Upper);
                     Emit ("ud2");
                     Put (Safe_Upper & ":");
                     Emit ("movq " & Value_Cell (Operand (3)) & ", %rcx");
                     Emit ("cmpq " & Value_Cell (Operand (4)) & ", %rcx");
                     Emit ("jbe " & Safe_Lower);
                     Emit ("ud2");
                     Put (Safe_Lower & ":");
                     if Stride > 1 then
                        Emit
                          ("imulq $"
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image (Stride))
                           & ", %rcx, %rcx");
                     end if;
                     Emit ("movq " & Value_Cell (Operand (1)) & ", %rax");
                     Emit ("addq %rcx, %rax");
                     Carry
                       (Landin.Targets.Byte_8, "%rax", Value_Cell (Value));
                  end;

               when Landin.IR.Empty_Slice_Base =>
                  declare
                     Element : constant Landin.IR.Field_Shape :=
                       Landin.IR.Slice_Element_Shape
                         (Of_Unit, Item, Value);
                     Size : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Landin.Backend.Field_Extent
                       (Of_Unit, Element, Facts, Size, Alignment);
                     pragma Unreferenced (Size);
                     Emit
                       ("movq $"
                        & Trimmed
                            (Landin.Targets.Byte_Alignment'Image (Alignment))
                        & ", " & Value_Cell (Value));
                  end;

               when Landin.IR.Load_Indirect =>
                  declare
                     Held : constant Held_Size := Size_Of_Value (Value);
                  begin
                     Emit ("movq " & Value_Cell (Operand (1)) & ", %rcx");
                     Emit ("mov" & Suffix (Held) & " (%rcx), "
                           & Accumulator (Held));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", " & Value_Cell (Value));
                  end;

               when Landin.IR.Store_Indirect =>
                  declare
                     Held : constant Held_Size := Size_Of_Value (Operand (2));
                  begin
                     Emit ("movq " & Value_Cell (Operand (1)) & ", %rcx");
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (2)) & ", "
                           & Accumulator (Held));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", (%rcx)");
                  end;

               when Landin.IR.Load =>
                  declare
                     Slot : constant Landin.IR.Slot_Id :=
                       Landin.IR.Slot_Of (Of_Unit, Item, Value);
                  begin
                     Carry (Size_Of_Slot (Slot), Slot_Cell (Slot),
                            Value_Cell (Value));
                  end;

               when Landin.IR.Store =>
                  declare
                     Slot : constant Landin.IR.Slot_Id :=
                       Landin.IR.Slot_Of (Of_Unit, Item, Value);
                  begin
                     Carry (Size_Of_Slot (Slot),
                            Value_Cell (Operand (1)), Slot_Cell (Slot));
                  end;

               when Landin.IR.Shift_Left | Landin.IR.Shift_Right =>
                  --  Two rules the hardware does not give.  [0320] fills with
                  --  zeros beyond the width for any amount, and x86-64 masks
                  --  the count to five or six bits instead, so the width test
                  --  is emitted here.  And [1950] leaves an amount the
                  --  compiler could not read to the trap; `L0306` has already
                  --  refused the negative ones it knew.  D6 gives the amount
                  --  the left operand's type, so both tests are at that width
                  --  rather than at the count's.
                  declare
                     Kind : constant Landin.Types.Integer_Name :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Signed : constant Boolean :=
                       Landin.Types.Is_Signed (Kind);
                     Bits : constant Landin.Targets.Bit_Width :=
                       Landin.Types.Width (Kind, Facts);
                     Not_Negative : constant String :=
                       Value_Label (Value) & "_nonnegative";
                     In_Range : constant String :=
                       Value_Label (Value) & "_inrange";
                     Done : constant String :=
                       Value_Label (Value) & "_done";
                     Instruction : constant String :=
                       (if Op = Landin.IR.Shift_Left then "shl"
                        elsif Signed then "sar"
                        else "shr");
                  begin
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (2)) & ", "
                           & Accumulator (Held));

                     if Signed then
                        Emit ("cmp" & Suffix (Held) & " $0, "
                              & Accumulator (Held));
                        Emit ("jge " & Not_Negative);
                        Emit ("ud2");
                        Put (Not_Negative & ":");
                     end if;

                     --  Every remaining amount is at or above zero, so the
                     --  width test is an unsigned one on both signednesses.
                     Emit ("cmp" & Suffix (Held) & " $"
                           & Trimmed
                               (Landin.Targets.Bit_Width'Image (Bits))
                           & ", " & Accumulator (Held));
                     Emit ("jb " & In_Range);
                     Emit ("mov" & Suffix (Held) & " $0, "
                           & Value_Cell (Value));
                     Emit ("jmp " & Done);
                     Put (In_Range & ":");

                     --  The count is below the width, so its low byte is the
                     --  whole of it and `%cl` is where a variable count goes.
                     Emit ("movb " & Value_Cell (Operand (2)) & ", %cl");
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit (Instruction & Suffix (Held) & " %cl, "
                           & Accumulator (Held));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                     Put (Done & ":");
                  end;

               when Landin.IR.Bitwise_And
                  | Landin.IR.Bitwise_Xor
                  | Landin.IR.Bitwise_Or =>
                  --  [0330] gives each of these its own integer type back, so
                  --  every pattern they produce is one the type holds and
                  --  neither signedness nor a flag has anything to say.
                  declare
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Instruction : constant String :=
                       (case Op is
                           when Landin.IR.Bitwise_And => "and",
                           when Landin.IR.Bitwise_Xor => "xor",
                           when Landin.IR.Bitwise_Or => "or",
                           when others => raise Program_Error);
                  begin
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit (Instruction & Suffix (Held) & " "
                           & Value_Cell (Operand (2)) & ", "
                           & Accumulator (Held));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                  end;

               when Landin.IR.Logical_Not =>
                  --  [1870] fixes a bool at zero or one, so the low bit is
                  --  the whole value and `not` over the byte would give 254
                  --  for `not false`.
                  Emit ("movb " & Value_Cell (Operand (1)) & ", %al");
                  Emit ("xorb $1, %al");
                  Emit ("movb %al, " & Value_Cell (Value));

               when Landin.IR.Negation =>
                  --  [1890] gives unary minus its own integer type back, so
                  --  the lowest signed value has no negation the type holds
                  --  and no unsigned value but zero has one at all.  `neg`
                  --  reports the first as overflow and the second as carry.
                  declare
                     Kind : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Next : constant String := Value_Label (Value);
                  begin
                     if Kind in Landin.Types.Float_Name then
                        Emit ("mov" & Suffix (Held) & " "
                              & Value_Cell (Operand (1)) & ", "
                              & Accumulator (Held));
                        Emit
                          ((if Kind = Landin.Types.F32
                            then "xorl $2147483648, %eax"
                            else "btcq $63, %rax"));
                        Emit ("mov" & Suffix (Held) & " "
                              & Accumulator (Held) & ", "
                              & Value_Cell (Value));
                        return;
                     end if;

                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit ("neg" & Suffix (Held) & " " & Accumulator (Held));
                     Emit ((if Landin.Types.Is_Signed
                                   (Landin.Types.Integer_Name (Kind))
                            then "jno " else "jnc ") & Next);
                     Emit ("ud2");
                     Put (Next & ":");
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                  end;

               when Landin.IR.Complement =>
                  --  [0330]'s `~` gives its own type back, so every pattern
                  --  it can produce is one the type holds and no edge is
                  --  needed.
                  declare
                     Held : constant Held_Size := Size_Of_Value (Value);
                  begin
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit ("not" & Suffix (Held) & " " & Accumulator (Held));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                  end;

               when Landin.IR.Copy_Array =>
                  --  D20/D50 move bytes directly between storage places.
                  --  Each field is a declaration-order identity; its target
                  --  offset is derived here.  The instruction stays one
                  --  operation even when D18 makes the extent too large for
                  --  the compiler host to enumerate.
                  declare
                     Source : constant Landin.IR.Storage :=
                       Landin.IR.Source_Of (Of_Unit, Item, Value);
                     Source_Field : constant Natural :=
                       Landin.IR.Source_Field_Of (Of_Unit, Item, Value);
                     Source_Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Source_Path_Of
                         (Of_Unit, Item, Value);
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Destination_Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Destination_Nested :
                       constant Landin.IR.Path_Step_Array :=
                         Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Destination_Case : constant Natural :=
                       Landin.IR.Variant_Case_Of (Of_Unit, Item, Value);
                     Destination_Payload_Field : constant Natural :=
                       Landin.IR.Variant_Payload_Field_Of
                         (Of_Unit, Item, Value);

                     Bytes : constant Landin.Targets.Byte_Count :=
                       Whole_Clear_Extent
                         (Source, Source_Field, Source_Nested);
                  begin
                     Storage_Address
                       (Destination, Destination_Field, "%rdi",
                        Destination_Case, Destination_Payload_Field,
                        Destination_Nested);
                     Storage_Address
                       (Source, Source_Field, "%rsi",
                        Nested => Source_Nested);
                     Emit
                       ("movabsq $"
                        & Trimmed
                            (Landin.Targets.Byte_Count'Image (Bytes))
                        & ", %rcx");
                     Emit ("cld");
                     Emit ("rep movsb");
                  end;

               when Landin.IR.Copy_Variant =>
                  --  D80 moves the complete padded unfolded part.  Both
                  --  endpoints were proved to have the same neutral shape;
                  --  offsets and extent are derived for this target here.
                  declare
                     Source : constant Landin.IR.Storage :=
                       Landin.IR.Source_Of (Of_Unit, Item, Value);
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     --  D126: the two endpoints have one shape and need
                     --  not sit in the same place, so each names its own.
                     Field : constant Positive := Positive
                       (Landin.IR.Source_Field_Of
                          (Of_Unit, Item, Value));
                     Into_Field : constant Positive := Positive
                       (Landin.IR.Element_Field_Of
                          (Of_Unit, Item, Value));
                     From_Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Source_Path_Of (Of_Unit, Item, Value);
                     Into_Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Shape : constant Landin.IR.Field_Shape :=
                       Reached_Shape (Source, Field, From_Nested);
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Landin.Backend.Field_Extent
                       (Of_Unit, Shape, Facts, Bytes, Alignment);
                     Storage_Address
                       (Destination, Into_Field, "%rdi",
                        Nested => Into_Nested);
                     Storage_Address
                       (Source, Field, "%rsi", Nested => From_Nested);
                     Emit
                       ("movabsq $"
                        & Trimmed
                            (Landin.Targets.Byte_Count'Image (Bytes))
                        & ", %rcx");
                     Emit ("cld");
                     Emit ("rep movsb");
                  end;

               when Landin.IR.Clear_Array =>
                  --  D28 clears complete array storage without making IR or
                  --  compiler work proportional to D18's extent.  D49 carries
                  --  a declaration-order array-field identity.  D57 gives
                  --  field zero of aggregate storage its complete padded
                  --  extent, so [0540]'s all-bit image includes padding.
                  declare
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Bytes : constant Landin.Targets.Byte_Count :=
                       Whole_Clear_Extent (Destination, Field, Nested);
                  begin
                     Storage_Address
                       (Destination, Field, "%rdi", Nested => Nested);
                     Emit ("xorl %eax, %eax");
                     Emit
                       ("movabsq $"
                        & Trimmed
                            (Landin.Targets.Byte_Count'Image (Bytes))
                        & ", %rcx");
                     Emit ("cld");
                     Emit ("rep stosb");
                  end;

               when Landin.IR.Load_Variant_Tag =>
                  declare
                     Source : constant Landin.IR.Storage :=
                       Landin.IR.Source_Of (Of_Unit, Item, Value);
                     Field : constant Positive := Positive
                       (Landin.IR.Element_Field_Of
                          (Of_Unit, Item, Value));
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Shape : constant Landin.IR.Field_Shape :=
                       Reached_Shape (Source, Field, Nested);
                     Held : constant Held_Size :=
                       Size_Of (Shape.Element, Facts);
                  begin
                     Storage_Address
                       (Source, Field, "%rcx", Nested => Nested);
                     Carry (Held, "(%rcx)", Value_Cell (Value));
                  end;

               when Landin.IR.Load_Variant_Field =>
                  declare
                     Source : constant Landin.IR.Storage :=
                       Landin.IR.Source_Of (Of_Unit, Item, Value);
                     Field : constant Positive := Positive
                       (Landin.IR.Element_Field_Of
                          (Of_Unit, Item, Value));
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Shape : constant Landin.IR.Field_Shape :=
                       Reached_Shape (Source, Field, Nested);
                     Which : constant Positive := Positive
                       (Landin.IR.Variant_Case_Of
                          (Of_Unit, Item, Value));
                     Payload_Field : constant Positive := Positive
                       (Landin.IR.Variant_Payload_Field_Of
                          (Of_Unit, Item, Value));
                     Leaf : constant Landin.IR.Field_Shape :=
                       Landin.IR.Nth_Variant_Case_Field
                         (Of_Unit, Shape, Which, Payload_Field);
                     At_Offset : constant Landin.Targets.Byte_Count :=
                       Landin.Backend.Variant_Payload_Field_Offset
                         (Of_Unit, Shape, Which, Payload_Field, Facts);
                     Held : constant Held_Size :=
                       Size_Of (Leaf.Element, Facts);
                  begin
                     Storage_Address
                       (Source, Field, "%rcx", Nested => Nested);
                     if At_Offset > 0 then
                        Emit
                          ("movabsq $"
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image (At_Offset))
                           & ", %rdx");
                        Emit ("addq %rdx, %rcx");
                     end if;
                     Carry (Held, "(%rcx)", Value_Cell (Value));
                  end;

               when Landin.IR.Select_Variant =>
                  declare
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Positive := Positive
                       (Landin.IR.Element_Field_Of
                          (Of_Unit, Item, Value));
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Shape : constant Landin.IR.Field_Shape :=
                       Reached_Shape (Destination, Field, Nested);
                     Size : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                     Tag : constant Natural :=
                       Landin.IR.Variant_Case_Of
                         (Of_Unit, Item, Value) - 1;
                     Held : constant Held_Size :=
                       Size_Of (Shape.Element, Facts);
                  begin
                     Landin.Backend.Field_Extent
                       (Of_Unit, Shape, Facts, Size, Alignment);
                     Storage_Address
                       (Destination, Field, "%rdi", Nested => Nested);
                     Emit
                       ("movabsq $"
                        & Trimmed
                            (Landin.Targets.Byte_Count'Image (Size))
                        & ", %rcx");
                     Emit ("xorl %eax, %eax");
                     Emit ("rep stosb");

                     --  rep stosb advances %rdi, so form the part base
                     --  again before writing the source-order tag.
                     Storage_Address
                       (Destination, Field, "%rcx", Nested => Nested);
                     Emit
                       ("mov" & Suffix (Held) & " $"
                        & Trimmed (Natural'Image (Tag)) & ", (%rcx)");
                  end;

               when Landin.IR.Store_Variant_Field =>
                  declare
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Positive := Positive
                       (Landin.IR.Element_Field_Of
                          (Of_Unit, Item, Value));
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Shape : constant Landin.IR.Field_Shape :=
                       Reached_Shape (Destination, Field, Nested);
                     Which : constant Positive :=
                       Positive
                         (Landin.IR.Variant_Case_Of
                            (Of_Unit, Item, Value));
                     Payload_Field : constant Positive :=
                       Positive
                         (Landin.IR.Variant_Payload_Field_Of
                            (Of_Unit, Item, Value));
                     Leaf : constant Landin.IR.Field_Shape :=
                       Landin.IR.Nth_Variant_Case_Field
                         (Of_Unit, Shape, Which, Payload_Field);
                     At_Offset : constant Landin.Targets.Byte_Count :=
                       Landin.Backend.Variant_Payload_Field_Offset
                         (Of_Unit, Shape, Which, Payload_Field, Facts);
                     Held : constant Held_Size :=
                       Size_Of (Leaf.Element, Facts);
                  begin
                     Storage_Address
                       (Destination, Field, "%rcx", Nested => Nested);
                     if At_Offset > 0 then
                        Emit
                          ("movabsq $"
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image (At_Offset))
                           & ", %rdx");
                        Emit ("addq %rdx, %rcx");
                     end if;
                     Carry (Held, Value_Cell (Operand (1)), "(%rcx)");
                  end;

               when Landin.IR.Fill_Array =>
                  --  D32 evaluates one scalar and repeats its target-width
                  --  pattern through the destination.  D53 may name an array
                  --  field; the element count, width and both containing and
                  --  suffix offsets stay compact and target-derived.
                  declare
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Which : constant Natural :=
                       Landin.IR.Variant_Case_Of (Of_Unit, Item, Value);
                     Payload_Field : constant Natural :=
                       Landin.IR.Variant_Payload_Field_Of
                         (Of_Unit, Item, Value);
                     Length : constant Landin.IR.Element_Total :=
                       Array_Length_Of
                         (Destination, Field, Which, Payload_Field, Nested);
                     Element : constant Landin.Types.Scalar_Name :=
                       Array_Element_Of
                         (Destination, Field, Which, Payload_Field, Nested);
                     Held : constant Held_Size := Size_Of (Element, Facts);
                     First : constant Landin.IR.Part_Position :=
                       Landin.IR.First_Part_Of (Of_Unit, Item, Value);
                     Count : constant Landin.IR.Element_Total :=
                       Length - (Landin.IR.Element_Total (First) - 1);
                     Offset : constant Landin.Targets.Byte_Count :=
                       Landin.Targets.Byte_Count
                         (Landin.IR.Element_Total (First) - 1)
                       * Landin.Targets.Byte_Count
                           (Landin.Targets.Bytes (Held));
                  begin
                     Storage_Address
                       (Destination, Field, "%rdi", Which, Payload_Field,
                        Nested);
                     if Offset /= 0 then
                        Emit
                          ("addq $"
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image (Offset))
                           & ", %rdi");
                     end if;
                     Emit
                       ("mov" & Suffix (Held) & " "
                        & Value_Cell (Operand (1)) & ", "
                        & Accumulator (Held));
                     Emit
                       ("movabsq $"
                        & Trimmed (Landin.IR.Element_Total'Image (Count))
                        & ", %rcx");
                     Emit ("cld");
                     Emit ("rep stos" & Suffix (Held));
                  end;

               when Landin.IR.Load_Datum | Landin.IR.Store_Datum =>
                  --  A module value is named rather than offset from a
                  --  frame, and RIP-relative is how x86-64 names one
                  --  without a relocation the loader has to fix up.
                  declare
                     Datum : constant Landin.IR.Item_Id :=
                       Landin.IR.Datum_Of (Of_Unit, Item, Value);
                     Kind : constant Landin.Types.Scalar_Name :=
                       Landin.IR.Result_Of (Of_Unit, Datum);
                     Held : constant Held_Size := Size_Of (Kind, Facts);
                     Place : constant String :=
                       Symbol (Datum) & "(%rip)";
                  begin
                     if Op = Landin.IR.Load_Datum then
                        Carry (Held, Place, Value_Cell (Value));
                     else
                        Carry (Held, Value_Cell (Operand (1)), Place);
                     end if;
                  end;

               when Landin.IR.Load_Element | Landin.IR.Store_Element =>
                  --  [0580] requires the bounds check before any address
                  --  computation.  Keep the index in %rax through the
                  --  unsigned comparison, trap on index >= length, and only
                  --  then scale it and add it to the array's base address.
                  --  D22 lets the base be a module datum's symbol or a
                  --  frame slot's %rbp-relative address; D48 may move that
                  --  base to an aggregate field.  D89 may move it once more
                  --  to a fixed array inside that ordinary child.
                  declare
                     Reaches_Slot : constant Boolean :=
                       Landin.IR.Reaches_A_Slot (Of_Unit, Item, Value);
                     Index : constant Landin.IR.Value_Id :=
                       Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Which : constant Natural :=
                       Landin.IR.Variant_Case_Of (Of_Unit, Item, Value);
                     Payload_Field : constant Natural :=
                       Landin.IR.Variant_Payload_Field_Of
                         (Of_Unit, Item, Value);
                     Place : constant Landin.IR.Storage :=
                       (if Reaches_Slot
                        then (Kind => Landin.IR.Frame_Slot,
                              Slot => Landin.IR.Slot_Of
                                (Of_Unit, Item, Value))
                        else (Kind => Landin.IR.Module_Datum,
                              Datum => Landin.IR.Datum_Of
                                (Of_Unit, Item, Value)));
                     Length : constant Landin.IR.Element_Total :=
                       Array_Length_Of
                         (Place, Field, Which, Payload_Field, Nested);
                     Element : constant Landin.IR.Field_Shape :=
                       Element_Shape_Of
                         (Place, Field, Which, Payload_Field, Nested);
                     Stride : constant Landin.Targets.Byte_Count :=
                       Element_Bytes_Of
                         (Place, Field, Which, Payload_Field, Nested);
                     --  D121: the element may be an aggregate, and then
                     --  what the operation loads is a leaf inside it.
                     Below : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Element_Path_Of (Of_Unit, Item, Value);
                     Kind : constant Landin.Types.Scalar_Name :=
                       Landin.IR.Shape_At (Of_Unit, Element, Below).Element;
                     Inside : constant Landin.Targets.Byte_Count :=
                       Path_Offset (Element, Below);
                     Held : constant Held_Size := Size_Of (Kind, Facts);
                     Safe : constant String := Value_Label (Value) & "_index";
                  begin
                     Emit ("movq " & Value_Cell (Index) & ", %rax");
                     Emit
                       ("movabsq $"
                        & Trimmed (Landin.IR.Element_Total'Image (Length))
                        & ", %rdx");
                     Emit ("cmpq %rdx, %rax");
                     Emit ("jb " & Safe);
                     Emit ("ud2");
                     Put (Safe & ":");
                     --  An `imul` immediate is a signed 32-bit field, and
                     --  D121's element may be wider than one, so a stride
                     --  that does not fit is formed in a register first.
                     if Stride <= 2 ** 31 - 1 then
                        Emit
                          ("imulq $"
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image (Stride))
                           & ", %rax, %rax");
                     else
                        Emit
                          ("movabsq $"
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image (Stride))
                           & ", %rdx");
                        Emit ("imulq %rdx, %rax");
                     end if;

                     --  Storage_Address first derives the top-level field
                     --  and D84's selected payload offset; only after the
                     --  bounds check above is the scaled index added, and
                     --  only then the run inside the element.
                     Storage_Address
                       (Place, Field, "%rcx", Which, Payload_Field, Nested);
                     Emit ("addq %rax, %rcx");
                     if Inside > 0 then
                        Emit
                          ("movabsq $"
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image (Inside))
                           & ", %rdx");
                        Emit ("addq %rdx, %rcx");
                     end if;

                     if Op = Landin.IR.Load_Element then
                        Carry (Held, "(%rcx)", Value_Cell (Value));
                     else
                        Carry
                          (Held, Value_Cell (Operand (2)), "(%rcx)");
                     end if;
                  end;

               when Landin.IR.Load_Field | Landin.IR.Store_Field =>
                  if Landin.IR.Reaches_A_Slot (Of_Unit, Item, Value) then
                     --  [1810]'s local: a cell in this frame, reached the
                     --  way every other cell is and at the field's own
                     --  displacement inside it.
                     declare
                        Slot : constant Landin.IR.Slot_Id :=
                          Landin.IR.Slot_Of (Of_Unit, Item, Value);
                        Which : constant Landin.IR.Part_Position :=
                          Landin.IR.Field_Of (Of_Unit, Item, Value);
                        Nested : constant Landin.IR.Path_Step_Array :=
                          Landin.IR.Path_Of (Of_Unit, Item, Value);
                     begin
                        if Landin.IR.Is_Address (Of_Unit, Item, Slot) then
                           declare
                              Place : constant Landin.IR.Storage :=
                                (Kind => Landin.IR.Runtime_Address,
                                 Address => Slot);
                              Shape : constant Landin.IR.Field_Shape :=
                                (if Nested'Length = 0
                                 then Part_Shape_Of (Place, Which)
                                 else Landin.IR.Shape_At
                                   (Of_Unit,
                                    Part_Shape_Of (Place, Which), Nested));
                              Held : constant Held_Size :=
                                Size_Of (Shape.Element, Facts);
                           begin
                              Storage_Address
                                (Place, Natural (Which), "%rcx",
                                 Nested => Nested);
                              if Op = Landin.IR.Load_Field then
                                 Carry
                                   (Held, "(%rcx)", Value_Cell (Value));
                              else
                                 Carry
                                   (Held, Value_Cell (Operand (1)),
                                    "(%rcx)");
                              end if;
                              return;
                           end;
                        end if;

                        declare
                           Kind : constant Landin.Types.Scalar_Name :=
                             (if Nested'Length = 0
                              then Landin.IR.Nth_Slot_Part
                                (Of_Unit, Item, Slot, Which)
                              else Landin.IR.Shape_At
                                (Of_Unit,
                                 Part_Shape_Of
                                   ((Kind => Landin.IR.Frame_Slot,
                                     Slot => Slot), Which),
                                 Nested).Element);
                           Held : constant Held_Size := Size_Of (Kind, Facts);
                           Top : constant Landin.Targets.Byte_Count :=
                             Field_Offset
                               (Of_Unit, Item, Layout, Slot, Which, Facts);
                           --  A cell grows downward and [0750] lays a struct
                           --  out upward, so the whole path moves the leaf
                           --  back toward the frame pointer.
                           At_Offset : constant Landin.Targets.Byte_Count :=
                             (if Nested'Length = 0 then Top
                              else Top - Path_Offset
                                (Part_Shape_Of
                                   ((Kind => Landin.IR.Frame_Slot,
                                     Slot => Slot), Which),
                                 Nested));
                           Place : constant String := Cell (At_Offset);
                        begin
                           if Op = Landin.IR.Load_Field then
                              Carry (Held, Place, Value_Cell (Value));
                           else
                              Carry (Held, Value_Cell (Operand (1)), Place);
                           end if;
                        end;
                     end;

                     return;
                  end if;

                  --  [0750] puts the field where the same placement the
                  --  checker used puts it.  A small offset is a displacement
                  --  from the datum's symbol; D18 can make an array offset
                  --  wider than that instruction field, so a large one is
                  --  added to the symbol address in registers.
                  declare
                     Datum : constant Landin.IR.Item_Id :=
                       Landin.IR.Datum_Of (Of_Unit, Item, Value);
                     Which : constant Landin.IR.Part_Position :=
                       Landin.IR.Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     At_Offset : constant Landin.Targets.Byte_Count :=
                       Field_Offset (Datum, Which)
                       + (if Nested'Length = 0
                          then Landin.Targets.Byte_Count'(0)
                          else Path_Offset
                            (Part_Shape_Of
                               ((Kind  => Landin.IR.Module_Datum,
                                 Datum => Datum), Which),
                             Nested));
                     Kind : constant Landin.Types.Scalar_Name :=
                       (if Nested'Length = 0
                        then Landin.IR.Nth_Part (Of_Unit, Datum, Which)
                        else Landin.IR.Shape_At
                               (Of_Unit,
                                Part_Shape_Of
                                  ((Kind  => Landin.IR.Module_Datum,
                                    Datum => Datum), Which),
                                Nested).Element);
                     Held : constant Held_Size := Size_Of (Kind, Facts);
                  begin
                     --  A RIP-relative memory operand has a signed 32-bit
                     --  displacement, and its relocation is symbol plus
                     --  offset minus instruction: the offset alone cannot
                     --  prove that it fits.  D18 lets an array span the full
                     --  target range, so form every nonzero element address
                     --  in registers rather than leave that placement
                     --  question to an unencodable relocation.
                     if (Landin.IR.Result_Of (Of_Unit, Datum)
                           = Landin.Types.Fixed_Array
                         or else Has_Wide_Field (Datum))
                       and then At_Offset > 0
                     then
                        Emit ("leaq " & Symbol (Datum) & "(%rip), %rcx");
                        Emit
                          ("movabsq $"
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image (At_Offset))
                           & ", %rdx");
                        Emit ("addq %rdx, %rcx");

                        if Op = Landin.IR.Load_Field then
                           Carry (Held, "(%rcx)", Value_Cell (Value));
                        else
                           Carry
                             (Held, Value_Cell (Operand (1)), "(%rcx)");
                        end if;
                     else
                        declare
                           Place : constant String :=
                             Symbol (Datum)
                             & (if At_Offset = 0 then ""
                                else "+"
                                     & Trimmed
                                         (Landin.Targets.Byte_Count'Image
                                            (At_Offset)))
                             & "(%rip)";
                        begin
                           if Op = Landin.IR.Load_Field then
                              Carry (Held, Place, Value_Cell (Value));
                           else
                              Carry
                                (Held, Value_Cell (Operand (1)), Place);
                           end if;
                        end;
                     end if;
                  end;

               when Landin.IR.Add | Landin.IR.Subtract =>
                  declare
                     Kind : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Next : constant String := Value_Label (Value);
                  begin
                     if Kind in Landin.Types.Float_Name then
                        Emit ((if Kind = Landin.Types.F32
                               then "movss " else "movsd ")
                              & Value_Cell (Operand (1)) & ", %xmm0");
                        Emit ((if Op = Landin.IR.Add then "add" else "sub")
                              & (if Kind = Landin.Types.F32
                                 then "ss " else "sd ")
                              & Value_Cell (Operand (2)) & ", %xmm0");
                        Emit ((if Kind = Landin.Types.F32
                               then "movss " else "movsd ")
                              & "%xmm0, " & Value_Cell (Value));
                        return;
                     end if;

                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit ((if Op = Landin.IR.Add then "add" else "sub")
                           & Suffix (Held) & " "
                           & Value_Cell (Operand (2)) & ", "
                           & Accumulator (Held));
                     Emit ((if Landin.Types.Is_Signed
                                   (Landin.Types.Integer_Name (Kind))
                            then "jno " else "jnc ") & Next);
                     Emit ("ud2");
                     Put (Next & ":");
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                  end;

               when Landin.IR.Wrapping_Add
                  | Landin.IR.Wrapping_Subtract =>
                  declare
                     Held : constant Held_Size := Size_Of_Value (Value);
                  begin
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit ((if Op = Landin.IR.Wrapping_Add
                            then "add" else "sub") & Suffix (Held) & " "
                           & Value_Cell (Operand (2)) & ", "
                           & Accumulator (Held));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                  end;

               when Landin.IR.Divide | Landin.IR.Remainder =>
                  declare
                     Kind : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Nonzero : constant String :=
                       Value_Label (Value) & "_nonzero";
                     Divide : constant String :=
                       Value_Label (Value) & "_divide";
                     Done : constant String :=
                       Value_Label (Value) & "_done";
                  begin
                     if Kind in Landin.Types.Float_Name then
                        if Op /= Landin.IR.Divide then
                           raise Compiler_Defect with
                             "float remainder passed IR verification";
                        end if;
                        Emit ((if Kind = Landin.Types.F32
                               then "movss " else "movsd ")
                              & Value_Cell (Operand (1)) & ", %xmm0");
                        Emit ((if Kind = Landin.Types.F32
                               then "divss " else "divsd ")
                              & Value_Cell (Operand (2)) & ", %xmm0");
                        Emit ((if Kind = Landin.Types.F32
                               then "movss " else "movsd ")
                              & "%xmm0, " & Value_Cell (Value));
                        return;
                     end if;

                     declare
                        Integer_Kind : constant Landin.Types.Integer_Name :=
                          Landin.Types.Integer_Name (Kind);
                        Signed : constant Boolean :=
                          Landin.Types.Is_Signed (Integer_Kind);
                        Minimum_Pattern : constant Landin.Types.Magnitude :=
                          2 ** Natural
                            (Landin.Types.Width (Integer_Kind, Facts) - 1);
                     begin
                        Emit ("cmp" & Suffix (Held) & " $0, "
                              & Value_Cell (Operand (2)));
                        Emit ("jne " & Nonzero);
                        Emit ("ud2");
                        Put (Nonzero & ":");

                        if Signed then
                           Emit ("cmp" & Suffix (Held) & " $-1, "
                                 & Value_Cell (Operand (2)));
                           Emit ("jne " & Divide);
                           Emit ("movabsq $"
                                 & Trimmed
                                     (Landin.Types.Magnitude'Image
                                        (Minimum_Pattern))
                                 & ", %rax");
                           Emit ("cmp" & Suffix (Held) & " "
                                 & Value_Cell (Operand (1)) & ", "
                                 & Accumulator (Held));
                           Emit ("jne " & Divide);
                           if Op = Landin.IR.Divide then
                              Emit ("ud2");
                           else
                              Emit ("mov" & Suffix (Held) & " $0, "
                                    & Value_Cell (Value));
                              Emit ("jmp " & Done);
                           end if;
                           Put (Divide & ":");
                        end if;

                        Emit ("mov" & Suffix (Held) & " "
                              & Value_Cell (Operand (1)) & ", "
                              & Accumulator (Held));
                        if Signed then
                           Emit
                             (case Held is
                                 when Landin.Targets.Byte_1 => "cbtw",
                                 when Landin.Targets.Byte_2 => "cwtd",
                                 when Landin.Targets.Byte_4 => "cltd",
                                 when Landin.Targets.Byte_8 => "cqto");
                        else
                           case Held is
                              when Landin.Targets.Byte_1 =>
                                 Emit ("movb $0, %ah");
                              when Landin.Targets.Byte_2 =>
                                 Emit ("xorw %dx, %dx");
                              when Landin.Targets.Byte_4 =>
                                 Emit ("xorl %edx, %edx");
                              when Landin.Targets.Byte_8 =>
                                 Emit ("xorq %rdx, %rdx");
                           end case;
                        end if;
                        Emit ((if Signed then "idiv" else "div")
                              & Suffix (Held) & " "
                              & Value_Cell (Operand (2)));
                        Emit ("mov" & Suffix (Held) & " "
                              & (if Op = Landin.IR.Divide
                                 then Accumulator (Held)
                                 else
                                   (case Held is
                                       when Landin.Targets.Byte_1 => "%ah",
                                       when Landin.Targets.Byte_2 => "%dx",
                                       when Landin.Targets.Byte_4 => "%edx",
                                       when Landin.Targets.Byte_8 => "%rdx"))
                              & ", " & Value_Cell (Value));
                        if Op = Landin.IR.Remainder then
                           Put (Done & ":");
                        end if;
                     end;
                  end;

               when Landin.IR.Multiply =>
                  declare
                     Kind : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                     Next : constant String := Value_Label (Value);
                  begin
                     if Kind in Landin.Types.Float_Name then
                        Emit ((if Kind = Landin.Types.F32
                               then "movss " else "movsd ")
                              & Value_Cell (Operand (1)) & ", %xmm0");
                        Emit ((if Kind = Landin.Types.F32
                               then "mulss " else "mulsd ")
                              & Value_Cell (Operand (2)) & ", %xmm0");
                        Emit ((if Kind = Landin.Types.F32
                               then "movss " else "movsd ")
                              & "%xmm0, " & Value_Cell (Value));
                        return;
                     end if;

                     declare
                        Signed : constant Boolean :=
                          Landin.Types.Is_Signed
                            (Landin.Types.Integer_Name (Kind));
                     begin
                        Emit ("mov" & Suffix (Held) & " "
                              & Value_Cell (Operand (1)) & ", "
                              & Accumulator (Held));
                        Emit ((if Signed then "imul" else "mul")
                              & Suffix (Held) & " "
                              & Value_Cell (Operand (2)));
                        Emit ((if Signed then "jno " else "jnc ") & Next);
                        Emit ("ud2");
                        Put (Next & ":");
                        Emit ("mov" & Suffix (Held) & " "
                              & Accumulator (Held) & ", "
                              & Value_Cell (Value));
                     end;
                  end;

               when Landin.IR.Wrapping_Multiply =>
                  declare
                     Kind : constant Landin.Types.Integer_Name :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                  begin
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit ((if Landin.Types.Is_Signed (Kind)
                            then "imul" else "mul")
                           & Suffix (Held) & " "
                           & Value_Cell (Operand (2)));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Cell (Value));
                  end;

               when Landin.IR.Equal_To
                  | Landin.IR.Not_Equal_To
                  | Landin.IR.Less_Than
                  | Landin.IR.Less_Or_Equal
                  | Landin.IR.Greater_Than
                  | Landin.IR.Greater_Or_Equal =>
                  declare
                     Kind : constant Landin.Types.Scalar_Name :=
                       Landin.IR.Result_Of
                         (Of_Unit, Item, Operand (1));
                     Held : constant Held_Size := Size_Of (Kind, Facts);
                     Signed : constant Boolean :=
                       Kind in Landin.Types.Integer_Name
                       and then Landin.Types.Is_Signed
                                  (Landin.Types.Integer_Name (Kind));
                     Condition : constant String :=
                       (case Op is
                           when Landin.IR.Equal_To => "sete",
                           when Landin.IR.Not_Equal_To => "setne",
                           when Landin.IR.Less_Than =>
                             (if Signed then "setl" else "setb"),
                           when Landin.IR.Less_Or_Equal =>
                             (if Signed then "setle" else "setbe"),
                           when Landin.IR.Greater_Than =>
                             (if Signed then "setg" else "seta"),
                           when Landin.IR.Greater_Or_Equal =>
                             (if Signed then "setge" else "setae"),
                           when others => raise Program_Error);
                  begin
                     if Kind in Landin.Types.Float_Name then
                        Emit ((if Kind = Landin.Types.F32
                               then "movss " else "movsd ")
                              & Value_Cell (Operand (1)) & ", %xmm0");
                        Emit ((if Kind = Landin.Types.F32
                               then "ucomiss " else "ucomisd ")
                              & Value_Cell (Operand (2)) & ", %xmm0");
                        case Op is
                           when Landin.IR.Equal_To =>
                              Emit ("sete %al");
                              Emit ("setnp %cl");
                              Emit ("andb %cl, %al");
                           when Landin.IR.Not_Equal_To =>
                              Emit ("setne %al");
                              Emit ("setp %cl");
                              Emit ("orb %cl, %al");
                           when Landin.IR.Less_Than
                              | Landin.IR.Less_Or_Equal =>
                              Emit
                                ((if Op = Landin.IR.Less_Than
                                  then "setb " else "setbe ") & "%al");
                              Emit ("setnp %cl");
                              Emit ("andb %cl, %al");
                           when Landin.IR.Greater_Than =>
                              Emit ("seta %al");
                           when Landin.IR.Greater_Or_Equal =>
                              Emit ("setae %al");
                           when others =>
                              raise Compiler_Defect with
                                "non-comparison in comparison emission";
                        end case;
                        Emit ("movb %al, " & Value_Cell (Value));
                        return;
                     end if;

                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Cell (Operand (1)) & ", "
                           & Accumulator (Held));
                     Emit ("cmp" & Suffix (Held) & " "
                           & Value_Cell (Operand (2)) & ", "
                           & Accumulator (Held));
                     Emit (Condition & " %al");
                     Emit ("movb %al, " & Value_Cell (Value));
                  end;

               when Landin.IR.Failure_Test =>
                  Emit ("cmpl $0, " & Value_Cell (Operand (1)));
                  Emit ("setne %al");
                  Emit ("movb %al, " & Value_Cell (Value));

               when Landin.IR.Function_Address =>
                  Emit
                    ("leaq "
                     & Symbol (Landin.IR.Callee_Of (Of_Unit, Item, Value))
                     & "(%rip), %rax");
                  Emit ("movq %rax, " & Value_Cell (Value));

               when Landin.IR.Evidence_Address =>
                  Emit
                    ("leaq "
                     & Evidence_Symbol
                         (Landin.IR.Evidence_Of (Of_Unit, Item, Value))
                     & "(%rip), %rax");
                  Emit ("movq %rax, " & Value_Cell (Value));

               when Landin.IR.Evidence_Function =>
                  declare
                     Which : constant Natural :=
                       Landin.IR.Evidence_Entry_Of (Of_Unit, Item, Value);
                     Offset : constant Landin.Targets.Byte_Count :=
                       Landin.Targets.Evidence_Function_Offset
                         (Facts, Positive (Which));
                  begin
                     Emit ("movq " & Value_Cell (Operand (1)) & ", %rax");
                     Emit
                       ("movq "
                        & Trimmed
                            (Landin.Targets.Byte_Count'Image (Offset))
                        & "(%rax), %rax");
                     Emit ("movq %rax, " & Value_Cell (Value));
                  end;

               when Landin.IR.Call | Landin.IR.Indirect_Call =>
                  --  [1920] names every parameter once and in order, so the
                  --  operands are already the argument list.  The first six
                  --  scalars fill the internal convention's integer
                  --  registers; each later scalar occupies an eight-byte
                  --  stack slot, in source order from the current `%rsp`.
                  --  Round the whole outgoing run to the target's stack
                  --  alignment, keeping the call boundary aligned without
                  --  making padding part of the argument run.  A `-> none`
                  --  callee defines nothing, and [1930] says there is no
                  --  result there to store.
                  declare
                     Gives : constant Landin.Types.Type_Kind :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Indirect : constant Boolean :=
                       Landin.IR.Op_Of (Of_Unit, Item, Value)
                         = Landin.IR.Indirect_Call;
                     Callee : constant Landin.IR.Item_Id :=
                       (if Indirect then Landin.IR.No_Item
                        else Landin.IR.Callee_Of
                          (Of_Unit, Item, Value));
                     Offset : constant Natural :=
                       (if Indirect then 1 else 0);
                     Count : constant Natural :=
                       Landin.IR.Operand_Count (Of_Unit, Item, Value) - Offset;
                     Stack_Bytes : constant Landin.Targets.Byte_Count :=
                       (if Count <= Register_Arguments then 0
                        else Landin.Targets.Align_Up
                          (Landin.Targets.Byte_Count
                             (Count - Register_Arguments)
                           * Stack_Argument_Bytes,
                           Landin.Targets.Stack_Alignment (Facts)));
                  begin
                     if Stack_Bytes > 0 then
                        Emit ("subq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image
                                     (Stack_Bytes))
                              & ", %rsp");
                     end if;

                     for Index in 1 .. Count loop
                        declare
                           Argument : constant Landin.IR.Value_Id :=
                             Operand (Index + Offset);
                           Held : constant Held_Size :=
                             Size_Of_Value (Argument);
                        begin
                           if Index <= Register_Arguments then
                              Emit ("mov" & Suffix (Held) & " "
                                    & Value_Cell (Argument) & ", "
                                    & Argument_Register (Index, Held));
                           else
                              Carry
                                (Held, Value_Cell (Argument),
                                 Trimmed
                                   (Landin.Targets.Byte_Count'Image
                                      (Landin.Targets.Byte_Count
                                         (Index - Register_Arguments - 1)
                                       * Stack_Argument_Bytes))
                                 & "(%rsp)");
                           end if;
                        end;
                     end loop;

                     if Indirect then
                        Emit ("call *" & Value_Cell (Operand (1)));
                     else
                        Emit ("call " & Symbol (Callee));
                     end if;

                     if Landin.IR.Failure_Slot_Of
                          (Of_Unit, Item, Value) /= Landin.IR.No_Slot
                     then
                        Emit
                          ("movl %r10d, "
                           & Slot_Cell
                               (Landin.IR.Failure_Slot_Of
                                  (Of_Unit, Item, Value)));
                     end if;

                     if Stack_Bytes > 0 then
                        Emit ("addq $"
                              & Trimmed
                                  (Landin.Targets.Byte_Count'Image
                                     (Stack_Bytes))
                              & ", %rsp");
                     end if;

                     if Gives in Landin.Types.Scalar_Name then
                        declare
                           Held : constant Held_Size :=
                             Size_Of (Gives, Facts);
                        begin
                           Emit ("mov" & Suffix (Held) & " "
                                 & Accumulator (Held) & ", "
                                 & Value_Cell (Value));
                        end;
                     end if;
                  end;

               when Landin.IR.Jump =>
                  Emit ("jmp "
                        & Label (Item,
                                 Landin.IR.Target_Of
                                   (Of_Unit, Item, Value)));

               when Landin.IR.Branch =>
                  --  A bool is a byte, and zero is [1870]'s `false`.
                  Emit ("cmpb $0, " & Value_Cell (Operand (1)));
                  Emit ("jne "
                        & Label (Item,
                                 Landin.IR.Target_Of
                                   (Of_Unit, Item, Value)));
                  Emit ("jmp "
                        & Label (Item,
                                 Landin.IR.Alternative_Of
                                   (Of_Unit, Item, Value)));

               when Landin.IR.Leave =>
                  --  [1810]'s return carries what the named return place
                  --  held; a `-> none` routine carries nothing.
                  if Result in Landin.Types.Scalar_Name then
                     declare
                        Held : constant Held_Size :=
                          Size_Of (Result, Facts);
                     begin
                        Emit ("mov" & Suffix (Held) & " "
                              & Value_Cell (Operand (1)) & ", "
                              & Accumulator (Held));
                     end;
                  elsif Result in Landin.Types.Aggregate
                                   | Landin.Types.Fixed_Array
                  then
                     declare
                        Return_Address : constant Landin.IR.Slot_Id :=
                          Landin.IR.Nth_Parameter (Of_Unit, Item, 1);
                        Return_Value : constant Landin.IR.Slot_Id :=
                          Landin.IR.Result_Slot (Of_Unit, Item);
                        Bytes : constant Landin.Targets.Byte_Count :=
                          Whole_Clear_Extent
                            ((Kind => Landin.IR.Frame_Slot,
                              Slot => Return_Value), 0,
                             Landin.IR.No_Path_Steps);
                     begin
                        Emit ("movq " & Slot_Cell (Return_Address)
                              & ", %rdi");
                        Storage_Address
                          ((Kind => Landin.IR.Frame_Slot,
                            Slot => Return_Value), 0, "%rsi");
                        Emit
                          ("movabsq $"
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image (Bytes))
                           & ", %rcx");
                        Emit ("cld");
                        Emit ("rep movsb");
                        Emit ("movq " & Slot_Cell (Return_Address)
                              & ", %rax");
                     end;
                  end if;

                  if Landin.IR.Signature_Of (Of_Unit, Item)
                       /= Landin.IR.No_Signature
                    and then Landin.IR.Signature_Errors
                      (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
                        /= Landin.IR.No_Atom_Set
                  then
                     Emit ("xorl %r10d, %r10d");
                  end if;
                  Emit_Epilogue;

               when Landin.IR.Fail =>
                  Emit ("movl " & Value_Cell (Operand (1)) & ", %r10d");
                  Emit_Epilogue;
            end case;
         end Emit_Instruction;

      begin
         if Is_Public_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;

         Put (Character'Val (9) & ".type " & Symbol (Item)
              & ", @function");
         Put (Symbol (Item) & ":");

         --  [1550]'s frame pointer, set up before anything reads a cell.
         Emit ("pushq %rbp");
         Emit ("movq %rsp, %rbp");

         --  The hosted entry keeps its source-level no-argument shape.  Its
         --  C argc/argv carriers are captured before ordinary Landin code can
         --  clobber them and exposed only through core/io's runtime bridge.
         if Item = Hosted_Entry then
            Emit ("movl %edi, .Llandin_host_argc(%rip)");
            Emit ("movq %rsi, .Llandin_host_argv(%rip)");
         end if;

         if Extent (Layout) > 0 then
            Emit ("subq $"
                  & Trimmed
                      (Landin.Targets.Byte_Count'Image (Extent (Layout)))
                  & ", %rsp");
         end if;

         --  A scalar parameter is copied directly into its slot.  D94's
         --  aggregate argument transports an address in the same position;
         --  preserve every such address before any byte copy clobbers the
         --  integer argument registers, then copy into the parameter's own
         --  aggregate frame slot.  The copy is what keeps `in` by value.
         for Index in 1 .. Landin.IR.Parameter_Count (Of_Unit, Item) loop
            declare
               Slot : constant Landin.IR.Slot_Id :=
                 Landin.IR.Nth_Parameter (Of_Unit, Item, Index);
            begin
               if not Landin.IR.Is_Aggregate (Of_Unit, Item, Slot)
                 and then not Landin.IR.Is_Array (Of_Unit, Item, Slot)
               then
                  declare
                     Held : constant Held_Size := Size_Of_Slot (Slot);
                  begin
                     if Index <= Register_Arguments then
                        Emit ("mov" & Suffix (Held) & " "
                              & Argument_Register (Index, Held) & ", "
                              & Slot_Cell (Slot));
                     else
                        Carry
                          (Held,
                           Trimmed
                             (Landin.Targets.Byte_Count'Image
                                (16 + Landin.Targets.Byte_Count
                                        (Index - Register_Arguments - 1)
                                      * Stack_Argument_Bytes))
                           & "(%rbp)",
                           Slot_Cell (Slot));
                     end if;
                  end;
               end if;
            end;
         end loop;

         for Index in 1 .. Landin.IR.Parameter_Count (Of_Unit, Item) loop
            declare
               Slot : constant Landin.IR.Slot_Id :=
                 Landin.IR.Nth_Parameter (Of_Unit, Item, Index);
            begin
               if Landin.IR.Is_Aggregate (Of_Unit, Item, Slot)
                 or else Landin.IR.Is_Array (Of_Unit, Item, Slot)
               then
                  if Index <= Register_Arguments then
                     Emit
                       ("pushq "
                        & Argument_Register (Index, Landin.Targets.Byte_8));
                  else
                     Emit
                       ("pushq "
                        & Trimmed
                            (Landin.Targets.Byte_Count'Image
                               (16 + Landin.Targets.Byte_Count
                                       (Index - Register_Arguments - 1)
                                     * Stack_Argument_Bytes))
                        & "(%rbp)");
                  end if;
               end if;
            end;
         end loop;

         for Index in reverse
           1 .. Landin.IR.Parameter_Count (Of_Unit, Item)
         loop
            declare
               Slot : constant Landin.IR.Slot_Id :=
                 Landin.IR.Nth_Parameter (Of_Unit, Item, Index);
            begin
               if Landin.IR.Is_Aggregate (Of_Unit, Item, Slot)
                 or else Landin.IR.Is_Array (Of_Unit, Item, Slot)
               then
                  declare
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     if Landin.IR.Is_Aggregate (Of_Unit, Item, Slot) then
                        Landin.Backend.Aggregate_Extent
                          (Of_Unit, Item, Slot, Facts, Bytes, Alignment);
                     else
                        Bytes := Landin.Targets.Byte_Count
                          (Landin.IR.Slot_Array_Length
                             (Of_Unit, Item, Slot))
                          * Landin.Targets.Byte_Count
                              (Landin.Targets.Bytes
                                 (Size_Of
                                    (Landin.IR.Slot_Array_Element
                                       (Of_Unit, Item, Slot), Facts)));
                        Alignment := Landin.Targets.Byte_Alignment'Max
                          (1, Landin.Targets.Byte_Alignment
                                (Landin.Targets.Bytes
                                   (Size_Of
                                      (Landin.IR.Slot_Array_Element
                                         (Of_Unit, Item, Slot), Facts))));
                     end if;
                     Emit ("popq %rsi");
                     Storage_Address
                       ((Kind => Landin.IR.Frame_Slot, Slot => Slot),
                        0, "%rdi");
                     Emit
                       ("movabsq $"
                        & Trimmed
                            (Landin.Targets.Byte_Count'Image (Bytes))
                        & ", %rcx");
                     Emit ("cld");
                     Emit ("rep movsb");
                  end;
               end if;
            end;
         end loop;

         for Index in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            declare
               Block : constant Landin.IR.Block_Id :=
                 Landin.IR.Block_Id (Index);
            begin
               Put (Label (Item, Block) & ":");

               for Position in 1 .. Landin.IR.Length
                                      (Of_Unit, Item, Block)
               loop
                  Emit_Instruction
                    (Landin.IR.Nth_Value
                       (Of_Unit, Item, Block, Position));
               end loop;
            end;
         end loop;

         Put (Character'Val (9) & ".size " & Symbol (Item) & ", .-"
              & Symbol (Item));
      end Emit_Routine;

      --  The value a datum's block describes.  [1460] says nothing runs
      --  before the entry point, so this walk is a fold and not an
      --  interpreter: it reaches the block's own Leave and answers with
      --  what that carries.
      function Folded (Item : Landin.IR.Item_Id) return Landin.Types.Folded;

      --  Each datum is folded once.  [0130] makes a module a set, so one
      --  module value may name another as often as it likes: `b = a + a`
      --  reaches `a` twice, and a chain of those without this would cost
      --  two folds per link and so double with every one of them.  The
      --  state is here for the second reason as well -- a cycle names
      --  nothing at all and [1940] refuses it, so meeting one here is a
      --  defect rather than something to fold.
      type Fold_State is (Unseen, Running, Settled);

      Fold_Of : array (1 .. Landin.IR.Item_Count (Of_Unit))
                  of Landin.Types.Folded := [others => 0];
      Fold_At : array (1 .. Landin.IR.Item_Count (Of_Unit)) of Fold_State :=
        [others => Unseen];

      function Folded (Item : Landin.IR.Item_Id) return Landin.Types.Folded is
         Answer : Landin.Types.Folded := 0;

         --  [0410] fixes the order of a binary's operands, so the lowering
         --  carries the left one through a slot.  A fold therefore reads
         --  slots as well as values, even though nothing here runs.
         Held : array (1 .. Landin.IR.Value_Count (Of_Unit, Item))
                  of Landin.Types.Folded := [others => 0];
         Slots : array (1 .. Landin.IR.Slot_Count (Of_Unit, Item))
                   of Landin.Types.Folded := [others => 0];

         function Bits_Of
           (Value : Landin.IR.Value_Id) return Landin.Targets.Bit_Width;

         function Bits_Of
           (Value : Landin.IR.Value_Id) return Landin.Targets.Bit_Width
         is
            Kind : constant Landin.Types.Scalar_Name :=
              Landin.IR.Result_Of (Of_Unit, Item, Value);
         begin
            return Fold_Width (Kind, Facts);
         end Bits_Of;

         function Signed_At (Value : Landin.IR.Value_Id) return Boolean;

         function Signed_At (Value : Landin.IR.Value_Id) return Boolean is
            Kind : constant Landin.Types.Scalar_Name :=
              Landin.IR.Result_Of (Of_Unit, Item, Value);
         begin
            return Kind in Landin.Types.Integer_Name
                   and then Landin.Types.Is_Signed
                              (Landin.Types.Integer_Name (Kind));
         end Signed_At;

         function Of_Value (Value : Landin.IR.Value_Id)
           return Landin.Types.Folded
           is (Held (Natural (Value)));

         function Operand_Of
           (Value : Landin.IR.Value_Id; Index : Positive)
           return Landin.IR.Value_Id
           is (Landin.IR.Nth_Operand (Of_Unit, Item, Value, Index));
      begin
         --  D177 resolves every module bool through the shared static-image
         --  folder.  In particular, a short-circuit Branch is routine CFG
         --  and never reaches this datum-emission walk.
         if Landin.IR.Has_Bool_Image (Of_Unit, Item) then
            return Landin.IR.Bool_Image (Of_Unit, Item);
         end if;

         case Fold_At (Natural (Item)) is
            when Settled =>
               return Fold_Of (Natural (Item));

            when Running =>
               raise Compiler_Defect
                 with "a module value names itself through a chain the "
                      & "checker was to have refused";

            when Unseen =>
               Fold_At (Natural (Item)) := Running;
         end case;

         for Block in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            for Position in 1 .. Landin.IR.Length
                                   (Of_Unit, Item,
                                    Landin.IR.Block_Id (Block))
            loop
               declare
                  Value : constant Landin.IR.Value_Id :=
                    Landin.IR.Nth_Value
                      (Of_Unit, Item, Landin.IR.Block_Id (Block), Position);
                  Op : constant Landin.IR.Opcode :=
                    Landin.IR.Op_Of (Of_Unit, Item, Value);
               begin
                  case Op is
                     when Landin.IR.Number =>
                        --  [1880]'s minus is carried apart from [1770]'s
                        --  magnitude, and this is where the two meet.
                        Held (Natural (Value)) :=
                          (if Landin.IR.Is_Negated (Of_Unit, Item, Value)
                           then -Landin.Types.Folded
                                   (Landin.IR.Number_Of
                                      (Of_Unit, Item, Value))
                           else Landin.Types.Folded
                                  (Landin.IR.Number_Of
                                     (Of_Unit, Item, Value)));

                     when Landin.IR.Truth =>
                        Held (Natural (Value)) :=
                          (if Landin.IR.Truth_Of (Of_Unit, Item, Value)
                           then 1 else 0);

                     when Landin.IR.Atom =>
                        Held (Natural (Value)) :=
                          Landin.Types.Folded
                            (Atom_Code
                               (Of_Unit,
                                Landin.IR.Atom_Of
                                  (Of_Unit, Item, Value)));

                     --  [0370] in a module value, folded here for the
                     --  same reason the shifts are: it needs a target.
                     when Landin.IR.Measure_Size
                        | Landin.IR.Measure_Align =>
                        declare
                           Size : Landin.Targets.Byte_Count;
                           Alignment : Landin.Targets.Byte_Alignment;
                        begin
                           Measurement_Extent
                             (Of_Unit, Item, Value, Facts, Size, Alignment);
                           Held (Natural (Value)) :=
                             (if Op = Landin.IR.Measure_Size
                              then Landin.Types.Folded (Size)
                              else Landin.Types.Folded (Alignment));
                        end;

                     when Landin.IR.Load_Datum =>
                        --  [0130] makes a module a set, so one module value
                        --  may name another written below it.
                        Held (Natural (Value)) :=
                          Folded
                            (Landin.IR.Datum_Of (Of_Unit, Item, Value));

                     when Landin.IR.Load =>
                        Held (Natural (Value)) :=
                          Slots (Natural
                                   (Landin.IR.Slot_Of
                                      (Of_Unit, Item, Value)));

                     when Landin.IR.Store =>
                        Slots (Natural
                                 (Landin.IR.Slot_Of (Of_Unit, Item, Value)))
                          := Of_Value (Operand_Of (Value, 1));

                     when Landin.IR.Conversion =>
                        declare
                           Source : constant Landin.IR.Value_Id :=
                             Operand_Of (Value, 1);
                           From : constant Landin.Types.Type_Kind :=
                             Landin.IR.Result_Of (Of_Unit, Item, Source);
                           Into_Type : constant Landin.Types.Type_Kind :=
                             Landin.IR.Result_Of (Of_Unit, Item, Value);
                        begin
                           if From in Landin.Types.Float_Name
                             and then Into_Type in Landin.Types.Float_Name
                           then
                              declare
                                 Converted : Landin.Types.Magnitude;
                                 Overflowed : Boolean;
                              begin
                                 Landin.Types.Convert_Float_Width
                                   (Landin.Types.Magnitude
                                      (Of_Value (Source)),
                                    Landin.Types.Float_Name (From),
                                    Landin.Types.Float_Name (Into_Type),
                                    Converted, Overflowed);
                                 if Overflowed then
                                    raise Compiler_Defect with
                                      "an overflowing module float"
                                      & " conversion passed checking";
                                 end if;
                                 Held (Natural (Value)) :=
                                   Landin.Types.Folded (Converted);
                              end;
                           elsif From = Landin.Types.Bool
                             and then Into_Type in Landin.Types.Float_Name
                           then
                              Held (Natural (Value)) :=
                                Landin.Types.Folded
                                  (Landin.Types.Convert_Bool_To_Float
                                     (Of_Value (Source),
                                      Landin.Types.Float_Name (Into_Type)));
                           elsif From in Landin.Types.Integer_Name
                             and then Into_Type in Landin.Types.Float_Name
                           then
                              Held (Natural (Value)) :=
                                Landin.Types.Folded
                                  (Landin.Types.Convert_Integer_To_Float
                                     (Of_Value (Source),
                                      Landin.Types.Float_Name (Into_Type)));
                           elsif From in Landin.Types.Float_Name
                             and then Into_Type in Landin.Types.Integer_Name
                           then
                              declare
                                 Converted : Landin.Types.Folded;
                                 Overflowed : Boolean;
                              begin
                                 Landin.Types.Convert_Float_To_Integer
                                   (Landin.Types.Magnitude
                                      (Of_Value (Source)),
                                    Landin.Types.Float_Name (From),
                                    Landin.Types.Integer_Name (Into_Type),
                                    Facts, Converted, Overflowed);
                                 if Overflowed then
                                    raise Compiler_Defect with
                                      "an overflowing module float-to-"
                                      & "integer conversion passed checking";
                                 end if;
                                 Held (Natural (Value)) := Converted;
                              end;
                           elsif From in Landin.Types.Float_Name
                             and then Into_Type = Landin.Types.Bool
                           then
                              declare
                                 Converted : Landin.Types.Folded;
                                 Overflowed : Boolean;
                              begin
                                 Landin.Types.Convert_Float_To_Bool
                                   (Landin.Types.Magnitude
                                      (Of_Value (Source)),
                                    Landin.Types.Float_Name (From),
                                    Converted, Overflowed);
                                 if Overflowed then
                                    raise Compiler_Defect with
                                      "an impossible module float-to-bool"
                                      & " conversion passed checking";
                                 end if;
                                 Held (Natural (Value)) := Converted;
                              end;
                           else
                              Held (Natural (Value)) := Of_Value (Source);
                           end if;
                        end;

                     when Landin.IR.Negation =>
                        if Landin.IR.Result_Of (Of_Unit, Item, Value)
                             in Landin.Types.Float_Name
                        then
                           Held (Natural (Value)) :=
                             Landin.Types.Folded
                               (Landin.Types.Negated_Float
                                  (Landin.Types.Magnitude
                                     (Of_Value (Operand_Of (Value, 1))),
                                   Landin.Types.Float_Name
                                     (Landin.IR.Result_Of
                                        (Of_Unit, Item, Value))));
                        else
                           Held (Natural (Value)) :=
                             -Of_Value (Operand_Of (Value, 1));
                        end if;

                     when Landin.IR.Logical_Not =>
                        Held (Natural (Value)) :=
                          1 - Of_Value (Operand_Of (Value, 1));

                     when Landin.IR.Complement =>
                        --  A width operation, so it is the one place the
                        --  pattern rather than the number is what is meant.
                        declare
                           Bits : constant Landin.Targets.Bit_Width :=
                             Bits_Of (Value);
                        begin
                           Held (Natural (Value)) :=
                             As_Number
                               (Mask (not To_Pattern
                                            (Of_Value
                                               (Operand_Of (Value, 1)),
                                             Bits),
                                      Bits),
                                Bits, Signed_At (Value));
                        end;

                     when Landin.IR.Add | Landin.IR.Subtract
                        | Landin.IR.Multiply | Landin.IR.Divide
                        | Landin.IR.Remainder
                        | Landin.IR.Wrapping_Add
                        | Landin.IR.Wrapping_Subtract
                        | Landin.IR.Wrapping_Multiply
                        | Landin.IR.Bitwise_And | Landin.IR.Bitwise_Xor
                        | Landin.IR.Bitwise_Or
                        | Landin.IR.Shift_Left | Landin.IR.Shift_Right
                        | Landin.IR.Equal_To | Landin.IR.Not_Equal_To
                        | Landin.IR.Less_Than | Landin.IR.Less_Or_Equal
                        | Landin.IR.Greater_Than
                        | Landin.IR.Greater_Or_Equal =>
                        declare
                           Left_Id : constant Landin.IR.Value_Id :=
                             Operand_Of (Value, 1);
                           A : constant Landin.Types.Folded :=
                             Of_Value (Left_Id);
                           B : constant Landin.Types.Folded :=
                             Of_Value (Operand_Of (Value, 2));

                           --  A comparison gives a bool back, so its own
                           --  width and sign say nothing about the
                           --  operands'.
                           Compares : constant Boolean :=
                             Op in Landin.IR.Equal_To
                                 .. Landin.IR.Greater_Or_Equal;
                           Bits : constant Landin.Targets.Bit_Width :=
                             (if Compares then Bits_Of (Left_Id)
                              else Bits_Of (Value));
                           Signed : constant Boolean :=
                             (if Compares then Signed_At (Left_Id)
                              else Signed_At (Value));

                           Left : constant Pattern := To_Pattern (A, Bits);
                           Right : constant Pattern := To_Pattern (B, Bits);

                           function Truth (Of_It : Boolean)
                             return Landin.Types.Folded
                             is (if Of_It then 1 else 0);

                           --  A width operation's answer, read back as the
                           --  number that pattern stands for.
                           function Narrowed (Bits_Wide : Pattern)
                             return Landin.Types.Folded
                             is (As_Number (Mask (Bits_Wide, Bits),
                                            Bits, Signed));

                           --  [0320] and D13: an amount at or past the
                           --  width gives zero, on every shift.
                           Exhausted : constant Boolean :=
                             Op in Landin.IR.Shift_Left
                                 | Landin.IR.Shift_Right
                             and then B >= Landin.Types.Folded (Bits);
                        begin
                           if Landin.IR.Result_Of
                                (Of_Unit, Item, Left_Id)
                                  in Landin.Types.Float_Name
                           then
                              if Compares then
                                 Held (Natural (Value)) :=
                                   Truth
                                     (Landin.Types.Float_Comparison_Result
                                        (Landin.Types.Magnitude (A),
                                         Landin.Types.Magnitude (B),
                                         Landin.Types.Float_Name
                                           (Landin.IR.Result_Of
                                              (Of_Unit, Item, Left_Id)),
                                         (case Op is
                                             when Landin.IR.Equal_To =>
                                               Landin.Types.Float_Equal,
                                             when Landin.IR.Not_Equal_To =>
                                               Landin.Types.Float_Not_Equal,
                                             when Landin.IR.Less_Than =>
                                               Landin.Types.Float_Less,
                                             when Landin.IR.Less_Or_Equal =>
                                               Landin.Types
                                                 .Float_Less_Or_Equal,
                                             when Landin.IR.Greater_Than =>
                                               Landin.Types.Float_Greater,
                                             when others =>
                                               Landin.Types
                                                 .Float_Greater_Or_Equal)));
                              else
                                 Held (Natural (Value)) :=
                                   Landin.Types.Folded
                                     (Landin.Types.Float_Arithmetic_Result
                                        (Landin.Types.Magnitude (A),
                                         Landin.Types.Magnitude (B),
                                         Landin.Types.Float_Name
                                           (Landin.IR.Result_Of
                                              (Of_Unit, Item, Left_Id)),
                                         (case Op is
                                             when Landin.IR.Add =>
                                               Landin.Types.Float_Add,
                                             when Landin.IR.Subtract =>
                                               Landin.Types.Float_Subtract,
                                             when Landin.IR.Multiply =>
                                               Landin.Types.Float_Multiply,
                                             when others =>
                                               Landin.Types.Float_Divide)));
                              end if;
                           else
                              Held (Natural (Value)) :=
                                (case Op is
                                 --  A checked operator has no width to
                                 --  answer at: [1460] gives a module value
                                 --  no moment in which to trap, so the
                                 --  whole expression is worked out and the
                                 --  checker refuses the answer no type
                                 --  holds.  That is why these do not mask.
                                 when Landin.IR.Add => A + B,
                                 when Landin.IR.Subtract => A - B,
                                 when Landin.IR.Multiply => A * B,
                                 --  Ada's own division truncates toward
                                 --  zero and its remainder takes the
                                 --  dividend's sign, which is [0290].
                                 when Landin.IR.Divide => A / B,
                                 when Landin.IR.Remainder => A rem B,
                                 --  [0300]'s wrapping forms are width
                                 --  operations and say so by name.
                                 when Landin.IR.Wrapping_Add =>
                                   Narrowed (Left + Right),
                                 when Landin.IR.Wrapping_Subtract =>
                                   Narrowed (Left - Right),
                                 when Landin.IR.Wrapping_Multiply =>
                                   Narrowed (Left * Right),
                                 when Landin.IR.Bitwise_And =>
                                   Narrowed (Left and Right),
                                 when Landin.IR.Bitwise_Xor =>
                                   Narrowed (Left xor Right),
                                 when Landin.IR.Bitwise_Or =>
                                   Narrowed (Left or Right),
                                 when Landin.IR.Shift_Left =>
                                   (if Exhausted then 0
                                    else Narrowed
                                           (Left * 2 ** Natural (Right))),
                                 --  A negative arithmetic shift is the
                                 --  complement of the logical shift of the
                                 --  complement, and every complement in
                                 --  that sentence is at this type's width
                                 --  rather than at the pattern's 64.
                                 when Landin.IR.Shift_Right =>
                                   (if Exhausted then 0
                                    elsif Signed and then A < 0
                                    then Narrowed
                                           (not (Mask (not Left, Bits)
                                                 / 2 ** Natural (Right)))
                                    else Narrowed
                                           (Left / 2 ** Natural (Right))),
                                 when Landin.IR.Equal_To => Truth (A = B),
                                 when Landin.IR.Not_Equal_To =>
                                   Truth (A /= B),
                                 when Landin.IR.Less_Than => Truth (A < B),
                                 when Landin.IR.Less_Or_Equal =>
                                   Truth (A <= B),
                                 when Landin.IR.Greater_Than =>
                                   Truth (A > B),
                                    when others => Truth (A >= B));
                           end if;
                        end;

                     when Landin.IR.Leave =>
                        Answer := Of_Value (Operand_Of (Value, 1));

                     when Landin.IR.Failure_Test
                        | Landin.IR.Function_Address
                        | Landin.IR.Evidence_Address
                        | Landin.IR.Evidence_Function | Landin.IR.Call
                        | Landin.IR.Load_Indirect | Landin.IR.Store_Indirect
                        | Landin.IR.Indirect_Call | Landin.IR.Storage_Address
                        | Landin.IR.Place_Address | Landin.IR.Slice_Address
                        | Landin.IR.Empty_Slice_Base
                        | Landin.IR.Pointer_Address
                        | Landin.IR.Store_Datum
                        | Landin.IR.Load_Field | Landin.IR.Store_Field
                        | Landin.IR.Load_Element | Landin.IR.Store_Element
                        | Landin.IR.Copy_Array | Landin.IR.Copy_Variant
                        | Landin.IR.Clear_Array
                        | Landin.IR.Fill_Array
                        | Landin.IR.Load_Variant_Tag
                        | Landin.IR.Load_Variant_Field
                        | Landin.IR.Select_Variant
                        | Landin.IR.Store_Variant_Field
                        | Landin.IR.Jump | Landin.IR.Branch
                        | Landin.IR.Fail =>
                        --  [1940] admits none of these in a module value,
                        --  and [1830] refuses a call there by name.
                        raise Compiler_Defect
                          with "a module value reached the backend holding "
                               & Landin.IR.Opcode'Image (Op);
                  end case;
               end;
            end loop;
         end loop;

         Fold_Of (Natural (Item)) := Answer;
         Fold_At (Natural (Item)) := Settled;
         return Answer;
      end Folded;

      --  How wide a store the assembler is asked for, at each size.
      function Directive (Size : Held_Size) return String
        is (case Size is
               when Landin.Targets.Byte_1 => ".byte",
               when Landin.Targets.Byte_2 => ".word",
               when Landin.Targets.Byte_4 => ".long",
               when Landin.Targets.Byte_8 => ".quad");

      procedure Emit_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Slice_Image_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Aggregate_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Aggregate_Image_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Recursive_Aggregate_Image_Datum
        (Item : Landin.IR.Item_Id);

      function Shape_Contains_Aggregate
        (Shape : Landin.IR.Field_Shape) return Boolean;

      function Item_Image_Contains_Aggregate
        (Item : Landin.IR.Item_Id) return Boolean;

      procedure Emit_Array_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Reserved
        (Item      : Landin.IR.Item_Id;
         Size      : Landin.Targets.Byte_Count;
         Alignment : Landin.Targets.Byte_Alignment);

      --  [0670]'s module state.  The item carries its fields' types and
      --  this works out the same placement the checker did, because it is
      --  Landin.Targets.Placement over the same run against the same
      --  description.  D10 makes the whole of it zero, so the assembler is
      --  asked for that many zero bytes rather than for a value per field.
      procedure Emit_Aggregate_Datum (Item : Landin.IR.Item_Id) is
         Placed  : Landin.Targets.Placement;
         Ignored : Landin.Targets.Byte_Count;
      begin
         Place_Fields (Item, Placed, 0, Ignored);
         Emit_Reserved
           (Item,
            Landin.Targets.Size_Of (Placed),
            Landin.Targets.Alignment_Of (Placed));
      end Emit_Aggregate_Datum;

      function Shape_Contains_Aggregate
        (Shape : Landin.IR.Field_Shape) return Boolean
      is
      begin
         if Shape.Kind = Landin.IR.Aggregate_Field_Shape then
            return True;
         elsif Shape.Kind = Landin.IR.Array_Field_Shape
           and then Landin.IR.Array_Element_Is_Aggregate (Of_Unit, Shape)
         then
            return Shape_Contains_Aggregate
              (Landin.IR.Array_Element_Shape (Of_Unit, Shape));
         elsif Shape.Kind = Landin.IR.Variant_Field_Shape then
            for Variant_Case in 1 .. Shape.Cases loop
               for Payload in
                 1 .. Landin.IR.Variant_Case_Field_Count
                        (Of_Unit, Shape, Variant_Case)
               loop
                  if Shape_Contains_Aggregate
                    (Landin.IR.Nth_Variant_Case_Field
                       (Of_Unit, Shape, Variant_Case, Payload))
                  then
                     return True;
                  end if;
               end loop;
            end loop;
         end if;
         return False;
      end Shape_Contains_Aggregate;

      function Item_Image_Contains_Aggregate
        (Item : Landin.IR.Item_Id) return Boolean
      is
      begin
         for Field in 1 .. Landin.IR.Field_Count (Of_Unit, Item) loop
            if Shape_Contains_Aggregate
              (Landin.IR.Nth_Field_Shape (Of_Unit, Item, Field))
            then
               return True;
            end if;
         end loop;
         return False;
      end Item_Image_Contains_Aggregate;

      --  D132 emits the recursively indexed descriptor tree by replaying
      --  each ordinary-child and selected-payload placement against this
      --  target.  Descriptors carry no byte offsets: every gap and tail below
      --  is derived here and emitted as zero.
      procedure Emit_Recursive_Aggregate_Image_Datum
        (Item : Landin.IR.Item_Id)
      is
         Placed : Landin.Targets.Placement;
         Ignored : Landin.Targets.Byte_Count;
         Written : Landin.Targets.Byte_Count := 0;

         procedure Emit_Zero (Bytes : Landin.Targets.Byte_Count);

         procedure Emit_Field
           (Shape : Landin.IR.Field_Shape;
            Image : Landin.IR.Aggregate_Field_Image;
            Flat  : Landin.Types.Folded;
            Top   : Boolean := False);

         procedure Emit_Children
           (Shape  : Landin.IR.Field_Shape;
            Parent : Landin.IR.Aggregate_Field_Image);

         procedure Emit_Array
           (Shape : Landin.IR.Field_Shape;
            Image : Landin.IR.Aggregate_Field_Image);

         procedure Emit_Variant
           (Shape : Landin.IR.Field_Shape;
            Image : Landin.IR.Aggregate_Field_Image);

         procedure Emit_Zero (Bytes : Landin.Targets.Byte_Count) is
         begin
            if Bytes > 0 then
               Emit
                 (".zero "
                  & Trimmed (Landin.Targets.Byte_Count'Image (Bytes)));
            end if;
         end Emit_Zero;

         procedure Emit_Array
           (Shape : Landin.IR.Field_Shape;
            Image : Landin.IR.Aggregate_Field_Image)
         is
            Field_Size : Landin.Targets.Byte_Count;
            Field_Alignment : Landin.Targets.Byte_Alignment;
         begin
            Landin.Backend.Field_Extent
              (Of_Unit, Shape, Facts, Field_Size, Field_Alignment);
            pragma Unreferenced (Field_Alignment);

            if Image.Slice then
               declare
                  Element_Size : Landin.Targets.Byte_Count;
                  Element_Alignment : Landin.Targets.Byte_Alignment;
               begin
                  Landin.Backend.Field_Extent
                    (Of_Unit, Image.Slice_Element, Facts,
                     Element_Size, Element_Alignment);
                  declare
                     Offset : constant Landin.Targets.Byte_Count :=
                       Landin.Targets.Byte_Count (Image.Slice_First)
                       * Element_Size;
                     Base : constant String :=
                       (if Image.Target = Landin.IR.No_Item
                        then Trimmed
                          (Landin.Targets.Byte_Alignment'Image
                             (Element_Alignment))
                        else Symbol (Image.Target)
                          & (if Offset = 0 then ""
                             else " + " & Trimmed
                               (Landin.Targets.Byte_Count'Image (Offset))));
                  begin
                     Emit (".quad " & Base);
                     Emit
                       (".quad "
                        & Trimmed (Landin.Types.Folded'Image (Image.Value)));
                  end;
               end;
            elsif Landin.IR.Array_Element_Is_Aggregate (Of_Unit, Shape) then
               Emit_Zero (Field_Size);
            elsif Image.Form = Landin.IR.Finite then
               for Position in 1 .. Image.Count loop
                  Emit
                    (Directive (Size_Of (Shape.Element, Facts)) & " "
                     & Trimmed
                         (Landin.Types.Folded'Image
                            (Landin.IR.Nth_Descriptor_Element
                               (Of_Unit, Item, Image,
                                Landin.IR.Part_Position (Position)))));
               end loop;
            elsif Image.Form
                    in Landin.IR.Repeated | Landin.IR.Hybrid
            then
               if Image.Form = Landin.IR.Hybrid then
                  for Position in 1 .. Image.Count loop
                     Emit
                       (Directive (Size_Of (Shape.Element, Facts)) & " "
                        & Trimmed
                            (Landin.Types.Folded'Image
                               (Landin.IR.Nth_Descriptor_Element
                                  (Of_Unit, Item, Image,
                                   Landin.IR.Part_Position (Position)))));
                  end loop;
               end if;
               Emit
                 (".rept "
                  & Trimmed
                      (Landin.IR.Element_Total'Image
                         (Shape.Length
                          - Landin.IR.Element_Total (Image.Count))));
               Emit
                 (Directive (Size_Of (Shape.Element, Facts)) & " "
                  & Trimmed (Landin.Types.Folded'Image (Image.Value)));
               Emit (".endr");
            elsif Image.Form = Landin.IR.Absent then
               Emit_Zero (Field_Size);
            else
               raise Landin.Compiler_Defect with
                 "a malformed recursive array image reached x86-64";
            end if;
         end Emit_Array;

         procedure Emit_Variant
           (Shape : Landin.IR.Field_Shape;
            Image : Landin.IR.Aggregate_Field_Image)
         is
            Field_Size : Landin.Targets.Byte_Count;
            Field_Alignment : Landin.Targets.Byte_Alignment;
         begin
            Landin.Backend.Field_Extent
              (Of_Unit, Shape, Facts, Field_Size, Field_Alignment);
            pragma Unreferenced (Field_Alignment);

            if Image.Form = Landin.IR.Absent then
               Emit_Zero (Field_Size);
               return;
            end if;

            if Image.Form /= Landin.IR.Selected then
               raise Landin.Compiler_Defect with
                 "a malformed recursive variant image reached x86-64";
            end if;

            declare
               Selected : constant Positive := Positive (Image.Value);
               In_Field : Landin.Targets.Byte_Count :=
                 Landin.Targets.Byte_Count
                   (Landin.Targets.Bytes (Size_Of (Shape.Element, Facts)));
            begin
               Emit
                 (Directive (Size_Of (Shape.Element, Facts)) & " "
                  & Trimmed (Natural'Image (Natural (Selected) - 1)));

               for Payload in 1 .. Image.Count loop
                  declare
                     Leaf : constant Landin.IR.Field_Shape :=
                       Landin.IR.Nth_Variant_Case_Field
                         (Of_Unit, Shape, Selected, Payload);
                     Payload_Image : constant
                       Landin.IR.Aggregate_Field_Image :=
                         Landin.IR.Descendant_Image_Of
                           (Of_Unit, Item, Image, Payload);
                     At_Payload : constant Landin.Targets.Byte_Count :=
                       Landin.Backend.Variant_Payload_Field_Offset
                         (Of_Unit, Shape, Selected, Payload, Facts);
                     Payload_Size : Landin.Targets.Byte_Count;
                     Payload_Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Landin.Backend.Field_Extent
                       (Of_Unit, Leaf, Facts, Payload_Size,
                        Payload_Alignment);
                     pragma Unreferenced (Payload_Alignment);
                     if At_Payload > In_Field then
                        Emit_Zero (At_Payload - In_Field);
                     end if;
                     Emit_Field
                       (Leaf, Payload_Image, Payload_Image.Value);
                     In_Field := At_Payload + Payload_Size;
                  end;
               end loop;

               if Field_Size > In_Field then
                  Emit_Zero (Field_Size - In_Field);
               end if;
            end;
         end Emit_Variant;

         procedure Emit_Children
           (Shape  : Landin.IR.Field_Shape;
            Parent : Landin.IR.Aggregate_Field_Image)
         is
            Child_Placement : Landin.Targets.Placement :=
              Landin.Targets.Empty_Placement;
            Child_Written : Landin.Targets.Byte_Count := 0;
            Child_Size : Landin.Targets.Byte_Count;
            Child_Alignment : Landin.Targets.Byte_Alignment;
         begin
            for Child in 1 .. Parent.Count loop
               declare
                  Leaf : constant Landin.IR.Field_Shape :=
                    Landin.IR.Nth_Aggregate_Field
                      (Of_Unit, Shape, Child);
                  Image : constant Landin.IR.Aggregate_Field_Image :=
                    Landin.IR.Descendant_Image_Of
                      (Of_Unit, Item, Parent, Child);
                  At_Child : Landin.Targets.Byte_Count;
               begin
                  Landin.Backend.Field_Extent
                    (Of_Unit, Leaf, Facts, Child_Size, Child_Alignment);
                  Landin.Targets.Place
                    (Child_Placement, Child_Size, Child_Alignment, At_Child);
                  if At_Child > Child_Written then
                     Emit_Zero (At_Child - Child_Written);
                  end if;
                  Emit_Field (Leaf, Image, Image.Value);
                  Child_Written := At_Child + Child_Size;
               end;
            end loop;

            if Landin.Targets.Size_Of (Child_Placement) > Child_Written then
               Emit_Zero
                 (Landin.Targets.Size_Of (Child_Placement) - Child_Written);
            end if;
         end Emit_Children;

         procedure Emit_Field
           (Shape : Landin.IR.Field_Shape;
            Image : Landin.IR.Aggregate_Field_Image;
            Flat  : Landin.Types.Folded;
            Top   : Boolean := False)
         is
            Field_Size : Landin.Targets.Byte_Count;
            Field_Alignment : Landin.Targets.Byte_Alignment;
         begin
            case Shape.Kind is
               when Landin.IR.Scalar_Field_Shape =>
                  Emit
                    (Directive (Size_Of (Shape.Element, Facts)) & " "
                     & (if Image.Target /= Landin.IR.No_Item
                        then Symbol (Image.Target)
                        else Trimmed
                          (Landin.Types.Folded'Image
                             ((if Top then Flat else Image.Value)))));

               when Landin.IR.Array_Field_Shape =>
                  Emit_Array (Shape, Image);

               when Landin.IR.Aggregate_Field_Shape =>
                  if Image.Form = Landin.IR.Absent then
                     Landin.Backend.Field_Extent
                       (Of_Unit, Shape, Facts, Field_Size,
                        Field_Alignment);
                     Emit_Zero (Field_Size);
                  elsif Image.Form = Landin.IR.Nested then
                     Emit_Children (Shape, Image);
                  else
                     raise Landin.Compiler_Defect with
                       "a malformed nested image reached x86-64";
                  end if;

               when Landin.IR.Variant_Field_Shape =>
                  Emit_Variant (Shape, Image);
            end case;
         end Emit_Field;
      begin
         Place_Fields (Item, Placed, 0, Ignored);

         if Is_Public_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;
         Put (Character'Val (9) & ".type " & Symbol (Item) & ", @object");
         Put
           (Character'Val (9) & ".align "
            & Trimmed
                (Landin.Targets.Byte_Alignment'Image
                   (Landin.Targets.Alignment_Of (Placed))));
         Put (Symbol (Item) & ":");

         for Field in 1 .. Landin.IR.Field_Count (Of_Unit, Item) loop
            declare
               Shape : constant Landin.IR.Field_Shape :=
                 Landin.IR.Nth_Field_Shape (Of_Unit, Item, Field);
               Image : constant Landin.IR.Aggregate_Field_Image :=
                 Landin.IR.Field_Image_Of (Of_Unit, Item, Field);
               Field_Size : Landin.Targets.Byte_Count;
               Field_Alignment : Landin.Targets.Byte_Alignment;
               At_Field : Landin.Targets.Byte_Count;
               Field_Placement : Landin.Targets.Placement;
            begin
               Place_Fields
                 (Item, Field_Placement,
                  Landin.IR.Element_Total (Field), At_Field);
               Landin.Backend.Field_Extent
                 (Of_Unit, Shape, Facts, Field_Size, Field_Alignment);
               pragma Unreferenced (Field_Placement, Field_Alignment);
               if At_Field > Written then
                  Emit_Zero (At_Field - Written);
               end if;
               Emit_Field
                 (Shape, Image,
                  Landin.IR.Nth_Field_Image (Of_Unit, Item, Field),
                  Top => True);
               Written := At_Field + Field_Size;
            end;
         end loop;

         if Landin.Targets.Size_Of (Placed) > Written then
            Emit_Zero (Landin.Targets.Size_Of (Placed) - Written);
         end if;
         Put
           (Character'Val (9) & ".size " & Symbol (Item) & ", "
            & Trimmed
                (Landin.Targets.Byte_Count'Image
                   (Landin.Targets.Size_Of (Placed))));
      end Emit_Recursive_Aggregate_Image_Datum;

      --  D66 keeps the written aggregate image target-neutral: one fold per
      --  declaration-order field.  Replay the shared placement here to insert
      --  this target's padding, write scalar fields at their target widths,
      --  reserve zero array fields at their compact extents, and keep every
      --  padding byte zero as [0540] requires.
      procedure Emit_Aggregate_Image_Datum (Item : Landin.IR.Item_Id) is
         Placed  : Landin.Targets.Placement;
         Ignored : Landin.Targets.Byte_Count;
         Written : Landin.Targets.Byte_Count := 0;
      begin
         if Item_Image_Contains_Aggregate (Item) then
            Emit_Recursive_Aggregate_Image_Datum (Item);
            return;
         end if;

         Place_Fields (Item, Placed, 0, Ignored);

         if Is_Public_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;

         Put (Character'Val (9) & ".type " & Symbol (Item) & ", @object");
         Put (Character'Val (9) & ".align "
              & Trimmed
                  (Landin.Targets.Byte_Alignment'Image
                     (Landin.Targets.Alignment_Of (Placed))));
         Put (Symbol (Item) & ":");

         for Field in 1 .. Landin.IR.Field_Count (Of_Unit, Item) loop
            declare
               Shape : constant Landin.IR.Field_Shape :=
                 Landin.IR.Nth_Field_Shape (Of_Unit, Item, Field);
               Image : constant Landin.IR.Aggregate_Field_Image :=
                 Landin.IR.Field_Image_Of (Of_Unit, Item, Field);
               Field_Size : Landin.Targets.Byte_Count;
               Field_Alignment : Landin.Targets.Byte_Alignment;
               At_Field : Landin.Targets.Byte_Count;
               Field_Placement : Landin.Targets.Placement;
            begin
               Place_Fields
                 (Item, Field_Placement, Landin.IR.Element_Total (Field),
                  At_Field);
               Landin.Backend.Field_Extent
                 (Of_Unit, Shape, Facts, Field_Size, Field_Alignment);
               pragma Unreferenced (Field_Placement, Field_Alignment);

               if At_Field > Written then
                  Emit
                    (".zero "
                     & Trimmed
                         (Landin.Targets.Byte_Count'Image
                            (At_Field - Written)));
               end if;

               if Shape.Kind = Landin.IR.Variant_Field_Shape
                 and then Image.Form = Landin.IR.Selected
               then
                  declare
                     Selected : constant Positive := Positive (Image.Value);
                     In_Field : Landin.Targets.Byte_Count :=
                       Landin.Targets.Byte_Count
                         (Landin.Targets.Bytes
                            (Size_Of (Shape.Element, Facts)));
                  begin
                     Emit
                       (Directive (Size_Of (Shape.Element, Facts)) & " "
                        & Trimmed
                            (Natural'Image (Natural (Selected) - 1)));

                     for Payload in 1 .. Image.Count loop
                        declare
                           Leaf : constant Landin.IR.Field_Shape :=
                             Landin.IR.Nth_Variant_Case_Field
                               (Of_Unit, Shape, Selected, Payload);
                           Payload_Image : constant
                             Landin.IR.Aggregate_Field_Image :=
                               Landin.IR.Variant_Payload_Image_Of
                                 (Of_Unit, Item, Field, Payload);
                           At_Payload : constant
                             Landin.Targets.Byte_Count :=
                               Landin.Backend.Variant_Payload_Field_Offset
                                 (Of_Unit, Shape, Selected, Payload, Facts);
                           Payload_Size : Landin.Targets.Byte_Count;
                           Payload_Alignment :
                             Landin.Targets.Byte_Alignment;
                        begin
                           Landin.Backend.Field_Extent
                             (Of_Unit, Leaf, Facts, Payload_Size,
                              Payload_Alignment);
                           pragma Unreferenced (Payload_Alignment);

                           if At_Payload > In_Field then
                              Emit
                                (".zero "
                                 & Trimmed
                                     (Landin.Targets.Byte_Count'Image
                                        (At_Payload - In_Field)));
                           end if;

                           if Leaf.Kind =
                                Landin.IR.Scalar_Field_Shape
                           then
                              Emit
                                (Directive
                                   (Size_Of (Leaf.Element, Facts))
                                 & " "
                                 & (if Payload_Image.Target /=
                                         Landin.IR.No_Item
                                    then Symbol (Payload_Image.Target)
                                    else Trimmed
                                      (Landin.Types.Folded'Image
                                         (Payload_Image.Value))));
                           elsif Payload_Image.Form = Landin.IR.Finite then
                              for Position in 1 .. Payload_Image.Count loop
                                 Emit
                                   (Directive
                                      (Size_Of (Leaf.Element, Facts))
                                    & " "
                                    & Trimmed
                                        (Landin.Types.Folded'Image
                                           (Landin.IR
                                              .Nth_Variant_Field_Element
                                                (Of_Unit, Item, Field,
                                                 Payload,
                                                 Landin.IR.Part_Position
                                                   (Position)))));
                              end loop;
                           elsif Payload_Image.Form
                                   in Landin.IR.Repeated | Landin.IR.Hybrid
                           then
                              if Payload_Image.Form = Landin.IR.Hybrid then
                                 for Position in
                                   1 .. Payload_Image.Count
                                 loop
                                    Emit
                                      (Directive
                                         (Size_Of (Leaf.Element, Facts))
                                       & " "
                                       & Trimmed
                                           (Landin.Types.Folded'Image
                                              (Landin.IR
                                                 .Nth_Variant_Field_Element
                                                   (Of_Unit, Item, Field,
                                                    Payload,
                                                    Landin.IR.Part_Position
                                                      (Position)))));
                                 end loop;
                              end if;
                              Emit
                                (".rept "
                                 & Trimmed
                                     (Landin.IR.Element_Total'Image
                                        (Leaf.Length
                                         - Landin.IR.Element_Total
                                             (Payload_Image.Count))));
                              Emit
                                (Directive (Size_Of (Leaf.Element, Facts))
                                 & " "
                                 & Trimmed
                                     (Landin.Types.Folded'Image
                                        (Payload_Image.Value)));
                              Emit (".endr");
                           elsif Payload_Image.Form = Landin.IR.Absent then
                              if Payload_Size > 0 then
                                 Emit
                                   (".zero "
                                    & Trimmed
                                        (Landin.Targets.Byte_Count'Image
                                           (Payload_Size)));
                              end if;
                           else
                              raise Landin.Compiler_Defect with
                                "a nested selected variant image reached"
                                & " x86-64";
                           end if;

                           In_Field := At_Payload + Payload_Size;
                        end;
                     end loop;

                     if Field_Size > In_Field then
                        Emit
                          (".zero "
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image
                                  (Field_Size - In_Field)));
                     end if;
                  end;
               elsif Shape.Kind = Landin.IR.Variant_Field_Shape
                 and then Image.Form = Landin.IR.Absent
               then
                  if Field_Size > 0 then
                     Emit
                       (".zero "
                        & Trimmed
                            (Landin.Targets.Byte_Count'Image (Field_Size)));
                  end if;
               elsif Shape.Kind = Landin.IR.Scalar_Field_Shape then
                  Emit
                    (Directive (Size_Of (Shape.Element, Facts)) & " "
                     & (if Image.Target /= Landin.IR.No_Item
                        then Symbol (Image.Target)
                        else Trimmed
                          (Landin.Types.Folded'Image
                             (Landin.IR.Nth_Field_Image
                                (Of_Unit, Item, Field)))));
               elsif Image.Slice then
                  declare
                     Element_Size : Landin.Targets.Byte_Count;
                     Element_Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Landin.Backend.Field_Extent
                       (Of_Unit, Image.Slice_Element, Facts,
                        Element_Size, Element_Alignment);
                     declare
                        Offset : constant Landin.Targets.Byte_Count :=
                          Landin.Targets.Byte_Count (Image.Slice_First)
                          * Element_Size;
                        Base : constant String :=
                          (if Image.Target = Landin.IR.No_Item
                           then Trimmed
                             (Landin.Targets.Byte_Alignment'Image
                                (Element_Alignment))
                           else Symbol (Image.Target)
                             & (if Offset = 0 then ""
                                else " + " & Trimmed
                                  (Landin.Targets.Byte_Count'Image (Offset))));
                     begin
                        Emit (".quad " & Base);
                        Emit
                          (".quad "
                           & Trimmed
                               (Landin.Types.Folded'Image (Image.Value)));
                     end;
                  end;
               elsif Image.Form = Landin.IR.Finite then
                  for Position in 1 .. Image.Count loop
                     Emit
                       (Directive (Size_Of (Shape.Element, Facts)) & " "
                        & Trimmed
                            (Landin.Types.Folded'Image
                               (Landin.IR.Nth_Field_Element
                                  (Of_Unit, Item, Field,
                                   Landin.IR.Part_Position (Position)))));
                  end loop;
               elsif Image.Form in Landin.IR.Repeated | Landin.IR.Hybrid
               then
                  if Image.Form = Landin.IR.Hybrid then
                     for Position in 1 .. Image.Count loop
                        Emit
                          (Directive (Size_Of (Shape.Element, Facts)) & " "
                           & Trimmed
                               (Landin.Types.Folded'Image
                                  (Landin.IR.Nth_Field_Element
                                     (Of_Unit, Item, Field,
                                      Landin.IR.Part_Position (Position)))));
                     end loop;
                  end if;
                  Emit
                    (".rept "
                     & Trimmed
                         (Landin.IR.Element_Total'Image
                            (Shape.Length
                             - Landin.IR.Element_Total (Image.Count))));
                  Emit
                    (Directive (Size_Of (Shape.Element, Facts)) & " "
                     & Trimmed
                         (Landin.Types.Folded'Image (Image.Value)));
                  Emit (".endr");
               elsif Image.Form = Landin.IR.Absent then
                  if Field_Size > 0 then
                     Emit
                       (".zero "
                        & Trimmed
                            (Landin.Targets.Byte_Count'Image (Field_Size)));
                  end if;
               else
                  raise Landin.Compiler_Defect with
                    "an aggregate array-field image form reached x86-64"
                    & " before its backend rule";
               end if;

               Written := At_Field + Field_Size;
            end;
         end loop;

         if Landin.Targets.Size_Of (Placed) > Written then
            Emit
              (".zero "
               & Trimmed
                   (Landin.Targets.Byte_Count'Image
                      (Landin.Targets.Size_Of (Placed) - Written)));
         end if;

         Put (Character'Val (9) & ".size " & Symbol (Item) & ", "
              & Trimmed
                  (Landin.Targets.Byte_Count'Image
                     (Landin.Targets.Size_Of (Placed))));
      end Emit_Aggregate_Image_Datum;

      --  Whether a module value has an absent zero image, and so is storage
      --  to reserve rather than bytes to carry.  D66 gives an aggregate its
      --  first written image; omitted and whole-`zeroed` aggregates still
      --  have none.  An
      --  array datum is zero when it has no image at all.  A D24 literal image
      --  that happens to be every-position-zero is written as `.data` anyway;
      --  D34 deliberately represents a repeated zero pattern as no image, so
      --  that form remains storage the loader zeroes in this section.
      function Is_All_Zero (Item : Landin.IR.Item_Id) return Boolean;

      function Is_All_Zero (Item : Landin.IR.Item_Id) return Boolean is
      begin
         if Landin.IR.Signature_Of (Of_Unit, Item)
              /= Landin.IR.No_Signature
           or else Landin.IR.Address_Target (Of_Unit, Item)
             /= Landin.IR.No_Item
         then
            return False;
         end if;

         if Landin.IR.Result_Of (Of_Unit, Item) = Landin.Types.Aggregate then
            return not Landin.IR.Has_Image (Of_Unit, Item);
         end if;

         if Landin.IR.Result_Of (Of_Unit, Item)
            = Landin.Types.Fixed_Array
         then
            return not Landin.IR.Has_Image (Of_Unit, Item);
         end if;

         return Folded (Item) = 0;
      end Is_All_Zero;

      --  Reserved and not written: `.zero` in a section the assembler
      --  marks NOBITS costs no bytes in the object or the image, while
      --  the same directive in `.data` costs every one of them.
      procedure Emit_Reserved
        (Item      : Landin.IR.Item_Id;
         Size      : Landin.Targets.Byte_Count;
         Alignment : Landin.Targets.Byte_Alignment)
      is
         Bytes : constant String :=
           Trimmed (Landin.Targets.Byte_Count'Image (Size));
      begin
         if Is_Public_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;

         Put (Character'Val (9) & ".type " & Symbol (Item) & ", @object");
         Put (Character'Val (9) & ".align "
              & Trimmed (Landin.Targets.Byte_Alignment'Image (Alignment)));
         Put (Symbol (Item) & ":");
         Emit (".zero " & Bytes);
         Put (Character'Val (9) & ".size " & Symbol (Item) & ", " & Bytes);
      end Emit_Reserved;

      --  [0520]'s array: the element repeated, so its extent is one
      --  multiplication and its alignment is the element's own.  A length
      --  of zero takes no room and aligns to a byte, having no element to
      --  be aligned as.
      procedure Emit_Array_Datum (Item : Landin.IR.Item_Id) is
         Length : constant Landin.IR.Element_Total :=
           Landin.IR.Array_Length (Of_Unit, Item);
         --  D121: the element may be an ordinary struct, whose extent and
         --  alignment are its own padded layout.
         Size : Landin.Targets.Byte_Count;
         Alignment : Landin.Targets.Byte_Alignment;
      begin
         Landin.Backend.Field_Extent
           (Of_Unit, Landin.IR.Array_Element_Shape (Of_Unit, Item),
            Facts, Size, Alignment);
         Emit_Reserved
           (Item,
            Landin.Targets.Byte_Count (Length) * Size,
            (if Length = 0 then 1 else Alignment));
      end Emit_Array_Datum;

      --  D24/D34: an array datum with an image.  Each literal element becomes
      --  one directive of its own size; a repetition becomes one directive
      --  inside `.rept`.  Nonzero or mixed images reach `.data`, while
      --  omitted, explicit-zero and repeated-zero images stay in `.bss`.  A
      --  negative fold is written as the number
      --  the assembler encodes at this width -- the same spelling
      --  Emit_Datum already uses.
      procedure Emit_Array_Image_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Array_Image_Datum (Item : Landin.IR.Item_Id) is
         Length : constant Landin.IR.Element_Total :=
           Landin.IR.Array_Length (Of_Unit, Item);
         Element : constant Landin.Types.Scalar_Name :=
           Landin.IR.Array_Element (Of_Unit, Item);
         Held : constant Held_Size := Size_Of (Element, Facts);
         Bytes : constant String :=
           Trimmed
             (Landin.Targets.Byte_Count'Image
                (Landin.Targets.Byte_Count (Length)
                 * Landin.Targets.Byte_Count (Landin.Targets.Bytes (Held))));
      begin
         if Is_Public_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;

         Put (Character'Val (9) & ".type " & Symbol (Item) & ", @object");
         Put (Character'Val (9) & ".align "
              & Trimmed
                  (Landin.Targets.Byte_Alignment'Image
                     (Landin.Targets.Alignment_Of (Facts, Held))));
         Put (Symbol (Item) & ":");

         if Landin.IR.Is_Repeated_Image (Of_Unit, Item) then
            --  D34 uses `.rept` around one width-specific scalar directive.
            --  D38 writes its finite prefix first, then repeats one suffix
            --  value for N - k positions.  Assembly size therefore depends on
            --  the written prefix, never the target-sized extent; `.quad`
            --  preserves all eight bytes unlike GNU `.fill`.
            declare
               Prefix : constant Landin.IR.Element_Total :=
                 Landin.IR.Image_Prefix_Length (Of_Unit, Item);
            begin
               if Prefix > 0 then
                  for Position in Landin.IR.Part_Position'(1)
                                  .. Landin.IR.Part_Position (Prefix)
                  loop
                     Emit
                       (Directive (Held) & " "
                        & Trimmed
                            (Landin.Types.Folded'Image
                               (Landin.IR.Nth_Image
                                  (Of_Unit, Item, Position))));
                  end loop;
               end if;
               Emit
                 (".rept "
                  & Trimmed
                      (Landin.IR.Element_Total'Image (Length - Prefix)));
               Emit
                 (Directive (Held) & " "
                  & Trimmed
                      (Landin.Types.Folded'Image
                         (Landin.IR.Repeated_Image_Value (Of_Unit, Item))));
               Emit (".endr");
            end;
         else
            for Position in Landin.IR.Part_Position'(1)
                            .. Landin.IR.Part_Position (Length)
            loop
               Emit
                 (Directive (Held) & " "
                  & Trimmed
                      (Landin.Types.Folded'Image
                         (Landin.IR.Nth_Image
                            (Of_Unit, Item, Position))));
            end loop;
         end if;

         Put (Character'Val (9) & ".size " & Symbol (Item) & ", " & Bytes);
      end Emit_Array_Image_Datum;

      procedure Emit_Slice_Image_Datum (Item : Landin.IR.Item_Id) is
         Source : constant Landin.IR.Item_Id :=
           Landin.IR.Slice_Image_Source (Of_Unit, Item);
         Element : constant Landin.IR.Field_Shape :=
           Landin.IR.Slice_Image_Element (Of_Unit, Item);
         Element_Size : Landin.Targets.Byte_Count;
         Alignment : Landin.Targets.Byte_Alignment;
      begin
         Landin.Backend.Field_Extent
           (Of_Unit, Element, Facts, Element_Size, Alignment);
         if Is_Public_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;
         Put (Character'Val (9) & ".type " & Symbol (Item) & ", @object");
         Put (Character'Val (9) & ".align 8");
         Put (Symbol (Item) & ":");
         declare
            Offset : constant Landin.Targets.Byte_Count :=
              Landin.Targets.Byte_Count
                (Landin.IR.Slice_Image_First (Of_Unit, Item))
              * Element_Size;
            Base : constant String :=
              (if Source = Landin.IR.No_Item
               then Trimmed
                 (Landin.Targets.Byte_Alignment'Image (Alignment))
               else Symbol (Source)
                 & (if Offset = 0 then ""
                    else " + " & Trimmed
                      (Landin.Targets.Byte_Count'Image (Offset))));
         begin
            Emit (".quad " & Base);
         end;
         Emit
           (".quad "
            & Trimmed
                (Landin.IR.Element_Total'Image
                   (Landin.IR.Slice_Image_Length (Of_Unit, Item))));
         Put (Character'Val (9) & ".size " & Symbol (Item) & ", 16");
      end Emit_Slice_Image_Datum;

      procedure Emit_Datum (Item : Landin.IR.Item_Id) is
         Kind : constant Landin.Types.Scalar_Name :=
           Landin.IR.Result_Of (Of_Unit, Item);
         Held : constant Held_Size := Size_Of (Kind, Facts);
         --  A function datum is a static relocation to its verified routine
         --  target; D181's cstring datum similarly relocates to read-only
         --  bytes.  Every other scalar is the folded number the assembler
         --  encodes at this width.
         Written : constant String :=
           (if Landin.IR.Signature_Of (Of_Unit, Item)
                 /= Landin.IR.No_Signature
            then Symbol (Landin.IR.Function_Target (Of_Unit, Item))
            elsif Landin.IR.Address_Target (Of_Unit, Item)
                    /= Landin.IR.No_Item
            then Symbol (Landin.IR.Address_Target (Of_Unit, Item))
            else Trimmed (Landin.Types.Folded'Image (Folded (Item))));
         Bytes : constant String :=
           Trimmed (Positive'Image (Landin.Targets.Bytes (Held)));
      begin
         if Is_Public_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;

         Put (Character'Val (9) & ".type " & Symbol (Item) & ", @object");
         Put (Character'Val (9) & ".align "
              & Trimmed
                  (Landin.Targets.Byte_Alignment'Image
                     (Landin.Targets.Alignment_Of (Facts, Held))));
         Put (Symbol (Item) & ":");
         Emit (Directive (Held) & " " & Written);
         Put (Character'Val (9) & ".size " & Symbol (Item) & ", " & Bytes);
      end Emit_Datum;

      Any_Written  : Boolean := False;
      Any_Reserved : Boolean := False;
      Any_Read_Only : Boolean := False;

   begin
      Put (Character'Val (9) & ".text");

      for Right in 2 .. Landin.IR.Item_Count (Of_Unit) loop
         if Landin.IR.Kind_Of
           (Of_Unit, Landin.IR.Item_Id (Right)) = Landin.IR.Routine
           and then not Landin.IR.Is_External
             (Of_Unit, Landin.IR.Item_Id (Right))
         then
            for Left in 1 .. Right - 1 loop
               if Landin.IR.Kind_Of
                 (Of_Unit, Landin.IR.Item_Id (Left)) = Landin.IR.Routine
                 and then not Landin.IR.Is_External
                   (Of_Unit, Landin.IR.Item_Id (Left))
                 and then Routines_Can_Share
                   (Landin.IR.Item_Id (Left), Landin.IR.Item_Id (Right))
               then
                  Shared_With (Right) := Landin.IR.Item_Id (Left);
                  exit;
               end if;
            end loop;
         end if;
      end loop;

      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine then
               if Landin.IR.Is_External (Of_Unit, Item) then
                  null;
               elsif Shared_With (Index) = Landin.IR.No_Item then
                  Emit_Routine (Item);
               else
                  Emit
                    (".set " & Symbol (Item) & ", "
                     & Symbol (Shared_With (Index)));
               end if;
            elsif Landin.IR.Is_Read_Only (Of_Unit, Item) then
               Any_Read_Only := True;
            elsif Is_All_Zero (Item) then
               Any_Reserved := True;
            else
               Any_Written := True;
            end if;
         end;
      end loop;

      --  D161: read-only images sit in `.rodata`, so a write through a
      --  reference the checker should have refused faults instead of
      --  silently changing every reader's literal.
      if Any_Read_Only then
         Put (Character'Val (9) & ".section .rodata");

         for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id :=
                 Landin.IR.Item_Id (Index);
            begin
               if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Datum
                 and then Landin.IR.Is_Read_Only (Of_Unit, Item)
               then
                  Emit_Array_Image_Datum (Item);
               end if;
            end;
         end loop;
      end if;

      if Landin.IR.Evidence_Count (Of_Unit) > 0 then
         Put (Character'Val (9) & ".section .data.rel.ro.local,""aw""");
         for Position in 1 .. Landin.IR.Evidence_Count (Of_Unit) loop
            declare
               Evidence : constant Landin.IR.Evidence_Id :=
                 Landin.IR.Evidence_Id (Position);
               Size : Landin.Targets.Byte_Count;
               Alignment : Landin.Targets.Byte_Alignment;
            begin
               Landin.Backend.Field_Extent
                 (Of_Unit, Landin.IR.Evidence_Represented
                    (Of_Unit, Evidence), Facts, Size, Alignment);
               Emit
                 (".balign "
                  & Trimmed
                      (Landin.Targets.Byte_Alignment'Image
                         (Landin.Targets.Pointer_Alignment (Facts))));
               Put (Evidence_Symbol (Evidence) & ":");
               Emit
                 (".quad "
                  & Trimmed (Landin.Targets.Byte_Count'Image (Size)));
               Emit
                 (".quad "
                  & Trimmed
                      (Landin.Targets.Byte_Alignment'Image (Alignment)));
               for Which in 1 .. Landin.IR.Evidence_Entry_Count
                 (Of_Unit, Evidence)
               loop
                  Emit
                    (".quad "
                     & Symbol
                         (Landin.IR.Evidence_Entry_Target
                            (Of_Unit, Evidence, Which)));
               end loop;
            end;
         end loop;
      end if;

      --  Data follows every routine rather than interrupting them, and each
      --  section is one run, so each directive is written once however many
      --  objects it holds.  Written first and reserved second, in the order
      --  the declarations were made inside each.
      if Any_Written then
         Put (Character'Val (9) & ".data");

         for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id :=
                 Landin.IR.Item_Id (Index);
            begin
               if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Datum
                 and then not Landin.IR.Is_Read_Only (Of_Unit, Item)
                 and then not Is_All_Zero (Item)
               then
                  if Landin.IR.Result_Of (Of_Unit, Item)
                     = Landin.Types.Aggregate
                  then
                     Emit_Aggregate_Image_Datum (Item);
                  elsif Landin.IR.Has_Slice_Image (Of_Unit, Item) then
                     Emit_Slice_Image_Datum (Item);
                  elsif Landin.IR.Result_Of (Of_Unit, Item)
                        = Landin.Types.Fixed_Array
                  then
                     Emit_Array_Image_Datum (Item);
                  else
                     Emit_Datum (Item);
                  end if;
               end if;
            end;
         end loop;
      end if;

      if Any_Reserved then
         Put (Character'Val (9) & ".bss");

         for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id :=
                 Landin.IR.Item_Id (Index);
            begin
               if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Datum
                 and then not Landin.IR.Is_Read_Only (Of_Unit, Item)
                 and then Is_All_Zero (Item)
               then
                  if Landin.IR.Result_Of (Of_Unit, Item)
                     = Landin.Types.Aggregate
                  then
                     Emit_Aggregate_Datum (Item);
                  elsif Landin.IR.Result_Of (Of_Unit, Item)
                        = Landin.Types.Fixed_Array
                  then
                     Emit_Array_Datum (Item);
                  else
                     Emit_Reserved
                       (Item,
                        Landin.Targets.Byte_Count
                          (Landin.Targets.Bytes
                             (Size_Of
                                (Landin.IR.Result_Of (Of_Unit, Item),
                                 Facts))),
                        Landin.Targets.Alignment_Of
                          (Facts,
                           Size_Of
                             (Landin.IR.Result_Of (Of_Unit, Item),
                              Facts)));
                  end if;
               end if;
            end;
         end loop;
      end if;

      if Hosted_Entry /= Landin.IR.No_Item then
         Put (Character'Val (9) & ".text");
         Put (Character'Val (9)
              & ".type _landin_host_argument_count, @function");
         Put ("_landin_host_argument_count:");
         Emit ("movl .Llandin_host_argc(%rip), %eax");
         Emit ("subl $1, %eax");
         Emit ("jns .Llandin_host_count_ready");
         Emit ("xorl %eax, %eax");
         Put (".Llandin_host_count_ready:");
         Emit ("ret");
         Put (Character'Val (9)
              & ".size _landin_host_argument_count, "
              & ".-_landin_host_argument_count");

         Put (Character'Val (9)
              & ".type _landin_host_argument_at, @function");
         Put ("_landin_host_argument_at:");
         Emit ("movq .Llandin_host_argv(%rip), %rax");
         Emit ("movq 8(%rax,%rdi,8), %rax");
         Emit ("ret");
         Put (Character'Val (9)
              & ".size _landin_host_argument_at, "
              & ".-_landin_host_argument_at");

         Put (Character'Val (9)
              & ".type _landin_host_text_length, @function");
         Put ("_landin_host_text_length:");
         Emit ("jmp strlen");
         Put (Character'Val (9)
              & ".size _landin_host_text_length, "
              & ".-_landin_host_text_length");

         Put (Character'Val (9)
              & ".type _landin_host_open_read, @function");
         Put ("_landin_host_open_read:");
         Emit ("xorl %esi, %esi");
         Emit ("xorl %eax, %eax");
         Emit ("jmp open");
         Put (Character'Val (9)
              & ".size _landin_host_open_read, "
              & ".-_landin_host_open_read");

         Put (Character'Val (9) & ".type _landin_host_read, @function");
         Put ("_landin_host_read:");
         Emit ("jmp read");
         Put (Character'Val (9)
              & ".size _landin_host_read, .-_landin_host_read");

         Put (Character'Val (9) & ".type _landin_host_write, @function");
         Put ("_landin_host_write:");
         Emit ("jmp write");
         Put (Character'Val (9)
              & ".size _landin_host_write, .-_landin_host_write");

         Put (Character'Val (9) & ".type _landin_host_close, @function");
         Put ("_landin_host_close:");
         Emit ("jmp close");
         Put (Character'Val (9)
              & ".size _landin_host_close, .-_landin_host_close");

         Put (Character'Val (9) & ".type _landin_host_errno, @function");
         Put ("_landin_host_errno:");
         Emit ("subq $8, %rsp");
         Emit ("call __errno_location");
         Emit ("movl (%rax), %eax");
         Emit ("addq $8, %rsp");
         Emit ("ret");
         Put (Character'Val (9)
              & ".size _landin_host_errno, .-_landin_host_errno");

         --  Keep the two entry cells in the small initialized data section.
         --  A program may own a multi-gigabyte zero-image datum in .bss;
         --  placing these cells after that section would put RIP-relative
         --  entry accesses outside x86-64's signed displacement.
         Put (Character'Val (9) & ".data");
         Put (Character'Val (9) & ".balign 8");
         Put (".Llandin_host_argv:");
         Emit (".zero 8");
         Put (Character'Val (9) & ".balign 4");
         Put (".Llandin_host_argc:");
         Emit (".zero 4");
      end if;

      --  An executable stack is inherited when nothing says otherwise,
      --  and nothing this compiler emits needs one.
      Put (Character'Val (9)
           & ".section .note.GNU-stack,"""",@progbits");
      return Unbounded.To_String (Out_Text);
   end Text;

end Landin.Backend.X86_64;
