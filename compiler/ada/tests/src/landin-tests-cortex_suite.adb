with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Landin.Backend;
with Landin.Backend.Arm32_ABI;
with Landin.Backend.Cortex_M;
with Landin.Build_Reports;
with Landin.Build_Reports.Firmware;
with Landin.Driver;
with Landin.Testing.Fakes;
with Landin.IR;
with Landin.IR.Dump;
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
                  Narrow_Frame := Stats.Frame_Bytes;
               end if;
               Landin.Testing.Check
                 (Item, Stats.Spill_Count = 3
                    and then Stats.Spill_Bytes = 3 * Bytes (Index)
                    and then Stats.Frame_Bytes =
                      Narrow_Frame + T.Align_Up
                        (3 * Bytes (Index), 8) - 8,
                  "three live homes use scalar widths and aligned frames");
            end;
         end;
      end loop;
   end Scalar_Spill_Homes;
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
         and then T.Capabilities.Triplet (T.Cortex_M) = "arm-none-eabi",
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
               U.Append (Source, "r = 3 ");
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
        (Host, "p.elf", "p.elf.map", Result, Valid);
      Landin.Testing.Check (Item, Valid, "ELF load extents are measured");
      Landin.Testing.Check_Equal
        (Item, U.To_String (Result),
         "{""flash_used"":784,""flash_limit"":32768,"
         & """flash_remaining"":31984,""static_ram_used"":40,"
         & """static_ram_limit"":12288,""static_ram_remaining"":12248,"
         & """stack_reserved"":4096,""runtime_members"":"
         & "[""_muldi3.o"",""_udivsi3.o""]}",
         "occupied extents include gaps and archive members are sorted");

      Host.Add_File ("p.ldn", "start: () -> none = end start");
      Args.Append ("--target=cortex-m0");
      Args.Append ("--firmware-entry=start");
      Args.Append ("--emit=exe");
      Args.Append ("--build-report=p.json");
      Args.Append ("-o");
      Args.Append ("p.elf");
      Args.Append ("p.ldn");
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
        (Host, "p.elf", "p.elf.map", Result, Valid);
      Landin.Testing.Check (Item, not Valid, "invalid ELF is refused");
      Host.Add_File ("p.elf", Data);
      Host.Add_File ("p.elf.map", "");
      Landin.Build_Reports.Firmware.Measure
        (Host, "p.elf", "p.elf.map", Result, Valid);
      Landin.Testing.Check (Item, not Valid, "empty map is refused");
   end Linked_Firmware_Evidence;

   procedure Firmware_Path (Item : in out Landin.Testing.Context) is
   begin
      for Mode in 1 .. 12 loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
         begin
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
           when others => "link(vector: 11) extern(interrupt) h: () -> none"
             & " = end h");
      end Program;
   begin
      for Case_Number in 1 .. 48 loop
         declare
            Host : Landin.Testing.Fakes.Fake_Filesystem;
            Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
            Args : Landin.Platform.Path_List;
         begin
            Host.Add_File ("p.ldn", Program (Case_Number)
              & " start: () -> none = end start");
            if Case_Number = 1 then
               Args.Append ("--firmware-entry=start");
            end if;
            Args.Append (if Case_Number in 25 .. 27 | 44
                         then "--target=darwin-arm64"
                         else "--target=cortex-m0");
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
                  (if Case_Number in 1 | 26 | 38 | 45
                   then Landin.Driver.Status_Success
                   else Landin.Driver.Status_Reported),
                  "machine contract case" & Case_Number'Image & ": "
                    & U.To_String (Result.Report));
               if Case_Number not in 1 | 26 | 38 | 45 then
                  Landin.Testing.Check_Equal
                    (Item, Host.Write_Count, 0,
                     "invalid machine constructs refuse before emission");
               end if;
               Landin.Testing.Check_Equal
                 (Item, Tools.Run_Count, 0, "assembly checks run no tool");
            end;
         end;
      end loop;
   end Machine_Directives;

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

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "cortex ABI", "scalar spill homes",
         Scalar_Spill_Homes'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "register staging", Register_Staging'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "source-debug contract", Source_Debugging'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "assembly IR", Assembly_IR'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "literal pooling", Literal_Pooling'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "machine IR boundaries", Machine_IR'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "machine directives", Machine_Directives'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "firmware path", Firmware_Path'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "linked firmware evidence",
         Linked_Firmware_Evidence'Access);
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
        (Into, "cortex ABI", "lowered source carriers",
         Source_Carriers'Access);
      Landin.Testing.Register
        (Into, "cortex ABI", "capabilities and refusals", Refusals'Access);
   end Register;

end Landin.Tests.Cortex_Suite;
