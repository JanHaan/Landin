--  What the checker answers about nominal aggregate identity, asked directly.
--
--  Struct values remain contextual, so ordinary expressions cannot expose the
--  distinction from outside those contexts.  Lowering needs the answer before
--  it can admit one: this asks the table at that seam rather than pretending
--  equal layouts prove [0710]'s nominal rule.

with Ada.Assertions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Checking;
with Landin.Diagnostics;
with Landin.IR;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Source.Names;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Targets;
with Landin.Tokens;
with Landin.Types;

package body Landin.Tests.Checking_Suite is

   use type Landin.IR.Item_Id;
   use type Landin.IR.Nominal_Type_Id;
   use type Landin.Provenance.Declaration_Id;
   use type Landin.Source.Span;
   use type Landin.Resolution.Application_Class;
   use type Landin.Resolution.Argument_Role;
   use type Landin.Resolution.Call_Match_State;
   use type Landin.Resolution.Declaration_Sort;
   use type Landin.Resolution.Verdict;
   use type Landin.Source.Source_Id;
   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;
   use type Landin.Checking.Actual_Kind;
   use type Landin.Checking.Actual_Type_Form;
   use type Landin.Checking.Array_Element_Form;
   use type Landin.Checking.Atom_Set_Id;
   use type Landin.Checking.Concept_Id;
   use type Landin.Checking.Conformance_Id;
   use type Landin.Checking.Element_Count;
   use type Landin.Checking.Error_Set_Form;
   use type Landin.Checking.Field_Kind;
   use type Landin.Checking.Instance_State;
   use type Landin.Checking.Nominal_Type_Id;
   use type Landin.Checking.Progress;
   use type Landin.Checking.Reference_Id;
   use type Landin.Checking.Routine_Instance_Id;
   use type Landin.Checking.Routine_Instance_State;
   use type Landin.Checking.Signature_Id;
   use type Landin.Types.Magnitude;
   use type Landin.Types.Reference_View;
   use type Landin.Targets.Byte_Alignment;
   use type Landin.Targets.Byte_Count;
   use type Landin.Types.Type_Kind;

   package US renames Ada.Strings.Unbounded;

   function Image (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Checker  : aliased Landin.Stages.Checking.Instance;

   LF : constant Character := Character'Val (10);

   Program : constant String :=
     "ahead: type = point" & LF
     & "point: type = struct" & LF
     & "    x: i32" & LF
     & "end point" & LF
     & "same: type = point" & LF
     & "again: type = same" & LF
     & "other: type = struct" & LF
     & "    x: i32" & LF
     & "end other" & LF;

   Layout_Program : constant String :=
     "ahead: type = span" & LF
     & "span: type = struct" & LF
     & "    start: i32" & LF
     & "    to: i32" & LF
     & "    tag: bool" & LF
     & "end span" & LF
     & "same: type = span" & LF
     & "machine: type = struct" & LF
     & "    word: usize" & LF
     & "    tag: bool" & LF
     & "end machine" & LF
     & "nested: type = struct" & LF
     & "    tag: u8" & LF
     & "    words: [2]usize" & LF
     & "    tail: u16" & LF
     & "end nested" & LF
     & "outer: type = struct" & LF
     & "    prefix: u16" & LF
     & "    child: nested" & LF
     & "    tail: u8" & LF
     & "end outer" & LF;

   --  A loop frame must not copy its two program-sized transfer tables through
   --  Ada.Containers.Vectors.  The production reproducer had 1,217 resolved
   --  declarations; these module bindings cross that same boundary without
   --  carrying the container workload into this narrow checker regression.
   procedure Large_Loop_Frames_Stay_Off_The_Host_Stack
     (Item : in out Landin.Testing.Context);

   procedure Large_Loop_Frames_Stay_Off_The_Host_Stack
     (Item : in out Landin.Testing.Context)
   is
      Pressure_Declarations : constant Positive := 1_220;

      function Source (Conforming : Boolean) return String;

      function Source (Conforming : Boolean) return String
      is
         Text : US.Unbounded_String := US.To_Unbounded_String
           ("ordered: type = concept (t: type)" & LF
            & "end ordered" & LF);
      begin
         for Declaration in 1 .. Pressure_Declarations loop
            US.Append
              (Text, "pressure_" & Image (Declaration) & ": i32 = 0" & LF);
         end loop;
         US.Append
           (Text, (if Conforming then "i32 is ordered ()" & LF
                  else "marker: i32 = 0" & LF)
            & "identity: (t: type is ordered, value: t)"
            & " -> (result: t) =" & LF
            & "    result = value" & LF
            & "end identity" & LF
            & "stress: () -> none =" & LF
            & "    loop do" & LF
            & "        loop do" & LF
            & "            loop do" & LF
            & "                loop do" & LF
            & "                    break" & LF
            & "                end loop" & LF
            & "            end loop" & LF
            & "        end loop" & LF
            & "    end loop" & LF
            & "end stress" & LF
            & "use: () -> none =" & LF
            & "    _ = identity(42)" & LF
            & "end use" & LF);
         return US.To_String (Text);
      end Source;

      procedure Check_Source (Conforming : Boolean);

      procedure Check_Source (Conforming : Boolean)
      is
         Expected_Declarations : constant Natural :=
           Pressure_Declarations + (if Conforming then 8 else 9);
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Synthetic_32);
         Resolution_Order : Landin.Stages.Pipeline;
         Checking_Order : Landin.Stages.Pipeline;
         Resolution_Ran : Natural;
         Checking_Ran : Natural;
         Src : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source
           (Work, "large-loop-frame.ldn", Source (Conforming));
         Landin.Stages.Append (Resolution_Order, Frontend'Access);
         Landin.Stages.Append (Resolution_Order, Configurer'Access);
         Landin.Stages.Append (Resolution_Order, Names'Access);
         Resolution_Ran := Landin.Stages.Run (Resolution_Order, Work);
         Landin.Testing.Check_Equal
           (Item, Resolution_Ran, 3, "the large loop reaches resolution");
         Landin.Testing.Check_Equal
           (Item,
            Landin.Resolution.Declaration_Count
              (Landin.Stages.Meanings (Work).all),
            Expected_Declarations,
            "resolution records every pressure declaration");

         Landin.Stages.Append (Checking_Order, Checker'Access);
         Checking_Ran := Landin.Stages.Run (Checking_Order, Work);
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check_Equal
              (Item, Checking_Ran, 1, "the large loop reaches checking");
            Landin.Testing.Check
              (Item, Landin.Stages.Failed (Work) /= Conforming
               and then
                 (if Conforming then Landin.Diagnostics.Count (Reports) = 0
                  else Landin.Diagnostics.Count (Reports) = 1
                    and then Landin.Diagnostics.Code
                      (Landin.Diagnostics.Get (Reports, 1)) = "L0318"),
               (if Conforming
                then "the accepted large loop keeps no diagnostic"
                else "the refused large loop retains its evidence"
                  & " diagnostic"));
         end;
      end Check_Source;
   begin
      Check_Source (Conforming => False);
      Check_Source (Conforming => True);
   end Large_Loop_Frames_Stay_Off_The_Host_Stack;

   procedure Try_Failures_Check_Reference_Cleanups
     (Item : in out Landin.Testing.Context);

   procedure Try_Failures_Check_Reference_Cleanups
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Source
        (Label, Text : String; Accepted : Boolean);

      procedure Check_Source
        (Label, Text : String; Accepted : Boolean)
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source (Work, "try-origins.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check_Equal (Item, Ran, 4, Label & " reaches flow");
            Landin.Testing.Check
              (Item, Landin.Stages.Failed (Work) /= Accepted
                 and then
                   (if Accepted then Landin.Diagnostics.Count (Reports) = 0
                    else Landin.Diagnostics.Count (Reports) = 1
                      and then Landin.Diagnostics.Code
                        (Landin.Diagnostics.Get (Reports, 1)) = "L0314"),
               Label & " has its exact origin or assignment verdict");
         end;
      end Check_Source;
   begin
      Check_Source
        ("undo frame on try",
         "problem: atom" & LF
         & "anchor: i32 = 42" & LF
         & "mut saved: ptr i32 = ptr(4096)" & LF
         & "retain: (escaping value: ptr i32) -> none = saved = value"
         & " end retain" & LF
         & "use: (value: i32) -> none = end use" & LF
         & "may_fail: () -> none ! problem = fail problem end may_fail" & LF
         & "may_fail_with: (value: i32) -> none ! problem = fail"
         & " problem end may_fail_with" & LF
         & "number_fail: () -> (r: i32) ! problem = fail problem end"
         & " number_fail" & LF
         & "f: () -> none ! problem = local: i32 = 42 undo retain(addr"
         & " local) try may_fail() end f" & LF,
         Accepted => False);
      Check_Source
        ("defer before success replacement",
         "problem: atom" & LF
         & "anchor: i32 = 42" & LF
         & "mut saved: ptr i32 = ptr(4096)" & LF
         & "retain: (escaping value: ptr i32) -> none = saved = value"
         & " end retain" & LF
         & "use: (value: i32) -> none = end use" & LF
         & "may_fail: () -> none ! problem = fail problem end may_fail" & LF
         & "may_fail_with: (value: i32) -> none ! problem = fail"
         & " problem end may_fail_with" & LF
         & "number_fail: () -> (r: i32) ! problem = fail problem end"
         & " number_fail" & LF
         & "f: () -> none ! problem = local: i32 = 42 mut view: ptr i32"
         & " = addr local defer retain(view) try may_fail() view = addr"
         & " anchor end f" & LF,
         Accepted => False);
      Check_Source
        ("direct failure control",
         "problem: atom" & LF
         & "anchor: i32 = 42" & LF
         & "mut saved: ptr i32 = ptr(4096)" & LF
         & "retain: (escaping value: ptr i32) -> none = saved = value"
         & " end retain" & LF
         & "use: (value: i32) -> none = end use" & LF
         & "may_fail: () -> none ! problem = fail problem end may_fail" & LF
         & "may_fail_with: (value: i32) -> none ! problem = fail"
         & " problem end may_fail_with" & LF
         & "number_fail: () -> (r: i32) ! problem = fail problem end"
         & " number_fail" & LF
         & "f: () -> none ! problem = local: i32 = 42 undo retain(addr"
         & " local) fail problem end f" & LF,
         Accepted => False);
      Check_Source
        ("non-escaping parameter",
         "problem: atom" & LF
         & "anchor: i32 = 42" & LF
         & "mut saved: ptr i32 = ptr(4096)" & LF
         & "retain: (escaping value: ptr i32) -> none = saved = value"
         & " end retain" & LF
         & "use: (value: i32) -> none = end use" & LF
         & "may_fail: () -> none ! problem = fail problem end may_fail" & LF
         & "may_fail_with: (value: i32) -> none ! problem = fail"
         & " problem end may_fail_with" & LF
         & "number_fail: () -> (r: i32) ! problem = fail problem end"
         & " number_fail" & LF
         & "f: (value: ptr i32) -> none ! problem = undo retain(value)"
         & " try may_fail() end f" & LF,
         Accepted => False);
      Check_Source
        ("escaping parameter",
         "problem: atom" & LF
         & "anchor: i32 = 42" & LF
         & "mut saved: ptr i32 = ptr(4096)" & LF
         & "retain: (escaping value: ptr i32) -> none = saved = value"
         & " end retain" & LF
         & "use: (value: i32) -> none = end use" & LF
         & "may_fail: () -> none ! problem = fail problem end may_fail" & LF
         & "may_fail_with: (value: i32) -> none ! problem = fail"
         & " problem end may_fail_with" & LF
         & "number_fail: () -> (r: i32) ! problem = fail problem end"
         & " number_fail" & LF
         & "f: (escaping value: ptr i32) -> none ! problem = undo"
         & " retain(value) try may_fail() end f" & LF,
         Accepted => True);
      Check_Source
        ("static reference",
         "problem: atom" & LF
         & "anchor: i32 = 42" & LF
         & "mut saved: ptr i32 = ptr(4096)" & LF
         & "retain: (escaping value: ptr i32) -> none = saved = value"
         & " end retain" & LF
         & "use: (value: i32) -> none = end use" & LF
         & "may_fail: () -> none ! problem = fail problem end may_fail" & LF
         & "may_fail_with: (value: i32) -> none ! problem = fail"
         & " problem end may_fail_with" & LF
         & "number_fail: () -> (r: i32) ! problem = fail problem end"
         & " number_fail" & LF
         & "f: () -> none ! problem = undo retain(addr anchor) try"
         & " may_fail() end f" & LF,
         Accepted => True);
      Check_Source
        ("undo skips success",
         "problem: atom" & LF
         & "anchor: i32 = 42" & LF
         & "mut saved: ptr i32 = ptr(4096)" & LF
         & "retain: (escaping value: ptr i32) -> none = saved = value"
         & " end retain" & LF
         & "use: (value: i32) -> none = end use" & LF
         & "may_fail: () -> none ! problem = fail problem end may_fail" & LF
         & "may_fail_with: (value: i32) -> none ! problem = fail"
         & " problem end may_fail_with" & LF
         & "number_fail: () -> (r: i32) ! problem = fail problem end"
         & " number_fail" & LF
         & "f: () -> none ! problem = local: i32 = 42 undo retain(addr"
         & " local) return end f" & LF,
         Accepted => True);
      Check_Source
        ("recovered call does not propagate",
         "problem: atom" & LF
         & "anchor: i32 = 42" & LF
         & "mut saved: ptr i32 = ptr(4096)" & LF
         & "retain: (escaping value: ptr i32) -> none = saved = value"
         & " end retain" & LF
         & "use: (value: i32) -> none = end use" & LF
         & "may_fail: () -> none ! problem = fail problem end may_fail" & LF
         & "may_fail_with: (value: i32) -> none ! problem = fail"
         & " problem end may_fail_with" & LF
         & "number_fail: () -> (r: i32) ! problem = fail problem end"
         & " number_fail" & LF
         & "f: () -> none ! problem = local: i32 = 42 undo retain(addr"
         & " local) may_fail() else 0 return end f" & LF,
         Accepted => True);
      Check_Source
        ("nested try",
         "problem: atom" & LF
         & "anchor: i32 = 42" & LF
         & "mut saved: ptr i32 = ptr(4096)" & LF
         & "retain: (escaping value: ptr i32) -> none = saved = value"
         & " end retain" & LF
         & "use: (value: i32) -> none = end use" & LF
         & "may_fail: () -> none ! problem = fail problem end may_fail" & LF
         & "may_fail_with: (value: i32) -> none ! problem = fail"
         & " problem end may_fail_with" & LF
         & "number_fail: () -> (r: i32) ! problem = fail problem end"
         & " number_fail" & LF
         & "f: () -> none ! problem = local: i32 = 42 undo retain(addr"
         & " local) value: i32 = 1 + try number_fail() end f" & LF,
         Accepted => False);
      Check_Source
        ("labelled try",
         "problem: atom" & LF
         & "anchor: i32 = 42" & LF
         & "mut saved: ptr i32 = ptr(4096)" & LF
         & "retain: (escaping value: ptr i32) -> none = saved = value"
         & " end retain" & LF
         & "use: (value: i32) -> none = end use" & LF
         & "may_fail: () -> none ! problem = fail problem end may_fail" & LF
         & "may_fail_with: (value: i32) -> none ! problem = fail"
         & " problem end may_fail_with" & LF
         & "number_fail: () -> (r: i32) ! problem = fail problem end"
         & " number_fail" & LF
         & "f: () -> none ! problem = local: i32 = 42 undo retain(addr"
         & " local) try may_fail_with(value: 0) end f" & LF,
         Accepted => False);
      Check_Source
        ("failure origins do not leak into success",
         "problem: atom" & LF
         & "anchor: i32 = 42" & LF
         & "mut saved: ptr i32 = ptr(4096)" & LF
         & "retain: (escaping value: ptr i32) -> none = saved = value"
         & " end retain" & LF
         & "use: (value: i32) -> none = end use" & LF
         & "may_fail: () -> none ! problem = fail problem end may_fail" & LF
         & "may_fail_with: (value: i32) -> none ! problem = fail"
         & " problem end may_fail_with" & LF
         & "number_fail: () -> (r: i32) ! problem = fail problem end"
         & " number_fail" & LF
         & "f: () -> (r: ptr i32) ! problem = local: i32 = 42 mut view:"
         & " ptr i32 = addr anchor undo use(begin view = addr local 1"
         & " end) try may_fail() r = view end f" & LF,
         Accepted => True);
      Check_Source
        ("failure restoration does not excuse success",
         "problem: atom" & LF
         & "anchor: i32 = 42" & LF
         & "mut saved: ptr i32 = ptr(4096)" & LF
         & "retain: (escaping value: ptr i32) -> none = saved = value"
         & " end retain" & LF
         & "use: (value: i32) -> none = end use" & LF
         & "may_fail: () -> none ! problem = fail problem end may_fail" & LF
         & "may_fail_with: (value: i32) -> none ! problem = fail"
         & " problem end may_fail_with" & LF
         & "number_fail: () -> (r: i32) ! problem = fail problem end"
         & " number_fail" & LF
         & "f: () -> (r: ptr i32) ! problem = local: i32 = 42 mut view:"
         & " ptr i32 = addr local undo use(begin view = addr anchor 1"
         & " end) try may_fail() r = view end f" & LF,
         Accepted => False);
      Check_Source
        ("failure uses post-argument origins",
         "problem: atom" & LF
         & "anchor: i32 = 42" & LF
         & "mut saved: ptr i32 = ptr(4096)" & LF
         & "retain: (escaping value: ptr i32) -> none = saved = value"
         & " end retain" & LF
         & "use: (value: i32) -> none = end use" & LF
         & "may_fail: () -> none ! problem = fail problem end may_fail" & LF
         & "may_fail_with: (value: i32) -> none ! problem = fail"
         & " problem end may_fail_with" & LF
         & "number_fail: () -> (r: i32) ! problem = fail problem end"
         & " number_fail" & LF
         & "f: () -> none ! problem = local: i32 = 42 mut view: ptr i32"
         & " = addr anchor undo retain(view) try may_fail_with(begin"
         & " view = addr local 1 end) end f" & LF,
         Accepted => False);
      Check_Source
        ("argument return prevents the call",
         "problem: atom" & LF
         & "anchor: i32 = 42" & LF
         & "mut saved: ptr i32 = ptr(4096)" & LF
         & "retain: (escaping value: ptr i32) -> none = saved = value"
         & " end retain" & LF
         & "use: (value: i32) -> none = end use" & LF
         & "may_fail: () -> none ! problem = fail problem end may_fail" & LF
         & "may_fail_with: (value: i32) -> none ! problem = fail"
         & " problem end may_fail_with" & LF
         & "number_fail: () -> (r: i32) ! problem = fail problem end"
         & " number_fail" & LF
         & "f: () -> none ! problem = local: i32 = 42 undo retain(addr"
         & " local) try may_fail_with(begin return end) end f" & LF,
         Accepted => True);
   end Try_Failures_Check_Reference_Cleanups;

   procedure Joined_Destinations_Keep_Escape_Obligations
     (Item : in out Landin.Testing.Context);

   procedure Joined_Destinations_Keep_Escape_Obligations
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Source
        (Label, Text : String; Accepted : Boolean);

      procedure Check_Source
        (Label, Text : String; Accepted : Boolean)
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source (Work, "joined-facts.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check_Equal (Item, Ran, 4, Label & " reaches flow");
            Landin.Testing.Check
              (Item, Landin.Stages.Failed (Work) /= Accepted
                 and then
                   (if Accepted then Landin.Diagnostics.Count (Reports) = 0
                    else Landin.Diagnostics.Count (Reports) = 1
                      and then Landin.Diagnostics.Code
                        (Landin.Diagnostics.Get (Reports, 1)) = "L0314"),
               Label & " has its exact origin or assignment verdict");
         end;
      end Check_Source;
   begin
      Check_Source
        ("frame and caller",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (inout out: ptr i32, flag: bool) -> none =" & LF
         & "mut spare: ptr i32 = addr anchor" & LF
         & "mut view: ptr mut ptr i32 = addr spare" & LF
         & "if flag then view = addr out end if" & LF
         & "inner: i32 = 1" & LF
         & "view.val = addr inner" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("caller directly",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (inout out: ptr i32) -> none =" & LF
         & "view: ptr mut ptr i32 = addr out" & LF
         & "inner: i32 = 1" & LF
         & "view.val = addr inner" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("frame only",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: () -> none =" & LF
         & "mut spare: ptr i32 = addr anchor" & LF
         & "mut view: ptr mut ptr i32 = addr spare" & LF
         & "inner: i32 = 1" & LF
         & "view.val = addr inner" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("two frame alternatives",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (flag: bool) -> none =" & LF
         & "mut spare: ptr i32 = addr anchor" & LF
         & "mut view: ptr mut ptr i32 = addr spare" & LF
         & "mut other: ptr i32 = addr anchor" & LF
         & "if flag then view = addr other end if" & LF
         & "inner: i32 = 1" & LF
         & "view.val = addr inner" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("frame and module",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (flag: bool) -> none =" & LF
         & "mut spare: ptr i32 = addr anchor" & LF
         & "mut view: ptr mut ptr i32 = addr spare" & LF
         & "if flag then view = addr module_slot end if" & LF
         & "inner: i32 = 1" & LF
         & "view.val = addr inner" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("module and frame reversed",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (flag: bool) -> none =" & LF
         & "mut spare: ptr i32 = addr anchor" & LF
         & "mut view: ptr mut ptr i32 = addr module_slot" & LF
         & "if flag then view = addr spare end if" & LF
         & "inner: i32 = 1" & LF
         & "view.val = addr inner" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("parameter alternatives",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (inout a: ptr i32, inout b: ptr i32, flag: bool) -> "
         & "none =" & LF
         & "mut view: ptr mut ptr i32 = addr a" & LF
         & "if flag then view = addr b end if" & LF
         & "view.val = a" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("parameter alternatives reversed",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (inout a: ptr i32, inout b: ptr i32, flag: bool) -> "
         & "none =" & LF
         & "mut view: ptr mut ptr i32 = addr b" & LF
         & "if flag then view = addr a end if" & LF
         & "view.val = a" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("same parameter",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (inout a: ptr i32) -> none =" & LF
         & "view: ptr mut ptr i32 = addr a" & LF
         & "view.val = a" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("same parameter and frame",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (inout a: ptr i32, flag: bool) -> none =" & LF
         & "mut spare: ptr i32 = addr anchor" & LF
         & "mut view: ptr mut ptr i32 = addr spare" & LF
         & "if flag then view = addr a end if" & LF
         & "view.val = a" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("other parameter and frame",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (a: ptr i32, inout b: ptr i32, flag: bool) -> none =" & LF
         & "mut spare: ptr i32 = addr anchor" & LF
         & "mut view: ptr mut ptr i32 = addr spare" & LF
         & "if flag then view = addr b end if" & LF
         & "view.val = a" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("same parameter and module",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (inout a: ptr i32, flag: bool) -> none =" & LF
         & "mut view: ptr mut ptr i32 = addr a" & LF
         & "if flag then view = addr module_slot end if" & LF
         & "view.val = a" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("escaping parameter across destinations",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (escaping a: ptr i32, inout b: ptr i32, flag: bool) "
         & "-> none =" & LF
         & "mut spare: ptr i32 = addr anchor" & LF
         & "mut view: ptr mut ptr i32 = addr spare" & LF
         & "if flag then view = addr b end if" & LF
         & "view.val = a" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("pure untracked destination",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: () -> none =" & LF
         & "view: ptr mut ptr i32 = ptr(4096)" & LF
         & "inner: i32 = 1" & LF
         & "view.val = addr inner" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("untracked and caller",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (inout out: ptr i32, flag: bool) -> none =" & LF
         & "mut view: ptr mut ptr i32 = ptr(4096)" & LF
         & "if flag then view = addr out end if" & LF
         & "inner: i32 = 1" & LF
         & "view.val = addr inner" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("untracked and module",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (flag: bool) -> none =" & LF
         & "mut view: ptr mut ptr i32 = ptr(4096)" & LF
         & "if flag then view = addr module_slot end if" & LF
         & "inner: i32 = 1" & LF
         & "view.val = addr inner" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("control value destination",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (inout out: ptr i32, flag: bool) -> none =" & LF
         & "mut spare: ptr i32 = addr anchor" & LF
         & "view: ptr mut ptr i32 =" & LF
         & "if flag then addr spare else addr out end if" & LF
         & "inner: i32 = 1" & LF
         & "view.val = addr inner" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("loop destination join",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (inout out: ptr i32, flag: bool) -> none =" & LF
         & "mut spare: ptr i32 = addr anchor" & LF
         & "mut view: ptr mut ptr i32 = addr spare" & LF
         & "while flag do view = addr out break end while" & LF
         & "inner: i32 = 1" & LF
         & "view.val = addr inner" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("module reference value joins frame",
         "anchor: i32 = 42" & LF
         & "mut module_slot: ptr i32 = ptr(4096)" & LF
         & "f: (flag: bool) -> none =" & LF
         & "mut spare: ptr i32 = addr anchor" & LF
         & "mut view: ptr mut ptr i32 = addr spare" & LF
         & "if flag then view = addr module_slot end if" & LF
         & "view.val = addr anchor" & LF
         & "end f" & LF,
         Accepted => True);
   end Joined_Destinations_Keep_Escape_Obligations;

   procedure Assigned_Children_Cover_Element_Descendants
     (Item : in out Landin.Testing.Context);

   procedure Assigned_Children_Cover_Element_Descendants
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Source
        (Label, Text : String; Accepted : Boolean);

      procedure Check_Source
        (Label, Text : String; Accepted : Boolean)
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source (Work, "joined-facts.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check_Equal (Item, Ran, 4, Label & " reaches flow");
            Landin.Testing.Check
              (Item, Landin.Stages.Failed (Work) /= Accepted
                 and then
                   (if Accepted then Landin.Diagnostics.Count (Reports) = 0
                    else Landin.Diagnostics.Count (Reports) = 1
                      and then Landin.Diagnostics.Code
                        (Landin.Diagnostics.Get (Reports, 1)) = "L0302"),
               Label & " has its exact origin or assignment verdict");
         end;
      end Check_Source;
   begin
      Check_Source
        ("whole child covers two leaves",
         "inner: type = struct y: i32 z: i32 end inner" & LF
         & "outer: type = struct x: inner sibling: inner end outer" & LF
         & "wrap: type = struct child: outer end wrap" & LF
         & "take: (sink value: i32) -> none = end take" & LF
         & "f: (flag: bool) -> (r: i32) =" & LF
         & "mut a: [2]outer" & LF
         & "src: inner = (y: 5, z: 6)" & LF
         & "a[0].x = src" & LF
         & "r = a[0].x.y + a[0].x.z" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("whole child does not cover sibling",
         "inner: type = struct y: i32 z: i32 end inner" & LF
         & "outer: type = struct x: inner sibling: inner end outer" & LF
         & "wrap: type = struct child: outer end wrap" & LF
         & "take: (sink value: i32) -> none = end take" & LF
         & "f: (flag: bool) -> (r: i32) =" & LF
         & "mut a: [2]outer" & LF
         & "src: inner = (y: 5, z: 6)" & LF
         & "a[0].x = src" & LF
         & "r = a[0].sibling.z" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("whole child does not cover other element",
         "inner: type = struct y: i32 z: i32 end inner" & LF
         & "outer: type = struct x: inner sibling: inner end outer" & LF
         & "wrap: type = struct child: outer end wrap" & LF
         & "take: (sink value: i32) -> none = end take" & LF
         & "f: (flag: bool) -> (r: i32) =" & LF
         & "mut a: [2]outer" & LF
         & "src: inner = (y: 5, z: 6)" & LF
         & "a[0].x = src" & LF
         & "r = a[1].x.z" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("leaf does not cover sibling",
         "inner: type = struct y: i32 z: i32 end inner" & LF
         & "outer: type = struct x: inner sibling: inner end outer" & LF
         & "wrap: type = struct child: outer end wrap" & LF
         & "take: (sink value: i32) -> none = end take" & LF
         & "f: (flag: bool) -> (r: i32) =" & LF
         & "mut a: [2]outer" & LF
         & "src: inner = (y: 5, z: 6)" & LF
         & "a[0].x.y = 5" & LF
         & "r = a[0].x.z" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("leaf does not cover parent",
         "inner: type = struct y: i32 z: i32 end inner" & LF
         & "outer: type = struct x: inner sibling: inner end outer" & LF
         & "wrap: type = struct child: outer end wrap" & LF
         & "take: (sink value: i32) -> none = end take" & LF
         & "f: (flag: bool) -> (r: i32) =" & LF
         & "mut a: [2]outer" & LF
         & "src: inner = (y: 5, z: 6)" & LF
         & "a[0].x.y = 5" & LF
         & "b: inner = a[0].x" & LF
         & "r = b.y" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("deeper child covers leaves",
         "inner: type = struct y: i32 z: i32 end inner" & LF
         & "outer: type = struct x: inner sibling: inner end outer" & LF
         & "wrap: type = struct child: outer end wrap" & LF
         & "take: (sink value: i32) -> none = end take" & LF
         & "f: (flag: bool) -> (r: i32) =" & LF
         & "mut a: [2]wrap" & LF
         & "src: inner = (y: 5, z: 6)" & LF
         & "a[0].child.x = src" & LF
         & "r = a[0].child.x.z" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("whole and leaf edges",
         "inner: type = struct y: i32 z: i32 end inner" & LF
         & "outer: type = struct x: inner sibling: inner end outer" & LF
         & "wrap: type = struct child: outer end wrap" & LF
         & "take: (sink value: i32) -> none = end take" & LF
         & "f: (flag: bool) -> (r: i32) =" & LF
         & "mut a: [2]outer" & LF
         & "src: inner = (y: 5, z: 6)" & LF
         & "if flag then a[0].x = src" & LF
         & "else a[0].x.z = 6 end if" & LF
         & "r = a[0].x.z" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("leaf and whole edges",
         "inner: type = struct y: i32 z: i32 end inner" & LF
         & "outer: type = struct x: inner sibling: inner end outer" & LF
         & "wrap: type = struct child: outer end wrap" & LF
         & "take: (sink value: i32) -> none = end take" & LF
         & "f: (flag: bool) -> (r: i32) =" & LF
         & "mut a: [2]outer" & LF
         & "src: inner = (y: 5, z: 6)" & LF
         & "if flag then a[0].x.z = 6" & LF
         & "else a[0].x = src end if" & LF
         & "r = a[0].x.z" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("join keeps missing sibling unassigned",
         "inner: type = struct y: i32 z: i32 end inner" & LF
         & "outer: type = struct x: inner sibling: inner end outer" & LF
         & "wrap: type = struct child: outer end wrap" & LF
         & "take: (sink value: i32) -> none = end take" & LF
         & "f: (flag: bool) -> (r: i32) =" & LF
         & "mut a: [2]outer" & LF
         & "src: inner = (y: 5, z: 6)" & LF
         & "if flag then a[0].x = src" & LF
         & "else a[0].x.z = 6 end if" & LF
         & "r = a[0].x.y" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("consumed descendant stays dead",
         "inner: type = struct y: i32 z: i32 end inner" & LF
         & "outer: type = struct x: inner sibling: inner end outer" & LF
         & "wrap: type = struct child: outer end wrap" & LF
         & "take: (sink value: i32) -> none = end take" & LF
         & "f: (flag: bool) -> (r: i32) =" & LF
         & "mut a: [2]outer" & LF
         & "src: inner = (y: 5, z: 6)" & LF
         & "a[0].x = src" & LF
         & "take(a[0].x.y)" & LF
         & "r = a[0].x.y" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("whole child restores consumed descendant",
         "inner: type = struct y: i32 z: i32 end inner" & LF
         & "outer: type = struct x: inner sibling: inner end outer" & LF
         & "wrap: type = struct child: outer end wrap" & LF
         & "take: (sink value: i32) -> none = end take" & LF
         & "f: (flag: bool) -> (r: i32) =" & LF
         & "mut a: [2]outer" & LF
         & "src: inner = (y: 5, z: 6)" & LF
         & "a[0].x = src" & LF
         & "take(a[0].x.y)" & LF
         & "a[0].x = src" & LF
         & "r = a[0].x.y" & LF
         & "end f" & LF,
         Accepted => True);
   end Assigned_Children_Cover_Element_Descendants;

   procedure Match_Aliases_Keep_Backing_Origins
     (Item : in out Landin.Testing.Context);

   procedure Match_Aliases_Keep_Backing_Origins
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Source
        (Parameters, Prelude, Holder : String; Accepted : Boolean);

      procedure Check_Source
        (Parameters, Prelude, Holder : String; Accepted : Boolean)
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Synthetic_32);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source
           (Work, "match-origins.ldn",
            "missing: atom" & LF
            & "packet: type = struct" & LF
            & "    kind: variant" & LF
            & "        empty | row: (values: [2]u32)" & LF
            & "    end kind" & LF
            & "end packet" & LF
            & "f: (" & Parameters & ") -> (result: []mut u32"
            & (if Accepted then " from source" else "")
            & ") ! missing =" & LF
            & Prelude
            & "    match " & Holder & ".kind" & LF
            & "        empty: fail missing" & LF
            & "        row(inout values): result = values[0..<2]" & LF
            & "    end match" & LF
            & "end f" & LF);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
            Landin.Testing.Check
              (Item, Landin.Stages.Failed (Work) /= Accepted
                 and then
                   (if Accepted then Landin.Diagnostics.Count (Reports) = 0
                    else Landin.Diagnostics.Count (Reports) = 1
                      and then Landin.Diagnostics.Code
                        (Landin.Diagnostics.Get (Reports, 1)) = "L0314"
                      and then Landin.Diagnostics.Message
                        (Landin.Diagnostics.Primary
                           (Landin.Diagnostics.Get (Reports, 1))) =
                             "this returned reference still has frame origin"),
               "match aliases retain backing origin through " & Holder);
         end;
      end Check_Source;
   begin
      Check_Source ("source: ptr mut packet", "", "source.val", True);
      Check_Source
        ("source: []mut packet, index: usize", "", "source[index]", True);
      Check_Source
        ("inout source: [1]packet, index: usize", "", "source[index]", True);
      Check_Source
        ("", "    mut local: packet = zeroed" & LF
         & "    source := addr local" & LF, "source.val", False);
      Check_Source
        ("index: usize", "    mut local: [1]packet = zeroed" & LF
         & "    source := local[0..<1]" & LF, "source[index]", False);
      Check_Source
        ("source: [1]packet, index: usize", "", "source[index]", False);
   end Match_Aliases_Keep_Backing_Origins;

   procedure C_Metadata_Is_Independent_Of_Storage
     (Item : in out Landin.Testing.Context);

   procedure C_Metadata_Is_Independent_Of_Storage
     (Item : in out Landin.Testing.Context)
   is
      package C renames Landin.Checking;
      package IR renames Landin.IR;
      use type Landin.Source.Names.Name_Id;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Src : Landin.Source.Source_Id;
      Ran : Natural;
   begin
      Src := Landin.Stages.Add_Source (Work, "c-metadata.ldn", Program);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check_Equal (Item, Ran, 3, "metadata source resolves");
      if Landin.Stages.Failed (Work) then
         Landin.Testing.Fail (Item, "metadata source was refused");
         return;
      end if;
      declare
         Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access C.Table :=
           Landin.Stages.Types (Work);
         Unit : constant not null access IR.Unit := Landin.Stages.Code (Work);
         Site : constant Landin.Provenance.Origin := Landin.Syntax.Origin
           (Tree.all, Landin.Syntax.Nth_Declaration (Tree.all, 1));
         Symbol : constant Landin.Source.Names.Name_Id :=
           Landin.Source.Names.Intern
             (Landin.Stages.Identities (Work).all, "foreign_point");
      begin
         C.Prepare
           (Types.all, Landin.Stages.Trees (Work).all,
            Landin.Stages.Meanings (Work).all,
            Landin.Stages.Identities (Work).all);
         IR.Prepare (Unit.all, Landin.Stages.Meanings (Work).all);
         declare
            Part : constant C.Signature_Part :=
              (Kind => Landin.Types.I32, Site => Site, others => <>);
            Native : constant C.Signature_Id := C.Add_Signature
              (Types.all, [Part], Part, Site);
            Foreign : constant C.Signature_Id := C.Add_Signature
              (Types.all, [Part], C.Signature_Part_Array'([Part]), Site,
               C_ABI => True);
            Variadic : constant C.Signature_Id := C.Add_Signature
              (Types.all, [Part], Part, Site,
               C_ABI => True, Variadic => True);
            Nested_Native : constant C.Signature_Id := C.Add_Signature
              (Types.all,
               [(Kind => Landin.Types.Function_Value, Signature => Native,
                 Site => Site, others => <>)], Part, Site);
            Nested_Foreign : constant C.Signature_Id := C.Add_Signature
              (Types.all,
               [(Kind => Landin.Types.Function_Value, Signature => Foreign,
                 Site => Site, others => <>)], Part, Site);
            Nominal : constant C.Nominal_Type_Id :=
              C.Nth_Nominal_Type (Types.all, 1);
            Fits : Boolean;
         begin
            Landin.Testing.Check
              (Item, not C.Signature_Uses_C_ABI (Types.all, Native)
                 and then not C.Signature_Is_Variadic (Types.all, Native)
                 and then C.Signature_Uses_C_ABI (Types.all, Foreign)
                 and then C.Signature_Is_Variadic (Types.all, Variadic),
               "checking builders preserve explicit flags and defaults");
            Landin.Testing.Check
              (Item, not C.Signatures_Agree (Types.all, Native, Foreign)
                 and then not C.Signatures_Agree (Types.all, Foreign, Variadic)
                 and then not C.Signatures_Agree
                   (Types.all, Nested_Native, Nested_Foreign),
               "C convention and varargs participate in recursive identity");
            Landin.Testing.Check
              (Item, C.Link_Symbol (Types.all, 1)
                       = Landin.Source.Names.No_Name,
               "checking link names default to absent");
            C.Note_Link_Symbol (Types.all, 1, Symbol);
            Landin.Testing.Check
              (Item, C.Link_Symbol (Types.all, 1) = Symbol,
               "checking preserves an explicit link symbol");
            C.Lay_Out
              (Types.all, Nominal,
               [(Element => Landin.Types.U8, others => <>),
                (Element => Landin.Types.U32, others => <>),
                (Element => Landin.Types.U8, others => <>)],
               Landin.Targets.Linux_X86_64, Fits, C_Layout => True);
            Landin.Testing.Check
              (Item, Fits and then C.Has_C_Layout (Types.all, Nominal)
                 and then C.Field_Offset (Types.all, Nominal, 2) = 4
                 and then C.Layout_Size (Types.all, Nominal) = 12,
               "C layout metadata retains natural placement and tail padding");
         end;
         declare
            Part : constant IR.Signature_Part :=
              (Kind => Landin.Types.I32, others => <>);
            Native : constant IR.Signature_Id :=
              IR.Add_Signature (Unit.all, [Part], Part);
            Foreign : constant IR.Signature_Id :=
              IR.Add_Signature_With_Results
                (Unit.all, [Part], [Part], C_ABI => True);
            Variadic : constant IR.Signature_Id := IR.Add_Signature
              (Unit.all, [Part], Part, C_ABI => True, Variadic => True);
            First : constant IR.Nominal_Type_Id :=
              IR.Add_Nominal_Type (Unit.all, 1);
            Second : constant IR.Nominal_Type_Id :=
              IR.Add_Nominal_Type (Unit.all, 1);
            Third : constant IR.Nominal_Type_Id :=
              IR.Add_Nominal_Type (Unit.all, 1);
            Scalar : constant IR.Field_Shape :=
              (Element => Landin.Types.F64, others => <>);
            Prefix : constant Natural := IR.Add_Shape_Run
              (Unit.all, [(Element => Landin.Types.U8, others => <>)]);
            Root : constant IR.Field_Shape :=
              (Kind => IR.Aggregate_Field_Shape, Cases => 1,
               Payloads_First => 1, others => <>);
            Shape : IR.Field_Shape;
         begin
            Landin.Testing.Check
              (Item, not IR.Signature_Uses_C_ABI (Unit.all, Native)
                 and then IR.Signature_Uses_C_ABI (Unit.all, Foreign)
                 and then IR.Signature_Is_Variadic (Unit.all, Variadic)
                 and then not IR.Signatures_Agree (Unit.all, Native, Foreign)
                 and then not IR.Signatures_Agree
                   (Unit.all, Foreign, Variadic),
               "IR builders preserve flags in signature identity");
            Landin.Testing.Check
              (Item, Prefix = 1
                 and then not IR.Has_Nominal_Shape (Unit.all, First)
                 and then not IR.Nominal_Field_Run_Is_Valid
                   (Unit.all, IR.No_Nominal_Type),
               "unregistered and absent nominal shapes are distinct");
            IR.Set_Nominal_Shape (Unit.all, First, [Scalar], C_Layout => True);
            Landin.Testing.Check
              (Item, IR.Item_Count (Unit.all) = 0
                 and then IR.Has_C_Layout (Unit.all, First)
                 and then IR.Aggregate_Field_Count
                   (Unit.all,
                    (Kind => IR.Aggregate_Field_Shape, Nominal => First,
                     others => <>)) = 1,
               "import-only nominals have canonical fields without storage");
            IR.Set_Nominal_Shape
              (Unit.all, Second, [7 => Root],
               Cases => [5 => (First => 4, Count => 1)],
               Payloads =>
                 [8 => (Kind => IR.Array_Field_Shape, Length => 2,
                        Cases => 1, Payloads_First => 2, others => <>),
                  9 => (Kind => IR.Aggregate_Field_Shape,
                        Cases => 1, Payloads_First => 3, others => <>),
                  10 => (Kind => IR.Variant_Field_Shape,
                         Cases => 1, Payloads_First => 1, others => <>),
                  11 => Scalar]);
            Shape := IR.Nth_Nominal_Field (Unit.all, Second, 1);
            IR.Set_Nominal_Shape (Unit.all, Third, [Shape]);
            Landin.Testing.Check
              (Item, IR.Same_Shape
                 (Unit.all, Shape, IR.Nth_Nominal_Field (Unit.all, Third, 1)),
               "already absolute shared payload runs are not rebased twice");
            Shape := IR.Nth_Aggregate_Field (Unit.all, Shape, 1);
            Shape := IR.Array_Element_Shape (Unit.all, Shape);
            Shape := IR.Nth_Aggregate_Field (Unit.all, Shape, 1);
            Shape := IR.Nth_Variant_Case_Field (Unit.all, Shape, 1, 1);
            Landin.Testing.Check
              (Item, Shape.Element = Landin.Types.F64,
               "every recursive local payload index is normalized");
            Landin.Testing.Check
              (Item, not IR.Variant_Case_Run_Is_Valid
                 (Unit.all,
                  (Kind => IR.Variant_Field_Shape, Cases => Natural'Last,
                   Payloads_First => Natural'Last, others => <>), 1),
               "malformed case runs are safe to query in every build mode");
            begin
               Shape := IR.Nth_Nominal_Field (Unit.all, First, 2);
               pragma Assert (Shape.Element = Landin.Types.F64);
               Landin.Testing.Fail (Item, "an invalid nominal index escaped");
            exception
               when Landin.Compiler_Defect =>
                  Landin.Testing.Check
                    (Item, True, "nominal access has a release-mode guard");
            end;
         end;
      end;
   end C_Metadata_Is_Independent_Of_Storage;

   procedure Declarations_Give_Structs_Their_Identity
     (Item : in out Landin.Testing.Context);

   procedure Nominal_Instances_Intern_Normalized_Actuals
     (Item : in out Landin.Testing.Context);

   procedure Routine_Instance_Views_Keep_Source_Facts_Separate
     (Item : in out Landin.Testing.Context);

   procedure Generic_Array_Selections_Keep_Field_Metadata
     (Item : in out Landin.Testing.Context);

   procedure Float_Specials_Have_Canonical_Bits
     (Item : in out Landin.Testing.Context);

   procedure Float_Arithmetic_Uses_IEEE_Bits
     (Item : in out Landin.Testing.Context);

   procedure Failed_Generic_Deduction_Has_No_Target
     (Item : in out Landin.Testing.Context);

   procedure Structural_Deduction_Interns_Complete_Tuple
     (Item : in out Landin.Testing.Context);

   procedure Reference_Actuals_Keep_Complete_Identity
     (Item : in out Landin.Testing.Context);

   procedure Generic_Signatures_Keep_Nominal_Array_Elements
     (Item : in out Landin.Testing.Context);

   procedure Discovery_Skips_Refused_Generic_Calls
     (Item : in out Landin.Testing.Context);

   procedure Recovery_Deduction_Interns_Final_Sets
     (Item : in out Landin.Testing.Context);

   procedure Generic_Instances_Carry_Declared_Errors
     (Item : in out Landin.Testing.Context);

   procedure Generic_Instances_Infer_Errors_Per_Key
     (Item : in out Landin.Testing.Context);

   procedure Erased_Recovery_Bindings_Have_Exact_Errors
     (Item : in out Landin.Testing.Context);

   procedure Inferred_Erased_Results_Use_Exact_Entry_Shapes
     (Item : in out Landin.Testing.Context);

   procedure Contextual_Generic_Text_Literals_Keep_Exact_Views
     (Item : in out Landin.Testing.Context);

   procedure Declared_Structs_Follow_Target_Layout
     (Item : in out Landin.Testing.Context);

   procedure Declarations_Give_Structs_Their_Identity
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source (Work, "identity.ldn", Program);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "the declarations are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);

         Ahead_Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 1);
         Point_Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 2);
         Alias_Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 3);
         Again_Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 4);
         Other_Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 5);

         function Declaration_At (Node : Landin.Syntax.Node_Id)
           return Landin.Provenance.Declaration_Id;

         function Declaration_At (Node : Landin.Syntax.Node_Id)
           return Landin.Provenance.Declaration_Id is
         begin
            for Id in Landin.Provenance.Declaration_Id'(1)
                      .. Landin.Provenance.Declaration_Id
                           (Landin.Resolution.Declaration_Count (Meanings.all))
            loop
               if Landin.Resolution.Source_Of (Meanings.all, Id) = Src
                 and then Landin.Resolution.Node_Of (Meanings.all, Id) = Node
               then
                  return Id;
               end if;
            end loop;

            return Landin.Provenance.No_Declaration;
         end Declaration_At;

         Ahead : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (Ahead_Node);
         Point : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (Point_Node);
         Alias : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (Alias_Node);
         Again : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (Again_Node);
         Other : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (Other_Node);
         Point_Body : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type (Of_Tree.all, Point_Node);
         Alias_Type : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type (Of_Tree.all, Alias_Node);
         Other_Body : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type (Of_Tree.all, Other_Node);
         Point_Type : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Empty_Nominal_Instance (Types.all, Point);
         Other_Type : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Empty_Nominal_Instance (Types.all, Other);
      begin
         Landin.Testing.Check
           (Item,
            Ahead /= Landin.Provenance.No_Declaration
            and then Point /= Landin.Provenance.No_Declaration
            and then Alias /= Landin.Provenance.No_Declaration
            and then Again /= Landin.Provenance.No_Declaration
            and then Other /= Landin.Provenance.No_Declaration,
            "all five declarations have identities");
         Landin.Testing.Check_Equal
           (Item, Landin.Checking.Nominal_Type_Count (Types.all), 2,
            "the two struct templates have two canonical instances");
         Landin.Testing.Check
           (Item,
            Landin.Checking.Nominal_Of (Types.all, Point) = Point_Type
            and then Landin.Checking.Template_Of (Types.all, Point_Type)
              = Point,
            "a struct declaration owns its empty-actual nominal instance");
         Landin.Testing.Check
           (Item,
            Landin.Checking.Nominal_Of
              (Types.all, Of_Tree.all, Point_Body) = Point_Type,
            "the struct body node carries the identity it created");
         Landin.Testing.Check
           (Item,
            Landin.Checking.Nominal_Of (Types.all, Ahead) = Point_Type
            and then Landin.Checking.Nominal_Of (Types.all, Alias)
              = Point_Type
            and then Landin.Checking.Nominal_Of (Types.all, Again)
              = Point_Type,
            "forward aliases and alias chains preserve one identity");
         Landin.Testing.Check
           (Item,
            Landin.Checking.Nominal_Of (Types.all, Other) = Other_Type
            and then Landin.Checking.Nominal_Of
              (Types.all, Of_Tree.all, Other_Body) = Other_Type,
            "repeated uses of the second struct share its identity");
         Landin.Testing.Check
           (Item, Point_Type /= Other_Type,
            "same-shaped named structs remain nominally unequal");
         Landin.Testing.Check
           (Item,
            Landin.Checking.Nominal_Of (Types.all, Of_Tree.all, Alias_Type)
              = Point_Type,
            "the type-reference node carries the identity into later stages");
         Landin.Testing.Check
           (Item,
            Landin.Checking.Nominal_Identities.Nth (Types.all, 3)
              = Landin.Checking.No_Nominal_Type,
            "enumeration cannot construct an identity outside the table");
         Landin.Testing.Check
           (Item,
            not Landin.Checking.Has_Layout
              (Types.all, Landin.Checking.No_Nominal_Type),
            "Has_Layout safely rejects an identity the table does not hold");
      end;
   end Declarations_Give_Structs_Their_Identity;

   procedure Nominal_Instances_Intern_Normalized_Actuals
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "left: type = struct" & LF
        & "    value: usize" & LF
        & "end left" & LF
        & "right: type = struct" & LF
        & "    value: usize" & LF
        & "end right" & LF;
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;

      function One (Actual : Landin.Checking.Actual_Key)
        return Landin.Checking.Actual_Tuple;

      function One (Actual : Landin.Checking.Actual_Key)
        return Landin.Checking.Actual_Tuple
      is
         Result : Landin.Checking.Actual_Tuple :=
           Landin.Checking.Empty_Actuals;
      begin
         Landin.Checking.Append_Actual (Result, Actual);
         return Result;
      end One;

      function Two (First, Second : Landin.Checking.Actual_Key)
        return Landin.Checking.Actual_Tuple;

      function Two (First, Second : Landin.Checking.Actual_Key)
        return Landin.Checking.Actual_Tuple
      is
         Result : Landin.Checking.Actual_Tuple :=
           Landin.Checking.Empty_Actuals;
      begin
         Landin.Checking.Append_Actual (Result, First);
         Landin.Checking.Append_Actual (Result, Second);
         return Result;
      end Two;
   begin
      Src := Landin.Stages.Add_Source (Work, "instances.ldn", Source_Text);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "the ordinary templates are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         Unit : constant not null access Landin.IR.Unit :=
           Landin.Stages.Code (Work);

         function Declaration_At (Position : Positive)
           return Landin.Provenance.Declaration_Id;

         function Declaration_At (Position : Positive)
           return Landin.Provenance.Declaration_Id
         is
            Node : constant Landin.Syntax.Node_Id :=
              Landin.Syntax.Nth_Declaration (Of_Tree.all, Position);
         begin
            for Id in Landin.Provenance.Declaration_Id'(1)
                      .. Landin.Provenance.Declaration_Id
                           (Landin.Resolution.Declaration_Count (Meanings.all))
            loop
               if Landin.Resolution.Source_Of (Meanings.all, Id) = Src
                 and then Landin.Resolution.Node_Of (Meanings.all, Id) = Node
               then
                  return Id;
               end if;
            end loop;
            return Landin.Provenance.No_Declaration;
         end Declaration_At;

         Left_Template : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (1);
         Right_Template : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (2);
         Left_Empty : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Empty_Nominal_Instance
             (Types.all, Left_Template);
         Right_Empty : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Empty_Nominal_Instance
             (Types.all, Right_Template);
         Site : constant Landin.Provenance.Origin :=
           Landin.Syntax.Origin
             (Of_Tree.all, Landin.Syntax.Nth_Declaration (Of_Tree.all, 1));
         Set_Left_Right : constant Landin.Checking.Atom_Set_Id :=
           Landin.Checking.Add_Atom_Set
             (Types.all, [Left_Template, Right_Template]);
         Set_Right_Left : constant Landin.Checking.Atom_Set_Id :=
           Landin.Checking.Add_Atom_Set
             (Types.all, [Right_Template, Left_Template]);
         Set_Left : constant Landin.Checking.Atom_Set_Id :=
           Landin.Checking.Add_Atom_Set (Types.all, [1 => Left_Template]);
         Signature_Left : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Add_Signature
             (Types.all,
              Landin.Checking.Signature_Part_Array'
                [1 => (Kind => Landin.Types.U8, Site => Site,
                       others => <>)],
              Landin.Checking.Signature_Part_Array'
                [1 => (Kind => Landin.Types.Aggregate,
                       Nominal => Left_Empty, Site => Site, others => <>)],
              Site, Set_Left_Right, Landin.Checking.Concrete);
         Signature_Alias : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Add_Signature
             (Types.all,
              Landin.Checking.Signature_Part_Array'
                [1 => (Kind => Landin.Types.U8, Site => Site,
                       others => <>)],
              Landin.Checking.Signature_Part_Array'
                [1 => (Kind => Landin.Types.Aggregate,
                       Nominal => Left_Empty, Site => Site, others => <>)],
              Site, Set_Right_Left, Landin.Checking.Concrete);
         Signature_Different : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Add_Signature
             (Types.all,
              Landin.Checking.Signature_Part_Array'
                [1 => (Kind => Landin.Types.I8, Site => Site,
                       others => <>)],
              Landin.Checking.Signature_Part_Array'
                [1 => (Kind => Landin.Types.Aggregate,
                       Nominal => Left_Empty, Site => Site, others => <>)],
              Site, Set_Left_Right, Landin.Checking.Concrete);
         Wrapper_Left : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Add_Signature
             (Types.all,
              Landin.Checking.Signature_Part_Array'
                [1 => (Kind => Landin.Types.Function_Value,
                       Signature => Signature_Left, Site => Site,
                       others => <>)],
              Landin.Checking.Signature_Part_Array'
                [1 => (Kind => Landin.Types.Fixed_Array, Length => 3,
                       Nominal => Left_Empty, Site => Site, others => <>)],
              Site);
         Wrapper_Alias : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Add_Signature
             (Types.all,
              Landin.Checking.Signature_Part_Array'
                [1 => (Kind => Landin.Types.Function_Value,
                       Signature => Signature_Alias, Site => Site,
                       others => <>)],
              Landin.Checking.Signature_Part_Array'
                [1 => (Kind => Landin.Types.Fixed_Array, Length => 3,
                       Nominal => Left_Empty, Site => Site, others => <>)],
              Site);

         Hex_Value, Decimal_Value : Landin.Types.Magnitude;
         Hex_Overflow, Decimal_Overflow : Boolean;
         Scalar, Scalar_Alias, Other_Scalar, Other_Template :
           Landin.Checking.Nominal_Type_Id;
         Fixed_Hex, Fixed_Decimal, Fixed_Different :
           Landin.Checking.Nominal_Type_Id;
         Nested, Nested_Again : Landin.Checking.Nominal_Type_Id;
         Atom_Set, Atom_Set_Alias, Atom_Set_Different :
           Landin.Checking.Nominal_Type_Id;
         Scalar_Array, Scalar_Array_Count :
           Landin.Checking.Nominal_Type_Id;
         Aggregate_Array, Other_Aggregate_Array :
           Landin.Checking.Nominal_Type_Id;
         Function_Key, Function_Alias, Function_Different :
           Landin.Checking.Nominal_Type_Id;
         Ordered, Reversed, Scalar_Kind, Fixed_Kind :
           Landin.Checking.Nominal_Type_Id;
         Before : constant Natural :=
           Landin.Checking.Nominal_Type_Count (Types.all);

         procedure Check_Foreign_Key
           (Key : Landin.Checking.Actual_Key; Name : String);

         procedure Check_Foreign_Key
           (Key : Landin.Checking.Actual_Key; Name : String)
         is
            Actuals : Landin.Checking.Actual_Tuple :=
              Landin.Checking.Empty_Actuals;
            Made : Landin.Checking.Nominal_Type_Id :=
              Landin.Checking.No_Nominal_Type;
         begin
            Landin.Checking.Append_Actual (Actuals, Key);
            Landin.Testing.Check
              (Item, not Landin.Checking.Holds (Types.all, Key)
                       and then not Landin.Checking.Holds
                         (Types.all, Actuals),
               Name & " key retains its foreign table provenance");
            begin
               Made := Landin.Checking.Intern_Nominal_Instance
                 (Types.all, Left_Template, Actuals);
               Landin.Testing.Check
                 (Item, Made = Landin.Checking.No_Nominal_Type,
                  Name & " foreign key cannot be interned");
            exception
               when Ada.Assertions.Assertion_Error | Landin.Compiler_Defect =>
                  Landin.Testing.Check
                    (Item, True, Name & " foreign key is rejected");
            end;
         end Check_Foreign_Key;
      begin
         Landin.IR.Prepare (Unit.all, Meanings.all);
         Landin.Testing.Check
           (Item,
            Landin.IR.Item_Count (Unit.all) = 0
              and then Landin.IR.Nominal_Type_Count (Unit.all) = 0,
            "checking has created no IR runtime or nominal entity");

         Landin.Testing.Check
           (Item,
            Landin.Checking.Intern_Nominal_Instance
              (Types.all, Left_Template, Landin.Checking.Empty_Actuals)
              = Left_Empty
              and then Landin.Checking.Instance_Actual_Count
                (Types.all, Left_Empty) = 0
              and then Landin.Checking.Instance_State_Of
                (Types.all, Left_Empty) = Landin.Checking.Instance_Ready,
            "an ordinary struct is the interner's empty-tuple instance");

         Landin.Types.Evaluate
           ("ff", Landin.Tokens.Hexadecimal, Hex_Value, Hex_Overflow);
         Landin.Types.Evaluate
           ("255", Landin.Tokens.Decimal, Decimal_Value, Decimal_Overflow);
         Landin.Testing.Check
           (Item,
            not Hex_Overflow and then not Decimal_Overflow
              and then Hex_Value = Decimal_Value,
            "radix spellings normalize to one mathematical magnitude");

         Scalar := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Scalar_Type_Actual (Landin.Types.U8)));
         Scalar_Alias := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Scalar_Type_Actual (Landin.Types.U8)));
         Other_Scalar := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Scalar_Type_Actual (Landin.Types.I8)));
         Other_Template := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Right_Template,
            One (Landin.Checking.Scalar_Type_Actual (Landin.Types.U8)));
         Landin.Testing.Check
           (Item,
            Scalar = Scalar_Alias
              and then Scalar /= Other_Scalar
              and then Scalar /= Other_Template,
            "normalized aliases share keys while scalar and template"
            & " identity differ");
         Landin.Testing.Check
           (Item,
            Landin.Checking.Nominal_Identities.Position (Types.all, Scalar)
              = Before + 1
              and then Landin.Checking.Nth_Nominal_Type
                (Types.all, Before + 1) = Scalar,
            "new identities follow checker interning order");

         Fixed_Hex := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Fixed_Actual (Hex_Value)));
         Fixed_Decimal := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Fixed_Actual (Decimal_Value)));
         Fixed_Different := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Fixed_Actual (Decimal_Value - 1)));
         Landin.Testing.Check
           (Item,
            Fixed_Hex = Fixed_Decimal
              and then Fixed_Hex /= Fixed_Different,
            "fixed keys retain normalized value but no radix or formal type");

         Nested := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Right_Template,
            One (Landin.Checking.Nominal_Type_Actual
                   (Types.all, Fixed_Hex)));
         Nested_Again := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Right_Template,
            One (Landin.Checking.Nominal_Type_Actual
                   (Types.all, Fixed_Decimal)));
         Landin.Testing.Check
           (Item, Nested = Nested_Again,
            "a nested nominal actual uses its interned instance identity");

         Atom_Set := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Atom_Set_Type_Actual
                   (Types.all, Set_Left_Right)));
         Atom_Set_Alias := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Atom_Set_Type_Actual
                   (Types.all, Set_Right_Left)));
         Atom_Set_Different := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Atom_Set_Type_Actual
                   (Types.all, Set_Left)));
         Landin.Testing.Check
           (Item,
            Atom_Set = Atom_Set_Alias
              and then Atom_Set /= Atom_Set_Different,
            "atom-set actual identity is structural rather than descriptor"
            & " order");

         Scalar_Array := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Fixed_Array_Type_Actual
                   (3, Landin.Types.U8)));
         Scalar_Array_Count := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Fixed_Array_Type_Actual
                   (4, Landin.Types.U8)));
         Aggregate_Array := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Fixed_Array_Type_Actual
                   (Types.all, 3, Left_Empty)));
         Other_Aggregate_Array := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Fixed_Array_Type_Actual
                   (Types.all, 3, Right_Empty)));
         Landin.Testing.Check
           (Item,
            Scalar_Array /= Scalar_Array_Count
              and then Scalar_Array /= Aggregate_Array
              and then Aggregate_Array /= Other_Aggregate_Array,
            "array count and scalar-versus-nominal element identity remain"
            & " exact");

         Function_Key := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Function_Type_Actual
                   (Types.all, Wrapper_Left)));
         Function_Alias := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Function_Type_Actual
                   (Types.all, Wrapper_Alias)));
         Function_Different := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Function_Type_Actual
                   (Types.all, Signature_Different)));
         Landin.Testing.Check
           (Item,
            Function_Key = Function_Alias
              and then Function_Key /= Function_Different,
            "nested function signatures use complete structural identity");

         Ordered := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            Two (Landin.Checking.Scalar_Type_Actual (Landin.Types.U8),
                 Landin.Checking.Fixed_Actual (1)));
         Reversed := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            Two (Landin.Checking.Fixed_Actual (1),
                 Landin.Checking.Scalar_Type_Actual (Landin.Types.U8)));
         Scalar_Kind := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Scalar_Type_Actual (Landin.Types.U8)));
         Fixed_Kind := Landin.Checking.Intern_Nominal_Instance
           (Types.all, Left_Template,
            One (Landin.Checking.Fixed_Actual (0)));
         Landin.Testing.Check
           (Item,
            Ordered /= Reversed and then Scalar_Kind /= Fixed_Kind,
            "actual order and actual kind distinguish unused phantom actuals");

         declare
            Ordered_First : constant Landin.Checking.Actual_Key :=
              Landin.Checking.Nth_Instance_Actual
                (Types.all, Ordered, 1);
            Ordered_Second : constant Landin.Checking.Actual_Key :=
              Landin.Checking.Nth_Instance_Actual
                (Types.all, Ordered, 2);
            Reversed_First : constant Landin.Checking.Actual_Key :=
              Landin.Checking.Nth_Instance_Actual
                (Types.all, Reversed, 1);
            Scalar_Key : constant Landin.Checking.Actual_Key :=
              Landin.Checking.Nth_Instance_Actual
                (Types.all, Scalar, 1);
            Fixed_Key : constant Landin.Checking.Actual_Key :=
              Landin.Checking.Nth_Instance_Actual
                (Types.all, Fixed_Hex, 1);
            Atom_Key : constant Landin.Checking.Actual_Key :=
              Landin.Checking.Nth_Instance_Actual
                (Types.all, Atom_Set, 1);
            Scalar_Array_Key : constant Landin.Checking.Actual_Key :=
              Landin.Checking.Nth_Instance_Actual
                (Types.all, Scalar_Array, 1);
            Aggregate_Array_Key : constant Landin.Checking.Actual_Key :=
              Landin.Checking.Nth_Instance_Actual
                (Types.all, Aggregate_Array, 1);
            Nested_Key : constant Landin.Checking.Actual_Key :=
              Landin.Checking.Nth_Instance_Actual
                (Types.all, Nested, 1);
            Function_Actual_Key : constant Landin.Checking.Actual_Key :=
              Landin.Checking.Nth_Instance_Actual
                (Types.all, Function_Key, 1);
         begin
            Landin.Testing.Check
              (Item,
               Landin.Checking.Instance_Actual_Count (Types.all, Ordered) = 2
                 and then Landin.Checking.Instance_Actual_Count
                   (Types.all, Reversed) = 2
                 and then Landin.Checking.Actual_Kind_Of (Ordered_First)
                   = Landin.Checking.Type_Actual_Kind
                 and then Landin.Checking.Type_Form_Of (Ordered_First)
                   = Landin.Checking.Scalar_Actual_Type
                 and then Landin.Checking.Scalar_Of
                   (Types.all, Ordered_First) = Landin.Types.U8
                 and then Landin.Checking.Actual_Kind_Of (Ordered_Second)
                   = Landin.Checking.Fixed_Actual_Kind
                 and then Landin.Checking.Fixed_Magnitude_Of
                   (Ordered_Second) = 1
                 and then Landin.Checking.Actual_Kind_Of (Reversed_First)
                   = Landin.Checking.Fixed_Actual_Kind,
               "same-template unequal tuples round-trip in exact order");
            Landin.Testing.Check
              (Item,
               Landin.Checking.Scalar_Of (Types.all, Scalar_Key)
                   = Landin.Types.U8
                 and then Landin.Checking.Fixed_Magnitude_Of (Fixed_Key)
                   = Decimal_Value
                 and then Landin.Checking.Atom_Set_Of
                   (Types.all, Atom_Key) = Set_Left_Right,
               "scalar, fixed and structural atom actuals round-trip");
            Landin.Testing.Check
              (Item,
               Landin.Checking.Array_Length_Of
                   (Types.all, Scalar_Array_Key) = 3
                 and then Landin.Checking.Array_Element_Form_Of
                   (Types.all, Scalar_Array_Key)
                     = Landin.Checking.Scalar_Array_Element
                 and then Landin.Checking.Array_Scalar_Element_Of
                   (Types.all, Scalar_Array_Key) = Landin.Types.U8
                 and then Landin.Checking.Array_Length_Of
                   (Types.all, Aggregate_Array_Key) = 3
                 and then Landin.Checking.Array_Element_Form_Of
                   (Types.all, Aggregate_Array_Key)
                     = Landin.Checking.Nominal_Array_Element
                 and then Landin.Checking.Array_Nominal_Element_Of
                   (Types.all, Aggregate_Array_Key) = Left_Empty,
               "fixed-array descriptors round-trip both element families");
            Landin.Testing.Check
              (Item,
               Landin.Checking.Nominal_Of (Types.all, Nested_Key) = Fixed_Hex
                 and then Landin.Checking.Function_Signature_Of
                   (Types.all, Function_Actual_Key) = Wrapper_Left,
               "nested nominal and function descriptors round-trip");
         end;

         Landin.Testing.Check
           (Item,
            Landin.Checking.Instance_State_Of (Types.all, Ordered)
              = Landin.Checking.Instance_Unseen,
            "interning reserves unseen instance and layout storage");
         Landin.Checking.Begin_Instance (Types.all, Ordered);
         Landin.Testing.Check
           (Item,
            Landin.Checking.Instance_State_Of (Types.all, Ordered)
              = Landin.Checking.Instance_Building,
            "instance storage records recursive construction in progress");
         Landin.Checking.Invalidate_Instance (Types.all, Ordered);
         Landin.Testing.Check
           (Item,
            Landin.Checking.Instance_State_Of (Types.all, Ordered)
              = Landin.Checking.Instance_Invalid
              and then Landin.Checking.Intern_Nominal_Instance
                (Types.all, Left_Template,
                 Two (Landin.Checking.Scalar_Type_Actual (Landin.Types.U8),
                      Landin.Checking.Fixed_Actual (1))) = Ordered,
            "invalid state is retained outside the immutable key");

         declare
            Foreign_Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Landin.Targets.Linux_X86_64);
            Foreign_Order : Landin.Stages.Pipeline;
            Foreign_Src : Landin.Source.Source_Id;
            Foreign_Ran : Natural;
         begin
            Foreign_Src := Landin.Stages.Add_Source
              (Foreign_Work, "foreign-instances.ldn", Source_Text);
            Landin.Stages.Append (Foreign_Order, Frontend'Access);
            Landin.Stages.Append (Foreign_Order, Configurer'Access);
            Landin.Stages.Append (Foreign_Order, Names'Access);
            Landin.Stages.Append (Foreign_Order, Checker'Access);
            Foreign_Ran := Landin.Stages.Run (Foreign_Order, Foreign_Work);
            Landin.Testing.Check_Equal
              (Item, Foreign_Ran, 4, "the foreign checker ran");
            Landin.Testing.Check
              (Item, not Landin.Stages.Failed (Foreign_Work),
               "the foreign collision templates are accepted");

            declare
               Foreign_Tree : constant not null access constant
                 Landin.Syntax.Tree := Landin.Syntax.Forest.Tree_Of
                   (Landin.Stages.Trees (Foreign_Work).all, Foreign_Src);
               Foreign_Types : constant not null access
                 Landin.Checking.Table := Landin.Stages.Types (Foreign_Work);
               Foreign_Left : constant Landin.Checking.Nominal_Type_Id :=
                 Landin.Checking.Nth_Nominal_Type (Foreign_Types.all, 1);
               Foreign_Right : constant Landin.Checking.Nominal_Type_Id :=
                 Landin.Checking.Nth_Nominal_Type (Foreign_Types.all, 2);
               Foreign_Left_Template : constant
                 Landin.Provenance.Declaration_Id :=
                   Landin.Checking.Template_Of
                     (Foreign_Types.all, Foreign_Left);
               Foreign_Right_Template : constant
                 Landin.Provenance.Declaration_Id :=
                   Landin.Checking.Template_Of
                     (Foreign_Types.all, Foreign_Right);
               Foreign_Set : constant Landin.Checking.Atom_Set_Id :=
                 Landin.Checking.Add_Atom_Set
                   (Foreign_Types.all,
                    [Foreign_Left_Template, Foreign_Right_Template]);
               Foreign_Site : constant Landin.Provenance.Origin :=
                 Landin.Syntax.Origin
                   (Foreign_Tree.all,
                    Landin.Syntax.Nth_Declaration (Foreign_Tree.all, 1));
               Foreign_Signature : constant Landin.Checking.Signature_Id :=
                 Landin.Checking.Add_Signature
                   (Into       => Foreign_Types.all,
                    Parameters => Landin.Checking.No_Signature_Parts,
                    Result     =>
                      (Kind => Landin.Types.U8, Site => Foreign_Site,
                       others => <>),
                    Site       => Foreign_Site);
               Foreign_Atom_Key : constant Landin.Checking.Actual_Key :=
                 Landin.Checking.Atom_Set_Type_Actual
                   (Foreign_Types.all, Foreign_Set);
               Foreign_Nominal_Key : constant Landin.Checking.Actual_Key :=
                 Landin.Checking.Nominal_Type_Actual
                   (Foreign_Types.all, Foreign_Left);
               Foreign_Array_Key : constant Landin.Checking.Actual_Key :=
                 Landin.Checking.Fixed_Array_Type_Actual
                   (Foreign_Types.all, 3, Foreign_Left);
               Foreign_Function_Key : constant Landin.Checking.Actual_Key :=
                 Landin.Checking.Function_Type_Actual
                   (Foreign_Types.all, Foreign_Signature);
            begin
               Landin.Testing.Check
                 (Item,
                  Foreign_Left = Left_Empty
                    and then Foreign_Set = Set_Left_Right
                    and then Foreign_Signature = Signature_Left,
                  "foreign descriptors deliberately collide numerically");
               Check_Foreign_Key (Foreign_Atom_Key, "atom-set");
               Check_Foreign_Key (Foreign_Nominal_Key, "nominal");
               Check_Foreign_Key (Foreign_Array_Key, "nominal-array");
               Check_Foreign_Key (Foreign_Function_Key, "signature");
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Holds
                    (Types.all, Landin.Checking.Scalar_Type_Actual
                       (Landin.Types.U8))
                    and then Landin.Checking.Holds
                      (Types.all, Landin.Checking.Fixed_Actual (1)),
                  "pure scalar and fixed keys remain table-independent");
            end;
         end;

         Landin.Testing.Check
           (Item,
            Landin.IR.Item_Count (Unit.all) = 0
              and then Landin.IR.Nominal_Type_Count (Unit.all) = 0
              and then Landin.Checking.Declaration_Limit (Types.all)
                = Landin.Resolution.Declaration_Count (Meanings.all),
            "interning synthesizes no declaration, IR item, or runtime"
            & " entity");

         for Position in
           1 .. Landin.Checking.Nominal_Type_Count (Types.all)
         loop
            declare
               Source : constant Landin.Checking.Nominal_Type_Id :=
                 Landin.Checking.Nth_Nominal_Type (Types.all, Position);
               Made : constant Landin.IR.Nominal_Type_Id :=
                 Landin.IR.Add_Nominal_Type
                   (Unit.all, Landin.Checking.Template_Of (Types.all, Source));
            begin
               Landin.Testing.Check
                 (Item,
                  Landin.IR.Nth_Nominal_Type (Unit.all, Position) = Made
                    and then Landin.IR.Template_Of (Unit.all, Made)
                      = Landin.Checking.Template_Of (Types.all, Source),
                  "IR nominal mapping follows checker interning order");
            end;
         end loop;
         Landin.Testing.Check
           (Item, Landin.IR.Item_Count (Unit.all) = 0,
            "mapping nominal type metadata creates no runtime item");
      end;

      declare
         procedure Check_Target
           (Facts : Landin.Targets.Target_Facts;
            Position : out Positive;
            Size : out Natural);

         procedure Check_Target
           (Facts : Landin.Targets.Target_Facts;
            Position : out Positive;
            Size : out Natural)
         is
            Target_Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Facts);
            Target_Order : Landin.Stages.Pipeline;
            Target_Src : Landin.Source.Source_Id;
            pragma Unreferenced (Target_Src);
            Target_Ran : Natural;
         begin
            Target_Src := Landin.Stages.Add_Source
              (Target_Work, "target-key.ldn",
               "machine: type = struct" & LF
               & "    value: usize" & LF
               & "end machine" & LF);
            Landin.Stages.Append (Target_Order, Frontend'Access);
            Landin.Stages.Append (Target_Order, Configurer'Access);
            Landin.Stages.Append (Target_Order, Names'Access);
            Landin.Stages.Append (Target_Order, Checker'Access);
            Target_Ran := Landin.Stages.Run (Target_Order, Target_Work);
            Landin.Testing.Check_Equal
              (Item, Target_Ran, 4, "the target checker ran");
            Landin.Testing.Check
              (Item, not Landin.Stages.Failed (Target_Work),
               "the target comparison template is accepted");

            declare
               Target_Types : constant not null access Landin.Checking.Table :=
                 Landin.Stages.Types (Target_Work);
               Machine : constant Landin.Checking.Nominal_Type_Id :=
                 Landin.Checking.Nth_Nominal_Type (Target_Types.all, 1);
               Made : constant Landin.Checking.Nominal_Type_Id :=
                 Landin.Checking.Intern_Nominal_Instance
                   (Target_Types.all,
                    Landin.Checking.Template_Of (Target_Types.all, Machine),
                    Two
                      (Landin.Checking.Scalar_Type_Actual
                         (Landin.Types.Usize),
                       Landin.Checking.Fixed_Actual (255)));
            begin
               Position := Landin.Checking.Nominal_Identities.Position
                 (Target_Types.all, Made);
               Size := Natural
                 (Landin.Checking.Layout_Size (Target_Types.all, Machine));
            end;
         end Check_Target;

         Position_64, Position_32 : Positive;
         Size_64, Size_32 : Natural;
      begin
         Check_Target
           (Landin.Targets.Linux_X86_64, Position_64, Size_64);
         Check_Target
           (Landin.Targets.Synthetic_32, Position_32, Size_32);
         Landin.Testing.Check
           (Item,
            Position_64 = Position_32
              and then Size_64 = 8 and then Size_32 = 4,
            "target-dependent layout cannot enter a nominal actual key");
      end;
   end Nominal_Instances_Intern_Normalized_Actuals;

   procedure Routine_Instance_Views_Keep_Source_Facts_Separate
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "identity: (t: type, value: t) -> (result: t) =" & LF
        & "    local: t = value" & LF
        & "    result = identity(local)" & LF
        & "end identity" & LF;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Src : Landin.Source.Source_Id;
      Ran : Natural;
   begin
      Src := Landin.Stages.Add_Source (Work, "routine-views.ldn", Source_Text);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check_Equal
        (Item, Ran, 3, "syntax, configuration and resolution ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the generic source resolves");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         Unit : constant not null access Landin.IR.Unit :=
           Landin.Stages.Code (Work);
         Template, Parameter, Returned, Local :
           Landin.Provenance.Declaration_Id :=
             Landin.Provenance.No_Declaration;
         Call : Landin.Syntax.Node_Id := Landin.Syntax.No_Node;
         Previous : Landin.Checking.Routine_Instance_Id;
      begin
         Landin.Checking.Prepare
           (Types.all, Landin.Stages.Trees (Work).all, Meanings.all,
            Landin.Stages.Identities (Work).all);
         Landin.IR.Prepare (Unit.all, Meanings.all);
         for Id in Landin.Provenance.Declaration_Id'(1)
                   .. Landin.Provenance.Declaration_Id
                        (Landin.Resolution.Declaration_Count (Meanings.all))
         loop
            case Landin.Resolution.Sort_Of (Meanings.all, Id) is
               when Landin.Resolution.Module_Function => Template := Id;
               when Landin.Resolution.Parameter => Parameter := Id;
               when Landin.Resolution.Named_Return => Returned := Id;
               when Landin.Resolution.Local_Binding => Local := Id;
               when others => null;
            end case;
         end loop;
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node) = Landin.Syntax.Call then
               Call := Node;
            end if;
         end loop;

         declare
            U8_Actuals : Landin.Checking.Actual_Tuple :=
              Landin.Checking.Empty_Actuals;
            I32_Actuals : Landin.Checking.Actual_Tuple :=
              Landin.Checking.Empty_Actuals;
         begin
            Landin.Checking.Append_Actual
              (U8_Actuals,
               Landin.Checking.Scalar_Type_Actual (Landin.Types.U8));
            Landin.Checking.Append_Actual
              (I32_Actuals,
               Landin.Checking.Scalar_Type_Actual (Landin.Types.I32));
            declare
               Small : constant Landin.Checking.Routine_Instance_Id :=
                 Landin.Checking.Intern_Routine_Instance
                   (Types.all, Template, U8_Actuals);
               Small_Again : constant Landin.Checking.Routine_Instance_Id :=
                 Landin.Checking.Intern_Routine_Instance
                   (Types.all, Template, U8_Actuals);
               Wide : constant Landin.Checking.Routine_Instance_Id :=
                 Landin.Checking.Intern_Routine_Instance
                   (Types.all, Template, I32_Actuals);
               Site : constant Landin.Provenance.Origin :=
                 Landin.Syntax.Origin
                   (Of_Tree.all,
                    Landin.Resolution.Node_Of (Meanings.all, Template));
               Small_Signature : constant Landin.Checking.Signature_Id :=
                 Landin.Checking.Add_Signature
                   (Types.all,
                    Landin.Checking.Signature_Part_Array'
                      [1 => (Kind => Landin.Types.U8, Site => Site,
                             others => <>)],
                    Landin.Checking.Signature_Part'
                      (Kind => Landin.Types.U8, Site => Site, others => <>),
                    Site);
               Wide_Signature : constant Landin.Checking.Signature_Id :=
                 Landin.Checking.Add_Signature
                   (Types.all,
                    Landin.Checking.Signature_Part_Array'
                      [1 => (Kind => Landin.Types.I32, Site => Site,
                             others => <>)],
                    Landin.Checking.Signature_Part'
                      (Kind => Landin.Types.I32, Site => Site, others => <>),
                    Site);
            begin
               Landin.Testing.Check
                 (Item, Small = Small_Again and then Small /= Wide,
                  "equal routine keys reuse and unequal keys stay distinct");

               Landin.Checking.Begin_Routine_Instance (Types.all, Small);
               Landin.Checking.Publish_Routine_Signature
                 (Types.all, Small, Small_Signature);
               Landin.Checking.Activate_Routine_View
                 (Types.all, Small, Previous);
               Landin.Checking.Settle
                 (Types.all, Parameter, Landin.Types.U8);
               Landin.Checking.Settle
                 (Types.all, Returned, Landin.Types.U8);
               Landin.Checking.Settle (Types.all, Local, Landin.Types.U8);
               Landin.Checking.Note
                 (Types.all, Of_Tree.all, Call, Landin.Types.U8);
               Landin.Checking.Note_Routine_Target
                 (Types.all, Of_Tree.all, Call, Small);
               Landin.Checking.Restore_Routine_View (Types.all, Previous);
               Landin.Checking.Finish_Routine_Instance (Types.all, Small);

               Landin.Checking.Begin_Routine_Instance (Types.all, Wide);
               Landin.Checking.Publish_Routine_Signature
                 (Types.all, Wide, Wide_Signature);
               Landin.Checking.Activate_Routine_View
                 (Types.all, Wide, Previous);
               Landin.Checking.Settle
                 (Types.all, Parameter, Landin.Types.I32);
               Landin.Checking.Settle
                 (Types.all, Returned, Landin.Types.I32);
               Landin.Checking.Settle (Types.all, Local, Landin.Types.I32);
               Landin.Checking.Note
                 (Types.all, Of_Tree.all, Call, Landin.Types.I32);
               Landin.Checking.Note_Routine_Target
                 (Types.all, Of_Tree.all, Call, Wide);
               Landin.Checking.Restore_Routine_View (Types.all, Previous);
               Landin.Checking.Finish_Routine_Instance (Types.all, Wide);

               Landin.Testing.Check
                 (Item,
                  Landin.Checking.State_Of (Types.all, Local)
                    = Landin.Checking.Untouched
                    and then Landin.Checking.Type_Of
                      (Types.all, Of_Tree.all, Call)
                        = Landin.Types.Undecided
                    and then Landin.Checking.Routine_Target_Of
                      (Types.all, Of_Tree.all, Call)
                        = Landin.Checking.No_Routine_Instance,
                  "the global fact layer remains untouched");

               Landin.Checking.Activate_Routine_View
                 (Types.all, Small, Previous);
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Local)
                    = Landin.Types.U8
                    and then Landin.Checking.Type_Of (Types.all, Returned)
                      = Landin.Types.U8
                    and then Landin.Checking.Type_Of
                      (Types.all, Of_Tree.all, Call) = Landin.Types.U8
                    and then Landin.Checking.Routine_Target_Of
                      (Types.all, Of_Tree.all, Call) = Small,
                  "the u8 view retains local, return, and call facts");
               Landin.Checking.Restore_Routine_View (Types.all, Previous);

               Landin.Checking.Activate_Routine_View
                 (Types.all, Wide, Previous);
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Local)
                    = Landin.Types.I32
                    and then Landin.Checking.Type_Of (Types.all, Returned)
                      = Landin.Types.I32
                    and then Landin.Checking.Type_Of
                      (Types.all, Of_Tree.all, Call) = Landin.Types.I32
                    and then Landin.Checking.Routine_Target_Of
                      (Types.all, Of_Tree.all, Call) = Wide,
                  "the i32 view retains distinct facts on the same source");
               Landin.Checking.Restore_Routine_View (Types.all, Previous);

               declare
                  Small_Item : constant Landin.IR.Item_Id :=
                    Landin.IR.Add_Routine_Instance_Item
                      (Unit.all,
                       Landin.Checking.Routine_Identities.Position
                         (Types.all, Small),
                       Template, Landin.Types.U8, Site);
                  Wide_Item : constant Landin.IR.Item_Id :=
                    Landin.IR.Add_Routine_Instance_Item
                      (Unit.all,
                       Landin.Checking.Routine_Identities.Position
                         (Types.all, Wide),
                       Template, Landin.Types.I32, Site);
               begin
                  Landin.Testing.Check
                    (Item,
                     Small_Item /= Wide_Item
                       and then Landin.IR.Item_For_Instance
                         (Unit.all,
                          Landin.Checking.Routine_Identities.Position
                            (Types.all, Small_Again)) = Small_Item
                       and then Landin.IR.Item_For_Instance
                         (Unit.all,
                          Landin.Checking.Routine_Identities.Position
                            (Types.all, Wide)) = Wide_Item
                       and then Landin.IR.Declares (Unit.all, Small_Item)
                         = Landin.IR.No_Declaration
                       and then Landin.IR.Generic_Template_Of
                         (Unit.all, Small_Item) = Template
                       and then Landin.IR.Generic_Template_Of
                         (Unit.all, Wide_Item) = Template,
                     "routine keys map to reused or distinct local IR items");
               end;
            end;
         end;
      end;
   end Routine_Instance_Views_Keep_Source_Facts_Separate;

   procedure Union_Aliases_Keep_Exact_Instance_Keys
     (Item : in out Landin.Testing.Context);

   procedure Union_Aliases_Keep_Exact_Instance_Keys
     (Item : in out Landin.Testing.Context)
   is
      Text : constant String :=
        "first, second, third: atom" & LF
        & "joined: type (left: type, right: type) = left | right" & LF
        & "a: type = joined(first, second)" & LF
        & "b: type = joined(second, first)" & LF
        & "c: type = joined(a, first)" & LF
        & "d: type = joined(first, third)" & LF
        & "observe: (t: type, value: t) -> none = _ = value end observe" & LF
        & "main: () -> none =" & LF
        & "  one: a = first" & LF
        & "  two: b = second" & LF
        & "  three: c = first" & LF
        & "  four: d = third" & LF
        & "  observe(one)" & LF
        & "  observe(two)" & LF
        & "  observe(three)" & LF
        & "  observe(four)" & LF
        & "end main" & LF;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Src : Landin.Source.Source_Id;
      Ran : Natural;
   begin
      Src := Landin.Stages.Add_Source (Work, "union-alias-keys.ldn", Text);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "union aliases are accepted");
      declare
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Targets : array (1 .. 4) of Landin.Checking.Routine_Instance_Id :=
           [others => Landin.Checking.No_Routine_Instance];
         Calls : Natural := 0;
      begin
         for Node in Landin.Syntax.Node_Id'(1)
           .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node) = Landin.Syntax.Call then
               Calls := Calls + 1;
               if Calls <= Targets'Last then
                  Targets (Calls) := Landin.Checking.Routine_Target_Of
                    (Types.all, Of_Tree.all, Node);
               end if;
            elsif Landin.Syntax.Kind (Of_Tree.all, Node)
              = Landin.Syntax.Atom_Union_Type
            then
               Landin.Testing.Check
                 (Item, Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Undecided,
                  "the template never receives one instance's atom set");
            end if;
         end loop;
         Landin.Testing.Check_Equal
           (Item, Calls, 4, "four calls were checked");
         Landin.Testing.Check
           (Item, Targets (1) /= Landin.Checking.No_Routine_Instance
              and then Targets (1) = Targets (2)
              and then Targets (1) = Targets (3)
              and then Targets (4) /= Landin.Checking.No_Routine_Instance
              and then Targets (1) /= Targets (4),
            "order and duplicates reuse a key; a different atom changes it");
         Landin.Testing.Check_Equal
           (Item, Landin.Checking.Routine_Instance_Count (Types.all), 2,
            "only the two complete structural sets create instances");
      end;
   end Union_Aliases_Keep_Exact_Instance_Keys;

   --  A concrete generic array result may be copied from a slice element.
   --  The element's type is supplied by the instance, but the member that
   --  reaches that slice remains an ordinary declaration-order field.
   procedure Generic_Array_Selections_Keep_Field_Metadata
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "box: type (item: type) = struct" & LF
        & "    prefix: []mut item" & LF
        & "end box" & LF
        & "copy: (item: type, source: box(item), index: usize," & LF
        & "       inout target: box(item)) -> (written: usize) =" & LF
        & "    value: item = source.prefix[index]" & LF
        & "    target.prefix[index] = value" & LF
        & "    written = index" & LF
        & "end copy" & LF
        & "empty: type = [0]u8" & LF
        & "main: () -> none =" & LF
        & "    mut backing: [1]empty = zeroed" & LF
        & "    view: []mut empty = backing[0..<1]" & LF
        & "    source: box(empty) = (prefix: view)" & LF
        & "    mut target: box(empty) = (prefix: view)" & LF
        & "    zero: usize = 0" & LF
        & "    written: usize = copy(source, zero, target)" & LF
        & "end main" & LF;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Src : Landin.Source.Source_Id;
      Ran : Natural;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "generic-array-selection.ldn", Source_Text);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "the generic array-valued slice selection is accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         Instance : constant Landin.Checking.Routine_Instance_Id :=
           Landin.Checking.Routine_Identities.Nth (Types.all, 1);
         Previous : Landin.Checking.Routine_Instance_Id;
         Seen : Natural := 0;
         Elements : Natural := 0;
      begin
         Landin.Testing.Check_Equal
           (Item, Landin.Checking.Routine_Instance_Count (Types.all), 1,
            "the call selects one concrete generic routine");
         Landin.Checking.Activate_Routine_View
           (Types.all, Instance, Previous);
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Member_Selection
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Slice_Value,
                  "the concrete selected field keeps its slice type");
               Landin.Testing.Check_Equal
                 (Item,
                  Landin.Checking.Field_Index
                    (Types.all, Of_Tree.all, Node),
                  1, "the concrete selected field keeps its field index");
            elsif Landin.Syntax.Kind (Of_Tree.all, Node)
                    = Landin.Syntax.Element_Index
              and then Landin.Syntax.Kind
                (Of_Tree.all,
                 Landin.Syntax.Target_Of (Of_Tree.all, Node))
                   = Landin.Syntax.Member_Selection
            then
               Elements := Elements + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array,
                  "the concrete selected element keeps its array type");
            end if;
         end loop;
         Landin.Checking.Restore_Routine_View (Types.all, Previous);
         Landin.Testing.Check_Equal
           (Item, Seen, 2, "the generic body has two selected fields");
         Landin.Testing.Check_Equal
           (Item, Elements, 2, "the generic body has two array elements");
      end;
   end Generic_Array_Selections_Keep_Field_Metadata;

   procedure Failed_Generic_Deduction_Has_No_Target
     (Item : in out Landin.Testing.Context)
   is
      Text : constant String :=
        "box: type (t: type, fixed n: u32) = struct" & LF
        & "    marker: bool" & LF
        & "end box" & LF
        & "first: (fixed n: u32, t: type," & LF
        & "        left: box([n]t, n), right: box([n]t, n)) -> none =" & LF
        & "end first" & LF
        & "use: () -> none =" & LF
        & "    left: box([2]i32, 2) = (marker: true)" & LF
        & "    right: box([3]i32, 3) = (marker: false)" & LF
        & "    first(left, right)" & LF
        & "end use" & LF;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source (Work, "fixed-conflict.ldn", Text);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check_Equal
        (Item, Landin.Diagnostics.Count (Landin.Stages.Report (Work)), 1,
         "one nested deduction conflict is reported for the call");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         Call : Landin.Syntax.Node_Id := Landin.Syntax.No_Node;
      begin
         for Node in Landin.Syntax.Node_Id'(1)
           .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node) = Landin.Syntax.Call then
               Call := Node;
               exit;
            end if;
         end loop;
         Landin.Testing.Check
           (Item, Call /= Landin.Syntax.No_Node, "the call was found");
         Landin.Testing.Check
           (Item,
            Landin.Checking.Type_Of (Types.all, Of_Tree.all, Call)
              = Landin.Types.Ill_Typed
              and then Landin.Checking.Routine_Target_Of
                (Types.all, Of_Tree.all, Call)
                  = Landin.Checking.No_Routine_Instance
              and then Landin.Checking.Routine_Instance_Count (Types.all) = 0,
            "a refused nested deduction has neither a target nor an instance");
      end;
   end Failed_Generic_Deduction_Has_No_Target;

   procedure Structural_Deduction_Interns_Complete_Tuple
     (Item : in out Landin.Testing.Context)
   is
      Text : constant String :=
        "box: type (t: type, fixed n: u32) = struct" & LF
        & "    marker: bool" & LF
        & "end box" & LF
        & "copy: (t: type, fixed n: u32, value: box([n]t, n)) -> none ="
        & LF & "end copy" & LF
        & "value: box([3]i32, 3) = (marker: true)" & LF
        & "use: () -> none = copy(value) end use" & LF;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
      pragma Unreferenced (Src);
   begin
      Src := Landin.Stages.Add_Source (Work, "structural.ldn", Text);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "the nested structural pattern is accepted");
      declare
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         Instance : constant Landin.Checking.Routine_Instance_Id :=
           Landin.Checking.Routine_Identities.Nth (Types.all, 1);
         Type_Actual : constant Landin.Checking.Actual_Key :=
           Landin.Checking.Nth_Routine_Actual (Types.all, Instance, 1);
         Fixed_Actual : constant Landin.Checking.Actual_Key :=
           Landin.Checking.Nth_Routine_Actual (Types.all, Instance, 2);
      begin
         Landin.Testing.Check
           (Item,
            Landin.Checking.Routine_Instance_Count (Types.all) = 1
              and then Landin.Checking.Routine_State_Of (Types.all, Instance)
                = Landin.Checking.Routine_Ready
              and then Landin.Checking.Type_Form_Of (Type_Actual)
                = Landin.Checking.Scalar_Actual_Type
              and then Landin.Checking.Scalar_Of (Types.all, Type_Actual)
                = Landin.Types.I32
              and then Landin.Checking.Fixed_Magnitude_Of (Fixed_Actual) = 3,
            "nested array and phantom tuple relations intern i32 and three");
      end;
   end Structural_Deduction_Interns_Complete_Tuple;

   procedure Reference_Actuals_Keep_Complete_Identity
     (Item : in out Landin.Testing.Context)
   is
      Text : constant String :=
        "box: type (t: type) = struct" & LF
        & "    marker: bool" & LF
        & "end box" & LF
        & "node: type = struct" & LF
        & "    value: i32" & LF
        & "end node" & LF
        & "other: type = struct" & LF
        & "    value: i32" & LF
        & "end other" & LF
        & "alias: type = node" & LF
        & "first: type = concept (t: type)" & LF
        & "    value: (self: ptr t) -> (n: i32)" & LF
        & "end first" & LF
        & "second: type = concept (t: type)" & LF
        & "    value: (self: ptr t) -> (n: i32)" & LF
        & "end second" & LF
        & "observe: (t: type, source: box(t)) -> none =" & LF
        & "end observe" & LF
        & "use: () -> none =" & LF
        & "    a: box(ptr node) = (marker: true)" & LF
        & "    b: box(ptr mut node) = (marker: true)" & LF
        & "    c: box(ptr other) = (marker: true)" & LF
        & "    d: box(any first) = (marker: true)" & LF
        & "    e: box(any second) = (marker: true)" & LF
        & "    f: box([]node) = (marker: true)" & LF
        & "    g: box([]mut node) = (marker: true)" & LF
        & "    h: box(ptr alias) = (marker: true)" & LF
        & "    observe(a)" & LF
        & "    observe(b)" & LF
        & "    observe(c)" & LF
        & "    observe(d)" & LF
        & "    observe(e)" & LF
        & "    observe(f)" & LF
        & "    observe(g)" & LF
        & "    observe(h)" & LF
        & "end use" & LF;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
      pragma Unreferenced (Src);
   begin
      Src := Landin.Stages.Add_Source (Work, "reference-keys.ldn", Text);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "reference and any actuals deduce through nominal instances");
      Landin.Testing.Check_Equal
        (Item, Landin.Checking.Routine_Instance_Count
           (Landin.Stages.Types (Work).all), 7,
         "permission, referent and concept split keys; an alias reuses one");
   end Reference_Actuals_Keep_Complete_Identity;

   procedure R470_Field_Ranges_Keep_Recursive_Children
     (Item : in out Landin.Testing.Context);

   procedure R470_Field_Ranges_Keep_Recursive_Children
     (Item : in out Landin.Testing.Context)
   is
      package C renames Landin.Checking;

      Text : constant String :=
        "node: type = struct value: i32 end node" & LF
        & "holder: type = struct" & LF
        & "    deep: [2][3][4]i32" & LF
        & "    empty: [2][0][3]i32" & LF
        & "    refs: [2][3][]mut i32" & LF
        & "    nominal: [2][3]node" & LF
        & "end holder" & LF
        & "inspect: (inout value: holder) -> none =" & LF
        & "    deep := value.deep[0..<2]" & LF
        & "    empty := value.empty[0..<2]" & LF
        & "    refs := value.refs[0..<2]" & LF
        & "    nominal := value.nominal[0..<2]" & LF
        & "    _ = lenof deep + lenof empty + lenof refs + lenof nominal" & LF
        & "end inspect" & LF
        & "inspect_readonly: (value: holder) -> none =" & LF
        & "    deep := value.deep[0..<2]" & LF
        & "    _ = lenof deep" & LF
        & "end inspect_readonly" & LF;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source (Work, "r470-field-ranges.ldn", Text);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "nested field ranges are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access C.Table :=
           Landin.Stages.Types (Work);
         Seen, Deep, Empty, References, Nominals : Natural := 0;
         Mutable_Deep, Readonly_Deep : Natural := 0;
      begin
         for Where in Landin.Syntax.Node_Id'(1)
                    .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Where)
                 = Landin.Syntax.Half_Open_Slice
            then
               Seen := Seen + 1;
               declare
                  Ref : constant C.Reference_Descriptor := C.Descriptor_Of
                    (Types.all,
                     C.Reference_Of (Types.all, Of_Tree.all, Where));
               begin
                  Landin.Testing.Check
                    (Item, Ref.Kind = Landin.Types.Slice_Value
                     and then Ref.Referent = Landin.Types.Fixed_Array,
                     "a field range keeps a fixed-array referent");
                  if Ref.Length = 3
                    and then Ref.Element_Shape.Kind = C.Fixed_Array_Field
                  then
                     declare
                        Child : constant C.Field_Shape :=
                          C.Array_Field_Element (Types.all, Ref.Element_Shape);
                     begin
                        if Ref.Element_Shape.Length = 4 then
                           Deep := Deep + 1;
                           if Ref.Mutable then
                              Mutable_Deep := Mutable_Deep + 1;
                           else
                              Readonly_Deep := Readonly_Deep + 1;
                           end if;
                           Landin.Testing.Check
                             (Item, Child.Kind = C.Scalar_Field
                              and then Child.Element = Landin.Types.I32,
                              "the deepest scalar child remains i32");
                        end if;
                     end;
                  elsif Ref.Length = 0
                    and then Ref.Element_Shape.Kind = C.Fixed_Array_Field
                  then
                     Empty := Empty + 1;
                     declare
                        Child : constant C.Field_Shape :=
                          C.Array_Field_Element (Types.all, Ref.Element_Shape);
                     begin
                        Landin.Testing.Check
                          (Item, Ref.Element_Shape.Length = 3
                           and then Child.Kind = C.Scalar_Field
                           and then Child.Element = Landin.Types.I32,
                           "a zero child extent keeps its nonempty"
                           & " grandchild");
                     end;
                  elsif Ref.Length = 3
                    and then Ref.Element_Shape.Kind = C.Reference_Field
                  then
                     References := References + 1;
                     declare
                        Child : constant C.Reference_Descriptor :=
                          C.Descriptor_Of
                            (Types.all, Ref.Element_Shape.Reference);
                     begin
                        Landin.Testing.Check
                          (Item, Child.Kind = Landin.Types.Slice_Value
                           and then Child.Mutable
                           and then Child.Referent = Landin.Types.I32,
                           "a nested mutable reference child remains"
                           & " complete");
                     end;
                  elsif Ref.Length = 3
                    and then Ref.Element_Nominal /= C.No_Nominal_Type
                  then
                     Nominals := Nominals + 1;
                     Landin.Testing.Check
                       (Item, C.Holds (Types.all, Ref.Element_Nominal),
                        "a nested nominal child remains registered");
                  end if;
               end;
            end if;
         end loop;
         Landin.Testing.Check
           (Item, Seen = 5 and then Deep = 2 and then Empty = 1
            and then References = 1 and then Nominals = 1
            and then Mutable_Deep = 1 and then Readonly_Deep = 1,
            "all mutable and readonly recursive range descriptors survived");
      end;
   end R470_Field_Ranges_Keep_Recursive_Children;

   procedure Array_Actuals_Keep_Complete_Identity
     (Item : in out Landin.Testing.Context);

   procedure Array_Actuals_Keep_Complete_Identity
     (Item : in out Landin.Testing.Context)
   is
      Text : constant String :=
        "box: type (t: type) = struct" & LF
        & "    marker: bool" & LF
        & "end box" & LF
        & "node: type = struct" & LF
        & "    value: i32" & LF
        & "end node" & LF
        & "other: type = struct" & LF
        & "    value: i32" & LF
        & "end other" & LF
        & "alias: type = node" & LF
        & "first: type = concept (t: type)" & LF
        & "    value: (self: ptr t) -> (n: i32)" & LF
        & "end first" & LF
        & "second: type = concept (t: type)" & LF
        & "    value: (self: ptr t) -> (n: i32)" & LF
        & "end second" & LF
        & "observe: (t: type, source: box(t)) -> none =" & LF
        & "end observe" & LF
        & "use: () -> none =" & LF
        & "    a: box([1]ptr node) = (marker: true)" & LF
        & "    b: box([1]ptr mut node) = (marker: true)" & LF
        & "    c: box([1]ptr other) = (marker: true)" & LF
        & "    d: box([1]any first) = (marker: true)" & LF
        & "    e: box([1]any second) = (marker: true)" & LF
        & "    f: box([3][]node) = (marker: true)" & LF
        & "    g: box([3][]mut node) = (marker: true)" & LF
        & "    h: box([1]ptr alias) = (marker: true)" & LF
        & "    i: box([3]ptr node) = (marker: true)" & LF
        & "    j: box([0]any first) = (marker: true)" & LF
        & "    observe(i)" & LF
        & "    observe(j)" & LF
        & "    observe(a)" & LF
        & "    observe(b)" & LF
        & "    observe(c)" & LF
        & "    observe(d)" & LF
        & "    observe(e)" & LF
        & "    observe(f)" & LF
        & "    observe(g)" & LF
        & "    observe(h)" & LF
        & "end use" & LF;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
      pragma Unreferenced (Src);
   begin
      Src := Landin.Stages.Add_Source (Work, "array-keys.ldn", Text);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "array reference and any actuals deduce through nominal instances");
      Landin.Testing.Check_Equal
        (Item, Landin.Checking.Routine_Instance_Count
           (Landin.Stages.Types (Work).all), 9,
         "extent, permission, referent and concept split array keys");
   end Array_Actuals_Keep_Complete_Identity;

   procedure Generic_Signatures_Keep_Nominal_Array_Elements
     (Item : in out Landin.Testing.Context)
   is
      Text : constant String :=
        "box: type (item: type) = struct" & LF
        & "    value: item" & LF
        & "end box" & LF
        & "empty: type (item: type) = [0]item" & LF
        & "copy: (item: type, value: empty(item))"
        & " -> (result: empty(item)) = value end copy" & LF
        & "copy_boxes: (value: empty(box(i32)))"
        & " -> (result: empty(box(i32))) = value end copy_boxes" & LF
        & "through: (item: type," & LF
        & "          action: (value: empty(item))"
        & " -> (result: empty(item))," & LF
        & "          value: empty(item)) -> (result: empty(item)) ="
        & LF & "    result = action(value)" & LF
        & "end through" & LF
        & "values: empty(box(i32))" & LF
        & "use: () -> none =" & LF
        & "    copied: empty(box(i32)) = copy(values)" & LF
        & "    nested: empty(box(i32)) = through(copy_boxes, copied)"
        & LF & "end use" & LF;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
      pragma Unreferenced (Src);
   begin
      Src := Landin.Stages.Add_Source (Work, "nominal-array.ldn", Text);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "zero-length nominal arrays are accepted in generic signatures");
      declare
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         Array_Count : Natural := 0;
         Parts_Agree : Boolean := True;
         First_Nominal : Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.No_Nominal_Type;
         First_Array : Landin.Checking.Signature_Part;
         First_Signature : Landin.Checking.Signature_Id :=
           Landin.Checking.No_Signature;

         procedure Visit (Signature : Landin.Checking.Signature_Id);

         procedure Check_Part
           (Part : Landin.Checking.Signature_Part;
            Signature : Landin.Checking.Signature_Id);

         procedure Check_Part
           (Part : Landin.Checking.Signature_Part;
            Signature : Landin.Checking.Signature_Id) is
         begin
            if Part.Kind = Landin.Types.Fixed_Array then
               Array_Count := Array_Count + 1;
               Parts_Agree := Parts_Agree
                 and then Part.Length = 0
                 and then Part.Nominal
                   /= Landin.Checking.No_Nominal_Type
                 and then Landin.Checking.Holds (Types.all, Part);
               if First_Nominal = Landin.Checking.No_Nominal_Type then
                  First_Nominal := Part.Nominal;
                  First_Array := Part;
                  First_Signature := Signature;
               else
                  Parts_Agree := Parts_Agree
                    and then Part.Nominal = First_Nominal;
               end if;
            elsif Part.Kind = Landin.Types.Function_Value then
               Visit (Part.Signature);
            end if;
         end Check_Part;

         procedure Visit (Signature : Landin.Checking.Signature_Id) is
         begin
            for Index in 1 .. Landin.Checking.Signature_Parameter_Count
              (Types.all, Signature)
            loop
               Check_Part
                 (Landin.Checking.Nth_Signature_Parameter
                    (Types.all, Signature, Index),
                  Signature);
            end loop;
            for Index in 1 .. Landin.Checking.Signature_Result_Count
              (Types.all, Signature)
            loop
               Check_Part
                 (Landin.Checking.Nth_Signature_Result
                    (Types.all, Signature, Index),
                  Signature);
            end loop;
         end Visit;
      begin
         for Position in 1 .. Landin.Checking.Routine_Instance_Count
           (Types.all)
         loop
            declare
               Instance : constant Landin.Checking.Routine_Instance_Id :=
                 Landin.Checking.Routine_Identities.Nth
                   (Types.all, Position);
            begin
               Visit
                 (Landin.Checking.Routine_Signature_Of
                    (Types.all, Instance));
            end;
         end loop;

         Landin.Testing.Check
           (Item, Array_Count = 6 and then Parts_Agree,
            "aliases and nested signatures retain six zero-length nominal"
            & " array parts");
         declare
            Malformed : Landin.Checking.Signature_Part := First_Array;
         begin
            Malformed.Signature := First_Signature;
            Landin.Testing.Check
              (Item,
               not Landin.Checking.Holds (Types.all, Malformed)
                 and then not Landin.Checking.Holds
                   (Types.all,
                    Landin.Checking.Signature_Part'
                      (Kind => Landin.Types.Aggregate,
                       Site => First_Array.Site,
                       others => <>)),
               "the public signature seam rejects stray and missing"
               & " descriptor identities");
         end;
      end;
   end Generic_Signatures_Keep_Nominal_Array_Elements;

   procedure Discovery_Skips_Refused_Generic_Calls
     (Item : in out Landin.Testing.Context)
   is
      Text : constant String :=
        "identity: (t: type, value: t) -> (result: t) = value"
        & " end identity" & LF
        & "one: (t: type, value: t) -> (result: t) = value end one" & LF
        & "result := one(identity(42), 0)" & LF;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "inferred-module-conflict.ldn", Text);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check_Equal
        (Item, Landin.Diagnostics.Count (Landin.Stages.Report (Work)), 1,
         "discovery does not repeat the inference diagnostic");
      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         Outer, Nested : Landin.Syntax.Node_Id := Landin.Syntax.No_Node;
      begin
         for Node in Landin.Syntax.Node_Id'(1)
           .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node) = Landin.Syntax.Call then
               if Landin.Syntax.Argument_Count (Of_Tree.all, Node) = 2 then
                  Outer := Node;
               else
                  Nested := Node;
               end if;
            end if;
         end loop;
         Landin.Testing.Check
           (Item,
            Outer /= Landin.Syntax.No_Node
              and then Nested /= Landin.Syntax.No_Node
              and then Landin.Checking.Type_Of
                (Types.all, Of_Tree.all, Outer) = Landin.Types.Ill_Typed
              and then Landin.Checking.Routine_Target_Of
                (Types.all, Of_Tree.all, Outer)
                  = Landin.Checking.No_Routine_Instance
              and then Landin.Checking.Routine_Target_Of
                (Types.all, Of_Tree.all, Nested)
                  /= Landin.Checking.No_Routine_Instance
              and then Landin.Checking.Routine_Instance_Count (Types.all) = 1,
            "the refused outer call stays targetless while discovery reaches"
            & " its nested call");
      end;
   end Discovery_Skips_Refused_Generic_Calls;

   procedure Recovery_Deduction_Interns_Final_Sets
     (Item : in out Landin.Testing.Context)
   is
      Text : constant String :=
        "problem, denied: atom" & LF
        & "leaf: () -> none ! ... = fail problem end leaf" & LF
        & "other: () -> none ! ... = fail denied end other" & LF
        & "observe: (t: type, value: t) -> none = _ = value end observe" & LF
        & "use: () -> none =" & LF
        & "    leaf() else (error) observe(error) end" & LF
        & "    leaf() else (error)" & LF
        & "        alias := error" & LF
        & "        observe(alias)" & LF
        & "    end" & LF
        & "    other() else (error) observe(error) end" & LF
        & "end use" & LF;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source (Work, "recovery-deduction.ldn", Text);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");
      declare
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Sets : array (1 .. 2) of Landin.Checking.Atom_Set_Id :=
           [others => Landin.Checking.No_Atom_Set];
         Targets : Natural := 0;
      begin
         Landin.Testing.Check_Equal
           (Item, Landin.Checking.Routine_Instance_Count (Types.all), 2,
            "equal final sets share an instance and unequal sets do not");
         for Position in 1 .. Landin.Checking.Routine_Instance_Count
           (Types.all)
         loop
            declare
               Instance : constant Landin.Checking.Routine_Instance_Id :=
                 Landin.Checking.Routine_Identities.Nth (Types.all, Position);
               Signature : constant Landin.Checking.Signature_Id :=
                 Landin.Checking.Routine_Signature_Of (Types.all, Instance);
               Part : constant Landin.Checking.Signature_Part :=
                 Landin.Checking.Nth_Signature_Parameter
                   (Types.all, Signature, 1);
            begin
               Landin.Testing.Check
                 (Item, Landin.Checking.Routine_State_Of (Types.all, Instance)
                    = Landin.Checking.Routine_Ready
                    and then Part.Kind = Landin.Types.Atom_Value
                    and then Landin.Checking.Atom_Count
                      (Types.all, Part.Atoms) = 1,
                  "each ready instance has one exact atom parameter");
               if Position in Sets'Range then
                  Sets (Position) := Part.Atoms;
               end if;
            end;
         end loop;
         Landin.Testing.Check
           (Item, Sets (1) /= Sets (2), "the two atoms remain distinct");
         for Node in Landin.Syntax.Node_Id'(1)
           .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node) = Landin.Syntax.Call
              and then Landin.Checking.Routine_Target_Of
                (Types.all, Of_Tree.all, Node)
                  /= Landin.Checking.No_Routine_Instance
            then
               Targets := Targets + 1;
            end if;
         end loop;
         Landin.Testing.Check_Equal
           (Item, Targets, 3, "every deferred call keeps its final target");
      end;
   end Recovery_Deduction_Interns_Final_Sets;

   procedure Generic_Instances_Carry_Declared_Errors
     (Item : in out Landin.Testing.Context)
   is
      Text : constant String :=
        "problem: atom" & LF
        & "problems: type = problem" & LF
        & "choose: (t: type, value: t, stop: bool) -> (result: t)"
        & " ! problems =" & LF
        & "    fail problem when stop" & LF
        & "    result = value" & LF
        & "end choose" & LF
        & "use: () -> (result: i32) =" & LF
        & "    result = choose(42, false) else 0" & LF
        & "end use" & LF;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "generic-errors.ldn", Text);
      pragma Unreferenced (Src);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");
      declare
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         Instance : constant Landin.Checking.Routine_Instance_Id :=
           Landin.Checking.Routine_Identities.Nth (Types.all, 1);
         Signature : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Routine_Signature_Of (Types.all, Instance);
         Errors : constant Landin.Checking.Atom_Set_Id :=
           Landin.Checking.Signature_Errors (Types.all, Signature);
      begin
         Landin.Testing.Check
           (Item,
            Landin.Checking.Routine_Instance_Count (Types.all) = 1
              and then Landin.Checking.Routine_State_Of (Types.all, Instance)
                = Landin.Checking.Routine_Ready
              and then Landin.Checking.Signature_Error_Form
                (Types.all, Signature) = Landin.Checking.Concrete
              and then Landin.Checking.Atom_Count (Types.all, Errors) = 1,
            "the public instance signature carries its concrete error set");
      end;
   end Generic_Instances_Carry_Declared_Errors;

   procedure Generic_Instances_Infer_Errors_Per_Key
     (Item : in out Landin.Testing.Context)
   is
      Text : constant String :=
        "missing, denied: atom" & LF
        & "missing_set: type = missing" & LF
        & "denied_set: type = denied" & LF
        & "miss: (stop: bool) -> none ! missing_set =" & LF
        & "    fail missing when stop" & LF
        & "end miss" & LF
        & "deny: (stop: bool) -> none ! denied_set =" & LF
        & "    fail denied when stop" & LF
        & "end deny" & LF
        & "invoke: (f: type, action: f, stop: bool) -> none ! ... =" & LF
        & "    try action(stop)" & LF
        & "end invoke" & LF
        & "use: () -> none =" & LF
        & "    invoke(miss, true) else 0" & LF
        & "    invoke(deny, true) else 0" & LF
        & "    invoke(miss, false) else 0" & LF
        & "end use" & LF;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "generic-inferred-errors.ldn", Text);
      pragma Unreferenced (Src);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");
      declare
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         First : constant Landin.Checking.Routine_Instance_Id :=
           Landin.Checking.Routine_Identities.Nth (Types.all, 1);
         Second : constant Landin.Checking.Routine_Instance_Id :=
           Landin.Checking.Routine_Identities.Nth (Types.all, 2);
         First_Signature : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Routine_Signature_Of (Types.all, First);
         Second_Signature : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Routine_Signature_Of (Types.all, Second);
         First_Errors : constant Landin.Checking.Atom_Set_Id :=
           Landin.Checking.Signature_Errors (Types.all, First_Signature);
         Second_Errors : constant Landin.Checking.Atom_Set_Id :=
           Landin.Checking.Signature_Errors (Types.all, Second_Signature);
      begin
         Landin.Testing.Check
           (Item,
            Landin.Checking.Routine_Instance_Count (Types.all) = 2
              and then First /= Second
              and then Landin.Checking.Signature_Error_Form
                (Types.all, First_Signature) = Landin.Checking.Concrete
              and then Landin.Checking.Signature_Error_Form
                (Types.all, Second_Signature) = Landin.Checking.Concrete
              and then Landin.Checking.Atom_Count
                (Types.all, First_Errors) = 1
              and then Landin.Checking.Atom_Count
                (Types.all, Second_Errors) = 1
              and then Landin.Checking.Nth_Atom
                (Types.all, First_Errors, 1)
                  /= Landin.Checking.Nth_Atom
                    (Types.all, Second_Errors, 1),
            "equal keys reuse one instance while unequal function"
            & " descriptors retain distinct finalized inferred sets");
      end;
   end Generic_Instances_Infer_Errors_Per_Key;

   procedure Declared_Structs_Follow_Target_Layout
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Target
        (Facts             : Landin.Targets.Target_Facts;
         Machine_Tag       : Natural;
         Machine_Extent    : Natural;
         Machine_Alignment : Natural;
         Machine_Size      : Natural;
         Array_Offset      : Natural;
         Array_Tail        : Natural;
         Array_Extent      : Natural;
         Array_Alignment   : Natural;
         Array_Size        : Natural;
         Outer_Size        : Natural);

      procedure Check_Target
        (Facts             : Landin.Targets.Target_Facts;
         Machine_Tag       : Natural;
         Machine_Extent    : Natural;
         Machine_Alignment : Natural;
         Machine_Size      : Natural;
         Array_Offset      : Natural;
         Array_Tail        : Natural;
         Array_Extent      : Natural;
         Array_Alignment   : Natural;
         Array_Size        : Natural;
         Outer_Size        : Natural)
      is
         Work  : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Order : Landin.Stages.Pipeline;
         Ran   : Natural;
         Src   : Landin.Source.Source_Id;
      begin
         Src := Landin.Stages.Add_Source (Work, "layout.ldn", Layout_Program);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);

         Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
         Landin.Testing.Check
           (Item, not Landin.Stages.Failed (Work),
            "the scalar-only structs are accepted");

         declare
            Of_Tree : constant not null access constant Landin.Syntax.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Landin.Stages.Trees (Work).all, Src);
            Meanings : constant not null access Landin.Resolution.Table :=
              Landin.Stages.Meanings (Work);
            Types : constant not null access Landin.Checking.Table :=
              Landin.Stages.Types (Work);

            function Declaration_At (Position : Positive)
              return Landin.Provenance.Declaration_Id;

            function Declaration_At (Position : Positive)
              return Landin.Provenance.Declaration_Id
            is
               Node : constant Landin.Syntax.Node_Id :=
                 Landin.Syntax.Nth_Declaration (Of_Tree.all, Position);
            begin
               for Id in Landin.Provenance.Declaration_Id'(1)
                         .. Landin.Provenance.Declaration_Id
                              (Landin.Resolution.Declaration_Count
                                 (Meanings.all))
               loop
                  if Landin.Resolution.Source_Of (Meanings.all, Id) = Src
                    and then Landin.Resolution.Node_Of (Meanings.all, Id)
                                 = Node
                  then
                     return Id;
                  end if;
               end loop;

               return Landin.Provenance.No_Declaration;
            end Declaration_At;

            Ahead : constant Landin.Checking.Nominal_Type_Id :=
              Landin.Checking.Nominal_Of (Types.all, Declaration_At (1));
            Span : constant Landin.Checking.Nominal_Type_Id :=
              Landin.Checking.Nominal_Of (Types.all, Declaration_At (2));
            Same : constant Landin.Checking.Nominal_Type_Id :=
              Landin.Checking.Nominal_Of (Types.all, Declaration_At (3));
            Machine : constant Landin.Checking.Nominal_Type_Id :=
              Landin.Checking.Nominal_Of (Types.all, Declaration_At (4));
            Nested : constant Landin.Checking.Nominal_Type_Id :=
              Landin.Checking.Nominal_Of (Types.all, Declaration_At (5));
            Outer : constant Landin.Checking.Nominal_Type_Id :=
              Landin.Checking.Nominal_Of (Types.all, Declaration_At (6));
         begin
            Landin.Testing.Check
              (Item, Landin.Checking.Has_Layout (Types.all, Span),
               "the ordinary struct has a layout");
            Landin.Testing.Check_Equal
              (Item, Landin.Checking.Layout_Field_Count (Types.all, Span), 3,
               "the layout has every field");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Field_Offset (Types.all, Span, 1)),
               0, "the first i32 starts at zero");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Field_Offset (Types.all, Span, 2)),
               4, "the second i32 follows the first");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Field_Offset (Types.all, Span, 3)),
               8, "the bool keeps source order and occupies one byte");
            Landin.Testing.Check_Equal
              (Item, Natural (Landin.Checking.Layout_Extent (Types.all, Span)),
               9, "the fields reach nine bytes");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Layout_Alignment (Types.all, Span)),
               4, "the widest field aligns the struct");
            Landin.Testing.Check_Equal
              (Item, Natural (Landin.Checking.Layout_Size (Types.all, Span)),
               12, "tail padding makes arrays stay aligned");

            declare
               type Alias_Array is array (Positive range <>) of
                 Landin.Checking.Nominal_Type_Id;
            begin
               for Alias of Alias_Array'[Ahead, Same] loop
                  Landin.Testing.Check
                    (Item, Landin.Checking.Has_Layout (Types.all, Alias),
                     "an aggregate alias exposes its body's layout");
                  Landin.Testing.Check_Equal
                    (Item,
                     Landin.Checking.Layout_Field_Count (Types.all, Alias),
                     3, "an alias has every field");
                  Landin.Testing.Check_Equal
                    (Item,
                     Natural
                       (Landin.Checking.Field_Offset (Types.all, Alias, 3)),
                     8, "an alias has the body's offsets");
                  Landin.Testing.Check_Equal
                    (Item,
                     Natural
                       (Landin.Checking.Layout_Extent (Types.all, Alias)),
                     9, "an alias has the body's extent");
                  Landin.Testing.Check_Equal
                    (Item,
                     Natural
                       (Landin.Checking.Layout_Alignment (Types.all, Alias)),
                     4, "an alias has the body's alignment");
                  Landin.Testing.Check_Equal
                    (Item,
                     Natural (Landin.Checking.Layout_Size (Types.all, Alias)),
                     12, "an alias has the body's size");
               end loop;
            end;

            Landin.Testing.Check
              (Item, Landin.Checking.Has_Layout (Types.all, Machine),
               "the pointer-width struct has a layout");
            Landin.Testing.Check_Equal
              (Item,
               Natural
                 (Landin.Checking.Field_Offset (Types.all, Machine, 2)),
               Machine_Tag, "usize follows the compilation target");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Layout_Extent (Types.all, Machine)),
               Machine_Extent, "its extent follows the target");
            Landin.Testing.Check_Equal
              (Item,
               Natural
                 (Landin.Checking.Layout_Alignment (Types.all, Machine)),
               Machine_Alignment, "its alignment follows the target");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Layout_Size (Types.all, Machine)),
               Machine_Size, "its size follows the target");

            Landin.Testing.Check
              (Item, Landin.Checking.Has_Layout (Types.all, Nested),
               "an array-field struct has its complete compact layout");
            Landin.Testing.Check
              (Item,
               Landin.Checking.Field_Kind_Of (Types.all, Nested, 2)
                 = Landin.Checking.Fixed_Array_Field
               and then Landin.Checking.Field_Array_Length
                          (Types.all, Nested, 2) = 2
               and then Landin.Checking.Field_Array_Element
                          (Types.all, Nested, 2) = Landin.Types.Usize,
               "the array field keeps one compact structural shape");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Field_Offset (Types.all, Nested, 2)),
               Array_Offset, "the array begins at its element alignment");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Field_Offset (Types.all, Nested, 3)),
               Array_Tail, "the following field begins after the whole array");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Layout_Extent (Types.all, Nested)),
               Array_Extent, "the array contributes its complete extent");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Layout_Alignment (Types.all, Nested)),
               Array_Alignment, "its element alignment reaches the struct");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Layout_Size (Types.all, Nested)),
               Array_Size, "the complete nested layout receives tail padding");
            Landin.Testing.Check
              (Item,
               Landin.Checking.Has_Layout (Types.all, Outer)
                 and then Landin.Checking.Field_Kind_Of
                   (Types.all, Outer, 2)
                     = Landin.Checking.Aggregate_Field
                 and then Landin.Checking.Field_Shape_Of
                   (Types.all, Outer, 2).Nominal = Nested,
               "the named child is one aggregate field with its body");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Field_Offset (Types.all, Outer, 2)),
               Array_Offset, "the child begins at its own alignment");
            Landin.Testing.Check_Equal
              (Item, Natural (Landin.Checking.Layout_Size (Types.all, Outer)),
               Outer_Size,
               "the outer size contains the child's padded size");
         end;
      end Check_Target;
   begin
      Check_Target
        (Landin.Targets.Linux_X86_64, 8, 9, 8, 16,
         8, 24, 26, 8, 32, 48);
      Check_Target
        (Landin.Targets.Synthetic_32, 4, 5, 4, 8,
         4, 12, 14, 4, 16, 24);
   end Declared_Structs_Follow_Target_Layout;

   --  D17: an array's identity is its length and its element, so two
   --  written the same way are one type and an alias keeps that identity.
   --  Its extent is the element repeated, which needs a target: `usize`
   --  is four elements of four bytes on a 32-bit description and of eight
   --  on Linux x86-64.
   procedure Array_Types_Are_Their_Length_And_Element
     (Item : in out Landin.Testing.Context);

   procedure Array_Types_Are_Their_Length_And_Element
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "row: type = [4]u8" & LF
        & "same: type = [4]u8" & LF
        & "alias: type = row" & LF
        & "words: type = [3]u32" & LF
        & "wide: type = [4]usize" & LF;

      procedure Check_Target
        (Facts      : Landin.Targets.Target_Facts;
         Wide_Size  : Natural;
         Wide_Align : Natural);

      procedure Check_Target
        (Facts      : Landin.Targets.Target_Facts;
         Wide_Size  : Natural;
         Wide_Align : Natural)
      is
         Work  : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Order : Landin.Stages.Pipeline;
         Ran   : Natural;
         Src   : Landin.Source.Source_Id;
      begin
         Src := Landin.Stages.Add_Source (Work, "arrays.ldn", Source_Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);

         Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
         Landin.Testing.Check
           (Item, not Landin.Stages.Failed (Work),
            "the array declarations are accepted");

         declare
            Of_Tree : constant not null access constant Landin.Syntax.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Landin.Stages.Trees (Work).all, Src);
            Types : constant not null access Landin.Checking.Table :=
              Landin.Stages.Types (Work);

            function Written_At (Position : Positive)
              return Landin.Syntax.Node_Id
              is (Landin.Syntax.Declared_Type
                    (Of_Tree.all,
                     Landin.Syntax.Nth_Declaration (Of_Tree.all, Position)));

            Row   : constant Landin.Syntax.Node_Id := Written_At (1);
            Same  : constant Landin.Syntax.Node_Id := Written_At (2);
            Words : constant Landin.Syntax.Node_Id := Written_At (4);
            Wide  : constant Landin.Syntax.Node_Id := Written_At (5);

            Size      : Landin.Targets.Byte_Count;
            Alignment : Landin.Targets.Byte_Alignment;
         begin
            Landin.Testing.Check_Equal
              (Item,
               Natural
                 (Landin.Checking.Array_Length (Types.all, Of_Tree.all, Row)),
               4, "the length is the bound that was written");
            Landin.Testing.Check
              (Item,
               Landin.Checking.Array_Element (Types.all, Of_Tree.all, Row)
                 = Landin.Types.U8,
               "and the element is the type that was written");

            --  D17's whole point: the same shape twice is one type.
            Landin.Testing.Check
              (Item,
               Landin.Checking.Array_Length (Types.all, Of_Tree.all, Row)
                 = Landin.Checking.Array_Length
                     (Types.all, Of_Tree.all, Same)
               and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Row)
                        = Landin.Checking.Array_Element
                            (Types.all, Of_Tree.all, Same),
               "two arrays written the same way agree");
            Landin.Testing.Check
              (Item,
               Landin.Checking.Array_Length (Types.all, Of_Tree.all, Words)
                 /= Landin.Checking.Array_Length
                      (Types.all, Of_Tree.all, Row),
               "and two written differently do not");

            Landin.Checking.Array_Extent
              (Landin.Checking.Array_Length (Types.all, Of_Tree.all, Row),
               Landin.Checking.Array_Element (Types.all, Of_Tree.all, Row),
               Facts, Size, Alignment);
            Landin.Testing.Check_Equal
              (Item, Natural (Size), 4, "four bytes end to end");
            Landin.Testing.Check_Equal
              (Item, Natural (Alignment), 1, "aligned as one of them is");

            Landin.Checking.Array_Extent
              (Landin.Checking.Array_Length (Types.all, Of_Tree.all, Words),
               Landin.Checking.Array_Element
                 (Types.all, Of_Tree.all, Words),
               Facts, Size, Alignment);
            Landin.Testing.Check_Equal
              (Item, Natural (Size), 12, "three u32 reach twelve bytes");
            Landin.Testing.Check_Equal
              (Item, Natural (Alignment), 4, "aligned as a u32 is");

            --  The declaration carries the shape too, and so does an
            --  alias of it: a later stage asks the declaration and not
            --  the node it was written at.
            declare
               function Declared (Position : Positive)
                 return Landin.Provenance.Declaration_Id;

               function Declared (Position : Positive)
                 return Landin.Provenance.Declaration_Id
               is
                  Meanings : constant not null access
                    Landin.Resolution.Table := Landin.Stages.Meanings (Work);
                  Node : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Nth_Declaration (Of_Tree.all, Position);
               begin
                  for Id in Landin.Provenance.Declaration_Id'(1)
                            .. Landin.Provenance.Declaration_Id
                                 (Landin.Resolution.Declaration_Count
                                    (Meanings.all))
                  loop
                     if Landin.Resolution.Source_Of (Meanings.all, Id) = Src
                       and then Landin.Resolution.Node_Of (Meanings.all, Id)
                                = Node
                     then
                        return Id;
                     end if;
                  end loop;

                  return Landin.Provenance.No_Declaration;
               end Declared;
            begin
               Landin.Testing.Check_Equal
                 (Item,
                  Natural
                    (Landin.Checking.Array_Length (Types.all, Declared (1))),
                  4, "the declaration carries the length");
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Array_Element (Types.all, Declared (1))
                    = Landin.Types.U8,
                  "and the element");

               --  D15's alias, which has no shape of its own to carry.
               Landin.Testing.Check_Equal
                 (Item,
                  Natural
                    (Landin.Checking.Array_Length (Types.all, Declared (3))),
                  4, "an alias carries the shape it names");
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Array_Element (Types.all, Declared (3))
                    = Landin.Types.U8,
                  "including its element");
               Landin.Testing.Check_Equal
                 (Item,
                  Natural
                    (Landin.Checking.Array_Length (Types.all, Declared (4))),
                  3, "and a different array keeps its own");
            end;

            --  A length of zero: no room, and a byte's alignment
            --  because there is no element to be aligned as.
            Landin.Checking.Array_Extent
              (0, Landin.Types.U32, Facts, Size, Alignment);
            Landin.Testing.Check_Equal
              (Item, Natural (Size), 0, "no elements take no room");
            Landin.Testing.Check_Equal
              (Item, Natural (Alignment), 1,
               "and align to a byte, having no element to align as");

            --  The one that follows the target rather than the host.
            Landin.Checking.Array_Extent
              (Landin.Checking.Array_Length (Types.all, Of_Tree.all, Wide),
               Landin.Checking.Array_Element (Types.all, Of_Tree.all, Wide),
               Facts, Size, Alignment);
            Landin.Testing.Check_Equal
              (Item, Natural (Size), Wide_Size,
               "a pointer-width element follows the target");
            Landin.Testing.Check_Equal
              (Item, Natural (Alignment), Wide_Align,
               "and so does its alignment");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64, 32, 8);
      Check_Target (Landin.Targets.Synthetic_32, 16, 4);
   end Array_Types_Are_Their_Length_And_Element;

   --  D135: a saturated alias application is erased into the same scalar or
   --  fixed-array descriptor as direct syntax.  Template bodies and formals
   --  remain compile-time syntax: no answer from either application is
   --  written back onto them.
   procedure Ordinary_Function_Signatures_Use_Identity_Only
     (Item : in out Landin.Testing.Context);

   procedure Parameterized_Aliases_Normalize_To_Existing_Descriptors
     (Item : in out Landin.Testing.Context);

   procedure Parameterized_Structs_Intern_And_Lay_Out_Instances
     (Item : in out Landin.Testing.Context);

   procedure Identity_Actuals_Materialize_At_Value_Uses
     (Item : in out Landin.Testing.Context);

   procedure Nominal_Layout_Requirements_Distinguish_Identity_And_Value
     (Item : in out Landin.Testing.Context);

   procedure Repeated_Invalid_Instances_Report_Each_Application
     (Item : in out Landin.Testing.Context);

   procedure Invalid_Parameterized_Templates_Are_Checked_When_Unused
     (Item : in out Landin.Testing.Context);

   procedure Fixed_Bound_Arithmetic_And_Applications_Are_Bounded
     (Item : in out Landin.Testing.Context);

   procedure Ordinary_Function_Signatures_Use_Identity_Only
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "ordinary-signature-recursion.ldn",
         "alias: type = node" & LF
         & "again: type = alias" & LF
         & "node: type = struct" & LF
         & "    direct: (value: node) -> (result: node)" & LF
         & "    through: (value: again) -> (result: alias)" & LF
         & "end node" & LF
         & "left: type = struct" & LF
         & "    exchange: (value: right) -> (result: right)" & LF
         & "end left" & LF
         & "right: type = struct" & LF
         & "    exchange: (value: left) -> (result: left)" & LF
         & "end right" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check
        (Item, Ran = 4 and then not Landin.Stages.Failed (Work),
         "ordinary self, alias and mutual signature recursion is accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);

         function Declaration_At (Position : Positive)
           return Landin.Provenance.Declaration_Id;

         function Declaration_At (Position : Positive)
           return Landin.Provenance.Declaration_Id
         is
            Node : constant Landin.Syntax.Node_Id :=
              Landin.Syntax.Nth_Declaration (Of_Tree.all, Position);
         begin
            for Id in Landin.Provenance.Declaration_Id'(1)
              .. Landin.Provenance.Declaration_Id
                   (Landin.Resolution.Declaration_Count (Meanings.all))
            loop
               if Landin.Resolution.Source_Of (Meanings.all, Id) = Src
                 and then Landin.Resolution.Node_Of (Meanings.all, Id) = Node
               then
                  return Id;
               end if;
            end loop;
            return Landin.Provenance.No_Declaration;
         end Declaration_At;

         Node_Id : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Declaration_At (3));
         Left_Id : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Declaration_At (4));
         Right_Id : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Declaration_At (5));
         Direct : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Field_Shape_Of
             (Types.all, Node_Id, 1).Signature;
         Through : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Field_Shape_Of
             (Types.all, Node_Id, 2).Signature;
         Left_Signature : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Field_Shape_Of
             (Types.all, Left_Id, 1).Signature;
         Right_Signature : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Field_Shape_Of
             (Types.all, Right_Id, 1).Signature;
      begin
         Landin.Testing.Check
           (Item, Landin.Checking.Has_Layout (Types.all, Node_Id)
             and then Landin.Checking.Has_Layout (Types.all, Left_Id)
             and then Landin.Checking.Has_Layout (Types.all, Right_Id)
             and then Landin.Checking.Nominal_Of
               (Types.all, Declaration_At (1)) = Node_Id
             and then Landin.Checking.Nominal_Of
               (Types.all, Declaration_At (2)) = Node_Id,
            "signature identity lookup preserves layouts and aliases");
         Landin.Testing.Check
           (Item, Landin.Checking.Nth_Signature_Parameter
              (Types.all, Direct, 1).Nominal = Node_Id
             and then Landin.Checking.Nth_Signature_Result
               (Types.all, Direct, 1).Nominal = Node_Id
             and then Landin.Checking.Nth_Signature_Parameter
               (Types.all, Through, 1).Nominal = Node_Id
             and then Landin.Checking.Nth_Signature_Result
               (Types.all, Through, 1).Nominal = Node_Id,
            "self parameters and results retain one nominal identity");
         Landin.Testing.Check
           (Item, Landin.Checking.Nth_Signature_Parameter
              (Types.all, Left_Signature, 1).Nominal = Right_Id
             and then Landin.Checking.Nth_Signature_Result
               (Types.all, Left_Signature, 1).Nominal = Right_Id
             and then Landin.Checking.Nth_Signature_Parameter
               (Types.all, Right_Signature, 1).Nominal = Left_Id
             and then Landin.Checking.Nth_Signature_Result
               (Types.all, Right_Signature, 1).Nominal = Left_Id,
            "mutual signature references retain both finite identities");
      end;

      declare
         Abi_Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Abi_Order : Landin.Stages.Pipeline;
         Abi_Ran : Natural;
         Abi_Source : constant Landin.Source.Source_Id :=
           Landin.Stages.Add_Source
             (Abi_Work, "multiple-nominal-results.ldn",
              "cell: type (item: type) = struct" & LF
              & "    value: item" & LF
              & "end cell" & LF
              & "pair: () -> (one: cell(u8), many: [2]cell(u8)," & LF
              & "            first: node, second: node) =" & LF
              & "    one = (value: 1)" & LF
              & "    many = zeroed" & LF
              & "    first = zeroed" & LF
              & "    second = zeroed" & LF
              & "end pair" & LF
              & "node: type = struct" & LF
              & "    value: u8" & LF
              & "end node" & LF);
      begin
         Landin.Stages.Append (Abi_Order, Frontend'Access);
         Landin.Stages.Append (Abi_Order, Configurer'Access);
         Landin.Stages.Append (Abi_Order, Names'Access);
         Landin.Stages.Append (Abi_Order, Checker'Access);
         Abi_Ran := Landin.Stages.Run (Abi_Order, Abi_Work);
         Landin.Testing.Check
           (Item, Abi_Source /= Landin.Source.No_Source and then Abi_Ran = 4
             and then not Landin.Stages.Failed (Abi_Work),
            "multiple nominal results materialize their ABI layouts");
      end;
   end Ordinary_Function_Signatures_Use_Identity_Only;

   procedure Parameterized_Aliases_Normalize_To_Existing_Descriptors
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "parameterized-aliases.ldn",
         "identity: type (t: type) = t" & LF
         & "bytes: type (t: type, fixed n: u64) = [n * 2]t" & LF
         & "nested: type (fixed n: integer, integer: type, t: type)"
         & " = bytes(t, n)" & LF
         & "word: type = identity(u16)" & LF
         & "pair: type = identity([2]u8)" & LF
         & "four: type = nested(2, u8, u32)" & LF
         & "mut direct: bytes(u8, 7)" & LF
         & "large: type = [64 * 1024]u8" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "scalar, fixed and nested substitutions are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);

         function Declaration_At (Position : Positive)
           return Landin.Provenance.Declaration_Id;

         function Declaration_At (Position : Positive)
           return Landin.Provenance.Declaration_Id
         is
            Node : constant Landin.Syntax.Node_Id :=
              Landin.Syntax.Nth_Declaration (Of_Tree.all, Position);
         begin
            for Id in Landin.Provenance.Declaration_Id'(1)
                      .. Landin.Provenance.Declaration_Id
                           (Landin.Resolution.Declaration_Count (Meanings.all))
            loop
               if Landin.Resolution.Source_Of (Meanings.all, Id) = Src
                 and then Landin.Resolution.Node_Of (Meanings.all, Id) = Node
               then
                  return Id;
               end if;
            end loop;
            return Landin.Provenance.No_Declaration;
         end Declaration_At;

         Identity : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 1);
         Bytes : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 2);
         Nested : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 3);
         Word : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (4);
         Pair : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (5);
         Four : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (6);
         Direct : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (7);
         Large : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (8);
         type Template_Array is array (Positive range <>) of
           Landin.Syntax.Node_Id;
         Compile_Time_Formals : Natural := 0;
      begin
         Landin.Testing.Check
           (Item, Landin.Checking.Type_Of (Types.all, Word)
                    = Landin.Types.U16,
            "a scalar application erases to its scalar descriptor");
         Landin.Testing.Check
           (Item, Landin.Checking.Type_Of (Types.all, Pair)
                    = Landin.Types.Fixed_Array
             and then Landin.Checking.Array_Length (Types.all, Pair) = 2
             and then Landin.Checking.Array_Element (Types.all, Pair)
                        = Landin.Types.U8,
            "a fixed-array type actual retains its existing descriptor");
         Landin.Testing.Check
           (Item, Landin.Checking.Type_Of (Types.all, Four)
                    = Landin.Types.Fixed_Array
             and then Landin.Checking.Array_Length (Types.all, Four) = 4
             and then Landin.Checking.Array_Element (Types.all, Four)
                        = Landin.Types.U32,
            "nested type and fixed substitutions erase to one array shape");
         Landin.Testing.Check
           (Item, Landin.Checking.Type_Of (Types.all, Direct)
                    = Landin.Types.Fixed_Array
             and then Landin.Checking.Array_Length (Types.all, Direct) = 14
             and then Landin.Checking.Array_Element (Types.all, Direct)
                        = Landin.Types.U8,
            "a direct application folds its substituted bound");
         Landin.Testing.Check
           (Item, Landin.Checking.Type_Of (Types.all, Large)
                    = Landin.Types.Fixed_Array
             and then Landin.Checking.Array_Length (Types.all, Large) = 65_536
             and then Landin.Checking.Array_Element (Types.all, Large)
                        = Landin.Types.U8,
            "a concrete fixed expression supplies the canonical count");

         for Template of Template_Array'[Identity, Bytes, Nested] loop
            declare
               Template_Body : constant Landin.Syntax.Node_Id :=
                 Landin.Syntax.Declared_Type (Of_Tree.all, Template);
            begin
               Landin.Testing.Check
                 (Item, Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Template_Body)
                            = Landin.Types.Undecided,
                  "a template body stores no instantiation type");
               if Landin.Syntax.Kind (Of_Tree.all, Template_Body)
                    = Landin.Syntax.Array_Type
               then
                  Landin.Testing.Check_Equal
                    (Item, Natural (Landin.Checking.Array_Length
                      (Types.all, Of_Tree.all, Template_Body)), 0,
                     "a template array stores no instantiation length");
               end if;
            end;
         end loop;

         for Id in Landin.Provenance.Declaration_Id'(1)
                   .. Landin.Provenance.Declaration_Id
                        (Landin.Resolution.Declaration_Count (Meanings.all))
         loop
            if Landin.Resolution.Sort_Of (Meanings.all, Id)
                 in Landin.Resolution.Type_Parameter
                    | Landin.Resolution.Fixed_Parameter
            then
               Compile_Time_Formals := Compile_Time_Formals + 1;
               Landin.Testing.Check
                 (Item, Landin.Checking.Type_Of (Types.all, Id)
                          = Landin.Types.Not_Typed,
                  "a formal has no runtime type descriptor");
            end if;
         end loop;
         Landin.Testing.Check_Equal
           (Item, Compile_Time_Formals, 6,
            "every formal was retained only for compile-time substitution");
      end;
   end Parameterized_Aliases_Normalize_To_Existing_Descriptors;

   procedure Parameterized_Structs_Intern_And_Lay_Out_Instances
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "parameterized-structs.ldn",
         "byte: type = u8" & LF
         & "box: type (item: type) = struct" & LF
         & "    value: item" & LF
         & "end box" & LF
         & "first: box(u8)" & LF
         & "same: box(byte)" & LF
         & "different: box(i8)" & LF
         & "other: type (item: type) = struct" & LF
         & "    value: item" & LF
         & "end other" & LF
         & "other_first: other(u8)" & LF
         & "packet: type (item: type, fixed count: u8) = struct" & LF
         & "    data: [count]item" & LF
         & "end packet" & LF
         & "short: packet(u16, 2)" & LF
         & "long: packet(u16, 4)" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check
        (Item, Ran = 4 and then not Landin.Stages.Failed (Work),
         "the checker materializes every applied nominal instance");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);

         function Declaration_For (Node : Landin.Syntax.Node_Id)
           return Landin.Provenance.Declaration_Id;

         function Declaration_For (Node : Landin.Syntax.Node_Id)
           return Landin.Provenance.Declaration_Id is
         begin
            for Id in Landin.Provenance.Declaration_Id'(1)
              .. Landin.Provenance.Declaration_Id
                   (Landin.Resolution.Declaration_Count (Meanings.all))
            loop
               if Landin.Resolution.Source_Of (Meanings.all, Id) = Src
                 and then Landin.Resolution.Node_Of (Meanings.all, Id) = Node
               then
                  return Id;
               end if;
            end loop;
            return Landin.Provenance.No_Declaration;
         end Declaration_For;

         function Declaration_At (Position : Positive)
           return Landin.Provenance.Declaration_Id
         is (Declaration_For
               (Landin.Syntax.Nth_Declaration (Of_Tree.all, Position)));

         Box : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (2);
         First : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Declaration_At (3));
         Same : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Declaration_At (4));
         Different : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Declaration_At (5));
         Other_First : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Declaration_At (7));
         Short : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Declaration_At (9));
         Long : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Declaration_At (10));
         Template : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 2);
         Template_Body : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type (Of_Tree.all, Template);
         Formal : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Type_Formal (Of_Tree.all, Template, 1);
         Formal_Id : constant Landin.Provenance.Declaration_Id :=
           Declaration_For (Formal);
      begin
         Landin.Testing.Check
           (Item, First = Same and then First /= Different
             and then First /= Other_First,
            "normalized aliases reuse a key while actuals and templates"
            & " remain nominally distinct");
         Landin.Testing.Check
           (Item, Landin.Checking.Nominal_Type_Count (Types.all) = 5
             and then Landin.Checking.Template_Of (Types.all, First) = Box
             and then Landin.Checking.Instance_Actual_Count
               (Types.all, First) = 1
             and then Landin.Checking.Type_Form_Of
               (Landin.Checking.Nth_Instance_Actual
                  (Types.all, First, 1))
                    = Landin.Checking.Scalar_Actual_Type
             and then Landin.Checking.Scalar_Of
               (Types.all, Landin.Checking.Nth_Instance_Actual
                  (Types.all, First, 1)) = Landin.Types.U8,
            "only concrete instances retain their complete normalized"
            & " tuples");
         Landin.Testing.Check
           (Item, Landin.Checking.Has_Layout (Types.all, Short)
             and then Landin.Checking.Has_Layout (Types.all, Long)
             and then Natural
               (Landin.Checking.Layout_Size (Types.all, Short)) = 4
             and then Natural
               (Landin.Checking.Layout_Size (Types.all, Long)) = 8,
            "fixed substitution builds one target layout for each key");
         Landin.Testing.Check
           (Item, Landin.Checking.Type_Of
              (Types.all, Of_Tree.all, Template_Body)
                = Landin.Types.Undecided
             and then Landin.Checking.Type_Of
               (Types.all, Of_Tree.all,
                Landin.Syntax.Declared_Type (Of_Tree.all,
                  Landin.Syntax.Nth_Field
                    (Of_Tree.all, Template_Body, 1)))
                  = Landin.Types.Undecided
             and then Landin.Checking.Type_Of (Types.all, Formal_Id)
                        = Landin.Types.Not_Typed,
            "template bodies, fields and formals retain no instance answer");
      end;
   end Parameterized_Structs_Intern_And_Lay_Out_Instances;

   procedure Identity_Actuals_Materialize_At_Value_Uses
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "lazy-value-layout.ldn",
         "cell: type (item: type) = struct" & LF
         & "    value: item" & LF
         & "end cell" & LF
         & "wrapper: type (item: type) = struct" & LF
         & "    value: item" & LF
         & "end wrapper" & LF
         & "good: wrapper(cell(u8)) = (value: (value: 1))" & LF
         & "nested: wrapper(wrapper(cell(u8))) ="
         & " (value: (value: (value: 2)))" & LF
         & "row: wrapper([2]cell(u8)) = zeroed" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check
        (Item, Ran = 4 and then not Landin.Stages.Failed (Work),
         "identity-only descriptors are promoted at substituted value uses");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);

         function Declaration_At (Position : Positive)
           return Landin.Provenance.Declaration_Id;

         function Declaration_At (Position : Positive)
           return Landin.Provenance.Declaration_Id
         is
            Node : constant Landin.Syntax.Node_Id :=
              Landin.Syntax.Nth_Declaration (Of_Tree.all, Position);
         begin
            for Id in Landin.Provenance.Declaration_Id'(1)
              .. Landin.Provenance.Declaration_Id
                   (Landin.Resolution.Declaration_Count (Meanings.all))
            loop
               if Landin.Resolution.Source_Of (Meanings.all, Id) = Src
                 and then Landin.Resolution.Node_Of (Meanings.all, Id) = Node
               then
                  return Id;
               end if;
            end loop;
            return Landin.Provenance.No_Declaration;
         end Declaration_At;

         Good : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Declaration_At (3));
         Nested : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Declaration_At (4));
         Row : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Declaration_At (5));
         Cell : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Field_Shape_Of (Types.all, Good, 1).Nominal;
         Cell_Body : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type
             (Of_Tree.all,
              Landin.Syntax.Nth_Declaration (Of_Tree.all, 1));
         Wrapper_Body : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type
             (Of_Tree.all,
              Landin.Syntax.Nth_Declaration (Of_Tree.all, 2));
      begin
         Landin.Testing.Check
           (Item, Landin.Checking.Nominal_Type_Count (Types.all) = 4
             and then Landin.Checking.Has_Layout (Types.all, Cell)
             and then Landin.Checking.Has_Layout (Types.all, Good)
             and then Landin.Checking.Has_Layout (Types.all, Nested)
             and then Landin.Checking.Has_Layout (Types.all, Row),
            "nested promotion reuses four canonical identities with layouts");
         Landin.Testing.Check
           (Item, Landin.Checking.Field_Shape_Of
              (Types.all, Nested, 1).Nominal = Good
             and then Landin.Checking.Field_Kind_Of (Types.all, Row, 1)
               = Landin.Checking.Fixed_Array_Field
             and then Landin.Checking.Field_Array_Length
               (Types.all, Row, 1) = 2
             and then Landin.Checking.Field_Shape_Of
               (Types.all, Row, 1).Nominal = Cell,
            "nominal and nominal-array actuals retain their promoted shape");
         Landin.Testing.Check
           (Item, Landin.Checking.Type_Of
              (Types.all, Of_Tree.all, Cell_Body) = Landin.Types.Undecided
             and then Landin.Checking.Type_Of
               (Types.all, Of_Tree.all, Wrapper_Body)
                  = Landin.Types.Undecided
             and then Landin.Checking.Type_Of
               (Types.all, Of_Tree.all,
                Landin.Syntax.Declared_Type
                  (Of_Tree.all,
                   Landin.Syntax.Nth_Field
                     (Of_Tree.all, Wrapper_Body, 1)))
                       = Landin.Types.Undecided,
            "lazy promotion writes no answer onto either template AST");
      end;
   end Identity_Actuals_Materialize_At_Value_Uses;

   procedure Nominal_Layout_Requirements_Distinguish_Identity_And_Value
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Failure
        (Text : String;
         Code : String;
         What : String;
         No_Concrete_Instances : Boolean := False);

      procedure Check_Failure
        (Text : String;
         Code : String;
         What : String;
         No_Concrete_Instances : Boolean := False)
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
      begin
         Src := Landin.Stages.Add_Source (Work, "nominal-edge.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check
              (Item, Src /= Landin.Source.No_Source and then Ran = 4
                and then Landin.Diagnostics.Count (Reports) = 1
                and then Landin.Diagnostics.Code
                  (Landin.Diagnostics.Get (Reports, 1)) = Code
                and then
                  (not No_Concrete_Instances
                   or else Landin.Checking.Nominal_Type_Count
                     (Landin.Stages.Types (Work).all) = 0),
               What);
         end;
      end Check_Failure;

      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "identity-only.ldn",
         "function_node: type (item: type) = struct" & LF
         & "    visit: (value: function_node(item)) -> none" & LF
         & "end function_node" & LF
         & "ignore: (value: function_node(u8)) -> none =" & LF
         & "end ignore" & LF
         & "function_good: function_node(u8) = (visit: ignore)" & LF
         & "phantom_node: type (item: type) = struct" & LF
         & "    marker: phantom(phantom_node(item))" & LF
         & "end phantom_node" & LF
         & "phantom: type (item: type) = struct" & LF
         & "    marker: u8" & LF
         & "end phantom" & LF
         & "phantom_good: phantom_node(u8) = zeroed" & LF
         & "huge: type (fixed count: u64) = struct" & LF
         & "    bytes: [count]u64" & LF
         & "end huge" & LF
         & "huge_is_only_an_actual:"
         & " phantom(huge(18446744073709551615)) = zeroed" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check
        (Item, Ran = 4 and then not Landin.Stages.Failed (Work),
         "signature and phantom references need identity but not child"
         & " layout");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);

         function Declaration_At (Position : Positive)
           return Landin.Provenance.Declaration_Id;

         function Declaration_At (Position : Positive)
           return Landin.Provenance.Declaration_Id
         is
            Node : constant Landin.Syntax.Node_Id :=
              Landin.Syntax.Nth_Declaration (Of_Tree.all, Position);
         begin
            for Id in Landin.Provenance.Declaration_Id'(1)
              .. Landin.Provenance.Declaration_Id
                   (Landin.Resolution.Declaration_Count (Meanings.all))
            loop
               if Landin.Resolution.Source_Of (Meanings.all, Id) = Src
                 and then Landin.Resolution.Node_Of (Meanings.all, Id) = Node
               then
                  return Id;
               end if;
            end loop;
            return Landin.Provenance.No_Declaration;
         end Declaration_At;

         Function_Node : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Declaration_At (3));
         Phantom_Node : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Declaration_At (6));
         Function_Field : constant Landin.Checking.Field_Shape :=
           Landin.Checking.Field_Shape_Of (Types.all, Function_Node, 1);
         Function_Parameter : constant Landin.Checking.Signature_Part :=
           Landin.Checking.Nth_Signature_Parameter
             (Types.all, Function_Field.Signature, 1);
         Phantom_Instance : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Field_Shape_Of
             (Types.all, Phantom_Node, 1).Nominal;
         Huge_Phantom : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of (Types.all, Declaration_At (8));
         Huge_Identity : constant Landin.Checking.Nominal_Type_Id :=
           Landin.Checking.Nominal_Of
             (Types.all, Landin.Checking.Nth_Instance_Actual
                (Types.all, Huge_Phantom, 1));
      begin
         Landin.Testing.Check
           (Item, Landin.Checking.Has_Layout (Types.all, Function_Node)
             and then Function_Parameter.Nominal = Function_Node,
            "a recursive signature retains the canonical identity without"
            & " becoming a value-layout edge");
         Landin.Testing.Check
           (Item, Landin.Checking.Has_Layout (Types.all, Phantom_Node)
             and then Landin.Checking.Has_Layout
               (Types.all, Phantom_Instance)
             and then Landin.Checking.Nominal_Of
               (Types.all, Landin.Checking.Nth_Instance_Actual
                  (Types.all, Phantom_Instance, 1)) = Phantom_Node,
            "a phantom actual retains identity while only the outer marker"
            & " contributes layout");
         Landin.Testing.Check
           (Item, Landin.Checking.Has_Layout (Types.all, Huge_Phantom)
             and then Landin.Checking.Instance_State_Of
               (Types.all, Huge_Identity) = Landin.Checking.Instance_Unseen,
            "an identity-only actual neither requests target layout nor"
            & " caches an actual-dependent failure");
      end;

      Check_Failure
        ("node: type (item: type) = struct" & LF
         & "    children: [0]node(item)" & LF
         & "end node" & LF
         & "bad: node(u8)" & LF,
         "L0313",
         "a zero-length nominal array still follows its element layout"
         & " edge");
      Check_Failure
        ("node: type (item: type) = struct" & LF
         & "    kind: variant" & LF
         & "        leaf |" & LF
         & "        next: (value: node(item))" & LF
         & "    end kind" & LF
         & "end node" & LF
         & "bad: node(u8)" & LF,
         "L0313",
         "a nominal payload remains a by-value layout edge");
      Check_Failure
        ("holder: type (item: type) = struct" & LF
         & "    value: looping(item)" & LF
         & "end holder" & LF
         & "looping: type (item: type) = looping(item)" & LF
         & "good: holder(u8) = zeroed" & LF,
         "L0307",
         "an alias cycle inside an earlier struct is not nominal recursion");
      Check_Failure
        ("looping: type (item: type) = looping(item)" & LF
         & "holder: type (item: type) = struct" & LF
         & "    value: looping(item)" & LF
         & "end holder" & LF
         & "good: holder(u8) = zeroed" & LF,
         "L0307",
         "the same alias classification is declaration-order independent");
      Check_Failure
        ("wrapper: type (item: type) = struct" & LF
         & "    value: item" & LF
         & "end wrapper" & LF
         & "node: type (item: type) = struct" & LF
         & "    next: wrapper(node(item))" & LF
         & "end node" & LF,
         "L0313",
         "symbolic promotion rejects unused indirect nominal recursion",
         No_Concrete_Instances => True);
      Check_Failure
        ("node: type (item: type) = struct" & LF
         & "    next: wrapper(node(item))" & LF
         & "end node" & LF
         & "wrapper: type (item: type) = struct" & LF
         & "    value: item" & LF
         & "end wrapper" & LF,
         "L0313",
         "symbolic recursion is declaration-order independent",
         No_Concrete_Instances => True);
      Check_Failure
        ("wrapper: type (item: type) = struct" & LF
         & "    value: item" & LF
         & "end wrapper" & LF
         & "node: type (item: type) = struct" & LF
         & "    next: wrapper([0]node(item))" & LF
         & "end node" & LF,
         "L0313",
         "a symbolic nominal-array obligation remains a value edge",
         No_Concrete_Instances => True);
      Check_Failure
        ("wrapper: type (item: type) = struct" & LF
         & "    value: item" & LF
         & "end wrapper" & LF
         & "left: type (item: type) = struct" & LF
         & "    next: wrapper(right(item))" & LF
         & "end left" & LF
         & "right: type (item: type) = struct" & LF
         & "    next: wrapper(left(item))" & LF
         & "end right" & LF,
         "L0313",
         "symbolic obligations reject mutual used-formal recursion",
         No_Concrete_Instances => True);
      Check_Failure
        ("one: type (item: type) = struct" & LF
         & "    value: item" & LF
         & "end one" & LF
         & "two: type (item: type) = struct" & LF
         & "    value: one(item)" & LF
         & "end two" & LF
         & "node: type (item: type) = struct" & LF
         & "    next: two(node(item))" & LF
         & "end node" & LF,
         "L0313",
         "symbolic obligations survive multiple used-formal wrappers",
         No_Concrete_Instances => True);
      Check_Failure
        ("huge: type (fixed count: u64) = struct" & LF
         & "    bytes: [count]u64" & LF
         & "end huge" & LF
         & "wrapper: type (item: type) = struct" & LF
         & "    value: item" & LF
         & "end wrapper" & LF
         & "bad: wrapper(huge(18446744073709551615))" & LF,
         "L0300",
         "a nominal actual checks target extent only at its value use");
      Check_Failure
        ("cell: type (item: type) = struct" & LF
         & "    value: item" & LF
         & "end cell" & LF
         & "wrapper: type (item: type) = struct" & LF
         & "    value: item" & LF
         & "end wrapper" & LF
         & "bad: wrapper([18446744073709551615]cell(u64))" & LF,
         "L0300",
         "a used array actual materializes its nominal element before D18");
      Check_Failure
        ("huge: type (fixed count: u64) = struct" & LF
         & "    bytes: [count]u64" & LF
         & "end huge" & LF
         & "bad: () -> (result: huge(18446744073709551615)) =" & LF
         & "end bad" & LF,
         "L0300",
         "one invalid nominal result application reports one layout failure");
   end Nominal_Layout_Requirements_Distinguish_Identity_And_Value;

   procedure Repeated_Invalid_Instances_Report_Each_Application
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "repeated-invalid.ldn",
         "huge: type (fixed count: u64) = struct" & LF
         & "    bytes: [count]u64" & LF
         & "end huge" & LF
         & "first: huge(18446744073709551615)" & LF
         & "second: huge(18446744073709551615)" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      declare
         Reports : constant Landin.Diagnostics.Diagnostic_List :=
           Landin.Stages.Report (Work);
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         First : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type
             (Of_Tree.all,
              Landin.Syntax.Nth_Declaration (Of_Tree.all, 2));
         Second : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type
             (Of_Tree.all,
              Landin.Syntax.Nth_Declaration (Of_Tree.all, 3));
      begin
         Landin.Testing.Check
           (Item, Ran = 4 and then Landin.Diagnostics.Count (Reports) = 2
             and then Landin.Diagnostics.Code
               (Landin.Diagnostics.Get (Reports, 1)) = "L0300"
             and then Landin.Diagnostics.Code
               (Landin.Diagnostics.Get (Reports, 2)) = "L0300",
            "one cached invalid identity replays its dependent failure");
         Landin.Testing.Check
           (Item, Landin.Diagnostics.Span_Of
              (Landin.Diagnostics.Primary
                 (Landin.Diagnostics.Get (Reports, 1)))
                    = Landin.Syntax.Where (Of_Tree.all, First)
             and then Landin.Diagnostics.Span_Of
               (Landin.Diagnostics.Primary
                  (Landin.Diagnostics.Get (Reports, 2)))
                    = Landin.Syntax.Where (Of_Tree.all, Second)
             and then Landin.Syntax.Where (Of_Tree.all, First)
               /= Landin.Syntax.Where (Of_Tree.all, Second),
            "the repeated failures retain distinguishable application"
            & " primaries");
         Landin.Testing.Check
           (Item, Landin.Checking.Nominal_Type_Count (Types.all) = 1
             and then Landin.Checking.Instance_State_Of
               (Types.all, Landin.Checking.Nth_Nominal_Type (Types.all, 1))
                  = Landin.Checking.Instance_Invalid,
            "replay retains one canonical identity and one tuple");
      end;
   end Repeated_Invalid_Instances_Report_Each_Application;

   procedure Invalid_Parameterized_Templates_Are_Checked_When_Unused
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Rejected (Text : String; What : String);
      procedure Check_Rejected_Message
        (Text : String; Expected : String; What : String);
      procedure Check_Nested_Unconditional
        (Outer_First : Boolean; What : String);

      procedure Check_Rejected (Text : String; What : String) is
         Work  : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran   : Natural;
         Src   : Landin.Source.Source_Id;
      begin
         Src := Landin.Stages.Add_Source (Work, "unused.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         Landin.Testing.Check
           (Item, Src /= Landin.Source.No_Source and then Ran = 4
             and then Landin.Stages.Failed (Work),
            What);
      end Check_Rejected;

      procedure Check_Rejected_Message
        (Text : String; Expected : String; What : String)
      is
         Work  : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran   : Natural;
         Src   : Landin.Source.Source_Id;
      begin
         Src := Landin.Stages.Add_Source (Work, "nonfixed-name.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check
              (Item, Src /= Landin.Source.No_Source and then Ran = 4
                and then Landin.Diagnostics.Count (Reports) = 1
                and then Landin.Diagnostics.Message
                  (Landin.Diagnostics.Primary
                     (Landin.Diagnostics.Get (Reports, 1))) = Expected,
               What);
         end;
      end Check_Rejected_Message;

      procedure Check_Nested_Unconditional
        (Outer_First : Boolean; What : String)
      is
         Work  : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran   : Natural;
         Outer, Inner : Landin.Source.Source_Id;
      begin
         if Outer_First then
            Outer := Landin.Stages.Add_Source
              (Work, "outer.ldn",
               "outer: type (t: type) = inner(t)" & LF);
            Inner := Landin.Stages.Add_Source
              (Work, "inner.ldn",
               "inner: type (t: type) = [1 / 0]t" & LF);
         else
            Inner := Landin.Stages.Add_Source
              (Work, "inner.ldn",
               "inner: type (t: type) = [1 / 0]t" & LF);
            Outer := Landin.Stages.Add_Source
              (Work, "outer.ldn",
               "outer: type (t: type) = inner(t)" & LF);
         end if;
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
            Report : constant Landin.Diagnostics.Diagnostic :=
              Landin.Diagnostics.Get (Reports, 1);
         begin
            Landin.Testing.Check
              (Item, Outer /= Landin.Source.No_Source
                and then Inner /= Landin.Source.No_Source
                and then Ran = 4
                and then Landin.Diagnostics.Count (Reports) = 1
                and then Landin.Diagnostics.Code (Report) = "L0306"
                and then Landin.Diagnostics.Source_Of
                  (Landin.Diagnostics.Primary (Report)) = Inner
                and then Landin.Diagnostics.Label_Count (Report) = 0,
               What);
         end;
      end Check_Nested_Unconditional;

      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "unused-unknown.ldn",
         "bad: type (t: type) = missing" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check
        (Item, Ran = 4 and then Landin.Stages.Failed (Work),
         "an unused template still rejects an unresolved free type");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         Declaration : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 1);
         Template_Id : Landin.Provenance.Declaration_Id :=
           Landin.Provenance.No_Declaration;
      begin
         for Id in Landin.Provenance.Declaration_Id'(1)
                   .. Landin.Provenance.Declaration_Id
                        (Landin.Resolution.Declaration_Count (Meanings.all))
         loop
            if Landin.Resolution.Node_Of (Meanings.all, Id) = Declaration then
               Template_Id := Id;
               exit;
            end if;
         end loop;
         Landin.Testing.Check
           (Item, Template_Id /= Landin.Provenance.No_Declaration
             and then Landin.Checking.Type_Of (Types.all, Template_Id)
                        = Landin.Types.Not_Typed
             and then Landin.Checking.Type_Of
               (Types.all, Of_Tree.all,
                Landin.Syntax.Declared_Type (Of_Tree.all, Declaration))
                  = Landin.Types.Undecided,
            "validation writes no type metadata onto an invalid template");
      end;

      Check_Rejected
        ("value: u8 = 1" & LF
         & "bad: type (t: type) = value" & LF,
         "an unused template rejects a free value name");
      Check_Rejected
        ("bad: type (fixed n: bool) = u8" & LF,
         "an unused fixed formal rejects a decidable bool type");
      Check_Rejected
        ("bad: type (t: type) = () -> none" & LF,
         "an unused template rejects a decidable function result");
      Check_Rejected
        ("a: type (t: type) = b(t)" & LF
         & "b: type (t: type) = a(t)" & LF,
         "unused templates reject an unconditional expansion cycle");
      Check_Rejected
        ("bad: type (t: type) = [1 / 0]t" & LF,
         "an impossible fixed-expression divisor is rejected");
      Check_Nested_Unconditional
        (Outer_First => True,
         What => "an inner unconditional defect belongs to its declaration"
                 & " when the outer template is declared first");
      Check_Nested_Unconditional
        (Outer_First => False,
         What => "an inner unconditional defect belongs to its declaration"
                 & " when the inner template is declared first");
      Check_Rejected
        ("bad: type (t: type) = [18446744073709551615 + 1]t" & LF,
         "a fixed-expression intermediate overflow is rejected");
      Check_Rejected_Message
        ("bad: type (n: type, t: type) = [n]t" & LF,
         "this name is a type formal, not a fixed value",
         "a type formal is distinguished from runtime storage");
      Check_Rejected_Message
        ("named: type = u8" & LF
         & "bad: type (t: type) = [named]t" & LF,
         "this name does not denote a fixed integer value",
         "a non-value declaration is distinguished from runtime storage");
      Check_Rejected_Message
        ("n: u32 = 4" & LF
         & "bad: type (t: type) = [n]t" & LF,
         "this name is runtime storage, not a fixed formal",
         "runtime storage is identified as the non-fixed leaf");
      Check_Rejected
        ("size: () -> (n: u32) = n = 4 end size" & LF
         & "bad: type (t: type) = [size()]t" & LF,
         "a user call in a bound is rejected without evaluating its body");
      Check_Rejected
        ("bad: type (t: type) = [1 << 2]t" & LF,
         "a width-dependent operator is not a fixed expression");
   end Invalid_Parameterized_Templates_Are_Checked_When_Unused;

   procedure Fixed_Bound_Arithmetic_And_Applications_Are_Bounded
     (Item : in out Landin.Testing.Context)
   is
      procedure Append_Checking (Into : in out Landin.Stages.Pipeline);

      procedure Append_Checking (Into : in out Landin.Stages.Pipeline) is
      begin
         Landin.Stages.Append (Into, Frontend'Access);
         Landin.Stages.Append (Into, Configurer'Access);
         Landin.Stages.Append (Into, Names'Access);
         Landin.Stages.Append (Into, Checker'Access);
      end Append_Checking;
   begin
      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
      begin
         Src := Landin.Stages.Add_Source
           (Work, "fixed-boundaries.ldn",
            "first_cancel: type = [(-18446744073709551615)"
            & " + 18446744073709551615 + 1]u8" & LF
            & "last_divide: type = [(-18446744073709551615) / -1]u8"
            & LF
            & "multiply_boundary: type = [(-18446744073709551615) * -1]u8"
            & LF
            & "negative_divide: type = [-7 / 2 + 4]u8" & LF
            & "negative_remainder: type = [-7 % 2 + 2]u8" & LF);
         Append_Checking (Order);
         Ran := Landin.Stages.Run (Order, Work);
         Landin.Testing.Check
           (Item, Ran = 4 and then not Landin.Stages.Failed (Work),
            "exact folded boundaries and negative quotient rules are valid");

         declare
            Of_Tree : constant not null access constant Landin.Syntax.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Landin.Stages.Trees (Work).all, Src);
            Meanings : constant not null access Landin.Resolution.Table :=
              Landin.Stages.Meanings (Work);
            Types : constant not null access Landin.Checking.Table :=
              Landin.Stages.Types (Work);

            function Declaration_At (Node : Landin.Syntax.Node_Id)
              return Landin.Provenance.Declaration_Id;

            function Declaration_At (Node : Landin.Syntax.Node_Id)
              return Landin.Provenance.Declaration_Id is
            begin
               for Id in Landin.Provenance.Declaration_Id'(1)
                 .. Landin.Provenance.Declaration_Id
                      (Landin.Resolution.Declaration_Count (Meanings.all))
               loop
                  if Landin.Resolution.Source_Of (Meanings.all, Id) = Src
                    and then Landin.Resolution.Node_Of (Meanings.all, Id)
                               = Node
                  then
                     return Id;
                  end if;
               end loop;
               return Landin.Provenance.No_Declaration;
            end Declaration_At;

            Expected : constant array (Positive range 1 .. 5) of
              Landin.Checking.Element_Count :=
                [1, Landin.Checking.Element_Count'Last,
                 Landin.Checking.Element_Count'Last, 1, 1];
         begin
            for Index in Expected'Range loop
               declare
                  Declaration : constant Landin.Provenance.Declaration_Id :=
                    Declaration_At
                      (Landin.Syntax.Nth_Declaration (Of_Tree.all, Index));
               begin
                  Landin.Testing.Check
                    (Item, Landin.Checking.Type_Of (Types.all, Declaration)
                              = Landin.Types.Fixed_Array
                       and then Landin.Checking.Array_Length
                         (Types.all, Declaration) = Expected (Index),
                     "the boundary expression has its exact canonical count");
               end;
            end loop;
         end;
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
      begin
         Src := Landin.Stages.Add_Source
           (Work, "fixed-overflow.ldn",
            "subtract_underflow: type = [-18446744073709551615 - 1]u8"
            & LF
            & "multiply_overflow: type = [18446744073709551615 * 2]u8"
            & LF);
         Append_Checking (Order);
         Ran := Landin.Stages.Run (Order, Work);
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check
              (Item, Src /= Landin.Source.No_Source and then Ran = 4
                and then Landin.Diagnostics.Count (Reports) = 2
                and then Landin.Diagnostics.Code
                  (Landin.Diagnostics.Get (Reports, 1)) = "L0300"
                and then Landin.Diagnostics.Code
                  (Landin.Diagnostics.Get (Reports, 2)) = "L0300",
               "subtraction underflow and multiplication overflow are exact");
         end;
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Template_Src, Use_Src : Landin.Source.Source_Id;
      begin
         Template_Src := Landin.Stages.Add_Source
           (Work, "templates.ldn",
            "scaled: type (fixed n: u64) = [n * 2]u8" & LF
            & "quotient: type (fixed n: u64, fixed d: u64) = [n / d]u8"
            & LF);
         Use_Src := Landin.Stages.Add_Source
           (Work, "applications.ldn",
            "good: type = scaled(3)" & LF
            & "overflow_one: type = scaled(18446744073709551615)" & LF
            & "overflow_two: type = scaled(18446744073709551614)" & LF
            & "zero_divisor: type = quotient(8, 0)" & LF);
         Append_Checking (Order);
         Ran := Landin.Stages.Run (Order, Work);

         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
            Template_Tree : constant not null access constant
              Landin.Syntax.Tree := Landin.Syntax.Forest.Tree_Of
                (Landin.Stages.Trees (Work).all, Template_Src);
            Use_Tree : constant not null access constant Landin.Syntax.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Landin.Stages.Trees (Work).all, Use_Src);
            Types : constant not null access Landin.Checking.Table :=
              Landin.Stages.Types (Work);
            Good : constant Landin.Syntax.Node_Id :=
              Landin.Syntax.Declared_Type
                (Use_Tree.all,
                 Landin.Syntax.Nth_Declaration (Use_Tree.all, 1));
         begin
            Landin.Testing.Check
              (Item, Ran = 4 and then Landin.Diagnostics.Count (Reports) = 3,
               "one valid and three application-dependent folds are checked");
            Landin.Testing.Check
              (Item, Landin.Checking.Type_Of (Types.all, Use_Tree.all, Good)
                       = Landin.Types.Fixed_Array
                and then Landin.Checking.Array_Length
                  (Types.all, Use_Tree.all, Good) = 6,
               "an unknown template formal becomes a valid concrete count");

            for Index in 1 .. 3 loop
               declare
                  Report : constant Landin.Diagnostics.Diagnostic :=
                    Landin.Diagnostics.Get (Reports, Index);
                  Application_Node : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Declared_Type
                      (Use_Tree.all,
                       Landin.Syntax.Nth_Declaration
                         (Use_Tree.all, Index + 1));
               begin
                  Landin.Testing.Check
                    (Item, Landin.Diagnostics.Source_Of
                       (Landin.Diagnostics.Primary (Report)) = Use_Src
                       and then Landin.Diagnostics.Span_Of
                         (Landin.Diagnostics.Primary (Report))
                           = Landin.Syntax.Where
                               (Use_Tree.all, Application_Node),
                     "an applied fold failure is primary at its application");
                  Landin.Testing.Check
                    (Item, Landin.Diagnostics.Label_Count (Report) = 1
                       and then Landin.Diagnostics.Source_Of
                         (Landin.Diagnostics.Nth_Label (Report, 1))
                           = Template_Src,
                     "an applied fold failure relates its template"
                     & " expression");
               end;
            end loop;

            Landin.Testing.Check
              (Item, Landin.Diagnostics.Code
                 (Landin.Diagnostics.Get (Reports, 1)) = "L0300"
                and then Landin.Diagnostics.Code
                  (Landin.Diagnostics.Get (Reports, 2)) = "L0300"
                and then Landin.Diagnostics.Code
                  (Landin.Diagnostics.Get (Reports, 3)) = "L0306",
               "direct and applied failures retain their semantic codes");
            Landin.Testing.Check
              (Item, Landin.Diagnostics.Span_Of
                 (Landin.Diagnostics.Primary
                    (Landin.Diagnostics.Get (Reports, 1)))
                /= Landin.Diagnostics.Span_Of
                  (Landin.Diagnostics.Primary
                     (Landin.Diagnostics.Get (Reports, 2))),
               "two bad instantiations have distinguishable primary spans");
            Landin.Testing.Check
              (Item, Landin.Checking.Type_Of
                 (Types.all, Template_Tree.all,
                  Landin.Syntax.Declared_Type
                    (Template_Tree.all,
                     Landin.Syntax.Nth_Declaration
                       (Template_Tree.all, 1))) = Landin.Types.Undecided,
               "application folds write no answer onto the template body");
         end;
      end;

      declare
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
      begin
         Src := Landin.Stages.Add_Source
           (Work, "nested-dependent.ldn",
            "inner: type (fixed d: u32, t: type) = [8 / d]t" & LF
            & "outer: type (fixed d: u32, t: type) = inner(d, t)" & LF
            & "bad: type = outer(0, u8)" & LF);
         Append_Checking (Order);
         Ran := Landin.Stages.Run (Order, Work);
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
            Of_Tree : constant not null access constant Landin.Syntax.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Landin.Stages.Trees (Work).all, Src);
            Application : constant Landin.Syntax.Node_Id :=
              Landin.Syntax.Declared_Type
                (Of_Tree.all,
                 Landin.Syntax.Nth_Declaration (Of_Tree.all, 3));
            Report : constant Landin.Diagnostics.Diagnostic :=
              Landin.Diagnostics.Get (Reports, 1);
         begin
            Landin.Testing.Check
              (Item, Ran = 4
                and then Landin.Diagnostics.Count (Reports) = 1
                and then Landin.Diagnostics.Code (Report) = "L0306"
                and then Landin.Diagnostics.Source_Of
                  (Landin.Diagnostics.Primary (Report)) = Src
                and then Landin.Diagnostics.Span_Of
                  (Landin.Diagnostics.Primary (Report))
                    = Landin.Syntax.Where (Of_Tree.all, Application)
                and then Landin.Diagnostics.Label_Count (Report) = 1,
               "a genuinely dependent nested defect belongs to the"
               & " application and relates its inner template expression");
         end;
      end;
   end Fixed_Bound_Arithmetic_And_Applications_Are_Bounded;

   --  R2.20: inference from a direct storage name carries D17's exact shape
   --  onto module and local declarations, independent of destination
   --  mutability and whether the source is module or prior-local storage.
   procedure Inferred_Array_Bindings_Carry_Their_Source_Shape
     (Item : in out Landin.Testing.Context);

   procedure Inferred_Array_Bindings_Carry_Their_Source_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Count : Natural := 0;
      Src   : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "inferred-arrays.ldn",
         "source: [3]u16" & LF
         & "mut module_copy := source" & LF
         & "f: () -> none =" & LF
         & "    mut mutable_module := source" & LF
         & "    immutable_module := source" & LF
         & "    mut mutable_local := mutable_module" & LF
         & "    immutable_local := immutable_module" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, Src /= Landin.Source.No_Source, "the source was recorded");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "all four forms are accepted");

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Id in Landin.Provenance.Declaration_Id'(1)
                   .. Landin.Provenance.Declaration_Id
                        (Landin.Resolution.Declaration_Count (Meanings.all))
         loop
            if Landin.Resolution.Sort_Of (Meanings.all, Id)
                 in Landin.Resolution.Local_Binding
                    | Landin.Resolution.Module_Binding
              and then Landin.Checking.Type_Of (Types.all, Id)
                       = Landin.Types.Fixed_Array
            then
               Count := Count + 1;
               Landin.Testing.Check
                 (Item, Landin.Checking.Type_Of (Types.all, Id)
                          = Landin.Types.Fixed_Array,
                  "the inferred declaration is a fixed array");
               Landin.Testing.Check_Equal
                 (Item,
                  Natural (Landin.Checking.Array_Length (Types.all, Id)), 3,
                  "it carries the source length");
               Landin.Testing.Check
                 (Item, Landin.Checking.Array_Element (Types.all, Id)
                          = Landin.Types.U16,
                  "and the source element type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Count, 6, "module and local destinations were checked");
   end Inferred_Array_Bindings_Carry_Their_Source_Shape;

   --  D23: the written local array type gives the literal its exact shape and
   --  supplies one scalar context to every element expression.
   procedure Local_Array_Literal_Takes_Its_Written_Shape
     (Item : in out Landin.Testing.Context);

   procedure Local_Array_Literal_Takes_Its_Written_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "literal.ldn",
         "f: () -> none =" & LF
         & "    row: [3]u16 = [1, 2 + 3, 4]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the literal is accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Array_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array,
                  "the literal is a fixed array");
               Landin.Testing.Check_Equal
                 (Item,
                  Natural
                    (Landin.Checking.Array_Length
                       (Types.all, Of_Tree.all, Node)),
                  3, "it carries the written length");
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Array_Element
                    (Types.all, Of_Tree.all, Node) = Landin.Types.U16,
                  "it carries the written element type");

               for Position in
                 1 .. Landin.Syntax.Element_Count (Of_Tree.all, Node)
               loop
                  Landin.Testing.Check
                    (Item,
                     Landin.Checking.Type_Of
                       (Types.all, Of_Tree.all,
                        Landin.Syntax.Nth_Element
                          (Of_Tree.all, Node, Position)) = Landin.Types.U16,
                     "each element receives the written scalar context");
               end loop;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal (Item, Seen, 1, "one literal was checked");
   end Local_Array_Literal_Takes_Its_Written_Shape;

   --  D24: the written module array type gives the literal its exact shape,
   --  its element type is the scalar context for every element expression,
   --  and forward references to other module scalar bindings are admitted
   --  because [1740] makes a module a set.
   procedure Module_Array_Literal_Takes_Its_Written_Shape
     (Item : in out Landin.Testing.Context);

   procedure Module_Array_Literal_Takes_Its_Written_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "module.ldn",
         "mut buffer: [3]u32 = [base, base + 1, 12]" & LF
         & "base: u32 = 100" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "the module literal is accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Array_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array,
                  "the module literal is a fixed array");
               Landin.Testing.Check_Equal
                 (Item,
                  Natural
                    (Landin.Checking.Array_Length
                       (Types.all, Of_Tree.all, Node)),
                  3, "it carries the written length");
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Array_Element
                    (Types.all, Of_Tree.all, Node) = Landin.Types.U32,
                  "it carries the written element type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 1, "one module literal was checked");
   end Module_Array_Literal_Takes_Its_Written_Shape;

   --  D34: a nonzero written fixed-array type supplies the complete context
   --  for either spelling, at module scope and for a local.  A written count
   --  remains an assertion that the same contextual length was named.
   procedure Typed_Repetition_Takes_Its_Written_Shape
     (Item : in out Landin.Testing.Context);

   procedure Typed_Repetition_Takes_Its_Written_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "repetition.ldn",
         "seed: u64 = 0x123456789ABCDEF0" & LF
         & "counted: [3]u64 = [3 of seed]" & LF
         & "contextual: [2]u64 = [of seed + 1]" & LF
         & "f: () -> none =" & LF
         & "    local: [4]u64 = [of seed]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and local typed repetitions are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Array_Repetition
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array,
                  "the contextual repetition is a fixed array");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 3, "all three typed repetitions carry a shape");
   end Typed_Repetition_Takes_Its_Written_Shape;

   --  D36: only an explicitly typed local supplies the complete shape for a
   --  nonempty literal prefix followed by one repeated suffix expression.
   procedure Mixed_Repetition_Takes_Its_Typed_Written_Shape
     (Item : in out Landin.Testing.Context);

   procedure Mixed_Repetition_Takes_Its_Typed_Written_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "mixed-repetition.ldn",
         "module_row: [4]u16 = [1, 2 + 1, of 4]" & LF
         & "f: (first: u16, repeated: u16) -> none =" & LF
         & "    row: [4]u16 = [first, first + 1, of repeated]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "explicitly typed local and module mixed repetitions are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Mixed_Array_Repetition
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array
                  and then Landin.Checking.Array_Length
                    (Types.all, Of_Tree.all, Node) = 4
                  and then Landin.Checking.Array_Element
                    (Types.all, Of_Tree.all, Node) = Landin.Types.U16,
                  "the mixed repetition carries the written array shape");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both typed mixed repetitions carry a shape");
   end Mixed_Repetition_Takes_Its_Typed_Written_Shape;

   --  D37: a mutable fixed-array assignment place supplies the complete shape
   --  for a nonempty prefix followed by one repeated suffix expression.  Both
   --  local frame storage and module storage use that same contextual rule.
   procedure Mixed_Repetition_Assignment_Takes_Its_Destination_Shape
     (Item : in out Landin.Testing.Context);

   procedure Mixed_Repetition_Assignment_Takes_Its_Destination_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "mixed-assignment.ldn",
         "mut state: [3]u16" & LF
         & "f: (first: u16, repeated: u16) -> none =" & LF
         & "    mut row: [4]u16" & LF
         & "    row = [first, first + 1, of repeated]" & LF
         & "    state = [first, of repeated]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "local and module mixed-repetition assignments are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Mixed_Array_Repetition
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array
                  and then Landin.Checking.Array_Element
                    (Types.all, Of_Tree.all, Node) = Landin.Types.U16,
                  "the assignment gives the mixed form its element type");
               Landin.Testing.Check_Equal
                 (Item,
                  Natural
                    (Landin.Checking.Array_Length
                       (Types.all, Of_Tree.all, Node)),
                  (if Seen = 1 then 4 else 3),
                  "the mixed form carries its destination length");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both mixed assignments carry a shape");
   end Mixed_Repetition_Assignment_Takes_Its_Destination_Shape;

   --  D33: the written repetition count and its one scalar expression supply
   --  an inferred local's compact D17 shape.  A typed expression retains its
   --  type and an untyped integer receives [0200]'s default.
   procedure Inferred_Repetition_Carries_Its_Source_Shape
     (Item : in out Landin.Testing.Context);

   procedure Inferred_Repetition_Carries_Its_Source_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "repetition.ldn",
         "f: (seed: u16) -> none =" & LF
         & "    typed := [3 of seed]" & LF
         & "    defaulted := [2 of 1]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "both inferred repetitions are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Array_Repetition
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array,
                  "the repetition is recorded as a fixed array");

               if Seen = 1 then
                  Landin.Testing.Check
                    (Item,
                     Landin.Checking.Array_Length
                       (Types.all, Of_Tree.all, Node) = 3
                     and then Landin.Checking.Array_Element
                       (Types.all, Of_Tree.all, Node) = Landin.Types.U16,
                     "a typed scalar supplies the three-element shape");
               else
                  Landin.Testing.Check
                    (Item,
                     Landin.Checking.Array_Length
                       (Types.all, Of_Tree.all, Node) = 2
                     and then Landin.Checking.Array_Element
                       (Types.all, Of_Tree.all, Node)
                         = Landin.Types.Default_Integer,
                     "an untyped scalar supplies the default integer shape");
               end if;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both repetition nodes carry a shape");
   end Inferred_Repetition_Carries_Its_Source_Shape;

   --  D35: a counted repetition supplies the same inferred shape at module
   --  scope, where its scalar expression must also satisfy [1940].
   procedure Inferred_Module_Repetition_Carries_Its_Source_Shape
     (Item : in out Landin.Testing.Context);

   procedure Inferred_Module_Repetition_Carries_Its_Source_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "module-repetition.ldn",
         "seed: u16 = 40" & LF
         & "typed := [3 of seed + 2]" & LF
         & "defaulted := [2 of 1]" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "both inferred module repetitions are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Array_Repetition
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array,
                  "the module repetition is recorded as a fixed array");
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Array_Length
                    (Types.all, Of_Tree.all, Node)
                      = (if Seen = 1 then 3 else 2)
                  and then Landin.Checking.Array_Element
                    (Types.all, Of_Tree.all, Node)
                      = (if Seen = 1
                         then Landin.Types.U16
                         else Landin.Types.Default_Integer),
                  "the count and scalar supply the inferred module shape");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both module repetition nodes carry a shape");
   end Inferred_Module_Repetition_Carries_Its_Source_Shape;

   --  D39: an explicitly typed module scalar supplies `zeroed`'s scalar
   --  context, including when a type alias supplies the enabled scalar.
   procedure Module_Scalar_Zeroed_Takes_Its_Written_Type
     (Item : in out Landin.Testing.Context);

   procedure Module_Scalar_Zeroed_Takes_Its_Written_Type
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "module.ldn",
         "word: type = u32" & LF
         & "number: word = zeroed" & LF
         & "flag: bool = zeroed" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "typed module scalar zeroed initializers are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Zeroed_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = (if Seen = 1
                       then Landin.Types.U32
                       else Landin.Types.Bool),
                  "zeroed carries the resolved written scalar type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both scalar zeroed nodes were checked");
   end Module_Scalar_Zeroed_Takes_Its_Written_Type;

   --  D40: an explicitly typed local scalar supplies `zeroed`'s scalar
   --  context, including through an alias.  Reading both bindings also pins
   --  that their initializers make them definitely assigned.
   procedure Local_Scalar_Zeroed_Takes_Its_Written_Type
     (Item : in out Landin.Testing.Context);

   procedure Local_Scalar_Zeroed_Takes_Its_Written_Type
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "local.ldn",
         "word: type = u32" & LF
         & "f: () -> (result: u32) =" & LF
         & "    number: word = zeroed" & LF
         & "    flag: bool = zeroed" & LF
         & "    if flag then" & LF
         & "        result = 1" & LF
         & "    else" & LF
         & "        result = number" & LF
         & "    end if" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "typed local scalar zeroed initializers are accepted and assigned");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Zeroed_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = (if Seen = 1
                       then Landin.Types.U32
                       else Landin.Types.Bool),
                  "local zeroed carries the resolved written scalar type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both local scalar zeroed nodes were checked");
   end Local_Scalar_Zeroed_Takes_Its_Written_Type;

   --  D41: a mutable module scalar destination supplies `zeroed`'s scalar
   --  context, including when an alias supplies that destination type.
   procedure Module_Scalar_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context);

   procedure Module_Scalar_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "module-assignment.ldn",
         "word: type = u32" & LF
         & "mut number: word" & LF
         & "f: () -> none =" & LF
         & "    number = zeroed" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a module scalar destination gives zeroed its type");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Zeroed_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.U32,
                  "assigned zeroed carries the resolved destination type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 1, "the assigned zeroed node was checked");
   end Module_Scalar_Assignment_Gives_Zeroed_Its_Type;

   --  D41: assignment to a mutable local scalar also supplies `zeroed`'s
   --  resolved scalar type and establishes definite assignment.
   procedure Local_Scalar_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context);

   procedure Local_Scalar_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "local-assignment.ldn",
         "truth: type = bool" & LF
         & "f: () -> (result: bool) =" & LF
         & "    mut flag: truth" & LF
         & "    flag = zeroed" & LF
         & "    result = flag" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a local scalar destination types zeroed and becomes assigned");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Zeroed_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Bool,
                  "assigned zeroed carries the resolved local type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 1, "the local assigned zeroed node was checked");
   end Local_Scalar_Assignment_Gives_Zeroed_Its_Type;

   --  D43: a scalar named return supplies `zeroed`'s resolved type, and the
   --  ordinary assignment establishes the return place before `return`.
   procedure Named_Return_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context);

   procedure Named_Return_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "named-return-assignment.ldn",
         "word: type = u32" & LF
         & "f: () -> (result: word) =" & LF
         & "    result = zeroed" & LF
         & "    return" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a named return types zeroed and becomes assigned");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Zeroed_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.U32,
                  "zeroed carries the resolved named-return type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 1, "the named-return zeroed node was checked");
   end Named_Return_Assignment_Gives_Zeroed_Its_Type;

   --  D42: an ordinary mutable struct field supplies `zeroed`'s resolved
   --  scalar type, including when an alias names the field type.
   procedure Struct_Field_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context);

   procedure Struct_Field_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "field-assignment.ldn",
         "truth: type = bool" & LF
         & "flags: type = struct" & LF
         & "    ready: truth" & LF
         & "end flags" & LF
         & "mut state: flags" & LF
         & "f: () -> none =" & LF
         & "    state.ready = zeroed" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a mutable scalar field gives zeroed its type");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Zeroed_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Bool,
                  "field zeroed carries the resolved alias type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 1, "the field zeroed node was checked");
   end Struct_Field_Assignment_Gives_Zeroed_Its_Type;

   --  D42: a fixed-array element supplies `zeroed`'s resolved scalar element
   --  type, including when an alias names that element type.  D62 applies the
   --  same rule through a D48 array field on module and local storage.
   procedure Array_Element_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context);

   procedure Array_Element_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "element-assignment.ldn",
         "word: type = u32" & LF
         & "truth: type = bool" & LF
         & "holder: type = struct" & LF
         & "    flags: [1]truth" & LF
         & "    words: [2]word" & LF
         & "end holder" & LF
         & "mut row: [2]word" & LF
         & "mut state: holder" & LF
         & "f: () -> none =" & LF
         & "    mut local: holder" & LF
         & "    row[1] = zeroed" & LF
         & "    state.flags[0] = zeroed" & LF
         & "    local.words[0] = zeroed" & LF
         & "    _ = local.words[0]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "direct and array-field elements give zeroed their scalar type");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Zeroed_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = (if Seen = 2
                       then Landin.Types.Bool
                       else Landin.Types.U32),
                  "element zeroed carries the direct or field element type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 3, "all element zeroed nodes were checked");
   end Array_Element_Assignment_Gives_Zeroed_Its_Type;

   --  D49: the selected fixed-array field supplies both the contextual
   --  shape of `zeroed` and the whole-field assignment fact used by the
   --  computed read that follows it.
   procedure Array_Field_Assignment_Gives_Zeroed_Its_Shape
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Assignment_Gives_Zeroed_Its_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "array-field-zeroed.ldn",
         "word: type = u32" & LF
         & "holder: type = struct" & LF
         & "    row: [2]word" & LF
         & "end holder" & LF
         & "f: (at: usize) -> (result: word) =" & LF
         & "    mut local: holder" & LF
         & "    local.row = zeroed" & LF
         & "    result = local.row[at]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a local array field gives zeroed its shape and becomes complete");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Zeroed_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array
                  and then Landin.Checking.Array_Length
                    (Types.all, Of_Tree.all, Node) = 2
                  and then Landin.Checking.Array_Element
                    (Types.all, Of_Tree.all, Node) = Landin.Types.U32,
                  "field zeroed carries the resolved fixed-array shape");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 1, "the array-field zeroed node was checked");
   end Array_Field_Assignment_Gives_Zeroed_Its_Shape;

   --  D52 gives D29's literal the selected field's complete contextual
   --  shape.  The selection retains its declaration-order field identity;
   --  neither fact is a target byte offset.
   procedure Array_Field_Literals_Carry_Their_Destination_Shape
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Literals_Carry_Their_Destination_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "array-field-literals.ldn",
         "word: type = u32" & LF
         & "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]word" & LF
         & "end holder" & LF
         & "mut state: holder" & LF
         & "f: (at: usize) -> (result: word) =" & LF
         & "    state.row = [20, 22]" & LF
         & "    mut local: holder" & LF
         & "    local.row = [30, 12]" & LF
         & "    result = state.row[at] + local.row[at]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and local array fields accept contextual literals");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Assignment
            then
               declare
                  Target : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Target_Of (Of_Tree.all, Node);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  if Landin.Syntax.Kind (Of_Tree.all, Target)
                       = Landin.Syntax.Member_Selection
                    and then Landin.Syntax.Kind (Of_Tree.all, Value)
                               = Landin.Syntax.Array_Literal
                  then
                     Seen := Seen + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Target)
                            = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Target) = 2
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Target) = Landin.Types.U32
                        and then Landin.Checking.Field_Index
                          (Types.all, Of_Tree.all, Target) = 2,
                        "the selected destination carries field two's shape");
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Value)
                            = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Value) = 2
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Value) = Landin.Types.U32,
                        "the literal receives the selected field's shape");
                  end if;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both contextual field literals were checked");
   end Array_Field_Literals_Carry_Their_Destination_Shape;

   --  D53 gives D32's full repetition and D37's mixed repetition the
   --  selected field's complete context.  The field identity stays a
   --  declaration-order position rather than becoming a target offset.
   procedure Array_Field_Repetitions_Carry_Their_Destination_Shape
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Repetitions_Carry_Their_Destination_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "array-field-repetitions.ldn",
         "word: type = u32" & LF
         & "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [4]word" & LF
         & "end holder" & LF
         & "mut state: holder" & LF
         & "f: (at: usize) -> (result: word) =" & LF
         & "    state.row = [4 of 10]" & LF
         & "    state.row = [11, 12, of 13]" & LF
         & "    mut local: holder" & LF
         & "    local.row = [of 20]" & LF
         & "    local.row = [21, 22, of 23]" & LF
         & "    result = state.row[at] + local.row[at]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and local array fields accept both repetition forms");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Assignment
            then
               declare
                  Target : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Target_Of (Of_Tree.all, Node);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  if Landin.Syntax.Kind (Of_Tree.all, Target)
                       = Landin.Syntax.Member_Selection
                    and then Landin.Syntax.Kind (Of_Tree.all, Value)
                               in Landin.Syntax.Array_Repetition
                                | Landin.Syntax.Mixed_Array_Repetition
                  then
                     Seen := Seen + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Target)
                            = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Target) = 4
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Target) = Landin.Types.U32
                        and then Landin.Checking.Field_Index
                          (Types.all, Of_Tree.all, Target) = 2,
                        "the selected destination carries field two's shape");
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Value)
                            = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Value) = 4
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Value) = Landin.Types.U32,
                        "the repetition receives the selected field's shape");
                  end if;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 4, "all contextual field repetitions were checked");
   end Array_Field_Repetitions_Carry_Their_Destination_Shape;

   --  D54 admits the one aggregate expression context as soon as every
   --  field has an enabled copy representation.  Nominal identity stays on
   --  both names while D16 and D48 account for scalar and array fields.
   procedure Array_Bearing_Struct_Copy_Uses_Each_Field_Fact
     (Item : in out Landin.Testing.Context);

   procedure Array_Bearing_Struct_Copy_Uses_Each_Field_Fact
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "array-bearing-struct-copy.ldn",
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "    tail: u16" & LF
         & "end holder" & LF
         & "same: type = holder" & LF
         & "mut left: holder" & LF
         & "mut right: same" & LF
         & "f: (at: usize) -> (result: u32) =" & LF
         & "    right = left" & LF
         & "    mut source: same" & LF
         & "    source.tag = 1" & LF
         & "    source.row[0] = 20" & LF
         & "    source.row[1] = 22" & LF
         & "    source.tail = 3" & LF
         & "    mut destination: holder" & LF
         & "    destination = source" & LF
         & "    right = destination" & LF
         & "    destination = left" & LF
         & "    destination = destination" & LF
         & "    result = destination.row[at]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "whole copies cross module and local storage after complete reads");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Assignment
            then
               declare
                  Target : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Target_Of (Of_Tree.all, Node);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  if Landin.Checking.Type_Of
                       (Types.all, Of_Tree.all, Target)
                       = Landin.Types.Aggregate
                  then
                     Seen := Seen + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Value)
                            = Landin.Types.Aggregate
                        and then Landin.Checking.Nominal_Of
                          (Types.all, Of_Tree.all, Target)
                            = Landin.Checking.Nominal_Of
                                (Types.all, Of_Tree.all, Value),
                        "each whole copy keeps one nominal struct identity");
                  end if;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 5, "every whole aggregate assignment was checked");
   end Array_Bearing_Struct_Copy_Uses_Each_Field_Fact;

   --  D58 gives a whole mutable struct place D57's contextual zero image.
   --  Both storage classes carry the destination's nominal body, and the
   --  local clear supplies every D16/D48 field fact used by the later read.
   procedure Struct_Assignment_Gives_Zeroed_Its_Body
     (Item : in out Landin.Testing.Context);

   procedure Struct_Assignment_Gives_Zeroed_Its_Body
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "struct-zeroed-assignment.ldn",
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "    tail: u16" & LF
         & "end holder" & LF
         & "same: type = holder" & LF
         & "mut state: same" & LF
         & "f: (at: usize) -> (result: u32) =" & LF
         & "    mut local: holder" & LF
         & "    state = zeroed" & LF
         & "    local = zeroed" & LF
         & "    result = state.row[at] + local.row[at]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and local struct places accept zeroed and become complete");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Assignment
              and then Landin.Syntax.Kind
                (Of_Tree.all, Landin.Syntax.Value_Of (Of_Tree.all, Node))
                  = Landin.Syntax.Zeroed_Literal
            then
               declare
                  Place : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Target_Of (Of_Tree.all, Node);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  Seen := Seen + 1;
                  Landin.Testing.Check
                    (Item,
                     Landin.Checking.Type_Of
                       (Types.all, Of_Tree.all, Value)
                         = Landin.Types.Aggregate
                     and then Landin.Checking.Nominal_Of
                       (Types.all, Of_Tree.all, Value)
                         = Landin.Checking.Nominal_Of
                           (Types.all, Of_Tree.all, Place),
                     "zeroed carries its destination's nominal struct body");
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both whole struct zeroed assignments were checked");
   end Struct_Assignment_Gives_Zeroed_Its_Body;

   --  D55 gives a directly named whole struct D54's copy context; D57 gives
   --  `zeroed` the same written nominal context.  Each value node and binding
   --  keep the one body later layout and selection use.
   procedure Local_Struct_Initializer_Keeps_Its_Nominal_Source
     (Item : in out Landin.Testing.Context);

   procedure Local_Struct_Initializer_Keeps_Its_Nominal_Source
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "local-struct-initializers.ldn",
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "    tail: u16" & LF
         & "end holder" & LF
         & "same: type = holder" & LF
         & "state: holder" & LF
         & "f: (at: usize) -> (result: u32) =" & LF
         & "    mut source: same" & LF
         & "    source.tag = 1" & LF
         & "    source.row = zeroed" & LF
         & "    source.tail = 2" & LF
         & "    local: holder = source" & LF
         & "    aliased: same = local" & LF
         & "    snapshot: holder = state" & LF
         & "    blank: holder = zeroed" & LF
         & "    empty: same = zeroed" & LF
         & "    result = aliased.row[at] + snapshot.row[at]"
         & " + blank.row[at] + empty.row[at]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "storage names and zeroed initialize typed locals");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Id in Landin.Provenance.Declaration_Id'(1)
                   .. Landin.Provenance.Declaration_Id
                        (Landin.Resolution.Declaration_Count (Meanings.all))
         loop
            if Landin.Resolution.Sort_Of (Meanings.all, Id)
                 = Landin.Resolution.Local_Binding
              and then Landin.Checking.Type_Of (Types.all, Id)
                         = Landin.Types.Aggregate
            then
               declare
                  Node : constant Landin.Syntax.Node_Id :=
                    Landin.Resolution.Node_Of (Meanings.all, Id);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  if Value /= Landin.Syntax.No_Node then
                     Seen := Seen + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Value)
                            = Landin.Types.Aggregate
                        and then Landin.Checking.Nominal_Of (Types.all, Id)
                          = Landin.Checking.Nominal_Of
                              (Types.all, Of_Tree.all, Value),
                        "the initializer and local share one struct body");
                  end if;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 5,
         "five explicit local struct initializers were checked");
   end Local_Struct_Initializer_Keeps_Its_Nominal_Source;

   --  D59 gives the same written zero-image context to module bindings.
   --  Mutable, immutable and aliased spellings all carry one nominal body;
   --  lowering may then reuse D10's existing zero datum unchanged.
   procedure Module_Struct_Zeroed_Keeps_Its_Nominal_Body
     (Item : in out Landin.Testing.Context);

   procedure Module_Struct_Zeroed_Keeps_Its_Nominal_Body
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "module-struct-zeroed.ldn",
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "end holder" & LF
         & "same: type = holder" & LF
         & "state: holder = zeroed" & LF
         & "mut aliased: same = zeroed" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "typed module structs accept their explicit zero image");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Id in Landin.Provenance.Declaration_Id'(1)
                   .. Landin.Provenance.Declaration_Id
                        (Landin.Resolution.Declaration_Count (Meanings.all))
         loop
            if Landin.Resolution.Sort_Of (Meanings.all, Id)
                 = Landin.Resolution.Module_Binding
              and then Landin.Checking.Type_Of (Types.all, Id)
                         = Landin.Types.Aggregate
            then
               declare
                  Node : constant Landin.Syntax.Node_Id :=
                    Landin.Resolution.Node_Of (Meanings.all, Id);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  if Value /= Landin.Syntax.No_Node then
                     Seen := Seen + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Value)
                            = Landin.Types.Aggregate
                        and then Landin.Checking.Nominal_Of (Types.all, Id)
                          = Landin.Checking.Nominal_Of
                              (Types.all, Of_Tree.all, Value),
                        "the module value and datum share one struct body");
                  end if;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both module struct zero images were checked");
   end Module_Struct_Zeroed_Keeps_Its_Nominal_Body;

   --  D60/D61 follow a direct module-storage name across forward declarations
   --  and aliases while retaining [0710]'s one nominal body in typed and
   --  inferred destinations.  The source name remains contextual here.
   procedure Module_Struct_Image_Chains_Keep_Their_Nominal_Body
     (Item : in out Landin.Testing.Context);

   procedure Module_Struct_Image_Chains_Keep_Their_Nominal_Body
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "module-struct-images.ldn",
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "end holder" & LF
         & "same: type = holder" & LF
         & "mut first: same = later" & LF
         & "second: holder = first" & LF
         & "mut inferred := later" & LF
         & "typed_from_inferred: holder = inferred" & LF
         & "later: holder = zeroed" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module struct image chains are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Id in Landin.Provenance.Declaration_Id'(1)
                   .. Landin.Provenance.Declaration_Id
                        (Landin.Resolution.Declaration_Count (Meanings.all))
         loop
            if Landin.Resolution.Sort_Of (Meanings.all, Id)
                 = Landin.Resolution.Module_Binding
              and then Landin.Checking.Type_Of (Types.all, Id)
                         = Landin.Types.Aggregate
            then
               declare
                  Node : constant Landin.Syntax.Node_Id :=
                    Landin.Resolution.Node_Of (Meanings.all, Id);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  if Value /= Landin.Syntax.No_Node
                    and then Landin.Syntax.Kind (Of_Tree.all, Value)
                               = Landin.Syntax.Name_Reference
                  then
                     Seen := Seen + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Value)
                            = Landin.Types.Aggregate
                        and then Landin.Checking.Nominal_Of (Types.all, Id)
                          = Landin.Checking.Nominal_Of
                              (Types.all, Of_Tree.all, Value),
                        "each image source has the destination's body");
                  end if;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 4, "the four direct-name links were checked");
   end Module_Struct_Image_Chains_Keep_Their_Nominal_Body;

   --  D56 infers the same nominal body from a direct struct storage name.
   --  The inferred declaration must carry that identity before later
   --  selections, copies and lowering ask for its layout.
   procedure Inferred_Local_Struct_Keeps_Its_Nominal_Source
     (Item : in out Landin.Testing.Context);

   procedure Inferred_Local_Struct_Keeps_Its_Nominal_Source
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "inferred-local-struct-initializers.ldn",
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "    tail: u16" & LF
         & "end holder" & LF
         & "same: type = holder" & LF
         & "state: holder" & LF
         & "f: (at: usize) -> (result: u32) =" & LF
         & "    mut source: same" & LF
         & "    source.tag = 1" & LF
         & "    source.row = zeroed" & LF
         & "    source.tail = 2" & LF
         & "    local := source" & LF
         & "    aliased := local" & LF
         & "    snapshot := state" & LF
         & "    mut state := state" & LF
         & "    result = aliased.row[at] + snapshot.row[at]"
         & " + state.row[at]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and completed local sources infer local structs");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Id in Landin.Provenance.Declaration_Id'(1)
                   .. Landin.Provenance.Declaration_Id
                        (Landin.Resolution.Declaration_Count (Meanings.all))
         loop
            if Landin.Resolution.Sort_Of (Meanings.all, Id)
                 = Landin.Resolution.Local_Binding
              and then Landin.Checking.Type_Of (Types.all, Id)
                         = Landin.Types.Aggregate
            then
               declare
                  Node : constant Landin.Syntax.Node_Id :=
                    Landin.Resolution.Node_Of (Meanings.all, Id);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  if Value /= Landin.Syntax.No_Node
                    and then Landin.Syntax.Declared_Type
                               (Of_Tree.all, Node) = Landin.Syntax.No_Node
                  then
                     Seen := Seen + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Value)
                            = Landin.Types.Aggregate
                        and then Landin.Checking.Nominal_Of (Types.all, Id)
                          = Landin.Checking.Nominal_Of
                              (Types.all, Of_Tree.all, Value),
                        "the inferred local carries its source struct body");
                  end if;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 4,
         "four inferred local struct initializers were checked");
   end Inferred_Local_Struct_Keeps_Its_Nominal_Source;

   --  D50: a fixed-array field may supply or receive D20's complete copy.
   --  The source read uses the field-qualified whole-array fact established
   --  by D49 or an earlier copy, rather than D16's scalar-field bit.
   procedure Array_Field_Copy_Uses_Whole_Field_Facts
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Copy_Uses_Whole_Field_Facts
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "array-field-copy.ldn",
         "word: type = u32" & LF
         & "holder: type = struct" & LF
         & "    row: [2]word" & LF
         & "end holder" & LF
         & "f: (at: usize) -> (result: word) =" & LF
         & "    mut left: holder" & LF
         & "    mut right: holder" & LF
         & "    mut words: [2]word" & LF
         & "    left.row = zeroed" & LF
         & "    right.row = left.row" & LF
         & "    words = right.row" & LF
         & "    right.row = words" & LF
         & "    result = right.row[at]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "field and direct-array copy endpoints are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Member_Selection
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array
                  and then Landin.Checking.Array_Length
                    (Types.all, Of_Tree.all, Node) = 2
                  and then Landin.Checking.Array_Element
                    (Types.all, Of_Tree.all, Node) = Landin.Types.U32,
                  "each contextual field endpoint carries one array shape");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 6, "six contextual array-field selections were checked");
   end Array_Field_Copy_Uses_Whole_Field_Facts;

   --  D51 gives a selected fixed-array field D21's initializer context for
   --  a local binding; D70 admits the same copied-image context at module
   --  scope.  Written and inferred destinations carry the field shape
   --  without making the selection a general value.
   procedure Array_Field_Initializers_Carry_Their_Source_Shape
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Initializers_Carry_Their_Source_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "array-field-initializers.ldn",
         "word: type = u32" & LF
         & "holder: type = struct" & LF
         & "    row: [2]word" & LF
         & "end holder" & LF
         & "state: holder" & LF
         & "module_typed: [2]word = state.row" & LF
         & "module_inferred := state.row" & LF
         & "f: () -> none =" & LF
         & "    mut local: holder" & LF
         & "    local.row = zeroed" & LF
         & "    local_typed: [2]word = local.row" & LF
         & "    local_inferred := local.row" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "typed and inferred bindings accept either field source");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Id in Landin.Provenance.Declaration_Id'(1)
                   .. Landin.Provenance.Declaration_Id
                        (Landin.Resolution.Declaration_Count (Meanings.all))
         loop
            if Landin.Resolution.Sort_Of (Meanings.all, Id)
                 in Landin.Resolution.Local_Binding
                    | Landin.Resolution.Module_Binding
            then
               declare
                  Node : constant Landin.Syntax.Node_Id :=
                    Landin.Resolution.Node_Of (Meanings.all, Id);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  if Value /= Landin.Syntax.No_Node
                    and then Landin.Syntax.Kind (Of_Tree.all, Value)
                               = Landin.Syntax.Member_Selection
                  then
                     Seen := Seen + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of (Types.all, Id)
                          = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Id) = 2
                        and then Landin.Checking.Array_Element
                          (Types.all, Id) = Landin.Types.U32
                        and then Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Value)
                            = Landin.Types.Fixed_Array,
                        "the binding and contextual selection share a shape");
                  end if;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 4, "four contextual field initializers were checked");
   end Array_Field_Initializers_Carry_Their_Source_Shape;

   --  [0460]/[0480]: integer-to-pointer conversion uses the target's usize,
   --  not the host's.  A nonzero u64 whose low 32 bits are zero is therefore
   --  the reserved null carrier on Synthetic_32, while the next address is
   --  still a nonnull pointer value.
   procedure Pointer_Construction_Folds_To_Target_Usize
     (Item : in out Landin.Testing.Context);

   procedure Pointer_Construction_Folds_To_Target_Usize
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Address (Address : String; Accepted : Boolean);

      procedure Check_Address (Address : String; Accepted : Boolean) is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Synthetic_32);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source
           (Work, "pointer-width.ldn",
            "address: u64 = " & Address & LF
            & "f: () -> none =" & LF
            & "    pointer: ptr u8 = ptr(address)" & LF
            & "    _ = pointer" & LF
            & "end f" & LF);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);

         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
            Landin.Testing.Check
              (Item,
               Landin.Stages.Failed (Work) /= Accepted
                 and then
                   (if Accepted then
                       Landin.Diagnostics.Count (Reports) = 0
                    else
                       Landin.Diagnostics.Count (Reports) = 1
                       and then Landin.Diagnostics.Code
                         (Landin.Diagnostics.Get (Reports, 1)) = "L0301"
                       and then Landin.Diagnostics.Message
                         (Landin.Diagnostics.Primary
                            (Landin.Diagnostics.Get (Reports, 1))) =
                              "a pointer cannot be constructed from"
                              & " a known zero address"),
               "pointer construction folds after target-width conversion");
         end;
      end Check_Address;
   begin
      Check_Address ("4294967296", False);
      Check_Address ("4294967297", True);
   end Pointer_Construction_Folds_To_Target_Usize;

   --  D18: an array may occupy every byte a target's `usize` can name, and
   --  not one beyond it.  The same 2**32-byte array therefore belongs to a
   --  64-bit target and is refused by a 32-bit one; neither answer comes from
   --  the host running this test.
   procedure Array_Extent_Follows_Usize
     (Item : in out Landin.Testing.Context);

   procedure Struct_Array_Field_Extent_Follows_Usize
     (Item : in out Landin.Testing.Context);

   procedure Struct_Array_Field_Storage_Classes_Are_Enabled
     (Item : in out Landin.Testing.Context);

   procedure Array_Extent_Follows_Usize
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Target
        (Facts    : Landin.Targets.Target_Facts;
         Length   : String;
         Element  : String;
         Accepted : Boolean);

      procedure Check_Target
        (Facts    : Landin.Targets.Target_Facts;
         Length   : String;
         Element  : String;
         Accepted : Boolean)
      is
         Work  : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Order : Landin.Stages.Pipeline;
         Ran   : Natural;
         Src   : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source
           (Work, "extent.ldn",
            "huge: type = [" & Length & "]" & Element & LF);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);

         Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
         Landin.Testing.Check
           (Item, Landin.Stages.Failed (Work) /= Accepted,
            "the array extent follows the target's usize");
      end Check_Target;
   begin
      Check_Target
        (Landin.Targets.Synthetic_32, "4294967295", "u8", True);
      Check_Target
        (Landin.Targets.Synthetic_32, "2147483648", "u16", False);
      Check_Target
        (Landin.Targets.Linux_X86_64, "2147483648", "u16", True);
   end Array_Extent_Follows_Usize;

   --  D45: a field that fits alone may leave no target `usize` room for
   --  the field after it.  The same declaration therefore fits the 64-bit
   --  description and is refused by the synthetic 32-bit one.
   procedure Struct_Array_Field_Extent_Follows_Usize
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Target
        (Facts    : Landin.Targets.Target_Facts;
         Accepted : Boolean);

      procedure Check_Target
        (Facts    : Landin.Targets.Target_Facts;
         Accepted : Boolean)
      is
         Work  : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Order : Landin.Stages.Pipeline;
         Ran   : Natural;
         Src   : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source
           (Work, "struct-extent.ldn",
            "bounded: type = struct" & LF
            & "    bytes: [4294967295]u8" & LF
            & "    tail: u8" & LF
            & "end bounded" & LF
            & "answer: usize = sizeof bounded" & LF);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);

         Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
         Landin.Testing.Check
           (Item, Landin.Stages.Failed (Work) /= Accepted,
            "the complete struct extent follows the target's usize");
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Synthetic_32, False);
      Check_Target (Landin.Targets.Linux_X86_64, True);
   end Struct_Array_Field_Extent_Follows_Usize;

   --  D47 adds a target-neutral frame shape for the same laid-out type D46
   --  admitted as zeroed module state.  Both declaration-only storage
   --  classes are enabled without forming a whole aggregate value.
   procedure Struct_Array_Field_Storage_Classes_Are_Enabled
     (Item : in out Landin.Testing.Context)
   is
      Prefix : constant String :=
        "holder: type = struct" & LF
        & "    row: [2]u32" & LF
        & "    tail: u8" & LF
        & "end holder" & LF;

      procedure Check_Source (Source : String; Accepted : Boolean);

      procedure Check_Source (Source : String; Accepted : Boolean) is
         Work  : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran   : Natural;
         Src   : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source (Work, "storage.ldn", Source);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);

         Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
         Landin.Testing.Check
           (Item, Landin.Stages.Failed (Work) /= Accepted,
            "both declaration-only storage classes accept the shape");
      end Check_Source;
   begin
      Check_Source (Prefix & "mut state: holder" & LF, True);
      Check_Source
        (Prefix
         & "f: () -> none =" & LF
         & "    mut state: holder" & LF
         & "end f" & LF,
         True);
   end Struct_Array_Field_Storage_Classes_Are_Enabled;

   --  D64/D66--D71 carry one nominal body on the contextual literal, record
   --  each source label as a declaration-order field identity, and give each
   --  module array label its field's complete static shape.
   procedure Struct_Literals_Carry_Body_And_Field_Identities
     (Item : in out Landin.Testing.Context);

   procedure Struct_Literals_Carry_Body_And_Field_Identities
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "struct-literals.ldn",
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]usize" & LF
         & "    ready: bool" & LF
         & "    tail: u16" & LF
         & "    repeated: [2]u8" & LF
         & "    mixed: [3]u16" & LF
         & "end holder" & LF
         & "image: holder = (ready: true, row: row_source, tail: 11,"
         & " tag: 2, repeated: [of 7], mixed: [17, of 19])" & LF
         & "row_source: [2]usize = [8, 9]" & LF
         & "mut state: holder" & LF
         & "f: () -> none =" & LF
         & "    local: holder = (ready: true, tail: 5, tag: 3,"
         & " of zeroed)" & LF
         & "    state = (tail: 7, tag: 4, ready: false, of zeroed)" & LF
         & "    contextual: holder = (row: [8, 9], ready: zeroed,"
         & " tag: 6, tail: 10, repeated: [2 of 7],"
         & " mixed: [17, of 19])" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "typed module, local and whole-assignment literals are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Struct_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Aggregate
                  and then Landin.Checking.Nominal_Of
                    (Types.all, Of_Tree.all, Node)
                      /= Landin.Checking.No_Nominal_Type,
                  "the literal carries its contextual nominal body");
               Landin.Testing.Check_Equal
                 (Item,
                  Landin.Checking.Field_Index
                    (Types.all, Of_Tree.all,
                     Landin.Syntax.Nth_Field_Value
                       (Of_Tree.all, Node, 1)),
                  (case Seen is
                      when 1 | 2 => 3,
                      when 3 => 4,
                      when others => 2),
                  "the first written label keeps its layout identity");
               Landin.Testing.Check_Equal
                 (Item,
                  Landin.Checking.Field_Index
                    (Types.all, Of_Tree.all,
                     Landin.Syntax.Nth_Field_Value
                       (Of_Tree.all, Node, 2)),
                  (case Seen is
                      when 1 => 2,
                      when 2 => 4,
                      when 3 => 1,
                      when others => 3),
                  "the second written label keeps its layout identity");

               if Seen = 1 then
                  declare
                     Row : constant Landin.Syntax.Node_Id :=
                       Landin.Syntax.Value_Of
                         (Of_Tree.all,
                          Landin.Syntax.Nth_Field_Value
                            (Of_Tree.all, Node, 2));
                  begin
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Row)
                            = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Row) = 2
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Row)
                            = Landin.Types.Usize,
                        "the direct static array label carries field two's"
                        & " shape");
                  end;
                  declare
                     Repeated : constant Landin.Syntax.Node_Id :=
                       Landin.Syntax.Value_Of
                         (Of_Tree.all,
                          Landin.Syntax.Nth_Field_Value
                            (Of_Tree.all, Node, 5));
                     Mixed : constant Landin.Syntax.Node_Id :=
                       Landin.Syntax.Value_Of
                         (Of_Tree.all,
                          Landin.Syntax.Nth_Field_Value
                            (Of_Tree.all, Node, 6));
                  begin
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Repeated)
                            = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Repeated) = 2
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Repeated) = Landin.Types.U8
                        and then Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Mixed)
                            = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Mixed) = 3
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Mixed)
                            = Landin.Types.U16,
                        "static repetitions carry their field shapes");
                  end;
               elsif Seen = 4 then
                  declare
                     Row : constant Landin.Syntax.Node_Id :=
                       Landin.Syntax.Value_Of
                         (Of_Tree.all,
                          Landin.Syntax.Nth_Field_Value
                            (Of_Tree.all, Node, 1));
                     Ready : constant Landin.Syntax.Node_Id :=
                       Landin.Syntax.Value_Of
                         (Of_Tree.all,
                          Landin.Syntax.Nth_Field_Value
                            (Of_Tree.all, Node, 2));
                  begin
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Row)
                            = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Row) = 2
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Row)
                            = Landin.Types.Usize,
                        "the array label carries field two's whole shape");
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Ready)
                            = Landin.Types.Bool,
                        "the zeroed label carries field three's scalar type");
                  end;
               end if;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 4, "all contextual struct literals were checked");
   end Struct_Literals_Carry_Body_And_Field_Identities;

   --  D72 keeps a labelled application neutral until resolution selects its
   --  construction projection, then carries the type's nominal body into
   --  both typed and inferred contexts.
   procedure Constructions_Carry_Their_Nominal_Body
     (Item : in out Landin.Testing.Context);

   procedure Constructions_Carry_Their_Nominal_Body
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "constructions.ldn",
         "point: type = struct" & LF
         & "    x: i32" & LF
         & "    y: i32" & LF
         & "end point" & LF
         & "same: type = point" & LF
         & "origin := point(x: 1, y: 2)" & LF
         & "typed: point = same(x: 3, y: 4)" & LF
         & "mut state: point" & LF
         & "f: () -> none =" & LF
         & "    local := point(x: 5, y: 6)" & LF
         & "    typed_local: same = point(x: 7, y: 8)" & LF
         & "    state = same(x: 9, y: 10)" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "typed, inferred, module, local and assignment construction pass");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Labeled_Application
              and then Landin.Resolution.Class_Of
                (Meanings.all, Of_Tree.all, Node)
                  = Landin.Resolution.Type_Construction
            then
               Seen := Seen + 1;
               declare
                  Nominal : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Callee_Of (Of_Tree.all, Node);
               begin
                  Landin.Testing.Check
                    (Item,
                     Landin.Syntax.Kind (Of_Tree.all, Nominal)
                       = Landin.Syntax.Name_Reference,
                     "construction keeps its leading name neutral");
                  Landin.Testing.Check
                    (Item,
                     Landin.Checking.Type_Of
                       (Types.all, Of_Tree.all, Node)
                         = Landin.Types.Aggregate
                     and then Landin.Resolution.Verdict_Of
                       (Meanings.all, Of_Tree.all, Nominal)
                         = Landin.Resolution.Bound
                     and then Landin.Checking.Nominal_Of
                       (Types.all, Of_Tree.all, Node)
                         /= Landin.Checking.No_Nominal_Type,
                     "the construction carries its resolved nominal body");
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 5, "all construction contexts were checked");
   end Constructions_Carry_Their_Nominal_Body;

   --  D71 gives a selected module struct array field the static label's D17
   --  context without making the selection a general value.
   procedure Module_Struct_Field_Image_Carries_Source_Shape
     (Item : in out Landin.Testing.Context);

   procedure Module_Struct_Field_Image_Carries_Source_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "selected-field-image.ldn",
         "word: type = u16" & LF
         & "holder: type = struct" & LF
         & "    row: [2]word" & LF
         & "end holder" & LF
         & "copy: holder = (row: source.row)" & LF
         & "source: holder = (row: [11, 13])" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a selected field supplies a labelled module image");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Member_Selection
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array
                  and then Landin.Checking.Array_Length
                    (Types.all, Of_Tree.all, Node) = 2
                  and then Landin.Checking.Array_Element
                    (Types.all, Of_Tree.all, Node) = Landin.Types.U16
                  and then Landin.Checking.Field_Index
                    (Types.all, Of_Tree.all, Node) = 1,
                  "the selected source carries its field identity and shape");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 1, "one selected field image was checked");
   end Module_Struct_Field_Image_Carries_Source_Shape;

   --  D124 carries one complete scalar or stored shape onto the control
   --  node itself, including through a nested bare block.  Lowering can then
   --  allocate its join without rediscovering source syntax.
   procedure Control_Expression_Values_Carry_Their_Shapes
     (Item : in out Landin.Testing.Context);

   procedure Control_Expression_Values_Carry_Their_Shapes
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Scalars, Functions, Arrays, Aggregates : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "control-shapes.ldn",
         "point: type = struct" & LF
         & "    x: i32" & LF
         & "    y: i32" & LF
         & "end point" & LF
         & "unary: type = (value: i32) -> (result: i32)" & LF
         & "increment: (value: i32) -> (result: i32) =" & LF
         & "    value + 1" & LF
         & "end increment" & LF
         & "identity: (value: i32) -> (result: i32) =" & LF
         & "    value" & LF
         & "end identity" & LF
         & "make_function: (left: bool) -> (result: unary) =" & LF
         & "    if left then increment else begin identity end end if" & LF
         & "end make_function" & LF
         & "make_point: (left: bool) -> (result: point) =" & LF
         & "    if left then" & LF
         & "        point(x: 19, y: 23)" & LF
         & "    else" & LF
         & "        begin" & LF
         & "            point(x: 21, y: 21)" & LF
         & "        end" & LF
         & "    end if" & LF
         & "end make_point" & LF
         & "make_row: (left: bool) -> (result: [2]u16) =" & LF
         & "    if left then [11, 13] else [17, 19] end if" & LF
         & "end make_row" & LF
         & "make_scalar: (left: bool) -> (result: i32) =" & LF
         & "    if left then begin 19 + 23 end else 42 end if" & LF
         & "end make_scalar" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "scalar, function, fixed-array and nominal controls are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 in Landin.Syntax.If_Statement | Landin.Syntax.Bare_Block
            then
               case Landin.Checking.Type_Of
                 (Types.all, Of_Tree.all, Node)
               is
                  when Landin.Types.Aggregate =>
                     Aggregates := Aggregates + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Nominal_Of
                          (Types.all, Of_Tree.all, Node)
                            /= Landin.Checking.No_Nominal_Type,
                        "an aggregate control node keeps nominal identity");
                  when Landin.Types.Fixed_Array =>
                     Arrays := Arrays + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Node) = 2
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Node) = Landin.Types.U16,
                        "an array control node keeps length and element");
                  when Landin.Types.Function_Value =>
                     Functions := Functions + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Signature_Of
                          (Types.all, Of_Tree.all, Node)
                            /= Landin.Checking.No_Signature,
                        "a function control node keeps its signature");
                  when Landin.Types.I32 =>
                     Scalars := Scalars + 1;
                  when others =>
                     Landin.Testing.Fail
                       (Item, "a control node lost its contextual type");
               end case;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Aggregates, 2,
         "the aggregate if and its nested bare block carry identity");
      Landin.Testing.Check_Equal
        (Item, Arrays, 1, "the array if carries one structural shape");
      Landin.Testing.Check_Equal
        (Item, Functions, 2,
         "the function if and its nested bare block carry a signature");
      Landin.Testing.Check_Equal
        (Item, Scalars, 2,
         "the scalar if and its nested bare block carry i32");
   end Control_Expression_Values_Carry_Their_Shapes;

   --  The flow pass is part of checking's stage.  These paired programs
   --  distinguish a return-compatible edge from the fallthrough state: an
   --  assignment on the surviving edge is retained, while one made only on
   --  the returned edge cannot be borrowed afterward.
   procedure Control_Edges_Merge_Only_Fallthrough
     (Item : in out Landin.Testing.Context);

   procedure Control_Edges_Merge_Only_Fallthrough
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Source (Text : String; Accepted : Boolean);

      procedure Check_Source (Text : String; Accepted : Boolean) is
         Work  : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran   : Natural;
         Src   : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source (Work, "control-edges.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         Landin.Testing.Check_Equal (Item, Ran, 4, "the flow checker ran");
         Landin.Testing.Check
           (Item, Landin.Stages.Failed (Work) /= Accepted,
            "only fallthrough assignment facts reach the following read");
      end Check_Source;

      Prefix : constant String :=
        "f: (condition: bool) -> (result: i32) =" & LF
        & "    mut local: i32" & LF
        & "    _ = if condition then" & LF;
   begin
      Check_Source
        (Prefix
         & "        result = 41" & LF
         & "        return" & LF
         & "    else" & LF
         & "        local = 42" & LF
         & "        0" & LF
         & "    end if" & LF
         & "    result = local" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        (Prefix
         & "        local = 42" & LF
         & "        result = 41" & LF
         & "        return" & LF
         & "    else" & LF
         & "        0" & LF
         & "    end if" & LF
         & "    result = local" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("f: (condition: bool) -> (result: i32) =" & LF
         & "    mut local: i32" & LF
         & "    _ = condition and begin" & LF
         & "        local = 42" & LF
         & "        true" & LF
         & "    end" & LF
         & "    result = local" & LF
         & "end f" & LF,
         Accepted => False);
   end Control_Edges_Merge_Only_Fallthrough;

   --  R4.91: runtime calls carry consumption and failure edges through
   --  enclosing expressions; measurement and callback bodies stay unevaluated.
   procedure Fresh_Bindings_Reset_Flow_Facts
     (Item : in out Landin.Testing.Context);

   procedure Fresh_Bindings_Reset_Flow_Facts
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Source
        (Label, Text : String; Accepted : Boolean;
         Code : String := "L0302");

      procedure Check_Source
        (Label, Text : String; Accepted : Boolean;
         Code : String := "L0302")
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source (Work, "fresh-bindings.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check_Equal (Item, Ran, 4, Label & " reaches flow");
            Landin.Testing.Check
              (Item, Landin.Stages.Failed (Work) /= Accepted
                 and then
                   (if Accepted then Landin.Diagnostics.Count (Reports) = 0
                    else Landin.Diagnostics.Count (Reports) = 1
                      and then Landin.Diagnostics.Code
                        (Landin.Diagnostics.Get (Reports, 1)) = Code),
               Label & " retains its exact assignment verdict");
         end;
      end Check_Source;

   begin
      Check_Source
        ("fresh initialized scalar",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "while keep do" & LF
         & "value: i32 = 42" & LF
         & "consume(value)" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("fresh consumed field",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "while keep do" & LF
         & "value: box = (value: 42)" & LF
         & "consume(value.value)" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("fresh consumed nested field",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "while keep do" & LF
         & "value: outer = (child: (value: 42))" & LF
         & "consume(value.child.value)" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("fresh consumed element",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "while keep do" & LF
         & "value: [2]i32 = [1, 2]" & LF
         & "consume(value[0])" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("fresh consumed element field",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "while keep do" & LF
         & "value: [2]box = [(value: 1), (value: 2)]" & LF
         & "consume(value[0].value)" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("fresh destructured results",
         "pair: () -> (value: i32, other: i32) =" & LF
         & "value = 42 other = 0 end pair" & LF
         & "f: (keep: bool) -> none =" & LF
         & "while keep do" & LF
         & "(value: part, other: rest) := pair()" & LF
         & "_ = part + rest" & LF
         & "end while end f" & LF,
         Accepted => True);
      Check_Source
        ("destructured sink restriction is preserved",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "pair: () -> (value: i32, other: i32) =" & LF
         & "value = 42 other = 0 end pair" & LF
         & "f: (keep: bool) -> none =" & LF
         & "while keep do" & LF
         & "(value: part, other: rest) := pair()" & LF
         & "consume(part)" & LF
         & "end while end f" & LF,
         Accepted => False, Code => "L0301");
      Check_Source
        ("fresh condition binding",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "while ready: bool = keep do" & LF
         & "consume_bool(ready)" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("fresh arm binding",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "while keep do" & LF
         & "if ready: bool = keep then" & LF
         & "consume_bool(ready)" & LF
         & "end if" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("fresh range element",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "for value in 0 ..< 2 do" & LF
         & "consume(value)" & LF
         & "end for" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("fresh array element",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (values: [2]i32) -> none =" & LF
         & "for value, index in values do" & LF
         & "consume(value)" & LF
         & "end for" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("fresh assignment",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "while keep do" & LF
         & "mut value: i32" & LF
         & "value = 42" & LF
         & "consume(value)" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("fresh unassigned scalar",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "while keep do" & LF
         & "mut value: i32" & LF
         & "_ = value" & LF
         & "value = 42" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("fresh unassigned field",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "while keep do" & LF
         & "mut value: box" & LF
         & "_ = value.value" & LF
         & "value.value = 42" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("fresh unassigned element",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "while keep do" & LF
         & "mut value: [2]i32" & LF
         & "_ = value[0]" & LF
         & "value[0] = 42" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("outer consumption persists",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "value: i32 = 42" & LF
         & "while keep do" & LF
         & "fresh: i32 = 42" & LF
         & "_ = fresh" & LF
         & "consume(value)" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("initializer reads consumed outer",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "value: i32 = 42" & LF
         & "consume(value)" & LF
         & "while keep do" & LF
         & "value: i32 = value" & LF
         & "_ = value" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("continue reaches fresh binding",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "while keep do" & LF
         & "value: i32 = 42" & LF
         & "consume(value)" & LF
         & "continue" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("repeat read stays dead",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "while keep do" & LF
         & "value: i32 = 42" & LF
         & "consume(value)" & LF
         & "_ = value" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("inner loop retains outer instance",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "while keep do" & LF
         & "value: i32 = 42" & LF
         & "while keep do" & LF
         & "consume(value)" & LF
         & "end while" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("initializer effects persist",
         "consume: (sink value: i32) -> none = end consume" & LF
         & "consume_bool: (sink value: bool) -> none = end consume_bool" & LF
         & "box: type = struct value: i32 end box" & LF
         & "outer: type = struct child: box end outer" & LF
         & "f: (keep: bool) -> none =" & LF
         & "other: i32 = 42" & LF
         & "while keep do" & LF
         & "value: i32 = begin consume(other) 42 end" & LF
         & "_ = value" & LF
         & "end while" & LF
         & "end f" & LF,
         Accepted => False);
   end Fresh_Bindings_Reset_Flow_Facts;

   procedure Nested_Calls_Retain_Flow_Effects
     (Item : in out Landin.Testing.Context);

   procedure Nested_Calls_Retain_Flow_Effects
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Source
        (Label, Text : String; Accepted : Boolean);

      procedure Check_Source
        (Label, Text : String; Accepted : Boolean)
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source (Work, "nested-flow.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check_Equal (Item, Ran, 4, Label & " reaches flow");
            Landin.Testing.Check
              (Item, Landin.Stages.Failed (Work) /= Accepted
                 and then
                   (if Accepted then Landin.Diagnostics.Count (Reports) = 0
                    else Landin.Diagnostics.Count (Reports) = 1
                      and then Landin.Diagnostics.Code
                        (Landin.Diagnostics.Get (Reports, 1)) = "L0302"),
               Label & " retains its exact assignment verdict");
         end;
      end Check_Source;

      Prefix : constant String :=
        "unavailable: atom" & LF
         & "box: type = struct value: i32 end box" & LF
         & "consume: (sink value: i32) -> (r: i32) =" & LF
         & "    r = value end consume" & LF
         & "use: (value: i32, other: i32) -> none = end use" & LF
         & "observe: (value: i32) -> none = end observe" & LF
         & "restore: (inout value: i32) -> none = value = 7 end restore" & LF
         & "fallible: (sink value: i32) -> (r: i32) ! unavailable =" & LF
         & "    fail unavailable when value == 0" & LF
         & "    r = value" & LF
         & "end fallible" & LF
         & "slice_consumer: (sink view: []i32) -> none =" & LF
         & "end slice_consumer" & LF
         & "holder: type = struct view: []i32 end holder" & LF;
   begin
      Check_Source
        ("labelled read", Prefix
         & "f: () -> (r: i32) =" & LF
         & "later: i32" & LF
         & "use(value: 1, other: later)" & LF
         & "r = 0" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("labelled initialized", Prefix
         & "f: () -> (r: i32) =" & LF
         & "later: i32 = 2" & LF
         & "use(value: 1, other: later)" & LF
         & "r = 0" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("labelled sink", Prefix
         & "f: () -> (r: i32) =" & LF
         & "mut v: i32 = 1" & LF
         & "_ = consume(value: v)" & LF
         & "r = v" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("labelled sink statement", Prefix
         & "take: (sink value: i32, tag: i32) -> none = end take" & LF
         & "f: () -> (r: i32) =" & LF
         & "mut v: i32 = 1" & LF
         & "take(tag: 0, value: v)" & LF
         & "r = v" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("discarded sink", Prefix
         & "f: () -> (r: i32) =" & LF
         & "mut v: i32 = 1" & LF
         & "_ = consume(v)" & LF
         & "r = v" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("binary sink", Prefix
         & "f: () -> (r: i32) =" & LF
         & "mut v: i32 = 1" & LF
         & "n: i32 = 1 + consume(v)" & LF
         & "r = v + n" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("argument order", Prefix
         & "f: () -> (r: i32) =" & LF
         & "mut v: i32 = 1" & LF
         & "use(consume(v), v)" & LF
         & "r = 0" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("labelled argument order", Prefix
         & "f: () -> (r: i32) =" & LF
         & "mut v: i32 = 1" & LF
         & "use(other: consume(v), value: v)" & LF
         & "r = 0" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("array element sink", Prefix
         & "f: () -> (r: i32) =" & LF
         & "mut v: i32 = 1" & LF
         & "a: [1]i32 = [consume(v)]" & LF
         & "r = v" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("constructed field sink", Prefix
         & "f: () -> (r: i32) =" & LF
         & "mut v: i32 = 1" & LF
         & "b: box = (value: consume(v))" & LF
         & "r = v" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("short circuit sink", Prefix
         & "f: (flag: bool) -> (r: bool) =" & LF
         & "mut v: i32 = 1" & LF
         & "r = flag and (consume(v) == 0)" & LF
         & "_ = v" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("restored nested sink", Prefix
         & "f: () -> (r: i32) =" & LF
         & "mut v: i32 = 1" & LF
         & "_ = 1 + consume(v)" & LF
         & "v = 7" & LF
         & "r = v" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("measured literal does not consume", Prefix
         & "f: () -> (r: i32) =" & LF
         & "mut v: i32 = 1" & LF
         & "r = i32(lenof ([consume(v)])) + v" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("measured literal does not read", Prefix
         & "f: () -> (r: i32) =" & LF
         & "v: i32" & LF
         & "r = i32(lenof ([consume(v)]))" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("fixed length does not read", Prefix
         & "f: () -> (r: i32) =" & LF
         & "a: [2]i32" & LF
         & "r = i32(lenof a)" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("slice length reads", Prefix
         & "f: () -> (r: i32) =" & LF
         & "s: []i32" & LF
         & "r = i32(lenof s)" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("slice length after sink", Prefix
         & "f: (s: []i32) -> (r: i32) =" & LF
         & "slice_consumer(s)" & LF
         & "r = i32(lenof s)" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("slice index after sink", Prefix
         & "f: (s: []i32) -> (r: i32) =" & LF
         & "slice_consumer(s)" & LF
         & "r = s[0]" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("nested try restores only success", Prefix
         & "f: (inout v: i32) -> none ! unavailable =" & LF
         & "_ = 1 + try fallible(v)" & LF
         & "v = 7" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("nested try undo restores", Prefix
         & "f: (inout v: i32) -> none ! unavailable =" & LF
         & "undo observe(begin v = 7 0 end)" & LF
         & "_ = 1 + try fallible(v)" & LF
         & "v = 7" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("nested try undo reads", Prefix
         & "f: (v: i32) -> (r: i32) ! unavailable =" & LF
         & "mut later: i32" & LF
         & "undo observe(later)" & LF
         & "r = 1 + try fallible(v)" & LF
         & "later = 7" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("index sink", Prefix
         & "f: () -> (r: i32) =" & LF
         & "mut v: i32 = 0" & LF
         & "a: [1]i32 = [42]" & LF
         & "_ = a[usize(consume(v))]" & LF
         & "r = v" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("indexed field sink", Prefix
         & "f: () -> (r: i32) =" & LF
         & "mut v: i32 = 0" & LF
         & "mut a: [1]box = [box(value: 42)]" & LF
         & "_ = a[usize(consume(v))].value" & LF
         & "r = v" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("slice receiver sink", Prefix
         & "f: (s: []i32) -> (r: i32) =" & LF
         & "mut v: i32 = 0" & LF
         & "a: [1]holder = [holder(view: s)]" & LF
         & "_ = a[usize(consume(v))].view[0]" & LF
         & "r = v" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("anonymous body checked separately", Prefix
         & "f: () -> (r: i32) =" & LF
         & "cb: () -> (r: i32) = () -> (r: i32) =" & LF
         & "mut v: i32 = 1" & LF
         & "r = consume(v)" & LF
         & "end" & LF
         & "r = cb()" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("indexed field destination consumes", Prefix
         & "f: () -> (r: i32) = mut v: i32 = 0" & LF
         & "mut a: [1]box = [box(value: 42)]" & LF
         & "a[usize(consume(v))].value = 1" & LF
         & "r = v end f" & LF,
         Accepted => False);
      Check_Source
        ("destination effects precede assigned value", Prefix
         & "f: () -> (r: i32) = mut v: i32 = 0" & LF
         & "mut a: [1]box = [box(value: 42)]" & LF
         & "a[usize(consume(v))].value = v" & LF
         & "r = 0 end f" & LF,
         Accepted => False);
      Check_Source
        ("compound index read is reported once", Prefix
         & "f: () -> (r: i32) = index: usize" & LF
         & "mut a: [1]box = [box(value: 42)]" & LF
         & "a[index].value += 1" & LF
         & "r = 0 end f" & LF,
         Accepted => False);
      Check_Source
        ("field destination does not read its contents", Prefix
         & "f: () -> (r: i32) = mut b: box" & LF
         & "b.value = 7 r = b.value end f" & LF,
         Accepted => True);
      Check_Source
        ("slice sibling stays live", Prefix
         & "f: (s: []mut i32) -> (r: i32) =" & LF
         & "_ = consume(s[0]) r = s[1] end f" & LF,
         Accepted => True);
      Check_Source
        ("consumed slice element stays dead", Prefix
         & "f: (s: []mut i32) -> (r: i32) =" & LF
         & "_ = consume(s[0]) r = s[0] end f" & LF,
         Accepted => False);
      Check_Source
        ("slice length does not read elements", Prefix
         & "f: (s: []mut i32) -> (r: usize) =" & LF
         & "_ = consume(s[0]) r = lenof s end f" & LF,
         Accepted => True);
   end Nested_Calls_Retain_Flow_Effects;

   --  [1100] registers syntax rather than an evaluated value, but ordinary
   --  call checking still fixes the complete direct or indirect signature
   --  and any stored result shape where the statement is written.
   procedure Deferred_Calls_Are_Typed_At_Registration
     (Item : in out Landin.Testing.Context);

   procedure Deferred_Calls_Are_Typed_At_Registration
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
      None_Calls, Array_Calls : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "defer-types.ldn",
         "consume: (value: i32) -> none = _ = value end consume" & LF
         & "make_row: () -> (result: [2]i32) =" & LF
         & "    result = [19, 23]" & LF
         & "end make_row" & LF
         & "use: () -> none =" & LF
         & "    callback := consume" & LF
         & "    defer callback(42)" & LF
         & "    defer make_row()" & LF
         & "end use" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "direct stored-result and indirect deferred calls are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Defer_Statement
            then
               declare
                  Call : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Deferred_Call (Of_Tree.all, Node);
               begin
                  case Landin.Checking.Type_Of
                    (Types.all, Of_Tree.all, Call)
                  is
                     when Landin.Types.No_Value =>
                        None_Calls := None_Calls + 1;
                     when Landin.Types.Fixed_Array =>
                        Array_Calls := Array_Calls + 1;
                        Landin.Testing.Check
                          (Item,
                           Landin.Checking.Array_Length
                             (Types.all, Of_Tree.all, Call) = 2
                           and then Landin.Checking.Array_Element
                             (Types.all, Of_Tree.all, Call)
                               = Landin.Types.I32,
                           "the deferred aggregate result keeps its shape");
                     when others =>
                        Landin.Testing.Fail
                          (Item, "a deferred call lost its checked result");
                  end case;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, None_Calls, 1, "the indirect no-value call was typed");
      Landin.Testing.Check_Equal
        (Item, Array_Calls, 1, "the direct array call was typed");
   end Deferred_Calls_Are_Typed_At_Registration;

   --  [1110] has the same late call shape as defer.  Registration still
   --  fixes direct/indirect signatures and caller-owned stored result shape,
   --  including D128's anonymous multiple-result aggregate.
   procedure Undo_Calls_Are_Typed_At_Registration
     (Item : in out Landin.Testing.Context);

   procedure Undo_Calls_Are_Typed_At_Registration
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
      None_Calls, Array_Calls, Multiple_Calls : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "undo-types.ldn",
         "consume: (value: i32) -> none = _ = value end consume" & LF
         & "make_row: () -> (result: [2]i32) =" & LF
         & "    result = [19, 23]" & LF
         & "end make_row" & LF
         & "make_multiple: () -> (left: i32, right: i32) =" & LF
         & "    left = 19" & LF
         & "    right = 23" & LF
         & "end make_multiple" & LF
         & "use: () -> none =" & LF
         & "    callback := consume" & LF
         & "    undo callback(42)" & LF
         & "    undo make_row()" & LF
         & "    undo make_multiple()" & LF
         & "end use" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "indirect and stored-result undo calls are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Undo_Statement
            then
               declare
                  Call : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Undo_Call (Of_Tree.all, Node);
               begin
                  case Landin.Checking.Type_Of
                    (Types.all, Of_Tree.all, Call)
                  is
                     when Landin.Types.No_Value =>
                        None_Calls := None_Calls + 1;
                     when Landin.Types.Fixed_Array =>
                        Array_Calls := Array_Calls + 1;
                     when Landin.Types.Aggregate =>
                        if Landin.Checking.Result_Shape_Of
                             (Types.all, Of_Tree.all, Call)
                               /= Landin.Checking.No_Signature
                          and then Landin.Checking.Signature_Result_Count
                            (Types.all,
                             Landin.Checking.Result_Shape_Of
                               (Types.all, Of_Tree.all, Call)) = 2
                        then
                           Multiple_Calls := Multiple_Calls + 1;
                        end if;
                     when others =>
                        Landin.Testing.Fail
                          (Item, "an undo call lost its checked result");
                  end case;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, None_Calls, 1, "the indirect no-value undo call was typed");
      Landin.Testing.Check_Equal
        (Item, Array_Calls, 1, "the fixed-array undo result was typed");
      Landin.Testing.Check_Equal
        (Item, Multiple_Calls, 1,
         "the multiple-result undo call retained its structural shape");
   end Undo_Calls_Are_Typed_At_Registration;

   --  Definite assignment is asked where a registered call executes.  The
   --  accepted program assigns after registration and even fills its named
   --  result while evaluating a cleanup argument; the rejected one has an
   --  earlier guarded-return edge on which that same argument is unassigned.
   procedure Deferred_Reads_Use_Each_Exit_State
     (Item : in out Landin.Testing.Context);

   procedure Deferred_Reads_Use_Each_Exit_State
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Source (Text : String; Accepted : Boolean);

      procedure Check_Source (Text : String; Accepted : Boolean) is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source (Work, "defer-flow.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         Landin.Testing.Check_Equal (Item, Ran, 4, "the flow checker ran");
         Landin.Testing.Check
           (Item, Landin.Stages.Failed (Work) /= Accepted,
            "deferred reads use assignment facts at their execution edge");
      end Check_Source;

      Sink : constant String :=
        "consume: (value: i32) -> none = _ = value end consume" & LF;
   begin
      Check_Source
        (Sink
         & "f: () -> (result: i32) =" & LF
         & "    mut local: i32" & LF
         & "    defer consume(local)" & LF
         & "    defer consume(begin result = 42 result end)" & LF
         & "    local = 42" & LF
         & "    return" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        (Sink
         & "f: (leave: bool) -> (result: i32) =" & LF
         & "    mut local: i32" & LF
         & "    defer consume(local)" & LF
         & "    result = 0" & LF
         & "    return when leave" & LF
         & "    local = 42" & LF
         & "end f" & LF,
         Accepted => False);
   end Deferred_Reads_Use_Each_Exit_State;

   --  [1110]: delayed reads are required on direct and propagated failure
   --  edges alone.  Success, return, and a locally recovered call never run
   --  undo and therefore lend it no spurious assignment requirement.
   procedure Undo_Reads_Use_Only_Failure_States
     (Item : in out Landin.Testing.Context);

   procedure Undo_Reads_Use_Only_Failure_States
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Source (Text : String; Accepted : Boolean);

      procedure Check_Source (Text : String; Accepted : Boolean) is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source (Work, "undo-flow.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         Landin.Testing.Check_Equal (Item, Ran, 4, "the flow checker ran");
         Landin.Testing.Check
           (Item, Landin.Stages.Failed (Work) /= Accepted,
            "undo reads use only failure-edge assignment facts");
      end Check_Source;

      Prelude : constant String :=
        "bad: atom" & LF
        & "problem: type = bad" & LF
        & "consume: (value: i32) -> none = _ = value end consume" & LF
        & "leaf: () -> none ! problem = fail bad end leaf" & LF;
   begin
      Check_Source
        (Prelude
         & "f: () -> none ! problem =" & LF
         & "    mut local: i32" & LF
         & "    undo consume(local)" & LF
         & "    return" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        (Prelude
         & "f: () -> none ! problem =" & LF
         & "    mut local: i32" & LF
         & "    undo consume(local)" & LF
         & "    local = 42" & LF
         & "    fail bad" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        (Prelude
         & "f: () -> none ! problem =" & LF
         & "    mut local: i32" & LF
         & "    undo consume(local)" & LF
         & "    fail bad" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        (Prelude
         & "f: () -> none ! problem =" & LF
         & "    mut local: i32" & LF
         & "    undo consume(local)" & LF
         & "    local = 42" & LF
         & "    try leaf()" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        (Prelude
         & "f: () -> none ! problem =" & LF
         & "    mut local: i32" & LF
         & "    undo consume(local)" & LF
         & "    try leaf()" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        (Prelude
         & "f: () -> none ! problem =" & LF
         & "    mut local: i32" & LF
         & "    undo consume(local)" & LF
         & "    leaf() else 0" & LF
         & "    return" & LF
         & "end f" & LF,
         Accepted => True);
   end Undo_Reads_Use_Only_Failure_States;

   procedure Named_Runtime_Calls_Record_One_Formal_Match
     (Item : in out Landin.Testing.Context);

   procedure Named_Runtime_Calls_Record_One_Formal_Match
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "named-runtime-seam.ldn",
         "callback: type = (left: i32, middle: i32, right: i32)"
         & " -> (answer: i32)" & LF
         & "box: type = struct" & LF
         & "    invoke: callback" & LF
         & "end box" & LF
         & "combine: (a: i32, b: i32, c: i32) -> (r: i32) ="
         & " a * 100 + b * 10 + c end combine" & LF
         & "run: () -> (r: i32) =" & LF
         & "    direct := combine(c: 3, a: 1, b: 2)" & LF
         & "    indirect: callback = combine" & LF
         & "    via_value := indirect(right: 3, left: 1, middle: 2)" & LF
         & "    holder: box = (invoke: combine)" & LF
         & "    via_field := holder.invoke(middle: 2, right: 3, left: 1)"
         & LF
         & "    r = direct + via_value + via_field" & LF
         & "end run" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "direct, function-valued and selected named calls check");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Labeled_Application
              and then Landin.Resolution.Class_Of
                (Meanings.all, Of_Tree.all, Node)
                  = Landin.Resolution.Function_Call
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Resolution.Match_Of
                    (Meanings.all, Of_Tree.all, Node)
                      = Landin.Resolution.Call_Matched,
                  "checking publishes one accepted call match");
               for Written in 1 .. Landin.Syntax.Argument_Count
                 (Of_Tree.all, Node)
               loop
                  declare
                     Argument : constant Landin.Syntax.Node_Id :=
                       Landin.Syntax.Nth_Argument
                         (Of_Tree.all, Node, Written);
                     Position : constant Natural :=
                       Landin.Resolution.Position_Of
                         (Meanings.all, Of_Tree.all, Argument);
                  begin
                     Landin.Testing.Check
                       (Item,
                        Landin.Resolution.Role_Of
                          (Meanings.all, Of_Tree.all, Argument)
                            = Landin.Resolution.Runtime_Argument
                        and then Position in 1 .. 3,
                        "every written argument has one runtime formal"
                        & " position");
                  end;
               end loop;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 3, "all ordinary named call forms were matched");

      declare
         Rejected : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Rejected_Order : Landin.Stages.Pipeline;
         Rejected_Source : Landin.Source.Source_Id;
         Rejected_Ran : Natural;
         Found_Call : Boolean := False;
      begin
         Rejected_Source := Landin.Stages.Add_Source
           (Rejected, "rejected-named-runtime-seam.ldn",
            "add: (a: i32, b: i32) -> (r: i32) = a + b end add" & LF
            & "f: () -> (r: i32) = add(a: 1, a: 2) end f" & LF);
         Landin.Stages.Append (Rejected_Order, Frontend'Access);
         Landin.Stages.Append (Rejected_Order, Configurer'Access);
         Landin.Stages.Append (Rejected_Order, Names'Access);
         Landin.Stages.Append (Rejected_Order, Checker'Access);
         Rejected_Ran := Landin.Stages.Run (Rejected_Order, Rejected);
         Landin.Testing.Check_Equal
           (Item, Rejected_Ran, 4, "the rejecting checker ran");
         Landin.Testing.Check
           (Item, Landin.Stages.Failed (Rejected),
            "a duplicate named argument is rejected");

         declare
            Of_Tree : constant not null access constant Landin.Syntax.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Landin.Stages.Trees (Rejected).all, Rejected_Source);
            Meanings : constant not null access Landin.Resolution.Table :=
              Landin.Stages.Meanings (Rejected);
            Types : constant not null access Landin.Checking.Table :=
              Landin.Stages.Types (Rejected);
         begin
            for Node in Landin.Syntax.Node_Id'(1)
                      .. Landin.Syntax.Last_Node (Of_Tree.all)
            loop
               if Landin.Syntax.Kind (Of_Tree.all, Node)
                    = Landin.Syntax.Labeled_Application
               then
                  Found_Call := True;
                  Landin.Testing.Check
                    (Item,
                     Landin.Resolution.Match_Of
                       (Meanings.all, Of_Tree.all, Node)
                         = Landin.Resolution.Call_Rejected
                     and then Landin.Checking.Routine_Target_Of
                       (Types.all, Of_Tree.all, Node)
                         = Landin.Checking.No_Routine_Instance,
                     "a failed match records rejection and no lowering"
                     & " target");
               end if;
            end loop;
         end;
         Landin.Testing.Check
           (Item, Found_Call, "the rejected application remains queryable");
      end;
   end Named_Runtime_Calls_Record_One_Formal_Match;

   procedure Reference_Unions_Follow_Target_Layout
     (Item : in out Landin.Testing.Context);

   procedure Reference_Unions_Follow_Target_Layout
     (Item : in out Landin.Testing.Context)
   is
      Size : Landin.Targets.Byte_Count;
      Alignment : Landin.Targets.Byte_Alignment;
   begin
      Landin.Checking.Reference_Union_Extent
        (1, Landin.Targets.Linux_X86_64, Size, Alignment);
      Landin.Testing.Check
        (Item, Size = 8 and then Alignment = 8,
         "one atom and one pointer use the plain 64-bit pointer carrier");
      Landin.Checking.Reference_Union_Extent
        (2, Landin.Targets.Linux_X86_64, Size, Alignment);
      Landin.Testing.Check
        (Item, Size = 16 and then Alignment = 8,
         "two atoms and one pointer keep a 64-bit tag-plus-payload layout");
      Landin.Checking.Reference_Union_Extent
        (1, Landin.Targets.Synthetic_32, Size, Alignment);
      Landin.Testing.Check
        (Item, Size = 4 and then Alignment = 4,
         "one atom and one pointer use the plain 32-bit pointer carrier");
      Landin.Checking.Reference_Union_Extent
        (2, Landin.Targets.Synthetic_32, Size, Alignment);
      Landin.Testing.Check
        (Item, Size = 8 and then Alignment = 4,
         "two atoms and one pointer keep a 32-bit tag-plus-payload layout");
   end Reference_Unions_Follow_Target_Layout;

   procedure Array_Reference_Fields_Follow_Target
     (Item : in out Landin.Testing.Context);

   procedure Array_Reference_Fields_Follow_Target
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Target (Facts : Landin.Targets.Target_Facts);

      procedure Check_Target (Facts : Landin.Targets.Target_Facts) is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
         Count : Natural := 0;
      begin
         Src := Landin.Stages.Add_Source
           (Work, "array-reference-layout.ldn",
            "show: type = concept (t: type)" & LF
            & "    read: (self: ptr t) -> (value: i32)" & LF
            & "end show" & LF
            & "node: type = struct value: i32 end node" & LF
            & "holder: type (t: type) = struct values: [3]t end holder" & LF
            & "p: usize = sizeof holder(ptr node)" & LF
            & "s: usize = sizeof holder([]mut u32)" & LF
            & "a: usize = sizeof holder(any show)" & LF);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
         Landin.Testing.Check
           (Item, not Landin.Stages.Failed (Work),
            "generic array fields retain their reference element");
         declare
            Types : constant not null access Landin.Checking.Table :=
              Landin.Stages.Types (Work);
         begin
            for Position in 1 .. Landin.Checking.Nominal_Type_Count (Types.all)
            loop
               declare
                  Nominal : constant Landin.Checking.Nominal_Type_Id :=
                    Landin.Checking.Nth_Nominal_Type (Types.all, Position);
               begin
                  if Landin.Checking.Has_Layout (Types.all, Nominal)
                    and then Landin.Checking.Layout_Field_Count
                      (Types.all, Nominal) = 1
                  then
                     declare
                        Field : constant Landin.Checking.Field_Shape :=
                          Landin.Checking.Field_Shape_Of
                            (Types.all, Nominal, 1);
                     begin
                        if Field.Kind = Landin.Checking.Fixed_Array_Field then
                           declare
                              Ref : constant
                                Landin.Checking.Reference_Descriptor :=
                                  Landin.Checking.Descriptor_Of
                                    (Types.all, Field.Reference);
                              Bytes : constant Landin.Targets.Byte_Count :=
                                (if Ref.Kind = Landin.Types.Any_Value
                                 then Landin.Targets.Any_Value_Size (Facts)
                                 else Landin.Targets.Byte_Count
                                   (Landin.Targets.Bytes
                                      (Landin.Targets.Pointer_Size (Facts)))
                                   * (if Ref.Kind = Landin.Types.Slice_Value
                                      then 2 else 1));
                           begin
                              Count := Count + 1;
                              Landin.Testing.Check
                                (Item, Field.Length = 3
                                 and then Landin.Checking.Layout_Size
                                   (Types.all, Nominal) = 3 * Bytes,
                                 "three complete elements use target bytes");
                              Landin.Testing.Check
                                (Item, Landin.Checking.Contains_References
                                   (Types.all, Nominal),
                                 "array fields keep reference origin checks");
                           end;
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end;
         Landin.Testing.Check_Equal
           (Item, Count, 3, "all three array field layouts were checked");
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64);
      Check_Target (Landin.Targets.Synthetic_32);
   end Array_Reference_Fields_Follow_Target;

   procedure Conformance_Register_Uses_Normalized_Keys
     (Item : in out Landin.Testing.Context);

   procedure Conformance_Register_Uses_Normalized_Keys
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source (Work, "conformance-table.ldn", Program);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the table source is valid");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         Point_Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 2);
         Point : Landin.Provenance.Declaration_Id :=
           Landin.Provenance.No_Declaration;
      begin
         for Id in Landin.Provenance.Declaration_Id'(1)
           .. Landin.Provenance.Declaration_Id
             (Landin.Resolution.Declaration_Count (Meanings.all))
         loop
            if Landin.Resolution.Source_Of (Meanings.all, Id) = Src
              and then Landin.Resolution.Node_Of (Meanings.all, Id)
                = Point_Node
            then
               Point := Id;
               exit;
            end if;
         end loop;

         declare
            Concept : constant Landin.Checking.Concept_Id :=
              Landin.Checking.Intern_Concept (Types.all, Point);
            Inputs : Landin.Checking.Actual_Tuple :=
              Landin.Checking.Empty_Actuals;
            Empty : constant Landin.Checking.Actual_Tuple :=
              Landin.Checking.Empty_Actuals;
            Target : constant Landin.Checking.Actual_Key :=
              Landin.Checking.Scalar_Type_Actual (Landin.Types.I32);
            Made : Landin.Checking.Conformance_Id;
         begin
            Landin.Checking.Append_Actual
              (Inputs,
               Landin.Checking.Scalar_Type_Actual (Landin.Types.U8));
            Made := Landin.Checking.Add_Conformance
              (Types.all, Concept, Target, Inputs, Empty, Src, Point_Node,
               Landin.Checking.Declared_Conformance);

            Landin.Testing.Check
              (Item,
               Landin.Checking.Compiler_Zeroable_Concept (Types.all)
                 /= Concept
               and then Landin.Checking.Is_Compiler_Concept
                 (Types.all,
                  Landin.Checking.Compiler_Zeroable_Concept (Types.all))
               and then not Landin.Checking.Is_Compiler_Concept
                 (Types.all, Concept),
               "the closed compiler concept is distinct from source concepts");
            Landin.Testing.Check
              (Item,
               Landin.Checking.Find_Conformance
                 (Types.all, Concept, Target, Inputs) = Made
               and then Landin.Checking.Conformance_Concept
                 (Types.all, Made) = Concept
               and then Landin.Checking.Conformance_Input_Count
                 (Types.all, Made) = 1
               and then Landin.Checking.Conformance_Source
                 (Types.all, Made) = Src
               and then Landin.Checking.Conformance_Node
                 (Types.all, Made) = Point_Node,
               "one normalized target, concept and input tuple finds one row");
            Landin.Testing.Check
              (Item,
               Landin.Checking.Find_Conformance
                 (Types.all, Concept,
                  Landin.Checking.Scalar_Type_Actual (Landin.Types.U32),
                  Inputs) = Landin.Checking.No_Conformance,
               "a different normalized target has no conformance");
         end;
      end;
   end Conformance_Register_Uses_Normalized_Keys;

   procedure Float_Specials_Have_Canonical_Bits
     (Item : in out Landin.Testing.Context)
   is
   begin
      Landin.Testing.Check
        (Item,
         Landin.Types.Float_Special_Bits
           (Landin.Types.F32, Landin.Types.Infinity) = 16#7F80_0000#
         and then Landin.Types.Float_Special_Bits
           (Landin.Types.F64, Landin.Types.Infinity)
             = 16#7FF0_0000_0000_0000#,
         "each infinity has the positive IEEE pattern");
      Landin.Testing.Check
        (Item,
         Landin.Types.Float_Special_Bits
           (Landin.Types.F32, Landin.Types.Quiet_NaN) = 16#7FC0_0000#
         and then Landin.Types.Float_Special_Bits
           (Landin.Types.F64, Landin.Types.Quiet_NaN)
             = 16#7FF8_0000_0000_0000#,
         "each nan has the canonical quiet IEEE pattern");
      Landin.Testing.Check
        (Item,
         Landin.Types.Negated_Float
           (Landin.Types.Float_Special_Bits
              (Landin.Types.F32, Landin.Types.Quiet_NaN),
            Landin.Types.F32) = 16#FFC0_0000#
         and then Landin.Types.Negated_Float
           (Landin.Types.Float_Special_Bits
              (Landin.Types.F64, Landin.Types.Quiet_NaN),
            Landin.Types.F64) = 16#FFF8_0000_0000_0000#,
         "unary minus changes only the nan sign bit");
   end Float_Specials_Have_Canonical_Bits;

   procedure Float_Arithmetic_Uses_IEEE_Bits
     (Item : in out Landin.Testing.Context)
   is
   begin
      Landin.Testing.Check
        (Item,
         Landin.Types.Float_Arithmetic_Result
           (16#3F80_0000#, 16#3380_0000#, Landin.Types.F32,
            Landin.Types.Float_Add) = 16#3F80_0000#,
         "binary32 addition rounds a halfway result to even");
      Landin.Testing.Check
        (Item,
         Landin.Types.Float_Arithmetic_Result
           (1, 1, Landin.Types.F32, Landin.Types.Float_Add) = 2
         and then Landin.Types.Float_Arithmetic_Result
           (16#0010_0000_0000_0000#, 16#4000_0000_0000_0000#,
            Landin.Types.F64, Landin.Types.Float_Divide)
              = 16#0008_0000_0000_0000#,
         "arithmetic retains gradual underflow in both widths");
      Landin.Testing.Check
        (Item,
         Landin.Types.Float_Arithmetic_Result
           (16#3F80_0000#, 16#4040_0000#, Landin.Types.F32,
            Landin.Types.Float_Divide) = 16#3EAA_AAAB#
         and then Landin.Types.Float_Arithmetic_Result
           (16#3FF0_0000_0000_0000#, 16#4008_0000_0000_0000#,
            Landin.Types.F64, Landin.Types.Float_Divide)
              = 16#3FD5_5555_5555_5555#,
         "division rounds recurring quotients in each IEEE width");
      Landin.Testing.Check
        (Item,
         Landin.Types.Float_Arithmetic_Result
           (16#7F7F_FFFF#, 16#4000_0000#, Landin.Types.F32,
            Landin.Types.Float_Multiply) = 16#7F80_0000#
         and then Landin.Types.Float_Arithmetic_Result
           (0, 0, Landin.Types.F64, Landin.Types.Float_Divide)
              = 16#7FF8_0000_0000_0000#,
         "overflow becomes infinity and invalid arithmetic canonicalizes nan");
      Landin.Testing.Check
        (Item,
         Landin.Types.Float_Arithmetic_Result
           (16#3FF0_0000_0000_0000#, 16#3FF0_0000_0000_0000#,
            Landin.Types.F64, Landin.Types.Float_Subtract) = 0
         and then Landin.Types.Float_Arithmetic_Result
           (16#8000_0000#, 16#4000_0000#, Landin.Types.F32,
            Landin.Types.Float_Divide) = 16#8000_0000#,
         "exact cancellation and division preserve IEEE zero signs");
      Landin.Testing.Check
        (Item,
         Landin.Types.Float_Comparison_Result
           (16#8000_0000#, 0, Landin.Types.F32,
            Landin.Types.Float_Equal)
         and then Landin.Types.Float_Comparison_Result
           (16#7FC0_0000#, 16#7FC0_0000#, Landin.Types.F32,
            Landin.Types.Float_Not_Equal)
         and then not Landin.Types.Float_Comparison_Result
           (16#7FC0_0000#, 0, Landin.Types.F32,
            Landin.Types.Float_Less),
         "comparison equates signed zeros and leaves nan unordered");
   end Float_Arithmetic_Uses_IEEE_Bits;

   procedure Contextual_Generic_Text_Literals_Keep_Exact_Views
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "keep_utf8: (item: type, value: item, text: utf8)"
        & " -> (answer: item) = value end keep_utf8" & LF
        & "keep_utf16: (item: type, value: item, text: utf16)"
        & " -> (answer: item) = value end keep_utf16" & LF
        & "keep_cstring: (item: type, value: item, text: cstring)"
        & " -> (answer: item) = value end keep_cstring" & LF
        & "keep_bytes: (item: type, value: item, text: []u8)"
        & " -> (answer: item) = value end keep_bytes" & LF
        & "same: (item: type, left: item, right: item)"
        & " -> (answer: i32) = answer = 42 end same" & LF
        & "public main: () -> (code: i32) =" & LF
        & "    seed: i32 = 42" & LF
        & "    a := keep_utf8(seed, ""A\u{2603}"")" & LF
        & "    b: i32 = keep_utf8(item: i32, value: seed,"
        & " text: ""B"")" & LF
        & "    c := keep_utf16(seed, ""C\u{1f600}"")" & LF
        & "    d: i32 = keep_utf16(item: i32, value: seed,"
        & " text: ""D"")" & LF
        & "    e := keep_cstring(seed, ""E\u{2603}"")" & LF
        & "    f: i32 = keep_cstring(item: i32, value: seed,"
        & " text: ""F"")" & LF
        & "    g := keep_bytes(seed, ""\x47H"")" & LF
        & "    h: i32 = keep_bytes(item: i32, value: seed,"
        & " text: ""I"")" & LF
        & "    i: i32 = same(item: utf16, left: ""J"", right: ""K"")"
        & LF
        & "    code = a + b + c + d + e + f + g + h + i" & LF
        & "end main" & LF;
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
      Exact : Boolean := True;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "generic-contextual-text.ldn", Source_Text);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "inferred and explicit generic calls accept each concrete text"
         & " literal view");
      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
           .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 in Landin.Syntax.Text_Literal | Landin.Syntax.Raw_Literal
            then
               Seen := Seen + 1;
               declare
                  Reference : constant Landin.Checking.Reference_Id :=
                    Landin.Checking.Reference_Of
                      (Types.all, Of_Tree.all, Node);
                  Expected_View : constant Landin.Types.Reference_View :=
                    (if Seen <= 2 then Landin.Types.Utf8_View
                     elsif Seen <= 4 then Landin.Types.Utf16_View
                     elsif Seen <= 6 then Landin.Types.C_String_View
                     elsif Seen <= 8 then Landin.Types.Ordinary_View
                     else Landin.Types.Utf16_View);
               begin
                  if Reference = Landin.Checking.No_Reference then
                     Exact := False;
                  else
                     declare
                        Descriptor : constant
                          Landin.Checking.Reference_Descriptor :=
                            Landin.Checking.Descriptor_Of
                              (Types.all, Reference);
                     begin
                        Exact := Exact
                          and then Descriptor.View = Expected_View
                          and then not Descriptor.Mutable
                          and then Descriptor.Kind =
                            (if Expected_View = Landin.Types.C_String_View
                             then Landin.Types.Pointer_Value
                             else Landin.Types.Slice_Value)
                          and then Descriptor.Referent =
                            (if Expected_View = Landin.Types.Utf16_View
                             then Landin.Types.U16 else Landin.Types.U8);
                     end;
                  end if;
               end;
            end if;
         end loop;
      end;
      Landin.Testing.Check_Equal
        (Item, Seen, 10, "all contextual text literals were checked");
      Landin.Testing.Check
        (Item, Exact,
         "each literal retains its exact view, permission and referent");
   end Contextual_Generic_Text_Literals_Keep_Exact_Views;

   procedure Erased_Recovery_Bindings_Have_Exact_Errors
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "oops: atom" & LF
        & "service: type = concept (item: type)" & LF
        & "    get: (self: ptr mut item) -> (value: i32) ! oops" & LF
        & "end service" & LF
        & "state: type = struct value: i32 end state" & LF
        & "get_value: (self: ptr mut state) -> (answer: i32) ! oops ="
        & LF & "    fail oops when self.val.value == 0" & LF
        & "    answer = self.val.value" & LF & "end get_value" & LF
        & "state is service (get: get_value)" & LF
        & "public main: () -> (code: i32) =" & LF
        & "    code = 42" & LF
        & "    mut data: state = (value: 0)" & LF
        & "    value: any service = any(addr data)" & LF
        & "    first: i32 = value.get() else (typed_error)" & LF
        & "        _ = typed_error" & LF & "        return" & LF
        & "    end" & LF
        & "    second := value.get() else (inferred_error)" & LF
        & "        _ = inferred_error" & LF & "        return" & LF
        & "    end" & LF
        & "    code = first + second" & LF & "end main" & LF;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "erased-recovery.ldn", Source_Text);
      pragma Unreferenced (Src);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "both calls are accepted");
      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         Seen : Natural := 0;
         Expected : Landin.Checking.Atom_Set_Id :=
           Landin.Checking.No_Atom_Set;
      begin
         for Id in Landin.Provenance.Declaration_Id'(1)
           .. Landin.Provenance.Declaration_Id
             (Landin.Resolution.Declaration_Count (Meanings.all))
         loop
            if Landin.Resolution.Sort_Of (Meanings.all, Id)
              = Landin.Resolution.Error_Binding
            then
               Seen := Seen + 1;
               declare
                  Errors : constant Landin.Checking.Atom_Set_Id :=
                    Landin.Checking.Atom_Set_Of (Types.all, Id);
               begin
                  Landin.Testing.Check
                    (Item, Landin.Checking.Type_Of (Types.all, Id)
                       = Landin.Types.Atom_Value,
                     "recovery binding has a storable atom type");
                  Landin.Testing.Check
                    (Item, Errors /= Landin.Checking.No_Atom_Set,
                     "recovery retains the declared error set");
                  if Seen = 1 then
                     Expected := Errors;
                  else
                     Landin.Testing.Check
                       (Item, Errors /= Landin.Checking.No_Atom_Set
                          and then Expected /= Landin.Checking.No_Atom_Set
                          and then Landin.Checking.Atom_Sets_Agree
                            (Types.all, Errors, Expected),
                        "typed and inferred calls retain identical errors");
                  end if;
               end;
            end if;
         end loop;
         Landin.Testing.Check_Equal
           (Item, Seen, 2, "both named recoveries were inspected");
      end;
   end Erased_Recovery_Bindings_Have_Exact_Errors;

   procedure Inferred_Erased_Results_Use_Exact_Entry_Shapes
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "counter: type = concept (t: type)" & LF
        & "    add: (self: ptr mut t, amount: i32) -> (value: i32)" & LF
        & "end counter" & LF
        & "node: type = struct" & LF
        & "    value: i32" & LF
        & "end node" & LF
        & "public main: () -> (code: i32) =" & LF
        & "    mut local: node = (value: 40)" & LF
        & "    erased: any counter = any(addr local)" & LF
        & "    inferred := erased.add(amount: 1)" & LF
        & "    typed: i32 = erased.add(amount: 1)" & LF
        & "    code = inferred + typed" & LF
        & "end main" & LF
        & "add_node: (self: ptr mut node, n: i32)"
        & " -> (answer: i32) =" & LF
        & "    self.val.value = self.val.value + n" & LF
        & "    answer = self.val.value" & LF
        & "end add_node" & LF
        & "node is counter (add: add_node)" & LF;
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "inferred-erased-result.ldn", Source_Text);
      pragma Unreferenced (Src);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "inferred and typed erased calls use the concept's named interface");
      declare
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
         Evidence : constant Landin.Checking.Conformance_Id :=
           Landin.Checking.Conformance_Identities.Nth (Types.all, 1);
      begin
         Landin.Testing.Check_Equal
           (Item, Landin.Checking.Conformance_Count (Types.all), 1,
            "the exact concept has one concrete conformance");
         Landin.Testing.Check_Equal
           (Item,
            Landin.Checking.Conformance_Entry_Count
              (Types.all, Evidence),
            1, "provider finalization still populates the entry run");
      end;
   end Inferred_Erased_Results_Use_Exact_Entry_Shapes;

   procedure R440_Result_Locals_Are_Contextual
     (Item : in out Landin.Testing.Context);

   procedure R440_Result_Locals_Are_Contextual
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Local (By_Inout, Copy_First : Boolean);

      procedure Check_Local (By_Inout, Copy_First : Boolean) is
         Text : constant String :=
           "absent: atom" & LF
           & "maybe_pointer: type = absent | ptr u32" & LF
           & "pair: ("
           & (if By_Inout then "inout cell: [1]u32" else "cell: ptr u32")
           & ") -> (got: bool, item: maybe_pointer from cell) =" & LF
           & "    got = true" & LF
           & "    item = "
           & (if By_Inout then "addr cell[0]" else "cell") & LF
           & "end pair" & LF
           & "inspect: ("
           & (if By_Inout then "inout cell: [1]u32" else "cell: ptr u32")
           & ") -> none =" & LF
           & "    (item: local, _) := pair(cell)" & LF
           & (if Copy_First then "    copied := local" & LF else "")
           & "    match " & (if Copy_First then "copied" else "local") & LF
           & "        absent: _ = 0" & LF
           & "        ptr (pointer): _ = pointer.val" & LF
           & "    end match" & LF
           & "end inspect" & LF;
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Src : Landin.Source.Source_Id;
         Ran : Natural;
         Locals : Natural := 0;
      begin
         Src := Landin.Stages.Add_Source (Work, "r440-result-local.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
         if Landin.Stages.Failed (Work) then
            Landin.Testing.Fail
              (Item, "result locals need no initializer during discovery");
            return;
         end if;
         declare
            Types : constant not null access Landin.Checking.Table :=
              Landin.Stages.Types (Work);
            Meanings : constant not null access Landin.Resolution.Table :=
              Landin.Stages.Meanings (Work);
         begin
            for Id in Landin.Resolution.Declaration_Id'(1)
              .. Landin.Resolution.Declaration_Id
                (Landin.Resolution.Declaration_Count (Meanings.all))
            loop
               if Landin.Resolution.Source_Of (Meanings.all, Id) = Src
                 and then Landin.Resolution.Sort_Of (Meanings.all, Id)
                   = Landin.Resolution.Result_Binding
               then
                  Locals := Locals + 1;
                  Landin.Testing.Check
                    (Item, Landin.Checking.Type_Of (Types.all, Id)
                       = Landin.Types.Pointer_Value
                     and then Landin.Checking.Reference_Of (Types.all, Id)
                       /= Landin.Checking.No_Reference
                     and then Landin.Checking.Descriptor_Of
                       (Types.all, Landin.Checking.Reference_Of
                          (Types.all, Id)).Empty_Atom
                       /= Landin.Resolution.No_Declaration,
                     "the selected later result keeps its optional identity");
               end if;
            end loop;
         end;
         Landin.Testing.Check_Equal
           (Item, Locals, 1, "one selected local is settled contextually");
      end Check_Local;
   begin
      for By_Inout in Boolean loop
         for Copy_First in Boolean loop
            Check_Local (By_Inout, Copy_First);
         end loop;
      end loop;
   end R440_Result_Locals_Are_Contextual;

   procedure R440_Result_Binding_Refusals_Are_Stable
     (Item : in out Landin.Testing.Context);

   procedure R440_Result_Binding_Refusals_Are_Stable
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Refusal (Duplicate : Boolean);

      procedure Check_Refusal (Duplicate : Boolean) is
         Text : constant String :=
           "absent: atom" & LF
           & "maybe_pointer: type = absent | ptr u32" & LF
           & "pair: (cell: ptr u32)"
           & " -> (got: bool, item: maybe_pointer from cell) =" & LF
           & "    got = true" & LF
           & "    item = cell" & LF
           & "end pair" & LF
           & "bad: (cell: ptr u32) -> none =" & LF
           & (if Duplicate then
               "    (item: first, item: local, _) := pair(cell)" & LF
             else "    (missing: local, _) := pair(cell)" & LF)
           & "    match local" & LF
           & "        absent: _ = 0" & LF
           & "        ptr (pointer): _ = pointer.val" & LF
           & "    end match" & LF
           & "end bad" & LF;
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Src : Landin.Source.Source_Id;
         Ran : Natural;
      begin
         Src := Landin.Stages.Add_Source
           (Work, "r440-result-refusal.ldn", Text);
         pragma Unreferenced (Src);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check
              (Item, Landin.Stages.Failed (Work)
                 and then Landin.Diagnostics.Count (Reports) = 1
                 and then Landin.Diagnostics.Code
                   (Landin.Diagnostics.Get (Reports, 1))
                     = (if Duplicate then "L0301" else "L0308"),
               "lazy and ordinary walks report an invalid result label once");
         end;
      end Check_Refusal;
   begin
      Check_Refusal (False);
      Check_Refusal (True);
   end R440_Result_Binding_Refusals_Are_Stable;

   procedure R440_C_Array_Literals_Keep_Nominals
     (Item : in out Landin.Testing.Context);

   procedure R440_C_Array_Literals_Keep_Nominals
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Elements (Matching : Boolean);

      procedure Check_Elements (Matching : Boolean) is
         Text : constant String :=
           "leaf: type = layout(c) struct" & LF
           & "    value: f64" & LF
           & "end leaf" & LF
           & "other: type = layout(c) struct" & LF
           & "    value: f64" & LF
           & "end other" & LF
           & "outer: type = layout(c) struct" & LF
           & "    values: [2]leaf" & LF
           & "end outer" & LF
           & "construct: (value: f64) -> (result: outer) =" & LF
           & "    result = outer(values: [leaf(value: value), "
           & (if Matching then "leaf" else "other")
           & "(value: value + 1.0)])" & LF
           & "end construct" & LF;
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Src : Landin.Source.Source_Id;
         Ran : Natural;
         Literals : Natural := 0;
      begin
         Src := Landin.Stages.Add_Source
           (Work, "r440-array-element.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check
              (Item, Landin.Stages.Failed (Work) /= Matching
                 and then (if Matching then
                   Landin.Diagnostics.Count (Reports) = 0
                 else
                   Landin.Diagnostics.Count (Reports) = 1
                   and then Landin.Diagnostics.Code
                     (Landin.Diagnostics.Get (Reports, 1)) = "L0301"),
               "array elements keep nominal identity, not a scalar carrier");
         end;
         if not Matching or else Landin.Stages.Failed (Work) then
            return;
         end if;
         declare
            Tree : constant not null access constant Landin.Syntax.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Landin.Stages.Trees (Work).all, Src);
            Types : constant not null access Landin.Checking.Table :=
              Landin.Stages.Types (Work);
         begin
            for Node in Landin.Syntax.Node_Id'(1)
              .. Landin.Syntax.Last_Node (Tree.all)
            loop
               if Landin.Syntax.Kind (Tree.all, Node)
                 = Landin.Syntax.Array_Literal
               then
                  Literals := Literals + 1;
                  declare
                     Nominal : constant Landin.Checking.Nominal_Type_Id :=
                       Landin.Checking.Array_Element_Nominal
                         (Types.all, Tree.all, Node);
                  begin
                     Landin.Testing.Check
                       (Item, Nominal /= Landin.Checking.No_Nominal_Type
                          and then Landin.Checking.Array_Length
                            (Types.all, Tree.all, Node) = 2,
                        "the literal keeps its nominal array shape");
                     for Position in 1 .. 2 loop
                        Landin.Testing.Check
                          (Item, Landin.Checking.Nominal_Of
                             (Types.all, Tree.all, Landin.Syntax.Nth_Element
                                (Tree.all, Node, Position)) = Nominal,
                           "each inline element keeps the nominal identity");
                     end loop;
                  end;
               end if;
            end loop;
         end;
         Landin.Testing.Check_Equal
           (Item, Literals, 1, "the nested array literal was checked");
      end Check_Elements;
   begin
      Check_Elements (True);
      Check_Elements (False);
   end R440_C_Array_Literals_Keep_Nominals;

   procedure R440_Variadic_Carrier_Refusal_Is_Precise
     (Item : in out Landin.Testing.Context);

   procedure R440_Variadic_Carrier_Refusal_Is_Precise
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Tail (Argument : String);

      procedure Check_Tail (Argument : String) is
         Text : constant String :=
           "pair: type = layout(c) struct" & LF
           & "    left: i32" & LF
           & "    right: i32" & LF
           & "end pair" & LF
           & "extern(c) collect: (count: i32, ...) -> none" & LF
           & "bad: () -> none =" & LF
           & "    value: pair = pair(left: 1, right: 2)" & LF
           & "    collect(1, " & Argument & ")" & LF
           & "end bad" & LF;
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Src : Landin.Source.Source_Id;
         Ran : Natural;
      begin
         Src := Landin.Stages.Add_Source
           (Work, "r440-variadic-tail.ldn", Text);
         pragma Unreferenced (Src);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check
              (Item, Landin.Stages.Failed (Work)
                 and then Landin.Diagnostics.Count (Reports) = 1
                 and then Landin.Diagnostics.Code
                   (Landin.Diagnostics.Get (Reports, 1)) = "L0301"
                 and then Landin.Diagnostics.Message
                   (Landin.Diagnostics.Primary
                      (Landin.Diagnostics.Get (Reports, 1))) =
                        "this C variadic tail argument is not"
                        & " an enabled scalar carrier",
               "the carrier boundary owns the aggregate refusal");
         end;
      end Check_Tail;
   begin
      Check_Tail ("value");
      Check_Tail ("pair(left: 1, right: 2)");
   end R440_Variadic_Carrier_Refusal_Is_Precise;

   procedure R440_Recursive_Array_Foundations
     (Item : in out Landin.Testing.Context);

   procedure R440_Recursive_Array_Foundations
     (Item : in out Landin.Testing.Context)
   is
      package C renames Landin.Checking;
      package Ty renames Landin.Types;
      use type C.Field_Shape;
      Text : constant String := Program
        & "identity: (t: type, value: t) -> (result: t) =" & LF
        & "    result = value" & LF & "end identity" & LF;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Src : Landin.Source.Source_Id;
      Ran : Natural;
   begin
      Src := Landin.Stages.Add_Source (Work, "r440-shapes.ldn", Text);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check_Equal (Item, Ran, 3, "foundation source resolves");
      if Landin.Stages.Failed (Work) then
         Landin.Testing.Fail (Item, "recursive foundation source was refused");
         return;
      end if;
      declare
         Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access C.Table :=
           Landin.Stages.Types (Work);
         Other : C.Table;
         Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Tree.all, 1);
         Site : constant Landin.Provenance.Origin :=
           Landin.Syntax.Origin (Tree.all, Node);
         Template : Landin.Provenance.Declaration_Id :=
           Landin.Provenance.No_Declaration;
      begin
         C.Prepare
           (Types.all, Landin.Stages.Trees (Work).all,
            Landin.Stages.Meanings (Work).all,
            Landin.Stages.Identities (Work).all);
         C.Prepare
           (Other, Landin.Stages.Trees (Work).all,
            Landin.Stages.Meanings (Work).all,
            Landin.Stages.Identities (Work).all);
         for Id in Landin.Provenance.Declaration_Id'(1)
           .. Landin.Provenance.Declaration_Id
             (Landin.Resolution.Declaration_Count
                (Landin.Stages.Meanings (Work).all))
         loop
            if Landin.Resolution.Sort_Of
              (Landin.Stages.Meanings (Work).all, Id)
                = Landin.Resolution.Module_Function
            then
               Template := Id;
            end if;
         end loop;
         declare
            Part : constant C.Signature_Part :=
              (Kind => Ty.I32, Site => Site, others => <>);
            Renamed : C.Signature_Part := Part;
            First : constant C.Signature_Id :=
              C.Add_Signature (Types.all, [Part], Part, Site, C_ABI => True);
            Native : constant C.Signature_Id :=
              C.Add_Signature (Types.all, [Part], Part, Site);
            Variadic : constant C.Signature_Id := C.Add_Signature
              (Types.all, [Part], Part, Site, C_ABI => True, Variadic => True);
            Pointer : constant C.Reference_Id := C.Add_Reference
              (Types.all, (Referent => Ty.U8, others => <>));
            Pointer_Part : constant C.Signature_Part :=
              (Kind => Ty.Pointer_Value, Reference => Pointer,
               Site => Site, others => <>);
            With_Pointer : constant C.Signature_Id := C.Add_Signature
              (Types.all, [Pointer_Part], Part, Site, C_ABI => True);
            Callback : constant C.Field_Shape :=
              (Element => Ty.Usize, Signature => First, others => <>);
            Row : constant C.Field_Shape :=
              C.Make_Array_Field (Types.all, 3, Callback);
            Matrix : constant C.Field_Shape :=
              C.Make_Array_Field (Types.all, 2, Row);
            Again : constant C.Field_Shape :=
              C.Make_Array_Field (Types.all, 100_000, Row);
            Nominal : constant C.Nominal_Type_Id :=
              C.Nth_Nominal_Type (Types.all, 1);
            Leaves : constant C.Field_Shape_Array :=
              [(Element => Ty.U16, others => <>),
               (Kind => C.Reference_Field, Reference => Pointer, others => <>),
               (Kind => C.Aggregate_Field, Nominal => Nominal, others => <>),
               Callback, Row, Matrix];
            Size : Landin.Targets.Byte_Count;
            Alignment : Landin.Targets.Byte_Alignment;
            Fits : Boolean;
            Bad, Got : C.Field_Shape;
            Previous : C.Routine_Instance_Id;
         begin
            C.Lay_Out
              (Types.all, Nominal,
               [(Element => Ty.U8, others => <>)],
               Landin.Targets.Linux_X86_64, Fits);
            Landin.Testing.Check (Item, Fits, "nominal leaf has a layout");
            for Leaf of Leaves loop
               declare
                  Shape : constant C.Field_Shape :=
                    C.Make_Array_Field (Types.all, 7, Leaf);
               begin
                  Landin.Testing.Check
                    (Item, C.Holds (Types.all, Shape)
                       and then C.Array_Field_Element
                         (Types.all, Shape) = Leaf,
                     "complete immediate children round trip without loss");
                  if Shape.Cases = 0 then
                     Landin.Testing.Check
                       (Item, C.Array_Field_Element (Shape) = Leaf,
                        "metadata-free children keep the compact accessor");
                  end if;
               end;
            end loop;
            Landin.Testing.Check
              (Item, Row.Cases = 1 and then Matrix.Cases = 1
                 and then Matrix.Payloads_First = Again.Payloads_First
                 and then Matrix.Signature = C.No_Signature
                 and then Row.Signature = C.No_Signature,
               "repetition shares one child, not one descriptor per element");
            C.Shape_Extent
              (Types.all, Matrix, Landin.Targets.Synthetic_32,
               Size, Alignment);
            Landin.Testing.Check
              (Item, Size = 24 and then Alignment = 4,
               "nested callbacks use target pointer width, not host width");
            C.Shape_Extent
              (Types.all, Matrix, Landin.Targets.Linux_X86_64,
               Size, Alignment);
            Landin.Testing.Check
              (Item, Size = 48 and then Alignment = 8,
               "the same complete shape measures on the 64-bit target");
            declare
               Wide_Row : constant C.Field_Shape := C.Make_Array_Field
                 (Types.all, 65_536, (Element => Ty.U8, others => <>));
               Huge : constant C.Field_Shape :=
                 C.Make_Array_Field (Types.all, 65_536, Wide_Row);
            begin
               C.Shape_Extent
                 (Types.all, Huge, Landin.Targets.Linux_X86_64,
                  Size, Alignment);
               Landin.Testing.Check
                 (Item, Size = 4_294_967_296, "extent stays target-sized");
               begin
                  C.Shape_Extent
                    (Types.all, Huge, Landin.Targets.Synthetic_32,
                     Size, Alignment);
                  Landin.Testing.Fail (Item, "32-bit nested extent overflow");
               exception
                  when Landin.Compiler_Defect =>
                     Landin.Testing.Check
                       (Item, True, "nested multiplication checks before use");
               end;
               C.Lay_Out
                 (Types.all, C.Nth_Nominal_Type (Types.all, 2), [Huge],
                  Landin.Targets.Synthetic_32, Fits);
               Landin.Testing.Check
                 (Item, not Fits and then not C.Has_Layout
                    (Types.all, C.Nth_Nominal_Type (Types.all, 2)),
                  "32-bit overflowing records never publish a partial layout");
            end;
            for Fault in 1 .. 7 loop
               Bad := Matrix;
               case Fault is
                  when 1 => Bad.Cases := 2;
                  when 2 => Bad.Payloads_First := 0;
                  when 3 => Bad.Payloads_First := Natural'Last;
                  when 4 => Bad.Signature := First;
                  when 5 => Bad.Reference := Pointer;
                  when 6 => Bad.Nominal := Nominal;
                  when 7 => Bad.Cases := 0;
               end case;
               Landin.Testing.Check
                 (Item, not C.Holds (Types.all, Bad)
                    and then not C.Field_Shapes_Agree (Types.all, Bad, Bad),
                  "malformed complete-child runs are safely rejected");
               begin
                  Got := C.Array_Field_Element (Types.all, Bad);
                  pragma Assert (Got.Kind = C.Fixed_Array_Field);
                  Landin.Testing.Fail (Item, "malformed child access escaped");
               exception
                  when Landin.Compiler_Defect
                     | Ada.Assertions.Assertion_Error =>
                     Landin.Testing.Check
                       (Item, True, "child access has a checked boundary");
               end;
            end loop;
            begin
               Got := C.Array_Field_Element (Matrix);
               pragma Assert (Got.Kind = C.Fixed_Array_Field);
               Landin.Testing.Fail (Item, "compact accessor erased a child");
            exception
               when Landin.Compiler_Defect | Ada.Assertions.Assertion_Error =>
                  Landin.Testing.Check
                    (Item, True, "compact accessor refuses complete children");
            end;
            Renamed.Name := Landin.Source.Names.Intern
              (Landin.Stages.Identities (Work).all, "renamed");
            Renamed.Site := Landin.Syntax.Origin
              (Tree.all, Landin.Syntax.Nth_Declaration (Tree.all, 2));
            declare
               Second : constant C.Signature_Id := C.Add_Signature
                 (Types.all, [Renamed], Renamed, Renamed.Site, C_ABI => True);
               Twin : constant C.Field_Shape := C.Make_Array_Field
                 (Types.all, 3,
                  (Element => Ty.Usize, Signature => Second, others => <>));
               Wrong : constant C.Field_Shape := C.Make_Array_Field
                 (Types.all, 3,
                  (Element => Ty.Usize, Signature => Native, others => <>));
               A, B, D : C.Actual_Tuple := C.Empty_Actuals;
               Plain : constant C.Actual_Key :=
                 C.Fixed_Array_Type_Actual (2, Ty.U8);
               Key : constant C.Actual_Key :=
                 C.Fixed_Array_Type_Actual (Types.all, 2, Row);
               Instance, Same, Different : C.Routine_Instance_Id;
            begin
               Landin.Testing.Check
                 (Item, First /= Second
                    and then C.Field_Shapes_Agree (Types.all, Row, Twin)
                    and then not C.Field_Shapes_Agree (Types.all, Row, Wrong)
                    and then not C.Signatures_Agree
                      (Types.all, First, Variadic),
                  "callback identity is structural but convention-sensitive");
               Landin.Testing.Check
                 (Item, C.Holds (Other, Plain)
                    and then C.Holds (Types.all, Key)
                    and then not C.Holds (Other, Key)
                    and then C.Array_Element_Shape_Of (Types.all, Key) = Row,
                  "descriptor keys are table-owned; scalar keys are portable");
               begin
                  Got := C.Array_Element_Shape_Of (Other, Key);
                  pragma Assert (Got.Kind = C.Fixed_Array_Field);
                  Landin.Testing.Fail (Item, "foreign array key escaped");
               exception
                  when Landin.Compiler_Defect
                     | Ada.Assertions.Assertion_Error =>
                     Landin.Testing.Check
                       (Item, True, "key ownership is guarded");
               end;
               begin
                  Got := C.Array_Element_Shape_Of
                    (Types.all, C.Scalar_Type_Actual (Ty.U8));
                  pragma Assert (Got.Element = Ty.U8);
                  Landin.Testing.Fail (Item, "nonarray key escaped");
               exception
                  when Landin.Compiler_Defect
                     | Ada.Assertions.Assertion_Error =>
                     Landin.Testing.Check (Item, True, "key kind is guarded");
               end;
               C.Append_Actual (A, Key);
               C.Append_Actual
                 (B, C.Fixed_Array_Type_Actual (Types.all, 2, Twin));
               C.Append_Actual
                 (D, C.Fixed_Array_Type_Actual (Types.all, 2, Wrong));
               Instance := C.Intern_Routine_Instance (Types.all, Template, A);
               Same := C.Intern_Routine_Instance (Types.all, Template, B);
               Different := C.Intern_Routine_Instance (Types.all, Template, D);
               Landin.Testing.Check
                 (Item, Instance = Same and then Instance /= Different
                    and then C.Intern_Nominal_Instance
                      (Types.all, C.Template_Of (Types.all, Nominal), A)
                        = C.Intern_Nominal_Instance
                          (Types.all, C.Template_Of (Types.all, Nominal), B),
                  "recursive actuals intern routine and nominal keys");
               C.Note_Array (Types.all, Template, 2, Ty.Bool);
               C.Note_Array_Element_Nominal (Types.all, Template, Nominal);
               C.Note_Array (Types.all, Tree.all, Node, 2, Ty.Bool);
               C.Note_Array_Element_Nominal
                 (Types.all, Tree.all, Node, Nominal);
               C.Activate_Routine_View (Types.all, Instance, Previous);
               C.Note_Array_Element_Shape (Types.all, Template, Callback);
               C.Note_Array_Element_Shape
                 (Types.all, Tree.all, Node, Callback);
               Landin.Testing.Check
                 (Item, C.Array_Length (Types.all, Template) = 2
                    and then C.Array_Element_Shape
                      (Types.all, Template) = Callback
                    and then C.Array_Element_Shape
                      (Types.all, Tree.all, Node) = Callback
                    and then C.Array_Element_Nominal
                      (Types.all, Template) = C.No_Nominal_Type
                    and then C.Array_Element_Nominal
                      (Types.all, Tree.all, Node) = C.No_Nominal_Type,
                  "child overlays retain length and replace nominal facts");
               C.Note_Array (Types.all, Template, 4, Ty.Bool, Row);
               C.Note_Array (Types.all, Tree.all, Node, 4, Ty.Bool, Row);
               C.Restore_Routine_View (Types.all, Previous);
               Landin.Testing.Check
                 (Item, C.Array_Element_Nominal
                    (Types.all, Template) = Nominal
                    and then C.Array_Element_Nominal
                      (Types.all, Tree.all, Node) = Nominal,
                  "restoring the global view retains its nominal facts");
               C.Activate_Routine_View (Types.all, Instance, Previous);
               Landin.Testing.Check
                 (Item, C.Array_Length (Types.all, Template) = 4
                    and then C.Array_Element_Shape (Types.all, Template) = Row
                    and then C.Array_Element_Shape
                      (Types.all, Tree.all, Node) = Row,
                  "whole-array overlays preserve the recursive child");
               C.Note_Array_Element_Shape
                 (Types.all, Template, (Element => Ty.U16, others => <>));
               C.Note_Array_Element_Shape
                 (Types.all, Tree.all, Node,
                  (Element => Ty.U16, others => <>));
               Landin.Testing.Check
                 (Item, C.Array_Element (Types.all, Template) = Ty.U16
                    and then C.Array_Element
                      (Types.all, Tree.all, Node) = Ty.U16,
                  "scalar replacement updates the compact carrier too");
               C.Restore_Routine_View (Types.all, Previous);
            end;
            declare
               Retained : C.Signature_Part := Pointer_Part;
               Moved : C.Signature_Part := Pointer_Part;
               Base : constant C.Signature_Id := C.Add_Signature
                 (Types.all, [Pointer_Part], Pointer_Part, Site,
                  C_ABI => True);
               Borrowed : constant C.Signature_Id := C.Add_Signature
                 (Types.all, [Pointer_Part], Pointer_Part, Site,
                  Sources => [(Result => 1, Parameter => 1)], C_ABI => True);
               Retaining, Moving : C.Signature_Id;
               Bad_Carrier : C.Field_Shape := Callback;
            begin
               Retained.Escaping := True;
               Moved.Convention := Landin.Syntax.Inout_Convention;
               Retaining := C.Add_Signature
                 (Types.all, [Retained], Pointer_Part, Site, C_ABI => True);
               Moving := C.Add_Signature
                 (Types.all, [Moved], Pointer_Part, Site, C_ABI => True);
               Landin.Testing.Check
                 (Item, not C.Signatures_Agree (Types.all, Base, Borrowed)
                    and then not C.Signatures_Agree
                      (Types.all, Base, Retaining)
                    and then not C.Signatures_Agree (Types.all, Base, Moving),
                  "callback identity retains from, escaping"
                    & " and parameter mode");
               Bad_Carrier.Element := Ty.U8;
               Landin.Testing.Check
                 (Item, not C.Holds (Types.all, Bad_Carrier),
                  "a callback leaf cannot masquerade as a byte scalar");
            end;
            declare
               Functions : constant C.Field_Shape := C.Make_Array_Field
                 (Types.all, 2,
                  (Element => Ty.Usize, Signature => With_Pointer,
                   others => <>));
               Pointers : constant C.Field_Shape := C.Make_Array_Field
                 (Types.all, 2,
                  (Kind => C.Reference_Field, Reference => Pointer,
                   others => <>));
               Nested : constant C.Field_Shape :=
                 C.Make_Array_Field (Types.all, 2, Pointers);
            begin
               Landin.Testing.Check
                 (Item, not C.Contains_References (Types.all, Functions)
                    and then C.Contains_References (Types.all, Nested),
                  "callback parameter types are not references stored in it");
            end;
         end;
      end;
   end R440_Recursive_Array_Foundations;

   procedure R440_Check_Source
     (Item : in out Landin.Testing.Context;
      Text : String;
      Expected : String := "";
      Code : String := "L0301");

   procedure R440_Check_Source
     (Item : in out Landin.Testing.Context;
      Text : String;
      Expected : String := "";
      Code : String := "L0301")
   is
      package D renames Landin.Diagnostics;
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Src : Landin.Source.Source_Id;
      Ran : Natural;
   begin
      Src := Landin.Stages.Add_Source (Work, "r440-source-contract.ldn", Text);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check_Equal (Item, Ran, 4, "the source reaches checking");
      declare
         Reports : constant D.Diagnostic_List := Landin.Stages.Report (Work);
      begin
         Landin.Testing.Check
           (Item, Landin.Stages.Failed (Work) = (Expected /= "")
              and then D.Count (Reports) = (if Expected = "" then 0 else 1),
            "the source has exactly the expected diagnostic count: " & Text);
         if Expected /= "" and then D.Count (Reports) = 1 then
            declare
               Report : constant D.Diagnostic := D.Get (Reports, 1);
            begin
               Landin.Testing.Check
                 (Item, D.Code (Report) = Code
                    and then D.Message (D.Primary (Report)) = Expected
                    and then D.Source_Of (D.Primary (Report)) = Src
                    and then D.Span_Of (D.Primary (Report))
                      /= Landin.Source.Empty_Span,
                  "precise refusal: " & D.Message (D.Primary (Report)));
               if Expected'Length >= 21
                 and then Expected (Expected'First .. Expected'First + 20)
                   = "compiler-owned helper"
               then
                  Landin.Testing.Check
                    (Item, D.Label_Count (Report) = 1
                       and then D.Message (D.Nth_Label (Report, 1))
                         = "this helper contract"
                       and then D.Source_Of (D.Nth_Label (Report, 1)) = Src
                       and then D.Note_Count (Report) = 1
                       and then D.Nth_Note (Report, 1) =
                         "[1610]/[1975]: a helper import must preserve its"
                         & " source types, pointer permissions"
                         & " and nullability;"
                         & " [0780] retains argv and [0790] preserves from",
                     "helper refusal retains the exact related contract note");
               end if;
            end;
         end if;
      end;
   end R440_Check_Source;

   procedure R440_Array_Field_Copies_Compare_Complete_Children
     (Item : in out Landin.Testing.Context);

   procedure R440_Array_Field_Copies_Compare_Complete_Children
     (Item : in out Landin.Testing.Context)
   is
      Foundation : constant String :=
        "counter: type = concept (t: type)" & LF
        & "    bump: (self: ptr mut t) -> (value: i32)" & LF
        & "end counter" & LF
        & "node: type = struct" & LF
        & "    value: i32" & LF
        & "end node" & LF
        & "bump_node: (self: ptr mut node) -> (value: i32) =" & LF
        & "    inc self.val.value" & LF
        & "    value = self.val.value" & LF
        & "end bump_node" & LF
        & "node is counter (bump: bump_node)" & LF
        & "row: type (t: type, fixed n: usize) = [n]t" & LF
        & "copy: (fixed n: usize, t: type, source: row(t, n))" & LF
        & "      -> (result: row(t, n) from source) =" & LF
        & "    result = source" & LF
        & "end copy" & LF
        & "identity: (t: type, value: t) -> (result: t from value) =" & LF
        & "    result = value" & LF
        & "end identity" & LF
        & "shelf: type (t: type) = struct" & LF
        & "    values: [2]t" & LF
        & "end shelf" & LF;
   begin
      --  A complex element's scalar carrier is storage bookkeeping, not part
      --  of D17's identity.  Generic result overlays may spell that carrier
      --  differently while retaining the same complete reference/concept
      --  child.  This is the path exercised by both existing runtime fixtures.
      R440_Check_Source
        (Item, Foundation
         & "use: () -> none =" & LF
         & "    mut local: node = (value: 0)" & LF
         & "    mut pointers: [2]ptr mut node" & LF
         & "    pointers[0] = addr local" & LF
         & "    pointers[1] = addr local" & LF
         & "    mut pointer_copy: [2]ptr mut node =" & LF
         & "      identity(copy(pointers))" & LF
         & "    pointer_shelf: shelf(ptr mut node) =" & LF
         & "      (values: pointer_copy)" & LF
         & "    mut erased: [2]any counter" & LF
         & "    erased[0] = any(addr local)" & LF
         & "    erased[1] = any(addr local)" & LF
         & "    mut erased_copy: [2]any counter = identity(copy(erased))" & LF
         & "    erased_shelf: shelf(any counter) = (values: erased_copy)" & LF
         & "end use" & LF);

      R440_Check_Source
        (Item, Foundation
         & "bad: () -> none =" & LF
         & "    mut local: node = (value: 0)" & LF
         & "    mut values: [2]ptr node" & LF
         & "    values[0] = addr local" & LF
         & "    values[1] = addr local" & LF
         & "    stored: shelf(ptr mut node) = (values: values)" & LF
         & "end bad" & LF,
         "this is not an array of the type named by the struct field");
   end R440_Array_Field_Copies_Compare_Complete_Children;

   procedure R440_Helper_Source_Contracts
     (Item : in out Landin.Testing.Context);

   procedure R440_Helper_Source_Contracts
     (Item : in out Landin.Testing.Context)
   is
      function Helper (Index : Positive) return String;

      function Helper (Index : Positive) return String
        is ("_landin_host_" & (case Index is
              when 1 => "initialize_arguments", when 2 => "argument_count",
              when 3 => "argument_table", when 4 => "argument_at",
              when 5 => "argument_at_from", when 6 => "text_length",
              when 7 => "open_read", when 8 => "open_write",
              when 9 => "read", when 10 => "write", when 11 => "close",
              when 12 => "errno", when 13 => "heap_allocate",
              when 14 => "heap_release", when others => "not_a_helper"));

      procedure Refuse
        (Index : Positive; Signature, Requirement : String;
         Prefix : String := "");

      procedure Refuse
        (Index : Positive; Signature, Requirement : String;
         Prefix : String := "") is
      begin
         R440_Check_Source
           (Item, Prefix & "extern(c) link(symbol: """ & Helper (Index)
            & """) bridge: " & Signature & LF,
            "compiler-owned helper `" & Helper (Index) & "` " & Requirement);
      end Refuse;

      procedure Initializer (Argv : String; Prefix : String := "");

      procedure Initializer (Argv : String; Prefix : String := "") is
      begin
         Refuse
           (1, "(argc: i32, escaping argv: " & Argv & ") -> none",
            "requires parameter 2 to be `ptr ptr u8`", Prefix);
      end Initializer;
   begin
      for Index in 1 .. 14 loop
         for Form in 1 .. 3 loop
            declare
               Name : constant String :=
                 (if Form = 2 then Helper (Index) else "bridge");
               Prefix : constant String :=
                 (if Form = 1 then "link(symbol: """ & Helper (Index) & """) "
                  elsif Form = 2 then "public extern(c) "
                  else "extern(c) link(symbol: """ & Helper (Index) & """) ");
            begin
               R440_Check_Source
                 (Item, Prefix & Name & ": () -> none =" & LF
                  & "end " & Name & LF,
                  "compiler-owned helper `" & Helper (Index)
                  & "` cannot be defined by source");
            end;
         end loop;
         --  Source spelling alone is not a forced linker identity.
         R440_Check_Source
           (Item, Helper (Index) & ": () -> none =" & LF
            & "end " & Helper (Index) & LF);
         R440_Check_Source
           (Item, "extern(c) " & Helper (Index) & ": () -> none =" & LF
            & "end " & Helper (Index) & LF);
      end loop;
      R440_Check_Source
        (Item, "link(symbol: ""_landin_host_not_a_helper"") local:"
         & " () -> none =" & LF & "end local" & LF
         & "extern(c) malloc: () -> none" & LF
         & "extern(c) link(symbol: ""$foreign.entry"") odd: () -> none" & LF);
      Refuse
        (1, "(argc: i32, argv: ptr ptr u8) -> none",
         "requires escaping argv");
      Refuse
        (1, "(argc: usize, escaping argv: ptr ptr u8) -> none",
         "requires parameter 1 to be `i32`");
      Refuse
        (1, "(argc: i32, escaping argv: usize) -> none",
         "requires parameter 2 to be `ptr ptr u8`");
      Initializer ("ptr u8");
      Initializer ("ptr ptr u32");
      Initializer ("ptr mut ptr u8");
      Initializer ("ptr ptr mut u8");
      Initializer
        ("maybe_table", "missing: atom" & LF
         & "maybe_table: type = missing | ptr ptr u8" & LF);
      Initializer
        ("ptr maybe_byte", "missing: atom" & LF
         & "maybe_byte: type = missing | ptr u8" & LF);
      Initializer
        ("ptr ptr byte_record", "byte_record: type = layout(c) struct" & LF
         & "    value: u8" & LF & "end byte_record" & LF);
      Refuse (1, "(argc: i32) -> none", "requires 2 parameters and no result");
      Refuse
        (1, "(argc: i32, escaping argv: ptr ptr u8) -> (value: i32)",
         "requires 2 parameters and no result");
      Refuse
        (1, "(argc: i32, escaping argv: ptr ptr u8, ...) -> none",
         "requires a fixed infallible C import");
      Refuse (2, "() -> (count: u64)", "requires result `usize`");
      Refuse (3, "() -> (table: ptr u8)", "requires result `ptr ptr u8`");
      Refuse
        (4, "(index: usize) -> (value: ptr mut u8)",
         "requires result `ptr u8 or cstring`");
      Refuse
        (5, "(table: ptr ptr u8, index: usize) -> (value: ptr u8)",
         "requires its result from parameter 1");
      Refuse
        (5, "(table: ptr ptr u8, index: usize)"
         & " -> (value: ptr u8 from index)",
         "requires its result from parameter 1");
      Refuse
        (5, "(table: ptr ptr u8, index: usize)"
         & " -> (value: ptr u8 from table, index)",
         "requires its result from parameter 1");
      Refuse
        (6, "(data: ptr u32) -> (length: usize)",
         "requires parameter 1 to be `ptr u8`");
      Refuse
        (7, "(path: ptr mut u8) -> (fd: i32)",
         "requires parameter 1 to be `ptr u8`");
      Refuse
        (8, "(path: ptr u8) -> (fd: u32)", "requires result `i32`");
      Refuse
        (9, "(fd: i32, data: ptr u8, length: usize) -> (count: usize)",
         "requires parameter 2 to be `ptr mut u8`");
      Refuse
        (10, "(fd: i32, data: ptr u8, length: u64) -> (count: usize)",
         "requires parameter 3 to be `usize`");
      Refuse (11, "(fd: u32) -> (status: i32)",
              "requires parameter 1 to be `i32`");
      Refuse (12, "() -> (number: u32)", "requires result `i32`");
      Refuse
        (13, "(length: usize, alignment: usize) -> (data: ptr mut u8)",
         "requires result `one atom | ptr mut u8`");
      Refuse (14, "(data: ptr u8) -> none",
              "requires parameter 1 to be `ptr mut u8`");
      R440_Check_Source
        (Item, "byte: type = u8" & LF & "size: type = usize" & LF
         & "bytes: type = ptr byte" & LF & "table: type = ptr bytes" & LF
         & "no_memory: atom" & LF
         & "allocation: type = no_memory | ptr mut byte" & LF
         & "extern(c) " & Helper (1)
         & ": (escaping argc: i32, escaping argv: table) -> none" & LF
         & "extern(c) " & Helper (2) & ": () -> (count: size)" & LF
         & "extern(c) " & Helper (3) & ": () -> (argv: table)" & LF
         & "extern(c) " & Helper (4) & ": (i: size) -> (data: bytes)" & LF
         & "extern(c) " & Helper (5)
         & ": (argv: table, i: size) -> (data: bytes from argv)" & LF
         & "extern(c) " & Helper (6) & ": (p: bytes) -> (n: size)" & LF
         & "extern(c) " & Helper (7) & ": (p: bytes) -> (fd: i32)" & LF
         & "extern(c) " & Helper (8) & ": (p: bytes) -> (fd: i32)" & LF
         & "extern(c) " & Helper (9)
         & ": (fd: i32, p: ptr mut byte, n: size) -> (count: size)" & LF
         & "extern(c) " & Helper (10)
         & ": (fd: i32, p: bytes, n: size) -> (count: size)" & LF
         & "extern(c) " & Helper (11) & ": (fd: i32) -> (status: i32)" & LF
         & "extern(c) " & Helper (12) & ": () -> (error: i32)" & LF
         & "extern(c) " & Helper (13)
         & ": (n: size, a: size) -> (data: allocation)" & LF
         & "extern(c) " & Helper (14) & ": (p: ptr mut byte) -> none" & LF
         & "extern(c) link(symbol: """ & Helper (1) & """) initialize:"
         & " (escaping count: i32, escaping pointers: ptr ptr u8) -> none"
         & LF);
      R440_Check_Source
        (Item, "extern(c) " & Helper (4)
         & ": (index: usize) -> (value: cstring)" & LF);
      R440_Check_Source
        (Item, "extern(c) " & Helper (4)
         & ": (index: usize) -> (value: ptr u8)" & LF
         & "extern(c) link(symbol: """ & Helper (4) & """) text:"
         & " (index: usize) -> (value: cstring)" & LF,
         "this C link symbol collides with another declaration or definition");
      R440_Check_Source
        (Item, "extern(c) " & Helper (1)
         & ": (argc: i32, escaping argv: ptr ptr u8) -> none" & LF
         & "forward: (argv: ptr ptr u8) -> none =" & LF
         & "    " & Helper (1) & "(0, argv)" & LF & "end forward" & LF,
         "this parameter is non-escaping, so its reference cannot be retained"
         & " by the called function", "L0314");
   end R440_Helper_Source_Contracts;

   procedure R440_Hosted_Main_Linkage
     (Item : in out Landin.Testing.Context);

   procedure R440_Hosted_Main_Linkage
     (Item : in out Landin.Testing.Context)
   is
      Main : constant String := "public main: () -> (code: i32) =" & LF
        & "    code = 0" & LF & "end main" & LF;
      Import_Main : constant String :=
        "extern(c) link(symbol: ""main"") foreign: () -> (result: i32)" & LF;
      Define_Main : constant String :=
        "link(symbol: ""main"") foreign: () -> (result: i32) =" & LF
        & "    result = 0" & LF & "end foreign" & LF;
      Expected : constant String :=
        "link symbol `main` collides with the selected native hosted entry";
   begin
      R440_Check_Source (Item, Main & Import_Main, Expected);
      R440_Check_Source (Item, Import_Main & Main, Expected);
      R440_Check_Source (Item, Main & Define_Main, Expected);
      R440_Check_Source (Item, Define_Main & Main, Expected);
      R440_Check_Source
        (Item, "public link(symbol: ""renamed"") main: () -> (code: i32) ="
         & LF & "    code = 0" & LF & "end main" & LF & Import_Main);
      R440_Check_Source
        (Item, "public extern(c) link(symbol: ""c_entry"") main:"
         & " () -> (code: i32) =" & LF & "    code = 0" & LF
         & "end main" & LF & Import_Main);
      R440_Check_Source
        (Item, "public extern(c) main: () -> (code: i32) =" & LF
         & "    code = 0" & LF & "end main" & LF & Import_Main);
      R440_Check_Source (Item, Define_Main);
      R440_Check_Source
        (Item, "public main: () -> (result: i32) =" & LF
         & "    result = 0" & LF & "end main" & LF & Import_Main);
   end R440_Hosted_Main_Linkage;

   procedure R440_Recursive_Source_Contexts
     (Item : in out Landin.Testing.Context);

   procedure R440_Recursive_Source_Contexts
     (Item : in out Landin.Testing.Context)
   is
      Numeric : constant String :=
        "row: type = [3]i32" & LF & "matrix: type = [2]row" & LF
        & "record: type = layout(c) struct" & LF
        & "    values: matrix" & LF & "end record" & LF
        & "alias: type = record" & LF
        & "image: alias = alias(values: [[1 + 2, 4, 5], [3 of 6]])" & LF
        & "copy: record = image" & LF & "again: alias = copy" & LF;
      Callbacks : constant String :=
        "handler: type = extern(c) (value: i32) -> (result: i32)" & LF
        & "callbacks: type = layout(c) struct" & LF
        & "    values: [2][2]handler" & LF & "end callbacks" & LF
        & "extern(c) add: (value: i32) -> (result: i32) =" & LF
        & "    result = value + 1" & LF & "end add" & LF;
   begin
      R440_Check_Source
        (Item, Numeric
         & "identity: (t: type, value: t) -> (result: t) =" & LF
         & "    result = value" & LF & "end identity" & LF
         & "make: (flag: bool) -> (result: matrix) =" & LF
         & "    result = if flag then [[1, 2, 3], [3 of 4]]" & LF
         & "             else [of [1, of 2]] end if" & LF & "end make" & LF
         & "use: (flag: bool, index: usize) -> (result: i32) =" & LF
         & "    mut values: matrix = [[1, 2, 3], of [of 4]]" & LF
         & "    zero: matrix = zeroed" & LF
         & "    copied: matrix = identity(values)" & LF
         & "    values[0] = [3 of 7]" & LF
         & "    pointer: ptr mut matrix = addr values" & LF
         & "    pointer.val[index][1] = copied[1][2]" & LF
         & "    chosen: matrix = make(flag)" & LF
         & "    result = pointer.val[index][1] + chosen[0][0]"
         & " + zero[1][2] + again.values[1][0]" & LF & "end use" & LF);
      R440_Check_Source
        (Item, Callbacks
         & "image: callbacks = callbacks(values: [[add, add], [2 of add]])"
         & LF & "copy: callbacks = image" & LF
         & "select: (input: callbacks) -> (result: callbacks) =" & LF
         & "    result = callbacks(values: [input.values[1],"
         & " [input.values[0][1], input.values[0][0]]])" & LF
         & "end select" & LF
         & "use: (row: usize, column: usize) -> (result: i32) =" & LF
         & "    mut local: callbacks = select(copy)" & LF
         & "    pointer: ptr mut callbacks = addr local" & LF
         & "    pointer.val.values[row][column] = add" & LF
         & "    mut values: [2][2]handler = local.values" & LF
         & "    array_pointer: ptr mut [2][2]handler = addr values" & LF
         & "    array_pointer.val[row][column] = add" & LF
         & "    result = array_pointer.val[row][column](41)" & LF
         & "end use" & LF);
      R440_Check_Source
        (Item, "leaf: type = layout(c) struct" & LF
         & "    value: i32" & LF & "end leaf" & LF
         & "use: () -> (result: i32) =" & LF
         & "    values: [2][2]leaf = zeroed" & LF
         & "    result = values[1][1].value" & LF & "end use" & LF);
      R440_Check_Source
        (Item, Callbacks & "use: () -> none =" & LF
         & "    values: [2][2]handler = zeroed" & LF & "end use" & LF,
         "this array has no all-bits-zero value");
      R440_Check_Source
        (Item, "use: () -> none =" & LF
         & "    values: [2][2]ptr u8 = zeroed" & LF & "end use" & LF,
         "this array has no all-bits-zero value");
      R440_Check_Source
        (Item, Callbacks
         & "wrapper: type = struct" & LF
         & "    tag: i32" & LF & "    values: [2][2]handler" & LF
         & "end wrapper" & LF
         & "use: () -> none =" & LF
         & "    value: wrapper = wrapper(tag: 0, of zeroed)" & LF
         & "end use" & LF,
         "`of zeroed` cannot fill field `values`, which has no zero image");
      R440_Check_Source
        (Item, "use: () -> none =" & LF
         & "    values: [2][2]i32 = [[1, 2], [3]]" & LF & "end use" & LF,
         "this literal has 1 element, and its array context has a"
         & " different length");
      R440_Check_Source
        (Item, "bad: type = layout(c) struct" & LF
         & "    values: [2][0]i32" & LF & "end bad" & LF,
         "this layout(c) struct has a non-C representation");
      R440_Check_Source
        (Item, Callbacks & "use: () -> none =" & LF
         & "    values := [add, add]" & LF & "end use" & LF,
         "a non-scalar array literal needs an explicit element type", "L0304");
      R440_Check_Source
        (Item, Callbacks & "use: (flag: bool) -> none =" & LF
         & "    values := if flag then [add, add] else [add, add] end if" & LF
         & "end use" & LF,
         "a non-scalar array literal needs an explicit element type", "L0304");
      R440_Check_Source
        (Item, "record: type = layout(c) struct" & LF
         & "    values: [1][1]u8" & LF & "end record" & LF
         & "alias: type = record" & LF
         & "image: alias = alias(values: [[255 + 1]])" & LF,
         "this image value works out to 256, and no `u8` holds it", "L0300");
      R440_Check_Source
        (Item, "record: type = layout(c) struct" & LF
         & "    values: [2][1]i32" & LF & "end record" & LF
         & "first: record = second" & LF & "second: record = first" & LF,
         "the initial image of `first` is worked out from itself", "L0305");
   end R440_Recursive_Source_Contexts;

   procedure Variant_Array_Elements_Keep_Case_Identity
     (Item : in out Landin.Testing.Context);

   procedure Variant_Array_Elements_Keep_Case_Identity
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran : Natural;
      Src : Landin.Source.Source_Id;
      Seen : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "variant-array.ldn",
         "choice: type = struct" & LF
         & " kind: variant pair: (first: i32, second: i32)"
         & " | empty end kind" & LF & "end choice" & LF
         & "f: () -> none =" & LF
         & " mut values: [2]choice ="
         & " [(kind: pair(first: 40, second: 2)), (kind: empty)]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      Landin.Testing.Check_Equal (Item, Ran, 4, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "variant-valued array literals are accepted");
      declare
         Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
           .. Landin.Syntax.Last_Node (Tree.all)
         loop
            if Landin.Syntax.Kind (Tree.all, Node)
                 = Landin.Syntax.Field_Value
              and then Landin.Source.Names.Spelling
                (Landin.Stages.Identities (Work).all,
                 Landin.Syntax.Name (Tree.all, Node)) = "kind"
            then
               Seen := Seen + 1;
               Landin.Testing.Check_Equal
                 (Item, Landin.Checking.Field_Index
                    (Types.all, Tree.all,
                     Landin.Syntax.Value_Of (Tree.all, Node)),
                  Seen, "each array element retains its selected case");
            end if;
         end loop;
      end;
      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both variant initializers were inspected");
   end Variant_Array_Elements_Keep_Case_Identity;

   procedure Construction_Arguments_Keep_Value_Forms
     (Item : in out Landin.Testing.Context);

   procedure Construction_Arguments_Keep_Value_Forms
     (Item : in out Landin.Testing.Context) is
   begin
      R440_Check_Source
        (Item,
         "display: type = concept (t: type)" & LF
         & "get: (self: ptr t) -> (r: i32)" & LF
         & "end display" & LF
         & "thing: type = struct value: i32 end thing" & LF
         & "get_thing: (self: ptr thing) -> (r: i32) =" & LF
         & "r = self.val.value end get_thing" & LF
         & "thing is display (get: get_thing)" & LF
         & "holder: type = struct item: any display end holder" & LF
         & "f: () -> none =" & LF
         & "local: thing = (value: 42)" & LF
         & "wrapped: holder = holder(item: any(addr local))" & LF
         & "contextual: holder = (item: any(addr local))" & LF
         & "end f" & LF);
      R440_Check_Source
        (Item,
         "triple: type = struct x: i32 y: i32 z: i32 end triple" & LF
         & "image: triple = triple(x: 1, of 2)" & LF
         & "f: () -> none =" & LF
         & "local: triple = triple(x: 1, y: 2, of 3)" & LF
         & "contextual: triple = (x: 1, of 2)" & LF
         & "end f" & LF);
   end Construction_Arguments_Keep_Value_Forms;

   procedure Static_Fields_Check_Evaluated_Values
     (Item : in out Landin.Testing.Context);

   procedure Static_Fields_Check_Evaluated_Values
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Source
        (Label, Text : String; Accepted : Boolean;
         Code : String := "L0305");

      procedure Check_Source
        (Label, Text : String; Accepted : Boolean;
         Code : String := "L0305")
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source (Work, "static-fields.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check_Equal
              (Item, Ran, 4, Label & " reaches checking");
            Landin.Testing.Check
              (Item, Landin.Stages.Failed (Work) /= Accepted
                 and then
                   (if Accepted then Landin.Diagnostics.Count (Reports) = 0
                    else Landin.Diagnostics.Count (Reports) = 1
                      and then Landin.Diagnostics.Code
                        (Landin.Diagnostics.Get (Reports, 1)) = Code),
               Label & " retains its exact static-image verdict");
         end;
      end Check_Source;

   begin
      Check_Source
        ("ordinary reference call",
         "make: () -> (r: utf8) = r = ""ok"" end make" & LF
         & "holder: type = struct value: utf8 end holder" & LF
         & "image: holder = (value: make())" & LF,
         Accepted => False);
      Check_Source
        ("nominal reference call",
         "make: () -> (r: utf8) = r = ""ok"" end make" & LF
         & "holder: type = struct value: utf8 end holder" & LF
         & "image: holder = holder(value: make())" & LF,
         Accepted => False);
      Check_Source
        ("reference fill call",
         "make: () -> (r: utf8) = r = ""ok"" end make" & LF
         & "holder: type = struct first: utf8 second: utf8 end holder" & LF
         & "image: holder = (first: ""ok"", of make())" & LF,
         Accepted => False);
      Check_Source
        ("nested reference call",
         "make: () -> (r: utf8) = r = ""ok"" end make" & LF
         & "holder: type = struct value: utf8 end holder" & LF
         & "outer: type = struct child: holder end outer" & LF
         & "image: outer = (child: (value: make()))" & LF,
         Accepted => False);
      Check_Source
        ("variant reference call",
         "make: () -> (r: utf8) = r = ""ok"" end make" & LF
         & "choice: type = struct kind: variant empty | text: "
         & "(value: utf8) end kind end choice" & LF
         & "image: choice = (kind: text(value: make()))" & LF,
         Accepted => False);
      Check_Source
        ("variant reference fill",
         "make: () -> (r: utf8) = r = ""ok"" end make" & LF
         & "choice: type = struct kind: variant empty | text: "
         & "(first: utf8, second: utf8) end kind end choice" & LF
         & "image: choice = (kind: text(first: ""ok"", of make()))" & LF,
         Accepted => False);
      Check_Source
        ("direct reference call",
         "make: () -> (r: utf8) = r = ""ok"" end make" & LF
         & "image: utf8 = make()" & LF,
         Accepted => False);
      Check_Source
        ("local reference calls",
         "make: () -> (r: utf8) = r = ""ok"" end make" & LF
         & "holder: type = struct value: utf8 end holder" & LF
         & "choice: type = struct kind: variant empty | text: "
         & "(value: utf8) end kind end choice" & LF
         & "f: () -> none =" & LF
         & "local: holder = (value: make())" & LF
         & "selected: choice = (kind: text(value: make()))" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("known reference fields",
         "holder: type = struct text: utf8 pointer: ptr i32 end holder" & LF
         & "image: holder = (text: ""ok"", pointer: ptr(4096))" & LF,
         Accepted => True);
      Check_Source
        ("known variant reference",
         "choice: type = struct kind: variant empty | text: "
         & "(value: utf8) end kind end choice" & LF
         & "image: choice = (kind: text(value: ""ok""))" & LF,
         Accepted => True);
      Check_Source
        ("known empty slice",
         "holder: type = struct value: utf8 end holder" & LF
         & "image: holder = (value: [])" & LF,
         Accepted => True);
      Check_Source
        ("reference type mismatch",
         "make: () -> (r: i32) = r = 1 end make" & LF
         & "holder: type = struct value: utf8 end holder" & LF
         & "image: holder = (value: make())" & LF,
         Accepted => False, Code => "L0301");
      Check_Source
        ("unevaluated address measurement",
         "target: i32 = 0" & LF
         & "image: usize = lenof ([usize(addr target)])" & LF,
         Accepted => True);
      Check_Source
        ("unevaluated address field",
         "target: i32 = 0" & LF
         & "holder: type = struct n: usize end holder" & LF
         & "image: holder = (n: lenof ([usize(addr target)]))" & LF,
         Accepted => True);
      Check_Source
        ("unevaluated address payload",
         "target: i32 = 0" & LF
         & "choice: type = struct kind: variant empty | size: (n: "
         & "usize) end kind end choice" & LF
         & "image: choice = (kind: size(n: lenof ([usize(addr "
         & "target)])))" & LF,
         Accepted => True);
      Check_Source
        ("evaluated address field",
         "target: i32 = 0" & LF
         & "holder: type = struct n: usize end holder" & LF
         & "image: holder = (n: usize(addr target))" & LF,
         Accepted => False);
      Check_Source
        ("evaluated pointer field",
         "target: i32 = 0" & LF
         & "holder: type = struct p: ptr i32 end holder" & LF
         & "image: holder = (p: addr target)" & LF,
         Accepted => False);
      Check_Source
        ("distinct payload",
         "meter: type = distinct u32" & LF
         & "choice: type = struct kind: variant empty | spot: (m: "
         & "meter) end kind end choice" & LF
         & "image: choice = (kind: spot(m: meter(5)))" & LF,
         Accepted => True);
      Check_Source
        ("distinct ordinary field",
         "meter: type = distinct u32" & LF
         & "holder: type = struct m: meter end holder" & LF
         & "image: holder = (m: meter(5))" & LF,
         Accepted => True);
      Check_Source
        ("distinct payload identity",
         "meter: type = distinct u32" & LF
         & "other: type = distinct u32" & LF
         & "choice: type = struct kind: variant empty | spot: (m: "
         & "meter) end kind end choice" & LF
         & "image: choice = (kind: spot(m: other(5)))" & LF,
         Accepted => False, Code => "L0301");
      Check_Source
        ("unevaluated address array element",
         "target: i32 = 0" & LF
         & "image: [2]usize = [lenof ([usize(addr target)]), 2]" & LF,
         Accepted => True);
      Check_Source
        ("unevaluated address repeated element",
         "target: i32 = 0" & LF
         & "image: [2]usize = [2 of lenof ([usize(addr target)])]" & LF,
         Accepted => True);
      Check_Source
        ("unevaluated address mixed repetition",
         "target: i32 = 0" & LF
         & "image: [2]usize = [0, of lenof ([usize(addr target)])]" & LF,
         Accepted => True);
   end Static_Fields_Check_Evaluated_Values;

   procedure Refused_Values_Always_Report
     (Item : in out Landin.Testing.Context);

   procedure Refused_Values_Always_Report
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Source
        (Label, Text : String; Accepted : Boolean;
         Code : String := "L0304");

      procedure Check_Source
        (Label, Text : String; Accepted : Boolean;
         Code : String := "L0304")
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source (Work, "refused-values.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check_Equal
              (Item, Ran, 4, Label & " reaches checking");
            Landin.Testing.Check
              (Item, Landin.Stages.Failed (Work) /= Accepted
                 and then
                   (if Accepted then Landin.Diagnostics.Count (Reports) = 0
                    else Landin.Diagnostics.Count (Reports) = 1
                      and then Landin.Diagnostics.Code
                        (Landin.Diagnostics.Get (Reports, 1)) = Code),
               Label & " retains its exact source verdict");
         end;
      end Check_Source;

   begin
      Check_Source
        ("module struct refusal",
         "box: type (t: type) = struct value: t end box" & LF
         & "item: box(u8) = 5" & LF,
         Accepted => False);
      Check_Source
        ("module struct initializer",
         "box: type (t: type) = struct value: t end box" & LF
         & "item: box(u8) = (value: 5)" & LF,
         Accepted => True);
      Check_Source
        ("local struct refusal",
         "box: type (t: type) = struct value: t end box" & LF
         & "f: () -> none =" & LF
         & "item: box(u8) = 5" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("local struct initializer",
         "box: type (t: type) = struct value: t end box" & LF
         & "f: () -> none =" & LF
         & "item: box(u8) = (value: 5)" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("module nested struct refusal",
         "box: type (t: type) = struct value: t end box" & LF
         & "outer: type (t: type) = struct child: box(t) end outer" & LF
         & "item: outer(u8) = 5" & LF,
         Accepted => False);
      Check_Source
        ("module nested struct initializer",
         "box: type (t: type) = struct value: t end box" & LF
         & "outer: type (t: type) = struct child: box(t) end outer" & LF
         & "item: outer(u8) = (child: (value: 5))" & LF,
         Accepted => True);
      Check_Source
        ("local nested struct refusal",
         "box: type (t: type) = struct value: t end box" & LF
         & "outer: type (t: type) = struct child: box(t) end outer" & LF
         & "f: () -> none =" & LF
         & "item: outer(u8) = 5" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("local nested struct initializer",
         "box: type (t: type) = struct value: t end box" & LF
         & "outer: type (t: type) = struct child: box(t) end outer" & LF
         & "f: () -> none =" & LF
         & "item: outer(u8) = (child: (value: 5))" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("module variant struct refusal",
         "choice: type (t: type) = struct tag: variant empty "
         & "| value: (held: t) end tag end choice" & LF
         & "item: choice(u8) = 5" & LF,
         Accepted => False);
      Check_Source
        ("module variant struct initializer",
         "choice: type (t: type) = struct tag: variant empty "
         & "| value: (held: t) end tag end choice" & LF
         & "item: choice(u8) = (tag: value(held: 5))" & LF,
         Accepted => True);
      Check_Source
        ("local variant struct refusal",
         "choice: type (t: type) = struct tag: variant empty "
         & "| value: (held: t) end tag end choice" & LF
         & "f: () -> none =" & LF
         & "item: choice(u8) = 5" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("local variant struct initializer",
         "choice: type (t: type) = struct tag: variant empty "
         & "| value: (held: t) end tag end choice" & LF
         & "f: () -> none =" & LF
         & "item: choice(u8) = (tag: value(held: 5))" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("module array refusal",
         "row: type (t: type, fixed n: usize) = [n]t" & LF
         & "item: row(u8, 2) = 5" & LF,
         Accepted => False);
      Check_Source
        ("module array initializer",
         "row: type (t: type, fixed n: usize) = [n]t" & LF
         & "item: row(u8, 2) = [5, 6]" & LF,
         Accepted => True);
      Check_Source
        ("local array refusal",
         "row: type (t: type, fixed n: usize) = [n]t" & LF
         & "f: () -> none =" & LF
         & "item: row(u8, 2) = 5" & LF
         & "end f" & LF,
         Accepted => False);
      Check_Source
        ("local array initializer",
         "row: type (t: type, fixed n: usize) = [n]t" & LF
         & "f: () -> none =" & LF
         & "item: row(u8, 2) = [5, 6]" & LF
         & "end f" & LF,
         Accepted => True);
      Check_Source
        ("named struct alias refusal",
         "box: type (t: type) = struct value: t end box" & LF
         & "alias: type = box(u8)" & LF
         & "item: alias = 5" & LF,
         Accepted => False);
      Check_Source
        ("named array alias refusal",
         "row: type (t: type, fixed n: usize) = [n]t" & LF
         & "alias: type = row(u8, 2)" & LF
         & "item: alias = 5" & LF,
         Accepted => False);
      Check_Source
        ("inline array refusal",
         "item: [2]u8 = 5" & LF,
         Accepted => False);
      Check_Source
        ("integer slice",
         "f: (value: u32) -> none =" & LF
         & "_ = value[0..2]" & LF
         & "end f" & LF,
         Accepted => False, Code => "L0301");
      Check_Source
        ("boolean slice",
         "f: (value: bool) -> none =" & LF
         & "_ = value[0..<2]" & LF
         & "end f" & LF,
         Accepted => False, Code => "L0301");
      Check_Source
        ("ordinary pointer slice",
         "f: (value: ptr u32) -> none =" & LF
         & "_ = value[0..2]" & LF
         & "end f" & LF,
         Accepted => False, Code => "L0301");
      Check_Source
        ("half-open pointer slice",
         "f: (value: ptr u32) -> none =" & LF
         & "_ = value[0..<2]" & LF
         & "end f" & LF,
         Accepted => False, Code => "L0301");
      Check_Source
        ("cstring slice",
         "f: (value: cstring) -> none =" & LF
         & "_ = value[0..<2]" & LF
         & "end f" & LF,
         Accepted => False, Code => "L0301");
      Check_Source
        ("aggregate slice",
         "box: type = struct value: i32 end box" & LF
         & "f: (value: box) -> none =" & LF
         & "_ = value[0..2]" & LF
         & "end f" & LF,
         Accepted => False, Code => "L0301");
      Check_Source
        ("callback slice",
         "f: (value: () -> none) -> none =" & LF
         & "_ = value[0..<2]" & LF
         & "end f" & LF,
         Accepted => False, Code => "L0301");
      Check_Source
        ("array slice",
         "f: (value: [3]u8) -> none =" & LF
         & "_ = value[0..2]" & LF
         & "end f" & LF,
         Accepted => True, Code => "L0301");
      Check_Source
        ("slice view",
         "f: (value: []u8) -> none =" & LF
         & "_ = value[0..<2]" & LF
         & "end f" & LF,
         Accepted => True, Code => "L0301");
      Check_Source
        ("text slice",
         "f: (value: utf8) -> none =" & LF
         & "_ = value[0..<2]" & LF
         & "end f" & LF,
         Accepted => True, Code => "L0301");
      Check_Source
        ("slice bound type refusal",
         "f: (value: [3]u8) -> none =" & LF
         & "_ = value[false ..< 2]" & LF
         & "end f" & LF,
         Accepted => False, Code => "L0301");
   end Refused_Values_Always_Report;

   procedure Range_Type_Actuals_Are_Refused
     (Item : in out Landin.Testing.Context);

   procedure Range_Type_Actuals_Are_Refused
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Source
        (Label, Text : String; Accepted : Boolean;
         Code : String := "L0304");

      procedure Check_Source
        (Label, Text : String; Accepted : Boolean;
         Code : String := "L0304")
      is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source
           (Work, "range-type-actuals.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            Landin.Testing.Check_Equal
              (Item, Ran, 4, Label & " reaches checking");
            Landin.Testing.Check
              (Item, Landin.Stages.Failed (Work) /= Accepted
                 and then
                   (if Accepted then Landin.Diagnostics.Count (Reports) = 0
                    else Landin.Diagnostics.Count (Reports) = 1
                      and then Landin.Diagnostics.Code
                        (Landin.Diagnostics.Get (Reports, 1)) = Code),
               Label & " retains its exact source verdict");
         end;
      end Check_Source;

   begin
      Check_Source
        ("constrained struct",
         "percent: type = u8 range 0..100" & LF
         & "cell: type (t: type) = struct value: t end cell" & LF
         & "mut a: cell(percent)" & LF,
         Accepted => False);
      Check_Source
        ("constrained array",
         "percent: type = u8 range 0..100" & LF
         & "row: type (t: type, fixed n: u32) = [n]t" & LF
         & "mut a: row(percent, 3)" & LF,
         Accepted => False);
      Check_Source
        ("constrained alias",
         "percent: type = u8 range 0..100" & LF
         & "cell: type (t: type) = struct value: t end cell" & LF
         & "alias: type = percent" & LF
         & "mut a: cell(alias)" & LF,
         Accepted => False);
      Check_Source
        ("identity alias",
         "percent: type = u8 range 0..100" & LF
         & "identity: type (t: type) = t" & LF
         & "mut a: identity(percent)" & LF,
         Accepted => False);
      Check_Source
        ("unused actual",
         "percent: type = u8 range 0..100" & LF
         & "constant: type (t: type) = u8" & LF
         & "mut a: constant(percent)" & LF,
         Accepted => False);
      Check_Source
        ("nested actual",
         "percent: type = u8 range 0..100" & LF
         & "cell: type (t: type) = struct value: t end cell" & LF
         & "identity: type (t: type) = t" & LF
         & "mut a: cell(identity(percent))" & LF,
         Accepted => False);
      Check_Source
        ("template fixed subtype",
         "percent: type = u8 range 0..100" & LF
         & "cell: type (t: type) = struct value: t end cell" & LF
         & "outer: type (t: type) = struct" & LF
         & "value: cell(percent) end outer" & LF,
         Accepted => False);
      Check_Source
        ("local constrained struct",
         "percent: type = u8 range 0..100" & LF
         & "cell: type (t: type) = struct value: t end cell" & LF
         & "f: () -> none = mut a: cell(percent) = zeroed end f" & LF,
         Accepted => False);
      Check_Source
        ("unconstrained struct",
         "cell: type (t: type) = struct value: t end cell" & LF
         & "mut a: cell(u8)" & LF,
         Accepted => True);
      Check_Source
        ("unconstrained array",
         "row: type (t: type, fixed n: u32) = [n]t" & LF
         & "mut a: row(u8, 3)" & LF,
         Accepted => True);
      Check_Source
        ("unconstrained alias",
         "cell: type (t: type) = struct value: t end cell" & LF
         & "alias: type = u8" & LF
         & "mut a: cell(alias)" & LF,
         Accepted => True);
      Check_Source
        ("nested unconstrained actual",
         "cell: type (t: type) = struct value: t end cell" & LF
         & "identity: type (t: type) = t" & LF
         & "mut a: cell(identity(u8))" & LF,
         Accepted => True);
      Check_Source
        ("ordinary subtype",
         "percent: type = u8 range 0..100" & LF
         & "mut a: percent = 40" & LF
         & "f: (v: percent) -> (r: percent) = r = v end f" & LF,
         Accepted => True);
      Check_Source
        ("deduced generic value",
         "percent: type = u8 range 0..100" & LF
         & "copy: (t: type, v: t) -> (r: t) = r = v end copy" & LF
         & "f: () -> (r: u8) = p: percent = 40 r = copy(p) end f" & LF,
         Accepted => True);
      Check_Source
        ("nested pointer actual",
         "percent: type = u8 range 0..100" & LF
         & "identity: type (t: type) = t" & LF
         & "held: type = identity(ptr percent)" & LF,
         Accepted => False);
      Check_Source
        ("nested slice actual",
         "percent: type = u8 range 0..100" & LF
         & "identity: type (t: type) = t" & LF
         & "held: type = identity([]percent)" & LF,
         Accepted => False);
      Check_Source
        ("nested array actual",
         "percent: type = u8 range 0..100" & LF
         & "identity: type (t: type) = t" & LF
         & "held: type = identity([2]percent)" & LF,
         Accepted => False);
      Check_Source
        ("nested pointer control actual",
         "percent: type = u8 range 0..100" & LF
         & "identity: type (t: type) = t" & LF
         & "held: type = identity(ptr u8)" & LF,
         Accepted => True);
      Check_Source
        ("nested slice control actual",
         "percent: type = u8 range 0..100" & LF
         & "cell: type (t: type) = struct value: t end cell" & LF
         & "held: type = cell([]u8)" & LF,
         Accepted => True);
      Check_Source
        ("nested array control actual",
         "percent: type = u8 range 0..100" & LF
         & "identity: type (t: type) = t" & LF
         & "held: type = identity([2]u8)" & LF,
         Accepted => True);
   end Range_Type_Actuals_Are_Refused;

   procedure Refused_Conformances_Are_Not_Selected
     (Item : in out Landin.Testing.Context);

   procedure Refused_Conformances_Are_Not_Selected
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Source (Label, Text, Codes : String);

      procedure Check_Source (Label, Text, Codes : String) is
         Work : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran : Natural;
         Src : Landin.Source.Source_Id;
         Got : Ada.Strings.Unbounded.Unbounded_String;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source
           (Work, "conformance-boundaries.ldn", Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);
         declare
            Reports : constant Landin.Diagnostics.Diagnostic_List :=
              Landin.Stages.Report (Work);
         begin
            for Position in 1 .. Landin.Diagnostics.Count (Reports) loop
               if Position > 1 then
                  Ada.Strings.Unbounded.Append (Got, " ");
               end if;
               Ada.Strings.Unbounded.Append
                 (Got, Landin.Diagnostics.Code
                    (Landin.Diagnostics.Get (Reports, Position)));
            end loop;
            Landin.Testing.Check_Equal
              (Item, Ran, 4, Label & " reaches checking");
            Landin.Testing.Check
              (Item, Landin.Stages.Failed (Work) = (Codes /= "")
                 and then Ada.Strings.Unbounded.To_String (Got) = Codes,
               Label & " keeps its ordered source diagnostics");
         end;
      end Check_Source;
   begin
      Check_Source
        ("duplicate concrete label",
         "ordered: type = concept (t: type)" & LF
         & "less: (a: t, b: t) -> (r: bool)" & LF
         & "end ordered" & LF
         & "less_i32: (a: i32, b: i32) -> (r: bool) = r = a < b end "
         & "less_i32" & LF
         & "i32 is ordered (less: less_i32, less: less_i32)" & LF,
         "L0301");
      Check_Source
        ("missing concrete entry",
         "ordered: type = concept (t: type)" & LF
         & "less: (a: t, b: t) -> (r: bool)" & LF
         & "end ordered" & LF
         & "less_i32: (a: i32, b: i32) -> (r: bool) = r = a < b end "
         & "less_i32" & LF
         & "i32 is ordered ()" & LF,
         "L0301");
      Check_Source
        ("unknown concrete label",
         "ordered: type = concept (t: type)" & LF
         & "less: (a: t, b: t) -> (r: bool)" & LF
         & "end ordered" & LF
         & "less_i32: (a: i32, b: i32) -> (r: bool) = r = a < b end "
         & "less_i32" & LF
         & "i32 is ordered (less: less_i32, other: less_i32)" & LF,
         "L0301");
      Check_Source
        ("nonfunction concrete entry",
         "ordered: type = concept (t: type)" & LF
         & "less: (a: t, b: t) -> (r: bool)" & LF
         & "end ordered" & LF
         & "less_i32: (a: i32, b: i32) -> (r: bool) = r = a < b end "
         & "less_i32" & LF
         & "value: i32 = 0" & LF
         & "i32 is ordered (less: value)" & LF,
         "L0301");
      Check_Source
        ("valid concrete entry",
         "ordered: type = concept (t: type)" & LF
         & "less: (a: t, b: t) -> (r: bool)" & LF
         & "end ordered" & LF
         & "less_i32: (a: i32, b: i32) -> (r: bool) = r = a < b end "
         & "less_i32" & LF
         & "i32 is ordered (less: less_i32)" & LF,
         "");
      Check_Source
        ("valid multi-input keys",
         "lookup: type = concept (t: type, index: type)" & LF
         & "    get: (value: t, at: index) -> (answer: i32)" & LF
         & "end lookup" & LF
         & "" & LF
         & "signed_get: (value: i32, at: i32) -> (answer: i32) =" & LF
         & "    answer = value + at" & LF
         & "end signed_get" & LF
         & "unsigned_get: (value: i32, at: u32) -> (answer: i32) =" & LF
         & "    answer = value - i32(at)" & LF
         & "end unsigned_get" & LF
         & "" & LF
         & "-- The input identity is part of the key, and labels "
         & "are not its order." & LF
         & "i32 is lookup (index: i32, get: signed_get)" & LF
         & "i32 is lookup (get: unsigned_get, index: u32)" & LF
         & "" & LF
         & "public main: () -> (code: i32) =" & LF
         & "    code = 42" & LF
         & "end main" & LF,
         "");
      Check_Source
        ("missing associated input",
         "lookup: type = concept (t: type, index: type)" & LF
         & "    get: (value: t, at: index) -> (answer: i32)" & LF
         & "end lookup" & LF
         & "" & LF
         & "signed_get: (value: i32, at: i32) -> (answer: i32) =" & LF
         & "    answer = value + at" & LF
         & "end signed_get" & LF
         & "unsigned_get: (value: i32, at: u32) -> (answer: i32) =" & LF
         & "    answer = value - i32(at)" & LF
         & "end unsigned_get" & LF
         & "" & LF
         & "-- The input identity is part of the key, and labels "
         & "are not its order." & LF
         & "i32 is lookup (get: signed_get)" & LF
         & "i32 is lookup (get: unsigned_get, index: u32)" & LF
         & "" & LF
         & "public main: () -> (code: i32) =" & LF
         & "    code = 42" & LF
         & "end main" & LF,
         "L0301");
      Check_Source
        ("missing generic entry",
         "equatable: type = concept (t: type)" & LF
         & "    equal: (left: t, right: t) -> (yes: bool)" & LF
         & "end equatable" & LF
         & "" & LF
         & "box: type (t: type) = struct" & LF
         & "    value: t" & LF
         & "end box" & LF
         & "" & LF
         & "equal_box: (t: type, left: box(t), right: box(t)) -> "
         & "(yes: bool) =" & LF
         & "    yes = true" & LF
         & "end equal_box" & LF
         & "" & LF
         & "(t: type) box(t) is equatable ()" & LF
         & "" & LF
         & "sized: type = concept (t: type)" & LF
         & "end sized" & LF
         & "" & LF
         & "bounded: type (fixed n: u32) = struct" & LF
         & "    bytes: [n]u8" & LF
         & "end bounded" & LF
         & "" & LF
         & "(fixed n: u32) bounded(n) is sized ()" & LF
         & "" & LF
         & "holder: type (t: type is sized) = struct" & LF
         & "    value: t" & LF
         & "end holder" & LF
         & "" & LF
         & "checked: type = holder(bounded(2))" & LF
         & "" & LF
         & "accept: (t: type is equatable, value: t) -> (code: i32) "
         & "=" & LF
         & "    code = 42" & LF
         & "end accept" & LF
         & "" & LF
         & "public main: () -> (code: i32) =" & LF
         & "    item: box(i32) = (value: 1)" & LF
         & "    code = accept(item)" & LF
         & "end main" & LF,
         "L0301 L0318");
      Check_Source
        ("valid generic entry",
         "equatable: type = concept (t: type)" & LF
         & "    equal: (left: t, right: t) -> (yes: bool)" & LF
         & "end equatable" & LF
         & "" & LF
         & "box: type (t: type) = struct" & LF
         & "    value: t" & LF
         & "end box" & LF
         & "" & LF
         & "equal_box: (t: type, left: box(t), right: box(t)) -> "
         & "(yes: bool) =" & LF
         & "    yes = true" & LF
         & "end equal_box" & LF
         & "" & LF
         & "(t: type) box(t) is equatable (equal: equal_box)" & LF
         & "" & LF
         & "sized: type = concept (t: type)" & LF
         & "end sized" & LF
         & "" & LF
         & "bounded: type (fixed n: u32) = struct" & LF
         & "    bytes: [n]u8" & LF
         & "end bounded" & LF
         & "" & LF
         & "(fixed n: u32) bounded(n) is sized ()" & LF
         & "" & LF
         & "holder: type (t: type is sized) = struct" & LF
         & "    value: t" & LF
         & "end holder" & LF
         & "" & LF
         & "checked: type = holder(bounded(2))" & LF
         & "" & LF
         & "accept: (t: type is equatable, value: t) -> (code: i32) "
         & "=" & LF
         & "    code = 42" & LF
         & "end accept" & LF
         & "" & LF
         & "public main: () -> (code: i32) =" & LF
         & "    item: box(i32) = (value: 1)" & LF
         & "    code = accept(item)" & LF
         & "end main" & LF,
         "");
      Check_Source
        ("nominal-less traversal",
         "iterable: type = concept (t: type, cur: type, "
         & "item_type: type)" & LF
         & "    first:  (s: t) -> (c: cur)" & LF
         & "    at_end: (s: t, c: cur) -> (yes: bool)" & LF
         & "    item:   (s: t, c: cur) -> (v: item_type)" & LF
         & "    next:   (s: t, c: cur) -> (c2: cur)" & LF
         & "end iterable" & LF
         & "" & LF
         & "token: type = struct" & LF
         & "    value: i32" & LF
         & "end token" & LF
         & "" & LF
         & "bag: type = struct" & LF
         & "    low: i32" & LF
         & "    count: usize" & LF
         & "end bag" & LF
         & "" & LF
         & "cursor: type = struct" & LF
         & "    position: usize" & LF
         & "end cursor" & LF
         & "" & LF
         & "cell: type (t: type) = struct" & LF
         & "    value: t" & LF
         & "    count: usize" & LF
         & "end cell" & LF
         & "" & LF
         & "cell_first: (t: type, s: cell(t)) -> (c: usize) =" & LF
         & "    c = 0" & LF
         & "end cell_first" & LF
         & "" & LF
         & "cell_at_end: (t: type, s: cell(t), c: usize) -> (yes: "
         & "bool) =" & LF
         & "    yes = c == s.count" & LF
         & "end cell_at_end" & LF
         & "" & LF
         & "cell_item: (t: type, s: cell(t), c: usize) -> (v: t) =" & LF
         & "    v = s.value" & LF
         & "end cell_item" & LF
         & "" & LF
         & "cell_next: (t: type, s: cell(t), c: usize) -> (c2: "
         & "usize) =" & LF
         & "    c2 = c + 1" & LF
         & "end cell_next" & LF
         & "" & LF
         & "(t: type) cell(t) is iterable" & LF
         & "    (next: cell_next, item_type: t, first: cell_first," & LF
         & "     cur: usize, item: cell_item, at_end: cell_at_end)" & LF
         & "" & LF
         & "two: () -> (a: i32, b: i32) = a = 1 b = 2 end two" & LF
         & "f: () -> none = for value in two() do _ = value end for "
         & "end f" & LF,
         "L0301");
      Check_Source
        ("valid nominal traversal",
         "iterable: type = concept (t: type, cur: type, "
         & "item_type: type)" & LF
         & "    first:  (s: t) -> (c: cur)" & LF
         & "    at_end: (s: t, c: cur) -> (yes: bool)" & LF
         & "    item:   (s: t, c: cur) -> (v: item_type)" & LF
         & "    next:   (s: t, c: cur) -> (c2: cur)" & LF
         & "end iterable" & LF
         & "" & LF
         & "token: type = struct" & LF
         & "    value: i32" & LF
         & "end token" & LF
         & "" & LF
         & "bag: type = struct" & LF
         & "    low: i32" & LF
         & "    count: usize" & LF
         & "end bag" & LF
         & "" & LF
         & "cursor: type = struct" & LF
         & "    position: usize" & LF
         & "end cursor" & LF
         & "" & LF
         & "cell: type (t: type) = struct" & LF
         & "    value: t" & LF
         & "    count: usize" & LF
         & "end cell" & LF
         & "" & LF
         & "cell_first: (t: type, s: cell(t)) -> (c: usize) =" & LF
         & "    c = 0" & LF
         & "end cell_first" & LF
         & "" & LF
         & "cell_at_end: (t: type, s: cell(t), c: usize) -> (yes: "
         & "bool) =" & LF
         & "    yes = c == s.count" & LF
         & "end cell_at_end" & LF
         & "" & LF
         & "cell_item: (t: type, s: cell(t), c: usize) -> (v: t) =" & LF
         & "    v = s.value" & LF
         & "end cell_item" & LF
         & "" & LF
         & "cell_next: (t: type, s: cell(t), c: usize) -> (c2: "
         & "usize) =" & LF
         & "    c2 = c + 1" & LF
         & "end cell_next" & LF
         & "" & LF
         & "(t: type) cell(t) is iterable" & LF
         & "    (next: cell_next, item_type: t, first: cell_first," & LF
         & "     cur: usize, item: cell_item, at_end: cell_at_end)" & LF
         & "" & LF
         & "f: () -> none = values: cell(i32) = (value: 1, count: 2)" & LF
         & "for value in values do _ = value end for end f" & LF,
         "");
      Check_Source
        ("self constrained concept",
         "loopy: type = concept (t: type is loopy) end loopy" & LF
         & "i32 is loopy ()" & LF,
         "L0301");
      Check_Source
        ("mutual formal constraints",
         "left: type = concept (t: type is right) end left" & LF
         & "right: type = concept (t: type is left) end right" & LF
         & "i32 is left ()" & LF
         & "i32 is right ()" & LF,
         "L0301");
      Check_Source
        ("mixed parent and formal cycle",
         "left: type = concept (t: type) is right end left" & LF
         & "right: type = concept (t: type is left) end right" & LF
         & "i32 is left ()" & LF
         & "i32 is right ()" & LF,
         "L0301");
      Check_Source
        ("unused formal cycle",
         "loopy: type = concept (t: type is loopy) end loopy" & LF,
         "L0301");
      Check_Source
        ("finite formal requirement",
         "base: type = concept (t: type) end base" & LF
         & "child: type = concept (t: type is base) end child" & LF
         & "i32 is base ()" & LF
         & "i32 is child ()" & LF,
         "");
   end Refused_Conformances_Are_Not_Selected;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "checking", "refused conformances are not selected",
         Refused_Conformances_Are_Not_Selected'Access);
      Landin.Testing.Register
        (Into, "checking", "range type actuals are refused",
         Range_Type_Actuals_Are_Refused'Access);
      Landin.Testing.Register
        (Into, "checking", "refused values always report",
         Refused_Values_Always_Report'Access);
      Landin.Testing.Register
        (Into, "checking", "static fields check evaluated values",
         Static_Fields_Check_Evaluated_Values'Access);
      Landin.Testing.Register
        (Into, "checking", "construction arguments keep value forms",
         Construction_Arguments_Keep_Value_Forms'Access);
      Landin.Testing.Register
        (Into, "checking", "fresh bindings reset flow facts",
         Fresh_Bindings_Reset_Flow_Facts'Access);
      Landin.Testing.Register
        (Into, "checking", "variant arrays retain case identities",
         Variant_Array_Elements_Keep_Case_Identity'Access);
      Landin.Testing.Register
        (Into, "checking", "union aliases keep exact instance keys",
         Union_Aliases_Keep_Exact_Instance_Keys'Access);
      Landin.Testing.Register
        (Into, "checking", "large loop frames stay off the host stack",
         Large_Loop_Frames_Stay_Off_The_Host_Stack'Access);
      Landin.Testing.Register
        (Into, "checking", "R4.70 field ranges keep recursive children",
         R470_Field_Ranges_Keep_Recursive_Children'Access);
      Landin.Testing.Register
        (Into, "checking", "try failures check reference cleanups",
         Try_Failures_Check_Reference_Cleanups'Access);
      Landin.Testing.Register
        (Into, "checking", "joined destinations keep escape obligations",
         Joined_Destinations_Keep_Escape_Obligations'Access);
      Landin.Testing.Register
        (Into, "checking", "assigned children cover element descendants",
         Assigned_Children_Cover_Element_Descendants'Access);
      Landin.Testing.Register
        (Into, "checking", "match aliases keep backing origins",
         Match_Aliases_Keep_Backing_Origins'Access);
      Landin.Testing.Register
        (Into, "checking",
         "R4.40 array field copies compare complete children",
         R440_Array_Field_Copies_Compare_Complete_Children'Access);
      Landin.Testing.Register
        (Into, "checking", "R4.40 recursive array foundations",
         R440_Recursive_Array_Foundations'Access);
      Landin.Testing.Register
        (Into, "checking", "R4.40 recursive source contexts",
         R440_Recursive_Source_Contexts'Access);
      Landin.Testing.Register
        (Into, "checking", "R4.40 helper source contracts",
         R440_Helper_Source_Contracts'Access);
      Landin.Testing.Register
        (Into, "checking", "R4.40 hosted main linkage",
         R440_Hosted_Main_Linkage'Access);
      Landin.Testing.Register
        (Into, "checking", "R4.40 result locals are contextual",
         R440_Result_Locals_Are_Contextual'Access);
      Landin.Testing.Register
        (Into, "checking", "R4.40 result binding refusals are stable",
         R440_Result_Binding_Refusals_Are_Stable'Access);
      Landin.Testing.Register
        (Into, "checking", "R4.40 C array literals keep nominals",
         R440_C_Array_Literals_Keep_Nominals'Access);
      Landin.Testing.Register
        (Into, "checking", "R4.40 variadic carrier refusal is precise",
         R440_Variadic_Carrier_Refusal_Is_Precise'Access);
      Landin.Testing.Register
        (Into, "checking", "C metadata is independent of storage",
         C_Metadata_Is_Independent_Of_Storage'Access);
      Landin.Testing.Register
        (Into, "checking", "float arithmetic uses ieee bits",
         Float_Arithmetic_Uses_IEEE_Bits'Access);
      Landin.Testing.Register
        (Into, "checking", "float specials have canonical bits",
         Float_Specials_Have_Canonical_Bits'Access);
      Landin.Testing.Register
        (Into, "checking", "conformance register uses normalized keys",
         Conformance_Register_Uses_Normalized_Keys'Access);
      Landin.Testing.Register
        (Into, "checking", "named runtime calls record formal positions",
         Named_Runtime_Calls_Record_One_Formal_Match'Access);
      Landin.Testing.Register
        (Into, "checking", "declarations give structs their identity",
         Declarations_Give_Structs_Their_Identity'Access);
      Landin.Testing.Register
        (Into, "checking", "array types are their length and element",
         Array_Types_Are_Their_Length_And_Element'Access);
      Landin.Testing.Register
        (Into, "checking", "nominal instances intern normalized actuals",
         Nominal_Instances_Intern_Normalized_Actuals'Access);
      Landin.Testing.Register
        (Into, "checking", "routine instance views keep source facts",
         Routine_Instance_Views_Keep_Source_Facts_Separate'Access);
      Landin.Testing.Register
        (Into, "checking", "generic array selections keep field metadata",
         Generic_Array_Selections_Keep_Field_Metadata'Access);
      Landin.Testing.Register
        (Into, "checking", "failed generic deduction has no target",
         Failed_Generic_Deduction_Has_No_Target'Access);
      Landin.Testing.Register
        (Into, "checking", "structural deduction interns complete tuple",
         Structural_Deduction_Interns_Complete_Tuple'Access);
      Landin.Testing.Register
        (Into, "checking", "reference actuals keep complete identity",
         Reference_Actuals_Keep_Complete_Identity'Access);
      Landin.Testing.Register
        (Into, "checking", "array actuals keep complete identity",
         Array_Actuals_Keep_Complete_Identity'Access);
      Landin.Testing.Register
        (Into, "checking", "array reference fields follow target",
         Array_Reference_Fields_Follow_Target'Access);
      Landin.Testing.Register
        (Into, "checking", "generic signatures keep nominal array elements",
         Generic_Signatures_Keep_Nominal_Array_Elements'Access);
      Landin.Testing.Register
        (Into, "checking", "discovery skips refused generic calls",
         Discovery_Skips_Refused_Generic_Calls'Access);
      Landin.Testing.Register
        (Into, "checking", "recovery deduction interns final sets",
         Recovery_Deduction_Interns_Final_Sets'Access);
      Landin.Testing.Register
        (Into, "checking", "generic instances carry declared errors",
         Generic_Instances_Carry_Declared_Errors'Access);
      Landin.Testing.Register
        (Into, "checking", "generic instances infer errors per key",
         Generic_Instances_Infer_Errors_Per_Key'Access);
      Landin.Testing.Register
        (Into, "checking", "erased calls keep concept labels across staging",
         Inferred_Erased_Results_Use_Exact_Entry_Shapes'Access);
      Landin.Testing.Register
        (Into, "checking", "erased recovery bindings retain exact errors",
         Erased_Recovery_Bindings_Have_Exact_Errors'Access);
      Landin.Testing.Register
        (Into, "checking", "contextual generic text literals keep exact views",
         Contextual_Generic_Text_Literals_Keep_Exact_Views'Access);
      Landin.Testing.Register
        (Into, "checking", "ordinary signatures use nominal identity only",
         Ordinary_Function_Signatures_Use_Identity_Only'Access);
      Landin.Testing.Register
        (Into, "checking", "parameterized aliases normalize descriptors",
         Parameterized_Aliases_Normalize_To_Existing_Descriptors'Access);
      Landin.Testing.Register
        (Into, "checking", "parameterized structs intern and lay out",
         Parameterized_Structs_Intern_And_Lay_Out_Instances'Access);
      Landin.Testing.Register
        (Into, "checking", "identity actuals materialize at value uses",
         Identity_Actuals_Materialize_At_Value_Uses'Access);
      Landin.Testing.Register
        (Into, "checking", "nominal layout edges exclude identity mentions",
         Nominal_Layout_Requirements_Distinguish_Identity_And_Value'Access);
      Landin.Testing.Register
        (Into, "checking", "invalid instances replay at each application",
         Repeated_Invalid_Instances_Report_Each_Application'Access);
      Landin.Testing.Register
        (Into, "checking", "invalid unused templates are checked",
         Invalid_Parameterized_Templates_Are_Checked_When_Unused'Access);
      Landin.Testing.Register
        (Into, "checking", "fixed bound arithmetic stays bounded",
         Fixed_Bound_Arithmetic_And_Applications_Are_Bounded'Access);
      Landin.Testing.Register
        (Into, "checking", "inferred arrays carry their source shape",
         Inferred_Array_Bindings_Carry_Their_Source_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "inferred repetition carries its source shape",
         Inferred_Repetition_Carries_Its_Source_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "inferred module repetition carries its shape",
         Inferred_Module_Repetition_Carries_Its_Source_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "typed repetition takes its written shape",
         Typed_Repetition_Takes_Its_Written_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "mixed repetition takes typed written shape",
         Mixed_Repetition_Takes_Its_Typed_Written_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "mixed assignment takes destination shape",
         Mixed_Repetition_Assignment_Takes_Its_Destination_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "a local array literal takes its written shape",
         Local_Array_Literal_Takes_Its_Written_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "a module array literal takes its written shape",
         Module_Array_Literal_Takes_Its_Written_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "typed module scalar gives zeroed its type",
         Module_Scalar_Zeroed_Takes_Its_Written_Type'Access);
      Landin.Testing.Register
        (Into, "checking", "typed local scalar gives zeroed its type",
         Local_Scalar_Zeroed_Takes_Its_Written_Type'Access);
      Landin.Testing.Register
        (Into, "checking", "module assignment gives zeroed its type",
         Module_Scalar_Assignment_Gives_Zeroed_Its_Type'Access);
      Landin.Testing.Register
        (Into, "checking", "local assignment gives zeroed its type",
         Local_Scalar_Assignment_Gives_Zeroed_Its_Type'Access);
      Landin.Testing.Register
        (Into, "checking", "named return gives zeroed its type",
         Named_Return_Assignment_Gives_Zeroed_Its_Type'Access);
      Landin.Testing.Register
        (Into, "checking", "field assignment gives zeroed its type",
         Struct_Field_Assignment_Gives_Zeroed_Its_Type'Access);
      Landin.Testing.Register
        (Into, "checking", "element assignment gives zeroed its type",
         Array_Element_Assignment_Gives_Zeroed_Its_Type'Access);
      Landin.Testing.Register
        (Into, "checking", "array field assignment gives zeroed its shape",
         Array_Field_Assignment_Gives_Zeroed_Its_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "array field literals carry destination shape",
         Array_Field_Literals_Carry_Their_Destination_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "array field repetitions carry destination shape",
         Array_Field_Repetitions_Carry_Their_Destination_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "array-bearing struct copy uses each field fact",
         Array_Bearing_Struct_Copy_Uses_Each_Field_Fact'Access);
      Landin.Testing.Register
        (Into, "checking", "struct assignment gives zeroed its body",
         Struct_Assignment_Gives_Zeroed_Its_Body'Access);
      Landin.Testing.Register
        (Into, "checking", "local struct initializer keeps nominal source",
         Local_Struct_Initializer_Keeps_Its_Nominal_Source'Access);
      Landin.Testing.Register
        (Into, "checking", "module struct zeroed keeps nominal body",
         Module_Struct_Zeroed_Keeps_Its_Nominal_Body'Access);
      Landin.Testing.Register
        (Into, "checking", "module struct image chains keep nominal body",
         Module_Struct_Image_Chains_Keep_Their_Nominal_Body'Access);
      Landin.Testing.Register
        (Into, "checking", "inferred local struct keeps nominal source",
         Inferred_Local_Struct_Keeps_Its_Nominal_Source'Access);
      Landin.Testing.Register
        (Into, "checking", "array field copy uses whole field facts",
         Array_Field_Copy_Uses_Whole_Field_Facts'Access);
      Landin.Testing.Register
        (Into, "checking", "array field initializers carry source shape",
         Array_Field_Initializers_Carry_Their_Source_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "pointer construction folds to target usize",
         Pointer_Construction_Folds_To_Target_Usize'Access);
      Landin.Testing.Register
        (Into, "checking", "array extent follows usize",
         Array_Extent_Follows_Usize'Access);
      Landin.Testing.Register
        (Into, "checking", "reference unions follow target layout",
         Reference_Unions_Follow_Target_Layout'Access);
      Landin.Testing.Register
        (Into, "checking", "struct array field extent follows usize",
         Struct_Array_Field_Extent_Follows_Usize'Access);
      Landin.Testing.Register
        (Into, "checking", "struct array field storage classes are enabled",
         Struct_Array_Field_Storage_Classes_Are_Enabled'Access);
      Landin.Testing.Register
        (Into, "checking", "struct literals carry body and field contexts",
         Struct_Literals_Carry_Body_And_Field_Identities'Access);
      Landin.Testing.Register
        (Into, "checking", "construction carries its nominal body",
         Constructions_Carry_Their_Nominal_Body'Access);
      Landin.Testing.Register
        (Into, "checking", "a struct field image carries source shape",
         Module_Struct_Field_Image_Carries_Source_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "control expression values carry their shapes",
         Control_Expression_Values_Carry_Their_Shapes'Access);
      Landin.Testing.Register
        (Into, "checking", "control edges merge only fallthrough",
         Control_Edges_Merge_Only_Fallthrough'Access);
      Landin.Testing.Register
        (Into, "checking", "nested calls retain flow effects",
         Nested_Calls_Retain_Flow_Effects'Access);
      Landin.Testing.Register
        (Into, "checking", "deferred calls are typed at registration",
         Deferred_Calls_Are_Typed_At_Registration'Access);
      Landin.Testing.Register
        (Into, "checking", "undo calls are typed at registration",
         Undo_Calls_Are_Typed_At_Registration'Access);
      Landin.Testing.Register
        (Into, "checking", "deferred reads use each exit state",
         Deferred_Reads_Use_Each_Exit_State'Access);
      Landin.Testing.Register
        (Into, "checking", "undo reads use only failure states",
         Undo_Reads_Use_Only_Failure_States'Access);
      Landin.Testing.Register
        (Into, "checking", "declared structs follow target layout",
         Declared_Structs_Follow_Target_Layout'Access);
   end Register;

end Landin.Tests.Checking_Suite;
