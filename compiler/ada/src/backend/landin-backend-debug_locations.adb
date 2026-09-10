with Landin.IR.Control_Flow;
with Landin.Provenance;
with Landin.Source;
with Landin.Types;

package body Landin.Backend.Debug_Locations is

   use Landin.IR;
   use type Landin.IR.Declaration_Id;
   use type Landin.Resolution.Scope_Id;
   use type Landin.Source.Source_Id;
   use type Landin.Source.Byte_Offset;
   use type Landin.Types.Type_Kind;

   function Within
     (Meanings : Landin.Resolution.Table;
      Inner, Outer : Landin.Resolution.Scope_Id) return Boolean
   is
      Scope : Landin.Resolution.Scope_Id := Inner;
   begin
      while Scope /= Landin.Resolution.No_Scope loop
         if Scope = Outer then
            return True;
         end if;
         Scope := Landin.Resolution.Enclosing (Meanings, Scope);
      end loop;
      return False;
   end Within;

   --  These are logical leaves, not bytes: a scalar is one leaf, arrays
   --  repeat their element run, and variants have a tag followed by disjoint
   --  case runs.  Intervals keep even a target-sized array compact.  No
   --  physical layout, padding, or register choice enters this analysis.
   type Interval is record
      First, Last : Element_Total := 0;
   end record;
   package Intervals is new Ada.Containers.Vectors (Positive, Interval);
   use type Intervals.Vector;

   procedure Include
     (Into : in out Intervals.Vector; First, Last : Element_Total);
   procedure Include
     (Into : in out Intervals.Vector; First, Last : Element_Total)
   is
      Result : Intervals.Vector;
      Part : Interval := (First, Last);
      Added : Boolean := False;
   begin
      if First = Last then
         return;
      end if;
      for Old of Into loop
         if Old.Last < Part.First then
            Result.Append (Old);
         elsif Part.Last < Old.First then
            if not Added then
               Result.Append (Part);
               Added := True;
            end if;
            Result.Append (Old);
         else
            Part.First := Element_Total'Min (Part.First, Old.First);
            Part.Last := Element_Total'Max (Part.Last, Old.Last);
         end if;
      end loop;
      if not Added then
         Result.Append (Part);
      end if;
      Into := Result;
   end Include;

   procedure Exclude
     (From : in out Intervals.Vector; First, Last : Element_Total);
   procedure Exclude
     (From : in out Intervals.Vector; First, Last : Element_Total)
   is
      Result : Intervals.Vector;
   begin
      for Old of From loop
         if Old.Last <= First or else Old.First >= Last then
            Result.Append (Old);
         else
            if Old.First < First then
               Result.Append (Interval'(Old.First, First));
            end if;
            if Old.Last > Last then
               Result.Append (Interval'(Last, Old.Last));
            end if;
         end if;
      end loop;
      From := Result;
   end Exclude;

   function Meet (Left, Right : Intervals.Vector) return Intervals.Vector;
   function Meet (Left, Right : Intervals.Vector) return Intervals.Vector is
      Result : Intervals.Vector;
      R : Positive := 1;
   begin
      for L of Left loop
         while R <= Right.Last_Index and then Right (R).Last <= L.First loop
            R := R + 1;
         end loop;
         for P in R .. Right.Last_Index loop
            exit when Right (P).First >= L.Last;
            Include (Result, Element_Total'Max (L.First, Right (P).First),
                     Element_Total'Min (L.Last, Right (P).Last));
         end loop;
      end loop;
      return Result;
   end Meet;

   function Analyze
     (Of_Unit : Unit;
      Meanings : Landin.Resolution.Table;
      Info : Landin.Debugging.Information;
      Item : Item_Id;
      Slot : Slot_Id;
      Parameter : Boolean;
      Alias_Index : Natural := 0) return Flags.Vector;

   function Analyze
     (Of_Unit : Unit;
      Meanings : Landin.Resolution.Table;
      Info : Landin.Debugging.Information;
      Item : Item_Id;
      Slot : Slot_Id;
      Parameter : Boolean;
      Alias_Index : Natural := 0) return Flags.Vector
   is
      pragma Unreferenced (Info);
      Graph : constant Control_Flow.Graph := Control_Flow.Make (Of_Unit, Item);
      Binding : constant Declaration_Id :=
        (if Alias_Index = 0 then Declares (Of_Unit, Item, Slot)
         else Nth_Source_Alias (Of_Unit, Item, Alias_Index).Binding);
      Born : constant Landin.Provenance.Origin :=
        (if Alias_Index = 0 then Origin_Of (Of_Unit, Item, Slot)
         else Nth_Source_Alias (Of_Unit, Item, Alias_Index).Site);
      Result : Flags.Vector;
      type States is array (Positive range <>) of Intervals.Vector;
      Inputs, Outputs : States (1 .. Block_Count (Of_Unit, Item));
      Whole, Wanted : Intervals.Vector;
      Birth : Value_Id := No_Value;
      Changed : Boolean := True;

      type Selection is record
         Known : Boolean := False;
         Root : Boolean := False;
         First, Count : Element_Total := 0;
         Shape : Field_Shape;
      end record;

      function Leaves (Shape : Field_Shape) return Element_Total;
      function Leaves (Shape : Field_Shape) return Element_Total is
         Total : Element_Total := 0;
      begin
         case Shape.Kind is
            when Scalar_Field_Shape => return 1;
            when Array_Field_Shape =>
               return Shape.Length * Leaves
                 (Array_Element_Shape (Of_Unit, Shape));
            when Aggregate_Field_Shape =>
               for F in 1 .. Aggregate_Field_Count (Of_Unit, Shape) loop
                  Total := Total + Leaves
                    (Nth_Aggregate_Field (Of_Unit, Shape, F));
               end loop;
            when Variant_Field_Shape =>
               Total := 1;
               for C in 1 .. Shape.Cases loop
                  for F in 1 .. Variant_Case_Field_Count
                    (Of_Unit, Shape, C)
                  loop
                     Total := Total + Leaves
                       (Nth_Variant_Case_Field (Of_Unit, Shape, C, F));
                  end loop;
               end loop;
         end case;
         return Total;
      end Leaves;

      function Root_Selection return Selection;
      function Root_Selection return Selection is
         Place : Selection := (Known => True, Root => True, others => <>);
      begin
         if Is_Array (Of_Unit, Item, Slot) then
            Place.Shape := Whole_Slot_Array_Shape (Of_Unit, Item, Slot);
            Place.Count := Leaves (Place.Shape);
         elsif Is_Aggregate (Of_Unit, Item, Slot) then
            for F in 1 .. Slot_Field_Count (Of_Unit, Item, Slot) loop
               Place.Count := Place.Count + Leaves
                 (Nth_Slot_Field_Shape (Of_Unit, Item, Slot, F));
            end loop;
         else
            Place.Count := 1;
         end if;
         return Place;
      end Root_Selection;

      procedure Field
        (Place : in out Selection; Which : Element_Total;
         Case_Index : Natural := 0);
      procedure Field
        (Place : in out Selection; Which : Element_Total;
         Case_Index : Natural := 0)
      is
         Child : Field_Shape;
      begin
         if not Place.Known or else Which = 0 then
            return;
         end if;
         if Place.Root and then Is_Aggregate (Of_Unit, Item, Slot) then
            for F in 1 .. Natural (Which) - 1 loop
               Place.First := Place.First + Leaves
                 (Nth_Slot_Field_Shape (Of_Unit, Item, Slot, F));
            end loop;
            Child := Nth_Slot_Field_Shape
              (Of_Unit, Item, Slot, Positive (Which));
         elsif Place.Shape.Kind = Aggregate_Field_Shape then
            for F in 1 .. Natural (Which) - 1 loop
               Place.First := Place.First + Leaves
                 (Nth_Aggregate_Field (Of_Unit, Place.Shape, F));
            end loop;
            Child := Nth_Aggregate_Field
              (Of_Unit, Place.Shape, Positive (Which));
         elsif Place.Shape.Kind = Array_Field_Shape then
            if Which > Place.Shape.Length then
               Place.Known := False;
               return;
            end if;
            Child := Array_Element_Shape (Of_Unit, Place.Shape);
            Place.First := Place.First + (Which - 1) * Leaves (Child);
         elsif Place.Shape.Kind = Variant_Field_Shape and then Case_Index > 0
         then
            Place.First := Place.First + 1;
            for C in 1 .. Case_Index loop
               for F in 1 .. (if C = Case_Index then Natural (Which) - 1
                             else Variant_Case_Field_Count
                               (Of_Unit, Place.Shape, C))
               loop
                  Place.First := Place.First + Leaves
                    (Nth_Variant_Case_Field (Of_Unit, Place.Shape, C, F));
               end loop;
            end loop;
            Child := Nth_Variant_Case_Field
              (Of_Unit, Place.Shape, Case_Index, Positive (Which));
         else
            Place.Known := False;
            return;
         end if;
         Place.Root := False;
         Place.Shape := Child;
         Place.Count := Leaves (Child);
      end Field;

      procedure Follow (Place : in out Selection; Path : Path_Step_Array);
      procedure Follow (Place : in out Selection; Path : Path_Step_Array) is
      begin
         for Step of Path loop
            Field (Place, Element_Total (Step.Field), Step.Case_Index);
         end loop;
      end Follow;

      function Definition (Cell : Slot_Id) return Value_Id;
      function Definition (Cell : Slot_Id) return Value_Id is
         Found : Value_Id := No_Value;
      begin
         --  Only immutable address temporaries have a unique definition.
         --  A mutable pointer or ambiguous alias is not proof of a write.
         for V in 1 .. Value_Count (Of_Unit, Item) loop
            if Op_Of (Of_Unit, Item, Value_Id (V)) = Store
              and then Slot_Of (Of_Unit, Item, Value_Id (V)) = Cell
            then
               if Found /= No_Value then
                  return No_Value;
               end if;
               Found := Nth_Operand (Of_Unit, Item, Value_Id (V), 1);
            end if;
         end loop;
         return Found;
      end Definition;

      function Address
        (Value : Value_Id; Depth : Natural := 0) return Selection;
      function Storage_Place
        (Place : Storage; Depth : Natural := 0) return Selection;

      procedure Index_Element (Place : in out Selection; Index : Value_Id);
      procedure Index_Element (Place : in out Selection; Index : Value_Id) is
         Position : Element_Total;
         Child : Field_Shape;
         Known_Index : Value_Id := Index;
      begin
         --  Lowering retains an evaluated subscript across its right-hand
         --  side in a single-definition temporary, even for a literal index.
         for Depth in 1 .. Slot_Count (Of_Unit, Item) loop
            exit when Known_Index = No_Value
              or else Op_Of (Of_Unit, Item, Known_Index) /= Load;
            Known_Index := Definition
              (Slot_Of (Of_Unit, Item, Known_Index));
         end loop;
         if not Place.Known then
            return;
         elsif Place.Shape.Kind /= Array_Field_Shape
           or else Known_Index = No_Value
           or else Op_Of (Of_Unit, Item, Known_Index) /= Number
         then
            Place.Known := False;
            return;
         end if;
         Position := Element_Total (Number_Of (Of_Unit, Item, Known_Index));
         if Position >= Place.Shape.Length then
            Place.Known := False;
            return;
         end if;
         Child := Array_Element_Shape (Of_Unit, Place.Shape);
         Place.Root := False;
         Place.First := Place.First + Position * Leaves (Child);
         Place.Count := Leaves (Child);
         Place.Shape := Child;
      end Index_Element;

      function Address
        (Value : Value_Id; Depth : Natural := 0) return Selection
      is
         Place : Selection;
      begin
         if Value = No_Value or else Depth > Value_Count (Of_Unit, Item) then
            return Place;
         end if;
         case Op_Of (Of_Unit, Item, Value) is
            when Load =>
               return Address
                 (Definition (Slot_Of (Of_Unit, Item, Value)), Depth + 1);
            when Storage_Address | Place_Address =>
               Place := Storage_Place
                 (Destination_Of (Of_Unit, Item, Value), Depth + 1);
               Field (Place, Element_Total
                 (Element_Field_Of (Of_Unit, Item, Value)));
               Follow (Place, Path_Of (Of_Unit, Item, Value));
               if Op_Of (Of_Unit, Item, Value) = Storage_Address
                 and then Storage_Address_Has_Index (Of_Unit, Item, Value)
               then
                  Index_Element
                    (Place, Nth_Operand (Of_Unit, Item, Value, 1));
               end if;
            when others => null;
         end case;
         return Place;
      end Address;

      function Storage_Place
        (Place : Storage; Depth : Natural := 0) return Selection is
      begin
         if Place.Kind = Frame_Slot and then Place.Slot = Slot then
            return Root_Selection;
         elsif Place.Kind = Runtime_Address then
            return Address (Definition (Place.Address), Depth + 1);
         end if;
         return (others => <>);
      end Storage_Place;

      function Call_Result (Value : Value_Id) return Selection;
      function Call_Result (Value : Value_Id) return Selection is
         Signature : constant Signature_Id :=
           Call_Signature (Of_Unit, Item, Value);
      begin
         if Signature /= No_Signature
           and then (Signature_Result_Count (Of_Unit, Signature) > 1
             or else (Signature_Result_Count (Of_Unit, Signature) = 1
               and then Signature_Result (Of_Unit, Signature).Kind
                 in Landin.Types.Aggregate | Landin.Types.Fixed_Array))
         then
            return Address (Nth_Operand
              (Of_Unit, Item, Value,
               (if Op_Of (Of_Unit, Item, Value) = Call then 1 else 2)));
         end if;
         return (others => <>);
      end Call_Result;

      procedure Mark (State : in out Intervals.Vector; Place : Selection);
      procedure Mark (State : in out Intervals.Vector; Place : Selection) is
      begin
         if Place.Known then
            Include (State, Place.First, Place.First + Place.Count);
         end if;
      end Mark;

      procedure Transfer (State : in out Intervals.Vector; Value : Value_Id);
      procedure Transfer (State : in out Intervals.Vector; Value : Value_Id) is
         Op : constant Opcode := Op_Of (Of_Unit, Item, Value);
         Place : Selection;
      begin
         if Value = Birth then
            State.Clear;
         end if;
         case Op is
            when Store =>
               if Slot_Of (Of_Unit, Item, Value) = Slot then
                  Place := Root_Selection;
               end if;
            when Store_Indirect =>
               Place := Address (Nth_Operand (Of_Unit, Item, Value, 1));
            when Store_Field | Store_Element =>
               if Reaches_A_Slot (Of_Unit, Item, Value) then
                  Place := Storage_Place
                    ((Kind => Frame_Slot,
                      Slot => Slot_Of (Of_Unit, Item, Value)));
                  Field (Place,
                    (if Op = Store_Field
                     then Element_Total (Field_Of (Of_Unit, Item, Value))
                     else Element_Total
                       (Element_Field_Of (Of_Unit, Item, Value))));
                  Follow (Place, Path_Of (Of_Unit, Item, Value));
                  if Op = Store_Element then
                     Field (Place,
                       Element_Total (Variant_Payload_Field_Of
                         (Of_Unit, Item, Value)),
                       Variant_Case_Of (Of_Unit, Item, Value));
                     Index_Element
                       (Place, Nth_Operand (Of_Unit, Item, Value, 1));
                     Follow (Place, Element_Path_Of (Of_Unit, Item, Value));
                  end if;
               end if;
            when Copy_Array | Clear_Array | Fill_Array | Copy_Variant
               | Select_Variant | Store_Variant_Field =>
               Place := Storage_Place (Destination_Of (Of_Unit, Item, Value));
               Field (Place, Element_Total
                 (Element_Field_Of (Of_Unit, Item, Value)));
               Follow (Place, Path_Of (Of_Unit, Item, Value));
               if Op in Copy_Array | Fill_Array | Store_Variant_Field then
                  Field (Place,
                    Element_Total (Variant_Payload_Field_Of
                      (Of_Unit, Item, Value)),
                    Variant_Case_Of (Of_Unit, Item, Value));
               end if;
               if Place.Known and then Op = Fill_Array then
                  declare
                     Prefix : constant Element_Total :=
                       (Element_Total (First_Part_Of (Of_Unit, Item, Value))
                        - 1) * Leaves
                          (Array_Element_Shape (Of_Unit, Place.Shape));
                  begin
                     Place.First := Place.First + Prefix;
                     Place.Count := Place.Count - Prefix;
                  end;
               elsif Place.Known and then Op = Select_Variant then
                  --  The tag selects which payload is meaningful.  Inactive
                  --  cases impose no obligation; the selected case must be
                  --  written anew, even after a previous selection.
                  Mark (State, Place);
                  for F in 1 .. Variant_Case_Field_Count
                    (Of_Unit, Place.Shape,
                     Variant_Case_Of (Of_Unit, Item, Value))
                  loop
                     declare
                        Payload : Selection := Place;
                     begin
                        Field (Payload, Element_Total (F),
                          Variant_Case_Of (Of_Unit, Item, Value));
                        Exclude (State, Payload.First,
                                 Payload.First + Payload.Count);
                     end;
                  end loop;
                  return;
               end if;
            when Call | Indirect_Call =>
               Place := Call_Result (Value);
               if Place.Known
                 and then Failure_Slot_Of (Of_Unit, Item, Value) /= No_Slot
               then
                  --  A failed callee may have written only part of its
                  --  destination.  Even an older value is no longer proof.
                  Exclude (State, Place.First, Place.First + Place.Count);
                  return;
               end if;
            when others => null;
         end case;
         Mark (State, Place);
      end Transfer;

      function On_Edge (Pred, Block : Block_Id) return Intervals.Vector;
      function On_Edge (Pred, Block : Block_Id) return Intervals.Vector is
         State : Intervals.Vector := Outputs (Positive (Pred));
         Last : constant Value_Id := Nth_Value
           (Of_Unit, Item, Pred, Length (Of_Unit, Item, Pred));
      begin
         if Op_Of (Of_Unit, Item, Last) = Branch
           and then Alternative_Of (Of_Unit, Item, Last) = Block
         then
            declare
               Test : constant Value_Id :=
                 Nth_Operand (Of_Unit, Item, Last, 1);
            begin
               if Op_Of (Of_Unit, Item, Test) = Failure_Test then
                  declare
                     Error : constant Value_Id :=
                       Nth_Operand (Of_Unit, Item, Test, 1);
                  begin
                     if Op_Of (Of_Unit, Item, Error) = Load then
                        for P in reverse 1 .. Length (Of_Unit, Item, Pred) loop
                           declare
                              V : constant Value_Id :=
                                Nth_Value (Of_Unit, Item, Pred, P);
                           begin
                              if Op_Of (Of_Unit, Item, V)
                                in Call | Indirect_Call
                                and then Failure_Slot_Of (Of_Unit, Item, V)
                                  = Slot_Of (Of_Unit, Item, Error)
                              then
                                 Mark (State, Call_Result (V));
                                 exit;
                              end if;
                           end;
                        end loop;
                     end if;
                  end;
               end if;
            end;
         end if;
         return State;
      end On_Edge;
   begin
      Mark (Whole, Root_Selection);
      Result.Append (False, Ada.Containers.Count_Type
        (Value_Count (Of_Unit, Item)));
      Wanted := Whole;
      if Alias_Index /= 0 then
         declare
            Alias : constant Source_Alias :=
              Nth_Source_Alias (Of_Unit, Item, Alias_Index);
            Place : Selection := Root_Selection;
         begin
            if Alias.Place.Kind = Frame_Slot then
               Field (Place, Element_Total (Alias.Field));
               Follow (Place, Source_Alias_Path (Of_Unit, Item, Alias_Index));
               if not Place.Known then
                  return Result;
               end if;
               Wanted.Clear;
               Mark (Wanted, Place);
            end if;
         end;
      end if;
      if not Parameter and then Alias_Index = 0 then
         for V in 1 .. Value_Count (Of_Unit, Item) loop
            declare
               Site : constant Landin.Provenance.Origin :=
                 Origin_Of (Of_Unit, Item, Value_Id (V));
            begin
               if Site.Source = Born.Source
                 and then Site.Where.First >= Born.Where.First
               then
                  Birth := Value_Id (V);
                  exit;
               end if;
            end;
         end loop;
      end if;
      Inputs := [others => Whole];
      Outputs := Inputs;
      while Changed loop
         Changed := False;
         for B in 1 .. Block_Count (Of_Unit, Item) loop
            declare
               Block : constant Block_Id := Block_Id (B);
               State : Intervals.Vector := Whole;
               Edge : Natural := Control_Flow.First_Predecessor (Graph, Block);
            begin
               if Block = First_Block then
                  if not Parameter then
                     State.Clear;
                  end if;
               elsif not Control_Flow.Is_Reachable (Graph, Block) then
                  State.Clear;
               else
                  while Edge /= 0 loop
                     declare
                        Pred : constant Block_Id :=
                          Control_Flow.Predecessor (Graph, Edge);
                     begin
                        if Control_Flow.Is_Reachable (Graph, Pred) then
                           State := Meet (State, On_Edge (Pred, Block));
                        end if;
                     end;
                     Edge := Control_Flow.Next_Predecessor (Graph, Edge);
                  end loop;
               end if;
               Inputs (B) := State;
               for P in 1 .. Length (Of_Unit, Item, Block) loop
                  Transfer (State, Nth_Value (Of_Unit, Item, Block, P));
               end loop;
               if Outputs (B) /= State then
                  Outputs (B) := State;
                  Changed := True;
               end if;
            end;
         end loop;
      end loop;
      for B in 1 .. Block_Count (Of_Unit, Item) loop
         declare
            Block : constant Block_Id := Block_Id (B);
            State : Intervals.Vector := Inputs (B);
            Visible : constant Boolean := Binding /= No_Declaration
              and then Within (Meanings, Scope_Of (Of_Unit, Item, Block),
                Landin.Resolution.Scope_Of (Meanings, Binding));
         begin
            for P in 1 .. Length (Of_Unit, Item, Block) loop
               declare
                  Value : constant Value_Id :=
                    Nth_Value (Of_Unit, Item, Block, P);
                  Site : constant Landin.Provenance.Origin :=
                    Origin_Of (Of_Unit, Item, Value);
               begin
                  Result (Positive (Value)) := Meet (State, Wanted) = Wanted
                    and then Value /= Birth and then Visible
                    and then Control_Flow.Is_Reachable (Graph, Block)
                    and then Op_Of (Of_Unit, Item, Value) not in Leave | Fail
                    and then (Parameter or else
                      (Site.Source = Born.Source
                       and then Site.Where.First >= Born.Where.Last));
                  Transfer (State, Value);
               end;
            end loop;
         end;
      end loop;
      return Result;
   end Analyze;

   function Available
     (Of_Unit : Unit;
      Meanings : Landin.Resolution.Table;
      Info : Landin.Debugging.Information;
      Item : Item_Id;
      Slot : Slot_Id;
      Parameter : Boolean) return Flags.Vector
   is (Analyze (Of_Unit, Meanings, Info, Item, Slot, Parameter));

   function Available_Alias
     (Of_Unit : Unit;
      Meanings : Landin.Resolution.Table;
      Info : Landin.Debugging.Information;
      Item : Item_Id;
      Index : Positive) return Flags.Vector
   is
      Alias : constant Source_Alias := Nth_Source_Alias (Of_Unit, Item, Index);
      Slot : Slot_Id := No_Slot;
      Parameter : Boolean := False;
      Result : Flags.Vector;
   begin
      case Alias.Place.Kind is
         when Frame_Slot =>
            Slot := Alias.Place.Slot;
            Parameter := Alias.Initialized_On_Entry;
         when Runtime_Address =>
            --  Entry proves the referred value, not its address carrier.
            --  The latter must have been refreshed before this arm/iteration.
            if not Alias.Initialized_On_Entry then
               Result.Append (False, Ada.Containers.Count_Type
                 (Value_Count (Of_Unit, Item)));
               return Result;
            end if;
            Slot := Alias.Place.Address;
         when Module_Datum =>
            for V in 1 .. Value_Count (Of_Unit, Item) loop
               Result.Append (Alias.Initialized_On_Entry
                 and then Op_Of (Of_Unit, Item, Value_Id (V))
                   not in Leave | Fail
                 and then Within (Meanings, Scope_Of
                   (Of_Unit, Item, Block_Of (Of_Unit, Item, Value_Id (V))),
                   Landin.Resolution.Scope_Of (Meanings, Alias.Binding)));
            end loop;
            return Result;
      end case;
      for P in 1 .. Parameter_Count (Of_Unit, Item) loop
         Parameter := Parameter
           or else Nth_Parameter (Of_Unit, Item, P) = Slot;
      end loop;
      return Analyze (Of_Unit, Meanings, Info, Item, Slot, Parameter, Index);
   end Available_Alias;

end Landin.Backend.Debug_Locations;
