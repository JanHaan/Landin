with Landin.Checking;
with Landin.Diagnostics.Checking;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Syntax.Forest;
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
   use type Landin.Provenance.Declaration_Id;
   use type Res.Application_Class;
   use type Res.Declaration_Sort;
   use type Res.Verdict;
   use type Landin.Source.Byte_Offset;
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

      type Parameter_Bits is array (Positive range 1 .. Parameters) of Boolean;
      type Declaration_Bits is
        array (Positive range 1 .. Declarations) of Boolean;

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
      Parameter_Of : array (Origins'Range) of Natural := [others => 0];
      Parameter_Escapes : array (1 .. Parameters) of Boolean :=
        [others => False];

      Signature : constant Landin.Checking.Signature_Id :=
        Landin.Checking.Signature_Of
          (Types.all, Of_Tree, Function_Node);

      function Tree_For (Source : Landin.Source.Source_Id)
        return not null access constant Syn.Tree
        is (Syn.Forest.Tree_Of (Trees.all, Source));

      function Declaration_At
        (Tree : Syn.Tree; Node : Syn.Node_Id) return Res.Declaration_Id;

      function Root_Declaration
        (Tree : Syn.Tree; Node : Syn.Node_Id) return Res.Declaration_Id;

      function Has_References (Id : Res.Declaration_Id) return Boolean;

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

      procedure Check_Escaping_Arguments
        (Tree : Syn.Tree; Call : Syn.Node_Id);

      function Has_Future_Use
        (Borrower : Res.Declaration_Id;
         After    : Landin.Source.Byte_Offset) return Boolean;

      procedure Check_Borrows (Tree : Syn.Tree; Call : Syn.Node_Id);

      procedure Check_Returns (Tree : Syn.Tree; At_Node : Syn.Node_Id);

      procedure Assign
        (Tree : Syn.Tree; Place : Syn.Node_Id; Value : Syn.Node_Id);

      procedure Process_Statement (Tree : Syn.Tree; Node : Syn.Node_Id);

      procedure Process_Block (Tree : Syn.Tree; Block : Syn.Node_Id);

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
            declare
               Nominal : constant Landin.Checking.Nominal_Type_Id :=
                 Landin.Checking.Array_Element_Nominal (Types.all, Id);
            begin
               return Landin.Checking.Array_Length (Types.all, Id) > 0
                 and then Nominal /= Landin.Checking.No_Nominal_Type
                 and then Landin.Checking.Has_Layout (Types.all, Nominal)
                 and then Landin.Checking.Contains_References
                   (Types.all, Nominal);
            end;
         end if;
         return False;
      end Has_References;

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
               Position : constant Natural :=
                 (if Syn.Kind (Tree, Raw) = Syn.Call_Argument
                  then Res.Position_Of (Meanings.all, Tree, Raw)
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
            Into    => Into);
      end Report_Escape;

      procedure Check_Escaping_Arguments
        (Tree : Syn.Tree; Call : Syn.Node_Id)
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
                     Fact : constant Origin_Fact := Fact_Of (Tree, Argument);
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

      function Has_Future_Use
        (Borrower : Res.Declaration_Id;
         After    : Landin.Source.Byte_Offset) return Boolean
      is
         None : constant Landin.Source.Byte_Offset :=
           Landin.Source.Byte_Offset'Last;
         Read_At : Landin.Source.Byte_Offset := None;
         Killed_At : Landin.Source.Byte_Offset := None;

         procedure Visit (Node : Syn.Node_Id);

         procedure Visit (Node : Syn.Node_Id) is
         begin
            if Node = Syn.No_Node
              or else Syn.Where (Of_Tree, Node).Last <= After
              or else Syn.Kind (Of_Tree, Node) = Syn.Anonymous_Function
            then
               return;
            end if;

            if Syn.Kind (Of_Tree, Node) = Syn.Assignment then
               declare
                  Place : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
               begin
                  Visit (Syn.Value_Of (Of_Tree, Node));
                  if Syn.Kind (Of_Tree, Place) = Syn.Name_Reference
                    and then Root_Declaration (Of_Tree, Place) = Borrower
                  then
                     Killed_At := Landin.Source.Byte_Offset'Min
                       (Killed_At, Syn.Where (Of_Tree, Node).First);
                  else
                     for Slot in 1 .. Syn.Slot_Count (Of_Tree, Place) loop
                        Visit (Syn.Slot (Of_Tree, Place, Slot));
                     end loop;
                  end if;
                  return;
               end;
            end if;

            if Syn.Kind (Of_Tree, Node) = Syn.Name_Reference
              and then Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound
              and then Res.Bound_To (Meanings.all, Of_Tree, Node) = Borrower
            then
               Read_At := Landin.Source.Byte_Offset'Min
                 (Read_At, Syn.Where (Of_Tree, Node).First);
               return;
            end if;

            for Slot in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
               Visit (Syn.Slot (Of_Tree, Node, Slot));
            end loop;
         end Visit;
      begin
         Visit (Body_Node);
         return Read_At /= None and then Read_At < Killed_At;
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
                  for Borrower in Origins'Range loop
                     if Borrower /= Mutated
                       and then Origins (Borrower).Derives
                         (Positive (Mutated))
                       and then Has_Future_Use
                         (Borrower, Syn.Where (Tree, Call).First)
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
                              Into    => Into);
                        end;
                        exit;
                     end if;
                  end loop;
               end if;
            end;
         end loop;
      end Check_Borrows;

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
               declare
                  Place : constant Syn.Node_Id := Syn.Operand_Of (Tree, Node);
                  Id : constant Res.Declaration_Id :=
                    Root_Declaration (Tree, Place);
               begin
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
                        when others =>
                           null;
                     end case;
                  end if;
               end;
               return Result;

            when Syn.Member_Selection | Syn.Element_Index
               | Syn.Inclusive_Slice | Syn.Half_Open_Slice =>
               Result := Fact_Of (Tree, Syn.Target_Of (Tree, Node));
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
               if Syn.Kind (Tree, Node) = Syn.Labeled_Application
                 and then Res.Class_Of (Meanings.all, Tree, Node)
                   /= Res.Function_Call
               then
                  null;
               else
                  Check_Escaping_Arguments (Tree, Node);
                  Check_Borrows (Tree, Node);
                  declare
                     Called : constant Landin.Checking.Signature_Id :=
                       Call_Signature (Tree, Node);
                  begin
                     if Landin.Checking.Holds (Types.all, Called)
                       and then Landin.Checking.Signature_Result_Count
                         (Types.all, Called) = 1
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
                                 Join (Result, Fact_Of (Tree, Argument));
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

            when Syn.If_Statement =>
               for Arm in 1 .. Syn.Arm_Count (Tree, Node) loop
                  Join
                    (Result,
                     Fact_Of
                       (Tree, Syn.Block_Value
                          (Tree, Syn.Body_Of
                             (Tree, Syn.Nth_Arm (Tree, Node, Arm)))));
               end loop;
               if Syn.Else_Body (Tree, Node) /= Syn.No_Node then
                  Join
                    (Result,
                     Fact_Of
                       (Tree, Syn.Block_Value
                          (Tree, Syn.Else_Body (Tree, Node))));
               end if;
               return Result;

            when Syn.Match_Statement =>
               for Arm in 1 .. Syn.Match_Arm_Count (Tree, Node) loop
                  Join
                    (Result,
                     Fact_Of
                       (Tree, Syn.Block_Value
                          (Tree, Syn.Body_Of
                             (Tree, Syn.Nth_Match_Arm
                                (Tree, Node, Arm)))));
               end loop;
               return Result;

            when Syn.Bare_Block =>
               return Fact_Of
                 (Tree, Syn.Block_Value (Tree, Syn.Body_Of (Tree, Node)));

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
                        Into    => Into);
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

      procedure Process_Statement (Tree : Syn.Tree; Node : Syn.Node_Id) is
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

            when Syn.Assignment =>
               Assign
                 (Tree, Syn.Target_Of (Tree, Node), Syn.Value_Of (Tree, Node));

            when Syn.If_Statement =>
               declare
                  Before : constant Origin_Table := Origins;
                  Merged : Origin_Table (Origins'Range) :=
                    [others => No_Origin];
                  First  : Boolean := True;

                  procedure Merge_Branch;

                  procedure Merge_Branch is
                  begin
                     if First then
                        Merged := Origins;
                        First := False;
                     else
                        for Id in Origins'Range loop
                           Join (Merged (Id), Origins (Id));
                        end loop;
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
                        end if;
                        Process_Block (Tree, Syn.Body_Of (Tree, This));
                     end;
                     Merge_Branch;
                  end loop;
                  Origins := Before;
                  if Syn.Else_Body (Tree, Node) /= Syn.No_Node then
                     Process_Block (Tree, Syn.Else_Body (Tree, Node));
                  end if;
                  Merge_Branch;
                  Origins := Merged;
               end;

            when Syn.Match_Statement =>
               declare
                  Before : constant Origin_Table := Origins;
                  Merged : Origin_Table (Origins'Range) :=
                    [others => No_Origin];
                  First  : Boolean := True;
               begin
                  for Arm in 1 .. Syn.Match_Arm_Count (Tree, Node) loop
                     Origins := Before;
                     Process_Block
                       (Tree, Syn.Body_Of
                          (Tree, Syn.Nth_Match_Arm (Tree, Node, Arm)));
                     if First then
                        Merged := Origins;
                        First := False;
                     else
                        for Id in Origins'Range loop
                           Join (Merged (Id), Origins (Id));
                        end loop;
                     end if;
                  end loop;
                  Origins := Merged;
               end;

            when Syn.Bare_Block =>
               Process_Block (Tree, Syn.Body_Of (Tree, Node));

            when Syn.Loop_Statement | Syn.While_Statement
               | Syn.For_Statement =>
               --  A conditional loop may execute zero times; an
               --  unconditional one can leave through `break`.  Origin
               --  facts only grow, so joining one body pass with entry is
               --  the conservative fixed point for this analysis.
               declare
                  Before : constant Origin_Table := Origins;
               begin
                  if Syn.Kind (Tree, Node) = Syn.While_Statement
                    and then Syn.Kind
                      (Tree, Syn.Condition_Of (Tree, Node)) = Syn.Binding
                  then
                     Process_Statement
                       (Tree, Syn.Condition_Of (Tree, Node));
                  end if;
                  if Syn.Kind (Tree, Node) = Syn.For_Statement then
                     declare
                        Source_Fact : Origin_Fact :=
                          Fact_Of (Tree, Syn.Traversal_Lower (Tree, Node));
                        Element : constant Res.Declaration_Id :=
                          Declaration_At
                            (Tree, Syn.Traversal_Element (Tree, Node));
                     begin
                        if Syn.Traversal_Upper (Tree, Node) /= Syn.No_Node then
                           Source_Fact := Fact_Of
                             (Tree, Syn.Traversal_Upper (Tree, Node));
                        elsif Element /= Res.No_Declaration
                          and then Element in Origins'Range
                        then
                           if Landin.Checking.Traversal_Evidence_Of
                             (Types.all, Tree, Node)
                                = Landin.Checking.No_Conformance
                           then
                              --  D160: the element is a place inside the
                              --  traversed storage, so a reference read out
                              --  of it derives from wherever that storage
                              --  came from.
                              Origins (Element) := Source_Fact;
                           else
                              --  D180: iterable.item returns an ordinary
                              --  value with [1320]'s source-free result
                              --  signature.  Its origin is therefore the
                              --  same empty fact an explicit call with that
                              --  signature produces, not the source alias
                              --  fact used by arrays and slices.
                              Origins (Element) := No_Origin;
                           end if;
                        end if;
                     end;
                  end if;
                  Process_Block (Tree, Syn.Loop_Body (Tree, Node));
                  if Syn.Complete_Body (Tree, Node) /= Syn.No_Node then
                     Process_Block (Tree, Syn.Complete_Body (Tree, Node));
                  end if;
                  for Id in Origins'Range loop
                     Join (Origins (Id), Before (Id));
                  end loop;
               end;

            when Syn.Return_Statement =>
               Check_Returns (Tree, Node);

            when Syn.Call | Syn.Labeled_Application | Syn.Try_Expression
               | Syn.Discard =>
               declare
                  Ignored : constant Origin_Fact := Fact_Of (Tree, Node);
               begin
                  pragma Unreferenced (Ignored);
               end;

            when others =>
               null;
         end case;
      end Process_Statement;

      procedure Process_Block (Tree : Syn.Tree; Block : Syn.Node_Id) is
      begin
         if Block = Syn.No_Node then
            return;
         end if;
         for Position in 1 .. Syn.Statement_Count (Tree, Block) loop
            declare
               Statement : constant Syn.Node_Id :=
                 Syn.Nth_Statement (Tree, Block, Position);
            begin
               Process_Statement (Tree, Statement);
               if Syn.Kind (Tree, Statement)
                    in Syn.Return_Statement | Syn.Fail_Statement
                 and then Syn.Condition_Of (Tree, Statement) = Syn.No_Node
               then
                  return;
               end if;
            end;
         end loop;
         if Syn.Block_Value (Tree, Block) /= Syn.No_Node then
            declare
               Ignored : constant Origin_Fact :=
                 Fact_Of (Tree, Syn.Block_Value (Tree, Block));
            begin
               pragma Unreferenced (Ignored);
            end;
         end if;
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
         Process_Block (Of_Tree, Body_Node);
         Check_Returns (Of_Tree, Function_Node);
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
