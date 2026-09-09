--  Host-independent allocation and selected-machine evidence.  These cases
--  inspect assembly; the separately recorded ABI/runtime fixtures execute it.
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Backend.X86_64.Allocation;
with Landin.Backend.X86_64.Machine;
with Landin.Build_Reports;
with Landin.IR;
with Landin.Optimization;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;

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
   use type Alloc.Register_Set;
   use type IR.Opcode;
   use type Landin.Source.Source_Id;
   use type Landin.Targets.Byte_Count;

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
   procedure Pressure_And_C_Homes (Item : in out Landin.Testing.Context);
   procedure Bounded_Probes (Item : in out Landin.Testing.Context);
   procedure Final_Folding (Item : in out Landin.Testing.Context);

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

   procedure Pressure_And_C_Homes (Item : in out Landin.Testing.Context) is
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
                          (Item, Plan.Value (Argument).Kind = Alloc.Stack
                           and then Plan.Value (Argument).Address_Required,
                           "C arguments keep addressable transport homes");
                     end;
                  end loop;
               end if;
            end;
         end loop;
         Landin.Testing.Check
           (Item, Calls = 2
            and then Contains (Emitted (C_Work), "foreign_step"),
            "both foreign call boundaries survive allocation");
      end;
   end Pressure_And_C_Homes;

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

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "x86 opt", "selected instructions",
         Selected_Instructions'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "canonical bodies", Canonical_Bodies'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "loop allocation", Loop_Allocation'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "pressure and C homes", Pressure_And_C_Homes'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "bounded probes", Bounded_Probes'Access);
      Landin.Testing.Register
        (Into, "x86 opt", "final folding", Final_Folding'Access);
   end Register;

end Landin.Tests.X86_Optimization_Suite;
