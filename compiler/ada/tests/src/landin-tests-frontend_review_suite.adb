with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Landin.Checking;
with Landin.Layouts;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Types;

package body Landin.Tests.Frontend_Review_Suite is

   package C renames Landin.Checking;
   package Ty renames Landin.Types;
   package US renames Ada.Strings.Unbounded;
   use type Landin.Layouts.Policy;
   use type Landin.Source.Source_Id;
   use type Landin.Targets.Byte_Count;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Resolver : aliased Landin.Stages.Resolution.Instance;
   Checker : aliased Landin.Stages.Checking.Instance;
   Lowerer : aliased Landin.Stages.Lowering.Instance;
   LF : constant Character := Character'Val (10);

   function Image (Value : Natural) return String
     is (Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Both));

   procedure Run_Source
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation;
      Text : String;
      Diagnostic : String := "");
   procedure Measurements (Item : in out Landin.Testing.Context);
   procedure Return_Operands (Item : in out Landin.Testing.Context);
   procedure Scalar_Operands (Item : in out Landin.Testing.Context);
   procedure Nested_Operands (Item : in out Landin.Testing.Context);
   procedure Literal_Controls (Item : in out Landin.Testing.Context);
   procedure Result_Bodies (Item : in out Landin.Testing.Context);
   procedure Value_Boundaries (Item : in out Landin.Testing.Context);
   procedure Refusals (Item : in out Landin.Testing.Context);
   procedure Layout_Boundaries (Item : in out Landin.Testing.Context);

   procedure Run_Source
     (Item : in out Landin.Testing.Context;
      Work : in out Landin.Stages.Compilation;
      Text : String;
      Diagnostic : String := "")
   is
      Order : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id := Landin.Stages.Add_Source
        (Work, "r450-review-frontend.ldn", Text);
   begin
      pragma Assert (Written /= Landin.Source.No_Source);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Resolver'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Landin.Stages.Append (Order, Lowerer'Access);
      Landin.Testing.Check_Equal
        (Item, Landin.Stages.Run (Order, Work),
         (if Diagnostic = "" then 5 else 4),
         "source reaches verified IR or the intended checking refusal: "
         & Text);
      if Diagnostic = "" then
         Landin.Testing.Check
           (Item, not Landin.Stages.Failed (Work),
            "accepted: " & Landin.Stages.Rendered_Report (Work));
      else
         Landin.Testing.Check
           (Item, Landin.Stages.Failed (Work)
            and then Ada.Strings.Fixed.Count
              (Landin.Stages.Rendered_Report (Work), "error[") = 1
            and then Ada.Strings.Fixed.Index
              (Landin.Stages.Rendered_Report (Work),
               "error[" & Diagnostic & "]") > 0,
            "one exact refusal: " & Landin.Stages.Rendered_Report (Work));
      end if;
   end Run_Source;

   procedure Measurements (Item : in out Landin.Testing.Context) is
      Text : US.Unbounded_String := US.To_Unbounded_String
        ("row_0: type = [21]u8" & LF);
   begin
      for Index in 1 .. 128 loop
         US.Append (Text, "row_" & Image (Index) & ": type = row_"
           & Image (Index - 1) & LF);
      end loop;
      US.Append (Text, "f: () -> (r: usize) = mut a: row_128"
        & " r = lenof row_0 + lenof row_128 + lenof a end f");
      for Small in Boolean loop
         declare
            Work : Landin.Stages.Compilation := Landin.Stages.Create
              ((if Small then Landin.Targets.Synthetic_32
                else Landin.Targets.Linux_X86_64));
         begin
            Run_Source (Item, Work, US.To_String (Text));
         end;
      end loop;
   end Measurements;

   procedure Return_Operands (Item : in out Landin.Testing.Context) is
      Counts : constant array (Positive range <>) of Natural :=
        [0, 3, 1_048_576];
   begin
      for Count of Counts loop
         for Left_Returns in Boolean loop
            for Mode in 1 .. 4 loop
               declare
                  Work : Landin.Stages.Compilation :=
                    Landin.Stages.Create (Landin.Targets.Linux_X86_64);
                  Shape : constant String := "[" & Image (Count) & "]i32";
                  Expression : constant String :=
                    (if Left_Returns then "(begin return end) + a"
                     else "a + (begin return end)");
                  Statement : constant String :=
                    (case Mode is
                        when 1 => "b: " & Shape & " = " & Expression,
                        when 2 => "b := " & Expression,
                        when 3 => "mut b: " & Shape & " = zeroed b = "
                          & Expression,
                        when others => "_ = " & Expression);
               begin
                  Run_Source (Item, Work,
                    "f: () -> (r: i32) = r = 42 a: " & Shape
                    & " = zeroed " & Statement & " r = 1 end f");
               end;
            end loop;
         end loop;
      end loop;
   end Return_Operands;

   procedure Scalar_Operands (Item : in out Landin.Testing.Context) is
   begin
      for Floating in Boolean loop
         for Left_Returns in Boolean loop
            for Mode in 1 .. 4 loop
               for Falls_Through in Boolean loop
                  declare
                     Work : Landin.Stages.Compilation :=
                       Landin.Stages.Create (Landin.Targets.Linux_X86_64);
                     Kind : constant String :=
                       (if Floating then "f64" else "i64");
                     Literal : constant String :=
                       (if Floating then "1.0" else "1");
                     Control : constant String :=
                       (if Falls_Through then "(if stop then return end if)"
                        else "(begin return end)");
                     Expression : constant String :=
                       (if Left_Returns then Control & " + " & Literal
                        else Literal & " + " & Control);
                     Statement : constant String :=
                       (case Mode is
                           when 1 => "b: " & Kind & " = " & Expression,
                           when 2 => "b := " & Expression,
                           when 3 => "mut b: " & Kind & " = " & Literal
                             & " b = " & Expression,
                           when others => "_ = " & Expression);
                  begin
                     Run_Source (Item, Work,
                       "f: (stop: bool) -> (r: i32) = r = 42 "
                       & Statement & " r = 1 end f",
                       (if Falls_Through then "L0301" else ""));
                  end;
               end loop;
            end loop;
         end loop;
      end loop;
   end Scalar_Operands;

   procedure Nested_Operands (Item : in out Landin.Testing.Context) is
   begin
      for Shape_Mode in 1 .. 3 loop
         for Left_Returns in Boolean loop
            for Contextual in Boolean loop
               for Wrapper in 1 .. 5 loop
                  for Falls_Through in Boolean loop
                     declare
                        Work : Landin.Stages.Compilation :=
                          Landin.Stages.Create (Landin.Targets.Linux_X86_64);
                        Shape : constant String :=
                          (case Shape_Mode is
                              when 1 => "i32",
                              when 2 => "[0]i32",
                              when others => "[3]i32");
                        Control : constant String :=
                          (if Falls_Through then "(begin end)"
                           else "(begin return end)");
                        Operand : constant String :=
                          (case Wrapper is
                              when 1 => "-" & Control,
                              when 2 => "-(-(-" & Control & "))",
                              when 3 => "-(" & Control & " + " & Control & ")",
                              when 4 => "-(if stop then " & Control
                                & " else " & Control & " end if)",
                              when others => "-(begin (match choice"
                                & " left: " & Control & " right: " & Control
                                & " end match) end)");
                        Expression : constant String :=
                          (if Left_Returns then Operand & " + a"
                           else "a + " & Operand);
                     begin
                        --  One falling block gives one report; duplicate
                        --  answerless arms legitimately give one per arm.
                        if not Falls_Through or else Wrapper <= 2 then
                           Run_Source (Item, Work,
                             "left: atom right: atom choices: type = left"
                             & " | right f: (stop: bool, choice: choices)"
                             & " -> (r: i32) = r = 42"
                             & " a: " & Shape & " = zeroed b"
                             & (if Contextual then ": " & Shape & " = "
                                else " := ")
                             & Expression & " r = 1 end f",
                             (if Falls_Through then "L0301" else ""));
                        end if;
                     end;
                  end loop;
               end loop;
            end loop;
         end loop;
         for Assigned in Boolean loop
            declare
               Work : Landin.Stages.Compilation :=
                 Landin.Stages.Create (Landin.Targets.Linux_X86_64);
               Shape : constant String :=
                 (case Shape_Mode is
                     when 1 => "i64",
                     when 2 => "[0]i32",
                     when others => "[3]i32");
            begin
               Run_Source (Item, Work,
                 "f: () -> (r: i32) = r = 42 "
                 & (if Assigned then "mut b: " & Shape & " = zeroed b = "
                    else "b: " & Shape & " = ")
                 & "-(begin return end) + -(-(begin return end)) end f");
            end;
         end loop;
      end loop;
   end Nested_Operands;

   procedure Literal_Controls (Item : in out Landin.Testing.Context) is
   begin
      for Floating in Boolean loop
         for Left_Control in Boolean loop
            for Contextual in Boolean loop
               for Form in 1 .. 6 loop
                  for Empty in Boolean loop
                     declare
                        Work : Landin.Stages.Compilation :=
                          Landin.Stages.Create (Landin.Targets.Linux_X86_64);
                        Kind : constant String :=
                          (if Floating then "f64" else "u8");
                        Literal : constant String :=
                          (if Floating then "1.0000000000000002" else "1");
                        Control : constant String :=
                          (case Form is
                              when 1 => "(begin " & Literal & " end)",
                              when 2 => "(if stop then " & Literal & " else "
                                & Literal & " end if)",
                              when 3 => "(match choice left: " & Literal
                                & " right: " & Literal & " end match)",
                              when 4 => "(begin (if stop then (match choice"
                                & " left: " & Literal & " right: " & Literal
                                & " end match) else " & Literal
                                & " end if) end)",
                              when 5 => "(loop do break with " & Literal
                                & " end loop)",
                              when others => "(while stop do break with "
                                & Literal & " complete break with " & Literal
                                & " end while)");
                        Shape : constant String :=
                          (if Empty then "[0]" else "[1]") & Kind;
                     begin
                        Run_Source (Item, Work,
                          "left: atom right: atom choices: type = left"
                          & " | right f: (stop: bool, choice: choices)"
                          & " -> (r: i32) = r = 42"
                          & " a: " & Shape & " = zeroed b"
                          & (if Contextual then ": " & Shape & " = "
                             else " := ")
                          & (if Left_Control then Control & " + a"
                             else "a + " & Control) & " end f");
                     end;
                  end loop;
               end loop;
            end loop;
         end loop;
      end loop;
   end Literal_Controls;

   procedure Result_Bodies (Item : in out Landin.Testing.Context) is
   begin
      for Shape_Mode in 1 .. 6 loop
         for Wrapper in 1 .. 4 loop
            for Flow in 1 .. 4 loop
               declare
                  Work : Landin.Stages.Compilation :=
                    Landin.Stages.Create (Landin.Targets.Linux_X86_64);
                  Shape : constant String :=
                    (case Shape_Mode is
                        when 1 => "i64",
                        when 2 => "f64",
                        when 3 => "[0]i32",
                        when 4 => "[3]i32",
                        when 5 => "[0]f64",
                        when others => "[3]f64");
                  Control : constant String :=
                    (case Flow is
                        when 1 => "(begin r = zeroed return end)",
                        when 2 => "(if stop then r = zeroed return"
                          & " else a end if)",
                        when 3 => "(begin return end)",
                        when others => "(begin end)");
                  Expression : constant String :=
                    (case Wrapper is
                        when 1 => "-" & Control,
                        when 2 => "-(-(-" & Control & "))",
                        when 3 => "-(a + -(" & Control & " + a))",
                        when others => "-(" & Control & " + -(a + a))");
               begin
                  Run_Source (Item, Work,
                    "f: (stop: bool, a: " & Shape & ") -> (r: " & Shape
                    & ") = " & Expression & " end f",
                    (case Flow is
                        when 1 | 2 => "",
                        --  D17: an empty result is assigned vacuously.
                        when 3 => (if Shape_Mode in 3 | 5 then ""
                                   else "L0302"),
                        when others => "L0301"));
               end;
            end loop;
         end loop;
      end loop;
   end Result_Bodies;

   procedure Value_Boundaries (Item : in out Landin.Testing.Context) is
   begin
      for Shape_Mode in 1 .. 6 loop
         for Boundary in 1 .. 7 loop
            for Flow in 1 .. 5 loop
               declare
                  Work : Landin.Stages.Compilation :=
                    Landin.Stages.Create (Landin.Targets.Linux_X86_64);
                  Shape : constant String :=
                    (case Shape_Mode is
                        when 1 => "i64",
                        when 2 => "f64",
                        when 3 => "[0]i32",
                        when 4 => "[3]i32",
                        when 5 => "[0]f64",
                        when others => "[3]f64");
                  Expression : constant String :=
                    (case Flow is
                        when 1 => "-(begin return end)"
                          & " + -(-(begin return end))",
                        when 2 => "-(-(-(if stop then return else a end if)))",
                        when 3 => "-(-(-(begin end)))",
                        when 4 => "(begin return end)",
                        when others => "(loop do return end loop)");
                  Statement : constant String :=
                    (case Boundary is
                        when 1 => "b: box = (value: " & Expression & ")",
                        when 2 => "b: outer = (child: (value: "
                          & Expression & "))",
                        when 3 => "b: [1]box = [(value: " & Expression & ")]",
                        when 4 => "consume(" & Expression & ")",
                        when 5 => "mut b: box = zeroed b.value = "
                          & Expression,
                        when 6 => "mut b: box = zeroed"
                          & " b = (value: " & Expression & ")",
                        when others => "b: [1]" & Shape & " = ["
                          & Expression & "]");
               begin
                  Run_Source (Item, Work,
                    "box: type = struct value: " & Shape & " end box "
                    & "outer: type = struct child: box end outer "
                    & "consume: (a: " & Shape & ") -> none = end consume "
                    & "f: (stop: bool, a: " & Shape & ") -> (r: i32) ="
                    & " r = 42 " & Statement & " r = 1 end f",
                    (if Flow = 3 then "L0301" else ""));
               end;
            end loop;
         end loop;
      end loop;
   end Value_Boundaries;

   procedure Refusals (Item : in out Landin.Testing.Context) is
   begin
      for Mode in 1 .. 13 loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Landin.Targets.Linux_X86_64);
            Text : constant String :=
              (case Mode is
                  when 1 => "f: () -> none = mut a: [3]i32"
                    & " _ = a + 1 end f",
                  when 2 => "row: type = [21]u8 f: () -> none ="
                    & " _ = row + 1 end f",
                  when 3 => "f: () -> none = a: [3]i32 = zeroed"
                    & " _ = (begin end) + a end f",
                  when 4 => "f: () -> none = a: [3]i32 = zeroed"
                    & " _ = a + (begin end) end f",
                  when 5 => "f: (stop: bool) -> none ="
                    & " a: [0]i32 = zeroed"
                    & " _ = a + (if stop then return end if) end f",
                  when 6 => "f: () -> none = a: [1]u8 = [10]"
                    & " _ = a + (if true then 1 else i32(2) end if) end f",
                  when 7 => "f: () -> none = a: [1]f64 = [0.0]"
                    & " _ = (if true then f32(1.0) else 2.0 end if) + a end f",
                  when 8 => "f: () -> none = mut x: i32"
                    & " a: [0]i32 = zeroed _ = a + -(begin x end) end f",
                  when 9 => "row: type = [1]i32 f: () -> none ="
                    & " _ = -(begin row end) + 1 end f",
                  when 10 => "f: () -> none ="
                    & " _ = true + -(begin return end) end f",
                  when 11 => "f: () -> none ="
                    & " b := -(begin return end) + (begin return end) end f",
                  when 12 => "f: () -> none ="
                    & " _ = -(begin return end) + (begin return end) end f",
                  when others => "f: () -> (r: i32) = a: [0]i32 = zeroed"
                    & " b := a + -(begin return end) end f");
         begin
            Run_Source (Item, Work, Text,
              (case Mode is
                  when 1 | 8 | 13 => "L0302",
                  when 2 | 9 => "L0304",
                  when others => "L0301"));
         end;
      end loop;
   end Refusals;

   procedure Layout_Boundaries (Item : in out Landin.Testing.Context) is
   begin
      for Small in Boolean loop
         for Policy in Landin.Layouts.Policy loop
            declare
               Facts : constant Landin.Targets.Target_Facts :=
                 (if Small then Landin.Targets.Synthetic_32
                  else Landin.Targets.Linux_X86_64);
               Work : Landin.Stages.Compilation :=
                 Landin.Stages.Create (Facts);
               Order : Landin.Stages.Pipeline;
               Text : US.Unbounded_String;
               Types : constant not null access C.Table :=
                 Landin.Stages.Types (Work);
               Fits : Boolean;
               Pointer : constant Landin.Targets.Byte_Count :=
                 (if Small then 4 else 8);
            begin
               for Index in 1 .. 5 loop
                  US.Append (Text, "n" & Image (Index)
                    & ": type = struct a: u8 end n" & Image (Index) & LF);
               end loop;
               declare
                  Written : constant Landin.Source.Source_Id :=
                    Landin.Stages.Add_Source
                      (Work, "layout-review.ldn", US.To_String (Text));
               begin
                  pragma Assert (Written /= Landin.Source.No_Source);
               end;
               Landin.Stages.Append (Order, Frontend'Access);
               Landin.Stages.Append (Order, Configurer'Access);
               Landin.Stages.Append (Order, Resolver'Access);
               Landin.Testing.Check_Equal
                 (Item, Landin.Stages.Run (Order, Work), 3,
                  "layout test declarations resolve in memory");
               C.Prepare
                 (Types.all, Landin.Stages.Trees (Work).all,
                  Landin.Stages.Meanings (Work).all,
                  Landin.Stages.Identities (Work).all);
               C.Lay_Out
                 (Types.all, C.Nth_Nominal_Type (Types.all, 1),
                  [(Element => Ty.U64, others => <>),
                   (Element => Ty.U8, others => <>)], Facts, Fits, Policy);
               Landin.Testing.Check
                 (Item, Fits and then C.Layout_Extent
                    (Types.all, C.Nth_Nominal_Type (Types.all, 1)) = 9
                  and then C.Layout_Size
                    (Types.all, C.Nth_Nominal_Type (Types.all, 1)) = 16,
                  "unpadded extent remains distinct from padded plan size");
               C.Lay_Out
                 (Types.all, C.Nth_Nominal_Type (Types.all, 2),
                  C.Field_Shape_Array'
                    (7 => (Element => Ty.U8, others => <>),
                     8 => (Element => Ty.Usize, others => <>),
                     9 => (Element => Ty.U8, others => <>),
                     10 => (Element => Ty.Usize, others => <>)),
                  Facts, Fits, Policy);
               Landin.Testing.Check (Item, Fits, "all policies fit");
               for Field in 1 .. 4 loop
                  declare
                     Expected : constant Landin.Targets.Byte_Count :=
                       (if Policy = Landin.Layouts.Optimal then
                          (case Field is
                              when 1 => 2 * Pointer,
                              when 2 => 0,
                              when 3 => 2 * Pointer + 1,
                              when others => Pointer)
                        else (case Field is
                              when 1 => 0,
                              when 2 => Pointer,
                              when 3 => 2 * Pointer,
                              when others => 3 * Pointer));
                  begin
                     Landin.Testing.Check
                       (Item, C.Field_Offset (Types.all,
                          C.Nth_Nominal_Type (Types.all, 2), Field) = Expected,
                        "physical placement retains source field identities");
                  end;
               end loop;
               declare
                  Huge : constant C.Field_Shape := C.Make_Array_Field
                    (Types.all, C.Element_Count
                       (Landin.Targets.Maximum_Object_Size (Facts)),
                     (Element => Ty.U8, others => <>));
               begin
                  C.Lay_Out
                    (Types.all, C.Nth_Nominal_Type (Types.all, 3),
                     [Huge, (Element => Ty.U8, others => <>)],
                     Facts, Fits, Policy);
                  Landin.Testing.Check
                    (Item, not Fits and then not C.Has_Layout
                       (Types.all, C.Nth_Nominal_Type (Types.all, 3)),
                     "oversized placement rejects without publishing layout");
               end;
               if Small then
                  declare
                     Large : constant C.Field_Shape := C.Make_Array_Field
                       (Types.all, 4_294_967_280,
                        (Element => Ty.U8, others => <>));
                  begin
                     C.Lay_Out
                       (Types.all, C.Nth_Nominal_Type (Types.all, 4),
                        [(Element => Ty.U8, others => <>),
                         (Element => Ty.Usize, others => <>),
                         (Element => Ty.U8, others => <>),
                         (Element => Ty.Usize, others => <>), Large],
                        Facts, Fits, Policy);
                     Landin.Testing.Check
                       (Item, Fits = (Policy = Landin.Layouts.Optimal),
                        "optimal rescues a natural layout above target limit");
                     if Fits then
                        Landin.Testing.Check
                          (Item, C.Layout_Size (Types.all,
                             C.Nth_Nominal_Type (Types.all, 4))
                               = 4_294_967_292,
                           "rescued layout uses 32-bit target facts");
                     end if;
                  end;
               end if;
               begin
                  C.Lay_Out
                    (Types.all, C.Nth_Nominal_Type (Types.all, 5),
                     [(Kind => C.Variant_Field, others => <>)],
                     Facts, Fits, Policy);
                  Landin.Testing.Fail
                    (Item, "malformed case runs must remain compiler defects");
               exception
                  when Landin.Compiler_Defect =>
                     Landin.Testing.Check
                       (Item, True,
                        "only placement failures map to rejection");
               end;
            end;
         end loop;
      end loop;
   end Layout_Boundaries;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "frontend review", "nonreading alias measurements",
         Measurements'Access);
      Landin.Testing.Register
        (Into, "frontend review", "return-only array operands",
         Return_Operands'Access);
      Landin.Testing.Register
        (Into, "frontend review", "scalar literal operand contexts",
         Scalar_Operands'Access);
      Landin.Testing.Register
        (Into, "frontend review", "nested operand contexts",
         Nested_Operands'Access);
      Landin.Testing.Register
        (Into, "frontend review", "control literal contexts",
         Literal_Controls'Access);
      Landin.Testing.Register
        (Into, "frontend review", "expression body returning operands",
         Result_Bodies'Access);
      Landin.Testing.Register
        (Into, "frontend review", "contextual value boundaries",
         Value_Boundaries'Access);
      Landin.Testing.Register
        (Into, "frontend review", "preserved array refusals", Refusals'Access);
      Landin.Testing.Register
        (Into, "frontend review", "single-plan layout boundaries",
         Layout_Boundaries'Access);
   end Register;

end Landin.Tests.Frontend_Review_Suite;
