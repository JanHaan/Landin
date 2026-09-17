with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Landin.Backend;
with Landin.Backend.Arm32_ABI;
with Landin.Backend.Toolchain;
with Landin.Driver;
with Landin.Testing.Fakes;
with Landin.IR;
with Landin.IR.Dump;
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
           = T.Capabilities.No_Debug_Format
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
                    (Item, U.Index (Result.Report, "L0500") > 0,
                     "language executable linking is explicitly refused");
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

   procedure Backend_Boundaries (Item : in out Landin.Testing.Context);

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
                 (case Mode is when 1 => "L0504", when 2 | 3 => "L0301",
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
      declare
         Args : Landin.Platform.Path_List;
         pragma Unreferenced (Args);
      begin
         Args := Landin.Backend.Toolchain.Link_Arguments
           ("p.s", "p", "", Facts => T.Cortex_M);
         Landin.Testing.Fail (Item, "Cortex language linking was enabled");
      exception
         when Compiler_Defect =>
            Landin.Testing.Check (Item, True, "R6.60 owns Cortex linking");
      end;
   end Backend_Boundaries;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "cortex ABI", "backend boundaries", Backend_Boundaries'Access);
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
