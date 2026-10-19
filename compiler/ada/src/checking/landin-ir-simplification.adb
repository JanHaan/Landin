with Ada.Containers.Generic_Array_Sort;
with Ada.Containers.Vectors;
with Ada.Finalization;
with Ada.Unchecked_Deallocation;
with System.Storage_Elements;
with Interfaces;
with Landin.IR.Control_Flow;
with Landin.IR.Dominance;
with Landin.IR.Effects;
with Landin.IR.Rewriting;
with Landin.IR.Scalar_Replacement;
with Landin.IR.Shape_Measurement;
with Landin.IR.Verifier;
with Landin.Source.Names;
with Landin.Targets.Layouts;

package body Landin.IR.Simplification is
   use type Interfaces.Unsigned_64;
   use type System.Storage_Elements.Storage_Count;
   use type Landin.Optimization.Objective;
   use type Landin.Targets.Bit_Width;
   subtype Bits is Interfaces.Unsigned_64;
   subtype Integer_Value is Landin.Types.Folded;

   function Checked_Scratch_Bytes
     (Count : Natural; Width : System.Storage_Elements.Storage_Count)
      return System.Storage_Elements.Storage_Count;

   function Checked_Scratch_Bytes
     (Count : Natural; Width : System.Storage_Elements.Storage_Count)
      return System.Storage_Elements.Storage_Count
   is
      use System.Storage_Elements;
   begin
      if Width /= 0 and then Storage_Count (Count)
        > Storage_Count'Last / Width
      then
         raise Storage_Error with
           "simplifier scratch size is not representable";
      end if;
      return Storage_Count (Count) * Width;
   end Checked_Scratch_Bytes;

   generic
      type Element is private;
      Initial : Element;
   package Scratch_Arrays is
      type Elements is array (Positive range <>) of Element;
      type Elements_Access is access Elements;
      type Owner is new Ada.Finalization.Limited_Controlled with record
         Data : Elements_Access := null;
      end record;
      overriding procedure Finalize (Value : in out Owner);
      function Create (Count : Natural) return Owner;
   end Scratch_Arrays;

   package body Scratch_Arrays is
      procedure Free is new Ada.Unchecked_Deallocation
        (Object => Elements, Name => Elements_Access);

      overriding procedure Finalize (Value : in out Owner) is
      begin
         Free (Value.Data);
      end Finalize;

      function Create (Count : Natural) return Owner is
         Bytes : constant System.Storage_Elements.Storage_Count :=
           Checked_Scratch_Bytes
             (Count, Element'Object_Size / System.Storage_Unit);
      begin
         pragma Unreferenced (Bytes);
         return Result : Owner do
            --  Initialize in owned heap storage, without an input-sized
            --  aggregate or return temporary on the compiler's stack.
            Result.Data := new Elements (1 .. Count);
            for Held of Result.Data.all loop
               Held := Initial;
            end loop;
         end return;
      end Create;
   end Scratch_Arrays;

   package Flags is new Scratch_Arrays (Boolean, False);
   package Values is new Scratch_Arrays (Value_Id, No_Value);
   package Indices is new Scratch_Arrays (Positive, 1);
   package Numbers is new Scratch_Arrays (Integer_Value, 0);

   --  A module datum's static value, worked out once on demand.
   type Datum_State is (Unseen, Running, Static, Dynamic);
   package Datum_States is new Scratch_Arrays (Datum_State, Unseen);
   package Counts is new Scratch_Arrays (Natural, 0);

   --  What the proof of a check knows a value to equal besides itself: a
   --  constant, one part of a slot nothing in the routine writes, or the
   --  content an eligible slot had when the current block was entered.
   type Term_Kind is (No_Term, Constant_Term, Fixed_Term, Entry_Term);

   type Term is record
      Kind : Term_Kind := No_Term;
      Number : Integer_Value := 0;
      Slot : Slot_Id := No_Slot;
      Part : Natural := 0;
   end record;

   --  A slot's content is below, or above, Limit; strictly or not.  The
   --  limit may be a value no term names, which still bounds the content
   --  by its type.
   type Bound is record
      Present : Boolean := False;
      Limit : Term;
      Strict : Boolean := False;
   end record;

   --  Left < Right, or Left <= Right, on the edge into a block.
   type Relation is record
      Present : Boolean := False;
      Left, Right : Term;
      Strict : Boolean := False;
   end record;

   type Edge_Relations is record
      First, Second : Relation;
   end record;

   package Terms is new Scratch_Arrays (Term, (others => <>));
   package Bounds is new Scratch_Arrays (Bound, (others => <>));
   package Edges is new Scratch_Arrays (Edge_Relations, (others => <>));

   type Relation_Array is array (Positive range <>) of Relation;
   type Storage_Array is array (Positive range <>) of Storage;
   package Highs is new Scratch_Arrays
     (Integer_Value, Integer_Value'Last);
   procedure Sort is new Ada.Containers.Generic_Array_Sort
     (Positive, Natural, Counts.Elements);

   function Same_Term (Left, Right : Term) return Boolean
     is (Left.Kind /= No_Term and then Left = Right);

   --  The slot a term says a value holds, whose bounds a fact can carry.
   function Subject (Of_Term : Term) return Slot_Id
     is (if Of_Term.Kind = Entry_Term
           or else (Of_Term.Kind = Fixed_Term and then Of_Term.Part = 0)
         then Of_Term.Slot else No_Slot);

   function Lowest
     (Kind : Landin.Types.Integer_Name; Facts : Landin.Targets.Target_Facts)
      return Integer_Value;
   function Highest
     (Kind : Landin.Types.Integer_Name; Facts : Landin.Targets.Target_Facts)
      return Integer_Value;

   function Pattern (Value : Integer_Value) return Bits
     is (if Value < 0 then 0 - Bits (-Value) else Bits (Value));

   function Mask (Width : Positive) return Bits
     is (if Width = 64 then Bits'Last else 2 ** Width - 1);

   function Signed_Value
     (Value : Bits; Width : Positive; Signed : Boolean) return Integer_Value;

   function Signed_Value
     (Value : Bits; Width : Positive; Signed : Boolean) return Integer_Value
   is
      Kept : constant Bits := Value and Mask (Width);
   begin
      if Signed and then (Kept and 2 ** (Width - 1)) /= 0 then
         return -Integer_Value (((not Kept) and Mask (Width)) + 1);
      else
         return Integer_Value (Kept);
      end if;
   end Signed_Value;

   --  The value numbering table of a routine: a power of two at least
   --  twice its values, so that probing always finds a free entry.
   function Table_Size (Count : Natural) return Positive;

   function Table_Size (Count : Natural) return Positive is
      Size : Positive := 2;
   begin
      while Size < 2 * Count loop
         Size := 2 * Size;
      end loop;
      return Size;
   end Table_Size;

   --  [1890]'s answer for one integer operation, or one comparison, over
   --  operands already known; Kind is the operands' type.  A checked
   --  operation whose answer its result type cannot hold is not known: it
   --  traps at runtime, and that trap stays.
   procedure Compute
     (Code : Instruction; Kind : Landin.Types.Integer_Name;
      A, B : Integer_Value; Facts : Landin.Targets.Target_Facts;
      Known, Is_Boolean, Truth_Result : out Boolean;
      Result : out Integer_Value);

   procedure Compute
     (Code : Instruction; Kind : Landin.Types.Integer_Name;
      A, B : Integer_Value; Facts : Landin.Targets.Target_Facts;
      Known, Is_Boolean, Truth_Result : out Boolean;
      Result : out Integer_Value)
   is
      Into_Kind : Landin.Types.Integer_Name := Kind;
      Width : Positive;
      Right : Integer_Value := B;
   begin
      Known := False;
      Is_Boolean := False;
      Truth_Result := False;
      Result := 0;
      if Code.Op in Comparison_Kind then
         Is_Boolean := True;
         Known := True;
         Truth_Result :=
           (case Code.Op is
               when Equal_To => A = B,
               when Not_Equal_To => A /= B,
               when Less_Than => A < B,
               when Less_Or_Equal => A <= B,
               when Greater_Than => A > B,
               when Greater_Or_Equal => A >= B,
               when others => False);
         return;
      elsif Code.Result not in Landin.Types.Integer_Name then
         return;
      end if;
      Into_Kind := Landin.Types.Integer_Name (Code.Result);
      Width := Positive (Landin.Types.Width (Into_Kind, Facts));
      case Code.Op is
         when Add | Subtract =>
            if Code.Op = Subtract then
               Right := -Right;
            end if;
            if Code.Unchecked then
               Result := Signed_Value
                 (Pattern (A) + Pattern (Right), Width,
                  Landin.Types.Is_Signed (Into_Kind));
               Known := True;
            elsif (Right >= 0 and then A <= Integer_Value'Last - Right)
              or else (Right < 0
                and then A >= Integer_Value'First - Right)
            then
               Result := A + Right;
               Known := True;
            end if;
         when Multiply =>
            if Code.Unchecked then
               Result := Signed_Value
                 (Pattern (A) * Pattern (B), Width,
                  Landin.Types.Is_Signed (Into_Kind));
               Known := True;
            elsif B = 0 or else
              abs A <= Integer_Value'Last / abs B
            then
               Result := A * B;
               Known := True;
            end if;
         when Negation =>
            Result := -A;
            if Code.Unchecked then
               Result := Signed_Value
                 (Pattern (Result), Width,
                  Landin.Types.Is_Signed (Into_Kind));
            end if;
            Known := True;
         when Divide | Remainder =>
            if B /= 0 then
               Result := (if Code.Op = Divide then A / B
                          else A rem B);
               Known := True;
            end if;
         when Wrapping_Add | Wrapping_Subtract
            | Wrapping_Multiply | Bitwise_And | Bitwise_Xor
            | Bitwise_Or | Complement =>
            declare
               X : constant Bits := Pattern (A);
               Y : constant Bits := Pattern (B);
               Z : constant Bits :=
                 (case Code.Op is
                     when Wrapping_Add => X + Y,
                     when Wrapping_Subtract => X - Y,
                     when Wrapping_Multiply => X * Y,
                     when Bitwise_And => X and Y,
                     when Bitwise_Xor => X xor Y,
                     when Bitwise_Or => X or Y,
                     when Complement => not X,
                     when others => 0);
            begin
               Result := Signed_Value
                 (Z, Width, Landin.Types.Is_Signed (Into_Kind));
               Known := True;
            end;
         when Shift_Left | Shift_Right =>
            if B >= 0 then
               if B >= Integer_Value (Width) then
                  Result := 0;
               elsif Code.Op = Shift_Left then
                  Result := Signed_Value
                    (Interfaces.Shift_Left
                       (Pattern (A), Natural (B)), Width,
                     Landin.Types.Is_Signed (Into_Kind));
               else
                  declare
                     X : Bits := Interfaces.Shift_Right
                       (Pattern (A), Natural (B));
                  begin
                     if A < 0 and then B > 0 then
                        X := X or not Interfaces.Shift_Right
                          (Bits'Last, Natural (B));
                     end if;
                     Result := Signed_Value
                       (X, Width, Landin.Types.Is_Signed (Into_Kind));
                  end;
               end if;
               Known := True;
            end if;
         when Conversion =>
            Result := A;
            if Code.Unchecked then
               Result := Signed_Value
                 (Pattern (A), Width,
                  Landin.Types.Is_Signed (Into_Kind));
            end if;
            Known := True;
         when Range_Check =>
            Result := A;
            Known := A >= Code.Lower_Bound
              and then A <= Code.Upper_Bound;
         when others => null;
      end case;
      Known := Known and then Landin.Types.Holds (Result, Into_Kind, Facts);
   end Compute;

   function Lowest
     (Kind : Landin.Types.Integer_Name; Facts : Landin.Targets.Target_Facts)
      return Integer_Value
   is
      Width : constant Positive :=
        Positive (Landin.Types.Width (Kind, Facts));
   begin
      return (if Landin.Types.Is_Signed (Kind)
              then -Integer_Value (Mask (Width - 1)) - 1 else 0);
   end Lowest;

   function Highest
     (Kind : Landin.Types.Integer_Name; Facts : Landin.Targets.Target_Facts)
      return Integer_Value
   is
      Width : constant Positive :=
        Positive (Landin.Types.Width (Kind, Facts));
   begin
      return Integer_Value
        (Mask (if Landin.Types.Is_Signed (Kind) then Width - 1 else Width));
   end Highest;

   procedure Run
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Objective : Landin.Optimization.Objective) is
   begin
      Verifier.Verify (Into, Facts);
      Run_On_Verified (Into, Facts, Objective);
   end Run;

   procedure Run_On_Verified
     (Into : in out Unit;
      Facts : Landin.Targets.Target_Facts;
      Objective : Landin.Optimization.Objective)
   is
      use type Landin.Source.Names.Name_Id;

      --  [0370]'s answer from the target facts a backend measures with,
      --  through the same neutral layout.
      function Measured
        (Code : Instruction; Result : out Integer_Value) return Boolean;

      function Measured
        (Code : Instruction; Result : out Integer_Value) return Boolean is
      begin
         if Code.Aggregate_Measurement then
            declare
               Fields : Field_Shape_Array (1 .. Code.Measurement_Field_Total);
            begin
               for Index in Fields'Range loop
                  Fields (Index) := Into.Measurement_Fields.Element
                    (Code.First_Measurement_Field + Index);
               end loop;
               declare
                  Placed : constant Landin.Targets.Layouts.Plan :=
                    Shape_Measurement.Fields_Layout
                      (Into, Fields, Code.Measurement_Layout, Facts,
                       Landin.Targets.Maximum_Object_Size (Facts));
               begin
                  if Code.Op = Measure_Offset then
                     --  D411: the path's first field in the run, then the
                     --  offsets of the fields below it.
                     declare
                        First : constant Positive := Positive
                          (Into.Paths.Element (Code.Nested.First + 1).Field);
                        Reached : Field_Shape := Fields (First);
                        Total : Landin.Targets.Byte_Count :=
                          Placed.Offsets (First);
                        Cache : Shape_Measurement.Layout_Cache;
                     begin
                        for Step in 2 .. Code.Nested.Count loop
                           declare
                              Field : constant Positive := Positive
                                (Into.Paths.Element
                                   (Code.Nested.First + Step).Field);
                           begin
                              Total := Landin.Targets."+"
                                (Total,
                                 Shape_Measurement
                                   .Cached_Aggregate_Field_Offset
                                     (Cache, Into, Reached, Field, Facts,
                                      Landin.Targets.Maximum_Object_Size
                                        (Facts)));
                              Reached := Nth_Aggregate_Field
                                (Into, Reached, Field);
                           end;
                        end loop;
                        Result := Integer_Value (Total);
                     end;
                  else
                     Result := (if Code.Op = Measure_Size
                                then Integer_Value (Placed.Size)
                                else Integer_Value (Placed.Alignment));
                  end if;
               end;
            end;
         else
            declare
               Held : constant Landin.Targets.Scalar_Size :=
                 Landin.Types.Storage_Size (Code.Measured, Facts);
            begin
               Result := (if Code.Op = Measure_Size
                          then Integer_Value (Landin.Targets.Bytes (Held))
                          else Integer_Value
                            (Landin.Targets.Alignment_Of (Facts, Held)));
            end;
         end if;
         return True;
      end Measured;

      Datum_At_Owner : constant Datum_States.Owner :=
        Datum_States.Create (Item_Count (Into));
      Datum_At : Datum_States.Elements renames Datum_At_Owner.Data.all;
      Datum_Value_Owner : constant Numbers.Owner :=
        Numbers.Create (Item_Count (Into));
      Datum_Value : Numbers.Elements renames Datum_Value_Owner.Data.all;

      procedure Settle (Datum : Item_Id);
      procedure Evaluate (Datum : Item_Id);

      --  A datum's static image as every backend emits it: one block of
      --  constants, measurements, other data's images, its own temporary
      --  slots and integer arithmetic, left by its Leave.  Anything else,
      --  and any cycle, leaves the datum unknown.  Every datum it reads
      --  has already settled, or is in a cycle and still running.
      procedure Settle (Datum : Item_Id) is
         Held : constant Item_Record := Into.Items.Element (Positive (Datum));
         Value_Owner : constant Numbers.Owner :=
           Numbers.Create (Held.Values.Count);
         Known_Owner : constant Flags.Owner :=
           Flags.Create (Held.Values.Count);
         Slot_Owner : constant Numbers.Owner :=
           Numbers.Create (Held.Slots.Count);
         Slot_Known_Owner : constant Flags.Owner :=
           Flags.Create (Held.Slots.Count);
         Value : Numbers.Elements renames Value_Owner.Data.all;
         Known : Flags.Elements renames Known_Owner.Data.all;
         Slot : Numbers.Elements renames Slot_Owner.Data.all;
         Slot_Known : Flags.Elements renames Slot_Known_Owner.Data.all;
         Answer : Datum_State := Dynamic;
      begin
         if Held.Kind /= IR.Datum or else Held.External
           or else Held.Has_Image
         then
            null;
         elsif Held.Has_Bool_Image then
            Datum_Value (Positive (Datum)) := Held.Bool_Image;
            Answer := Static;
         elsif Held.Result in Landin.Types.Integer_Name
           and then Held.Blocks.Count = 1
         then
            for V in 1 .. Held.Values.Count loop
               declare
                  Code : constant Instruction :=
                    Into.Code.Element (Held.Values.First + V);

                  function Argument (Position : Positive) return Positive
                    is (Positive (Into.Operands.Element
                          (Code.First_Arg + Position)));
               begin
                  case Code.Op is
                     when Number =>
                        Known (V) := Code.Result in Landin.Types.Integer_Name;
                        Value (V) := (if Code.Negated
                                      then -Integer_Value (Code.Number)
                                      else Integer_Value (Code.Number));
                     when Measurement_Kind =>
                        Known (V) := Measured (Code, Value (V));
                     when Load_Datum =>
                        Known (V) :=
                          Datum_At (Positive (Code.Named)) = Static
                          and then Code.Result in Landin.Types.Integer_Name;
                        Value (V) := Datum_Value (Positive (Code.Named));
                     when Load =>
                        Known (V) := Slot_Known (Positive (Code.Slot));
                        Value (V) := Slot (Positive (Code.Slot));
                     when Store =>
                        Slot_Known (Positive (Code.Slot)) :=
                          Known (Argument (1));
                        Slot (Positive (Code.Slot)) := Value (Argument (1));
                     when Unary_Kind | Binary_Kind | Conversion
                        | Range_Check =>
                        if Code.Args in 1 .. 2
                          and then Known (Argument (1))
                          and then (Code.Args = 1
                                    or else Known (Argument (Code.Args)))
                          and then Into.Code.Element
                            (Held.Values.First + Argument (1)).Result
                            in Landin.Types.Integer_Name
                        then
                           declare
                              Is_Boolean, Truth : Boolean;
                           begin
                              Compute
                                (Code, Landin.Types.Integer_Name
                                   (Into.Code.Element
                                      (Held.Values.First
                                       + Argument (1)).Result),
                                 Value (Argument (1)),
                                 Value (Argument (Code.Args)), Facts,
                                 Known (V), Is_Boolean, Truth, Value (V));
                              Known (V) := Known (V) and then not Is_Boolean;
                           end;
                        end if;
                     when Leave =>
                        if Code.Args = 1 and then Known (Argument (1))
                          and then Landin.Types.Holds
                            (Value (Argument (1)),
                             Landin.Types.Integer_Name (Held.Result), Facts)
                        then
                           Datum_Value (Positive (Datum)) :=
                             Value (Argument (1));
                           Answer := Static;
                        end if;
                        exit;
                     when others =>
                        exit;
                  end case;
               end;
            end loop;
         end if;
         Datum_At (Positive (Datum)) := Answer;
      end Settle;

      --  Settle a datum after every datum it reads, without recursion: a
      --  module may chain thousands of values.  A datum is running from
      --  when the data it reads are pushed above it until it settles.
      procedure Evaluate (Datum : Item_Id) is
         Pending : Item_Ref_Vectors.Vector;
      begin
         Pending.Append (Datum);
         while not Pending.Is_Empty loop
            declare
               Top : constant Item_Id := Pending.Last_Element;
               Held : constant Item_Record :=
                 Into.Items.Element (Positive (Top));
            begin
               case Datum_At (Positive (Top)) is
                  when Unseen =>
                     Datum_At (Positive (Top)) := Running;
                     if Held.Kind = IR.Datum then
                        for V in 1 .. Held.Values.Count loop
                           declare
                              Code : constant Instruction :=
                                Into.Code.Element (Held.Values.First + V);
                           begin
                              if Code.Op = Load_Datum
                                and then Datum_At (Positive (Code.Named))
                                  = Unseen
                              then
                                 Pending.Append (Code.Named);
                              end if;
                           end;
                        end loop;
                     end if;
                  when Running =>
                     Pending.Delete_Last;
                     Settle (Top);
                  when Static | Dynamic =>
                     Pending.Delete_Last;
               end case;
            end;
         end loop;
      end Evaluate;

      --  A load of a module binding [1940] that is not `mut` reads the
      --  static image every backend writes for it, and nothing writes it
      --  afterwards: the checker admits no writable reference to it.  Not
      --  one that is defined outside the program, has its own link name
      --  or is placed where a linker or the hardware may say otherwise.
      function Folded_Datum
        (Datum : Item_Id; Result : out Integer_Value) return Boolean;

      function Folded_Datum
        (Datum : Item_Id; Result : out Integer_Value) return Boolean
      is
         Held : constant Item_Record := Into.Items.Element (Positive (Datum));
      begin
         Result := 0;
         if Held.Kind /= IR.Datum or else not Held.Immutable
           or else Held.External
           or else Held.Link_Name /= Landin.Source.Names.No_Name
           or else Held.Placement.Keep or else Held.Placement.Vector /= 0
           or else Held.Placement.Section /= Landin.Source.Names.No_Name
           or else Held.Pointee /= No_Pointee
           or else Held.Signature /= No_Signature
           or else Held.Atom_Set /= No_Atom_Set
           or else Held.Result not in Landin.Types.Integer_Name
             | Landin.Types.Bool
         then
            return False;
         end if;
         if Datum_At (Positive (Datum)) = Unseen then
            Evaluate (Datum);
         end if;
         Result := Datum_Value (Positive (Datum));
         return Datum_At (Positive (Datum)) = Static;
      end Folded_Datum;

      procedure Simplify
        (Item : Item_Id; Keep : in out Rewriting.Keep_Vectors.Vector);

      procedure Simplify
        (Item : Item_Id; Keep : in out Rewriting.Keep_Vectors.Vector) is
         Held : constant Item_Record := Into.Items.Element (Positive (Item));
         Alias_Owner : constant Values.Owner :=
           Values.Create (Held.Values.Count);
         Alias : Values.Elements renames Alias_Owner.Data.all;
         Needed_Owner : constant Flags.Owner :=
           Flags.Create (Held.Values.Count);
         Needed : Flags.Elements renames Needed_Owner.Data.all;
         Required_Proof_Owner : constant Flags.Owner :=
           Flags.Create (Held.Values.Count);
         Required_Proof : Flags.Elements renames Required_Proof_Owner.Data.all;
         Eligible_Owner : constant Flags.Owner :=
           Flags.Create (Held.Slots.Count);
         Eligible : Flags.Elements renames Eligible_Owner.Data.all;
         Loaded_Owner : constant Flags.Owner :=
           Flags.Create (Held.Slots.Count);
         Loaded : Flags.Elements renames Loaded_Owner.Data.all;
         Pending_Owner : constant Values.Owner :=
           Values.Create (Held.Slots.Count);
         Pending : Values.Elements renames Pending_Owner.Data.all;
         Pending_Tracked_Owner : constant Flags.Owner :=
           Flags.Create (Held.Slots.Count);
         Pending_Tracked : Flags.Elements renames
           Pending_Tracked_Owner.Data.all;
         Pending_Slots_Owner : constant Indices.Owner :=
           Indices.Create (Held.Slots.Count);
         Pending_Slots : Indices.Elements renames Pending_Slots_Owner.Data.all;
         Stored_Owner : constant Values.Owner :=
           Values.Create (Held.Slots.Count);
         Stored : Values.Elements renames Stored_Owner.Data.all;
         Remembered_Owner : constant Indices.Owner :=
           Indices.Create (Held.Slots.Count);
         Remembered : Indices.Elements renames Remembered_Owner.Data.all;
         First_Load_Owner : constant Values.Owner :=
           Values.Create (Held.Slots.Count);
         First_Load : Values.Elements renames First_Load_Owner.Data.all;
         Class_Owner : constant Values.Owner :=
           Values.Create (Held.Values.Count);
         Class : Values.Elements renames Class_Owner.Data.all;
         Last_Write_Owner : constant Values.Owner :=
           Values.Create (Held.Slots.Count);
         Last_Write : Values.Elements renames Last_Write_Owner.Data.all;
         Exposed_Owner : constant Flags.Owner :=
           Flags.Create (Held.Slots.Count);
         Exposed : Flags.Elements renames Exposed_Owner.Data.all;
         Table_Owner : constant Values.Owner :=
           Values.Create (Table_Size (Held.Values.Count));
         Table : Values.Elements renames Table_Owner.Data.all;
         Filled_Owner : constant Indices.Owner :=
           Indices.Create (Held.Values.Count);
         Filled : Indices.Elements renames Filled_Owner.Data.all;
         Filled_Count : Natural := 0;
         Pending_Count : Natural := 0;
         Remembered_Count : Natural := 0;
         Last_Block : Block_Id := No_Block;

         procedure Forget_Pending;
         procedure Forget_Stores;
         procedure Remember
           (Slot : Slot_Id; Value : Value_Id; Is_Load : Boolean := False);

         procedure Forget_Pending is
         begin
            for Index in 1 .. Pending_Count loop
               Pending (Pending_Slots (Index)) := No_Value;
               Pending_Tracked (Pending_Slots (Index)) := False;
            end loop;
            Pending_Count := 0;
         end Forget_Pending;

         procedure Forget_Stores is
         begin
            for Index in 1 .. Remembered_Count loop
               Stored (Remembered (Index)) := No_Value;
               First_Load (Remembered (Index)) := No_Value;
            end loop;
            Remembered_Count := 0;
         end Forget_Stores;

         --  A store makes its operand the slot's value.  A load that had
         --  nothing to forward is only the first of its class: a later
         --  load of the slot is numbered the same, but keeps its own value
         --  so that no value lives longer than the code asked for.
         procedure Remember
           (Slot : Slot_Id; Value : Value_Id; Is_Load : Boolean := False) is
         begin
            if Stored (Positive (Slot)) = No_Value
              and then First_Load (Positive (Slot)) = No_Value
            then
               Remembered_Count := Remembered_Count + 1;
               Remembered (Remembered_Count) := Positive (Slot);
            end if;
            if Is_Load then
               First_Load (Positive (Slot)) := Value;
            else
               Stored (Positive (Slot)) := Value;
               First_Load (Positive (Slot)) := No_Value;
            end if;
         end Remember;

         function Code_At (Value : Value_Id) return Instruction
           is (Into.Code.Element (Held.Values.First + Positive (Value)));

         procedure Pin (Place : Storage);
         procedure Pin (Place : Storage) is
         begin
            case Place.Kind is
               when Frame_Slot =>
                  if Place.Slot /= No_Slot then
                     Eligible (Positive (Place.Slot)) := False;
                  end if;
               when Runtime_Address =>
                  if Place.Address /= No_Slot then
                     Eligible (Positive (Place.Address)) := False;
                  end if;
               when Module_Datum => null;
            end case;
         end Pin;

         function Plain (Code : Instruction) return Boolean
           is (Code.Pointee = No_Pointee
               and then Code.Signature = No_Signature
               and then Code.Atom_Set = No_Atom_Set);

         function Integer_Constant (Value : Value_Id) return Boolean
           is (Code_At (Value).Op = Number
               and then Code_At (Value).Result in Landin.Types.Integer_Name
               and then Plain (Code_At (Value)));

         function Numeric (Value : Value_Id) return Integer_Value
           is (if Code_At (Value).Negated
               then -Integer_Value (Code_At (Value).Number)
               else Integer_Value (Code_At (Value).Number));

         procedure Fold (Code : in out Instruction);
         procedure Fold (Code : in out Instruction) is
            Left, Right : Value_Id := No_Value;
            A, B, Result : Integer_Value := 0;
            Known : Boolean := False;
            Boolean_Result : Boolean := False;
            Is_Boolean : Boolean := False;
         begin
            if Code.Op in Measurement_Kind
              and then Plain (Code)
              and then Code.Result in Landin.Types.Integer_Name
            then
               Known := Measured (Code, Result)
                 and then Landin.Types.Holds
                   (Result, Landin.Types.Integer_Name (Code.Result), Facts);
            elsif Code.Op = Load_Datum and then Plain (Code) then
               Known := Folded_Datum (Code.Named, Result);
               Is_Boolean := Code.Result = Landin.Types.Bool;
               Boolean_Result := Result /= 0;
            end if;
            if not Plain (Code) or else Code.Args = 0 then
               null;
            else
               Left := Into.Operands.Element (Code.First_Arg + 1);
               if Code.Args = 2 then
                  Right := Into.Operands.Element (Code.First_Arg + 2);
               end if;
            end if;
            if Left = No_Value then
               null;
            elsif Code.Op = Logical_Not and then Code_At (Left).Op = Truth
            then
               Known := True;
               Is_Boolean := True;
               Boolean_Result := not Code_At (Left).Truth;
            elsif Code.Op in Equal_To | Not_Equal_To
              and then Right /= No_Value
              and then Code_At (Left).Op = Truth
              and then Code_At (Right).Op = Truth
            then
               A := Boolean'Pos (Code_At (Left).Truth);
               B := Boolean'Pos (Code_At (Right).Truth);
               Is_Boolean := True;
               Known := True;
               Boolean_Result := (A = B) = (Code.Op = Equal_To);
            elsif Integer_Constant (Left)
              and then (Code.Op in Unary_Kind | Binary_Kind
                        | Conversion | Range_Check)
              and then (Code.Args = 1 or else Integer_Constant (Right))
            then
               A := Numeric (Left);
               if Right /= No_Value then
                  B := Numeric (Right);
               end if;
               Compute
                 (Code, Landin.Types.Integer_Name (Code_At (Left).Result),
                  A, B, Facts, Known, Is_Boolean, Boolean_Result, Result);
            end if;
            if Known then
               --  Replacement keeps the operation's source site, not the
               --  literal's site. Removed checks were proved, never assumed.
               Code := (Op => (if Is_Boolean then Truth else Number),
                        Result => Code.Result, Site => Code.Site,
                        In_Block => Code.In_Block,
                        Number => Landin.Types.Magnitude (abs Result),
                        Negated => Result < 0, Truth => Boolean_Result,
                        others => <>);
            end if;
         end Fold;

         function Operand
           (Code : Instruction; Position : Positive) return Value_Id
           is (Into.Operands.Element (Code.First_Arg + Position));

         function Zero (Value : Value_Id) return Boolean
           is (Integer_Constant (Value) and then Numeric (Value) = 0);

         function One (Value : Value_Id) return Boolean
           is (Integer_Constant (Value) and then Numeric (Value) = 1);

         --  Integer identities.  None holds for a float: x + 0.0 is not x
         --  when x is -0.0, and x == x is false for a NaN.  An identity
         --  that drops a checked operation drops a check that cannot fail.
         procedure Apply_Identity
           (Code : in out Instruction; Same_As : out Value_Id);

         procedure Apply_Identity
           (Code : in out Instruction; Same_As : out Value_Id)
         is
            Left, Right : Value_Id;
         begin
            Same_As := No_Value;
            if not Plain (Code) or else Code.Args /= 2 then
               return;
            end if;
            Left := Operand (Code, 1);
            Right := Operand (Code, 2);
            if Code.Op in Comparison_Kind then
               if Class (Positive (Left)) = Class (Positive (Right))
                 and then Code_At (Left).Result
                   not in Landin.Types.Float_Name
               then
                  Code := (Op => Truth, Result => Code.Result,
                           Site => Code.Site, In_Block => Code.In_Block,
                           Truth => Code.Op in Equal_To | Less_Or_Equal
                             | Greater_Or_Equal,
                           others => <>);
               end if;
               return;
            elsif Code.Result not in Landin.Types.Integer_Name then
               return;
            end if;
            case Code.Op is
               when Add | Wrapping_Add | Bitwise_Xor =>
                  Same_As := (if Zero (Right) then Left
                              elsif Zero (Left) then Right else No_Value);
               when Bitwise_Or =>
                  Same_As :=
                    (if Zero (Right)
                       or else Class (Positive (Left))
                         = Class (Positive (Right))
                     then Left elsif Zero (Left) then Right else No_Value);
               when Subtract | Wrapping_Subtract | Shift_Left | Shift_Right =>
                  Same_As := (if Zero (Right) then Left else No_Value);
               when Multiply | Wrapping_Multiply =>
                  Same_As := (if One (Right) then Left
                              elsif One (Left) then Right else No_Value);
               when Divide =>
                  Same_As := (if One (Right) then Left else No_Value);
               when Bitwise_And =>
                  Same_As :=
                    (if Class (Positive (Left)) = Class (Positive (Right))
                     then Left else No_Value);
               when others => null;
            end case;
            if Same_As /= No_Value
              and then (Code_At (Same_As).Result /= Code.Result
                        or else not Plain (Code_At (Same_As)))
            then
               Same_As := No_Value;
            end if;
         end Apply_Identity;

         --  A storage reached through an address slot is the same place
         --  only while that slot keeps its address, which only a direct
         --  write changes when nothing else can reach the slot.
         function Stable (Place : Storage) return Boolean
           is (Place.Kind /= Runtime_Address
               or else not Exposed (Positive (Place.Address)));

         function Unchanged (Place : Storage; Since : Value_Id) return Boolean
           is (Place.Kind /= Runtime_Address
               or else Last_Write (Positive (Place.Address)) < Since);

         --  The pure computations, checked ones among them, that value
         --  numbering may share.  Memory reads are not among them; loads
         --  of an eligible slot only lend their operands a class.  An
         --  address is shared only for a whole place or one indexed
         --  element of it, whose bounds are its static shape's.
         function Numbered (Code : Instruction) return Boolean
           is (Code.Op in Unary_Kind | Binary_Kind | Conversion | Range_Check
                 | Storage_Address | Place_Address | Pointer_Address
                 | Slice_Address
               and then Code.Variadic_Types.Count = 0
               and then Code.Assembly_Run.Count = 0
               and then Code.Source_Nested.Count = 0
               and then Code.Below_Element.Count = 0
               and then Code.Nested.Count = 0
               and then Code.Element_Field = 0
               and then Code.Variant_Case = 0
               and then Stable (Code.Source)
               and then Stable (Code.Destination));

         --  Everything an operation computes from, apart from where it is
         --  written and which values it reads: those are compared through
         --  their classes.  The unchecked flag stays in: an operation whose
         --  check was removed by [1120] proves nothing for a checked one.
         function Normal (Code : Instruction) return Instruction
           is (Code with delta Site => Landin.Provenance.No_Origin,
                 In_Block => No_Block, First_Arg => 0,
                 Variadic_Types => (others => <>),
                 Assembly_Run => (others => <>),
                 Source_Nested => (others => <>),
                 Below_Element => (others => <>),
                 Nested => (others => <>));

         function Same (Earlier : Value_Id; Code : Instruction)
           return Boolean;

         function Same (Earlier : Value_Id; Code : Instruction)
           return Boolean
         is
            Prior : constant Instruction := Code_At (Earlier);
         begin
            if Normal (Prior) /= Normal (Code)
              or else not Unchanged (Prior.Source, Earlier)
              or else not Unchanged (Prior.Destination, Earlier)
            then
               return False;
            end if;
            for A in 1 .. Code.Args loop
               if Class (Positive (Operand (Prior, A)))
                 /= Class (Positive (Operand (Code, A)))
               then
                  return False;
               end if;
            end loop;
            return True;
         end Same;

         function Hash (Code : Instruction) return Bits;

         function Hash (Code : Instruction) return Bits is
            --  Every field that tells two operations apart is mixed in,
            --  so that distinct operations rarely share a chain and the
            --  table stays linear in a block of near-identical checks.
            Result : Bits := Bits (Opcode'Pos (Code.Op)) * 16#9E37_79B9#
              + Bits (Landin.Types.Type_Kind'Pos (Code.Result))
              + Bits (Code.Number) + Bits (Code.Pointee)
              + Pattern (Code.Lower_Bound) * 7
              + Pattern (Code.Upper_Bound) * 13
              + Bits (Boolean'Pos (Code.Unchecked));
         begin
            for A in 1 .. Code.Args loop
               Result := Result * 31
                 + Bits (Class (Positive (Operand (Code, A))));
            end loop;
            if Code.Destination.Kind = Frame_Slot then
               Result := Result * 31 + Bits (Code.Destination.Slot);
            elsif Code.Destination.Kind = Runtime_Address then
               Result := Result * 31 + Bits (Code.Destination.Address);
            end if;
            return Result;
         end Hash;

         --  [1960]: an operation that would have failed stopped the
         --  program where it stood, so a later identical one in the same
         --  block cannot fail and has the earlier one's value.  That is a
         --  proof, not an unchecked assumption: the replaced operation is
         --  gone, and no flag says its check was waived.
         function Earlier_Same (V : Positive; Code : Instruction)
           return Value_Id;

         function Earlier_Same (V : Positive; Code : Instruction)
           return Value_Id
         is
            Mask : constant Bits := Bits (Table'Length - 1);
            Index : Bits := Hash (Code) and Mask;
         begin
            while Table (Natural (Index) + 1) /= No_Value loop
               if Same (Table (Natural (Index) + 1), Code) then
                  return Table (Natural (Index) + 1);
               end if;
               Index := (Index + 1) and Mask;
            end loop;
            Table (Natural (Index) + 1) := Value_Id (V);
            Filled_Count := Filled_Count + 1;
            Filled (Filled_Count) := Natural (Index) + 1;
            return No_Value;
         end Earlier_Same;

         function Removable (Code : Instruction) return Boolean;

         function Removable (Code : Instruction) return Boolean is
            Effect : constant Effects.Effect_Set := Effects.Of_Code (Code.Op);
         begin
            if Code.Op = Load then
               return Eligible (Positive (Code.Slot));
            end if;
            return not Effect.Reads and then not Effect.Writes
              and then not Effect.Calls and then not Effect.Traps
              and then not Effect.Control and then not Effect.Adjacency
              --  A verified function address is a pure value even though
              --  it carries a signature. Demand still keeps every live use.
              and then (Plain (Code) or else Code.Op = Function_Address);
         end Removable;
      begin
         for S in Eligible'Range loop
            declare
               Slot : constant Slot_Record := Into.Slots.Element
                 (Held.Slots.First + S);
            begin
               --  A forwarded load is the stored value itself: a float
               --  keeps its exact bits, NaN payload and signed zero, and a
               --  pointer its pointee, which the verifier already held to
               --  agree with the slot's when the value was stored.
               Eligible (S) :=
                 not Slot.Aggregate and then not Slot.Array_Shape
                 and then not Slot.Addressed
                 and then Slot.Signature = No_Signature
                 and then Slot.Atom_Set = No_Atom_Set;
            end;
         end loop;
         for V in Alias'Range loop
            Alias (V) := Value_Id (V);
            declare
               Code : constant Instruction := Code_At (Value_Id (V));
            begin
               Pin (Code.Source);
               Pin (Code.Destination);
               if Code.Source.Kind = Frame_Slot
                 and then Code.Source.Slot /= No_Slot
               then
                  Exposed (Positive (Code.Source.Slot)) := True;
               end if;
               if Code.Destination.Kind = Frame_Slot
                 and then Code.Destination.Slot /= No_Slot
               then
                  Exposed (Positive (Code.Destination.Slot)) := True;
               end if;
               if Code.Op = Range_Check and then Code.Pointee /= No_Pointee
               then
                  --  A raw-pointer check proves its carrier using the
                  --  preceding integer-to-usize conversion, not just its
                  --  bits. Keep that structural witness intact.
                  Required_Proof (Positive
                    (Into.Operands.Element (Code.First_Arg + 1))) := True;
               end if;
               if Code.Slot /= No_Slot and then Code.Op not in Load | Store
               then
                  Eligible (Positive (Code.Slot)) := False;
               end if;
               --  [1630]: a block writes its output slots itself, so no
               --  store before it may stand in for a load after it.
               for A in 1 .. Code.Assembly_Run.Count loop
                  declare
                     Output : constant Slot_Id :=
                       Into.Assembly_Operands.Element
                         (Code.Assembly_Run.First + A).Output;
                  begin
                     if Output /= No_Slot then
                        Eligible (Positive (Output)) := False;
                     end if;
                  end;
               end loop;
            end;
         end loop;
         --  An eligible slot is a scalar whose address nothing takes:
         --  every instruction that names it any other way than as a load
         --  or store target, as a source or destination storage, or as an
         --  assembly output made it ineligible above.  So only its own
         --  loads and stores reach it, and a call, an indirect or element
         --  store or a memory event can neither read nor write it.  An
         --  assembly block remains a barrier for every slot: its text is
         --  opaque, and [1630] keeps it ordered against all memory.
         --
         --  A plain local store has no observer before the next store to
         --  that slot in this block.  A load of it, the block boundary or
         --  an assembly block ends the proof, and so does a call: while
         --  the callee runs, a debugger shows this frame's variables.  Its
         --  value preparation remains subject to the backward demand
         --  pass, which keeps any calls or traps.
         for V in Alias'Range loop
            declare
               Code : constant Instruction := Code_At (Value_Id (V));
            begin
               if Code.In_Block /= Last_Block then
                  Forget_Pending;
                  Last_Block := Code.In_Block;
               end if;
               if Code.Op = Store and then Eligible (Positive (Code.Slot))
               then
                  if Pending (Positive (Code.Slot)) /= No_Value then
                     Keep (Held.Values.First
                           + Positive (Pending (Positive (Code.Slot)))) :=
                       False;
                  elsif not Pending_Tracked (Positive (Code.Slot)) then
                     Pending_Count := Pending_Count + 1;
                     Pending_Slots (Pending_Count) := Positive (Code.Slot);
                     Pending_Tracked (Positive (Code.Slot)) := True;
                  end if;
                  Pending (Positive (Code.Slot)) := Value_Id (V);
               elsif Code.Op = Load and then Eligible (Positive (Code.Slot))
               then
                  Pending (Positive (Code.Slot)) := No_Value;
               elsif Effects.Of_Code (Code.Op).Calls then
                  Forget_Pending;
               end if;
            end;
         end loop;
         Last_Block := No_Block;
         for V in Alias'Range loop
            declare
               Code : Instruction := Code_At (Value_Id (V));
            begin
               if Code.In_Block /= Last_Block then
                  Forget_Stores;
                  for Index in 1 .. Filled_Count loop
                     Table (Filled (Index)) := No_Value;
                  end loop;
                  Filled_Count := 0;
                  Last_Block := Code.In_Block;
               end if;
               Class (V) := Value_Id (V);
               for A in 1 .. Code.Args loop
                  Into.Operands.Replace_Element
                    (Code.First_Arg + A, Alias (Positive
                       (Into.Operands.Element (Code.First_Arg + A))));
               end loop;
               if Code.Op = Load and then Eligible (Positive (Code.Slot))
                 and then Stored (Positive (Code.Slot)) /= No_Value
               then
                  Alias (V) := Stored (Positive (Code.Slot));
                  Keep (Held.Values.First + V) := False;
               elsif Code.Op = Load and then Eligible (Positive (Code.Slot))
                 and then First_Load (Positive (Code.Slot)) /= No_Value
               then
                  Class (V) := Class
                    (Positive (First_Load (Positive (Code.Slot))));
               else
                  if not Required_Proof (V) then
                     Fold (Code);
                     declare
                        Same_As : Value_Id;
                     begin
                        Apply_Identity (Code, Same_As);
                        if Same_As = No_Value and then Numbered (Code) then
                           Same_As := Earlier_Same (V, Code);
                        end if;
                        if Same_As /= No_Value then
                           Alias (V) := Same_As;
                           Keep (Held.Values.First + V) := False;
                        end if;
                     end;
                  end if;
                  if Code.Op = Branch then
                     declare
                        Condition : constant Instruction := Code_At
                          (Into.Operands.Element (Code.First_Arg + 1));
                     begin
                        if Condition.Op = Truth then
                           Code.Target := (if Condition.Truth then Code.Target
                                           else Code.Alternative);
                           Code.Op := Jump;
                           Code.Args := 0;
                           Code.Alternative := No_Block;
                        end if;
                     end;
                  end if;
                  Into.Code.Replace_Element (Held.Values.First + V, Code);
               end if;
               --  For the same reason the slot's value survives every
               --  instruction but its own stores and an assembly block.  A
               --  load that found nothing to forward lends its class to
               --  any later load of the slot in this block until then.
               if Code.Op = Store and then Eligible (Positive (Code.Slot))
               then
                  Remember
                    (Code.Slot, Into.Operands.Element (Code.First_Arg + 1));
               elsif Code.Op = Load and then Eligible (Positive (Code.Slot))
                 and then First_Load (Positive (Code.Slot)) = No_Value
                 and then Alias (V) = Value_Id (V)
               then
                  Remember (Code.Slot, Value_Id (V), Is_Load => True);
               elsif Code.Op = Assembly then
                  Forget_Stores;
               end if;
               if Effects.Of_Code (Code.Op).Writes
                 and then Code.Slot /= No_Slot
               then
                  Last_Write (Positive (Code.Slot)) := Value_Id (V);
               end if;
               for A in 1 .. Code.Assembly_Run.Count loop
                  declare
                     Output : constant Slot_Id :=
                       Into.Assembly_Operands.Element
                         (Code.Assembly_Run.First + A).Output;
                  begin
                     if Output /= No_Slot then
                        Last_Write (Positive (Output)) := Value_Id (V);
                     end if;
                  end;
               end loop;
            end;
         end loop;
         --  An eligible slot is read only by its loads.  Once forwarding
         --  has replaced the last of them, a compiler temporary's stores
         --  have no observer: lowering's carried left operand is the
         --  common case.  A declared slot keeps its stores, because they
         --  are its variable's home for the debugger, and so do the
         --  pieces scalar replacement split a declared slot into.
         for V in Alias'Range loop
            if Keep (Held.Values.First + V)
              and then Code_At (Value_Id (V)).Op = Load
            then
               Loaded (Positive (Code_At (Value_Id (V)).Slot)) := True;
            end if;
         end loop;
         for S in 1 .. Held.Slots.Count loop
            declare
               First : constant Slot_Id :=
                 First_Piece (Into, Item, Slot_Id (S));
            begin
               if First /= No_Slot
                 and then Declares (Into, Item, Slot_Id (S)) /= No_Declaration
               then
                  for Part in 1 .. Natural
                    (Slot_Part_Count (Into, Item, Slot_Id (S)))
                  loop
                     Loaded (Positive (First) + Part - 1) := True;
                  end loop;
               end if;
            end;
         end loop;
         for V in Alias'Range loop
            declare
               Code : constant Instruction := Code_At (Value_Id (V));
            begin
               if Code.Op = Store and then Eligible (Positive (Code.Slot))
                 and then not Loaded (Positive (Code.Slot))
                 and then Code.Slot /= Result_Slot (Into, Item)
                 and then Into.Slots.Element
                   (Held.Slots.First + Positive (Code.Slot)).Declaration
                   = No_Declaration
               then
                  Keep (Held.Values.First + V) := False;
               end if;
            end;
         end loop;
         --  D211 removes a check only when it cannot fail, and [1960]
         --  says one that failed stopped the program where it stood.  So
         --  a check whose operands a comparison on the way here, a type's
         --  range or an earlier passed check in this block already bound
         --  is proved, and its edge is not emitted: the instruction keeps
         --  its operation and says Unchecked, which every backend reads
         --  as no edge.  Nothing here reads that flag as a fact; a check
         --  [1120] waived proves nothing.
         --
         --  A comparison's answer reaches the block its branch selects
         --  when that block has no other way in.  It bounds the content
         --  of the slots it compared, and holds below that block in the
         --  dominator tree for as long as no path from the block to a use
         --  stores to them.  A store's block X and successor Y can carry a
         --  change to every block whose subtree holds both, the deepest of
         --  which is Y when Y dominates X and Y's immediate dominator
         --  otherwise; a fact whose block dominates no such block for its
         --  slots holds in its whole subtree.  One that does holds only in
         --  its own block, before that block stores to them.
         --
         --  Work: the dominator tree's O(E log V), one sort of the stores'
         --  blocks, and one walk of the routine in which each fact costs a
         --  binary search.
         declare
            Graph : constant Control_Flow.Graph :=
              Control_Flow.Make (Into, Item);
            Tree : Dominance.Tree;
            Block_Total : constant Natural := Held.Blocks.Count;
            Slot_Total : constant Natural := Held.Slots.Count;
            Value_Total : constant Natural := Held.Values.Count;
            Frozen_Owner : constant Flags.Owner := Flags.Create (Slot_Total);
            Frozen : Flags.Elements renames Frozen_Owner.Data.all;
            Store_Total_Owner : constant Counts.Owner :=
              Counts.Create (Slot_Total);
            Store_Total : Counts.Elements renames Store_Total_Owner.Data.all;
            Store_Block_Owner : constant Counts.Owner :=
              Counts.Create (Slot_Total);
            Store_Block : Counts.Elements renames Store_Block_Owner.Data.all;
            Single_Term_Owner : constant Terms.Owner :=
              Terms.Create (Slot_Total);
            Single_Term : Terms.Elements renames Single_Term_Owner.Data.all;
            Single_Upper_Owner : constant Highs.Owner :=
              Highs.Create (Slot_Total);
            Single_Upper : Highs.Elements renames
              Single_Upper_Owner.Data.all;
            Bad_First_Owner : constant Counts.Owner :=
              Counts.Create (Slot_Total + 1);
            Bad_First : Counts.Elements renames Bad_First_Owner.Data.all;
            Incoming_Owner : constant Counts.Owner :=
              Counts.Create (Block_Total);
            Incoming : Counts.Elements renames Incoming_Owner.Data.all;
            Edge_Owner : constant Edges.Owner := Edges.Create (Block_Total);
            Edge : Edges.Elements renames Edge_Owner.Data.all;
            Upper_Fact_Owner : constant Bounds.Owner :=
              Bounds.Create (Slot_Total);
            Upper_Fact : Bounds.Elements renames Upper_Fact_Owner.Data.all;
            Lower_Fact_Owner : constant Bounds.Owner :=
              Bounds.Create (Slot_Total);
            Lower_Fact : Bounds.Elements renames Lower_Fact_Owner.Data.all;
            Value_Term_Owner : constant Terms.Owner :=
              Terms.Create (Value_Total);
            Value_Term : Terms.Elements renames Value_Term_Owner.Data.all;
            Value_Upper_Owner : constant Highs.Owner :=
              Highs.Create (Value_Total);
            Value_Upper : Highs.Elements renames Value_Upper_Owner.Data.all;
            --  A checked x - k, for a constant k above zero, that did not
            --  trap is below x.
            Under_Owner : constant Values.Owner :=
              Values.Create (Value_Total);
            Under : Values.Elements renames Under_Owner.Data.all;
            Stored_Here_Owner : constant Flags.Owner :=
              Flags.Create (Slot_Total);
            Stored_Here : Flags.Elements renames Stored_Here_Owner.Data.all;
            Stored_List_Owner : constant Counts.Owner :=
              Counts.Create (Slot_Total);
            Stored_List : Counts.Elements renames Stored_List_Owner.Data.all;
            Stored_Count : Natural := 0;
            --  The least static length an index has passed in this block.
            Checked_Below_Owner : constant Numbers.Owner :=
              Numbers.Create (Value_Total);
            Checked_Below : Numbers.Elements renames
              Checked_Below_Owner.Data.all;
            Checked_List_Owner : constant Counts.Owner :=
              Counts.Create (Value_Total);
            Checked_List : Counts.Elements renames
              Checked_List_Owner.Data.all;
            Checked_Count : Natural := 0;

            type Undo_Entry is record
               Slot : Slot_Id := No_Slot;
               Upper : Boolean := False;
               Previous : Bound;
            end record;
            package Undo_Vectors is new Ada.Containers.Vectors
              (Index_Type => Positive, Element_Type => Undo_Entry);
            type Scope_Entry is record
               Last : Natural := 0;
               Mark : Natural := 0;
            end record;
            package Scope_Vectors is new Ada.Containers.Vectors
              (Index_Type => Positive, Element_Type => Scope_Entry);
            Undo : Undo_Vectors.Vector;
            Scopes : Scope_Vectors.Vector;

            function Code_In (Block : Positive; Index : Positive)
              return Value_Id
              is (Value_Id (Into.Blocks.Element
                    (Held.Blocks.First + Block).First_Value
                  - Held.Values.First + Index));

            function Length_Of (Block : Positive) return Natural
              is (Into.Blocks.Element (Held.Blocks.First + Block).Values);

            function Slot_Of (Slot : Slot_Id) return Slot_Record
              is (Into.Slots.Element (Held.Slots.First + Positive (Slot)));

            procedure Undo_To (Mark : Natural);
            procedure Undo_To (Mark : Natural) is
            begin
               while Natural (Undo.Length) > Mark loop
                  declare
                     Last : constant Undo_Entry := Undo.Last_Element;
                  begin
                     if Last.Upper then
                        Upper_Fact (Positive (Last.Slot)) := Last.Previous;
                     else
                        Lower_Fact (Positive (Last.Slot)) := Last.Previous;
                     end if;
                     Undo.Delete_Last;
                  end;
               end loop;
            end Undo_To;

            procedure Set
              (Slot : Slot_Id; Upper : Boolean; Value : Bound);
            procedure Set
              (Slot : Slot_Id; Upper : Boolean; Value : Bound) is
            begin
               Undo.Append
                 (Undo_Entry'(Slot => Slot, Upper => Upper,
                              Previous =>
                                (if Upper then Upper_Fact (Positive (Slot))
                                 else Lower_Fact (Positive (Slot)))));
               if Upper then
                  Upper_Fact (Positive (Slot)) := Value;
               else
                  Lower_Fact (Positive (Slot)) := Value;
               end if;
            end Set;

            --  Each store reaches at most two positions, one a successor.
            Bad_Owner : constant Counts.Owner :=
              Counts.Create (2 * Value_Total);
            Bad : Counts.Elements renames Bad_Owner.Data.all;

            --  Whether no store to this slot can reach a use below Block
            --  without passing Block again.
            function Holds_Below (Slot : Slot_Id; Block : Block_Id)
              return Boolean;
            function Holds_Below (Slot : Slot_Id; Block : Block_Id)
              return Boolean
            is
               Low : Positive := Bad_First (Positive (Slot));
               High : Natural := Bad_First (Positive (Slot) + 1) - 1;
               From : constant Natural := Dominance.Position (Tree, Block);
               Upto : constant Natural := Dominance.Last_Below (Tree, Block);
            begin
               --  The first recorded position at or after From.
               while Low <= High loop
                  declare
                     Middle : constant Positive := (Low + High) / 2;
                  begin
                     if Bad (Middle) < From then
                        Low := Middle + 1;
                     else
                        High := Middle - 1;
                     end if;
                  end;
               end loop;
               return Low >= Bad_First (Positive (Slot) + 1)
                 or else Bad (Low) > Upto;
            end Holds_Below;

            function Holds_Below (Fact : Relation; Block : Block_Id)
              return Boolean
              is ((Fact.Left.Kind /= Entry_Term
                   or else Holds_Below (Fact.Left.Slot, Block))
                  and then (Fact.Right.Kind /= Entry_Term
                    or else Holds_Below (Fact.Right.Slot, Block)));

            procedure Assume (Fact : Relation);
            procedure Assume (Fact : Relation) is
            begin
               if not Fact.Present then
                  return;
               end if;
               if Subject (Fact.Left) /= No_Slot then
                  Set (Subject (Fact.Left), True,
                       (Present => True, Limit => Fact.Right,
                        Strict => Fact.Strict));
               end if;
               if Subject (Fact.Right) /= No_Slot then
                  Set (Subject (Fact.Right), False,
                       (Present => True, Limit => Fact.Left,
                        Strict => Fact.Strict));
               end if;
            end Assume;

            function Kind_Of (Value : Value_Id) return Landin.Types.Type_Kind
              is (Code_At (Value).Result);

            function Unsigned (Value : Value_Id) return Boolean
              is (Kind_Of (Value) in Landin.Types.Integer_Name
                  and then not Landin.Types.Is_Signed
                    (Landin.Types.Integer_Name (Kind_Of (Value))));

            function Type_Low (Value : Value_Id) return Integer_Value
              is (Lowest (Landin.Types.Integer_Name (Kind_Of (Value)), Facts));

            function Type_High (Value : Value_Id) return Integer_Value
              is (Highest
                    (Landin.Types.Integer_Name (Kind_Of (Value)), Facts));

            function Step (Strict : Boolean) return Integer_Value
              is (if Strict then 1 else 0);

            --  The greatest and least a value can be: its type's range
            --  narrowed by what produced it and by the facts on its slot.
            function Upper_Of (Value : Value_Id) return Integer_Value;
            function Upper_Of (Value : Value_Id) return Integer_Value is
               Result : Integer_Value := Value_Upper (Positive (Value));
               Slot : constant Slot_Id :=
                 Subject (Value_Term (Positive (Value)));
            begin
               if Slot /= No_Slot and then Upper_Fact (Positive (Slot)).Present
               then
                  declare
                     Fact : constant Bound := Upper_Fact (Positive (Slot));
                  begin
                     Result := Integer_Value'Min
                       (Result,
                        (if Fact.Limit.Kind = Constant_Term
                         then Fact.Limit.Number
                         else Type_High (Value)) - Step (Fact.Strict));
                  end;
               end if;
               return Result;
            end Upper_Of;

            function Lower_Of (Value : Value_Id) return Integer_Value;
            function Lower_Of (Value : Value_Id) return Integer_Value is
               Result : Integer_Value :=
                 (if Value_Term (Positive (Value)).Kind = Constant_Term
                  then Value_Term (Positive (Value)).Number
                  else Type_Low (Value));
               Slot : constant Slot_Id :=
                 Subject (Value_Term (Positive (Value)));
            begin
               if Slot /= No_Slot and then Lower_Fact (Positive (Slot)).Present
               then
                  declare
                     Fact : constant Bound := Lower_Fact (Positive (Slot));
                  begin
                     Result := Integer_Value'Max
                       (Result,
                        (if Fact.Limit.Kind = Constant_Term
                         then Fact.Limit.Number
                         else Type_Low (Value)) + Step (Fact.Strict));
                  end;
               end if;
               return Result;
            end Lower_Of;

            --  Left < Right: a fact naming Right, or two bounds apart.
            function Below (Left, Right : Value_Id) return Boolean;
            function Below (Left, Right : Value_Id) return Boolean is
               Slot : constant Slot_Id :=
                 Subject (Value_Term (Positive (Left)));
            begin
               if Slot /= No_Slot and then Upper_Fact (Positive (Slot)).Present
                 and then Upper_Fact (Positive (Slot)).Strict
                 and then Same_Term (Upper_Fact (Positive (Slot)).Limit,
                                     Value_Term (Positive (Right)))
               then
                  return True;
               end if;
               declare
                  Above : constant Value_Id := Under (Positive (Left));
               begin
                  if Above /= No_Value
                    and then (Class (Positive (Above))
                                = Class (Positive (Right))
                              or else Same_Term
                                (Value_Term (Positive (Above)),
                                 Value_Term (Positive (Right))))
                  then
                     return True;
                  end if;
               end;
               return Upper_Of (Left) < Lower_Of (Right);
            end Below;

            --  [0520]'s static length of the array an element operation
            --  indexes, or zero when it reaches through a field, a path or
            --  a variant case, which this proof does not follow.
            function Static_Length (Code : Instruction) return Integer_Value;
            function Static_Length (Code : Instruction) return Integer_Value
            is
               function Of_Slot (Slot : Slot_Id) return Integer_Value
                 is (if Slot_Of (Slot).Addressed
                     then (if Slot_Of (Slot).Element.Kind = Array_Field_Shape
                           then Integer_Value (Slot_Of (Slot).Element.Length)
                           else 0)
                     elsif Slot_Of (Slot).Array_Shape
                     then Integer_Value (Slot_Of (Slot).Length)
                     else 0);

               function Of_Datum (Datum : Item_Id) return Integer_Value
                 is (if Into.Items.Element (Positive (Datum)).Result
                       = Landin.Types.Fixed_Array
                     then Integer_Value
                       (Into.Items.Element (Positive (Datum)).Length)
                     else 0);
            begin
               if Code.Element_Field /= 0 or else Code.Nested.Count /= 0
                 or else Code.Variant_Case /= 0
                 or else Code.Variant_Payload_Field /= 0
               then
                  return 0;
               end if;
               case Code.Op is
                  when Load_Element | Store_Element =>
                     return (if Code.Slot /= No_Slot then Of_Slot (Code.Slot)
                             else Of_Datum (Code.Named));
                  when Storage_Address =>
                     if not Code.Indexed_Address then
                        return 0;
                     end if;
                     case Code.Destination.Kind is
                        when Frame_Slot =>
                           return Of_Slot (Code.Destination.Slot);
                        when Runtime_Address =>
                           return Of_Slot (Code.Destination.Address);
                        when Module_Datum =>
                           return Of_Datum (Code.Destination.Datum);
                     end case;
                  when others =>
                     return 0;
               end case;
            end Static_Length;

            --  The relations the branch ending Block proves on one edge.
            procedure Note_Edges (Block : Positive);
            procedure Note_Edges (Block : Positive) is
               Last : constant Instruction :=
                 Code_At (Code_In (Block, Length_Of (Block)));
               Condition : Value_Id;
               Test : Instruction;
               A, B : Value_Id;
               Left, Right : Term;

               function Fact (Left, Right : Term; Strict : Boolean)
                 return Relation
                 is ((Present => True, Left => Left, Right => Right,
                      Strict => Strict));

               --  A term a store in this block has overtaken says nothing
               --  about the slot's content on the way out.
               function Current (Of_Term : Term) return Term
                 is (if Of_Term.Kind = Entry_Term
                       and then Stored_Here (Positive (Of_Term.Slot))
                     then (others => <>) else Of_Term);

               procedure Record_Edge
                 (Target : Block_Id; Op : Opcode; Holds : Boolean);
               procedure Record_Edge
                 (Target : Block_Id; Op : Opcode; Holds : Boolean)
               is
                  Zero : constant Term :=
                    (Kind => Constant_Term, Number => 0, others => <>);
                  Facts_Here : Edge_Relations;
                  --  Not holding, a < b is b <= a, and so on.
                  Effective : constant Opcode :=
                    (if Holds then Op
                     else (case Op is
                              when Less_Than => Greater_Or_Equal,
                              when Less_Or_Equal => Greater_Than,
                              when Greater_Than => Less_Or_Equal,
                              when Greater_Or_Equal => Less_Than,
                              when Equal_To => Not_Equal_To,
                              when others => Equal_To));
               begin
                  --  The entry is also entered from the caller.
                  if Incoming (Positive (Target)) /= 1
                    or else Target = First_Block
                  then
                     return;
                  end if;
                  case Effective is
                     when Less_Than =>
                        Facts_Here.First := Fact (Left, Right, True);
                     when Less_Or_Equal =>
                        Facts_Here.First := Fact (Left, Right, False);
                     when Greater_Than =>
                        Facts_Here.First := Fact (Right, Left, True);
                     when Greater_Or_Equal =>
                        Facts_Here.First := Fact (Right, Left, False);
                     when Equal_To =>
                        Facts_Here.First := Fact (Left, Right, False);
                        Facts_Here.Second := Fact (Right, Left, False);
                     when others =>
                        --  Unsigned, a value other than zero is above it.
                        if Unsigned (A) and then Same_Term (Right, Zero) then
                           Facts_Here.First := Fact (Zero, Left, True);
                        elsif Unsigned (A) and then Same_Term (Left, Zero)
                        then
                           Facts_Here.First := Fact (Zero, Right, True);
                        end if;
                  end case;
                  Edge (Positive (Target)) := Facts_Here;
               end Record_Edge;
            begin
               if Last.Op /= Branch or else Last.Target = Last.Alternative
               then
                  return;
               end if;
               Condition := Operand (Last, 1);
               Test := Code_At (Condition);
               if Test.Op not in Comparison_Kind or else not Plain (Test)
                 or else Test.Args /= 2
               then
                  return;
               end if;
               A := Operand (Test, 1);
               B := Operand (Test, 2);
               if Kind_Of (A) not in Landin.Types.Integer_Name
                 or else Kind_Of (B) /= Kind_Of (A)
               then
                  return;
               end if;
               Left := Current (Value_Term (Positive (A)));
               Right := Current (Value_Term (Positive (B)));
               Record_Edge (Last.Target, Test.Op, True);
               Record_Edge (Last.Alternative, Test.Op, False);
            end Note_Edges;

            --  One instruction of a block being walked: what it is known
            --  to be, then whether its check is proved.
            procedure Visit (Block : Positive; V : Value_Id);
            procedure Visit (Block : Positive; V : Value_Id) is
               Code : Instruction := Code_At (V);
               Waived : constant Boolean := Code.Unchecked;
               Here : Term;
               Upper : Integer_Value := 0;
               Proved : Boolean := False;
            begin
               if Code.Result in Landin.Types.Integer_Name then
                  Upper := Type_High (V);
               end if;
               case Code.Op is
                  when Number =>
                     if Plain (Code)
                       and then Code.Result in Landin.Types.Integer_Name
                     then
                        Here := (Kind => Constant_Term,
                                 Number => Numeric (V), others => <>);
                        Upper := Numeric (V);
                     end if;
                  when Load =>
                     if Frozen (Positive (Code.Slot)) then
                        Here := (Kind => Fixed_Term, Slot => Code.Slot,
                                 others => <>);
                     elsif Eligible (Positive (Code.Slot))
                       and then not Stored_Here (Positive (Code.Slot))
                     then
                        Here := (Kind => Entry_Term, Slot => Code.Slot,
                                 others => <>);
                        --  The one store in the routine ran before every
                        --  block it strictly dominates.
                        if Store_Total (Positive (Code.Slot)) = 1
                          and then Dominance.Strictly_Dominates
                            (Tree,
                             Block_Id (Store_Block (Positive (Code.Slot))),
                             Block_Id (Block))
                        then
                           if Single_Term (Positive (Code.Slot)).Kind
                             in Constant_Term | Fixed_Term
                           then
                              Here := Single_Term (Positive (Code.Slot));
                           end if;
                           if Code.Result in Landin.Types.Integer_Name then
                              Upper := Integer_Value'Min
                                (Upper, Single_Upper (Positive (Code.Slot)));
                           end if;
                        end if;
                     end if;
                  when Load_Field =>
                     if Code.Slot /= No_Slot
                       and then Frozen (Positive (Code.Slot))
                       and then Plain (Code)
                       and then Code.Nested.Count = 0
                       and then Code.Source_Nested.Count = 0
                     then
                        Here := (Kind => Fixed_Term, Slot => Code.Slot,
                                 Part => Natural (Code.Part), others => <>);
                     end if;
                  when Conversion =>
                     --  Widening an unsigned value keeps it.
                     if Code.Result in Landin.Types.Integer_Name
                       and then Unsigned (Operand (Code, 1))
                       and then Landin.Types.Width
                         (Landin.Types.Integer_Name
                            (Kind_Of (Operand (Code, 1))), Facts)
                       <= Landin.Types.Width
                         (Landin.Types.Integer_Name (Code.Result), Facts)
                     then
                        Upper := Integer_Value'Min
                          (Upper, Upper_Of (Operand (Code, 1)));
                     end if;
                  when Bitwise_And | Remainder | Divide | Shift_Right =>
                     if Unsigned (V) and then Code.Args = 2 then
                        declare
                           Left : constant Value_Id := Operand (Code, 1);
                           Right : constant Value_Id := Operand (Code, 2);
                           Constant_Right : constant Boolean :=
                             Value_Term (Positive (Right)).Kind
                               = Constant_Term;
                           Count : constant Integer_Value :=
                             Value_Term (Positive (Right)).Number;
                        begin
                           --  None of these makes an unsigned value larger
                           --  than its left operand.
                           Upper := Integer_Value'Min
                             (Upper, Upper_Of (Left));
                           if Code.Op = Bitwise_And then
                              Upper := Integer_Value'Min
                                (Upper, Upper_Of (Right));
                           elsif Code.Op = Remainder and then Constant_Right
                             and then Count > 0
                           then
                              Upper := Integer_Value'Min (Upper, Count - 1);
                           elsif Code.Op = Shift_Right and then Constant_Right
                             and then Count in 0 .. 63
                           then
                              Upper := Integer_Value
                                (Interfaces.Shift_Right
                                   (Bits (Upper), Natural (Count)));
                           end if;
                        end;
                     end if;
                  when Store =>
                     if Eligible (Positive (Code.Slot)) then
                        if not Stored_Here (Positive (Code.Slot)) then
                           Stored_Here (Positive (Code.Slot)) := True;
                           Stored_Count := Stored_Count + 1;
                           Stored_List (Stored_Count) := Positive (Code.Slot);
                        end if;
                        if Store_Total (Positive (Code.Slot)) = 1 then
                           Single_Term (Positive (Code.Slot)) :=
                             Value_Term (Positive (Operand (Code, 1)));
                           if Kind_Of (Operand (Code, 1))
                             in Landin.Types.Integer_Name
                           then
                              Single_Upper (Positive (Code.Slot)) :=
                                Upper_Of (Operand (Code, 1));
                           end if;
                        end if;
                     end if;
                  when others =>
                     null;
               end case;
               Value_Term (Positive (V)) := Here;
               if Code.Op = Subtract and then not Waived
                 and then Code.Result in Landin.Types.Integer_Name
                 and then Code.Args = 2
                 and then Value_Term (Positive (Operand (Code, 2))).Kind
                   = Constant_Term
                 and then Value_Term (Positive (Operand (Code, 2))).Number > 0
               then
                  Under (Positive (V)) := Operand (Code, 1);
               end if;
               Value_Upper (Positive (V)) := Upper;
               if Waived or else not Check_Is_Removable (Into, Item, V) then
                  null;
               elsif Code.Op in Add | Subtract and then Code.Args = 2 then
                  declare
                     Left : constant Value_Id := Operand (Code, 1);
                     Right : constant Value_Id := Operand (Code, 2);
                     Varying : Value_Id := No_Value;
                     Amount : Integer_Value := 0;
                  begin
                     if Value_Term (Positive (Right)).Kind = Constant_Term
                     then
                        Varying := Left;
                        Amount := Value_Term (Positive (Right)).Number;
                     elsif Code.Op = Add
                       and then Value_Term (Positive (Left)).Kind
                         = Constant_Term
                     then
                        Varying := Right;
                        Amount := Value_Term (Positive (Left)).Number;
                     end if;
                     if Code.Op = Subtract then
                        Amount := -Amount;
                     end if;
                     --  x + k, with k a constant of x's own type.
                     if Varying /= No_Value then
                        Proved :=
                          (if Amount >= 0
                           then Upper_Of (Varying) <= Type_High (V) - Amount
                           else Lower_Of (Varying) >= Type_Low (V) - Amount);
                     end if;
                  end;
               elsif Code.Op in Load_Element | Store_Element | Storage_Address
               then
                  declare
                     Length : constant Integer_Value := Static_Length (Code);
                     Index : constant Value_Id := Operand (Code, 1);
                     Key : constant Positive :=
                       Positive (Class (Positive (Index)));
                  begin
                     if Length > 0 and then Unsigned (Index) then
                        Proved := Upper_Of (Index) < Length
                          or else (Checked_Below (Key) > 0
                                   and then Checked_Below (Key) <= Length);
                        --  Past this check the index is below Length.
                        if Checked_Below (Key) = 0 then
                           Checked_Count := Checked_Count + 1;
                           Checked_List (Checked_Count) := Key;
                           Checked_Below (Key) := Length;
                        else
                           Checked_Below (Key) :=
                             Integer_Value'Min (Checked_Below (Key), Length);
                        end if;
                     end if;
                  end;
               elsif Code.Op = Slice_Address and then Code.Args = 4
                 and then Code.Truth
                 and then Operand (Code, 3) = Operand (Code, 4)
               then
                  --  One element: lower and upper are one value, and the
                  --  inclusive upper edge asks that it be below the length.
                  Proved := Below (Operand (Code, 3), Operand (Code, 2));
               end if;
               if Proved then
                  Code.Unchecked := True;
                  Into.Code.Replace_Element (Held.Values.First + Positive (V),
                                             Code);
               end if;
            end Visit;
         begin
            Dominance.Build (Tree, Graph);
            for B in 1 .. Block_Total loop
               declare
                  Edge_At : Natural := Control_Flow.First_Predecessor
                    (Graph, Block_Id (B));
               begin
                  while Edge_At /= 0 loop
                     Incoming (B) := Incoming (B) + 1;
                     Edge_At := Control_Flow.Next_Predecessor (Graph, Edge_At);
                  end loop;
               end;
            end loop;
            --  A slot is frozen when the routine only ever reads it whole
            --  or by part: a parameter nothing assigns, never addressed.
            for S in Frozen'Range loop
               Frozen (S) := not Slot_Of (Slot_Id (S)).Addressed;
            end loop;
            for V in 1 .. Value_Total loop
               if Keep (Held.Values.First + V) then
                  declare
                     Code : constant Instruction := Code_At (Value_Id (V));
                  begin
                     for Place of Storage_Array'(Code.Source, Code.Destination)
                     loop
                        case Place.Kind is
                           when Frame_Slot =>
                              if Place.Slot /= No_Slot then
                                 Frozen (Positive (Place.Slot)) := False;
                              end if;
                           when Runtime_Address =>
                              if Place.Address /= No_Slot then
                                 Frozen (Positive (Place.Address)) := False;
                              end if;
                           when Module_Datum =>
                              null;
                        end case;
                     end loop;
                     if Code.Slot /= No_Slot then
                        if Code.Op not in Load | Load_Field then
                           Frozen (Positive (Code.Slot)) := False;
                        end if;
                        if Code.Op = Store
                          and then Eligible (Positive (Code.Slot))
                        then
                           Store_Total (Positive (Code.Slot)) :=
                             Store_Total (Positive (Code.Slot)) + 1;
                           Store_Block (Positive (Code.Slot)) :=
                             Natural (Code.In_Block);
                        end if;
                     end if;
                     for A in 1 .. Code.Assembly_Run.Count loop
                        declare
                           Output : constant Slot_Id :=
                             Into.Assembly_Operands.Element
                               (Code.Assembly_Run.First + A).Output;
                        begin
                           if Output /= No_Slot then
                              Frozen (Positive (Output)) := False;
                           end if;
                        end;
                     end loop;
                  end;
               end if;
            end loop;
            --  Each store's reach, as preorder positions grouped by slot
            --  and sorted within it.
            declare
               Filled_Owner : constant Counts.Owner :=
                 Counts.Create (Slot_Total + 1);
               Filled : Counts.Elements renames Filled_Owner.Data.all;
            begin
               --  Count each slot's positions, then place them.
               for V in 1 .. Value_Total loop
                  declare
                     Code : constant Instruction := Code_At (Value_Id (V));
                  begin
                     if Keep (Held.Values.First + V) and then Code.Op = Store
                       and then Eligible (Positive (Code.Slot))
                       and then Dominance.Position (Tree, Code.In_Block) /= 0
                     then
                        for Next in 1 .. 2 loop
                           if Control_Flow.Successor
                             (Graph, Code.In_Block, Next) /= No_Block
                           then
                              Filled (Positive (Code.Slot)) :=
                                Filled (Positive (Code.Slot)) + 1;
                           end if;
                        end loop;
                     end if;
                  end;
               end loop;
               Bad_First (1) := 1;
               for S in 1 .. Slot_Total loop
                  Bad_First (S + 1) := Bad_First (S) + Filled (S);
                  Filled (S) := Bad_First (S);
               end loop;
               for V in 1 .. Value_Total loop
                  declare
                     Code : constant Instruction := Code_At (Value_Id (V));
                  begin
                     if Keep (Held.Values.First + V) and then Code.Op = Store
                       and then Eligible (Positive (Code.Slot))
                       and then Dominance.Position (Tree, Code.In_Block) /= 0
                     then
                        for Next in 1 .. 2 loop
                           declare
                              Target : constant Block_Id :=
                                Control_Flow.Successor
                                  (Graph, Code.In_Block, Next);
                              Deepest : Block_Id;
                           begin
                              if Target /= No_Block then
                                 Deepest :=
                                   (if Dominance.Dominates
                                         (Tree, Target, Code.In_Block)
                                    then Target
                                    else Dominance.Immediate (Tree, Target));
                                 Bad (Filled (Positive (Code.Slot))) :=
                                     Dominance.Position (Tree, Deepest);
                                 Filled (Positive (Code.Slot)) :=
                                   Filled (Positive (Code.Slot)) + 1;
                              end if;
                           end;
                        end loop;
                     end if;
                  end;
               end loop;
               for S in 1 .. Slot_Total loop
                  if Bad_First (S + 1) > Bad_First (S) + 1 then
                     Sort (Bad (Bad_First (S) .. Bad_First (S + 1) - 1));
                  end if;
               end loop;
            end;
            for Index in 1 .. Dominance.Reached (Tree) loop
               declare
                  Block : constant Block_Id :=
                    Dominance.Block_At (Tree, Index);
                  Entered : Natural;
                  Facts_Here : constant Edge_Relations :=
                    Edge (Positive (Block));
                  Local : Natural;
               begin
                  --  Leave every subtree this block is not in.
                  while not Scopes.Is_Empty
                    and then Scopes.Last_Element.Last < Index
                  loop
                     Undo_To (Scopes.Last_Element.Mark);
                     Scopes.Delete_Last;
                  end loop;
                  Entered := Natural (Undo.Length);
                  for Fact of Relation_Array'(Facts_Here.First,
                                              Facts_Here.Second)
                  loop
                     if Holds_Below (Fact, Block) then
                        Assume (Fact);
                     end if;
                  end loop;
                  Local := Natural (Undo.Length);
                  for Fact of Relation_Array'(Facts_Here.First,
                                              Facts_Here.Second)
                  loop
                     if not Holds_Below (Fact, Block) then
                        Assume (Fact);
                     end if;
                  end loop;
                  for Position in 1 .. Length_Of (Positive (Block)) loop
                     declare
                        V : constant Value_Id :=
                          Code_In (Positive (Block), Position);
                     begin
                        if Keep (Held.Values.First + Positive (V)) then
                           Visit (Positive (Block), V);
                        end if;
                     end;
                  end loop;
                  Note_Edges (Positive (Block));
                  Undo_To (Local);
                  for Index_At in 1 .. Stored_Count loop
                     Stored_Here (Stored_List (Index_At)) := False;
                  end loop;
                  Stored_Count := 0;
                  for Index_At in 1 .. Checked_Count loop
                     Checked_Below (Checked_List (Index_At)) := 0;
                  end loop;
                  Checked_Count := 0;
                  Scopes.Append
                    (Scope_Entry'(Last => Dominance.Last_Below (Tree, Block),
                                  Mark => Entered));
               end;
            end loop;
         end;
         --  Backward demand marks transitive operands once. Observable
         --  instructions are roots even when their result is discarded.
         for V in reverse Alias'Range loop
            if Keep (Held.Values.First + V) then
               declare
                  Code : constant Instruction := Code_At (Value_Id (V));
               begin
                  if Needed (V) or else not Removable (Code) then
                     for A in 1 .. Code.Args loop
                        Needed (Positive (Into.Operands.Element
                          (Code.First_Arg + A))) := True;
                     end loop;
                  else
                     Keep (Held.Values.First + V) := False;
                  end if;
               end;
            end if;
         end loop;
      end Simplify;
   begin
      if Objective = Landin.Optimization.None then
         return;
      end if;
      --  Verified below with this pass's own edits.
      Scalar_Replacement.Replace (Into, Objective);
      declare
         Keep : Rewriting.Keep_Vectors.Vector :=
           Rewriting.Keep_Vectors.To_Vector
             (True, Into.Code.Length);
      begin
         for I in 1 .. Item_Count (Into) loop
            if Kind_Of (Into, Item_Id (I)) = Routine
              and then not Is_External (Into, Item_Id (I))
            then
               Simplify (Item_Id (I), Keep);
            end if;
         end loop;
         Rewriting.Compact (Into, Keep);
      end;
      Verifier.Verify (Into, Facts);
   end Run_On_Verified;
end Landin.IR.Simplification;
