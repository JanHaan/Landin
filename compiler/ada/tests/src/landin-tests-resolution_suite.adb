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
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Targets;

package body Landin.Tests.Resolution_Suite is

   use type Landin.Resolution.Scope_Id;
   use type Landin.Resolution.Scope_Sort;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
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
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the frontend ran");
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
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);
      pragma Assert (Ran = 3);

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

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "resolution", "every scope names the node that opened it",
         Every_Scope_Names_The_Node_That_Opened_It'Access);
      Landin.Testing.Register
        (Into, "resolution", "a node that opens nothing says so",
         A_Node_That_Opens_Nothing_Says_So'Access);
   end Register;

end Landin.Tests.Resolution_Suite;
