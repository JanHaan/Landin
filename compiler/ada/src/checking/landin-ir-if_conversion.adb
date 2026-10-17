with Ada.Containers.Vectors;
with Ada.Finalization;
with Ada.Unchecked_Deallocation;
with Landin.IR.Control_Flow;
with Landin.IR.Effects;
with Landin.IR.Rewriting;
with Landin.IR.Verifier;

package body Landin.IR.If_Conversion is
   use type Landin.Optimization.Objective;
   use type Landin.Targets.Bit_Width;

   --  The package comment's limits: operations an arm may compute besides
   --  its constants, loads and stores, slots one conversion chooses, and
   --  forwarding blocks followed to find where two arms meet.
   Arm_Limit : constant := 6;
   Choice_Limit : constant := 4;
   Thread_Limit : constant := 8;

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
      begin
         return Result : Owner do
            Result.Data := new Elements'(1 .. Count => Initial);
         end return;
      end Create;
   end Scratch_Arrays;

   package Flags is new Scratch_Arrays (Boolean, False);
   package Counts is new Scratch_Arrays (Natural, 0);
   package Values is new Scratch_Arrays (Value_Id, No_Value);
   package Slots is new Scratch_Arrays (Slot_Id, No_Slot);

   --  A planned instruction's operand: a value the head block already
   --  had, or one planned before it.  Early instructions are the arms'
   --  copies, which go before the branch's condition when nothing but
   --  the branch follows it, so that a backend finds the condition next
   --  to the choice that reads it; late ones are the choices, the
   --  admitted trapping updates and the stores.
   type Ref_Kind is (Old_Value, Early, Late);

   type Ref is record
      Kind  : Ref_Kind := Old_Value;
      Index : Natural  := 0;
   end record;

   No_Ref : constant Ref := (Kind => Old_Value, Index => 0);

   package Refs is new Scratch_Arrays (Ref, No_Ref);

   package Ref_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Ref);

   package Index_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Positive);

   package Value_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Value_Id);

   --  Code.Args operands start after Plan_Args' First.
   type Planned is record
      Code  : Instruction;
      First : Natural := 0;
   end record;

   package Planned_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Planned);

   type Rewrite is record
      Head   : Block_Id := No_Block;
      --  The instruction the early group goes before, and the branch the
      --  late group and a jump to Join replace.
      Before : Value_Id := No_Value;
      Branch : Value_Id := No_Value;
      Join   : Block_Id := No_Block;
      Early_First, Early_Count : Natural := 0;
      Late_First, Late_Count   : Natural := 0;
   end record;

   package Rewrite_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Rewrite);

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
      Code : Code_Vectors.Vector;
      Args : Value_Ref_Vectors.Vector;
      Assembled : Assembly_Operand_Vectors.Vector;
      Blocks : Block_Vectors.Vector;
      Items : Item_Vectors.Vector := Into.Items;
      Changed : Boolean := False;

      --  Plan Item's conversions, then append its instructions, with them,
      --  to the new vectors.
      procedure Convert (Item : Item_Id);

      procedure Convert (Item : Item_Id) is
         Old : constant Item_Record := Into.Items.Element (Positive (Item));
         Held : Item_Record := Old;
         Graph : constant Control_Flow.Graph := Control_Flow.Make
           (Into, Item);

         Private_Owner : constant Flags.Owner :=
           Flags.Create (Old.Slots.Count);
         Is_Private : Flags.Elements renames Private_Owner.Data.all;
         Uses_Owner : constant Counts.Owner :=
           Counts.Create (Old.Values.Count);
         Uses : Counts.Elements renames Uses_Owner.Data.all;
         --  A load that read its slot before its arm stored to it.
         Fresh_Owner : constant Flags.Owner := Flags.Create (Old.Values.Count);
         Fresh : Flags.Elements renames Fresh_Owner.Data.all;
         --  The slot a trapping update would write, once it is admitted.
         Update_Owner : constant Slots.Owner := Slots.Create
           (Old.Values.Count);
         Updates : Slots.Elements renames Update_Owner.Data.all;
         Copy_Owner : constant Refs.Owner := Refs.Create (Old.Values.Count);
         Copy : Refs.Elements renames Copy_Owner.Data.all;
         --  Per slot and per arm: whether the arm stored to it, the value
         --  it stored last, and the admitted update that wrote it.
         Stored_Yes_Owner : constant Flags.Owner :=
           Flags.Create (Old.Slots.Count);
         Stored_Yes : Flags.Elements renames Stored_Yes_Owner.Data.all;
         Stored_No_Owner : constant Flags.Owner :=
           Flags.Create (Old.Slots.Count);
         Stored_No : Flags.Elements renames Stored_No_Owner.Data.all;
         Updated_Owner : constant Flags.Owner :=
           Flags.Create (Old.Slots.Count);
         Updated : Flags.Elements renames Updated_Owner.Data.all;
         Last_Yes_Owner : constant Refs.Owner := Refs.Create (Old.Slots.Count);
         Last_Yes : Refs.Elements renames Last_Yes_Owner.Data.all;
         Last_No_Owner : constant Refs.Owner := Refs.Create (Old.Slots.Count);
         Last_No : Refs.Elements renames Last_No_Owner.Data.all;
         Store_Of_Owner : constant Values.Owner :=
           Values.Create (Old.Slots.Count);
         Store_Of : Values.Elements renames Store_Of_Owner.Data.all;
         --  The slots the arms being considered store, in order.
         Touched : Index_Vectors.Vector;
         --  The values a condition is computed from, while one is walked.
         Seen_Owner : constant Flags.Owner := Flags.Create (Old.Values.Count);
         Seen : Flags.Elements renames Seen_Owner.Data.all;
         Walk : Index_Vectors.Vector;
         --  The values the head block stores to a slot the arms store.
         Kept_Owner : constant Flags.Owner := Flags.Create (Old.Values.Count);
         Kept : Flags.Elements renames Kept_Owner.Data.all;
         Kept_List : Index_Vectors.Vector;
         Plan_Of_Owner : constant Counts.Owner :=
           Counts.Create (Old.Blocks.Count);
         Plan_Of : Counts.Elements renames Plan_Of_Owner.Data.all;

         Plans : Rewrite_Vectors.Vector;
         Early_Plan, Late_Plan : Planned_Vectors.Vector;
         Plan_Args : Ref_Vectors.Vector;

         function Code_At (Value : Value_Id) return Instruction
           is (Into.Code.Element (Old.Values.First + Positive (Value)));

         function Operand (Of_Code : Instruction; Position : Positive)
           return Value_Id
           is (Into.Operands.Element (Of_Code.First_Arg + Position));

         function First_Of (Block : Block_Id) return Value_Id
           is (Value_Id
                 (Into.Blocks.Element (Old.Blocks.First + Positive (Block))
                    .First_Value + 1 - Old.Values.First));

         function Last_Of (Block : Block_Id) return Value_Id
           is (First_Of (Block) - 1 + Value_Id
                 (Into.Blocks.Element (Old.Blocks.First + Positive (Block))
                    .Values));

         function Plain (Of_Code : Instruction) return Boolean
           is (Of_Code.Pointee = No_Pointee
               and then Of_Code.Signature = No_Signature
               and then Of_Code.Atom_Set = No_Atom_Set);

         --  Whether Block's one way in is the branch at the end of Head.
         function Only_From (Block, Head : Block_Id) return Boolean;

         function Only_From (Block, Head : Block_Id) return Boolean is
            Edge : constant Natural :=
              Control_Flow.First_Predecessor (Graph, Block);
         begin
            return Edge /= 0
              and then Control_Flow.Next_Predecessor (Graph, Edge) = 0
              and then Control_Flow.Predecessor (Graph, Edge) = Head;
         end Only_From;

         --  Where From leads once the blocks that only jump are passed.
         function Thread (From : Block_Id) return Block_Id;

         function Thread (From : Block_Id) return Block_Id is
            At_Block : Block_Id := From;
         begin
            for Step in 1 .. Thread_Limit loop
               declare
                  Last : constant Instruction := Code_At (Last_Of (At_Block));
               begin
                  exit when First_Of (At_Block) /= Last_Of (At_Block)
                    or else Last.Op /= Jump
                    or else Last.Target = At_Block;
                  At_Block := Last.Target;
               end;
            end loop;
            return At_Block;
         end Thread;

         --  [0310]'s conversions that hold every value of their source:
         --  D170's integer to float, D169's f32 to f64, D172 and D176's
         --  bool to a number and an integer into one that holds its range.
         function Is_Total (Of_Code : Instruction) return Boolean;

         function Is_Total (Of_Code : Instruction) return Boolean is
            From : constant Landin.Types.Type_Kind :=
              Code_At (Operand (Of_Code, 1)).Result;
            To : constant Landin.Types.Type_Kind := Of_Code.Result;
         begin
            if From = Landin.Types.Bool then
               return To in Landin.Types.Numeric_Name;
            elsif From in Landin.Types.Integer_Name
              and then To in Landin.Types.Float_Name
            then
               return True;
            elsif From = Landin.Types.F32 and then To = Landin.Types.F64
            then
               return True;
            elsif From in Landin.Types.Integer_Name
              and then To in Landin.Types.Integer_Name
            then
               declare
                  Source : constant Landin.Targets.Bit_Width :=
                    Landin.Types.Width (From, Facts);
                  Result : constant Landin.Targets.Bit_Width :=
                    Landin.Types.Width (To, Facts);
               begin
                  return
                    (if Landin.Types.Is_Signed (From)
                          = Landin.Types.Is_Signed (To)
                     then Source <= Result
                     else not Landin.Types.Is_Signed (From)
                          and then Source < Result);
               end;
            else
               return False;
            end if;
         end Is_Total;

         --  Whether computing Of_Code when its arm is not taken changes
         --  nothing a program can observe: it cannot trap, and it reads
         --  nothing but a private slot, which no arm writes before the
         --  choices are made.
         function Speculates (Of_Code : Instruction) return Boolean;

         function Speculates (Of_Code : Instruction) return Boolean is
            Effect : constant Effects.Effect_Set :=
              Effects.Of_Code (Of_Code.Op);
         begin
            if not Plain (Of_Code) then
               return False;
            end if;
            case Of_Code.Op is
               when Load =>
                  return Is_Private (Positive (Of_Code.Slot));
               --  D162: float arithmetic has an IEEE answer for every
               --  operand.  An integer operation traps unless its check
               --  was proved, or is one an `unchecked` region omits.
               --  Integer division is left alone even then, because the
               --  hardware itself refuses a zero divisor.
               when Add | Subtract | Multiply | Negation =>
                  return Of_Code.Result in Landin.Types.Float_Name
                    or else Of_Code.Unchecked;
               when Divide =>
                  return Of_Code.Result in Landin.Types.Float_Name;
               when Conversion =>
                  return Is_Total (Of_Code)
                    or else
                      (Of_Code.Unchecked
                       and then Of_Code.Result in Landin.Types.Integer_Name
                       and then Code_At (Operand (Of_Code, 1)).Result
                         in Landin.Types.Integer_Name);
               when others =>
                  return not Effect.Reads and then not Effect.Writes
                    and then not Effect.Calls and then not Effect.Traps
                    and then not Effect.Control
                    and then not Effect.Adjacency;
            end case;
         end Speculates;

         --  Whether Arm's instructions all qualify, noting in Stored the
         --  slots it stores and in Updates each update it admits.
         function Qualifies
           (Arm : Block_Id; Stored : in out Flags.Elements) return Boolean;

         function Qualifies
           (Arm : Block_Id; Stored : in out Flags.Elements) return Boolean
         is
            Cost : Natural := 0;
         begin
            for V in First_Of (Arm) .. Last_Of (Arm) - 1 loop
               declare
                  Here : constant Instruction := Code_At (V);
               begin
                  case Here.Op is
                     when Store =>
                        declare
                           Slot : constant Positive := Positive (Here.Slot);
                           Stored_Value : constant Value_Id :=
                             Operand (Here, 1);
                        begin
                           if not Is_Private (Slot) or else Updated (Slot)
                           then
                              return False;
                           end if;
                           if Updates (Positive (Stored_Value)) = Here.Slot
                           then
                              --  The update's one use is this store.
                              Updated (Slot) := True;
                           end if;
                           if not Stored (Slot)
                             and then not Stored_Yes (Slot)
                             and then not Stored_No (Slot)
                           then
                              Touched.Append (Slot);
                           end if;
                           Stored (Slot) := True;
                        end;
                     when Load =>
                        --  An update's value goes nowhere but its store.
                        if not Speculates (Here)
                          or else (Stored (Positive (Here.Slot))
                                   and then Updated (Positive (Here.Slot)))
                        then
                           return False;
                        end if;
                        Fresh (Positive (V)) :=
                          not Stored (Positive (Here.Slot));
                     when Add | Subtract | Wrapping_Add | Wrapping_Subtract
                     =>
                        --  x = x + k, from the value x had before the arm,
                        --  with k computed in the arm and the sum stored
                        --  straight back, is an update; anything else is
                        --  computed either way when it cannot trap.
                        declare
                           Left : constant Instruction :=
                             Code_At (Operand (Here, 1));
                           Right : constant Instruction :=
                             Code_At (Operand (Here, 2));
                           Next : constant Value_Id := V + 1;
                           Slot : Slot_Id := No_Slot;
                        begin
                           if Left.Op = Load
                             and then Fresh (Positive (Operand (Here, 1)))
                           then
                              Slot := Left.Slot;
                           elsif Here.Op in Add | Wrapping_Add
                             and then Right.Op = Load
                             and then Fresh (Positive (Operand (Here, 2)))
                           then
                              Slot := Right.Slot;
                           end if;
                           if Here.Result in Landin.Types.Integer_Name
                             and then Slot /= No_Slot
                             and then Uses (Positive (V)) = 1
                             and then Next < Last_Of (Arm)
                             and then Code_At (Next).Op = Store
                             and then Code_At (Next).Slot = Slot
                             and then not Stored (Positive (Slot))
                           then
                              Updates (Positive (V)) := Slot;
                           elsif not Speculates (Here) then
                              return False;
                           end if;
                           Cost := Cost + 1;
                        end;
                     when others =>
                        if not Speculates (Here) then
                           return False;
                        end if;
                        if Here.Op not in Number | Truth then
                           Cost := Cost + 1;
                        end if;
                  end case;
               end;
            end loop;
            return Cost <= Arm_Limit;
         end Qualifies;

         function Resolve (Value : Ref) return Value_Id;

         --  Where each planned instruction went in the new vectors.
         Early_Map, Late_Map : Value_Vectors.Vector;
         New_Of_Owner : constant Values.Owner :=
           Values.Create (Old.Values.Count);
         New_Of : Values.Elements renames New_Of_Owner.Data.all;

         function Resolve (Value : Ref) return Value_Id
           is (case Value.Kind is
                  when Old_Value => New_Of (Value.Index),
                  when Early => Early_Map (Value.Index),
                  when Late => Late_Map (Value.Index));

         --  Plan one instruction, its operands those given.
         procedure Add
           (Group : in out Planned_Vectors.Vector;
            Made : Instruction;
            Operands : Ref_Vectors.Vector);

         procedure Add
           (Group : in out Planned_Vectors.Vector;
            Made : Instruction;
            Operands : Ref_Vectors.Vector)
         is
            Held_Code : Instruction := Made;
         begin
            Held_Code.Args := Natural (Operands.Length);
            Group.Append
              (Planned'(Code => Held_Code,
                        First => Natural (Plan_Args.Length)));
            Plan_Args.Append (Operands);
         end Add;

         --  The same, answering how a later operand names it.
         function Plan
           (Group : in out Planned_Vectors.Vector;
            Kind : Ref_Kind;
            Made : Instruction;
            Operands : Ref_Vectors.Vector) return Ref;

         function Plan
           (Group : in out Planned_Vectors.Vector;
            Kind : Ref_Kind;
            Made : Instruction;
            Operands : Ref_Vectors.Vector) return Ref is
         begin
            Add (Group, Made, Operands);
            return (Kind => Kind, Index => Natural (Group.Length));
         end Plan;

         function One (First : Ref) return Ref_Vectors.Vector
           is (Ref_Vectors.To_Vector (First, 1));

         function Two (First, Second : Ref) return Ref_Vectors.Vector;

         function Two (First, Second : Ref) return Ref_Vectors.Vector is
         begin
            return Result : Ref_Vectors.Vector := One (First) do
               Result.Append (Second);
            end return;
         end Two;

         function Three (First, Second, Third : Ref)
           return Ref_Vectors.Vector;

         function Three (First, Second, Third : Ref)
           return Ref_Vectors.Vector is
         begin
            return Result : Ref_Vectors.Vector := Two (First, Second) do
               Result.Append (Third);
            end return;
         end Three;

         --  Copy Arm's instructions into the plan: what can be computed
         --  either way goes early, an admitted update and its choice of
         --  addend go late.  Last holds each stored slot's final value.
         procedure Copy_Arm
           (Arm : Block_Id; Yes : Boolean; Condition : Ref;
            Last : in out Refs.Elements);

         procedure Copy_Arm
           (Arm : Block_Id; Yes : Boolean; Condition : Ref;
            Last : in out Refs.Elements) is
         begin
            for V in First_Of (Arm) .. Last_Of (Arm) - 1 loop
               declare
                  Here : constant Instruction := Code_At (V);
                  Operands : Ref_Vectors.Vector;
               begin
                  for A in 1 .. Here.Args loop
                     Operands.Append (Copy (Positive (Operand (Here, A))));
                  end loop;
                  if Here.Op = Store then
                     Last (Positive (Here.Slot)) := Operands (1);
                     if Store_Of (Positive (Here.Slot)) = No_Value then
                        Store_Of (Positive (Here.Slot)) := V;
                     end if;
                  elsif Here.Op = Load
                    and then not Fresh (Positive (V))
                  then
                     Copy (Positive (V)) := Last (Positive (Here.Slot));
                  elsif Updates (Positive (V)) /= No_Slot then
                     declare
                        Slot : constant Slot_Id := Updates (Positive (V));
                        Loaded_Left : constant Boolean :=
                          Code_At (Operand (Here, 1)).Op = Load
                          and then Code_At (Operand (Here, 1)).Slot = Slot
                          and then Fresh (Positive (Operand (Here, 1)));
                        Addend : constant Ref :=
                          Operands (if Loaded_Left then 2 else 1);
                        Zero : constant Ref := Plan
                          (Early_Plan, Early,
                           Instruction'(Op => Number,
                                        Result => Here.Result,
                                        Site => Here.Site,
                                        Number => 0,
                                        Negated => False,
                                        others => <>),
                           Ref_Vectors.Empty_Vector);
                        Chosen : constant Ref := Plan
                          (Late_Plan, Late,
                           Instruction'(Op => Choose,
                                        Result => Here.Result,
                                        Site => Here.Site,
                                        others => <>),
                           (if Yes then Three (Condition, Addend, Zero)
                            else Three (Condition, Zero, Addend)));
                     begin
                        Copy (Positive (V)) := Plan
                          (Late_Plan, Late, Here,
                           (if Loaded_Left
                            then Two (Operands (1), Chosen)
                            else Two (Chosen, Operands (2))));
                     end;
                  else
                     Copy (Positive (V)) :=
                       Plan (Early_Plan, Early, Here, Operands);
                  end if;
               end;
            end loop;
         end Copy_Arm;

         --  Whether Head computes Condition from a slot the arms store,
         --  loaded or as the value Head stored there: the choice of that
         --  slot's next value would then wait for the comparison, which
         --  waits for the value chosen before, a chain a predicted branch
         --  does not wait on.  `inc at if at == n then at = 0 end if` in
         --  a loop is one; a count, whose condition reads anything but the
         --  count, is not.
         function Recurs (Head : Block_Id; Condition : Value_Id)
           return Boolean;

         function Recurs (Head : Block_Id; Condition : Value_Id)
           return Boolean
         is
            Found : Boolean := False;
            Position : Positive := 1;
         begin
            Kept_List.Clear;
            for V in First_Of (Head) .. Last_Of (Head) loop
               declare
                  Here : constant Instruction := Code_At (V);
               begin
                  if Here.Op = Store
                    and then (Stored_Yes (Positive (Here.Slot))
                              or else Stored_No (Positive (Here.Slot)))
                  then
                     Kept (Positive (Operand (Here, 1))) := True;
                     Kept_List.Append (Positive (Operand (Here, 1)));
                  end if;
               end;
            end loop;
            Walk.Clear;
            Walk.Append (Positive (Condition));
            Seen (Positive (Condition)) := True;
            while Position <= Natural (Walk.Length) loop
               declare
                  Here : constant Instruction :=
                    Code_At (Value_Id (Walk (Position)));
               begin
                  if Kept (Walk (Position))
                    or else (Here.Op = Load
                             and then (Stored_Yes (Positive (Here.Slot))
                                       or else Stored_No
                                         (Positive (Here.Slot))))
                  then
                     Found := True;
                  end if;
                  for A in 1 .. Here.Args loop
                     if not Seen (Positive (Operand (Here, A))) then
                        Seen (Positive (Operand (Here, A))) := True;
                        Walk.Append (Positive (Operand (Here, A)));
                     end if;
                  end loop;
               end;
               Position := Position + 1;
            end loop;
            for Each of Walk loop
               Seen (Each) := False;
            end loop;
            for Each of Kept_List loop
               Kept (Each) := False;
            end loop;
            return Found;
         end Recurs;

         --  Plan the conversion of Head's branch, if it qualifies.
         procedure Consider (Head : Block_Id);

         procedure Consider (Head : Block_Id) is
            Branch : constant Value_Id := Last_Of (Head);
            Last : constant Instruction := Code_At (Branch);
            Condition_Value : constant Value_Id := Operand (Last, 1);

            --  An arm is the block a side leads to when only Head leads
            --  there and it ends in a jump; otherwise the side has none.
            --  Lowering may put blocks that only jump before it, as an
            --  `else` has, which it passes while each is the only way in.
            function Arm_Of (Side : Block_Id) return Block_Id;

            function Arm_Of (Side : Block_Id) return Block_Id is
               At_Block : Block_Id := Side;
            begin
               if Side = Head or else not Only_From (Side, Head) then
                  return No_Block;
               end if;
               for Step in 1 .. Thread_Limit loop
                  declare
                     Ending : constant Instruction :=
                       Code_At (Last_Of (At_Block));
                  begin
                     exit when Ending.Op /= Jump
                       or else First_Of (At_Block) /= Last_Of (At_Block)
                       or else Ending.Target in Head | At_Block
                       or else not Only_From (Ending.Target, At_Block);
                     At_Block := Ending.Target;
                  end;
               end loop;
               return (if Code_At (Last_Of (At_Block)).Op = Jump
                       then At_Block else No_Block);
            end Arm_Of;

            Yes_Arm : constant Block_Id := Arm_Of (Last.Target);
            No_Arm : constant Block_Id := Arm_Of (Last.Alternative);

            function Meets (Side, Arm : Block_Id) return Block_Id
              is (if Arm = No_Block then Thread (Side)
                  else Thread (Code_At (Last_Of (Arm)).Target));

            Join : constant Block_Id := Meets (Last.Target, Yes_Arm);
            Chosen : Natural := 0;
            Fits : Boolean;
         begin
            if Last.Target = Last.Alternative
              or else Join /= Meets (Last.Alternative, No_Arm)
              or else Join in Head | Yes_Arm | No_Arm
            then
               return;
            end if;
            Touched.Clear;
            Fits :=
              (Yes_Arm = No_Block or else Qualifies (Yes_Arm, Stored_Yes))
              and then (No_Arm = No_Block
                        or else Qualifies (No_Arm, Stored_No));
            for Each of Touched loop
               declare
                  Slot : constant Positive := Each;
               begin
                  Chosen := Chosen + 1;
                  --  An update needs its slot left alone by the other arm.
                  if Updated (Slot) and then Stored_Yes (Slot)
                    and then Stored_No (Slot)
                  then
                     Fits := False;
                  end if;
               end;
            end loop;
            if Fits and then Chosen <= Choice_Limit
              and then not Recurs (Head, Condition_Value)
            then
               declare
                  Condition : constant Ref :=
                    (Kind => Old_Value, Index => Positive (Condition_Value));
                  Plan_Here : Rewrite :=
                    (Head => Head,
                     Before =>
                       (if Condition_Value = Branch - 1
                        then Condition_Value else Branch),
                     Branch => Branch,
                     Join => Join,
                     Early_First => Natural (Early_Plan.Length),
                     Late_First => Natural (Late_Plan.Length),
                     others => <>);
               begin
                  if Yes_Arm /= No_Block then
                     Copy_Arm (Yes_Arm, True, Condition, Last_Yes);
                  end if;
                  if No_Arm /= No_Block then
                     Copy_Arm (No_Arm, False, Condition, Last_No);
                  end if;
                  for Each of Touched loop
                     declare
                        Slot : constant Positive := Each;
                        Store : constant Instruction :=
                          Code_At (Store_Of (Slot));
                        Before : Ref := No_Ref;

                        function Value_Of
                          (Stored : Boolean; Last_Value : Ref) return Ref;

                        function Value_Of
                          (Stored : Boolean; Last_Value : Ref) return Ref is
                        begin
                           if Stored then
                              return Last_Value;
                           end if;
                           if Before = No_Ref then
                              Before := Plan
                                (Early_Plan, Early,
                                 Instruction'
                                   (Op => Load,
                                    Result => Into.Slots.Element
                                      (Old.Slots.First + Slot).Of_Type,
                                    Site => Store.Site,
                                    Slot => Slot_Id (Slot),
                                    others => <>),
                                 Ref_Vectors.Empty_Vector);
                           end if;
                           return Before;
                        end Value_Of;

                        Final : Ref;
                     begin
                        if Updated (Slot) then
                           Final := (if Stored_Yes (Slot) then Last_Yes (Slot)
                                     else Last_No (Slot));
                        else
                           declare
                              If_Yes : constant Ref :=
                                Value_Of (Stored_Yes (Slot), Last_Yes (Slot));
                              If_No : constant Ref :=
                                Value_Of (Stored_No (Slot), Last_No (Slot));
                           begin
                              Final :=
                                (if If_Yes = If_No then If_Yes
                                 else Plan
                                   (Late_Plan, Late,
                                    Instruction'(Op => Choose,
                                                 Result => Into.Slots.Element
                                                   (Old.Slots.First + Slot)
                                                   .Of_Type,
                                                 Site => Store.Site,
                                                 others => <>),
                                    Three (Condition, If_Yes, If_No)));
                           end;
                        end if;
                        Add (Late_Plan, Store, One (Final));
                     end;
                  end loop;
                  Plan_Here.Early_Count :=
                    Natural (Early_Plan.Length) - Plan_Here.Early_First;
                  Plan_Here.Late_Count :=
                    Natural (Late_Plan.Length) - Plan_Here.Late_First;
                  Plans.Append (Plan_Here);
                  Plan_Of (Positive (Head)) := Natural (Plans.Length);
               end;
            end if;
            for Each of Touched loop
               Stored_Yes (Each) := False;
               Stored_No (Each) := False;
               Updated (Each) := False;
               Store_Of (Each) := No_Value;
            end loop;
         end Consider;

         --  Append one instruction to Block in the new vectors.
         function Put (Made : Instruction; Block : Block_Id) return Value_Id;

         function Put (Made : Instruction; Block : Block_Id) return Value_Id
         is
            At_Block : constant Positive :=
              Held.Blocks.First + Positive (Block);
            Placed : Block_Record := Blocks (At_Block);
            Now : Instruction := Made;
         begin
            Now.In_Block := Block;
            if Placed.Values = 0 then
               Placed.First_Value := Natural (Code.Length);
            end if;
            Placed.Values := Placed.Values + 1;
            Blocks.Replace_Element (At_Block, Placed);
            Code.Append (Now);
            Held.Values.Count := Held.Values.Count + 1;
            return Value_Id (Held.Values.Count);
         end Put;

         procedure Put_Planned
           (Group : Planned_Vectors.Vector; First, Count : Natural;
            Map : in out Value_Vectors.Vector; Block : Block_Id);

         procedure Put_Planned
           (Group : Planned_Vectors.Vector; First, Count : Natural;
            Map : in out Value_Vectors.Vector; Block : Block_Id) is
         begin
            for P in First + 1 .. First + Count loop
               declare
                  Made : Instruction := Group (P).Code;
               begin
                  Made.First_Arg := Natural (Args.Length);
                  for A in 1 .. Made.Args loop
                     Args.Append (Resolve (Plan_Args (Group (P).First + A)));
                  end loop;
                  Map.Replace_Element (P, Put (Made, Block));
               end;
            end loop;
         end Put_Planned;
      begin
         for S in Is_Private'Range loop
            declare
               Slot : constant Slot_Record :=
                 Into.Slots.Element (Old.Slots.First + S);
            begin
               Is_Private (S) :=
                 not Slot.Aggregate and then not Slot.Array_Shape
                 and then not Slot.Addressed
                 and then Slot.Signature = No_Signature
                 and then Slot.Atom_Set = No_Atom_Set
                 and then Slot.Pointee = No_Pointee;
            end;
         end loop;
         for V in 1 .. Old.Values.Count loop
            declare
               Here : constant Instruction := Code_At (Value_Id (V));

               procedure Pin (Place : Storage);

               procedure Pin (Place : Storage) is
               begin
                  case Place.Kind is
                     when Frame_Slot =>
                        if Place.Slot /= No_Slot then
                           Is_Private (Positive (Place.Slot)) := False;
                        end if;
                     when Runtime_Address =>
                        if Place.Address /= No_Slot then
                           Is_Private (Positive (Place.Address)) := False;
                        end if;
                     when Module_Datum => null;
                  end case;
               end Pin;
            begin
               Pin (Here.Source);
               Pin (Here.Destination);
               if Here.Slot /= No_Slot and then Here.Op not in Load | Store
               then
                  Is_Private (Positive (Here.Slot)) := False;
               end if;
               for A in 1 .. Here.Assembly_Run.Count loop
                  declare
                     Output : constant Slot_Id :=
                       Into.Assembly_Operands.Element
                         (Here.Assembly_Run.First + A).Output;
                  begin
                     if Output /= No_Slot then
                        Is_Private (Positive (Output)) := False;
                     end if;
                  end;
               end loop;
               for A in 1 .. Here.Args loop
                  Uses (Positive (Operand (Here, A))) :=
                    Uses (Positive (Operand (Here, A))) + 1;
               end loop;
            end;
         end loop;
         for B in 1 .. Old.Blocks.Count loop
            if Old.Kind = Routine and then not Old.External
              and then Control_Flow.Is_Reachable (Graph, Block_Id (B))
              and then Code_At (Last_Of (Block_Id (B))).Op = Branch
            then
               Consider (Block_Id (B));
            end if;
         end loop;

         Early_Map := Value_Vectors.To_Vector (No_Value, Early_Plan.Length);
         Late_Map := Value_Vectors.To_Vector (No_Value, Late_Plan.Length);
         Changed := Changed or else not Plans.Is_Empty;
         Held.Blocks := (First => Natural (Blocks.Length),
                         Count => Old.Blocks.Count);
         Held.Values := (First => Natural (Code.Length), Count => 0);
         for B in 1 .. Old.Blocks.Count loop
            declare
               Block : Block_Record :=
                 Into.Blocks.Element (Old.Blocks.First + B);
            begin
               Block.First_Value := 0;
               Block.Values := 0;
               Blocks.Append (Block);
            end;
         end loop;
         for V in 1 .. Old.Values.Count loop
            declare
               Was : constant Instruction := Code_At (Value_Id (V));
               Which : constant Natural := Plan_Of (Positive (Was.In_Block));
               Now : Instruction := Was;
            begin
               if Which /= 0 and then Value_Id (V) = Plans (Which).Before then
                  Put_Planned
                    (Early_Plan, Plans (Which).Early_First,
                     Plans (Which).Early_Count, Early_Map,
                     Was.In_Block);
               end if;
               if Which /= 0 and then Value_Id (V) = Plans (Which).Branch
               then
                  Put_Planned
                    (Late_Plan, Plans (Which).Late_First,
                     Plans (Which).Late_Count, Late_Map,
                     Was.In_Block);
                  Now.Op := Jump;
                  Now.Target := Plans (Which).Join;
                  Now.Alternative := No_Block;
                  Now.Args := 0;
                  Now.First_Arg := Natural (Args.Length);
               else
                  Now.First_Arg := Natural (Args.Length);
                  for A in 1 .. Was.Args loop
                     Args.Append (New_Of (Positive (Operand (Was, A))));
                  end loop;
                  Now.Assembly_Run :=
                    (First => Natural (Assembled.Length),
                     Count => Was.Assembly_Run.Count);
                  for A in 1 .. Was.Assembly_Run.Count loop
                     Assembled.Append
                       (Into.Assembly_Operands.Element
                          (Was.Assembly_Run.First + A));
                  end loop;
               end if;
               New_Of (V) := Put (Now, Was.In_Block);
            end;
         end loop;
         Items.Replace_Element (Positive (Item), Held);
      end Convert;
   begin
      if Objective = Landin.Optimization.None then
         return;
      end if;
      for I in 1 .. Item_Count (Into) loop
         Convert (Item_Id (I));
      end loop;
      if not Changed then
         return;
      end if;
      Into.Items.Move (Items);
      Into.Code.Move (Code);
      Into.Operands.Move (Args);
      Into.Assembly_Operands.Move (Assembled);
      Into.Blocks.Move (Blocks);
      --  Nothing reaches a converted arm any longer.
      Rewriting.Compact
        (Into,
         Rewriting.Keep_Vectors.To_Vector (True, Into.Code.Length));
      Verifier.Verify (Into, Facts);
   end Run_On_Verified;
end Landin.IR.If_Conversion;
