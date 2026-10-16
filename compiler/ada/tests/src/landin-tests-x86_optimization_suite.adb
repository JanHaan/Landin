--  Host-independent allocation and selected-machine evidence.  These cases
--  inspect assembly; the separately recorded ABI/runtime fixtures execute it.
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Conversion;
with Interfaces;

with Landin.Backend.Reciprocals;
with Landin.Backend.X86_64.Allocation;
with Landin.Backend.X86_64.Machine;
with Landin.Build_Reports;
with Landin.Debugging;
with Landin.IR;
with Landin.Optimization;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Targets.Levels;
with Landin.Types;

package body Landin.Tests.X86_Optimization_Suite is

   package X86 renames Landin.Backend.X86_64;
   package Alloc renames X86.Allocation;
   package Machine renames X86.Machine;
   package IR renames Landin.IR;
   package Opt renames Landin.Optimization;
   package Reports renames Landin.Build_Reports;
   package US renames Ada.Strings.Unbounded;
   use type Alloc.Location_Kind;
   use type Alloc.Locations;
   use type Alloc.Register_Id;
   use type Alloc.Register_Set;
   use type Alloc.SSE_Register_Set;
   use type IR.Block_Id;
   use type IR.Declaration_Id;
   use type IR.Opcode;
   use type IR.Value_Id;
   use type Landin.Source.Source_Id;
   use type Landin.Targets.Byte_Count;
   use type Landin.Types.Type_Kind;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Resolver : aliased Landin.Stages.Resolution.Instance;
   Checker : aliased Landin.Stages.Checking.Instance;
   Lowerer : aliased Landin.Stages.Lowering.Instance;
   LF : constant Character := Character'Val (10);

   function Contains (Text, Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   procedure Lower
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation; Text : String);
   function Emitted
     (Work : in out Landin.Stages.Compilation;
      Options : Opt.Options := Opt.Default_Options) return String;
   procedure Selected_Instructions (Item : in out Landin.Testing.Context);
   procedure Canonical_Bodies (Item : in out Landin.Testing.Context);
   procedure Loop_Allocation (Item : in out Landin.Testing.Context);
   procedure Loop_Nesting (Item : in out Landin.Testing.Context);
   procedure Single_Block_Spans (Item : in out Landin.Testing.Context);
   procedure Slot_Intervals (Item : in out Landin.Testing.Context);
   procedure Pressure_And_C_Scalars (Item : in out Landin.Testing.Context);
   procedure Small_Array_Bounds (Item : in out Landin.Testing.Context);
   procedure Float_Registers (Item : in out Landin.Testing.Context);
   procedure Bounded_Probes (Item : in out Landin.Testing.Context);
   procedure C_Entry_Saves (Item : in out Landin.Testing.Context);
   procedure Final_Folding (Item : in out Landin.Testing.Context);
   procedure Level_Selects_Shifts (Item : in out Landin.Testing.Context);
   procedure Speed_Unrolls_Transfers (Item : in out Landin.Testing.Context);
   procedure Slice_Elements_Check_Once
     (Item : in out Landin.Testing.Context);
   procedure Arithmetic_Shapes (Item : in out Landin.Testing.Context);
   procedure Element_Addressing (Item : in out Landin.Testing.Context);
   function Merging_Moves (Text : String) return Natural;
   procedure Reciprocals_Divide_Exactly
     (Item : in out Landin.Testing.Context);
   procedure Speed_Multiplies_Known_Divisors
     (Item : in out Landin.Testing.Context);
   procedure Float_Branches_Read_Flags
     (Item : in out Landin.Testing.Context);
   procedure Conditions_Jump (Item : in out Landin.Testing.Context);

   procedure Lower
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation; Text : String)
   is
      Order : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "x86-opt.ldn", Text);
   begin
      pragma Assert (Written /= Landin.Source.No_Source);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Resolver'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Landin.Stages.Append (Order, Lowerer'Access);
      declare
         Ran : constant Natural := Landin.Stages.Run (Order, Work);
      begin
         Landin.Testing.Check_Equal
           (Item, Ran, 5, "in-memory source reaches verified IR: "
            & Landin.Stages.Rendered_Report (Work));
      end;
   end Lower;

   function Emitted
     (Work : in out Landin.Stages.Compilation;
      Options : Opt.Options := Opt.Default_Options) return String
   is (X86.Text
         (Landin.Stages.Code (Work).all, Landin.Stages.Meanings (Work).all,
          Landin.Stages.Identities (Work).all, Landin.Stages.Target (Work),
          Options));

   --  Lines that move a float between two XMM registers with a scalar
   --  movss or movsd, which merges into the destination.
   function Merging_Moves (Text : String) return Natural is
      Count : Natural := 0;
      First : Positive := Text'First;
   begin
      for Index in Text'Range loop
         if Text (Index) = LF then
            declare
               Line : constant String := Text (First .. Index - 1);
            begin
               if (Contains (Line, "movsd %xmm")
                   or else Contains (Line, "movss %xmm"))
                 and then Contains (Line, ", %xmm")
               then
                  Count := Count + 1;
               end if;
            end;
            First := Index + 1;
         end if;
      end loop;
      return Count;
   end Merging_Moves;

   procedure Selected_Instructions (Item : in out Landin.Testing.Context) is
      Stream : Machine.Stream;
   begin
      Landin.Testing.Check
        (Item, Machine.Selected ("movq %rbx, %rbx") = ""
         and then Machine.Selected ("movb %r12b, %r12b") = ""
         and then Machine.Selected ("movw %r13w, %r13w") = ""
         and then Machine.Selected ("movl %ebx, %ebx") = "movl %ebx, %ebx",
         "self moves disappear only without upper-half effects");
      Landin.Testing.Check
        (Item, Machine.Selected ("movabsq $2147483647, %rax") =
           "movq $2147483647, %rax"
         and then Machine.Selected ("movabsq $-2147483648, %rax") =
           "movq $-2147483648, %rax"
         and then Machine.Selected ("movabsq $2147483648, %rax") =
           "movabsq $2147483648, %rax",
         "immediate selection respects sign-extension boundaries");
      Landin.Testing.Check
        (Item, Machine.Fits_Arithmetic_Immediate (0)
         and then Machine.Fits_Arithmetic_Immediate (2_147_483_647)
         and then not Machine.Fits_Arithmetic_Immediate (2_147_483_648)
         and then not Machine.Fits_Arithmetic_Immediate (4_294_967_295)
         and then not Machine.Fits_Arithmetic_Immediate
           (18_446_744_073_709_551_615),
         "target byte counts cannot use sign-extended negative immediates");
      Machine.Instruction (Stream, "pushq %rbp");
      Machine.Instruction (Stream, "movq -8(%rbp), %rax");
      Machine.Instruction (Stream, "movq %rax, -16(%rbp)");
      Machine.Instruction (Stream, "addq $1, -16(%rbp)");
      Machine.Instruction (Stream, "leaq -16(%rbp), %rdi");
      Machine.Instruction (Stream, "call target");
      Machine.Instruction (Stream, "call *%r11");
      Machine.Instruction (Stream, "popq %rbp");
      Machine.Instruction (Stream, "ret");
      Machine.Seal (Stream);
      declare
         Counts : constant Reports.Routine_Statistics :=
           Machine.Statistics (Stream);
      begin
         Landin.Testing.Check
           (Item, Counts.Instructions = 9 and then Counts.Stack_Loads = 4
            and then Counts.Stack_Stores = 5
            and then Counts.Direct_Calls = 1
            and then Counts.Indirect_Calls = 1,
            "selected sites and explicit stack traffic are counted once");
      end;
   end Selected_Instructions;

   procedure Canonical_Bodies (Item : in out Landin.Testing.Context) is
      Left, Right, Relocation, Width, Condition : Machine.Stream;

      procedure Fill
        (Into : in out Machine.Stream;
         Label_Name, Symbol, Load, Jump : String);

      procedure Fill
        (Into : in out Machine.Stream; Label_Name, Symbol, Load, Jump : String)
      is
      begin
         Machine.Define_Label (Into, Label_Name);
         Machine.Instruction (Into, Load);
         Machine.Instruction (Into, "leaq " & Symbol & "+8(%rip), %rdi");
         Machine.Instruction (Into, Jump & " " & Label_Name);
         Machine.Instruction (Into, "ret");
         Machine.Seal (Into);
      end Fill;
   begin
      Fill (Left, ".L1_check", "external", "movl %ebx, %eax", "jne");
      Fill (Right, ".L9_check", "external", "movl %ebx, %eax", "jne");
      Fill (Relocation, ".L8_check", "other", "movl %ebx, %eax", "jne");
      Fill (Width, ".L7_check", "external", "movq %rbx, %rax", "jne");
      Fill (Condition, ".L6_check", "external", "movl %ebx, %eax", "je");
      Landin.Testing.Check
        (Item, Machine.Equivalent (Left, Right)
         and then not Machine.Equivalent (Left, Relocation)
         and then not Machine.Equivalent (Left, Width)
         and then not Machine.Equivalent (Left, Condition),
         "local labels canonicalize but relocations widths and checks do not");
   end Canonical_Bodies;

   procedure Loop_Allocation (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Reference, Optimized : Reports.Report;
      Before, After : US.Unbounded_String;
   begin
      Lower
        (Item, Work,
         "public sum: (limit: i32) -> (result: i32) =" & LF
         & "mut i: i32 = 0 mut total: i32 = 0" & LF
         & "while i < limit do total = total + i inc i end while" & LF
         & "result = total end sum");
      declare
         Code : IR.Unit renames Landin.Stages.Code (Work).all;
         Facts : constant Landin.Targets.Target_Facts :=
           Landin.Stages.Target (Work);
         Plan : constant Alloc.Plan :=
           Alloc.Make (Code, 1, Facts, Opt.Default_Options);
         Again : constant Alloc.Plan :=
           Alloc.Make (Code, 1, Facts, Opt.Default_Options);
         Promoted : Natural := 0;
      begin
         for Place of Plan.Slot loop
            if Place.Kind = Alloc.GP then
               Promoted := Promoted + 1;
            end if;
         end loop;
         Landin.Testing.Check
           (Item, Promoted >= 2 and then Alloc.Save_Count (Plan) > 0
            and then Plan.Slot = Again.Slot and then Plan.Value = Again.Value
            and then Plan.Used = Again.Used,
            "loop scalars promote with a repeatable physical register plan");
         Landin.Testing.Check
           (Item, X86.Frame_Is_Addressable (Code, 1, Facts,
                                           Opt.Default_Options),
            "preflight accepts the same optimized frame");
         X86.Emit
           (Code, Landin.Stages.Meanings (Work).all,
            Landin.Stages.Identities (Work).all, Facts,
            Opt.Reference_Options, Before, Reference);
         X86.Emit
           (Code, Landin.Stages.Meanings (Work).all,
            Landin.Stages.Identities (Work).all, Facts,
            Opt.Default_Options, After, Optimized);
         declare
            Old : constant Reports.Routine_Statistics :=
              Reports.Nth_Routine (Reference, 1);
            New_Counts : constant Reports.Routine_Statistics :=
              Reports.Nth_Routine (Optimized, 1);
         begin
            Landin.Testing.Check
              (Item, New_Counts.Stack_Loads + New_Counts.Stack_Stores
                 < Old.Stack_Loads + Old.Stack_Stores
               and then New_Counts.Frame_Bytes < Old.Frame_Bytes
               and then New_Counts.Register_Count = Alloc.Save_Count (Plan),
               "loop traffic frame and reports reflect actual allocation");
         end;
         Landin.Testing.Check
           (Item, US.To_String (After) = Emitted (Work)
            and then Contains (US.To_String (Before), "setl %al")
            and then not Contains (US.To_String (After), "setl %al")
            and then Contains (US.To_String (After), "ud2"),
            "emission repeats and fuses comparisons without lost traps");
         declare
            Again_Report : Reports.Report;
            Again_Text : US.Unbounded_String;
         begin
            X86.Emit
              (Code, Landin.Stages.Meanings (Work).all,
               Landin.Stages.Identities (Work).all, Facts,
               Opt.Default_Options, Again_Text, Again_Report);
            Landin.Testing.Check
              (Item, Reports.JSON (Optimized, Facts, Opt.Default_Options)
                 = Reports.JSON (Again_Report, Facts, Opt.Default_Options)
               and then US.To_String (Again_Text) = US.To_String (After),
               "typed reports and assembly repeat together");
         end;
      end;
   end Loop_Allocation;

   --  Twelve conditional updates give the u32 local, the first u32 slot,
   --  the most static references; the nested loop gives usize the weight.
   procedure Loop_Nesting (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Speed : constant Opt.Options := (Opt.Speed, Opt.Auto);
      Updates : US.Unbounded_String;
   begin
      for Bound in 1 .. 12 loop
         US.Append
           (Updates, "if limit >" & Natural'Image (Bound)
            & " then setup = setup + 1 end if" & LF);
      end loop;
      Lower
        (Item, Work,
         "public walk: (limit: usize) -> (result: usize) =" & LF
         & "mut setup: u32 = 0" & LF & US.To_String (Updates)
         & "mut i: usize = 0 mut total: usize = 0" & LF
         & "while i < limit do mut j: usize = 0" & LF
         & "while j < limit do total = total + j inc j end while" & LF
         & "inc i end while" & LF
         & "result = total + usize(setup) end walk");
      declare
         Code : IR.Unit renames Landin.Stages.Code (Work).all;
         Facts : constant Landin.Targets.Target_Facts :=
           Landin.Stages.Target (Work);
         Compact : constant Alloc.Plan :=
           Alloc.Make (Code, 1, Facts, Opt.Default_Options);
         Fast : constant Alloc.Plan := Alloc.Make (Code, 1, Facts, Speed);
         Setup, Promoted : Natural := 0;
         Shared : Boolean := False;
      begin
         for Index in 1 .. IR.Slot_Count (Code, 1) loop
            if Setup = 0 and then IR.Type_Of (Code, 1, IR.Slot_Id (Index))
              = Landin.Types.U32
            then
               Setup := Index;
            end if;
            --  A register over the slot's live interval.
            if Fast.Slot (Index).Kind = Alloc.GP then
               Promoted := Promoted + 1;
            end if;
         end loop;
         Landin.Testing.Check
           (Item, Setup /= 0
            and then Compact.Slot (Setup).Kind = Alloc.GP
            and then Fast.Slot (Setup).Kind = Alloc.Stack
            and then Promoted >= 3,
            "speed weights slot references by loop nesting; size counts");
         for Index in 1 .. IR.Value_Count (Code, 1) loop
            for Position in 1 .. IR.Operand_Count
              (Code, 1, IR.Value_Id (Index))
            loop
               declare
                  Defined : Alloc.Location renames Compact.Value (Index);
                  Operand : Alloc.Location renames Compact.Value
                    (Positive (IR.Nth_Operand
                       (Code, 1, IR.Value_Id (Index), Position)));
               begin
                  Shared := Shared
                    or else (Defined.Kind = Alloc.GP
                             and then Operand.Kind = Alloc.GP
                             and then Defined.Register = Operand.Register);
               end;
            end loop;
         end loop;
         Landin.Testing.Check
           (Item, Shared,
            "a result may take the register its last operand frees");
         Landin.Testing.Check
           (Item, Contains (Emitted (Work), "jbe .L1_3" & LF)
            and then Contains (Emitted (Work, Speed), "jbe .L1_4" & LF)
            and then not Contains (Emitted (Work, Speed), "jbe .L1_3" & LF),
            "speed branches past a block that only jumps on");
      end;
   end Loop_Nesting;

   --  `step` is stored and then read in the loop body alone, so it is dead
   --  on entering that block and after its last read there.
   procedure Single_Block_Spans (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Speed : constant Opt.Options := (Opt.Speed, Opt.Auto);
   begin
      Lower
        (Item, Work,
         "public spans: (limit: usize) -> (result: usize) =" & LF
         & "mut total: usize = 0 mut i: usize = 0" & LF
         & "while i < limit do step: usize = i * 3" & LF
         & "total = total + step + step inc i end while" & LF
         & "result = total end spans");
      declare
         Code : IR.Unit renames Landin.Stages.Code (Work).all;
         Facts : constant Landin.Targets.Target_Facts :=
           Landin.Stages.Target (Work);
         Compact : constant Alloc.Plan :=
           Alloc.Make (Code, 1, Facts, Opt.Default_Options);
         Fast : constant Alloc.Plan := Alloc.Make (Code, 1, Facts, Speed);
         Spanned : Boolean := False;
         Kept : Boolean := True;
      begin
         for Index in 1 .. IR.Slot_Count (Code, 1) loop
            declare
               Place : Alloc.Location renames Fast.Slot (Index);
            begin
               if IR.Declares (Code, 1, IR.Slot_Id (Index))
                 /= IR.No_Declaration
                 and then Place.From /= IR.No_Value
               then
                  Spanned := Spanned
                    or else (Place.Kind = Alloc.GP
                             and then IR.Op_Of (Code, 1, Place.From)
                               = IR.Store
                             and then IR.Block_Of (Code, 1, Place.From)
                               = IR.Block_Of (Code, 1, Place.Through));
                  Kept := Kept
                    and then (Compact.Slot (Index).Kind = Alloc.Stack
                              or else Compact.Slot (Index).From
                                = IR.No_Value);
               end if;
            end;
         end loop;
         Landin.Testing.Check
           (Item, Spanned and then Kept,
            "speed spans a single-block variable; size holds it throughout");
         Landin.Testing.Check
           (Item, Emitted (Work, Speed) = Emitted (Work, Speed)
            and then Fast.Slot = Alloc.Make (Code, 1, Facts, Speed).Slot,
            "single-block spans repeat");
      end;
   end Single_Block_Spans;

   --  Four counters live in four loops one after another, beside the
   --  address an inout array arrives as: more than three slots hold a
   --  register, and counters whose intervals are disjoint share one.
   procedure Slot_Intervals (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Speed : constant Opt.Options := (Opt.Speed, Opt.Auto);
   begin
      Lower
        (Item, Work,
         "public walk: (inout values: [8]u8, limit: usize)" & LF
         & "-> (result: usize) =" & LF
         & "mut total: usize = 0 mut a: usize = 0" & LF
         & "while a < limit do total = total + usize(values[a]) inc a"
         & " end while" & LF
         & "mut b: usize = 0" & LF
         & "while b < limit do total = total + b inc b end while" & LF
         & "mut c: usize = 0" & LF
         & "while c < limit do total = total + c inc c end while" & LF
         & "mut d: usize = 0" & LF
         & "while d < limit do total = total + d inc d end while" & LF
         & "result = total end walk");
      declare
         Code : IR.Unit renames Landin.Stages.Code (Work).all;
         Facts : constant Landin.Targets.Target_Facts :=
           Landin.Stages.Target (Work);
         Fast : constant Alloc.Plan := Alloc.Make (Code, 1, Facts, Speed);
         Held, Narrowed : Natural := 0;
         Shared, Address, Caller_Saved : Boolean := False;
      begin
         for Index in 1 .. IR.Slot_Count (Code, 1) loop
            if Fast.Slot (Index).Kind = Alloc.GP then
               Held := Held + 1;
               Address := Address
                 or else IR.Is_Address (Code, 1, IR.Slot_Id (Index));
               if Fast.Slot (Index).From /= IR.No_Value then
                  Narrowed := Narrowed + 1;
               end if;
               for Other in 1 .. Index - 1 loop
                  Shared := Shared
                    or else (Fast.Slot (Other).Kind = Alloc.GP
                             and then Fast.Slot (Other).Register
                               = Fast.Slot (Index).Register);
               end loop;
            end if;
         end loop;
         for Index in 1 .. IR.Value_Count (Code, 1) loop
            Caller_Saved := Caller_Saved
              or else (Fast.Value (Index).Kind = Alloc.GP
                       and then Fast.Value (Index).Register
                         in Alloc.Caller_Saved);
         end loop;
         Landin.Testing.Check
           (Item, Held > 3 and then Narrowed > 3 and then Shared,
            "slots with disjoint intervals share a register");
         Landin.Testing.Check
           (Item, Address, "an address slot holds a register");
         Landin.Testing.Check
           (Item, Caller_Saved,
            "a value with no call in its interval holds a caller-saved"
            & " register");
         Landin.Testing.Check
           (Item, Fast.Slot = Alloc.Make (Code, 1, Facts, Speed).Slot,
            "slot intervals repeat");
      end;
   end Slot_Intervals;

   procedure Float_Registers (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Speed : constant Opt.Options := (Opt.Speed, Opt.Auto);
      Before, After : US.Unbounded_String;
      Old_Report, New_Report : Reports.Report;
   begin
      Lower
        (Item, Work,
         "public twice: (value: f64) -> (result: f64) = "
         & "working: f64 = value "
         & "result = working * 2.0 + working end twice "
         & "public caller: (value: f64) -> (result: f64) = "
         & "result = twice(value) + value end caller");
      declare
         Code : IR.Unit renames Landin.Stages.Code (Work).all;
         Facts : constant Landin.Targets.Target_Facts :=
           Landin.Stages.Target (Work);
         Plan : constant Alloc.Plan := Alloc.Make (Code, 1, Facts, Speed);
         Again : constant Alloc.Plan := Alloc.Make (Code, 1, Facts, Speed);
         Calling : constant Alloc.Plan := Alloc.Make (Code, 2, Facts, Speed);
         Compact : constant Alloc.Plan := Alloc.Make
           (Code, 1, Facts, Opt.Default_Options);
         Slots, Values : Natural := 0;

         --  SysV preserves no XMM register across a call, so no value
         --  defined before one may be read from an XMM register after it.
         function Spans_Call
           (Of_Plan : Alloc.Plan; Routine : IR.Item_Id) return Boolean;

         function Spans_Call
           (Of_Plan : Alloc.Plan; Routine : IR.Item_Id) return Boolean
         is
            Defined : array (1 .. IR.Value_Count (Code, Routine)) of Natural
              := [others => 0];
            Called : Natural;
         begin
            for Block in 1 .. IR.Block_Count (Code, Routine) loop
               Called := 0;
               for Position in 1 .. IR.Length
                 (Code, Routine, IR.Block_Id (Block))
               loop
                  declare
                     Value : constant IR.Value_Id := IR.Nth_Value
                       (Code, Routine, IR.Block_Id (Block), Position);
                  begin
                     Defined (Positive (Value)) := Position;
                     for Which in 1 .. IR.Operand_Count
                       (Code, Routine, Value)
                     loop
                        declare
                           Operand : constant Positive := Positive
                             (IR.Nth_Operand (Code, Routine, Value, Which));
                        begin
                           if Of_Plan.Value (Operand).Kind = Alloc.SSE
                             and then Defined (Operand) < Called
                           then
                              return True;
                           end if;
                        end;
                     end loop;
                     if IR.Op_Of (Code, Routine, Value)
                       in IR.Call | IR.Indirect_Call
                     then
                        Called := Position;
                     end if;
                  end;
               end loop;
            end loop;
            return False;
         end Spans_Call;
      begin
         for Place of Plan.Slot loop
            if Place.Kind = Alloc.SSE then
               Slots := Slots + 1;
            end if;
         end loop;
         for Place of Plan.Value loop
            if Place.Kind = Alloc.SSE then
               Values := Values + 1;
            end if;
         end loop;
         Landin.Testing.Check
           (Item, Slots > 0 and then Values > 0
            and then Plan.Slot = Again.Slot
            and then Plan.Value = Again.Value
            and then Plan.Used_SSE = Again.Used_SSE
            and then Alloc.SSE_Count (Calling) > 0
            and then not Spans_Call (Calling, 2)
            and then Alloc.SSE_Count (Compact) = 0,
            "speed floats use repeatable XMM locations no call clobbers");
         X86.Emit
           (Code, Landin.Stages.Meanings (Work).all,
            Landin.Stages.Identities (Work).all, Facts,
            Opt.Default_Options, Before, Old_Report);
         X86.Emit
           (Code, Landin.Stages.Meanings (Work).all,
            Landin.Stages.Identities (Work).all, Facts,
            Speed, After, New_Report);
         declare
            Old : constant Reports.Routine_Statistics :=
              Reports.Nth_Routine (Old_Report, 1);
            New_Counts : constant Reports.Routine_Statistics :=
              Reports.Nth_Routine (New_Report, 1);
         begin
            Landin.Testing.Check
              (Item, New_Counts.Stack_Loads + New_Counts.Stack_Stores
                 < Old.Stack_Loads + Old.Stack_Stores
               and then New_Counts.Frame_Bytes < Old.Frame_Bytes
               and then New_Counts.Register_Count
                 = Alloc.Save_Count (Plan) + Alloc.SSE_Count (Plan)
               and then Contains (US.To_String (After), "%xmm8")
               and then Contains (US.To_String (After), "mulsd"),
               "float allocation reduces measured stack traffic and frame");
            Landin.Testing.Check
              (Item, Contains (US.To_String (After), "movapd %xmm")
               and then Merging_Moves (US.To_String (After)) = 0,
               "register float copies move whole registers, not merging");
         end;
         declare
            Info : aliased Landin.Debugging.Information
              (Landin.Stages.Trees (Work), Landin.Stages.Sources (Work));
            Debug_Text : US.Unbounded_String;
            Debug_Report : Reports.Report;
         begin
            Landin.Debugging.Append
              (Info, Landin.Stages.Source (Work, 1));
            X86.Emit
              (Code, Landin.Stages.Meanings (Work).all,
               Landin.Stages.Identities (Work).all, Facts, Speed,
               Debug_Text, Debug_Report, Debug => Info'Access);
            Landin.Testing.Check
              (Item, Contains (US.To_String (Debug_Text), "working")
               and then Contains
                 (US.To_String (Debug_Text), ".byte 105"),
               "promoted float local has an XMM8 DWARF location");
         end;
      end;
   end Float_Registers;

   procedure Pressure_And_C_Scalars (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Native_Source : constant String :=
        "consume: (a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, "
        & "g: i64, h: i64) -> (r: i64) = r = a+b+c+d+e+f+g+h end consume "
        & "public pressure: (x: i64) -> (r: i64) = "
        & "r = consume(x+1,x+2,x+3,x+4,x+5,x+6,x+7,x+8) "
        & "+ consume(x+2,x+3,x+4,x+5,x+6,x+7,x+8,x+9) end pressure";
      C_Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Work, Native_Source);
      declare
         Plan : constant Alloc.Plan := Alloc.Make
           (Landin.Stages.Code (Work).all, 2, Landin.Stages.Target (Work),
            Opt.Default_Options);
         Stack_Values : Natural := 0;
      begin
         for Place of Plan.Value loop
            if Place.Kind = Alloc.Stack then
               Stack_Values := Stack_Values + 1;
            end if;
         end loop;
         Landin.Testing.Check
           (Item, Alloc.Save_Count (Plan) = 5 and then Plan.Spill_Homes > 0
            and then Plan.Spill_Homes < Stack_Values,
            "simultaneous arguments pressure all GP homes and reuse spills");
         Landin.Testing.Check
           (Item, Contains (Emitted (Work), "call "),
            "pressure emission retains the native call");
      end;
      Lower
        (Item, C_Work,
         "extern(c) link(symbol: ""foreign_step"") step: "
         & "(x: i64) -> (r: i64) "
         & "public caller: (x: i64) -> (r: i64) = "
         & "r = x + step(x+1) + step(x+2) + x end caller");
      declare
         Code : IR.Unit renames Landin.Stages.Code (C_Work).all;
         Plan : constant Alloc.Plan := Alloc.Make
           (Code, 2, Landin.Stages.Target (C_Work), Opt.Default_Options);
         Calls : Natural := 0;
         Register_Arguments : Natural := 0;
      begin
         for Index in 1 .. IR.Value_Count (Code, 2) loop
            declare
               Value : constant IR.Value_Id := IR.Value_Id (Index);
            begin
               if IR.Op_Of (Code, 2, Value) = IR.Call then
                  Calls := Calls + 1;
                  Landin.Testing.Check
                    (Item, Plan.Value (Index).Kind = Alloc.Stack
                     and then Plan.Value (Index).Address_Required,
                     "C result has a distinct live addressable home");
                  for Position in 1 .. IR.Operand_Count (Code, 2, Value) loop
                     declare
                        Argument : constant Positive := Positive
                          (IR.Nth_Operand (Code, 2, Value, Position));
                     begin
                        Landin.Testing.Check
                          (Item, not Plan.Value (Argument).Address_Required,
                           "scalar C arguments do not require an address");
                        if Plan.Value (Argument).Kind = Alloc.GP then
                           Register_Arguments := Register_Arguments + 1;
                        end if;
                     end;
                  end loop;
               end if;
            end;
         end loop;
         Landin.Testing.Check
           (Item, Calls = 2 and then Register_Arguments > 0
            and then Contains (Emitted (C_Work), "foreign_step")
            and then Contains (Emitted (C_Work), "movq %r10, %rdi")
            and then not Contains
              (Emitted (C_Work), "movq 0(%r11), %r10"),
            "foreign calls load scalar values without address roundtrips");
      end;
   end Pressure_And_C_Scalars;

   procedure Bounded_Probes (Item : in out Landin.Testing.Context) is
      type Length_Array is array (Positive range <>) of Positive;
      Lengths : constant Length_Array := [4096, 8192, 1048583];
   begin
      for Length of Lengths loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         begin
            Lower
              (Item, Work,
               "public probe: () -> (r: u8) = mut bytes: ["
               & Ada.Strings.Fixed.Trim (Integer'Image (Length),
                                         Ada.Strings.Both)
               & "]u8 = zeroed bytes[0] = 7 r = bytes[0] end probe");
            for Objective in Opt.Objective loop
               declare
                  Text : constant String := Emitted
                    (Work, (Objective, Opt.Off));
               begin
                  Landin.Testing.Check
                    (Item, Contains (Text, "subq $4096, %rsp")
                     and then Contains (Text, "orq $0, (%rsp)")
                     and then Contains (Text, "cmpq %r11, %rsp")
                     and then Text'Length < 20000,
                     "page probing is bounded code even for a megabyte frame");
               end;
            end loop;
         end;
      end loop;
   end Bounded_Probes;

   procedure C_Entry_Saves (Item : in out Landin.Testing.Context) is
      Empty : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Mixed : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Empty,
             "public extern(c) empty: () -> (r: i32) = "
             & "r = 42 end empty");
      declare
         Text : constant String := Emitted (Empty);
      begin
         Landin.Testing.Check
           (Item, not Contains (Text, "subq $112, %rsp")
            and then not Contains (Text, "addq $112, %rsp")
            and then not Contains (Text, "(%rsp)"),
            "an empty C entry does not stage argument registers");
      end;

      Lower (Item, Mixed,
             "public extern(c) mixed: (i: i64, f: f64) -> (r: i64) = "
             & "r = i end mixed");
      declare
         Text : constant String := Emitted (Mixed);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, "movq %rdi, 0(%rsp)")
            and then Contains (Text, "movq %xmm0, 8(%rsp)")
            and then Contains (Text, "movq 8(%rsp), %r10")
            and then not Contains (Text, "movq %rsi, 8(%rsp)")
            and then not Contains (Text, "movq %xmm1, 16(%rsp)"),
            "a mixed C entry saves only the used register prefixes");
      end;
   end C_Entry_Saves;

   procedure Final_Folding (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Observed : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower
        (Item, Work,
         "first: (x: i32) -> (r: i32) = r = x end first "
         & "second: (x: u32) -> (r: u32) = r = x end second "
         & "public visible: (x: i32) -> (r: i32) = r = x end visible");
      declare
         Text : constant String := Emitted (Work);
         Reference : constant String := Emitted (Work, Opt.Reference_Options);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, ".set ")
            and then not Contains (Reference, ".set ")
            and then Contains (Text, "visible:")
            and then not Contains (Text, ".set visible,")
            and then not Contains (Text, "%rbx")
            and then Text = Emitted (Work),
            "ordinary final bodies fold without merging public entry identity"
            & " or charging a tiny leaf for callee saves");
      end;
      Lower
        (Item, Observed,
         "callback: type = (x: i32) -> (r: i32) "
         & "first_observed: (x: i32) -> (r: i32) = "
         & "r = x end first_observed "
         & "second_observed: (x: i32) -> (r: i32) = "
         & "r = x end second_observed "
         & "mut current: callback = first_observed "
         & "public invoke: (x: i32) -> (r: i32) = "
         & "current = second_observed r = current(x) end invoke");
      Landin.Testing.Check
        (Item, not Contains (Emitted (Observed), ".set "),
         "static image and runtime function addresses both prevent folding");
   end Final_Folding;

   --  D255: at x86-64-v3 a variable 32- or 64-bit shift is BMI2's, which
   --  shifts by any register, and at the baseline it is the legacy shift by
   --  %cl.  The 8- and 16-bit shifts BMI2 has no form for stay legacy at
   --  both, and every guard [0320] and [1950] ask for is kept at both.
   procedure Level_Selects_Shifts (Item : in out Landin.Testing.Context) is
      Source : constant String :=
        "public shifts: (a: u32, b: i64, c: u64, d: u8, e: i16)"
        & " -> (r: u32, s: i64, t: u64, u: u8, v: i16) =" & LF
        & "    r = a << a" & LF
        & "    s = b >> b" & LF
        & "    t = c >> c" & LF
        & "    u = d << d" & LF
        & "    v = e >> e" & LF
        & "end shifts" & LF;
      Facts : constant Landin.Targets.Target_Facts :=
        Landin.Targets.Linux_X86_64;
      Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);

      function At_Level (Name : String) return String;

      function At_Level (Name : String) return String is
         Assembly : US.Unbounded_String;
         Report : Reports.Report;
      begin
         X86.Emit
           (Landin.Stages.Code (Work).all,
            Landin.Stages.Meanings (Work).all,
            Landin.Stages.Identities (Work).all, Facts,
            Opt.Default_Options, Assembly, Report,
            Level => Landin.Targets.Levels.Level_Named (Facts, Name));
         return US.To_String (Assembly);
      end At_Level;
   begin
      Lower (Item, Work, Source);
      declare
         Base : constant String := At_Level ("x86-64-v1");
         Two : constant String := At_Level ("x86-64-v2");
         Three : constant String := At_Level ("x86-64-v3");
         Four : constant String := At_Level ("x86-64-v4");

         function Count (Text, Needle : String) return Natural
           is (Ada.Strings.Fixed.Count (Text, Needle));
      begin
         Landin.Testing.Check
           (Item, Base = Emitted (Work) and then Two = Base,
            "the baseline and x86-64-v2 select what was always selected");
         Landin.Testing.Check
           (Item, Count (Base, "%cl, ") = 5
              and then not Contains (Base, "shlx")
              and then not Contains (Base, "sarx")
              and then not Contains (Base, "shrx"),
            "the baseline shifts all five by %cl");
         Landin.Testing.Check
           (Item, Contains (Three, "shlx %eax, ")
              and then Contains (Three, "sarx %rax, ")
              and then Contains (Three, "shrx %rax, ")
              and then Count (Three, "%cl, ") = 2
              and then Contains (Three, "shlb %cl, %al")
              and then Contains (Three, "sarw %cl, %ax"),
            "x86-64-v3 shifts 32 and 64 bits by BMI2 and narrow ones by %cl");
         Landin.Testing.Check
           (Item, Count (Three, "_inrange:") = Count (Base, "_inrange:")
              and then Count (Three, "_trap_range:")
                = Count (Base, "_trap_range:")
              and then Count (Three, "ud2") = Count (Base, "ud2"),
            "every width and sign guard is kept at every level");
         Landin.Testing.Check
           (Item, Four = Three, "x86-64-v4 shifts as x86-64-v3 does");
      end;
   end Level_Selects_Shifts;

   procedure Small_Array_Bounds (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower
        (Item, Work,
         "public probe: (i: usize) -> (r: u32) = "
         & "mut words: [4]u32 = zeroed "
         & "p: ptr mut u32 = addr words[i] "
         & "p.val = 7 r = words[i] end probe");
      for Reference in Boolean loop
         declare
            Text : constant String := Emitted
              (Work, (if Reference then Opt.Reference_Options
                      else Opt.Default_Options));
         begin
            --  Size compares the index where it lives; none loads it
            --  into the accumulator first.  Either compares an immediate.
            Landin.Testing.Check
              (Item, Ada.Strings.Fixed.Count
                 (Text, (if Reference then "cmpq $4, %rax"
                         else "cmpq $4, %")) = 2
               and then Ada.Strings.Fixed.Count (Text, "_trap_range:") = 2
               and then Ada.Strings.Fixed.Count (Text, "ud2") = 2
               and then not Contains (Text, "cmpq %rdx, %rax"),
               "element address and load compare small bounds directly"
               & " while retaining both traps");
         end;
      end loop;
   end Small_Array_Bounds;

   --  Speed moves a fixed extent through 64 bytes with plain moves and
   --  keeps the string instructions above it; size and the reference
   --  profile keep their own shape.
   procedure Speed_Unrolls_Transfers (Item : in out Landin.Testing.Context)
   is
      use type Opt.Objective;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower
        (Item, Work,
         "mut pair: [2]usize mut other: [2]usize "
         & "mut wide: [9]usize mut wider: [9]usize "
         & "public move: () -> none = other = pair wider = wide "
         & "pair = zeroed end move");
      for Objective in Opt.Objective loop
         declare
            Text : constant String := Emitted (Work, (Objective, Opt.Off));
            Copies : constant Natural :=
              Ada.Strings.Fixed.Count (Text, "rep movsb");
            Clears : constant Natural :=
              Ada.Strings.Fixed.Count (Text, "rep stosb");
         begin
            if Objective = Opt.Speed then
               Landin.Testing.Check
                 (Item, Copies = 1 and then Clears = 0
                  and then Contains (Text, "movq 8(%rsi), %rax")
                  and then Contains (Text, "movq $0, 8(%rdi)"),
                  "speed moves sixteen bytes as words, seventy-two as a"
                  & " string");
            else
               Landin.Testing.Check
                 (Item, Copies = 2 and then Clears = 1,
                  "size and none keep one string operation per transfer");
            end if;
         end;
      end loop;
   end Speed_Unrolls_Transfers;

   --  A slice element is the inclusive range from its index to itself:
   --  the upper edge is checked and the lower edge, the index against
   --  itself, cannot fail and is not emitted.  Both edges would share
   --  the operation's one trap, so the guards are counted as the jumps
   --  to it rather than as traps.
   procedure Slice_Elements_Check_Once
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower
        (Item, Work,
         "public probe: (words: []u64, i: usize) -> (r: u64) = "
         & "r = words[i] end probe");
      for Objective in Opt.Objective loop
         declare
            Text   : constant String := Emitted (Work, (Objective, Opt.Off));
            Traps  : constant Natural :=
              Ada.Strings.Fixed.Count (Text, "_trap_range:");
            Guards : constant Natural :=
              Ada.Strings.Fixed.Count (Text, "_trap_range") - Traps;
         begin
            Landin.Testing.Check
              (Item, Traps = 1 and then Guards = 1
               and then Ada.Strings.Fixed.Count (Text, "ud2") = 1,
               "a slice element keeps its bound trap and no self-comparison");
         end;
      end loop;
   end Slice_Elements_Check_Once;

   --  Every reciprocal Landin.Backend.Reciprocals gives, applied exactly as
   --  the backend applies it, against Ada's own division and remainder:
   --  every 8-bit dividend by every 8-bit divisor, and at the wider widths
   --  each divisor up to 1100, those beside every power of two, the
   --  largest and a pseudo-random spread, each over the width's extreme
   --  dividends, those beside the divisor and its largest multiples, and
   --  a pseudo-random spread.  A divisor's sign is a negation after.
   procedure Reciprocals_Divide_Exactly
     (Item : in out Landin.Testing.Context)
   is
      package R renames Landin.Backend.Reciprocals;
      use type R.Word;
      use type Interfaces.Integer_64;
      subtype Word is R.Word;
      subtype Wide is Interfaces.Integer_64;
      function As_Wide is new Ada.Unchecked_Conversion (Word, Wide);
      function As_Word is new Ada.Unchecked_Conversion (Wide, Word);
      type Word_Array is array (Positive range <>) of Word;
      type Wide_Array is array (Positive range <>) of Wide;

      Seed : Word := 16#9E37_79B9_7F4A_7C15#;
      Checked : Natural := 0;
      Failed : Natural := 0;
      First_Failure : US.Unbounded_String;
      Added : array (Boolean) of Natural := [others => 0];

      function High (Left, Right : Word) return Word;
      function Signed_High (Left, Right : Word) return Word;
      function Next return Word;
      procedure Fail (Text : String);
      procedure Unsigned_Divisor (Bits : R.Dividend_Bits; Divisor : Word);
      procedure Signed_Divisor (Bits : R.Dividend_Bits; Magnitude : Word);
      procedure Divisors (Bits : R.Dividend_Bits; Signed : Boolean);

      --  The high half of the 128-bit product, as `mulq` leaves in RDX.
      function High (Left, Right : Word) return Word is
         Mask : constant Word := 16#FFFF_FFFF#;
         Low_Low : constant Word := (Left and Mask) * (Right and Mask);
         Low_High : constant Word := (Left and Mask) * (Right / 2 ** 32);
         High_Low : constant Word := (Left / 2 ** 32) * (Right and Mask);
         Middle : constant Word :=
           Low_Low / 2 ** 32 + (Low_High and Mask) + (High_Low and Mask);
      begin
         return (Left / 2 ** 32) * (Right / 2 ** 32)
           + Low_High / 2 ** 32 + High_Low / 2 ** 32 + Middle / 2 ** 32;
      end High;

      --  The same for two's-complement operands, as one-operand `imulq`.
      function Signed_High (Left, Right : Word) return Word is
        (High (Left, Right)
         - (if Left >= 2 ** 63 then Right else 0)
         - (if Right >= 2 ** 63 then Left else 0));

      function Next return Word is
      begin
         Seed := Seed * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
         return Seed xor Seed / 2 ** 31;
      end Next;

      procedure Fail (Text : String) is
      begin
         if Failed = 0 then
            First_Failure := US.To_Unbounded_String (Text);
         end if;
         Failed := Failed + 1;
      end Fail;

      procedure Unsigned_Divisor (Bits : R.Dividend_Bits; Divisor : Word)
      is
         Largest : constant Word :=
           (if Bits = 64 then Word'Last else 2 ** Bits - 1);
         Inverse : constant R.Reciprocal :=
           R.Unsigned_Reciprocal (Divisor, Bits);
         Top : constant Word := Largest / Divisor * Divisor;

         procedure Try (Dividend : Word);

         procedure Try (Dividend : Word) is
            T : constant Word := High (Dividend, Inverse.Multiplier);
            Quotient : constant Word :=
              (if Inverse.Add then (Dividend - T) / 2 + T else T)
              / 2 ** Inverse.Shift;
         begin
            Checked := Checked + 1;
            if Quotient /= Dividend / Divisor
              or else Dividend - Quotient * Divisor /= Dividend mod Divisor
            then
               Fail ("u" & R.Dividend_Bits'Image (Bits) & ":"
                     & Word'Image (Dividend) & " /" & Word'Image (Divisor));
            end if;
         end Try;
      begin
         if Inverse.Add then
            Added (False) := Added (False) + 1;
         end if;
         if (Inverse.Add or else Inverse.Shift > 0) and then Bits < 64 then
            Fail ("u" & R.Dividend_Bits'Image (Bits)
                  & " needs more than a high multiply by"
                  & Word'Image (Divisor));
         end if;
         if Bits = 8 then
            for Dividend in Word range 0 .. 255 loop
               Try (Dividend);
            end loop;
            return;
         end if;
         for Edge of Word_Array'
           [0, 1, 2, Largest, Largest - 1, Largest / 2, Largest / 2 + 1,
            Divisor - 1, Divisor, Divisor + 1, 2 * Divisor - 1,
            Top - 1, Top, Largest - (Largest - Top) / 2]
         loop
            Try (Edge and Largest);
         end loop;
         for Spread in 1 .. 96 loop
            Try (Next and Largest);
         end loop;
      end Unsigned_Divisor;

      procedure Signed_Divisor (Bits : R.Dividend_Bits; Magnitude : Word)
      is
         Largest : constant Wide := Wide (Word'(2 ** (Bits - 1) - 1));
         Least : constant Wide := -Largest - 1;
         Inverse : constant R.Reciprocal :=
           R.Signed_Reciprocal (Magnitude, Bits);
         Positive_Divisor : constant Wide := Wide (Magnitude);
         Top : constant Wide := Largest / Positive_Divisor * Positive_Divisor;

         procedure Try (Dividend : Wide);

         procedure Try (Dividend : Wide) is
            T : constant Word :=
              Signed_High (As_Word (Dividend), Inverse.Multiplier)
              + (if Inverse.Add then As_Word (Dividend) else 0);
            Floor : constant Wide :=
              (if As_Wide (T) >= 0 then As_Wide (T) / 2 ** Inverse.Shift
               else -((-(As_Wide (T) + 1)) / 2 ** Inverse.Shift) - 1);
            Quotient : constant Wide :=
              Floor + (if Floor < 0 then 1 else 0);
            Remainder : constant Wide :=
              As_Wide (As_Word (Dividend) - As_Word (Quotient) * Magnitude);
         begin
            Checked := Checked + 2;
            if Quotient /= Dividend / Positive_Divisor
              or else -Quotient /= Dividend / (-Positive_Divisor)
              or else Remainder /= Dividend rem Positive_Divisor
              or else Remainder /= Dividend rem (-Positive_Divisor)
            then
               Fail ("i" & R.Dividend_Bits'Image (Bits) & ":"
                     & Wide'Image (Dividend) & " / +-"
                     & Word'Image (Magnitude));
            end if;
         end Try;
      begin
         if Inverse.Add then
            Added (True) := Added (True) + 1;
         end if;
         if (Inverse.Add or else Inverse.Shift > 0) and then Bits < 64 then
            Fail ("i" & R.Dividend_Bits'Image (Bits)
                  & " needs more than a high multiply by"
                  & Word'Image (Magnitude));
         end if;
         if Bits = 8 then
            for Dividend in Wide range -128 .. 127 loop
               Try (Dividend);
            end loop;
            return;
         end if;
         for Edge of Wide_Array'
           [Least, Least + 1, -1, 0, 1, Largest, Largest - 1,
            Positive_Divisor - 1, Positive_Divisor,
            Wide'Min (Positive_Divisor, Largest - 1) + 1,
            -Positive_Divisor + 1, -Positive_Divisor,
            -Positive_Divisor - 1,
            Top, Top - 1, -Top, -Top + 1, -Top - 1]
         loop
            Try (Edge);
         end loop;
         for Spread in 1 .. 96 loop
            Try (As_Wide (Next) / 2 ** (64 - Bits));
         end loop;
      end Signed_Divisor;

      --  Every divisor that is not zero, one or a power of two: all of
      --  them below 1100, those beside each power of two, the largest
      --  three and a spread.
      procedure Divisors (Bits : R.Dividend_Bits; Signed : Boolean) is
         Width : constant Natural := (if Signed then Bits - 1 else Bits);
         Largest : constant Word :=
           (if Width = 64 then Word'Last else 2 ** Width - 1);

         procedure Divisor (Value : Word);

         procedure Divisor (Value : Word) is
         begin
            if Value >= 3 and then Value <= Largest
              and then not R.Is_Power_Of_Two (Value)
            then
               if Signed then
                  Signed_Divisor (Bits, Value);
               else
                  Unsigned_Divisor (Bits, Value);
               end if;
            end if;
         end Divisor;
      begin
         if Bits = 8 then
            for Value in Word range 3 .. Largest loop
               Divisor (Value);
            end loop;
            return;
         end if;
         for Value in Word range 3 .. 1_100 loop
            Divisor (Value);
         end loop;
         for Power in 11 .. Width - 1 loop
            Divisor (2 ** Power - 1);
            Divisor (2 ** Power + 1);
            Divisor (2 ** Power + 3);
            Divisor (2 ** Power + 2 ** (Power - 1));
         end loop;
         Divisor (Largest);
         Divisor (Largest - 1);
         Divisor (Largest - 2);
         for Spread in 1 .. 64 loop
            Divisor (Next and Largest);
         end loop;
      end Divisors;
   begin
      for Bits in R.Dividend_Bits loop
         Divisors (Bits, Signed => False);
         Divisors (Bits, Signed => True);
      end loop;
      Landin.Testing.Check
        (Item, Failed = 0 and then Checked > 1_000_000,
         "every reciprocal quotient and remainder is the division's;"
         & Natural'Image (Failed) & " of" & Natural'Image (Checked)
         & " differ, first " & US.To_String (First_Failure));
      Landin.Testing.Check
        (Item, Added (False) > 0 and then Added (True) > 0,
         "64-bit unsigned and signed divisors reach the 65-bit multiplier");
   end Reciprocals_Divide_Exactly;

   --  Speed multiplies by a known divisor that is not a power of two, at
   --  every width, and so never divides; size and the reference profile
   --  keep the divide instruction.
   procedure Speed_Multiplies_Known_Divisors
     (Item : in out Landin.Testing.Context)
   is
      use type Opt.Objective;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower
        (Item, Work,
         "public a: (n: u8) -> (r: u8) = r = n / 10 end a "
         & "public b: (n: i16) -> (r: i16) = r = n % -7 end b "
         & "public c: (n: u32) -> (r: u32) = r = n % 139968 end c "
         & "public d: (n: i32) -> (r: i32) = r = n / -1000 end d "
         & "public e: (n: u64) -> (r: u64) = r = n / 7 end e "
         & "public f: (n: i64) -> (r: i64) = r = n % 641 end f");
      for Objective in Opt.Objective loop
         declare
            Text : constant String := Emitted (Work, (Objective, Opt.Off));
            Divides : constant Natural :=
              Ada.Strings.Fixed.Count (Text, "div")
              - Ada.Strings.Fixed.Count (Text, "_divide");
         begin
            if Objective = Opt.Speed then
               Landin.Testing.Check
                 (Item, Divides = 0
                  and then Ada.Strings.Fixed.Count
                    (Text, ASCII.HT & "mulq %rcx") = 3
                  and then Ada.Strings.Fixed.Count
                    (Text, ASCII.HT & "imulq %rcx") = 3
                  and then not Contains (Text, "ud2"),
                  "speed multiplies by six reciprocals and keeps no trap");
            else
               Landin.Testing.Check
                 (Item, Divides = 6 and then not Contains (Text, "mulq"),
                  "size and none divide by known divisors");
            end if;
         end;
      end loop;
   end Speed_Multiplies_Known_Divisors;

   --  An optimized float comparison that a branch tests is a ucomis and a
   --  jump: ordered ones pick their operand order so that an unordered
   --  NaN falls to false with no parity test, and equality adds one.
   --  The reference profile still makes each verdict a bool.
   procedure Float_Branches_Read_Flags
     (Item : in out Landin.Testing.Context)
   is
      use type Opt.Objective;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower
        (Item, Work,
         "public probe: (a: f64, b: f32, c: f32) -> (r: u32) = r = 0 "
         & "if a < 1.0 then r = 1 end if "
         & "if a >= 2.0 then r = 2 end if "
         & "if b <= c then r = 3 end if "
         & "if b > c then r = 4 end if "
         & "if a == 3.0 then r = 5 end if "
         & "if b <> c then r = 6 end if end probe");
      for Objective in Opt.Objective loop
         declare
            Text : constant String := Emitted (Work, (Objective, Opt.Off));
            Parity : constant Natural :=
              Ada.Strings.Fixed.Count (Text, ASCII.HT & "jp ")
              + Ada.Strings.Fixed.Count (Text, ASCII.HT & "jnp ");
         begin
            if Objective = Opt.None then
               Landin.Testing.Check
                 (Item, Ada.Strings.Fixed.Count (Text, "setnp") = 3
                  and then Ada.Strings.Fixed.Count (Text, "cmpb $0") = 6
                  and then Parity = 0,
                  "the reference profile stores each float verdict");
            else
               Landin.Testing.Check
                 (Item, not Contains (Text, ASCII.HT & "set")
                  and then not Contains (Text, "cmpb $0")
                  and then Ada.Strings.Fixed.Count (Text, "ucomisd") = 3
                  and then Ada.Strings.Fixed.Count (Text, "ucomiss") = 3
                  and then Parity = 2,
                  "optimized float branches read the comparison's flags,"
                  & " the parity flag only for equality");
            end if;
         end;
      end loop;
   end Float_Branches_Read_Flags;

   --  An `and` or `or` that a branch tests has no answer slot: each
   --  operand's comparison branches on its own flags.  The same operator
   --  as a value still stores its answer.
   procedure Conditions_Jump (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower
        (Item, Work,
         "public probe: (a: i32, b: i32, c: u8) -> (r: u32) = r = 0 "
         & "while a < b and (b > 7 or c == 3) do r = 1 "
         & "break when r > 3 or a == b end while "
         & "if r == 1 and c <> 2 then r = 2 end if end probe "
         & "public value: (a: i32, b: i32) -> (r: bool) = "
         & "r = a < b and b > 7 end value");
      for Objective in Opt.Objective range Opt.Size .. Opt.Speed loop
         declare
            Text : constant String := Emitted (Work, (Objective, Opt.Off));
            Probe : constant String :=
              Text (Text'First .. Ada.Strings.Fixed.Index (Text, "value:"));
         begin
            Landin.Testing.Check
              (Item, not Contains (Probe, ASCII.HT & "set")
               and then not Contains (Probe, "cmpb $0")
               and then Contains
                 (Text (Probe'Last .. Text'Last), ASCII.HT & "set"),
               "branch conditions jump and value conditions store");
         end;
      end loop;
   end Conditions_Jump;

   --  Size and speed compute an operation where its result lives, write
   --  a constant that fits as an immediate and never place it, take a
   --  signed product in the two- and three-operand `imul` with its
   --  overflow edge, and load a byte zero-extended.  None keeps the
   --  accumulator, the placed constant and the one-operand multiply.
   procedure Arithmetic_Shapes (Item : in out Landin.Testing.Context) is
      use type Opt.Objective;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      HT : constant Character := Character'Val (9);
   begin
      Lower
        (Item, Work,
         "public sum_bytes: (bytes: [8]u8, n: usize) -> (r: u32) = "
         & "mut total: u32 = 0 mut at: usize = 0 "
         & "while at < n do total = total + u32(bytes[at]) + 3 inc at "
         & "end while r = total end sum_bytes "
         & "public scale: (b: i64, n: usize) -> (r: i64) = "
         & "mut product: i64 = b mut count: usize = 0 "
         & "while count < n do product = product * 5 "
         & "product = product * b inc count end while "
         & "r = product end scale");
      for Objective in Opt.Objective loop
         declare
            Text : constant String := Emitted (Work, (Objective, Opt.Off));
         begin
            if Objective = Opt.None then
               Landin.Testing.Check
                 (Item, Contains (Text, HT & "movabsq $3, %rax" & LF)
                  and then Contains (Text, HT & "imulq -")
                  and then not Contains (Text, "imulq $")
                  and then not Contains (Text, "movzbl"),
                  "none keeps the accumulator, placed constants and the"
                  & " one-operand multiply");
            else
               Landin.Testing.Check
                 (Item, Contains (Text, HT & "addl $3, %r")
                  and then not Contains (Text, "$3, %eax")
                  and then not Contains (Text, "movabsq $3,")
                  and then Contains (Text, HT & "imulq $5, %r")
                  and then Contains (Text, HT & "imulq %r")
                  and then not Contains (Text, HT & "imulq -")
                  and then Ada.Strings.Fixed.Count (Text, HT & "jo ") = 2
                  and then Contains (Text, HT & "movzbl -")
                  and then not Contains (Text, HT & "movb -"),
                  "size and speed compute in the result's register with"
                  & " immediates, imul's two- and three-operand forms and"
                  & " zero-extending byte loads");
            end if;
         end;
      end loop;
   end Arithmetic_Shapes;

   --  Size and speed reach an element as one indexed memory operand
   --  after its bounds check: a frame array from %rbp, a slice element
   --  from its base, an element behind an address slot inside the access
   --  that uses it, and an address two accesses share with one `leaq`.
   --  None forms every address with a multiply and adds.  The registers
   --  are the allocator's, so only the operands' shapes are asserted.
   procedure Element_Addressing (Item : in out Landin.Testing.Context) is
      use type Opt.Objective;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Reference_Traps, Reference_Guards : Natural := 0;

      --  Lines of Text whose instruction is Mnemonic over an indexed
      --  memory operand `(%base,%index...)` ending in Tail.
      function Indexed (Text, Mnemonic, Tail : String) return Natural;

      function Indexed (Text, Mnemonic, Tail : String) return Natural is
         Count : Natural := 0;
         First : Positive := Text'First;
      begin
         for Index in Text'Range loop
            if Text (Index) = LF then
               declare
                  Line : constant String := Text (First .. Index - 1);
                  Open : constant Natural :=
                    Ada.Strings.Fixed.Index (Line, "(%");
               begin
                  if Line'Length > Mnemonic'Length + 1
                    and then Line (Line'First + 1
                                   .. Line'First + Mnemonic'Length)
                      = Mnemonic
                    and then Open > 0
                    and then Ada.Strings.Fixed.Index
                      (Line (Open .. Line'Last), ",%") > 0
                    and then Contains (Line (Open .. Line'Last), Tail)
                  then
                     Count := Count + 1;
                  end if;
               end;
               First := Index + 1;
            end if;
         end loop;
         return Count;
      end Indexed;
   begin
      Lower
        (Item, Work,
         "public words_at: (words: []u64, i: usize) -> (r: u64) = "
         & "mut local: [4]u64 = zeroed local[i] = words[i] "
         & "r = local[i] + words[i] end words_at "
         & "public pick: (inout values: [16]u8, i: usize) -> (r: u8) = "
         & "r = values[i] end pick "
         & "public flip: (inout values: [16]u8, i: usize) -> none = "
         & "saved: u8 = values[i] values[i] = values[0] "
         & "values[0] = saved end flip");
      for Objective in Opt.Objective loop
         declare
            Text : constant String := Emitted (Work, (Objective, Opt.Off));
            Traps : constant Natural :=
              Ada.Strings.Fixed.Count (Text, "_trap_range:");
            Guards : constant Natural :=
              Ada.Strings.Fixed.Count (Text, "_trap_range") - Traps;
         begin
            if Objective = Opt.None then
               Reference_Traps := Traps;
               Reference_Guards := Guards;
               Landin.Testing.Check
                 (Item, Contains (Text, "imulq $8, %rax, %rax")
                  and then not Contains (Text, "(%rbp,%")
                  and then Traps > 0,
                  "none scales every index with a multiply");
            else
               Landin.Testing.Check
                 (Item, Traps = Reference_Traps
                  and then Guards = Reference_Guards,
                  "every element keeps its bounds trap");
               Landin.Testing.Check
                 (Item, Indexed (Text, "movq", ",8)") >= 3
                  and then Contains (Text, "(%rbp,%")
                  and then Indexed (Text, "movzbl", ")") >= 1
                  and then Indexed (Text, "leaq", ")") >= 1
                  and then not Contains (Text, "imulq $8"),
                  "size and speed address frame, slice and indirect"
                  & " elements with indexed memory operands");
            end if;
         end;
      end loop;
   end Element_Addressing;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "x86 opt", "small array bounds", Small_Array_Bounds'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "selected instructions",
         Selected_Instructions'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "canonical bodies", Canonical_Bodies'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "loop allocation", Loop_Allocation'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "loop nesting", Loop_Nesting'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "single-block spans", Single_Block_Spans'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "slot intervals", Slot_Intervals'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "pressure and C scalars",
         Pressure_And_C_Scalars'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "float registers", Float_Registers'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "bounded probes", Bounded_Probes'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "C entry saves", C_Entry_Saves'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "final folding", Final_Folding'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "a level selects its shifts",
         Level_Selects_Shifts'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "speed unrolls small transfers",
         Speed_Unrolls_Transfers'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "slice elements check once",
         Slice_Elements_Check_Once'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "reciprocals divide exactly",
         Reciprocals_Divide_Exactly'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "speed multiplies by known divisors",
         Speed_Multiplies_Known_Divisors'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "float branches read the flags",
         Float_Branches_Read_Flags'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "conditions jump", Conditions_Jump'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "arithmetic shapes", Arithmetic_Shapes'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "element addressing", Element_Addressing'Access);
   end Register;

end Landin.Tests.X86_Optimization_Suite;
