with Ada.Containers.Vectors;

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

      --  Untracked *suppresses* the frame-escape refusal below, so it is
      --  set only by [0470]'s integer-to-pointer conversion, where there is
      --  genuinely nothing to know.  D189's empty case contributes
      --  No_Origin instead: an atom name reaches Fact_Of through no arm and
      --  gets all four fields false, which is the answer this increment
      --  wants.  Setting Untracked there would launder every frame pointer
      --  joined with it.
      type Origin_Fact is record
         Frame      : Boolean := False;
         Untracked  : Boolean := False;
         From       : Parameter_Bits := [others => False];
         Derives    : Declaration_Bits := [others => False];
      end record;

      No_Origin : constant Origin_Fact := (others => <>);
      type Origin_Table is
        array (Res.Declaration_Id range <>) of Origin_Fact;
      Origins : Origin_Table
        (Res.Declaration_Id'(1)
         .. Res.Declaration_Id (Res.Declaration_Count (Meanings.all))) :=
           [others => No_Origin];
      --  A pattern binding's value and its backing storage can have distinct
      --  origins.  Pointer/slice-backed and computed match subjects are
      --  copied into a frame temporary by lowering, while a reference value
      --  carried in their payload still points where the subject said.
      Pattern_Storage : Origin_Table (Origins'Range) := [others => No_Origin];
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
      --  back edge.
      type Loop_Frame is record
         Label        : Landin.Source.Names.Name_Id :=
           Landin.Source.Names.No_Name;
         Cleanup_Base : Natural := 0;
         Exits        : Boolean := False;
         Exit_State   : Function_Table := [others => No_Origin];
         Continues    : Boolean := False;
         Back_State   : Function_Table := [others => No_Origin];
         Value        : Origin_Fact := No_Origin;
      end record;

      package Loop_Frames is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Loop_Frame);

      Loop_Stack : Loop_Frames.Vector;

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

      function Match_Subject_Is_Copied
        (Tree : Syn.Tree; Subject : Syn.Node_Id) return Boolean;

      function Storage_Fact
        (Tree : Syn.Tree; Place : Syn.Node_Id) return Origin_Fact;

      function Fact_Of
        (Tree : Syn.Tree; Node : Syn.Node_Id) return Origin_Fact;

      function Call_Signature
        (Tree : Syn.Tree; Call : Syn.Node_Id)
         return Landin.Checking.Signature_Id;

      function Runtime_Argument
        (Tree : Syn.Tree;
         Call : Syn.Node_Id;
         Formal : Positive) return Syn.Node_Id;

      function First_Derivation
        (Fact : Origin_Fact) return Res.Declaration_Id;

      procedure Report_Escape
        (Tree : Syn.Tree;
         Node : Syn.Node_Id;
         Fact : Origin_Fact;
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

      procedure Check_Borrows (Tree : Syn.Tree; Call : Syn.Node_Id);

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

      procedure Join (Into_Fact : in out Origin_Fact; Other : Origin_Fact);

      procedure Join (Into_Fact : in out Origin_Fact; Other : Origin_Fact) is
      begin
         Into_Fact.Frame := Into_Fact.Frame or Other.Frame;
         Into_Fact.Untracked := Into_Fact.Untracked or Other.Untracked;
         for Position in Into_Fact.From'Range loop
            Into_Fact.From (Position) :=
              Into_Fact.From (Position) or Other.From (Position);
         end loop;
         for Id in Into_Fact.Derives'Range loop
            Into_Fact.Derives (Id) :=
              Into_Fact.Derives (Id) or Other.Derives (Id);
         end loop;
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
            begin
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

      function Match_Subject_Is_Copied
        (Tree : Syn.Tree; Subject : Syn.Node_Id) return Boolean
      is
         Where : Syn.Node_Id := Subject;

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
         --  Keep this predicate identical to Lower_Variant_Match's
         --  Has_Computed_Index/Has_Reference_Storage choice.  Those subjects
         --  are copied once; every other checked named place is matched in
         --  its actual storage.
         while Syn.Kind (Tree, Where)
           in Syn.Member_Selection | Syn.Element_Index
         loop
            if Syn.Kind (Tree, Where) = Syn.Element_Index
              and then not Is_Constant_Index (Where)
            then
               return True;
            elsif Syn.Kind (Tree, Where) = Syn.Element_Index
              and then Landin.Checking.Type_Of
                (Types.all, Tree, Syn.Target_Of (Tree, Where)) = Ty.Slice_Value
            then
               return True;
            elsif Syn.Kind (Tree, Where) = Syn.Member_Selection
              and then Landin.Checking.Field_Index
                (Types.all, Tree, Where) = 0
              and then Landin.Checking.Type_Of
                (Types.all, Tree, Syn.Target_Of (Tree, Where))
                  = Ty.Pointer_Value
            then
               return True;
            end if;
            Where := Syn.Target_Of (Tree, Where);
         end loop;
         return False;
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

      function First_Derivation (Fact : Origin_Fact)
        return Res.Declaration_Id
      is
      begin
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
         Fact : Origin_Fact;
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
                     Fact : constant Origin_Fact :=
                       Known_Fact (Tree, Known, Argument);
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

      procedure Check_Borrows (Tree : Syn.Tree; Call : Syn.Node_Id)
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
               then
                  --  [0830]: a borrow is a view.  A scalar computed from
                  --  one carries derivation facts for [0790]'s clauses but
                  --  holds no reference into the mutated storage.
                  for Borrower in Origins'Range loop
                     if Borrower /= Mutated
                       and then Has_References (Borrower)
                       and then Origins (Borrower).Derives
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

      function Storage_Fact (Tree : Syn.Tree; Place : Syn.Node_Id)
        return Origin_Fact
      is
         Result : Origin_Fact := No_Origin;
         Id : constant Res.Declaration_Id :=
           Root_Declaration (Tree, Place);
         Selected : Syn.Node_Id := Place;
      begin
         --  A dereference or slice index selects storage behind a
         --  reference, not the local descriptor which holds it.
         --  Ordinary fields and fixed-array indices keep selecting
         --  their containing storage until such a boundary occurs.
         while Syn.Kind (Tree, Selected)
           in Syn.Member_Selection | Syn.Element_Index
         loop
            declare
               Target : constant Syn.Node_Id :=
                 Syn.Target_Of (Tree, Selected);
               Kind : constant Ty.Type_Kind :=
                 Landin.Checking.Type_Of (Types.all, Tree, Target);
            begin
               if (Syn.Kind (Tree, Selected) = Syn.Member_Selection
                   and then Kind = Ty.Pointer_Value)
                 or else
                   (Syn.Kind (Tree, Selected) = Syn.Element_Index
                    and then Kind = Ty.Slice_Value)
               then
                  Result := Fact_Of (Tree, Target);
                  if Id /= Res.No_Declaration then
                     Result.Derives (Positive (Id)) := True;
                  end if;
                  return Result;
               end if;
               Selected := Target;
            end;
         end loop;
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
      end Storage_Fact;

      function Fact_Of (Tree : Syn.Tree; Node : Syn.Node_Id)
        return Origin_Fact
      is
         Result : Origin_Fact := No_Origin;
      begin
         if Node = Syn.No_Node then
            return Result;
         end if;
         case Syn.Kind (Tree, Node) is
            when Syn.Name_Reference =>
               if Res.Verdict_Of (Meanings.all, Tree, Node) = Res.Bound then
                  declare
                     Id : constant Res.Declaration_Id :=
                       Res.Bound_To (Meanings.all, Tree, Node);
                  begin
                     if Id in Origins'Range then
                        return Origins (Id);
                     end if;
                  end;
               end if;

            when Syn.Any_Construction =>
               return Fact_Of (Tree, Syn.Operand_Of (Tree, Node));

            when Syn.Pointer_Conversion =>
               Result.Untracked := True;
               return Result;

            when Syn.Address_Of =>
               return Storage_Fact (Tree, Syn.Operand_Of (Tree, Node));

            when Syn.Member_Selection | Syn.Element_Index
               | Syn.Inclusive_Slice | Syn.Half_Open_Slice =>
               if Syn.Kind (Tree, Node)
                    in Syn.Inclusive_Slice | Syn.Half_Open_Slice
                 and then Landin.Checking.Type_Of
                   (Types.all, Tree, Syn.Target_Of (Tree, Node))
                     = Ty.Fixed_Array
               then
                  return Storage_Fact (Tree, Syn.Target_Of (Tree, Node));
               end if;
               Result := Fact_Of (Tree, Syn.Target_Of (Tree, Node));
               for Slot in 2 .. Syn.Slot_Count (Tree, Node) loop
                  declare
                     Ignored : constant Origin_Fact :=
                       Fact_Of (Tree, Syn.Slot (Tree, Node, Slot));
                  begin
                     pragma Unreferenced (Ignored);
                  end;
               end loop;
               if Syn.Kind (Tree, Node)
                    in Syn.Member_Selection | Syn.Element_Index
                 and then Landin.Checking.Type_Of (Types.all, Tree, Node)
                   in Ty.Scalar_Name
               then
                  return No_Origin;
               end if;
               declare
                  Id : constant Res.Declaration_Id :=
                    Root_Declaration (Tree, Node);
               begin
                  if Id /= Res.No_Declaration then
                     Result.Derives (Positive (Id)) := True;
                     if Syn.Kind (Tree, Node)
                          in Syn.Inclusive_Slice | Syn.Half_Open_Slice
                       and then Res.Sort_Of (Meanings.all, Id)
                         in Res.Local_Binding | Res.Named_Return
                       and then Landin.Checking.Type_Of (Types.all, Id)
                         = Ty.Fixed_Array
                     then
                        --  A view into a local fixed array points into this
                        --  frame even though the array value itself contains
                        --  no references. A local slice instead carries its
                        --  own source fact and must not acquire frame origin.
                        Result.Frame := True;
                     end if;
                     if Parameter_Of (Id) > 0
                       and then Landin.Checking.Type_Of
                         (Types.all, Tree, Node)
                           in Ty.Pointer_Value | Ty.Slice_Value
                     then
                        if Syn.Kind (Tree, Node)
                             in Syn.Inclusive_Slice | Syn.Half_Open_Slice
                        then
                           declare
                              Parameter_Tree : constant
                                not null access constant Syn.Tree := Tree_For
                                  (Res.Source_Of (Meanings.all, Id));
                              Parameter_Node : constant Syn.Node_Id :=
                                Res.Node_Of (Meanings.all, Id);
                           begin
                              if Landin.Checking.Type_Of (Types.all, Id)
                                   = Ty.Slice_Value
                                or else Syn.Convention_Of
                                  (Parameter_Tree.all, Parameter_Node)
                                    = Syn.Inout_Convention
                              then
                                 Result.From (Parameter_Of (Id)) := True;
                              else
                                 Result.Frame := True;
                              end if;
                           end;
                        else
                           Result.From (Parameter_Of (Id)) := True;
                        end if;
                     end if;
                  end if;
               end;
               return Result;

            when Syn.Call | Syn.Labeled_Application =>
               if Landin.Checking.Text_Conversion_Of
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
                     Check_Escaping_Arguments (Tree, Node, Known);
                     Check_Borrows (Tree, Node);
                     if Landin.Checking.Holds (Types.all, Called)
                       and then Landin.Checking.Signature_Result_Count
                         (Types.all, Called) = 1
                       and then Landin.Checking.Contains_References
                         (Types.all,
                          Landin.Checking.Nth_Signature_Result
                            (Types.all, Called, 1))
                     then
                        for Source in
                          1 .. Landin.Checking.Signature_Return_Source_Count
                            (Types.all, Called, 1)
                        loop
                           declare
                              Formal : constant Positive :=
                                Landin.Checking.Nth_Signature_Return_Source
                                  (Types.all, Called, 1, Source);
                              Argument : constant Syn.Node_Id :=
                                Runtime_Argument (Tree, Node, Formal);
                           begin
                              if Argument /= Syn.No_Node then
                                 --  An inout return source names a place. A
                                 --  returned view may point into that place
                                 --  even when its current value contains no
                                 --  reference (an inline fixed array is the
                                 --  motivating case). Other conventions keep
                                 --  describing origins carried by the value.
                                 if Landin.Checking.Nth_Signature_Parameter
                                   (Types.all, Called, Formal).Convention
                                      = Syn.Inout_Convention
                                 then
                                    Join
                                      (Result,
                                       Storage_Fact (Tree, Argument));
                                 else
                                    Join
                                      (Result,
                                       Known_Fact (Tree, Known, Argument));
                                 end if;
                                 declare
                                    Id : constant Res.Declaration_Id :=
                                      Root_Declaration (Tree, Argument);
                                 begin
                                    if Id /= Res.No_Declaration then
                                       Result.Derives (Positive (Id)) := True;
                                    end if;
                                 end;
                              end if;
                           end;
                        end loop;
                     end if;
                  end;
                  return Result;
               end if;

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
            Join (Result, Fact_Of (Tree, Syn.Slot (Tree, Node, Slot)));
         end loop;
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
               Fact : constant Origin_Fact := Origins (Id);
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
               elsif not Fact.Untracked then
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
         Fact : constant Origin_Fact := Fact_Of (Tree, Value);
      begin
         if Id = Res.No_Declaration or else Id not in Origins'Range then
            return;
         end if;

         if Res.Sort_Of (Meanings.all, Id) = Res.Module_Binding
           and then not Fact.Untracked
         then
            if Fact.Frame then
               Report_Escape
                 (Tree, Value, Fact,
                  "this frame-origin reference cannot be stored in module"
                  & " state",
                  Syn.Origin (Tree, Place));
            else
               for Source in Fact.From'Range loop
                  if Fact.From (Source)
                    and then not Parameter_Escapes (Source)
                  then
                     Report_Escape
                       (Tree, Value, Fact,
                        "this non-escaping parameter cannot be retained in"
                        & " module state",
                        Syn.Origin (Tree, Place));
                     exit;
                  end if;
               end loop;
            end if;
         end if;

         if Syn.Kind (Tree, Place) = Syn.Name_Reference then
            Origins (Id) := Fact;
         else
            Join (Origins (Id), Fact);
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
         case Syn.Kind (Tree, Node) is
            when Syn.Binding =>
               declare
                  Id : constant Res.Declaration_Id :=
                    Declaration_At (Tree, Node);
               begin
                  if Id /= Res.No_Declaration then
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
                                   (if Has_References (Id)
                                    then Value else No_Origin);
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
                  Before : constant Function_Table := Origins;
                  Merged : Function_Table := [others => No_Origin];
                  First  : Boolean := True;

                  Value  : Origin_Fact := No_Origin;

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
                     Origins := Before;
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
                        Process_Block (Tree, Syn.Body_Of (Tree, This), Fell);
                     end;
                     Merge_Branch (Fell);
                  end loop;
                  Origins := Before;
                  if Syn.Else_Body (Tree, Node) /= Syn.No_Node then
                     Process_Block (Tree, Syn.Else_Body (Tree, Node), Fell);
                     Merge_Branch (Fell);
                  else
                     Statement_Value := No_Origin;
                     Merge_Branch (True);
                  end if;
                  if not First then
                     Origins := Merged;
                  end if;
                  Statement_Value := Value;
               end;

            when Syn.Match_Statement =>
               declare
                  Subject_Node : constant Syn.Node_Id :=
                    Syn.Match_Subject (Tree, Node);
                  Subject_Value : constant Origin_Fact :=
                    Fact_Of (Tree, Subject_Node);
                  Subject_Storage : constant Origin_Fact :=
                    (if Match_Subject_Is_Copied (Tree, Subject_Node)
                     then (Frame => True, others => <>)
                     else Storage_Fact (Tree, Subject_Node));
                  Before : constant Function_Table := Origins;
                  Merged : Function_Table := [others => No_Origin];
                  First  : Boolean := True;
                  Value  : Origin_Fact := No_Origin;
               begin
                  for Arm in 1 .. Syn.Match_Arm_Count (Tree, Node) loop
                     declare
                        This : constant Syn.Node_Id :=
                          Syn.Nth_Match_Arm (Tree, Node, Arm);
                     begin
                        Origins := Before;
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
                                 Pattern_Storage (Id) := Subject_Storage;
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
                  Entry_State : constant Function_Table := Origins;
                  Head : Function_Table := Origins;
                  Frame : Loop_Frame;
                  Scratch : aliased Landin.Diagnostics.Diagnostic_List;
                  Outer_Sink : constant
                    not null access Landin.Diagnostics.Diagnostic_List := Sink;
                  Passes : Natural := 0;
                  Converged : Boolean := False;

                  --  One bit per fact is the least a pass that has not
                  --  converged adds, so this many passes is impossible.
                  Pass_Limit : constant Positive :=
                    Origins'Length * (2 + Parameters + Declarations) + 2;

                  procedure Pass (Reporting : Boolean);

                  procedure Pass (Reporting : Boolean) is
                     Body_Fell : Boolean;
                     Next : Function_Table := Entry_State;
                  begin
                     Sink := (if Reporting
                              then Outer_Sink
                              else Scratch'Unchecked_Access);
                     Origins := Head;
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
                     elsif Is_For then
                        declare
                           Source_Fact : Origin_Fact :=
                             Fact_Of (Tree, Syn.Traversal_Lower (Tree, Node));
                           Element : constant Res.Declaration_Id :=
                             Declaration_At
                               (Tree, Syn.Traversal_Element (Tree, Node));
                        begin
                           if Syn.Traversal_Upper (Tree, Node) /= Syn.No_Node
                           then
                              Source_Fact := Fact_Of
                                (Tree, Syn.Traversal_Upper (Tree, Node));
                           elsif Element /= Res.No_Declaration
                             and then Element in Origins'Range
                           then
                              if Landin.Checking.Traversal_Evidence_Of
                                (Types.all, Tree, Node)
                                   = Landin.Checking.No_Conformance
                                and then Has_References (Element)
                              then
                                 --  D160: a reference-bearing element read
                                 --  out of the traversed storage derives
                                 --  from wherever that storage came from.
                                 Origins (Element) := Source_Fact;
                              else
                                 --  A reference-free ordinary element
                                 --  carries no origin into scalar
                                 --  computations. D180's iterable.item
                                 --  likewise returns an ordinary value with
                                 --  [1320]'s source-free signature.
                                 Origins (Element) := No_Origin;
                              end if;
                           end if;
                        end;
                     end if;

                     Process_Block
                       (Tree, Syn.Loop_Body (Tree, Node), Body_Fell,
                        Of_Loop => Node);
                     Frame := Loop_Stack.Last_Element;
                     Loop_Stack.Delete_Last;

                     if Body_Fell then
                        Join_Table (Next, Origins);
                     end if;
                     if Frame.Continues then
                        Join_Table (Next, Frame.Back_State);
                     end if;
                     Converged := Next = Head;
                     Head := Next;
                     Sink := Outer_Sink;
                  end Pass;
               begin
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

                  --  A while or for leaves when its test fails, from the
                  --  head facts, through `complete` if there is one; any
                  --  loop also leaves through its `break` edges.  An
                  --  unconditional loop without one never leaves, and the
                  --  head facts stand in for its unreachable exit.
                  Origins := Head;
                  if Is_While or else Is_For then
                     if Syn.Complete_Body (Tree, Node) /= Syn.No_Node then
                        --  `complete` runs on the exhausted edge and may
                        --  itself leave through `break with`: those are
                        --  exits of this loop too.
                        Loop_Stack.Append
                          (Loop_Frame'
                             (Label        => Syn.Name (Tree, Node),
                              Cleanup_Base =>
                                Natural (Cleanup_Stack.Length),
                              others       => <>));
                        Process_Block
                          (Tree, Syn.Complete_Body (Tree, Node), Fell);
                        declare
                           Completion : constant Loop_Frame :=
                             Loop_Stack.Last_Element;
                        begin
                           Loop_Stack.Delete_Last;
                           Join (Frame.Value, Completion.Value);
                           if Completion.Exits then
                              if Frame.Exits then
                                 Join_Table
                                   (Frame.Exit_State, Completion.Exit_State);
                              else
                                 Frame.Exit_State := Completion.Exit_State;
                                 Frame.Exits := True;
                              end if;
                           end if;
                           if not Fell then
                              Origins := [others => No_Origin];
                           end if;
                        end;
                     end if;
                     if Frame.Exits then
                        Join_Table (Origins, Frame.Exit_State);
                     end if;
                  elsif Frame.Exits then
                     Origins := Frame.Exit_State;
                  end if;
                  Statement_Value := Frame.Value;
               end;

            when Syn.Return_Statement =>
               Evaluate (Syn.Condition_Of (Tree, Node));
               Run_Cleanups (Tree, 1, Landin.Cleanup.Successful_Return);
               Check_Returns (Tree, Node);

            when Syn.Fail_Statement =>
               Evaluate (Syn.Condition_Of (Tree, Node));
               Evaluate (Syn.Value_Of (Tree, Node));
               Run_Cleanups (Tree, 1, Landin.Cleanup.Failure_Propagation);

            when Syn.Break_Statement | Syn.Continue_Statement =>
               Evaluate (Syn.Condition_Of (Tree, Node));
               declare
                  Target : constant Positive := Transfer_Loop (Tree, Node);
                  Frame : Loop_Frame := Loop_Stack (Target);
               begin
                  if Syn.Kind (Tree, Node) = Syn.Break_Statement then
                     Join
                       (Frame.Value,
                        Fact_Of (Tree, Syn.Transfer_Value (Tree, Node)));
                  end if;
                  Run_Cleanups
                    (Tree, Frame.Cleanup_Base + 1,
                     Landin.Cleanup.Structured_Transfer);
                  if Syn.Kind (Tree, Node) = Syn.Break_Statement then
                     if Frame.Exits then
                        Join_Table (Frame.Exit_State, Origins);
                     else
                        Frame.Exit_State := Origins;
                        Frame.Exits := True;
                     end if;
                  elsif Frame.Continues then
                     Join_Table (Frame.Back_State, Origins);
                  else
                     Frame.Back_State := Origins;
                     Frame.Continues := True;
                  end if;
                  Loop_Stack.Replace_Element (Target, Frame);
               end;

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
      begin
         Fell_Through := True;
         if Block = Syn.No_Node then
            return;
         end if;
         Positions.Append
           (Position_Frame'(Block => Block, Index => 0, Of_Loop => Of_Loop));
         for Position in 1 .. Syn.Statement_Count (Tree, Block) loop
            declare
               Statement : constant Syn.Node_Id :=
                 Syn.Nth_Statement (Tree, Block, Position);
            begin
               Positions (Positions.Last_Index).Index := Position;
               Process_Statement (Tree, Statement);
               if Syn.Kind (Tree, Statement)
                    in Syn.Return_Statement | Syn.Fail_Statement
                       | Syn.Break_Statement | Syn.Continue_Statement
                 and then Syn.Condition_Of (Tree, Statement) = Syn.No_Node
               then
                  Fell_Through := False;
                  exit;
               end if;
            end;
         end loop;
         Statement_Value := No_Origin;
         if Fell_Through then
            Positions (Positions.Last_Index).Index :=
              Syn.Statement_Count (Tree, Block) + 1;
            if Syn.Block_Value (Tree, Block) /= Syn.No_Node then
               Statement_Value :=
                 Fact_Of (Tree, Syn.Block_Value (Tree, Block));
            end if;
            Run_Cleanups (Tree, Base + 1, Landin.Cleanup.Normal_Fallthrough);
         end if;
         Cleanup_Stack.Set_Length (Ada.Containers.Count_Type (Base));
         Positions.Delete_Last;
      end Process_Block;

   begin
      if Signature = Landin.Checking.No_Signature then
         return;
      end if;

      for Position in 1 .. Syn.Parameter_Count (Of_Tree, Function_Node) loop
         declare
            Node : constant Syn.Node_Id :=
              Syn.Nth_Parameter (Of_Tree, Function_Node, Position);
            Id : constant Res.Declaration_Id := Declaration_At (Of_Tree, Node);
         begin
            if Id /= Res.No_Declaration then
               Parameter_Of (Id) := Position;
               Parameter_Escapes (Position) := Syn.Is_Escaping (Of_Tree, Node);
               if Has_References (Id) then
                  Origins (Id).From (Position) := True;
                  Origins (Id).Derives (Positive (Id)) := True;
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
      elsif Syn.Return_Count (Of_Tree, Function_Node) = 1 then
         declare
            Returned : constant Syn.Node_Id :=
              Syn.Nth_Return (Of_Tree, Function_Node, 1);
            Id : constant Res.Declaration_Id :=
              Declaration_At (Of_Tree, Returned);
         begin
            Origins (Id) := Fact_Of (Of_Tree, Body_Node);
            Check_Returns (Of_Tree, Body_Node);
         end;
      end if;
   end Check_Function;

end Landin.Stages.Checking.References;
