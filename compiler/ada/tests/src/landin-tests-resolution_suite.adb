--  What the resolver answers about scopes, asked directly.
--
--  The fixtures already hold [1840]'s sibling rule to what a program is
--  allowed to name, which is the rule seen from the outside.  This asks the
--  table the question R1.70's lowering asks it -- which scope did this node
--  open -- because a wrong answer there is invisible from outside: an arm's
--  blocks landing in the function's body scope names every local correctly
--  and still puts the instructions in the wrong scope, and only R4.60 would
--  ever notice.

with Landin.Resolution;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Configuration;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Targets;

package body Landin.Tests.Resolution_Suite is

   use type Landin.Resolution.Scope_Id;
   use type Landin.Resolution.Scope_Sort;
   use type Landin.Resolution.Declaration_Sort;
   use type Landin.Resolution.Verdict;
   use type Landin.Resolution.Declaration_Id;
   use type Landin.Source.Source_Id;
   use type Landin.Syntax.Node_Id;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
   Configurer : aliased Landin.Stages.Configuration.Instance;
   Checker  : aliased Landin.Stages.Checking.Instance;

   LF : constant Character := Character'Val (10);

   Program : constant String :=
     "f: (a: u32) -> (r: u32) =" & LF
     & "    if a > 1 then" & LF
     & "        t: u32 = 1" & LF
     & "        r = t" & LF
     & "    else" & LF
     & "        t: u32 = 2" & LF
     & "        r = t" & LF
     & "    end if" & LF
     & "end f" & LF;

   procedure Every_Scope_Names_The_Node_That_Opened_It
     (Item : in out Landin.Testing.Context);

   procedure Every_Scope_Names_The_Node_That_Opened_It
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Id    : Landin.Source.Source_Id;
   begin
      Id := Landin.Stages.Add_Source (Work, "scopes.ldn", Program);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the frontend ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "the program is accepted");

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Of_Tree  : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Id);

         Fn : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 1);
         Runs : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Body_Of (Of_Tree.all, Fn);
         Branch : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Statement (Of_Tree.all, Runs, 1);
         Arm : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Body_Of
             (Of_Tree.all, Landin.Syntax.Nth_Arm (Of_Tree.all, Branch, 1));
         Otherwise : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Else_Body (Of_Tree.all, Branch);

         Signature : constant Landin.Resolution.Scope_Id :=
           Landin.Resolution.Scope_At (Meanings.all, Of_Tree.all, Fn);
         Inside : constant Landin.Resolution.Scope_Id :=
           Landin.Resolution.Scope_At (Meanings.all, Of_Tree.all, Runs);
         First : constant Landin.Resolution.Scope_Id :=
           Landin.Resolution.Scope_At (Meanings.all, Of_Tree.all, Arm);
         Second : constant Landin.Resolution.Scope_Id :=
           Landin.Resolution.Scope_At
             (Meanings.all, Of_Tree.all, Otherwise);
      begin
         --  [1840]: a function opens a signature inside the module.
         Landin.Testing.Check
           (Item,
            Landin.Resolution.Sort_Of (Meanings.all, Signature)
            = Landin.Resolution.Signature,
            "the function declaration opened its signature");
         Landin.Testing.Check
           (Item,
            Landin.Resolution.Enclosing (Meanings.all, Signature)
            = Landin.Resolution.Program_Scope,
            "the signature sits in the module scope");

         --  The body is a block inside the signature, so a parameter is
         --  visible in it and a local is not visible outside it.
         Landin.Testing.Check
           (Item,
            Landin.Resolution.Sort_Of (Meanings.all, Inside)
            = Landin.Resolution.Block,
            "the body opened a block scope");
         Landin.Testing.Check
           (Item,
            Landin.Resolution.Enclosing (Meanings.all, Inside) = Signature,
            "the body sits in the signature");

         --  The rule this case exists for: the arms are siblings of each
         --  other inside the body, and not the body itself.
         Landin.Testing.Check
           (Item, First /= Inside and then Second /= Inside,
            "an arm is not the body it is written in");
         Landin.Testing.Check
           (Item, First /= Second,
            "the two arms are different scopes");
         Landin.Testing.Check
           (Item,
            Landin.Resolution.Enclosing (Meanings.all, First) = Inside
            and then Landin.Resolution.Enclosing (Meanings.all, Second)
                     = Inside,
            "both arms sit directly in the body, as siblings");
      end;
   end Every_Scope_Names_The_Node_That_Opened_It;

   --  Nearly every node opens nothing, and the lowering relies on being
   --  told so rather than on guessing from the kind.
   procedure A_Node_That_Opens_Nothing_Says_So
     (Item : in out Landin.Testing.Context);

   procedure A_Node_That_Opens_Nothing_Says_So
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Id    : Landin.Source.Source_Id;
      Opens : Natural := 0;
   begin
      Id := Landin.Stages.Add_Source (Work, "scopes.ldn", Program);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      pragma Assert (Ran = 4);

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Of_Tree  : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Id);
      begin
         for Node in
           Landin.Syntax.Node_Id (1)
             .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Resolution.Scope_At (Meanings.all, Of_Tree.all, Node)
               /= Landin.Resolution.No_Scope
            then
               Opens := Opens + 1;
            end if;
         end loop;

         --  Four: the signature, the body, the arm and the else.  Every
         --  other node of this program opens nothing.
         Landin.Testing.Check_Equal
           (Item, Opens, 4,
            "exactly the four nodes that open a scope say they do");
      end;
   end A_Node_That_Opens_Nothing_Says_So;

   procedure Variant_Cases_Are_Module_Visible_Identities
     (Item : in out Landin.Testing.Context);

   procedure Variant_Cases_Are_Module_Visible_Identities
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Id    : Landin.Source.Source_Id;
   begin
      Id := Landin.Stages.Add_Source
        (Work, "cases.ldn",
         "picked := leaf" & LF
         & "choice: type = struct" & LF
         & "    kind: variant" & LF
         & "        leaf |" & LF
         & "        number: (value: u8)" & LF
         & "    end kind" & LF
         & "end choice" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the resolver ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a case may be named before its containing declaration");

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Id);
         Use_Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Value_Of
             (Of_Tree.all, Landin.Syntax.Nth_Declaration (Of_Tree.all, 1));
         Body_Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type
             (Of_Tree.all, Landin.Syntax.Nth_Declaration (Of_Tree.all, 2));
         Part : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Field (Of_Tree.all, Body_Node, 1);
         Case_Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Case (Of_Tree.all, Part, 1);
         Means : Landin.Resolution.Declaration_Id :=
           Landin.Resolution.No_Declaration;
      begin
         for Decl in Landin.Resolution.Declaration_Id'(1)
                       .. Landin.Resolution.Declaration_Id
                            (Landin.Resolution.Declaration_Count
                               (Meanings.all))
         loop
            if Landin.Resolution.Source_Of (Meanings.all, Decl) = Id
              and then Landin.Resolution.Node_Of (Meanings.all, Decl)
                         = Case_Node
            then
               Means := Decl;
            end if;
         end loop;

         Landin.Testing.Check
           (Item,
            Means /= Landin.Resolution.No_Declaration
              and then Landin.Resolution.Sort_Of (Meanings.all, Means)
                         = Landin.Resolution.Case_Name,
            "the case owns a Case_Name declaration identity");
         Landin.Testing.Check
           (Item,
            Landin.Resolution.Verdict_Of
              (Meanings.all, Of_Tree.all, Use_Node) = Landin.Resolution.Bound
              and then Landin.Resolution.Bound_To
                (Meanings.all, Of_Tree.all, Use_Node) = Means,
            "a forward use binds to that exact case identity");
      end;
   end Variant_Cases_Are_Module_Visible_Identities;

   --  D135 collects the complete list before resolving any fixed formal
   --  type or the alias body, so the first formal may be used by the second
   --  and both are visible in `[count]element` regardless of their order.
   procedure Type_Formals_Have_One_Collected_Scope
     (Item : in out Landin.Testing.Context);

   procedure Type_Formals_Have_One_Collected_Scope
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Id    : Landin.Source.Source_Id;
   begin
      Id := Landin.Stages.Add_Source
        (Work, "formals.ldn",
         "bytes: type (element: type, fixed count: element) = [count]element"
         & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the resolver ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a type alias resolves its collected formals");

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Id);
         Alias : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 1);
         Element : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Type_Formal (Of_Tree.all, Alias, 1);
         Count : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Type_Formal (Of_Tree.all, Alias, 2);
         Count_Type : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type (Of_Tree.all, Count);
         Alias_Body : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type (Of_Tree.all, Alias);
         Bound : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Bound_Of (Of_Tree.all, Alias_Body);
         Element_Use : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Element_Of (Of_Tree.all, Alias_Body);
         Formal_Scope : constant Landin.Resolution.Scope_Id :=
           Landin.Resolution.Scope_At (Meanings.all, Of_Tree.all, Alias);
         Element_Declaration : Landin.Resolution.Declaration_Id :=
           Landin.Resolution.No_Declaration;
         Count_Declaration : Landin.Resolution.Declaration_Id :=
           Landin.Resolution.No_Declaration;
      begin
         for Decl in Landin.Resolution.Declaration_Id'(1)
                       .. Landin.Resolution.Declaration_Id
                            (Landin.Resolution.Declaration_Count
                               (Meanings.all))
         loop
            if Landin.Resolution.Source_Of (Meanings.all, Decl) = Id then
               if Landin.Resolution.Node_Of
                    (Meanings.all, Decl) = Element
               then
                  Element_Declaration := Decl;
               elsif Landin.Resolution.Node_Of
                    (Meanings.all, Decl) = Count
               then
                  Count_Declaration := Decl;
               end if;
            end if;
         end loop;

         Landin.Testing.Check
           (Item,
            Landin.Resolution.Sort_Of (Meanings.all, Formal_Scope)
              = Landin.Resolution.Type_Declaration
              and then Landin.Resolution.Scope_Of
                (Meanings.all, Element_Declaration) = Formal_Scope
              and then Landin.Resolution.Scope_Of
                (Meanings.all, Count_Declaration) = Formal_Scope,
            "the alias owns one scope containing both formals");
         Landin.Testing.Check
           (Item,
            Landin.Resolution.Sort_Of (Meanings.all, Element_Declaration)
              = Landin.Resolution.Type_Parameter
              and then Landin.Resolution.Sort_Of
                (Meanings.all, Count_Declaration)
                  = Landin.Resolution.Fixed_Parameter,
            "the formal declarations retain their kinds");
         Landin.Testing.Check
           (Item,
            Landin.Resolution.Verdict_Of
              (Meanings.all, Of_Tree.all, Count_Type)
                = Landin.Resolution.Bound
              and then Landin.Resolution.Bound_To
                (Meanings.all, Of_Tree.all, Count_Type)
                  = Element_Declaration
              and then Landin.Resolution.Verdict_Of
                (Meanings.all, Of_Tree.all, Bound)
                  = Landin.Resolution.Bound
              and then Landin.Resolution.Bound_To
                (Meanings.all, Of_Tree.all, Bound) = Count_Declaration
              and then Landin.Resolution.Verdict_Of
                (Meanings.all, Of_Tree.all, Element_Use)
                  = Landin.Resolution.Bound
              and then Landin.Resolution.Bound_To
                (Meanings.all, Of_Tree.all, Element_Use)
                  = Element_Declaration,
            "later resolution sees every collected formal");
      end;
   end Type_Formals_Have_One_Collected_Scope;

   procedure Parameterized_Struct_Formals_Have_One_Collected_Scope
     (Item : in out Landin.Testing.Context);

   --  The struct branch uses D135's same type-declaration scope as an
   --  alias.  This runs only syntax and resolution: nominal instance
   --  checking and lowering are deliberately outside this increment.
   procedure Parameterized_Struct_Formals_Have_One_Collected_Scope
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Id    : Landin.Source.Source_Id;
   begin
      Id := Landin.Stages.Add_Source
        (Work, "struct-formals.ldn",
         "buffer: type (fixed count: element, element: type) = struct" & LF
         & "    slots: [count]element" & LF
         & "end buffer" & LF
         & "sample: buffer(2, u8)" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 4, "the resolver ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a parameterized struct resolves its collected formals");

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Id);
         Struct : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 1);
         Count : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Type_Formal (Of_Tree.all, Struct, 1);
         Element : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Type_Formal (Of_Tree.all, Struct, 2);
         Count_Type : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type (Of_Tree.all, Count);
         Struct_Body : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type (Of_Tree.all, Struct);
         Slots : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Field (Of_Tree.all, Struct_Body, 1);
         Slots_Type : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type (Of_Tree.all, Slots);
         Bound : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Bound_Of (Of_Tree.all, Slots_Type);
         Element_Use : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Element_Of (Of_Tree.all, Slots_Type);
         Application : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type
             (Of_Tree.all,
              Landin.Syntax.Nth_Declaration (Of_Tree.all, 2));
         Target : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Applied_Type (Of_Tree.all, Application);
         Formal_Scope : constant Landin.Resolution.Scope_Id :=
           Landin.Resolution.Scope_At (Meanings.all, Of_Tree.all, Struct);
         Count_Declaration : Landin.Resolution.Declaration_Id :=
           Landin.Resolution.No_Declaration;
         Element_Declaration : Landin.Resolution.Declaration_Id :=
           Landin.Resolution.No_Declaration;
      begin
         for Decl in Landin.Resolution.Declaration_Id'(1)
                       .. Landin.Resolution.Declaration_Id
                            (Landin.Resolution.Declaration_Count
                               (Meanings.all))
         loop
            if Landin.Resolution.Source_Of (Meanings.all, Decl) = Id then
               if Landin.Resolution.Node_Of (Meanings.all, Decl) = Count then
                  Count_Declaration := Decl;
               elsif Landin.Resolution.Node_Of (Meanings.all, Decl)
                     = Element
               then
                  Element_Declaration := Decl;
               end if;
            end if;
         end loop;

         Landin.Testing.Check
           (Item,
            Landin.Resolution.Sort_Of (Meanings.all, Formal_Scope)
              = Landin.Resolution.Type_Declaration
              and then Landin.Resolution.Scope_Of
                (Meanings.all, Count_Declaration) = Formal_Scope
              and then Landin.Resolution.Scope_Of
                (Meanings.all, Element_Declaration) = Formal_Scope
              and then Landin.Resolution.Sort_Of
                (Meanings.all, Count_Declaration)
                  = Landin.Resolution.Fixed_Parameter
              and then Landin.Resolution.Sort_Of
                (Meanings.all, Element_Declaration)
                  = Landin.Resolution.Type_Parameter,
            "the struct owns one scope containing its collected formals");
         Landin.Testing.Check
           (Item,
            Landin.Resolution.Verdict_Of
              (Meanings.all, Of_Tree.all, Count_Type)
                = Landin.Resolution.Bound
              and then Landin.Resolution.Bound_To
                (Meanings.all, Of_Tree.all, Count_Type)
                  = Element_Declaration
              and then Landin.Resolution.Verdict_Of
                (Meanings.all, Of_Tree.all, Bound)
                  = Landin.Resolution.Bound
              and then Landin.Resolution.Bound_To
                (Meanings.all, Of_Tree.all, Bound) = Count_Declaration
              and then Landin.Resolution.Verdict_Of
                (Meanings.all, Of_Tree.all, Element_Use)
                  = Landin.Resolution.Bound
              and then Landin.Resolution.Bound_To
                (Meanings.all, Of_Tree.all, Element_Use)
                  = Element_Declaration,
            "struct fields resolve every collected formal regardless of"
            & " order");
         Landin.Testing.Check
           (Item,
            Landin.Resolution.Verdict_Of
              (Meanings.all, Of_Tree.all, Target) = Landin.Resolution.Bound
              and then Landin.Resolution.Sort_Of
                (Meanings.all,
                 Landin.Resolution.Bound_To
                   (Meanings.all, Of_Tree.all, Target))
                  = Landin.Resolution.Module_Type,
            "a struct application resolves its template declaration");
      end;
   end Parameterized_Struct_Formals_Have_One_Collected_Scope;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "resolution", "every scope names the node that opened it",
         Every_Scope_Names_The_Node_That_Opened_It'Access);
      Landin.Testing.Register
        (Into, "resolution", "a node that opens nothing says so",
         A_Node_That_Opens_Nothing_Says_So'Access);
      Landin.Testing.Register
        (Into, "resolution", "variant cases are module visible identities",
         Variant_Cases_Are_Module_Visible_Identities'Access);
      Landin.Testing.Register
        (Into, "resolution", "type formals have one collected scope",
         Type_Formals_Have_One_Collected_Scope'Access);
      Landin.Testing.Register
        (Into, "resolution",
         "parameterized struct formals have one collected scope",
         Parameterized_Struct_Formals_Have_One_Collected_Scope'Access);
   end Register;

end Landin.Tests.Resolution_Suite;
