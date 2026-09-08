--  What the resolver answers about scopes, asked directly.
--
--  The fixtures already hold [1840]'s sibling rule to what a program is
--  allowed to name, which is the rule seen from the outside.  This asks the
--  table the question R1.70's lowering asks it -- which scope did this node
--  open -- because a wrong answer there is invisible from outside: an arm's
--  blocks landing in the function's body scope names every local correctly
--  and still puts the instructions in the wrong scope, and only R4.60 would
--  ever notice.

with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Driver;
with Landin.Platform;
with Landin.Testing.Fakes;
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

   use type Landin.Resolution.Application_Class;
   use type Landin.Resolution.Argument_Role;
   use type Landin.Resolution.Scope_Id;
   use type Landin.Resolution.Scope_Sort;
   use type Landin.Resolution.Declaration_Sort;
   use type Landin.Resolution.Verdict;
   use type Landin.Resolution.Declaration_Id;
   use type Landin.Source.Source_Id;
   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;

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
         --  [1840]: a function opens a signature inside its file import
         --  scope, which in turn sits inside the containing module.
         Landin.Testing.Check
           (Item,
            Landin.Resolution.Sort_Of (Meanings.all, Signature)
            = Landin.Resolution.Signature,
            "the function declaration opened its signature");
         Landin.Testing.Check
           (Item,
            Landin.Resolution.Sort_Of
              (Meanings.all,
               Landin.Resolution.Enclosing (Meanings.all, Signature))
              = Landin.Resolution.File_Imports,
            "the signature sits in the file import scope");
         Landin.Testing.Check
           (Item,
            Landin.Resolution.Sort_Of
              (Meanings.all,
               Landin.Resolution.Enclosing
                 (Meanings.all,
                  Landin.Resolution.Enclosing (Meanings.all, Signature)))
              = Landin.Resolution.Module_Scope,
            "the file import scope sits in the module scope");

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

      Landin.Testing.Check_Equal (Item, Ran, 3, "the resolver ran");
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

      Landin.Testing.Check_Equal (Item, Ran, 3, "the resolver ran");
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

      Landin.Testing.Check_Equal (Item, Ran, 3, "the resolver ran");
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

   procedure Return_Sources_Retain_Parameter_Positions
     (Item : in out Landin.Testing.Context);

   procedure Labeled_Applications_Are_Classified_Callee_First
     (Item : in out Landin.Testing.Context);

   --  [0790]'s labels are structural signature positions.  A function type
   --  opens no declaration scope, while declared and anonymous routines do;
   --  the one position representation must work for all three without making
   --  a function-type label into a lexical declaration.
   procedure Return_Sources_Retain_Parameter_Positions
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Id    : Landin.Source.Source_Id;
   begin
      Id := Landin.Stages.Add_Source
        (Work, "return-sources.ldn",
         "item: type = u8" & LF
         & "callback: type = (first: ptr item, second: []item) ->"
         & " (view: []item from second, first)" & LF
         & "project: (t: type, first: ptr t, second: []t) ->"
         & " (view: []t from second, first) = second end project" & LF
         & "stored := (only: ptr item) ->"
         & " (view: ptr item from only) = only end" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the resolver ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "reference signatures need no checking to resolve their labels");

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Id);
         Callback : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type
             (Of_Tree.all,
              Landin.Syntax.Nth_Declaration (Of_Tree.all, 2));
         Callback_Return : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Return (Of_Tree.all, Callback, 1);
         Project : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 3);
         Project_Return : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Return (Of_Tree.all, Project, 1);
         Stored : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Value_Of
             (Of_Tree.all,
              Landin.Syntax.Nth_Declaration (Of_Tree.all, 4));
         Stored_Return : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Return (Of_Tree.all, Stored, 1);
      begin
         Landin.Testing.Check
           (Item,
            Landin.Resolution.Source_Parameter_Position
              (Meanings.all, Of_Tree.all,
               Landin.Syntax.Nth_Return_Source
                 (Of_Tree.all, Callback_Return, 1)) = 2
            and then Landin.Resolution.Source_Parameter_Position
              (Meanings.all, Of_Tree.all,
               Landin.Syntax.Nth_Return_Source
                 (Of_Tree.all, Callback_Return, 2)) = 1,
            "a function type maps source labels without declarations");
         Landin.Testing.Check
           (Item,
            Landin.Resolution.Source_Parameter_Position
              (Meanings.all, Of_Tree.all,
               Landin.Syntax.Nth_Return_Source
                 (Of_Tree.all, Project_Return, 1)) = 2
            and then Landin.Resolution.Source_Parameter_Position
              (Meanings.all, Of_Tree.all,
               Landin.Syntax.Nth_Return_Source
                 (Of_Tree.all, Project_Return, 2)) = 1,
            "generic statics do not consume runtime parameter positions");
         Landin.Testing.Check_Equal
           (Item,
            Landin.Resolution.Source_Parameter_Position
              (Meanings.all, Of_Tree.all,
               Landin.Syntax.Nth_Return_Source
                 (Of_Tree.all, Stored_Return, 1)),
            1, "an anonymous signature uses the same position table");
      end;
   end Return_Sources_Retain_Parameter_Positions;

   procedure Labeled_Applications_Are_Classified_Callee_First
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Id    : Landin.Source.Source_Id;
      Calls : Natural := 0;
      Types : Natural := 0;
      Cases : Natural := 0;
   begin
      Id := Landin.Stages.Add_Source
        (Work, "label-resolution.ldn",
         "apply: (t: type, fixed count: usize, first: t, value: t)"
         & " -> none =" & LF
         & "end apply" & LF
         & "box: type = struct" & LF
         & "    value: i32" & LF
         & "    kind: variant" & LF
         & "        leaf: (value: i32)" & LF
         & "    end kind" & LF
         & "end box" & LF
         & "run: (source: i32) -> none =" & LF
         & "    apply(1, t: i32, count: 4, value: source)" & LF
         & "    _ = box(value: source)" & LF
         & "    _ = leaf(value: source)" & LF
         & "end run" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Configurer'Access);
      Landin.Stages.Append (Order, Names'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the resolver ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "neutral applications resolve without checking either spare view");

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Id);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                     .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Labeled_Application
            then
               case Landin.Resolution.Class_Of
                 (Meanings.all, Of_Tree.all, Node)
               is
                  when Landin.Resolution.Function_Call =>
                     Calls := Calls + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Resolution.Role_Of
                          (Meanings.all, Of_Tree.all,
                           Landin.Syntax.Nth_Argument
                             (Of_Tree.all, Node, 1)) =
                               Landin.Resolution.Runtime_Argument
                        and then Landin.Resolution.Position_Of
                          (Meanings.all, Of_Tree.all,
                           Landin.Syntax.Nth_Argument
                             (Of_Tree.all, Node, 1)) = 1,
                        "a leading positional maps to runtime position one");
                     Landin.Testing.Check
                       (Item,
                        Landin.Resolution.Role_Of
                          (Meanings.all, Of_Tree.all,
                           Landin.Syntax.Nth_Argument
                             (Of_Tree.all, Node, 2)) =
                               Landin.Resolution.Type_Argument
                        and then Landin.Resolution.Formal_Of
                          (Meanings.all, Of_Tree.all,
                           Landin.Syntax.Nth_Argument
                             (Of_Tree.all, Node, 2)) /=
                               Landin.Resolution.No_Declaration,
                        "a type label maps to its collected signature formal");
                     Landin.Testing.Check
                       (Item,
                        Landin.Resolution.Role_Of
                          (Meanings.all, Of_Tree.all,
                           Landin.Syntax.Nth_Argument
                             (Of_Tree.all, Node, 3)) =
                               Landin.Resolution.Fixed_Argument
                        and then Landin.Resolution.Position_Of
                          (Meanings.all, Of_Tree.all,
                           Landin.Syntax.Nth_Argument
                             (Of_Tree.all, Node, 4)) = 2,
                        "fixed and runtime labels retain distinct roles");
                  when Landin.Resolution.Type_Construction =>
                     Types := Types + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Resolution.Role_Of
                          (Meanings.all, Of_Tree.all,
                           Landin.Syntax.Nth_Argument
                             (Of_Tree.all, Node, 1)) =
                               Landin.Resolution.Field_Argument,
                        "a type callee selects the field expression view");
                  when Landin.Resolution.Case_Construction =>
                     Cases := Cases + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Resolution.Role_Of
                          (Meanings.all, Of_Tree.all,
                           Landin.Syntax.Nth_Argument
                             (Of_Tree.all, Node, 1)) =
                               Landin.Resolution.Payload_Argument,
                        "a case callee selects the payload expression view");
                  when Landin.Resolution.Unclassified_Application =>
                     null;
               end case;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal (Item, Calls, 1, "one function call");
      Landin.Testing.Check_Equal (Item, Types, 1, "one type construction");
      Landin.Testing.Check_Equal (Item, Cases, 1, "one case construction");
   end Labeled_Applications_Are_Classified_Callee_First;

   --  D201 end-to-end cases use the fake host; source membership, roots,
   --  checking, lowering and emission follow the actual driver path.
   procedure Import_Bindings_Preserve_Identity
     (Item : in out Landin.Testing.Context);

   procedure Import_Bindings_Preserve_Identity
     (Item : in out Landin.Testing.Context)
   is
      Host : Landin.Testing.Fakes.Fake_Filesystem;
      Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
      Args : Landin.Platform.Path_List;
   begin
      Host.Add_Directory ("entry");
      Host.Add_Directory ("root");
      Host.Add_Directory ("root/lib");
      Host.Add_Directory ("later");
      Host.Add_Directory ("later/lib");
      Host.Add_File ("later/lib/wrong.ldn", "invalid later root");
      Host.Add_File
        ("root/lib/library.ldn",
         "public number: type = i32" & LF
         & "public cell: type (item: type) = struct" & LF
         & "    value: item" & LF
         & "end cell" & LF
         & "public marked: type = concept (item: type)" & LF
         & "end marked" & LF
         & "i32 is marked ()" & LF
         & "public absent, denied: atom" & LF
         & "public problems: type = absent | denied" & LF
         & "public choice: type = struct" & LF
         & "    kind: variant" & LF
         & "        empty |" & LF
         & "        full: (value: i32)" & LF
         & "    end kind" & LF
         & "end choice" & LF
         & "public mut counter: i32 = 1" & LF
         & "public answer: i32 = 40" & LF
         & "public identity: (item: type is marked, value: item)"
         & " -> (result: item) =" & LF
         & "    result = value" & LF
         & "end identity" & LF
         & "public work: (value: number) -> (result: number) ! problems =" & LF
         & "    fail absent when value < 0" & LF
         & "    result = value" & LF
         & "end work" & LF
         & "hidden: type = struct" & LF
         & "    secret: i32" & LF
         & "end hidden" & LF
         & "public opaque: type = hidden" & LF
         & "public reveal: () -> (value: opaque) =" & LF
         & "    value = (secret: 7)" & LF
         & "end reveal" & LF
         & "private_value: i32 = 7" & LF);
      Host.Add_File
        ("entry/main.ldn",
         "import lib as qualified" & LF
         & "import lib (number, cell, marked, absent, problems,"
         & " choice, empty, full," & LF
         & "            counter, answer, identity, work)" & LF
         & "as: i32 = 0" & LF
         & "qualified: i32 = 2" & LF
         & "answer: i32 = 99" & LF
         & "forward: (item: type is marked, value: item) ->"
         & " (result: item) =" & LF
         & "    result = identity(value)" & LF
         & "end forward" & LF
         & "fallible: (value: number) -> (result: number) ! problems =" & LF
         & "    result = try work(value)" & LF
         & "end fallible" & LF
         & "shadow: (answer: i32) -> (result: i32) = answer end shadow" & LF
         & "public main: () -> (code: i32) =" & LF
         & "    original: cell(number) = (value: forward(answer))" & LF
         & "    selected: choice = choice(kind: full(value:"
         & " original.value))" & LF
         & "    counter = counter + 1" & LF
         & "    caught := fallible(-1) else (problem)" & LF
         & "        match problem" & LF
         & "            absent: 0" & LF
         & "            _: 1" & LF
         & "        end match" & LF
         & "    end" & LF
         & "    if qualified.counter <> 2 or qualified <> 2" & LF
         & "       or sibling() <> 99 or shadow(3) <> 3 or"
         & " caught <> 0 then" & LF
         & "        code = 1" & LF
         & "    else" & LF
         & "        code = match selected.kind" & LF
         & "            empty: 0" & LF
         & "            full: original.value + counter" & LF
         & "        end match" & LF
         & "    end if" & LF
         & "end main" & LF);
      Host.Add_File
        ("entry/sibling.ldn",
         "sibling: () -> (value: i32) = answer end sibling" & LF);
      Args.Append ("--root=root");
      Args.Append ("--root=later");
      Args.Append ("--emit=asm");
      Args.Append ("entry");
      declare
         Result : constant Landin.Driver.Outcome :=
           Landin.Driver.Execute (Args, Host, Tools);
      begin
         Landin.Testing.Check_Equal
           (Item, Result.Status, Landin.Driver.Status_Success,
            "all selected declaration positions emit: "
            & Ada.Strings.Unbounded.To_String (Result.Report));
         Landin.Testing.Check_Equal
           (Item, Tools.Run_Count, 0, "emission invokes no host tool");
      end;
   end Import_Bindings_Preserve_Identity;

   procedure Import_Scopes_And_Refusals
     (Item : in out Landin.Testing.Context);

   procedure Import_Scopes_And_Refusals
     (Item : in out Landin.Testing.Context)
   is
      procedure Check
        (Source, Expected : String; Sibling : String := "";
         Library : String := "public answer: i32 = 42" & LF);

      procedure Check
        (Source, Expected : String; Sibling : String := "";
         Library : String := "public answer: i32 = 42" & LF)
      is
         Host : Landin.Testing.Fakes.Fake_Filesystem;
         Tools : Landin.Testing.Fakes.Fake_Tool_Runner;
         Args : Landin.Platform.Path_List;
      begin
         Host.Add_Directory ("entry");
         Host.Add_Directory ("root");
         Host.Add_Directory ("root/lib");
         Host.Add_Directory ("root/other");
         Host.Add_File
           ("root/other/other.ldn", "public borrowed: i32 = 1" & LF);
         Host.Add_File ("entry/main.ldn", Source & LF);
         Host.Add_File ("entry/sibling.ldn", Sibling & LF);
         Host.Add_File ("root/lib/library.ldn", Library & LF);
         Args.Append ("--root=root");
         Args.Append ("entry");
         declare
            Result : constant Landin.Driver.Outcome :=
              Landin.Driver.Execute (Args, Host, Tools);
            Report : constant String :=
              Ada.Strings.Unbounded.To_String (Result.Report);
         begin
            Landin.Testing.Check
              (Item,
               (if Expected = "" then Result.Status = 0
                else Result.Status = 1 and then
                  Ada.Strings.Fixed.Index (Report, Expected) > 0),
               "import scope verdict " & Expected & ": " & Report);
         end;
      end Check;
   begin
      Check
        ("import lib" & LF & "as: i32 = 2" & LF & "lib: i32 = 3" & LF
         & "f: () -> (v: i32) = lib.answer + lib + as end f", "");
      Check ("import lib (answer, answer)", "L0200");
      Check ("import lib as answer" & LF & "import lib (answer)", "L0200");
      Check ("import lib (answer)" & LF & "import lib as answer", "L0200");
      Check ("import lib (answer)", "",
             Library => "import lib as self" & LF
                        & "public answer: i32 = 42");
      Check ("import lib (borrowed)", "L0201",
             Library => "import other (borrowed)" & LF
                        & "public answer: i32 = 42");
      Check ("import lib (missing)", "L0201");
      Check ("import lib (answer)", "L0202", Library => "answer: i32 = 2");
      Check ("import lib (answer)", "L0201",
             Sibling => "f: () -> (v: i32) = answer end f");
      Check ("import lib as renamed", "L0201",
             Sibling => "f: () -> (v: i32) = renamed.answer end f");
      Check ("import lib (answer)" & LF
             & "f: () -> (v: i32) = lib.answer end f", "L0201");
      Check ("import lib as renamed" & LF
             & "f: () -> (v: i32) = lib.answer end f", "L0201");
      Check ("import lib (answer)" & LF
             & "f: () -> none = answer = 1 end f", "L0303");
      Check ("import lib as compiler", "L0203");
      Check ("import lib (compiler)", "L0203");
      Check ("compiler: i32 = 2", "L0203");
      Check ("f: (assembler: i32) -> none = _ = assembler end f", "L0203");
      Check ("f: () -> none = linker: i32 = 2 _ = linker end f", "L0203");
      Check ("f: (compiler: type) -> none = end f", "L0203");
      Check ("x: type = struct compiler: i32 end x", "");
      Check ("option answer: i32 = 1" & LF & "answer: i32 = 2", "L0200");
      Check ("import lib (answer)" & LF & "option answer: i32 = 1", "L0200");
      Check ("option answer: i32 = 1" & LF
             & "f: () -> (v: i32) = answer end f", "configuration-only");
      Check ("option answer: i32 = 1" & LF
             & "f: (answer: i32) -> (v: i32) = answer end f", "");
      Check ("f: () -> none = assembler.block() end f", "R6.60");
      Check ("f: () -> none = compiler.atomic_add() end f", "R6.30");
      Check ("f: () -> none = compiler.assert(true) end f", "module");
   end Import_Scopes_And_Refusals;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "resolution", "import bindings preserve identity",
         Import_Bindings_Preserve_Identity'Access);
      Landin.Testing.Register
        (Into, "resolution", "import scopes and refusals",
         Import_Scopes_And_Refusals'Access);
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
        (Into, "resolution", "return sources retain parameter positions",
         Return_Sources_Retain_Parameter_Positions'Access);
      Landin.Testing.Register
        (Into, "resolution", "classifies labelled applications callee first",
         Labeled_Applications_Are_Classified_Callee_First'Access);
      Landin.Testing.Register
        (Into, "resolution", "type formals have one collected scope",
         Type_Formals_Have_One_Collected_Scope'Access);
      Landin.Testing.Register
        (Into, "resolution",
         "parameterized struct formals have one collected scope",
         Parameterized_Struct_Formals_Have_One_Collected_Scope'Access);
   end Register;

end Landin.Tests.Resolution_Suite;
