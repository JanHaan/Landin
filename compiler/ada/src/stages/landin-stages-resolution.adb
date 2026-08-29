with Landin.Diagnostics.Resolution;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Source;
with Landin.Syntax.Forest;
with Landin.Syntax;

package body Landin.Stages.Resolution is

   package Names renames Landin.Diagnostics.Resolution;
   package Syn renames Landin.Syntax;

   use type Landin.Provenance.Declaration_Id;
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

      Found : Landin.Diagnostics.Diagnostic_List;

      --  How a name is written, for the sentence a user reads.  The
      --  resolver compares identities; only a message needs the bytes.
      function Spelled (Of_Name : Landin.Source.Names.Name_Id) return String
        is (Landin.Source.Names.Spelling (Spellings.all, Of_Name));

      procedure Declare_One
        (Of_Tree         : Syn.Tree;
         Node            : Syn.Node_Id;
         Inside          : Landin.Resolution.Scope_Id;
         Resolve_Declared : Boolean := True);

      procedure Resolve
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Inside  : Landin.Resolution.Scope_Id);

      procedure Walk_Block
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Inside  : Landin.Resolution.Scope_Id);

      procedure Resolve_Anonymous
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

      --  [1850]: one scope gives one name to one thing.  The first
      --  declaration keeps the name, so every reference binds to one thing
      --  and one duplicate is one report rather than a second entry every
      --  later stage would have to choose between.
      procedure Declare_One
        (Of_Tree          : Syn.Tree;
         Node             : Syn.Node_Id;
         Inside           : Landin.Resolution.Scope_Id;
         Resolve_Declared : Boolean := True)
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
                   (Meanings.all, Written.all, Of_Tree, Node, Inside);
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

      --  [1010]'s anonymous function has a static routine body and captures
      --  nothing.  Its signature therefore encloses the module scope, not the
      --  lexical scope of the expression that produced its code address.
      procedure Resolve_Anonymous
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         Signature : constant Landin.Resolution.Scope_Id :=
           Landin.Resolution.Open_Scope
             (Meanings.all, Landin.Resolution.Signature,
              Landin.Resolution.Program_Scope);
         Runs : constant Syn.Node_Id := Syn.Body_Of (Of_Tree, Node);
      begin
         Landin.Resolution.Record_Scope
           (Meanings.all, Of_Tree, Node, Signature);

         for Which in 1 .. Syn.Parameter_Count (Of_Tree, Node) loop
            Declare_One
              (Of_Tree, Syn.Nth_Parameter (Of_Tree, Node, Which), Signature);
         end loop;
         if Syn.Return_Of (Of_Tree, Node) /= Syn.No_Node then
            Declare_One
              (Of_Tree, Syn.Return_Of (Of_Tree, Node), Signature);
         end if;

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
         end if;

         --  One of the eleven the kernel predeclares, which the parser
         --  already recognised: there is no declaration to find.
         if Syn.Kind (Of_Tree, Node) = Syn.Type_Name then
            return;
         end if;

         if Syn.Kind (Of_Tree, Node)
            in Syn.Name_Reference | Syn.Type_Reference
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
                  if Syn.Kind (Of_Tree, Node) = Syn.Type_Reference then
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

                  when Syn.If_Statement =>
                     --  Each arm and the else are their own scope [1840],
                     --  and siblings: a name declared in one arm is not
                     --  visible in another.
                     for Arm in 1 .. Syn.Arm_Count (Of_Tree, Item) loop
                        declare
                           This : constant Syn.Node_Id :=
                             Syn.Nth_Arm (Of_Tree, Item, Arm);
                        begin
                           Resolve
                             (Of_Tree,
                              Syn.Condition_Of (Of_Tree, This), Inside);

                           declare
                              Runs : constant Syn.Node_Id :=
                                Syn.Body_Of (Of_Tree, This);
                              Arm_Scope : constant
                                Landin.Resolution.Scope_Id :=
                                  Landin.Resolution.Open_Scope
                                    (Meanings.all,
                                     Landin.Resolution.Block, Inside);
                           begin
                              Landin.Resolution.Record_Scope
                                (Meanings.all, Of_Tree, Runs, Arm_Scope);
                              Walk_Block (Of_Tree, Runs, Arm_Scope);
                           end;
                        end;
                     end loop;

                     if Syn.Else_Body (Of_Tree, Item) /= Syn.No_Node then
                        declare
                           Runs : constant Syn.Node_Id :=
                             Syn.Else_Body (Of_Tree, Item);
                           Otherwise : constant
                             Landin.Resolution.Scope_Id :=
                               Landin.Resolution.Open_Scope
                                 (Meanings.all,
                                  Landin.Resolution.Block, Inside);
                        begin
                           Landin.Resolution.Record_Scope
                             (Meanings.all, Of_Tree, Runs, Otherwise);
                           Walk_Block (Of_Tree, Runs, Otherwise);
                        end;
                     end if;

                  when Syn.Match_Statement =>
                     --  D77: the subject is read in the surrounding scope.
                     --  Each arm is a sibling scope.  D78 declares its
                     --  payload aliases there before walking the body, so
                     --  neither aliases nor locals cross into another arm.
                     Resolve
                       (Of_Tree, Syn.Match_Subject (Of_Tree, Item), Inside);

                     for Arm in 1 .. Syn.Match_Arm_Count (Of_Tree, Item)
                     loop
                        declare
                           This : constant Syn.Node_Id :=
                             Syn.Nth_Match_Arm (Of_Tree, Item, Arm);
                           Runs : constant Syn.Node_Id :=
                             Syn.Body_Of (Of_Tree, This);
                           Arm_Scope : constant
                             Landin.Resolution.Scope_Id :=
                               Landin.Resolution.Open_Scope
                                 (Meanings.all,
                                  Landin.Resolution.Block, Inside);
                        begin
                           Resolve
                             (Of_Tree,
                              Syn.Match_Pattern (Of_Tree, This), Inside);
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

                  when others =>
                     Resolve (Of_Tree, Item, Inside);
               end case;
            end;
         end loop;
      end Walk_Block;

   begin
      Landin.Resolution.Prepare (Meanings.all, Trees.all);

      --  Pass one: every module declaration of every file, before any body
      --  is walked.  [1840]'s module is a set, so this is what lets a name
      --  be used above the line that introduces it -- and across a file
      --  boundary, because there is one module until [1410] arrives.
      for Index in 1 .. Source_Count (Context) loop
         declare
            Of_Tree : constant not null access constant Syn.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Trees.all, Nth_Source (Context, Index));
         begin
            for Position in
              1 .. Syn.Declaration_Count (Of_Tree.all)
            loop
               declare
                  Node : constant Syn.Node_Id :=
                    Syn.Nth_Declaration (Of_Tree.all, Position);
               begin
                  if Landin.Resolution.Declares
                       (Syn.Kind (Of_Tree.all, Node))
                  then
                     Declare_One
                       (Of_Tree.all, Node,
                        Landin.Resolution.Program_Scope,
                        Resolve_Declared => False);
                  end if;
               end;
            end loop;
         end;
      end loop;

      --  [0690]'s case names are module-visible atoms.  Declare them only
      --  after every ordinary module declaration, so a collision has one
      --  deterministic winner independent of file order and a later case
      --  may be used before the type that contains it is written.
      for Index in 1 .. Source_Count (Context) loop
         declare
            Of_Tree : constant not null access constant Syn.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Trees.all, Nth_Source (Context, Index));
         begin
            for Position in
              1 .. Syn.Declaration_Count (Of_Tree.all)
            loop
               declare
                  Node : constant Syn.Node_Id :=
                    Syn.Nth_Declaration (Of_Tree.all, Position);
               begin
                  if Syn.Kind (Of_Tree.all, Node) = Syn.Type_Declaration
                    and then Syn.Kind
                      (Of_Tree.all,
                       Syn.Declared_Type (Of_Tree.all, Node))
                        = Syn.Struct_Body
                  then
                     declare
                        Struct_Node : constant Syn.Node_Id :=
                          Syn.Declared_Type (Of_Tree.all, Node);
                     begin
                        for Member in 1 .. Syn.Field_Count
                          (Of_Tree.all, Struct_Node)
                        loop
                           declare
                              Part : constant Syn.Node_Id :=
                                Syn.Nth_Field
                                  (Of_Tree.all, Struct_Node, Member);
                           begin
                              if Syn.Kind (Of_Tree.all, Part)
                                   = Syn.Variant_Part
                              then
                                 for Which in 1 .. Syn.Case_Count
                                   (Of_Tree.all, Part)
                                 loop
                                    Declare_One
                                      (Of_Tree.all,
                                       Syn.Nth_Case
                                         (Of_Tree.all, Part, Which),
                                       Landin.Resolution.Program_Scope,
                                       Resolve_Declared => False);
                                 end loop;
                              end if;
                           end;
                        end loop;
                     end;
                  end if;
               end;
            end loop;
         end;
      end loop;

      --  Pass two: the bodies, in the same order, so the report is read
      --  top to bottom of the file it is about.
      for Index in 1 .. Source_Count (Context) loop
         declare
            Of_Tree : constant not null access constant Syn.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Trees.all, Nth_Source (Context, Index));
         begin
            for Position in
              1 .. Syn.Declaration_Count (Of_Tree.all)
            loop
               declare
                  Node : constant Syn.Node_Id :=
                    Syn.Nth_Declaration (Of_Tree.all, Position);
               begin
                  case Syn.Kind (Of_Tree.all, Node) is
                     when Syn.Type_Declaration =>
                        --  Every module name exists before any type position
                        --  is read, because [1840]'s module scope is a set.
                        Resolve
                          (Of_Tree.all,
                           Syn.Declared_Type (Of_Tree.all, Node),
                           Landin.Resolution.Program_Scope);

                     when Syn.Binding =>
                        --  Both halves are read only after every module name
                        --  exists.  The value and its written type therefore
                        --  obey the same set rule.
                        Resolve
                          (Of_Tree.all,
                           Syn.Declared_Type (Of_Tree.all, Node),
                           Landin.Resolution.Program_Scope);
                        Resolve
                          (Of_Tree.all,
                           Syn.Value_Of (Of_Tree.all, Node),
                           Landin.Resolution.Program_Scope);

                     when Syn.Function_Declaration =>
                        declare
                           Signature : constant
                             Landin.Resolution.Scope_Id :=
                               Landin.Resolution.Open_Scope
                                 (Meanings.all,
                                  Landin.Resolution.Signature,
                                  Landin.Resolution.Program_Scope);
                           Runs : constant Syn.Node_Id :=
                             Syn.Body_Of (Of_Tree.all, Node);
                        begin
                           Landin.Resolution.Record_Scope
                             (Meanings.all, Of_Tree.all, Node, Signature);

                           for Which in
                             1 .. Syn.Parameter_Count (Of_Tree.all, Node)
                           loop
                              Declare_One
                                (Of_Tree.all,
                                 Syn.Nth_Parameter
                                   (Of_Tree.all, Node, Which),
                                 Signature);
                           end loop;

                           --  The named return is declared here and not in
                           --  the body [1840]: the body assigns it like any
                           --  other place [0930], and a parameter and a
                           --  return may not share a name.
                           if Syn.Return_Of (Of_Tree.all, Node)
                              /= Syn.No_Node
                           then
                              Declare_One
                                (Of_Tree.all,
                                 Syn.Return_Of (Of_Tree.all, Node),
                                 Signature);
                           end if;

                           --  [1800]'s expression body opens no scope,
                           --  because an expression declares nothing.
                           if Syn.Kind (Of_Tree.all, Runs) = Syn.Block then
                              declare
                                 Body_Scope : constant
                                   Landin.Resolution.Scope_Id :=
                                     Landin.Resolution.Open_Scope
                                       (Meanings.all,
                                        Landin.Resolution.Block,
                                        Signature);
                              begin
                                 Landin.Resolution.Record_Scope
                                   (Meanings.all, Of_Tree.all, Runs,
                                    Body_Scope);
                                 Walk_Block
                                   (Of_Tree.all, Runs, Body_Scope);
                              end;
                           else
                              Resolve (Of_Tree.all, Runs, Signature);
                           end if;
                        end;

                     when others =>
                        null;
                  end case;
               end;
            end loop;
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
