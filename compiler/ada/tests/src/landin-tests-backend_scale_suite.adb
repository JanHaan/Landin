--  In-memory source and structural probes only.  The large-routine and
--  C-entry ABI fixtures separately execute the original result oracles.
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Backend.X86_64.Allocation;
with Landin.Backend.X86_64.Machine;
with Landin.Build_Reports;
with Landin.IR.Shape_Measurement;
with Landin.Layouts;
with Landin.Optimization;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets.Layouts;
with Landin.Types;

package body Landin.Tests.Backend_Scale_Suite is

   package Backend renames Landin.Backend;
   package X86 renames Backend.X86_64;
   package Alloc renames X86.Allocation;
   package Machine renames X86.Machine;
   package IR renames Landin.IR;
   package Measure renames IR.Shape_Measurement;
   package Opt renames Landin.Optimization;
   package Reports renames Landin.Build_Reports;
   package Targets renames Landin.Targets;
   package Layout renames Targets.Layouts;
   package US renames Ada.Strings.Unbounded;
   use type Alloc.Location_Kind;
   use type IR.Element_Total;
   use type Landin.Layouts.Policy;
   use type Opt.Objective;
   use type Reports.Routine_Statistics;
   use type Targets.Byte_Count;
   use type Targets.Byte_Alignment;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Resolver : aliased Landin.Stages.Resolution.Instance;
   Checker : aliased Landin.Stages.Checking.Instance;
   Lowerer : aliased Landin.Stages.Lowering.Instance;
   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   function Image (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));
   function Contains (Text, Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   procedure Lower
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation; Text : String);
   procedure Emit
     (Work : in out Landin.Stages.Compilation; Objective : Opt.Objective;
      Text : out US.Unbounded_String; Report : in out Reports.Report);
   procedure Many_Private_Bodies (Item : in out Landin.Testing.Context);
   procedure Exposure_Channels (Item : in out Landin.Testing.Context);
   procedure Streaming_Counts (Item : in out Landin.Testing.Context);
   procedure Large_Routine (Item : in out Landin.Testing.Context);
   procedure C_Entry_Boundaries (Item : in out Landin.Testing.Context);
   procedure Shared_Measurements (Item : in out Landin.Testing.Context);

   procedure Lower
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation; Text : String)
   is
      Order : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "r450-review-backend.ldn", Text);
      use type Landin.Source.Source_Id;
   begin
      Landin.Testing.Check
        (Item, Written /= Landin.Source.No_Source, "source is retained");
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Resolver'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Landin.Stages.Append (Order, Lowerer'Access);
      declare
         Ran : constant Natural := Landin.Stages.Run (Order, Work);
      begin
         Landin.Testing.Check_Equal
           (Item, Ran, 5, "source reaches verified IR: "
            & Landin.Stages.Rendered_Report (Work));
      end;
   end Lower;

   procedure Emit
     (Work : in out Landin.Stages.Compilation; Objective : Opt.Objective;
      Text : out US.Unbounded_String; Report : in out Reports.Report) is
   begin
      X86.Emit
        (Landin.Stages.Code (Work).all, Landin.Stages.Meanings (Work).all,
         Landin.Stages.Identities (Work).all, Landin.Stages.Target (Work),
         (Objective, Opt.Off), Text, Report);
   end Emit;

   procedure Many_Private_Bodies (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Targets.Linux_X86_64);
      Source : US.Unbounded_String;
      Text, Again : US.Unbounded_String;
      Report, Repeated : Reports.Report;
   begin
      --  Distinct same-length bodies defeat the sharing loop's early exit.
      --  No wall-clock threshold: the same scale runs on both build modes.
      for Index in 1 .. 800 loop
         US.Append
           (Source, "private_" & Image (Index)
            & ": (x: i64) -> (r: i64) = r = x +% " & Image (Index)
            & " end private_" & Image (Index) & LF);
      end loop;
      US.Append
        (Source, "duplicate: (x: i64) -> (r: i64) = "
         & "r = x +% 800 end duplicate");
      Lower (Item, Work, US.To_String (Source));
      Emit (Work, Opt.Size, Text, Report);
      Emit (Work, Opt.Size, Again, Repeated);
      Landin.Testing.Check
        (Item, US.To_String (Text) = US.To_String (Again)
         and then Reports.JSON
           (Report, Targets.Linux_X86_64, (Opt.Size, Opt.Off))
           = Reports.JSON
             (Repeated, Targets.Linux_X86_64, (Opt.Size, Opt.Off)),
         "many distinct bodies retain deterministic assembly and evidence");
      for Index in 1 .. 800 loop
         Landin.Testing.Check
           (Item, Contains (US.To_String (Text), LF & "private_"
                            & Image (Index) & ":" & LF),
            "different constants never become equivalent machine bodies");
      end loop;
      Landin.Testing.Check
        (Item, Contains (US.To_String (Text), ".set duplicate, private_800"),
         "an equivalent private body still folds after the distinct run");
   end Many_Private_Bodies;

   procedure Exposure_Channels (Item : in out Landin.Testing.Context) is
      Bodies : constant String :=
        "first: (x: i32) -> (r: i32) = r = x end first "
        & "second: (x: i32) -> (r: i32) = r = x end second ";
      Callback : constant String :=
        "callback: type = (x: i32) -> (r: i32) ";
   begin
      for Channel in 1 .. 7 loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Targets.Linux_X86_64);
            Text : US.Unbounded_String;
            Report : Reports.Report;
         begin
            Lower
              (Item, Work,
               (case Channel is
                   when 3 => Callback & Bodies
                     & "mut current: callback = first",
                   when 4 => Callback & Bodies
                     & "holder: type = struct cb: callback end holder "
                     & "mut current: holder = (cb: first)",
                   when 5 => Callback & Bodies
                     & "public address: () -> (r: callback) = "
                     & "r = first end address",
                   when 6 => "public " & Bodies,
                   when 7 => "public extern(c) " & Bodies,
                   when others => Bodies));
            if Channel = 1 then
               --  A later emission must not reuse a mask from an older unit.
               Emit (Work, Opt.Size, Text, Report);
               Landin.Testing.Check
                 (Item, Contains (US.To_String (Text), ".set second, first"),
                  "private unexposed identity initially permits folding");
               IR.Mark_Address_Exposed (Landin.Stages.Code (Work).all, 1);
            elsif Channel = 2 then
               declare
                  Code : IR.Unit renames Landin.Stages.Code (Work).all;
                  Table : constant IR.Evidence_Id := IR.Add_Evidence
                    (Code, (Element => Landin.Types.I32, others => <>));
               begin
                  IR.Add_Evidence_Entry
                    (Code, Table, 1, IR.Signature_Of (Code, IR.Item_Id'(1)));
               end;
            end if;
            declare
               Fresh : Reports.Report;
            begin
               Emit (Work, Opt.Size, Text, Fresh);
            end;
            Landin.Testing.Check
              (Item, not Contains (US.To_String (Text), ".set "),
               "exposure or explicit ABI identity prevents folding channel "
               & Image (Channel));
         end;
      end loop;
   end Exposure_Channels;

   procedure Streaming_Counts (Item : in out Landin.Testing.Context) is
      Recorded, Counted : Machine.Stream;

      procedure Step (Stream : in out Machine.Stream; Index : Positive);

      procedure Step (Stream : in out Machine.Stream; Index : Positive) is
      begin
         Machine.Define_Label (Stream, ".L" & Image (Index));
         Machine.Instruction (Stream, "movq -8(%rbp), %rax");
         Machine.Instruction (Stream, "addq %rax, -16(%rbp)");
         Machine.Instruction (Stream, "leaq -16(%rbp), %rdi");
         Machine.Instruction (Stream, "call target");
         Machine.Instruction (Stream, "call *%r11");
         Machine.Instruction (Stream, "jne .L" & Image (Index));
      end Step;
   begin
      Machine.Start (Recorded);
      Machine.Start (Counted, Record_Body => False);
      for Index in 1 .. 12000 loop
         Step (Recorded, Index);
         Step (Counted, Index);
      end loop;
      Machine.Seal (Recorded);
      Machine.Seal (Counted);
      Landin.Testing.Check
        (Item, Machine.Statistics (Recorded) = Machine.Statistics (Counted)
         and then Machine.Statistics (Counted).Instructions = 72000
         and then Machine.Retained_Tokens (Recorded) > 72000
         and then Machine.Retained_Labels (Recorded) = 12000
         and then Machine.Retained_Tokens (Counted) = 0
         and then Machine.Retained_Labels (Counted) = 0
         and then not Machine.Is_Recording (Counted),
         "streaming statistics match without retaining canonical evidence");
      begin
         if Machine.Equivalent (Recorded, Counted) then
            Landin.Testing.Fail (Item, "uncaptured body compared equal");
         else
            Landin.Testing.Fail (Item, "uncaptured body entered equality");
         end if;
      exception
         when Landin.Compiler_Defect =>
            Landin.Testing.Check (Item, True, "uncaptured comparison refused");
      end;
   end Streaming_Counts;

   procedure Large_Routine (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Targets.Linux_X86_64);
      Source : US.Unbounded_String := US.To_Unbounded_String
        ("public run: (x: i64) -> (r: i64) = r = x" & LF);
      Facts : constant Targets.Target_Facts := Targets.Linux_X86_64;
   begin
      for Index in 1 .. 24000 loop
         US.Append (Source, "r +%= 1" & LF);
      end loop;
      US.Append (Source, "end run");
      Lower (Item, Work, US.To_String (Source));
      for Objective in Opt.Objective loop
         declare
            Code : IR.Unit renames Landin.Stages.Code (Work).all;
            Plan : constant Alloc.Plan :=
              Alloc.Make (Code, 1, Facts, (Objective, Opt.Off));
            Frame : constant Backend.Frame :=
              Alloc.Frame_For (Code, 1, Facts, Plan, (Objective, Opt.Off));
            Text : US.Unbounded_String;
            Report : Reports.Report;
         begin
            Landin.Testing.Check
              (Item, X86.Frame_Is_Addressable
                 (Code, 1, Facts, (Objective, Opt.Off)),
               "large source preflight uses bounded host-stack storage");
            if Objective = Opt.None then
               declare
                  Below : Targets.Byte_Count := 0;
                  Scalars : Natural := 0;
               begin
                  for Index in 1 .. IR.Slot_Count (Code, 1) loop
                     declare
                        Slot : constant IR.Slot_Id := IR.Slot_Id (Index);
                        Size : constant Targets.Scalar_Size :=
                          Backend.Size_Of (IR.Type_Of (Code, 1, Slot), Facts);
                     begin
                        Below := Targets.Align_Up
                          (Below + Targets.Byte_Count (Targets.Bytes (Size)),
                           Targets.Alignment_Of (Facts, Size));
                        Landin.Testing.Check
                          (Item, Backend.Slot_Offset (Frame, Slot) = Below,
                           "reference slot order retains individual homes");
                     end;
                  end loop;
                  for Index in 1 .. IR.Value_Count (Code, 1) loop
                     declare
                        Value : constant IR.Value_Id := IR.Value_Id (Index);
                        Kind : constant Landin.Types.Type_Kind :=
                          IR.Result_Of (Code, 1, Value);
                     begin
                        if Kind in Landin.Types.Scalar_Name then
                           declare
                              Size : constant Targets.Scalar_Size :=
                                Backend.Size_Of (Kind, Facts);
                           begin
                              Below := Targets.Align_Up
                                (Below + Targets.Byte_Count
                                   (Targets.Bytes (Size)),
                                 Targets.Alignment_Of (Facts, Size));
                              Scalars := Scalars + 1;
                              Landin.Testing.Check
                                (Item, Backend.Value_Offset (Frame, Value)
                                   = Below
                                 and then Plan.Value (Index).Kind = Alloc.Stack
                                 and then Plan.Value (Index).Home = Scalars,
                                 "reference instruction home unchanged");
                           end;
                        else
                           Landin.Testing.Check
                             (Item, not Backend.Has_Value_Home (Frame, Value),
                              "effect-only instruction has no scalar home");
                        end if;
                     end;
                  end loop;
                  Landin.Testing.Check
                    (Item, Backend.Extent (Frame) = Targets.Align_Up
                       (Below, Targets.Stack_Alignment (Facts))
                     and then Plan.Spill_Homes = Scalars
                     and then Alloc.Save_Count (Plan) = 0,
                     "reference frame extent and spill count are truthful");
               end;
            end if;
            Emit (Work, Objective, Text, Report);
            Landin.Testing.Check
              (Item, Contains (US.To_String (Text), "run:")
               and then Reports.Nth_Routine (Report, 1).Frame_Bytes
                 = Backend.Extent (Frame)
               and then Reports.Nth_Routine (Report, 1).Spill_Count
                 = Plan.Spill_Homes,
               "24000 source statements emit and report under default stack");
         end;
      end loop;
   end Large_Routine;

   procedure C_Entry_Boundaries (Item : in out Landin.Testing.Context) is
      type Lengths is array (Positive range <>) of Natural;
   begin
      for Length of Lengths'[3932, 3948, 3964, 3980] loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Targets.Linux_X86_64);
         begin
            Lower
              (Item, Work, "public extern(c) probe: (x: i64) -> (r: i64) = "
               & "mut pad: [" & Image (Length) & "]u8 = zeroed "
               & "r = x end probe");
            for Objective in Opt.Objective loop
               declare
                  Text : US.Unbounded_String;
                  Report : Reports.Report;
               begin
                  Emit (Work, Objective, Text, Report);
                  Landin.Testing.Check
                    (Item, Reports.Nth_Routine (Report, 1).Register_Count = 0
                     and then Reports.Nth_Routine (Report, 1).Frame_Bytes
                       = Targets.Byte_Count (Length + 36),
                     "boundary witness has no intervening callee-save touch");
                  declare
                     Assembly : constant String := US.To_String (Text);
                     First : Positive := Assembly'First;
                     Gap : Natural := 0;
                     Saw_Entry : Boolean := False;
                  begin
                     for Last in Assembly'Range loop
                        if Assembly (Last) = LF then
                           declare
                              Line : constant String :=
                                Assembly (First .. Last - 1);
                           begin
                              if Contains (Line, "subq $") then
                                 declare
                                    Dollar : constant Natural :=
                                      Ada.Strings.Fixed.Index (Line, "$");
                                    Comma : constant Natural :=
                                      Ada.Strings.Fixed.Index (Line, ",");
                                 begin
                                    Gap := Gap + Natural'Value
                                      (Line (Dollar + 1 .. Comma - 1));
                                 end;
                              elsif Line = HT & "orq $0, (%rsp)" then
                                 Landin.Testing.Check
                                   (Item, Gap <= 4096,
                                    "every probe touch is within one page");
                                 Gap := 0;
                              elsif Line = HT & "movq %rdi, 0(%rsp)" then
                                 Landin.Testing.Check
                                   (Item, Gap <= 4096,
                                    "first C carrier save is within one page");
                                 Saw_Entry := True;
                                 exit;
                              end if;
                           end;
                           First := Last + 1;
                        end if;
                     end loop;
                     Landin.Testing.Check
                       (Item, Saw_Entry, "C entry saved the incoming GP bank");
                  end;
               end;
            end loop;
         end;
      end loop;
   end C_Entry_Boundaries;

   procedure Shared_Measurements (Item : in out Landin.Testing.Context) is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Targets.Linux_X86_64);
   begin
      Lower (Item, Work, "f: () -> none = end f");
      declare
         Code : IR.Unit renames Landin.Stages.Code (Work).all;
         Fields : constant IR.Field_Shape_Array :=
           [(Element => Landin.Types.U8, others => <>),
            (Element => Landin.Types.Usize, others => <>),
            (Element => Landin.Types.U8, others => <>),
            (Element => Landin.Types.Usize, others => <>)];

         function Shape_Of
           (Parts : IR.Field_Shape_Array; Policy : Landin.Layouts.Policy)
            return IR.Field_Shape;

         function Shape_Of
           (Parts : IR.Field_Shape_Array; Policy : Landin.Layouts.Policy)
            return IR.Field_Shape
         is
            Nominal : constant IR.Nominal_Type_Id :=
              IR.Add_Nominal_Type (Code, 1);
         begin
            IR.Set_Nominal_Shape (Code, Nominal, Parts, Policy);
            return (Kind => IR.Aggregate_Field_Shape, Nominal => Nominal,
                    others => <>);
         end Shape_Of;
      begin
         for Policy in Landin.Layouts.Policy loop
            declare
               Shape : constant IR.Field_Shape := Shape_Of (Fields, Policy);
               Run : constant Natural :=
                 IR.Add_Shape_Run (Code, [Fields (1), Shape]);
               Cases : constant Natural := IR.Add_Case_Run
                 (Code, [1 => (First => Run, Count => 2)]);
               Variant : constant IR.Field_Shape :=
                 (Kind => IR.Variant_Field_Shape,
                  Element => Landin.Types.U8, Cases => 1,
                  Payloads_First => Cases, others => <>);
               Repeated : constant IR.Field_Shape :=
                 IR.Make_Array_Shape (Code, 7, Shape);
               Empty : constant IR.Field_Shape :=
                 IR.Make_Array_Shape (Code, 0, Shape);
               Outer : constant IR.Field_Shape := Shape_Of
                 ([Fields (1), Variant, Repeated, Empty], Policy);
            begin
               for Small in Boolean loop
                  declare
                     Facts : constant Targets.Target_Facts :=
                       (if Small then Targets.Synthetic_32
                        else Targets.Linux_X86_64);
                     Pointer : constant Targets.Byte_Count :=
                       Targets.Byte_Count
                         (Targets.Bytes (Targets.Pointer_Size (Facts)));
                     Base : constant Targets.Byte_Count := Pointer
                       * (if Policy = Landin.Layouts.Optimal then 3 else 4);
                  begin
                     Landin.Testing.Check
                       (Item, Measure.Extent
                          (Code, Shape, Facts, Targets.Byte_Count'Last).Size
                            = Base
                        and then Measure.Extent
                          (Code, Variant, Facts, Targets.Byte_Count'Last).Size
                            = Base + 2 * Pointer
                        and then Measure.Extent
                          (Code, Repeated, Facts, Targets.Byte_Count'Last).Size
                            = 7 * Base
                        and then Measure.Extent
                          (Code, Empty, Facts, Targets.Byte_Count'Last).Size
                            = 0
                        and then Measure.Extent
                          (Code, Empty, Facts, Targets.Byte_Count'Last)
                            .Alignment = 1,
                        "nested policies and empty arrays retain byte counts");
                     for Part of IR.Field_Shape_Array'
                       [Shape, Variant, Repeated, Empty, Outer]
                     loop
                        declare
                           Size : Targets.Byte_Count;
                           Alignment : Targets.Byte_Alignment;
                           Cost : constant Layout.Field_Extent :=
                             Measure.Extent
                               (Code, Part, Facts, Targets.Byte_Count'Last);
                        begin
                           Backend.Field_Extent
                             (Code, Part, Facts, Size, Alignment);
                           Landin.Testing.Check
                             (Item, Size = Cost.Size
                              and then Alignment = Cost.Alignment,
                              "cost and placement share target bytes");
                        end;
                     end loop;
                  end;
               end loop;
            end;
         end loop;
         declare
            Huge : constant IR.Field_Shape := IR.Make_Array_Shape
              (Code, 2 ** 30, (Element => Landin.Types.U64, others => <>));
            Cost : constant Layout.Field_Extent := Measure.Extent
              (Code, Huge, Targets.Synthetic_32, Targets.Byte_Count'Last);
            Size : Targets.Byte_Count;
            Alignment : Targets.Byte_Alignment;
         begin
            Landin.Testing.Check
              (Item, Cost.Size = 2 ** 33,
               "specialization explicitly retains the byte-count limit");
            begin
               Backend.Field_Extent
                 (Code, Huge, Targets.Synthetic_32, Size, Alignment);
               Landin.Testing.Fail
                 (Item, "target object limit returned"
                  & Targets.Byte_Count'Image (Size)
                  & Targets.Byte_Alignment'Image (Alignment));
            exception
               when Landin.Compiler_Defect =>
                  Landin.Testing.Check
                    (Item, True, "backend retains its target object limit");
            end;
         end;
         begin
            declare
               Overflow : constant Layout.Field_Extent := Measure.Repeated
                 ((Targets.Byte_Count'Last, 1), 2, Targets.Byte_Count'Last);
            begin
               Landin.Testing.Fail
                 (Item, "represented overflow returned"
                  & Targets.Byte_Count'Image (Overflow.Size));
            end;
         exception
            when Landin.Compiler_Defect =>
               Landin.Testing.Check
                 (Item, True, "byte-count overflow refused");
         end;
      end;
   end Shared_Measurements;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "backend scale", "many private bodies",
         Many_Private_Bodies'Access);
      Landin.Testing.Register
        (Into, "backend scale", "exposure channels", Exposure_Channels'Access);
      Landin.Testing.Register
        (Into, "backend scale", "streaming counts", Streaming_Counts'Access);
      Landin.Testing.Register
        (Into, "backend scale", "large routine", Large_Routine'Access);
      Landin.Testing.Register
        (Into, "backend scale", "C entry boundaries",
         C_Entry_Boundaries'Access);
      Landin.Testing.Register
        (Into, "backend scale", "shared measurements",
         Shared_Measurements'Access);
   end Register;

end Landin.Tests.Backend_Scale_Suite;
