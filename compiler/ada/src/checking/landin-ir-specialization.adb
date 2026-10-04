with Ada.Containers.Ordered_Maps;
with Ada.Containers.Vectors;
with Landin.IR.Effects;
with Landin.IR.Rewriting;
with Landin.IR.Shape_Measurement;
with Landin.IR.Specialization_Policy;
with Landin.IR.Verifier;

package body Landin.IR.Specialization is
   use type Landin.Optimization.Specialization_Mode;
   use type Landin.Targets.Byte_Count;
   use type Landin.Build_Reports.Specialization_Action;

   procedure Run
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options;
      Report : in out Landin.Build_Reports.Report) is
   begin
      Verifier.Verify (Into, Facts);
      Run_On_Verified (Into, Facts, Options, Report);
   end Run;

   procedure Run_On_Verified
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Options : Landin.Optimization.Options;
      Report : in out Landin.Build_Reports.Report)
   is
      package Reports renames Landin.Build_Reports;
      use type Reports.Specialization_Decision;
      package Template_Counts is new Ada.Containers.Ordered_Maps
        (Key_Type => Declaration_Id, Element_Type => Natural);
      package Boolean_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Boolean);
      package Decision_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive,
         Element_Type => Reports.Specialization_Decision);
      Eligible : Template_Counts.Map;
      Count : constant Natural := Item_Count (Into);
      Proven : Boolean_Vectors.Vector := Boolean_Vectors.To_Vector
        (False, Ada.Containers.Count_Type (Count));
      Exposed : Boolean_Vectors.Vector := Boolean_Vectors.To_Vector
        (False, Ada.Containers.Count_Type (Count));
      Decisions : Decision_Vectors.Vector := Decision_Vectors.To_Vector
        ((others => <>), Ada.Containers.Count_Type (Count));
      Stable_Slots : Boolean_Vectors.Vector := Boolean_Vectors.To_Vector
        (True, Into.Slots.Length);
      Private_Slots : Boolean_Vectors.Vector := Boolean_Vectors.To_Vector
        (True, Into.Slots.Length);
      Aliases : Value_Ref_Vectors.Vector := Value_Ref_Vectors.To_Vector
        (No_Value, Into.Code.Length);
      Rewritten : Boolean := False;
      --  Keep the dependency graph on the heap like the other whole-unit
      --  scratch: source declaration bounds do not bound IR item counts.
      package Natural_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Natural);
      First_Dependent : Natural_Vectors.Vector := Natural_Vectors.To_Vector
        (0, Ada.Containers.Count_Type (Count));
      Next_Dependent : Natural_Vectors.Vector := Natural_Vectors.To_Vector
        (0, Into.Code.Length);
      Dependent_Target : Item_Ref_Vectors.Vector :=
        Item_Ref_Vectors.To_Vector (No_Item, Into.Code.Length);
      Dependency_Count : Natural := 0;
      Pending : Item_Ref_Vectors.Vector := Item_Ref_Vectors.To_Vector
        (No_Item, Ada.Containers.Count_Type (Count));
      Pending_First : Natural := 1;
      Pending_Last : Natural := 0;

      procedure Expose (Item : Item_Id);

      procedure Expose (Item : Item_Id) is
      begin
         Exposed (Positive (Item)) := True;
      end Expose;

      procedure Invalidate (Item : Item_Id);
      procedure Invalidate (Item : Item_Id) is
      begin
         if Proven (Positive (Item)) then
            Proven (Positive (Item)) := False;
            Pending_Last := Pending_Last + 1;
            Pending (Pending_Last) := Item;
         end if;
      end Invalidate;

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
      Visit_Address_Exposures (Into, Expose'Access);
      --  Allocate every decision before inspecting recursive calls. Proof
      --  is a greatest fixed point: each surviving incoming edge is either
      --  a literal table address or an immutable parameter of a surviving
      --  caller. Exposed roots are false, so unknown runtime evidence cannot
      --  bootstrap a cycle into a proof.
      for I in 1 .. Count loop
         declare
            Item : constant Item_Id := Item_Id (I);
         begin
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
                  --  Assembly outputs are frame writes, even though the
                  --  instruction itself has no Slot operand.  A parameter
                  --  overwritten here cannot establish static evidence.
                  for A in 1 .. Code.Assembly_Run.Count loop
                     declare
                        Output : constant Slot_Id := Into.Assembly_Operands
                          (Code.Assembly_Run.First + A).Output;
                     begin
                        if Output /= No_Slot then
                           Stable_Slots (Into.Items (I).Slots.First
                                         + Positive (Output)) := False;
                        end if;
                     end;
                  end loop;
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
                  --  Do not forward a store across a block's output write.
                  --  A later store may still establish a fresh alias.
                  for A in 1 .. Code.Assembly_Run.Count loop
                     declare
                        Output : constant Slot_Id := Into.Assembly_Operands
                          (Code.Assembly_Run.First + A).Output;
                     begin
                        if Output /= No_Slot then
                           Stored (Positive (Output)) := No_Value;
                           Blocks (Positive (Output)) := No_Block;
                        end if;
                     end;
                  end loop;
               end;
            end loop;
         end;
      end loop;
      --  Inspect each call once. Literal evidence is independent of the
      --  caller; a stable bound-parameter load creates a dependency from the
      --  caller to the callee. Any other incoming evidence is a failed root.
      --  Each failed instance enters the queue once, including failures found
      --  while scanning later calls, so propagation never rescans the unit.
      for I in 1 .. Count loop
         declare
            Caller : constant Item_Id := Item_Id (I);
         begin
            for V in 1 .. Value_Count (Into, Caller) loop
               declare
                  Code : constant Instruction := Code_At
                    (Caller, Value_Id (V));
                  Depends : Boolean := False;
               begin
                  if Code.Op = Call and then Proven (Positive (Code.Named))
                  then
                     for B in 1 .. Evidence_Binding_Count (Into, Code.Named)
                     loop
                        declare
                           Binding : constant Evidence_Binding :=
                             Nth_Evidence_Binding (Into, Code.Named, B);
                        begin
                           if Binding.Parameter > Code.Args then
                              Invalidate (Code.Named);
                              exit;
                           end if;
                           declare
                              Argument : constant Value_Id := Into.Operands
                                (Code.First_Arg + Binding.Parameter);
                              Source : constant Instruction := Code_At
                                (Caller, Original (Caller, Argument));
                           begin
                              if Static_Table (Caller, Argument)
                                /= Binding.Evidence
                              then
                                 Invalidate (Code.Named);
                                 exit;
                              end if;
                              Depends := Depends or else Source.Op = Load;
                           end;
                        end;
                     end loop;
                     if Depends and then Proven (Positive (Code.Named)) then
                        Dependency_Count := Dependency_Count + 1;
                        Dependent_Target (Dependency_Count) := Code.Named;
                        Next_Dependent (Dependency_Count) :=
                          First_Dependent (I);
                        First_Dependent (I) := Dependency_Count;
                     end if;
                  end if;
               end;
            end loop;
         end;
      end loop;
      while Pending_First <= Pending_Last loop
         declare
            Edge : Natural := First_Dependent
              (Positive (Pending (Pending_First)));
         begin
            while Edge /= 0 loop
               Invalidate (Dependent_Target (Edge));
               Edge := Next_Dependent (Edge);
            end loop;
            Pending_First := Pending_First + 1;
         end;
      end loop;
      --  The unit's represented shapes stay fixed throughout costing. Share
      --  one memo across bindings and instances, then discard it before any
      --  specialization rewrite mutates the unit.
      declare
         Measurements : Shape_Measurement.Layout_Cache;
      begin
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
                   (Landin.Targets.Bytes
                      (Landin.Targets.Pointer_Size (Facts)));
            begin
               if Decision.Template /= No_Declaration then
                  for V in 1 .. Value_Count (Into, Item) loop
                     declare
                        Code : constant Instruction :=
                          Code_At (Item, Value_Id (V));
                     begin
                        Decision.Estimated_Growth := Natural'Min
                          (Natural'Last - Effects.Weight (Code.Op),
                           Decision.Estimated_Growth)
                          + Effects.Weight (Code.Op);
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
                        Bytes : constant Landin.Targets.Byte_Count :=
                          Shape_Measurement.Cached_Field_Extent
                            (Measurements, Into,
                             Evidence_Represented (Into, Binding.Evidence),
                             Facts, Landin.Targets.Byte_Count'Last).Size;
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
                          + (if Decision.Represented_Bytes mod Pointer_Bytes
                                > 0
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
      end;
      --  Count eligible normalized instances, never call sites. Profitability
      --  cannot alter the evidence proof or source recursion acceptance.
      --  Each template is counted once before any profitability decision.
      for I in 1 .. Count loop
         if Proven (I) and then not Exposed (I)
           and then Decisions (I).Entry_Calls > 0
         then
            declare
               Template : constant Declaration_Id := Decisions (I).Template;
            begin
               if Eligible.Contains (Template) then
                  Eligible.Replace (Template, Eligible.Element (Template) + 1);
               else
                  Eligible.Insert (Template, 1);
               end if;
            end;
         end if;
      end loop;
      for I in 1 .. Count loop
         if Decisions (I).Action = Reports.Specialized then
            declare
               Instances : constant Natural :=
                 Eligible.Element (Decisions (I).Template);
            begin
               if Options.Specialize = Landin.Optimization.All_Eligible then
                  Decisions (I).Reason := Reports.Forced;
               elsif Instances = 1 then
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
                        Rewritten := True;
                     end;
                  end if;
               end loop;
            end;
         end if;
         if Decisions (I).Template /= No_Declaration then
            Decisions (I).Retains_Fallback := False;
            for V in 1 .. Value_Count (Into, Item_Id (I)) loop
               if Code_At (Item_Id (I), Value_Id (V)).Op = Indirect_Call then
                  Decisions (I).Retains_Fallback := True;
                  exit;
               end if;
            end loop;
            Reports.Append (Report, Decisions (I));
         end if;
      end loop;
      --  The verified input has no unreachable blocks. Rebuild its vectors
      --  only when a rewritten call leaves an unused callee operand behind.
      if Rewritten then
         Rewriting.Compact
           (Into, Rewriting.Keep_Vectors.To_Vector
              (True, Into.Code.Length));
         Verifier.Verify (Into, Facts);
      end if;
   end Run_On_Verified;
end Landin.IR.Specialization;
