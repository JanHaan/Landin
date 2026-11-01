with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Landin.Backend;
with Landin.Backend.Arm32_ABI;
with Landin.Backend.Cortex_M;
with Landin.Build_Reports;
with Landin.Build_Reports.Firmware;
with Landin.Diagnostics;
with Landin.Driver;
with Landin.Driver.Boot_Stage;
with Landin.Driver.Image_Block;
with Landin.Testing.Fakes;
with Landin.IR;
with Landin.IR.Dump;
with Landin.IR.Simplification;
with Landin.IR.Verifier;
with Landin.IR.Testing_Support;
with Landin.Machine;
with Landin.Optimization;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Platform.Native;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Lowering;
with Landin.Stages.Syntax;
with Landin.Stages.Configuration;
with Landin.Stages.Resolution;
with Landin.Targets;
with Landin.Targets.Capabilities;
with Landin.Targets.Firmware;
with Landin.Targets.Layouts;
with Landin.Types;

package body Landin.Tests.Cortex_Suite is

   package T renames Landin.Targets;
   package IR renames Landin.IR;
   package Ty renames Landin.Types;
   package ABI renames Landin.Backend.Arm32_ABI;
   package U renames Ada.Strings.Unbounded;
   use type IR.Element_Total;
   use type IR.Opcode;
   use type T.Byte_Count;
   use type T.Byte_Alignment;
   use type Landin.Platform.Read_Status;
   use type ABI.Extension;
   use type T.C_ABI_Kind;
   use type T.Architecture;
   use type T.Scalar_Size;
   use type T.Capabilities.Backend_Kind;
   use type T.Capabilities.Debug_Format;

   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);
   function Contains (Text, Needle : String) return Boolean
     is (Ada.Strings.Fixed.Index (Text, Needle) > 0);
   Frontend : aliased Landin.Stages.Syntax.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Resolver : aliased Landin.Stages.Resolution.Instance;
   Checker : aliased Landin.Stages.Checking.Instance;
   Lowerer : aliased Landin.Stages.Lowering.Instance;

   function Part (Kind : Ty.Type_Kind) return IR.Signature_Part
     is (Kind => Kind, others => <>);
   function Array_Part (Size : IR.Element_Total) return IR.Signature_Part
     is (Kind => Ty.Fixed_Array, Element => Ty.U8, Length => Size,
         others => <>);

   procedure Prepare (Item : in out Landin.Testing.Context;
                      Unit : in out IR.Unit);
   function C_Record (Unit : in out IR.Unit; Size : IR.Element_Total;
                      Element : Ty.Scalar_Name := Ty.U8)
                      return IR.Signature_Part;

   procedure Prepare (Item : in out Landin.Testing.Context;
                      Unit : in out IR.Unit) is
      Work : Landin.Stages.Compilation := Landin.Stages.Create (T.Cortex_M);
      Order : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id := Landin.Stages.Add_Source
        (Work, "cortex.ldn", "f: () -> none = end f");
   begin
      pragma Unreferenced (Written);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Resolver'Access);
      Landin.Testing.Check_Equal
        (Item, Landin.Stages.Run (Order, Work), 3, "layout provenance");
      IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
   end Prepare;

   function C_Record (Unit : in out IR.Unit; Size : IR.Element_Total;
                      Element : Ty.Scalar_Name := Ty.U8)
                      return IR.Signature_Part is
      Nominal : constant IR.Nominal_Type_Id := IR.Add_Nominal_Type (Unit, 1);
   begin
      IR.Set_Nominal_Shape
        (Unit, Nominal, [1 => (Kind => IR.Array_Field_Shape,
         Length => Size, Element => Element, others => <>)], C_Layout => True);
      return (Kind => Ty.Aggregate, Nominal => Nominal, others => <>);
   end C_Record;

   procedure Contract (Item : in out Landin.Testing.Context);
   procedure Refusals (Item : in out Landin.Testing.Context);
   procedure Source_Carriers (Item : in out Landin.Testing.Context);
   procedure Driver_Boundaries (Item : in out Landin.Testing.Context);
   procedure Scalar_Spill_Homes (Item : in out Landin.Testing.Context);

   procedure Scalar_Spill_Homes (Item : in out Landin.Testing.Context) is
      use type IR.Verifier.Fault_Kind;
      Kinds : constant array (Positive range 1 .. 5) of Ty.Integer_Name :=
        [Ty.U8, Ty.U16, Ty.U32, Ty.U64, Ty.U8];
      Bytes : constant array (Positive range 1 .. 5) of T.Byte_Count :=
        [1, 2, 4, 8, 8];
      Narrow_Frame : T.Byte_Count := 0;
   begin
      for Index in Kinds'Range loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (T.Cortex_M);
            Order : Landin.Stages.Pipeline;
            Written : constant Landin.Source.Source_Id :=
              Landin.Stages.Add_Source
                (Work, "spill.ldn", "f: () -> none = end f");
            Unit : IR.Unit;
            Site : constant Landin.Provenance.Origin :=
              (Written, Landin.Source.Empty_Span);
            Routine : IR.Item_Id;
            Signature : IR.Signature_Id;
            Block : IR.Block_Id;
            Next_Block : IR.Block_Id := IR.No_Block;
            Left, Right, Sum, Next : IR.Value_Id;
            Assembly : U.Unbounded_String;
            Report : Landin.Build_Reports.Report;
         begin
            Landin.Stages.Append (Order, Frontend'Access);
            Landin.Stages.Append (Order, Configurer'Access);
            Landin.Stages.Append (Order, Resolver'Access);
            Landin.Testing.Check_Equal
              (Item, Landin.Stages.Run (Order, Work), 3,
               "spill declarations resolve");
            IR.Prepare (Unit, Landin.Stages.Meanings (Work).all);
            Routine := IR.Add_Item
              (Unit, IR.Routine, 1, Ty.No_Value, Site);
            Signature := IR.Add_Signature
              (Unit, IR.No_Signature_Parts, (others => <>));
            IR.Set_Signature (Unit, Routine, Signature);
            Block := IR.Add_Block
              (Unit, Routine, Landin.Resolution.Program_Scope, Site);
            IR.Enter (Unit, Routine, Block);
            Left := IR.Emit_Number
              (Unit, Routine, Kinds (Index), 1, False, Site);
            Right := IR.Emit_Number
              (Unit, Routine, Kinds (Index), 2, False, Site);
            Sum := IR.Emit_Binary
              (Unit, Routine, IR.Add, Left, Right, Kinds (Index), Site);
            Next := IR.Emit_Number
              (Unit, Routine, Kinds (Index), 3, False, Site);
            Sum := IR.Emit_Binary
              (Unit, Routine, IR.Add, Sum, Next, Kinds (Index), Site);
            if Index = 5 then
               --  Later wide values enlarge the three reused homes.
               Left := IR.Emit_Number
                 (Unit, Routine, Ty.U64, 4, False, Site);
               Right := IR.Emit_Number
                 (Unit, Routine, Ty.U64, 5, False, Site);
               Sum := IR.Emit_Binary
                 (Unit, Routine, IR.Add, Left, Right, Ty.U64, Site);
            end if;
            if Index = 5 then
               Next_Block := IR.Add_Block
                 (Unit, Routine, Landin.Resolution.Program_Scope, Site);
               IR.Emit_Jump (Unit, Routine, Next_Block, Site);
            else
               IR.Emit_Leave (Unit, Routine, IR.No_Value, Site);
            end if;
            IR.Leave_Block (Unit, Routine);
            if Index = 5 then
               --  The next block starts at home 1 after the first grew to
               --  three homes.
               IR.Enter (Unit, Routine, Next_Block);
               Left := IR.Emit_Number
                 (Unit, Routine, Ty.U8, 6, False, Site);
               IR.Emit_Leave (Unit, Routine, IR.No_Value, Site);
               IR.Leave_Block (Unit, Routine);
            end if;
            Landin.Testing.Check
              (Item, IR.Verifier.Check (Unit, T.Cortex_M).Kind
                = IR.Verifier.Nothing_Wrong,
               "overlapping and reused scalar values verify");
            Landin.Backend.Cortex_M.Emit
              (Unit, Landin.Stages.Meanings (Work).all,
               Landin.Stages.Identities (Work).all, T.Cortex_M,
               Landin.Optimization.Reference_Options, Assembly, Report);
            Landin.Testing.Check_Equal
              (Item, Landin.Build_Reports.Routine_Count (Report), 1,
               "one scalar routine is emitted");
            declare
               Stats : constant Landin.Build_Reports.Routine_Statistics :=
                 Landin.Build_Reports.Nth_Routine (Report, 1);
            begin
               if Index = 1 then
                  Narrow_Frame := Stats.Frame_Bytes - Stats.Save_Bytes;
               end if;
               Landin.Testing.Check
                 (Item, Stats.Spill_Count = 3
                    and then Stats.Spill_Bytes = 3 * Bytes (Index)
                    and then Stats.Frame_Bytes - Stats.Save_Bytes =
                      Narrow_Frame + T.Align_Up
                        (3 * Bytes (Index), 8) - 8,
                  "three live homes use scalar widths and aligned frames");
            end;
         end;
      end loop;
   end Scalar_Spill_Homes;
   procedure Outgoing_Calls (Item : in out Landin.Testing.Context);

   procedure Outgoing_Calls (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
      HT : constant Character := Character'Val (9);
   begin
      Host.Add_File ("p.ldn",
        "f0: () -> none = end f0 "
        & "f1: (a: u32) -> none = end f1 "
        & "f2: (a: u32, b: u32) -> none = end f2 "
        & "f3: (a: u32, b: u32, c: u32) -> none = end f3 "
        & "f4: (a: u32, b: u32, c: u32, d: u32) -> none = end f4 "
        & "f5: (a: u32, b: u32, c: u32, d: u32, e: u32) "
        & "-> none = end f5 "
        & "pair: type = struct x: u32 y: u32 end pair "
        & "ret: (a: u32, b: u32, c: u32, d: u32) -> (p: pair) "
        & "= p = (x: a + c, y: b + d) end ret "
        & "bad: atom problem: type = bad "
        & "fails: (a: u32) -> (r: u32) ! problem = a end fails "
        & "public main: () -> (code: i32) = "
        & "f0() f1(1) f2(1, 2) f3(1, 2, 3) "
        & "f4(1, 2, 3, 4) f5(1, 2, 3, 4, 5) "
        & "made := ret(1, 2, 3, 4) cb := f2 cb(5, 6) "
        & "value := fails(7) else 8 "
        & "code = i32(made.x + made.y + value) end main");
      Args.Append ("--target=cortex-m0");
      Args.Append ("--optimize=size");
      Args.Append ("--emit=asm");
      Args.Append ("-o");
      Args.Append ("p.s");
      Args.Append ("p.ldn");
      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            U.To_String (Result.Report));
         if Result.Status /= Landin.Driver.Status_Success then
            return;
         end if;
      end;
      declare
         Assembly : constant String := Host.Written ("p.s");

         function Site (Previous, Branch : String) return String;
         procedure Check_Call
           (Previous, Branch, Load : String; Bytes : Positive);

         function Site (Previous, Branch : String) return String is
            Marker : constant String :=
              (if Previous = "main:" then Previous else HT & Previous);
            Start_At : constant Natural :=
              Ada.Strings.Fixed.Index (Assembly, Marker)
                + Marker'Length;
            End_At : constant Natural :=
              Ada.Strings.Fixed.Index
                (Assembly, HT & Branch, From => Start_At);
         begin
            if Start_At <= Marker'Length or else End_At = 0 then
               return "";
            end if;
            return Assembly (Start_At .. End_At + Branch'Length);
         end Site;

         procedure Check_Call
           (Previous, Branch, Load : String; Bytes : Positive) is
            Text : constant String := Site (Previous, Branch);
            Amount : constant String := Ada.Strings.Fixed.Trim
              (Bytes'Image, Ada.Strings.Both);
         begin
            Landin.Testing.Check
              (Item, Ada.Strings.Fixed.Index
                 (Text, "sub sp, #" & Amount) > 0,
               Branch & " reserves aligned homes");
            Landin.Testing.Check
              (Item, Ada.Strings.Fixed.Index
                 (Text, Load & LF & HT & Branch) > 0,
               Branch & " loads only planned registers");
            if Branch /= "bl fails" then
               Landin.Testing.Check
                 (Item, Ada.Strings.Fixed.Index
                    (Assembly, Branch & LF & HT & "add sp, #" & Amount) > 0,
                  Branch & " releases aligned homes");
            end if;
         end Check_Call;
      begin
         --  The zero-argument call follows its block label directly.
         Landin.Testing.Check
           (Item, Ada.Strings.Fixed.Index
              (Site ("main:", "bl f0"), "sub sp, #16") = 0,
            "zero-register call reserves no outgoing homes");
         Check_Call ("bl f0", "bl f1", "ldr r0, [r6]", 8);
         Check_Call ("bl f1", "bl f2", "ldmia r6!, {r0, r1}", 8);
         Check_Call ("bl f2", "bl f3", "ldmia r6!, {r0, r1, r2}", 16);
         Check_Call
           ("bl f3", "bl f4", "ldmia r6!, {r0, r1, r2, r3}", 16);
         Check_Call
           ("bl f4", "bl f5", "ldmia r6!, {r0, r1, r2, r3}", 24);
         Check_Call
           ("bl f5", "bl ret", "ldmia r6!, {r0, r1, r2, r3}", 24);
         Landin.Testing.Check
           (Item, Ada.Strings.Fixed.Index
              (Site ("bl f5", "bl ret"),
               "mov r6, sp" & LF & HT & "adds r6, #8" & LF & HT
               & "str r0, [r6]") > 0,
            "hidden result address occupies r0 above stack arguments");
         Check_Call
           ("bl ret", "blx r4", "ldmia r6!, {r0, r1}", 8);
         Landin.Testing.Check
           (Item, Ada.Strings.Fixed.Index
              (Site ("bl ret", "blx r4"), "mov r4, r0") > 0,
            "indirect target survives argument reload");
         Check_Call ("blx r4", "bl fails", "ldr r0, [r6]", 8);
         Landin.Testing.Check
           (Item, Ada.Strings.Fixed.Index
              (Assembly, "bl fails" & LF & HT & "mov r4, r12") > 0,
            "error carrier survives the call");
      end;
   end Outgoing_Calls;

   procedure Fixed_Zero_Stores (Item : in out Landin.Testing.Context);

   procedure Fixed_Zero_Stores (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
   begin
      Host.Add_File ("zero.ldn",
        "public main: () -> (code: i32) =" & LF
        & "    aligned32: [8]u32 = zeroed" & LF
        & "    aligned12: [3]u32 = zeroed" & LF
        & "    tail: [5]u8 = zeroed" & LF
        & "    mut empty: [0]u8 = zeroed" & LF
        & "    empty = zeroed" & LF
        & "    if aligned32[0] == 0 and aligned12[2] == 0"
        & " and tail[4] == 0 then" & LF
        & "        code = 42" & LF
        & "    else" & LF
        & "        code = 1" & LF
        & "    end if" & LF
        & "end main" & LF);
      Args.Append ("--target=cortex-m0");
      Args.Append ("--emit=asm");
      Args.Append ("-o");
      Args.Append ("zero.s");
      Args.Append ("zero.ldn");
      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            U.To_String (Result.Report));
         if Result.Status = Landin.Driver.Status_Success then
            declare
               Text : constant String := Host.Written ("zero.s");
               function Loop_Body (Count : Positive) return String;
               function Occurrences (Needle : String) return Natural;
               function Loop_Body (Count : Positive) return String is
                  At_Count : constant Natural := Ada.Strings.Fixed.Index
                    (Text, "movs r4, #" & Ada.Strings.Fixed.Trim
                       (Count'Image, Ada.Strings.Both));
               begin
                  if At_Count = 0 then
                     return "";
                  end if;
                  return Text
                    (At_Count .. Natural'Min (Text'Last, At_Count + 95));
               end Loop_Body;
               function Occurrences (Needle : String) return Natural is
                  From : Positive := Text'First;
                  At_Next : Natural;
                  Seen : Natural := 0;
               begin
                  loop
                     At_Next := Ada.Strings.Fixed.Index
                       (Text (From .. Text'Last), Needle);
                     exit when At_Next = 0;
                     Seen := Seen + 1;
                     exit when At_Next + Needle'Length > Text'Last;
                     From := At_Next + Needle'Length;
                  end loop;
                  return Seen;
               end Occurrences;
            begin
               for Which in 1 .. 2 loop
                  declare
                     Count : constant Positive :=
                       (if Which = 1 then 8 else 3);
                  begin
                     Landin.Testing.Check
                       (Item, Contains (Loop_Body (Count),
                        "str r5, [r0]" & LF & HT & "adds r0, #4"),
                        "aligned clear uses " & Count'Image
                          & " word stores");
                  end;
               end loop;
               Landin.Testing.Check
                 (Item, Contains (Loop_Body (5),
                    "strb r5, [r0]" & LF & HT & "adds r0, #1"),
                  "five-byte clear stays bytewise");
               Landin.Testing.Check_Equal
                 (Item, Occurrences ("str r5, [r0]"), 2,
                  "only aligned clears use word stores");
               Landin.Testing.Check_Equal
                 (Item, Occurrences ("strb r5, [r0]"), 1,
                  "five-byte clear is the only byte loop");
               Landin.Testing.Check_Equal
                 (Item, Tools.Run_Count, 0,
                  "assembly inspection invokes no target tools");
            end;
         end if;
      end;
   end Fixed_Zero_Stores;

   procedure Register_Staging (Item : in out Landin.Testing.Context);

   procedure Register_Staging (Item : in out Landin.Testing.Context) is
   begin
      for Count in 0 .. 4 loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
            Parameters : constant String :=
              (case Count is
                 when 0 => "",
                 when 1 => "a: u32",
                 when 2 => "a: u32, b: u32",
                 when 3 => "a: u32, b: u32, c: u32",
                 when 4 => "a: u32, b: u32, c: u32, d: u32");
            Store : constant String :=
              (case Count is
                 when 0 => "",
                 when 1 => "str r0, [sp]",
                 when 2 => "stmia r6!, {r0, r1}",
                 when 3 => "stmia r6!, {r0, r1, r2}",
                 when 4 => "stmia r6!, {r0, r1, r2, r3}");
            Reserve : constant String :=
              (if Count = 0 then ""
               elsif Count <= 2 then "sub sp, #16"
               else "sub sp, #32");
         begin
            Host.Add_File ("p.ldn", "f: (" & Parameters
              & ") -> none = end f");
            Args.Append ("--target=cortex-m0");
            Args.Append ("--emit=asm");
            Args.Append ("-o");
            Args.Append ("p.s");
            Args.Append ("p.ldn");
            declare
               Result : constant Landin.Driver.Outcome :=
                 Landin.Driver.Execute (Args, Host, Tools);
            begin
               Landin.Testing.Check_Equal
                 (Item, Result.Status, Landin.Driver.Status_Success,
                  "Cortex register staging" & Count'Image & ": "
                  & U.To_String (Result.Report));
               if Result.Status = Landin.Driver.Status_Success then
                  declare
                     Code : constant String := Host.Written ("p.s");
                  begin
                     Landin.Testing.Check
                       (Item, (Store = "" or else
                          Ada.Strings.Fixed.Index (Code, Store) > 0)
                        and then (Count /= 0 or else
                          Ada.Strings.Fixed.Index (Code, "stmia r6!") = 0)
                        and then (Count /= 0 or else
                          Ada.Strings.Fixed.Index (Code, "str r0, [sp]") = 0)
                        and then (Count = 4 or else
                          Ada.Strings.Fixed.Index
                            (Code, "stmia r6!, {r0, r1, r2, r3}") = 0),
                        "entry stores only the planned core words");
                     Landin.Testing.Check
                       (Item, (Reserve = "" or else
                          Ada.Strings.Fixed.Index (Code, Reserve) > 0)
                        and then (Count /= 0 or else
                          Ada.Strings.Fixed.Index (Code, "sub sp, #") = 0),
                        "frame reserves only aligned argument homes");
                  end;
               end if;
            end;
         end;
      end loop;
   end Register_Staging;
   procedure Dead_Array_Slot_Has_No_Frame
     (Item : in out Landin.Testing.Context);

   procedure Dead_Array_Slot_Has_No_Frame
     (Item : in out Landin.Testing.Context)
   is
      package Reports renames Landin.Build_Reports;
      package Opt renames Landin.Optimization;
      function Frame_Bytes (Condition : String) return T.Byte_Count;

      function Frame_Bytes (Condition : String) return T.Byte_Count is
         Work : Landin.Stages.Compilation := Landin.Stages.Create (T.Cortex_M);
         Order : Landin.Stages.Pipeline;
         Written : constant Landin.Source.Source_Id := Landin.Stages.Add_Source
           (Work, "dead-slot.ldn", "f: () -> (r: u8) = "
            & "r = 1 if " & Condition & " then "
            & "dead: [8192]u8 = [of 0] r = dead[0] "
            & "end if end f");
         Assembly : U.Unbounded_String;
         Report : Reports.Report;
      begin
         pragma Unreferenced (Written);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
         Landin.Stages.Append (Order, Resolver'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Landin.Stages.Append (Order, Lowerer'Access);
         Landin.Testing.Check_Equal
           (Item, Landin.Stages.Run (Order, Work), 5,
            "array source reaches IR: "
            & Landin.Stages.Rendered_Report (Work));
         if Landin.Stages.Failed (Work) then
            return 0;
         end if;
         IR.Simplification.Run
           (Landin.Stages.Code (Work).all, T.Cortex_M, Opt.Size);
         Landin.Backend.Cortex_M.Emit
           (Landin.Stages.Code (Work).all,
            Landin.Stages.Meanings (Work).all,
            Landin.Stages.Identities (Work).all, T.Cortex_M,
            (Opt.Size, Opt.Off), Assembly, Report);
         return Reports.Nth_Routine (Report, 1).Frame_Bytes;
      end Frame_Bytes;

      Dead : constant T.Byte_Count := Frame_Bytes ("1 == 2");
      Live : constant T.Byte_Count := Frame_Bytes ("1 == 1");
   begin
      Landin.Testing.Check
        (Item, Dead > 0 and then Dead < 256,
         "unreachable array reserves no Cortex-M0 frame home");
      Landin.Testing.Check
        (Item, Live >= 8192,
         "reachable array retains its Cortex-M0 frame home");
   end Dead_Array_Slot_Has_No_Frame;

   procedure Contract (Item : in out Landin.Testing.Context) is
      Unit : IR.Unit;
      Text : U.Unbounded_String;
      type Values is array (Positive range <>) of T.Byte_Count;
      --  Deliberate real-host read: this is the retained executable-probe
      --  contract, independently consumed by the pinned Linux C/ASM lane.
      Host : Landin.Platform.Native.Native_Filesystem;
      Recorded : U.Unbounded_String;
      Status : Landin.Platform.Read_Status;
      Nominal : IR.Nominal_Type_Id;

      procedure Row (Name : String; Data : Values);
      procedure Layout_Row (Name : String; Fields : IR.Field_Shape_Array);
      procedure Call_Row
        (Name : String; Parameters : IR.Signature_Part_Array;
         Results : IR.Signature_Part_Array := IR.No_Signature_Parts;
         Convention : ABI.Convention := ABI.External_C;
         Error : Boolean := False;
         Fixed : Natural := Natural'Last);

      procedure Row (Name : String; Data : Values) is
      begin
         U.Append (Text, Name);
         for Value of Data loop
            U.Append (Text, " " & Ada.Strings.Fixed.Trim
              (Value'Image, Ada.Strings.Both));
         end loop;
         U.Append (Text, LF);
      end Row;

      procedure Layout_Row (Name : String; Fields : IR.Field_Shape_Array) is
         Shape : IR.Field_Shape;
         Size : T.Byte_Count;
         Alignment : T.Byte_Alignment;
      begin
         Nominal := IR.Add_Nominal_Type (Unit, 1);
         IR.Set_Nominal_Shape (Unit, Nominal, Fields);
         Shape := (Kind => IR.Aggregate_Field_Shape, Nominal => Nominal,
                   others => <>);
         Landin.Backend.Field_Extent (Unit, Shape, T.Cortex_M, Size,
                                     Alignment);
         declare
            Layout : constant T.Layouts.Plan :=
              Landin.Backend.Aggregate_Layout (Unit, Shape, T.Cortex_M);
            Synthetic : constant T.Layouts.Plan :=
              Landin.Backend.Aggregate_Layout (Unit, Shape, T.Synthetic_32);
            Data : Values (1 .. Fields'Length + 2);
         begin
            Data (1) := Size;
            Data (2) := T.Byte_Count (Alignment);
            for Index in Layout.Offsets'Range loop
               Data (Index + 2) := Layout.Offsets (Index);
               Landin.Testing.Check
                 (Item, Layout.Offsets (Index) = Synthetic.Offsets (Index),
                  Name & " agrees with synthetic-32 offsets");
            end loop;
            Landin.Testing.Check
              (Item, Size = Synthetic.Size
               and then Alignment = Synthetic.Alignment,
               Name & " agrees with synthetic-32 extent");
            Row (Name, Data);
         end;
      end Layout_Row;

      procedure Call_Row
        (Name : String; Parameters : IR.Signature_Part_Array;
         Results : IR.Signature_Part_Array := IR.No_Signature_Parts;
         Convention : ABI.Convention := ABI.External_C;
         Error : Boolean := False;
         Fixed : Natural := Natural'Last)
      is
         Plan : constant ABI.Plan := ABI.Assign
           (Unit, Parameters, Results, T.Cortex_M, Convention, Error,
            Fixed_Count => Fixed);
      begin
         Row (Name & ".result",
              [T.Byte_Count (Boolean'Pos (Plan.Result.Shape.Indirect)),
               T.Byte_Count (Plan.Result.First_Core),
               T.Byte_Count (Plan.Result.Core_Count), Plan.Stack_Bytes,
               T.Byte_Count (Boolean'Pos (Plan.Has_Error))]);
         for Index in Plan.Arguments'Range loop
            declare
               Arg : ABI.Location renames Plan.Arguments (Index);
            begin
               Row (Name & ".arg" & Ada.Strings.Fixed.Trim
                    (Index'Image, Ada.Strings.Both),
                    [T.Byte_Count (Arg.First_Core),
                     T.Byte_Count (Arg.Core_Count),
                     Arg.Stack_At, Arg.Stack_Bytes,
                     T.Byte_Count (Boolean'Pos (Arg.Shape.Indirect))]);
            end;
         end loop;
      end Call_Row;
   begin
      Prepare (Item, Unit);
      for Kind in Ty.Scalar_Name loop
         declare
            Size : constant T.Scalar_Size := Ty.Storage_Size (Kind,
                                                            T.Cortex_M);
         begin
            Row (Ty.Spelling (Kind),
                 [T.Byte_Count (T.Bytes (Size)),
                  T.Byte_Count (T.Alignment_Of (T.Cortex_M, Size))]);
            Landin.Testing.Check
              (Item, Size = Ty.Storage_Size (Kind, T.Synthetic_32),
               "scalar storage agrees with synthetic-32");
         end;
      end loop;
      Layout_Row ("a", [(Element => Ty.U8, others => <>),
                        (Element => Ty.U32, others => <>),
                        (Element => Ty.U8, others => <>)]);
      Layout_Row ("b", [(Element => Ty.U8, others => <>),
                        (Element => Ty.U8, others => <>),
                        (Element => Ty.U32, others => <>)]);
      Layout_Row ("c", [(Element => Ty.U8, others => <>),
                        (Element => Ty.Usize, others => <>)]);
      Layout_Row ("d", [(Element => Ty.U64, others => <>),
                        (Element => Ty.U8, others => <>)]);
      declare
         Payload : constant Natural := IR.Add_Shape_Run
           (Unit, [(Element => Ty.Usize, others => <>),
                   (Element => Ty.U8, others => <>),
                   (Kind => IR.Array_Field_Shape, Element => Ty.U16,
                    Length => 3, others => <>)]);
         Cases : constant Natural := IR.Add_Case_Run
           (Unit, [(First => 0, Count => 0),
                   (First => Payload, Count => 2),
                   (First => Payload + 2, Count => 1)]);
         Variant : constant IR.Field_Shape :=
           (Kind => IR.Variant_Field_Shape, Element => Ty.U8,
            Cases => 3, Payloads_First => Cases, others => <>);
      begin
         Layout_Row ("variant", [1 => Variant]);
         Row ("payload", [Landin.Backend.Variant_Payload_Field_Offset
           (Unit, Variant, 2, 1, T.Cortex_M)]);
         Layout_Row ("wrapped", [(Element => Ty.U8, others => <>),
                                Variant,
                                (Element => Ty.U16, others => <>)]);
      end;
      Layout_Row ("child", [(Element => Ty.U8, others => <>),
                            (Element => Ty.Usize, others => <>),
                            (Kind => IR.Array_Field_Shape, Element => Ty.U16,
                             Length => 3, others => <>)]);
      Layout_Row ("nested", [(Element => Ty.U16, others => <>),
                             (Kind => IR.Aggregate_Field_Shape,
                              Nominal => Nominal, others => <>),
                             (Element => Ty.U8, others => <>)]);
      Layout_Row ("multiple", [(Element => Ty.U8, others => <>),
                               (Element => Ty.U64, others => <>)]);
      Row ("evidence0", [T.Evidence_Table_Size (T.Cortex_M, 0),
        T.Byte_Count (T.Evidence_Table_Alignment (T.Cortex_M))]);
      Row ("evidence", [T.Evidence_Table_Size (T.Cortex_M, 2),
                        T.Byte_Count (T.Evidence_Table_Alignment (T.Cortex_M)),
                        T.Evidence_Size_Offset (T.Cortex_M),
                        T.Evidence_Alignment_Offset (T.Cortex_M),
                        T.Evidence_Function_Offset (T.Cortex_M, 1),
                        T.Evidence_Function_Offset (T.Cortex_M, 2)]);
      Row ("any", [T.Any_Value_Size (T.Cortex_M),
                   T.Byte_Count (T.Any_Value_Alignment (T.Cortex_M)),
                   T.Any_Data_Offset (T.Cortex_M),
                   T.Any_Table_Offset (T.Cortex_M)]);
      Call_Row ("gap", [Part (Ty.U32), Part (Ty.U64), Part (Ty.U32)]);
      Call_Row ("split", [Part (Ty.U32), Part (Ty.U32), Part (Ty.U32),
                          C_Record (Unit, 12), Part (Ty.U32)]);
      Call_Row ("stack", [Part (Ty.U32), Part (Ty.U32), Part (Ty.U32),
                          Part (Ty.U32), Part (Ty.I8), Part (Ty.F64),
                          Part (Ty.U16)]);
      Call_Row ("sret", [Part (Ty.U32), Part (Ty.U64), Part (Ty.U32)],
                [1 => C_Record (Unit, 5)]);
      Call_Row ("small", [Part (Ty.I8), Part (Ty.U16), Part (Ty.F32)],
                [1 => C_Record (Unit, 3)]);
      Call_Row ("varargs", [Part (Ty.U32), Part (Ty.I32), Part (Ty.F64),
                            Part (Ty.U32)], Fixed => 1);
      Call_Row ("floatpair", [Part (Ty.U32),
        C_Record (Unit, 2, Ty.F32),
        Part (Ty.U32)], [1 => Part (Ty.F64)]);
      Call_Row ("native", [Part (Ty.Usize), Part (Ty.Usize),
                           Array_Part (8), Part (Ty.U64)],
                [1 => Array_Part (8)], ABI.Internal_Landin, True);
      Call_Row ("multi", [Part (Ty.Usize)],
                [Part (Ty.U8), Part (Ty.U64)], ABI.Internal_Landin, True);
      Host.Read_File ("../tests/cortex-m.contract", Recorded, Status);
      Landin.Testing.Check
        (Item, Status = Landin.Platform.Read_Ok, "contract is retained");
      Landin.Testing.Check_Equal
        (Item, U.To_String (Text), U.To_String (Recorded),
         "actual target layout and planner match executable contract");
   end Contract;

   procedure Refusals (Item : in out Landin.Testing.Context) is
      Unit : IR.Unit;
      C : ABI.Classification;
      Plan : ABI.Plan (5);
      pragma Unreferenced (Plan);
   begin
      Prepare (Item, Unit);
      Landin.Testing.Check
        (Item, T.Architecture_Of (T.Cortex_M) = T.Cortex_M0
         and then T.C_ABI_Of (T.Cortex_M) = T.Arm_AAPCS32_Soft
         and then T.Maximum_Object_Size (T.Cortex_M) = 2 ** 32 - 1,
         "Cortex-M names the selected architecture and ABI");
      Landin.Testing.Check
        (Item, not T.Capabilities.C_Signatures (T.Cortex_M)
         and then not T.Capabilities.C_Records (T.Cortex_M)
         and then not T.Capabilities.C_Variadic_Calls (T.Cortex_M)
         and then T.Capabilities.Backend_For (T.Cortex_M)
           = T.Capabilities.Cortex_M0_ELF
         and then T.Capabilities.Debug_Format_Of (T.Cortex_M)
           = T.Capabilities.ELF_DWARF_Lines
         and then T.Capabilities.Triplet (T.Cortex_M) = "arm-eabi",
         "assembly does not advertise C or source debugging");
      for Kind in Ty.Scalar_Name loop
         C := ABI.Classify (Unit, Part (Kind), T.Cortex_M, ABI.External_C);
         Landin.Testing.Check
           (Item, (if Kind in Ty.I8 | Ty.I16 then C.Extend = ABI.Sign_Extend
                   elsif Kind in Ty.U8 | Ty.U16 | Ty.Bool
                   then C.Extend = ABI.Zero_Extend
                   else C.Extend = ABI.No_Extension),
            "narrow extension is explicit");
      end loop;
      declare
         Targets : constant array (Positive range <>) of T.Target_Facts :=
           [T.Synthetic_32, T.Linux_X86_64, T.Darwin_Arm64];
      begin
         for Facts of Targets loop
            begin
               C := ABI.Classify (Unit, Part (Ty.U32), Facts, ABI.External_C);
               Landin.Testing.Fail (Item, "wrong target accepted by ARM ABI");
            exception
               when Compiler_Defect =>
                  Landin.Testing.Check (Item, True, "wrong target refused");
            end;
         end loop;
      end;
      Landin.Testing.Check
        (Item, T.Evidence_Table_Size (T.Cortex_M, 2 ** 30 - 3)
           = 2 ** 32 - 4
         and then T.Evidence_Function_Offset (T.Cortex_M, 2 ** 30 - 3)
           = 2 ** 32 - 8,
         "last complete evidence cell fits target usize");
      for Mode in 1 .. 3 loop
         declare
            Offset : T.Byte_Count;
            pragma Unreferenced (Offset);
         begin
            Offset :=
              (case Mode is
                 when 1 => T.Evidence_Function_Offset
                   (T.Cortex_M, 2 ** 30 - 2),
                 when 2 => T.Evidence_Function_Offset
                   (T.Cortex_M, Positive'Last),
                 when 3 => T.Evidence_Table_Size (T.Cortex_M, Natural'Last));
            Landin.Testing.Fail (Item, "evidence overflow accepted");
         exception
            when Compiler_Defect =>
               Landin.Testing.Check (Item, True, "evidence overflow refused");
         end;
      end loop;
      for Size in 1 .. 5 loop
         declare
            Result : constant ABI.Plan := ABI.Assign
              (Unit, IR.No_Signature_Parts,
               [1 => C_Record (Unit, IR.Element_Total (Size))],
               T.Cortex_M, ABI.External_C);
         begin
            Landin.Testing.Check
              (Item, Result.Result.Shape.Indirect = (Size > 4)
               and then Result.Result.Core_Count = 1,
               "C composite result boundary is four bytes");
         end;
      end loop;
      for Mode in 1 .. 5 loop
         begin
            Plan := ABI.Assign
              (Unit, [Part (Ty.U32), Part (Ty.U32), Part (Ty.U32),
                      Part (Ty.U32),
                      (if Mode = 2 then Part (Ty.F32)
                       elsif Mode = 3 then C_Record (Unit, 0)
                       elsif Mode = 5 then C_Record (Unit, 2 ** 32 - 1)
                       else Part (Ty.U32))],
               IR.No_Signature_Parts, T.Cortex_M, ABI.External_C,
               Has_Error => Mode = 4,
               Maximum => (if Mode = 1 then 7 else 2 ** 32 - 1),
               Fixed_Count => (if Mode = 2 then 4 else Natural'Last));
            Landin.Testing.Fail (Item, "invalid ABI plan accepted");
         exception
            when Compiler_Defect | Landin.Backend.Stack_Limit_Exceeded =>
               Landin.Testing.Check (Item, True, "invalid ABI plan refused");
         end;
      end loop;
   end Refusals;

   procedure Source_Carriers (Item : in out Landin.Testing.Context) is
      --  Deliberate real-host read of existing source pressure fixtures.
      Host : Landin.Platform.Native.Native_Filesystem;
      Source : U.Unbounded_String;
      Status : Landin.Platform.Read_Status;
      Paths : constant array (Positive range <>) of U.Unbounded_String :=
        [U.To_Unbounded_String ("generic-evidence-indirect"),
         U.To_Unbounded_String ("generic-composed-evidence"),
         U.To_Unbounded_String ("any-heterogeneous-dispatch"),
         U.To_Unbounded_String ("generic-erased-aggregate-try"),
         U.To_Unbounded_String ("null-pointer-union-call-else"),
         U.To_Unbounded_String ("r490-distinct-generic-pointer-images"),
         U.To_Unbounded_String ("multiple-named-returns"),
         U.To_Unbounded_String ("caller-parameters")];
   begin
      for Name of Paths loop
         Host.Read_File
           ("../tests/fixtures/runtime/" & U.To_String (Name) & "/main.ldn",
            Source, Status);
         Landin.Testing.Check
           (Item, Status = Landin.Platform.Read_Ok, "source fixture exists");
         declare
            Cortex : Landin.Stages.Compilation :=
              Landin.Stages.Create (T.Cortex_M);
            Synthetic : Landin.Stages.Compilation :=
              Landin.Stages.Create (T.Synthetic_32);
            Order : Landin.Stages.Pipeline;
            Cortex_Source : constant Landin.Source.Source_Id :=
              Landin.Stages.Add_Source
                (Cortex, "carrier.ldn", U.To_String (Source));
            Synthetic_Source : constant Landin.Source.Source_Id :=
              Landin.Stages.Add_Source
                (Synthetic, "carrier.ldn", U.To_String (Source));
            pragma Unreferenced (Cortex_Source, Synthetic_Source);
         begin
            if U.To_String (Name) = "caller-parameters" then
               declare
                  Other : U.Unbounded_String;
               begin
                  Host.Read_File
                    ("../tests/fixtures/runtime/caller-parameters/other.ldn",
                     Other, Status);
                  Landin.Testing.Check
                    (Item, Status = Landin.Platform.Read_Ok,
                     "caller fixture companion exists");
                  declare
                     Left : constant Landin.Source.Source_Id :=
                       Landin.Stages.Add_Source
                         (Cortex, "other.ldn", U.To_String (Other));
                     Right : constant Landin.Source.Source_Id :=
                       Landin.Stages.Add_Source
                         (Synthetic, "other.ldn", U.To_String (Other));
                  begin
                     pragma Unreferenced (Left, Right);
                  end;
               end;
            end if;
            Landin.Stages.Append (Order, Frontend'Access);
            Landin.Stages.Append (Order, Configurer'Access);
            Landin.Stages.Append (Order, Resolver'Access);
            Landin.Stages.Append (Order, Checker'Access);
            Landin.Stages.Append (Order, Lowerer'Access);
            Landin.Testing.Check_Equal
              (Item, Landin.Stages.Run (Order, Cortex), 5,
               "Cortex source reaches verified IR");
            Landin.Testing.Check_Equal
              (Item, Landin.Stages.Run (Order, Synthetic), 5,
               "synthetic source reaches verified IR");
            Landin.Testing.Check
              (Item, not Landin.Stages.Failed (Cortex),
               Landin.Stages.Rendered_Report (Cortex));
            if not Landin.Stages.Failed (Cortex)
              and then not Landin.Stages.Failed (Synthetic)
            then
               declare
                  Code : constant not null access IR.Unit :=
                    Landin.Stages.Code (Cortex);
               begin
                  Landin.Testing.Check_Equal
                    (Item, IR.Dump.Text (Code.all,
                            Landin.Stages.Meanings (Cortex).all,
                            Landin.Stages.Identities (Cortex).all, True),
                     IR.Dump.Text (Landin.Stages.Code (Synthetic).all,
                            Landin.Stages.Meanings (Synthetic).all,
                            Landin.Stages.Identities (Synthetic).all, True),
                     "target identity changes no neutral carrier semantics");
                  for Index in 1 .. IR.Item_Count (Code.all) loop
                     for Value in 1 .. IR.Value_Count
                       (Code.all, IR.Item_Id (Index))
                     loop
                        if IR.Op_Of (Code.all, IR.Item_Id (Index),
                          IR.Value_Id (Value)) in IR.Call | IR.Indirect_Call
                        then
                           declare
                              Plan : constant ABI.Plan := ABI.Call_Plan
                                (Code.all, IR.Item_Id (Index),
                                 IR.Value_Id (Value), T.Cortex_M);
                           begin
                              Landin.Testing.Check
                                (Item, Plan.Stack_Bytes mod 8 = 0,
                                 "direct and indirect calls have plans");
                           end;
                        end if;
                     end loop;
                  end loop;
                  for Index in 1 .. IR.Signature_Count (Code.all) loop
                     declare
                        Plan : constant ABI.Plan := ABI.Signature_Plan
                          (Code.all, IR.Signature_Id (Index), T.Cortex_M);
                     begin
                        Landin.Testing.Check
                          (Item, Plan.Stack_Bytes mod 8 = 0,
                           "all reached carrier signatures have a plan");
                     end;
                  end loop;
               end;
            end if;
         end;
      end loop;
   end Source_Carriers;

   procedure Driver_Boundaries (Item : in out Landin.Testing.Context) is
   begin
      for Mode in 1 .. 9 loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
         begin
            Host.Add_File ("p.ldn",
              (case Mode is
                 when 1 .. 3 =>
                   "f: () -> (r: usize) = 4294967295 end f",
                 when 4 => "f: () -> (r: usize) = 4294967296 end f",
                 when 5 => "f: () -> (r: isize) = 2147483648 end f",
                 when 6 =>
                   "f: () -> (r: ptr u8) = ptr(4294967296) end f",
                 when 7 => "extern(c) f: () -> (r: u32)",
                 when 8 => "big: type = [4294967296]u8",
                 when 9 => "big: type = [4294967295]u8"));
            Args.Append ("--target=cortex-m0");
            Args.Append ("p.ldn");
            if Mode in 2 .. 3 then
               Args.Append (if Mode = 2 then "--emit=asm" else "--emit=exe");
               Args.Append ("-o");
               Args.Append ("p.out");
            end if;
            declare
               Result : constant Landin.Driver.Outcome :=
                 Landin.Driver.Execute (Args, Host, Tools);
            begin
               Landin.Testing.Check_Equal
                 (Item, Result.Status,
                  (if Mode in 1 | 2 | 9 then Landin.Driver.Status_Success
                   else Landin.Driver.Status_Reported),
                  "Cortex target boundary " & Mode'Image & ": "
                  & U.To_String (Result.Report));
               if Mode = 3 then
                  Landin.Testing.Check
                    (Item, U.Index (Result.Report, "L0502") > 0,
                     "firmware executable needs an explicit entry");
               end if;
               Landin.Testing.Check_Equal
                 (Item, Host.Write_Count, (if Mode = 2 then 1 else 0),
                  "only assembly emission writes output");
               Landin.Testing.Check_Equal
                 (Item, Tools.Run_Count, 0, "boundary invokes no tool");
            end;
         end;
      end loop;
   end Driver_Boundaries;

   procedure Hard_Trap_Emission (Item : in out Landin.Testing.Context);

   procedure Hard_Trap_Emission (Item : in out Landin.Testing.Context) is
   begin
      for Mode in 1 .. 2 loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
         begin
            Host.Add_File ("p.ldn",
              (if Mode = 1 then
                 "public f: () -> (r: u32) = r = 7 end f"
               else
                 "public f: (d: u32) -> (r: u32) = r = 7 / d end f"));
            Args.Append ("--target=cortex-m0");
            Args.Append ("--emit=asm");
            Args.Append ("-o");
            Args.Append ("p.s");
            Args.Append ("p.ldn");
            declare
               Result : constant Landin.Driver.Outcome :=
                 Landin.Driver.Execute (Args, Host, Tools);
            begin
               Landin.Testing.Check_Equal
                 (Item, Result.Status, Landin.Driver.Status_Success,
                  "Cortex trap assembly: " & U.To_String (Result.Report));
               if Result.Status = Landin.Driver.Status_Success then
                  declare
                     Text : constant String := Host.Written ("p.s");
                     Reference : constant Natural :=
                       Ada.Strings.Fixed.Index (Text, "_trap");
                     Definition : constant Natural :=
                       Ada.Strings.Fixed.Index (Text, "_trap:");
                  begin
                     if Mode = 1 then
                        Landin.Testing.Check
                          (Item, Definition = 0
                           and then Ada.Strings.Fixed.Index
                             (Text, "udf #1") = 0,
                           "trap-free routine has no hard trap");
                     else
                        Landin.Testing.Check
                          (Item, Reference > 0 and then Definition > Reference
                           and then Ada.Strings.Fixed.Index
                             (Text, "udf #1") > 0,
                           "division guard retains its hard trap");
                     end if;
                  end;
               end if;
            end;
         end;
      end loop;
   end Hard_Trap_Emission;

   procedure Frame_Saves (Item : in out Landin.Testing.Context);

   procedure Frame_Saves (Item : in out Landin.Testing.Context) is
   begin
      for Mode in 1 .. 5 loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
            Path : constant String :=
              (if Mode = 1 then "r5.ldn" else "p.ldn");
            Source : constant String :=
              (case Mode is
                 when 1 => "public simple: () -> (code: i32) = "
                   & "code = 7 end simple" & LF
                   & "public r5: () -> (code: i32) = "
                   & "code = 7 end r5",
                 when 2 => "public fifth: (a: i32, b: i32, c: i32,"
                   & " d: i32, e: i32) -> (r: i32) = r = e end fifth"
                   & LF & "public caller: () -> (r: i32) = "
                   & "r = fifth(1, 2, 3, 4, 5) end caller",
                 when 3 => "public with_asm: (x: u32) -> (r: u32)"
                   & " = r = assembler.block(""adds {o}, {i}, #7"","
                   & " out o: u32 at r5, in i: u32 at r1 = x)"
                   & " end with_asm",
                 when 4 => "public tabbed: () -> none = "
                   & "assembler.block(""movs\tr5, #1"", out _ at r5)"
                   & " end tabbed",
                 when others => "public spaced: () -> none = "
                   & "assembler.block(""movs\t  \tr5, #1"","
                   & " out _ at r5) end spaced");
         begin
            Host.Add_File (Path, Source);
            Args.Append ("--target=cortex-m0");
            Args.Append ("--debug=lines");
            Args.Append ("--emit=asm");
            Args.Append ("--build-report=build.json");
            Args.Append ("-o");
            Args.Append ("p.s");
            Args.Append (Path);
            declare
               Result : constant Landin.Driver.Outcome :=
                 Landin.Driver.Execute (Args, Host, Tools);
            begin
               Landin.Testing.Check_Equal
                 (Item, Result.Status, Landin.Driver.Status_Success,
                  "Cortex frame variant emits" & Mode'Image);
               if Result.Status = Landin.Driver.Status_Success then
                  declare
                     Text : constant String :=
                       Landin.Testing.Fakes.Written (Host, "p.s");
                     Report : constant String :=
                       Landin.Testing.Fakes.Written (Host, "build.json");
                  begin
                     case Mode is
                        when 1 =>
                           declare
                              First : constant Natural :=
                                Ada.Strings.Fixed.Index
                                  (Text, "simple:" & LF);
                              Second : constant Natural :=
                                Ada.Strings.Fixed.Index
                                  (Text, "r5:" & LF);
                           begin
                              Landin.Testing.Check
                                (Item, First > 0 and then Second > First,
                                 "both named leaves are emitted");
                              if First > 0 and then Second > First then
                                 declare
                                    First_Body : constant String :=
                                      Text (First .. Second - 1);
                                    Second_Body : constant String :=
                                      Text (Second .. Text'Last);
                                 begin
                                    Landin.Testing.Check
                                      (Item, Ada.Strings.Fixed.Index
                                        (First_Body, "push {r6}" & LF) > 0
                                        and then Ada.Strings.Fixed.Index
                                          (Second_Body, "push {r6}" & LF) > 0
                                        and then Ada.Strings.Fixed.Index
                                          (Second_Body, "push {r5") = 0,
                                       "symbol r5 does not change saves");
                                    Landin.Testing.Check
                                      (Item, Ada.Strings.Fixed.Index
                                        (First_Body, "push {lr}") = 0
                                        and then Ada.Strings.Fixed.Index
                                          (Second_Body, "mov r11, sp") = 0,
                                       "leaves omit LR and r11 frame record");
                                 end;
                              end if;
                           end;
                           Landin.Testing.Check
                             (Item, Ada.Strings.Fixed.Index
                               (Text, ".cfi_offset r6, -4" & LF) > 0
                               and then Ada.Strings.Fixed.Index
                                 (Text, ".cfi_offset lr") = 0
                               and then Ada.Strings.Fixed.Index
                                 (Report, """save_bytes"":4") > 0,
                              "leaf unwind and report use four save bytes");
                        when 2 =>
                           Landin.Testing.Check
                             (Item, Ada.Strings.Fixed.Index
                               (Text, "adds r6, r6, r2" & LF) > 0,
                              "leaf stack argument follows its save area");
                           Landin.Testing.Check
                             (Item, Ada.Strings.Fixed.Index
                               (Text, "push {r4, r5}" & LF) > 0
                               and then Ada.Strings.Fixed.Index
                                 (Text, ".cfi_offset r11, -24" & LF) > 0
                               and then Ada.Strings.Fixed.Index
                                 (Report, """save_bytes"":24") > 0,
                              "caller retains aligned frame and unwind");
                        when 3 =>
                           Landin.Testing.Check
                             (Item, Ada.Strings.Fixed.Index
                               (Text, "adds r5, r1, #7" & LF) > 0
                               and then Ada.Strings.Fixed.Index
                                 (Text, "push {r4, r5, r6, r7}" & LF) > 0
                               and then Ada.Strings.Fixed.Index
                                 (Report, """save_bytes"":24") > 0,
                              "inline assembly register is preserved");
                        when others =>
                           Landin.Testing.Check
                             (Item, (if Mode = 4 then
                                Ada.Strings.Fixed.Index
                                  (Text, "movs" & Character'Val (9)
                                    & "r5, #1") > 0
                              else Ada.Strings.Fixed.Index
                                  (Text, "movs" & Character'Val (9)
                                    & "  " & Character'Val (9)
                                    & "r5, #1") > 0)
                               and then Ada.Strings.Fixed.Index
                                 (Text, "push {r4, r5, r6, r7}" & LF) > 0
                               and then Ada.Strings.Fixed.Index
                                 (Text, "pop {r4, r5, r6, r7}" & LF) > 0,
                              "tab-separated register keeps its save");
                           Landin.Testing.Check
                             (Item, Ada.Strings.Fixed.Index
                               (Text, ".cfi_offset r5, -12" & LF) > 0
                               and then Ada.Strings.Fixed.Index
                                 (Report, """save_bytes"":24") > 0,
                              "tab-separated clobber has unwind and report");
                     end case;
                  end;
               end if;
            end;
         end;
      end loop;
   end Frame_Saves;

   procedure Source_Debugging (Item : in out Landin.Testing.Context);

   procedure Source_Debugging (Item : in out Landin.Testing.Context) is
   begin
      for Mode in 1 .. 4 loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
         begin
            Host.Add_File ("p.ldn", "start: () -> none = end start");
            Args.Append
              (if Mode = 3 then "--target=linux-x86-64"
               elsif Mode = 4 then "--target=darwin-arm64"
               else "--target=cortex-m0");
            Args.Append (if Mode = 2 then "--debug=full"
                         else "--debug=lines");
            Args.Append ("--emit=asm");
            Args.Append ("-o");
            Args.Append ("p.s");
            Args.Append ("p.ldn");
            declare
               Result : constant Landin.Driver.Outcome :=
                 Landin.Driver.Execute (Args, Host, Tools);
            begin
               Landin.Testing.Check_Equal
                 (Item, Result.Status,
                  (if Mode = 1 then Landin.Driver.Status_Success
                   else Landin.Driver.Status_Reported),
                  "explicit source-debug contract" & Mode'Image & ": "
                  & U.To_String (Result.Report));
               if Mode /= 1 then
                  Landin.Testing.Check_Equal
                    (Item, Host.Write_Count, 0,
                     "unsupported debug interface refuses before writes");
               end if;
               Landin.Testing.Check_Equal
                 (Item, Tools.Run_Count, 0, "assembly runs no debugger");
            end;
         end;
      end loop;
   end Source_Debugging;

   procedure Fixed_Fills_Enter_Their_Loops
     (Item : in out Landin.Testing.Context);

   procedure Fixed_Fills_Enter_Their_Loops
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
   begin
      Host.Add_File ("p.ldn",
        "main: () -> (r: u32) = "
        & "a: [4]u8 = [of 7] "
        & "b: [4]u8 = [1, 2, of 3] "
        & "r = u32(a[0]) + u32(b[3]) end main");
      Args.Append ("--target=cortex-m0");
      Args.Append ("--emit=asm");
      Args.Append ("-o");
      Args.Append ("p.s");
      Args.Append ("p.ldn");
      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            U.To_String (Result.Report));
         if Result.Status = Landin.Driver.Status_Success then
            declare
               Text : constant String := Host.Written ("p.s");
            begin
               Landin.Testing.Check
                 (Item, Ada.Strings.Fixed.Index (Text, "movs r4, #4") > 0
                    and then Ada.Strings.Fixed.Index
                      (Text, "movs r4, #2") > 0,
                  "full and suffix fills use their fixed element counts");
               Landin.Testing.Check
                 (Item, Ada.Strings.Fixed.Index (Text, "cmp r4, #0") = 0,
                  "fixed fills do not test their positive counts");
            end;
         end if;
      end;
   end Fixed_Fills_Enter_Their_Loops;

   procedure Backend_Boundaries (Item : in out Landin.Testing.Context);
   procedure Local_Branches (Item : in out Landin.Testing.Context);

   procedure Local_Branches (Item : in out Landin.Testing.Context) is
   begin
      for Long_Body in Boolean loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
            Source : U.Unbounded_String := U.To_Unbounded_String
              ("main: (x: u32) -> (r: u32) = r = 1 "
               & "if x == 0 then ");
         begin
            if Long_Body then
               for N in 1 .. 80 loop
                  U.Append (Source, "r = r + x ");
               end loop;
            else
               --  A checked product, so that D338 keeps the branch.
               U.Append (Source, "r = r * 3 ");
            end if;
            U.Append (Source, "else r = 2 end if end main");
            Host.Add_File ("p.ldn", U.To_String (Source));
            Args.Append ("--target=cortex-m0");
            Args.Append ("--emit=asm");
            Args.Append ("-o");
            Args.Append ("p.s");
            Args.Append ("p.ldn");
            declare
               Result : constant Landin.Driver.Outcome :=
                 Landin.Driver.Execute (Args, Host, Tools);
            begin
               Landin.Testing.Check_Equal
                 (Item, Result.Status, Landin.Driver.Status_Success,
                  U.To_String (Result.Report));
               if Result.Status = Landin.Driver.Status_Success then
                  declare
                     Assembly : constant String := Host.Written ("p.s");
                  begin
                     Landin.Testing.Check
                       (Item, Ada.Strings.Fixed.Index
                          (Assembly, Character'Val (9) & "bne L1_2") > 0,
                        "near conditional branch is direct");
                     Landin.Testing.Check
                       (Item, Ada.Strings.Fixed.Index
                          (Assembly, Character'Val (9)
                           & (if Long_Body then
                                "bne L1_2" & LF & Character'Val (9)
                                & "ldr r7, "
                              else "b L1_3" & LF & "L1_2:")) > 0,
                        "near edge is direct; distant edge uses long jump");
                  end;
               end if;
            end;
         end;
      end loop;
   end Local_Branches;

   procedure Debug_Branches (Item : in out Landin.Testing.Context);

   procedure Debug_Branches (Item : in out Landin.Testing.Context) is
      HT : constant Character := Character'Val (9);

      function Edges (Assembly : String) return String;

      function Edges (Assembly : String) return String is
         Result : U.Unbounded_String;
         First : Positive := Assembly'First;
      begin
         for Last in Assembly'Range loop
            if Assembly (Last) = LF then
               declare
                  Line : constant String := Assembly (First .. Last);
               begin
                  if Ada.Strings.Fixed.Index (Line, HT & "b") = First
                    or else Ada.Strings.Fixed.Index
                      (Line, HT & "ldr r7, ") = First
                  then
                     U.Append (Result, Line);
                  end if;
               end;
               First := Last + 1;
            end if;
         end loop;
         return U.To_String (Result);
      end Edges;
   begin
      --  Vary a checked conversion around the conservative branch bound.
      --  Source locations must not turn a near trap edge into a long jump.
      for Size in 1 .. 8 loop
         declare
            Source : U.Unbounded_String := U.To_Unbounded_String
              ("main: (x: u32) -> (r: u32) = r = u32(u8(x)) ");
            Plain : U.Unbounded_String;
         begin
            for Index in 1 .. Size loop
               U.Append (Source, "r = x ");
            end loop;
            U.Append (Source, "end main");
            for Debug in Boolean loop
               declare
                  Host : Landin.Testing.Fakes.Fake_Filesystem;
                  Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
                  Args : Landin.Platform.Path_List;
               begin
                  Host.Add_File ("p.ldn", U.To_String (Source));
                  Args.Append ("--target=cortex-m0");
                  Args.Append ("--optimize=none");
                  Args.Append ("--specialize=off");
                  Args.Append (if Debug then "--debug=lines"
                               else "--debug=none");
                  Args.Append ("--emit=asm");
                  Args.Append ("-o");
                  Args.Append ("p.s");
                  Args.Append ("p.ldn");
                  declare
                     Result : constant Landin.Driver.Outcome :=
                       Landin.Driver.Execute (Args, Host, Tools);
                  begin
                     Landin.Testing.Check_Equal
                       (Item, Result.Status, Landin.Driver.Status_Success,
                        U.To_String (Result.Report));
                     if Result.Status = Landin.Driver.Status_Success then
                        if Debug then
                           Landin.Testing.Check_Equal
                             (Item, Edges (Host.Written ("p.s")),
                              U.To_String (Plain),
                              "debugging preserves branch choices"
                              & Size'Image);
                        else
                           Plain := U.To_Unbounded_String
                             (Edges (Host.Written ("p.s")));
                        end if;
                     end if;
                  end;
               end;
            end loop;
         end;
      end loop;
   end Debug_Branches;

   procedure Branch_Rich_Cleanup (Item : in out Landin.Testing.Context);

   procedure Branch_Rich_Cleanup (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
      Source : U.Unbounded_String := U.To_Unbounded_String
        ("mut trace: i32 = 0 "
         & "mark: (value: i32) -> none = trace += value end mark "
         & "cleanup: (flag: bool) -> (result: i32) = result = 42 ");
   begin
      --  Each return unwinds the remaining cleanups. This small source
      --  emits thousands of branches, and exposed a quadratic text walk
      --  that kept every Cortex corpus profile from reaching the linker.
      for Index in 1 .. 12 loop
         U.Append (Source, "defer mark(begin return when flag 1 end) ");
      end loop;
      U.Append (Source, "end cleanup");
      Host.Add_File ("cleanup.ldn", U.To_String (Source));
      Args.Append ("--target=cortex-m0");
      Args.Append ("--emit=asm");
      Args.Append ("--optimize=none");
      Args.Append ("--specialize=off");
      Args.Append ("-o");
      Args.Append ("cleanup.s");
      Args.Append ("cleanup.ldn");
      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            U.To_String (Result.Report));
         if Result.Status = Landin.Driver.Status_Success then
            Landin.Testing.Check
              (Item, Ada.Strings.Fixed.Count
                 (Host.Written ("cleanup.s"), "cmp r0, #0")
                   > 4_000,
               "a large cleanup routine retains its conditional edges");
            Landin.Testing.Check
              (Item, Ada.Strings.Fixed.Index
                 (Host.Written ("cleanup.s"), "ldr r7, ") > 0,
               "distant cleanup edges retain their long jumps");
         end if;
      end;
   end Branch_Rich_Cleanup;

   procedure Backend_Boundaries (Item : in out Landin.Testing.Context) is
   begin
      for Mode in 1 .. 4 loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
         begin
            Host.Add_File ("p.ldn",
              (case Mode is
                 when 1 => "main: () -> (r: u32) = "
                   & "mut a: [4294967295]u8 = zeroed r = u32(a[0]) end main",
                 when 2 => "main: () -> (r: u32) = mut a: u32 = 0 "
                   & "r = compiler.atomic_add(addr a, 1, compiler.relaxed) "
                   & "end main",
                 when 3 => "main: () -> (r: u64) = mut a: u64 = 0 "
                   & "r = compiler.volatile_load(addr a) end main",
                 when 4 => "main: () -> (r: u32) = 42 end main"));
            Args.Append ("--target=cortex-m0");
            Args.Append ("--emit=asm");
            Args.Append ("-o");
            Args.Append ("p.s");
            Args.Append ("p.ldn");
            if Mode = 4 then
               Args.Append ("--debug=full");
            end if;
            declare
               Result : constant Landin.Driver.Outcome :=
                 Landin.Driver.Execute (Args, Host, Tools);
               Code : constant String :=
                 (case Mode is when 1 => "L0504", when 2 | 3 => "L0344",
                    when 4 => "L0500");
            begin
               Landin.Testing.Check_Equal
                 (Item, Result.Status, Landin.Driver.Status_Reported,
                  "unsupported Cortex boundary reports a diagnostic");
               Landin.Testing.Check
                 (Item, U.Index (Result.Report, Code) > 0,
                  "precise Cortex refusal: " & U.To_String (Result.Report));
               Landin.Testing.Check_Equal
                 (Item, Host.Write_Count, 0, "refusal writes no artifact");
               Landin.Testing.Check_Equal
                 (Item, Tools.Run_Count, 0, "refusal invokes no host tool");
            end;
         end;
      end loop;
   end Backend_Boundaries;

   procedure Firmware_Path (Item : in out Landin.Testing.Context);
   --  [1990]'s constrained profile, written out here as the expectation
   --  platform/cortex_m/reference must select, apart from its source.
   function Reference return Landin.Targets.Firmware.Profile;
   function Reference return Landin.Targets.Firmware.Profile is
      package F renames Landin.Targets.Firmware;
      Result : F.Profile;
   begin
      Result.Present := True;
      Result.Reference := True;
      Result.Device := F.To_Name ("constrained-reference");
      Result.Core := F.Cortex_M0;
      Result.Vector_Count := 48;
      for Slot in 16 .. 41 loop
         Result.Interrupts (Slot) := Slot /= 21;
      end loop;
      Result.Boot := F.Vector_Table;
      Result.Count := 2;
      Result.Regions (1) :=
        (F.To_Name ("FLASH"), 0, 32 * 1024, F.Read_Execute);
      Result.Regions (2) :=
        (F.To_Name ("RAM"), 16#2000_0000#, 16 * 1024, F.Read_Write_Execute);
      Result.Placed := [F.Vectors | F.Text | F.Rodata => 1, others => 2];
      Result.Stack_Size := 4 * 1024;
      return Result;
   end Reference;

   procedure Linked_Firmware_Evidence (Item : in out Landin.Testing.Context);

   procedure Linked_Firmware_Evidence (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Data : String (1 .. 512) := [others => Character'Val (0)];
      Result : U.Unbounded_String;
      Valid : Boolean;
      Args : Landin.Platform.Path_List;

      procedure Put (Offset : Natural; Value : Natural; Width : Positive);
      procedure Put (Offset : Natural; Value : Natural; Width : Positive) is
         Rest : Natural := Value;
      begin
         for Index in 0 .. Width - 1 loop
            Data (Offset + Index + 1) := Character'Val (Rest mod 256);
            Rest := Rest / 256;
         end loop;
      end Put;
   begin
      Data (1 .. 6) := Character'Val (127) & "ELF"
        & Character'Val (1) & Character'Val (1);
      Put (16, 2, 2);
      Put (18, 40, 2);
      Put (20, 1, 4);
      Put (28, 52, 4);
      Put (40, 52, 2);
      Put (42, 32, 2);
      Put (44, 3, 2);
      --  Vectors, flash text, and copied data plus zero-filled RAM.
      Put (52, 1, 4);
      Put (56, 148, 4);
      Put (68, 192, 4);
      Put (72, 192, 4);
      Put (84, 1, 4);
      Put (88, 340, 4);
      Put (92, 512, 4);
      Put (96, 512, 4);
      Put (100, 100, 4);
      Put (104, 100, 4);
      Put (116, 1, 4);
      Put (120, 440, 4);
      Put (124, 16#2000_0008#, 4);
      Put (128, 768, 4);
      Put (132, 16, 4);
      Put (136, 32, 4);
      Host.Add_File ("p.elf", Data);
      Host.Add_File ("p.elf.map",
        "/tool/libgcc.a(_udivsi3.o)" & LF
        & "/tool/libgcc.a(_muldi3.o)" & LF
        & "/tool/libgcc.a(_udivsi3.o)" & LF);
      Landin.Build_Reports.Firmware.Measure
        (Host, "p.elf", "p.elf.map", Reference, Stage => "", Valid => Valid,
         Result => Result);
      Landin.Testing.Check (Item, Valid, "ELF load extents are measured");
      Landin.Testing.Check_Equal
        (Item, U.To_String (Result),
         "{""flash_used"":784,""flash_limit"":32768,"
         & """flash_remaining"":31984,""static_ram_used"":40,"
         & """static_ram_limit"":12288,""static_ram_remaining"":12248,"
         & """stack_reserved"":4096,""runtime_members"":"
         & "[""_muldi3.o"",""_udivsi3.o""],"
         & """device"":""constrained-reference"",""core"":""cortex-m0"","
         & """boot"":""vector-table"",""vector_address"":0,"
         & """vector_words"":48,""regions"":[{""name"":""FLASH"","
         & """origin"":0,""length"":32768,""access"":""rx""},"
         & "{""name"":""RAM"",""origin"":536870912,""length"":16384,"
         & """access"":""rwx""}],""placed"":{""vectors"":""FLASH"","
         & """text"":""FLASH"",""rodata"":""FLASH"",""data"":""RAM"","
         & """bss"":""RAM"",""stack"":""RAM""}}",
         "occupied extents include gaps and archive members are sorted");

      Host.Add_Firmware_Library;
      Host.Add_File ("p.ldn", "start: () -> none = end start");
      Args.Append ("--target=cortex-m0");
      Args.Append ("--firmware-entry=start");
      Args.Append ("--emit=exe");
      Args.Append ("--build-report=p.json");
      Args.Append ("-o");
      Args.Append ("p.elf");
      Args.Append ("p.ldn");
      --  The reserved old output must not supply the post-link evidence.
      Host.Add_File ("p.elf", "old invalid ELF");
      Tools.Set_Output_Content (Data);
      Tools.Set_Result (0, "");
      declare
         Built : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Built.Status, Landin.Driver.Status_Success,
            U.To_String (Built.Report));
         Landin.Testing.Check
           (Item, Ada.Strings.Fixed.Index
              (Host.Written ("p.json"), """flash_used"":784") > 0,
            "post-link measurement reaches the emitted report");
      end;
      Host.Add_File ("p.elf", "invalid ELF");
      Landin.Build_Reports.Firmware.Measure
        (Host, "p.elf", "p.elf.map", Reference, Stage => "", Valid => Valid,
         Result => Result);
      Landin.Testing.Check (Item, not Valid, "invalid ELF is refused");
      Host.Add_File ("p.elf", Data);
      Host.Add_File ("p.elf.map", "");
      Landin.Build_Reports.Firmware.Measure
        (Host, "p.elf", "p.elf.map", Reference, Stage => "", Valid => Valid,
         Result => Result);
      Landin.Testing.Check (Item, not Valid, "empty map is refused");

      --  D546: a developer's script is linked in place of OUT.ld, and an
      --  image with no startup symbols breaks the contract's clause 2.
      Host.Add_File ("dev.ld", "SECTIONS { }");
      Host.Add_File ("p.elf.map", "");
      Args.Clear;
      Args.Append ("--target=cortex-m0");
      Args.Append ("--firmware-entry=start");
      Args.Append ("--emit=exe");
      Args.Append ("--linker-script=dev.ld");
      Args.Append ("-o");
      Args.Append ("p.elf");
      Args.Append ("p.ldn");
      Tools.Set_Output_Content (Data);
      Tools.Set_Result (0, "");
      declare
         Built : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check
           (Item, Landin.Diagnostics.Count (Built.Found) > 0
              and then Landin.Diagnostics.Code
                (Landin.Diagnostics.Get (Built.Found, 1)) = "L0519"
              and then Ada.Strings.Fixed.Index
                (U.To_String (Built.Report),
                 "clause 2, the startup symbols") > 0,
            "a script whose image lacks the startup symbols is L0519: "
            & U.To_String (Built.Report));
         Landin.Testing.Check
           (Item, Ada.Strings.Fixed.Index
              (Host.Written ("p.elf.ld"), "MEMORY {") > 0,
            "the derived script is still written beside the image");
      end;
      Args.Clear;
      Args.Append ("--target=cortex-m0");
      Args.Append ("--emit=asm");
      Args.Append ("--linker-script=dev.ld");
      Args.Append ("p.ldn");
      declare
         Refused : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check
           (Item, Ada.Strings.Fixed.Index
              (U.To_String (Refused.Report),
               "--linker-script links firmware") > 0,
            "--linker-script without a firmware link is refused: "
            & U.To_String (Refused.Report));
      end;
   end Linked_Firmware_Evidence;

   procedure Firmware_Path (Item : in out Landin.Testing.Context) is
   begin
      for Mode in 1 .. 13 loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
         begin
            Host.Add_Firmware_Library;
            Host.Add_File ("p.ldn",
              (case Mode is
                 when 1 => "mut result: u32 = 1 "
                   & "link(symbol: ""firmware_source_entry"") "
                   & "start: () -> none = result = 42 end start",
                 when 11 => "start: () -> none = end start "
                   & "start: () -> none = end start",
                 when 12 => "start: (t: type) -> none = end start "
                   & "invoke: () -> none = start(t: u32) end invoke",
                 when 3 => "start: (x: u32) -> none = end start",
                 when 4 => "start: () -> (r: u32) = 1 end start",
                 when 5 => "bad: atom start: () -> none ! bad = "
                   & "fail bad end start",
                 when 10 => "link(keep) image: [8388609]u8 = [of 1] "
                   & "start: () -> none = end start",
                 when 13 => "linker.library(""third"") "
                   & "start: () -> none = end start",
                 when others => "mut result: u32 = 1 "
                   & "start: () -> none = result = 42 end start"));
            Args.Append (if Mode = 6 then "--target=darwin-arm64"
                         else "--target=cortex-m0");
            Args.Append ("--emit=exe");
            Args.Append ("--firmware-entry="
                         & (if Mode = 2 then "absent" else "start"));
            Args.Append ("-o");
            Args.Append ("p.elf");
            Args.Append ("p.ldn");
            if Mode = 7 then
               Args.Append ("--firmware-entry=start");
            elsif Mode = 8 then
               Host.Add_Alias ("p.elf.ld", "p.ldn");
            end if;
            Tools.Set_Result
              ((if Mode = 9 then 1 else 0), "test tool result");
            declare
               Result : constant Landin.Driver.Outcome :=
                 Landin.Driver.Execute (Args, Host, Tools);
            begin
               if Mode = 1 then
                  Landin.Testing.Check_Equal
                    (Item, Result.Status, Landin.Driver.Status_Success,
                     U.To_String (Result.Report));
                  Landin.Testing.Check_Equal
                    (Item, Tools.Run_Count, 2,
                     "assembly and freestanding link are separate calls");
                  Landin.Testing.Check_Equal
                    (Item, Host.Write_Count, 2,
                     "compiler writes assembly and linker script");
                  Landin.Testing.Check
                    (Item, Ada.Strings.Fixed.Index
                       (Tools.Last_Command, "-nostdlib") > 0,
                     "firmware suppresses hosted defaults");
                  Landin.Testing.Check
                    (Item, Ada.Strings.Fixed.Index
                       (Host.Written ("p.elf.s"),
                        "bl firmware_source_entry") > 0,
                     "reset calls the selected source routine");
               elsif Mode = 9 then
                  Landin.Testing.Check_Equal
                    (Item, Result.Status, Landin.Driver.Status_Reported,
                     "assembler failure is a reported tool failure");
                  Landin.Testing.Check_Equal
                    (Item, Tools.Run_Count, 1,
                     "assembly failure prevents linking");
               else
                  Landin.Testing.Check
                    (Item, Result.Status /= Landin.Driver.Status_Success,
                     "invalid firmware request refuses " & Mode'Image);
                  if Mode = 3 then
                     Landin.Testing.Check
                       (Item, U.Index (Result.Report, "p.ldn:1:") > 0,
                        "an invalid entry points to its source identity");
                  elsif Mode = 12 then
                     Landin.Testing.Check
                       (Item, U.Index (Result.Report, "L0502") > 0,
                        "a reached generic instance is not a source entry");
                  elsif Mode = 10 then
                     Landin.Testing.Check
                       (Item, U.Index (Result.Report, "L0505") > 0,
                        "bounded image failure has a dedicated diagnostic");
                  elsif Mode = 13 then
                     Landin.Testing.Check
                       (Item, U.Index (Result.Report, "L0500") > 0
                        and then U.Index
                          (Result.Report, "remove linker.library") > 0,
                        "firmware library refusal names its remedy");
                  end if;
                  Landin.Testing.Check_Equal
                    (Item, Host.Write_Count, 0,
                     "entry and artifact refusal precedes writes");
                  Landin.Testing.Check_Equal
                    (Item, Tools.Run_Count, 0,
                     "entry and artifact refusal precedes tools");
               end if;
            end;
         end;
      end loop;
   end Firmware_Path;

   procedure Firmware_Frame_Limit (Item : in out Landin.Testing.Context);

   procedure Firmware_Frame_Limit (Item : in out Landin.Testing.Context) is
   begin
      for Mode in 1 .. 5 loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
            Body_Text : constant String :=
              "mut bytes: [" & (if Mode = 4 then "4064"
                                elsif Mode = 5 then "4072" else "5000")
              & "]u8 = zeroed bytes[0] = 1 _ = bytes[0] ";
         begin
            Host.Add_Firmware_Library;
            Host.Add_File ("p.ldn",
              (if Mode = 2 then
                 "large: () -> none = " & Body_Text & "end large "
                 & "start: () -> none = large() end start"
               else "start: () -> none = " & Body_Text & "end start"));
            Args.Append ("--target=cortex-m0");
            if Mode /= 3 then
               Args.Append ("--firmware-entry=start");
            end if;
            Args.Append ("--emit=asm");
            Args.Append ("-o");
            Args.Append ("p.s");
            Args.Append ("p.ldn");
            declare
               Result : constant Landin.Driver.Outcome :=
                 Landin.Driver.Execute (Args, Host, Tools);
            begin
               Landin.Testing.Check_Equal
                 (Item, Result.Status,
                  (if Mode in 1 .. 2 | 5 then Landin.Driver.Status_Reported
                   else Landin.Driver.Status_Success),
                  "firmware frame mode" & Mode'Image & ": "
                  & U.To_String (Result.Report));
               if Mode in 1 .. 2 | 5 then
                  Landin.Testing.Check
                    (Item, U.Index (Result.Report, "L0507") > 0,
                     "oversized known frame has its own diagnostic");
                  Landin.Testing.Check_Equal
                    (Item, Host.Write_Count, 0,
                     "oversized frame is refused before writing");
               else
                  Landin.Testing.Check_Equal
                    (Item, Host.Write_Count, 1,
                     "fitting frame or bare target writes assembly");
               end if;
               Landin.Testing.Check_Equal
                 (Item, Tools.Run_Count, 0, "assembly needs no tool");
            end;
         end;
      end loop;
   end Firmware_Frame_Limit;

   procedure Machine_Directives (Item : in out Landin.Testing.Context);

   procedure Machine_Directives (Item : in out Landin.Testing.Context) is
      function Program (Case_Number : Positive) return String;
      function Program (Case_Number : Positive) return String is
      begin
         return (case Case_Number is
           when 1 => "link(vector: 11) extern(interrupt) h: () -> none = "
             & "assembler.block(""nop"") end h "
             & "link(keep) extern(naked) n: () -> none = "
             & "assembler.block(""bx lr"") end n "
             & "link(section: "".data.value"", align: 1_6, keep, "
             & "symbol: ""value"") mut x: u32 = 1 "
             & "link(keep) zs: [2]u64 = zeroed "
             & "pair: type = struct value: u32 end pair "
             & "link(keep) zp: pair = zeroed",
           when 2 => "extern(interrupt) h: (x: u32) -> none = end h",
           when 3 => "extern(interrupt) h: () -> (r: u32) = 1 end h",
           when 4 => "bad: atom extern(interrupt) h: () -> none ! bad = "
             & "fail bad end h",
           when 5 => "extern(naked) h: () -> none = mut x: u32 = 0 end h",
           when 6 => "extern(naked) h: () -> none = end h",
           when 7 => "extern(naked) h: () -> none = "
             & "assembler.block(""nop"") assembler.block(""bx lr"") end h",
           when 8 => "extern(interrupt) h: () -> none = end h "
             & "call: () -> none = h() end call",
           when 9 => "extern(interrupt) h: () -> none = end h "
             & "fn: type = () -> none p: fn = h",
           when 10 => "link(vector: 4) extern(interrupt) h: () -> none = "
             & "end h",
           when 11 => "link(vector: 11) extern(interrupt) h: () -> none = "
             & "end h link(vector: 11) extern(interrupt) j: () -> none = "
             & "end j",
           when 12 => "link(vector: 16) h: () -> none = end h",
           when 13 => "link(section: "".data.code"") h: () -> none = end h",
           when 14 => "link(align: 3) mut x: u32 = 0",
           when 15 => "link(align: 0) mut x: u32 = 0",
           when 16 => "link(section: "".isr_vector"", keep) x: u32 = 0",
           when 17 => "link(section: "".bss.bad"") mut x: u32 = 1",
           when 18 => "link(keep, keep) x: u32 = 1",
           when 19 => "link(keep) link(keep) x: u32 = 1",
           when 20 => "extern(naked) h: () -> none = "
             & "assembler.block(""local: .cpu cortex-m3"") end h",
           when 21 => "h: () -> none = assembler.block(""mov r9, r0"") end h",
           when 22 => "h: () -> none = "
             & "assembler.block(""ldrex r0, [r1]"") end h",
           when 23 => "link(symbol: ""_landin_firmware_reset"") "
             & "h: () -> none = end h",
           when 24 => "link(symbol: ""data_symbol"") x: u32 = 0 "
             & "link(symbol: ""data_symbol"") y: u32 = 0",
           when 25 => "extern(interrupt) h: () -> none = end h",
           when 26 => "h: () -> none = assembler.block(""nop"") end h",
           when 27 => "link(keep) x: u32 = 0",
           when 28 => "link(vector: 42) extern(interrupt) h: () -> none"
             & " = end h",
           when 29 => "h: () -> none = assembler.block(""mrs r0, basepri"")"
             & " end h",
           when 30 => "h: () -> none = assembler.block(""msr control, r0"")"
             & " end h",
           when 31 => "h: () -> none = assembler.block(""cpsid f"") end h",
           when 32 => "h: () -> none = assembler.block(""dmb ish"") end h",
           when 33 => "extern(naked) h: () -> none = "
             & "assembler.block(""bx lr"") end h "
             & "fn: type = extern(interrupt) () -> none p: fn = h",
           when 34 => "extern(interrupt) h: () -> none = end h "
             & "fn: type = extern(interrupt) () -> none p: fn = h "
             & "call: () -> none = p() end call",
           when 36 => "link(align: 0x10) mut x: u32 = 0",
           when 37 => "link(vector: 0x10) extern(interrupt) h: () -> none"
             & " = end h",
           when 38 => "h: (x: u32) -> (r: u32) = "
             & "assembler.block(""adds r0, #1"", x) end h",
           when 39 => "h: (x: u16) -> none = "
             & "_ = assembler.block(""nop"", x) end h",
           when 40 => "extern(naked) h: () -> none = "
             & "assembler.block(""bx lr"", 0) end h",
           when 41 => "h: () -> none = "
             & "_ = assembler.block(""nop"", missing) end h",
           when 42 => "h: (x: u32) -> none = "
             & "_ = assembler.block(""mov r11, r0"", x) end h",
           when 43 => "h: (x: u32) -> none = "
             & "_ = assembler.block(""nop"", x, x) end h",
           when 44 => "h: (x: u32) -> none = "
             & "_ = assembler.block(""nop"", x) end h",
           when 45 => "h: (x: u32) -> (r: u32) = r = 42 "
             & "_ = assembler.block(""nop"", begin return when x == 0 "
             & "x end) end h",
           when 46 => "h: (x: u32) -> none = "
             & "_ = assembler.block(""nop"", x) else 0 end h",
           when 47 => "h: () -> none = "
             & "_ = assembler.block(""nop"", 0) end h",
           when 48 => "h: (x: u32) -> none = "
             & "_ = assembler.block(text: ""nop"", operand: x) end h",
           when 65 => "link(section: "".rodata.shared"") "
             & "first: u8 = 1 "
             & "link(section: "".rodata.shared"", keep) "
             & "second: u8 = 2 "
             & "link(section: "".rodata.third"") third: u8 = 3",
           when 49 | 50 =>
             "h: (a: u32, b: u32) -> (q: u32) = "
             & "q = assembler.block(""udiv {q}, {q}, {b}"", "
             & "inout q: u32 at r0 = a, in b: u32 at r1 = b) end h",
           when 51 => "h: () -> none = assembler.block(""qadd r0, r0, r1"")"
             & " end h",
           when 52 => "h: () -> none = assembler.block(""b.w elsewhere"")"
             & " end h",
           when 53 => "h: () -> none = assembler.block(""udiv r9, r0, r1"")"
             & " end h",
           when 54 => "h: () -> none = assembler.block(""there: nop"")"
             & " end h",
           when 55 => "h: () -> none = assembler.block(""it eq"") end h",
           when 56 => "h: () -> none = "
             & "assembler.block(""ldrex r0, [r1]"") end h",
           when 57 => "h: () -> none = "
             & "assembler.block(""mrs r0, basepri"") end h",
           when 58 => "h: () -> none = "
             & "assembler.block(""msr basepri, r0"") end h",
           when 59 => "h: () -> none = "
             & "assembler.block(""cpsid f"") end h",
           when 60 | 62 => "h: () -> none = "
             & "assembler.block(""udf #0"") end h",
           when 61 => "h: () -> none = "
             & "assembler.block(""bkpt #0"") end h",
           when 63 => "extern(naked) h: () -> none = "
             & "assembler.block(""udf #0"") end h",
           when 64 => "h: () -> none = "
             & "assembler.block(""udf.w #0"") end h",
           when others => "link(vector: 11) extern(interrupt) h: () -> none"
             & " = end h");
      end Program;
   begin
      for Case_Number in 1 .. 65 loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
         begin
            Host.Add_Firmware_Library;
            Host.Add_File ("p.ldn", Program (Case_Number)
              & " start: () -> none = end start");
            if Case_Number = 1 then
               Args.Append ("--firmware-entry=start");
            end if;
            Args.Append (if Case_Number in 25 .. 27 | 44
                         then "--target=darwin-arm64"
                         else "--target=cortex-m0");
            if Case_Number in 50 | 52 .. 61 | 63 .. 64 then
               Args.Append ("--level=armv7-m");
            elsif Case_Number in 51 | 62 then
               Args.Append ("--level=armv7e-m");
            end if;
            Args.Append ("--emit=asm");
            Args.Append ("-o");
            Args.Append ("p.s");
            Args.Append ("p.ldn");
            declare
               Result : constant Landin.Driver.Outcome :=
                 Landin.Driver.Execute (Args, Host, Tools);
            begin
               Landin.Testing.Check_Equal
                 (Item, Result.Status,
                  --  26: a hosted operand-free block lowers like any other.
                  (if Case_Number in 1 | 26 | 38 | 45 | 50 | 51
                    | 56 .. 59 | 63 | 65
                   then Landin.Driver.Status_Success
                   else Landin.Driver.Status_Reported),
                  "machine contract case" & Case_Number'Image & ": "
                    & U.To_String (Result.Report));
               if Case_Number not in 1 | 26 | 38 | 45 | 50 | 51
                 | 56 .. 59 | 63 | 65
               then
                  Landin.Testing.Check_Equal
                    (Item, Host.Write_Count, 0,
                     "invalid machine constructs refuse before emission");
               elsif Case_Number = 49 then
                  declare
                     Assembly : U.Unbounded_String;
                     Status : Landin.Platform.Read_Status;
                  begin
                     Host.Read_File ("p.s", Assembly, Status);
                     Landin.Testing.Check
                       (Item, Status = Landin.Platform.Read_Ok,
                        "shared-section assembly is written");
                     Landin.Testing.Check_Equal
                       (Item, Ada.Strings.Fixed.Count
                         (U.To_String (Assembly),
                          ".section .rodata.shared,""aR"",%progbits"),
                        2, "later keep retains both shared-section items");
                     Landin.Testing.Check_Equal
                       (Item, Ada.Strings.Fixed.Count
                         (U.To_String (Assembly),
                          ".section .rodata.third,""a"",%progbits"),
                        1, "unrelated explicit section remains unretained");
                  end;
               end if;
               Landin.Testing.Check_Equal
                 (Item, Tools.Run_Count, 0, "assembly checks run no tool");
            end;
         end;
      end loop;
   end Machine_Directives;

   --  D597: a block's comments, in an ordinary block on each target and
   --  beside a Cortex-M naked body's labels, are checked as absent and
   --  written nowhere in the assembly, while every instruction is.
   procedure Assembly_Comments_Are_Not_Emitted
     (Item : in out Landin.Testing.Context);

   procedure Assembly_Comments_Are_Not_Emitted
     (Item : in out Landin.Testing.Context)
   is
      type Target_Case is (Cortex, X86, Linux_Arm, Darwin_Arm, RV);

      function Target_Name (Of_Case : Target_Case) return String
        is (case Of_Case is
               when Cortex => "cortex-m0",
               when X86 => "linux-x86-64",
               when Linux_Arm => "linux-arm64",
               when Darwin_Arm => "darwin-arm64",
               when RV => "linux-rv64");

      --  Each block's comment names a slot no operand has, a register the
      --  block does not declare and a word, WITHHELD, found nowhere else.
      function Program (Of_Case : Target_Case) return String
        is (case Of_Case is
               when Cortex =>
                 "link(keep) extern(naked) n: () -> none = "
                 & "assembler.block(""@ WITHHELD {gone}\n"
                 & "movs r0, #0\nagain: @ WITHHELD\nadds r0, #1"
                 & "\ncmp r0, #8 @ WITHHELD r9\nbne again\nbx lr"")"
                 & " end n "
                 & "h: (v: u32) -> (r: u32) = r = assembler.block("
                 & """adds {r}, #7 @ WITHHELD {gone} r9"","
                 & " inout r: u32 at general = v) end h",
               when X86 =>
                 "h: (v: u32) -> (r: u32) = r = assembler.block("
                 & """# WITHHELD\naddl $7, {r} # WITHHELD {gone} %rbx"","
                 & " inout r: u32 at general = v) end h",
               when Linux_Arm | Darwin_Arm =>
                 "h: (v: u32) -> (r: u32) = r = assembler.block("
                 & """// WITHHELD\nadd {r}, {r}, #7 // WITHHELD {gone}"
                 & " x19"", inout r: u32 at general = v) end h",
               when RV =>
                 "h: (v: u32) -> (r: u32) = r = assembler.block("
                 & """# WITHHELD\naddi {r}, {r}, 7 # WITHHELD {gone} s1"","
                 & " inout r: u32 at general = v) end h");

      function Instructions (Of_Case : Target_Case) return String
        is (case Of_Case is
               when Cortex => "bne again",
               when X86 => "addl $7, %",
               when Linux_Arm | Darwin_Arm => ", #7",
               when RV => "addi ");
   begin
      for Of_Case in Target_Case loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
            Assembly : U.Unbounded_String;
            Status : Landin.Platform.Read_Status;
         begin
            Host.Add_Firmware_Library;
            Host.Add_File ("p.ldn", Program (Of_Case)
              & " start: () -> none = _ = h(35) end start");
            Args.Append ("--target=" & Target_Name (Of_Case));
            if Of_Case in X86 | Linux_Arm | RV then
               --  A static Linux link starts in platform/linux, which the
               --  fake host does not hold.
               Args.Append ("--link=libc");
            end if;
            Args.Append ("--emit=asm");
            Args.Append ("-o");
            Args.Append ("p.s");
            Args.Append ("p.ldn");
            declare
               Result : constant Landin.Driver.Outcome :=
                 Landin.Driver.Execute (Args, Host, Tools);
            begin
               Landin.Testing.Check_Equal
                 (Item, Result.Status, Landin.Driver.Status_Success,
                  Target_Name (Of_Case) & ": "
                  & U.To_String (Result.Report));
            end;
            Host.Read_File ("p.s", Assembly, Status);
            Landin.Testing.Check
              (Item, Status = Landin.Platform.Read_Ok
                 and then U.Index (Assembly, Instructions (Of_Case)) > 0
                 and then U.Index (Assembly, "WITHHELD") = 0
                 and then U.Index (Assembly, "{gone}") = 0,
               Target_Name (Of_Case) & " writes the instructions and none"
               & " of their comments");
         end;
      end loop;
   end Assembly_Comments_Are_Not_Emitted;

   procedure Machine_IR (Item : in out Landin.Testing.Context);

   procedure Machine_IR (Item : in out Landin.Testing.Context) is
      use type IR.Verifier.Fault_Kind;
   begin
      for Mode in 1 .. 4 loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (T.Cortex_M);
            Order : Landin.Stages.Pipeline;
            Written : constant Landin.Source.Source_Id :=
              Landin.Stages.Add_Source
                (Work, "machine.ldn", "f: () -> none = end f");
            pragma Unreferenced (Written);
         begin
            Landin.Stages.Append (Order, Frontend'Access);
            Landin.Stages.Append (Order, Configurer'Access);
            Landin.Stages.Append (Order, Resolver'Access);
            Landin.Stages.Append (Order, Checker'Access);
            Landin.Stages.Append (Order, Lowerer'Access);
            Landin.Testing.Check_Equal
              (Item, Landin.Stages.Run (Order, Work), 5,
               "machine verifier control reaches IR");
            declare
               Code : constant not null access IR.Unit :=
                 Landin.Stages.Code (Work);
               Attr : Landin.Machine.Placement;
            begin
               Landin.Testing.Check
                 (Item, IR.Verifier.Check (Code.all, T.Cortex_M).Kind
                    = IR.Verifier.Nothing_Wrong,
                  "unmodified machine verifier control is sound");
               case Mode is
                  when 1 => Attr.Alignment := 3;
                  when 2 => Attr.Vector := 11;
                  when 3 => Attr.Vector := 4;
                  when others => Attr.Keep := True;
               end case;
               IR.Set_Placement (Code.all, 1, Attr);
               Landin.Testing.Check
                 (Item, IR.Verifier.Check
                   (Code.all, (if Mode = 4 then T.Linux_X86_64
                               else T.Cortex_M)).Kind
                    = IR.Verifier.Routine_Signature_Disagrees,
                  "malformed placement/identity refuses before emission");
            end;
         end;
      end loop;
   end Machine_IR;

   procedure Assembly_IR (Item : in out Landin.Testing.Context);

   procedure Literal_Pooling (Item : in out Landin.Testing.Context);

   procedure Literal_Pooling (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
   begin
      Host.Add_File ("pool.ldn", "mut datum: u32 = 1 "
        & "f: () -> (r: u32) = "
        & "r = datum + datum + datum end f "
        & "g: () -> (r: u32) = "
        & "r = 305419896 r = 305419896 end g");
      Args.Append ("--target=cortex-m0");
      Args.Append ("--emit=asm");
      Args.Append ("-o");
      Args.Append ("pool.s");
      Args.Append ("pool.ldn");
      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            U.To_String (Result.Report));
         if Result.Status = Landin.Driver.Status_Success then
            Landin.Testing.Check_Equal
              (Item, Ada.Strings.Fixed.Count
                (Host.Written ("pool.s"), ".word datum"), 1,
               "three datum references share one forward literal");
            Landin.Testing.Check_Equal
              (Item, Ada.Strings.Fixed.Count
                (Host.Written ("pool.s"), ".word 305419896"), 1,
               "repeated non-encodable constants share one literal");
         end if;
      end;
      declare
         Source : U.Unbounded_String := U.To_Unbounded_String
           ("mut datum: u32 = 1 f: () -> (r: u32) = r = 0 ");
         Long_Host : Landin.Testing.Fakes.Fake_Filesystem;
         Long_Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      begin
         for Index in 1 .. 40 loop
            U.Append (Source, "r = r + datum ");
         end loop;
         U.Append (Source, "end f");
         Long_Host.Add_File ("pool.ldn", U.To_String (Source));
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Args, Long_Host, Long_Tools);
         begin
            Landin.Testing.Check_Equal
              (Item, Result.Status, Landin.Driver.Status_Success,
               U.To_String (Result.Report));
            if Result.Status = Landin.Driver.Status_Success then
               declare
                  Words : constant Natural := Ada.Strings.Fixed.Count
                    (Long_Host.Written ("pool.s"), ".word datum");
               begin
                  Landin.Testing.Check
                    (Item, Words in 2 .. 20,
                     "long code flushes reachable pools and reuses words");
               end;
            end if;
         end;
      end;
      declare
         Boundary_Host : Landin.Testing.Fakes.Fake_Filesystem;
         Boundary_Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      begin
         --  The pending datum literal reaches its distance bound inside a
         --  shortenable branch. Replacing that branch must retain the pool.
         Boundary_Host.Add_File ("pool.ldn", "mut datum: u32 = 1 "
           & "f: (x: u32) -> (r: u32) = r = datum unchecked begin "
           & "r = r + x r = r + x end unchecked "
           & "if x == 0 then r = 3 else r = 2 end if end f");
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Args, Boundary_Host, Boundary_Tools);
         begin
            Landin.Testing.Check_Equal
              (Item, Result.Status, Landin.Driver.Status_Success,
               U.To_String (Result.Report));
            if Result.Status = Landin.Driver.Status_Success then
               Landin.Testing.Check_Equal
                 (Item, Ada.Strings.Fixed.Count
                   (Boundary_Host.Written ("pool.s"), ".word datum"), 1,
                  "shortening a branch preserves its inserted literal pool");
            end if;
         end;
      end;
      declare
         Jump_Host : Landin.Testing.Fakes.Fake_Filesystem;
         Jump_Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      begin
         --  The pool limit falls between a long jump's label and its
         --  address word. A flush there would load instructions into r7.
         Jump_Host.Add_File ("pool.ldn", "mut state: [3]u32 = [7, 8, 9] "
           & "public main: () -> (code: i32) = "
           & "mut local: [4]u64 = [10, 20, 30, 40] "
           & "state = zeroed local = zeroed "
           & "if state[0] == 0 and state[2] == 0 "
           & "and local[0] == 0 and local[3] == 0 then "
           & "code = 42 else code = 1 end if end main");
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Args, Jump_Host, Jump_Tools);
         begin
            Landin.Testing.Check_Equal
              (Item, Result.Status, Landin.Driver.Status_Success,
               U.To_String (Result.Report));
            if Result.Status = Landin.Driver.Status_Success then
               declare
                  Code : constant String := Jump_Host.Written ("pool.s");
                  Cursor : Positive := Code'First;
                  Found, Last : Natural;
               begin
                  loop
                     Found := Ada.Strings.Fixed.Index
                       (Code, "ldr r7, Lcm_step_", From => Cursor);
                     exit when Found = 0;
                     Last := Ada.Strings.Fixed.Index
                       (Code, String'(1 => LF), From => Found);
                     Landin.Testing.Check
                       (Item, Ada.Strings.Fixed.Index
                         (Code, Code (Found + 8 .. Last - 1) & ":" & LF
                           & Character'Val (9) & ".word ") > 0,
                        "a long jump label remains attached to its word");
                     Cursor := Last + 1;
                  end loop;
               end;
            end if;
         end;
      end;
   end Literal_Pooling;

   --  [1630]'s one instruction, from D230's shorthand and from the named
   --  form, and the verifier's refusal of each way it can be malformed.
   --  Mode 8 is the per-target evidence: a register [1990]'s Cortex-M0
   --  table never answers for.
   procedure Assembly_IR (Item : in out Landin.Testing.Context) is
      use type IR.Verifier.Fault_Kind;
      use type IR.Slot_Id;
      use type IR.Assembly_Direction;
   begin
      for Mode in 1 .. 10 loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (T.Cortex_M);
            Order : Landin.Stages.Pipeline;
            Written : constant Landin.Source.Source_Id :=
              Landin.Stages.Add_Source
                (Work, "assembly.ldn", "f: (x: u32) -> (r: u32) = "
                 & "flag: bool = true _ = flag "
                 & (if Mode <= 4
                    then "r = assembler.block(""adds r0, #7"", x)"
                    else "r = assembler.block(""adds {o}, {i}, #7"","
                         & " out o: u32 at general,"
                         & " in i: u32 at r1 = x)")
                 & " end f");
            pragma Unreferenced (Written);
         begin
            Landin.Stages.Append (Order, Frontend'Access);
            Landin.Stages.Append (Order, Configurer'Access);
            Landin.Stages.Append (Order, Resolver'Access);
            Landin.Stages.Append (Order, Checker'Access);
            Landin.Stages.Append (Order, Lowerer'Access);
            Landin.Testing.Check_Equal
              (Item, Landin.Stages.Run (Order, Work), 5,
               "assembly reaches verified IR");
            declare
               Code : constant not null access IR.Unit :=
                 Landin.Stages.Code (Work);
               Assembly_Value : IR.Value_Id := IR.No_Value;
               Boolean_Value : IR.Value_Id := IR.No_Value;
            begin
               for V in 1 .. IR.Value_Count (Code.all, 1) loop
                  if IR.Op_Of (Code.all, 1, IR.Value_Id (V)) = IR.Assembly
                  then
                     Assembly_Value := IR.Value_Id (V);
                  elsif IR.Op_Of (Code.all, 1, IR.Value_Id (V)) = IR.Truth
                  then
                     Boolean_Value := IR.Value_Id (V);
                  end if;
               end loop;
               Landin.Testing.Check
                 (Item, IR.Verifier.Check (Code.all, T.Cortex_M).Kind
                          = IR.Verifier.Nothing_Wrong,
                  "the block verifies as lowered");
               declare
                  First : constant IR.Assembly_Operand :=
                    IR.Nth_Assembly_Operand (Code.all, 1, Assembly_Value, 1);
                  Other_Slot : constant IR.Slot_Id :=
                    (if First.Output = 1 then 2 else 1);
               begin
                  Landin.Testing.Check
                    (Item, (if Mode <= 4
                            then IR.Register_Of (First) = "r0"
                              and then First.Direction = IR.Both
                            else IR.Register_Of (First) = ""
                              and then First.Direction = IR.Output),
                     "the operand is what the source wrote");
                  case Mode is
                     when 1 =>
                        --  An input of another type than the operand's.
                        IR.Testing_Support.Overwrite_Operand
                          (Code.all, 1, Assembly_Value, 1, Boolean_Value);
                     when 2 =>
                        --  An output written to a slot of another type.
                        IR.Testing_Support.Overwrite_Assembly_Operand
                          (Code.all, 1, Assembly_Value, 1,
                           IR.Operand_At
                             (IR.Both, First.Name, "r0", Ty.U16,
                              First.Output));
                     when 3 =>
                        --  The shorthand on a target that has no r0.
                        null;
                     when 4 =>
                        --  An output that writes no slot.
                        IR.Testing_Support.Overwrite_Assembly_Operand
                          (Code.all, 1, Assembly_Value, 1,
                           IR.Operand_At
                             (IR.Both, First.Name, "r0", Ty.U32));
                     when 5 =>
                        --  `general` asked of a discarded output.
                        IR.Testing_Support.Overwrite_Assembly_Operand
                          (Code.all, 1, Assembly_Value, 1,
                           IR.Operand_At
                             (IR.Discarded, Landin.Source.Names.No_Name, "",
                              Ty.Not_Typed));
                     when 6 =>
                        --  Two operands on one register.
                        IR.Testing_Support.Overwrite_Assembly_Operand
                          (Code.all, 1, Assembly_Value, 1,
                           IR.Operand_At
                             (IR.Output, First.Name, "r1", Ty.U32,
                              First.Output));
                     when 7 =>
                        --  An output slot that is not the routine's.
                        IR.Testing_Support.Overwrite_Assembly_Operand
                          (Code.all, 1, Assembly_Value, 1,
                           IR.Operand_At
                             (IR.Output, First.Name, "", Ty.U32,
                              IR.Slot_Id (IR.Slot_Count (Code.all, 1) + 1)));
                     when 8 =>
                        --  A register Cortex-M0's table never answers for.
                        IR.Testing_Support.Overwrite_Assembly_Operand
                          (Code.all, 1, Assembly_Value, 1,
                           IR.Operand_At
                             (IR.Output, First.Name, "r8", Ty.U32,
                              First.Output));
                     when 9 =>
                        --  A wider operand than one Cortex-M0 register.
                        IR.Testing_Support.Overwrite_Assembly_Operand
                          (Code.all, 1, Assembly_Value, 1,
                           IR.Operand_At
                             (IR.Output, First.Name, "", Ty.U64,
                              Other_Slot));
                     when others =>
                        --  An output may not replace the input parameter.
                        IR.Testing_Support.Overwrite_Assembly_Operand
                          (Code.all, 1, Assembly_Value, 1,
                           IR.Operand_At
                             (IR.Output, First.Name, "", Ty.U32,
                              IR.Nth_Parameter (Code.all, 1, 1)));
                  end case;
               end;
               declare
                  Found : constant IR.Verifier.Fault_Kind :=
                    IR.Verifier.Check
                      (Code.all, (if Mode = 3 then T.Linux_X86_64
                                  else T.Cortex_M)).Kind;
               begin
                  Landin.Testing.Check
                    (Item, Found /= IR.Verifier.Nothing_Wrong,
                     "malformed assembly refuses before selection");
                  if Mode in 3 | 8 then
                     Landin.Testing.Check
                       (Item, Found = IR.Verifier.Assembly_Register_Refused,
                        "the register table refuses it");
                  elsif Mode = 10 then
                     Landin.Testing.Check
                       (Item, Found =
                          IR.Verifier.Assembly_Output_To_A_Parameter,
                        "an assembly output cannot replace a parameter");
                     Landin.Testing.Check
                       (Item, IR.Verifier.Check (Code.all).Kind = Found,
                        "the target-neutral verifier also refuses it");
                  end if;
               end;
            end;
         end;
      end loop;
   end Assembly_IR;

   procedure Shared_Returns (Item : in out Landin.Testing.Context);

   procedure Shared_Returns (Item : in out Landin.Testing.Context) is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
   begin
      Host.Add_File ("p.ldn",
        "bad: atom "
        & "pair: type = struct value: u32 end pair "
        & "scalar: (x: u32) -> (r: u32) ! bad = "
        & "r = x return when x == 0 fail bad when x == 1 "
        & "r = x + 1 end scalar "
        & "aggregate: (x: u32) -> (r: pair) = "
        & "r = pair(value: x) return when x == 0 "
        & "r = pair(value: x + 1) end aggregate "
        & "single: () -> none = end single");
      Args.Append ("--target=cortex-m0");
      Args.Append ("--optimize=size");
      Args.Append ("--debug=lines");
      Args.Append ("--emit=asm");
      Args.Append ("-o");
      Args.Append ("p.s");
      Args.Append ("p.ldn");
      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            U.To_String (Result.Report));
         if Result.Status = Landin.Driver.Status_Success then
            declare
               Text : constant String := Host.Written ("p.s");
               function Count (Part : String) return Natural
                 is (Ada.Strings.Fixed.Count (Text, Part));
            begin
               Landin.Testing.Check
                 (Item, Count ("_return:") = 2
                    and then Count ("_return" & LF) = 5,
                  "five scalar, aggregate, and failure exits share two"
                  & " return blocks");
               Landin.Testing.Check
                 (Item, Count ("mov sp, r6") = 0
                    and then Count ("bx lr") = 3,
                  "single exit stays inline and shared exits restore once");
               Landin.Testing.Check
                 (Item, Count ("mov r12, r0") = 1
                    and then Count ("mov r12, r2") = 5,
                  "failure carrier and successful return preparations differ");
               Landin.Testing.Check
                 (Item, Count (".cfi_remember_state") = 3
                    and then Count (".cfi_restore_state") = 3,
                  "each teardown restores its framed debug CFI state");
            end;
         end if;
      end;
   end Shared_Returns;

   --  D542-D547: descriptions selected by device identity, every refusal
   --  of one, and the vector words each profile leaves.  The RP2040 and
   --  reference descriptions are the checkout's own files, read from the
   --  real host deliberately; the expectations are written here apart from
   --  them, from pico-sdk 2.2.0's map and [1990].
   procedure Device_Descriptions (Item : in out Landin.Testing.Context);
   procedure Device_Descriptions (Item : in out Landin.Testing.Context) is
      Real : Landin.Platform.Native.Native_Filesystem;
      LF : constant String := [1 => ASCII.LF];

      function Checkout (Path : String) return String;
      function Checkout (Path : String) return String is
         Text : U.Unbounded_String;
         Status : Landin.Platform.Read_Status;
      begin
         Real.Read_File ("../../" & Path, Text, Status);
         if Status /= Landin.Platform.Read_Ok then
            raise Program_Error with "cannot read " & Path;
         end if;
         return U.To_String (Text);
      end Checkout;

      Plain_Interrupts : constant String :=
        "compiler.device(""plain"")" & LF
        & "compiler.core(""cortex-m0plus"")" & LF
        & "compiler.vectors(48)" & LF
        & "compiler.interrupt(""ONE"", 1)" & LF;
      Plain_Memory : constant String :=
        "linker.region(""FLASH"", 0x0800_0000, 64 * 1024, ""rx"")" & LF
        & "linker.region(""RAM"", 0x2000_0000, 8 * 1024, ""rw"")" & LF
        & "compiler.boot(""vector-table"")" & LF
        & "linker.place(""vectors"", ""FLASH"")" & LF
        & "linker.place(""text"", ""FLASH"")" & LF
        & "linker.place(""rodata"", ""FLASH"")" & LF
        & "linker.place(""data"", ""RAM"")" & LF
        & "linker.place(""bss"", ""RAM"")" & LF
        & "linker.place(""stack"", ""RAM"", 1024)" & LF;

      --  Compile /w/app, which imports descriptions/dev when Imports,
      --  against a description of those two files; the first code, or ""
      --  when it compiled, and the assembly.
      procedure Try
        (Program : String; Interrupts, Memory : String;
         Code : out U.Unbounded_String; Assembly : out U.Unbounded_String;
         Imports : Boolean := True; Library : Boolean := True;
         Extra : String := "--firmware-entry=start";
         Target : String := "--target=cortex-m0";
         Second : Boolean := False; Stage : String := "");
      procedure Try
        (Program : String; Interrupts, Memory : String;
         Code : out U.Unbounded_String; Assembly : out U.Unbounded_String;
         Imports : Boolean := True; Library : Boolean := True;
         Extra : String := "--firmware-entry=start";
         Target : String := "--target=cortex-m0";
         Second : Boolean := False; Stage : String := "")
      is
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Args : Landin.Platform.Path_List;
         Status : Landin.Platform.Read_Status;
      begin
         if Library then
            Host.Add_Firmware_Library;
         end if;
         Host.Add_Directory ("/w");
         Host.Add_Directory ("/w/app");
         Host.Add_Directory ("/w/devices");
         Host.Add_Directory ("/w/devices/descriptions");
         Host.Add_Directory ("/w/devices/descriptions/dev");
         Host.Add_File ("/w/app/main.ldn",
           (if Imports then "import descriptions/dev" & LF else "")
           & (if Second then "import descriptions/other" & LF else "")
           & Program & LF & "start: () -> none = end start" & LF);
         Host.Add_File ("/w/devices/descriptions/dev/interrupts.ldn",
           Interrupts);
         Host.Add_File ("/w/devices/descriptions/dev/memory.ldn", Memory);
         if Stage /= "" then
            Host.Add_File ("/w/devices/descriptions/dev/boot2.ldn", Stage);
         end if;
         if Second then
            Host.Add_Directory ("/w/devices/descriptions/other");
            Host.Add_File ("/w/devices/descriptions/other/interrupts.ldn",
              "compiler.device(""other"")" & LF);
         end if;
         Args.Append ("--root=/w/devices");
         Args.Append (Target);
         --  Extra is words separated by single spaces.
         declare
            First : Positive := Extra'First;
         begin
            for Index in Extra'Range loop
               if Extra (Index) = ' ' then
                  Args.Append (Extra (First .. Index - 1));
                  First := Index + 1;
               end if;
            end loop;
            if First <= Extra'Last then
               Args.Append (Extra (First .. Extra'Last));
            end if;
         end;
         Args.Append ("--emit=asm");
         Args.Append ("-o");
         Args.Append ("/w/p.s");
         Args.Append ("/w/app");
         declare
            Ran : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Args, Host, Tools);
         begin
            Code := U.Null_Unbounded_String;
            if Landin.Diagnostics.Count (Ran.Found) > 0 then
               Code := U.To_Unbounded_String (Landin.Diagnostics.Code
                 (Landin.Diagnostics.Get (Ran.Found, 1)));
            end if;
            Assembly := U.Null_Unbounded_String;
            Host.Read_File ("/w/p.s", Assembly, Status);
         end;
      end Try;

      --  The vector word at SLOT in an emitted table.
      function Vector_Word (Assembly : String; Slot : Natural) return String;
      function Vector_Word (Assembly : String; Slot : Natural) return String
      is
         Cursor : Natural := Ada.Strings.Fixed.Index
           (Assembly, "_landin_firmware_vectors:");
      begin
         if Cursor = 0 then
            return "";
         end if;
         for Index in 0 .. Slot loop
            Cursor := Ada.Strings.Fixed.Index
              (Assembly, ".word ", From => Cursor + 1);
            exit when Cursor = 0;
         end loop;
         if Cursor = 0 then
            return "";
         end if;
         return Assembly (Cursor + 6 .. Ada.Strings.Fixed.Index
           (Assembly, LF, From => Cursor) - 1);
      end Vector_Word;

      procedure Expect
        (Name, Program, Interrupts, Memory, Wanted : String;
         Imports : Boolean := True; Library : Boolean := True;
         Extra : String := "--firmware-entry=start";
         Target : String := "--target=cortex-m0";
         Second : Boolean := False; Stage : String := "");
      procedure Expect
        (Name, Program, Interrupts, Memory, Wanted : String;
         Imports : Boolean := True; Library : Boolean := True;
         Extra : String := "--firmware-entry=start";
         Target : String := "--target=cortex-m0";
         Second : Boolean := False; Stage : String := "")
      is
         Code, Assembly : U.Unbounded_String;
      begin
         Try (Program, Interrupts, Memory, Code, Assembly, Imports, Library,
              Extra, Target, Second, Stage);
         Landin.Testing.Check_Equal
           (Item, U.To_String (Code), Wanted, Name);
      end Expect;

      RP2040_Interrupts : constant String :=
        Checkout ("devices/descriptions/rp2040/interrupts.ldn");
      RP2040_Memory : constant String :=
        Checkout ("devices/descriptions/rp2040/memory.ldn");
      RP2040_Stage : constant String :=
        Checkout ("devices/descriptions/rp2040/boot2.ldn");
      --  D587: a stage, and a plain description that boots RP2040's way.
      Small_Stage : constant String :=
        "link(boot_stage) extern(naked) stage: () -> none =" & LF
        & "    assembler.block(""bx lr"")" & LF & "end stage" & LF;
      Boot2_Memory : constant String :=
        "linker.region(""FLASH"", 0x1000_0000, 64 * 1024, ""rx"")" & LF
        & "linker.region(""RAM"", 0x2000_0000, 8 * 1024, ""rw"")" & LF
        & "compiler.boot(""rp2040-boot2"")" & LF
        & Plain_Memory (Ada.Strings.Fixed.Index
          (Plain_Memory, "linker.place(""vectors""") .. Plain_Memory'Last);
      Block_Memory : constant String :=
        "linker.region(""FLASH"", 0x1000_0000, 64 * 1024, ""rx"")" & LF
        & "linker.region(""RAM"", 0x2000_0000, 8 * 1024, ""rw"")" & LF
        & "compiler.boot(""rp2350-image-block"")" & LF
        & Plain_Memory (Ada.Strings.Fixed.Index
          (Plain_Memory, "linker.place(""vectors""") .. Plain_Memory'Last);
      RP2350_Interrupts : constant String :=
        Checkout ("devices/descriptions/rp2350/interrupts.ldn");
      RP2350_Memory : constant String :=
        Checkout ("devices/descriptions/rp2350/memory.ldn");
      Code, Assembly : U.Unbounded_String;
   begin
      --  RP2040 by its identity: USBCTRL_IRQ's slot 21 holds the handler,
      --  the second stage comes first and the table follows it.
      Try ("link(vector: 21) extern(interrupt) usb: () -> none = end usb",
           RP2040_Interrupts, RP2040_Memory, Code, Assembly,
           Stage => RP2040_Stage);
      Landin.Testing.Check_Equal
        (Item, U.To_String (Code), "", "RP2040 admits slot 21");
      Landin.Testing.Check
        (Item, Vector_Word (U.To_String (Assembly), 21) /= ""
           and then Vector_Word (U.To_String (Assembly), 21)
             not in "0" | "_landin_firmware_unhandled",
         "RP2040's vector word 21 is the USBCTRL_IRQ handler");
      Landin.Testing.Check_Equal
        (Item, Vector_Word (U.To_String (Assembly), 47),
         "_landin_firmware_unhandled",
         "RP2040's spare IRQ5 at slot 47 is implemented");
      Landin.Testing.Check_Equal
        (Item, Vector_Word (U.To_String (Assembly), 4), "0",
         "RP2040's ARMv6-M reserved slot 4 is zero");
      --  D588: the stage's first instruction is the slot's first byte,
      --  its literals follow it, then zeros to the checksum's word.
      Landin.Testing.Check
        (Item, Contains (U.To_String (Assembly),
           HT & ".section .boot2,""ax"",%progbits" & LF
           & HT & ".globl _landin_firmware_boot2" & LF
           & "_landin_firmware_boot2:" & LF
           & HT & ".globl boot2" & LF
           & HT & ".balign 2" & LF
           & HT & ".type boot2, %function" & LF
           & HT & ".thumb_func" & LF
           & "boot2:" & LF & LF
           & "push {lr}" & LF),
         "RP2040's second stage begins its slot");
      Landin.Testing.Check
        (Item, Contains (U.To_String (Assembly),
           "bx r1" & LF & LF
           & HT & "udf #1" & LF
           & HT & ".ltorg" & LF
           & HT & ".size boot2, . - boot2" & LF
           & HT & ".size _landin_firmware_boot2, . - _landin_firmware_boot2"
           & LF
           & HT & ".space (252 - (. - _landin_firmware_boot2)) & ((. -"
           & " _landin_firmware_boot2) <= 252)" & LF
           & HT & ".word 0" & LF),
         "RP2040's stage is padded to 252 bytes and a zero checksum word");
      Landin.Testing.Check
        (Item, not Contains (U.To_String (Assembly), ".zero 256"),
         "RP2040's second-stage slot no longer holds zeros alone");

      --  D637: RP2350 by its identity, PROC0_IRQ_CTI's slot 56 taking a
      --  handler; the table at the start of flash and the image block
      --  directly after it, in a section of its own.
      Try ("link(vector: 56) extern(interrupt) cti: () -> none = end cti",
           RP2350_Interrupts, RP2350_Memory, Code, Assembly,
           Extra => "--firmware-entry=start --level=armv8-m.main");
      Landin.Testing.Check_Equal
        (Item, U.To_String (Code), "", "RP2350 admits slot 56");
      Landin.Testing.Check
        (Item, Vector_Word (U.To_String (Assembly), 56)
           not in "" | "0" | "_landin_firmware_unhandled",
         "RP2350's vector word 56 is the PROC0_IRQ_CTI handler");
      Landin.Testing.Check_Equal
        (Item, Vector_Word (U.To_String (Assembly), 7),
         "_landin_firmware_unhandled",
         "RP2350's SecureFault slot 7 is the M33's");
      Landin.Testing.Check_Equal
        (Item, Vector_Word (U.To_String (Assembly), 8), "0",
         "RP2350's reserved slot 8 is zero");
      Landin.Testing.Check
        (Item, Contains (U.To_String (Assembly),
           HT & ".balign 512" & LF
           & HT & ".globl _landin_firmware_vectors" & LF)
           and then Contains (U.To_String (Assembly),
             HT & ".word _landin_firmware_unhandled" & LF
             & HT & ".section .embedded_block,""a"",%progbits" & LF
             & HT & ".balign 4" & LF
             & HT & ".globl _landin_firmware_image_block" & LF
             & HT & ".type _landin_firmware_image_block, %object" & LF
             & "_landin_firmware_image_block:" & LF
             & HT & ".word 0xffffded3" & LF
             & HT & ".word 0x10210142" & LF
             & HT & ".word 0x1ff" & LF
             & HT & ".word 0x0" & LF
             & HT & ".word 0xab123579" & LF
             & HT & ".size _landin_firmware_image_block, . -"
             & " _landin_firmware_image_block" & LF)
           and then not Contains (U.To_String (Assembly), ".boot2"),
         "RP2350's image block follows its 68-word table");

      --  The constrained reference: slot 21 refused, and zero beside a
      --  handler at slot 20.
      Expect ("the reference refuses slot 21",
        "link(vector: 21) extern(interrupt) usb: () -> none = end usb",
        "", "", "L0347", Imports => False);
      Try ("link(vector: 20) extern(interrupt) h: () -> none = end h",
           "", "", Code, Assembly, Imports => False);
      Landin.Testing.Check_Equal
        (Item, Vector_Word (U.To_String (Assembly), 21), "0",
         "the reference emits zero at slot 21");
      Landin.Testing.Check
        (Item, Ada.Strings.Fixed.Index (U.To_String (Assembly), ".boot2")
           = 0 and then Ada.Strings.Fixed.Index
             (U.To_String (Assembly), ".balign 256") > 0,
         "the reference's table has no second stage and keeps its"
         & " alignment");
      Expect ("a plain description compiles", "", Plain_Interrupts,
        Plain_Memory, "");

      --  Each refusal.
      Expect ("an unknown core is L0399", "",
        "compiler.device(""plain"")" & LF & "compiler.core(""cortex-m99"")"
        & LF & "compiler.vectors(48)" & LF, Plain_Memory, "L0399");
      Expect ("a stack without a size is L0399", "", Plain_Interrupts,
        Plain_Memory & "linker.place(""stack"", ""RAM"")" & LF, "L0399");
      Expect ("a directive outside a description is L0513",
        "linker.region(""X"", 0, 4, ""rx"")", "", "", "L0513",
        Imports => False);
      Expect ("a directive in a fixed arm is L0513", "",
        Plain_Interrupts & "fixed if false then" & LF
        & "compiler.interrupt(""TWO"", 2)" & LF & "end if" & LF,
        Plain_Memory, "L0513");
      Expect ("a declaration in a description is L0513", "",
        Plain_Interrupts & "x: u32 = 1" & LF, Plain_Memory, "L0513");
      Expect ("a missing boot kind is L0513", "", Plain_Interrupts,
        "linker.region(""FLASH"", 0x0800_0000, 64 * 1024, ""rx"")" & LF
        & "linker.region(""RAM"", 0x2000_0000, 8 * 1024, ""rw"")" & LF
        & "linker.place(""vectors"", ""FLASH"")" & LF
        & "linker.place(""text"", ""FLASH"")" & LF
        & "linker.place(""rodata"", ""FLASH"")" & LF
        & "linker.place(""data"", ""RAM"")" & LF
        & "linker.place(""bss"", ""RAM"")" & LF
        & "linker.place(""stack"", ""RAM"", 1024)" & LF, "L0513");
      Expect ("a second description is L0513", "", Plain_Interrupts,
        Plain_Memory, "L0513", Second => True);
      Expect ("overlapping regions are L0514", "", Plain_Interrupts,
        Plain_Memory
        & "linker.region(""MORE"", 0x2000_1000, 8 * 1024, ""rw"")" & LF,
        "L0514");
      Expect ("text in a region code cannot run in is L0514", "",
        Plain_Interrupts,
        "linker.region(""FLASH"", 0x0800_0000, 64 * 1024, ""rw"")" & LF
        & "linker.region(""RAM"", 0x2000_0000, 8 * 1024, ""rw"")" & LF
        & "compiler.boot(""vector-table"")" & LF
        & "linker.place(""vectors"", ""RAM"")" & LF
        & "linker.place(""text"", ""FLASH"")" & LF
        & "linker.place(""rodata"", ""FLASH"")" & LF
        & "linker.place(""data"", ""RAM"")" & LF
        & "linker.place(""bss"", ""RAM"")" & LF
        & "linker.place(""stack"", ""RAM"", 1024)" & LF, "L0514");
      Expect ("a placement into an unknown region is L0514", "",
        Plain_Interrupts,
        Plain_Memory (Plain_Memory'First .. Ada.Strings.Fixed.Index
          (Plain_Memory, "linker.place(""stack""") - 1)
        & "linker.place(""stack"", ""NOWHERE"", 1024)" & LF, "L0514");
      Expect ("an IRQ past the table is L0514", "",
        Plain_Interrupts & "compiler.interrupt(""FAR"", 40)" & LF,
        Plain_Memory, "L0514");
      --  D543: a core builds at its own level or a lower one of its
      --  family, never a higher one, and the reference at every level.
      Expect ("a core above its level is L0515", "", Plain_Interrupts,
        Plain_Memory, "L0515",
        Extra => "--firmware-entry=start --level=armv7-m");
      Expect ("a cortex-m4 at its own level compiles", "",
        "compiler.device(""plain"")" & LF & "compiler.core(""cortex-m4"")"
        & LF & "compiler.vectors(48)" & LF, Plain_Memory, "",
        Extra => "--firmware-entry=start --level=armv7e-m");
      Expect ("a cortex-m4 at armv7-m compiles", "",
        "compiler.device(""plain"")" & LF & "compiler.core(""cortex-m4"")"
        & LF & "compiler.vectors(48)" & LF, Plain_Memory, "",
        Extra => "--firmware-entry=start --level=armv7-m");
      Expect ("a cortex-m4 at armv6-m compiles",
        "link(vector: 11) extern(interrupt) h: () -> none = end h",
        "compiler.device(""plain"")" & LF & "compiler.core(""cortex-m4"")"
        & LF & "compiler.vectors(48)" & LF, Plain_Memory, "",
        Extra => "--firmware-entry=start");
      Expect ("a cortex-m3 at armv7e-m is L0515", "",
        "compiler.device(""plain"")" & LF & "compiler.core(""cortex-m3"")"
        & LF & "compiler.vectors(48)" & LF, Plain_Memory, "L0515",
        Extra => "--firmware-entry=start --level=armv7e-m");
      --  ARMv7E-M and ARMv8-M Mainline do not nest: each holds ARMv7-M.
      Expect ("a cortex-m33 at its own level compiles",
        "link(vector: 7) extern(interrupt) h: () -> none = end h",
        "compiler.device(""plain"")" & LF & "compiler.core(""cortex-m33"")"
        & LF & "compiler.vectors(48)" & LF, Plain_Memory, "",
        Extra => "--firmware-entry=start --level=armv8-m.main");
      Expect ("a cortex-m33 at armv7-m compiles", "",
        "compiler.device(""plain"")" & LF & "compiler.core(""cortex-m33"")"
        & LF & "compiler.vectors(48)" & LF, Plain_Memory, "",
        Extra => "--firmware-entry=start --level=armv7-m");
      Expect ("a cortex-m33 at armv7e-m is L0515", "",
        "compiler.device(""plain"")" & LF & "compiler.core(""cortex-m33"")"
        & LF & "compiler.vectors(48)" & LF, Plain_Memory, "L0515",
        Extra => "--firmware-entry=start --level=armv7e-m");
      Expect ("a cortex-m7 at armv8-m.main is L0515", "",
        "compiler.device(""plain"")" & LF & "compiler.core(""cortex-m7"")"
        & LF & "compiler.vectors(48)" & LF, Plain_Memory, "L0515",
        Extra => "--firmware-entry=start --level=armv8-m.main");
      Expect ("the reference builds at armv7e-m",
        "link(vector: 20) extern(interrupt) h: () -> none = end h",
        "", "", "", Imports => False,
        Extra => "--firmware-entry=start --level=armv7e-m");
      Expect ("a description on a hosted target is L0515", "",
        Plain_Interrupts, Plain_Memory, "L0515", Extra => "",
        Target => "--target=linux-x86-64");
      Expect ("a reserved boot kind is L0516", "", Plain_Interrupts,
        "compiler.boot(""esp-app-image"")" & LF
        & Plain_Memory (Ada.Strings.Fixed.Index
          (Plain_Memory, "linker.place(""vectors""") .. Plain_Memory'Last)
        & "linker.region(""FLASH"", 0x0800_0000, 64 * 1024, ""rx"")" & LF
        & "linker.region(""RAM"", 0x2000_0000, 8 * 1024, ""rw"")" & LF,
        "L0516");
      Expect ("an unknown region placement is L0517",
        "link(region: ""NOWHERE"") x: u32 = 1", Plain_Interrupts,
        Plain_Memory, "L0517");
      Expect ("a routine in a region code cannot run in is L0517",
        "link(region: ""RAM"") f: () -> none = end f", Plain_Interrupts,
        Plain_Memory, "L0517");
      Expect ("firmware with no library and no description is L0518", "",
        "", "", "L0518", Imports => False, Library => False);
      Expect ("a vector with no profile is L0518",
        "link(vector: 11) extern(interrupt) h: () -> none = end h",
        "", "", "L0518", Imports => False, Library => False, Extra => "");
      Expect ("a program with no placement needs no library", "",
        "", "", "", Imports => False, Library => False, Extra => "");

      --  D587: the boot stage and where it may be.
      Expect ("an rp2040-boot2 description with a stage compiles", "",
        Plain_Interrupts, Boot2_Memory, "", Stage => Small_Stage);
      Expect ("an rp2040-boot2 description without a stage is L0537", "",
        Plain_Interrupts, Boot2_Memory, "L0537");
      Expect ("a vector-table description with a stage is L0535", "",
        Plain_Interrupts, Plain_Memory, "L0535", Stage => Small_Stage);
      Expect ("an rp2350-image-block description with a stage is L0535", "",
        Plain_Interrupts, Block_Memory, "L0535", Stage => Small_Stage);
      Expect ("an rp2350-image-block description compiles", "",
        Plain_Interrupts, Block_Memory, "");
      Expect ("a second stage is L0536", "", Plain_Interrupts,
        Boot2_Memory, "L0536",
        Stage => Small_Stage
          & "link(boot_stage) extern(naked) other: () -> none =" & LF
          & "    assembler.block(""bx lr"")" & LF & "end other" & LF);
      Expect ("a stage outside the description is L0534", Small_Stage,
        Plain_Interrupts, Boot2_Memory, "L0534", Stage => Small_Stage);
      Expect ("a stage with no description is L0534", Small_Stage,
        "", "", "L0534", Imports => False);
      Expect ("an ordinary routine as a stage is L0533", "",
        Plain_Interrupts, Boot2_Memory, "L0533",
        Stage => "link(boot_stage) stage: () -> none = end stage" & LF);
      Expect ("a binding as a stage is L0533", "",
        Plain_Interrupts, Boot2_Memory, "L0533",
        Stage => "link(boot_stage) stage: u32 = 1" & LF);
      Expect ("a stage with a section is L0533", "",
        Plain_Interrupts, Boot2_Memory, "L0533",
        Stage => "link(boot_stage, section: "".text.x"") extern(naked)"
          & " stage: () -> none =" & LF
          & "    assembler.block(""bx lr"")" & LF & "end stage" & LF);
   end Device_Descriptions;

   --  D588: the boot ROM's checksum, and the object it is sealed into.
   procedure Boot_Stage_Seal (Item : in out Landin.Testing.Context);
   procedure Boot_Stage_Seal (Item : in out Landin.Testing.Context) is
      use type Landin.Targets.Firmware.Checksum;
      type Relocation_Kind is (None, From_Stage, To_Stage);

      function Bytes (Value, Width : Natural) return String;
      function Bytes (Value, Width : Natural) return String is
         Result : String (1 .. Width);
         Rest : Natural := Value;
      begin
         for Index in Result'Range loop
            Result (Index) := Character'Val (Rest mod 256);
            Rest := Rest / 256;
         end loop;
         return Result;
      end Bytes;

      --  A 32-bit little-endian Arm relocatable object holding a .boot2 of
      --  SIZE bytes, and with KIND a relocation in it, or one in .text
      --  against a symbol defined in it.
      function Object (Size : Natural; Kind : Relocation_Kind)
        return String;
      function Object (Size : Natural; Kind : Relocation_Kind)
        return String
      is
         NUL : constant Character := ASCII.NUL;
         Names : constant String := NUL & ".boot2" & NUL & ".shstrtab" & NUL
           & ".symtab" & NUL & ".strtab" & NUL & ".text" & NUL & ".rel.x"
           & NUL;
         function Pattern return String;
         function Pattern return String is
            Result : String (1 .. Size);
         begin
            for Index in Result'Range loop
               Result (Index) := Character'Val (Index * 7 mod 251);
            end loop;
            return Result;
         end Pattern;
         Stage : constant String := Pattern;
         Strings : constant String := NUL & "far" & NUL & "inside" & NUL;
         --  The null symbol, `far` undefined and `inside` in .boot2.
         Symbols : constant String := Bytes (0, 16)
           & Bytes (1, 4) & Bytes (0, 8) & Bytes (16#10#, 2) & Bytes (0, 2)
           & Bytes (5, 4) & Bytes (0, 8) & Bytes (16#10#, 2) & Bytes (1, 2);
         Text : constant String := Bytes (0, 4);
         Relocation : constant String := Bytes (8, 4)
           & Bytes ((if Kind = From_Stage then 1 else 2) * 256 + 2, 4);
         Body_Of : constant String := Stage & Names & Strings & Symbols
           & Text & Relocation;
         At_Stage : constant Natural := 52;
         At_Names : constant Natural := At_Stage + Size;
         At_Strings : constant Natural := At_Names + Names'Length;
         At_Symbols : constant Natural := At_Strings + Strings'Length;
         At_Text : constant Natural := At_Symbols + Symbols'Length;
         At_Relocation : constant Natural := At_Text + Text'Length;
         Pad : constant Natural := (4 - (52 + Body_Of'Length) mod 4) mod 4;
         Headers : constant Natural := 52 + Body_Of'Length + Pad;
         Count : constant Natural := (if Kind = None then 6 else 7);
         function Section
           (Name, Kind_Of, Flags, Offset, Length, Link, Info, Size_Of :
              Natural) return String
         is (Bytes (Name, 4) & Bytes (Kind_Of, 4) & Bytes (Flags, 4)
             & Bytes (0, 4) & Bytes (Offset, 4) & Bytes (Length, 4)
             & Bytes (Link, 4) & Bytes (Info, 4) & Bytes (4, 4)
             & Bytes (Size_Of, 4));
      begin
         return Character'Val (127) & "ELF" & Character'Val (1)
           & Character'Val (1) & Character'Val (1) & Bytes (0, 9)
           & Bytes (1, 2) & Bytes (40, 2) & Bytes (1, 4) & Bytes (0, 4)
           & Bytes (0, 4) & Bytes (Headers, 4) & Bytes (16#0500_0000#, 4)
           & Bytes (52, 2) & Bytes (0, 2) & Bytes (0, 2) & Bytes (40, 2)
           & Bytes (Count, 2) & Bytes (2, 2)
           & (if Kind = None
              then Body_Of (1 .. Body_Of'Length - Relocation'Length)
                & Bytes (0, Relocation'Length)
              else Body_Of)
           & Bytes (0, Pad)
           & Bytes (0, 40)
           & Section (1, 1, 6, At_Stage, Size, 0, 0, 0)
           & Section (8, 3, 0, At_Names, Names'Length, 0, 0, 0)
           & Section (18, 2, 0, At_Symbols, Symbols'Length, 4, 1, 16)
           & Section (26, 3, 0, At_Strings, Strings'Length, 0, 0, 0)
           & Section (34, 1, 6, At_Text, Text'Length, 0, 0, 0)
           & (if Kind = None then ""
              else Section (40, 9, 0, At_Relocation, Relocation'Length, 3,
                            (if Kind = From_Stage then 1 else 5), 8));
      end Object;

      procedure Try
        (Name : String; Size : Natural; Kind : Relocation_Kind;
         Wanted : String);
      procedure Try
        (Name : String; Size : Natural; Kind : Relocation_Kind;
         Wanted : String)
      is
         Original : constant String := Object (Size, Kind);
         Sealed : U.Unbounded_String := U.To_Unbounded_String (Original);
         Fault : U.Unbounded_String;
      begin
         Landin.Driver.Boot_Stage.Seal (Sealed, Fault);
         if Wanted = "" then
            declare
               Result : constant String := U.To_String (Sealed);
               Sum : constant Landin.Targets.Firmware.Checksum :=
                 Landin.Targets.Firmware.Stage_Checksum
                   (Original (53 .. 52 + 252));
            begin
               Landin.Testing.Check_Equal
                 (Item, U.To_String (Fault), "", Name);
               Landin.Testing.Check
                 (Item, Result (1 .. 52 + 252) = Original (1 .. 52 + 252)
                    and then Result (52 + 257 .. Result'Last)
                      = Original (52 + 257 .. Original'Last)
                    and then Result (52 + 253 .. 52 + 256)
                      = Bytes (Natural (Sum mod 2 ** 16), 2)
                        & Bytes (Natural (Sum / 2 ** 16), 2),
                  Name & ": the checksum is the slot's last word alone");
            end;
         else
            Landin.Testing.Check
              (Item, Contains (U.To_String (Fault), Wanted)
                 and then U.To_String (Sealed) = Original,
               Name & ": " & U.To_String (Fault));
         end if;
      end Try;
   begin
      Landin.Testing.Check
        (Item, Landin.Targets.Firmware.Stage_Checksum ("123456789")
           = 16#0376_E6E7#,
         "the stage checksum is CRC-32/MPEG-2");
      Landin.Testing.Check
        (Item, Landin.Targets.Firmware.Stage_Checksum ("") = 16#FFFF_FFFF#,
         "the checksum of nothing is its initial value");
      Try ("a 256-byte stage is sealed", 256, None, "");
      Try ("an oversize stage names its size", 300, None,
        "the second stage and its literals are 296 bytes, and its slot"
        & " holds 252 before the checksum");
      Try ("a relocation in the stage is named", 256, From_Stage,
        "the second stage holds a relocation at offset 0x8 against far");
      Try ("a relocation to the stage is named", 256, To_Stage,
        "a relocation in .text at offset 0x8 refers to the second stage"
        & " through inside");
      declare
         Text : U.Unbounded_String := U.To_Unbounded_String ("not ELF");
         Fault : U.Unbounded_String;
      begin
         Landin.Driver.Boot_Stage.Seal (Text, Fault);
         Landin.Testing.Check
           (Item, Contains (U.To_String (Fault), "not a 32-bit"),
            "a file that is not an object is refused");
      end;

      --  The driver seals the object its assembler wrote before linking
      --  it, and refuses one it cannot seal as L0538 without a link.
      for Oversize in Boolean loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
            Written : constant String :=
              Object ((if Oversize then 300 else 256), None);
         begin
            Host.Add_Firmware_Library;
            Host.Add_Directory ("/w");
            Host.Add_Directory ("/w/app");
            Host.Add_Directory ("/w/devices");
            Host.Add_Directory ("/w/devices/descriptions");
            Host.Add_Directory ("/w/devices/descriptions/dev");
            Host.Add_File ("/w/app/main.ldn",
              "import descriptions/dev" & LF
              & "start: () -> none = end start" & LF);
            Host.Add_File ("/w/devices/descriptions/dev/dev.ldn",
              "compiler.device(""dev"")" & LF
              & "compiler.core(""cortex-m0plus"")" & LF
              & "compiler.vectors(48)" & LF
              & "compiler.boot(""rp2040-boot2"")" & LF
              & "linker.region(""FLASH"", 0x1000_0000, 64 * 1024, ""rx"")"
              & LF
              & "linker.region(""RAM"", 0x2000_0000, 8 * 1024, ""rw"")" & LF
              & "linker.place(""vectors"", ""FLASH"")" & LF
              & "linker.place(""text"", ""FLASH"")" & LF
              & "linker.place(""rodata"", ""FLASH"")" & LF
              & "linker.place(""data"", ""RAM"")" & LF
              & "linker.place(""bss"", ""RAM"")" & LF
              & "linker.place(""stack"", ""RAM"", 1024)" & LF
              & "link(boot_stage) extern(naked) stage: () -> none =" & LF
              & "    assembler.block(""bx lr"")" & LF & "end stage" & LF);
            --  What the fake assembler leaves as its object.
            Host.Add_File ("/w/p.elf.o", Written);
            Tools.Set_Result (0, "");
            Args.Append ("--root=/w/devices");
            Args.Append ("--target=cortex-m0");
            Args.Append ("--firmware-entry=start");
            Args.Append ("--emit=exe");
            Args.Append ("-o");
            Args.Append ("/w/p.elf");
            Args.Append ("/w/app");
            declare
               Ran : constant Landin.Driver.Outcome :=
                 Landin.Driver.Execute (Args, Host, Tools);
            begin
               if Oversize then
                  Landin.Testing.Check
                    (Item, Landin.Diagnostics.Count (Ran.Found) > 0
                       and then Landin.Diagnostics.Code
                         (Landin.Diagnostics.Get (Ran.Found, 1)) = "L0538"
                       and then Contains (U.To_String (Ran.Report),
                         "its literals are 296 bytes")
                       and then not Host.Exists ("/w/p.elf"),
                     "an oversize stage is L0538 before any link: "
                     & U.To_String (Ran.Report));
               else
                  Landin.Testing.Check_Equal
                    (Item, Ran.Status, Landin.Driver.Status_Success,
                     U.To_String (Ran.Report));
                  Landin.Testing.Check
                    (Item, Host.Written ("/w/p.elf.o")'Length = Written'Length
                       and then Host.Written ("/w/p.elf.o") /= Written
                       and then Host.Written ("/w/p.elf.o") (1 .. 52 + 252)
                         = Written (1 .. 52 + 252),
                     "the driver writes the checksum into the object it"
                     & " links");
               end if;
            end;
         end;
      end loop;
   end Boot_Stage_Seal;

   --  D637/D638: the image block's words, and the object it is read from.
   procedure Image_Block_Check (Item : in out Landin.Testing.Context);
   procedure Image_Block_Check (Item : in out Landin.Testing.Context) is
      function Bytes (Value : Long_Long_Integer; Width : Natural)
        return String;
      function Bytes (Value : Long_Long_Integer; Width : Natural)
        return String
      is
         Result : String (1 .. Width);
         Rest : Long_Long_Integer := Value;
      begin
         for Index in Result'Range loop
            Result (Index) := Character'Val (Natural (Rest mod 256));
            Rest := Rest / 256;
         end loop;
         return Result;
      end Bytes;

      Good : constant String :=
        Bytes (16#FFFF_DED3#, 4) & Bytes (16#1021_0142#, 4)
        & Bytes (16#0000_01FF#, 4) & Bytes (0, 4) & Bytes (16#AB12_3579#, 4);

      --  GOOD with the word at INDEX, from 1, replaced by WORD.
      function With_Word (Index : Positive; Word : Long_Long_Integer)
        return String is
        (Good (1 .. 4 * (Index - 1)) & Bytes (Word, 4)
         & Good (4 * Index + 1 .. Good'Last));

      --  A 32-bit little-endian Arm relocatable object holding BLOCK in a
      --  section named NAME and, when RELOCATED, a relocation in it.
      function Object
        (Block : String; Name : String := ".embedded_block";
         Relocated : Boolean := False) return String;
      function Object
        (Block : String; Name : String := ".embedded_block";
         Relocated : Boolean := False) return String
      is
         NUL : constant Character := ASCII.NUL;
         Names : constant String := NUL & Name & NUL & ".shstrtab" & NUL
           & ".symtab" & NUL & ".strtab" & NUL & ".rel.x" & NUL;
         Shstrtab_At : constant Natural := Name'Length + 2;
         Symtab_At : constant Natural := Shstrtab_At + 10;
         Strtab_At : constant Natural := Symtab_At + 8;
         Rel_At : constant Natural := Strtab_At + 8;
         Strings : constant String := NUL & "far" & NUL;
         Symbols : constant String := Bytes (0, 16)
           & Bytes (1, 4) & Bytes (0, 8) & Bytes (16#10#, 2) & Bytes (0, 2);
         Relocation : constant String := Bytes (8, 4) & Bytes (256 + 2, 4);
         Body_Of : constant String := Block & Names & Strings & Symbols
           & (if Relocated then Relocation else "");
         At_Block : constant Natural := 52;
         At_Names : constant Natural := At_Block + Block'Length;
         At_Strings : constant Natural := At_Names + Names'Length;
         At_Symbols : constant Natural := At_Strings + Strings'Length;
         At_Relocation : constant Natural := At_Symbols + Symbols'Length;
         Pad : constant Natural := (4 - (52 + Body_Of'Length) mod 4) mod 4;
         Headers : constant Natural := 52 + Body_Of'Length + Pad;
         Count : constant Natural := (if Relocated then 6 else 5);
         function Word (Value : Natural) return String is
           (Bytes (Long_Long_Integer (Value), 4));
         function Section
           (Name_At, Kind_Of, Flags, Offset, Length, Link, Info, Size_Of :
              Natural) return String
         is (Word (Name_At) & Word (Kind_Of) & Word (Flags) & Word (0)
             & Word (Offset) & Word (Length) & Word (Link) & Word (Info)
             & Word (4) & Word (Size_Of));
      begin
         return Character'Val (127) & "ELF" & Character'Val (1)
           & Character'Val (1) & Character'Val (1) & Bytes (0, 9)
           & Bytes (1, 2) & Bytes (40, 2) & Bytes (1, 4) & Bytes (0, 4)
           & Bytes (0, 4) & Word (Headers) & Bytes (16#0500_0000#, 4)
           & Bytes (52, 2) & Bytes (0, 2) & Bytes (0, 2) & Bytes (40, 2)
           & Bytes (Long_Long_Integer (Count), 2) & Bytes (2, 2)
           & Body_Of & Bytes (0, Pad)
           & Bytes (0, 40)
           & Section (1, 1, 2, At_Block, Block'Length, 0, 0, 0)
           & Section (Shstrtab_At, 3, 0, At_Names, Names'Length, 0, 0, 0)
           & Section (Symtab_At, 2, 0, At_Symbols, Symbols'Length, 4, 1, 16)
           & Section (Strtab_At, 3, 0, At_Strings, Strings'Length, 0, 0, 0)
           & (if Relocated
              then Section (Rel_At, 9, 0, At_Relocation, Relocation'Length,
                            3, 1, 8)
              else "");
      end Object;

      procedure Try (Name, Object_Bytes, Wanted : String);
      procedure Try (Name, Object_Bytes, Wanted : String) is
         Fault : constant String := U.To_String
           (Landin.Driver.Image_Block.Fault (Object_Bytes));
      begin
         if Wanted = "" then
            Landin.Testing.Check_Equal (Item, Fault, "", Name);
         else
            Landin.Testing.Check
              (Item, Contains (Fault, Wanted), Name & ": " & Fault);
         end if;
      end Try;
   begin
      Landin.Testing.Check_Equal
        (Item, Landin.Targets.Firmware.Image_Block_Fault (Good), "",
         "the image block is RP2350's minimum Arm IMAGE_DEF");
      Try ("the block in its section is read", Object (Good), "");
      Try ("a long block names its size", Object (Good & Bytes (0, 4)),
        "the image block is 24 bytes, and an IMAGE_DEF block of one item"
        & " is 20");
      Try ("a block without its start marker is named",
        Object (With_Word (1, 16#FFFF_DED4#)),
        "begins with 0xffffded4, not the start marker 0xffffded3");
      Try ("a first item that is not IMAGE_TYPE is named",
        Object (With_Word (2, 16#1021_0242#)),
        "first item is type 0x42 of 2 words, not IMAGE_TYPE");
      Try ("another image type is named",
        Object (With_Word (2, 16#1011_0142#)),
        "image type is 0x1011, not 0x1021");
      Try ("a last item that is not LAST is named",
        Object (With_Word (3, 16#0000_01FE#)),
        "last item is type 0xfe, not LAST, 0xff");
      Try ("a LAST of another size is named",
        Object (With_Word (3, 16#0000_02FF#)),
        "LAST item gives its items 2 words");
      Try ("a link elsewhere is named", Object (With_Word (4, 16#40#)),
        "links to offset 0x00000040, and a block loop of one block links"
        & " to itself");
      Try ("a block without its end marker is named",
        Object (With_Word (5, 0)),
        "ends with 0x00000000, not the end marker 0xab123579");
      Try ("a relocation in the block is named",
        Object (Good, Relocated => True),
        "the image block holds a relocation at offset 0x8 against far");
      Try ("an object without the section is named",
        Object (Good, Name => ".embedded_blocks"),
        "holds no .embedded_block section");
      Try ("a file that is not an object is refused", "not ELF",
        "not a 32-bit");

      --  The driver reads the object its assembler wrote before linking
      --  it, and refuses a block that is not the one it emitted as L0555
      --  without a link.
      for Broken in Boolean loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
         begin
            Host.Add_Firmware_Library;
            Host.Add_Directory ("/w");
            Host.Add_Directory ("/w/app");
            Host.Add_Directory ("/w/devices");
            Host.Add_Directory ("/w/devices/descriptions");
            Host.Add_Directory ("/w/devices/descriptions/dev");
            Host.Add_File ("/w/app/main.ldn",
              "import descriptions/dev" & ASCII.LF
              & "start: () -> none = end start" & ASCII.LF);
            Host.Add_File ("/w/devices/descriptions/dev/dev.ldn",
              "compiler.device(""dev"")" & ASCII.LF
              & "compiler.core(""cortex-m33"")" & ASCII.LF
              & "compiler.vectors(48)" & ASCII.LF
              & "compiler.boot(""rp2350-image-block"")" & ASCII.LF
              & "linker.region(""FLASH"", 0x1000_0000, 64 * 1024, ""rx"")"
              & ASCII.LF
              & "linker.region(""RAM"", 0x2000_0000, 8 * 1024, ""rw"")"
              & ASCII.LF
              & "linker.place(""vectors"", ""FLASH"")" & ASCII.LF
              & "linker.place(""text"", ""FLASH"")" & ASCII.LF
              & "linker.place(""rodata"", ""FLASH"")" & ASCII.LF
              & "linker.place(""data"", ""RAM"")" & ASCII.LF
              & "linker.place(""bss"", ""RAM"")" & ASCII.LF
              & "linker.place(""stack"", ""RAM"", 1024)" & ASCII.LF);
            --  What the fake assembler leaves as its object.
            Host.Add_File ("/w/p.elf.o",
              Object (if Broken then With_Word (4, 4) else Good));
            Tools.Set_Result (0, "");
            Args.Append ("--root=/w/devices");
            Args.Append ("--target=cortex-m0");
            Args.Append ("--firmware-entry=start");
            Args.Append ("--emit=exe");
            Args.Append ("-o");
            Args.Append ("/w/p.elf");
            Args.Append ("/w/app");
            declare
               Ran : constant Landin.Driver.Outcome :=
                 Landin.Driver.Execute (Args, Host, Tools);
            begin
               if Broken then
                  Landin.Testing.Check
                    (Item, Landin.Diagnostics.Count (Ran.Found) > 0
                       and then Landin.Diagnostics.Code
                         (Landin.Diagnostics.Get (Ran.Found, 1)) = "L0555"
                       and then Contains (U.To_String (Ran.Report),
                         "links to offset 0x00000004")
                       and then not Host.Exists ("/w/p.elf"),
                     "a block that is not the one emitted is L0555 before"
                     & " any link: " & U.To_String (Ran.Report));
               else
                  Landin.Testing.Check_Equal
                    (Item, Ran.Status, Landin.Driver.Status_Success,
                     U.To_String (Ran.Report));
               end if;
            end;
         end;
      end loop;
   end Image_Block_Check;

   --  D545: for the constrained reference the derived script is D229's.
   procedure Reference_Script (Item : in out Landin.Testing.Context);
   procedure Reference_Script (Item : in out Landin.Testing.Context) is
      LF : constant Character := ASCII.LF;
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
   begin
      Host.Add_Firmware_Library;
      Host.Add_File ("p.ldn", "start: () -> none = end start");
      Args.Append ("--target=cortex-m0");
      Args.Append ("--firmware-entry=start");
      Args.Append ("--emit=exe");
      Args.Append ("-o");
      Args.Append ("p.elf");
      Args.Append ("p.ldn");
      Tools.Set_Result (0, "");
      declare
         Ignored : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
         pragma Unreferenced (Ignored);
      begin
         Landin.Testing.Check_Equal
           (Item, Host.Written ("p.elf.ld"),
            "OUTPUT_FORMAT(""elf32-littlearm"")" & LF
            & "OUTPUT_ARCH(arm)" & LF
            & "ENTRY(_landin_firmware_reset)" & LF
            & "MEMORY {" & LF
            & "  FLASH (rx) : ORIGIN = 0, LENGTH = 32768" & LF
            & "  RAM (rwx) : ORIGIN = 536870912, LENGTH = 16384" & LF
            & "}" & LF
            & "_landin_firmware_stack_top = ORIGIN(RAM) + LENGTH(RAM);" & LF
            & "_landin_firmware_stack_bottom = _landin_firmware_stack_top"
            & " - 4096;" & LF
            & "SECTIONS {" & LF
            & "  .isr_vector ORIGIN(FLASH) : { KEEP(*(.isr_vector)) } > FLASH"
            & LF
            & "  .text : { *(.text .text.*) } > FLASH" & LF
            & "  .rodata : { *(.rodata .rodata.*) } > FLASH" & LF
            & "  .ARM.extab : { *(.ARM.extab*) } > FLASH" & LF
            & "  .ARM.exidx : { *(.ARM.exidx*) } > FLASH" & LF
            & "  .data : ALIGN(8) {" & LF
            & "    _landin_firmware_data_start = .;" & LF
            & "    *(.data .data.*)" & LF
            & "    _landin_firmware_data_end = .;" & LF
            & "  } > RAM AT> FLASH" & LF
            & "  _landin_firmware_data_load = LOADADDR(.data);" & LF
            & "  .ramtext : ALIGN(8) {" & LF
            & "    _landin_firmware_ramtext_start = .;" & LF
            & "    *(.ramtext.*)" & LF
            & "    _landin_firmware_ramtext_end = .;" & LF
            & "  } > RAM AT> FLASH" & LF
            & "  _landin_firmware_ramtext_load = LOADADDR(.ramtext);" & LF
            & "  .bss (NOLOAD) : AT(ADDR(.bss)) ALIGN(8) {" & LF
            & "    _landin_firmware_bss_start = .;" & LF
            & "    *(.bss .bss.* COMMON)" & LF
            & "    _landin_firmware_bss_end = .;" & LF
            & "  } > RAM" & LF
            & "  /DISCARD/ : { *(.comment .note.GNU-stack) }" & LF
            & "}" & LF
            & "ASSERT(ADDR(.isr_vector) == 0, ""vectors must start at zero"")"
            & LF
            & "ASSERT(SIZEOF(.isr_vector) == 192, ""vectors must contain 48"
            & " words"")" & LF
            & "ASSERT((_landin_firmware_stack_top & 7) == 0, ""unaligned"
            & " initial stack"")" & LF
            & "ASSERT(_landin_firmware_bss_end <= _landin_firmware_stack"
            & "_bottom," & LF
            & "       ""RAM image overlaps the reserved 4 KiB stack"")" & LF
            & "ASSERT(LOADADDR(.ramtext) + SIZEOF(.ramtext) <= ORIGIN(FLASH)"
            & " + LENGTH(FLASH)," & LF
            & "       ""initialized image exceeds flash"")" & LF,
            "the reference's derived script is D229's, byte for byte");
      end;
   end Reference_Script;

   --  D589: the derived script and its limits, with no entry and no link.
   procedure Script_Without_Program (Item : in out Landin.Testing.Context);
   procedure Script_Without_Program (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;

      function Run (Words : String) return Landin.Driver.Outcome;
      function Run (Words : String) return Landin.Driver.Outcome is
         Args : Landin.Platform.Path_List;
         First : Positive := Words'First;
      begin
         for Index in Words'Range loop
            if Words (Index) = ' ' then
               Args.Append (Words (First .. Index - 1));
               First := Index + 1;
            end if;
         end loop;
         Args.Append (Words (First .. Words'Last));
         return Landin.Driver.Execute (Args, Host, Tools);
      end Run;
   begin
      Host.Add_Firmware_Library;
      Host.Add_File ("p.ldn", "start: () -> none = end start");
      Host.Add_File ("q.ldn", "x: u32 = 1");
      Tools.Set_Result (0, "");
      declare
         Built : constant Landin.Driver.Outcome := Run
           ("--target=cortex-m0 --firmware-entry=start --emit=exe -o p.elf"
            & " p.ldn");
         Script : constant Landin.Driver.Outcome := Run
           ("--target=cortex-m0 --emit=linker-script --build-report=q.json"
            & " -o q.ld q.ldn");
         pragma Unreferenced (Built);
      begin
         Landin.Testing.Check_Equal
           (Item, Script.Status, Landin.Driver.Status_Success,
            U.To_String (Script.Report));
         Landin.Testing.Check_Equal
           (Item, Host.Written ("q.ld"), Host.Written ("p.elf.ld"),
            "the script is the one a firmware build writes beside its image");
         Landin.Testing.Check
           (Item, Contains (Host.Written ("q.json"),
              """firmware"":{""flash_limit"":32768,""static_ram_limit"""
              & ":12288,""stack_reserved"":4096,""stack_top"":536887296,"
              & """device"":""constrained-reference""")
              and then not Contains (Host.Written ("q.json"), "flash_used"),
            "the report gives the profile's limits and no linked figure");
      end;
      declare
         Hosted : constant Landin.Driver.Outcome := Run
           ("--target=linux-x86-64 --emit=linker-script -o h.ld q.ldn");
      begin
         Landin.Testing.Check
           (Item, Hosted.Status /= Landin.Driver.Status_Success
              and then Contains (U.To_String (Hosted.Report),
                "it needs --target=cortex-m0 (D589)"),
            "a hosted target has no firmware profile to write");
      end;
   end Script_Without_Program;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "cortex ABI", "device descriptions select their profiles",
         Device_Descriptions'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "the reference derives D229's script",
         Reference_Script'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "a boot stage is sealed with its checksum",
         Boot_Stage_Seal'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "an image block is read from its object",
         Image_Block_Check'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "the linker script is written without a program",
         Script_Without_Program'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "routine register saves", Frame_Saves'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "fixed fills enter their loops",
         Fixed_Fills_Enter_Their_Loops'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "fixed zero stores", Fixed_Zero_Stores'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "outgoing calls", Outgoing_Calls'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "scalar spill homes",
         Scalar_Spill_Homes'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "register staging", Register_Staging'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "dead array slot frame",
         Dead_Array_Slot_Has_No_Frame'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "source-debug contract", Source_Debugging'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "assembly IR", Assembly_IR'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "literal pooling", Literal_Pooling'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "shared returns", Shared_Returns'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "machine IR boundaries", Machine_IR'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "machine directives", Machine_Directives'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "assembly comments are not emitted",
         Assembly_Comments_Are_Not_Emitted'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "firmware path", Firmware_Path'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "linked firmware evidence",
         Linked_Firmware_Evidence'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "firmware frame limit",
         Firmware_Frame_Limit'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "backend boundaries", Backend_Boundaries'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "local branches", Local_Branches'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "debug branch transparency",
         Debug_Branches'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "branch-rich cleanup",
         Branch_Rich_Cleanup'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "layout and transport contract", Contract'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "driver boundaries",
         Driver_Boundaries'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "hard trap emission",
         Hard_Trap_Emission'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "lowered source carriers",
         Source_Carriers'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "capabilities and refusals", Refusals'Access);
   end Register;

end Landin.Tests.Cortex_Suite;
