with Landin.Configuration;
with Landin.Diagnostics.Resolution;
with Landin.Modules;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Source;
with Landin.Syntax.Forest;
with Landin.Types;
with Landin.Syntax;

package body Landin.Stages.Resolution is

   package Names renames Landin.Diagnostics.Resolution;
   package Res renames Landin.Resolution;
   package Syn renames Landin.Syntax;

   use type Landin.Provenance.Declaration_Id;
   use type Landin.Modules.Module_Id;
   use type Landin.Resolution.Application_Class;
   use type Landin.Resolution.Declaration_Sort;
   use type Landin.Resolution.Verdict;
   use type Landin.Resolution.Argument_Role;
   use type Landin.Resolution.Scope_Id;
   use type Landin.Resolution.Scope_Sort;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;

   overriding function Name (Item : Instance) return String is
      pragma Unreferenced (Item);
   begin
      return "resolution";
   end Name;

   overriding procedure Run
     (Item    : Instance;
      Context : in out Compilation;
      Outcome : out Stage_Outcome)
   is
      pragma Unreferenced (Item);

      Spellings : constant not null access Landin.Source.Names.Table :=
        Identities (Context);
      Written   : constant not null access Landin.Provenance.Table :=
        Sites (Context);
      Trees     : constant not null access Landin.Syntax.Forest.Table :=
        Landin.Stages.Trees (Context);
      Meanings  : constant not null access Landin.Resolution.Table :=
        Landin.Stages.Meanings (Context);
      Graph     : constant not null access Landin.Modules.Table :=
        Landin.Stages.Modules (Context);
      Activity : constant not null access Landin.Configuration.Table :=
        Configurations (Context);

      Found : Landin.Diagnostics.Diagnostic_List;

      --  How a name is written, for the sentence a user reads.  The
      --  resolver compares identities; only a message needs the bytes.
      function Spelled (Of_Name : Landin.Source.Names.Name_Id) return String
        is (Landin.Source.Names.Spelling (Spellings.all, Of_Name));

      function File_Base (Of_Tree : Syn.Tree)
        return Landin.Resolution.Scope_Id
        is (Landin.Resolution.File_Scope_Of
              (Meanings.all, Syn.Source_Of (Of_Tree)));

      function Module_Base (Of_Tree : Syn.Tree)
        return Landin.Resolution.Scope_Id
        is (Landin.Resolution.Module_Scope_Of
              (Meanings.all,
               Landin.Modules.Module_Of
                 (Graph.all, Syn.Source_Of (Of_Tree))));

      procedure Declare_One
        (Of_Tree         : Syn.Tree;
         Node            : Syn.Node_Id;
         Inside          : Landin.Resolution.Scope_Id;
         Resolve_Declared : Boolean := True;
         Inherits_Public  : Boolean := False);

      procedure Resolve
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Inside  : Landin.Resolution.Scope_Id);

      procedure Resolve_Type_View
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Inside  : Landin.Resolution.Scope_Id);

      procedure Resolve_Labeled_Application
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Inside  : Landin.Resolution.Scope_Id);

      procedure Walk_Block
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Inside  : Landin.Resolution.Scope_Id);

      procedure Resolve_Anonymous
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

      procedure Associate_Return_Sources
        (Of_Tree : Syn.Tree; Signature_Node : Syn.Node_Id);

      procedure Walk_Scoped_Block
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Parent  : Landin.Resolution.Scope_Id);

      --  [1850]: one scope gives one name to one thing.  The first
      --  declaration keeps the name, so every reference binds to one thing
      --  and one duplicate is one report rather than a second entry every
      --  later stage would have to choose between.
      procedure Declare_One
        (Of_Tree          : Syn.Tree;
         Node             : Syn.Node_Id;
         Inside           : Landin.Resolution.Scope_Id;
         Resolve_Declared : Boolean := True;
         Inherits_Public  : Boolean := False)
      is
         Named : constant Landin.Source.Names.Name_Id :=
           Syn.Name (Of_Tree, Node);
      begin
         --  A declaration whose name position the parser refused has no
         --  identity, and there is nothing to declare or to collide with.
         if Named = Landin.Source.Names.No_Name then
            return;
         end if;

         declare
            Earlier : constant Landin.Resolution.Declaration_Id :=
              Landin.Resolution.Declared_Here (Meanings.all, Inside, Named);
         begin
            if Earlier /= Landin.Resolution.No_Declaration then
               Names.Report
                 (Item    => Names.Duplicate_Declaration,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Anchor (Of_Tree, Node),
                  Message => "`" & Spelled (Named)
                             & "` is declared twice in one scope",
                  Note    => "[1850]: only an inner scope may shadow an"
                             & " outer name, and these are one scope",
                  Related => Landin.Provenance.Site
                               (Written.all, Earlier),
                  Because => "the declaration that keeps the name",
                  Into    => Found);
               return;
            end if;

            declare
               Made : constant Landin.Resolution.Declaration_Id :=
                 Landin.Resolution.Declare_Name
                   (Meanings.all, Written.all, Of_Tree, Node, Inside,
                    Inherits_Public);
            begin
               pragma Assert (Made /= Landin.Resolution.No_Declaration);
            end;

            --  [1795] made a type position a place a name can stand, so
            --  the type a declaration writes down is resolved like any
            --  other name.  Before it, every type was one of the eleven
            --  the parser knew and there was nothing here to look up.
            if Resolve_Declared
              and then Syn.Kind (Of_Tree, Node)
                       in Syn.Binding | Syn.Parameter | Syn.Named_Return
                          | Syn.Type_Declaration
            then
               Resolve (Of_Tree, Syn.Declared_Type (Of_Tree, Node),
                        Inside);
            end if;
         end;
      end Declare_One;

      --  [0790] names runtime parameter labels, not lexical names.  The same
      --  structural association therefore serves declarations, anonymous
      --  routines and function types; no declaration is invented for a label
      --  in a written type [1800].  Missing and duplicated labels remain
      --  retained for the later R2.50 checker to diagnose.
      procedure Associate_Return_Sources
        (Of_Tree : Syn.Tree; Signature_Node : Syn.Node_Id) is
      begin
         for Which in 1 .. Syn.Return_Count (Of_Tree, Signature_Node) loop
            declare
               Returned : constant Syn.Node_Id :=
                 Syn.Nth_Return (Of_Tree, Signature_Node, Which);
            begin
               for Source_Index in
                 1 .. Syn.Return_Source_Count (Of_Tree, Returned)
               loop
                  declare
                     Source : constant Syn.Node_Id :=
                       Syn.Nth_Return_Source
                         (Of_Tree, Returned, Source_Index);
                  begin
                     for Position in
                       1 .. Syn.Parameter_Count (Of_Tree, Signature_Node)
                     loop
                        if Syn.Name
                             (Of_Tree,
                              Syn.Nth_Parameter
                                (Of_Tree, Signature_Node, Position))
                           = Syn.Name (Of_Tree, Source)
                        then
                           Landin.Resolution.Associate_Return_Source
                             (Meanings.all, Of_Tree, Source, Position);
                           exit;
                        end if;
                     end loop;
                  end;
               end loop;
            end;
         end loop;
      end Associate_Return_Sources;

      --  [1010]'s anonymous function has a static routine body and captures
      --  nothing.  Its signature therefore encloses the module scope, not the
      --  lexical scope of the expression that produced its code address.
      procedure Resolve_Anonymous
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         Signature : constant Landin.Resolution.Scope_Id :=
           Landin.Resolution.Open_Scope
             (Meanings.all, Landin.Resolution.Signature,
              File_Base (Of_Tree));
         Runs : constant Syn.Node_Id := Syn.Body_Of (Of_Tree, Node);
      begin
         Landin.Resolution.Record_Scope
           (Meanings.all, Of_Tree, Node, Signature);

         for Which in 1 .. Syn.Parameter_Count (Of_Tree, Node) loop
            Declare_One
              (Of_Tree, Syn.Nth_Parameter (Of_Tree, Node, Which), Signature);
         end loop;
         for Which in 1 .. Syn.Return_Count (Of_Tree, Node) loop
            Declare_One
              (Of_Tree, Syn.Nth_Return (Of_Tree, Node, Which), Signature);
         end loop;
         Associate_Return_Sources (Of_Tree, Node);
         Resolve
           (Of_Tree, Syn.Error_Set_Of (Of_Tree, Node),
            File_Base (Of_Tree));

         if Syn.Kind (Of_Tree, Runs) = Syn.Block then
            declare
               Body_Scope : constant Landin.Resolution.Scope_Id :=
                 Landin.Resolution.Open_Scope
                   (Meanings.all, Landin.Resolution.Block, Signature);
            begin
               Landin.Resolution.Record_Scope
                 (Meanings.all, Of_Tree, Runs, Body_Scope);
               Walk_Block (Of_Tree, Runs, Body_Scope);
            end;
         else
            Resolve (Of_Tree, Runs, Signature);
         end if;
      end Resolve_Anonymous;

      --  Resolve an ambiguous compact projection as type syntax.  A bare
      --  Name_Reference is intentionally quiet when no declaration matches:
      --  it may be one of the predeclared scalar names, exactly as a parsed
      --  Type_Name would be.  A match is still bound once so declared type
      --  actuals and forwarded fixed formals retain their identity.
      procedure Resolve_Type_View
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Inside  : Landin.Resolution.Scope_Id) is
      begin
         if Node = Syn.No_Node then
            return;
         end if;

         if Syn.Kind (Of_Tree, Node) = Syn.Name_Reference then
            declare
               Named : constant Landin.Source.Names.Name_Id :=
                 Syn.Name (Of_Tree, Node);
               Meant : constant Landin.Resolution.Declaration_Id :=
                 (if Named = Landin.Source.Names.No_Name
                  then Landin.Resolution.No_Declaration
                  else Landin.Resolution.Visible
                    (Meanings.all, Inside, Named));
            begin
               if Meant /= Landin.Resolution.No_Declaration then
                  Landin.Resolution.Bind
                    (Meanings.all, Of_Tree, Node, Meant);
               end if;
            end;
            return;
         elsif Syn.Kind (Of_Tree, Node) = Syn.Call then
            Resolve_Type_View
              (Of_Tree, Syn.Callee_Of (Of_Tree, Node), Inside);
            for Which in 1 .. Syn.Argument_Count (Of_Tree, Node) loop
               Resolve_Type_View
                 (Of_Tree, Syn.Nth_Argument (Of_Tree, Node, Which), Inside);
            end loop;
            return;
         end if;

         Resolve (Of_Tree, Node, Inside);
      end Resolve_Type_View;

      --  [0980]/D72: bind and classify the direct callee first.  Only the
      --  projection selected by a matched formal or construction role is
      --  then resolved; the other projection remains immutable syntax, not a
      --  second set of name uses.  Position is role-local: runtime positions
      --  are ABI positions, while static formal positions are source order.
      procedure Resolve_Labeled_Application
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Inside  : Landin.Resolution.Scope_Id)
      is
         Callee : constant Syn.Node_Id := Syn.Callee_Of (Of_Tree, Node);
         Named  : constant Landin.Source.Names.Name_Id :=
           Syn.Name (Of_Tree, Callee);
         Meant  : Landin.Resolution.Declaration_Id :=
           (if Named = Landin.Source.Names.No_Name
            then Landin.Resolution.No_Declaration
            else Landin.Resolution.Visible (Meanings.all, Inside, Named));
         Class : Landin.Resolution.Application_Class :=
           Landin.Resolution.Unclassified_Application;
         Direct_Function : Boolean := False;
      begin
         if Syn.Kind (Of_Tree, Callee) = Syn.Name_Reference then
            if Meant = Landin.Resolution.No_Declaration then
               --  Keep the ambiguous direct spelling neutral.  Construction
               --  checking owns the existing source diagnostic for an
               --  undeclared or nonconstructible name.
               null;
            else
               Landin.Resolution.Bind (Meanings.all, Of_Tree, Callee, Meant);
               case Landin.Resolution.Sort_Of (Meanings.all, Meant) is
                  when Landin.Resolution.Module_Function =>
                     Class := Landin.Resolution.Function_Call;
                     Direct_Function := True;
                  when Landin.Resolution.Module_Type =>
                     Class := Landin.Resolution.Type_Construction;
                  when Landin.Resolution.Case_Name =>
                     Class := Landin.Resolution.Case_Construction;
                  when others =>
                     --  A binding may hold a function value.  Its structural
                     --  signature is a checking fact, so runtime matching is
                     --  deliberately completed there.
                     Class := Landin.Resolution.Function_Call;
               end case;
            end if;
         else
            --  Selected and otherwise indirect callees are ordinary
            --  expressions.  Resolve the complete callee before any written
            --  argument, preserving [0410]'s semantic walk order.
            Resolve (Of_Tree, Callee, Inside);
            if Landin.Resolution.Verdict_Of
                 (Meanings.all, Of_Tree, Callee) = Landin.Resolution.Bound
            then
               --  A qualified module member is syntactically a selection,
               --  but resolution has made its declaration just as direct as
               --  an unqualified name.  Its declaration sort therefore
               --  decides between call and construction too [1420].
               Meant := Landin.Resolution.Bound_To
                 (Meanings.all, Of_Tree, Callee);
               case Landin.Resolution.Sort_Of (Meanings.all, Meant) is
                  when Landin.Resolution.Module_Function =>
                     Class := Landin.Resolution.Function_Call;
                     Direct_Function := True;
                  when Landin.Resolution.Module_Type =>
                     Class := Landin.Resolution.Type_Construction;
                  when Landin.Resolution.Case_Name =>
                     Class := Landin.Resolution.Case_Construction;
                  when others =>
                     Class := Landin.Resolution.Function_Call;
               end case;
            else
               Class := Landin.Resolution.Function_Call;
            end if;
         end if;

         Landin.Resolution.Classify
           (Meanings.all, Of_Tree, Node, Class);

         if Class = Landin.Resolution.Function_Call and Direct_Function then
            declare
               Callee_Tree : constant not null access constant Syn.Tree :=
                 Trees.Tree_Of
                   (Landin.Resolution.Source_Of (Meanings.all, Meant));
               Declaration : constant Syn.Node_Id :=
                 Landin.Resolution.Node_Of (Meanings.all, Meant);
               Runtime_Position : Natural := 0;
               Signature : constant Landin.Resolution.Scope_Id :=
                 Landin.Resolution.Scope_At
                   (Meanings.all, Callee_Tree.all, Declaration);
            begin
               for Which in 1 .. Syn.Argument_Count (Of_Tree, Node) loop
                  declare
                     Argument : constant Syn.Node_Id :=
                       Syn.Nth_Argument (Of_Tree, Node, Which);
                     Label : constant Landin.Source.Names.Name_Id :=
                       Syn.Argument_Label (Of_Tree, Argument);
                     Role : Landin.Resolution.Argument_Role :=
                       Landin.Resolution.Unmatched_Argument;
                     Position : Natural := 0;
                     Formal_Node : Syn.Node_Id := Syn.No_Node;
                     Formal : Landin.Resolution.Declaration_Id :=
                       Landin.Resolution.No_Declaration;
                  begin
                     if Syn.Is_Fill_Argument (Of_Tree, Argument) then
                        Role := Landin.Resolution.Fill_Argument;
                     elsif Label = Landin.Source.Names.No_Name then
                        Runtime_Position := Runtime_Position + 1;
                        if Runtime_Position <=
                          Syn.Parameter_Count (Callee_Tree.all, Declaration)
                        then
                           Role := Landin.Resolution.Runtime_Argument;
                           Position := Runtime_Position;
                           Formal_Node := Syn.Nth_Parameter
                             (Callee_Tree.all, Declaration, Position);
                        end if;
                     else
                        for Static in 1 .. Syn.Generic_Formal_Count
                          (Callee_Tree.all, Declaration)
                        loop
                           declare
                              Candidate : constant Syn.Node_Id :=
                                Syn.Nth_Generic_Formal
                                  (Callee_Tree.all, Declaration, Static);
                           begin
                              if Syn.Name (Callee_Tree.all, Candidate) = Label
                              then
                                 Position := Static;
                                 Formal_Node := Candidate;
                                 Role :=
                                   (if Syn.Kind (Callee_Tree.all, Candidate)
                                         = Syn.Type_Formal
                                    then Landin.Resolution.Type_Argument
                                    else Landin.Resolution.Fixed_Argument);
                                 exit;
                              end if;
                           end;
                        end loop;

                        if Role = Landin.Resolution.Unmatched_Argument then
                           for Runtime in 1 .. Syn.Parameter_Count
                             (Callee_Tree.all, Declaration)
                           loop
                              declare
                                 Candidate : constant Syn.Node_Id :=
                                   Syn.Nth_Parameter
                                     (Callee_Tree.all, Declaration, Runtime);
                              begin
                                 if Syn.Name (Callee_Tree.all, Candidate)
                                      = Label
                                 then
                                    Role :=
                                      Landin.Resolution.Runtime_Argument;
                                    Position := Runtime;
                                    Formal_Node := Candidate;
                                    exit;
                                 end if;
                              end;
                           end loop;
                        end if;
                     end if;

                     if Formal_Node /= Syn.No_Node
                       and then Signature /= Landin.Resolution.No_Scope
                     then
                        Formal := Landin.Resolution.Declared_Here
                          (Meanings.all, Signature,
                           Syn.Name (Callee_Tree.all, Formal_Node));
                     end if;

                     if Role /= Landin.Resolution.Unmatched_Argument then
                        Landin.Resolution.Match_Argument
                          (Meanings.all, Of_Tree, Argument, Role, Position,
                           Formal);
                        if Role = Landin.Resolution.Type_Argument then
                           Resolve_Type_View
                             (Of_Tree,
                              Syn.Type_Projection (Of_Tree, Argument), Inside);
                        else
                           Resolve
                             (Of_Tree,
                              Syn.Expression_Projection
                                (Of_Tree, Argument), Inside);
                        end if;
                     else
                        --  Unknown runtime labels are still expressions.  A
                        --  type-only RHS stays unvisited and the shared call
                        --  matcher owns the one source diagnostic.
                        Resolve
                          (Of_Tree,
                           Syn.Expression_Projection (Of_Tree, Argument),
                           Inside);
                     end if;
                  end;
               end loop;
            end;
         elsif Class = Landin.Resolution.Function_Call then
            --  Only checking has the structural signature of a stored or
            --  selected function value.  Resolve every runtime projection
            --  now in written order and let that shared matcher assign ABI
            --  formal positions later.
            for Which in 1 .. Syn.Argument_Count (Of_Tree, Node) loop
               Resolve
                 (Of_Tree,
                  Syn.Expression_Projection
                    (Of_Tree, Syn.Nth_Argument (Of_Tree, Node, Which)),
                  Inside);
            end loop;
         elsif Class in Landin.Resolution.Type_Construction
                          | Landin.Resolution.Case_Construction
         then
            for Which in 1 .. Syn.Argument_Count (Of_Tree, Node) loop
               declare
                  Argument : constant Syn.Node_Id :=
                    Syn.Nth_Argument (Of_Tree, Node, Which);
                  Role : constant Landin.Resolution.Argument_Role :=
                    (if Syn.Is_Fill_Argument (Of_Tree, Argument)
                     then Landin.Resolution.Fill_Argument
                     elsif Class = Landin.Resolution.Case_Construction
                     then Landin.Resolution.Payload_Argument
                     else Landin.Resolution.Field_Argument);
               begin
                  Landin.Resolution.Match_Argument
                    (Meanings.all, Of_Tree, Argument, Role, Which);
                  Resolve
                    (Of_Tree,
                     Syn.Expression_Projection (Of_Tree, Argument), Inside);
               end;
            end loop;
         end if;

         --  The neutral application carries the same recovery slot as Call.
         --  Its bound error and body must therefore open and walk the same
         --  scope after the callee and written arguments have been resolved.
         if Syn.Recovery_Of (Of_Tree, Node) /= Syn.No_Node then
            declare
               Recovery : constant Syn.Node_Id :=
                 Syn.Recovery_Of (Of_Tree, Node);
               Runs : constant Syn.Node_Id :=
                 Syn.Else_Body (Of_Tree, Recovery);
               Recovery_Scope : constant Landin.Resolution.Scope_Id :=
                 Landin.Resolution.Open_Scope
                   (Meanings.all, Landin.Resolution.Block, Inside);
            begin
               Landin.Resolution.Record_Scope
                 (Meanings.all, Of_Tree, Recovery, Recovery_Scope);
               Declare_One (Of_Tree, Recovery, Recovery_Scope);
               if Syn.Kind (Of_Tree, Runs) = Syn.Block then
                  Landin.Resolution.Record_Scope
                    (Meanings.all, Of_Tree, Runs, Recovery_Scope);
                  Walk_Block (Of_Tree, Runs, Recovery_Scope);
               else
                  Resolve (Of_Tree, Runs, Recovery_Scope);
               end if;
            end;
         end if;
      end Resolve_Labeled_Application;

      --  Every use of a name is a Name_Reference node, so resolution is a
      --  walk looking for one kind rather than for identifiers in seven
      --  positions.  A Type_Name is not a use: [1790] gives the kernel
      --  eleven spellings and the parser already holds that node to them.
      procedure Resolve
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Inside  : Landin.Resolution.Scope_Id) is
      begin
         if Node = Syn.No_Node then
            return;
         end if;

         if Syn.Kind (Of_Tree, Node) = Syn.Anonymous_Function then
            Resolve_Anonymous (Of_Tree, Node);
            return;
         elsif Syn.Kind (Of_Tree, Node)
           in Syn.Function_Type | Syn.Concept_Entry
         then
            Associate_Return_Sources (Of_Tree, Node);
         end if;

         --  D124: control forms can now occur anywhere an expression can.
         --  Their conditions and subjects use the surrounding scope, while
         --  every answer block owns the same sibling scope it did when the
         --  form could only be a statement.  Keep that rule here, in the
         --  general expression walk, rather than at one statement caller.
         case Syn.Kind (Of_Tree, Node) is
            when Syn.Labeled_Application =>
               Resolve_Labeled_Application (Of_Tree, Node, Inside);
               return;

            when Syn.Call =>
               declare
                  Callee : constant Syn.Node_Id :=
                    Syn.Callee_Of (Of_Tree, Node);
                  Is_Scalar_Conversion : Boolean := False;
               begin
                  if Syn.Kind (Of_Tree, Callee) = Syn.Name_Reference then
                     for Scalar in Landin.Types.Scalar_Name loop
                        Is_Scalar_Conversion := Is_Scalar_Conversion
                          or else Landin.Types.Spelling (Scalar)
                            = Spelled (Syn.Name (Of_Tree, Callee));
                     end loop;
                  end if;
                  if Is_Scalar_Conversion then
                     Resolve_Type_View (Of_Tree, Callee, Inside);
                  else
                     Resolve (Of_Tree, Callee, Inside);
                  end if;
               end;
               for Argument in 1 .. Syn.Argument_Count (Of_Tree, Node) loop
                  Resolve
                    (Of_Tree,
                     Syn.Nth_Argument (Of_Tree, Node, Argument), Inside);
               end loop;

               if Syn.Recovery_Of (Of_Tree, Node) /= Syn.No_Node then
                  declare
                     Recovery : constant Syn.Node_Id :=
                       Syn.Recovery_Of (Of_Tree, Node);
                     Runs : constant Syn.Node_Id :=
                       Syn.Else_Body (Of_Tree, Recovery);
                     Recovery_Scope : constant Landin.Resolution.Scope_Id :=
                       Landin.Resolution.Open_Scope
                         (Meanings.all, Landin.Resolution.Block, Inside);
                  begin
                     Landin.Resolution.Record_Scope
                       (Meanings.all, Of_Tree, Recovery, Recovery_Scope);
                     Declare_One (Of_Tree, Recovery, Recovery_Scope);
                     if Syn.Kind (Of_Tree, Runs) = Syn.Block then
                        Landin.Resolution.Record_Scope
                          (Meanings.all, Of_Tree, Runs, Recovery_Scope);
                        Walk_Block (Of_Tree, Runs, Recovery_Scope);
                     else
                        Resolve (Of_Tree, Runs, Recovery_Scope);
                     end if;
                  end;
               end if;
               return;

            when Syn.If_Statement =>
               for Arm in 1 .. Syn.Arm_Count (Of_Tree, Node) loop
                  declare
                     This : constant Syn.Node_Id :=
                       Syn.Nth_Arm (Of_Tree, Node, Arm);
                  begin
                     Resolve
                       (Of_Tree, Syn.Condition_Of (Of_Tree, This), Inside);
                     Walk_Scoped_Block
                       (Of_Tree, Syn.Body_Of (Of_Tree, This), Inside);
                  end;
               end loop;

               if Syn.Else_Body (Of_Tree, Node) /= Syn.No_Node then
                  Walk_Scoped_Block
                    (Of_Tree, Syn.Else_Body (Of_Tree, Node), Inside);
               end if;
               return;

            when Syn.Match_Statement =>
               Resolve
                 (Of_Tree, Syn.Match_Subject (Of_Tree, Node), Inside);

               for Arm in 1 .. Syn.Match_Arm_Count (Of_Tree, Node) loop
                  declare
                     This : constant Syn.Node_Id :=
                       Syn.Nth_Match_Arm (Of_Tree, Node, Arm);
                     Runs : constant Syn.Node_Id :=
                       Syn.Body_Of (Of_Tree, This);
                     Arm_Scope : constant Landin.Resolution.Scope_Id :=
                       Landin.Resolution.Open_Scope
                         (Meanings.all, Landin.Resolution.Block, Inside);
                  begin
                     Resolve
                       (Of_Tree, Syn.Match_Pattern (Of_Tree, This), Inside);
                     Landin.Resolution.Record_Scope
                       (Meanings.all, Of_Tree, Runs, Arm_Scope);

                     for Binding in
                       1 .. Syn.Match_Binding_Count (Of_Tree, This)
                     loop
                        Declare_One
                          (Of_Tree,
                           Syn.Nth_Match_Binding
                             (Of_Tree, This, Binding),
                           Arm_Scope);
                     end loop;

                     Walk_Block (Of_Tree, Runs, Arm_Scope);
                  end;
               end loop;
               return;

            when Syn.Bare_Block =>
               Walk_Scoped_Block
                 (Of_Tree, Syn.Body_Of (Of_Tree, Node), Inside);
               return;

            when others =>
               null;
         end case;

         --  A leading name bound by this file's import prelude is a module
         --  namespace only in a qualified selection.  Locals and signature
         --  names shadow it; the import in turn shadows a declaration in the
         --  file's enclosing module scope [0140] [1450].
         if Syn.Kind (Of_Tree, Node) = Syn.Member_Selection
           and then Syn.Kind
             (Of_Tree, Syn.Target_Of (Of_Tree, Node))
               in Syn.Name_Reference | Syn.Type_Reference
                    | Syn.Concept_Reference
         then
            declare
               Prefix : constant Syn.Node_Id := Syn.Target_Of (Of_Tree, Node);
               Prefix_Name : constant Landin.Source.Names.Name_Id :=
                 Syn.Name (Of_Tree, Prefix);
               Member_Name : constant Landin.Source.Names.Name_Id :=
                 Syn.Name (Of_Tree, Node);
               Lexical : constant Res.Declaration_Id :=
                 Res.Visible (Meanings.all, Inside, Prefix_Name);
               Local_Shadow : constant Boolean :=
                 Lexical /= Res.No_Declaration
                 and then Res.Sort_Of
                   (Meanings.all, Res.Scope_Of (Meanings.all, Lexical))
                     /= Res.Module_Scope;
               Imported : constant Landin.Modules.Module_Id :=
                 Res.Imported_Module_Of
                   (Meanings.all, Syn.Source_Of (Of_Tree), Prefix_Name);
            begin
               if not Local_Shadow
                 and then Imported /= Landin.Modules.No_Module
               then
                  declare
                     Public_Member : constant Res.Declaration_Id :=
                       Res.Visible_Public_In_Module
                         (Meanings.all, Imported, Member_Name);
                     Any_Member : constant Res.Declaration_Id :=
                       Res.Declared_Here
                         (Meanings.all,
                          Res.Module_Scope_Of (Meanings.all, Imported),
                          Member_Name);
                  begin
                     if Public_Member /= Res.No_Declaration then
                        Res.Bind
                          (Meanings.all, Of_Tree, Node, Public_Member);
                     elsif Any_Member /= Res.No_Declaration then
                        Names.Report
                          (Item    => Names.Inaccessible_Name,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Anchor (Of_Tree, Node),
                           Message => "`" & Spelled (Member_Name)
                                      & "` is module-internal",
                           Note    => "[1410]: only a public declaration is"
                                      & " visible across a module boundary",
                           Related => Landin.Provenance.Site
                             (Written.all, Any_Member),
                           Because => "declared without `public` here",
                           Into    => Found);
                     elsif Member_Name /= Landin.Source.Names.No_Name then
                        Names.Report
                          (Item    => Names.Unresolved_Name,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Anchor (Of_Tree, Node),
                           Message => "module `" & Spelled (Prefix_Name)
                                      & "` has no member `"
                                      & Spelled (Member_Name) & "`",
                           Note    => "[1420]: a plain import exposes only"
                                      & " qualified public members",
                           Into    => Found);
                     end if;
                  end;
                  return;
               end if;
            end;
         end if;

         --  One of the eleven the kernel predeclares, which the parser
         --  already recognised: there is no declaration to find.
         if Syn.Kind (Of_Tree, Node) = Syn.Type_Name then
            return;
         end if;

         if Syn.Kind (Of_Tree, Node)
            in Syn.Name_Reference | Syn.Type_Reference | Syn.Concept_Reference
         then
            declare
               Named : constant Landin.Source.Names.Name_Id :=
                 Syn.Name (Of_Tree, Node);
               Meant : constant Landin.Resolution.Declaration_Id :=
                 (if Named = Landin.Source.Names.No_Name
                  then Landin.Resolution.No_Declaration
                  else Landin.Resolution.Visible
                         (Meanings.all, Inside, Named));
            begin
               if Meant = Landin.Resolution.No_Declaration then
                  --  A type name that resolved to nothing is left to the
                  --  checker, which is the stage that can tell a type the
                  --  tour writes and [1790] omits from a name nobody
                  --  declared.  Reporting here would put the weaker of
                  --  the two answers first.
                  if Syn.Kind (Of_Tree, Node) = Syn.Type_Reference
                    or else
                      (Syn.Kind (Of_Tree, Node) = Syn.Concept_Reference
                       and then Spelled (Named) = "zeroable")
                  then
                     --  Scalar type names and R2.60's closed compiler
                     --  concept have no source declaration to bind.
                     null;
                  elsif Named /= Landin.Source.Names.No_Name then
                     Names.Report
                       (Item    => Names.Unresolved_Name,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Anchor (Of_Tree, Node),
                        Message => "`" & Spelled (Named)
                                   & "` is not declared in any scope this"
                                   & " reaches",
                        Note    => "[1860]: a name that is not in scope is"
                                   & " a misspelling, not a new binding",
                        Into    => Found);
                  end if;
               else
                  Landin.Resolution.Bind
                    (Meanings.all, Of_Tree, Node, Meant);
               end if;
            end;

            return;
         end if;

         for Position in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
            Resolve (Of_Tree, Syn.Slot (Of_Tree, Node, Position), Inside);
         end loop;
      end Resolve;

      --  [1840]: a statement run is ordered, so a local is visible to the
      --  statements after it and not before, and its own value is read
      --  before its name exists [0110].
      procedure Walk_Block
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Inside  : Landin.Resolution.Scope_Id) is
      begin
         for Index in 1 .. Syn.Statement_Count (Of_Tree, Block) loop
            declare
               Item : constant Syn.Node_Id :=
                 Syn.Nth_Statement (Of_Tree, Block, Index);
            begin
               case Syn.Kind (Of_Tree, Item) is
                  when Syn.Binding =>
                     Resolve (Of_Tree, Syn.Value_Of (Of_Tree, Item),
                              Inside);
                     Declare_One (Of_Tree, Item, Inside);

                  when Syn.Destructuring_Binding =>
                     --  [0990] evaluates the source before introducing any
                     --  selected local, exactly as an inferred binding does.
                     Resolve
                       (Of_Tree, Syn.Destructured_Value (Of_Tree, Item),
                        Inside);
                     for Position in
                       1 .. Syn.Destructured_Field_Count (Of_Tree, Item)
                     loop
                        declare
                           Field : constant Syn.Node_Id :=
                             Syn.Nth_Destructured_Field
                               (Of_Tree, Item, Position);
                        begin
                           if Syn.Kind (Of_Tree, Field)
                                = Syn.Destructured_Field
                             and then Syn.Destructured_Local
                               (Of_Tree, Field) /= Syn.No_Node
                           then
                              Declare_One
                                (Of_Tree,
                                 Syn.Destructured_Local (Of_Tree, Field),
                                 Inside,
                                 Resolve_Declared => False);
                           end if;
                        end;
                     end loop;

                  when others =>
                     Resolve (Of_Tree, Item, Inside);
               end case;
            end;
         end loop;

         --  A value is evaluated after every preceding statement, so all
         --  declarations in the block are visible to it and none escape
         --  with it into a sibling arm.
         Resolve (Of_Tree, Syn.Block_Value (Of_Tree, Block), Inside);
      end Walk_Block;

      procedure Walk_Scoped_Block
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Parent  : Landin.Resolution.Scope_Id)
      is
         Scope : constant Landin.Resolution.Scope_Id :=
           Landin.Resolution.Open_Scope
             (Meanings.all, Landin.Resolution.Block, Parent);
      begin
         Landin.Resolution.Record_Scope
           (Meanings.all, Of_Tree, Block, Scope);
         Walk_Block (Of_Tree, Block, Scope);
      end Walk_Scoped_Block;

      --  The active declaration traversal supplies ordinary and selected
      --  declarations alike.  The action therefore keeps all declaration
      --  body rules in one place.
      procedure Resolve_Declaration
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

      procedure Resolve_Declaration
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) is
      begin
         case Syn.Kind (Of_Tree, Node) is
            when Syn.Concept_Declaration =>
               declare
                  Formal_Scope : constant Landin.Resolution.Scope_Id :=
                    Landin.Resolution.Open_Scope
                      (Meanings.all, Landin.Resolution.Concept_Declaration,
                       File_Base (Of_Tree));
               begin
                  Landin.Resolution.Record_Scope
                    (Meanings.all, Of_Tree, Node, Formal_Scope);

                  for Which in 1 .. Syn.Concept_Formal_Count
                    (Of_Tree, Node)
                  loop
                     Declare_One
                       (Of_Tree,
                        Syn.Nth_Concept_Formal (Of_Tree, Node, Which),
                        Formal_Scope, Resolve_Declared => False);
                  end loop;

                  for Which in 1 .. Syn.Concept_Formal_Count
                    (Of_Tree, Node)
                  loop
                     declare
                        Formal : constant Syn.Node_Id :=
                          Syn.Nth_Concept_Formal (Of_Tree, Node, Which);
                     begin
                        if Syn.Kind (Of_Tree, Formal) = Syn.Fixed_Formal then
                           Resolve
                             (Of_Tree, Syn.Declared_Type (Of_Tree, Formal),
                              Formal_Scope);
                        else
                           Resolve
                             (Of_Tree, Syn.Constraint_Of (Of_Tree, Formal),
                              Formal_Scope);
                        end if;
                     end;
                  end loop;

                  for Which in 1 .. Syn.Concept_Parent_Count
                    (Of_Tree, Node)
                  loop
                     Resolve
                       (Of_Tree,
                        Syn.Nth_Concept_Parent (Of_Tree, Node, Which),
                        Formal_Scope);
                  end loop;
                  for Which in 1 .. Syn.Concept_Entry_Count
                    (Of_Tree, Node)
                  loop
                     Resolve
                       (Of_Tree,
                        Syn.Nth_Concept_Entry (Of_Tree, Node, Which),
                        Formal_Scope);
                  end loop;
               end;

            when Syn.Conformance_Declaration =>
               declare
                  Formal_Scope : constant Landin.Resolution.Scope_Id :=
                    Landin.Resolution.Open_Scope
                      (Meanings.all, Landin.Resolution.Conformance_Declaration,
                       File_Base (Of_Tree));
                  Concept_Node : constant Syn.Node_Id :=
                    Syn.Conforming_Concept (Of_Tree, Node);
               begin
                  Landin.Resolution.Record_Scope
                    (Meanings.all, Of_Tree, Node, Formal_Scope);

                  for Which in 1 .. Syn.Conformance_Binder_Count
                    (Of_Tree, Node)
                  loop
                     Declare_One
                       (Of_Tree,
                        Syn.Nth_Conformance_Binder (Of_Tree, Node, Which),
                        Formal_Scope, Resolve_Declared => False);
                  end loop;
                  for Which in 1 .. Syn.Conformance_Binder_Count
                    (Of_Tree, Node)
                  loop
                     declare
                        Formal : constant Syn.Node_Id :=
                          Syn.Nth_Conformance_Binder
                            (Of_Tree, Node, Which);
                     begin
                        if Syn.Kind (Of_Tree, Formal) = Syn.Fixed_Formal then
                           Resolve
                             (Of_Tree, Syn.Declared_Type (Of_Tree, Formal),
                              Formal_Scope);
                        else
                           Resolve
                             (Of_Tree, Syn.Constraint_Of (Of_Tree, Formal),
                              Formal_Scope);
                        end if;
                     end;
                  end loop;

                  Resolve
                    (Of_Tree, Syn.Conforming_Type (Of_Tree, Node),
                     Formal_Scope);
                  Resolve (Of_Tree, Concept_Node, Formal_Scope);

                  --  The concept decides whether a labelled RHS is a type
                  --  input or a supplying function.  Resolve only that view,
                  --  as labelled applications do, so a scalar type input is
                  --  not misreported as an unresolved runtime value.
                  declare
                     Concept_Decl : constant
                       Landin.Resolution.Declaration_Id :=
                       (if Res.Verdict_Of
                          (Meanings.all, Of_Tree, Concept_Node) = Res.Bound
                        then Res.Bound_To
                          (Meanings.all, Of_Tree, Concept_Node)
                        else Res.No_Declaration);
                  begin
                     for Which in 1 .. Syn.Conformance_Entry_Count
                       (Of_Tree, Node)
                     loop
                        declare
                           Item : constant Syn.Node_Id :=
                             Syn.Nth_Conformance_Entry
                               (Of_Tree, Node, Which);
                           RHS : constant Syn.Node_Id :=
                             Syn.Conformance_RHS (Of_Tree, Item);
                           Is_Type_Input : Boolean := False;
                        begin
                           if Concept_Decl /= Res.No_Declaration
                             and then Res.Sort_Of
                               (Meanings.all, Concept_Decl)
                                 = Res.Module_Concept
                           then
                              declare
                                 Concept_Tree : constant
                                   not null access constant Syn.Tree :=
                                     Trees.Tree_Of
                                       (Res.Source_Of
                                          (Meanings.all, Concept_Decl));
                                 Concept : constant Syn.Node_Id :=
                                   Res.Node_Of (Meanings.all, Concept_Decl);
                              begin
                                 for Input in 2 .. Syn.Concept_Formal_Count
                                   (Concept_Tree.all, Concept)
                                 loop
                                    if Syn.Name (Of_Tree, Item)
                                      = Syn.Name
                                        (Concept_Tree.all,
                                         Syn.Nth_Concept_Formal
                                           (Concept_Tree.all, Concept, Input))
                                    then
                                       Is_Type_Input := True;
                                       exit;
                                    end if;
                                 end loop;
                              end;
                           end if;

                           if Is_Type_Input then
                              Resolve_Type_View (Of_Tree, RHS, Formal_Scope);
                           else
                              Resolve (Of_Tree, RHS, Formal_Scope);
                           end if;
                        end;
                     end loop;
                  end;
               end;

            when Syn.Type_Declaration =>
               --  D135: formals belong to this declaration, not to
               --  the module.  Collect every one before resolving
               --  any declared fixed-formal type or the alias RHS,
               --  so their order has no visibility meaning.
               if Syn.Type_Formal_Count (Of_Tree, Node) = 0 then
                  Resolve
                    (Of_Tree,
                     Syn.Declared_Type (Of_Tree, Node),
                     File_Base (Of_Tree));
               else
                  declare
                     Formal_Scope : constant
                       Landin.Resolution.Scope_Id :=
                         Landin.Resolution.Open_Scope
                           (Meanings.all,
                            Landin.Resolution.Type_Declaration,
                            File_Base (Of_Tree));
                  begin
                     Landin.Resolution.Record_Scope
                       (Meanings.all, Of_Tree, Node,
                        Formal_Scope);

                     for Which in 1 .. Syn.Type_Formal_Count
                       (Of_Tree, Node)
                     loop
                        Declare_One
                          (Of_Tree,
                           Syn.Nth_Type_Formal
                             (Of_Tree, Node, Which),
                           Formal_Scope,
                           Resolve_Declared => False);
                     end loop;

                     for Which in 1 .. Syn.Type_Formal_Count
                       (Of_Tree, Node)
                     loop
                        declare
                           Formal : constant Syn.Node_Id :=
                             Syn.Nth_Type_Formal
                               (Of_Tree, Node, Which);
                        begin
                           if Syn.Kind (Of_Tree, Formal)
                                = Syn.Fixed_Formal
                           then
                              Resolve
                                (Of_Tree,
                                 Syn.Declared_Type
                                   (Of_Tree, Formal),
                                 Formal_Scope);
                           else
                              Resolve
                                (Of_Tree, Syn.Constraint_Of (Of_Tree, Formal),
                                 Formal_Scope);
                           end if;
                        end;
                     end loop;

                     Resolve
                       (Of_Tree,
                        Syn.Declared_Type (Of_Tree, Node),
                        Formal_Scope);
                  end;
               end if;

            when Syn.Binding =>
               --  Both halves are read only after every module name
               --  exists.  The value and its written type therefore
               --  obey the same set rule.
               Resolve
                 (Of_Tree,
                  Syn.Declared_Type (Of_Tree, Node),
                  File_Base (Of_Tree));
               Resolve
                 (Of_Tree,
                  Syn.Value_Of (Of_Tree, Node),
                  File_Base (Of_Tree));

            when Syn.Function_Declaration =>
               declare
                  Signature : constant
                    Landin.Resolution.Scope_Id :=
                      Landin.Resolution.Open_Scope
                        (Meanings.all,
                         Landin.Resolution.Signature,
                         File_Base (Of_Tree));
                  Runs : constant Syn.Node_Id :=
                    Syn.Body_Of (Of_Tree, Node);
               begin
                  Landin.Resolution.Record_Scope
                    (Meanings.all, Of_Tree, Node, Signature);

                  --  D138: static formals share the routine signature
                  --  scope and are collected before any written type.
                  for Which in
                    1 .. Syn.Generic_Formal_Count (Of_Tree, Node)
                  loop
                     Declare_One
                       (Of_Tree,
                        Syn.Nth_Generic_Formal (Of_Tree, Node, Which),
                        Signature, Resolve_Declared => False);
                  end loop;

                  for Which in
                    1 .. Syn.Parameter_Count (Of_Tree, Node)
                  loop
                     Declare_One
                       (Of_Tree,
                        Syn.Nth_Parameter
                          (Of_Tree, Node, Which),
                        Signature);
                  end loop;

                  --  Named returns are declared here and not in
                  --  the body [1840]: the body assigns each like
                  --  any other place [0930], and no parameter or
                  --  sibling return may share its name.
                  for Which in
                    1 .. Syn.Return_Count (Of_Tree, Node)
                  loop
                     Declare_One
                       (Of_Tree,
                        Syn.Nth_Return
                          (Of_Tree, Node, Which),
                        Signature);
                  end loop;
                  Associate_Return_Sources (Of_Tree, Node);

                  for Which in
                    1 .. Syn.Generic_Formal_Count (Of_Tree, Node)
                  loop
                     declare
                        Formal : constant Syn.Node_Id :=
                          Syn.Nth_Generic_Formal (Of_Tree, Node, Which);
                     begin
                        if Syn.Kind (Of_Tree, Formal) = Syn.Fixed_Formal then
                           Resolve
                             (Of_Tree, Syn.Declared_Type (Of_Tree, Formal),
                              Signature);
                        else
                           Resolve
                             (Of_Tree, Syn.Constraint_Of (Of_Tree, Formal),
                              Signature);
                        end if;
                     end;
                  end loop;

                  Resolve
                    (Of_Tree,
                     Syn.Error_Set_Of (Of_Tree, Node),
                     File_Base (Of_Tree));

                  --  [1800]'s expression body opens no scope,
                  --  because an expression declares nothing.
                  if Syn.Kind (Of_Tree, Runs) = Syn.Block then
                     declare
                        Body_Scope : constant
                          Landin.Resolution.Scope_Id :=
                            Landin.Resolution.Open_Scope
                              (Meanings.all,
                               Landin.Resolution.Block,
                               Signature);
                     begin
                        Landin.Resolution.Record_Scope
                          (Meanings.all, Of_Tree, Runs,
                           Body_Scope);
                        Walk_Block
                          (Of_Tree, Runs, Body_Scope);
                     end;
                  else
                     Resolve (Of_Tree, Runs, Signature);
                  end if;
               end;

            when others =>
               null;
         end case;
      end Resolve_Declaration;

   begin
      Landin.Resolution.Prepare (Meanings.all, Trees.all, Graph.all);

      --  Each source owns its import bindings.  The final path segment is
      --  the bound namespace name, and two such names in one prelude are the
      --  same-scope duplicate [1420] [1450] [1850].
      for Index in 1 .. Source_Count (Context) loop
         declare
            Source_Id : constant Landin.Source.Source_Id :=
              Nth_Source (Context, Index);
            Of_Tree : constant not null access constant Syn.Tree :=
              Landin.Syntax.Forest.Tree_Of (Trees.all, Source_Id);
         begin
            for Import_Index in 1 .. Syn.Import_Count (Of_Tree.all) loop
               declare
                  Import_Node : constant Syn.Node_Id :=
                    Syn.Nth_Import (Of_Tree.all, Import_Index);
                  Last : constant Syn.Node_Id :=
                    Syn.Nth_Import_Segment
                      (Of_Tree.all, Import_Node,
                       Syn.Import_Segment_Count (Of_Tree.all, Import_Node));
                  Named : constant Landin.Source.Names.Name_Id :=
                    Syn.Name (Of_Tree.all, Last);
                  Target : constant Landin.Modules.Module_Id :=
                    Landin.Modules.Imported_Module
                      (Graph.all, Source_Id, Import_Node);
                  Earlier : constant Landin.Modules.Module_Id :=
                    Res.Imported_Module_Of
                      (Meanings.all, Source_Id, Named);
               begin
                  if Target = Landin.Modules.No_Module
                    or else Named = Landin.Source.Names.No_Name
                  then
                     null;
                  elsif Earlier /= Landin.Modules.No_Module then
                     Names.Report
                       (Item    => Names.Duplicate_Declaration,
                        Source  => Source_Id,
                        Where   => Syn.Anchor (Of_Tree.all, Last),
                        Message => "`" & Spelled (Named)
                                   & "` is imported twice in one file",
                        Note    => "[1450] [1850]: a file import scope gives"
                                   & " one name to one module",
                        Related => Res.Import_Origin
                          (Meanings.all, Source_Id, Named),
                        Because => "the import that keeps the name",
                        Into    => Found);
                  else
                     Res.Bind_Imported_Module
                       (Meanings.all, Source_Id, Named, Target,
                        Syn.Origin (Of_Tree.all, Last));
                  end if;
               end;
            end loop;
         end;
      end loop;

      --  Pass one: every module declaration of every file, before any body
      --  is walked.  [1840]'s module is a set, so this is what lets a name
      --  be used above the line that introduces it -- and across a file
      --  boundary, because there is one module until [1410] arrives.
      declare
         procedure Collect (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

         procedure Collect (Of_Tree : Syn.Tree; Node : Syn.Node_Id) is
         begin
            if Landin.Resolution.Declares (Syn.Kind (Of_Tree, Node)) then
               Declare_One
                 (Of_Tree, Node, Module_Base (Of_Tree),
                  Resolve_Declared => False);
               if Syn.Kind (Of_Tree, Node) = Syn.Atom_Declaration then
                  for Member in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
                     Declare_One
                       (Of_Tree, Syn.Slot (Of_Tree, Node, Member),
                        Module_Base (Of_Tree),
                        Resolve_Declared => False);
                  end loop;
               end if;
            end if;
         end Collect;
      begin
         for Index in 1 .. Source_Count (Context) loop
            declare
               Of_Tree : constant not null access constant Syn.Tree :=
                 Landin.Syntax.Forest.Tree_Of
                   (Trees.all, Nth_Source (Context, Index));
            begin
               declare
                  procedure Walk is new
                    Landin.Configuration.For_Each_Active_Declaration
                      (Collect);
               begin
                  Walk (Activity.all, Of_Tree.all);
               end;
            end;
         end loop;
      end;

      --  [0690]'s case names are module-visible atoms.  Declare them only
      --  after every ordinary module declaration, so a collision has one
      --  deterministic winner independent of file order and a later case
      --  may be used before the type that contains it is written.
      declare
         procedure Collect_Cases (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

         procedure Collect_Cases
           (Of_Tree : Syn.Tree; Node : Syn.Node_Id) is
         begin
            if Syn.Kind (Of_Tree, Node) = Syn.Type_Declaration
              and then Syn.Kind (Of_Tree, Syn.Declared_Type (Of_Tree, Node))
                = Syn.Struct_Body
            then
               declare
                  Struct_Node : constant Syn.Node_Id :=
                    Syn.Declared_Type (Of_Tree, Node);
               begin
                  for Member in 1 .. Syn.Field_Count (Of_Tree, Struct_Node)
                  loop
                     declare
                        Part : constant Syn.Node_Id :=
                          Syn.Nth_Field (Of_Tree, Struct_Node, Member);
                     begin
                        if Syn.Kind (Of_Tree, Part) = Syn.Variant_Part then
                           for Which in 1 .. Syn.Case_Count (Of_Tree, Part)
                           loop
                              Declare_One
                                (Of_Tree, Syn.Nth_Case (Of_Tree, Part, Which),
                                 Module_Base (Of_Tree),
                                 Resolve_Declared => False,
                                 Inherits_Public =>
                                   Syn.Is_Public (Of_Tree, Node));
                           end loop;
                        end if;
                     end;
                  end loop;
               end;
            end if;
         end Collect_Cases;
      begin
         for Index in 1 .. Source_Count (Context) loop
            declare
               Of_Tree : constant not null access constant Syn.Tree :=
                 Landin.Syntax.Forest.Tree_Of
                   (Trees.all, Nth_Source (Context, Index));
            begin
               declare
                  procedure Walk is new
                    Landin.Configuration.For_Each_Active_Declaration
                      (Collect_Cases);
               begin
                  Walk (Activity.all, Of_Tree.all);
               end;
            end;
         end loop;
      end;

      --  Pass two: bodies in source order through D139's single active
      --  declaration traversal.
      for Index in 1 .. Source_Count (Context) loop
         declare
            Of_Tree : constant not null access constant Syn.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Trees.all, Nth_Source (Context, Index));
            procedure Walk is new
              Landin.Configuration.For_Each_Active_Declaration
                (Resolve_Declaration);
         begin
            Walk (Activity.all, Of_Tree.all);
         end;
      end loop;

      declare
         Ordered : constant Landin.Diagnostics.Diagnostic_List :=
           Landin.Diagnostics.Sorted (Found);
      begin
         for Position in 1 .. Landin.Diagnostics.Count (Ordered) loop
            Report (Context, Landin.Diagnostics.Get (Ordered, Position));
         end loop;
      end;

      Outcome := (if Failed (Context) then Stop else Continue);
   end Run;

end Landin.Stages.Resolution;
