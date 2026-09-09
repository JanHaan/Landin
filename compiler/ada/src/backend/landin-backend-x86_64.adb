with Ada.Strings.Fixed;

with Landin.Backend.C_ABI;
with Landin.Backend.Work_Arrays;
with Landin.Backend.X86_64.Allocation;
with Landin.Backend.X86_64.Machine;
with Landin.Targets.Layouts;
with Landin.Types;

package body Landin.Backend.X86_64 is

   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Optimization.Objective;
   use type Allocation.Location_Kind;
   use type Landin.Backend.C_ABI.Eightbyte_Class;
   use type Landin.Source.Names.Name_Id;
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
   is (Frame_Is_Addressable
         (Of_Unit, Item, Facts, Landin.Optimization.Reference_Options));

   function Frame_Is_Addressable
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Facts   : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return Boolean
   is
      Largest_Displacement : constant Landin.Targets.Byte_Count :=
        2 ** 31 - 1;
      Layout : Frame;
   begin
      if Landin.IR.Is_External (Of_Unit, Item) then
         return True;
      end if;
      Layout := Allocation.Frame_For
        (Of_Unit, Item, Facts,
         Allocation.Make (Of_Unit, Item, Facts, Options), Options);
      if Extent (Layout) > Largest_Displacement then
         return False;
      end if;
      if Landin.IR.Signature_Of (Of_Unit, Item) /= Landin.IR.No_Signature
        and then Landin.IR.Signature_Uses_C_ABI
          (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item))
        and then C_ABI.Signature_Plan
          (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item), Facts).Stack_Bytes
          > Largest_Displacement - 16
      then
         return False;
      end if;
      --  C passes MEMORY arguments inline rather than as Landin addresses.
      --  A huge module object can therefore fit this frame while its outgoing
      --  stack area cannot be encoded by the baseline displacement form.
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
                  if Landin.IR.Signature_Uses_C_ABI (Of_Unit, Signature)
                    and then C_ABI.Call_Plan
                      (Of_Unit, Item, Value, Facts).Stack_Bytes
                      > Largest_Displacement
                  then
                     return False;
                  end if;
               end;
            end if;
         end;
      end loop;
      return True;
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
   is (Text (Of_Unit, Meanings, Names, Facts,
             Landin.Optimization.Reference_Options, Hosted_Entry));

   function Text
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table;
      Facts    : Landin.Targets.Target_Facts;
      Options  : Landin.Optimization.Options;
      Hosted_Entry : Landin.IR.Item_Id := Landin.IR.No_Item) return String
   is
      Assembly : Unbounded.Unbounded_String;
      Report : Landin.Build_Reports.Report;
   begin
      Emit (Of_Unit, Meanings, Names, Facts, Options, Assembly, Report,
            Hosted_Entry);
      return Unbounded.To_String (Assembly);
   end Text;

   procedure Emit
     (Of_Unit  : Landin.IR.Unit;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table;
      Facts    : Landin.Targets.Target_Facts;
      Options  : Landin.Optimization.Options;
      Assembly : out Unbounded.Unbounded_String;
      Report   : in out Landin.Build_Reports.Report;
      Hosted_Entry : Landin.IR.Item_Id := Landin.IR.No_Item)
   is
      Out_Text : Unbounded.Unbounded_String;
      Optimized : constant Boolean :=
        Options.Optimize /= Landin.Optimization.None;
      Bodies : array (1 .. Landin.IR.Item_Count (Of_Unit)) of
        Unbounded.Unbounded_String;
      Streams : array (1 .. Landin.IR.Item_Count (Of_Unit)) of Machine.Stream;
      Statistics : array (1 .. Landin.IR.Item_Count (Of_Unit)) of
        Landin.Build_Reports.Routine_Statistics;
      Capturing : Landin.IR.Item_Id := Landin.IR.No_Item;
      --  The emission unit is immutable.  Query retained exposure once per
      --  candidate, never inside the pairwise final-body equality proof.
      Shareable : Home_Mask (1 .. Landin.IR.Item_Count (Of_Unit)) :=
        [others => False];

      procedure Put (Line : String);

      procedure Put (Line : String) is
      begin
         if Capturing /= Landin.IR.No_Item and then Line'Length > 0
           and then Line (Line'Last) = ':'
         then
            Machine.Define_Label
              (Streams (Positive (Capturing)),
               Line (Line'First .. Line'Last - 1));
         end if;
         Unbounded.Append (Out_Text, Line & LF);
      end Put;

      procedure Emit (Instruction : String);

      procedure Emit (Instruction : String) is
         Selected : constant String :=
           (if Optimized then Machine.Selected (Instruction) else Instruction);
      begin
         if Selected'Length = 0 then
            return;
         end if;
         if Capturing /= Landin.IR.No_Item
           and then Selected (Selected'First) /= '.'
         then
            Machine.Instruction (Streams (Positive (Capturing)), Selected);
         end if;
         Put (Character'Val (9) & Selected);
      end Emit;

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

      type Hosted_Bridge is
        (Not_A_Bridge, Initialize_Arguments, Argument_Count, Argument_Table,
         Argument_At, Argument_At_From, Text_Length, Open_Read, Open_Write,
         Read_Bytes, Write_Bytes, Close_File, Errno_Value,
         Heap_Allocate, Heap_Release);

      function Bridge_Of (Spelling : String) return Hosted_Bridge
        is (if Spelling = "_landin_host_initialize_arguments"
            then Initialize_Arguments
            elsif Spelling = "_landin_host_argument_count" then Argument_Count
            elsif Spelling = "_landin_host_argument_table" then Argument_Table
            elsif Spelling = "_landin_host_argument_at" then Argument_At
            elsif Spelling = "_landin_host_argument_at_from"
            then Argument_At_From
            elsif Spelling = "_landin_host_text_length" then Text_Length
            elsif Spelling = "_landin_host_open_read" then Open_Read
            elsif Spelling = "_landin_host_open_write" then Open_Write
            elsif Spelling = "_landin_host_read" then Read_Bytes
            elsif Spelling = "_landin_host_write" then Write_Bytes
            elsif Spelling = "_landin_host_close" then Close_File
            elsif Spelling = "_landin_host_errno" then Errno_Value
            elsif Spelling = "_landin_host_heap_allocate" then Heap_Allocate
            elsif Spelling = "_landin_host_heap_release" then Heap_Release
            else Not_A_Bridge);

      function Is_Hosted_Dependency (Spelling : String) return Boolean
        is (Bridge_Of (Spelling) /= Not_A_Bridge
            or else Spelling = "strlen"
            or else Spelling = "malloc"
            or else Spelling = "free"
            or else Spelling = "open"
            or else Spelling = "read"
            or else Spelling = "write"
            or else Spelling = "close"
            or else Spelling = "__errno_location");

      function Is_Forced (Item : Landin.IR.Item_Id) return Boolean
        is (Landin.IR.Link_Symbol (Of_Unit, Item)
              /= Landin.Source.Names.No_Name
            or else Item = Hosted_Entry
            or else Landin.IR.Is_External (Of_Unit, Item));

      --  Explicit ELF spellings may start with `.L` too.  Pick a disjoint
      --  prefix for every generated local label (blocks, evidence, anonymous
      --  data and bridge state), rather than reserving a new source-language
      --  namespace.  Most units retain exactly the original `.L` spelling.
      function Unused_Local_Prefix return String;

      function Unused_Local_Prefix return String is
         Candidate : Unbounded.Unbounded_String :=
           Unbounded.To_Unbounded_String (".L");
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

      --  `$` is part of the requested ELF identity but starts an AT&T
      --  immediate operand.  Quote at the rendering seam, not in the symbol
      --  table: calls, addresses, data relocations and directives all use this
      --  spelling, while namespace comparisons keep the unquoted identity.
      function Symbol (Item : Landin.IR.Item_Id) return String is
         Spelling : constant String :=
           Unbounded.To_String (Allocated_Symbols (Positive (Item)));
      begin
         if Spelling'Length = 0 then
            raise Landin.Compiler_Defect with
              "an unallocated linker symbol reached assembly rendering";
         elsif Spelling (Spelling'First) = '$' then
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
      function Final_Bodies_Can_Share
        (Left, Right : Landin.IR.Item_Id) return Boolean;

      function Final_Bodies_Can_Share
        (Left, Right : Landin.IR.Item_Id) return Boolean
      is
      begin
         if not Optimized then
            return Routines_Can_Share (Left, Right);
         end if;
         return Shareable (Positive (Left))
           and then Shareable (Positive (Right))
           and then Signatures_Have_One_ABI
             (Landin.IR.Signature_Of (Of_Unit, Left),
              Landin.IR.Signature_Of (Of_Unit, Right),
              Landin.IR.Signature_Count (Of_Unit) + 1)
           and then Machine.Equivalent
             (Streams (Positive (Left)), Streams (Positive (Right)));
      end Final_Bodies_Can_Share;

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
                 and then A.Nominal = B.Nominal
                 and then
                   ((A.Element_Shape.Kind = Landin.IR.Scalar_Field_Shape
                     and then B.Element_Shape.Kind
                       = Landin.IR.Scalar_Field_Shape)
                    or else Landin.IR.Same_Shape
                      (Of_Unit, A.Element_Shape, B.Element_Shape));
            end if;
            return True;
         end Parts_Agree;
      begin
         if Left = Right then
            return True;
         elsif Limit = 0
           or else Landin.IR.Signature_Uses_C_ABI (Of_Unit, Left)
             /= Landin.IR.Signature_Uses_C_ABI (Of_Unit, Right)
           or else Landin.IR.Signature_Has_Erased_Self (Of_Unit, Left)
             /= Landin.IR.Signature_Has_Erased_Self (Of_Unit, Right)
           or else Landin.IR.Signature_Is_Variadic (Of_Unit, Left)
             /= Landin.IR.Signature_Is_Variadic (Of_Unit, Right)
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
                    and then
                      (Landin.IR.Evidence_Is_Erased
                         (Of_Unit, Landin.IR.Evidence_Of (Of_Unit, Left, A))
                       or else Landin.IR.Evidence_Is_Erased
                         (Of_Unit, Landin.IR.Evidence_Of (Of_Unit, Right, B))
                       or else Landin.IR.Evidence_Entry_Of
                         (Of_Unit, Left, A)
                           /= Landin.IR.Evidence_Entry_Of (Of_Unit, Right, B))
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
         Allocation_Plan : constant Allocation.Plan :=
           Allocation.Make (Of_Unit, Item, Facts, Options);
         Layout : constant Frame := Allocation.Frame_For
           (Of_Unit, Item, Facts, Allocation_Plan, Options);
         Result : constant Landin.Types.Type_Kind :=
           Landin.IR.Result_Of (Of_Unit, Item);
         type Use_Counts is array (Positive range <>) of Natural;
         package Use_Buffers is new Work_Arrays (Natural, Use_Counts, 0);
         Use_Data : Use_Buffers.Buffer
           (if Optimized then Landin.IR.Value_Count (Of_Unit, Item) else 0);
         Uses : Use_Counts renames Use_Data.Data.all;
         Current_Block : Landin.IR.Block_Id := Landin.IR.No_Block;
         Next_Instruction : Landin.IR.Value_Id := Landin.IR.No_Value;
         Fused_Branch : Landin.IR.Value_Id := Landin.IR.No_Value;

         function Size_Of_Value
           (Value : Landin.IR.Value_Id) return Held_Size
           is (Size_Of
                 (Landin.IR.Result_Of (Of_Unit, Item, Value), Facts));

         function Size_Of_Slot (Slot : Landin.IR.Slot_Id) return Held_Size
           is (Size_Of (Landin.IR.Type_Of (Of_Unit, Item, Slot), Facts));

         --  Locations retain their carrier width.  A byte projection is
         --  explicit (not a qword register accidentally used by movb); an
         --  address query is separate and refuses an unhomed register.
         function Value_Operand
           (Value : Landin.IR.Value_Id; Width : Held_Size) return String;
         function Value_Operand (Value : Landin.IR.Value_Id) return String
           is (Value_Operand (Value, Size_Of_Value (Value)));
         function Value_Address (Value : Landin.IR.Value_Id) return String;
         function Slot_Cell (Slot : Landin.IR.Slot_Id) return String;
         function Slot_Address (Slot : Landin.IR.Slot_Id) return String;
         procedure Load_Value (Value : Landin.IR.Value_Id);
         procedure Store_Value (Value : Landin.IR.Value_Id; From : String);

         function Value_Operand
           (Value : Landin.IR.Value_Id; Width : Held_Size) return String
         is
            Place : Allocation.Location renames
              Allocation_Plan.Value (Positive (Value));
         begin
            if Width > Place.Size or else Place.Kind = Allocation.Absent then
               raise Landin.Compiler_Defect with
                 "invalid value location width";
            elsif Place.Kind = Allocation.GP then
               return Allocation.Name (Place.Register, Width);
            end if;
            return Cell (Value_Offset (Layout, Value));
         end Value_Operand;

         function Value_Address (Value : Landin.IR.Value_Id) return String is
         begin
            if Allocation_Plan.Value (Positive (Value)).Kind
                 /= Allocation.Stack
              or else not Has_Value_Home (Layout, Value)
            then
               raise Landin.Compiler_Defect with
                 "an unhomed value was addressed";
            end if;
            return Cell (Value_Offset (Layout, Value));
         end Value_Address;

         function Slot_Cell (Slot : Landin.IR.Slot_Id) return String is
            Place : Allocation.Location renames
              Allocation_Plan.Slot (Positive (Slot));
         begin
            if Place.Kind = Allocation.GP then
               return Allocation.Name (Place.Register, Place.Size);
            end if;
            return Cell (Slot_Offset (Layout, Slot));
         end Slot_Cell;

         function Slot_Address (Slot : Landin.IR.Slot_Id) return String is
         begin
            if not Has_Slot_Home (Layout, Slot) then
               raise Landin.Compiler_Defect with
                 "an unhomed slot was addressed";
            end if;
            return Cell (Slot_Offset (Layout, Slot));
         end Slot_Address;

         procedure Load_Value (Value : Landin.IR.Value_Id) is
            Held : constant Held_Size := Size_Of_Value (Value);
         begin
            Emit ("mov" & Suffix (Held) & " " & Value_Operand (Value)
                  & ", " & Accumulator (Held));
         end Load_Value;

         procedure Store_Value (Value : Landin.IR.Value_Id; From : String) is
            Held : constant Held_Size := Size_Of_Value (Value);
         begin
            --  AH cannot be encoded with any REX prefix.  The allocator's
            --  high registers require one even for a one-byte destination.
            if From = "%ah"
              and then Allocation_Plan.Value (Positive (Value)).Kind
                = Allocation.GP
            then
               Emit ("movb %ah, %al");
               Emit ("movb %al, " & Value_Operand (Value));
            else
               Emit ("mov" & Suffix (Held) & " " & From & ", "
                     & Value_Operand (Value));
            end if;
         end Store_Value;

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
                     Plan : constant Landin.Targets.Layouts.Plan :=
                       Aggregate_Layout (Of_Unit, Reached, Facts);
                  begin
                     Total := Total + Plan.Offsets (Positive (Step.Field));
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
           is (Local_Prefix & Trimmed (Landin.IR.Item_Id'Image (Item))
               & "_V" & Trimmed (Landin.IR.Value_Id'Image (Value)));

         --  A move through the accumulator, at one width.  Every value
         --  that crosses an instruction crosses it this way.
         procedure Carry (Size : Held_Size; From, To : String);

         procedure Carry (Size : Held_Size; From, To : String) is
         begin
            if Optimized and then From = To then
               return;
            elsif Optimized
              and then (From (From'First) = '%' or else To (To'First) = '%')
            then
               Emit ("mov" & Suffix (Size) & " " & From & ", " & To);
            else
               Emit ("mov" & Suffix (Size) & " " & From & ", "
                     & Accumulator (Size));
               Emit ("mov" & Suffix (Size) & " " & Accumulator (Size)
                     & ", " & To);
            end if;
         end Carry;

         --  Chunk transport never touches argument or result registers as
         --  scratch.  %r11 is the object base and %r10 holds one eightbyte.
         --  Partial final chunks read/write only bytes inside the object.
         function Displacement
           (Offset : Landin.Targets.Byte_Count; Base : String) return String
           is (Trimmed (Landin.Targets.Byte_Count'Image (Offset))
               & "(" & Base & ")");

         function Chunk_Bytes
           (Shape : C_ABI.Classification; Index : Positive)
            return Landin.Targets.Byte_Count
           is (Landin.Targets.Byte_Count'Min
                 (8, Shape.Size - Landin.Targets.Byte_Count (Index - 1) * 8));

         function C_Register
           (Place : C_ABI.Location;
            Index : Positive;
            Returning : Boolean := False) return String
           is (if Place.Shape.Classes (Index) = C_ABI.SSE_Class
               then "%xmm" & Trimmed
                 (Natural'Image (Place.Registers (Index) - 1))
               elsif Returning
               then (if Place.Registers (Index) = 1
                     then "%rax" else "%rdx")
               else Argument_Register
                 (Place.Registers (Index), Landin.Targets.Byte_8));

         procedure Load_C_Chunk
           (Offset, Bytes : Landin.Targets.Byte_Count);
         procedure Store_C_Chunk
           (Offset, Bytes : Landin.Targets.Byte_Count);
         procedure Extend_C_Integer
           (Kind : Landin.Types.Type_Kind);
         procedure Reserve_Stack
           (Bytes : Landin.Targets.Byte_Count; Identity : String);
         procedure Emit_C_Entry;
         procedure Emit_C_Call (Value : Landin.IR.Value_Id);
         procedure Emit_C_Result (Value : Landin.IR.Value_Id);

         procedure Load_C_Chunk
           (Offset, Bytes : Landin.Targets.Byte_Count) is
         begin
            if Bytes = 8 then
               Emit ("movq " & Displacement (Offset, "%r11") & ", %r10");
            elsif Bytes = 4 then
               Emit ("movl " & Displacement (Offset, "%r11") & ", %r10d");
            elsif Bytes = 2 then
               Emit ("movzwq " & Displacement (Offset, "%r11") & ", %r10");
            elsif Bytes = 1 then
               Emit ("movzbq " & Displacement (Offset, "%r11") & ", %r10");
            else
               Emit ("xorq %r10, %r10");
               for Byte in reverse 0 .. Bytes - 1 loop
                  Emit ("shlq $8, %r10");
                  Emit ("movb " & Displacement (Offset + Byte, "%r11")
                        & ", %r10b");
               end loop;
            end if;
         end Load_C_Chunk;

         procedure Store_C_Chunk
           (Offset, Bytes : Landin.Targets.Byte_Count) is
         begin
            if Bytes = 8 then
               Emit ("movq %r10, " & Displacement (Offset, "%r11"));
            elsif Bytes = 4 then
               Emit ("movl %r10d, " & Displacement (Offset, "%r11"));
            elsif Bytes = 2 then
               Emit ("movw %r10w, " & Displacement (Offset, "%r11"));
            elsif Bytes = 1 then
               Emit ("movb %r10b, " & Displacement (Offset, "%r11"));
            else
               for Byte in 0 .. Bytes - 1 loop
                  Emit ("movb %r10b, "
                        & Displacement (Offset + Byte, "%r11"));
                  Emit ("shrq $8, %r10");
               end loop;
            end if;
         end Store_C_Chunk;

         procedure Extend_C_Integer
           (Kind : Landin.Types.Type_Kind) is
         begin
            case Kind is
               when Landin.Types.I8 => Emit ("movsbl %r10b, %r10d");
               when Landin.Types.I16 => Emit ("movswl %r10w, %r10d");
               when others => null;
            end case;
         end Extend_C_Integer;

         procedure Emit_C_Entry is
            Plan : constant C_ABI.Plan := C_ABI.Signature_Plan
              (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item), Facts);
            Hidden : constant Natural :=
              (if Plan.Result.Shape.Aggregate then 1 else 0);
            Saved_Bytes : constant Landin.Targets.Byte_Count := 112;
         begin
            --  Save both banks before a copy or partial-chunk helper can
            --  clobber them.  This temporary area does not become IR state.
            Reserve_Stack (Saved_Bytes, "c_entry");
            for Index in 1 .. 6 loop
               Emit ("movq "
                     & Argument_Register (Index, Landin.Targets.Byte_8)
                     & ", " & Displacement
                       (Landin.Targets.Byte_Count (Index - 1) * 8, "%rsp"));
            end loop;
            for Index in 1 .. 8 loop
               Emit ("movq %xmm" & Trimmed (Natural'Image (Index - 1))
                     & ", " & Displacement
                       (48 + Landin.Targets.Byte_Count (Index - 1) * 8,
                        "%rsp"));
            end loop;
            if Hidden = 1 then
               if Plan.Result.Shape.Memory then
                  Emit ("movq 0(%rsp), %r10");
               else
                  Emit ("leaq " & Slot_Address
                        (Landin.IR.Result_Slot (Of_Unit, Item))
                        & ", %r10");
               end if;
               Emit ("movq %r10, " & Slot_Cell
                     (Landin.IR.Nth_Parameter (Of_Unit, Item, 1)));
            end if;
            for Index in Plan.Arguments'Range loop
               declare
                  Place : C_ABI.Location renames Plan.Arguments (Index);
                  Slot : constant Landin.IR.Slot_Id :=
                    Landin.IR.Nth_Parameter (Of_Unit, Item, Index + Hidden);
               begin
                  if Place.On_Stack then
                     Emit ("leaq " & Displacement
                           (16 + Place.Stack_At, "%rbp") & ", %rsi");
                     Emit ("leaq " & Slot_Address (Slot) & ", %rdi");
                     Emit ("movabsq $" & Trimmed
                           (Landin.Targets.Byte_Count'Image (Place.Shape.Size))
                           & ", %rcx");
                     Emit ("cld");
                     Emit ("rep movsb");
                  else
                     Emit ("leaq " & Slot_Address (Slot) & ", %r11");
                     for Chunk in 1 .. Place.Shape.Count loop
                        if Place.Shape.Classes (Chunk) /= C_ABI.No_Class then
                           Emit ("movq " & Displacement
                                 ((if Place.Shape.Classes (Chunk)
                                       = C_ABI.SSE_Class
                                   then Landin.Targets.Byte_Count'(48)
                                   else Landin.Targets.Byte_Count'(0))
                                  + Landin.Targets.Byte_Count
                                    (Place.Registers (Chunk) - 1) * 8,
                                  "%rsp") & ", %r10");
                           Store_C_Chunk
                             (Landin.Targets.Byte_Count (Chunk - 1) * 8,
                              Chunk_Bytes (Place.Shape, Chunk));
                        end if;
                     end loop;
                  end if;
               end;
            end loop;
            Emit ("addq $" & Trimmed
                  (Landin.Targets.Byte_Count'Image (Saved_Bytes)) & ", %rsp");
         end Emit_C_Entry;

         procedure Emit_C_Call (Value : Landin.IR.Value_Id) is
            Indirect : constant Boolean :=
              Landin.IR.Op_Of (Of_Unit, Item, Value) = Landin.IR.Indirect_Call;
            Signature : constant Landin.IR.Signature_Id :=
              (if Indirect then Landin.IR.Call_Signature (Of_Unit, Item, Value)
               else Landin.IR.Signature_Of
                 (Of_Unit, Landin.IR.Callee_Of (Of_Unit, Item, Value)));
            Plan : constant C_ABI.Plan :=
              C_ABI.Call_Plan (Of_Unit, Item, Value, Facts);
            Hidden : constant Natural :=
              (if Plan.Result.Shape.Aggregate then 1 else 0);
            Offset : constant Natural := (if Indirect then 1 else 0);

            function Argument (Index : Positive) return Landin.IR.Value_Id
              is (Landin.IR.Nth_Operand
                    (Of_Unit, Item, Value, Index + Offset + Hidden));
         begin
            Reserve_Stack
              (Plan.Stack_Bytes, "call_"
               & Trimmed (Landin.IR.Value_Id'Image (Value)));
            --  Copy stack objects before filling either register bank.
            for Index in Plan.Arguments'Range loop
               declare
                  Place : C_ABI.Location renames Plan.Arguments (Index);
               begin
                  if Place.On_Stack then
                     if Place.Shape.Aggregate then
                        Emit ("movq " & Value_Operand (Argument (Index))
                              & ", %rsi");
                        Emit ("leaq " & Displacement
                              (Place.Stack_At, "%rsp") & ", %rdi");
                        Emit ("movabsq $" & Trimmed
                              (Landin.Targets.Byte_Count'Image
                                 (Place.Shape.Size)) & ", %rcx");
                        Emit ("cld");
                        Emit ("rep movsb");
                     else
                        Emit ("leaq " & Value_Address (Argument (Index))
                              & ", %r11");
                        Load_C_Chunk (0, Place.Shape.Size);
                        Extend_C_Integer
                          (Landin.IR.Result_Of
                             (Of_Unit, Item, Argument (Index)));
                        Emit ("movq %r10, "
                              & Displacement (Place.Stack_At, "%rsp"));
                     end if;
                  end if;
               end;
            end loop;
            if Plan.Result.Shape.Memory then
               Emit ("movq " & Value_Operand
                     (Landin.IR.Nth_Operand
                        (Of_Unit, Item, Value, Offset + 1)) & ", %rdi");
            end if;
            for Index in Plan.Arguments'Range loop
               declare
                  Place : C_ABI.Location renames Plan.Arguments (Index);
               begin
                  if not Place.On_Stack then
                     Emit ((if Place.Shape.Aggregate
                            then "movq " & Value_Operand (Argument (Index))
                            else "leaq " & Value_Address (Argument (Index)))
                           & ", %r11");
                     for Chunk in 1 .. Place.Shape.Count loop
                        if Place.Shape.Classes (Chunk) /= C_ABI.No_Class
                        then
                           Load_C_Chunk
                             (Landin.Targets.Byte_Count (Chunk - 1) * 8,
                              Chunk_Bytes (Place.Shape, Chunk));
                           if not Place.Shape.Aggregate then
                              Extend_C_Integer
                                (Landin.IR.Result_Of
                                   (Of_Unit, Item, Argument (Index)));
                           end if;
                           Emit ("movq %r10, " & C_Register (Place, Chunk));
                        end if;
                     end loop;
                  end if;
               end;
            end loop;
            if Landin.IR.Signature_Is_Variadic (Of_Unit, Signature) then
               Emit ("movb $" & Trimmed (Natural'Image (Plan.SSE_Used))
                     & ", %al");
            end if;
            if Indirect then
               Emit ("call *" & Value_Operand
                     (Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1)));
            else
               Emit ("call " & Symbol
                     (Landin.IR.Callee_Of (Of_Unit, Item, Value)));
            end if;
            if not Plan.Result.Shape.Memory
              and then Plan.Result.Shape.Size > 0
            then
               if Hidden = 1 then
                  Emit ("movq " & Value_Operand
                        (Landin.IR.Nth_Operand
                           (Of_Unit, Item, Value, Offset + 1)) & ", %r11");
               else
                  Emit ("leaq " & Value_Address (Value) & ", %r11");
               end if;
               for Chunk in 1 .. Plan.Result.Shape.Count loop
                  if Plan.Result.Shape.Classes (Chunk) /= C_ABI.No_Class
                  then
                     Emit ("movq " & C_Register
                           (Plan.Result, Chunk, Returning => True)
                           & ", %r10");
                     Store_C_Chunk
                       (Landin.Targets.Byte_Count (Chunk - 1) * 8,
                        Chunk_Bytes (Plan.Result.Shape, Chunk));
                  end if;
               end loop;
            end if;
            if Plan.Stack_Bytes > 0 then
               Emit ("addq $" & Trimmed
                     (Landin.Targets.Byte_Count'Image (Plan.Stack_Bytes))
                     & ", %rsp");
            end if;
         end Emit_C_Call;

         procedure Emit_C_Result (Value : Landin.IR.Value_Id) is
            Plan : constant C_ABI.Plan := C_ABI.Signature_Plan
              (Of_Unit, Landin.IR.Signature_Of (Of_Unit, Item), Facts);
            Place : C_ABI.Location renames Plan.Result;
         begin
            if Place.Shape.Size = 0 then
               return;
            elsif Place.Shape.Memory then
               Emit ("movq " & Slot_Cell
                     (Landin.IR.Nth_Parameter (Of_Unit, Item, 1)) & ", %rdi");
               Emit ("leaq " & Slot_Address
                     (Landin.IR.Result_Slot (Of_Unit, Item)) & ", %rsi");
               Emit ("movabsq $" & Trimmed
                     (Landin.Targets.Byte_Count'Image (Place.Shape.Size))
                     & ", %rcx");
               Emit ("cld");
               Emit ("rep movsb");
               Emit ("movq " & Slot_Cell
                     (Landin.IR.Nth_Parameter (Of_Unit, Item, 1)) & ", %rax");
               return;
            elsif Place.Shape.Aggregate then
               Emit ("leaq " & Slot_Address
                     (Landin.IR.Result_Slot (Of_Unit, Item)) & ", %r11");
            else
               Emit ("leaq " & Value_Address
                     (Landin.IR.Nth_Operand (Of_Unit, Item, Value, 1))
                     & ", %r11");
            end if;
            for Chunk in 1 .. Place.Shape.Count loop
               if Place.Shape.Classes (Chunk) /= C_ABI.No_Class then
                  Load_C_Chunk
                    (Landin.Targets.Byte_Count (Chunk - 1) * 8,
                     Chunk_Bytes (Place.Shape, Chunk));
                  if not Place.Shape.Aggregate then
                     Extend_C_Integer (Result);
                  end if;
                  Emit ("movq %r10, "
                        & C_Register (Place, Chunk, Returning => True));
               end if;
            end loop;
         end Emit_C_Result;

         --  Linux stack growth touches at most 4096 bytes apart.  R11 is
         --  scratch at each reservation boundary; argument banks, R10 failure
         --  state and allocated callee-saves remain live and untouched.
         procedure Reserve_Stack
           (Bytes : Landin.Targets.Byte_Count; Identity : String)
         is
            Pages : constant Landin.Targets.Byte_Count := Bytes / 4096;
            Partial : constant Landin.Targets.Byte_Count := Bytes mod 4096;
            Loop_Label : constant String := Local_Prefix
              & Trimmed (Landin.IR.Item_Id'Image (Item))
              & "_probe_" & Identity;
         begin
            --  A small frame may not have touched its bottom yet.  Anchor
            --  outgoing probing there before two individually small reserves
            --  could combine into an unprobed page.  Stack extents are aligned
            --  to 16, so a remaining sub-page run plus CALL's push stays below
            --  4096.  Tiny leaves retain the reference prologue unchanged.
            if Identity /= "frame" and then Extent (Layout) < 4096
              and then Extent (Layout) + Bytes >= 4096
            then
               Emit ("orq $0, (%rsp)");
            end if;
            if Bytes = 0 then
               return;
            elsif Pages = 0 then
               Emit ("subq $" & Trimmed
                     (Landin.Targets.Byte_Count'Image (Bytes)) & ", %rsp");
               return;
            end if;
            Emit ("leaq -" & Trimmed
                  (Landin.Targets.Byte_Count'Image (Pages * 4096))
                  & "(%rsp), %r11");
            Put (Loop_Label & ":");
            Emit ("subq $4096, %rsp");
            Emit ("orq $0, (%rsp)");
            Emit ("cmpq %r11, %rsp");
            Emit ("jne " & Loop_Label);
            if Partial > 0 then
               Emit ("subq $" & Trimmed
                     (Landin.Targets.Byte_Count'Image (Partial)) & ", %rsp");
               Emit ("orq $0, (%rsp)");
            end if;
         end Reserve_Stack;

         procedure Emit_Epilogue;

         procedure Emit_Epilogue is
         begin
            for Register in Allocation.Saved_Register loop
               if Allocation_Plan.Used (Register) then
                  Emit ("movq " & Cell (Save_Offset
                        (Layout, Allocation.Save_Index
                           (Allocation_Plan, Register))) & ", "
                        & Allocation.Name (Register, Landin.Targets.Byte_8));
               end if;
            end loop;
            Emit ("movq %rbp, %rsp");
            Emit ("popq %rbp");
            Emit ("ret");
         end Emit_Epilogue;

         procedure Conditional_Branch
           (Condition : String; Yes, No : Landin.IR.Block_Id);

         procedure Conditional_Branch
           (Condition : String; Yes, No : Landin.IR.Block_Id)
         is
            Following : constant Landin.IR.Block_Id := Current_Block + 1;
            Inverse : constant String :=
              (if Condition = "e" then "ne"
               elsif Condition = "ne" then "e"
               elsif Condition = "l" then "ge"
               elsif Condition = "le" then "g"
               elsif Condition = "g" then "le"
               elsif Condition = "ge" then "l"
               elsif Condition = "b" then "ae"
               elsif Condition = "be" then "a"
               elsif Condition = "a" then "be"
               elsif Condition = "ae" then "b"
               else raise Landin.Compiler_Defect with
                 "unknown branch condition");
         begin
            if Optimized and then Yes = Following then
               Emit ("j" & Inverse & " " & Label (Item, No));
            else
               Emit ("j" & Condition & " " & Label (Item, Yes));
               if not Optimized or else No /= Following then
                  Emit ("jmp " & Label (Item, No));
               end if;
            end if;
         end Conditional_Branch;

         procedure Emit_Instruction (Value : Landin.IR.Value_Id);

         procedure Emit_Instruction (Value : Landin.IR.Value_Id) is
            Op : constant Landin.IR.Opcode :=
              Landin.IR.Op_Of (Of_Unit, Item, Value);

            --  D187: this instruction is lexically inside [1120]'s region,
            --  so the edges that decision names are not emitted for it.
            --  Every other edge below is emitted whatever this says --
            --  a divisor, a shift count, a float or bool conversion and a
            --  text boundary keep their trap because their behaviour
            --  without one is not one thing on every target Landin
            --  describes.
            Unchecked : constant Boolean :=
              Landin.IR.Is_Unchecked (Of_Unit, Item, Value);

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
                           & Value_Operand (Value));
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
                           & Value_Operand (Value));
                     end;
                  end;

               when Landin.IR.Truth =>
                  --  [1870]'s two literals, and the one byte
                  --  Landin.Backend gives a bool.
                  Emit ("movb $"
                        & (if Landin.IR.Truth_Of (Of_Unit, Item, Value)
                           then "1" else "0")
                        & ", " & Value_Operand (Value));

               when Landin.IR.Atom =>
                  Emit
                    ("movl $"
                     & Trimmed
                         (Positive'Image
                            (Atom_Code
                               (Of_Unit,
                                Landin.IR.Atom_Of
                                  (Of_Unit, Item, Value))))
                     & ", " & Value_Operand (Value));

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
                       (Landin.Targets.Byte_8, "%rax", Value_Operand (Value));
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
                           Value_Operand (Value));
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
                           Emit ("movq " & Value_Operand (Index) & ", %rax");
                           --  D187 leaves the access at the computed
                           --  address, which is [0430]'s existing pointer
                           --  non-guarantee and nothing worse.
                           if not Unchecked then
                              Emit
                                ("movabsq $"
                                 & Trimmed
                                     (Landin.IR.Element_Total'Image
                                        (Length))
                                 & ", %rdx");
                              Emit ("cmpq %rdx, %rax");
                              Emit ("jb " & Safe);
                              Emit ("ud2");
                              Put (Safe & ":");
                           end if;
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
                              Value_Operand (Value));
                        end;
                     end if;
                  end;

               when Landin.IR.Pointer_Address =>
                  Carry
                    (Landin.Targets.Byte_8,
                     Value_Operand (Operand (1)), Value_Operand (Value));

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
                                (Size_Of (From, Facts), Value_Operand (Source),
                                 Value_Operand (Value));
                           elsif From = Landin.Types.F32 then
                              Emit
                                ("movss " & Value_Operand (Source)
                                 & ", %xmm0");
                              Emit ("cvtss2sd %xmm0, %xmm0");
                              Emit
                                ("movsd %xmm0, " & Value_Operand (Value));
                           else
                              declare
                                 Safe : constant String :=
                                   Value_Label (Value) & "_finite";
                              begin
                                 Emit
                                   ("movsd " & Value_Operand (Source)
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
                                   ("movq " & Value_Operand (Source)
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
                                   ("movss %xmm0, " & Value_Operand (Value));
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
                           Emit ("movb " & Value_Operand (Source) & ", %al");
                           Emit (Convert & " %rax, %xmm0");
                           Emit
                             (Store & " %xmm0, " & Value_Operand (Value));
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
                                 & Value_Operand (Source) & ", %rax");
                           else
                              Emit ("movq $0, %rax");
                              Emit ("mov" & Suffix (From_Size) & " "
                                    & Value_Operand (Source) & ", "
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
                             (Store & " %xmm0, " & Value_Operand (Value));
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
                                 & Value_Operand (Source)
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
                                ("movb %al, " & Value_Operand (Value));
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
                                    & Value_Operand (Source) & ", "
                                    & Accumulator (From_Size));
                              Emit ("cmpq $1, %rax");
                              Emit ("jbe " & Safe);
                              Emit ("ud2");
                              Put (Safe & ":");
                              Emit
                                ("movb %al, " & Value_Operand (Value));
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
                             ("movb " & Value_Operand (Source) & ", %al");
                           Emit ("mov" & Suffix (Into_Size) & " "
                                 & Accumulator (Into_Size) & ", "
                                 & Value_Operand (Value));
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
                              & Value_Operand (Source)
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
                                 & Value_Operand (Value));
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
                                 & Value_Operand (Source) & ", %rax");
                           else
                              Emit ("movq $0, %rax");
                              Emit ("mov" & Suffix (From_Size) & " "
                                    & Value_Operand (Source) & ", "
                                    & Accumulator (From_Size));
                           end if;

                           --  D187 removes the destination-range edge of
                           --  an integer-to-integer conversion only.  The
                           --  narrowing store below already keeps the
                           --  low-order bits of the source, which is the
                           --  one result every target gives.
                           if Unchecked then
                              null;
                           elsif Landin.Types.Is_Signed (Into_Type) then
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

                           if not Unchecked
                             and then not Landin.Types.Is_Signed (Into_Type)
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
                                 & Value_Operand (Value));
                        end;
                     end if;
                  end;

               when Landin.IR.Range_Check =>
                  --  D188/[0660].  Source and result are one type, so this
                  --  neither widens nor narrows: it widens to the
                  --  accumulator in that type's own signedness, compares
                  --  against the two folded bounds, and passes the value
                  --  through.  [1120]'s region does not reach it: a value
                  --  outside the bounds is not one the destination holds,
                  --  so removing the edge would not leave one meaning.
                  declare
                     Source : constant Landin.IR.Value_Id := Operand (1);
                     Kind : constant Landin.Types.Integer_Name :=
                       Landin.Types.Integer_Name
                         (Landin.IR.Result_Of (Of_Unit, Item, Value));
                     Width : constant Held_Size := Size_Of (Kind, Facts);
                     Lower : constant Landin.Types.Folded :=
                       Landin.IR.Range_Lower (Of_Unit, Item, Value);
                     Upper : constant Landin.Types.Folded :=
                       Landin.IR.Range_Upper (Of_Unit, Item, Value);
                     Signed : constant Boolean :=
                       Landin.Types.Is_Signed (Kind);
                     Safe_Lower : constant String :=
                       Value_Label (Value) & "_lower";
                     Safe_Upper : constant String :=
                       Value_Label (Value) & "_upper";
                  begin
                     if Signed then
                        Emit
                          ((case Width is
                              when Landin.Targets.Byte_1 => "movsbq ",
                              when Landin.Targets.Byte_2 => "movswq ",
                              when Landin.Targets.Byte_4 => "movslq ",
                              when Landin.Targets.Byte_8 => "movq ")
                           & Value_Operand (Source) & ", %rax");
                     else
                        Emit ("movq $0, %rax");
                        Emit ("mov" & Suffix (Width) & " "
                              & Value_Operand (Source) & ", "
                              & Accumulator (Width));
                     end if;

                     Emit
                       ("movabsq $"
                        & Trimmed (Landin.Types.Folded'Image (Lower))
                        & ", %rcx");
                     Emit ("cmpq %rcx, %rax");
                     Emit ((if Signed then "jge " else "jae ") & Safe_Lower);
                     Emit ("ud2");
                     Put (Safe_Lower & ":");

                     Emit
                       ("movabsq $"
                        & Trimmed (Landin.Types.Folded'Image (Upper))
                        & ", %rcx");
                     Emit ("cmpq %rcx, %rax");
                     Emit ((if Signed then "jle " else "jbe ") & Safe_Upper);
                     Emit ("ud2");
                     Put (Safe_Upper & ":");

                     Emit ("mov" & Suffix (Width) & " "
                           & Accumulator (Width) & ", "
                           & Value_Operand (Value));
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
                     --  D187 removes both range edges together.  The
                     --  text boundary traps of D182--D184 are emitted
                     --  through this same operation and are marked
                     --  required where they are lowered, so they arrive
                     --  here checked whatever region they sit in.
                     if not Unchecked then
                        Emit
                          ("movq " & Value_Operand (Operand (4)) & ", %rax");
                        Emit
                          ("cmpq " & Value_Operand (Operand (2)) & ", %rax");
                        Emit
                          ((if Landin.IR.Slice_Is_Inclusive
                                 (Of_Unit, Item, Value)
                            then "jb " else "jbe ") & Safe_Upper);
                        Emit ("ud2");
                        Put (Safe_Upper & ":");
                     end if;
                     Emit ("movq " & Value_Operand (Operand (3)) & ", %rcx");
                     if not Unchecked then
                        Emit
                          ("cmpq " & Value_Operand (Operand (4)) & ", %rcx");
                        Emit ("jbe " & Safe_Lower);
                        Emit ("ud2");
                        Put (Safe_Lower & ":");
                     end if;
                     if Stride > 1 then
                        Emit
                          ("imulq $"
                           & Trimmed
                               (Landin.Targets.Byte_Count'Image (Stride))
                           & ", %rcx, %rcx");
                     end if;
                     Emit ("movq " & Value_Operand (Operand (1)) & ", %rax");
                     Emit ("addq %rcx, %rax");
                     Carry
                       (Landin.Targets.Byte_8, "%rax", Value_Operand (Value));
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
                        & ", " & Value_Operand (Value));
                  end;

               when Landin.IR.Load_Indirect =>
                  declare
                     Held : constant Held_Size := Size_Of_Value (Value);
                  begin
                     Emit ("movq " & Value_Operand (Operand (1)) & ", %rcx");
                     Emit ("mov" & Suffix (Held) & " (%rcx), "
                           & Accumulator (Held));
                     Store_Value (Value, Accumulator (Held));
                  end;

               when Landin.IR.Store_Indirect =>
                  declare
                     Held : constant Held_Size := Size_Of_Value (Operand (2));
                  begin
                     Emit ("movq " & Value_Operand (Operand (1)) & ", %rcx");
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Operand (Operand (2)) & ", "
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
                            Value_Operand (Value));
                  end;

               when Landin.IR.Store =>
                  declare
                     Slot : constant Landin.IR.Slot_Id :=
                       Landin.IR.Slot_Of (Of_Unit, Item, Value);
                  begin
                     Carry (Size_Of_Slot (Slot),
                            Value_Operand (Operand (1)), Slot_Cell (Slot));
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
                     if Optimized and then Landin.IR.Op_Of
                       (Of_Unit, Item, Operand (2)) = Landin.IR.Number
                       and then not Landin.IR.Is_Negated
                         (Of_Unit, Item, Operand (2))
                     then
                        declare
                           Amount : constant Landin.Types.Magnitude :=
                             Landin.IR.Number_Of (Of_Unit, Item, Operand (2));
                        begin
                           if Amount >= Landin.Types.Magnitude (Bits) then
                              Emit ("mov" & Suffix (Held) & " $0, "
                                    & Value_Operand (Value));
                           else
                              Load_Value (Operand (1));
                              if Amount > 0 then
                                 Emit (Instruction & Suffix (Held) & " $"
                                       & Trimmed
                                         (Landin.Types.Magnitude'Image
                                            (Amount))
                                       & ", " & Accumulator (Held));
                              end if;
                              Store_Value (Value, Accumulator (Held));
                           end if;
                           return;
                        end;
                     end if;
                     Emit ("mov" & Suffix (Held) & " "
                           & Value_Operand (Operand (2)) & ", "
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
                           & Value_Operand (Value));
                     Emit ("jmp " & Done);
                     Put (In_Range & ":");

                     --  The count is below the width, so its low byte is the
                     --  whole of it and `%cl` is where a variable count goes.
                     Emit ("movb "
                           & Value_Operand (Operand (2), Landin.Targets.Byte_1)
                           & ", %cl");
                     Load_Value (Operand (1));
                     Emit (Instruction & Suffix (Held) & " %cl, "
                           & Accumulator (Held));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Operand (Value));
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
                           when others =>
                             raise Landin.Compiler_Defect
                               with "an unreachable operator case");
                  begin
                     Load_Value (Operand (1));
                     Emit (Instruction & Suffix (Held) & " "
                           & Value_Operand (Operand (2)) & ", "
                           & Accumulator (Held));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Operand (Value));
                  end;

               when Landin.IR.Logical_Not =>
                  --  [1870] fixes a bool at zero or one, so the low bit is
                  --  the whole value and `not` over the byte would give 254
                  --  for `not false`.
                  Emit ("movb " & Value_Operand (Operand (1)) & ", %al");
                  Emit ("xorb $1, %al");
                  Emit ("movb %al, " & Value_Operand (Value));

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
                              & Value_Operand (Operand (1)) & ", "
                              & Accumulator (Held));
                        Emit
                          ((if Kind = Landin.Types.F32
                            then "xorl $2147483648, %eax"
                            else "btcq $63, %rax"));
                        Emit ("mov" & Suffix (Held) & " "
                              & Accumulator (Held) & ", "
                              & Value_Operand (Value));
                        return;
                     end if;

                     Load_Value (Operand (1));
                     Emit ("neg" & Suffix (Held) & " " & Accumulator (Held));
                     if not Unchecked then
                        Emit ((if Landin.Types.Is_Signed
                                      (Landin.Types.Integer_Name (Kind))
                               then "jno " else "jnc ") & Next);
                        Emit ("ud2");
                        Put (Next & ":");
                     end if;
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Operand (Value));
                  end;

               when Landin.IR.Complement =>
                  --  [0330]'s `~` gives its own type back, so every pattern
                  --  it can produce is one the type holds and no edge is
                  --  needed.
                  declare
                     Held : constant Held_Size := Size_Of_Value (Value);
                  begin
                     Load_Value (Operand (1));
                     Emit ("not" & Suffix (Held) & " " & Accumulator (Held));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Operand (Value));
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
                     Carry (Held, "(%rcx)", Value_Operand (Value));
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
                     Carry (Held, "(%rcx)", Value_Operand (Value));
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
                     Emit ("cld");
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
                     Carry (Held, Value_Operand (Operand (1)), "(%rcx)");
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
                        & Value_Operand (Operand (1)) & ", "
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
                        Carry (Held, Place, Value_Operand (Value));
                     else
                        Carry (Held, Value_Operand (Operand (1)), Place);
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
                     Emit ("movq " & Value_Operand (Index) & ", %rax");
                     if not Unchecked then
                        Emit
                          ("movabsq $"
                           & Trimmed
                               (Landin.IR.Element_Total'Image (Length))
                           & ", %rdx");
                        Emit ("cmpq %rdx, %rax");
                        Emit ("jb " & Safe);
                        Emit ("ud2");
                        Put (Safe & ":");
                     end if;
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
                        Carry (Held, "(%rcx)", Value_Operand (Value));
                     else
                        Carry
                          (Held, Value_Operand (Operand (2)), "(%rcx)");
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
                                   (Held, "(%rcx)", Value_Operand (Value));
                              else
                                 Carry
                                   (Held, Value_Operand (Operand (1)),
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
                              Carry (Held, Place, Value_Operand (Value));
                           else
                              Carry (Held, Value_Operand (Operand (1)), Place);
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
                           Carry (Held, "(%rcx)", Value_Operand (Value));
                        else
                           Carry
                             (Held, Value_Operand (Operand (1)), "(%rcx)");
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
                              Carry (Held, Place, Value_Operand (Value));
                           else
                              Carry
                                (Held, Value_Operand (Operand (1)), Place);
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
                              & Value_Operand (Operand (1)) & ", %xmm0");
                        Emit ((if Op = Landin.IR.Add then "add" else "sub")
                              & (if Kind = Landin.Types.F32
                                 then "ss " else "sd ")
                              & Value_Operand (Operand (2)) & ", %xmm0");
                        Emit ((if Kind = Landin.Types.F32
                               then "movss " else "movsd ")
                              & "%xmm0, " & Value_Operand (Value));
                        return;
                     end if;

                     Load_Value (Operand (1));
                     Emit ((if Op = Landin.IR.Add then "add" else "sub")
                           & Suffix (Held) & " "
                           & Value_Operand (Operand (2)) & ", "
                           & Accumulator (Held));
                     --  D187 leaves [0320]'s two's-complement result in
                     --  the accumulator, which is what the wrapping
                     --  operators already mean on every target.
                     if not Unchecked then
                        Emit ((if Landin.Types.Is_Signed
                                      (Landin.Types.Integer_Name (Kind))
                               then "jno " else "jnc ") & Next);
                        Emit ("ud2");
                        Put (Next & ":");
                     end if;
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Operand (Value));
                  end;

               when Landin.IR.Wrapping_Add
                  | Landin.IR.Wrapping_Subtract =>
                  declare
                     Held : constant Held_Size := Size_Of_Value (Value);
                  begin
                     Load_Value (Operand (1));
                     Emit ((if Op = Landin.IR.Wrapping_Add
                            then "add" else "sub") & Suffix (Held) & " "
                           & Value_Operand (Operand (2)) & ", "
                           & Accumulator (Held));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Operand (Value));
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
                              & Value_Operand (Operand (1)) & ", %xmm0");
                        Emit ((if Kind = Landin.Types.F32
                               then "divss " else "divsd ")
                              & Value_Operand (Operand (2)) & ", %xmm0");
                        Emit ((if Kind = Landin.Types.F32
                               then "movss " else "movsd ")
                              & "%xmm0, " & Value_Operand (Value));
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
                              & Value_Operand (Operand (2)));
                        Emit ("jne " & Nonzero);
                        Emit ("ud2");
                        Put (Nonzero & ":");

                        if Signed then
                           Emit ("cmp" & Suffix (Held) & " $-1, "
                                 & Value_Operand (Operand (2)));
                           Emit ("jne " & Divide);
                           Emit ("movabsq $"
                                 & Trimmed
                                     (Landin.Types.Magnitude'Image
                                        (Minimum_Pattern))
                                 & ", %rax");
                           Emit ("cmp" & Suffix (Held) & " "
                                 & Value_Operand (Operand (1)) & ", "
                                 & Accumulator (Held));
                           Emit ("jne " & Divide);
                           if Op = Landin.IR.Divide then
                              Emit ("ud2");
                           else
                              Emit ("mov" & Suffix (Held) & " $0, "
                                    & Value_Operand (Value));
                              Emit ("jmp " & Done);
                           end if;
                           Put (Divide & ":");
                        end if;

                        Emit ("mov" & Suffix (Held) & " "
                              & Value_Operand (Operand (1)) & ", "
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
                              & Value_Operand (Operand (2)));
                        Store_Value
                          (Value,
                           (if Op = Landin.IR.Divide
                            then Accumulator (Held)
                            else
                              (case Held is
                                  when Landin.Targets.Byte_1 => "%ah",
                                  when Landin.Targets.Byte_2 => "%dx",
                                  when Landin.Targets.Byte_4 => "%edx",
                                  when Landin.Targets.Byte_8 => "%rdx")));
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
                              & Value_Operand (Operand (1)) & ", %xmm0");
                        Emit ((if Kind = Landin.Types.F32
                               then "mulss " else "mulsd ")
                              & Value_Operand (Operand (2)) & ", %xmm0");
                        Emit ((if Kind = Landin.Types.F32
                               then "movss " else "movsd ")
                              & "%xmm0, " & Value_Operand (Value));
                        return;
                     end if;

                     declare
                        Signed : constant Boolean :=
                          Landin.Types.Is_Signed
                            (Landin.Types.Integer_Name (Kind));
                     begin
                        Emit ("mov" & Suffix (Held) & " "
                              & Value_Operand (Operand (1)) & ", "
                              & Accumulator (Held));
                        Emit ((if Signed then "imul" else "mul")
                              & Suffix (Held) & " "
                              & Value_Operand (Operand (2)));
                        if not Unchecked then
                           Emit
                             ((if Signed then "jno " else "jnc ") & Next);
                           Emit ("ud2");
                           Put (Next & ":");
                        end if;
                        Emit ("mov" & Suffix (Held) & " "
                              & Accumulator (Held) & ", "
                              & Value_Operand (Value));
                     end;
                  end;

               when Landin.IR.Wrapping_Multiply =>
                  declare
                     Kind : constant Landin.Types.Integer_Name :=
                       Landin.IR.Result_Of (Of_Unit, Item, Value);
                     Held : constant Held_Size := Size_Of_Value (Value);
                  begin
                     Load_Value (Operand (1));
                     Emit ((if Landin.Types.Is_Signed (Kind)
                            then "imul" else "mul")
                           & Suffix (Held) & " "
                           & Value_Operand (Operand (2)));
                     Emit ("mov" & Suffix (Held) & " "
                           & Accumulator (Held) & ", "
                           & Value_Operand (Value));
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
                           when others =>
                             raise Landin.Compiler_Defect
                               with "an unreachable operator case");
                  begin
                     if Kind in Landin.Types.Float_Name then
                        Emit ((if Kind = Landin.Types.F32
                               then "movss " else "movsd ")
                              & Value_Operand (Operand (1)) & ", %xmm0");
                        Emit ((if Kind = Landin.Types.F32
                               then "ucomiss " else "ucomisd ")
                              & Value_Operand (Operand (2)) & ", %xmm0");
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
                        Emit ("movb %al, " & Value_Operand (Value));
                        return;
                     end if;

                     Load_Value (Operand (1));
                     Emit ("cmp" & Suffix (Held) & " "
                           & Value_Operand (Operand (2)) & ", "
                           & Accumulator (Held));
                     if Optimized and then Uses (Positive (Value)) = 1
                       and then Next_Instruction /= Landin.IR.No_Value
                       and then Landin.IR.Op_Of
                         (Of_Unit, Item, Next_Instruction) = Landin.IR.Branch
                       and then Landin.IR.Nth_Operand
                         (Of_Unit, Item, Next_Instruction, 1) = Value
                     then
                        Conditional_Branch
                          (Condition (Condition'First + 3 .. Condition'Last),
                           Landin.IR.Target_Of
                             (Of_Unit, Item, Next_Instruction),
                           Landin.IR.Alternative_Of
                             (Of_Unit, Item, Next_Instruction));
                        Fused_Branch := Next_Instruction;
                     else
                        Emit (Condition & " %al");
                        Store_Value (Value, "%al");
                     end if;
                  end;

               when Landin.IR.Failure_Test =>
                  Emit ("cmpl $0, " & Value_Operand (Operand (1)));
                  Emit ("setne %al");
                  Emit ("movb %al, " & Value_Operand (Value));

               when Landin.IR.Function_Address =>
                  Emit
                    ("leaq "
                     & Symbol (Landin.IR.Callee_Of (Of_Unit, Item, Value))
                     & "(%rip), %rax");
                  Emit ("movq %rax, " & Value_Operand (Value));

               when Landin.IR.Evidence_Address =>
                  Emit
                    ("leaq "
                     & Evidence_Symbol
                         (Landin.IR.Evidence_Of (Of_Unit, Item, Value))
                     & "(%rip), %rax");
                  Emit ("movq %rax, " & Value_Operand (Value));

               when Landin.IR.Evidence_Function =>
                  declare
                     Which : constant Natural :=
                       Landin.IR.Evidence_Entry_Of (Of_Unit, Item, Value);
                     Offset : constant Landin.Targets.Byte_Count :=
                       Landin.Targets.Evidence_Function_Offset
                         (Facts, Positive (Which));
                  begin
                     Emit ("movq " & Value_Operand (Operand (1)) & ", %rax");
                     if Landin.IR.Evidence_Is_Erased
                       (Of_Unit, Landin.IR.Evidence_Of (Of_Unit, Item, Value))
                     then
                        --  The saved descriptor is data then table. The
                        --  paired self projection reads this same snapshot.
                        Emit ("movq 8(%rax), %rax");
                     end if;
                     Emit
                       ("movq "
                        & Trimmed
                            (Landin.Targets.Byte_Count'Image (Offset))
                        & "(%rax), %rax");
                     Emit ("movq %rax, " & Value_Operand (Value));
                  end;

               when Landin.IR.Evidence_Self =>
                  declare
                     Receiver : constant Landin.IR.Value_Id :=
                       Landin.IR.Nth_Operand
                         (Of_Unit, Item, Operand (1), 1);
                  begin
                     Emit ("movq " & Value_Operand (Receiver) & ", %rax");
                     Emit ("movq (%rax), %rax");
                     Emit ("movq %rax, " & Value_Operand (Value));
                  end;

               when Landin.IR.Call | Landin.IR.Indirect_Call =>
                  if (if Op = Landin.IR.Indirect_Call
                      then Landin.IR.Signature_Uses_C_ABI
                        (Of_Unit,
                         Landin.IR.Call_Signature (Of_Unit, Item, Value))
                      else Is_C_Item
                        (Landin.IR.Callee_Of (Of_Unit, Item, Value)))
                  then
                     Emit_C_Call (Value);
                     return;
                  end if;
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
                     --  A C callee reads a narrow integer argument as the
                     --  32-bit register: GCC and Clang assume the caller
                     --  extended it, and passing only the low byte left the
                     --  upper bits to chance (R4.21).  The internal
                     --  convention keeps the exact width for Landin callees,
                     --  which copy the width they declared.
                     External : constant Boolean :=
                       not Indirect
                       and then Landin.IR.Is_External (Of_Unit, Callee);
                     Count : constant Natural :=
                       Landin.IR.Operand_Count (Of_Unit, Item, Value) - Offset;

                     function Extension
                       (Argument : Landin.IR.Value_Id;
                        Held     : Held_Size;
                        Wide     : Held_Size) return String;

                     function Extension
                       (Argument : Landin.IR.Value_Id;
                        Held     : Held_Size;
                        Wide     : Held_Size) return String
                     is
                        Signed : constant Boolean :=
                          Landin.IR.Result_Of (Of_Unit, Item, Argument)
                            in Landin.Types.I8 | Landin.Types.I16;
                     begin
                        return "mov" & (if Signed then "s" else "z")
                          & Suffix (Held) & Suffix (Wide);
                     end Extension;
                     Stack_Bytes : constant Landin.Targets.Byte_Count :=
                       (if Count <= Register_Arguments then 0
                        else Landin.Targets.Align_Up
                          (Landin.Targets.Byte_Count
                             (Count - Register_Arguments)
                           * Stack_Argument_Bytes,
                           Landin.Targets.Stack_Alignment (Facts)));
                  begin
                     Reserve_Stack
                       (Stack_Bytes, "call_"
                        & Trimmed (Landin.IR.Value_Id'Image (Value)));

                     for Index in 1 .. Count loop
                        declare
                           Argument : constant Landin.IR.Value_Id :=
                             Operand (Index + Offset);
                           Held : constant Held_Size :=
                             Size_Of_Value (Argument);
                           Narrow : constant Boolean :=
                             External
                             and then Held in Landin.Targets.Byte_1
                                              | Landin.Targets.Byte_2;
                        begin
                           if Index <= Register_Arguments then
                              if Narrow then
                                 Emit (Extension
                                         (Argument, Held,
                                          Landin.Targets.Byte_4)
                                       & " " & Value_Operand (Argument) & ", "
                                       & Argument_Register
                                           (Index, Landin.Targets.Byte_4));
                              else
                                 Emit ("mov" & Suffix (Held) & " "
                                       & Value_Operand (Argument) & ", "
                                       & Argument_Register (Index, Held));
                              end if;
                           elsif Narrow then
                              Emit (Extension
                                      (Argument, Held, Landin.Targets.Byte_8)
                                    & " " & Value_Operand (Argument)
                                    & ", %rax");
                              Emit ("movq %rax, "
                                    & Trimmed
                                        (Landin.Targets.Byte_Count'Image
                                           (Landin.Targets.Byte_Count
                                              (Index - Register_Arguments - 1)
                                            * Stack_Argument_Bytes))
                                    & "(%rsp)");
                           else
                              Carry
                                (Held, Value_Operand (Argument),
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
                        Emit ("call *" & Value_Operand (Operand (1)));
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
                                 & Value_Operand (Value));
                        end;
                     end if;
                  end;

               when Landin.IR.Jump =>
                  if not Optimized or else Landin.IR.Target_Of
                    (Of_Unit, Item, Value) /= Current_Block + 1
                  then
                     Emit ("jmp " & Label (Item,
                           Landin.IR.Target_Of (Of_Unit, Item, Value)));
                  end if;

               when Landin.IR.Branch =>
                  if Value /= Fused_Branch then
                     --  A bool is a byte, and zero is [1870]'s false.
                     Emit ("cmpb $0, " & Value_Operand (Operand (1)));
                     Conditional_Branch
                       ("ne", Landin.IR.Target_Of (Of_Unit, Item, Value),
                        Landin.IR.Alternative_Of (Of_Unit, Item, Value));
                  end if;

               when Landin.IR.Leave =>
                  if Is_C_Item (Item) then
                     Emit_C_Result (Value);
                     Emit_Epilogue;
                     return;
                  end if;
                  --  [1810]'s return carries what the named return place
                  --  held; a `-> none` routine carries nothing.
                  if Result in Landin.Types.Scalar_Name then
                     declare
                        Held : constant Held_Size :=
                          Size_Of (Result, Facts);
                     begin
                        Emit ("mov" & Suffix (Held) & " "
                              & Value_Operand (Operand (1)) & ", "
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
                  Emit ("movl " & Value_Operand (Operand (1)) & ", %r10d");
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
         Machine.Start
           (Streams (Positive (Item)), Shareable (Positive (Item)));
         Capturing := Item;

         --  [1550]'s frame pointer, set up before anything reads a cell.
         Emit ("pushq %rbp");
         Emit ("movq %rsp, %rbp");

         --  The hosted entry keeps its source-level no-argument shape.  The
         --  frame-pointer push aligned the stack for this C call, before any
         --  body code can clobber argc/argv.  C-owned startup calls the same
         --  initializer explicitly; ordinary exports and callbacks never do.
         if Item = Hosted_Entry then
            Emit ("call _landin_host_initialize_arguments");
         end if;

         Reserve_Stack (Extent (Layout), "frame");
         for Register in Allocation.Saved_Register loop
            if Allocation_Plan.Used (Register) then
               Emit ("movq "
                     & Allocation.Name (Register, Landin.Targets.Byte_8)
                     & ", " & Cell (Save_Offset
                       (Layout, Allocation.Save_Index
                          (Allocation_Plan, Register))));
            end if;
         end loop;

         if Is_C_Item (Item) then
            Emit_C_Entry;
         else
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
                           Landin.Backend.Field_Extent
                             (Of_Unit,
                              Landin.IR.Whole_Slot_Array_Shape
                                (Of_Unit, Item, Slot),
                              Facts, Bytes, Alignment);
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
         end if;

         for Index in Uses'Range loop
            for Position in 1 .. Landin.IR.Operand_Count
              (Of_Unit, Item, Landin.IR.Value_Id (Index))
            loop
               declare
                  Operand : constant Positive := Positive
                    (Landin.IR.Nth_Operand
                       (Of_Unit, Item, Landin.IR.Value_Id (Index), Position));
               begin
                  Uses (Operand) := Uses (Operand) + 1;
               end;
            end loop;
         end loop;
         for Index in 1 .. Landin.IR.Block_Count (Of_Unit, Item) loop
            declare
               Block : constant Landin.IR.Block_Id :=
                 Landin.IR.Block_Id (Index);
            begin
               Current_Block := Block;
               Put (Label (Item, Block) & ":");

               for Position in 1 .. Landin.IR.Length
                                      (Of_Unit, Item, Block)
               loop
                  Next_Instruction :=
                    (if Position < Landin.IR.Length (Of_Unit, Item, Block)
                     then Landin.IR.Nth_Value
                       (Of_Unit, Item, Block, Position + 1)
                     else Landin.IR.No_Value);
                  Emit_Instruction
                    (Landin.IR.Nth_Value
                       (Of_Unit, Item, Block, Position));
               end loop;
            end;
         end loop;

         Capturing := Landin.IR.No_Item;
         if Shareable (Positive (Item)) then
            Machine.Seal (Streams (Positive (Item)));
         end if;
         Statistics (Positive (Item)) :=
           Machine.Statistics (Streams (Positive (Item)));
         declare
            Counts : Landin.Build_Reports.Routine_Statistics renames
              Statistics (Positive (Item));
         begin
            Counts.Item := Item;
            Counts.Frame_Bytes := Extent (Layout);
            Counts.Spill_Bytes := Spill_Bytes (Layout);
            Counts.Save_Bytes := Save_Bytes (Layout);
            Counts.Register_Count := Allocation.Save_Count (Allocation_Plan);
            Counts.Spill_Count := Allocation_Plan.Spill_Homes;
         end;
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
            Plan : constant Landin.Targets.Layouts.Plan :=
              Aggregate_Layout (Of_Unit, Shape, Facts);
            Child_Written : Landin.Targets.Byte_Count := 0;
            Child_Size : Landin.Targets.Byte_Count;
            Child_Alignment : Landin.Targets.Byte_Alignment;
         begin
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
         Put (Character'Val (9) & ".type " & Symbol (Item) & ", @object");
         Put
           (Character'Val (9) & ".align "
            & Trimmed (Landin.Targets.Byte_Alignment'Image (Alignment)));
         Put (Symbol (Item) & ":");

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
         Put
           (Character'Val (9) & ".size " & Symbol (Item) & ", "
            & Trimmed (Landin.Targets.Byte_Count'Image (Size)));
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
            Bytes : constant String :=
              Trimmed
                (Landin.Targets.Byte_Count'Image
                   (Landin.Targets.Byte_Count (Length)
                    * Landin.Targets.Byte_Count
                        (Landin.Targets.Bytes (Held))));
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

            Put (Character'Val (9) & ".size " & Symbol (Item) & ", " & Bytes);
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
      --  A C-owned main can drive Landin exports without asking refine to
      --  synthesize a hosted entry.  Those exports still need the library's
      --  fixed runtime bridges.  Discover them before choosing private names,
      --  so a Landin `read` cannot capture a shim's libc dependency.
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
         begin
            if Landin.IR.Is_External (Of_Unit, Item) then
               declare
                  Name : constant String := Source_Symbol (Item);
                  Prefix : constant String := "_landin_host_";
               begin
                  if Name'Length >= Prefix'Length
                    and then Name
                      (Name'First .. Name'First + Prefix'Length - 1) = Prefix
                  then
                     Host_Bridge_Needed := True;
                  end if;
               end;
            end if;
         end;
      end loop;
      Validate_Linkage;
      Allocate_Symbols;
      if Optimized then
         for Index in Shareable'Range loop
            declare
               Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
            begin
               Shareable (Index) :=
                 Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine
                 and then Item /= Hosted_Entry
                 and then not Is_Public_Item (Item)
                 and then not Is_Forced (Item)
                 and then not Landin.IR.Has_Address_Exposure (Of_Unit, Item);
            end;
         end loop;
      end if;
      --  Selection/allocation happen once per body before comparing final
      --  instruction evidence.  The entry symbol is deliberately excluded
      --  from local-label canonicalization; self relocations stay exact.
      for Index in 1 .. Landin.IR.Item_Count (Of_Unit) loop
         declare
            Item : constant Landin.IR.Item_Id := Landin.IR.Item_Id (Index);
         begin
            if Landin.IR.Kind_Of (Of_Unit, Item) = Landin.IR.Routine
              and then not Landin.IR.Is_External (Of_Unit, Item)
            then
               Out_Text := Unbounded.Null_Unbounded_String;
               Emit_Routine (Item);
               Bodies (Index) := Out_Text;
            end if;
         end;
      end loop;
      Out_Text := Unbounded.Null_Unbounded_String;
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
                 and then Final_Bodies_Can_Share
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
                  Unbounded.Append (Out_Text, Bodies (Index));
                  Landin.Build_Reports.Append (Report, Statistics (Index));
               else
                  --  An alias is still this routine's symbol: a public one
                  --  keeps its visibility and its function type, so a
                  --  linker and a debugger see it as before the fold.
                  if Is_Public_Item (Item) then
                     Emit (".globl " & Symbol (Item));
                  end if;
                  Emit (".type " & Symbol (Item) & ", @function");
                  Emit
                    (".set " & Symbol (Item) & ", "
                     & Symbol (Shared_With (Index)));
                  --  An alias adds no instruction or frame storage of its own.
                  --  Its representative's report describes the executed body.
                  Landin.Build_Reports.Append
                    (Report, Landin.Build_Reports.Routine_Statistics'
                       (Item => Item, Shared_With => Shared_With (Index),
                        others => <>));
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
                     Emit_Recursive_Image_Datum (Item);
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

      if Host_Bridge_Needed then
         Put (Character'Val (9) & ".text");
         --  Compiler-owned C ABI: void _landin_host_initialize_arguments
         --  (int argc, char **argv).  Startup supplies the real C vector and
         --  retains its backing for every world derived from it.  Initialize
         --  before publishing capabilities or starting threads.  Identical
         --  repeated calls are harmless; replacing a live root is a trap.
         --  The nonzero argv cell is also the initialized-state guard: zero
         --  is private absence, never a published Landin pointer or fake argv.
         Put (Character'Val (9)
              & ".globl _landin_host_initialize_arguments");
         Put (Character'Val (9)
              & ".hidden _landin_host_initialize_arguments");
         Put (Character'Val (9)
              & ".type _landin_host_initialize_arguments, @function");
         Put ("_landin_host_initialize_arguments:");
         Emit ("cmpq $0, " & Local_Prefix & "landin_host_argv(%rip)");
         Emit ("jne " & Local_Prefix & "landin_host_arguments_initialized");
         Emit ("testl %edi, %edi");
         Emit ("js " & Local_Prefix & "landin_host_arguments_invalid");
         Emit ("testq %rsi, %rsi");
         Emit ("jz " & Local_Prefix & "landin_host_arguments_invalid");
         Emit ("movl %edi, " & Local_Prefix & "landin_host_argc(%rip)");
         Emit ("movq %rsi, " & Local_Prefix & "landin_host_argv(%rip)");
         Emit ("ret");
         Put (Local_Prefix & "landin_host_arguments_initialized:");
         Emit ("cmpl %edi, " & Local_Prefix & "landin_host_argc(%rip)");
         Emit ("jne " & Local_Prefix & "landin_host_arguments_invalid");
         Emit ("cmpq %rsi, " & Local_Prefix & "landin_host_argv(%rip)");
         Emit ("jne " & Local_Prefix & "landin_host_arguments_invalid");
         Emit ("ret");
         Put (Local_Prefix & "landin_host_arguments_invalid:");
         Emit ("ud2");
         Put (Character'Val (9)
              & ".size _landin_host_initialize_arguments, "
              & ".-_landin_host_initialize_arguments");

         Put (Character'Val (9)
              & ".type _landin_host_argument_count, @function");
         Put ("_landin_host_argument_count:");
         Emit ("cmpq $0, " & Local_Prefix & "landin_host_argv(%rip)");
         Emit ("je " & Local_Prefix & "landin_host_arguments_invalid");
         Emit ("movl " & Local_Prefix & "landin_host_argc(%rip), %eax");
         Emit ("subl $1, %eax");
         Emit ("jns " & Local_Prefix & "landin_host_count_ready");
         Emit ("xorl %eax, %eax");
         Put (Local_Prefix & "landin_host_count_ready:");
         Emit ("ret");
         Put (Character'Val (9)
              & ".size _landin_host_argument_count, "
              & ".-_landin_host_argument_count");

         --  Publish the user-argument table itself so core/io can retain the
         --  real backing capability in its system value.  Indexed results
         --  then derive from that stored table instead of from hidden global
         --  state; argv[0] remains outside the published table.
         Put (Character'Val (9)
              & ".type _landin_host_argument_table, @function");
         Put ("_landin_host_argument_table:");
         Emit ("movq " & Local_Prefix & "landin_host_argv(%rip), %rax");
         Emit ("testq %rax, %rax");
         Emit ("jz " & Local_Prefix & "landin_host_arguments_invalid");
         Emit ("addq $8, %rax");
         Emit ("ret");
         Put (Character'Val (9)
              & ".size _landin_host_argument_table, "
              & ".-_landin_host_argument_table");

         Put (Character'Val (9)
              & ".type _landin_host_argument_at, @function");
         Put ("_landin_host_argument_at:");
         Emit ("cmpq $0, " & Local_Prefix & "landin_host_argv(%rip)");
         Emit ("je " & Local_Prefix & "landin_host_arguments_invalid");
         Emit ("movl " & Local_Prefix & "landin_host_argc(%rip), %eax");
         Emit ("subl $1, %eax");
         Emit ("jle " & Local_Prefix & "landin_host_arguments_invalid");
         Emit ("cmpq %rax, %rdi");
         Emit ("jae " & Local_Prefix & "landin_host_arguments_invalid");
         Emit ("movq " & Local_Prefix & "landin_host_argv(%rip), %rax");
         Emit ("movq 8(%rax,%rdi,8), %rax");
         Emit ("testq %rax, %rax");
         Emit ("jz " & Local_Prefix & "landin_host_arguments_invalid");
         Emit ("ret");
         Put (Character'Val (9)
              & ".size _landin_host_argument_at, "
              & ".-_landin_host_argument_at");

         --  Keep the established one-index helper above for the existing
         --  foreign-C boundary fixtures.  The capability-aware variant has a
         --  distinct symbol and derives its result from the explicit table.
         Put (Character'Val (9)
              & ".type _landin_host_argument_at_from, @function");
         Put ("_landin_host_argument_at_from:");
         Emit ("movq (%rdi,%rsi,8), %rax");
         Emit ("ret");
         Put (Character'Val (9)
              & ".size _landin_host_argument_at_from, "
              & ".-_landin_host_argument_at_from");

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

         --  A fixed Landin signature fronts libc's variadic open.  Linux
         --  O_WRONLY | O_CREAT | O_TRUNC is 577; 0666 is filtered by the
         --  process umask.  Clearing eax satisfies the SysV variadic ABI.
         Put (Character'Val (9)
              & ".type _landin_host_open_write, @function");
         Put ("_landin_host_open_write:");
         Emit ("movl $577, %esi");
         Emit ("movl $438, %edx");
         Emit ("xorl %eax, %eax");
         Emit ("jmp open");
         Put (Character'Val (9)
              & ".size _landin_host_open_write, "
              & ".-_landin_host_open_write");

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

         --  core/heap keeps allocation behind the same fixed scalar/pointer
         --  bridge as hosted I/O.  Over-allocation leaves one pointer word
         --  immediately before the aligned result so release can recover
         --  the exact libc pointer.  The arithmetic and PTRDIFF_MAX checks
         --  are host-width work here, never constants in target-neutral IR.
         Put (Character'Val (9)
              & ".type _landin_host_heap_allocate, @function");
         Put ("_landin_host_heap_allocate:");
         Emit ("cmpq $1, %rsi");
         Emit ("ja " & Local_Prefix & "landin_host_heap_alignment_ready");
         Emit ("movl $1, %esi");
         Put (Local_Prefix & "landin_host_heap_alignment_ready:");
         Emit ("movq %rsi, %rax");
         Emit ("subq $1, %rax");
         Emit ("addq $8, %rax");
         Emit ("jc " & Local_Prefix & "landin_host_heap_failed");
         Emit ("addq %rdi, %rax");
         Emit ("jc " & Local_Prefix & "landin_host_heap_failed");
         Emit ("testq %rax, %rax");
         Emit ("js " & Local_Prefix & "landin_host_heap_failed");
         Emit ("subq $24, %rsp");
         Emit ("movq %rsi, (%rsp)");
         Emit ("movq %rax, %rdi");
         Emit ("call malloc");
         Emit ("testq %rax, %rax");
         Emit ("jz " & Local_Prefix & "landin_host_heap_malloc_failed");
         Emit ("movq %rax, 8(%rsp)");
         Emit ("addq $8, %rax");
         Emit ("xorl %edx, %edx");
         Emit ("divq (%rsp)");
         Emit ("movq 8(%rsp), %rax");
         Emit ("addq $8, %rax");
         Emit ("testq %rdx, %rdx");
         Emit ("jz " & Local_Prefix & "landin_host_heap_aligned");
         Emit ("movq (%rsp), %rcx");
         Emit ("subq %rdx, %rcx");
         Emit ("addq %rcx, %rax");
         Put (Local_Prefix & "landin_host_heap_aligned:");
         Emit ("movq 8(%rsp), %rcx");
         Emit ("movq %rcx, -8(%rax)");
         Emit ("addq $24, %rsp");
         Emit ("ret");
         Put (Local_Prefix & "landin_host_heap_malloc_failed:");
         Emit ("addq $24, %rsp");
         Put (Local_Prefix & "landin_host_heap_failed:");
         Emit ("xorl %eax, %eax");
         Emit ("ret");
         Put (Character'Val (9)
              & ".size _landin_host_heap_allocate, "
              & ".-_landin_host_heap_allocate");

         Put (Character'Val (9)
              & ".type _landin_host_heap_release, @function");
         Put ("_landin_host_heap_release:");
         Emit ("movq -8(%rdi), %rdi");
         Emit ("jmp free");
         Put (Character'Val (9)
              & ".size _landin_host_heap_release, "
              & ".-_landin_host_heap_release");
      end if;

      if Host_Bridge_Needed then
         --  Keep the two entry cells in the small initialized data section.
         --  A program may own a multi-gigabyte zero-image datum in .bss;
         --  placing these cells after that section would put RIP-relative
         --  entry accesses outside x86-64's signed displacement.
         Put (Character'Val (9) & ".data");
         Put (Character'Val (9) & ".balign 8");
         Put (Local_Prefix & "landin_host_argv:");
         Emit (".zero 8");
         Put (Character'Val (9) & ".balign 4");
         Put (Local_Prefix & "landin_host_argc:");
         Emit (".zero 4");
      end if;

      --  An executable stack is inherited when nothing says otherwise,
      --  and nothing this compiler emits needs one.
      Put (Character'Val (9)
           & ".section .note.GNU-stack,"""",@progbits");
      Assembly := Out_Text;
   end Emit;

end Landin.Backend.X86_64;
