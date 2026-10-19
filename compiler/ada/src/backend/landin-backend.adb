with Ada.Containers;
with Ada.Containers.Generic_Array_Sort;
with Ada.Strings.Unbounded;
with Landin.Backend.Work_Arrays;
with Landin.Machine;

package body Landin.Backend is

   use type Landin.IR.Declaration_Id;
   use type Landin.IR.Element_Total;
   use type Landin.IR.Field_Shape_Kind;
   use type Landin.IR.Field_Shape;
   use type Landin.IR.Item_Id;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.Byte_Alignment;
   use type Landin.Types.Type_Kind;

   package IR renames Landin.IR;
   package Targets renames Landin.Targets;
   package Layout renames Landin.Targets.Layouts;

   function Smallest_First
     (Items : Item_Array; Extents : Extent_Array) return Item_Array
   is
      type Position_Array is array (Positive range <>) of Positive;

      function Before (Left, Right : Positive) return Boolean
      is (Extents (Left) < Extents (Right)
          or else (Extents (Left) = Extents (Right) and then Left < Right));

      procedure Sort is new Ada.Containers.Generic_Array_Sort
        (Index_Type => Positive, Element_Type => Positive,
         Array_Type => Position_Array, "<" => Before);

      Order : Position_Array (Items'Range);
      Result : Item_Array (Items'Range);
   begin
      for Index in Order'Range loop
         Order (Index) := Index;
      end loop;
      Sort (Order);
      for Index in Order'Range loop
         Result (Index) := Items (Order (Index));
      end loop;
      return Result;
   end Smallest_First;

   function Shares_Evidence_Table
     (Of_Unit : IR.Unit; Direct, Erased : IR.Evidence_Id) return Boolean
   is
   begin
      if IR.Evidence_Is_Erased (Of_Unit, Direct)
        or else not IR.Evidence_Is_Erased (Of_Unit, Erased)
        or else IR.Evidence_Represented (Of_Unit, Direct)
                  /= IR.Evidence_Represented (Of_Unit, Erased)
        or else IR.Evidence_Entry_Count (Of_Unit, Direct)
                  /= IR.Evidence_Entry_Count (Of_Unit, Erased)
      then
         return False;
      end if;
      for Which in 1 .. IR.Evidence_Entry_Count (Of_Unit, Direct) loop
         if IR.Evidence_Entry_Target (Of_Unit, Direct, Which)
              /= IR.Evidence_Entry_Target (Of_Unit, Erased, Which)
         then
            return False;
         end if;
      end loop;
      return True;
   end Shares_Evidence_Table;

   package Item_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => IR.Item_Id);

   --  Every routine a word of an `assembler.block`'s text may name, by
   --  that word.
   package Word_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Item_Vectors.Vector,
      Hash => Ada.Strings.Hash, Equivalent_Keys => "=",
      "=" => Item_Vectors."=");

   function Kept_Evidence_Entries
     (Of_Unit  : IR.Unit;
      Handler  : IR.Item_Id;
      Meanings : Landin.Resolution.Table;
      Names    : Landin.Source.Names.Table) return Kept_Entries
   is
      use type Landin.IR.Item_Kind;
      use type Landin.IR.Opcode;
      use type Landin.IR.Signature_Id;
      use type Landin.Machine.Convention;
      use type Landin.Source.Names.Name_Id;

      Tables : constant Natural := IR.Evidence_Count (Of_Unit);
      Items : constant Natural := IR.Item_Count (Of_Unit);
      Result : Kept_Entries;
      Total : Natural := 0;

      type Flag_Array is array (Positive range <>) of Boolean;
      type Item_List is array (Positive range <>) of IR.Item_Id;
      type Table_List is array (Positive range <>) of Positive;

      Live : Flag_Array (1 .. Natural'Max (1, Items)) := [others => True];
      Pending : Item_List (1 .. Natural'Max (1, Items));
      Waiting : Natural := 0;

      --  Tables in family order, ties in table order, so that the tables
      --  sharing one family are a run; Run_Of (T) is where T's run starts.
      Order : Table_List (1 .. Natural'Max (1, Tables)) := [others => 1];
      Run_Of : Table_List (1 .. Natural'Max (1, Tables)) := [others => 1];

      function Key (Table : Positive) return Natural
        is (if IR.Evidence_Family (Of_Unit, IR.Evidence_Id (Table)) = 0
            then 0
            else 2 * IR.Evidence_Family (Of_Unit, IR.Evidence_Id (Table))
                 + (if IR.Evidence_Is_Erased
                         (Of_Unit, IR.Evidence_Id (Table))
                    then 1 else 0));

      function Before (Left, Right : Positive) return Boolean
        is (Key (Left) < Key (Right)
            or else (Key (Left) = Key (Right) and then Left < Right));

      procedure Sort is new Ada.Containers.Generic_Array_Sort
        (Index_Type => Positive, Element_Type => Positive,
         Array_Type => Table_List, "<" => Before);

      procedure Reach (Target : IR.Item_Id);
      procedure Keep (Table : Positive; Which : Positive);
      procedure Keep_In_Family (Table : Positive; Which : Positive);
      procedure Note_Exposed (Item : IR.Item_Id);

      procedure Reach (Target : IR.Item_Id) is
      begin
         if Target /= IR.No_Item and then not Live (Positive (Target)) then
            Live (Positive (Target)) := True;
            Waiting := Waiting + 1;
            Pending (Waiting) := Target;
         end if;
      end Reach;

      procedure Keep (Table : Positive; Which : Positive) is
         Position : constant Positive := Result.First (Table) + Which;
      begin
         if not Result.Kept (Position) then
            Result.Kept (Position) := True;
            Reach (IR.Evidence_Entry_Target
              (Of_Unit, IR.Evidence_Id (Table), Which));
         end if;
      end Keep;

      procedure Keep_In_Family (Table : Positive; Which : Positive) is
      begin
         if Key (Table) = 0 then
            Keep (Table, Which);
            return;
         elsif Result.Kept (Result.First (Table) + Which) then
            --  Only this procedure keeps a family's entry, and it keeps
            --  it in the whole family at once.
            return;
         end if;
         for Index in Run_Of (Table) .. Tables loop
            exit when Key (Order (Index)) /= Key (Table);
            if Which <= IR.Evidence_Entry_Count
              (Of_Unit, IR.Evidence_Id (Order (Index)))
            then
               Keep (Order (Index), Which);
            end if;
         end loop;
      end Keep_In_Family;

      procedure Note_Exposed (Item : IR.Item_Id) is
      begin
         Live (Positive (Item)) := True;
      end Note_Exposed;

      --  The routines a block's text may name, by the words D296 roots:
      --  a routine's name and link name.  A word with a leading `_`, as
      --  Mach-O spells a symbol, also names what it names without it.
      Named : Word_Maps.Map;

      procedure Name (Word : String; Item : IR.Item_Id);
      procedure Reach_Named (Word : String);
      procedure Reach_Words (Text : String);

      procedure Name (Word : String; Item : IR.Item_Id) is
         Position : constant Word_Maps.Cursor := Named.Find (Word);
      begin
         if Word'Length = 0 then
            return;
         elsif Word_Maps.Has_Element (Position) then
            Named.Reference (Position).Append (Item);
         else
            Named.Insert (Word, Item_Vectors.To_Vector (Item, 1));
         end if;
      end Name;

      procedure Reach_Named (Word : String) is
         Position : constant Word_Maps.Cursor := Named.Find (Word);
      begin
         if Word_Maps.Has_Element (Position) then
            for Target of Named.Constant_Reference (Position) loop
               Reach (Target);
            end loop;
         end if;
      end Reach_Named;

      --  Every run of symbol characters in Text, as D296 reads one.
      procedure Reach_Words (Text : String) is
         function Symbolic (C : Character) return Boolean is
           (C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' | '$');
         First : Natural := 0;
      begin
         for Index in Text'Range loop
            if Symbolic (Text (Index)) then
               if First = 0 then
                  First := Index;
               end if;
               if Index = Text'Last or else not Symbolic (Text (Index + 1))
               then
                  Reach_Named (Text (First .. Index));
                  if Text (First) = '_' and then Index > First then
                     Reach_Named (Text (First + 1 .. Index));
                  end if;
                  First := 0;
               end if;
            end if;
         end loop;
      end Reach_Words;

      Any_Assembly : Boolean := False;
   begin
      for Table in 1 .. Tables loop
         Result.First.Append (Total);
         Total := Total + IR.Evidence_Entry_Count
           (Of_Unit, IR.Evidence_Id (Table));
      end loop;
      Result.Kept.Append (False, Ada.Containers.Count_Type (Total));
      if Tables = 0 then
         return Result;
      end if;

      for Table in 1 .. Tables loop
         Order (Table) := Table;
      end loop;
      Sort (Order);
      for Index in 1 .. Tables loop
         Run_Of (Order (Index)) :=
           (if Index > 1 and then Key (Order (Index - 1)) = Key (Order (Index))
            then Run_Of (Order (Index - 1)) else Index);
      end loop;

      for Index in 1 .. Items loop
         declare
            Item : constant IR.Item_Id := IR.Item_Id (Index);
         begin
            if IR.Kind_Of (Of_Unit, Item) = IR.Routine then
               for Value in 1 .. IR.Value_Count (Of_Unit, Item) loop
                  Any_Assembly := Any_Assembly
                    or else IR.Op_Of (Of_Unit, Item, IR.Value_Id (Value))
                      = IR.Assembly;
               end loop;
            end if;
         end;
      end loop;

      --  A block names a routine by the words D296 roots, so the routines
      --  are indexed by them only when there is a block to read.
      if Any_Assembly then
         for Index in 1 .. Items loop
            declare
               Item : constant IR.Item_Id := IR.Item_Id (Index);
               Declared : constant IR.Declaration_Id :=
                 IR.Declares (Of_Unit, Item);
               Linked : constant Landin.Source.Names.Name_Id :=
                 IR.Link_Symbol (Of_Unit, Item);
            begin
               if IR.Kind_Of (Of_Unit, Item) = IR.Routine then
                  if Declared /= IR.No_Declaration then
                     Name (Landin.Source.Names.Spelling
                             (Names, Landin.Resolution.Name_Of
                                (Meanings, Declared)), Item);
                  end if;
                  if Linked /= Landin.Source.Names.No_Name then
                     Name (Landin.Source.Names.Spelling (Names, Linked), Item);
                  end if;
               end if;
            end;
         end loop;
      end if;

      --  Only an ordinary routine with parameters, which nothing but a
      --  call, a block's text or an evidence entry names, can be left
      --  unreached; every other routine, and the panic handler the backend
      --  calls, is a root.  A routine only unreached routines call or
      --  name stays unreached.
      for Index in 1 .. Items loop
         declare
            Target : constant IR.Item_Id := IR.Item_Id (Index);
            Signature : constant IR.Signature_Id :=
              (if IR.Kind_Of (Of_Unit, Target) = IR.Routine
               then IR.Signature_Of (Of_Unit, Target)
               else IR.No_Signature);
            Placed : constant Landin.Machine.Placement :=
              IR.Placement_Of (Of_Unit, Target);
         begin
            if Signature /= IR.No_Signature
              and then Target /= Handler
              and then not IR.Is_External (Of_Unit, Target)
              and then IR.Link_Symbol (Of_Unit, Target)
                = Landin.Source.Names.No_Name
              and then Placed.Section = Landin.Source.Names.No_Name
              and then Placed.Vector = 0
              and then not Placed.Keep
              and then not IR.Signature_Uses_C_ABI (Of_Unit, Signature)
              and then IR.Signature_Machine (Of_Unit, Signature)
                = Landin.Machine.Ordinary
              and then IR.Signature_Parameter_Count
                (Of_Unit, Signature) > 0
            then
               Live (Index) := False;
            end if;
         end;
      end loop;
      IR.Visit_Address_Exposures_Beside_Evidence
        (Of_Unit, Note_Exposed'Access);
      for Index in 1 .. Items loop
         declare
            Item : constant IR.Item_Id := IR.Item_Id (Index);
            Function_Image : constant IR.Item_Id :=
              IR.Function_Target (Of_Unit, Item);
            Address_Image : constant IR.Item_Id :=
              IR.Address_Target (Of_Unit, Item);
         begin
            if Function_Image /= IR.No_Item then
               Live (Positive (Function_Image)) := True;
            end if;
            if Address_Image /= IR.No_Item then
               Live (Positive (Address_Image)) := True;
            end if;
         end;
      end loop;

      --  Each item waits at most once: the roots now, and later only what
      --  Reach makes live.
      for Index in reverse 1 .. Items loop
         if Live (Index) then
            Waiting := Waiting + 1;
            Pending (Waiting) := IR.Item_Id (Index);
         end if;
      end loop;
      for Table in 1 .. Tables loop
         if Key (Table) = 0 then
            for Which in 1 .. IR.Evidence_Entry_Count
              (Of_Unit, IR.Evidence_Id (Table))
            loop
               Keep (Table, Which);
            end loop;
         end if;
      end loop;

      while Waiting > 0 loop
         declare
            Item : constant IR.Item_Id := Pending (Waiting);
         begin
            Waiting := Waiting - 1;
            if IR.Kind_Of (Of_Unit, Item) = IR.Routine then
               for Position in 1 .. IR.Value_Count (Of_Unit, Item) loop
                  declare
                     Value : constant IR.Value_Id := IR.Value_Id (Position);
                  begin
                     case IR.Op_Of (Of_Unit, Item, Value) is
                        when IR.Function_Address | IR.Call =>
                           Reach (IR.Callee_Of (Of_Unit, Item, Value));
                        when IR.Evidence_Function =>
                           Keep_In_Family
                             (Positive (IR.Evidence_Of (Of_Unit, Item, Value)),
                              IR.Evidence_Entry_Of (Of_Unit, Item, Value));
                        when IR.Assembly =>
                           Reach_Words (Landin.Source.Names.Spelling
                             (Names, IR.Assembly_Text (Of_Unit, Item, Value)));
                        when others =>
                           null;
                     end case;
                  end;
               end loop;
            end if;
         end;
      end loop;

      --  One physical table keeps what either of its identities keeps.
      for Table in 1 .. Tables - 1 loop
         if Shares_Evidence_Table
           (Of_Unit, IR.Evidence_Id (Table), IR.Evidence_Id (Table + 1))
         then
            for Which in 1 .. IR.Evidence_Entry_Count
              (Of_Unit, IR.Evidence_Id (Table))
            loop
               declare
                  Left : constant Positive := Result.First (Table) + Which;
                  Right : constant Positive :=
                    Result.First (Table + 1) + Which;
                  Either : constant Boolean :=
                    Result.Kept (Left) or else Result.Kept (Right);
               begin
                  Result.Kept (Left) := Either;
                  Result.Kept (Right) := Either;
               end;
            end loop;
         end if;
      end loop;
      return Result;
   end Kept_Evidence_Entries;

   function Is_Kept
     (Of_Kept : Kept_Entries;
      Id      : IR.Evidence_Id;
      Which   : Positive) return Boolean
     is (Of_Kept.Kept (Of_Kept.First (Positive (Id)) + Which));

   function Stack_Add
     (Left, Right, Maximum : Targets.Byte_Count) return Targets.Byte_Count
   is
   begin
      if Left > Maximum or else Right > Maximum - Left then
         raise Stack_Limit_Exceeded with "a stack extent exceeds its limit";
      end if;
      return Left + Right;
   end Stack_Add;

   function Stack_Align
     (Offset : Targets.Byte_Count;
      Alignment : Targets.Byte_Alignment;
      Maximum : Targets.Byte_Count) return Targets.Byte_Count
   is
   begin
      if not Targets.Is_Power_Of_Two (Alignment) then
         raise Compiler_Defect with "stack alignment is not a power of two";
      end if;
      declare
         Step : constant Targets.Byte_Count := Targets.Byte_Count (Alignment);
         Padding : constant Targets.Byte_Count := (Step - Offset mod Step)
           mod Step;
      begin
         return Stack_Add (Offset, Padding, Maximum);
      end;
   end Stack_Align;

   function Fields_Layout
     (Of_Unit : IR.Unit;
      Fields  : IR.Field_Shape_Array;
      Policy  : Landin.Layouts.Policy;
      Facts   : Targets.Target_Facts) return Layout.Plan
     is (IR.Shape_Measurement.Fields_Layout
           (Of_Unit, Fields, Policy, Facts,
            Targets.Maximum_Object_Size (Facts)));

   function Aggregate_Layout
     (Of_Unit : IR.Unit;
      Shape   : IR.Field_Shape;
      Facts   : Targets.Target_Facts) return Layout.Plan
     is (IR.Shape_Measurement.Aggregate_Layout
           (Of_Unit, Shape, Facts, Targets.Maximum_Object_Size (Facts)));

   function Path_Offset
     (Of_Unit : Landin.IR.Unit;
      Shape : Landin.IR.Field_Shape;
      Path  : Landin.IR.Path_Step_Array;
      Facts : Landin.Targets.Target_Facts;
      Cache : in out IR.Shape_Measurement.Layout_Cache)
      return Landin.Targets.Byte_Count
   is
      Reached : Landin.IR.Field_Shape := Shape;
      Total   : Landin.Targets.Byte_Count := 0;
   begin
      for Step of Path loop
         if Step.Case_Index = 0
           and then Reached.Kind = Landin.IR.Array_Field_Shape
         then
            --  D127: a step into an array names [0520]'s element
            --  position, so the offset is one multiplication.
            declare
               Element : constant Landin.IR.Field_Shape :=
                 Landin.IR.Array_Element_Shape (Of_Unit, Reached);
               Extent : constant Layout.Field_Extent :=
                 IR.Shape_Measurement.Cached_Field_Extent
                   (Cache, Of_Unit, Element, Facts,
                    Targets.Maximum_Object_Size (Facts));
            begin
               Total := Total
                 + Landin.Targets.Byte_Count
                     (Landin.IR.Element_Total (Step.Field) - 1)
                   * Extent.Size;
               Reached := Element;
            end;
         elsif Step.Case_Index = 0 then
            Total := Total
              + IR.Shape_Measurement.Cached_Aggregate_Field_Offset
                  (Cache, Of_Unit, Reached, Positive (Step.Field), Facts,
                   Targets.Maximum_Object_Size (Facts));
            Reached := Landin.IR.Nth_Aggregate_Field
              (Of_Unit, Reached, Positive (Step.Field));
         else
            Total := Total
              + IR.Shape_Measurement.Cached_Variant_Payload_Field_Offset
                  (Cache, Of_Unit, Reached, Step.Case_Index,
                   Positive (Step.Field), Facts,
                   Targets.Maximum_Object_Size (Facts));
            Reached := Landin.IR.Nth_Variant_Case_Field
              (Of_Unit, Reached, Step.Case_Index,
               Positive (Step.Field));
         end if;
      end loop;
      return Total;
   end Path_Offset;

   function Nominal_Layout
     (Of_Unit : IR.Unit;
      Nominal : IR.Nominal_Type_Id;
      Facts   : Targets.Target_Facts) return Layout.Plan
   is
      Fields : IR.Field_Shape_Array
        (1 .. IR.Nominal_Field_Count (Of_Unit, Nominal));
   begin
      for Index in Fields'Range loop
         Fields (Index) := IR.Nth_Nominal_Field (Of_Unit, Nominal, Index);
      end loop;
      return Fields_Layout
        (Of_Unit, Fields, IR.Layout_Of (Of_Unit, Nominal), Facts);
   end Nominal_Layout;

   function Slot_Layout
     (Of_Unit : IR.Unit;
      Item    : IR.Item_Id;
      Slot    : IR.Slot_Id;
      Facts   : Targets.Target_Facts) return Layout.Plan
   is
   begin
      if not IR.Holds (Of_Unit, Item, Slot)
        or else not IR.Is_Aggregate (Of_Unit, Item, Slot)
      then
         raise Compiler_Defect with "a slot layout needs an aggregate slot";
      end if;
      declare
         Fields : IR.Field_Shape_Array
           (1 .. IR.Slot_Field_Count (Of_Unit, Item, Slot));
      begin
         for Index in Fields'Range loop
            Fields (Index) := IR.Nth_Slot_Field_Shape
              (Of_Unit, Item, Slot, Index);
         end loop;
         return Fields_Layout
           (Of_Unit, Fields, IR.Layout_Of (Of_Unit, Item, Slot), Facts);
      end;
   end Slot_Layout;

   function Datum_Layout
     (Of_Unit : IR.Unit;
      Item    : IR.Item_Id;
      Facts   : Targets.Target_Facts) return Layout.Plan
   is
   begin
      if not IR.Holds (Of_Unit, Item)
        or else IR.Result_Of (Of_Unit, Item) /= Landin.Types.Aggregate
      then
         raise Compiler_Defect with "a datum layout needs an aggregate";
      end if;
      declare
         Fields : IR.Field_Shape_Array (1 .. IR.Field_Count (Of_Unit, Item));
      begin
         for Index in Fields'Range loop
            Fields (Index) := IR.Nth_Field_Shape (Of_Unit, Item, Index);
         end loop;
         return Fields_Layout
           (Of_Unit, Fields, IR.Layout_Of (Of_Unit, Item), Facts);
      end;
   end Datum_Layout;

   function Measurement_Layout
     (Of_Unit : IR.Unit;
      Item    : IR.Item_Id;
      Value   : IR.Value_Id;
      Facts   : Targets.Target_Facts) return Layout.Plan
   is
   begin
      if not IR.Holds (Of_Unit, Item, Value)
        or else not IR.Is_Aggregate_Measurement (Of_Unit, Item, Value)
      then
         raise Compiler_Defect with "a measurement layout needs an aggregate";
      end if;
      declare
         Fields : IR.Field_Shape_Array
           (1 .. IR.Measurement_Field_Count (Of_Unit, Item, Value));
      begin
         for Index in Fields'Range loop
            Fields (Index) := IR.Nth_Measurement_Field
              (Of_Unit, Item, Value, Index);
         end loop;
         return Fields_Layout
           (Of_Unit, Fields, IR.Layout_Of (Of_Unit, Item, Value), Facts);
      end;
   end Measurement_Layout;

   ------------------------------------------------------------------
   --  Size_Of
   ------------------------------------------------------------------

   function Size_Of
     (Item : Landin.Types.Scalar_Name;
      Facts : Landin.Targets.Target_Facts)
     return Landin.Targets.Scalar_Size
     is (Landin.Types.Storage_Size (Item, Facts));

   function Case_Layout
     (Of_Unit : IR.Unit; Shape : IR.Field_Shape; Which : Positive;
      Facts : Targets.Target_Facts) return Layout.Plan
     is (IR.Shape_Measurement.Case_Layout
           (Of_Unit, Shape, Which, Facts,
            Targets.Maximum_Object_Size (Facts)));

   function Variant_Layout
     (Of_Unit : IR.Unit; Shape : IR.Field_Shape;
      Facts : Targets.Target_Facts) return Layout.Plan
     is (IR.Shape_Measurement.Variant_Layout
           (Of_Unit, Shape, Facts, Targets.Maximum_Object_Size (Facts)));

   procedure Repeat_Extent
     (Length : IR.Element_Total; Facts : Targets.Target_Facts;
      Size : in out Targets.Byte_Count;
      Alignment : in out Targets.Byte_Alignment);

   procedure Repeat_Extent
     (Length : IR.Element_Total; Facts : Targets.Target_Facts;
      Size : in out Targets.Byte_Count;
      Alignment : in out Targets.Byte_Alignment)
   is
      Repeated : constant Layout.Field_Extent := IR.Shape_Measurement.Repeated
        ((Size, Alignment), Length, Targets.Maximum_Object_Size (Facts));
   begin
      Size := Repeated.Size;
      Alignment := Repeated.Alignment;
   end Repeat_Extent;

   procedure Field_Extent
     (Of_Unit   : Landin.IR.Unit;
      Shape     : Landin.IR.Field_Shape;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
   is
      Measured : constant Layout.Field_Extent := IR.Shape_Measurement.Extent
        (Of_Unit, Shape, Facts, Targets.Maximum_Object_Size (Facts));
   begin
      Size := Measured.Size;
      Alignment := Measured.Alignment;
   end Field_Extent;

   procedure Variant_Selected_Payload_Extent
     (Of_Unit : Landin.IR.Unit;
      Shape   : Landin.IR.Field_Shape;
      Which   : Positive;
      Facts   : Landin.Targets.Target_Facts;
      Offset  : out Landin.Targets.Byte_Count;
      Size    : out Landin.Targets.Byte_Count)
   is
      Part : constant Layout.Plan := Variant_Layout (Of_Unit, Shape, Facts);
      Payload : constant Layout.Plan :=
        Case_Layout (Of_Unit, Shape, Which, Facts);
   begin
      Offset := Part.Offsets (2);
      Size := Payload.Size;
   end Variant_Selected_Payload_Extent;

   function Variant_Payload_Field_Offset
     (Of_Unit       : Landin.IR.Unit;
      Shape         : Landin.IR.Field_Shape;
      Which         : Positive;
      Payload_Field : Positive;
      Facts         : Landin.Targets.Target_Facts)
      return Landin.Targets.Byte_Count
   is
      Part : constant Layout.Plan := Variant_Layout (Of_Unit, Shape, Facts);
      Payload : constant Layout.Plan :=
        Case_Layout (Of_Unit, Shape, Which, Facts);
   begin
      if Payload_Field > Payload.Count then
         raise Compiler_Defect with "no such variant payload field";
      end if;
      return Part.Offsets (2) + Payload.Offsets (Payload_Field);
   end Variant_Payload_Field_Offset;

   function Variant_Payload_Field_Offset
     (Of_Unit       : Landin.IR.Unit;
      Shape         : Landin.IR.Field_Shape;
      Which         : Positive;
      Payload_Field : Positive;
      Facts         : Landin.Targets.Target_Facts;
      Cache         : in out IR.Shape_Measurement.Layout_Cache)
      return Landin.Targets.Byte_Count is
     (IR.Shape_Measurement.Cached_Variant_Payload_Field_Offset
        (Cache, Of_Unit, Shape, Which, Payload_Field, Facts,
         Targets.Maximum_Object_Size (Facts)));

   ------------------------------------------------------------------
   --  A target-neutral measurement
   ------------------------------------------------------------------

   procedure Measurement_Extent
     (Of_Unit   : Landin.IR.Unit;
      Item      : Landin.IR.Item_Id;
      Value     : Landin.IR.Value_Id;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
   is
      use type Landin.IR.Opcode;
   begin
      if Landin.IR.Op_Of (Of_Unit, Item, Value) = Landin.IR.Measure_Offset
      then
         Size := Measurement_Answer (Of_Unit, Item, Value, Facts);
         Alignment := 1;
      elsif Landin.IR.Is_Aggregate_Measurement (Of_Unit, Item, Value) then
         declare
            Placed : constant Layout.Plan :=
              Measurement_Layout (Of_Unit, Item, Value, Facts);
         begin
            Size := Placed.Size;
            Alignment := Placed.Alignment;
         end;
      else
         declare
            Held : constant Landin.Targets.Scalar_Size :=
              Size_Of (Landin.IR.Measured_Of (Of_Unit, Item, Value), Facts);
         begin
            Size := Landin.Targets.Byte_Count (Landin.Targets.Bytes (Held));
            Alignment := Landin.Targets.Alignment_Of (Facts, Held);
         end;
      end if;
   end Measurement_Extent;

   function Measurement_Answer
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Value   : Landin.IR.Value_Id;
      Facts   : Landin.Targets.Target_Facts)
      return Landin.Targets.Byte_Count
   is
      use type Landin.IR.Opcode;
   begin
      if Landin.IR.Op_Of (Of_Unit, Item, Value) = Landin.IR.Measure_Offset
      then
         declare
            Path : constant Landin.IR.Path_Step_Array :=
              Landin.IR.Path_Of (Of_Unit, Item, Value);
            First : constant Positive := Positive (Path (Path'First).Field);
            Placed : constant Layout.Plan :=
              Measurement_Layout (Of_Unit, Item, Value, Facts);
            Cache : IR.Shape_Measurement.Layout_Cache;
         begin
            return Placed.Offsets (First)
              + Path_Offset
                  (Of_Unit,
                   Landin.IR.Nth_Measurement_Field
                     (Of_Unit, Item, Value, First),
                   Path (Path'First + 1 .. Path'Last), Facts, Cache);
         end;
      end if;
      declare
         Size : Landin.Targets.Byte_Count;
         Alignment : Landin.Targets.Byte_Alignment;
      begin
         Measurement_Extent (Of_Unit, Item, Value, Facts, Size, Alignment);
         return (if Landin.IR.Op_Of (Of_Unit, Item, Value)
                      = Landin.IR.Measure_Align
                 then Landin.Targets.Byte_Count (Alignment) else Size);
      end;
   end Measurement_Answer;

   ------------------------------------------------------------------
   --  An aggregate cell
   ------------------------------------------------------------------

   procedure Aggregate_Extent
     (Of_Unit   : Landin.IR.Unit;
      Item      : Landin.IR.Item_Id;
      Slot      : Landin.IR.Slot_Id;
      Facts     : Landin.Targets.Target_Facts;
      Size      : out Landin.Targets.Byte_Count;
      Alignment : out Landin.Targets.Byte_Alignment)
   is
   begin
      if Landin.IR.Is_Array (Of_Unit, Item, Slot) then
         declare
            Element_Size : Landin.Targets.Byte_Count;
            Element_Alignment : Landin.Targets.Byte_Alignment;
         begin
            Field_Extent
              (Of_Unit,
               Landin.IR.Slot_Array_Element_Shape (Of_Unit, Item, Slot),
               Facts, Element_Size, Element_Alignment);
            Repeat_Extent
              (IR.Slot_Array_Length (Of_Unit, Item, Slot), Facts,
               Element_Size, Element_Alignment);
            Size := Element_Size;
            Alignment := Element_Alignment;
         end;
      else
         declare
            Placed : constant Layout.Plan :=
              Slot_Layout (Of_Unit, Item, Slot, Facts);
         begin
            Size := Placed.Size;
            Alignment := Placed.Alignment;
         end;
      end if;
   end Aggregate_Extent;

   function Field_Offset
     (Of_Unit  : Landin.IR.Unit;
      Item     : Landin.IR.Item_Id;
      Of_Frame : Frame;
      Slot     : Landin.IR.Slot_Id;
      Field    : Landin.IR.Part_Position;
      Facts    : Landin.Targets.Target_Facts)
     return Landin.Targets.Byte_Count
   is
      Offset : Landin.Targets.Byte_Count;
   begin
      if Landin.IR.Is_Array (Of_Unit, Item, Slot) then
         declare
            Element_Size : Landin.Targets.Byte_Count;
            Element_Alignment : Landin.Targets.Byte_Alignment;
         begin
            Field_Extent
              (Of_Unit,
               Landin.IR.Slot_Array_Element_Shape (Of_Unit, Item, Slot),
               Facts, Element_Size, Element_Alignment);
            Offset :=
              Landin.Targets.Byte_Count
                (Landin.IR.Element_Total (Field) - 1)
              * Element_Size;
         end;
      else
         declare
            First : constant Natural := Of_Frame.Slot_Fields (Positive (Slot));
         begin
            Offset := (if First = 0
                       then Slot_Layout (Of_Unit, Item, Slot, Facts).Offsets
                         (Positive (Field))
                       else Of_Frame.Field_Offsets
                         (First + Positive (Field) - 1));
         end;
      end if;
      return Slot_Offset (Of_Frame, Slot) - Offset;
   end Field_Offset;

   ------------------------------------------------------------------
   --  Laid_Out
   ------------------------------------------------------------------

   function Laid_Out
     (Of_Unit : IR.Unit;
      Item    : IR.Item_Id;
      Facts   : Targets.Target_Facts;
      Slots   : Home_Mask;
      Values  : Spill_Assignments;
      Spills  : Layout.Field_Extent_Array;
      Saves   : Layout.Field_Extent_Array;
      Maximum : Targets.Byte_Count := Targets.Byte_Count'Last) return Frame
   is
      Built : Frame;
      Below : Targets.Byte_Count := 0;
      Limit : constant Targets.Byte_Count := Targets.Byte_Count'Min
        (Maximum, Targets.Maximum_Object_Size (Facts));

      function Placed
        (Size : Targets.Byte_Count; Alignment : Targets.Byte_Alignment)
         return Targets.Byte_Count;

      function Placed
        (Size : Targets.Byte_Count; Alignment : Targets.Byte_Alignment)
         return Targets.Byte_Count
      is
      begin
         if not Targets.Is_Power_Of_Two (Alignment)
           or else Targets.Stack_Alignment (Facts) mod Alignment /= 0
         then
            raise Compiler_Defect with "a frame home exceeds stack alignment";
         end if;
         Below := Stack_Align
           (Stack_Add (Below, Size, Limit), Alignment, Limit);
         return Below;
      end Placed;

   begin
      if not IR.Holds (Of_Unit, Item)
        or else not Targets.Frame_Pointer (Facts)
      then
         raise Compiler_Defect with "a frame needs an item and frame pointer";
      end if;
      if Slots'First /= 1 or else Values'First /= 1
        or else Spills'First /= 1 or else Saves'First /= 1
        or else Slots'Length /= IR.Slot_Count (Of_Unit, Item)
        or else Values'Length /= IR.Value_Count (Of_Unit, Item)
      then
         raise Compiler_Defect with "frame storage runs disagree with the IR";
      end if;

      for Index in Slots'Range loop
         declare
            Slot : constant IR.Slot_Id := IR.Slot_Id (Index);
         begin
            Built.Slot_Homes.Append (Slots (Index));
            Built.Slot_Fields.Append (0);
            if not Slots (Index) then
               Built.Slots.Append (0);
            elsif IR.Is_Aggregate (Of_Unit, Item, Slot)
            then
               declare
                  Placed_Fields : constant Layout.Plan :=
                    Slot_Layout (Of_Unit, Item, Slot, Facts);
               begin
                  Built.Slot_Fields.Replace_Element
                    (Index, Natural (Built.Field_Offsets.Length) + 1);
                  for Offset of Placed_Fields.Offsets loop
                     Built.Field_Offsets.Append (Offset);
                  end loop;
                  Built.Slots.Append
                    (Placed (Placed_Fields.Size, Placed_Fields.Alignment));
               end;
            elsif IR.Is_Array (Of_Unit, Item, Slot)
            then
               declare
                  Size : Targets.Byte_Count;
                  Alignment : Targets.Byte_Alignment;
               begin
                  Aggregate_Extent
                    (Of_Unit, Item, Slot, Facts, Size, Alignment);
                  Built.Slots.Append (Placed (Size, Alignment));
               end;
            else
               declare
                  Held : constant Targets.Scalar_Size :=
                    Size_Of (IR.Type_Of (Of_Unit, Item, Slot), Facts);
               begin
                  Built.Slots.Append
                    (Placed (Targets.Byte_Count (Targets.Bytes (Held)),
                             Targets.Alignment_Of (Facts, Held)));
               end;
            end if;
         end;
      end loop;

      for Home of Spills loop
         Built.Spills.Append (Placed (Home.Size, Home.Alignment));
         Built.Spill_Total := Built.Spill_Total + Home.Size;
      end loop;
      for Home of Saves loop
         Built.Saves.Append (Placed (Home.Size, Home.Alignment));
         Built.Save_Total := Built.Save_Total + Home.Size;
      end loop;

      for Index in Values'Range loop
         declare
            Home : constant Natural := Values (Index);
            Held : constant Landin.Types.Type_Kind :=
              IR.Result_Of (Of_Unit, Item, IR.Value_Id (Index));
         begin
            if Home = 0 then
               Built.Values.Append (0);
            else
               if Home > Spills'Length
                 or else Held not in Landin.Types.Scalar_Name
               then
                  raise Compiler_Defect with "a value names no scalar spill";
               end if;
               declare
                  Size : constant Targets.Scalar_Size := Size_Of (Held, Facts);
               begin
                  if Spills (Home).Size
                       < Targets.Byte_Count (Targets.Bytes (Size))
                    or else Spills (Home).Alignment
                       < Targets.Alignment_Of (Facts, Size)
                  then
                     raise Compiler_Defect with
                       "a spill cannot hold its value";
                  end if;
               end;
               Built.Values.Append (Built.Spills (Home));
            end if;
         end;
      end loop;
      Built.Size := Stack_Align
        (Below, Targets.Stack_Alignment (Facts), Limit);
      return Built;
   end Laid_Out;

   function Reference_Frame
     (Of_Unit : IR.Unit;
      Item    : IR.Item_Id;
      Facts   : Targets.Target_Facts;
      Maximum : Targets.Byte_Count;
      Saves   : Natural) return Frame;

   function Laid_Out
     (Of_Unit : IR.Unit;
      Item    : IR.Item_Id;
      Facts   : Targets.Target_Facts;
      Maximum : Targets.Byte_Count := Targets.Byte_Count'Last) return Frame
     is (Reference_Frame (Of_Unit, Item, Facts, Maximum, 0));

   function Laid_Out
     (Of_Unit : IR.Unit;
      Item    : IR.Item_Id;
      Facts   : Targets.Target_Facts;
      Maximum : Targets.Byte_Count;
      Saves   : Positive) return Frame
     is (Reference_Frame (Of_Unit, Item, Facts, Maximum, Saves));

   function Reference_Frame
     (Of_Unit : IR.Unit;
      Item    : IR.Item_Id;
      Facts   : Targets.Target_Facts;
      Maximum : Targets.Byte_Count;
      Saves   : Natural) return Frame
   is
      package Mask_Buffers is new Work_Arrays (Boolean, Home_Mask, True);
      package Value_Buffers is new Work_Arrays
        (Natural, Spill_Assignments, 0);
      package Extent_Buffers is new Work_Arrays
        (Layout.Field_Extent, Layout.Field_Extent_Array, (0, 1));
      Slot_Data : Mask_Buffers.Buffer (IR.Slot_Count (Of_Unit, Item));
      Value_Data : Value_Buffers.Buffer (IR.Value_Count (Of_Unit, Item));
      Spill_Data : Extent_Buffers.Buffer (IR.Value_Count (Of_Unit, Item));
      Slots : Home_Mask renames Slot_Data.Data.all;
      Values : Spill_Assignments renames Value_Data.Data.all;
      Spills : Layout.Field_Extent_Array renames Spill_Data.Data.all;
      Count : Natural := 0;
   begin
      --  The explicit reference plan assigns each scalar its own home in
      --  instruction order.  Storage placement is otherwise exactly shared.
      for Index in Values'Range loop
         declare
            Held : constant Landin.Types.Type_Kind :=
              IR.Result_Of (Of_Unit, Item, IR.Value_Id (Index));
         begin
            if Held in Landin.Types.Scalar_Name then
               declare
                  Size : constant Targets.Scalar_Size := Size_Of (Held, Facts);
               begin
                  Count := Count + 1;
                  Values (Index) := Count;
                  Spills (Count) :=
                    (Targets.Byte_Count (Targets.Bytes (Size)),
                     Targets.Alignment_Of (Facts, Size));
               end;
            end if;
         end;
      end loop;
      return Laid_Out
        (Of_Unit, Item, Facts, Slots, Values, Spills (1 .. Count),
         Layout.Field_Extent_Array'(1 .. Saves => (8, 8)), Maximum);
   end Reference_Frame;

   ------------------------------------------------------------------
   --  Reading one back
   ------------------------------------------------------------------

   function Spill_Bytes (Of_Frame : Frame) return Targets.Byte_Count
     is (Of_Frame.Spill_Total);

   function Spill_Count (Of_Frame : Frame) return Natural
     is (Natural (Of_Frame.Spills.Length));

   function Save_Bytes (Of_Frame : Frame) return Targets.Byte_Count
     is (Of_Frame.Save_Total);

   function Has_Slot_Home
     (Of_Frame : Frame; Slot : IR.Slot_Id) return Boolean
   is
      use type IR.Slot_Id;
   begin
      if Slot = IR.No_Slot
        or else Natural (Slot) > Natural (Of_Frame.Slot_Homes.Length)
      then
         raise Compiler_Defect with "no such frame slot";
      end if;
      return Of_Frame.Slot_Homes (Positive (Slot));
   end Has_Slot_Home;

   function Has_Value_Home
     (Of_Frame : Frame; Value : IR.Value_Id) return Boolean
     is (Value_Offset (Of_Frame, Value) /= 0);

   function Spill_Offset
     (Of_Frame : Frame; Home : Positive) return Targets.Byte_Count
   is
   begin
      if Home > Natural (Of_Frame.Spills.Length) then
         raise Compiler_Defect with "no such frame spill home";
      end if;
      return Of_Frame.Spills (Home);
   end Spill_Offset;

   function Save_Offset
     (Of_Frame : Frame; Home : Positive) return Targets.Byte_Count
   is
   begin
      if Home > Natural (Of_Frame.Saves.Length) then
         raise Compiler_Defect with "no such frame save home";
      end if;
      return Of_Frame.Saves (Home);
   end Save_Offset;

   function Extent (Of_Frame : Frame) return Landin.Targets.Byte_Count
     is (Of_Frame.Size);

   function Slot_Offset
     (Of_Frame : Frame; Slot : Landin.IR.Slot_Id)
     return Landin.Targets.Byte_Count
   is
      use type Landin.IR.Slot_Id;
   begin
      if Slot = Landin.IR.No_Slot
        or else Natural (Slot) > Natural (Of_Frame.Slots.Length)
      then
         raise Compiler_Defect with "no cell was laid out for this slot";
      end if;

      return Of_Frame.Slots (Positive (Slot));
   end Slot_Offset;

   function Value_Offset
     (Of_Frame : Frame; Value : Landin.IR.Value_Id)
     return Landin.Targets.Byte_Count
   is
      use type Landin.IR.Value_Id;
   begin
      if Value = Landin.IR.No_Value
        or else Natural (Value) > Natural (Of_Frame.Values.Length)
      then
         raise Compiler_Defect with "no cell was laid out for this value";
      end if;

      return Of_Frame.Values (Positive (Value));
   end Value_Offset;

   function Ranked (Of_Unit : Landin.IR.Unit) return Atom_Codes is
      Limit : Natural := 0;
      Result : Atom_Codes;
      Next : Natural := 0;
   begin
      for Set in 1 .. IR.Atom_Set_Count (Of_Unit) loop
         for Index in 1 .. IR.Atom_Count (Of_Unit, IR.Atom_Set_Id (Set)) loop
            Limit := Natural'Max
              (Limit, Natural (IR.Nth_Atom
                 (Of_Unit, IR.Atom_Set_Id (Set), Index)));
         end loop;
      end loop;
      Result.Codes.Set_Length (Ada.Containers.Count_Type (Limit));
      for Position in 1 .. Limit loop
         Result.Codes (Position) := 0;
      end loop;
      for Set in 1 .. IR.Atom_Set_Count (Of_Unit) loop
         for Index in 1 .. IR.Atom_Count (Of_Unit, IR.Atom_Set_Id (Set)) loop
            Result.Codes (Positive (IR.Nth_Atom
              (Of_Unit, IR.Atom_Set_Id (Set), Index))) := 1;
         end loop;
      end loop;
      for Position in 1 .. Limit loop
         if Result.Codes (Position) /= 0 then
            Next := Next + 1;
            Result.Codes (Position) := Next;
         end if;
      end loop;
      return Result;
   end Ranked;

   function Atom_Code
     (Of_Codes : Atom_Codes; Identity : Landin.IR.Declaration_Id)
      return Positive
   is
   begin
      if Identity = IR.No_Declaration
        or else Natural (Identity) > Natural (Of_Codes.Codes.Length)
        or else Of_Codes.Codes (Positive (Identity)) = 0
      then
         raise Compiler_Defect with
           "an atom instruction names no atom-set member";
      end if;
      return Of_Codes.Codes (Positive (Identity));
   end Atom_Code;

   function Runs_Of
     (Of_Unit  : Landin.IR.Unit;
      Of_Codes : Atom_Codes;
      Set      : Landin.IR.Atom_Set_Id) return Code_Runs
   is
      Count : constant Natural := IR.Atom_Count (Of_Unit, Set);
      Codes : array (1 .. Count) of Positive;
      Runs  : Code_Runs (1 .. Count) := [others => (Low => 1, High => 1)];
      Last  : Natural := 0;
   begin
      for Index in 1 .. Count loop
         Codes (Index) :=
           Atom_Code (Of_Codes, IR.Nth_Atom (Of_Unit, Set, Index));
      end loop;
      --  Insertion sort: a set is small, or already nearly in order.
      for Index in 2 .. Count loop
         declare
            Held : constant Positive := Codes (Index);
            At_Index : Natural := Index - 1;
         begin
            while At_Index >= 1 and then Codes (At_Index) > Held loop
               Codes (At_Index + 1) := Codes (At_Index);
               At_Index := At_Index - 1;
            end loop;
            Codes (At_Index + 1) := Held;
         end;
      end loop;
      for Code of Codes loop
         if Last > 0 and then Code <= Runs (Last).High + 1 then
            Runs (Last).High := Positive'Max (Runs (Last).High, Code);
         else
            Last := Last + 1;
            Runs (Last) := (Low => Code, High => Code);
         end if;
      end loop;
      return Runs (1 .. Last);
   end Runs_Of;

   procedure Add (Into : in out Spelling_Counts; Spelling : String) is
      Found : constant Spelling_Maps.Cursor := Into.Held.Find (Spelling);
   begin
      if Spelling_Maps.Has_Element (Found) then
         Into.Held.Replace_Element (Found, Spelling_Maps.Element (Found) + 1);
      else
         Into.Held.Insert (Spelling, 1);
      end if;
   end Add;

   function Is_Exported
     (Of_Unit        : Landin.IR.Unit;
      Meanings       : Landin.Resolution.Table;
      Item           : Landin.IR.Item_Id;
      Hosted_Entry   : Landin.IR.Item_Id;
      Firmware_Entry : Landin.IR.Item_Id := Landin.IR.No_Item)
      return Boolean
   is
      use type Landin.Machine.Convention;
      use type Landin.Machine.Placement;
      use type Landin.IR.Signature_Id;
      use type Landin.Source.Names.Name_Id;
      Declared : constant Landin.IR.Declaration_Id :=
        Landin.IR.Declares (Of_Unit, Item);
      Signature : constant Landin.IR.Signature_Id :=
        Landin.IR.Signature_Of (Of_Unit, Item);
      Default : constant Landin.Machine.Placement := (others => <>);
   begin
      return Item = Hosted_Entry
        or else (Firmware_Entry /= Landin.IR.No_Item
                 and then Item = Firmware_Entry)
        or else Landin.IR.Is_External (Of_Unit, Item)
        or else Landin.IR.Link_Symbol (Of_Unit, Item)
          /= Landin.Source.Names.No_Name
        or else Landin.IR.Placement_Of (Of_Unit, Item) /= Default
        or else (Declared /= Landin.IR.No_Declaration
                 and then Landin.Resolution.Is_Public (Meanings, Declared)
                 and then Signature /= Landin.IR.No_Signature
                 and then Landin.IR.Signature_Machine (Of_Unit, Signature)
                   /= Landin.Machine.Ordinary);
   end Is_Exported;

   function Qualified_Symbol
     (Meanings : Landin.Resolution.Table;
      Declared : Landin.IR.Declaration_Id;
      Spelling : String) return String
   is
      Path : String := Landin.Resolution.Module_Path_Of (Meanings, Declared);
   begin
      for C of Path loop
         if C = '/' then
            C := '.';
         end if;
      end loop;
      return (if Path = "" then "main" else Path) & "." & Spelling;
   end Qualified_Symbol;

   function Symbol_Declaration
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id) return Landin.IR.Declaration_Id
   is
      Declared : constant Landin.IR.Declaration_Id :=
        Landin.IR.Declares (Of_Unit, Item);
   begin
      if Declared /= Landin.IR.No_Declaration then
         return Declared;
      elsif Landin.IR.Generic_Template_Of (Of_Unit, Item)
        /= Landin.IR.No_Declaration
      then
         return Landin.IR.Generic_Template_Of (Of_Unit, Item);
      end if;
      return Landin.IR.Named_After (Of_Unit, Item);
   end Symbol_Declaration;

   procedure Remove (Into : in out Spelling_Counts; Spelling : String) is
      Found : Spelling_Maps.Cursor := Into.Held.Find (Spelling);
   begin
      if Spelling_Maps.Element (Found) = 1 then
         Into.Held.Delete (Found);
      else
         Into.Held.Replace_Element (Found, Spelling_Maps.Element (Found) - 1);
      end if;
   end Remove;

   function Count
     (Of_Counts : Spelling_Counts; Spelling : String) return Natural
   is
      Found : constant Spelling_Maps.Cursor := Of_Counts.Held.Find (Spelling);
   begin
      return (if Spelling_Maps.Has_Element (Found)
              then Spelling_Maps.Element (Found) else 0);
   end Count;

   function Assembly_Registers
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Value   : Landin.IR.Value_Id;
      Names   : Landin.Source.Names.Table;
      Facts   : Landin.Targets.Target_Facts)
      return Landin.Targets.Assembly.Operand_Register_Array
   is
      use type Landin.Source.Names.Name_Id;
      Result : Landin.Targets.Assembly.Operand_Register_Array
        (1 .. Landin.IR.Assembly_Operand_Count (Of_Unit, Item, Value));
   begin
      for Index in Result'Range loop
         declare
            Operand : constant Landin.IR.Assembly_Operand :=
              Landin.IR.Nth_Assembly_Operand (Of_Unit, Item, Value, Index);
         begin
            Result (Index) :=
              (Name => Ada.Strings.Unbounded.To_Unbounded_String
                 (if Operand.Name = Landin.Source.Names.No_Name then ""
                  else Landin.Source.Names.Spelling (Names, Operand.Name)),
               Register => Ada.Strings.Unbounded.To_Unbounded_String
                 (Landin.IR.Register_Of (Operand)),
               Bits => (if Operand.Kind in Landin.Types.Integer_Name
                        then Landin.Types.Width (Operand.Kind, Facts)
                        else Landin.Targets.Assembly.Register_Width (Facts)));
         end;
      end loop;
      Landin.Targets.Assembly.Choose
        (Facts, Landin.Source.Names.Spelling
           (Names, Landin.IR.Assembly_Text (Of_Unit, Item, Value)), Result);
      return Result;
   end Assembly_Registers;

   function Assembly_Text
     (Of_Unit : Landin.IR.Unit;
      Item    : Landin.IR.Item_Id;
      Value   : Landin.IR.Value_Id;
      Names   : Landin.Source.Names.Table;
      Facts   : Landin.Targets.Target_Facts) return String
     is (Landin.Targets.Assembly.Substituted
           (Facts, Landin.Source.Names.Spelling
              (Names, Landin.IR.Assembly_Text (Of_Unit, Item, Value)),
            Assembly_Registers (Of_Unit, Item, Value, Names, Facts)));

   procedure Count_Uses
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Uses : out Use_Counts;
      References : out Use_Counts)
   is
      use type Landin.IR.Slot_Id;
      Has_Assembly : Boolean := False;

      procedure Count (Slot : Landin.IR.Slot_Id);
      procedure Count (Place : Landin.IR.Storage);

      procedure Count (Slot : Landin.IR.Slot_Id) is
      begin
         if Slot /= Landin.IR.No_Slot then
            References (Positive (Slot)) := References (Positive (Slot)) + 1;
         end if;
      end Count;

      procedure Count (Place : Landin.IR.Storage) is
      begin
         case Place.Kind is
            when Landin.IR.Frame_Slot => Count (Place.Slot);
            when Landin.IR.Runtime_Address => Count (Place.Address);
            when Landin.IR.Module_Datum => null;
         end case;
      end Count;
   begin
      Uses := [others => 0];
      References := [others => 0];
      for Index in Uses'Range loop
         declare
            Value : constant Landin.IR.Value_Id := Landin.IR.Value_Id (Index);
         begin
            for Position in 1 .. Landin.IR.Operand_Count
              (Of_Unit, Item, Value)
            loop
               declare
                  Operand : constant Positive := Positive
                    (Landin.IR.Nth_Operand (Of_Unit, Item, Value, Position));
               begin
                  Uses (Operand) := Uses (Operand) + 1;
               end;
            end loop;
            case Landin.IR.Op_Of (Of_Unit, Item, Value) is
               when Landin.IR.Load | Landin.IR.Store =>
                  Count (Landin.IR.Slot_Of (Of_Unit, Item, Value));
               when Landin.IR.Load_Field | Landin.IR.Store_Field
                  | Landin.IR.Load_Element | Landin.IR.Store_Element =>
                  if Landin.IR.Reaches_A_Slot (Of_Unit, Item, Value) then
                     Count (Landin.IR.Slot_Of (Of_Unit, Item, Value));
                  end if;
               when Landin.IR.Copy_Array | Landin.IR.Copy_Variant =>
                  Count (Landin.IR.Source_Of (Of_Unit, Item, Value));
                  Count (Landin.IR.Destination_Of (Of_Unit, Item, Value));
               when Landin.IR.Load_Variant_Tag
                  | Landin.IR.Load_Variant_Field =>
                  Count (Landin.IR.Source_Of (Of_Unit, Item, Value));
               when Landin.IR.Storage_Address | Landin.IR.Place_Address
                  | Landin.IR.Clear_Array | Landin.IR.Fill_Array
                  | Landin.IR.Select_Variant
                  | Landin.IR.Store_Variant_Field =>
                  Count (Landin.IR.Destination_Of (Of_Unit, Item, Value));
               when Landin.IR.Call | Landin.IR.Indirect_Call =>
                  Count (Landin.IR.Failure_Slot_Of (Of_Unit, Item, Value));
               when Landin.IR.Assembly =>
                  Has_Assembly := True;
               when others => null;
            end case;
         end;
      end loop;
      if Has_Assembly then
         for Slot in References'Range loop
            References (Slot) := References (Slot) + 2;
         end loop;
      end if;
   end Count_Uses;

   --  Whether Through is an indirect access by Carried, its one use.
   function Accesses
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Through, Carried : Landin.IR.Value_Id;
      Uses : Use_Counts) return Boolean;

   function Fold_Of
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Block : Landin.IR.Block_Id;
      Position : Positive;
      Uses : Use_Counts;
      References : Use_Counts) return Address_Fold
   is
      use type Landin.IR.Value_Id;
      Value : constant Landin.IR.Value_Id :=
        Landin.IR.Nth_Value (Of_Unit, Item, Block, Position);
   begin
      if Position < Landin.IR.Length (Of_Unit, Item, Block)
        and then Uses (Positive (Value)) = 1
      then
         declare
            Next : constant Landin.IR.Value_Id :=
              Landin.IR.Nth_Value (Of_Unit, Item, Block, Position + 1);
            Pair : constant Address_Fold :=
              Carried (Of_Unit, Item, Block, Position + 1, Uses, References);
         begin
            if Accesses (Of_Unit, Item, Next, Value, Uses) then
               return (Access_Value => Next, others => <>);
            elsif Pair.Access_Value /= Landin.IR.No_Value
              and then Landin.IR.Nth_Operand (Of_Unit, Item, Next, 1) = Value
            then
               return Pair;
            end if;
         end;
      end if;
      return (others => <>);
   end Fold_Of;

   function Accesses
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Through, Carried : Landin.IR.Value_Id;
      Uses : Use_Counts) return Boolean
   is
      use type Landin.IR.Opcode;
      use type Landin.IR.Value_Id;
   begin
      return Through /= Landin.IR.No_Value
        and then Uses (Positive (Carried)) = 1
        and then Landin.IR.Op_Of (Of_Unit, Item, Through)
          in Landin.IR.Load_Indirect | Landin.IR.Store_Indirect
        and then Landin.IR.Nth_Operand (Of_Unit, Item, Through, 1) = Carried;
   end Accesses;

   function Carried
     (Of_Unit : Landin.IR.Unit;
      Item : Landin.IR.Item_Id;
      Block : Landin.IR.Block_Id;
      Position : Positive;
      Uses : Use_Counts;
      References : Use_Counts) return Address_Fold
   is
      use type Landin.IR.Opcode;
      use type Landin.IR.Slot_Id;
      Length : constant Natural := Landin.IR.Length (Of_Unit, Item, Block);
      Store : constant Landin.IR.Value_Id :=
        Landin.IR.Nth_Value (Of_Unit, Item, Block, Position);
   begin
      if Position + 2 > Length
        or else Landin.IR.Op_Of (Of_Unit, Item, Store) /= Landin.IR.Store
      then
         return (others => <>);
      end if;
      declare
         Load : constant Landin.IR.Value_Id :=
           Landin.IR.Nth_Value (Of_Unit, Item, Block, Position + 1);
         Through : constant Landin.IR.Value_Id :=
           Landin.IR.Nth_Value (Of_Unit, Item, Block, Position + 2);
         Slot : constant Landin.IR.Slot_Id :=
           Landin.IR.Slot_Of (Of_Unit, Item, Store);
      begin
         if Landin.IR.Op_Of (Of_Unit, Item, Load) = Landin.IR.Load
           and then Landin.IR.Slot_Of (Of_Unit, Item, Load) = Slot
           and then Landin.IR.Is_Address (Of_Unit, Item, Slot)
           and then Landin.IR.Declares (Of_Unit, Item, Slot)
             = Landin.IR.No_Declaration
           and then References (Positive (Slot)) = 2
           and then Accesses (Of_Unit, Item, Through, Load, Uses)
         then
            return (Access_Value => Through, Store => Store, Load => Load);
         end if;
      end;
      return (others => <>);
   end Carried;

end Landin.Backend;
