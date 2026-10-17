with Ada.Strings.Unbounded;
with Landin.IR.Dump;
with Landin.IR.Effects;
with Landin.IR.Inlining;
with Landin.IR.Simplification;
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

package body Landin.Tests.IR_Inlining_Suite is
   package IR renames Landin.IR;
   package Opt renames Landin.Optimization;
   use type IR.Opcode;
   use type IR.Item_Id;
   use type IR.Slot_Id;
   use type Landin.Provenance.Origin;
   use type Landin.Provenance.Declaration_Id;
   use type Landin.Source.Source_Id;
   use type Landin.Types.Magnitude;
   use type Landin.Types.Type_Kind;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Resolver : aliased Landin.Stages.Resolution.Instance;
   Checker : aliased Landin.Stages.Checking.Instance;
   Lowerer : aliased Landin.Stages.Lowering.Instance;

   procedure Lower
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation; Text : String);
   procedure Lower
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation; Text : String)
   is
      Order : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "ir-inline.ldn", Text);
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

   function Named
     (Work : in out Landin.Stages.Compilation; Spelling : String)
      return IR.Item_Id;
   function Named
     (Work : in out Landin.Stages.Compilation; Spelling : String)
      return IR.Item_Id
   is
      Code : IR.Unit renames Landin.Stages.Code (Work).all;
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

   function Count
     (Code : IR.Unit; Item : IR.Item_Id; Op : IR.Opcode) return Natural;
   function Count
     (Code : IR.Unit; Item : IR.Item_Id; Op : IR.Opcode) return Natural
   is
      Total : Natural := 0;
   begin
      for V in 1 .. IR.Value_Count (Code, Item) loop
         if IR.Op_Of (Code, Item, IR.Value_Id (V)) = Op then
            Total := Total + 1;
         end if;
      end loop;
      return Total;
   end Count;

   function Calls_To
     (Code : IR.Unit; Item, Callee : IR.Item_Id) return Natural;
   function Calls_To
     (Code : IR.Unit; Item, Callee : IR.Item_Id) return Natural
   is
      Total : Natural := 0;
   begin
      for V in 1 .. IR.Value_Count (Code, Item) loop
         if IR.Op_Of (Code, Item, IR.Value_Id (V)) = IR.Call
           and then IR.Callee_Of (Code, Item, IR.Value_Id (V)) = Callee
         then
            Total := Total + 1;
         end if;
      end loop;
      return Total;
   end Calls_To;

   function Weight (Code : IR.Unit; Item : IR.Item_Id) return Natural;
   function Weight (Code : IR.Unit; Item : IR.Item_Id) return Natural is
      Total : Natural := 0;
   begin
      for V in 1 .. IR.Value_Count (Code, Item) loop
         Total := Total + IR.Effects.Weight
           (IR.Op_Of (Code, Item, IR.Value_Id (V)));
      end loop;
      return Total;
   end Weight;

   --  A statement of the form `a = a * 3 + 1` weighs more than six, so
   --  this many of them put a routine past the bound.
   function Heavy_Body return String;
   function Heavy_Body return String is
      Result : Ada.Strings.Unbounded.Unbounded_String;
   begin
      for Index in 1 .. IR.Inlining.Body_Bound / 6 + 2 loop
         Ada.Strings.Unbounded.Append (Result, "a = a * 3 + 1 ");
      end loop;
      return Ada.Strings.Unbounded.To_String (Result);
   end Heavy_Body;

   procedure Copies_At_Speed_Only (Item : in out Landin.Testing.Context);
   procedure Copies_At_Speed_Only (Item : in out Landin.Testing.Context) is
      Source : constant String :=
        "leaf: (x: u32) -> (y: u32) = y = x + 1 end leaf "
        & "big: (x: u32) -> (y: u32) = mut a: u32 = x "
        & Heavy_Body & "y = a end big "
        --  Its address is taken, so its body is its own (D211).
        & "taken: (x: u32) -> (y: u32) = y = x + 2 end taken "
        & "down: (n: u32) -> (r: u32) = r = 0 "
        & "if n > 0 then r = down(n - 1) end if end down "
        & "public main: () -> (code: i32) = kept := taken "
        & "code = i32(leaf(41) + big(1) + taken(1) + kept(1) + down(3)) "
        & "end main";
   begin
      for Objective in Opt.None .. Opt.Size loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         begin
            Lower (Item, Work, Source);
            declare
               Before : constant String := Text (Work);
            begin
               IR.Inlining.Run
                 (Landin.Stages.Code (Work).all, Landin.Stages.Target (Work),
                  Objective);
               Landin.Testing.Check_Equal
                 (Item, Text (Work), Before,
                  Opt.Objective'Image (Objective) & " copies nothing");
            end;
         end;
      end loop;
      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      begin
         Lower (Item, Work, Source);
         declare
            Code : IR.Unit renames Landin.Stages.Code (Work).all;
            Main : constant IR.Item_Id := Named (Work, "main");
            Leaf : constant IR.Item_Id := Named (Work, "leaf");
            Big : constant IR.Item_Id := Named (Work, "big");
            Taken : constant IR.Item_Id := Named (Work, "taken");
            Down : constant IR.Item_Id := Named (Work, "down");
            Call_Site : Landin.Provenance.Origin :=
              Landin.Provenance.No_Origin;
         begin
            Landin.Testing.Check
              (Item, Weight (Code, Leaf) <= IR.Inlining.Body_Bound
                 and then Weight (Code, Down) <= IR.Inlining.Body_Bound
                 and then Weight (Code, Big) > IR.Inlining.Body_Bound,
               "the routines weigh what the cases below assume");
            for V in 1 .. IR.Value_Count (Code, Main) loop
               if IR.Op_Of (Code, Main, IR.Value_Id (V)) = IR.Call
                 and then IR.Callee_Of (Code, Main, IR.Value_Id (V)) = Leaf
               then
                  Call_Site := IR.Origin_Of (Code, Main, IR.Value_Id (V));
               end if;
            end loop;
            IR.Inlining.Run (Code, Landin.Stages.Target (Work), Opt.Speed);
            Landin.Testing.Check_Equal
              (Item, IR.Inline_Site_Count (Code, Main), 2,
               "main copies leaf and down");
            Landin.Testing.Check
              (Item, IR.Nth_Inline_Site (Code, Main, 1).Callee = Leaf
                 and then IR.Nth_Inline_Site (Code, Main, 1).Call = Call_Site
                 and then IR.Nth_Inline_Site (Code, Main, 2).Callee = Down,
               "each copy records its routine and the call it replaced");
            Landin.Testing.Check_Equal
              (Item, Calls_To (Code, Main, Leaf), 0, "leaf is no call");
            Landin.Testing.Check_Equal
              (Item, Calls_To (Code, Main, Big), 1,
               "a routine past the bound stays a call");
            Landin.Testing.Check_Equal
              (Item, Calls_To (Code, Main, Taken), 1,
               "a routine whose address is taken stays a call");
            Landin.Testing.Check_Equal
              (Item, Count (Code, Main, IR.Indirect_Call), 1,
               "a call through a function value stays indirect");
            Landin.Testing.Check_Equal
              (Item, Calls_To (Code, Main, Down), 1,
               "a copy's own call is not copied again");
            Landin.Testing.Check
              (Item, IR.Inline_Site_Count (Code, Down) = 0
                 and then Calls_To (Code, Down, Down) = 1,
               "a routine is not copied into itself");
            declare
               Copied_Blocks, Copied_Slots : Natural := 0;
            begin
               for B in 1 .. IR.Block_Count (Code, Main) loop
                  if IR.Inlined_At (Code, Main, IR.Block_Id (B)) = 1 then
                     Copied_Blocks := Copied_Blocks + 1;
                  end if;
               end loop;
               for S in 1 .. IR.Slot_Count (Code, Main) loop
                  if IR.Inlined_At (Code, Main, IR.Slot_Id (S)) = 1 then
                     Copied_Slots := Copied_Slots + 1;
                     Landin.Testing.Check
                       (Item, IR.Declares (Code, Main, IR.Slot_Id (S))
                          = IR.Declares
                              (Code, Leaf,
                               IR.Inlined_Origin
                                 (Code, Main, IR.Slot_Id (S))),
                        "a copied slot keeps the declaration it copies");
                  end if;
               end loop;
               Landin.Testing.Check_Equal
                 (Item, Copied_Blocks, IR.Block_Count (Code, Leaf),
                  "each of leaf's blocks is copied once");
               Landin.Testing.Check_Equal
                 (Item, Copied_Slots, IR.Slot_Count (Code, Leaf),
                  "each of leaf's slots is copied once");
            end;
            --  The argument is a constant, so the copy reads it as one and
            --  simplification folds the copy's addition.
            IR.Simplification.Run
              (Code, Landin.Stages.Target (Work), Opt.Speed);
            declare
               Folded : Boolean := False;
            begin
               for V in 1 .. IR.Value_Count (Code, Main) loop
                  if IR.Op_Of (Code, Main, IR.Value_Id (V)) = IR.Number
                    and then IR.Result_Of (Code, Main, IR.Value_Id (V))
                      = Landin.Types.U32
                    and then IR.Number_Of (Code, Main, IR.Value_Id (V)) = 42
                  then
                     Folded := True;
                  end if;
               end loop;
               Landin.Testing.Check
                 (Item, Folded, "leaf(41) folds to 42 in its copy");
            end;
         end;
      end;
   end Copies_At_Speed_Only;

   procedure Copies_Keep_Their_Checks (Item : in out Landin.Testing.Context);
   procedure Copies_Keep_Their_Checks (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Work,
        "grow: (value: u8) -> (result: u8) = result = value + 200 end grow "
        & "public main: () -> (code: i32) = small: u8 = grow(50) "
        & "code = i32(grow(small)) end main");
      declare
         Code : IR.Unit renames Landin.Stages.Code (Work).all;
         Main : constant IR.Item_Id := Named (Work, "main");
         Grow : constant IR.Item_Id := Named (Work, "grow");
         Check_Site : Landin.Provenance.Origin := Landin.Provenance.No_Origin;
         Kept, Remade : Natural := 0;
      begin
         for V in 1 .. IR.Value_Count (Code, Grow) loop
            if IR.Op_Of (Code, Grow, IR.Value_Id (V)) = IR.Add then
               Check_Site := IR.Origin_Of (Code, Grow, IR.Value_Id (V));
            end if;
         end loop;
         IR.Inlining.Run (Code, Landin.Stages.Target (Work), Opt.Speed);
         IR.Simplification.Run (Code, Landin.Stages.Target (Work), Opt.Speed);
         Landin.Testing.Check_Equal
           (Item, Calls_To (Code, Main, Grow), 0, "both calls are copied");
         for V in 1 .. IR.Value_Count (Code, Main) loop
            if IR.Op_Of (Code, Main, IR.Value_Id (V)) = IR.Add then
               Kept := Kept + 1;
               Landin.Testing.Check
                 (Item, IR.Origin_Of (Code, Main, IR.Value_Id (V)) = Check_Site
                    and then not IR.Is_Unchecked
                      (Code, Main, IR.Value_Id (V))
                    and then IR.Inlined_At
                      (Code, Main, IR.Block_Of (Code, Main, IR.Value_Id (V)))
                      /= 0,
                  "a copy's addition keeps grow's own site and its check");
            elsif IR.Op_Of (Code, Main, IR.Value_Id (V)) = IR.Number
              and then IR.Result_Of (Code, Main, IR.Value_Id (V))
                = Landin.Types.U8
              and then IR.Number_Of (Code, Main, IR.Value_Id (V)) = 250
            then
               Remade := Remade + 1;
            end if;
         end loop;
         --  50 + 200 fits and folds; 250 + 200 cannot, and its trap stays.
         Landin.Testing.Check_Equal
           (Item, Kept, 1, "the addition that overflows keeps its trap");
         Landin.Testing.Check
           (Item, Remade > 0, "the addition that fits folds to 250");
      end;
   end Copies_Keep_Their_Checks;

   procedure Failing_Copies_Take_The_Test
     (Item : in out Landin.Testing.Context);
   procedure Failing_Copies_Take_The_Test
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Work,
        "odd: atom "
        & "half: (v: u32) -> (r: u32) ! odd = "
        & "fail odd when v % 2 == 1 r = v / 2 end half "
        --  Declares the error and never fails: its call stays.
        & "never: (v: u32) -> (r: u32) ! odd = r = v end never "
        & "twice: (v: u32) -> (r: u32) ! odd = "
        & "r = try half(v) + try never(v) end twice "
        & "public main: () -> (code: i32) = "
        & "code = i32(twice(4) else 0) end main");
      declare
         Code : IR.Unit renames Landin.Stages.Code (Work).all;
         Twice : constant IR.Item_Id := Named (Work, "twice");
         Half : constant IR.Item_Id := Named (Work, "half");
         Never : constant IR.Item_Id := Named (Work, "never");
         Tests : constant Natural := Count (Code, Twice, IR.Failure_Test);
         Fails : constant Natural := Count (Code, Twice, IR.Fail);
      begin
         IR.Inlining.Run (Code, Landin.Stages.Target (Work), Opt.Speed);
         Landin.Testing.Check
           (Item, Calls_To (Code, Twice, Half) = 0
              and then IR.Inline_Site_Count (Code, Twice) = 1,
            "the call that can fail is copied at its failure test");
         Landin.Testing.Check_Equal
           (Item, Calls_To (Code, Twice, Never), 1,
            "a routine that never fails stays a call");
         Landin.Testing.Check_Equal
           (Item, Count (Code, Twice, IR.Failure_Test), Tests - 1,
            "the copy's test is the choice its exits make");
         Landin.Testing.Check_Equal
           (Item, Count (Code, Twice, IR.Fail), Fails,
            "the copy's failure is twice's own propagation, unchanged");
      end;
   end Failing_Copies_Take_The_Test;

   procedure Copies_Read_Arguments_In_Place
     (Item : in out Landin.Testing.Context);
   procedure Copies_Read_Arguments_In_Place
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      Lower (Item, Work,
        "pair: type = struct left: u64 right: u64 rows: [6]u64 end pair "
        & "total: (value: pair) -> (sum: u64) = "
        & "sum = value.left + value.rows[5] end total "
        & "public main: () -> (code: i32) = mut p: pair = zeroed "
        & "p.left = 1 q: pair = p "
        --  An address of p could write it while a copy reads it.
        & "seen: ptr mut pair = addr p seen.val.right = 2 "
        & "code = i32(total(q)) + i32(total(p)) end main");
      declare
         Code : IR.Unit renames Landin.Stages.Code (Work).all;
         Main : constant IR.Item_Id := Named (Work, "main");
         Total : constant IR.Item_Id := Named (Work, "total");
         Copies : constant Natural := Count (Code, Main, IR.Copy_Array);
         Read_There : Natural := 0;
      begin
         IR.Inlining.Run (Code, Landin.Stages.Target (Work), Opt.Speed);
         Landin.Testing.Check_Equal
           (Item, Calls_To (Code, Main, Total), 0, "both calls are copied");
         for A in 1 .. IR.Source_Alias_Count (Code, Main) loop
            if IR.Alias_Inlined_Parameter (Code, Main, A) /= IR.No_Slot then
               Read_There := Read_There + 1;
               Landin.Testing.Check
                 (Item, IR.Nth_Source_Alias (Code, Main, A).Binding
                    = IR.Declares
                        (Code, Total,
                         IR.Alias_Inlined_Parameter (Code, Main, A)),
                  "the debugger finds the parameter where it is read");
            end if;
         end loop;
         Landin.Testing.Check_Equal
           (Item, Read_There, 1, "q is read where main keeps it");
         Landin.Testing.Check_Equal
           (Item, Count (Code, Main, IR.Copy_Array), Copies + 1,
            "p, whose address is taken, is copied");
      end;
   end Copies_Read_Arguments_In_Place;

   procedure Growth_Is_Bounded (Item : in out Landin.Testing.Context);
   procedure Growth_Is_Bounded (Item : in out Landin.Testing.Context) is
      Calls : constant := 300;
      Source : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String
          ("step: (x: u64) -> (y: u64) = y = x *% 3 +% 7 end step "
           & "public main: () -> (code: i32) = mut s: u64 = 1 ");
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
   begin
      for Index in 1 .. Calls loop
         Ada.Strings.Unbounded.Append (Source, "s = step(s) ");
      end loop;
      --  The one call in a loop, written last.
      Ada.Strings.Unbounded.Append
        (Source, "mut i: u64 = 0 while i < 3 do s = step(s) inc i end while "
         & "code = i32(s & 1) end main");
      Lower (Item, Work, Ada.Strings.Unbounded.To_String (Source));
      declare
         Code : IR.Unit renames Landin.Stages.Code (Work).all;
         Main : constant IR.Item_Id := Named (Work, "main");
         Step : constant IR.Item_Id := Named (Work, "step");
         Budget : constant Natural :=
           Natural'Max (IR.Inlining.Growth_Floor, Weight (Code, Main));
         Each : constant Natural := Weight (Code, Step);
         Copies : Natural;
      begin
         IR.Inlining.Run (Code, Landin.Stages.Target (Work), Opt.Speed);
         Copies := IR.Inline_Site_Count (Code, Main);
         Landin.Testing.Check
           (Item, Each <= IR.Inlining.Body_Bound
              and then (Calls + 1) * Each > Budget,
            "step is light enough to copy and main may not copy them all");
         Landin.Testing.Check
           (Item, Copies > 0 and then Copies < Calls + 1,
            "some calls are copied and some are not");
         Landin.Testing.Check
           (Item, Copies * Each <= Budget,
            "the copies weigh no more than main may grow by");
         Landin.Testing.Check_Equal
           (Item, Calls_To (Code, Main, Step), Calls + 1 - Copies,
            "every call not copied is still a call");
         for V in 1 .. IR.Value_Count (Code, Main) loop
            if IR.Op_Of (Code, Main, IR.Value_Id (V)) = IR.Call then
               Landin.Testing.Check_Equal
                 (Item, IR.Call_Loop_Depth (Code, Main, IR.Value_Id (V)), 0,
                  "the call in the loop is copied first");
            end if;
         end loop;
      end;
   end Growth_Is_Bounded;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "ir opt", "inlining copies small calls at speed only",
         Copies_At_Speed_Only'Access);
      Landin.Testing.Register
        (Into, "ir opt", "inlined copies keep their checks",
         Copies_Keep_Their_Checks'Access);
      Landin.Testing.Register
        (Into, "ir opt", "inlined failures take the failure test",
         Failing_Copies_Take_The_Test'Access);
      Landin.Testing.Register
        (Into, "ir opt", "inlined copies read arguments in place",
         Copies_Read_Arguments_In_Place'Access);
      Landin.Testing.Register
        (Into, "ir opt", "inlined growth is bounded",
         Growth_Is_Bounded'Access);
   end Register;
end Landin.Tests.IR_Inlining_Suite;
