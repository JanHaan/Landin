with Landin.IR.Effects;
with Landin.IR.Rewriting;
with Landin.IR.Shape_Measurement;
with Landin.IR.Specialization_Policy;
with Landin.IR.Verifier;
with Landin.Targets.Layouts;

package body Landin.IR.Specialization is
   use type Landin.Optimization.Specialization_Mode;
   use type Landin.Targets.Byte_Count;
   use type Landin.Build_Reports.Specialization_Action;

   procedure Run
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options;
      Report : in out Landin.Build_Reports.Report)
   is
      package Reports renames Landin.Build_Reports;
      package Layouts renames Landin.Targets.Layouts;
      Count : constant Natural := Item_Count (Into);
      Proven, Exposed : array (1 .. Count) of Boolean := [others => False];
      Decisions : array (1 .. Count) of Reports.Specialization_Decision;
      Stable_Slots : array (1 .. Natural (Into.Slots.Length)) of Boolean :=
        [others => True];
      Private_Slots : array (Stable_Slots'Range) of Boolean :=
        [others => True];
      Aliases : array (1 .. Natural (Into.Code.Length)) of Value_Id :=
        [others => No_Value];
      Changed : Boolean;

      function Code_At (Item : Item_Id; Value : Value_Id) return Instruction
        is (Into.Code (Into.Items (Positive (Item)).Values.First
                      + Positive (Value)));

      function Original (Item : Item_Id; Value : Value_Id) return Value_Id
        is (Aliases (Into.Items (Positive (Item)).Values.First
                     + Positive (Value)));

      function Static_Table
        (Item : Item_Id; Value : Value_Id) return Evidence_Id;
      function Static_Table
        (Item : Item_Id; Value : Value_Id) return Evidence_Id
      is
         Code : constant Instruction := Code_At (Item, Original (Item, Value));
      begin
         if Code.Op = Evidence_Address
           and then not Evidence_Is_Erased (Into, Code.Evidence)
         then
            return Code.Evidence;
         elsif Code.Op = Load and then Proven (Positive (Item))
           and then Stable_Slots
             (Into.Items (Positive (Item)).Slots.First + Positive (Code.Slot))
         then
            return Bound_Evidence (Into, Item, Code.Slot);
         else
            return No_Evidence;
         end if;
      end Static_Table;

      function Direct_Target
        (Item : Item_Id; Value : Value_Id) return Item_Id;
      function Direct_Target
        (Item : Item_Id; Value : Value_Id) return Item_Id
      is
         Code : constant Instruction := Code_At (Item, Value);
      begin
         if Code.Op /= Indirect_Call or else Code.Args = 0 then
            return No_Item;
         end if;
         declare
            Projection : constant Instruction := Code_At
              (Item, Original (Item, Into.Operands (Code.First_Arg + 1)));
         begin
            if Projection.Op /= Evidence_Function
              or else Evidence_Is_Erased (Into, Projection.Evidence)
              or else Static_Table
                (Item, Into.Operands (Projection.First_Arg + 1))
                  /= Projection.Evidence
            then
               return No_Item;
            end if;
            return Evidence_Entry_Target
              (Into, Projection.Evidence, Projection.Evidence_Entry);
         end;
      end Direct_Target;

      --  Costing retains its byte-count limit; target-object admissibility
      --  and physical placement remain the backend's separate authority.
      function Extent (Shape : Field_Shape) return Layouts.Field_Extent
        is (Shape_Measurement.Extent
              (Into, Shape, Facts, Landin.Targets.Byte_Count'Last));

      procedure Pin (Item : Item_Id; Place : Storage);
      procedure Pin (Item : Item_Id; Place : Storage) is
         Slot : constant Slot_Id :=
           (case Place.Kind is
               when Frame_Slot => Place.Slot,
               when Runtime_Address => Place.Address,
               when Module_Datum => No_Slot);
      begin
         if Slot /= No_Slot then
            Stable_Slots
              (Into.Items (Positive (Item)).Slots.First + Positive (Slot)) :=
                False;
            Private_Slots
              (Into.Items (Positive (Item)).Slots.First + Positive (Slot)) :=
                False;
         end if;
      end Pin;
   begin
      Verifier.Verify (Into, Facts);
      --  Allocate every decision before inspecting recursive calls. Proof
      --  is a greatest fixed point: each surviving incoming edge is either
      --  a literal table address or an immutable parameter of a surviving
      --  caller. Exposed roots are false, so unknown runtime evidence cannot
      --  bootstrap a cycle into a proof.
      for I in 1 .. Count loop
         declare
            Item : constant Item_Id := Item_Id (I);
         begin
            Exposed (I) := Kind_Of (Into, Item) = Routine
              and then Has_Address_Exposure (Into, Item);
            Proven (I) := Generic_Template_Of (Into, Item) /= No_Declaration
              and then not Exposed (I) and then not Is_External (Into, Item)
              and then Evidence_Binding_Count (Into, Item) > 0;
            for V in 1 .. Value_Count (Into, Item) loop
               declare
                  Code : constant Instruction := Code_At (Item, Value_Id (V));
               begin
                  Pin (Item, Code.Source);
                  Pin (Item, Code.Destination);
                  if Code.Slot /= No_Slot and then Code.Op not in Load then
                     Stable_Slots (Into.Items (I).Slots.First
                                   + Positive (Code.Slot)) := False;
                     if Code.Op /= Store then
                        Private_Slots (Into.Items (I).Slots.First
                                       + Positive (Code.Slot)) := False;
                     end if;
                  end if;
               end;
            end loop;
         end;
      end loop;
      --  Lowering saves an indirect callee before evaluating arguments.
      --  Recover that local value without assuming a parameter's expected
      --  evidence is its actual value. Address-exposed slots never forward;
      --  block stamps prevent borrowing a definition across a join.
      for I in 1 .. Count loop
         declare
            Item : constant Item_Id := Item_Id (I);
            Held : constant Item_Record := Into.Items (I);
            Stored : array (1 .. Held.Slots.Count) of Value_Id :=
              [others => No_Value];
            Blocks : array (Stored'Range) of Block_Id := [others => No_Block];
         begin
            for V in 1 .. Held.Values.Count loop
               declare
                  Code : constant Instruction := Code_At (Item, Value_Id (V));
               begin
                  Aliases (Held.Values.First + V) := Value_Id (V);
                  if Code.Slot /= No_Slot
                    and then Private_Slots
                      (Held.Slots.First + Positive (Code.Slot))
                  then
                     if Code.Op = Store then
                        Stored (Positive (Code.Slot)) := Original
                          (Item, Into.Operands (Code.First_Arg + 1));
                        Blocks (Positive (Code.Slot)) := Code.In_Block;
                     elsif Code.Op = Load
                       and then Blocks (Positive (Code.Slot)) = Code.In_Block
                     then
                        Aliases (Held.Values.First + V) :=
                          Stored (Positive (Code.Slot));
                     end if;
                  end if;
               end;
            end loop;
         end;
      end loop;
      loop
         Changed := False;
         for I in 1 .. Count loop
            declare
               Caller : constant Item_Id := Item_Id (I);
            begin
               for V in 1 .. Value_Count (Into, Caller) loop
                  declare
                     Code : constant Instruction := Code_At
                       (Caller, Value_Id (V));
                  begin
                     if Code.Op = Call and then Proven (Positive (Code.Named))
                     then
                        for B in 1 .. Evidence_Binding_Count (Into, Code.Named)
                        loop
                           declare
                              Binding : constant Evidence_Binding :=
                                Nth_Evidence_Binding (Into, Code.Named, B);
                           begin
                              if Binding.Parameter > Code.Args or else
                                Static_Table (Caller, Into.Operands
                                  (Code.First_Arg + Binding.Parameter))
                                    /= Binding.Evidence
                              then
                                 Proven (Positive (Code.Named)) := False;
                                 Changed := True;
                                 exit;
                              end if;
                           end;
                        end loop;
                     end if;
                  end;
               end loop;
            end;
         end loop;
         exit when not Changed;
      end loop;
      for I in 1 .. Count loop
         declare
            Item : constant Item_Id := Item_Id (I);
            Decision : Reports.Specialization_Decision :=
              (Item => Item, Template => Generic_Template_Of (Into, Item),
               Instance_Position => Instance_Position_Of (Into, Item),
               others => <>);
            Entries : Natural := 0;
            Has_Dispatch : Boolean := False;
            Pointer_Bytes : constant Landin.Targets.Byte_Count :=
              Landin.Targets.Byte_Count
                (Landin.Targets.Bytes (Landin.Targets.Pointer_Size (Facts)));
         begin
            if Decision.Template /= No_Declaration then
               for V in 1 .. Value_Count (Into, Item) loop
                  declare
                     Code : constant Instruction :=
                       Code_At (Item, Value_Id (V));
                  begin
                     Decision.Estimated_Growth := Natural'Min
                       (Natural'Last - Effects.Weight (Code.Op),
                        Decision.Estimated_Growth) + Effects.Weight (Code.Op);
                     Has_Dispatch := Has_Dispatch or else
                       (Code.Op = Evidence_Function and then
                        not Evidence_Is_Erased (Into, Code.Evidence));
                     if Direct_Target (Item, Value_Id (V)) /= No_Item then
                        Entries := Entries + 1;
                        Decision.Loop_Depth := Natural'Min (4, Natural'Max
                          (Decision.Loop_Depth, Code.Call_Depth));
                     end if;
                  end;
               end loop;
               for B in 1 .. Evidence_Binding_Count (Into, Item) loop
                  declare
                     Binding : constant Evidence_Binding :=
                       Nth_Evidence_Binding (Into, Item, B);
                     Bytes : constant Landin.Targets.Byte_Count := Extent
                       (Evidence_Represented (Into, Binding.Evidence)).Size;
                  begin
                     Decision.Represented_Bytes :=
                       Landin.Targets.Byte_Count'Min
                         (Landin.Targets.Byte_Count'Last - Bytes,
                          Decision.Represented_Bytes) + Bytes;
                  end;
               end loop;
               Decision.Entry_Calls := Natural'Min (32, Entries);
               Decision.Benefit := Specialization_Policy.Benefit
                 (Entries, Decision.Loop_Depth,
                  Natural (Landin.Targets.Byte_Count'Min
                    (16, Decision.Represented_Bytes / Pointer_Bytes
                       + (if Decision.Represented_Bytes mod Pointer_Bytes > 0
                          then 1 else 0))));
               if Options.Specialize = Landin.Optimization.Off then
                  Decision.Reason := Reports.Disabled;
               elsif not Has_Dispatch then
                  Decision.Reason := Reports.No_Static_Dispatch;
               elsif Exposed (I) then
                  Decision.Reason := Reports.Address_Exposed;
               elsif not Proven (I) then
                  Decision.Reason := Reports.Unknown_Evidence;
               elsif Entries = 0 then
                  Decision.Reason := Reports.No_Static_Dispatch;
               else
                  Decision.Action := Reports.Specialized;
               end if;
            end if;
            Decisions (I) := Decision;
         end;
      end loop;
      --  Count eligible normalized instances, never call sites. Profitability
      --  cannot alter the evidence proof or source recursion acceptance.
      for I in 1 .. Count loop
         if Decisions (I).Action = Reports.Specialized then
            declare
               Eligible : Natural := 0;
            begin
               for J in 1 .. Count loop
                  if Decisions (J).Template = Decisions (I).Template
                    and then Proven (J) and then not Exposed (J)
                    and then Decisions (J).Entry_Calls > 0
                  then
                     Eligible := Eligible + 1;
                  end if;
               end loop;
               if Options.Specialize = Landin.Optimization.All_Eligible then
                  Decisions (I).Reason := Reports.Forced;
               elsif Eligible = 1 then
                  Decisions (I).Reason := Reports.Single_Instance;
               elsif Specialization_Policy.Profitable
                 (Decisions (I).Benefit, Decisions (I).Estimated_Growth,
                  Options.Optimize)
               then
                  Decisions (I).Reason := Reports.Profitable;
               else
                  Decisions (I).Action := Reports.Declined;
                  Decisions (I).Reason := Reports.Cost_Threshold;
               end if;
            end;
         end if;
      end loop;
      for I in 1 .. Count loop
         if Decisions (I).Action = Reports.Specialized then
            declare
               Item : constant Item_Id := Item_Id (I);
               Held : constant Item_Record := Into.Items (I);
               Targets : array (1 .. Held.Values.Count) of Item_Id;
            begin
               --  Freeze targets before changing projections used by more
               --  than one call. No traversal follows newly rewritten calls.
               for V in Targets'Range loop
                  Targets (V) := Direct_Target (Item, Value_Id (V));
               end loop;
               for V in Targets'Range loop
                  if Targets (V) /= No_Item then
                     declare
                        Code : Instruction := Code_At (Item, Value_Id (V));
                        Projection_Id : constant Value_Id := Original
                          (Item, Into.Operands (Code.First_Arg + 1));
                        Projection : Instruction := Code_At
                          (Item, Projection_Id);
                     begin
                        Projection.Op := Function_Address;
                        Projection.Named := Targets (V);
                        Projection.Args := 0;
                        Projection.Evidence := No_Evidence;
                        Projection.Evidence_Entry := 0;
                        Into.Code.Replace_Element
                          (Held.Values.First + Positive (Projection_Id),
                           Projection);
                        Code.Op := Call;
                        Code.Named := Targets (V);
                        Code.First_Arg := Code.First_Arg + 1;
                        Code.Args := Code.Args - 1;
                        Into.Code.Replace_Element
                          (Held.Values.First + V, Code);
                        Decisions (I).Direct_Calls_Made :=
                          Decisions (I).Direct_Calls_Made + 1;
                     end;
                  end if;
               end loop;
               Decisions (I).Retains_Fallback := False;
            end;
         end if;
         if Decisions (I).Template /= No_Declaration then
            Reports.Append (Report, Decisions (I));
         end if;
      end loop;
      if Options.Specialize /= Landin.Optimization.Off then
         Rewriting.Compact
           (Into, [1 .. Natural (Into.Code.Length) => True]);
      end if;
      Verifier.Verify (Into, Facts);
   end Run;
end Landin.IR.Specialization;
