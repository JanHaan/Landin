with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

package body Landin.Build_Reports is

   use type Landin.IR.Item_Id;
   use type Landin.Targets.Byte_Count;

   procedure Clear (Into : in out Report) is
   begin
      Into.Decisions.Clear;
      Into.Routines.Clear;
      Into.Layouts.Clear;
   end Clear;

   procedure Append
     (Into : in out Report; Decision : Specialization_Decision) is
   begin
      if Decision.Item = Landin.IR.No_Item
        or else (not Into.Decisions.Is_Empty
                 and then Decision.Item <= Into.Decisions.Last_Element.Item)
        or else (Decision.Action = Declined
                 and then Decision.Direct_Calls_Made /= 0)
      then
         raise Landin.Compiler_Defect with
           "invalid specialization report order";
      end if;
      Into.Decisions.Append (Decision);
   end Append;

   procedure Append
     (Into : in out Report; Statistics : Routine_Statistics) is
   begin
      if Statistics.Item = Landin.IR.No_Item
        or else (not Into.Routines.Is_Empty
                 and then Statistics.Item <= Into.Routines.Last_Element.Item)
        or else Statistics.Shared_With >= Statistics.Item
      then
         raise Landin.Compiler_Defect with "invalid routine report order";
      end if;
      Into.Routines.Append (Statistics);
   end Append;

   procedure Append_Layout
     (Into : in out Report; Nominal_Position : Positive;
      Policy : Landin.Layouts.Policy; Placement : Landin.Targets.Layouts.Plan)
   is
      Seen : array (1 .. Placement.Count) of Boolean := [others => False];
   begin
      if (not Into.Layouts.Is_Empty
          and then Nominal_Position <= Into.Layouts.Last_Element.Position)
        or else Placement.Size > Placement.Natural_Size
        or else Placement.Saved_Bytes
          /= Placement.Natural_Size - Placement.Size
        or else not Landin.Targets.Is_Power_Of_Two (Placement.Alignment)
      then
         raise Landin.Compiler_Defect with "invalid layout report";
      end if;
      for Position of Placement.Order loop
         if Position > Placement.Count or else Seen (Position) then
            raise Landin.Compiler_Defect with "invalid reported field order";
         end if;
         Seen (Position) := True;
      end loop;
      for Offset of Placement.Offsets loop
         if Offset > Placement.Size then
            raise Landin.Compiler_Defect with "invalid reported field offset";
         end if;
      end loop;
      Into.Layouts.Append
        (Layout_Record'(Count => Placement.Count,
                        Position => Nominal_Position,
                        Policy => Policy, Placement => Placement));
   end Append_Layout;

   function Specialization_Count (Of_Report : Report) return Natural
     is (Natural (Of_Report.Decisions.Length));
   function Nth_Specialization
     (Of_Report : Report; Index : Positive) return Specialization_Decision
     is (Of_Report.Decisions (Index));
   function Routine_Count (Of_Report : Report) return Natural
     is (Natural (Of_Report.Routines.Length));
   function Nth_Routine
     (Of_Report : Report; Index : Positive) return Routine_Statistics
     is (Of_Report.Routines (Index));
   function Layout_Count (Of_Report : Report) return Natural
     is (Natural (Of_Report.Layouts.Length));
   function Layout_Position
     (Of_Report : Report; Index : Positive) return Positive
     is (Of_Report.Layouts (Index).Position);
   function Layout_Policy
     (Of_Report : Report; Index : Positive) return Landin.Layouts.Policy
     is (Of_Report.Layouts (Index).Policy);

   function Layout_Plan
     (Of_Report : Report; Index : Positive) return Landin.Targets.Layouts.Plan
     is (Of_Report.Layouts (Index).Placement);

   function Spelling (Value : Specialization_Action) return String
     is (case Value is
            when Declined => "declined",
            when Specialized => "specialized");

   function Spelling (Value : Decision_Reason) return String
     is (case Value is
            when Disabled => "disabled",
            when No_Static_Dispatch => "no-static-dispatch",
            when Unknown_Evidence => "unknown-evidence",
            when Address_Exposed => "address-exposed",
            when Single_Instance => "single-instance",
            when Forced => "forced",
            when Profitable => "profitable",
            when Cost_Threshold => "cost-threshold",
            when Unsupported_Proof => "unsupported-proof");

   function JSON
     (Of_Report : Report;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options) return String
   is
      package US renames Ada.Strings.Unbounded;
      Text : US.Unbounded_String;
      LF : constant Character := Character'Val (10);

      function Image (Value : Landin.Targets.Byte_Count) return String;
      function Boolean_Image (Value : Boolean) return String;
      procedure Put (Value : String);
      procedure Field
        (Name : String; Value : Landin.Targets.Byte_Count);

      function Image (Value : Landin.Targets.Byte_Count) return String
        is (Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Both));
      function Boolean_Image (Value : Boolean) return String
        is (if Value then "true" else "false");
      procedure Put (Value : String) is
      begin
         US.Append (Text, Value);
      end Put;
      procedure Field
        (Name : String; Value : Landin.Targets.Byte_Count) is
      begin
         Put (",""" & Name & """:" & Image (Value));
      end Field;
   begin
      Put ("{""format"":""landin-build-report-1"",""target"":"""
           & Landin.Targets.Name (Facts) & """,""optimize"":"""
           & Landin.Optimization.Spelling (Options.Optimize)
           & """,""specialize"":"""
           & Landin.Optimization.Spelling (Options.Specialize)
           & """,""specializations"": [");
      for Index in 1 .. Specialization_Count (Of_Report) loop
         declare
            D : constant Specialization_Decision :=
              Nth_Specialization (Of_Report, Index);
         begin
            if Index > 1 then
               Put (",");
            end if;
            Put (LF & "{""item"":"
                 & Image (Landin.Targets.Byte_Count (D.Item)));
            Field ("template", Landin.Targets.Byte_Count (D.Template));
            Field ("instance", Landin.Targets.Byte_Count
                   (D.Instance_Position));
            Put (",""action"":""" & Spelling (D.Action)
                 & """,""reason"":""" & Spelling (D.Reason) & """");
            Field ("entry_calls", Landin.Targets.Byte_Count (D.Entry_Calls));
            Field ("loop_depth", Landin.Targets.Byte_Count (D.Loop_Depth));
            Field ("represented_bytes", D.Represented_Bytes);
            Field ("benefit", Landin.Targets.Byte_Count (D.Benefit));
            Field ("estimated_growth", Landin.Targets.Byte_Count
                   (D.Estimated_Growth));
            Field ("direct_calls_made", Landin.Targets.Byte_Count
                   (D.Direct_Calls_Made));
            Put (",""retains_evidence_abi"":"
                 & Boolean_Image (D.Retains_Evidence_ABI)
                 & ",""retains_fallback"":"
                 & Boolean_Image (D.Retains_Fallback) & "}");
         end;
      end loop;
      Put ("],""routines"": [");
      for Index in 1 .. Routine_Count (Of_Report) loop
         declare
            R : constant Routine_Statistics := Nth_Routine (Of_Report, Index);
         begin
            if Index > 1 then
               Put (",");
            end if;
            Put (LF & "{""item"":"
                 & Image (Landin.Targets.Byte_Count (R.Item)));
            Field ("shared_with", Landin.Targets.Byte_Count (R.Shared_With));
            Field ("frame_bytes", R.Frame_Bytes);
            Field ("spill_bytes", R.Spill_Bytes);
            Field ("save_bytes", R.Save_Bytes);
            Field ("register_count", Landin.Targets.Byte_Count
                   (R.Register_Count));
            Field ("spill_count", Landin.Targets.Byte_Count (R.Spill_Count));
            Field ("instructions", Landin.Targets.Byte_Count (R.Instructions));
            Field ("stack_loads", Landin.Targets.Byte_Count (R.Stack_Loads));
            Field ("stack_stores", Landin.Targets.Byte_Count (R.Stack_Stores));
            Field ("direct_calls", Landin.Targets.Byte_Count (R.Direct_Calls));
            Field ("indirect_calls", Landin.Targets.Byte_Count
                   (R.Indirect_Calls));
            Put ("}");
         end;
      end loop;
      Put ("],""layouts"": [");
      for Index in 1 .. Layout_Count (Of_Report) loop
         declare
            L : constant Layout_Record := Of_Report.Layouts (Index);
            P : Landin.Targets.Layouts.Plan renames L.Placement;
            Policy : constant String :=
              (case L.Policy is
                  when Landin.Layouts.Natural => "natural",
                  when Landin.Layouts.C => "c",
                  when Landin.Layouts.Optimal => "optimal");
         begin
            if Index > 1 then
               Put (",");
            end if;
            Put (LF & "{""nominal"":" & Image
                   (Landin.Targets.Byte_Count (L.Position))
                 & ",""policy"":""" & Policy & """");
            Field ("size", P.Size);
            Field ("alignment", Landin.Targets.Byte_Count (P.Alignment));
            Field ("natural_size", P.Natural_Size);
            Field ("saved_bytes", P.Saved_Bytes);
            Put (",""order"": [");
            for Position in P.Order'Range loop
               if Position > 1 then
                  Put (",");
               end if;
               Put (Image (Landin.Targets.Byte_Count (P.Order (Position))));
            end loop;
            Put ("],""offsets"": [");
            for Position in P.Offsets'Range loop
               if Position > 1 then
                  Put (",");
               end if;
               Put (Image (P.Offsets (Position)));
            end loop;
            Put ("]}");
         end;
      end loop;
      Put ("]}" & LF);
      return US.To_String (Text);
   end JSON;

end Landin.Build_Reports;
