with Ada.Containers.Vectors;
with Landin.Provenance;
with Landin.Layouts;
with Landin.Packed;
with Landin.Memory;
with Landin.Targets.Packed;
with Landin.Backend.Dwarf;
with Ada.Strings.Fixed;
with Landin.Hosted;
with Landin.Targets.Capabilities;
with Landin.Backend.Darwin_ABI;
with Landin.Backend.Work_Arrays;
with Landin.Types;

package body Landin.Backend.Arm64 is

   package Unbounded renames Ada.Strings.Unbounded;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Targets.Bit_Width;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.Scalar_Size;
   use type Landin.IR.Atom_Set_Id;
   use type Landin.IR.Declaration_Id;
   use type Landin.IR.Item_Kind;
   use type Landin.IR.Item_Id;
   use type Landin.IR.Value_Id;
   use type Landin.IR.Opcode;
   use type Landin.IR.Parameter_Convention;
   use type Landin.IR.Signature_Id;
   use type Landin.IR.Slot_Id;
   use type Landin.IR.Element_Total;
   use type Landin.IR.Field_Image_Form;
   use type Landin.IR.Field_Shape_Kind;
   use type Landin.Types.Folded;
   use type Landin.Types.Type_Kind;

   use type Landin.Targets.Target_Facts;
   use type Landin.Layouts.Policy;
   use type Landin.Targets.C_ABI_Kind;

   LF : constant Character := Character'Val (10);

   --  `Image` leads with a blank for a non-negative number and assembly
   --  is bytes, so the blank is a byte.  Landin.IR.Dump's trim, for the
   --  same reason.
   function Trimmed (Value : String) return String
     is (Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both));

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

   function Debug_Plan
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Frame;

   function Debug_Plan
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Frame
   is
      pragma Unreferenced (Options);
   begin
      return Laid_Out (Of_Unit, Item, Facts, 16#7fff_ffff#);
   end Debug_Plan;

   function Debug_Frame
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts; Plan : Frame;
      Options : Landin.Optimization.Options) return Frame;

   function Debug_Frame
     (Of_Unit : Landin.IR.Unit; Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts; Plan : Frame;
      Options : Landin.Optimization.Options) return Frame
   is
      pragma Unreferenced (Of_Unit, Item, Facts, Options);
   begin
      return Plan;
   end Debug_Frame;

   function Debug_Slot
     (Plan : Frame; Layout : Frame; Slot : Landin.IR.Slot_Id;
      Indirect, Address_Only : Boolean) return String;

   function Debug_Slot
     (Plan : Frame; Layout : Frame; Slot : Landin.IR.Slot_Id;
      Indirect, Address_Only : Boolean) return String
   is
      pragma Unreferenced (Plan, Address_Only);
      HT : constant Character := Character'Val (9);
      LF : constant Character := Character'Val (10);
   begin
      return HT & ".byte 0x91" & LF & HT & ".sleb128 -"
        & Trimmed (Landin.Targets.Byte_Count'Image
            (Slot_Offset (Layout, Slot))) & LF
        & (if Indirect then HT & ".byte 0x06" & LF else "");
   end Debug_Slot;

   function Debug_Sections is new Landin.Backend.Dwarf.Sections
     (Frame, Debug_Plan, Debug_Frame, Debug_Slot, 29, True);

   function Frame_Is_Addressable
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Boolean
   is
      pragma Unreferenced (Options);
      Limit : constant Landin.Targets.Byte_Count := 16#7fff_ffff#;
      Layout : Frame;
   begin
      if Landin.IR.Is_External (Of_Unit, Item) then
         return True;
      end if;
      Layout := Laid_Out (Of_Unit, Item, Facts, Limit);
      if Extent (Layout) > Limit then
         return False;
      end if;
      if Landin.IR.Signature_Of (Of_Unit, Item) /= Landin.IR.No_Signature
        and then Landin.IR.Signature_Uses_C_ABI
          (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
      then
         if Darwin_ABI.Signature_Plan
           (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item), Facts,
            Limit - 16).Stack_Bytes > Limit - 16
         then
            return False;
         end if;
      elsif Landin.Targets.Byte_Count
        (Landin.IR.Parameter_Count (Of_Unit, Item)) > (Limit - 16) / 8
      then
         return False;
      end if;
      for Index in 1 .. Landin.IR.Value_Count (Of_Unit, Item) loop
         declare
            Value : constant Landin.IR.Value_Id := Landin.IR.Value_Id (Index);
            Op : constant Landin.IR.Opcode :=
              Landin.IR.Op_Of (Of_Unit, Item, Value);
         begin
            if Op in Landin.IR.Call | Landin.IR.Indirect_Call then
               declare
                  Signature : constant Landin.IR.Signature_Id :=
                    (if Op = Landin.IR.Indirect_Call
                     then Landin.IR.Call_Signature (Of_Unit, Item, Value)
                     else Landin.IR.Signature_Of
                       (Of_Unit, Landin.IR.Callee_Of (Of_Unit, Item, Value)));
               begin
                  if Landin.IR.Signature_Uses_C_ABI (Of_Unit, Signature) then
                     declare
                        Plan : constant Darwin_ABI.Plan :=
                          Darwin_ABI.Call_Plan
                            (Of_Unit, Item, Value, Facts, Limit);
                        Bytes : Landin.Targets.Byte_Count := Plan.Stack_Bytes;
                     begin
                        for Part of Plan.Arguments loop
                           if Part.Shape.Indirect then
                              Bytes := Stack_Align
                                (Bytes, Part.Shape.Alignment, Limit);
                              Bytes := Stack_Add
                                (Bytes, Part.Shape.Size, Limit);
                           end if;
                        end loop;
                        if Stack_Align (Bytes, 16, Limit) > Limit then
                           return False;
                        end if;
                     end;
                  elsif Landin.Targets.Byte_Count
                    (Landin.IR.Operand_Count (Of_Unit, Item, Value))
                      > (Limit - 15) / 8
                  then
                     return False;
                  end if;
               end;
            end if;
         end;
      end loop;
      return True;
   exception
      when Stack_Limit_Exceeded => return False;
   end Frame_Is_Addressable;

   procedure Emit
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table;
      Facts    : Landin.Targets.Target_Facts;
      Options  : Landin.Optimization.Options;
      Assembly : out Unbounded.Unbounded_String;
      Report   : in out Landin.Build_Reports.Report;
      Hosted_Entry : Landin.IR.Item_Id := Landin.IR.No_Item;
      Debug : access constant Landin.Debugging.Information := null;
      Panic : access constant Landin.Panics.Plan := null)
   is
      Out_Text : Unbounded.Unbounded_String;
      --  Dense nonzero u32 atom codes, in declaration-identity order; zero
      --  stays available for the successful half of the failing-call
      --  carrier.
      Atoms_Ranked : constant Atom_Codes := Ranked (Of_Unit);
      Serial : Natural := 0;

      procedure Put (Line : String);
      procedure Emit (Instruction : String);
      function Fresh return String;
      procedure Immediate (Register : String; Value : Pattern);
      procedure Add_Offset
        (Register : String; Offset : Landin.Targets.Byte_Count);
      procedure Address (Register, Name : String; Imported : Boolean := False);
      procedure Memory
        (Store : Boolean; Size : Held_Size; Register, Base : String);
      procedure Frame_Address
        (Offset : Landin.Targets.Byte_Count; Register : String := "x15");
      procedure Reserve (Bytes : Landin.Targets.Byte_Count);
      procedure Copy_Bytes (Bytes : Landin.Targets.Byte_Count);
      procedure Zero_Bytes (Bytes : Landin.Targets.Byte_Count);

      procedure Put (Line : String) is
      begin
         Unbounded.Append (Out_Text, Line & LF);
      end Put;

      procedure Emit (Instruction : String) is
         Space : constant Natural :=
           Ada.Strings.Fixed.Index (Instruction, " ");
         Mnemonic : constant String :=
           (if Space = 0 then Instruction
            else Instruction (Instruction'First .. Space - 1));
         Inverse : constant String :=
           (if Mnemonic = "b.eq" then "b.ne"
            elsif Mnemonic = "b.ne" then "b.eq"
            elsif Mnemonic = "b.lo" then "b.hs"
            elsif Mnemonic = "b.hs" then "b.lo"
            elsif Mnemonic = "b.cc" then "b.cs"
            elsif Mnemonic = "b.cs" then "b.cc"
            elsif Mnemonic = "b.hi" then "b.ls"
            elsif Mnemonic = "b.ls" then "b.hi"
            elsif Mnemonic = "b.lt" then "b.ge"
            elsif Mnemonic = "b.ge" then "b.lt"
            elsif Mnemonic = "b.le" then "b.gt"
            elsif Mnemonic = "b.gt" then "b.le"
            elsif Mnemonic = "b.vs" then "b.vc"
            elsif Mnemonic = "b.vc" then "b.vs"
            elsif Mnemonic = "cbz" then "cbnz"
            elsif Mnemonic = "cbnz" then "cbz"
            elsif Mnemonic = "tbz" then "tbnz"
            elsif Mnemonic = "tbnz" then "tbz" else "");
      begin
         if Inverse = "" then
            Put (Character'Val (9) & Instruction);
         else
            --  Conditional branches have shorter reach than B.  Keep their
            --  immediate target adjacent even in expanded cleanup routines.
            declare
               Skip : constant String := Fresh;
               Last_Space : constant Natural := Ada.Strings.Fixed.Index
                 (Instruction, " ", Ada.Strings.Backward);
            begin
               Put (Character'Val (9) & Inverse
                 & Instruction (Space .. Last_Space) & Skip);
               Put (Character'Val (9) & "b "
                 & Instruction (Last_Space + 1 .. Instruction'Last));
               Put (Skip & ":");
            end;
         end if;
      end Emit;

      function Fresh return String is
      begin
         Serial := Serial + 1;
         return "Llandin_step_" & Trimmed (Natural'Image (Serial));
      end Fresh;

      procedure Immediate (Register : String; Value : Pattern) is
      begin
         Emit ("movz " & Register & ", #"
               & Trimmed (Pattern'Image (Value and 65535)));
         for Index in 1 .. 3 loop
            if (Value / 2 ** (Index * 16) and 65535) /= 0 then
               Emit ("movk " & Register & ", #"
                     & Trimmed (Pattern'Image
                       (Value / 2 ** (Index * 16) and 65535))
                     & ", lsl #" & Trimmed (Natural'Image (Index * 16)));
            end if;
         end loop;
      end Immediate;

      procedure Add_Offset
        (Register : String; Offset : Landin.Targets.Byte_Count) is
      begin
         if Offset > 0 then
            Immediate ("x16", Pattern (Offset));
            Emit ("add " & Register & ", " & Register & ", x16");
         end if;
      end Add_Offset;

      procedure Address (Register, Name : String; Imported : Boolean := False)
      is
      begin
         Emit ("adrp " & Register & ", " & Name
               & (if Imported then "@GOTPAGE" else "@PAGE"));
         if Imported then
            Emit ("ldr " & Register & ", [" & Register & ", "
                  & Name & "@GOTPAGEOFF]");
         else
            Emit ("add " & Register & ", " & Register & ", "
                  & Name & "@PAGEOFF");
         end if;
      end Address;

      procedure Memory
        (Store : Boolean; Size : Held_Size; Register, Base : String)
      is
         Reg : constant String :=
           (if Size = Landin.Targets.Byte_8 then Register
            else "w" & Register (Register'First + 1 .. Register'Last));
      begin
         Emit ((if Store then "str" else "ldr")
               & (case Size is
                    when Landin.Targets.Byte_1 => "b",
                    when Landin.Targets.Byte_2 => "h",
                    when others => "")
               & " " & Reg & ", [" & Base & "]");
      end Memory;

      procedure Frame_Address
        (Offset : Landin.Targets.Byte_Count; Register : String := "x15") is
      begin
         Immediate (Register, Pattern (Offset));
         Emit ("sub " & Register & ", x29, " & Register);
      end Frame_Address;

      procedure Reserve (Bytes : Landin.Targets.Byte_Count) is
         Loop_Label : constant String := Fresh;
      begin
         if Bytes = 0 then
            return;
         end if;
         --  Touch each intervening page without using the reserved x18.
         Immediate ("x15", Pattern (Bytes / 4096));
         Emit ("cbz x15, " & Loop_Label & "_tail");
         Put (Loop_Label & ":");
         Emit ("sub sp, sp, #1, lsl #12");
         Emit ("str xzr, [sp]");
         Emit ("subs x15, x15, #1");
         Emit ("b.ne " & Loop_Label);
         Put (Loop_Label & "_tail:");
         if Bytes mod 4096 > 0 then
            Emit ("sub sp, sp, #"
                  & Trimmed (Landin.Targets.Byte_Count'Image
                    (Bytes mod 4096)));
            Emit ("str xzr, [sp]");
         end if;
      end Reserve;

      --  x9 destination, x10 source; private scratch leaves argument banks
      --  intact while copying by-value parameters at routine entry.
      procedure Copy_Bytes (Bytes : Landin.Targets.Byte_Count) is
         Loop_Label : constant String := Fresh;
      begin
         Immediate ("x11", Pattern (Bytes));
         Emit ("cbz x11, " & Loop_Label & "_end");
         Put (Loop_Label & ":");
         Emit ("ldrb w12, [x10], #1");
         Emit ("strb w12, [x9], #1");
         Emit ("subs x11, x11, #1");
         Emit ("b.ne " & Loop_Label);
         Put (Loop_Label & "_end:");
      end Copy_Bytes;

      procedure Zero_Bytes (Bytes : Landin.Targets.Byte_Count) is
         Loop_Label : constant String := Fresh;
      begin
         Immediate ("x11", Pattern (Bytes));
         Emit ("cbz x11, " & Loop_Label & "_end");
         Put (Loop_Label & ":");
         Emit ("strb wzr, [x9], #1");
         Emit ("subs x11, x11, #1");
         Emit ("b.ne " & Loop_Label);
         Put (Loop_Label & "_end:");
      end Zero_Bytes;

      --  Allocate one namespace before emitting anything.  Forced linker
      --  identities are reserved first, including imports whose source names
      --  differ.  Ordinary routines, anonymous items and data then keep their
      --  readable names when free, or receive a deterministic unused mangle.
      --  A candidate must avoid both forced names and other source names:
      --  even `landin_1_foo` can be an explicit C name or an ordinary datum.
      function Symbol (Item : Landin.IR.Item_Id) return String;
      function Evidence_Symbol (Id : Landin.IR.Evidence_Id) return String;
      function Is_Public_Item (Item : Landin.IR.Item_Id) return Boolean;

      Host_Bridge_Needed : Boolean := Hosted_Entry /= Landin.IR.No_Item;
      Allocated_Symbols : array
        (1 .. Positive'Max (1, Landin.IR.Item_Count (Of_Unit))) of
          Unbounded.Unbounded_String;

      function Is_C_Item (Item : Landin.IR.Item_Id) return Boolean
        is (Landin.IR.Signature_Of (Of_Unit, Item) /= Landin.IR.No_Signature
            and then Landin.IR.Signature_Uses_C_ABI
              (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item)));

      use Landin.Hosted;
      subtype Hosted_Bridge is Host_Helper;
      Not_A_Bridge : constant Hosted_Bridge := No_Host_Helper;
      function Bridge_Of (Spelling : String) return Hosted_Bridge
        renames Helper_Of;

      function Bridge_Symbol (Helper : Host_Helper) return String
        is (Landin.Targets.Capabilities.Link_Symbol
              (Facts, Helper_Name (Helper)));

      function Is_Hosted_Dependency (Spelling : String) return Boolean
        is (Bridge_Of (Spelling) /= Not_A_Bridge
            or else Spelling = "strlen"
            or else Spelling = "malloc"
            or else Spelling = "free"
            or else Spelling = "open"
            or else Spelling = "read"
            or else Spelling = "write"
            or else Spelling = "close"
            or else Spelling = "__error");

      function Is_Forced (Item : Landin.IR.Item_Id) return Boolean
        is (Landin.IR.Link_Symbol (Of_Unit, Item)
              /= Landin.Source.Names.No_Name
            or else Item = Hosted_Entry
            or else Landin.IR.Is_External (Of_Unit, Item));

      --  Pick a disjoint prefix for generated local labels. External source
      --  identities receive Darwin's underscore at the rendering seam.
      function Unused_Local_Prefix return String;

      function Unused_Local_Prefix return String is
         Candidate : Unbounded.Unbounded_String :=
           Unbounded.To_Unbounded_String ("L");
         Collides : Boolean;
      begin
         loop
            Collides := False;
            for Position in 1 .. Landin.IR.Item_Count (Of_Unit) loop
               declare
                  Link : constant Landin.Source.Names.Name_Id :=
                    Landin.IR.Link_Symbol
                      (Of_Unit, Landin.IR.Item_Id (Position));
               begin
                  if Link /= Landin.Source.Names.No_Name then
                     declare
                        Spelling : constant String :=
                          Landin.Source.Names.Spelling (Names, Link);
                        Prefix : constant String :=
                          Unbounded.To_String (Candidate);
                     begin
                        if Spelling'Length >= Prefix'Length
                          and then Spelling
                            (Spelling'First
                             .. Spelling'First + Prefix'Length - 1) = Prefix
                        then
                           Collides := True;
                           exit;
                        end if;
                     end;
                  end if;
               end;
            end loop;
            exit when not Collides;
            Unbounded.Append (Candidate, "_");
         end loop;
         return Unbounded.To_String (Candidate);
      end Unused_Local_Prefix;

      Local_Prefix : constant String := Unused_Local_Prefix;

      --  Linker identity, not assembly syntax.  This is also available before
      --  allocation, when discovery decides which runtime names to reserve.
      function Source_Symbol (Item : Landin.IR.Item_Id) return String;

      function Source_Symbol (Item : Landin.IR.Item_Id) return String is
         Declared : constant Landin.IR.Declaration_Id :=
           Landin.IR.Declares (Of_Unit, Item);
      begin
         if Landin.IR.Link_Symbol (Of_Unit, Item)
           /= Landin.Source.Names.No_Name
         then
            return Landin.Source.Names.Spelling
              (Names, Landin.IR.Link_Symbol (Of_Unit, Item));
         elsif Declared = Landin.IR.No_Declaration then
            return Local_Prefix & "landin_anonymous_"
              & Trimmed (Landin.IR.Item_Id'Image (Item));
         end if;
         return Landin.Source.Names.Spelling
           (Names, Landin.Resolution.Name_Of (Meanings, Declared));
      end Source_Symbol;

      --  This target owns the emitted bridges and sees actual linker
      --  spellings; the target-neutral verifier sees only interned name IDs.
      --  Refuse an override before returning any assembly, in release too.
      --  Source linkage checking must diagnose these earlier, including the
      --  pointer/retention distinctions erased from neutral scalar carriers.
      procedure Validate_Linkage;

      procedure Validate_Linkage is
         function Import_Agrees
           (Item : Landin.IR.Item_Id; Bridge : Hosted_Bridge) return Boolean;

         function Import_Agrees
           (Item : Landin.IR.Item_Id; Bridge : Hosted_Bridge) return Boolean
         is
            package Ty renames Landin.Types;
            Signature : constant Landin.IR.Signature_Id :=
              Landin.IR.Signature_Of (Of_Unit, Item);
            type Kind_Array is array (Positive range <>) of Ty.Type_Kind;

            function Matches
              (Parameters : Kind_Array; Result : Ty.Type_Kind) return Boolean;

            function Matches
              (Parameters : Kind_Array; Result : Ty.Type_Kind) return Boolean
            is
            begin
               if Landin.IR.Signature_Parameter_Count (Of_Unit, Signature)
                    /= Parameters'Length
                 or else Landin.IR.Signature_Result_Count (Of_Unit, Signature)
                    /= (if Result = Ty.No_Value then 0 else 1)
               then
                  return False;
               end if;
               for Index in Parameters'Range loop
                  declare
                     Part : constant Landin.IR.Signature_Part :=
                       Landin.IR.Nth_Signature_Parameter
                         (Of_Unit, Signature, Index);
                  begin
                     if Part.Kind /= Parameters (Index)
                       or else Part.Convention /= Landin.IR.In_Value
                       or else Part.Atoms /= Landin.IR.No_Atom_Set
                     then
                        return False;
                     end if;
                  end;
               end loop;
               return Result = Ty.No_Value
                 or else Landin.IR.Nth_Signature_Result
                   (Of_Unit, Signature, 1).Kind = Result;
            end Matches;
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) /= Landin.IR.Routine
              or else Signature = Landin.IR.No_Signature
              or else not Is_C_Item (Item)
              or else Landin.IR.Signature_Is_Variadic (Of_Unit, Signature)
              or else Landin.IR.Signature_Errors (Of_Unit, Signature)
                /= Landin.IR.No_Atom_Set
            then
               return False;
            end if;
            case Bridge is
               when Initialize_Arguments =>
                  return Matches ([Ty.I32, Ty.Usize], Ty.No_Value);
               when Argument_Count | Argument_Table =>
                  return Matches ([], Ty.Usize);
               when Argument_At | Text_Length =>
                  return Matches ([Ty.Usize], Ty.Usize);
               when Argument_At_From | Heap_Allocate =>
                  return Matches ([Ty.Usize, Ty.Usize], Ty.Usize);
               when Open_Read | Open_Write =>
                  return Matches ([Ty.Usize], Ty.I32);
               when Read_Bytes | Write_Bytes =>
                  return Matches ([Ty.I32, Ty.Usize, Ty.Usize], Ty.Usize);
               when Close_File =>
                  return Matches ([Ty.I32], Ty.I32);
               when Errno_Value =>
                  return Matches ([], Ty.I32);
               when Heap_Release =>
                  return Matches ([Ty.Usize], Ty.No_Value);
               when Not_A_Bridge =>
                  return False;
            end case;
         end Import_Agrees;
      begin
         for Position in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id :=
                 Landin.IR.Item_Id (Position);
               Spelling : constant String := Source_Symbol (Item);
               Bridge : constant Hosted_Bridge := Bridge_Of (Spelling);
            begin
               if Item = Hosted_Entry then
                  if Landin.IR.Kind_Of (Of_Unit, Item) /= Landin.IR.Routine
                    or else Is_C_Item (Item)
                    or else Spelling /= "main"
                  then
                     raise Landin.Compiler_Defect with
                       "a hosted entry must retain native main linkage";
                  end if;
               elsif Is_Forced (Item)
                 and then Hosted_Entry /= Landin.IR.No_Item
                 and then Spelling = "main"
               then
                  raise Landin.Compiler_Defect with
                    "a link symbol overrides the hosted main entry";
               end if;
               if Is_Forced (Item) and then Bridge /= Not_A_Bridge then
                  if not Landin.IR.Is_External (Of_Unit, Item) then
                     raise Landin.Compiler_Defect with
                       "a definition overrides compiler-owned symbol "
                       & Spelling;
                  elsif not Import_Agrees (Item, Bridge) then
                     raise Landin.Compiler_Defect with
                       "an import disagrees with compiler-owned symbol "
                       & Spelling;
                  end if;
               end if;
            end;
         end loop;
      end Validate_Linkage;

      procedure Allocate_Symbols;

      procedure Allocate_Symbols is
         function Available
           (Candidate : String; Item : Landin.IR.Item_Id) return Boolean;

         function Available
           (Candidate : String; Item : Landin.IR.Item_Id) return Boolean
         is
         begin
            if Host_Bridge_Needed and then Is_Hosted_Dependency (Candidate)
            then
               return False;
            end if;
            for Position in 1 .. Landin.IR.Item_Count (Of_Unit) loop
               declare
                  Other : constant Landin.IR.Item_Id :=
                    Landin.IR.Item_Id (Position);
               begin
                  if Other /= Item
                    and then
                      (Unbounded.To_String (Allocated_Symbols (Position))
                         = Candidate
                       or else Source_Symbol (Other) = Candidate)
                  then
                     return False;
                  end if;
               end;
            end loop;
            return True;
         end Available;
      begin
         for Position in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id :=
                 Landin.IR.Item_Id (Position);
            begin
               if Is_Forced (Item) then
                  Allocated_Symbols (Position) :=
                    Unbounded.To_Unbounded_String (Source_Symbol (Item));
               end if;
            end;
         end loop;
         for Position in 1 .. Landin.IR.Item_Count (Of_Unit) loop
            declare
               Item : constant Landin.IR.Item_Id :=
                 Landin.IR.Item_Id (Position);
               Declared : constant Landin.IR.Declaration_Id :=
                 Landin.IR.Declares (Of_Unit, Item);
               Spelling : constant String := Source_Symbol (Item);
            begin
               if not Is_Forced (Item) then
                  if not Is_C_Item (Item) and then Available (Spelling, Item)
                  then
                     Allocated_Symbols (Position) :=
                       Unbounded.To_Unbounded_String (Spelling);
                  else
                     declare
                        Base : constant String :=
                          (if Declared = Landin.IR.No_Declaration
                           then Spelling
                           else "landin_"
                             & Trimmed
                               (Landin.IR.Declaration_Id'Image (Declared))
                             & "_" & Spelling);
                        Candidate : Unbounded.Unbounded_String :=
                          Unbounded.To_Unbounded_String (Base);
                        Attempt : Natural := 0;
                     begin
                        while not Available
                          (Unbounded.To_String (Candidate), Item)
                        loop
                           Attempt := Attempt + 1;
                           Candidate := Unbounded.To_Unbounded_String
                             (Base & "_" & Trimmed (Natural'Image (Attempt)));
                        end loop;
                        Allocated_Symbols (Position) := Candidate;
                     end;
                  end if;
               end if;
            end;
         end loop;
      end Allocate_Symbols;

      --  Apply Darwin's external-symbol prefix only at the rendering seam.
      --  Namespace comparisons retain the source identity.
      function Symbol (Item : Landin.IR.Item_Id) return String is
         Spelling : constant String :=
           Landin.Targets.Capabilities.Link_Symbol
             (Facts, Unbounded.To_String
                (Allocated_Symbols (Positive (Item))));
      begin
         if Spelling'Length = 0 then
            raise Landin.Compiler_Defect with
              "an unallocated linker symbol reached assembly rendering";
         elsif Spelling = "." or else Spelling (Spelling'First) = '$' then
            return '"' & Spelling & '"';
         end if;
         return Spelling;
      end Symbol;

      function Evidence_Symbol (Id : Landin.IR.Evidence_Id) return String
        is (Local_Prefix & "landin_evidence_"
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
        is (Local_Prefix & Trimmed (Landin.IR.Item_Id'Image (Item))
            & "_" & Trimmed (Landin.IR.Block_Id'Image (Block)));

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

         declare
            Plan : constant Landin.Targets.Layouts.Plan :=
              Datum_Layout (Of_Unit, Item, Facts);
            Ignored : Landin.Targets.Byte_Count;
         begin
            Landin.Targets.Place (Placed, Plan.Size, Plan.Alignment, Ignored);
            if Wanted > 0 then
               Offset := Plan.Offsets (Positive (Wanted));
            end if;
         end;
      end Place_Fields;

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
         Layout : constant Frame := Laid_Out
           (Of_Unit, Item, Facts, 16#7fff_ffff#);
         Result : constant Landin.Types.Type_Kind :=
           Landin.IR.Result_Of (Of_Unit, Item);
         Hard_Trap : constant String := Label (Item, 1) & "_trap";
         Current_Value : Landin.IR.Value_Id := Landin.IR.No_Value;
         type Panic_Edge is record
            Reason : Landin.Panics.Kind;
            Site : Landin.Panics.Site_Number;
            Origin : Landin.Provenance.Origin;
            Label : Unbounded.Unbounded_String;
         end record;
         package Edge_Vectors is new Ada.Containers.Vectors
           (Positive, Panic_Edge);
         Edges : Edge_Vectors.Vector;

         function Trap (Reason : Landin.Panics.Kind) return String;
         function Trap return String;

         function Trap (Reason : Landin.Panics.Kind) return String is
         begin
            if Panic = null or else Landin.Panics.Handler (Panic.all)
              = Landin.IR.No_Item
            then
               return Hard_Trap;
            end if;
            declare
               Origin : constant Landin.Provenance.Origin :=
                 (if Current_Value = Landin.IR.No_Value
                  then Landin.IR.Origin_Of (Of_Unit, Item)
                  else Landin.IR.Origin_Of (Of_Unit, Item, Current_Value));
               Site : constant Landin.Panics.Site_Number :=
                 Landin.Panics.Site (Panic.all, Origin, Reason);
               Name : constant String := Fresh;
            begin
               Edges.Append (Panic_Edge'
                 (Reason, Site, Origin, Unbounded.To_Unbounded_String (Name)));
               return Name;
            end;
         end Trap;

         function Trap return String is
           (Trap (Landin.Panics.For_Value
              (Of_Unit, Item, Current_Value)));


         function Kind (Value : Landin.IR.Value_Id)
           return Landin.Types.Scalar_Name
           is (Landin.IR.Result_Of (Of_Unit, Item, Value));
         function Size_Of_Value (Value : Landin.IR.Value_Id) return Held_Size
           is (Size_Of (Kind (Value), Facts));
         procedure Load_Value
           (Value : Landin.IR.Value_Id; Register : String := "x9");
         procedure Store_Value
           (Value : Landin.IR.Value_Id; Register : String := "x9");
         procedure Load_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "x9");
         procedure Store_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "x9");
         procedure Extend (Register : String; Scalar : Landin.Types.Type_Kind);
         procedure Check_Fit
           (Register : String; Scalar : Landin.Types.Integer_Name);
         procedure Epilogue;

         procedure Load_Value
           (Value : Landin.IR.Value_Id; Register : String := "x9") is
         begin
            Frame_Address (Value_Offset (Layout, Value));
            Memory (False, Size_Of_Value (Value), Register, "x15");
         end Load_Value;

         procedure Store_Value
           (Value : Landin.IR.Value_Id; Register : String := "x9")
         is
            Atoms : constant Landin.IR.Atom_Set_Id :=
              Landin.IR.Atom_Set_Of (Of_Unit, Item, Value);
         begin
            if Atoms /= Landin.IR.No_Atom_Set
              and then Landin.IR.Op_Of (Of_Unit, Item, Value) in
                Landin.IR.Load | Landin.IR.Load_Indirect
                | Landin.IR.Load_Datum | Landin.IR.Load_Field
                | Landin.IR.Load_Element | Landin.IR.Load_Variant_Field
            then
               declare
                  Done : constant String := Fresh;
               begin
                  if Landin.IR.Admits_Reserved_Zero
                    (Of_Unit, Item, Value)
                  then
                     Emit ("cbz " & Register & ", " & Done);
                  end if;
                  for Index in 1 .. Landin.IR.Atom_Count (Of_Unit, Atoms) loop
                     Immediate ("x14", Pattern (Atom_Code
                       (Atoms_Ranked,
                        Landin.IR.Nth_Atom (Of_Unit, Atoms, Index))));
                     Emit ("cmp " & Register & ", x14");
                     Emit ("b.eq " & Done);
                  end loop;
                  Emit ("b " & Trap (Landin.Panics.Bad_Conversion));
                  Put (Done & ":");
               end;
            end if;
            Frame_Address (Value_Offset (Layout, Value));
            Memory (True, Size_Of_Value (Value), Register, "x15");
         end Store_Value;

         procedure Load_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "x9") is
         begin
            Frame_Address (Slot_Offset (Layout, Slot));
            Memory (False, Size_Of
              (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts),
              Register, "x15");
         end Load_Slot;

         procedure Store_Slot
           (Slot : Landin.IR.Slot_Id; Register : String := "x9") is
         begin
            Frame_Address (Slot_Offset (Layout, Slot));
            Memory (True, Size_Of
              (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts),
              Register, "x15");
         end Store_Slot;

         procedure Extend (Register : String; Scalar : Landin.Types.Type_Kind)
         is
         begin
            if Scalar in Landin.Types.I8 | Landin.Types.I16 | Landin.Types.I32
            then
               Emit ((case Scalar is
                        when Landin.Types.I8 => "sxtb ",
                        when Landin.Types.I16 => "sxth ",
                        when others => "sxtw ")
                     & Register & ", w"
                     & Register (Register'First + 1 .. Register'Last));
            end if;
         end Extend;

         procedure Check_Fit
           (Register : String; Scalar : Landin.Types.Integer_Name)
         is
            Bits : constant Natural :=
              Natural (Landin.Types.Width (Scalar, Facts));
         begin
            if Bits = 64 then
               return;
            end if;
            Emit ((if Landin.Types.Is_Signed (Scalar)
                   then "sbfx " else "ubfx ")
                  & "x14, " & Register & ", #0, #"
                  & Trimmed (Natural'Image (Bits)));
            Emit ("cmp x14, " & Register);
            Emit ("b.ne " & Trap);
         end Check_Fit;

         procedure Epilogue is
         begin
            if Debug /= null then
               Put (Dwarf.Label_Name (Local_Prefix, "epilogue", Item,
                 Natural (Current_Value)) & ":");
               Emit (".cfi_remember_state");
            end if;
            Emit ("mov sp, x29");
            Emit ("ldp x29, x30, [sp], #16");
            if Debug /= null then
               Emit (".cfi_def_cfa sp, 0");
               Emit (".cfi_restore w29");
               Emit (".cfi_restore w30");
            end if;
            Emit ("ret");
            if Debug /= null then
               Emit (".cfi_restore_state");
            end if;
         end Epilogue;

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
         procedure Part_Address
           (Place         : Landin.IR.Storage;
            Field         : Landin.IR.Element_Total;
            Register      : String;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps);
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

         procedure Part_Address
           (Place         : Landin.IR.Storage;
            Field         : Landin.IR.Element_Total;
            Register      : String;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps)
         is
            Offset : Landin.Targets.Byte_Count := 0;
            function Shape return Landin.IR.Field_Shape is
              (if Field = 0 then Root_Shape_Of (Place, 0)
               else Part_Shape_Of (Place, Landin.IR.Part_Position (Field)));
         begin
            case Place.Kind is
               when Landin.IR.Module_Datum =>
                  Address (Register, Symbol (Place.Datum));
                  if Field > 0 then
                     Offset := Field_Offset
                       (Place.Datum, Landin.IR.Part_Position (Field));
                  end if;
               when Landin.IR.Frame_Slot =>
                  Frame_Address
                    (Slot_Offset (Layout, Place.Slot), Register);
                  if Field > 0 then
                     Offset := Slot_Offset (Layout, Place.Slot)
                       - Landin.Backend.Field_Offset
                         (Of_Unit, Item, Layout, Place.Slot,
                          Landin.IR.Part_Position (Field), Facts);
                  end if;
               when Landin.IR.Runtime_Address =>
                  Load_Slot (Place.Address, Register);
                  if Field > 0 then
                     Offset := Path_Offset
                       (Landin.IR.Address_Shape
                          (Of_Unit, Item, Place.Address),
                        [1 => (Field => Landin.IR.Part_Position (Field),
                               Case_Index => 0)]);
                  end if;
            end case;
            if Nested'Length > 0 then
               Offset := Offset
                 + Path_Offset (Shape, Nested);
            end if;
            if Payload_Field > 0 then
               Offset := Offset + Landin.Backend.Variant_Payload_Field_Offset
                 (Of_Unit, Landin.IR.Shape_At (Of_Unit, Shape, Nested),
                  Positive (Which), Positive (Payload_Field), Facts);
            end if;
            Add_Offset (Register, Offset);
         end Part_Address;

         procedure Storage_Address
           (Place         : Landin.IR.Storage;
            Field         : Natural;
            Register      : String;
            Which         : Natural := 0;
            Payload_Field : Natural := 0;
            Nested        : Landin.IR.Path_Step_Array :=
              Landin.IR.No_Path_Steps) is
         begin
            Part_Address
              (Place, Landin.IR.Element_Total (Field), Register,
               Which, Payload_Field, Nested);
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
           is (Landin.Backend.Path_Offset (Of_Unit, Shape, Path, Facts));

         --  A Value_Id restarts in each item, just as a Block_Id does.  The
         --  extra `V` keeps a continuation distinct from a block label.
         --  Transfer a classified chunk at x13. Byte replay avoids reading
         --  beyond a short aggregate and preserves both ABI register banks.
         procedure C_Chunk
           (Place : Darwin_ABI.Location; Chunk : Positive; Store : Boolean);
         procedure C_Entry;
         procedure C_Call (Value : Landin.IR.Value_Id);
         procedure C_Result (Value : Landin.IR.Value_Id);

         procedure C_Chunk
           (Place : Darwin_ABI.Location; Chunk : Positive; Store : Boolean)
         is
            Stride : constant Landin.Targets.Byte_Count :=
              (if Place.Shape.Float_Bytes > 0
               then Place.Shape.Float_Bytes else 8);
            Offset : constant Landin.Targets.Byte_Count :=
              Landin.Targets.Byte_Count (Chunk - 1) * Stride;
            Bytes : constant Landin.Targets.Byte_Count :=
              Landin.Targets.Byte_Count'Min (Stride, Place.Shape.Size -
                Offset);
            Reg : constant String :=
              Trimmed (Natural'Image (Place.Registers (Chunk) - 1));
         begin
            if Store then
               Emit ((if Place.Shape.Float_Bytes > 0
                      then "fmov x14, d" else "mov x14, x") & Reg);
            else
               Emit ("mov x14, #0");
            end if;
            for Byte in 0 .. Bytes - 1 loop
               if Store then
                  Emit ("lsr x17, x14, #"
                        & Trimmed (Landin.Targets.Byte_Count'Image (Byte *
                          8)));
                  Emit ("strb w17, [x13, #"
                        & Trimmed (Landin.Targets.Byte_Count'Image
                          (Offset + Byte)) & "]");
               else
                  Emit ("ldrb w17, [x13, #"
                        & Trimmed (Landin.Targets.Byte_Count'Image
                          (Offset + Byte)) & "]");
                  Emit ("orr x14, x14, x17, lsl #"
                        & Trimmed (Landin.Targets.Byte_Count'Image (Byte *
                          8)));
               end if;
            end loop;
            if not Store then
               Emit ((if Place.Shape.Float_Bytes > 0
                      then "fmov d" else "mov x") & Reg & ", x14");
            end if;
         end C_Chunk;

         procedure C_Entry is
            Plan : constant Darwin_ABI.Plan := Darwin_ABI.Signature_Plan
              (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item), Facts);
            Hidden : constant Natural :=
              (if Plan.Result.Shape.Aggregate then 1 else 0);
         begin
            if Hidden > 0 then
               if Plan.Result.Shape.Indirect then
                  Emit ("mov x9, x8");
               else
                  Frame_Address
                    (Slot_Offset (Layout,
                       Landin.IR.Result_Slot (Of_Unit, Item)), "x9");
               end if;
               Store_Slot (Landin.IR.Nth_Parameter (Of_Unit, Item, 1));
            end if;
            for Index in Plan.Arguments'Range loop
               declare
                  Place : Darwin_ABI.Location renames Plan.Arguments (Index);
                  Slot : constant Landin.IR.Slot_Id :=
                    Landin.IR.Nth_Parameter (Of_Unit, Item, Index + Hidden);
               begin
                  if Place.On_Stack or else Place.Shape.Indirect then
                     if Place.On_Stack then
                        Emit ("mov x10, x29");
                        Add_Offset ("x10", 16 + Place.Stack_At);
                        if Place.Shape.Indirect then
                           Emit ("ldr x10, [x10]");
                        end if;
                     else
                        Emit ("mov x10, x" & Trimmed
                          (Natural'Image (Place.Registers (1) - 1)));
                     end if;
                     Frame_Address (Slot_Offset (Layout, Slot), "x9");
                     Copy_Bytes (Place.Shape.Size);
                  else
                     Frame_Address (Slot_Offset (Layout, Slot), "x13");
                     for Chunk in 1 .. Place.Shape.Count loop
                        C_Chunk (Place, Chunk, True);
                     end loop;
                  end if;
               end;
            end loop;
         end C_Entry;

         procedure C_Call (Value : Landin.IR.Value_Id) is
            Indirect : constant Boolean :=
              Landin.IR.Op_Of (Of_Unit, Item, Value) = Landin.IR.Indirect_Call;
            Plan : constant Darwin_ABI.Plan :=
              Darwin_ABI.Call_Plan (Of_Unit, Item, Value, Facts);
            Hidden : constant Natural :=
              (if Plan.Result.Shape.Aggregate then 1 else 0);
            Offset : constant Natural := (if Indirect then 1 else 0);
            Copies : array (Plan.Arguments'Range) of
              Landin.Targets.Byte_Count := [others => 0];
            Bytes : Landin.Targets.Byte_Count := Plan.Stack_Bytes;
            function Argument (Index : Positive) return Landin.IR.Value_Id
              is (Landin.IR.Nth_Operand
                    (Of_Unit, Item, Value, Index + Offset + Hidden));
         begin
            for Index in Plan.Arguments'Range loop
               if Plan.Arguments (Index).Shape.Indirect then
                  Bytes := Stack_Align
                    (Bytes, Plan.Arguments (Index).Shape.Alignment,
                     16#7fff_ffff#);
                  Copies (Index) := Bytes;
                  Bytes := Stack_Add
                    (Bytes, Plan.Arguments (Index).Shape.Size,
                     16#7fff_ffff#);
               end if;
            end loop;
            Bytes := Stack_Align (Bytes, 16, 16#7fff_ffff#);
            Reserve (Bytes);
            for Index in Plan.Arguments'Range loop
               declare
                  Place : Darwin_ABI.Location renames Plan.Arguments (Index);
               begin
                  if Place.Shape.Indirect then
                     Load_Value (Argument (Index), "x10");
                     Emit ("mov x9, sp");
                     Add_Offset ("x9", Copies (Index));
                     Copy_Bytes (Place.Shape.Size);
                     Emit ("mov x13, sp");
                     Add_Offset ("x13", Copies (Index));
                     if Place.On_Stack then
                        Emit ("mov x9, sp");
                        Add_Offset ("x9", Place.Stack_At);
                        Emit ("str x13, [x9]");
                     else
                        Emit ("mov x" & Trimmed
                          (Natural'Image (Place.Registers (1) - 1))
                          & ", x13");
                     end if;
                  elsif Place.On_Stack then
                     if Place.Shape.Aggregate then
                        Load_Value (Argument (Index), "x10");
                     else
                        Frame_Address
                          (Value_Offset (Layout, Argument (Index)), "x10");
                     end if;
                     Emit ("mov x9, sp");
                     Add_Offset ("x9", Place.Stack_At);
                     Copy_Bytes (Place.Shape.Size);
                  else
                     if Place.Shape.Aggregate then
                        Load_Value (Argument (Index), "x13");
                     else
                        Frame_Address
                          (Value_Offset (Layout, Argument (Index)), "x13");
                     end if;
                     for Chunk in 1 .. Place.Shape.Count loop
                        C_Chunk (Place, Chunk, False);
                     end loop;
                     if not Place.Shape.Aggregate then
                        Extend
                          ("x" & Trimmed
                             (Natural'Image (Place.Registers (1) - 1)),
                           Kind (Argument (Index)));
                     end if;
                  end if;
               end;
            end loop;
            if Plan.Result.Shape.Indirect then
               Load_Value (Landin.IR.Nth_Operand
                 (Of_Unit, Item, Value, Offset + 1), "x8");
            end if;
            if Indirect then
               Load_Value
                 (Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1), "x14");
               Emit ("blr x14");
            else
               Emit ("bl " & Symbol
                 (Landin.IR.Callee_Of (Of_Unit, Item, Value)));
            end if;
            if not Plan.Result.Shape.Indirect
              and then Plan.Result.Shape.Size > 0
            then
               if Hidden > 0 then
                  Load_Value (Landin.IR.Nth_Operand
                    (Of_Unit, Item, Value, Offset + 1), "x13");
               else
                  Frame_Address (Value_Offset (Layout, Value), "x13");
               end if;
               for Chunk in 1 .. Plan.Result.Shape.Count loop
                  C_Chunk (Plan.Result, Chunk, True);
               end loop;
            end if;
            Immediate ("x15", Pattern (Bytes));
            Emit ("add sp, sp, x15");
         end C_Call;

         procedure C_Result (Value : Landin.IR.Value_Id) is
            Plan : constant Darwin_ABI.Plan := Darwin_ABI.Signature_Plan
              (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item), Facts);
         begin
            if Plan.Result.Shape.Size = 0 then
               return;
            elsif Plan.Result.Shape.Indirect then
               Load_Slot (Landin.IR.Nth_Parameter (Of_Unit, Item, 1), "x9");
               Frame_Address (Slot_Offset
                 (Layout, Landin.IR.Result_Slot (Of_Unit, Item)), "x10");
               Copy_Bytes (Plan.Result.Shape.Size);
            else
               if Plan.Result.Shape.Aggregate then
                  Frame_Address (Slot_Offset
                    (Layout, Landin.IR.Result_Slot (Of_Unit, Item)), "x13");
               else
                  Frame_Address (Value_Offset (Layout,
                    Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1)), "x13");
               end if;
               for Chunk in 1 .. Plan.Result.Shape.Count loop
                  C_Chunk (Plan.Result, Chunk, False);
               end loop;
               Extend ("x0", Result);
            end if;
         end C_Result;

         procedure Instruction (Value : Landin.IR.Value_Id);

         procedure Instruction (Value : Landin.IR.Value_Id) is
            Op : constant Landin.IR.Opcode :=
              Landin.IR.Op_Of (Of_Unit, Item, Value);
            Unchecked : constant Boolean :=
              Landin.IR.Is_Unchecked (Of_Unit, Item, Value);
            function Operand (Index : Positive) return Landin.IR.Value_Id
              is (Landin.IR.Nth_Operand (Of_Unit, Item, Value, Index));
            function Place return Landin.IR.Storage is
              (if Landin.IR.Reaches_A_Slot (Of_Unit, Item, Value)
               then (if Landin.IR.Is_Address
                          (Of_Unit, Item,
                           Landin.IR.Slot_Of (Of_Unit, Item, Value))
                     then (Kind => Landin.IR.Runtime_Address,
                           Address => Landin.IR.Slot_Of (Of_Unit, Item, Value))
                     else (Kind => Landin.IR.Frame_Slot,
                           Slot => Landin.IR.Slot_Of (Of_Unit, Item, Value)))
               else (Kind => Landin.IR.Module_Datum,
                     Datum => Landin.IR.Datum_Of (Of_Unit, Item, Value)));
            function FP (Scalar : Landin.Types.Scalar_Name) return String
              is (if Scalar = Landin.Types.F32 then "s" else "d");
            procedure Packed_Atom
              (Set_Id : Landin.IR.Atom_Set_Id; Encode : Boolean);

            procedure Packed_Atom
              (Set_Id : Landin.IR.Atom_Set_Id; Encode : Boolean)
            is
               Done : constant String := Fresh;
            begin
               if Set_Id = Landin.IR.No_Atom_Set then
                  return;
               end if;
               for Index in 1 .. Landin.IR.Atom_Count (Of_Unit, Set_Id) loop
                  declare
                     Next : constant String := Fresh;
                     Code : constant Pattern := Pattern (Atom_Code
                       (Atoms_Ranked,
                        Landin.IR.Nth_Atom (Of_Unit, Set_Id, Index)));
                     Raw : constant Pattern := Pattern
                       (Landin.IR.Nth_Encoding (Of_Unit, Set_Id, Index));
                  begin
                     Immediate ("x14", (if Encode then Code else Raw));
                     Emit ("cmp x9, x14");
                     Emit ("b.ne " & Next);
                     Immediate ("x9", (if Encode then Raw else Code));
                     Emit ("b " & Done);
                     Put (Next & ":");
                  end;
               end loop;
               Emit ("b " & Trap (Landin.Panics.Bad_Conversion));
               Put (Done & ":");
            end Packed_Atom;

            procedure FP_Load (Which : Positive; Register : String);
            procedure FP_Save;
            procedure Index_Address
              (Storage : Landin.IR.Storage; Field : Natural;
               Which, Payload : Natural; Nested : Landin.IR.Path_Step_Array;
               Below : Landin.IR.Path_Step_Array := Landin.IR.No_Path_Steps);

            procedure FP_Load (Which : Positive; Register : String) is
            begin
               Load_Value (Operand (Which));
               Emit ("fmov " & FP (Kind (Operand (Which))) & Register & ", "
                     & (if Kind (Operand (Which)) = Landin.Types.F32
                        then "w9" else "x9"));
            end FP_Load;

            procedure FP_Save is
            begin
               Emit ("fmov " & (if Kind (Value) = Landin.Types.F32
                                then "w9, s16" else "x9, d16"));
               Store_Value (Value);
            end FP_Save;

            procedure Index_Address
              (Storage : Landin.IR.Storage; Field : Natural;
               Which, Payload : Natural; Nested : Landin.IR.Path_Step_Array;
               Below : Landin.IR.Path_Step_Array := Landin.IR.No_Path_Steps)
            is
               Length : constant Landin.IR.Element_Total :=
                 Array_Length_Of (Storage, Field, Which, Payload, Nested);
               Stride : constant Landin.Targets.Byte_Count :=
                 Element_Bytes_Of (Storage, Field, Which, Payload, Nested);
            begin
               Load_Value (Operand (1), "x13");
               if not Unchecked then
                  Immediate ("x14", Pattern (Length));
                  Emit ("cmp x13, x14");
                  Emit ("b.hs " & Trap);
               end if;
               Immediate ("x14", Pattern (Stride));
               Emit ("mul x13, x13, x14");
               Storage_Address (Storage, Field, "x10", Which, Payload, Nested);
               Emit ("add x10, x10, x13");
               if Below'Length > 0 then
                  Add_Offset ("x10", Path_Offset
                    (Element_Shape_Of (Storage, Field, Which, Payload, Nested),
                     Below));
               end if;
            end Index_Address;
         begin
            case Op is
               when Landin.IR.Number =>
                  declare
                     Bits : constant Landin.Targets.Bit_Width :=
                       (if Kind (Value) in Landin.Types.Float_Name
                        then Landin.Types.Float_Width (Kind (Value))
                        else Landin.Types.Width (Kind (Value), Facts));
                     Number : Pattern := Pattern
                       (Landin.IR.Number_Of (Of_Unit, Item, Value));
                  begin
                     if Kind (Value) not in Landin.Types.Float_Name
                       and then Landin.IR.Is_Negated (Of_Unit, Item, Value)
                     then
                        Number := Mask (0 - Number, Bits);
                     end if;
                     Immediate ("x9", Number);
                     Store_Value (Value);
                  end;
               when Landin.IR.Truth =>
                  Immediate ("x9", (if Landin.IR.Truth_Of
                    (Of_Unit, Item, Value) then 1 else 0));
                  Store_Value (Value);
               when Landin.IR.Atom =>
                  Immediate ("x9", Pattern (Atom_Code
                    (Atoms_Ranked, Landin.IR.Atom_Of (Of_Unit, Item, Value))));
                  Store_Value (Value);
               when Landin.IR.Measure_Size | Landin.IR.Measure_Align =>
                  declare
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Measurement_Extent
                       (Of_Unit, Item, Value, Facts, Bytes, Alignment);
                     Immediate ("x9", (if Op = Landin.IR.Measure_Size
                       then Pattern (Bytes) else Pattern (Alignment)));
                     Store_Value (Value);
                  end;
               when Landin.IR.Place_Address | Landin.IR.Storage_Address =>
                  declare
                     Storage : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                  begin
                     if Op = Landin.IR.Storage_Address
                       and then Landin.IR.Storage_Address_Has_Index
                         (Of_Unit, Item, Value)
                     then
                        Index_Address (Storage, Field, 0, 0, Nested);
                        Store_Value (Value, "x10");
                     else
                        Storage_Address (Storage, Field, "x9", Nested =>
                          Nested);
                        Store_Value (Value);
                     end if;
                  end;
               when Landin.IR.Load =>
                  Load_Slot (Landin.IR.Slot_Of (Of_Unit, Item, Value));
                  Store_Value (Value);
               when Landin.IR.Store =>
                  Load_Value (Operand (1));
                  Store_Slot (Landin.IR.Slot_Of (Of_Unit, Item, Value));
               when Landin.IR.Memory_Access =>
                  declare
                     use all type Landin.Memory.Operation;
                     M : constant Landin.Memory.Operation :=
                       Landin.IR.Memory_Operation (Of_Unit, Item, Value);
                     Size : constant Landin.Targets.Scalar_Size :=
                       Landin.Types.Storage_Size
                         (Landin.IR.Memory_Scalar (Of_Unit, Item, Value),
                          Facts);
                     Bytes : constant Positive := Landin.Targets.Bytes (Size);
                     R9 : constant String :=
                       (if Bytes = 8 then "x9" else "w9");
                     R11 : constant String :=
                       (if Bytes = 8 then "x11" else "w11");
                     R12 : constant String :=
                       (if Bytes = 8 then "x12" else "w12");
                     Suffix : constant String :=
                       (if Bytes = 1 then "b" elsif Bytes = 2 then "h"
                        else "");
                     Loop_Name : constant String := Fresh;
                  begin
                     if Landin.Memory.Operands (M) = 0 then
                        case M is
                           when Compiler_Barrier => null;
                           when Completion_Barrier => Emit ("dsb sy");
                           when Device_Barrier => Emit ("dmb sy");
                           when others => Emit ("dmb ish");
                        end case;
                     else
                        Load_Value (Operand (1), "x10");
                        if Bytes > 1 then
                           Emit ("tst x10, #"
                             & Trimmed (Natural'Image (Bytes - 1)));
                           Emit ("b.ne " & Trap);
                        end if;
                        if M not in Volatile_Load | Volatile_Store then
                           Emit ("dmb ish");
                        end if;
                        if M in Atomic_Load | Volatile_Load then
                           Memory (False, Size, "x9", "x10");
                        elsif M in Atomic_Store | Volatile_Store then
                           Load_Value (Operand (2));
                           Memory (True, Size, "x9", "x10");
                        else
                           Load_Value (Operand (2), "x11");
                           if M = Atomic_Compare_Exchange then
                              Load_Value (Operand (3), "x12");
                           end if;
                           Put (Loop_Name & ":");
                           Emit ("ldxr" & Suffix & " " & R9 & ", [x10]");
                           if M = Atomic_Compare_Exchange then
                              Emit ("cmp " & R9 & ", " & R11);
                              Emit ("b.ne " & Loop_Name & "_mismatch");
                           elsif M = Atomic_Add then
                              Emit ("add " & R12 & ", " & R9 & ", " & R11);
                           else
                              Emit ("mov " & R12 & ", " & R11);
                           end if;
                           Emit ("stxr" & Suffix & " w13, " & R12
                                 & ", [x10]");
                           Emit ("cbnz w13, " & Loop_Name);
                           if M = Atomic_Compare_Exchange then
                              Emit ("b " & Loop_Name & "_done");
                              Put (Loop_Name & "_mismatch:");
                              Emit ("clrex");
                              Put (Loop_Name & "_done:");
                           end if;
                        end if;
                        if M not in Volatile_Load | Volatile_Store then
                           Emit ("dmb ish");
                        end if;
                        if Landin.Memory.Returns_Value (M) then
                           Store_Value (Value);
                        end if;
                     end if;
                  end;

               when Landin.IR.Load_Indirect =>
                  Load_Value (Operand (1), "x10");
                  Memory (False, Size_Of_Value (Value), "x9", "x10");
                  Store_Value (Value);
               when Landin.IR.Store_Indirect =>
                  Load_Value (Operand (1), "x10");
                  Load_Value (Operand (2));
                  Memory (True, Size_Of_Value (Operand (2)), "x9", "x10");
               when Landin.IR.Load_Datum | Landin.IR.Store_Datum =>
                  Address ("x10", Symbol
                    (Landin.IR.Datum_Of (Of_Unit, Item, Value)));
                  if Op = Landin.IR.Load_Datum then
                     Memory (False, Size_Of_Value (Value), "x9", "x10");
                     Store_Value (Value);
                  else
                     Load_Value (Operand (1));
                     Memory (True, Size_Of_Value (Operand (1)), "x9", "x10");
                  end if;
               when Landin.IR.Load_Field | Landin.IR.Store_Field =>
                  declare
                     Shape : constant Landin.IR.Field_Shape :=
                       Landin.IR.Shape_At
                       (Of_Unit, Part_Shape_Of
                          (Place, Landin.IR.Field_Of (Of_Unit, Item, Value)),
                        Landin.IR.Path_Of (Of_Unit, Item, Value));
                  begin
                     if Shape.Packing.Bits /= 0 then
                        Part_Address
                          (Place, Landin.IR.Element_Total
                             (Landin.IR.Field_Of (Of_Unit, Item, Value)),
                           "x10", Nested => Landin.IR.Path_Of
                             (Of_Unit, Item, Value));
                        if Op = Landin.IR.Load_Field then
                           Memory (False, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x9", "x10");
                           Emit ("ubfx x9, x9, #" & Trimmed
                             (Natural'Image (Shape.Packing.First)) & ", #"
                             & Trimmed (Natural'Image (Shape.Packing.Bits)));
                           Packed_Atom (Shape.Atoms, Encode => False);
                           Store_Value (Value);
                        else
                           Load_Value (Operand (1));
                           Packed_Atom (Shape.Atoms, Encode => True);
                           if Shape.Packing.Bits < 64 then
                              Emit ("lsr x11, x9, #" & Trimmed
                                (Natural'Image (Shape.Packing.Bits)));
                              Emit ("cbnz x11, "
                                & Trap (Landin.Panics.Bad_Conversion));
                           end if;
                           Memory (False, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x11", "x10");
                           Emit ("bfi x11, x9, #" & Trimmed
                             (Natural'Image (Shape.Packing.First)) & ", #"
                             & Trimmed (Natural'Image (Shape.Packing.Bits)));
                           Memory (True, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x11", "x10");
                        end if;
                        return;
                     end if;
                  end;
                  Part_Address
                    (Place, Landin.IR.Element_Total
                       (Landin.IR.Field_Of (Of_Unit, Item, Value)),
                     "x10", Nested => Landin.IR.Path_Of (Of_Unit, Item,
                       Value));
                  if Op = Landin.IR.Load_Field then
                     Memory (False, Size_Of_Value (Value), "x9", "x10");
                     Store_Value (Value);
                  else
                     Load_Value (Operand (1));
                     Memory (True, Size_Of_Value (Operand (1)), "x9", "x10");
                  end if;
               when Landin.IR.Load_Element | Landin.IR.Store_Element =>
                  declare
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Shape : constant Landin.IR.Field_Shape :=
                       Reached_Shape (Place, Field, Nested);
                  begin
                     if Shape.Packing.Bits /= 0 then
                        Load_Value (Operand (1), "x13");
                        Immediate ("x14", Pattern (Shape.Length));
                        Emit ("cmp x13, x14");
                        Emit ("b.hs " & Trap);
                        Immediate ("x14", Pattern (Shape.Packing.Bits));
                        Emit ("mul x13, x13, x14");
                        Emit ("add x13, x13, #" & Trimmed
                          (Natural'Image (Shape.Packing.First)));
                        Storage_Address
                          (Place, Field, "x10", Nested => Nested);
                        Immediate ("x12", (if Shape.Packing.Bits = 64
                          then Pattern'Last else
                            2 ** Shape.Packing.Bits - 1));
                        if Op = Landin.IR.Load_Element then
                           Memory (False, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x9", "x10");
                           Emit ("lsr x9, x9, x13");
                           Emit ("and x9, x9, x12");
                           Packed_Atom (Landin.IR.Array_Element_Shape
                             (Of_Unit, Shape).Atoms, Encode => False);
                           Store_Value (Value);
                        else
                           Load_Value (Operand (2));
                           Packed_Atom (Landin.IR.Array_Element_Shape
                             (Of_Unit, Shape).Atoms, Encode => True);
                           Emit ("bic x11, x9, x12");
                           Emit ("cbnz x11, "
                                & Trap (Landin.Panics.Bad_Conversion));
                           Emit ("lsl x9, x9, x13");
                           Emit ("lsl x12, x12, x13");
                           Memory (False, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x11", "x10");
                           Emit ("bic x11, x11, x12");
                           Emit ("orr x11, x11, x9");
                           Memory (True, Landin.Targets.Packed.Carrier
                             (Shape.Packing.Storage), "x11", "x10");
                        end if;
                        return;
                     end if;
                  end;
                  Index_Address
                    (Place, Landin.IR.Element_Field_Of (Of_Unit, Item, Value),
                     Landin.IR.Variant_Case_Of (Of_Unit, Item, Value),
                     Landin.IR.Variant_Payload_Field_Of (Of_Unit, Item, Value),
                     Landin.IR.Path_Of (Of_Unit, Item, Value),
                     Landin.IR.Element_Path_Of (Of_Unit, Item, Value));
                  if Op = Landin.IR.Load_Element then
                     Memory (False, Size_Of_Value (Value), "x9", "x10");
                     Store_Value (Value);
                  else
                     Load_Value (Operand (2));
                     Memory (True, Size_Of_Value (Operand (2)), "x9", "x10");
                  end if;
               when Landin.IR.Copy_Array | Landin.IR.Copy_Variant =>
                  declare
                     Source : constant Landin.IR.Storage :=
                       Landin.IR.Source_Of (Of_Unit, Item, Value);
                     Field : constant Natural :=
                       Landin.IR.Source_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Source_Path_Of (Of_Unit, Item, Value);
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     if Op = Landin.IR.Copy_Array then
                        Bytes := Whole_Clear_Extent (Source, Field, Nested);
                     else
                        Field_Extent (Of_Unit,
                          Reached_Shape (Source, Field, Nested), Facts,
                          Bytes, Alignment);
                     end if;
                     Storage_Address
                       (Landin.IR.Destination_Of (Of_Unit, Item, Value),
                        Landin.IR.Element_Field_Of (Of_Unit, Item, Value),
                          "x9",
                        (if Op = Landin.IR.Copy_Array then
                           Landin.IR.Variant_Case_Of (Of_Unit, Item, Value)
                         else 0),
                        (if Op = Landin.IR.Copy_Array then
                           Landin.IR.Variant_Payload_Field_Of
                             (Of_Unit, Item, Value) else 0),
                        Landin.IR.Path_Of (Of_Unit, Item, Value));
                     Storage_Address (Source, Field, "x10", Nested => Nested);
                     Copy_Bytes (Bytes);
                  end;
               when Landin.IR.Clear_Array | Landin.IR.Select_Variant =>
                  declare
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     if Op = Landin.IR.Select_Variant then
                        Field_Extent
                          (Of_Unit, Reached_Shape (Destination, Field, Nested),
                           Facts, Bytes, Alignment);
                     else
                        Bytes := Whole_Clear_Extent
                          (Destination, Field, Nested);
                     end if;
                     Storage_Address (Destination, Field, "x9", Nested =>
                       Nested);
                     Zero_Bytes (Bytes);
                     if Op = Landin.IR.Select_Variant then
                        Storage_Address
                          (Destination, Field, "x10", Nested => Nested);
                        Immediate ("x9", Pattern
                          (Landin.IR.Variant_Case_Of (Of_Unit, Item, Value) -
                            1));
                        Memory (True, Size_Of
                          (Reached_Shape (Destination, Field, Nested).Element,
                           Facts), "x9", "x10");
                     end if;
                  end;
               when Landin.IR.Fill_Array =>
                  declare
                     Destination : constant Landin.IR.Storage :=
                       Landin.IR.Destination_Of (Of_Unit, Item, Value);
                     Field : constant Natural :=
                       Landin.IR.Element_Field_Of (Of_Unit, Item, Value);
                     Nested : constant Landin.IR.Path_Step_Array :=
                       Landin.IR.Path_Of (Of_Unit, Item, Value);
                     Which : constant Natural :=
                       Landin.IR.Variant_Case_Of (Of_Unit, Item, Value);
                     Payload : constant Natural :=
                       Landin.IR.Variant_Payload_Field_Of (Of_Unit, Item,
                         Value);
                     First : constant Landin.IR.Element_Total :=
                       Landin.IR.Element_Total
                         (Landin.IR.First_Part_Of (Of_Unit, Item, Value)) - 1;
                     Length : constant Landin.IR.Element_Total :=
                       Array_Length_Of (Destination, Field, Which, Payload,
                         Nested);
                     Held : constant Held_Size := Size_Of_Value (Operand (1));
                     Loop_Label : constant String := Fresh;
                  begin
                     Storage_Address
                       (Destination, Field, "x10", Which, Payload, Nested);
                     Add_Offset ("x10", Landin.Targets.Byte_Count (First)
                       * Landin.Targets.Byte_Count (Landin.Targets.Bytes
                         (Held)));
                     Load_Value (Operand (1));
                     Immediate ("x11", Pattern (Length - First));
                     Emit ("cbz x11, " & Loop_Label & "_end");
                     Put (Loop_Label & ":");
                     Memory (True, Held, "x9", "x10");
                     Emit ("add x10, x10, #"
                       & Trimmed (Positive'Image (Landin.Targets.Bytes
                         (Held))));
                     Emit ("subs x11, x11, #1");
                     Emit ("b.ne " & Loop_Label);
                     Put (Loop_Label & "_end:");
                  end;
               when Landin.IR.Load_Variant_Tag | Landin.IR.Load_Variant_Field
                  | Landin.IR.Store_Variant_Field =>
                  declare
                     Writing : constant Boolean := Op =
                       Landin.IR.Store_Variant_Field;
                  begin
                     Storage_Address
                       ((if Writing then Landin.IR.Destination_Of (Of_Unit,
                         Item, Value)
                         else Landin.IR.Source_Of (Of_Unit, Item, Value)),
                        Landin.IR.Element_Field_Of (Of_Unit, Item, Value),
                          "x10",
                        (if Op = Landin.IR.Load_Variant_Tag then 0
                         else Landin.IR.Variant_Case_Of (Of_Unit, Item,
                           Value)),
                        (if Op = Landin.IR.Load_Variant_Tag then 0
                         else Landin.IR.Variant_Payload_Field_Of (Of_Unit,
                           Item, Value)),
                        Landin.IR.Path_Of (Of_Unit, Item, Value));
                     if Writing then
                        Load_Value (Operand (1));
                        Memory (True, Size_Of_Value (Operand (1)), "x9",
                          "x10");
                     else
                        Memory (False, Size_Of_Value (Value), "x9", "x10");
                        Store_Value (Value);
                     end if;
                  end;
               when Landin.IR.Slice_Address =>
                  declare
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Field_Extent (Of_Unit,
                       Landin.IR.Slice_Element_Shape (Of_Unit, Item, Value),
                       Facts, Bytes, Alignment);
                     Load_Value (Operand (4), "x11");
                     Load_Value (Operand (3), "x10");
                     if not Unchecked then
                        Load_Value (Operand (2), "x9");
                        Emit ("cmp x11, x9");
                        Emit ((if Landin.IR.Slice_Is_Inclusive
                          (Of_Unit, Item, Value) then "b.hs " else "b.hi ") &
                            Trap);
                        Emit ("cmp x10, x11");
                        Emit ("b.hi " & Trap);
                     end if;
                     Immediate ("x11", Pattern (Bytes));
                     Load_Value (Operand (1));
                     Emit ("madd x9, x10, x11, x9");
                     Store_Value (Value);
                  end;
               when Landin.IR.Empty_Slice_Base =>
                  declare
                     Bytes : Landin.Targets.Byte_Count;
                     Alignment : Landin.Targets.Byte_Alignment;
                  begin
                     Field_Extent (Of_Unit,
                       Landin.IR.Slice_Element_Shape (Of_Unit, Item, Value),
                       Facts, Bytes, Alignment);
                     Immediate ("x9", Pattern (Alignment));
                     Store_Value (Value);
                  end;
               when Landin.IR.Negation | Landin.IR.Complement |
                 Landin.IR.Logical_Not =>
                  Load_Value (Operand (1));
                  if Op = Landin.IR.Logical_Not then
                     Emit ("eor x9, x9, #1");
                  elsif Op = Landin.IR.Complement then
                     Emit ("mvn x9, x9");
                  elsif Kind (Value) in Landin.Types.Float_Name then
                     Immediate ("x10", (if Kind (Value) = Landin.Types.F32
                       then 2 ** 31 else 2 ** 63));
                     Emit ("eor x9, x9, x10");
                  else
                     Extend ("x9", Kind (Value));
                     Emit ("negs x9, x9");
                     if not Unchecked then
                        Emit ((if Landin.Types.Is_Signed (Kind (Value))
                          then "b.vs " else "b.cc ") & Trap);
                        Check_Fit ("x9", Kind (Value));
                     end if;
                  end if;
                  Store_Value (Value);
               when Landin.IR.Add | Landin.IR.Subtract | Landin.IR.Multiply
                  | Landin.IR.Divide | Landin.IR.Remainder
                  | Landin.IR.Wrapping_Add | Landin.IR.Wrapping_Subtract
                  | Landin.IR.Wrapping_Multiply | Landin.IR.Bitwise_And
                  | Landin.IR.Bitwise_Or | Landin.IR.Bitwise_Xor
                  | Landin.IR.Shift_Left | Landin.IR.Shift_Right =>
                  if Kind (Value) in Landin.Types.Float_Name then
                     FP_Load (1, "16");
                     FP_Load (2, "17");
                     Emit ((case Op is
                       when Landin.IR.Add => "fadd ",
                       when Landin.IR.Subtract => "fsub ",
                       when Landin.IR.Multiply => "fmul ",
                       when Landin.IR.Divide => "fdiv ",
                       when others => raise Compiler_Defect with
                         "invalid float operation")
                       & FP (Kind (Value)) & "16, " & FP (Kind (Value))
                       & "16, " & FP (Kind (Value)) & "17");
                     FP_Save;
                  else
                     declare
                        Signed : constant Boolean := Landin.Types.Is_Signed
                          (Kind (Value));
                        Checked : constant Boolean := not Unchecked and then
                          Op in
                          Landin.IR.Add | Landin.IR.Subtract |
                            Landin.IR.Multiply;
                        Bits : constant Natural := Natural
                          (Landin.Types.Width (Kind (Value), Facts));
                        Done : constant String := Fresh;
                     begin
                        Load_Value (Operand (1));
                        Load_Value (Operand (2), "x10");
                        Extend ("x9", Kind (Value));
                        Extend ("x10", Kind (Value));
                        case Op is
                           when Landin.IR.Add | Landin.IR.Wrapping_Add =>
                              Emit ("adds x9, x9, x10");
                              if Checked then
                                 Emit ((if Signed then "b.vs " else "b.cs ") &
                                   Trap);
                              end if;
                           when Landin.IR.Subtract |
                             Landin.IR.Wrapping_Subtract =>
                              Emit ("subs x9, x9, x10");
                              if Checked then
                                 Emit ((if Signed then "b.vs " else "b.cc ") &
                                   Trap);
                              end if;
                           when Landin.IR.Multiply |
                             Landin.IR.Wrapping_Multiply =>
                              if Checked then
                                 Emit ((if Signed then "smulh " else "umulh ")
                                   & "x11, x9, x10");
                              end if;
                              Emit ("mul x9, x9, x10");
                              if Checked then
                                 if Signed then
                                    Emit ("asr x12, x9, #63");
                                    Emit ("cmp x11, x12");
                                    Emit ("b.ne " & Trap);
                                 else
                                    Emit ("cbnz x11, " & Trap);
                                 end if;
                              end if;
                           when Landin.IR.Divide | Landin.IR.Remainder =>
                              Emit ("cbz x10, " & Trap);
                              if Signed and then Op = Landin.IR.Divide then
                                 Immediate ("x11", To_Pattern
                                   (-Landin.Types.Folded (2 ** (Bits - 1)),
                                     64));
                                 Emit ("cmp x9, x11");
                                 Emit ("b.ne " & Done & "_divide");
                                 Emit ("cmn x10, #1");
                                 Emit ("b.eq " & Trap);
                                 Put (Done & "_divide:");
                              end if;
                              Emit ((if Signed then "sdiv " else "udiv ")
                                & "x11, x9, x10");
                              if Op = Landin.IR.Remainder then
                                 Emit ("msub x9, x11, x10, x9");
                              else
                                 Emit ("mov x9, x11");
                              end if;
                           when Landin.IR.Bitwise_And => Emit
                             ("and x9, x9, x10");
                           when Landin.IR.Bitwise_Or => Emit
                             ("orr x9, x9, x10");
                           when Landin.IR.Bitwise_Xor => Emit
                             ("eor x9, x9, x10");
                           when Landin.IR.Shift_Left | Landin.IR.Shift_Right =>
                              if Signed then
                                 Emit ("tbnz x10, #63, " & Trap);
                              end if;
                              Emit ("cmp x10, #" & Trimmed (Natural'Image
                                (Bits)));
                              Emit ("b.lo " & Done & "_shift");
                              Emit ("mov x9, #0");
                              Emit ("b " & Done);
                              Put (Done & "_shift:");
                              Emit ((if Op = Landin.IR.Shift_Left then "lsl "
                                elsif Signed then "asr " else "lsr ") &
                                  "x9, x9, x10");
                              Put (Done & ":");
                           when others => raise Compiler_Defect with
                             "invalid integer operation";
                        end case;
                        if Checked then
                           Check_Fit ("x9", Kind (Value));
                        end if;
                        Store_Value (Value);
                     end;
                  end if;
               when Landin.IR.Equal_To | Landin.IR.Not_Equal_To
                  | Landin.IR.Less_Than | Landin.IR.Less_Or_Equal
                  | Landin.IR.Greater_Than | Landin.IR.Greater_Or_Equal =>
                  declare
                     Scalar : constant Landin.Types.Scalar_Name := Kind
                       (Operand (1));
                     Float : constant Boolean := Scalar in
                       Landin.Types.Float_Name;
                     Signed : constant Boolean := Scalar in
                       Landin.Types.Integer_Name
                       and then Landin.Types.Is_Signed (Scalar);
                     Condition : constant String :=
                       (case Op is
                          when Landin.IR.Equal_To => "eq",
                          when Landin.IR.Not_Equal_To => "ne",
                          when Landin.IR.Less_Than =>
                            (if Float then "mi" elsif Signed then "lt" else
                              "lo"),
                          when Landin.IR.Less_Or_Equal =>
                            (if Float then "ls" elsif Signed then "le" else
                              "ls"),
                          when Landin.IR.Greater_Than =>
                            (if Float or Signed then "gt" else "hi"),
                          when Landin.IR.Greater_Or_Equal =>
                            (if Float or Signed then "ge" else "hs"),
                          when others => raise Compiler_Defect with
                            "invalid comparison");
                  begin
                     if Float then
                        FP_Load (1, "16");
                        FP_Load (2, "17");
                        Emit ("fcmp " & FP (Scalar) & "16, " & FP (Scalar) &
                          "17");
                     else
                        Load_Value (Operand (1));
                        Load_Value (Operand (2), "x10");
                        Extend ("x9", Scalar);
                        Extend ("x10", Scalar);
                        Emit ("cmp x9, x10");
                     end if;
                     Emit ("cset w9, " & Condition);
                     Store_Value (Value);
                  end;
               when Landin.IR.Range_Check =>
                  Load_Value (Operand (1));
                  Extend ("x9", Kind (Value));
                  Immediate ("x10", To_Pattern
                    (Landin.IR.Range_Lower (Of_Unit, Item, Value), 64));
                  Emit ("cmp x9, x10");
                  Emit ((if Landin.Types.Is_Signed (Kind (Value))
                    then "b.lt " else "b.lo ") & Trap);
                  Immediate ("x10", To_Pattern
                    (Landin.IR.Range_Upper (Of_Unit, Item, Value), 64));
                  Emit ("cmp x9, x10");
                  Emit ((if Landin.Types.Is_Signed (Kind (Value))
                    then "b.gt " else "b.hi ") & Trap);
                  Store_Value (Value);
               when Landin.IR.Conversion | Landin.IR.Pointer_Address =>
                  declare
                     From : constant Landin.Types.Scalar_Name := Kind (Operand
                       (1));
                     Into_Type : constant Landin.Types.Scalar_Name := Kind
                       (Value);
                     From_Float : constant Boolean := From in
                       Landin.Types.Float_Name;
                     Into_Float : constant Boolean := Into_Type in
                       Landin.Types.Float_Name;
                     Done : constant String := Fresh;
                  begin
                     Load_Value (Operand (1));
                     Extend ("x9", From);
                     if From_Float then
                        FP_Load (1, "16");
                     end if;
                     if From_Float and Into_Float then
                        if From /= Into_Type then
                           Emit ("fcvt " & FP (Into_Type) & "16, " & FP (From)
                             & "16");
                           if Into_Type = Landin.Types.F32 then
                              Emit ("fmov w9, s16");
                              Immediate ("x10", 16#7f80_0000#);
                              Emit ("and x11, x9, x10");
                              Emit ("cmp x11, x10");
                              Emit ("b.ne " & Done);
                              Load_Value (Operand (1), "x11");
                              Immediate ("x10", 16#7ff0_0000_0000_0000#);
                              Emit ("and x11, x11, x10");
                              Emit ("cmp x11, x10");
                              Emit ("b.ne " & Trap);
                              Put (Done & ":");
                           end if;
                        end if;
                        FP_Save;
                     elsif Into_Float then
                        Emit ((if From in Landin.Types.Integer_Name
                          and then Landin.Types.Is_Signed (From)
                          then "scvtf " else "ucvtf ") & FP (Into_Type) &
                            "16, x9");
                        FP_Save;
                     elsif Into_Type = Landin.Types.Bool then
                        if From_Float then
                           Emit ("fcmp " & FP (From) & "16, #0.0");
                           Emit ("b.eq " & Done & "_zero");
                           Emit ("fmov " & FP (From) & "17, #1.0");
                           Emit ("fcmp " & FP (From) & "16, " & FP (From) &
                             "17");
                           Emit ("b.ne " & Trap);
                           Emit ("mov x9, #1");
                           Emit ("b " & Done);
                           Put (Done & "_zero:");
                           Emit ("mov x9, #0");
                           Put (Done & ":");
                        else
                           Emit ("cmp x9, #1");
                           Emit ("b.hi " & Trap);
                        end if;
                        Store_Value (Value);
                     elsif From_Float then
                        declare
                           Bits : constant Natural := Natural
                             (Landin.Types.Width (Into_Type, Facts));
                           Signed : constant Boolean := Landin.Types.Is_Signed
                             (Into_Type);
                           Power : constant Natural := (if Signed then Bits -
                             1 else Bits);
                           Bias : constant Natural := (if From =
                             Landin.Types.F32 then 127 else 1023);
                           Fraction : constant Natural := (if From =
                             Landin.Types.F32 then 23 else 52);
                           Upper : constant Pattern := Pattern (Bias + Power)
                             * 2 ** Fraction;
                        begin
                           --  Range is checked after truncation; -0.5 may
                           --  therefore convert to unsigned zero. NaNs trap.
                           Emit ("frintz " & FP (From) & "16, " & FP (From) &
                             "16");
                           Immediate ("x10", Upper);
                           Emit ("fmov " & FP (From) & "17, "
                             & (if From = Landin.Types.F32 then "w10" else
                               "x10"));
                           Emit ("fcmp " & FP (From) & "16, " & FP (From) &
                             "17");
                           Emit ("b.vs " & Trap);
                           Emit ("b.ge " & Trap);
                           if Signed then
                              Emit ("fneg " & FP (From) & "17, " & FP (From) &
                                "17");
                              Emit ("fcmp " & FP (From) & "16, " & FP (From) &
                                "17");
                           else
                              Emit ("fcmp " & FP (From) & "16, #0.0");
                           end if;
                           Emit ("b.lt " & Trap);
                           Emit ((if Signed then "fcvtzs " else "fcvtzu ")
                             & "x9, " & FP (From) & "16");
                           Store_Value (Value);
                        end;
                     else
                        if not Unchecked and then Into_Type in
                          Landin.Types.Integer_Name
                        then
                           if From in Landin.Types.Integer_Name then
                              if Landin.Types.Is_Signed (From)
                                and then not Landin.Types.Is_Signed (Into_Type)
                              then
                                 Emit ("tbnz x9, #63, " & Trap);
                              elsif not Landin.Types.Is_Signed (From)
                                and then Landin.Types.Is_Signed (Into_Type)
                              then
                                 Emit ("tbnz x9, #63, " & Trap);
                              end if;
                           end if;
                           Check_Fit ("x9", Into_Type);
                        end if;
                        Store_Value (Value);
                     end if;
                  end;
               when Landin.IR.Function_Address =>
                  declare
                     Callee : constant Landin.IR.Item_Id :=
                       Landin.IR.Callee_Of (Of_Unit, Item, Value);
                  begin
                     Address ("x9", Symbol (Callee), Landin.IR.Is_External
                       (Of_Unit, Callee));
                     Store_Value (Value);
                  end;
               when Landin.IR.Evidence_Address =>
                  Address ("x9", Evidence_Symbol
                    (Landin.IR.Evidence_Of (Of_Unit, Item, Value)));
                  Store_Value (Value);
               when Landin.IR.Evidence_Function =>
                  Load_Value (Operand (1));
                  if Landin.IR.Evidence_Is_Erased
                    (Of_Unit, Landin.IR.Evidence_Of (Of_Unit, Item, Value))
                  then
                     Emit ("ldr x9, [x9, #8]");
                  end if;
                  Add_Offset ("x9", Landin.Targets.Evidence_Function_Offset
                    (Facts, Landin.IR.Evidence_Entry_Of (Of_Unit, Item,
                      Value)));
                  Emit ("ldr x9, [x9]");
                  Store_Value (Value);
               when Landin.IR.Evidence_Self =>
                  Load_Value (Landin.IR.Nth_Operand (Of_Unit, Item, Operand
                    (1), 1));
                  Emit ("ldr x9, [x9]");
                  Store_Value (Value);
               when Landin.IR.Failure_Test =>
                  Load_Value (Operand (1));
                  Emit ("cmp w9, #0");
                  Emit ("cset w9, ne");
                  Store_Value (Value);
               when Landin.IR.Call | Landin.IR.Indirect_Call =>
                  declare
                     Indirect : constant Boolean := Op =
                       Landin.IR.Indirect_Call;
                     Signature : constant Landin.IR.Signature_Id :=
                       (if Indirect then Landin.IR.Call_Signature (Of_Unit,
                         Item, Value)
                        else Landin.IR.Signature_Of (Of_Unit,
                          Landin.IR.Callee_Of (Of_Unit, Item, Value)));
                     Offset : constant Natural := (if Indirect then 1 else 0);
                     Count : constant Natural :=
                       Landin.IR.Operand_Count (Of_Unit, Item, Value) - Offset;
                     Bytes : constant Landin.Targets.Byte_Count :=
                       Stack_Align (Landin.Targets.Byte_Count
                         (Natural'Max (8, Count) - 8) * 8, 16, 16#7fff_ffff#);
                  begin
                     if Landin.IR.Signature_Uses_C_ABI (Of_Unit, Signature)
                     then
                        C_Call (Value);
                        return;
                     end if;
                     Reserve (Bytes);
                     for Index in 1 .. Count loop
                        if Index <= 8 then
                           Load_Value (Operand (Index + Offset), "x"
                             & Trimmed (Natural'Image (Index - 1)));
                        else
                           Load_Value (Operand (Index + Offset));
                           Emit ("mov x10, sp");
                           Add_Offset ("x10", Landin.Targets.Byte_Count (Index
                             - 9) * 8);
                           Emit ("str x9, [x10]");
                        end if;
                     end loop;
                     if Indirect then
                        Load_Value (Operand (1), "x14");
                        Emit ("blr x14");
                     else
                        Emit ("bl " & Symbol (Landin.IR.Callee_Of (Of_Unit,
                          Item, Value)));
                     end if;
                     if Landin.IR.Failure_Slot_Of (Of_Unit, Item, Value) /=
                       Landin.IR.No_Slot
                     then
                        Store_Slot (Landin.IR.Failure_Slot_Of (Of_Unit, Item,
                          Value), "x8");
                     end if;
                     if Landin.IR.Result_Of (Of_Unit, Item, Value) in
                       Landin.Types.Scalar_Name
                     then
                        Store_Value (Value, "x0");
                     end if;
                     Immediate ("x15", Pattern (Bytes));
                     Emit ("add sp, sp, x15");
                  end;
               when Landin.IR.Jump =>
                  Emit ("b " & Label (Item, Landin.IR.Target_Of (Of_Unit,
                    Item, Value)));
               when Landin.IR.Branch =>
                  Load_Value (Operand (1));
                  Emit ("cbnz w9, " & Label (Item, Landin.IR.Target_Of
                    (Of_Unit, Item, Value)));
                  Emit ("b " & Label (Item, Landin.IR.Alternative_Of (Of_Unit,
                    Item, Value)));
               when Landin.IR.Leave =>
                  if Is_C_Item (Item) then
                     C_Result (Value);
                  elsif Result in Landin.Types.Scalar_Name then
                     Load_Value (Operand (1), "x0");
                  elsif Result in Landin.Types.Aggregate |
                    Landin.Types.Fixed_Array
                  then
                     declare
                        Slot : constant Landin.IR.Slot_Id :=
                          Landin.IR.Result_Slot (Of_Unit, Item);
                     begin
                        Load_Slot (Landin.IR.Nth_Parameter (Of_Unit, Item, 1));
                        Frame_Address (Slot_Offset (Layout, Slot), "x10");
                        Copy_Bytes (Whole_Clear_Extent
                          ((Kind => Landin.IR.Frame_Slot, Slot => Slot), 0,
                            Landin.IR.No_Path_Steps));
                     end;
                  end if;
                  Emit ("mov w8, #0");
                  Epilogue;
               when Landin.IR.Halt =>
                  if Panic = null or else Landin.Panics.Handler (Panic.all)
                    = Landin.IR.No_Item
                  then
                     Emit ("brk #1");
                  else
                     Emit ("b " & Trap (Landin.Panics.Unreachable));
                  end if;

               when Landin.IR.Fail =>
                  Load_Value (Operand (1), "x8");
                  Epilogue;
            end case;
         end Instruction;

      begin
         if Is_Public_Item (Item) or else Is_Forced (Item) then
            Emit (".globl " & Symbol (Item));
         end if;
         Emit (".p2align 2");
         Put (Symbol (Item) & ":");
         if Debug /= null then
            Put (Dwarf.Label_Name (Local_Prefix, "begin", Item) & ":");
            Put (Dwarf.Source_Line
              (Debug.all, Landin.IR.Origin_Of (Of_Unit, Item)));
            Emit (".cfi_startproc");
         end if;
         Emit ("stp x29, x30, [sp, #-16]!");
         if Debug /= null then
            Emit (".cfi_def_cfa_offset 16");
            Emit (".cfi_offset w29, -16");
            Emit (".cfi_offset w30, -8");
         end if;
         Emit ("mov x29, sp");
         if Debug /= null then
            Emit (".cfi_def_cfa_register w29");
         end if;
         if Item = Hosted_Entry then
            Emit ("bl " & Bridge_Symbol (Initialize_Arguments));
         end if;
         Reserve (Extent (Layout));
         if Panic /= null and then Item = Landin.Panics.Handler (Panic.all)
         then
            declare
               Retry : constant String := Fresh;
            begin
               Address ("x16", Local_Prefix & "landin_panic_active");
               Put (Retry & ":");
               Emit ("ldaxr w17, [x16]");
               Emit ("cbnz w17, " & Hard_Trap);
               Emit ("mov w17, #1");
               Emit ("stlxr w15, w17, [x16]");
               Emit ("cbnz w15, " & Retry);
            end;
         end if;
         if Is_C_Item (Item) then
            C_Entry;
         else
            for Index in 1 .. Landin.IR.Parameter_Count (Of_Unit, Item) loop
               declare
                  Slot : constant Landin.IR.Slot_Id := Landin.IR.Nth_Parameter
                    (Of_Unit, Item, Index);
                  Aggregate : constant Boolean := Landin.IR.Is_Aggregate
                    (Of_Unit, Item, Slot)
                    or else Landin.IR.Is_Array (Of_Unit, Item, Slot);
               begin
                  if Index <= 8 then
                     Emit ("mov x10, x" & Trimmed (Natural'Image (Index - 1)));
                  else
                     Emit ("mov x10, x29");
                     Add_Offset ("x10", 16 + Landin.Targets.Byte_Count (Index
                       - 9) * 8);
                     Emit ("ldr x10, [x10]");
                  end if;
                  if Aggregate then
                     Frame_Address (Slot_Offset (Layout, Slot), "x9");
                     Copy_Bytes (Whole_Clear_Extent
                       ((Kind => Landin.IR.Frame_Slot, Slot => Slot), 0,
                         Landin.IR.No_Path_Steps));
                  else
                     Store_Slot (Slot, "x10");
                  end if;
               end;
            end loop;
         end if;
         for Block in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            Put (Label (Item, Landin.IR.Block_Id (Block)) & ":");
            for Position in 1 .. Landin.IR.Length (Of_Unit, Item,
              Landin.IR.Block_Id (Block)) loop
               Current_Value := Landin.IR.Nth_Value (Of_Unit, Item,
                 Landin.IR.Block_Id (Block), Position);
               if Debug /= null then
                  Put (Dwarf.Label_Name (Local_Prefix, "value", Item,
                    Natural (Current_Value)) & ":");
                  Put (Dwarf.Source_Line (Debug.all,
                    Landin.IR.Origin_Of (Of_Unit, Item, Current_Value)));
               end if;
               Instruction (Current_Value);
               if Debug /= null then
                  Put (Dwarf.Label_Name (Local_Prefix, "after", Item,
                    Natural (Current_Value)) & ":");
               end if;
            end loop;
         end loop;
         for Edge of Edges loop
            Put (Unbounded.To_String (Edge.Label) & ":");
            if Debug /= null then
               Put (Dwarf.Source_Line (Debug.all, Edge.Origin));
            end if;
            Immediate ("x0", Pattern (Landin.Panics.Code
              (Panic.all, Edge.Reason)));
            Immediate ("x1", Pattern (Edge.Site));
            Emit ("bl " & Symbol (Landin.Panics.Handler (Panic.all)));
            Emit ("brk #1");
         end loop;
         Put (Hard_Trap & ":");
         Emit ("brk #1");
         if Debug /= null then
            Put (Dwarf.Label_Name (Local_Prefix, "end", Item) & ":");
            Emit (".cfi_endproc");
         end if;
         Landin.Build_Reports.Append (Report,
           Landin.Build_Reports.Routine_Statistics'
             (Item => Item, Frame_Bytes => Extent (Layout), others => <>));
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
         type Folded_Values is array (Positive range <>)
           of Landin.Types.Folded;
         package Folded_Buffers is new Work_Arrays
           (Landin.Types.Folded, Folded_Values, 0);
         Held_Data : Folded_Buffers.Buffer
           (Landin.IR.Value_Count (Of_Unit, Item));
         Slot_Data : Folded_Buffers.Buffer
           (Landin.IR.Slot_Count (Of_Unit, Item));
         Held : Folded_Values renames Held_Data.Data.all;
         Slots : Folded_Values renames Slot_Data.Data.all;

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
                               (Atoms_Ranked,
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

                     when Landin.IR.Range_Check =>
                        --  D188 folds a checked module datum before emission.
                        --  A mandatory integer-to-pointer nonnull check also
                        --  reaches this walk, so an in-range static operand
                        --  passes through while an impossible image remains
                        --  an internal failure.
                        declare
                           Source : constant Landin.IR.Value_Id :=
                             Operand_Of (Value, 1);
                           Folded_Source : constant Landin.Types.Folded :=
                             Of_Value (Source);
                           Lower : constant Landin.Types.Folded :=
                             Landin.IR.Range_Lower (Of_Unit, Item, Value);
                           Upper : constant Landin.Types.Folded :=
                             Landin.IR.Range_Upper (Of_Unit, Item, Value);
                        begin
                           if Folded_Source < Lower
                             or else Folded_Source > Upper
                           then
                              raise Compiler_Defect with
                                "an out-of-range module image passed checking";
                           end if;
                           Held (Natural (Value)) := Folded_Source;
                        end;

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
                        | Landin.IR.Evidence_Function
                        | Landin.IR.Evidence_Self | Landin.IR.Call
                        | Landin.IR.Memory_Access
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
                        | Landin.IR.Fail | Landin.IR.Halt =>
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
               when Landin.Targets.Byte_2 => ".short",
               when Landin.Targets.Byte_4 => ".long",
               when Landin.Targets.Byte_8 => ".quad");

      procedure Emit_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Slice_Image_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Aggregate_Datum (Item : Landin.IR.Item_Id);

      procedure Emit_Recursive_Image_Datum (Item : Landin.IR.Item_Id);

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

      --  D132 and recursive arrays share one descriptor-tree writer.  Replay
      --  ordinary-child and selected-payload placement against this target;
      --  array sequences repeat the complete child image at its padded size.
      --  Descriptors carry no byte offsets: every gap and tail is derived
      --  here and emitted as zero, never stored per logical array element.
      procedure Emit_Recursive_Image_Datum
        (Item : Landin.IR.Item_Id)
      is
         Placed : Landin.Targets.Placement;
         Ignored : Landin.Targets.Byte_Count;
         Written : Landin.Targets.Byte_Count := 0;
         Size : Landin.Targets.Byte_Count;
         Alignment : Landin.Targets.Byte_Alignment;
         Is_Array : constant Boolean :=
           Landin.IR.Has_Recursive_Array_Image (Of_Unit, Item);
         Top_Plan : constant Landin.Targets.Layouts.Plan :=
           (if Is_Array then Landin.Targets.Layouts.Make ([])
            else Datum_Layout (Of_Unit, Item, Facts));

         procedure Emit_Packed
           (Shape : Landin.IR.Field_Shape;
            Parent : Landin.IR.Aggregate_Field_Image;
            Top : Boolean := False);

         procedure Emit_Packed
           (Shape : Landin.IR.Field_Shape;
            Parent : Landin.IR.Aggregate_Field_Image;
            Top : Boolean := False)
         is
            use type Landin.Packed.Image;
            Bits : Landin.Packed.Image := 0;
            Storage : Natural := 0;
            Count : constant Natural :=
              (if Top then Landin.IR.Field_Count (Of_Unit, Item)
               else Landin.IR.Aggregate_Field_Count (Of_Unit, Shape));
         begin
            for Index in 1 .. Count loop
               declare
                  Leaf : constant Landin.IR.Field_Shape :=
                    (if Top then Landin.IR.Nth_Field_Shape
                       (Of_Unit, Item, Index)
                     else Landin.IR.Nth_Aggregate_Field
                       (Of_Unit, Shape, Index));
                  Image : constant Landin.IR.Aggregate_Field_Image :=
                    (if Top then Landin.IR.Field_Image_Of
                       (Of_Unit, Item, Index)
                     else Landin.IR.Descendant_Image_Of
                       (Of_Unit, Item, Parent, Index));
                  Scalar : constant Landin.Types.Folded :=
                    (if Top then Landin.IR.Nth_Field_Image
                       (Of_Unit, Item, Index) else Image.Value);
               begin
                  Bits := Bits or Landin.IR.Packed_Field_Image
                    (Of_Unit, Item, Leaf, Image, Scalar);
                  Storage := Leaf.Packing.Storage;
               end;
            end loop;
            Emit (Directive (Landin.Targets.Packed.Carrier (Storage)) & " "
              & Trimmed (Landin.Packed.Image'Image (Bits)));
         end Emit_Packed;

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
            elsif Image.Form = Landin.IR.Element_Sequence then
               --  Count is stored children, not logical elements.  Only
               --  the final child repeats; its complete target-laid-out
               --  image (including tail padding) is the array stride.
               --  Descendant_Image_Of skips descriptor roots, whereas
               --  Nth_Descriptor_Element below skips numeric fields only.
               if (Image.Count = 0
                   and then (Image.Value /= 0 or else Shape.Length /= 0))
                 or else (Image.Count > 0
                   and then
                     (Landin.IR.Element_Total (Image.Count - 1)
                        > Shape.Length
                      or else Image.Value /= Landin.Types.Folded
                        (Shape.Length
                         - Landin.IR.Element_Total (Image.Count - 1))))
               then
                  raise Landin.Compiler_Defect with
                    "a recursive array image has the wrong coverage";
               end if;
               for Position in 1 .. Image.Count loop
                  declare
                     Child : constant Landin.IR.Aggregate_Field_Image :=
                       Landin.IR.Descendant_Image_Of
                         (Of_Unit, Item, Image, Position);
                     Copies : constant Landin.Types.Folded :=
                       (if Position = Image.Count then Image.Value else 1);
                  begin
                     --  A zero suffix was evaluated but stores nothing.
                     if Copies > 0 then
                        if Copies > 1 then
                           Emit
                             (".rept " & Trimmed
                                (Landin.Types.Folded'Image (Copies)));
                        end if;
                        Emit_Field
                          (Landin.IR.Array_Element_Shape (Of_Unit, Shape),
                           Child, Child.Value);
                        if Copies > 1 then
                           Emit (".endr");
                        end if;
                     end if;
                  end;
               end loop;
            elsif Image.Form = Landin.IR.Absent then
               Emit_Zero (Field_Size);
            elsif Landin.IR.Array_Element_Is_Aggregate (Of_Unit, Shape) then
               raise Landin.Compiler_Defect with
                 "a complete array element has a numeric image";
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
            else
               raise Landin.Compiler_Defect with
                 "a malformed recursive array image reached arm64";
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
                 "a malformed recursive variant image reached arm64";
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
            Plan : constant Landin.Targets.Layouts.Plan :=
              Aggregate_Layout (Of_Unit, Shape, Facts);
            Child_Written : Landin.Targets.Byte_Count := 0;
            Child_Size : Landin.Targets.Byte_Count;
            Child_Alignment : Landin.Targets.Byte_Alignment;
         begin
            if Landin.IR.Layout_Of (Of_Unit, Shape) = Landin.Layouts.Packed
            then
               Emit_Packed (Shape, Parent);
               return;
            end if;
            for Child of Plan.Order loop
               declare
                  Leaf : constant Landin.IR.Field_Shape :=
                    Landin.IR.Nth_Aggregate_Field
                      (Of_Unit, Shape, Child);
                  Image : constant Landin.IR.Aggregate_Field_Image :=
                    Landin.IR.Descendant_Image_Of
                      (Of_Unit, Item, Parent, Child);
                  At_Child : constant Landin.Targets.Byte_Count :=
                    Plan.Offsets (Child);
               begin
                  Landin.Backend.Field_Extent
                    (Of_Unit, Leaf, Facts, Child_Size, Child_Alignment);
                  if At_Child > Child_Written then
                     Emit_Zero (At_Child - Child_Written);
                  end if;
                  Emit_Field (Leaf, Image, Image.Value);
                  Child_Written := At_Child + Child_Size;
               end;
            end loop;

            if Plan.Size > Child_Written then
               Emit_Zero (Plan.Size - Child_Written);
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
                        elsif Shape.Atoms /= Landin.IR.No_Atom_Set
                        then Trimmed (Positive'Image
                          (Atom_Code
                             (Atoms_Ranked, Landin.IR.Declaration_Id
                                (if Top then Flat else Image.Value))))
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
                       "a malformed nested image reached arm64";
                  end if;

               when Landin.IR.Variant_Field_Shape =>
                  Emit_Variant (Shape, Image);
            end case;
         end Emit_Field;
      begin
         if Is_Array then
            Landin.Backend.Field_Extent
              (Of_Unit, Landin.IR.Whole_Array_Shape (Of_Unit, Item),
               Facts, Size, Alignment);
         else
            Place_Fields (Item, Placed, 0, Ignored);
            Size := Landin.Targets.Size_Of (Placed);
            Alignment := Landin.Targets.Alignment_Of (Placed);
         end if;

         if Is_Public_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;
         Put
           (Character'Val (9) & ".balign "
            & Trimmed (Landin.Targets.Byte_Alignment'Image (Alignment)));
         Put (Symbol (Item) & ":");
         if not Is_Array
           and then Landin.IR.Layout_Of (Of_Unit, Item) = Landin.Layouts.Packed
         then
            Emit_Packed ((others => <>), (others => <>), Top => True);
            return;
         end if;


         if Is_Array then
            Emit_Array
              (Landin.IR.Whole_Array_Shape (Of_Unit, Item),
               Landin.IR.Array_Image_Of (Of_Unit, Item));
            Written := Size;
         end if;
         for Field of Top_Plan.Order loop
            declare
               Shape : constant Landin.IR.Field_Shape :=
                 Landin.IR.Nth_Field_Shape (Of_Unit, Item, Field);
               Image : constant Landin.IR.Aggregate_Field_Image :=
                 Landin.IR.Field_Image_Of (Of_Unit, Item, Field);
               Field_Size : Landin.Targets.Byte_Count;
               Field_Alignment : Landin.Targets.Byte_Alignment;
               At_Field : constant Landin.Targets.Byte_Count :=
                 Top_Plan.Offsets (Field);
            begin
               Landin.Backend.Field_Extent
                 (Of_Unit, Shape, Facts, Field_Size, Field_Alignment);
               pragma Unreferenced (Field_Alignment);
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

         if Size > Written then
            Emit_Zero (Size - Written);
         end if;
      end Emit_Recursive_Image_Datum;

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
         Power : Natural := 0;
         Remaining : Natural := Natural (Alignment);
      begin
         while Remaining > 1 loop
            Power := Power + 1;
            Remaining := Remaining / 2;
         end loop;
         if Is_Public_Item (Item) then
            Emit (".globl " & Symbol (Item));
         end if;
         Emit (".zerofill __DATA,__bss," & Symbol (Item) & ","
           & Trimmed (Landin.Targets.Byte_Count'Image (Size)) & ","
           & Trimmed (Natural'Image (Power)));
      end Emit_Reserved;

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
      begin
         if Landin.IR.Has_Recursive_Array_Image (Of_Unit, Item) then
            Emit_Recursive_Image_Datum (Item);
            return;
         end if;

         --  Do not even ask for a scalar width until recursive roots have
         --  been excluded: their immediate element need not be scalar.
         declare
            Length : constant Landin.IR.Element_Total :=
              Landin.IR.Array_Length (Of_Unit, Item);
            Element : constant Landin.Types.Scalar_Name :=
              Landin.IR.Array_Element (Of_Unit, Item);
            Held : constant Held_Size := Size_Of (Element, Facts);
         begin
            if Is_Public_Item (Item) then
               Put (Character'Val (9) & ".globl " & Symbol (Item));
            end if;

               Put (Character'Val (9) & ".balign "
                 & Trimmed
                     (Landin.Targets.Byte_Alignment'Image
                        (Landin.Targets.Alignment_Of (Facts, Held))));
            Put (Symbol (Item) & ":");

            if Landin.IR.Is_Repeated_Image (Of_Unit, Item) then
               --  D34 uses `.rept` around one width-specific scalar directive.
               --  D38 writes its finite prefix first, then repeats one suffix
               --  value for N - k positions.  Assembly size depends on
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

         end;
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
         Put (Character'Val (9) & ".balign 8");
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
      begin
         if Is_Public_Item (Item) then
            Put (Character'Val (9) & ".globl " & Symbol (Item));
         end if;

         Put (Character'Val (9) & ".balign "
              & Trimmed
                  (Landin.Targets.Byte_Alignment'Image
                     (Landin.Targets.Alignment_Of (Facts, Held))));
         Put (Symbol (Item) & ":");
         Emit (Directive (Held) & " " & Written);
      end Emit_Datum;

      procedure Runtime;

      procedure Runtime is
         Argv : constant String := Local_Prefix & "host_argv";
         Argc : constant String := Local_Prefix & "host_argc";
         Invalid : constant String := Local_Prefix & "host_invalid";
         Open_Frame : Boolean := False;
         procedure Start (Helper : Host_Helper);
         procedure Finish;
         procedure Tail (Name : String);

         procedure Start (Helper : Host_Helper) is
         begin
            if Debug /= null and then Open_Frame then
               Emit (".cfi_endproc");
            end if;
            Emit (".p2align 2");
            Emit (".globl " & Bridge_Symbol (Helper));
            Emit (".private_extern " & Bridge_Symbol (Helper));
            Put (Bridge_Symbol (Helper) & ":");
            if Debug /= null then
               Emit (".loc 1 0 0 is_stmt 0");
               Emit (".cfi_startproc");
               Open_Frame := True;
            end if;
            Emit ("stp x29, x30, [sp, #-16]!");
            if Debug /= null then
               Emit (".cfi_def_cfa_offset 16");
               Emit (".cfi_offset w29, -16");
               Emit (".cfi_offset w30, -8");
            end if;
            Emit ("mov x29, sp");
            if Debug /= null then
               Emit (".cfi_def_cfa_register w29");
            end if;
         end Start;

         procedure Finish is
         begin
            if Debug /= null then
               Emit (".cfi_remember_state");
            end if;
            Emit ("mov sp, x29");
            Emit ("ldp x29, x30, [sp], #16");
            if Debug /= null then
               Emit (".cfi_def_cfa sp, 0");
               Emit (".cfi_restore w29");
               Emit (".cfi_restore w30");
            end if;
            Emit ("ret");
            if Debug /= null then
               Emit (".cfi_restore_state");
            end if;
         end Finish;

         procedure Tail (Name : String) is
         begin
            Emit ("bl _" & Name);
            Finish;
         end Tail;
      begin
         Emit (".text");
         Start (Initialize_Arguments);
         Address ("x9", Argv);
         Emit ("ldr x10, [x9]");
         Emit ("cbnz x10, " & Local_Prefix & "host_initialized");
         Emit ("tbnz w0, #31, " & Invalid);
         Emit ("cbz x1, " & Invalid);
         Emit ("str x1, [x9]");
         Address ("x9", Argc);
         Emit ("str w0, [x9]");
         Finish;
         Put (Local_Prefix & "host_initialized:");
         Emit ("cmp x10, x1");
         Emit ("b.ne " & Invalid);
         Address ("x9", Argc);
         Emit ("ldr w10, [x9]");
         Emit ("cmp w10, w0");
         Emit ("b.ne " & Invalid);
         Finish;
         Put (Invalid & ":");
         if Panic /= null and then Landin.Panics.Handler (Panic.all)
           /= Landin.IR.No_Item
         then
            Immediate ("x0", Pattern (Landin.Panics.Code
              (Panic.all, Landin.Panics.Unreachable)));
            Emit ("mov w1, #0");
            Emit ("bl " & Symbol (Landin.Panics.Handler (Panic.all)));
         end if;
         Emit ("brk #1");
         Start (Argument_Count);
         Address ("x9", Argv);
         Emit ("ldr x9, [x9]");
         Emit ("cbz x9, " & Invalid);
         Address ("x9", Argc);
         Emit ("ldr w0, [x9]");
         Emit ("subs w0, w0, #1");
         Emit ("csel w0, w0, wzr, ge");
         Finish;
         Start (Argument_Table);
         Address ("x9", Argv);
         Emit ("ldr x0, [x9]");
         Emit ("cbz x0, " & Invalid);
         Emit ("add x0, x0, #8");
         Finish;
         Start (Argument_At);
         Address ("x9", Argv);
         Emit ("ldr x9, [x9]");
         Emit ("cbz x9, " & Invalid);
         Address ("x10", Argc);
         Emit ("ldr w10, [x10]");
         Emit ("subs w10, w10, #1");
         Emit ("b.le " & Invalid);
         Emit ("cmp x0, x10");
         Emit ("b.hs " & Invalid);
         Emit ("add x9, x9, #8");
         Emit ("ldr x0, [x9, x0, lsl #3]");
         Emit ("cbz x0, " & Invalid);
         Finish;
         Start (Argument_At_From);
         Emit ("ldr x0, [x0, x1, lsl #3]");
         Finish;
         Start (Text_Length);
         Tail ("strlen");
         Start (Read_Bytes);
         Tail ("read");
         Start (Write_Bytes);
         Tail ("write");
         Start (Close_File);
         Tail ("close");
         Start (Open_Read);
         Emit ("mov w1, #0");
         Tail ("open");
         Start (Open_Write);
         --  Darwin O_WRONLY | O_CREAT | O_TRUNC, mode 0666 on the
         --  variadic stack; libc applies the process umask.
         Emit ("mov w1, #1537");
         Emit ("sub sp, sp, #16");
         Emit ("mov w9, #438");
         Emit ("str x9, [sp]");
         Tail ("open");
         Start (Errno_Value);
         Emit ("bl ___error");
         Emit ("ldr w0, [x0]");
         Finish;
         Start (Heap_Allocate);
         Emit ("cmp x1, #1");
         Emit ("mov x9, #1");
         Emit ("csel x1, x1, x9, hi");
         Emit ("adds x9, x1, #7");
         Emit ("b.cs " & Local_Prefix & "heap_failed");
         Emit ("adds x0, x0, x9");
         Emit ("b.cs " & Local_Prefix & "heap_failed");
         Emit ("tbnz x0, #63, " & Local_Prefix & "heap_failed");
         Emit ("sub sp, sp, #16");
         Emit ("str x1, [sp]");
         Emit ("bl _malloc");
         Emit ("cbz x0, " & Local_Prefix & "heap_failed");
         Emit ("ldr x1, [sp]");
         Emit ("add x9, x0, #8");
         Emit ("udiv x10, x9, x1");
         Emit ("msub x10, x10, x1, x9");
         Emit ("sub x11, x1, x10");
         Emit ("cmp x10, #0");
         Emit ("csel x11, xzr, x11, eq");
         Emit ("add x9, x9, x11");
         Emit ("stur x0, [x9, #-8]");
         Emit ("mov x0, x9");
         Finish;
         Put (Local_Prefix & "heap_failed:");
         Emit ("mov x0, #0");
         Finish;
         Start (Heap_Release);
         Emit ("ldur x0, [x0, #-8]");
         Tail ("free");
         if Debug /= null then
            Emit (".cfi_endproc");
         end if;
         Emit (".data");
         Emit (".balign 8");
         Put (Argv & ":");
         Emit (".quad 0");
         Put (Argc & ":");
         Emit (".long 0");
      end Runtime;

   begin
      if Facts /= Landin.Targets.Darwin_Arm64 then
         raise Compiler_Defect with
           "arm64 emission needs Darwin";
      end if;
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         if Landin.IR.Is_External (Of_Unit, Landin.IR.Item_Id (Index))
           and then Helper_Of (Source_Symbol (Landin.IR.Item_Id (Index))) /=
             No_Host_Helper
         then
            Host_Bridge_Needed := True;
         end if;
      end loop;
      Validate_Linkage;
      Allocate_Symbols;
      if Panic /= null and then Landin.Panics.Handler (Panic.all)
        /= Landin.IR.No_Item
      then
         Emit (".zerofill __DATA,__bss," & Local_Prefix
           & "landin_panic_active,4,2");
      end if;
      Emit (".text");
      if Debug /= null then
         Unbounded.Append (Out_Text, Dwarf.Preamble
           (Debug.all, Local_Prefix, Mach_O => True));
      end if;
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine
              and then not Landin.IR.Is_External (Of_Unit, Item)
            then
               Emit_Routine (Item);
            end if;
         end;
      end loop;
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Datum then
               if Landin.IR.Is_Read_Only (Of_Unit, Item) then
                  Emit (".section __TEXT,__const");
                  Emit_Array_Image_Datum (Item);
               else
                  Emit (".data");
                  if Is_All_Zero (Item) then
                     if Landin.IR.Result_Of (Of_Unit, Item) =
                       Landin.Types.Aggregate
                     then
                        Emit_Aggregate_Datum (Item);
                     elsif Landin.IR.Result_Of (Of_Unit, Item) =
                       Landin.Types.Fixed_Array
                     then
                        Emit_Array_Datum (Item);
                     else
                        Emit_Reserved (Item, Landin.Targets.Byte_Count
                          (Landin.Targets.Bytes
                          (Size_Of (Landin.IR.Result_Of (Of_Unit, Item),
                            Facts))),
                          Landin.Targets.Alignment_Of (Facts,
                            Size_Of (Landin.IR.Result_Of (Of_Unit, Item),
                              Facts)));
                     end if;
                  elsif Landin.IR.Result_Of (Of_Unit, Item) =
                    Landin.Types.Aggregate
                  then
                     Emit_Recursive_Image_Datum (Item);
                  elsif Landin.IR.Has_Slice_Image (Of_Unit, Item) then
                     Emit_Slice_Image_Datum (Item);
                  elsif Landin.IR.Result_Of (Of_Unit, Item) =
                    Landin.Types.Fixed_Array
                  then
                     Emit_Array_Image_Datum (Item);
                  else
                     Emit_Datum (Item);
                  end if;
               end if;
            end if;
         end;
      end loop;
      if Landin.IR.Evidence_Count (Of_Unit) > 0 then
         Emit (".section __DATA_CONST,__const");
         for Index in 1 .. Landin.IR.Evidence_Count (Of_Unit) loop
            declare
               Id : constant Landin.IR.Evidence_Id := Landin.IR.Evidence_Id
                 (Index);
               Bytes : Landin.Targets.Byte_Count;
               Alignment : Landin.Targets.Byte_Alignment;
            begin
               Field_Extent (Of_Unit, Landin.IR.Evidence_Represented (Of_Unit,
                 Id),
                 Facts, Bytes, Alignment);
               Emit (".balign 8");
               Put (Evidence_Symbol (Id) & ":");
               Emit (".quad " & Trimmed (Landin.Targets.Byte_Count'Image
                 (Bytes)));
               Emit (".quad " & Trimmed (Landin.Targets.Byte_Alignment'Image
                 (Alignment)));
               for Entry_Index in 1 .. Landin.IR.Evidence_Entry_Count
                 (Of_Unit, Id) loop
                  Emit (".quad " & Symbol
                    (Landin.IR.Evidence_Entry_Target (Of_Unit, Id,
                      Entry_Index)));
               end loop;
            end;
         end loop;
      end if;
      if Host_Bridge_Needed then
         Runtime;
      end if;
      if Debug /= null then
         Unbounded.Append (Out_Text, Debug_Sections
           (Of_Unit, Meanings, Names, Facts, Options, Debug.all,
            Local_Prefix, Symbol'Access));
      end if;
      Emit (".subsections_via_symbols");
      Assembly := Out_Text;
   end Emit;

end Landin.Backend.Arm64;
