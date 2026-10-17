with Landin.Memory;
with Landin.IR.Testing_Support;
with Landin.Targets.Capabilities;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Landin.Backend.Arm64;
with Landin.Backend.X86_64;
with Landin.Backend.X86_64.Allocation;
with Landin.Build_Reports;
with Landin.IR.Control_Flow;
with Landin.IR.Dominance;
with Landin.IR.Dump;
with Landin.IR.If_Conversion;
with Landin.IR.In_Place;
with Landin.IR.Scalar_Replacement;
with Landin.IR.Simplification;
with Landin.IR.Specialization;
with Landin.IR.Specialization_Policy;
with Landin.IR.Verifier;
with Landin.Optimization;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Source.Names;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Types;

package body Landin.Tests.IR_Optimization_Suite is
   package IR renames Landin.IR;
   package Opt renames Landin.Optimization;
   package Reports renames Landin.Build_Reports;
   use type IR.Opcode;
   use type IR.Item_Id;
   use type IR.Item_Kind;
   use type IR.Evidence_Id;
   use type IR.Slot_Id;
   use type IR.Block_Id;
   use type IR.Signature_Id;
   use type Opt.Objective;
   use type Landin.Provenance.Origin;
   use type Landin.Provenance.Declaration_Id;
   use type Reports.Specialization_Action;
   use type Reports.Decision_Reason;
   use type Opt.Specialization_Mode;
   use type Landin.Source.Source_Id;
   use type Landin.Targets.Byte_Count;
   use type Landin.Types.Magnitude;
   use type Landin.Types.Folded;
   use type IR.Verifier.Fault_Kind;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Resolver : aliased Landin.Stages.Resolution.Instance;
   Checker : aliased Landin.Stages.Checking.Instance;
   Lowerer : aliased Landin.Stages.Lowering.Instance;

   Generic_Source : constant String :=
     "ordered: type = concept (t: type) "
     & "less: (a: t, b: t) -> (r: bool) end ordered "
     & "less: (a: i32, b: i32) -> (r: bool) = a < b end less "
     & "i32 is ordered (less: less) "
     & "choose: (t: type is ordered, a: t, b: t) -> (r: t) = "
     & "if t.less(a,b) then r = a else r = b end if end choose "
     & "public main: () -> (r: i32) = r = choose(42,43) end main";

   procedure Lower
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation; Text : String);
   function Text (Work : in out Landin.Stages.Compilation) return String;
   function Count (Code : IR.Unit; Op : IR.Opcode) return Natural;
   procedure Constant_Shifts (Item : in out Landin.Testing.Context);
   procedure Effect_Preservation (Item : in out Landin.Testing.Context);
   procedure Overwritten_Local_Stores (Item : in out Landin.Testing.Context);
   procedure Scalar_Replacement (Item : in out Landin.Testing.Context);
   procedure Forwarding_Through_Writes
     (Item : in out Landin.Testing.Context);
   procedure Block_Value_Numbering (Item : in out Landin.Testing.Context);
   procedure Memory_Events (Item : in out Landin.Testing.Context);
   procedure Static_Dispatch (Item : in out Landin.Testing.Context);
   procedure Exposed_Evidence (Item : in out Landin.Testing.Context);
   procedure Raw_Any (Item : in out Landin.Testing.Context);
   procedure Incoming_Evidence (Item : in out Landin.Testing.Context);
   procedure Assembly_Output_Aliases
     (Item : in out Landin.Testing.Context);
   procedure Forwarded_Evidence_Chain
     (Item : in out Landin.Testing.Context);
   procedure Instance_Costs (Item : in out Landin.Testing.Context);
   procedure Sparse_Instance_Items (Item : in out Landin.Testing.Context);
   procedure Large_Graph (Item : in out Landin.Testing.Context);
   procedure Scalar_Boundaries (Item : in out Landin.Testing.Context);
   procedure Policy_Boundaries (Item : in out Landin.Testing.Context);
   procedure Cyclic_Islands (Item : in out Landin.Testing.Context);
   procedure In_Place_Parameters (Item : in out Landin.Testing.Context);
   procedure Module_Constants (Item : in out Landin.Testing.Context);
   procedure Proved_Checks (Item : in out Landin.Testing.Context);
   procedure Dominators (Item : in out Landin.Testing.Context);
   procedure Choices_From_Computing_Arms
     (Item : in out Landin.Testing.Context);
   procedure Branches_Around_Observable_Arms
     (Item : in out Landin.Testing.Context);

   --  Source lowered, simplified and if-converted at Objective: the
   --  branches and choices left, and how many choices take two constants.
   procedure Converted
     (Item : in out Landin.Testing.Context;
      Source : String;
      Objective : Opt.Objective;
      Branches, Choices, Constant_Choices : out Natural);

   type Incoming_Kind is (Literal_Table, Unknown_Table, Wrong_Table);
   type Assembly_Case is
     (No_Assembly, Overwritten, Restored, Unrelated_Output);
   procedure Evidence_Unit
     (Code : in out IR.Unit; Work : in out Landin.Stages.Compilation;
      Incoming : Incoming_Kind; Instances : Positive; Recursive : Boolean;
      Split_Template : Boolean := False;
      Assembly_Output : Assembly_Case := No_Assembly;
      Chain : Boolean := False;
      Aggregate_Represented : Boolean := False);

   procedure Lower
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation; Text : String)
   is
      Order : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "ir-opt.ldn", Text);
      Ran : Natural;
   begin
      pragma Assert (Written /= Landin.Source.No_Source);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Resolver'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Landin.Stages.Append (Order, Lowerer'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check_Equal
        (Item, Ran, 5, "source reaches verified lowering: "
         & Landin.Stages.Rendered_Report (Work));
   end Lower;

   function Text (Work : in out Landin.Stages.Compilation) return String is
     (IR.Dump.Text (Landin.Stages.Code (Work).all,
                    Landin.Stages.Meanings (Work).all,
                    Landin.Stages.Identities (Work).all));

   function Count (Code : IR.Unit; Op : IR.Opcode) return Natural is
      Total : Natural := 0;
   begin
      for I in 1 .. IR.Item_Count (Code) loop
         for V in 1 .. IR.Value_Count (Code, IR.Item_Id (I)) loop
            if IR.Op_Of (Code, IR.Item_Id (I), IR.Value_Id (V)) = Op then
               Total := Total + 1;
            end if;
         end loop;
      end loop;
      return Total;
   end Count;

   procedure Constant_Shifts (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Work,
        "public f: () -> (r: i32) = r = -1 >> 32 end f");
      declare
         Before : constant String := Text (Work);
      begin
         IR.Simplification.Run
           (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work),
            Opt.None);
         Landin.Testing.Check_Equal
           (Item, Text (Work), Before, "none keeps the lowering oracle");
      end;
      IR.Simplification.Run
        (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work), Opt.Size);
      Landin.Testing.Check_Equal
        (Item, Count (Landin.Stages.Code (Work).all, IR.Shift_Right), 0,
         "the constant shift is folded");
      declare
         Code : IR.Unit renames Landin.Stages.Code (Work).all;
         Return_Value : constant IR.Value_Id := IR.Nth_Operand
           (Code, 1, IR.Value_Id (IR.Value_Count (Code, 1)), 1);
      begin
         Landin.Testing.Check
           (Item, IR.Op_Of (Code, 1, Return_Value) = IR.Number
            and then IR.Number_Of (Code, 1, Return_Value) = 0
            and then not IR.Is_Negated (Code, 1, Return_Value),
            "every beyond-width shift is zero, including signed right shift");
      end;
   end Constant_Shifts;

   procedure Memory_Events (Item : in out Landin.Testing.Context) is
      use all type Landin.Memory.Operation;
      use all type Landin.Memory.Ordering;
      use type IR.Value_Id;
      use Landin.Targets;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Linux_X86_64);
      Code : constant not null access IR.Unit := Landin.Stages.Code (Work);
      Load : IR.Value_Id := IR.No_Value;
      Report : Reports.Report;
   begin
      Lower (Item, Work,
        "public f: (p: ptr mut u32) -> none = "
        & "_ = compiler.volatile_load(p) "
        & "compiler.compiler_barrier() "
        & "compiler.volatile_store(p, 7) "
        & "_ = compiler.atomic_load(p, compiler.acquire) "
        & "compiler.thread_fence(compiler.seq_cst) end f");
      for Objective in Opt.Objective loop
         for Mode in Opt.Specialization_Mode loop
            IR.Specialization.Run (Code.all, Linux_X86_64,
                                   (Objective, Mode), Report);
            IR.Simplification.Run (Code.all, Linux_X86_64, Objective);
            Landin.Testing.Check_Equal
              (Item, Count (Code.all, IR.Memory_Access), 5,
               "discarded memory events survive every policy");
         end loop;
      end loop;
      for V in 1 .. IR.Value_Count (Code.all, 1) loop
         if IR.Op_Of (Code.all, 1, IR.Value_Id (V)) = IR.Memory_Access
           and then IR.Memory_Operation (Code.all, 1, IR.Value_Id (V))
             = Atomic_Load
         then
            Load := IR.Value_Id (V);
         end if;
      end loop;
      Landin.Testing.Check
        (Item, Load /= IR.No_Value, "atomic event retained");
      for Bad_Order in Landin.Memory.Ordering loop
         IR.Testing_Support.Overwrite_Memory
           (Code.all, 1, Load, Atomic_Load, Landin.Types.U32,
            Bad_Order, No_Ordering);
         Landin.Testing.Check
           (Item, (IR.Verifier.Check (Code.all, Linux_X86_64).Kind
                   = IR.Verifier.Nothing_Wrong)
              = (Bad_Order in Relaxed | Acquire | Seq_Cst),
            "verifier independently refuses invalid load orderings");
      end loop;
      IR.Testing_Support.Overwrite_Memory
        (Code.all, 1, Load, Atomic_Load, Landin.Types.U16,
         Acquire, No_Ordering);
      Landin.Testing.Check
        (Item, IR.Verifier.Check (Code.all).Kind /= IR.Verifier.Nothing_Wrong,
         "corrupted scalar width is refused");
      IR.Testing_Support.Overwrite_Memory
        (Code.all, 1, Load, Atomic_Load, Landin.Types.U32,
         Acquire, No_Ordering);
      Landin.Testing.Check
        (Item, IR.Verifier.Check (Code.all, Synthetic_32).Kind /=
           IR.Verifier.Nothing_Wrong, "unimplemented target refuses events");
      for Width in Scalar_Size loop
         Landin.Testing.Check
           (Item, Capabilities.Memory_Access
             (Cortex_M, Atomic_Load, Width) = (Width in Byte_1 .. Byte_4),
            "M0 load boundary is independent of hosted width");
         Landin.Testing.Check
           (Item, not Capabilities.Memory_Access
             (Cortex_M, Atomic_Add, Width), "M0 has no hidden RMW fallback");
      end loop;
   end Memory_Events;

   procedure Effect_Preservation (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Work,
        "extern(c) link(symbol: ""tick"") tick: () -> (r: i32) "
        & "public f: (x: i32, y: i32) -> (r: i32) = "
        & "_ = tick() unchecked begin r = x / y end unchecked end f");
      IR.Simplification.Run
        (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work), Opt.Size);
      Landin.Testing.Check
        (Item, Count (Landin.Stages.Code (Work).all, IR.Call) = 1
         and then Count (Landin.Stages.Code (Work).all, IR.Divide) = 1,
         "discarded effects and unknown division survive");
      declare
         Before : constant String := Text (Work);
      begin
         IR.Simplification.Run
           (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work),
            Opt.Size);
         Landin.Testing.Check_Equal
           (Item, Text (Work), Before, "a settled rewrite is repeatable");
      end;
   end Effect_Preservation;

   procedure Overwritten_Local_Stores
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Stores
        (Source : String; Removed : Natural; Trap : Boolean := False;
         Unused_Number : Boolean := False);

      procedure Check_Stores
        (Source : String; Removed : Natural; Trap : Boolean := False;
         Unused_Number : Boolean := False)
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      begin
         Lower (Item, Work, Source);
         declare
            Code : IR.Unit renames Landin.Stages.Code (Work).all;
            Before : constant Natural := Count (Code, IR.Store);
            Numbers : constant Natural := Count (Code, IR.Number);
         begin
            IR.Simplification.Run (Code, Landin.Targets.Linux_X86_64,
                                   Opt.Size);
            Landin.Testing.Check_Equal
              (Item, Count (Code, IR.Store) + Removed, Before,
               "only overwritten stores and unread temporaries disappear");
            if Trap then
               Landin.Testing.Check_Equal
                 (Item, Count (Code, IR.Divide), 1,
                  "discarding the store keeps its possible divide trap");
            end if;
            if Unused_Number then
               Landin.Testing.Check_Equal
                 (Item, Count (Code, IR.Number) + 1, Numbers,
                  "discarding the store removes its unused literal");
            end if;
         end;
      end Check_Stores;
   begin
      Check_Stores
        ("public f: () -> (r: i32) = "
         & "mut x: i32 = 1 x = 2 r = x end f", 1,
         Unused_Number => True);
      Check_Stores
        ("public f: () -> (r: f32) = "
         & "mut x: f32 = 1.0 x = 2.0 r = x end f", 1,
         Unused_Number => True);
      --  A binary operation carries its left operand through a compiler
      --  temporary.  Once its load is forwarded, the temporary is unread
      --  and its store disappears too; declared slots keep theirs.
      Check_Stores
        ("public f: (d: i32) -> (r: i32) = "
         & "mut x: i32 = 10 / d x = 2 r = x end f", 2, True);
      Check_Stores
        ("public f: () -> (r: i32) = "
         & "mut x: i32 = 1 y: i32 = x x = 2 r = y + x end f", 1);
      Check_Stores
        ("public f: (a: f64) -> (r: f64) = "
         & "x: f64 = a * 2.0 r = x * x end f", 2);
      Check_Stores
        ("public f: (a: ptr u8, b: ptr u8) -> (r: bool) = "
         & "r = a == b end f", 1);
      Check_Stores
        ("public f: () -> (r: i32) = "
         & "mut x: i32 = 1 p: ptr mut i32 = addr x "
         & "x = 2 r = p.val end f", 0);
      Check_Stores
        ("public f: (flag: bool) -> (r: i32) = "
         & "mut x: i32 = 1 if flag then x = 2 end if r = x end f", 0);
   end Overwritten_Local_Stores;

   procedure Scalar_Replacement (Item : in out Landin.Testing.Context) is
      --  Pieces: scalar slots the pass adds.  Split_Declared: declared
      --  slots it moves into pieces.  Field_Loads: loads that still read a
      --  field, which for a parameter are its copies on entry.
      procedure Check
        (Label, Source : String; Objective : Opt.Objective;
         Pieces, Split_Declared, Field_Loads : Natural);

      procedure Check
        (Label, Source : String; Objective : Opt.Objective;
         Pieces, Split_Declared, Field_Loads : Natural)
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);

         function Slots (Code : IR.Unit) return Natural;
         function Slots (Code : IR.Unit) return Natural is
            Total : Natural := 0;
         begin
            for I in 1 .. IR.Item_Count (Code) loop
               Total := Total + IR.Slot_Count (Code, IR.Item_Id (I));
            end loop;
            return Total;
         end Slots;
      begin
         Lower (Item, Work, Source);
         declare
            Code : IR.Unit renames Landin.Stages.Code (Work).all;
            Before : constant Natural := Slots (Code);
            Split : Natural := 0;
         begin
            IR.Scalar_Replacement.Run
              (Code, Landin.Stages.Target (Work), Objective);
            for I in 1 .. IR.Item_Count (Code) loop
               for S in 1 .. IR.Slot_Count (Code, IR.Item_Id (I)) loop
                  if IR.First_Piece (Code, IR.Item_Id (I), IR.Slot_Id (S))
                       /= IR.No_Slot
                    and then IR.Declares
                      (Code, IR.Item_Id (I), IR.Slot_Id (S))
                      /= Landin.Provenance.No_Declaration
                  then
                     Split := Split + 1;
                  end if;
               end loop;
            end loop;
            Landin.Testing.Check_Equal
              (Item, Slots (Code) - Before, Pieces, Label & ": pieces");
            Landin.Testing.Check_Equal
              (Item, Split, Split_Declared, Label & ": declared slots split");
            Landin.Testing.Check_Equal
              (Item, Count (Code, IR.Load_Field), Field_Loads,
               Label & ": field loads");
            Landin.Testing.Check
              (Item, IR.Verifier.Check (Code).Kind = IR.Verifier.Nothing_Wrong,
               Label & ": the result verifies");
         end;
      end Check;

      Loop_Source : constant String :=
        "public f: (s: []u8) -> (r: usize) = r = 0 first: usize = 0 "
        & "for i in first..<lenof s do r += usize(s[i]) end for end f";
      Local_Source : constant String :=
        "public f: (s: []u8) -> (r: usize) = mut t: []u8 = s "
        & "t = t[1..<lenof t] r = lenof t end f";
   begin
      Check ("none", Loop_Source, Opt.None, 0, 0, 4);
      --  The parameter stays whole as it arrived; its two parts are
      --  copied out once and every loop read becomes a scalar load.
      Check ("parameter", Loop_Source, Opt.Speed, 2, 0, 2);
      --  At size no register would hold the copies.
      Check ("parameter at size", Loop_Source, Opt.Size, 0, 0, 4);
      --  The copy into the split local reads the whole parameter's parts.
      Check ("local at speed", Local_Source, Opt.Speed, 2, 1, 2);
      --  Size keeps a declared variable in its frame cell.
      Check ("local at size", Local_Source, Opt.Size, 0, 0, 6);
      Check ("address taken",
             "public f: (s: []u8) -> (r: usize) = mut t: []u8 = s "
             & "p: ptr []u8 = addr t v: []u8 = p.val r = lenof v end f",
             Opt.Speed, 0, 0, 2);
      --  The argument is a snapshot of t that its address carrier keeps
      --  whole, so t is split and copied into the snapshot part by part.
      --  g reads x outside any loop, so x is read where it arrived.
      Check ("passed whole",
             "g: (x: []u8) -> (r: usize) = r = lenof x end g "
             & "public f: (s: []u8) -> (r: usize) = t: []u8 = s "
             & "r = g(t) + lenof t end f",
             Opt.Speed, 2, 1, 4);
   end Scalar_Replacement;

   procedure Forwarding_Through_Writes
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Loads (Source : String; Loads : Natural; Why : String);

      procedure Check_Loads (Source : String; Loads : Natural; Why : String)
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      begin
         Lower (Item, Work, Source);
         IR.Simplification.Run
           (Landin.Stages.Code (Work).all, Landin.Targets.Linux_X86_64,
            Opt.Size);
         Landin.Testing.Check_Equal
           (Item, Count (Landin.Stages.Code (Work).all, IR.Load), Loads, Why);
      end Check_Loads;
   begin
      --  B is never addressed, so the call cannot write it and its stored
      --  sum reaches the last line.  A is passed inout and is reloaded.
      --  D is loaded at each of its three references, because a load is
      --  never stretched over another; bump reads its address twice.
      Check_Loads
        ("bump: (inout x: i32) -> none = x = x + 1 end bump "
         & "public f: (d: i32) -> (r: i32) = "
         & "mut a: i32 = d mut b: i32 = d + 2 bump(a) r = a + b + d end f",
         6, "only the addressed slot is reloaded after a call");
      --  A store through a pointer cannot reach a slot nobody addressed:
      --  B is not loaded at all.  D is loaded twice, P and its carrier once.
      Check_Loads
        ("public f: (p: ptr mut i32, d: i32) -> (r: i32) = "
         & "b: i32 = d + 1 p.val = 0 r = b + d end f",
         4, "a store through a pointer keeps unaddressed values");
   end Forwarding_Through_Writes;

   procedure Block_Value_Numbering (Item : in out Landin.Testing.Context) is
      procedure Check_Count
        (Source : String; Op : IR.Opcode; Expected : Natural; Why : String);

      procedure Check_Count
        (Source : String; Op : IR.Opcode; Expected : Natural; Why : String)
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      begin
         Lower (Item, Work, Source);
         IR.Simplification.Run
           (Landin.Stages.Code (Work).all, Landin.Targets.Linux_X86_64,
            Opt.Size);
         Landin.Testing.Check_Equal
           (Item, Count (Landin.Stages.Code (Work).all, Op), Expected, Why);
      end Check_Count;
   begin
      --  The second and third products are the first one's value.
      Check_Count
        ("public f: (a: i32, b: i32) -> (r: i32) = "
         & "r = a * b + a * b - a * b end f",
         IR.Multiply, 1, "identical products are computed once");
      --  [1960]: the second indexing of the same element repeats a check
      --  the first already passed, in the same block.
      Check_Count
        ("public f: (inout v: [4]u8, i: usize) -> none = "
         & "saved: u8 = v[i] v[i] = saved + 1 end f",
         IR.Storage_Address, 1, "a passed bounds check is not repeated");
      --  Another block's check proves nothing here.
      Check_Count
        ("public f: (inout v: [4]u8, i: usize, flag: bool) -> none = "
         & "saved: u8 = v[i] if flag then v[i] = saved end if end f",
         IR.Storage_Address, 2, "value numbering stays in its block");
      --  D187: an unchecked sum proves nothing for a later checked one,
      --  so the two are numbered apart.
      Check_Count
        ("public f: (a: i32, b: i32) -> (r: i32) = "
         & "mut x: i32 = 0 unchecked begin x = a + b end unchecked "
         & "r = x + (a + b) end f",
         IR.Add, 3, "an unchecked operation proves no check");
      --  Integer identities, and none for a float.
      Check_Count
        ("public f: (a: i32) -> (r: i32) = r = (a + 0) * 1 end f",
         IR.Add, 0, "adding zero is the operand");
      Check_Count
        ("public f: (a: i32) -> (r: bool) = r = a == a end f",
         IR.Equal_To, 0, "an integer equals itself");
      Check_Count
        ("public f: (a: f64) -> (r: bool) = r = a == a end f",
         IR.Equal_To, 1, "a float NaN does not equal itself");
      Check_Count
        ("public f: (a: f64) -> (r: f64) = r = a + 0.0 end f",
         IR.Add, 1, "a float -0.0 plus 0.0 is not -0.0");
   end Block_Value_Numbering;

   procedure Static_Dispatch (Item : in out Landin.Testing.Context) is
   begin
      for Mode in Opt.Specialization_Mode loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Landin.Targets.Linux_X86_64);
            Report : Reports.Report;
         begin
            Lower (Item, Work, Generic_Source);
            declare
               Before : constant String := Text (Work);
            begin
               IR.Specialization.Run
                 (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work),
                  (Opt.None, Mode), Report);
               Landin.Testing.Check_Equal
                 (Item, Reports.Specialization_Count (Report), 1,
                  "one semantic instance gets one decision");
               Landin.Testing.Check
                 (Item, Reports.Nth_Specialization
                    (Report, 1).Retains_Fallback = (Mode = Opt.Off),
                  "fallback reflects the remaining indirect dispatch");
               if Mode = Opt.Off then
                  Landin.Testing.Check_Equal
                    (Item, Text (Work), Before,
                     "off preserves every evidence dispatch instruction");
               else
                  Landin.Testing.Check
                    (Item, Count (Landin.Stages.Code (Work).all,
                                  IR.Indirect_Call) = 0
                     and then Reports.Nth_Specialization
                       (Report, 1).Direct_Calls_Made = 1,
                     "a saved-and-reloaded static callee becomes direct");
               end if;
            end;
            IR.Verifier.Verify
              (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work));
         end;
      end loop;
   end Static_Dispatch;

   procedure Exposed_Evidence (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Report : Reports.Report;
   begin
      Lower (Item, Work, Generic_Source);
      for I in 1 .. IR.Item_Count (Landin.Stages.Code (Work).all) loop
         if IR.Instance_Position_Of
           (Landin.Stages.Code (Work).all, IR.Item_Id (I)) /= 0
         then
            IR.Mark_Address_Exposed
              (Landin.Stages.Code (Work).all, IR.Item_Id (I));
         end if;
      end loop;
      IR.Specialization.Run
        (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work),
         (Opt.Speed, Opt.All_Eligible), Report);
      Landin.Testing.Check
        (Item, Count (Landin.Stages.Code (Work).all, IR.Indirect_Call) = 1
         and then Reports.Nth_Specialization (Report, 1).Action
           = Reports.Declined
         and then Reports.Nth_Specialization (Report, 1).Reason
           = Reports.Address_Exposed,
         "all never assumes the expected table for an exposed entry");
   end Exposed_Evidence;

   procedure Raw_Any (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Report : Reports.Report;
   begin
      Lower (Item, Work,
        "display: type = concept (t: type) "
        & "code: (self: ptr t) -> (value: i32) end display "
        & "code: (self: ptr u32) -> (value: i32) = 42 end code "
        & "u32 is display (code: code) "
        & "erase_raw: () -> (result: any display) = "
        & "raw: ptr u32 = ptr(0x4002_0000) result = any(raw) end erase_raw "
        & "public main: () -> (code: i32) = _ = erase_raw() code = 42 "
        & "end main");
      IR.Specialization.Run
        (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work),
         Opt.Default_Options, Report);
      IR.Simplification.Run
        (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work), Opt.Size);
      declare
         Assembly : constant String := Landin.Backend.X86_64.Text
           (Landin.Stages.Code (Work).all, Landin.Stages.Meanings (Work).all,
            Landin.Stages.Identities (Work).all, Landin.Stages.Target (Work),
            Opt.Default_Options);
      begin
         Landin.Testing.Check (Item, Assembly'Length > 0,
                              "raw pointer evidence retains carrier shape");
      end;
      declare
         Dynamic : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Decisions : Reports.Report;
      begin
         Lower (Item, Dynamic,
           "display: type = concept (t: type) "
           & "code: (self: ptr t) -> (value: i32) end display "
           & "code: (self: ptr i32) -> (value: i32) = self.val end code "
           & "i32 is display (code: code) "
           & "public main: () -> (result: i32) = value: i32 = 42 "
           & "erased: any display = any(addr value) "
           & "result = erased.code() end main");
         IR.Specialization.Run
           (Landin.Stages.Code (Dynamic).all, Landin.Stages.Target (Dynamic),
            (Opt.Speed, Opt.All_Eligible), Decisions);
         IR.Simplification.Run
           (Landin.Stages.Code (Dynamic).all, Landin.Stages.Target (Dynamic),
            Opt.Speed);
         Landin.Testing.Check
           (Item, Count
              (Landin.Stages.Code (Dynamic).all, IR.Evidence_Self) = 1
            and then Count
              (Landin.Stages.Code (Dynamic).all, IR.Indirect_Call) = 1,
            "all retains verified erased projection and self adjacency");
      end;
   exception
      when Problem : others =>
         Landin.Testing.Fail
           (Item, Ada.Exceptions.Exception_Information (Problem)
            & Text (Work));
   end Raw_Any;

   procedure Evidence_Unit
     (Code : in out IR.Unit; Work : in out Landin.Stages.Compilation;
      Incoming : Incoming_Kind; Instances : Positive; Recursive : Boolean;
      Split_Template : Boolean := False;
      Assembly_Output : Assembly_Case := No_Assembly;
      Chain : Boolean := False;
      Aggregate_Represented : Boolean := False)
   is
      Site : constant Landin.Provenance.Origin :=
        IR.Origin_Of (Landin.Stages.Code (Work).all, 1);
      Generic_Items : array (1 .. Instances) of IR.Item_Id;
      Parameters, Locals, Outputs :
        array (Generic_Items'Range) of IR.Slot_Id;
      Root, Provider, Alternate : IR.Item_Id;
      Hidden : IR.Slot_Id := IR.No_Slot;
      Signature, Empty : IR.Signature_Id;
      Expected, Other : IR.Evidence_Id;
      Represented : IR.Field_Shape :=
        (Element => Landin.Types.I32, others => <>);
      Block : IR.Block_Id;
      Table, Projection, Called : IR.Value_Id;
   begin
      IR.Prepare (Code, Landin.Stages.Meanings (Work).all);
      Signature := IR.Add_Signature_With_Results
        (Code, [1 => (Kind => Landin.Types.Usize, others => <>)],
         IR.No_Signature_Parts);
      Empty := IR.Add_Signature_With_Results
        (Code, IR.No_Signature_Parts, IR.No_Signature_Parts);
      Provider := IR.Add_Item
        (Code, IR.Routine, IR.No_Declaration, Landin.Types.No_Value, Site);
      IR.Set_Signature (Code, Provider, Empty);
      Block := IR.Add_Block
        (Code, Provider, Landin.Resolution.Program_Scope, Site);
      IR.Enter (Code, Provider, Block);
      IR.Emit_Leave (Code, Provider, IR.No_Value, Site);
      IR.Leave_Block (Code, Provider);
      if Aggregate_Represented then
         declare
            Nominal : constant IR.Nominal_Type_Id :=
              IR.Add_Nominal_Type (Code, 1);
         begin
            IR.Set_Nominal_Shape
              (Code, Nominal,
               [(Element => Landin.Types.U8, others => <>),
                (Element => Landin.Types.U64, others => <>)]);
            Represented :=
              (Kind => IR.Aggregate_Field_Shape, Nominal => Nominal,
               others => <>);
         end;
      end if;
      if Assembly_Output /= No_Assembly then
         Alternate := IR.Add_Item
           (Code, IR.Routine, IR.No_Declaration,
            Landin.Types.No_Value, Site);
         IR.Set_Signature (Code, Alternate, Empty);
         Block := IR.Add_Block
           (Code, Alternate, Landin.Resolution.Program_Scope, Site);
         IR.Enter (Code, Alternate, Block);
         IR.Emit_Leave (Code, Alternate, IR.No_Value, Site);
         IR.Leave_Block (Code, Alternate);
      end if;
      Expected := IR.Add_Evidence
        (Code, Represented);
      IR.Add_Evidence_Entry (Code, Expected, Provider, Empty);
      Other := IR.Add_Evidence
        (Code, Represented);
      IR.Add_Evidence_Entry
        (Code, Other, (if Assembly_Output /= No_Assembly
                      then Alternate else Provider),
         Empty);
      for I in Generic_Items'Range loop
         Generic_Items (I) := IR.Add_Routine_Instance_Item
           (Code, I, (if Split_Template and then I = Instances then 2 else 1),
            Landin.Types.No_Value, Site);
         IR.Set_Signature (Code, Generic_Items (I), Signature);
         Parameters (I) := IR.Add_Parameter
           (Code, Generic_Items (I), Landin.Types.Usize,
            IR.No_Declaration, Site);
         IR.Bind_Evidence_Parameter (Code, Generic_Items (I), 1, Expected);
         if Assembly_Output /= No_Assembly then
            Locals (I) := IR.Add_Slot
              (Code, Generic_Items (I), Landin.Types.Usize,
               IR.No_Declaration, Site);
            Outputs (I) := Locals (I);
            if Assembly_Output = Unrelated_Output then
               Outputs (I) := IR.Add_Slot
                 (Code, Generic_Items (I), Landin.Types.Usize,
                  IR.No_Declaration, Site);
            end if;
         end if;
      end loop;
      Root := IR.Add_Item
        (Code, IR.Routine, IR.No_Declaration, Landin.Types.No_Value, Site);
      IR.Set_Signature
        (Code, Root, (if Incoming = Unknown_Table then Signature else Empty));
      if Incoming = Unknown_Table then
         Hidden := IR.Add_Parameter
           (Code, Root, Landin.Types.Usize, IR.No_Declaration, Site);
      end if;
      for I in Generic_Items'Range loop
         Block := IR.Add_Block
           (Code, Generic_Items (I), Landin.Resolution.Program_Scope, Site);
         IR.Enter (Code, Generic_Items (I), Block);
         Table := IR.Emit_Load (Code, Generic_Items (I), Parameters (I), Site);
         if Assembly_Output /= No_Assembly then
            declare
               Local : constant IR.Slot_Id := Locals (I);
               Output : constant IR.Slot_Id := Outputs (I);
               Other_Table : IR.Value_Id;
               Ignore : IR.Value_Id;
            begin
               IR.Emit_Store (Code, Generic_Items (I), Local, Table, Site);
               Other_Table := IR.Emit_Evidence_Address
                 (Code, Generic_Items (I), Other, Site);
               Ignore := IR.Emit_Assembly
                 (Code, Generic_Items (I),
                  Landin.Source.Names.Intern
                    (Landin.Stages.Identities (Work).all, "nop"),
                  [1 => IR.Operand_At
                    (IR.Both, Landin.Source.Names.No_Name, "rax",
                     Landin.Types.Usize, Output)],
                  [1 => Other_Table], Site);
               if Assembly_Output = Restored then
                  IR.Emit_Store
                    (Code, Generic_Items (I), Local, Table, Site);
               end if;
               Table := IR.Emit_Load
                 (Code, Generic_Items (I), Local, Site);
            end;
         end if;
         Projection := IR.Emit_Evidence_Function
           (Code, Generic_Items (I), Table, Expected, 1, Site);
         IR.Set_Loop_Depth (Code, Generic_Items (I), 1);
         Called := IR.Emit_Indirect_Call
           (Code, Generic_Items (I), Empty, Landin.Types.No_Value, Site);
         IR.Add_Argument (Code, Generic_Items (I), Called, Projection);
         IR.Set_Loop_Depth (Code, Generic_Items (I), 0);
         if Recursive then
            Called := IR.Emit_Call
              (Code, Generic_Items (I), Generic_Items (I),
               Landin.Types.No_Value, Site);
            IR.Add_Argument (Code, Generic_Items (I), Called, Table);
         end if;
         if Chain and then I > 1 then
            Called := IR.Emit_Call
              (Code, Generic_Items (I), Generic_Items (I - 1),
               Landin.Types.No_Value, Site);
            IR.Add_Argument (Code, Generic_Items (I), Called, Table);
         end if;
         IR.Emit_Leave (Code, Generic_Items (I), IR.No_Value, Site);
         IR.Leave_Block (Code, Generic_Items (I));
      end loop;
      Block := IR.Add_Block
        (Code, Root, Landin.Resolution.Program_Scope, Site);
      IR.Enter (Code, Root, Block);
      if Incoming = Unknown_Table then
         Table := IR.Emit_Load (Code, Root, Hidden, Site);
      else
         Table := IR.Emit_Evidence_Address
           (Code, Root, (if Incoming = Wrong_Table then Other else Expected),
            Site);
      end if;
      for Generic_Item of Generic_Items loop
         if not Chain or else Generic_Item = Generic_Items (Instances) then
            Called := IR.Emit_Call
              (Code, Root, Generic_Item, Landin.Types.No_Value, Site);
            IR.Add_Argument (Code, Root, Called, Table);
         end if;
      end loop;
      IR.Emit_Leave (Code, Root, IR.No_Value, Site);
      IR.Leave_Block (Code, Root);
      IR.Verifier.Verify (Code, Landin.Stages.Target (Work));
   end Evidence_Unit;

   procedure Assembly_Output_Aliases
     (Item : in out Landin.Testing.Context)
   is
      use type IR.Value_Id;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Work, "f: () -> none = end f");
      for Scenario in Overwritten .. Unrelated_Output loop
         declare
            Code : IR.Unit;
            Report : Reports.Report;
            Found : Boolean := False;
            Assembly_Slot : IR.Slot_Id := IR.No_Slot;
            Reloads_Output : Boolean := False;
            Input_Is_Other : Boolean := False;
            Other_Address : IR.Value_Id := IR.No_Value;
            Expected, Other : IR.Evidence_Id := IR.No_Evidence;
         begin
            Evidence_Unit
              (Code, Work, Literal_Table, 1, False,
               Assembly_Output => Scenario);
            Landin.Testing.Check_Equal
              (Item, Count (Code, IR.Indirect_Call), 1,
               "verified fixture starts with indirect dispatch");
            --  Check that the two table addresses really name different
            --  providers and that the overwritten case reloads the output.
            for V in 1 .. IR.Value_Count (Code, IR.Item_Id'(3)) loop
               declare
                  Id : constant IR.Value_Id := IR.Value_Id (V);
                  Op : constant IR.Opcode :=
                    IR.Op_Of (Code, IR.Item_Id'(3), Id);
               begin
                  if Op = IR.Evidence_Address then
                     Other := IR.Evidence_Of (Code, IR.Item_Id'(3), Id);
                     Other_Address := Id;
                  elsif Op = IR.Evidence_Function then
                     Expected := IR.Evidence_Of (Code, IR.Item_Id'(3), Id);
                  elsif Op = IR.Assembly then
                     Assembly_Slot := IR.Nth_Assembly_Operand
                       (Code, IR.Item_Id'(3), Id, 1).Output;
                     Input_Is_Other := IR.Nth_Operand
                       (Code, IR.Item_Id'(3), Id, 1) = Other_Address;
                  elsif Op = IR.Load and then
                    Assembly_Slot /= IR.No_Slot and then
                    IR.Slot_Of (Code, IR.Item_Id'(3), Id) = Assembly_Slot
                  then
                     Reloads_Output := True;
                  end if;
               end;
            end loop;
            Landin.Testing.Check
              (Item, Expected /= IR.No_Evidence
               and then Other /= IR.No_Evidence
               and then IR.Evidence_Entry_Target (Code, Expected, 1)
                 = IR.Item_Id'(1)
               and then IR.Evidence_Entry_Target (Code, Other, 1)
                 = IR.Item_Id'(2)
               and then Input_Is_Other
               and then (Scenario /= Overwritten or else Reloads_Output),
               "fixture has distinct table providers and output provenance");
            IR.Specialization.Run
              (Code, Landin.Stages.Target (Work),
               (Opt.Speed, Opt.All_Eligible), Report);
            if Scenario = Overwritten then
               Landin.Testing.Check
                 (Item, Reports.Nth_Specialization (Report, 1).Action
                   = Reports.Declined
                  and then Count (Code, IR.Indirect_Call) = 1,
                  "assembly output keeps dynamic dispatch");
            else
               Landin.Testing.Check
                 (Item, Reports.Nth_Specialization (Report, 1).Action
                   = Reports.Specialized
                  and then Count (Code, IR.Indirect_Call) = 0,
                  "safe store remains eligible for specialization");
               for V in 1 .. IR.Value_Count (Code, IR.Item_Id'(3)) loop
                  if IR.Op_Of (Code, IR.Item_Id'(3), IR.Value_Id (V))
                    = IR.Call
                  then
                     Found := True;
                     Landin.Testing.Check
                       (Item, IR.Callee_Of
                          (Code, IR.Item_Id'(3), IR.Value_Id (V))
                            = IR.Item_Id'(1),
                        "safe dispatch targets expected provider");
                  end if;
               end loop;
               Landin.Testing.Check
                 (Item, Found, "safe fixture contains direct call");
            end if;
         end;
      end loop;
   end Assembly_Output_Aliases;

   procedure Sparse_Instance_Items (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Code, Fresh : IR.Unit;
   begin
      Lower (Item, Work, "f: () -> none = end f");
      declare
         Site : constant Landin.Provenance.Origin :=
           IR.Origin_Of (Landin.Stages.Code (Work).all, 1);
         Ordinary, First, Far, Middle, Later, Reused : IR.Item_Id;
      begin
         IR.Prepare (Code, Landin.Stages.Meanings (Work).all);
         IR.Prepare (Fresh, Landin.Stages.Meanings (Work).all);
         Ordinary := IR.Add_Item
           (Code, IR.Routine, IR.No_Declaration, Landin.Types.No_Value,
            Site);
         First := IR.Add_Routine_Instance_Item
           (Code, 1, 1, Landin.Types.No_Value, Site);
         Far := IR.Add_Routine_Instance_Item
           (Code, 1_000_000, 1, Landin.Types.No_Value, Site);
         Middle := IR.Add_Routine_Instance_Item
           (Code, 17, 1, Landin.Types.No_Value, Site);
         Later := IR.Add_Item
           (Code, IR.Routine, IR.No_Declaration, Landin.Types.No_Value,
            Site);
         Landin.Testing.Check
           (Item,
            Ordinary = 1 and then First = 2 and then Far = 3
              and then Middle = 4 and then Later = 5
              and then IR.Item_For_Instance (Code, 1) = First
              and then IR.Item_For_Instance (Code, 1_000_000) = Far
              and then IR.Item_For_Instance (Code, 17) = Middle
              and then IR.Item_For_Instance (Code, 2) = IR.No_Item
              and then IR.Item_For_Instance (Code, 999_999) = IR.No_Item
              and then IR.Item_For_Instance (Code, 17) = Middle
              and then IR.Instance_Position_Of (Code, Far) = 1_000_000
              and then IR.Generic_Template_Of (Code, Far) = 1,
            "sparse checker positions retain their item identities");

         Landin.Testing.Check
           (Item, IR.Item_For_Instance (Fresh, 1) = IR.No_Item,
            "a fresh unit has no instance mappings");
         Reused := IR.Add_Routine_Instance_Item
           (Fresh, 17, 1, Landin.Types.No_Value, Site);
         Landin.Testing.Check
           (Item, Reused = 1
             and then IR.Item_For_Instance (Fresh, 17) = Reused
             and then IR.Item_For_Instance (Fresh, 1_000_000) = IR.No_Item
             and then IR.Item_For_Instance (Code, 17) = Middle,
            "instance mappings are owned by each unit");
      end;
   end Sparse_Instance_Items;

   procedure Incoming_Evidence (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Work, "f: () -> none = end f");
      for Incoming in Incoming_Kind loop
         for Recursive in Boolean loop
            declare
               Code : IR.Unit;
               Report : Reports.Report;
            begin
               Evidence_Unit (Code, Work, Incoming, 1, Recursive);
               IR.Specialization.Run
                 (Code, Landin.Stages.Target (Work),
                  (Opt.Speed, Opt.All_Eligible), Report);
               declare
                  Decision : constant Reports.Specialization_Decision :=
                    Reports.Nth_Specialization (Report, 1);
               begin
                  Landin.Testing.Check
                    (Item, (if Incoming = Literal_Table
                            then Decision.Action = Reports.Specialized
                              and then Count (Code, IR.Indirect_Call) = 0
                            else Decision.Action = Reports.Declined
                              and then Decision.Reason
                                = Reports.Unknown_Evidence
                              and then Count (Code, IR.Indirect_Call) = 1),
                     "incoming proof, including a recursive forwarding edge: "
                     & Incoming'Image & Recursive'Image);
               end;
            end;
         end loop;
      end loop;
      declare
         Code : IR.Unit;
         Report : Reports.Report;
         Callable : IR.Evidence_Id;
      begin
         Evidence_Unit (Code, Work, Literal_Table, 1, True);
         Callable := IR.Add_Evidence
           (Code, (Element => Landin.Types.I32, others => <>));
         IR.Add_Evidence_Entry
           (Code, Callable, 2, IR.Signature_Of (Code, IR.Item_Id'(2)));
         IR.Specialization.Run
           (Code, Landin.Stages.Target (Work),
            (Opt.Speed, Opt.All_Eligible), Report);
         Landin.Testing.Check
           (Item, Reports.Nth_Specialization (Report, 1).Reason
              = Reports.Address_Exposed
            and then Count (Code, IR.Indirect_Call) = 1,
            "table-callable recursion keeps an unknown-evidence fallback");
      end;
   end Incoming_Evidence;

   procedure Forwarded_Evidence_Chain
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Chain_Length : constant Positive := 20;
   begin
      Lower (Item, Work, "f: () -> none = end f");
      for Incoming in Incoming_Kind loop
         declare
            Code : IR.Unit;
            Report : Reports.Report;
            Expected : constant Boolean := Incoming = Literal_Table;
         begin
            Evidence_Unit
              (Code, Work, Incoming, Chain_Length, False, Chain => True);
            IR.Specialization.Run
              (Code, Landin.Stages.Target (Work),
               (Opt.Speed, Opt.All_Eligible), Report);
            Landin.Testing.Check_Equal
              (Item, Reports.Specialization_Count (Report), Chain_Length,
               "every forwarded instance has a decision");
            for I in 1 .. Chain_Length loop
               declare
                  Decision : constant Reports.Specialization_Decision :=
                    Reports.Nth_Specialization (Report, I);
               begin
                  Landin.Testing.Check
                    (Item, Decision.Action =
                       (if Expected then Reports.Specialized
                        else Reports.Declined)
                     and then Decision.Reason =
                       (if Expected then Reports.Forced
                        else Reports.Unknown_Evidence),
                     "forwarded evidence follows the late root: "
                     & Incoming'Image & Positive'Image (I));
               end;
            end loop;
            Landin.Testing.Check_Equal
              (Item, Count (Code, IR.Indirect_Call),
               (if Expected then 0 else Chain_Length),
               "forwarded dispatch follows the late root");
         end;
      end loop;
      --  The dependency graph must use the same post-assembly aliases as
      --  direct dispatch, including a restoring store and unrelated outputs.
      for Scenario in Overwritten .. Unrelated_Output loop
         declare
            Code : IR.Unit;
            Report : Reports.Report;
         begin
            Evidence_Unit
              (Code, Work, Literal_Table, Chain_Length, False,
               Assembly_Output => Scenario, Chain => True);
            IR.Specialization.Run
              (Code, Landin.Stages.Target (Work),
               (Opt.Speed, Opt.All_Eligible), Report);
            Landin.Testing.Check_Equal
              (Item, Count (Code, IR.Indirect_Call),
               (if Scenario = Overwritten then Chain_Length else 0),
               "forwarded dispatch respects assembly writes and restores");
            for I in 1 .. Chain_Length loop
               Landin.Testing.Check
                 (Item, Reports.Nth_Specialization (Report, I).Action =
                    (if Scenario = Overwritten then Reports.Declined
                     else Reports.Specialized),
                  "forwarded assembly evidence retains its decision");
            end loop;
         end;
      end loop;
   end Forwarded_Evidence_Chain;

   procedure Instance_Costs (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Work, "f: () -> none = end f");
      for Objective in Opt.Objective loop
         for Mode in Opt.Specialization_Mode loop
            declare
               Code : IR.Unit;
               Report : Reports.Report;
               Selected : constant Boolean := Mode = Opt.All_Eligible
                 or else (Mode = Opt.Auto and then Objective = Opt.Speed);
            begin
               Evidence_Unit (Code, Work, Literal_Table, 2, False);
               IR.Specialization.Run
                 (Code, Landin.Stages.Target (Work),
                  (Objective, Mode), Report);
               Landin.Testing.Check_Equal
                 (Item, Count (Code, IR.Indirect_Call),
                  (if Selected then 0 else 2),
                  "two instances use independent objective and mode");
               for I in 1 .. 2 loop
                  declare
                     Decision : constant Reports.Specialization_Decision :=
                       Reports.Nth_Specialization (Report, I);
                  begin
                     Landin.Testing.Check
                       (Item, Decision.Benefit = 17
                        --  D211: at speed a rewrite inside an existing
                        --  instance grows nothing; elsewhere it may split
                        --  a shared body, so the body is charged.
                        and then Decision.Estimated_Growth =
                          (if Objective = Opt.Speed then 0 else 12)
                        and then Decision.Reason =
                          (if Mode = Opt.Off then Reports.Disabled
                           elsif Mode = Opt.All_Eligible then Reports.Forced
                           elsif Selected then Reports.Profitable
                           else Reports.Cost_Threshold),
                        "measured IR cost uses the documented threshold");
                  end;
               end loop;
            end;
         end loop;
      end loop;
      declare
         Code : IR.Unit;
         Report : Reports.Report;
      begin
         Evidence_Unit
           (Code, Work, Literal_Table, 2, False,
            Aggregate_Represented => True);
         IR.Specialization.Run
           (Code, Landin.Stages.Target (Work),
            (Opt.Speed, Opt.Off), Report);
         for I in 1 .. 2 loop
            Landin.Testing.Check
              (Item, Reports.Nth_Specialization (Report, I)
                 .Represented_Bytes = 16,
               "repeated aggregate evidence keeps its represented cost");
         end loop;
      end;
   end Instance_Costs;

   procedure Template_Counts_Are_Independent
     (Item : in out Landin.Testing.Context);

   procedure Template_Counts_Are_Independent
     (Item : in out Landin.Testing.Context)
   is
   begin
      for Wide in Boolean loop
         declare
            Facts : constant Landin.Targets.Target_Facts :=
              (if Wide then Landin.Targets.Linux_X86_64
               else Landin.Targets.Synthetic_32);
            Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         begin
            Lower (Item, Work,
                   "f: () -> none = end f g: () -> none = end g");
            for Objective in Opt.Objective range Opt.Size .. Opt.Speed loop
               for Expose in Boolean loop
                  declare
                     Code : IR.Unit;
                     Report : Reports.Report;
                  begin
                     Evidence_Unit
                       (Code, Work, Literal_Table, 3, False,
                        Split_Template => True);
                     if Expose then
                        --  Item 1 is the provider; item 3 is the second
                        --  instance of f.  A retained table exposes its
                        --  address.
                        declare
                           Table : constant IR.Evidence_Id :=
                             IR.Add_Evidence
                               (Code,
                                (Element => Landin.Types.I32, others => <>));
                        begin
                           IR.Add_Evidence_Entry
                             (Code, Table, 3,
                              IR.Signature_Of (Code, IR.Item_Id'(3)));
                        end;
                     end if;
                     IR.Specialization.Run
                       (Code, Facts, (Objective, Opt.Auto), Report);
                     Landin.Testing.Check_Equal
                       (Item, Reports.Specialization_Count (Report), 3,
                        "two templates retain three normalized decisions");
                     for I in 1 .. 3 loop
                        declare
                           Decision : constant
                             Reports.Specialization_Decision :=
                               Reports.Nth_Specialization (Report, I);
                           Single : constant Boolean :=
                             I = 3 or else (Expose and then I = 1);
                        begin
                           Landin.Testing.Check
                             (Item, Decision.Reason =
                                (if Single then Reports.Single_Instance
                                 elsif Expose then Reports.Address_Exposed
                                 elsif Objective = Opt.Speed
                                 then Reports.Profitable
                                 else Reports.Cost_Threshold),
                              "counts exclude other templates and exposed "
                              & "roots");
                           Landin.Testing.Check
                             (Item, Decision.Action =
                                (if Single or else (Objective = Opt.Speed
                                                     and then not Expose)
                                 then Reports.Specialized
                                 else Reports.Declined),
                              "counting does not override evidence or cost");
                        end;
                     end loop;
                     Landin.Testing.Check_Equal
                       (Item, Count (Code, IR.Indirect_Call),
                        (if Expose then 1
                         elsif Objective = Opt.Speed then 0 else 2),
                        "unselected instances retain their dispatch fallback");
                  end;
               end loop;
            end loop;
         end;
      end loop;
   end Template_Counts_Are_Independent;

   procedure Exposure_Traversal_Keeps_References
     (Item : in out Landin.Testing.Context);

   procedure Exposure_Traversal_Keeps_References
     (Item : in out Landin.Testing.Context)
   is
      Source : constant String :=
        "callback: type = () -> none "
        & "public exported: () -> none = end exported "
        & "plain: () -> none = end plain "
        & "static_target: () -> none = end static_target "
        & "aggregate_target: () -> none = end aggregate_target "
        & "addressed: () -> none = end addressed "
        & "current: callback = static_target "
        & "holder: type = struct cb: callback end holder "
        & "image: holder = (cb: aggregate_target) "
        & "public run: () -> none = "
        & "a := addressed b := addressed a() b() end run";
   begin
      for Wide in Boolean loop
         declare
            Facts : constant Landin.Targets.Target_Facts :=
              (if Wide then Landin.Targets.Linux_X86_64
               else Landin.Targets.Synthetic_32);
            Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
            Evidence_Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Facts);
         begin
            Lower (Item, Work, Source
                   & (if Wide then " extern(c) imported: () -> none"
                      else ""));
            declare
               Code : IR.Unit renames Landin.Stages.Code (Work).all;
               Visits : array (1 .. IR.Item_Count (Code)) of Natural :=
                 [others => 0];
               Total : Natural := 0;
               procedure Note (Target : IR.Item_Id);

               procedure Note (Target : IR.Item_Id) is
               begin
                  Visits (Positive (Target)) := Visits (Positive (Target)) + 1;
                  Total := Total + 1;
               end Note;
            begin
               IR.Visit_Address_Exposures (Code, Note'Access);
               Landin.Testing.Check_Equal
                 (Item, Total, (if Wide then 8 else 7),
                  "one callback per retained reference or explicit marker");
               for Index in Visits'Range loop
                  declare
                     Target : constant IR.Item_Id := IR.Item_Id (Index);
                  begin
                     if IR.Kind_Of (Code, Target) = IR.Routine then
                        declare
                           Name : constant String :=
                             Landin.Source.Names.Spelling
                               (Landin.Stages.Identities (Work).all,
                                Landin.Resolution.Name_Of
                                  (Landin.Stages.Meanings (Work).all,
                                   IR.Declares (Code, Target)));
                           Expected : constant Natural :=
                             (if Name = "plain" then 0
                              elsif Name in "addressed" | "static_target"
                              then 2 else 1);
                        begin
                           Landin.Testing.Check_Equal
                             (Item, Visits (Index), Expected,
                              "retained exposure source: " & Name);
                           Landin.Testing.Check
                             (Item, IR.Has_Address_Exposure (Code, Target)
                                = (Expected > 0),
                              "single queries share the traversal policy");
                        end;
                     end if;
                  end;
               end loop;
            end;
            Lower (Item, Evidence_Work, "f: () -> none = end f");
            declare
               Code : IR.Unit;
               Visits : array (1 .. 3) of Natural := [others => 0];
               procedure Note (Target : IR.Item_Id);

               procedure Note (Target : IR.Item_Id) is
               begin
                  Visits (Positive (Target)) := Visits (Positive (Target)) + 1;
               end Note;
            begin
               Evidence_Unit (Code, Evidence_Work, Literal_Table, 1, False);
               IR.Visit_Address_Exposures (Code, Note'Access);
               Landin.Testing.Check
                 (Item, Visits = [2, 0, 0],
                  "two retained evidence entries expose the provider only");
               IR.Mark_Address_Exposed (Code, 2);
               Visits := [others => 0];
               IR.Visit_Address_Exposures (Code, Note'Access);
               Landin.Testing.Check
                 (Item, Visits = [2, 1, 0],
                  "a fresh traversal sees a later explicit exposure marker");
            end;
         end;
      end loop;
   end Exposure_Traversal_Keeps_References;

   procedure Large_Graph (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Code : IR.Unit;
      Routine : IR.Item_Id;
      Blocks : array (1 .. 2048) of IR.Block_Id;
      Condition : IR.Value_Id;
   begin
      Lower (Item, Work, "f: () -> none = end f");
      IR.Prepare (Code, Landin.Stages.Meanings (Work).all);
      declare
         Site : constant Landin.Provenance.Origin :=
           IR.Origin_Of (Landin.Stages.Code (Work).all, 1);
      begin
         Routine := IR.Add_Item
           (Code, IR.Routine, 1, Landin.Types.No_Value, Site);
         for B in Blocks'Range loop
            Blocks (B) := IR.Add_Block
              (Code, Routine, Landin.Resolution.Program_Scope, Site);
         end loop;
         for B in Blocks'Range loop
            IR.Enter (Code, Routine, Blocks (B));
            if B <= 1023 then
               Condition := IR.Emit_Truth (Code, Routine, True, Site);
               IR.Emit_Branch
                 (Code, Routine, Condition, Blocks (B + 1),
                  Blocks (B + 1024), Site);
            elsif B = 1024 then
               IR.Emit_Jump (Code, Routine, Blocks (2048), Site);
            else
               IR.Emit_Leave (Code, Routine, IR.No_Value, Site);
            end if;
            IR.Leave_Block (Code, Routine);
         end loop;
         IR.Verifier.Verify (Code, Landin.Stages.Target (Work));
         declare
            Graph : constant IR.Control_Flow.Graph :=
              IR.Control_Flow.Make (Code, Routine);
         begin
            Landin.Testing.Check
              (Item, IR.Control_Flow.Node_Visits (Graph) = 2048
               and then IR.Control_Flow.Edge_Visits (Graph) = 2047,
               "large sparse CFG traversal visits each node and edge once");
         end;
         IR.Simplification.Run
           (Code, Landin.Stages.Target (Work), Opt.Size);
         Landin.Testing.Check
           (Item, IR.Block_Count (Code, Routine) = 1025
            and then Count (Code, IR.Branch) = 0
            and then IR.Target_Of
              (Code, Routine, IR.Nth_Value (Code, Routine, 1024, 1)) = 1025
            and then IR.Origin_Of (Code, Routine, IR.Value_Id'(1)) = Site,
            "compaction removes islands and remaps jumps, keeping sites");
         Blocks (1) := IR.Add_Block
           (Code, Routine, Landin.Resolution.Program_Scope, Site);
         declare
            Before : constant String := IR.Dump.Text
              (Code, Landin.Stages.Meanings (Work).all,
               Landin.Stages.Identities (Work).all);
            Report : Reports.Report;
         begin
            begin
               IR.Specialization.Run
                 (Code, Landin.Stages.Target (Work),
                  (Opt.None, Opt.Off), Report);
               Landin.Testing.Fail
                 (Item, "disabled specialization accepted malformed input");
            exception
               when Landin.Compiler_Defect =>
                  Landin.Testing.Check_Equal
                    (Item, Reports.Specialization_Count (Report), 0,
                     "malformed input is refused before decisions");
            end;
            begin
               IR.Simplification.Run
                 (Code, Landin.Stages.Target (Work), Opt.None);
               Landin.Testing.Fail
                 (Item, "disabled simplification accepted malformed input");
            exception
               when Landin.Compiler_Defect =>
                  null;
            end;
            begin
               IR.Simplification.Run
                 (Code, Landin.Stages.Target (Work), Opt.Size);
               Landin.Testing.Fail (Item, "malformed input accepted");
            exception
               when Landin.Compiler_Defect =>
                  Landin.Testing.Check_Equal
                    (Item, IR.Dump.Text
                       (Code, Landin.Stages.Meanings (Work).all,
                        Landin.Stages.Identities (Work).all), Before,
                     "invalid input is refused before any rewrite");
            end;
         end;
      end;
   end Large_Graph;

   procedure Scalar_Boundaries (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      type Example is record
         Kind : Landin.Types.Integer_Name;
         Op : IR.Binary_Kind;
         Left, Right, Answer : Landin.Types.Folded;
         Folds, Unchecked : Boolean;
      end record;
      Examples : constant array (Positive range <>) of Example :=
        [(Landin.Types.U64, IR.Wrapping_Add, 2 ** 64 - 1, 1, 0, True, False),
         (Landin.Types.U64, IR.Add, 2 ** 64 - 1, 1, 0, False, False),
         (Landin.Types.U64, IR.Multiply, 2 ** 64 - 1,
          2 ** 64 - 1, 0, False, False),
         (Landin.Types.U64, IR.Wrapping_Multiply, 2 ** 64 - 1,
          2 ** 64 - 1, 1, True, False),
         (Landin.Types.I64, IR.Divide, -(2 ** 63), -1, 0, False, False),
         (Landin.Types.I64, IR.Remainder, -(2 ** 63), -1, 0, True, False),
         (Landin.Types.I32, IR.Divide, 3, 0, 0, False, True),
         (Landin.Types.I32, IR.Shift_Left, 1, -1, 0, False, True),
         (Landin.Types.I32, IR.Shift_Right, -16, 2, -4, True, False),
         (Landin.Types.I8, IR.Add, 127, 1, -128, True, True),
         (Landin.Types.I8, IR.Subtract, -128, 1, 0, False, False),
         (Landin.Types.I8, IR.Wrapping_Subtract, -128, 1, 127, True, False)];
   begin
      Lower (Item, Work, "f: () -> none = end f");
      for Example of Examples loop
         for Discard in Boolean loop
            declare
               Code : IR.Unit;
               Site : constant Landin.Provenance.Origin :=
                 IR.Origin_Of (Landin.Stages.Code (Work).all, 1);
               Routine : IR.Item_Id;
               Block : IR.Block_Id;
               Left, Right, Answer : IR.Value_Id;
            begin
               IR.Prepare (Code, Landin.Stages.Meanings (Work).all);
               Routine := IR.Add_Item
                 (Code, IR.Routine, 1,
                  (if Discard then Landin.Types.No_Value else Example.Kind),
                  Site);
               Block := IR.Add_Block
                 (Code, Routine, Landin.Resolution.Program_Scope, Site);
               IR.Enter (Code, Routine, Block);
               Left := IR.Emit_Number
                 (Code, Routine, Example.Kind,
                  Landin.Types.Magnitude (abs Example.Left),
                  Example.Left < 0, Site);
               Right := IR.Emit_Number
                 (Code, Routine, Example.Kind,
                  Landin.Types.Magnitude (abs Example.Right),
                  Example.Right < 0, Site);
               if Example.Unchecked then
                  IR.Begin_Unchecked (Code, Routine);
               end if;
               Answer := IR.Emit_Binary
                 (Code, Routine, Example.Op, Left, Right, Example.Kind, Site);
               if Example.Unchecked then
                  IR.End_Unchecked (Code, Routine);
               end if;
               IR.Emit_Leave
                 (Code, Routine, (if Discard then IR.No_Value else Answer),
                  Site);
               IR.Leave_Block (Code, Routine);
               IR.Simplification.Run
                 (Code, Landin.Stages.Target (Work), Opt.Size);
               Landin.Testing.Check_Equal
                 (Item, Count (Code, Example.Op),
                  (if Example.Folds then 0 else 1),
                  "safe folds and discarded mandatory traps: "
                  & Example.Op'Image & Discard'Image);
               if Example.Folds and then not Discard then
                  Answer := IR.Nth_Operand
                    (Code, Routine,
                     IR.Value_Id (IR.Value_Count (Code, Routine)), 1);
                  Landin.Testing.Check
                    (Item, IR.Op_Of (Code, Routine, Answer) = IR.Number
                     and then IR.Number_Of (Code, Routine, Answer)
                       = Landin.Types.Magnitude (abs Example.Answer)
                     and then IR.Is_Negated (Code, Routine, Answer)
                       = (Example.Answer < 0),
                     "folded result retains exact target integer bits");
               end if;
            end;
         end loop;
      end loop;
      for Synthetic in Boolean loop
         declare
            Code : IR.Unit;
            Facts : constant Landin.Targets.Target_Facts :=
              (if Synthetic then Landin.Targets.Synthetic_32
               else Landin.Targets.Linux_X86_64);
            Site : constant Landin.Provenance.Origin :=
              IR.Origin_Of (Landin.Stages.Code (Work).all, 1);
            Routine : IR.Item_Id;
            Block : IR.Block_Id;
            Left, Right, Answer : IR.Value_Id;
         begin
            IR.Prepare (Code, Landin.Stages.Meanings (Work).all);
            Routine := IR.Add_Item
              (Code, IR.Routine, 1, Landin.Types.Usize, Site);
            Block := IR.Add_Block
              (Code, Routine, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Code, Routine, Block);
            Left := IR.Emit_Number
              (Code, Routine, Landin.Types.Usize, 2 ** 32 - 1, False, Site);
            Right := IR.Emit_Number
              (Code, Routine, Landin.Types.Usize, 1, False, Site);
            Answer := IR.Emit_Binary
              (Code, Routine, IR.Wrapping_Add, Left, Right,
               Landin.Types.Usize, Site);
            IR.Emit_Leave (Code, Routine, Answer, Site);
            IR.Leave_Block (Code, Routine);
            IR.Simplification.Run (Code, Facts, Opt.Size);
            Answer := IR.Nth_Operand
              (Code, Routine, IR.Value_Id (IR.Value_Count (Code, Routine)), 1);
            Landin.Testing.Check
              (Item, IR.Op_Of (Code, Routine, Answer) = IR.Number
               and then IR.Number_Of (Code, Routine, Answer)
                 = (if Synthetic then 0 else 2 ** 32),
               "usize folding uses the selected target, not the host");
         end;
      end loop;
   end Scalar_Boundaries;

   procedure Policy_Boundaries (Item : in out Landin.Testing.Context) is
      package Policy renames IR.Specialization_Policy;
   begin
      Landin.Testing.Check
        (Item, Policy.Benefit (0, 0, 0) = 0
         and then Policy.Benefit (1, 0, 1) = 9
         and then Policy.Benefit (32, 4, 16) = 1296
         and then Policy.Benefit
           (Natural'Last, Natural'Last, Natural'Last) = 1296,
         "entry, loop and size caps bound cost arithmetic");
      Landin.Testing.Check
        (Item, not Policy.Profitable (39, 10, Opt.Size)
         and then Policy.Profitable (40, 10, Opt.Size)
         and then not Policy.Profitable (9, 10, Opt.Speed)
         and then Policy.Profitable (10, 10, Opt.Speed)
         and then not Policy.Profitable (39, 10, Opt.None)
         and then not Policy.Profitable
           (Natural'Last, Natural'Last, Opt.Size),
         "inclusive size/speed thresholds do not overflow growth times four");
   end Policy_Boundaries;

   procedure Cyclic_Islands (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Sizes : constant array (1 .. 2) of Positive := [1000, 10000];
   begin
      Lower (Item, Work, "f: () -> none = end f");
      for Size of Sizes loop
         for Island in Boolean loop
            declare
               Code : IR.Unit;
               Site : constant Landin.Provenance.Origin :=
                 IR.Origin_Of (Landin.Stages.Code (Work).all, 1);
               Routine : IR.Item_Id;
               Blocks : array (1 .. Size) of IR.Block_Id;
            begin
               IR.Prepare (Code, Landin.Stages.Meanings (Work).all);
               Routine := IR.Add_Item
                 (Code, IR.Routine, 1, Landin.Types.No_Value, Site);
               for B in Blocks'Range loop
                  Blocks (B) := IR.Add_Block
                    (Code, Routine, Landin.Resolution.Program_Scope, Site);
               end loop;
               for B in Blocks'Range loop
                  IR.Enter (Code, Routine, Blocks (B));
                  if Island and then B = Size - 2 then
                     IR.Emit_Leave (Code, Routine, IR.No_Value, Site);
                  else
                     IR.Emit_Jump
                       (Code, Routine,
                        (if B = Size then Blocks (Size - 1)
                         else Blocks (B + 1)), Site);
                  end if;
                  IR.Leave_Block (Code, Routine);
               end loop;
               declare
                  Graph : constant IR.Control_Flow.Graph :=
                    IR.Control_Flow.Make (Code, Routine);
                  Fault : constant IR.Verifier.Fault := IR.Verifier.Check
                    (Code, Landin.Stages.Target (Work));
                  Edges : Natural := 0;
               begin
                  for B in Blocks'Range loop
                     declare
                        Edge : Natural := IR.Control_Flow.First_Predecessor
                          (Graph, Blocks (B));
                     begin
                        while Edge /= 0 loop
                           Edges := Edges + 1;
                           Edge := IR.Control_Flow.Next_Predecessor
                             (Graph, Edge);
                        end loop;
                     end;
                  end loop;
                  Landin.Testing.Check
                    (Item, Edges = Size - (if Island then 1 else 0)
                     and then IR.Control_Flow.Node_Visits (Graph)
                       = Size - (if Island then 2 else 0)
                     and then IR.Control_Flow.Edge_Visits (Graph)
                       = Size - (if Island then 3 else 0),
                     "successor and predecessor work scales with edges: "
                     & Size'Image & Island'Image);
                  Landin.Testing.Check
                    (Item, (if Island then Fault.Kind
                              = IR.Verifier.Block_Unreachable
                            and then Fault.Block = IR.Block_Id (Size - 1)
                            else Fault.Kind = IR.Verifier.Nothing_Wrong),
                     "incoming edges do not prove a cyclic island reachable");
               end;
            end;
         end loop;
      end loop;
   end Cyclic_Islands;

   procedure Partial_Dispatch_Reports_Remaining_Calls
     (Item : in out Landin.Testing.Context);

   procedure Partial_Dispatch_Reports_Remaining_Calls
     (Item : in out Landin.Testing.Context)
   is
      Common : constant String :=
        "ordered: type = concept (t: type) "
        & "less: (a: t, b: t) -> (r: bool) end ordered "
        & "less: (a: i32, b: i32) -> (r: bool) = a < b end less "
        & "i32 is ordered (less: less) ";

      procedure Check_Source (Label, Source : String);

      procedure Check_Source (Label, Source : String) is
         procedure Check_Target (Facts : Landin.Targets.Target_Facts);

         procedure Check_Target (Facts : Landin.Targets.Target_Facts) is
            Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
            Report : Reports.Report;
         begin
            Lower (Item, Work, Common & Source);
            IR.Specialization.Run
              (Landin.Stages.Code (Work).all, Facts,
               (Opt.Speed, Opt.All_Eligible), Report);
            Landin.Testing.Check_Equal
              (Item, Reports.Specialization_Count (Report), 1,
               Label & " reports the single generic instance");
            if Reports.Specialization_Count (Report) /= 1 then
               return;
            end if;
            declare
               Decision : constant Reports.Specialization_Decision :=
                 Reports.Nth_Specialization (Report, 1);
               Unit : IR.Unit renames Landin.Stages.Code (Work).all;
               Remaining : Natural := 0;
            begin
               for V in 1 .. IR.Value_Count (Unit, Decision.Item) loop
                  if IR.Op_Of (Unit, Decision.Item, IR.Value_Id (V))
                    = IR.Indirect_Call
                  then
                     Remaining := Remaining + 1;
                  end if;
               end loop;
               Landin.Testing.Check
                 (Item, Decision.Action = Reports.Specialized
                  and then Decision.Direct_Calls_Made = 1,
                  Label & " specializes the proven evidence call");
               Landin.Testing.Check_Equal
                 (Item, Remaining, 1,
                  Label & " preserves the independent indirect call");
               Landin.Testing.Check
                 (Item, Decision.Retains_Fallback,
                  Label & " reports the surviving indirect dispatch");
            end;
         end Check_Target;
      begin
         Check_Target (Landin.Targets.Linux_X86_64);
         Check_Target (Landin.Targets.Synthetic_32);
      end Check_Source;
   begin
      Check_Source
        ("function value",
         "ready: () -> (r: bool) = true end ready "
         & "choose: (t: type is ordered, a: t, b: t, callback: () -> "
         & "(r: bool)) -> (r: t) = if callback() then if t.less(a,b) "
         & "then a else b end if else a end if end choose "
         & "main: () -> (r: i32) = choose(1, 2, ready) end main");
      Check_Source
        ("erased evidence",
         "display: type = concept (t: type) "
         & "ready: (self: ptr t) -> (r: bool) end display "
         & "ready: (self: ptr i32) -> (r: bool) = true end ready "
         & "i32 is display (ready: ready) "
         & "choose: (t: type is ordered, a: t, b: t, view: any display) "
         & "-> (r: t) = if view.ready() then if t.less(a,b) then a else "
         & "b end if else a end if end choose "
         & "main: () -> (r: i32) = item: i32 = 1 view: any display = "
         & "any(addr item) choose(1, 2, view) end main");
   end Partial_Dispatch_Reports_Remaining_Calls;

   procedure Measurement_Dumps_Name_Their_Types
     (Item : in out Landin.Testing.Context);

   procedure Measurement_Dumps_Name_Their_Types
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Target (Facts : Landin.Targets.Target_Facts);

      procedure Check_Target (Facts : Landin.Targets.Target_Facts) is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
      begin
         Lower
           (Item, Work,
            "small: () -> (r: usize) = sizeof u8 end small "
            & "large: () -> (r: usize) = sizeof u64 end large "
            & "aligned: () -> (r: usize) = alignof u32 end aligned "
            & "pair: type = struct a: u8 b: u64 end pair "
            & "aggregate: () -> (r: usize) = sizeof pair end aggregate");
         declare
            Dump : constant String := Text (Work);
         begin
            Landin.Testing.Check
              (Item, Ada.Strings.Fixed.Index
                 (Dump, "MEASURE_SIZE usize measured u8") > 0,
               "a byte measurement names its measured type");
            Landin.Testing.Check
              (Item, Ada.Strings.Fixed.Index
                 (Dump, "MEASURE_SIZE usize measured u64") > 0,
               "a wide measurement differs despite the same result type");
            Landin.Testing.Check
              (Item, Ada.Strings.Fixed.Index
                 (Dump, "MEASURE_ALIGN usize measured u32") > 0,
               "alignment names its measured type too");
            Landin.Testing.Check
              (Item, Ada.Strings.Fixed.Index
                 (Dump, "MEASURE_SIZE usize fields u8 u64") > 0,
               "aggregate measurements retain their field sequence");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64);
      Check_Target (Landin.Targets.Synthetic_32);
   end Measurement_Dumps_Name_Their_Types;

   procedure Dead_Function_Addresses
     (Item : in out Landin.Testing.Context);

   procedure Dead_Function_Addresses
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Target (Facts : Landin.Targets.Target_Facts);

      procedure Check_Target (Facts : Landin.Targets.Target_Facts) is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Code : IR.Unit;
         Report : Reports.Report;
      begin
         Lower (Item, Work, "f: () -> none = end f");
         Evidence_Unit (Code, Work, Literal_Table, 1, False);
         IR.Specialization.Run
           (Code, Facts, (Opt.Speed, Opt.All_Eligible), Report);
         Landin.Testing.Check_Equal
           (Item, Count (Code, IR.Function_Address), 1,
            "specialization leaves one typed address after its direct call");
         IR.Simplification.Run (Code, Facts, Opt.None);
         Landin.Testing.Check_Equal
           (Item, Count (Code, IR.Function_Address), 1,
            "none retains the reference instruction stream");
         IR.Simplification.Run (Code, Facts, Opt.Speed);
         Landin.Testing.Check_Equal
           (Item, Count (Code, IR.Function_Address), 0,
            "the unused function address has no observable effect");
         Landin.Testing.Check_Equal
           (Item, Count (Code, IR.Call), 2,
            "both the instance call and the provider call remain");
         declare
            Live : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         begin
            Lower
              (Item, Live,
               "invoke: (callback: () -> none) -> none = callback() "
               & "end invoke noop: () -> none = end noop "
               & "run: () -> none = invoke(noop) end run");
            declare
               Unit : IR.Unit renames Landin.Stages.Code (Live).all;
               Typed : Natural := 0;
            begin
               IR.Simplification.Run (Unit, Facts, Opt.Speed);
               for I in 1 .. IR.Item_Count (Unit) loop
                  for V in 1 .. IR.Value_Count (Unit, IR.Item_Id (I)) loop
                     if IR.Op_Of (Unit, IR.Item_Id (I), IR.Value_Id (V))
                       = IR.Function_Address
                       and then IR.Signature_Of
                         (Unit, IR.Item_Id (I), IR.Value_Id (V))
                           /= IR.No_Signature
                     then
                        Typed := Typed + 1;
                     end if;
                  end loop;
               end loop;
               Landin.Testing.Check_Equal
                 (Item, Typed, 1,
                  "a passed function value retains its signature");
               Landin.Testing.Check_Equal
                 (Item, Count (Unit, IR.Indirect_Call), 1,
                  "the callback still has its verified indirect use");
            end;
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64);
      Check_Target (Landin.Targets.Synthetic_32);
   end Dead_Function_Addresses;

   --  D94's callee copy goes only where nothing could tell: each routine
   --  below either reads its `in` aggregate where the caller keeps it or
   --  keeps the copy, and a slice argument loses its caller temporary.
   procedure In_Place_Parameters (Item : in out Landin.Testing.Context) is
      Source : constant String :=
        "pair: type = struct left: u64 right: u64 rows: [6]u64 end pair "
        & "mut global: pair = zeroed "
        --  Only reads.
        & "total: (value: pair) -> (sum: u64) = "
        & "sum = value.left + value.rows[5] end total "
        --  Its address is taken.
        & "apart: (value: pair) -> (at: usize) = "
        & "at = usize(addr value) end apart "
        --  The original is written through an inout place before a read.
        & "inout_first: (value: pair, inout original: pair) -> (seen: u64) = "
        & "original.left = 1 seen = value.left end inout_first "
        --  A call that writes the original falls between two reads.
        & "set_right: (inout original: pair) -> none = "
        & "original.right = 2 end set_right "
        & "across_call: (value: pair, inout original: pair) -> (seen: u64) = "
        & "seen = value.right set_right(original) "
        & "seen = seen + value.right end across_call "
        --  A call rewrites a module binding the original may be.
        & "clobber: () -> none = global.left = 9 end clobber "
        & "across_global: (value: pair) -> (seen: u64) = "
        & "clobber() seen = value.left end across_global "
        --  The write comes after the last read.
        & "read_then_write: (value: pair, original: ptr mut pair) "
        & "-> (seen: u64) = seen = value.left original.val.left = 5 "
        & "end read_then_write "
        --  Passed on with a later argument, through a saved carrier.
        & "pick: (value: pair, extra: u64) -> (sum: u64) = "
        & "sum = value.right + extra end pick "
        & "relay: (value: pair, extra: u64) -> (sum: u64) = "
        & "sum = pick(value, extra + 1) end relay "
        & "length_of: (bytes: []u8) -> (count: u64) = "
        & "count = u64(lenof bytes) end length_of "
        --  A scalar arriving in the register a zero carrier's clear uses.
        & "after_scalar: (a: u64, value: pair) -> (sum: u64) = "
        & "sum = a + value.left end after_scalar "
        & "public main: () -> (code: i32) = text: []u8 = ""abcd"" "
        & "mut p: pair = zeroed "
        & "code = i32(length_of(text)) + i32(total(zeroed)) "
        & "+ i32(relay(p, 1)) + i32(after_scalar(1, zeroed)) end main";

      procedure One (Objective : Opt.Objective);

      procedure One (Objective : Opt.Objective) is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Name : constant String := Opt.Objective'Image (Objective);
      begin
         Lower (Item, Work, Source);
         IR.Simplification.Run
           (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work),
            Objective);
         declare
            Code : IR.Unit renames Landin.Stages.Code (Work).all;

            function Named (Spelling : String) return IR.Item_Id;
            function Named (Spelling : String) return IR.Item_Id is
            begin
               for Which in 1 .. IR.Item_Count (Code) loop
                  declare
                     Id : constant IR.Item_Id := IR.Item_Id (Which);
                  begin
                     if IR.Declares (Code, Id) /= IR.No_Declaration
                       and then Landin.Source.Names.Spelling
                         (Landin.Stages.Identities (Work).all,
                          Landin.Resolution.Name_Of
                            (Landin.Stages.Meanings (Work).all,
                             IR.Declares (Code, Id))) = Spelling
                     then
                        return Id;
                     end if;
                  end;
               end loop;
               raise Landin.Compiler_Defect with "missing item " & Spelling;
            end Named;

            function In_Place (Spelling : String) return Boolean
              is (IR.In_Place_Home
                    (Code, Named (Spelling),
                     IR.Nth_Parameter (Code, Named (Spelling), 1))
                  /= IR.No_Slot);

            function Copies (Spelling : String) return Natural;
            function Copies (Spelling : String) return Natural is
               Total : Natural := 0;
            begin
               for V in 1 .. IR.Value_Count (Code, Named (Spelling)) loop
                  if IR.Op_Of (Code, Named (Spelling), IR.Value_Id (V))
                    = IR.Copy_Array
                  then
                     Total := Total + 1;
                  end if;
               end loop;
               return Total;
            end Copies;

            Main_Copies : constant Natural := Copies ("main");
            Read_Only : constant Boolean := Objective /= Opt.None;
         begin
            IR.In_Place.Run (Code, Landin.Stages.Target (Work), Objective);
            Landin.Testing.Check
              (Item, In_Place ("total") = Read_Only,
               Name & ": a parameter only read is read in place");
            Landin.Testing.Check
              (Item, In_Place ("read_then_write") = Read_Only,
               Name & ": a write after the last read keeps it in place");
            Landin.Testing.Check
              (Item, (In_Place ("relay") and then In_Place ("pick"))
                       = Read_Only,
               Name & ": a saved carrier passed on is read in place");
            Landin.Testing.Check
              (Item, In_Place ("length_of") = Read_Only,
               Name & ": a slice parameter is read in place");
            Landin.Testing.Check
              (Item,
               not In_Place ("apart") and then not In_Place ("inout_first")
               and then not In_Place ("across_call")
               and then not In_Place ("across_global"),
               Name & ": an address, an inout write and a writing call keep"
               & " the copy");
            --  At speed scalar replacement has already split `text`, whose
            --  copy into the temporary is then one store per part.
            Landin.Testing.Check_Equal
              (Item,
               Copies ("main") + (if Objective = Opt.Size then 1 else 0),
               Main_Copies,
               Name & ": only an optimizing pass drops the slice temporary");

            --  The verifier holds the parameter to its home.
            if Read_Only then
               declare
                  Routine : constant IR.Item_Id := Named ("total");
                  Slot : constant IR.Slot_Id :=
                    IR.Nth_Parameter (Code, Routine, 1);
                  Home : constant IR.Slot_Id :=
                    IR.In_Place_Home (Code, Routine, Slot);
               begin
                  IR.Testing_Support.Overwrite_In_Place_Home
                    (Code, Routine, Slot, Slot);
                  Landin.Testing.Check
                    (Item,
                     IR.Verifier.Check (Code).Kind
                       = IR.Verifier.Runtime_Address_Is_Not_Valid,
                     Name & ": a parameter cannot be its own home");
                  IR.Testing_Support.Overwrite_In_Place_Home
                    (Code, Routine, Slot, IR.No_Slot);
                  Landin.Testing.Check
                    (Item,
                     IR.Verifier.Check (Code).Kind
                       = IR.Verifier.Routine_Signature_Disagrees,
                     Name & ": an address for a value parameter needs a"
                     & " home");
                  IR.Testing_Support.Overwrite_In_Place_Home
                    (Code, Routine, Slot, Home);
                  Landin.Testing.Check
                    (Item,
                     IR.Verifier.Check (Code).Kind
                       = IR.Verifier.Nothing_Wrong,
                     Name & ": the home restored verifies");
               end;
            end if;

            --  A zero carrier's clear writes %rdi, where a first scalar
            --  parameter arrives: that parameter may not stay there.
            declare
               use type Landin.Backend.X86_64.Allocation.Location_Kind;
               use type Landin.Backend.X86_64.Allocation.Register_Id;
               Routine : constant IR.Item_Id := Named ("after_scalar");
               Plan : constant Landin.Backend.X86_64.Allocation.Plan :=
                 Landin.Backend.X86_64.Allocation.Make
                   (Code, Routine, Landin.Stages.Target (Work),
                    (Optimize => Objective, Specialize => Opt.Off));
               Scalar : constant Positive :=
                 Positive (IR.Nth_Parameter (Code, Routine, 1));
            begin
               Landin.Testing.Check
                 (Item,
                  not (Plan.Slot (Scalar).Kind
                         = Landin.Backend.X86_64.Allocation.GP
                       and then Plan.Slot (Scalar).Register
                         = Landin.Backend.X86_64.Allocation.RDI),
                  Name & ": a zero carrier's clear moves a scalar out of"
                  & " the register it arrived in");
            end;

            declare
               Assembly : Ada.Strings.Unbounded.Unbounded_String;
               Report : Reports.Report;
            begin
               Landin.Backend.X86_64.Emit
                 (Code, Landin.Stages.Meanings (Work).all,
                  Landin.Stages.Identities (Work).all,
                  Landin.Stages.Target (Work),
                  (Optimize => Objective, Specialize => Opt.Off),
                  Assembly, Report);
               declare
                  Text : constant String :=
                    Ada.Strings.Unbounded.To_String (Assembly);

                  function Entry_Of (Spelling : String) return String;
                  function Entry_Of (Spelling : String) return String is
                     First : constant Natural := Ada.Strings.Fixed.Index
                       (Text, ASCII.LF & Spelling & ":" & ASCII.LF);
                     Last : constant Natural :=
                       (if First = 0 then 0
                        else Ada.Strings.Fixed.Index
                          (Text, "_done:", First));
                  begin
                     return (if First = 0 or else Last = 0 then ""
                             else Text (First .. Last));
                  end Entry_Of;

                  Kept : constant String := Entry_Of ("inout_first");
                  Read : constant String := Entry_Of ("total");
               begin
                  Landin.Testing.Check
                    (Item,
                     Ada.Strings.Fixed.Index (Kept, "_zero_arg_1:") /= 0,
                     Name & ": x86-64 copies a parameter that must stay");
                  Landin.Testing.Check
                    (Item,
                     (Ada.Strings.Fixed.Index (Read, "_zero_arg_1:") = 0
                      and then Ada.Strings.Fixed.Index (Read, "(%rsi)") = 0
                      and then Ada.Strings.Fixed.Index (Read, "jnz ") /= 0)
                     = Read_Only,
                     Name & ": x86-64 reads in place, clearing its home only"
                     & " for a zero carrier");
               end;
            end;
         end;
      end One;
      --  arm64 keeps a parameter in the register it arrives in, where
      --  its carrier is still found: the zero test reads that register,
      --  and x10 only once the entry has loaded the carrier into it.
      procedure Arm64 (Objective : Opt.Objective);

      procedure Arm64 (Objective : Opt.Objective) is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_Arm64);
         Name : constant String := "arm64 " & Opt.Objective'Image (Objective);
         Assembly : Ada.Strings.Unbounded.Unbounded_String;
         Report : Reports.Report;
      begin
         Lower (Item, Work, Source);
         IR.Simplification.Run
           (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work),
            Objective);
         IR.In_Place.Run
           (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work),
            Objective);
         Landin.Backend.Arm64.Emit
           (Landin.Stages.Code (Work).all,
            Landin.Stages.Meanings (Work).all,
            Landin.Stages.Identities (Work).all,
            Landin.Stages.Target (Work),
            (Optimize => Objective, Specialize => Opt.Off),
            Assembly, Report);
         declare
            Text : constant String :=
              Ada.Strings.Unbounded.To_String (Assembly);
            First : constant Natural := Ada.Strings.Fixed.Index
              (Text, ASCII.LF & "total:" & ASCII.LF);
            Test : constant Natural :=
              (if First = 0 then 0
               else Ada.Strings.Fixed.Index (Text, "cbnz ", First));
            Register_Last : constant Natural :=
              (if Test = 0 then 0
               else Ada.Strings.Fixed.Index (Text, ",", Test));
            Register : constant String :=
              (if Register_Last = 0 then ""
               else Text (Test + 5 .. Register_Last - 1));
         begin
            Landin.Testing.Check
              (Item,
               Register /= ""
               and then
                 (Register in "x0" | "x1" | "x2" | "x3" | "x4" | "x5"
                              | "x6" | "x7"
                  or else Ada.Strings.Fixed.Index
                    (Text (First .. Test), "mov " & Register & ",") /= 0),
               Name & ": the zero test reads the register holding the"
               & " carrier, here " & Register);
         end;
      end Arm64;
   begin
      One (Opt.None);
      One (Opt.Size);
      One (Opt.Speed);
      Arm64 (Opt.Size);
      Arm64 (Opt.Speed);
   end In_Place_Parameters;
   --  A module value that is not `mut` is its target's image wherever it
   --  is read, and what then becomes constant folds with it; a `mut` one,
   --  and every value under the reference profile, is still read.
   procedure Module_Constants (Item : in out Landin.Testing.Context) is
      Source : constant String :=
        "word: usize = sizeof usize "
        & "mask: usize = word - 1 "
        & "mut moving: usize = 3 "
        & "public f: (x: usize) -> (r: usize) = "
        & "r = (x & mask) + moving end f";
   begin
      for Wide in Boolean loop
         for Objective in Opt.Objective loop
            declare
               Facts : constant Landin.Targets.Target_Facts :=
                 (if Wide then Landin.Targets.Linux_X86_64
                  else Landin.Targets.Synthetic_32);
               Work : Landin.Stages.Compilation :=
                 Landin.Stages.Create (Facts);
               Folded : Boolean := False;
               Reads : Natural := 0;
            begin
               Lower (Item, Work, Source);
               IR.Simplification.Run
                 (Landin.Stages.Code (Work).all, Facts, Objective);
               declare
                  Code : IR.Unit renames Landin.Stages.Code (Work).all;
               begin
                  for I in 1 .. IR.Item_Count (Code) loop
                     if IR.Kind_Of (Code, IR.Item_Id (I)) = IR.Routine then
                        for V in 1 .. IR.Value_Count (Code, IR.Item_Id (I))
                        loop
                           if IR.Op_Of (Code, IR.Item_Id (I), IR.Value_Id (V))
                             = IR.Load_Datum
                           then
                              Reads := Reads + 1;
                           elsif IR.Op_Of
                             (Code, IR.Item_Id (I), IR.Value_Id (V))
                             = IR.Bitwise_And
                           then
                              declare
                                 Mask : constant IR.Value_Id := IR.Nth_Operand
                                   (Code, IR.Item_Id (I), IR.Value_Id (V), 2);
                              begin
                                 Folded := IR.Op_Of
                                   (Code, IR.Item_Id (I), Mask) = IR.Number
                                   and then IR.Number_Of
                                     (Code, IR.Item_Id (I), Mask)
                                     = (if Wide then 7 else 3);
                              end;
                           end if;
                        end loop;
                     end if;
                  end loop;
                  Landin.Testing.Check
                    (Item, Folded = (Objective /= Opt.None),
                     "an immutable module value is its target's image");
                  Landin.Testing.Check_Equal
                    (Item, Reads, (if Objective = Opt.None then 2 else 1),
                     "a mutable module value is still read");
               end;
            end;
         end loop;
      end loop;
   end Module_Constants;

   --  [1960] and D211: a check whose operands a dominating comparison, a
   --  type's range or a passed check in its block bounds cannot fail, and
   --  loses its edge.  Every case beside one that must keep it.
   procedure Proved_Checks (Item : in out Landin.Testing.Context) is
      procedure Check_Proved
        (Source : String; Op : IR.Opcode; Expected : Natural; Why : String;
         Objective : Opt.Objective := Opt.Size);

      procedure Check_Proved
        (Source : String; Op : IR.Opcode; Expected : Natural; Why : String;
         Objective : Opt.Objective := Opt.Size)
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Total : Natural := 0;
      begin
         Lower (Item, Work, Source);
         IR.Simplification.Run
           (Landin.Stages.Code (Work).all, Landin.Targets.Linux_X86_64,
            Objective);
         declare
            Code : IR.Unit renames Landin.Stages.Code (Work).all;
         begin
            for I in 1 .. IR.Item_Count (Code) loop
               if IR.Kind_Of (Code, IR.Item_Id (I)) = IR.Routine then
                  for V in 1 .. IR.Value_Count (Code, IR.Item_Id (I)) loop
                     if IR.Op_Of (Code, IR.Item_Id (I), IR.Value_Id (V)) = Op
                       and then IR.Is_Unchecked
                         (Code, IR.Item_Id (I), IR.Value_Id (V))
                     then
                        Total := Total + 1;
                     end if;
                  end loop;
               end if;
            end loop;
         end;
         Landin.Testing.Check_Equal (Item, Total, Expected, Why);
      end Check_Proved;
   begin
      Check_Proved
        ("public f: (t: [256]u8, b: u8) -> (r: u8) = r = t[usize(b)] end f",
         IR.Load_Element, 1, "a widened u8 indexes [256]u8");
      Check_Proved
        ("public f: (t: [255]u8, b: u8) -> (r: u8) = r = t[usize(b)] end f",
         IR.Load_Element, 0, "a u8 may be 255, past [255]u8");
      Check_Proved
        ("public f: (t: [256]u8, b: u16) -> (r: u8) = r = t[usize(b)] end f",
         IR.Load_Element, 0, "a u16 may be past [256]u8");
      Check_Proved
        ("public f: (n: usize) -> (r: usize) = mut at: usize = n r = 0 "
         & "while at > 0 do dec at r += 1 end while end f",
         IR.Subtract, 1, "a decrement under at > 0");
      Check_Proved
        ("public f: (n: u32) -> (r: u32) = r = 0 "
         & "if n <> 0 then r = n - 1 end if end f",
         IR.Subtract, 1, "an unsigned value other than zero is above it");
      Check_Proved
        ("public f: (x: usize, flag: bool) -> (r: usize) = "
         & "mut y: usize = 0 if x > 0 then y = 1 end if r = x - 1 + y end f",
         IR.Subtract, 0, "a join's other edge proves nothing");
      Check_Proved
        ("public f: (inout v: [16]u8) -> none = mut left: usize = 0 "
         & "mut right: usize = usize(v[0]) while left < right do "
         & "inc left dec right end while end f",
         IR.Add, 1, "left < right leaves room above left");
      Check_Proved
        ("public f: (inout v: [16]u8) -> none = mut left: usize = 0 "
         & "mut right: usize = usize(v[0]) while left < right do "
         & "inc left dec right end while end f",
         IR.Subtract, 1, "left < right puts right above zero");
      Check_Proved
        ("public f: (n: usize) -> (r: usize) = mut i: usize = 0 "
         & "while i <= n do inc i end while r = i end f",
         IR.Add, 0, "i <= n leaves no room when n is the largest");
      Check_Proved
        ("public f: (n: usize, flag: bool) -> (r: usize) = "
         & "mut i: usize = 0 r = 0 while i < n do "
         & "if flag then i = i + 5 end if r = i + 1 end while end f",
         IR.Add, 0, "a store on the way to a use ends the fact");
      Check_Proved
        ("public f: (s: []u8) -> (r: usize) = r = 0 first: usize = 0 "
         & "for i in first..<lenof s do r += usize(s[i]) end for end f",
         IR.Slice_Address, 1, "a loop below a slice's length indexes it");
      Check_Proved
        ("public f: (s: []u8) -> (r: usize) = r = 0 first: usize = 0 "
         & "for i in first..<lenof s do r += usize(s[i + 1]) end for end f",
         IR.Slice_Address, 0, "the next element may be past the end");
      Check_Proved
        ("public f: (s: []u8, t: []u8) -> (r: usize) = r = 0 "
         & "first: usize = 0 "
         & "for i in first..<lenof t do r += usize(s[i]) end for end f",
         IR.Slice_Address, 0, "another slice's length bounds nothing");
      Check_Proved
        ("public f: (s: []u8, t: []u8) -> (r: usize) = r = 0 "
         & "mut u: []u8 = s first: usize = 0 "
         & "for i in first..<lenof u do u = t r += usize(u[i]) end for end f",
         IR.Slice_Address, 0, "a reassigned slice's length bounds nothing");
      Check_Proved
        ("public f: (s: []u8) -> (r: u8) = r = s[lenof s - 1] end f",
         IR.Slice_Address, 1, "a length less one that did not trap");
      Check_Proved
        ("public f: (s: []u8) -> (r: u8) = mut x: usize = 0 "
         & "unchecked begin x = lenof s - 1 end unchecked r = s[x] end f",
         IR.Slice_Address, 0, "an unchecked length less one may wrap");
      --  At speed scalar replacement copies a parameter's length out on
      --  entry and splits a local slice; the proofs see through both.
      Check_Proved
        ("public f: (s: []u8) -> (r: usize) = r = 0 first: usize = 0 "
         & "for i in first..<lenof s do r += usize(s[i]) end for end f",
         IR.Slice_Address, 1, "an entry copy of the length bounds the loop",
         Opt.Speed);
      Check_Proved
        ("public f: (s: []u8) -> (r: usize) = r = 0 first: usize = 0 "
         & "for i in first..<lenof s do r += usize(s[i + 1]) end for end f",
         IR.Slice_Address, 0, "at speed the next element may be past the end",
         Opt.Speed);
      Check_Proved
        ("public f: (s: []u8) -> (r: usize) = r = 0 mut u: []u8 = s "
         & "first: usize = 0 "
         & "for i in first..<lenof u do r += usize(u[i]) end for end f",
         IR.Slice_Address, 1, "a split local's length bounds the loop",
         Opt.Speed);
      Check_Proved
        ("public f: (s: []u8, t: []u8) -> (r: usize) = r = 0 "
         & "mut u: []u8 = s first: usize = 0 "
         & "for i in first..<lenof u do u = t r += usize(u[i]) end for end f",
         IR.Slice_Address, 0, "a split slice reassigned bounds nothing",
         Opt.Speed);
      Check_Proved
        ("public f: (i: usize) -> (r: u8) = mut v: [8]u8 = zeroed "
         & "v[i] = 3 r = v[i] end f",
         IR.Load_Element, 1, "a passed index check is not repeated");
      Check_Proved
        ("public f: (inout v: [8]u8, i: usize) -> (r: u8) = "
         & "unchecked begin v[i] = 1 end unchecked r = v[i] end f",
         IR.Storage_Address, 1, "an unchecked index proves nothing");
   end Proved_Checks;

   --  Lengauer and Tarjan's tree over a hand-made graph with a join, a
   --  loop and an unreached block, then work that stays near-linear over
   --  a ladder whose every rung also jumps to one exit.
   procedure Dominators (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Code : IR.Unit;
      Site : Landin.Provenance.Origin;
   begin
      Lower (Item, Work, "f: () -> none = end f");
      IR.Prepare (Code, Landin.Stages.Meanings (Work).all);
      Site := IR.Origin_Of (Landin.Stages.Code (Work).all, 1);
      declare
         Routine : constant IR.Item_Id := IR.Add_Item
           (Code, IR.Routine, 1, Landin.Types.No_Value, Site);
         Blocks : array (1 .. 7) of IR.Block_Id;
         Condition : IR.Value_Id;
      begin
         for B in Blocks'Range loop
            Blocks (B) := IR.Add_Block
              (Code, Routine, Landin.Resolution.Program_Scope, Site);
         end loop;
         for B in Blocks'Range loop
            IR.Enter (Code, Routine, Blocks (B));
            case B is
               when 1 | 4 =>
                  Condition := IR.Emit_Truth (Code, Routine, True, Site);
                  IR.Emit_Branch
                    (Code, Routine, Condition, Blocks (B + 1),
                     Blocks (B + 2), Site);
               when 2 | 3 | 5 | 7 =>
                  IR.Emit_Jump (Code, Routine, Blocks (4), Site);
               when others =>
                  IR.Emit_Leave (Code, Routine, IR.No_Value, Site);
            end case;
            IR.Leave_Block (Code, Routine);
         end loop;
         declare
            Graph : constant IR.Control_Flow.Graph :=
              IR.Control_Flow.Make (Code, Routine);
            Tree : IR.Dominance.Tree;
            function Up (B : Positive) return IR.Block_Id
              is (IR.Dominance.Immediate (Tree, Blocks (B)));
         begin
            IR.Dominance.Build (Tree, Graph);
            Landin.Testing.Check
              (Item, Up (1) = IR.No_Block and then Up (2) = Blocks (1)
               and then Up (3) = Blocks (1) and then Up (4) = Blocks (1)
               and then Up (5) = Blocks (4) and then Up (6) = Blocks (4)
               and then Up (7) = IR.No_Block
               and then IR.Dominance.Reached (Tree) = 6
               and then IR.Dominance.Position (Tree, Blocks (7)) = 0,
               "each reached block's immediate dominator, none unreached");
            Landin.Testing.Check
              (Item, IR.Dominance.Dominates (Tree, Blocks (4), Blocks (5))
               and then IR.Dominance.Dominates (Tree, Blocks (1), Blocks (1))
               and then not IR.Dominance.Strictly_Dominates
                 (Tree, Blocks (1), Blocks (1))
               and then not IR.Dominance.Dominates
                 (Tree, Blocks (2), Blocks (4))
               and then not IR.Dominance.Dominates
                 (Tree, Blocks (5), Blocks (4))
               and then not IR.Dominance.Dominates
                 (Tree, Blocks (7), Blocks (4)),
               "a join and a loop's back edge dominate nothing past them");
         end;
      end;
      declare
         Rungs : constant := 4096;
         Routine : constant IR.Item_Id := IR.Add_Item
           (Code, IR.Routine, IR.No_Declaration, Landin.Types.No_Value, Site);
         Blocks : array (1 .. Rungs + 1) of IR.Block_Id;
         Condition : IR.Value_Id;
      begin
         for B in Blocks'Range loop
            Blocks (B) := IR.Add_Block
              (Code, Routine, Landin.Resolution.Program_Scope, Site);
         end loop;
         for B in Blocks'Range loop
            IR.Enter (Code, Routine, Blocks (B));
            if B < Rungs then
               Condition := IR.Emit_Truth (Code, Routine, True, Site);
               IR.Emit_Branch
                 (Code, Routine, Condition, Blocks (B + 1),
                  Blocks (Rungs + 1), Site);
            elsif B = Rungs then
               IR.Emit_Jump (Code, Routine, Blocks (1), Site);
            else
               IR.Emit_Leave (Code, Routine, IR.No_Value, Site);
            end if;
            IR.Leave_Block (Code, Routine);
         end loop;
         declare
            Graph : constant IR.Control_Flow.Graph :=
              IR.Control_Flow.Make (Code, Routine);
            Tree : IR.Dominance.Tree;
         begin
            IR.Dominance.Build (Tree, Graph);
            Landin.Testing.Check
              (Item, IR.Dominance.Immediate (Tree, Blocks (Rungs + 1))
                 = Blocks (1)
               and then IR.Dominance.Immediate (Tree, Blocks (Rungs))
                 = Blocks (Rungs - 1)
               and then IR.Dominance.Evaluation_Steps (Tree) <= 4 * Rungs,
               "a long ladder's tree in near-linear evaluation:"
               & Natural'Image (IR.Dominance.Evaluation_Steps (Tree)));
         end;
      end;
   end Dominators;

   procedure Converted
     (Item : in out Landin.Testing.Context;
      Source : String;
      Objective : Opt.Objective;
      Branches, Choices, Constant_Choices : out Natural)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Work, Source);
      IR.Simplification.Run
        (Landin.Stages.Code (Work).all, Landin.Targets.Linux_X86_64,
         Objective);
      IR.If_Conversion.Run
        (Landin.Stages.Code (Work).all, Landin.Targets.Linux_X86_64,
         Objective);
      declare
         Code : IR.Unit renames Landin.Stages.Code (Work).all;
      begin
         Branches := Count (Code, IR.Branch);
         Choices := Count (Code, IR.Choose);
         Constant_Choices := 0;
         for I in 1 .. IR.Item_Count (Code) loop
            for V in 1 .. IR.Value_Count (Code, IR.Item_Id (I)) loop
               if IR.Op_Of (Code, IR.Item_Id (I), IR.Value_Id (V))
                    = IR.Choose
                 and then
                   (for all Position in 2 .. 3 =>
                      IR.Op_Of
                        (Code, IR.Item_Id (I),
                         IR.Nth_Operand
                           (Code, IR.Item_Id (I), IR.Value_Id (V), Position))
                      = IR.Number)
               then
                  Constant_Choices := Constant_Choices + 1;
               end if;
            end loop;
         end loop;
      end;
   end Converted;

   --  D338: an `if` whose arms only load, store and compute without a
   --  trap becomes a choice at size and speed, as does a checked count
   --  that only one arm makes; `--optimize none` keeps every branch.
   procedure Choices_From_Computing_Arms
     (Item : in out Landin.Testing.Context)
   is
      procedure Expect
        (Source : String; Choices, Constants : Natural; Why : String);

      procedure Expect
        (Source : String; Choices, Constants : Natural; Why : String)
      is
         Branches, Found, Constant_Found : Natural;
      begin
         for Objective in Opt.Size .. Opt.Speed loop
            Converted
              (Item, Source, Objective, Branches, Found, Constant_Found);
            Landin.Testing.Check
              (Item, Branches = 0 and then Found = Choices
                     and then Constant_Found = Constants,
               Why & " at " & Opt.Objective'Image (Objective)
               & ": branches" & Natural'Image (Branches)
               & ", choices" & Natural'Image (Found)
               & ", of constants" & Natural'Image (Constant_Found));
         end loop;
         Converted
           (Item, Source, Opt.None, Branches, Found, Constant_Found);
         Landin.Testing.Check
           (Item, Branches > 0 and then Found = 0,
            Why & ": none converts nothing");
      end Expect;
   begin
      Expect
        ("public f: (a: i32, b: i32) -> (r: i32) = "
         & "if a < b then r = a else r = b end if end f",
         1, 0, "a minimum chooses between its operands");
      Expect
        ("public f: (a: f64, b: f64) -> (r: u32) = mut n: u32 = 0 "
         & "if a >= b then inc n end if r = n end f",
         1, 1, "a checked count adds a chosen one or zero");
      Expect
        ("public f: (a: f64, b: f64) -> (r: f64) = mut m: f64 = b "
         & "if a < b then m = a * 2.0 - 1.0 end if r = m end f",
         1, 0, "float arithmetic cannot trap");
      Expect
        ("public f: (a: u8, b: u8) -> (r: u8) = mut x: u8 = 0 "
         & "mut y: u8 = 0 if a <> b then x = a +% b y = a ^ b "
         & "else x = 1 end if r = x | y end f",
         2, 0, "each slot an arm stores is chosen");
      Expect
        ("public f: (c: bool, n: usize) -> (r: usize) = mut k: usize = n "
         & "if c then dec k end if r = k end f",
         1, 1, "a checked decrement subtracts a chosen one or zero");
   end Choices_From_Computing_Arms;

   --  D211 lets no trap, call or write move to where its arm did not
   --  run, so an arm with one keeps its branch.  So does an arm whose
   --  condition reads the slot it stores, whose choice would wait on the
   --  value it chose last.
   procedure Branches_Around_Observable_Arms
     (Item : in out Landin.Testing.Context)
   is
      procedure Expect (Source : String; Why : String);

      procedure Expect (Source : String; Why : String) is
         Branches, Choices, Constants : Natural;
      begin
         for Objective in Opt.Size .. Opt.Speed loop
            Converted (Item, Source, Objective, Branches, Choices, Constants);
            Landin.Testing.Check
              (Item, Branches = 1 and then Choices = 0,
               Why & " at " & Opt.Objective'Image (Objective));
         end loop;
      end Expect;
   begin
      Expect
        ("public f: (t: [4]u32, i: usize, c: bool) -> (r: u32) = r = 0 "
         & "if c then r = t[i] end if end f",
         "an index check in an arm");
      Expect
        ("public f: (n: u32, d: u32) -> (r: u32) = r = 0 "
         & "if d > 1 then r = n / d end if end f",
         "a division in an arm");
      Expect
        ("public f: (a: u32, b: u32, c: bool) -> (r: u32) = r = 0 "
         & "if c then r = a + b end if end f",
         "a checked addition that is not the slot's own update");
      Expect
        ("public f: (c: bool, n: u32) -> (r: u32) = mut k: u32 = n "
         & "if c then inc k else k = 0 end if r = k end f",
         "a checked update the other arm also stores");
      Expect
        ("g: () -> (r: u32) = r = 1 end g "
         & "public f: (c: bool) -> (r: u32) = r = 0 "
         & "if c then r = g() end if end f",
         "a call in an arm");
      Expect
        ("public f: (p: ptr mut u32, c: bool) -> none = "
         & "if c then p.val = 1 end if end f",
         "a store through a pointer");
      Expect
        ("public f: (c: bool) -> (r: u32) = mut k: u32 = 0 "
         & "p: ptr mut u32 = addr k if c then k = 1 end if "
         & "r = p.val end f",
         "a store to a slot whose address is taken");
      Expect
        ("public f: (m: u32, s: u32) -> (r: u32) = mut at: u32 = s "
         & "at = at +% 1 if at == m then at = 0 end if r = at end f",
         "a condition read from the slot the arm stores");
   end Branches_Around_Observable_Arms;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "ir opt", "memory events", Memory_Events'Access);
      Landin.Testing.Register
        (Into, "ir opt", "in-place parameters", In_Place_Parameters'Access);
      Landin.Testing.Register
        (Into, "ir opt", "exposure traversal keeps references",
         Exposure_Traversal_Keeps_References'Access);
      Landin.Testing.Register
        (Into, "ir opt", "template counts are independent",
         Template_Counts_Are_Independent'Access);
      Landin.Testing.Register
        (Into, "ir opt", "dead function addresses",
         Dead_Function_Addresses'Access);
      Landin.Testing.Register
        (Into, "ir opt", "partial dispatch reports remaining calls",
         Partial_Dispatch_Reports_Remaining_Calls'Access);
      Landin.Testing.Register
        (Into, "ir opt", "measurement dumps name their types",
         Measurement_Dumps_Name_Their_Types'Access);
      Landin.Testing.Register
        (Into, "ir opt", "constant shifts", Constant_Shifts'Access);
      Landin.Testing.Register
        (Into, "ir opt", "effect preservation", Effect_Preservation'Access);
      Landin.Testing.Register
        (Into, "ir opt", "block value numbering",
         Block_Value_Numbering'Access);
      Landin.Testing.Register
        (Into, "ir opt", "forwarding through writes",
         Forwarding_Through_Writes'Access);
      Landin.Testing.Register
        (Into, "ir opt", "overwritten local stores",
         Overwritten_Local_Stores'Access);
      Landin.Testing.Register
        (Into, "ir opt", "scalar replacement", Scalar_Replacement'Access);
      Landin.Testing.Register
        (Into, "ir opt", "static dispatch", Static_Dispatch'Access);
      Landin.Testing.Register
        (Into, "ir opt", "exposed evidence", Exposed_Evidence'Access);
      Landin.Testing.Register
        (Into, "ir opt", "raw any", Raw_Any'Access);
      Landin.Testing.Register
        (Into, "ir opt", "incoming evidence", Incoming_Evidence'Access);
      Landin.Testing.Register
        (Into, "ir opt", "assembly output aliases",
         Assembly_Output_Aliases'Access);
      Landin.Testing.Register
        (Into, "ir opt", "forwarded evidence chain",
         Forwarded_Evidence_Chain'Access);
      Landin.Testing.Register
        (Into, "ir opt", "instance costs", Instance_Costs'Access);
      Landin.Testing.Register
        (Into, "ir opt", "sparse instance items",
         Sparse_Instance_Items'Access);
      Landin.Testing.Register
        (Into, "ir opt", "large graph", Large_Graph'Access);
      Landin.Testing.Register
        (Into, "ir opt", "scalar boundaries", Scalar_Boundaries'Access);
      Landin.Testing.Register
        (Into, "ir opt", "policy boundaries", Policy_Boundaries'Access);
      Landin.Testing.Register
        (Into, "ir opt", "cyclic islands", Cyclic_Islands'Access);
      Landin.Testing.Register
        (Into, "ir opt", "module constants", Module_Constants'Access);
      Landin.Testing.Register
        (Into, "ir opt", "proved checks", Proved_Checks'Access);
      Landin.Testing.Register
        (Into, "ir opt", "dominators", Dominators'Access);
      Landin.Testing.Register
        (Into, "ir opt",
         "if-conversion chooses between arms that only compute",
         Choices_From_Computing_Arms'Access);
      Landin.Testing.Register
        (Into, "ir opt",
         "if-conversion keeps a branch whose arm could be observed",
         Branches_Around_Observable_Arms'Access);
   end Register;
end Landin.Tests.IR_Optimization_Suite;
