with Ada.Containers.Vectors;
with Ada.Unchecked_Deallocation;

with Landin.Checking;
with Landin.Cleanup;
with Landin.Diagnostics.Checking;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Syntax.Forest;
with Landin.Tokens;
with Landin.Types;

package body Landin.Stages.Checking.References is

   package Bad renames Landin.Diagnostics.Checking;
   package Res renames Landin.Resolution;
   package Syn renames Landin.Syntax;
   package Ty renames Landin.Types;

   use type Landin.Checking.Element_Count;
   use type Landin.Checking.Conformance_Id;
   use type Landin.Checking.Nominal_Type_Id;
   use type Landin.Checking.Routine_Instance_Id;
   use type Landin.Checking.Signature_Id;
   use type Landin.Checking.Text_Conversion_Kind;
   use type Landin.Provenance.Declaration_Id;
   use type Res.Application_Class;
   use type Res.Argument_Role;
   use type Res.Declaration_Sort;
   use type Res.Verdict;
   use type Landin.Source.Byte_Offset;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Tokens.Assignment_Operator;
   use type Landin.Source.Source_Id;
   use type Syn.Node_Id;
   use type Syn.Node_Kind;
   use type Syn.Parameter_Convention;
   use type Ty.Type_Kind;
   use type Ty.Magnitude;

   procedure Check_Function
     (Context       : in out Compilation;
      Of_Tree       : Syn.Tree;
      Function_Node : Syn.Node_Id;
      Body_Node     : Syn.Node_Id;
      Into          : in out Landin.Diagnostics.Diagnostic_List)
   is
      Trees : constant not null access Syn.Forest.Table :=
        Landin.Stages.Trees (Context);
      Meanings : constant not null access Res.Table :=
        Landin.Stages.Meanings (Context);
      Types : constant not null access Landin.Checking.Table :=
        Landin.Stages.Types (Context);
      Declarations : constant Positive := Positive'Max
        (1, Res.Declaration_Count (Meanings.all));
      Parameters : constant Positive := Positive'Max
        (1, Syn.Parameter_Count (Of_Tree, Function_Node));

      type Parameter_Bits is array (Positive range 1 .. Parameters) of Boolean
        with Pack;
      type Declaration_Bits is
        array (Positive range 1 .. Declarations) of Boolean
        with Pack;

      --  Absence is a value proof, not an origin.  In this finite chain,
      --  No_Edge is the join identity, Empty_Optional proves absence, and
      --  Unknown_Value includes present pointers with no tracked sources.
      --  Only control-value accumulators start at No_Edge; No_Origin alone
      --  never proves emptiness.  Untracked still belongs exclusively to
      --  [0470]'s address conversion: an empty sibling must not launder a
      --  present sibling's frame or parameter origins.
      type Value_Fact is (No_Edge, Empty_Optional, Unknown_Value);

      type Reference_Fact is record
         Frame      : Boolean := False;
         Untracked  : Boolean := False;
         From       : Parameter_Bits := [others => False];
         Derives    : Declaration_Bits := [others => False];
         Presence   : Value_Fact := Unknown_Value;
      end record;

      No_Reference : constant Reference_Fact := (others => <>);

      package Result_Facts is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Reference_Fact);

      --  Keep a place's evaluated backing separately from its value: an
      --  index may mutate the descriptor after its address was captured.
      --  Anonymous multiple results additionally retain each position's
      --  sources; their union alone cannot validate distinct `from` clauses.
      type Origin_Fact is record
         Value   : Reference_Fact := No_Reference;
         Storage : Reference_Fact := No_Reference;
         Results : Result_Facts.Vector;
      end record;

      No_Origin : constant Origin_Fact := (others => <>);
      No_Value_Edge : constant Origin_Fact :=
        (Value => (Presence => No_Edge, others => <>), others => <>);
      Empty_Origin : constant Origin_Fact :=
        (Value => (Presence => Empty_Optional, others => <>), others => <>);
      --  Known alias stores join origins, but calls can still write through
      --  aliases. Never reuse an empty-value proof for storage exposed in
      --  this body, or for module state which another call can change.
      Exposed : Declaration_Bits := [others => False];
      type Origin_Table is
        array (Res.Declaration_Id range <>) of Origin_Fact;
      Origins : Origin_Table
        (Res.Declaration_Id'(1)
         .. Res.Declaration_Id (Res.Declaration_Count (Meanings.all))) :=
           [others => No_Origin];
      --  A pattern binding's value and its backing storage can have distinct
      --  origins.  Computed value subjects are copied into a frame temporary;
      --  referenced subjects retain their actual storage.  A reference value
      --  carried in either payload still points where the subject said.
      Pattern_Storage : array (Origins'Range) of Reference_Fact :=
        [others => No_Reference];
      Pattern_Subject : array (Origins'Range) of Syn.Node_Id :=
        [others => Syn.No_Node];
      Pattern_Block : array (Origins'Range) of Syn.Node_Id :=
        [others => Syn.No_Node];
      Falls_Through : Boolean := True;
      Parameter_Of : array (Origins'Range) of Natural := [others => 0];
      Parameter_Escapes : array (1 .. Parameters) of Boolean :=
        [others => False];

      Signature : constant Landin.Checking.Signature_Id :=
        Landin.Checking.Signature_Of
          (Types.all, Of_Tree, Function_Node);

      --  Where a diagnostic goes.  A loop body is analysed repeatedly
      --  until its facts stop changing, and only the pass made from the
      --  converged facts reports; the earlier passes point Sink at a
      --  scratch list that is thrown away.
      Sink : not null access Landin.Diagnostics.Diagnostic_List :=
        Into'Unchecked_Access;

      subtype Function_Table is Origin_Table (Origins'Range);
      type Function_Table_Access is access Function_Table;

      procedure Free is new Ada.Unchecked_Deallocation
        (Object => Function_Table, Name => Function_Table_Access);

      --  The lexical cleanup stack, kept the way
      --  Landin.Stages.Checking.Flow keeps it: `defer` and `undo` register
      --  syntax, and the call is evaluated on each edge that runs it with
      --  the origin facts of that edge.
      type Cleanup_Entry is record
         Kind   : Landin.Cleanup.Cleanup_Kind := Landin.Cleanup.Deferred_Call;
         Call   : Syn.Node_Id := Syn.No_Node;
         Active : Boolean := True;
      end record;

      package Cleanup_Entries is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Cleanup_Entry);

      Cleanup_Stack : Cleanup_Entries.Vector;

      --  One loop being analysed.  Its `break` edges are joined into
      --  Exit_State and its `continue` edges into Back_State; the loop
      --  handler joins the latter with the body's fallthrough to form the
      --  back edge.  A function table grows quadratically with the number of
      --  declarations because every fact carries declaration-origin bits.
      --  Allocate the uncommon transfer states only when an edge needs one;
      --  embedding both in a vector element makes Append copy program-sized
      --  values on the host stack.
      type Loop_Frame is record
         Label        : Landin.Source.Names.Name_Id :=
           Landin.Source.Names.No_Name;
         Cleanup_Base : Natural := 0;
         Exits        : Boolean := False;
         Exit_State   : Function_Table_Access := null;
         Continues    : Boolean := False;
         Back_State   : Function_Table_Access := null;
         Value        : Origin_Fact := No_Value_Edge;
      end record;

      package Loop_Frames is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Loop_Frame);

      Loop_Stack : Loop_Frames.Vector;

      procedure Release (Frame : in out Loop_Frame);

      procedure Release (Frame : in out Loop_Frame) is
      begin
         Free (Frame.Exit_State);
         Free (Frame.Back_State);
      end Release;

      --  Where the traversal is: the block being processed, the statement
      --  within it, and the loop whose body that block is, if any.  The
      --  borrow check reads the continuation of a call off this stack.
      type Position_Frame is record
         Block   : Syn.Node_Id := Syn.No_Node;
         Index   : Natural := 0;
         Of_Loop : Syn.Node_Id := Syn.No_Node;
      end record;

      package Position_Frames is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Position_Frame);

      Positions : Position_Frames.Vector;

      procedure Join_Table
        (Into_Table : in out Function_Table; Other : Function_Table);

      procedure Run_Cleanups
        (Tree    : Syn.Tree;
         First   : Natural;
         On_Exit : Landin.Cleanup.Exit_Kind);

      function Transfer_Loop
        (Tree : Syn.Tree; Node : Syn.Node_Id) return Positive;

      function Tree_For (Source : Landin.Source.Source_Id)
        return not null access constant Syn.Tree
        is (Syn.Forest.Tree_Of (Trees.all, Source));

      function Declaration_At
        (Tree : Syn.Tree; Node : Syn.Node_Id) return Res.Declaration_Id;

      function Root_Declaration
        (Tree : Syn.Tree; Node : Syn.Node_Id) return Res.Declaration_Id;

      function Has_References (Id : Res.Declaration_Id) return Boolean;
      function Has_References
        (Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Match_Subject_Is_Copied
        (Tree : Syn.Tree; Subject : Syn.Node_Id) return Boolean;

      function Named_Storage_Fact
        (Tree : Syn.Tree; Place : Syn.Node_Id) return Reference_Fact;

      function Fact_Of
        (Tree : Syn.Tree; Node : Syn.Node_Id) return Origin_Fact;

      function Call_Signature
        (Tree : Syn.Tree; Call : Syn.Node_Id)
         return Landin.Checking.Signature_Id;

      function Runtime_Argument
        (Tree : Syn.Tree;
         Call : Syn.Node_Id;
         Formal : Positive) return Syn.Node_Id;

      procedure Note_Exposed_Storage (Tree : Syn.Tree; Node : Syn.Node_Id);

      function First_Derivation
        (Fact : Reference_Fact) return Res.Declaration_Id;

      procedure Report_Escape
        (Tree : Syn.Tree;
         Node : Syn.Node_Id;
         Fact : Reference_Fact;
         Message : String;
         Related : Landin.Provenance.Origin);

      --  The facts of a call's written arguments, each walked exactly
      --  once so a nested call inside an argument is checked once.
      type Known_Argument is record
         Node : Syn.Node_Id := Syn.No_Node;
         Fact : Origin_Fact := No_Origin;
      end record;
      type Argument_Facts is array (Positive range <>) of Known_Argument;

      function Known_Fact
        (Tree : Syn.Tree; Known : Argument_Facts; Node : Syn.Node_Id)
         return Origin_Fact;

      procedure Check_Escaping_Arguments
        (Tree : Syn.Tree; Call : Syn.Node_Id; Known : Argument_Facts);

      function Has_Future_Use
        (Borrower : Res.Declaration_Id;
         After    : Landin.Source.Byte_Offset) return Boolean;

      procedure Check_Borrows
        (Tree : Syn.Tree; Call : Syn.Node_Id; Known : Argument_Facts);
      function Check_Payload_Borrows
        (Tree : Syn.Tree; Place : Syn.Node_Id;
         After : Landin.Source.Byte_Offset; Storage : Reference_Fact)
         return Boolean;

      procedure Check_Returns (Tree : Syn.Tree; At_Node : Syn.Node_Id);

      procedure Assign
        (Tree : Syn.Tree; Place : Syn.Node_Id; Value : Syn.Node_Id);

      procedure Process_Statement (Tree : Syn.Tree; Node : Syn.Node_Id);

      --  The fact of the value a control construct produced, for
      --  Fact_Of when an if, match, loop or block sits in expression
      --  position: its statements are processed exactly as in statement
      --  position, and its value is what its blocks or `break with`
      --  edges left here.
      Statement_Value : Origin_Fact := No_Origin;

      procedure Process_Block
        (Tree         : Syn.Tree;
         Block        : Syn.Node_Id;
         Fell_Through : out Boolean;
         Of_Loop      : Syn.Node_Id := Syn.No_Node);

      procedure Join
        (Into_Fact : in out Reference_Fact; Other : Reference_Fact);

      procedure Join (Into_Fact : in out Origin_Fact; Other : Origin_Fact);

      function Nth_Result (Fact : Origin_Fact; Position : Positive)
        return Origin_Fact;

      function Nth_Result (Fact : Origin_Fact; Position : Positive)
        return Origin_Fact is
      begin
         return
           (Value => (if Position <= Fact.Results.Last_Index
                      then Fact.Results (Position) else Fact.Value),
            Storage => Fact.Storage, others => <>);
      end Nth_Result;

      procedure Join
        (Into_Fact : in out Reference_Fact; Other : Reference_Fact) is
      begin
         Into_Fact.Presence :=
           Value_Fact'Max (Into_Fact.Presence, Other.Presence);
         Into_Fact.Frame := Into_Fact.Frame or Other.Frame;
         Into_Fact.Untracked := Into_Fact.Untracked or Other.Untracked;
         --  An explicitly untracked alternative cannot erase a tracked
         --  frame or parameter origin contributed by another alternative.
         if Into_Fact.Frame then
            Into_Fact.Untracked := False;
         end if;
         for Position in Into_Fact.From'Range loop
            Into_Fact.From (Position) :=
              Into_Fact.From (Position) or Other.From (Position);
            if Into_Fact.From (Position) then
               Into_Fact.Untracked := False;
            end if;
         end loop;
         for Id in Into_Fact.Derives'Range loop
            Into_Fact.Derives (Id) :=
              Into_Fact.Derives (Id) or Other.Derives (Id);
         end loop;
      end Join;

      procedure Join (Into_Fact : in out Origin_Fact; Other : Origin_Fact) is
      begin
         if Into_Fact.Value.Presence = No_Edge then
            Into_Fact := Other;
            return;
         elsif Other.Value.Presence = No_Edge then
            return;
         end if;
         if Into_Fact.Results.Last_Index = Other.Results.Last_Index then
            for Position in 1 .. Into_Fact.Results.Last_Index loop
               declare
                  Part : Reference_Fact := Into_Fact.Results (Position);
               begin
                  Join (Part, Other.Results (Position));
                  Into_Fact.Results.Replace_Element (Position, Part);
               end;
            end loop;
         else
            --  A value without positional facts is conservatively described
            --  by its union, not by whichever sibling retained more detail.
            Into_Fact.Results.Clear;
         end if;
         Join (Into_Fact.Value, Other.Value);
         Join (Into_Fact.Storage, Other.Storage);
      end Join;

      function Declaration_At
        (Tree : Syn.Tree; Node : Syn.Node_Id) return Res.Declaration_Id is
      begin
         for Id in Origins'Range loop
            if Res.Source_Of (Meanings.all, Id) = Syn.Source_Of (Tree)
              and then Res.Node_Of (Meanings.all, Id) = Node
            then
               return Id;
            end if;
         end loop;
         return Res.No_Declaration;
      end Declaration_At;

      function Root_Declaration
        (Tree : Syn.Tree; Node : Syn.Node_Id) return Res.Declaration_Id
      is
         Root : Syn.Node_Id := Node;
      begin
         while Syn.Kind (Tree, Root)
           in Syn.Member_Selection | Syn.Element_Index
              | Syn.Inclusive_Slice | Syn.Half_Open_Slice
         loop
            Root := Syn.Target_Of (Tree, Root);
         end loop;
         if Syn.Kind (Tree, Root) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Tree, Root) = Res.Bound
         then
            return Res.Bound_To (Meanings.all, Tree, Root);
         end if;
         return Res.No_Declaration;
      end Root_Declaration;

      function Has_References (Id : Res.Declaration_Id) return Boolean is
         Kind : constant Ty.Type_Kind :=
           Landin.Checking.Type_Of (Types.all, Id);
      begin
         if Kind in Ty.Pointer_Value | Ty.Slice_Value | Ty.Any_Value then
            return True;
         elsif Kind = Ty.Aggregate then
            declare
               Nominal : constant Landin.Checking.Nominal_Type_Id :=
                 Landin.Checking.Nominal_Of (Types.all, Id);
               Shape : constant Landin.Checking.Signature_Id :=
                 Landin.Checking.Result_Shape_Of (Types.all, Id);
            begin
               if Landin.Checking.Holds (Types.all, Shape) then
                  for Position in
                    1 .. Landin.Checking.Signature_Result_Count
                      (Types.all, Shape)
                  loop
                     if Landin.Checking.Contains_References
                       (Types.all, Landin.Checking.Nth_Signature_Result
                          (Types.all, Shape, Position))
                     then
                        return True;
                     end if;
                  end loop;
                  return False;
               end if;
               return Nominal /= Landin.Checking.No_Nominal_Type
                 and then Landin.Checking.Has_Layout (Types.all, Nominal)
                 and then Landin.Checking.Contains_References
                   (Types.all, Nominal);
            end;
         elsif Kind = Ty.Fixed_Array then
            return Landin.Checking.Array_Length (Types.all, Id) > 0
              and then Landin.Checking.Contains_References
                (Types.all,
                 Landin.Checking.Array_Element_Shape (Types.all, Id));
         end if;
         return False;
      end Has_References;

      function Has_References
        (Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
         Kind : constant Ty.Type_Kind :=
           Landin.Checking.Type_Of (Types.all, Tree, Node);
      begin
         if Kind in Ty.Pointer_Value | Ty.Slice_Value | Ty.Any_Value then
            return True;
         elsif Kind = Ty.Not_Typed
           and then Syn.Kind (Tree, Node) = Syn.Member_Selection
           and then Landin.Checking.Field_Index (Types.all, Tree, Node) > 0
         then
            --  A variant destination carries a field descriptor rather
            --  than a general expression type.
            return Landin.Checking.Contains_References
              (Types.all, Landin.Checking.Field_Shape_Of
                 (Types.all, Landin.Checking.Nominal_Of
                    (Types.all, Tree, Syn.Target_Of (Tree, Node)),
                  Landin.Checking.Field_Index (Types.all, Tree, Node)));
         elsif Kind = Ty.Aggregate then
            declare
               Nominal : constant Landin.Checking.Nominal_Type_Id :=
                 Landin.Checking.Nominal_Of (Types.all, Tree, Node);
               Shape : constant Landin.Checking.Signature_Id :=
                 Landin.Checking.Result_Shape_Of (Types.all, Tree, Node);
            begin
               if Landin.Checking.Holds (Types.all, Shape) then
                  for Position in
                    1 .. Landin.Checking.Signature_Result_Count
                      (Types.all, Shape)
                  loop
                     if Landin.Checking.Contains_References
                       (Types.all, Landin.Checking.Nth_Signature_Result
                          (Types.all, Shape, Position))
                     then
                        return True;
                     end if;
                  end loop;
                  return False;
               end if;
               return Nominal /= Landin.Checking.No_Nominal_Type
                 and then Landin.Checking.Has_Layout (Types.all, Nominal)
                 and then Landin.Checking.Contains_References
                   (Types.all, Nominal);
            end;
         elsif Kind = Ty.Fixed_Array then
            return Landin.Checking.Array_Length (Types.all, Tree, Node) > 0
              and then Landin.Checking.Contains_References
                (Types.all, Landin.Checking.Array_Element_Shape
                   (Types.all, Tree, Node));
         end if;
         return False;
      end Has_References;

      function Match_Subject_Is_Copied
        (Tree : Syn.Tree; Subject : Syn.Node_Id) return Boolean
      is
         Where : Syn.Node_Id := Subject;
         Computed : Boolean := False;

         function Is_Constant_Index (Node : Syn.Node_Id) return Boolean;

         function Is_Constant_Index (Node : Syn.Node_Id) return Boolean is
            Written : constant Syn.Node_Id := Syn.Index_Of (Tree, Node);
         begin
            return Syn.Kind (Tree, Written) = Syn.Integer_Literal
              or else
                (Syn.Kind (Tree, Written) = Syn.Negation
                 and then Syn.Kind
                   (Tree, Syn.Operand_Of (Tree, Written))
                     = Syn.Integer_Literal);
         end Is_Constant_Index;
      begin
         if Syn.Kind (Tree, Subject) /= Syn.Member_Selection then
            return False;
         end if;
         Where := Syn.Target_Of (Tree, Subject);
         --  Match Lower_Variant_Match's storage choice: pointer/slice-backed
         --  places and inout parameters retain their captured storage, even
         --  below a computed index.  Only a computed value subject gets
         --  D134's independent frame copy.
         while Syn.Kind (Tree, Where)
           in Syn.Member_Selection | Syn.Element_Index
         loop
            if Syn.Kind (Tree, Where) = Syn.Element_Index
              and then not Is_Constant_Index (Where)
            then
               Computed := True;
            end if;
            if Syn.Kind (Tree, Where) = Syn.Element_Index
              and then Landin.Checking.Type_Of
                (Types.all, Tree, Syn.Target_Of (Tree, Where)) = Ty.Slice_Value
            then
               return False;
            elsif Syn.Kind (Tree, Where) = Syn.Member_Selection
              and then Landin.Checking.Field_Index
                (Types.all, Tree, Where) = 0
              and then Landin.Checking.Type_Of
                (Types.all, Tree, Syn.Target_Of (Tree, Where))
                  = Ty.Pointer_Value
            then
               return False;
            end if;
            Where := Syn.Target_Of (Tree, Where);
         end loop;
         if Syn.Kind (Tree, Where) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Tree, Where) = Res.Bound
         then
            declare
               Id : constant Res.Declaration_Id :=
                 Res.Bound_To (Meanings.all, Tree, Where);
            begin
               if Res.Sort_Of (Meanings.all, Id) = Res.Parameter
                 and then Syn.Convention_Of
                   (Tree_For (Res.Source_Of (Meanings.all, Id)).all,
                    Res.Node_Of (Meanings.all, Id)) = Syn.Inout_Convention
               then
                  return False;
               end if;
            end;
         end if;
         return Computed;
      end Match_Subject_Is_Copied;

      function Call_Signature
        (Tree : Syn.Tree; Call : Syn.Node_Id)
         return Landin.Checking.Signature_Id
      is
         Target : constant Landin.Checking.Routine_Instance_Id :=
           Landin.Checking.Routine_Target_Of (Types.all, Tree, Call);
         Callee : constant Syn.Node_Id := Syn.Callee_Of (Tree, Call);
         Node_Signature : constant Landin.Checking.Signature_Id :=
           Landin.Checking.Signature_Of (Types.all, Tree, Callee);
      begin
         if Target /= Landin.Checking.No_Routine_Instance then
            return Landin.Checking.Routine_Signature_Of (Types.all, Target);
         elsif Node_Signature /= Landin.Checking.No_Signature then
            return Node_Signature;
         elsif Res.Verdict_Of (Meanings.all, Tree, Callee) = Res.Bound
         then
            return Landin.Checking.Signature_Of
              (Types.all, Res.Bound_To (Meanings.all, Tree, Callee));
         end if;
         return Landin.Checking.No_Signature;
      end Call_Signature;

      function Runtime_Argument
        (Tree : Syn.Tree;
         Call : Syn.Node_Id;
         Formal : Positive) return Syn.Node_Id
      is
         Called : constant Landin.Checking.Signature_Id :=
           Call_Signature (Tree, Call);
         Erased_Self : constant Boolean :=
           Syn.Kind (Tree, Syn.Callee_Of (Tree, Call))
             = Syn.Member_Selection
           and then Landin.Checking.Type_Of
             (Types.all, Tree,
              Syn.Target_Of (Tree, Syn.Callee_Of (Tree, Call)))
                = Ty.Any_Value;

         function Plain_Position (Written : Positive) return Natural;

         function Plain_Position (Written : Positive) return Natural is
            Seen : Natural := 0;
            First : constant Positive := (if Erased_Self then 2 else 1);
         begin
            if not Landin.Checking.Holds (Types.all, Called) then
               return 0;
            end if;
            for Position in First .. Landin.Checking.Signature_Parameter_Count
              (Types.all, Called)
            loop
               if not Landin.Checking.Nth_Signature_Parameter
                 (Types.all, Called, Position).Caller
               then
                  Seen := Seen + 1;
                  if Seen = Written then
                     return Position;
                  end if;
               end if;
            end loop;
            return 0;
         end Plain_Position;
      begin
         if not Landin.Checking.Holds (Types.all, Called) then
            return Syn.No_Node;
         end if;
         if Formal = 1
           and then Syn.Kind (Tree, Syn.Callee_Of (Tree, Call))
             = Syn.Member_Selection
           and then Landin.Checking.Type_Of
             (Types.all, Tree,
              Syn.Target_Of (Tree, Syn.Callee_Of (Tree, Call)))
                = Ty.Any_Value
         then
            return Syn.Target_Of (Tree, Syn.Callee_Of (Tree, Call));
         end if;
         for Written in 1 .. Syn.Argument_Count (Tree, Call) loop
            declare
               Raw : constant Syn.Node_Id :=
                 Syn.Nth_Argument (Tree, Call, Written);
               --  Static and runtime formals have separate positions.
               --  A static type argument cannot supply a retained origin.
               Position : constant Natural :=
                 (if Syn.Kind (Tree, Raw) = Syn.Call_Argument
                  then
                    (if Res.Role_Of (Meanings.all, Tree, Raw)
                          = Res.Runtime_Argument
                     then Res.Position_Of (Meanings.all, Tree, Raw)
                     else 0)
                  elsif Called /= Landin.Checking.No_Signature
                  then Plain_Position (Written)
                  else Written);
            begin
               if Position = Formal then
                  return
                    (if Syn.Kind (Tree, Raw) = Syn.Call_Argument
                     then Syn.Expression_Projection (Tree, Raw)
                     else Raw);
               end if;
            end;
         end loop;
         return Syn.No_Node;
      end Runtime_Argument;

      procedure Note_Exposed_Storage (Tree : Syn.Tree; Node : Syn.Node_Id) is
         procedure Expose (Place : Syn.Node_Id);

         procedure Expose (Place : Syn.Node_Id) is
            Id : constant Res.Declaration_Id :=
              (if Place = Syn.No_Node then Res.No_Declaration
               else Root_Declaration (Tree, Place));
         begin
            if Id /= Res.No_Declaration then
               Exposed (Positive (Id)) := True;
            end if;
         end Expose;
      begin
         if Node = Syn.No_Node then
            return;
         elsif Syn.Kind (Tree, Node) = Syn.Address_Of then
            Expose (Syn.Operand_Of (Tree, Node));
         elsif Syn.Kind (Tree, Node) in Syn.Call | Syn.Labeled_Application then
            declare
               Called : constant Landin.Checking.Signature_Id :=
                 Call_Signature (Tree, Node);
            begin
               if Landin.Checking.Holds (Types.all, Called) then
                  for Position in
                    1 .. Landin.Checking.Signature_Parameter_Count
                      (Types.all, Called)
                  loop
                     if Landin.Checking.Nth_Signature_Parameter
                       (Types.all, Called, Position).Convention
                         in Syn.Inout_Convention | Syn.Sink_Convention
                     then
                        Expose (Runtime_Argument (Tree, Node, Position));
                     end if;
                  end loop;
               end if;
            end;
         end if;
         for Slot in 1 .. Syn.Slot_Count (Tree, Node) loop
            Note_Exposed_Storage (Tree, Syn.Slot (Tree, Node, Slot));
         end loop;
         if Syn.Kind (Tree, Node) in Syn.Call | Syn.Labeled_Application
           and then Syn.Recovery_Of (Tree, Node) /= Syn.No_Node
         then
            Note_Exposed_Storage (Tree, Syn.Recovery_Of (Tree, Node));
         end if;
      end Note_Exposed_Storage;

      function First_Derivation (Fact : Reference_Fact)
        return Res.Declaration_Id
      is
      begin
         if Fact.Frame then
            for Id in Origins'Range loop
               if Fact.Derives (Positive (Id))
                 and then Res.Sort_Of (Meanings.all, Id)
                   in Res.Local_Binding | Res.Named_Return
               then
                  return Id;
               end if;
            end loop;
         end if;
         for Id in Origins'Range loop
            if Fact.Derives (Positive (Id)) then
               return Id;
            end if;
         end loop;
         return Res.No_Declaration;
      end First_Derivation;

      procedure Report_Escape
        (Tree : Syn.Tree;
         Node : Syn.Node_Id;
         Fact : Reference_Fact;
         Message : String;
         Related : Landin.Provenance.Origin)
      is
         Derived : constant Res.Declaration_Id := First_Derivation (Fact);
         Place : Landin.Provenance.Origin := Related;
      begin
         if Derived /= Res.No_Declaration then
            declare
               Source_Tree : constant not null access constant Syn.Tree :=
                 Tree_For (Res.Source_Of (Meanings.all, Derived));
            begin
               Place := Syn.Origin
                 (Source_Tree.all, Res.Node_Of (Meanings.all, Derived));
            end;
         end if;
         Bad.Report
           (Item    => Bad.Reference_Escapes,
            Source  => Syn.Source_Of (Tree),
            Where   => Syn.Where (Tree, Node),
            Message => Message,
            Note    => "[0770]/[0780]: frame references cannot escape and"
                       & " a retained parameter is declared `escaping`",
            Related => Place,
            Because => "the shorter-lived reference source",
            Into    => Sink.all);
      end Report_Escape;

      function Known_Fact
        (Tree : Syn.Tree; Known : Argument_Facts; Node : Syn.Node_Id)
         return Origin_Fact is
      begin
         for Each of Known loop
            if Each.Node = Node then
               return Each.Fact;
            end if;
         end loop;
         return Fact_Of (Tree, Node);
      end Known_Fact;

      procedure Check_Escaping_Arguments
        (Tree : Syn.Tree; Call : Syn.Node_Id; Known : Argument_Facts)
      is
         Called : constant Landin.Checking.Signature_Id :=
           Call_Signature (Tree, Call);
      begin
         if not Landin.Checking.Holds (Types.all, Called) then
            return;
         end if;
         for Position in 1 .. Landin.Checking.Signature_Parameter_Count
           (Types.all, Called)
         loop
            declare
               Part : constant Landin.Checking.Signature_Part :=
                 Landin.Checking.Nth_Signature_Parameter
                   (Types.all, Called, Position);
               Argument : constant Syn.Node_Id :=
                 Runtime_Argument (Tree, Call, Position);
            begin
               if Part.Escaping and then Argument /= Syn.No_Node then
                  declare
                     Fact : constant Reference_Fact :=
                       Known_Fact (Tree, Known, Argument).Value;
                  begin
                     if not Fact.Untracked and then Fact.Frame then
                        Report_Escape
                          (Tree, Argument, Fact,
                           "this frame-origin reference cannot be retained"
                           & " beyond the call",
                           Part.Site);
                     elsif not Fact.Untracked then
                        for Source in Fact.From'Range loop
                           if Fact.From (Source)
                             and then not Parameter_Escapes (Source)
                           then
                              Report_Escape
                                (Tree, Argument, Fact,
                                 "this parameter is non-escaping, so its"
                                 & " reference cannot be retained by the"
                                 & " called function",
                                 Part.Site);
                              exit;
                           end if;
                        end loop;
                     end if;
                  end;
               end if;
            end;
         end loop;
      end Check_Escaping_Arguments;

      --  [0830]: a borrow is live while some path from the mutating call
      --  reaches a read of the borrower before an assignment replaces it.
      --  The continuation is read off Positions: the rest of the statement
      --  being evaluated, the rest of each enclosing block, and for a loop
      --  body the back edge -- the loop's test and its body from the top,
      --  which is where a read written above the call executes next.
      function Has_Future_Use
        (Borrower : Res.Declaration_Id;
         After    : Landin.Source.Byte_Offset) return Boolean
      is
         --  What the paths through a run of statements do to the borrow.
         --  Reads: some path reads it before replacing it.  Falls: some
         --  path reaches the end without reading or replacing it.  Breaks
         --  and Continues: some such path leaves through that transfer.
         type Summary is record
            Reads     : Boolean := False;
            Falls     : Boolean := False;
            Breaks    : Boolean := False;
            Continues : Boolean := False;
         end record;

         Reading : constant Summary := (Reads => True, others => False);

         function Reads_In
           (Node : Syn.Node_Id;
            From : Landin.Source.Byte_Offset := 0) return Boolean;
         --  Since is the offset a read must lie at or beyond: the call's
         --  end along the straight-line continuation, where everything
         --  that executes later is written later, and zero along a back
         --  edge, where a read written above the call executes after it.
         function Scan_Statement
           (Node : Syn.Node_Id; Since : Landin.Source.Byte_Offset)
            return Summary;
         function Scan_Statements
           (Block : Syn.Node_Id;
            From  : Positive;
            Since : Landin.Source.Byte_Offset) return Summary;
         function Reads_Around (Loop_Node : Syn.Node_Id) return Boolean;

         function Is_Replacement (Place : Syn.Node_Id) return Boolean
           is (Syn.Kind (Of_Tree, Place) = Syn.Name_Reference
               and then Res.Sort_Of (Meanings.all, Borrower)
                 /= Res.Pattern_Binding
               and then Root_Declaration (Of_Tree, Place) = Borrower);

         procedure Absorb (Into_Summary : in out Summary; Arm : Summary);

         procedure Absorb (Into_Summary : in out Summary; Arm : Summary) is
         begin
            Into_Summary.Falls := Into_Summary.Falls or Arm.Falls;
            Into_Summary.Breaks := Into_Summary.Breaks or Arm.Breaks;
            Into_Summary.Continues := Into_Summary.Continues or Arm.Continues;
         end Absorb;

         --  Whether an expression reads the borrower at or after From.
         --  A plain assignment's target is a replacement, not a read;
         --  nested blocks are searched for reads only, which credits no
         --  replacement inside them and so can only over-report.
         function Reads_In
           (Node : Syn.Node_Id;
            From : Landin.Source.Byte_Offset := 0) return Boolean is
         begin
            if Node = Syn.No_Node
              or else Syn.Kind (Of_Tree, Node) = Syn.Anonymous_Function
            then
               return False;
            end if;

            if Syn.Kind (Of_Tree, Node) = Syn.Assignment then
               if Reads_In (Syn.Value_Of (Of_Tree, Node), From) then
                  return True;
               end if;
               declare
                  Place : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
               begin
                  if Is_Replacement (Place)
                    and then Syn.Assignment_Operation (Of_Tree, Node)
                      = Landin.Tokens.Plain_Assignment
                  then
                     return False;
                  end if;
                  return Reads_In (Place, From);
               end;
            end if;

            if Syn.Kind (Of_Tree, Node) = Syn.Name_Reference
              and then Syn.Where (Of_Tree, Node).First >= From
              and then Res.Verdict_Of (Meanings.all, Of_Tree, Node)
                = Res.Bound
              and then Res.Bound_To (Meanings.all, Of_Tree, Node) = Borrower
            then
               return True;
            end if;

            for Slot in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
               if Reads_In (Syn.Slot (Of_Tree, Node, Slot), From) then
                  return True;
               end if;
            end loop;
            if Syn.Kind (Of_Tree, Node) in Syn.Call | Syn.Labeled_Application
              and then Syn.Recovery_Of (Of_Tree, Node) /= Syn.No_Node
            then
               return Reads_In (Syn.Recovery_Of (Of_Tree, Node), From);
            end if;
            return False;
         end Reads_In;

         function Scan_Statements
           (Block : Syn.Node_Id;
            From  : Positive;
            Since : Landin.Source.Byte_Offset) return Summary
         is
            Result : Summary := (Falls => True, others => False);
         begin
            if Block = Syn.No_Node then
               return Result;
            end if;
            for Position in From .. Syn.Statement_Count (Of_Tree, Block) loop
               exit when not Result.Falls;
               declare
                  Step : constant Summary := Scan_Statement
                    (Syn.Nth_Statement (Of_Tree, Block, Position), Since);
               begin
                  if Step.Reads then
                     return Reading;
                  end if;
                  Result.Breaks := Result.Breaks or Step.Breaks;
                  Result.Continues := Result.Continues or Step.Continues;
                  Result.Falls := Step.Falls;
               end;
            end loop;
            if Result.Falls
              and then Reads_In (Syn.Block_Value (Of_Tree, Block), Since)
            then
               return Reading;
            end if;
            return Result;
         end Scan_Statements;

         function Scan_Statement
           (Node : Syn.Node_Id; Since : Landin.Source.Byte_Offset)
            return Summary
         is
            Result : Summary := (Falls => True, others => False);

            function Guarded return Boolean
              is (Syn.Condition_Of (Of_Tree, Node) /= Syn.No_Node);
         begin
            case Syn.Kind (Of_Tree, Node) is
               when Syn.Binding =>
                  if Reads_In (Syn.Value_Of (Of_Tree, Node), Since) then
                     return Reading;
                  end if;
                  if Declaration_At (Of_Tree, Node) = Borrower then
                     --  A declaration starts a new lifetime on a loop
                     --  back edge. Later reads use that new value.
                     Result.Falls := False;
                  end if;

               when Syn.Assignment =>
                  if Reads_In (Syn.Value_Of (Of_Tree, Node), Since) then
                     return Reading;
                  end if;
                  declare
                     Place : constant Syn.Node_Id :=
                       Syn.Target_Of (Of_Tree, Node);
                  begin
                     if Is_Replacement (Place) then
                        if Syn.Assignment_Operation (Of_Tree, Node)
                          = Landin.Tokens.Plain_Assignment
                        then
                           --  Replaced before any read: this path is done
                           --  with the borrow.
                           Result.Falls := False;
                           return Result;
                        end if;
                        return Reading;
                     end if;
                     if Reads_In (Place, Since) then
                        return Reading;
                     end if;
                  end;

               when Syn.Return_Statement =>
                  if Reads_In (Syn.Condition_Of (Of_Tree, Node), Since) then
                     return Reading;
                  end if;
                  Result.Falls := Guarded;

               when Syn.Fail_Statement =>
                  if Reads_In (Syn.Condition_Of (Of_Tree, Node), Since)
                    or else Reads_In (Syn.Value_Of (Of_Tree, Node), Since)
                  then
                     return Reading;
                  end if;
                  Result.Falls := Guarded;

               when Syn.Break_Statement =>
                  if Reads_In (Syn.Condition_Of (Of_Tree, Node), Since)
                    or else Reads_In
                      (Syn.Transfer_Value (Of_Tree, Node), Since)
                  then
                     return Reading;
                  end if;
                  Result.Breaks := True;
                  Result.Falls := Guarded;

               when Syn.Continue_Statement =>
                  if Reads_In (Syn.Condition_Of (Of_Tree, Node), Since) then
                     return Reading;
                  end if;
                  Result.Continues := True;
                  Result.Falls := Guarded;

               when Syn.If_Statement =>
                  Result.Falls := Syn.Else_Body (Of_Tree, Node) = Syn.No_Node;
                  for Arm in 1 .. Syn.Arm_Count (Of_Tree, Node) loop
                     declare
                        This : constant Syn.Node_Id :=
                          Syn.Nth_Arm (Of_Tree, Node, Arm);
                        Test : constant Syn.Node_Id :=
                          Syn.Condition_Of (Of_Tree, This);
                        Arm_Result : Summary;
                     begin
                        if Reads_In
                          ((if Syn.Kind (Of_Tree, Test) = Syn.Binding
                            then Syn.Value_Of (Of_Tree, Test)
                            else Test),
                           Since)
                        then
                           return Reading;
                        end if;
                        Arm_Result :=
                          Scan_Statements
                            (Syn.Body_Of (Of_Tree, This), 1, Since);
                        if Arm_Result.Reads then
                           return Reading;
                        end if;
                        Absorb (Result, Arm_Result);
                     end;
                  end loop;
                  if Syn.Else_Body (Of_Tree, Node) /= Syn.No_Node then
                     declare
                        Else_Result : constant Summary :=
                          Scan_Statements
                            (Syn.Else_Body (Of_Tree, Node), 1, Since);
                     begin
                        if Else_Result.Reads then
                           return Reading;
                        end if;
                        Absorb (Result, Else_Result);
                     end;
                  end if;

               when Syn.Match_Statement =>
                  if Reads_In (Syn.Match_Subject (Of_Tree, Node), Since) then
                     return Reading;
                  end if;
                  Result.Falls := False;
                  for Arm in 1 .. Syn.Match_Arm_Count (Of_Tree, Node) loop
                     declare
                        Arm_Result : constant Summary :=
                          Scan_Statements
                            (Syn.Body_Of
                               (Of_Tree,
                                Syn.Nth_Match_Arm (Of_Tree, Node, Arm)),
                             1, Since);
                     begin
                        if Arm_Result.Reads then
                           return Reading;
                        end if;
                        Absorb (Result, Arm_Result);
                     end;
                  end loop;

               when Syn.Bare_Block =>
                  return Scan_Statements
                    (Syn.Body_Of (Of_Tree, Node), 1, Since);

               when Syn.Loop_Statement | Syn.While_Statement
                  | Syn.For_Statement =>
                  --  A nested loop's transfers are its own.  It is taken
                  --  to leave normally, and a replacement inside it earns
                  --  no credit: both only over-report.
                  if Reads_Around (Node)
                    or else Scan_Statements
                      (Syn.Complete_Body (Of_Tree, Node), 1, 0).Reads
                  then
                     return Reading;
                  end if;

               when Syn.Defer_Statement | Syn.Undo_Statement =>
                  --  The call runs later on some edge; counting it here
                  --  is the conservative reading.
                  if Reads_In (Syn.Cleanup_Call (Of_Tree, Node), Since) then
                     return Reading;
                  end if;

               when others =>
                  if Reads_In (Node, Since) then
                     return Reading;
                  end if;
            end case;
            return Result;
         end Scan_Statement;

         --  The loop's test, traversal bounds and body from the top: what
         --  the back edge executes next.
         function Reads_Around (Loop_Node : Syn.Node_Id) return Boolean is
         begin
            case Syn.Kind (Of_Tree, Loop_Node) is
               when Syn.While_Statement =>
                  declare
                     Test : constant Syn.Node_Id :=
                       Syn.Condition_Of (Of_Tree, Loop_Node);
                  begin
                     if Reads_In
                       (if Syn.Kind (Of_Tree, Test) = Syn.Binding
                        then Syn.Value_Of (Of_Tree, Test)
                        else Test)
                     then
                        return True;
                     end if;
                  end;
               when Syn.For_Statement =>
                  if Reads_In (Syn.Traversal_Lower (Of_Tree, Loop_Node))
                    or else Reads_In
                      (Syn.Traversal_Upper (Of_Tree, Loop_Node))
                  then
                     return True;
                  end if;
               when others =>
                  null;
            end case;
            return Scan_Statements
              (Syn.Loop_Body (Of_Tree, Loop_Node), 1, 0).Reads;
         end Reads_Around;

         Pending : Summary := (Falls => True, others => False);
      begin
         for Action of Cleanup_Stack loop
            if Action.Active and then Reads_In (Action.Call) then
               return True;
            end if;
         end loop;
         if Positions.Is_Empty then
            --  An expression body: whatever follows the call is in it.
            return Reads_In (Body_Node, After);
         end if;

         --  The rest of the statement the call is part of.
         declare
            Top : constant Position_Frame := Positions.Last_Element;
         begin
            if Top.Index in 1 .. Syn.Statement_Count (Of_Tree, Top.Block)
              and then Reads_In
                (Syn.Nth_Statement (Of_Tree, Top.Block, Top.Index), After)
            then
               return True;
            end if;
         end;

         for Level in reverse 1 .. Positions.Last_Index loop
            declare
               Frame : constant Position_Frame := Positions (Level);
            begin
               if Pending.Falls then
                  declare
                     Rest : constant Summary :=
                       Scan_Statements (Frame.Block, Frame.Index + 1, After);
                  begin
                     if Rest.Reads then
                        return True;
                     end if;
                     Pending.Falls := Rest.Falls;
                     Pending.Breaks := Pending.Breaks or Rest.Breaks;
                     Pending.Continues := Pending.Continues or Rest.Continues;
                  end;
               end if;

               if Frame.Block = Pattern_Block (Borrower) then
                  --  A later iteration establishes fresh arm bindings.
                  --  Loops inside this arm were already checked above.
                  return False;
               end if;

               if Frame.Of_Loop /= Syn.No_Node then
                  if Pending.Falls or Pending.Continues then
                     if Reads_Around (Frame.Of_Loop)
                       or else Scan_Statements
                         (Syn.Complete_Body (Of_Tree, Frame.Of_Loop),
                          1, 0).Reads
                     then
                        return True;
                     end if;
                  end if;
                  if not (Pending.Falls or Pending.Continues
                          or Pending.Breaks)
                  then
                     return False;
                  end if;
                  --  Every remaining path leaves the loop somewhere.
                  Pending := (Falls => True, others => False);
               elsif not (Pending.Falls or Pending.Breaks
                          or Pending.Continues)
               then
                  return False;
               end if;
            end;
         end loop;
         return False;
      end Has_Future_Use;

      function Check_Payload_Borrows
        (Tree : Syn.Tree; Place : Syn.Node_Id;
         After : Landin.Source.Byte_Offset; Storage : Reference_Fact)
         return Boolean
      is
         function Same_Path (Left, Right : Syn.Node_Id) return Boolean;
         function Replaces (Subject : Syn.Node_Id) return Boolean;
         function Replaces_Aliased_Storage (Pattern : Res.Declaration_Id)
           return Boolean;
         function Disjoint_Frame_Storage (Pattern : Res.Declaration_Id)
           return Boolean;
         function Known_Index
           (Node : Syn.Node_Id; Value : out Ty.Magnitude) return Boolean;

         function Known_Index
           (Node : Syn.Node_Id; Value : out Ty.Magnitude) return Boolean
         is
            Overflowed : Boolean;
         begin
            Value := 0;
            if Syn.Kind (Tree, Node) /= Syn.Integer_Literal then
               return False;
            end if;
            Ty.Evaluate
              (Landin.Source.Slice
                 (Source (Context, Syn.Source_Of (Tree)),
                  Syn.Digit_Span (Tree, Node)),
               Syn.Base (Tree, Node), Value, Overflowed);
            return not Overflowed;
         end Known_Index;

         function Same_Path (Left, Right : Syn.Node_Id) return Boolean is
         begin
            if Syn.Kind (Tree, Left) /= Syn.Kind (Tree, Right) then
               return False;
            end if;
            case Syn.Kind (Tree, Left) is
               when Syn.Name_Reference =>
                  return Root_Declaration (Tree, Left) /= Res.No_Declaration
                    and then Root_Declaration (Tree, Left)
                      = Root_Declaration (Tree, Right);
               when Syn.Member_Selection =>
                  return Syn.Name (Tree, Left) = Syn.Name (Tree, Right)
                    and then Same_Path
                      (Syn.Target_Of (Tree, Left),
                       Syn.Target_Of (Tree, Right));
               when Syn.Element_Index =>
                  declare
                     L, R : Ty.Magnitude;
                  begin
                     return Same_Path
                       (Syn.Target_Of (Tree, Left),
                        Syn.Target_Of (Tree, Right))
                       and then
                         (not Known_Index (Syn.Index_Of (Tree, Left), L)
                          or else not Known_Index
                            (Syn.Index_Of (Tree, Right), R)
                          or else L = R);
                  end;
               when others =>
                  return False;
            end case;
         end Same_Path;

         function Replaces (Subject : Syn.Node_Id) return Boolean is
            Current : Syn.Node_Id := Subject;
         begin
            while Current /= Syn.No_Node loop
               if Same_Path (Place, Current) then
                  return True;
               end if;
               exit when Syn.Kind (Tree, Current)
                 not in Syn.Member_Selection | Syn.Element_Index;
               declare
                  Target : constant Syn.Node_Id :=
                    Syn.Target_Of (Tree, Current);
               begin
                  --  Replacing a descriptor does not overwrite its backing.
                  exit when Landin.Checking.Type_Of
                    (Types.all, Tree, Target)
                      in Ty.Pointer_Value | Ty.Slice_Value;
                  Current := Target;
               end;
            end loop;
            return False;
         end Replaces;

         function Replaces_Aliased_Storage (Pattern : Res.Declaration_Id)
           return Boolean
         is
            Same_Root : Boolean := False;
         begin
            if Root_Declaration (Tree, Place)
              = Root_Declaration (Tree, Pattern_Subject (Pattern))
            then
               return False;
            end if;
            for Id in Storage.Derives'Range loop
               Same_Root := Same_Root or else
                 (Storage.Derives (Id) and then Pattern_Storage (Pattern)
                    .Derives (Id));
            end loop;
            if not Same_Root then
               return False;
            end if;
            --  Known address aliases share backing roots. A contextual
            --  variant write or containing aggregate replacement through
            --  one can invalidate aliases reached through another.
            if Syn.Kind (Tree, Place) = Syn.Member_Selection
              and then Landin.Checking.Type_Of (Types.all, Tree, Place)
                = Ty.Not_Typed
              and then Landin.Checking.Field_Index (Types.all, Tree, Place)
                > 0
            then
               return True;
            end if;
            declare
               Nominal : constant Landin.Checking.Nominal_Type_Id :=
                 Landin.Checking.Nominal_Of (Types.all, Tree, Place);
               Current : Syn.Node_Id := Pattern_Subject (Pattern);
            begin
               while Current /= Syn.No_Node loop
                  if Nominal /= Landin.Checking.No_Nominal_Type
                    and then Nominal = Landin.Checking.Nominal_Of
                      (Types.all, Tree, Current)
                  then
                     return True;
                  end if;
                  exit when Syn.Kind (Tree, Current)
                    not in Syn.Member_Selection | Syn.Element_Index;
                  Current := Syn.Target_Of (Tree, Current);
                  exit when Landin.Checking.Type_Of
                    (Types.all, Tree, Current)
                      in Ty.Pointer_Value | Ty.Slice_Value;
               end loop;
            end;
            return False;
         end Replaces_Aliased_Storage;

         function Disjoint_Frame_Storage (Pattern : Res.Declaration_Id)
           return Boolean
         is
            Left_Known, Right_Known : Boolean := False;

            function Descriptor_Root (Node : Syn.Node_Id)
              return Res.Declaration_Id;

            function Descriptor_Root (Node : Syn.Node_Id)
              return Res.Declaration_Id
            is
               Current : Syn.Node_Id := Node;
            begin
               while Syn.Kind (Tree, Current)
                 in Syn.Member_Selection | Syn.Element_Index
               loop
                  Current := Syn.Target_Of (Tree, Current);
                  if Landin.Checking.Type_Of (Types.all, Tree, Current)
                    in Ty.Pointer_Value | Ty.Slice_Value
                  then
                     return Root_Declaration (Tree, Current);
                  end if;
               end loop;
               return Res.No_Declaration;
            end Descriptor_Root;

            Left_Descriptor : constant Res.Declaration_Id :=
              Descriptor_Root (Place);
            Right_Descriptor : constant Res.Declaration_Id :=
              Descriptor_Root (Pattern_Subject (Pattern));
         begin
            if not Storage.Frame or else not Pattern_Storage (Pattern).Frame
            then
               return False;
            end if;
            --  Selector facts also name the descriptor used to reach their
            --  storage. Rebinding that descriptor does not identify the old
            --  and new pointees. Both sides still need known backing roots.
            for Id in Storage.Derives'Range loop
               if Res.Declaration_Id (Id) /= Left_Descriptor
                 and then Res.Declaration_Id (Id) /= Right_Descriptor
               then
                  Left_Known := Left_Known or Storage.Derives (Id);
                  Right_Known := Right_Known
                    or Pattern_Storage (Pattern).Derives (Id);
                  if Storage.Derives (Id)
                    and then Pattern_Storage (Pattern).Derives (Id)
                  then
                     return False;
                  end if;
               end if;
            end loop;
            return Left_Known and Right_Known;
         end Disjoint_Frame_Storage;
      begin
         for Pattern in Origins'Range loop
            if Pattern_Subject (Pattern) /= Syn.No_Node
              and then not Disjoint_Frame_Storage (Pattern)
              and then (Replaces (Pattern_Subject (Pattern))
                        or else Replaces_Aliased_Storage (Pattern))
            then
               for Borrower in Origins'Range loop
                  if (Borrower = Pattern
                      or else (Has_References (Borrower)
                               and then Origins (Borrower).Value.Derives
                                 (Positive (Pattern))))
                    and then Has_Future_Use (Borrower, After)
                  then
                     Bad.Report
                       (Item    => Bad.Borrowed_Place,
                        Source  => Syn.Source_Of (Tree),
                        Where   => Syn.Where (Tree, Place),
                        Message => "this may replace a variant while its"
                                   & " payload storage is still in use",
                        Note    => "D78/D85: payload aliases refer to the"
                                   & " selected case's storage",
                        Related => Syn.Origin
                          (Tree_For
                             (Res.Source_Of (Meanings.all, Borrower)).all,
                           Res.Node_Of (Meanings.all, Borrower)),
                        Because => "the live payload alias or derived view",
                        Into    => Sink.all);
                     return True;
                  end if;
               end loop;
            end if;
         end loop;
         return False;
      end Check_Payload_Borrows;

      procedure Check_Borrows
        (Tree : Syn.Tree; Call : Syn.Node_Id; Known : Argument_Facts)
      is
         Called : constant Landin.Checking.Signature_Id :=
           Call_Signature (Tree, Call);
      begin
         if not Landin.Checking.Holds (Types.all, Called) then
            return;
         end if;
         for Position in 1 .. Landin.Checking.Signature_Parameter_Count
           (Types.all, Called)
         loop
            declare
               Part : constant Landin.Checking.Signature_Part :=
                 Landin.Checking.Nth_Signature_Parameter
                   (Types.all, Called, Position);
               Argument : constant Syn.Node_Id :=
                 Runtime_Argument (Tree, Call, Position);
               Mutated : constant Res.Declaration_Id :=
                 (if Argument = Syn.No_Node
                  then Res.No_Declaration
                  else Root_Declaration (Tree, Argument));
            begin
               if Part.Convention
                    in Syn.Inout_Convention | Syn.Sink_Convention
                 and then Mutated /= Res.No_Declaration
                 and then not Check_Payload_Borrows
                   (Tree, Argument, Syn.Where (Tree, Call).Last,
                    Known_Fact (Tree, Known, Argument).Storage)
               then
                  --  [0830]: a borrow is a view.  A scalar computed from
                  --  one carries derivation facts for [0790]'s clauses but
                  --  holds no reference into the mutated storage.
                  for Borrower in Origins'Range loop
                     if Borrower /= Mutated
                       and then Has_References (Borrower)
                       and then Origins (Borrower).Value.Derives
                         (Positive (Mutated))
                       and then Has_Future_Use
                         (Borrower, Syn.Where (Tree, Call).Last)
                     then
                        declare
                           Borrower_Tree : constant not null access constant
                             Syn.Tree := Tree_For
                               (Res.Source_Of (Meanings.all, Borrower));
                        begin
                           Bad.Report
                             (Item    => Bad.Borrowed_Place,
                              Source  => Syn.Source_Of (Tree),
                              Where   => Syn.Where (Tree, Argument),
                              Message => "this `inout` or `sink` use may"
                                         & " move storage while a derived"
                                         & " view is still in use",
                              Note    => "[0800]/[0830]: take the view again"
                                         & " after mutating its source",
                              Related => Syn.Origin
                                (Borrower_Tree.all,
                                 Res.Node_Of (Meanings.all, Borrower)),
                              Because => "the live derived view",
                              Into    => Sink.all);
                        end;
                        exit;
                     end if;
                  end loop;
               end if;
            end;
         end loop;
      end Check_Borrows;

      function Named_Storage_Fact (Tree : Syn.Tree; Place : Syn.Node_Id)
        return Reference_Fact
      is
         Result : Reference_Fact := No_Reference;
         Id : constant Res.Declaration_Id :=
           Root_Declaration (Tree, Place);
      begin
         --  Only a name's backing is classified here.  Computed selectors
         --  capture their target's storage during the ordinary expression
         --  walk, before evaluating their indexes; no syntax is replayed.
         if Id /= Res.No_Declaration then
            Result.Derives (Positive (Id)) := True;
            case Res.Sort_Of (Meanings.all, Id) is
               when Res.Local_Binding | Res.Named_Return =>
                  Result.Frame := True;
               when Res.Parameter =>
                  declare
                     Parameter_Tree : constant
                       not null access constant Syn.Tree :=
                         Tree_For
                           (Res.Source_Of (Meanings.all, Id));
                     Parameter_Node : constant Syn.Node_Id :=
                       Res.Node_Of (Meanings.all, Id);
                  begin
                     if Syn.Convention_Of
                       (Parameter_Tree.all, Parameter_Node)
                         = Syn.Inout_Convention
                     then
                        Result.From (Parameter_Of (Id)) := True;
                     else
                        Result.Frame := True;
                     end if;
                  end;
               when Res.Pattern_Binding =>
                  --  D85/D121: this is the payload's actual backing place,
                  --  distinct from origins carried by its copied value.
                  Result := Pattern_Storage (Id);
                  Result.Derives (Positive (Id)) := True;
               when others =>
                  null;
            end case;
         end if;
         return Result;
      end Named_Storage_Fact;

      function Fact_Of (Tree : Syn.Tree; Node : Syn.Node_Id)
        return Origin_Fact
      is
         Result : Origin_Fact := No_Origin;

         procedure Normalize_Scalar_Result;

         procedure Normalize_Scalar_Result is
         begin
            if Falls_Through
              and then Landin.Checking.Type_Of (Types.all, Tree, Node)
                in Ty.Scalar_Name
            then
               --  Evaluation has already contributed its effects and joined
               --  its control edges.  The computed scalar retains no view;
               --  keep Storage separate for scalar places used by `addr`.
               Result.Value := No_Reference;
               Result.Results.Clear;
            end if;
         end Normalize_Scalar_Result;
      begin
         if not Falls_Through then
            return No_Value_Edge;
         elsif Node = Syn.No_Node then
            return Result;
         end if;
         --  The contextual checker records the union descriptor on its
         --  empty atom, including qualified atom names.  Match that identity
         --  rather than treating an arbitrary source-free pointer as empty.
         if Syn.Kind (Tree, Node)
              in Syn.Name_Reference | Syn.Member_Selection
           and then Res.Verdict_Of (Meanings.all, Tree, Node) = Res.Bound
         then
            declare
               Reference : constant Landin.Checking.Reference_Id :=
                 Landin.Checking.Reference_Of (Types.all, Tree, Node);
            begin
               if Landin.Checking.Holds (Types.all, Reference)
                 and then Landin.Checking.Is_Optional_Pointer
                   (Types.all, Reference)
                 and then Res.Bound_To (Meanings.all, Tree, Node)
                   = Landin.Checking.Descriptor_Of
                     (Types.all, Reference).Empty_Atom
               then
                  return Empty_Origin;
               end if;
            end;
         end if;
         case Syn.Kind (Tree, Node) is
            when Syn.Name_Reference =>
               if Res.Verdict_Of (Meanings.all, Tree, Node) = Res.Bound then
                  declare
                     Id : constant Res.Declaration_Id :=
                       Res.Bound_To (Meanings.all, Tree, Node);
                  begin
                     if Id in Origins'Range then
                        Result := Origins (Id);
                        Result.Storage := Named_Storage_Fact (Tree, Node);
                        if Exposed (Positive (Id))
                          or else Res.Sort_Of (Meanings.all, Id)
                            = Res.Module_Binding
                        then
                           Result.Value.Presence := Unknown_Value;
                           for Position in 1 .. Result.Results.Last_Index loop
                              declare
                                 Part : Reference_Fact :=
                                   Result.Results (Position);
                              begin
                                 Part.Presence := Unknown_Value;
                                 Result.Results.Replace_Element
                                   (Position, Part);
                              end;
                           end loop;
                        end if;
                        return Result;
                     end if;
                  end;
               end if;

            when Syn.Anonymous_Function =>
               --  Creating a code value does not run its separately checked
               --  body or any transfers in that body's cleanup arguments.
               return No_Origin;

            when Syn.Len_Of =>
               --  D14/D31: a fixed-array length does not read its storage,
               --  and array-literal elements are typechecked but not run.
               return No_Origin;

            when Syn.Try_Expression =>
               return Fact_Of (Tree, Syn.Operand_Of (Tree, Node));

            when Syn.Any_Construction =>
               Result := Fact_Of (Tree, Syn.Operand_Of (Tree, Node));
               Result.Value.Presence := Unknown_Value;
               Result.Results.Clear;
               return Result;

            when Syn.Pointer_Conversion =>
               declare
                  Operand : constant Origin_Fact :=
                    Fact_Of (Tree, Syn.Operand_Of (Tree, Node));
               begin
                  pragma Unreferenced (Operand);
                  Result.Value.Untracked := True;
                  return Result;
               end;

            when Syn.Address_Of =>
               declare
                  Operand : constant Origin_Fact :=
                    Fact_Of (Tree, Syn.Operand_Of (Tree, Node));
               begin
                  return (Value => Operand.Storage, others => <>);
               end;

            when Syn.Member_Selection | Syn.Element_Index
               | Syn.Inclusive_Slice | Syn.Half_Open_Slice =>
               declare
                  Target : constant Syn.Node_Id := Syn.Target_Of (Tree, Node);
                  Target_Kind : constant Ty.Type_Kind :=
                    Landin.Checking.Type_Of (Types.all, Tree, Target);
                  Target_Fact : constant Origin_Fact := Fact_Of (Tree, Target);
                  Field : constant Natural :=
                    Landin.Checking.Field_Index (Types.all, Tree, Node);
                  Is_Slice : constant Boolean :=
                    Syn.Kind (Tree, Node)
                      in Syn.Inclusive_Slice | Syn.Half_Open_Slice;
               begin
                  Result := Target_Fact;
                  if Syn.Kind (Tree, Node) = Syn.Member_Selection
                    and then Field > 0
                    and then Landin.Checking.Result_Shape_Of
                      (Types.all, Tree, Target) /= Landin.Checking.No_Signature
                  then
                     Result := Nth_Result (Target_Fact, Field);
                  else
                     Result.Value.Presence := Unknown_Value;
                     Result.Results.Clear;
                  end if;
                  if Is_Slice and then Target_Kind = Ty.Fixed_Array then
                     Result.Value := Target_Fact.Storage;
                  elsif (Syn.Kind (Tree, Node) = Syn.Member_Selection
                         and then Target_Kind = Ty.Pointer_Value)
                    or else (Syn.Kind (Tree, Node) = Syn.Element_Index
                             and then Target_Kind = Ty.Slice_Value)
                  then
                     Result.Storage := Target_Fact.Value;
                  end if;
                  --  Capture the base before the selectors run: an index
                  --  can replace that base while its old address is in use.
                  for Slot in 2 .. Syn.Slot_Count (Tree, Node) loop
                     declare
                        Ignored : constant Origin_Fact :=
                          Fact_Of (Tree, Syn.Slot (Tree, Node, Slot));
                     begin
                        pragma Unreferenced (Ignored);
                     end;
                  end loop;
               end;
               declare
                  Id : constant Res.Declaration_Id :=
                    Root_Declaration (Tree, Node);
               begin
                  if Id /= Res.No_Declaration then
                     Result.Storage.Derives (Positive (Id)) := True;
                  end if;
                  if Syn.Kind (Tree, Node)
                       in Syn.Member_Selection | Syn.Element_Index
                    and then Landin.Checking.Type_Of (Types.all, Tree, Node)
                      in Ty.Scalar_Name
                  then
                     Result.Value := No_Reference;
                     Result.Results.Clear;
                  elsif Id /= Res.No_Declaration then
                     Result.Value.Derives (Positive (Id)) := True;
                     if Parameter_Of (Id) > 0
                       and then Syn.Kind (Tree, Node)
                         in Syn.Member_Selection | Syn.Element_Index
                       and then Landin.Checking.Type_Of
                         (Types.all, Tree, Node)
                           in Ty.Pointer_Value | Ty.Slice_Value
                     then
                        Result.Value.From (Parameter_Of (Id)) := True;
                     end if;
                  end if;
               end;
               return Result;

            when Syn.Call | Syn.Labeled_Application =>
               if Landin.Checking.Distinct_Conversion_Of
                 (Types.all, Tree, Node)
                   /= Landin.Checking.No_Nominal_Type
               then
                  return Fact_Of
                    (Tree, Syn.Nth_Argument (Tree, Node, 1));
               elsif Landin.Checking.Text_Conversion_Of
                 (Types.all, Tree, Node)
                   /= Landin.Checking.No_Text_Conversion
               then
                  --  D199's text conversions change only the exact view of
                  --  the same backing storage.  In particular, the C scan
                  --  measures a prefix but does not mint an independent
                  --  slice or pass through [0810]'s untracked address path.
                  return Fact_Of
                    (Tree, Syn.Nth_Argument (Tree, Node, 1));
               elsif Syn.Kind (Tree, Node) = Syn.Labeled_Application
                 and then Res.Class_Of (Meanings.all, Tree, Node)
                   /= Res.Function_Call
               then
                  null;
               else
                  --  Every argument is evaluated before the call, and
                  --  each one is walked here whether or not a formal
                  --  retains it: an escaping call nested in an ordinary
                  --  argument is still a call that ran.
                  declare
                     Written : constant Natural :=
                       Syn.Argument_Count (Tree, Node);
                     Callee : constant Syn.Node_Id :=
                       Syn.Callee_Of (Tree, Node);
                     Self : constant Syn.Node_Id :=
                       (if Syn.Kind (Tree, Callee) = Syn.Member_Selection
                        then Syn.Target_Of (Tree, Callee)
                        else Callee);
                     Known : Argument_Facts (1 .. Written + 1);
                     Called : constant Landin.Checking.Signature_Id :=
                       Call_Signature (Tree, Node);
                  begin
                     Known (1) := (Node => Self, Fact => Fact_Of (Tree, Self));
                     for Position in 1 .. Written loop
                        declare
                           Raw : constant Syn.Node_Id :=
                             Syn.Nth_Argument (Tree, Node, Position);
                           Expression : constant Syn.Node_Id :=
                             (if Syn.Kind (Tree, Raw) = Syn.Call_Argument
                                and then Res.Role_Of (Meanings.all, Tree, Raw)
                                  = Res.Runtime_Argument
                              then Syn.Expression_Projection (Tree, Raw)
                              else Raw);
                        begin
                           Known (Position + 1) :=
                             (Node => Expression,
                              Fact => Fact_Of (Tree, Expression));
                        end;
                     end loop;
                     if not Falls_Through then
                        return No_Value_Edge;
                     end if;
                     Check_Escaping_Arguments (Tree, Node, Known);
                     Check_Borrows (Tree, Node, Known);
                     if Landin.Checking.Holds (Types.all, Called) then
                        for Returned in
                          1 .. Landin.Checking.Signature_Result_Count
                            (Types.all, Called)
                        loop
                           declare
                              Part : Reference_Fact := No_Reference;
                           begin
                              if Landin.Checking.Contains_References
                                (Types.all,
                                 Landin.Checking.Nth_Signature_Result
                                   (Types.all, Called, Returned))
                              then
                                 for Source in 1 .. Landin.Checking
                                   .Signature_Return_Source_Count
                                     (Types.all, Called, Returned)
                                 loop
                                    declare
                                       Formal : constant Positive :=
                                         Landin.Checking
                                           .Nth_Signature_Return_Source
                                             (Types.all, Called,
                                              Returned, Source);
                                       Argument : constant Syn.Node_Id :=
                                         Runtime_Argument (Tree, Node, Formal);
                                    begin
                                       if Argument /= Syn.No_Node then
                                          declare
                                             Fact : constant Origin_Fact :=
                                               Known_Fact
                                                 (Tree, Known, Argument);
                                             Id : constant
                                               Res.Declaration_Id :=
                                                 Root_Declaration
                                                   (Tree, Argument);
                                          begin
                                             --  Both the value and backing
                                             --  were captured at this actual's
                                             --  evaluation, not replayed after
                                             --  later arguments ran.
                                             Join
                                               (Part,
                                                (if Landin.Checking
                                                  .Nth_Signature_Parameter
                                                    (Types.all, Called,
                                                     Formal).Convention
                                                       = Syn.Inout_Convention
                                                 then Fact.Storage
                                                 else Fact.Value));
                                             if Id /= Res.No_Declaration then
                                                Part.Derives
                                                  (Positive (Id)) := True;
                                             end if;
                                          end;
                                       end if;
                                    end;
                                 end loop;
                              end if;
                              Join (Result.Value, Part);
                              if Landin.Checking.Signature_Result_Count
                                (Types.all, Called) > 1
                              then
                                 Result.Results.Append (Part);
                              end if;
                           end;
                        end loop;
                     end if;
                     if Syn.Recovery_Of (Tree, Node) /= Syn.No_Node then
                        declare
                           Recovery : constant Syn.Node_Id := Syn.Else_Body
                             (Tree, Syn.Recovery_Of (Tree, Node));
                           Success : constant Function_Table := Origins;
                           Fallback : Origin_Fact;
                           Falls : Boolean := True;
                        begin
                           --  The fallback executes only on failure.  Its
                           --  value and state join the successful edge, but
                           --  its empty atom contributes no origin.  Never
                           --  mark that atom untracked: that would launder a
                           --  frame pointer returned on the success edge.
                           if Syn.Kind (Tree, Recovery) = Syn.Block then
                              Process_Block (Tree, Recovery, Falls);
                              Fallback := Statement_Value;
                           else
                              Fallback := Fact_Of (Tree, Recovery);
                              Falls := Falls_Through;
                           end if;
                           if Falls then
                              Join (Result, Fallback);
                              Join_Table (Origins, Success);
                           else
                              Origins := Success;
                           end if;
                           Falls_Through := True;
                        end;
                     end if;
                  end;
                  return Result;
               end if;

            when Syn.Logical_And | Syn.Logical_Or =>
               Result := Fact_Of (Tree, Syn.Left_Of (Tree, Node));
               if Falls_Through then
                  declare
                     Skipped : constant Function_Table := Origins;
                     Right : constant Origin_Fact :=
                       Fact_Of (Tree, Syn.Right_Of (Tree, Node));
                  begin
                     if Falls_Through then
                        Join (Result, Right);
                        Join_Table (Origins, Skipped);
                     else
                        Origins := Skipped;
                     end if;
                     Falls_Through := True;
                  end;
               end if;
               Normalize_Scalar_Result;
               return Result;

            when Syn.If_Statement | Syn.Match_Statement | Syn.Bare_Block
               | Syn.Loop_Statement | Syn.While_Statement
               | Syn.For_Statement =>
               --  In expression position the construct's statements run
               --  exactly as in statement position, so they are processed
               --  the same way; the value is what its edges left behind.
               Process_Statement (Tree, Node);
               return Statement_Value;

            when Syn.Block =>
               declare
                  Fell : Boolean;
               begin
                  Process_Block (Tree, Node, Fell);
                  return Statement_Value;
               end;

            when others =>
               null;
         end case;

         for Slot in 1 .. Syn.Slot_Count (Tree, Node) loop
            exit when not Falls_Through;
            Join (Result, Fact_Of (Tree, Syn.Slot (Tree, Node, Slot)));
         end loop;
         --  Only anonymous-result producers and their copies carry a
         --  positional shape, never an enclosing conversion or constructor.
         Result.Results.Clear;
         Normalize_Scalar_Result;
         return Result;
      end Fact_Of;

      procedure Check_Returns (Tree : Syn.Tree; At_Node : Syn.Node_Id) is
      begin
         if Signature = Landin.Checking.No_Signature then
            return;
         end if;
         for Position in 1 .. Syn.Return_Count (Of_Tree, Function_Node) loop
            declare
               Returned : constant Syn.Node_Id :=
                 Syn.Nth_Return (Of_Tree, Function_Node, Position);
               Id : constant Res.Declaration_Id :=
                 Declaration_At (Of_Tree, Returned);
               Part : constant Landin.Checking.Signature_Part :=
                 Landin.Checking.Nth_Signature_Result
                   (Types.all, Signature, Position);
               Fact : constant Reference_Fact := Origins (Id).Value;
               Expected : Parameter_Bits := [others => False];
               Same : Boolean := True;
            begin
               if not Landin.Checking.Contains_References
                 (Types.all, Part)
               then
                  goto Next_Return;
               end if;
               for Source in
                 1 .. Landin.Checking.Signature_Return_Source_Count
                   (Types.all, Signature, Position)
               loop
                  Expected
                    (Landin.Checking.Nth_Signature_Return_Source
                       (Types.all, Signature, Position, Source)) := True;
               end loop;

               if not Fact.Untracked and then Fact.Frame then
                  Report_Escape
                    (Tree, At_Node, Fact,
                     "this returned reference still has frame origin",
                     Part.Site);
               elsif not Fact.Untracked
                 and then not
                   (Fact.Presence = Empty_Optional
                    and then not Exposed (Positive (Id))
                    and then Landin.Checking.Holds (Types.all, Part.Reference)
                    and then Landin.Checking.Is_Optional_Pointer
                      (Types.all, Part.Reference))
               then
                  --  [0480]/D189: an empty result has no reference whose
                  --  sources could disagree.  A present or unknown result
                  --  still owes exact agreement, even with no origin bits.
                  for Source in Expected'Range loop
                     Same := Same
                       and then Expected (Source) = Fact.From (Source);
                  end loop;
                  if not Same then
                     Bad.Report
                       (Item    => Bad.Return_Sources_Disagree,
                        Source  => Syn.Source_Of (Tree),
                        Where   => Syn.Where (Tree, At_Node),
                        Message => "the returned reference does not derive"
                                   & " from exactly the parameters named by"
                                   & " its `from` clause",
                        Note    => "[0790]: the written clause and every"
                                   & " returning body edge agree both ways",
                        Related => Part.Site,
                        Because => "the named return and its declared sources",
                        Into    => Sink.all);
                  end if;
               end if;
               <<Next_Return>>
               null;
            end;
         end loop;
      end Check_Returns;

      procedure Assign
        (Tree : Syn.Tree; Place : Syn.Node_Id; Value : Syn.Node_Id)
      is
         Id : constant Res.Declaration_Id := Root_Declaration (Tree, Place);
         Target : constant Origin_Fact := Fact_Of (Tree, Place);
         Fact : Origin_Fact := No_Origin;
         Retag_First : constant Boolean :=
           (Landin.Checking.Type_Of (Types.all, Tree, Place) = Ty.Not_Typed
            and then not Match_Subject_Is_Copied (Tree, Place))
           or else Syn.Kind (Tree, Value) = Syn.Struct_Literal
           or else (Syn.Kind (Tree, Value) = Syn.Labeled_Application
                    and then Res.Class_Of (Meanings.all, Tree, Value)
                      = Res.Type_Construction);
         Valid : constant Boolean :=
           Landin.Checking.Type_Of (Types.all, Tree, Place) /= Ty.Ill_Typed
           and then Landin.Checking.Type_Of
             (Types.all, Tree, Value) /= Ty.Ill_Typed;

         function Through_Descriptor return Boolean;

         function Through_Descriptor return Boolean is
            Current : Syn.Node_Id := Place;
         begin
            while Syn.Kind (Tree, Current)
              in Syn.Member_Selection | Syn.Element_Index
            loop
               Current := Syn.Target_Of (Tree, Current);
               if Landin.Checking.Type_Of (Types.all, Tree, Current)
                 in Ty.Pointer_Value | Ty.Slice_Value
               then
                  return True;
               end if;
            end loop;
            return False;
         end Through_Descriptor;
      begin
         if not Falls_Through then
            return;
         end if;
         --  D76 selects a direct variant case before its payload values.
         --  An old payload used by those values is therefore still live.
         if Valid and then Retag_First and then Check_Payload_Borrows
           (Tree, Place, Syn.Where (Tree, Place).Last, Target.Storage)
         then
            return;
         end if;
         Fact := Fact_Of (Tree, Value);
         if not Falls_Through then
            return;
         end if;
         if Valid and then not Retag_First and then Check_Payload_Borrows
           (Tree, Place, Syn.Where (Tree, Value).Last, Target.Storage)
         then
            return;
         end if;
         if not Has_References (Tree, Place) then
            Fact := No_Origin;
         end if;

         if Valid
           and then ((Id /= Res.No_Declaration
              and then Res.Sort_Of (Meanings.all, Id) = Res.Module_Binding)
             or else (not Target.Storage.Frame
                      and then not Target.Storage.Untracked))
           and then not Fact.Value.Untracked
         then
            if Fact.Value.Frame then
               Report_Escape
                 (Tree, Value, Fact.Value,
                  "this frame-origin reference cannot be stored in"
                  & " storage outside this frame",
                  Syn.Origin (Tree, Place));
            else
               for Source in Fact.Value.From'Range loop
                  if Fact.Value.From (Source)
                    and then not Parameter_Escapes (Source)
                    and then not Target.Storage.From (Source)
                  then
                     Report_Escape
                       (Tree, Value, Fact.Value,
                        "this non-escaping parameter cannot be retained in"
                        & " storage belonging to another origin",
                        Syn.Origin (Tree, Place));
                     exit;
                  end if;
               end loop;
            end if;
         end if;

         --  An address of known local storage keeps its declaration roots.
         --  A write through that address must update their value facts too;
         --  otherwise returning the local would forget the aliased write.
         if Target.Storage.Frame then
            for Stored in Origins'Range loop
               if Stored /= Id
                 and then Target.Storage.Derives (Positive (Stored))
               then
                  Join (Origins (Stored).Value, Fact.Value);
                  Origins (Stored).Results.Clear;
               end if;
            end loop;
         end if;

         if Id = Res.No_Declaration or else Id not in Origins'Range then
            return;
         end if;
         if Syn.Kind (Tree, Place) = Syn.Name_Reference then
            Origins (Id) := Fact;
         elsif not Through_Descriptor then
            Join (Origins (Id).Value, Fact.Value);
            --  A partial write invalidates positional detail until a whole
            --  replacement establishes it again; the union remains sound.
            Origins (Id).Results.Clear;
         end if;
      end Assign;

      procedure Join_Table
        (Into_Table : in out Function_Table; Other : Function_Table) is
      begin
         for Id in Into_Table'Range loop
            Join (Into_Table (Id), Other (Id));
         end loop;
      end Join_Table;

      procedure Run_Cleanups
        (Tree    : Syn.Tree;
         First   : Natural;
         On_Exit : Landin.Cleanup.Exit_Kind)
      is
         Last : constant Natural := Natural (Cleanup_Stack.Length);
         Disabled : array (1 .. Last) of Boolean := [others => False];
      begin
         if First = 0 or else First > Last then
            return;
         end if;

         --  Active is cleared while an entry runs so a transfer from one
         --  of its arguments unwinds the still-pending entries without
         --  repeating it, and restored afterwards for the sibling edges.
         for Position in reverse First .. Last loop
            exit when not Falls_Through;
            declare
               Action : Cleanup_Entry := Cleanup_Stack (Position);
            begin
               if Action.Active
                 and then Landin.Cleanup.Applies (Action.Kind, On_Exit)
               then
                  Action.Active := False;
                  Cleanup_Stack.Replace_Element (Position, Action);
                  Disabled (Position) := True;
                  declare
                     Ignored : constant Origin_Fact :=
                       Fact_Of (Tree, Action.Call);
                  begin
                     pragma Unreferenced (Ignored);
                  end;
               end if;
            end;
         end loop;

         for Position in First .. Last loop
            if Disabled (Position) then
               declare
                  Action : Cleanup_Entry := Cleanup_Stack (Position);
               begin
                  Action.Active := True;
                  Cleanup_Stack.Replace_Element (Position, Action);
               end;
            end if;
         end loop;
      end Run_Cleanups;

      function Transfer_Loop
        (Tree : Syn.Tree; Node : Syn.Node_Id) return Positive
      is
         Target : constant Landin.Source.Names.Name_Id :=
           Syn.Name (Tree, Node);
      begin
         for Index in reverse 1 .. Loop_Stack.Last_Index loop
            if Target = Landin.Source.Names.No_Name
              or else Loop_Stack (Index).Label = Target
            then
               return Index;
            end if;
         end loop;
         raise Landin.Compiler_Defect with "a loop transfer has no target";
      end Transfer_Loop;

      procedure Process_Statement (Tree : Syn.Tree; Node : Syn.Node_Id) is
         --  Every expression a statement evaluates is walked, because the
         --  walk is where escaping arguments and live borrows are checked.
         procedure Evaluate (Expression : Syn.Node_Id);

         procedure Evaluate (Expression : Syn.Node_Id) is
            Ignored : constant Origin_Fact := Fact_Of (Tree, Expression);
         begin
            pragma Unreferenced (Ignored);
         end Evaluate;

         Fell : Boolean;
      begin
         Statement_Value := No_Value_Edge;
         if not Falls_Through then
            return;
         end if;
         case Syn.Kind (Tree, Node) is
            when Syn.Binding =>
               declare
                  Id : constant Res.Declaration_Id :=
                    Declaration_At (Tree, Node);
               begin
                  if Id /= Res.No_Declaration then
                     --  The fixed point may retain the previous loop
                     --  iteration's value. It is not in scope while this
                     --  fresh declaration evaluates its initializer.
                     Origins (Id) := No_Origin;
                     Origins (Id) := Fact_Of (Tree, Syn.Value_Of (Tree, Node));
                  end if;
               end;

            when Syn.Destructuring_Binding =>
               declare
                  Value : constant Origin_Fact :=
                    Fact_Of (Tree, Syn.Destructured_Value (Tree, Node));
               begin
                  for Position in
                    1 .. Syn.Destructured_Field_Count (Tree, Node)
                  loop
                     declare
                        Field : constant Syn.Node_Id :=
                          Syn.Nth_Destructured_Field (Tree, Node, Position);
                        Which : constant Natural :=
                          Landin.Checking.Field_Index (Types.all, Tree, Field);
                     begin
                        for Slot in 1 .. Syn.Slot_Count (Tree, Field) loop
                           declare
                              Id : constant Res.Declaration_Id :=
                                Declaration_At
                                  (Tree, Syn.Slot (Tree, Field, Slot));
                           begin
                              if Id /= Res.No_Declaration
                                and then Id in Origins'Range
                              then
                                 Origins (Id) :=
                                   (if not Has_References (Id) then No_Origin
                                    elsif Which > 0
                                    then Nth_Result (Value, Which)
                                    else Value);
                              end if;
                           end;
                        end loop;
                     end;
                  end loop;
               end;

            when Syn.Assignment =>
               Assign
                 (Tree, Syn.Target_Of (Tree, Node), Syn.Value_Of (Tree, Node));

            when Syn.If_Statement =>
               declare
                  Remaining : Function_Table := Origins;
                  Merged : Function_Table := [others => No_Origin];
                  First  : Boolean := True;
                  Can_Test : Boolean := True;
                  Value  : Origin_Fact := No_Value_Edge;

                  procedure Merge_Branch (Reached : Boolean);

                  procedure Merge_Branch (Reached : Boolean) is
                  begin
                     if not Reached then
                        return;
                     end if;
                     Join (Value, Statement_Value);
                     if First then
                        Merged := Origins;
                        First := False;
                     else
                        Join_Table (Merged, Origins);
                     end if;
                  end Merge_Branch;
               begin
                  for Arm in 1 .. Syn.Arm_Count (Tree, Node) loop
                     exit when not Can_Test;
                     Origins := Remaining;
                     Falls_Through := True;
                     declare
                        This : constant Syn.Node_Id :=
                          Syn.Nth_Arm (Tree, Node, Arm);
                        Test : constant Syn.Node_Id :=
                          Syn.Condition_Of (Tree, This);
                     begin
                        if Syn.Kind (Tree, Test) = Syn.Binding then
                           Process_Statement (Tree, Test);
                        else
                           Evaluate (Test);
                        end if;
                        Can_Test := Falls_Through;
                        --  Both outcomes have evaluated this condition.
                        --  Only its true edge evaluates the arm; the false
                        --  edge supplies the next elsif, else or join.
                        Remaining := Origins;
                        if Can_Test then
                           Process_Block
                             (Tree, Syn.Body_Of (Tree, This), Fell);
                           Merge_Branch (Fell);
                        end if;
                     end;
                  end loop;
                  Origins := Remaining;
                  Falls_Through := Can_Test;
                  if Can_Test then
                     if Syn.Else_Body (Tree, Node) /= Syn.No_Node then
                        Process_Block
                          (Tree, Syn.Else_Body (Tree, Node), Fell);
                        Merge_Branch (Fell);
                     else
                        Statement_Value := No_Origin;
                        Merge_Branch (True);
                     end if;
                  end if;
                  if not First then
                     Origins := Merged;
                  end if;
                  Falls_Through := not First;
                  Statement_Value := Value;
               end;

            when Syn.Match_Statement =>
               declare
                  Subject_Node : constant Syn.Node_Id :=
                    Syn.Match_Subject (Tree, Node);
                  Subject_Value : constant Origin_Fact :=
                    Fact_Of (Tree, Subject_Node);
                  Subject_Id : constant Res.Declaration_Id :=
                    (if Syn.Kind (Tree, Subject_Node) = Syn.Name_Reference
                     then Root_Declaration (Tree, Subject_Node)
                     else Res.No_Declaration);
                  Subject_Reference : constant Landin.Checking.Reference_Id :=
                    Landin.Checking.Reference_Of
                      (Types.all, Tree, Subject_Node);
                  Subject_Storage : constant Reference_Fact :=
                    (if Match_Subject_Is_Copied (Tree, Subject_Node)
                     then (Frame => True, others => <>)
                     else Subject_Value.Storage);
                  Before : constant Function_Table := Origins;
                  Merged : Function_Table := [others => No_Origin];
                  First  : Boolean := True;
                  Value  : Origin_Fact := No_Value_Edge;
               begin
                  if not Falls_Through then
                     Statement_Value := No_Value_Edge;
                     return;
                  end if;
                  for Arm in 1 .. Syn.Match_Arm_Count (Tree, Node) loop
                     declare
                        This : constant Syn.Node_Id :=
                          Syn.Nth_Match_Arm (Tree, Node, Arm);
                        Pattern : constant Syn.Node_Id :=
                          Syn.Match_Pattern (Tree, This);
                     begin
                        Origins := Before;
                        Falls_Through := True;
                        if Subject_Id /= Res.No_Declaration
                          and then not Exposed (Positive (Subject_Id))
                          and then Res.Sort_Of (Meanings.all, Subject_Id)
                            /= Res.Module_Binding
                          and then Landin.Checking.Holds
                            (Types.all, Subject_Reference)
                          and then Landin.Checking.Is_Optional_Pointer
                            (Types.all, Subject_Reference)
                          and then Res.Verdict_Of
                            (Meanings.all, Tree, Pattern) = Res.Bound
                          and then Res.Bound_To (Meanings.all, Tree, Pattern)
                            = Landin.Checking.Descriptor_Of
                              (Types.all, Subject_Reference).Empty_Atom
                        then
                           --  This arm reads no reference, even when the
                           --  subject's present sibling has tracked sources.
                           Origins (Subject_Id) := Empty_Origin;
                        end if;
                        --  D85/D121: a binding's value keeps subject origins
                        --  only when it can carry references. Its storage
                        --  separately follows the actual match place or the
                        --  independent temporary selected above.
                        for Position in
                          1 .. Syn.Match_Binding_Count (Tree, This)
                        loop
                           declare
                              Id : constant Res.Declaration_Id :=
                                Declaration_At
                                  (Tree, Syn.Nth_Match_Binding
                                           (Tree, This, Position));
                           begin
                              if Id /= Res.No_Declaration
                                and then Id in Origins'Range
                              then
                                 Origins (Id) :=
                                   (if Has_References (Id)
                                    then Subject_Value
                                    else No_Origin);
                                 Origins (Id).Value.Presence := Unknown_Value;
                                 Pattern_Storage (Id) := Subject_Storage;
                                 Pattern_Subject (Id) :=
                                   (if Match_Subject_Is_Copied
                                         (Tree, Subject_Node)
                                    then Syn.No_Node else Subject_Node);
                                 Pattern_Block (Id) :=
                                   Syn.Body_Of (Tree, This);
                              end if;
                           end;
                        end loop;
                     end;
                     Process_Block
                       (Tree, Syn.Body_Of
                          (Tree, Syn.Nth_Match_Arm (Tree, Node, Arm)), Fell);
                     if Fell then
                        Join (Value, Statement_Value);
                        if First then
                           Merged := Origins;
                           First := False;
                        else
                           Join_Table (Merged, Origins);
                        end if;
                     end if;
                  end loop;
                  if not First then
                     Origins := Merged;
                  end if;
                  Falls_Through := not First;
                  Statement_Value := Value;
               end;

            when Syn.Bare_Block =>
               Process_Block (Tree, Syn.Body_Of (Tree, Node), Fell);

            when Syn.Loop_Statement | Syn.While_Statement
               | Syn.For_Statement =>
               --  The facts at the loop head are the join of the entry
               --  facts with every back edge: the body's fallthrough and
               --  its `continue` transfers.  Facts only grow, the lattice
               --  is finite, and each pass either repeats the head or
               --  adds to it, so the passes converge; the last one is
               --  repeated with reporting on, because the earlier passes
               --  reported from facts that were not yet complete.
               declare
                  Is_While : constant Boolean :=
                    Syn.Kind (Tree, Node) = Syn.While_Statement;
                  Is_For : constant Boolean :=
                    Syn.Kind (Tree, Node) = Syn.For_Statement;
                  Entry_State : Function_Table;
                  Head : Function_Table;
                  Exhausted_State : Function_Table;
                  Can_Exhaust : Boolean := False;
                  Frame : Loop_Frame;
                  Scratch : aliased Landin.Diagnostics.Diagnostic_List;
                  Outer_Sink : constant
                    not null access Landin.Diagnostics.Diagnostic_List := Sink;
                  Passes : Natural := 0;
                  Converged : Boolean := False;

                  function Fact_Width return Positive;

                  function Fact_Width return Positive is
                     Width : Natural := 0;
                  begin
                     for Id in 1 .. Landin.Checking.Signature_Count
                       (Types.all)
                     loop
                        Width := Natural'Max
                          (Width, Landin.Checking.Signature_Result_Count
                             (Types.all, Landin.Checking.Signature_Id (Id)));
                     end loop;
                     --  Union, captured storage, result positions and one
                     --  possible loss of positional detail at a join.
                     return Width + 3;
                  end Fact_Width;

                  --  Each source bit grows once; the presence chain has two
                  --  upward steps.  Include every tracked result position.
                  Pass_Limit : constant Positive := Origins'Length
                    * Fact_Width * (4 + Parameters + Declarations) + 2;

                  procedure Pass (Reporting : Boolean);

                  procedure Pass (Reporting : Boolean) is
                     Body_Fell : Boolean;
                     Next : Function_Table := Entry_State;
                  begin
                     Release (Frame);
                     Sink := (if Reporting
                              then Outer_Sink
                              else Scratch'Unchecked_Access);
                     Origins := Head;
                     Falls_Through := True;
                     Loop_Stack.Append
                       (Loop_Frame'
                          (Label        => Syn.Name (Tree, Node),
                           Cleanup_Base => Natural (Cleanup_Stack.Length),
                           others       => <>));

                     if Is_While then
                        declare
                           Test : constant Syn.Node_Id :=
                             Syn.Condition_Of (Tree, Node);
                        begin
                           if Syn.Kind (Tree, Test) = Syn.Binding then
                              Process_Statement (Tree, Test);
                           else
                              Evaluate (Test);
                           end if;
                        end;
                     end if;
                     Can_Exhaust := (Is_While or else Is_For)
                       and then Falls_Through;
                     Exhausted_State := Origins;

                     Process_Block
                       (Tree, Syn.Loop_Body (Tree, Node), Body_Fell,
                        Of_Loop => Node);
                     Frame := Loop_Stack.Last_Element;
                     Loop_Stack.Delete_Last;

                     if Body_Fell then
                        Join_Table (Next, Origins);
                     end if;
                     if Frame.Continues then
                        Join_Table (Next, Frame.Back_State.all);
                     end if;
                     Converged := Next = Head;
                     Head := Next;
                     Sink := Outer_Sink;
                  end Pass;
               begin
                  if Is_For then
                     --  Traversal sources and bounds are evaluated once,
                     --  before the loop head, not again on its back edges.
                     declare
                        Source_Fact : constant Origin_Fact :=
                          Fact_Of (Tree, Syn.Traversal_Lower (Tree, Node));
                        Element : constant Res.Declaration_Id :=
                          Declaration_At
                            (Tree, Syn.Traversal_Element (Tree, Node));
                     begin
                        if Syn.Traversal_Upper (Tree, Node) /= Syn.No_Node then
                           Evaluate (Syn.Traversal_Upper (Tree, Node));
                        elsif Element /= Res.No_Declaration
                          and then Element in Origins'Range
                        then
                           Origins (Element) :=
                             (if Landin.Checking.Traversal_Evidence_Of
                                (Types.all, Tree, Node)
                                  = Landin.Checking.No_Conformance
                               and then Has_References (Element)
                              then Source_Fact else No_Origin);
                        end if;
                     end;
                  end if;
                  if not Falls_Through then
                     Statement_Value := No_Value_Edge;
                     return;
                  end if;
                  Entry_State := Origins;
                  Head := Origins;
                  loop
                     Passes := Passes + 1;
                     if Passes > Pass_Limit then
                        raise Landin.Compiler_Defect
                          with "origin facts of a loop did not converge";
                     end if;
                     Pass (Reporting => False);
                     exit when Converged;
                  end loop;
                  Pass (Reporting => True);

                  --  Exhaustion keeps the final test's effects, not the
                  --  pre-test head.  Completion and break edges join only
                  --  when they actually reach the loop's continuation.
                  Origins := Exhausted_State;
                  Falls_Through := Can_Exhaust;
                  if Can_Exhaust
                    and then Syn.Complete_Body (Tree, Node) /= Syn.No_Node
                  then
                     Loop_Stack.Append
                       (Loop_Frame'
                          (Label        => Syn.Name (Tree, Node),
                           Cleanup_Base => Natural (Cleanup_Stack.Length),
                           others       => <>));
                     Process_Block
                       (Tree, Syn.Complete_Body (Tree, Node), Fell);
                     declare
                        Completion : Loop_Frame := Loop_Stack.Last_Element;
                     begin
                        Loop_Stack.Delete_Last;
                        Join (Frame.Value, Completion.Value);
                        if Completion.Exits then
                           if Frame.Exits then
                              Join_Table
                                (Frame.Exit_State.all,
                                 Completion.Exit_State.all);
                           else
                              Frame.Exit_State := Completion.Exit_State;
                              Completion.Exit_State := null;
                              Frame.Exits := True;
                           end if;
                        end if;
                        Release (Completion);
                     end;
                  end if;
                  if Frame.Exits then
                     if Falls_Through then
                        Join_Table (Origins, Frame.Exit_State.all);
                     else
                        Origins := Frame.Exit_State.all;
                     end if;
                     Falls_Through := True;
                  end if;
                  Statement_Value := Frame.Value;
                  Release (Frame);
               end;

            when Syn.Return_Statement | Syn.Fail_Statement
               | Syn.Break_Statement | Syn.Continue_Statement =>
               Evaluate (Syn.Condition_Of (Tree, Node));
               if Falls_Through then
                  declare
                     Continuing : constant Function_Table := Origins;
                     Guarded : constant Boolean :=
                       Syn.Condition_Of (Tree, Node) /= Syn.No_Node;
                  begin
                     --  The guard has already run on both outcomes.  Only
                     --  its taken edge evaluates a transfer value and unwinds
                     --  cleanups; neither may modify the untaken edge.
                     case Syn.Kind (Tree, Node) is
                        when Syn.Return_Statement =>
                           Run_Cleanups
                             (Tree, 1, Landin.Cleanup.Successful_Return);
                           if Falls_Through then
                              Check_Returns (Tree, Node);
                           end if;

                        when Syn.Fail_Statement =>
                           Evaluate (Syn.Value_Of (Tree, Node));
                           Run_Cleanups
                             (Tree, 1, Landin.Cleanup.Failure_Propagation);

                        when Syn.Break_Statement | Syn.Continue_Statement =>
                           declare
                              Target : constant Positive :=
                                Transfer_Loop (Tree, Node);
                              Value : Origin_Fact := No_Value_Edge;
                           begin
                              if Syn.Kind (Tree, Node) = Syn.Break_Statement
                              then
                                 Value := Fact_Of
                                   (Tree, Syn.Transfer_Value (Tree, Node));
                              end if;
                              Run_Cleanups
                                (Tree, Loop_Stack (Target).Cleanup_Base + 1,
                                 Landin.Cleanup.Structured_Transfer);
                              if Falls_Through then
                                 declare
                                    Frame : Loop_Frame := Loop_Stack (Target);
                                 begin
                                    if Syn.Kind (Tree, Node)
                                      = Syn.Break_Statement
                                    then
                                       Join (Frame.Value, Value);
                                       if Frame.Exits then
                                          Join_Table
                                            (Frame.Exit_State.all, Origins);
                                       else
                                          Frame.Exit_State :=
                                            new Function_Table'(Origins);
                                          Frame.Exits := True;
                                       end if;
                                    elsif Frame.Continues then
                                       Join_Table
                                         (Frame.Back_State.all, Origins);
                                    else
                                       Frame.Back_State :=
                                         new Function_Table'(Origins);
                                       Frame.Continues := True;
                                    end if;
                                    Loop_Stack.Replace_Element (Target, Frame);
                                 end;
                              end if;
                           end;

                        when others =>
                           null;
                     end case;
                     Falls_Through := Guarded;
                     if Guarded then
                        Origins := Continuing;
                     end if;
                  end;
               end if;

            when Syn.Defer_Statement | Syn.Undo_Statement =>
               --  Registration evaluates nothing; the call is walked on
               --  each edge that runs it.
               Cleanup_Stack.Append
                 (Cleanup_Entry'
                    (Kind   =>
                       (if Syn.Kind (Tree, Node) = Syn.Undo_Statement
                        then Landin.Cleanup.Failure_Undo
                        else Landin.Cleanup.Deferred_Call),
                     Call   => Syn.Cleanup_Call (Tree, Node),
                     Active => True));

            when Syn.Increment | Syn.Decrement =>
               Evaluate (Syn.Target_Of (Tree, Node));

            when Syn.Call | Syn.Labeled_Application | Syn.Try_Expression
               | Syn.Discard =>
               Evaluate (Node);

            when others =>
               null;
         end case;
      end Process_Statement;

      procedure Process_Block
        (Tree         : Syn.Tree;
         Block        : Syn.Node_Id;
         Fell_Through : out Boolean;
         Of_Loop      : Syn.Node_Id := Syn.No_Node)
      is
         Base : constant Natural := Natural (Cleanup_Stack.Length);
         Value : Origin_Fact := No_Origin;
      begin
         Fell_Through := Falls_Through;
         Statement_Value :=
           (if Falls_Through then No_Origin else No_Value_Edge);
         if Block = Syn.No_Node or else not Falls_Through then
            return;
         end if;
         Positions.Append
           (Position_Frame'(Block => Block, Index => 0, Of_Loop => Of_Loop));
         for Position in 1 .. Syn.Statement_Count (Tree, Block) loop
            Positions (Positions.Last_Index).Index := Position;
            Process_Statement
              (Tree, Syn.Nth_Statement (Tree, Block, Position));
            exit when not Falls_Through;
         end loop;
         if Falls_Through then
            Positions (Positions.Last_Index).Index :=
              Syn.Statement_Count (Tree, Block) + 1;
            if Syn.Block_Value (Tree, Block) /= Syn.No_Node then
               Value := Fact_Of (Tree, Syn.Block_Value (Tree, Block));
            end if;
            Run_Cleanups (Tree, Base + 1, Landin.Cleanup.Normal_Fallthrough);
         end if;
         --  A block value is captured before its cleanup, whereas named
         --  function returns are checked after cleanup has updated storage.
         Fell_Through := Falls_Through;
         Statement_Value :=
           (if Falls_Through then Value else No_Value_Edge);
         Cleanup_Stack.Set_Length (Ada.Containers.Count_Type (Base));
         Positions.Delete_Last;
      end Process_Block;

   begin
      if Signature = Landin.Checking.No_Signature then
         return;
      end if;

      Note_Exposed_Storage (Of_Tree, Body_Node);
      for Position in 1 .. Syn.Parameter_Count (Of_Tree, Function_Node) loop
         declare
            Node : constant Syn.Node_Id :=
              Syn.Nth_Parameter (Of_Tree, Function_Node, Position);
            Id : constant Res.Declaration_Id := Declaration_At (Of_Tree, Node);
         begin
            if Id /= Res.No_Declaration then
               Parameter_Of (Id) := Position;
               Exposed (Positive (Id)) := Exposed (Positive (Id))
                 or else Syn.Convention_Of (Of_Tree, Node)
                   = Syn.Inout_Convention;
               Parameter_Escapes (Position) := Syn.Is_Escaping (Of_Tree, Node);
               if Has_References (Id) then
                  Origins (Id).Value.From (Position) := True;
                  Origins (Id).Value.Derives (Positive (Id)) := True;
               end if;
            end if;
         end;
      end loop;

      for Position in 1 .. Syn.Return_Count (Of_Tree, Function_Node) loop
         declare
            Node : constant Syn.Node_Id :=
              Syn.Nth_Return (Of_Tree, Function_Node, Position);
            Id : constant Res.Declaration_Id := Declaration_At (Of_Tree, Node);
         begin
            if Id /= Res.No_Declaration then
               Origins (Id) := No_Origin;
            end if;
         end;
      end loop;

      if Syn.Kind (Of_Tree, Body_Node) = Syn.Block then
         --  The final edge is a return only when the body reaches it; a
         --  body that ends in `fail` or `return` has no such edge, and
         --  each `return` checked its own.
         declare
            Fell : Boolean;
         begin
            Process_Block (Of_Tree, Body_Node, Fell);
            if Fell then
               Check_Returns (Of_Tree, Function_Node);
            end if;
         end;
      else
         declare
            Value : constant Origin_Fact := Fact_Of (Of_Tree, Body_Node);
            Count : constant Natural :=
              Syn.Return_Count (Of_Tree, Function_Node);
         begin
            --  Evaluate the body once, including none-returning bodies.
            --  Each position of an anonymous result fills its own named
            --  return, rather than trusting the enclosing signature or
            --  assigning every field the aggregate's union of sources.
            if Falls_Through then
               for Position in 1 .. Count loop
                  declare
                     Returned : constant Syn.Node_Id :=
                       Syn.Nth_Return (Of_Tree, Function_Node, Position);
                     Id : constant Res.Declaration_Id :=
                       Declaration_At (Of_Tree, Returned);
                  begin
                     Origins (Id) :=
                       (if Count = 1 then Value
                        else Nth_Result (Value, Position));
                  end;
               end loop;
               Check_Returns (Of_Tree, Body_Node);
            end if;
         end;
      end if;
   end Check_Function;

end Landin.Stages.Checking.References;
