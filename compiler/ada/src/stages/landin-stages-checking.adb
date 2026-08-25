with Ada.Strings.Fixed;

with Landin.Checking;
with Landin.Diagnostics.Checking;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Source;
with Landin.Syntax.Forest;
with Landin.Syntax;
with Landin.Targets;
with Landin.Types;

package body Landin.Stages.Checking is

   package Bad renames Landin.Diagnostics.Checking;
   package Res renames Landin.Resolution;
   package Syn renames Landin.Syntax;
   package Ty renames Landin.Types;

   use type Landin.Provenance.Declaration_Id;
   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;
   use type Landin.Types.Type_Kind;
   use type Landin.Types.Folded;
   use type Landin.Checking.Progress;
   use type Res.Verdict;
   use type Res.Declaration_Sort;
   use type Landin.Source.Source_Id;

   overriding function Name (Item : Instance) return String is
      pragma Unreferenced (Item);
   begin
      return "checking";
   end Name;

   overriding procedure Run
     (Item    : Instance;
      Context : in out Compilation;
      Outcome : out Stage_Outcome)
   is
      pragma Unreferenced (Item);

      Spellings : constant not null access Landin.Source.Names.Table :=
        Identities (Context);
      Trees     : constant not null access Syn.Forest.Table :=
        Landin.Stages.Trees (Context);
      Meanings  : constant not null access Res.Table :=
        Landin.Stages.Meanings (Context);
      Types     : constant not null access Landin.Checking.Table :=
        Landin.Stages.Types (Context);

      Facts : constant Landin.Targets.Target_Facts := Target (Context);
      Found : Landin.Diagnostics.Diagnostic_List;

      ------------------------------------------------------------

      function Tree_For (Id : Landin.Source.Source_Id)
        return not null access constant Syn.Tree
        is (Syn.Forest.Tree_Of (Trees.all, Id));

      function Spelled (Of_Name : Landin.Source.Names.Name_Id) return String
        is (Landin.Source.Names.Spelling (Spellings.all, Of_Name));

      --  How a type is named in a sentence a user reads.  The five that are
      --  not one of [1790]'s eleven are described and not spelled, because
      --  no program can write one of them down.
      function Shown (Item : Ty.Type_Kind) return String
        is (case Item is
               when Ty.Scalar_Name     => "`" & Ty.Spelling (Item) & "`",
               when Ty.Untyped_Integer => "a number",
               when Ty.No_Value        => "nothing",
               when others             => "something unknown");

      --  A requirement that is not a real type is checked and says
      --  nothing.  One rule at every position: a hole, a name that
      --  resolved to nothing and a node already refused all arrive here,
      --  and none of them is a second mistake the program made.
      function Decidable (Item : Ty.Type_Kind) return Boolean
        is (Item in Ty.Settled);

      --  A count a sentence can hold.  Natural'Image pads and pluralises
      --  nothing, and a report is bytes a fixture pins.
      function Counted (Value : Natural; Thing : String) return String
        is (Ada.Strings.Fixed.Trim
              (Natural'Image (Value), Ada.Strings.Both)
            & " " & Thing & (if Value = 1 then "" else "s"));

      --  'Image pads a non-negative value with a blank, and a report is
      --  bytes a fixture pins.
      function Written (Value : Ty.Folded) return String
        is (Ada.Strings.Fixed.Trim
              (Ty.Folded'Image (Value), Ada.Strings.Both));

      ------------------------------------------------------------
      --  Forward declarations
      ------------------------------------------------------------

      function Settled_Type (Id : Res.Declaration_Id) return Ty.Type_Kind;
      function Declared_As (Id : Res.Declaration_Id) return Ty.Type_Kind;
      function Declared_As_Node
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind;
      procedure Check_Literal
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wanted  : Ty.Scalar_Name;
         Negated : Boolean);
      procedure Commit_To
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wanted  : Ty.Scalar_Name);
      function Synthesise
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind;
      function Synthesise_Binary
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind;
      function Check_Call
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Callee  : Res.Declaration_Id) return Ty.Type_Kind;
      procedure Require
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wanted  : Ty.Type_Kind;
         Site    : Landin.Provenance.Origin;
         Because : String);
      procedure Check_Place
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Stepping : Boolean);
      procedure Check_Statement
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Returns : Ty.Type_Kind);
      procedure Check_Block
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Returns : Ty.Type_Kind);
      procedure Infer (Id : Res.Declaration_Id);
      function Is_Known (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Boolean;
      procedure Check_Module_Value
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

      ------------------------------------------------------------
      --  What a declaration's type is
      ------------------------------------------------------------

      --  The type a declaration writes down, or Undecided when it writes
      --  none.  Every declaration the kernel has except a module `:=`
      --  binding writes one, which is why pass two is so small.
      --  The type a declaring node writes down: [0110]'s right of the
      --  colon, read as one of [1790]'s eleven.  Undecided when it writes
      --  none, which in the kernel is only [1790]'s `:=` form.
      --  What a type position names.  One of [1790]'s eleven, which the
      --  parser recognised; or [1795]'s declared name, which only
      --  resolution can answer for and which this follows to the type it
      --  was declared from.  D15 makes that an alias, so following it is
      --  the whole of what a type declaration means.
      function Type_At (Of_Tree : Syn.Tree; Written : Syn.Node_Id)
        return Ty.Type_Kind;

      function Type_At (Of_Tree : Syn.Tree; Written : Syn.Node_Id)
        return Ty.Type_Kind is
      begin
         if Syn.Kind (Of_Tree, Written) = Syn.Type_Name then
            return Landin.Checking.Named
              (Types.all, Syn.Name (Of_Tree, Written));
         end if;

         if Syn.Kind (Of_Tree, Written) /= Syn.Type_Reference then
            --  An Error_Type: the parser refused what stood there and said
            --  so, so this declines to answer.
            return Ty.Ill_Typed;
         end if;

         if Res.Verdict_Of (Meanings.all, Of_Tree, Written) /= Res.Bound
         then
            --  [1830]'s refusal from the checker's side.  A name that
            --  resolved to nothing may still be a type the tour writes
            --  and [1790] omits, and saying which it is costs one table:
            --  the difference between "not enabled yet" and "declared
            --  nowhere" is the whole of what a reader needs here.
            declare
               Spelled_Here : constant String :=
                 Spelled (Syn.Name (Of_Tree, Written));
            begin
               for Named in Bad.Refused_Type_Name loop
                  if Bad.Spelling (Named) = Spelled_Here then
                     if Landin.Checking.Type_Of
                          (Types.all, Of_Tree, Written) = Ty.Undecided
                     then
                        Landin.Checking.Note
                          (Types.all, Of_Tree, Written, Ty.Ill_Typed);
                        Bad.Report
                          (Item    => Bad.Unsupported_Use,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Written),
                           Message => "`" & Spelled_Here
                                      & "` is not enabled yet",
                           Refused => Bad.Refusal (Named),
                           Into    => Found);
                     end if;

                     return Ty.Ill_Typed;
                  end if;
               end loop;
            end;

            --  [1860]: a name that names nothing, said here because
            --  resolution leaves a type name to this stage.
            if Landin.Checking.Type_Of (Types.all, Of_Tree, Written)
               = Ty.Undecided
            then
               Landin.Checking.Note
                 (Types.all, Of_Tree, Written, Ty.Ill_Typed);
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Written),
                  Message => "`" & Spelled (Syn.Name (Of_Tree, Written))
                             & "` is not declared in any scope this"
                             & " reaches",
                  Note    => "[1860]: a name that names nothing is"
                             & " refused",
                  Into    => Found);
            end if;

            return Ty.Ill_Typed;
         end if;

         declare
            Means : constant Res.Declaration_Id :=
              Res.Bound_To (Meanings.all, Of_Tree, Written);
         begin
            if Res.Sort_Of (Meanings.all, Means) /= Res.Module_Type then
               --  Every place that needs this type asks again, so the
               --  node carries whether it has been answered for: without
               --  that a name used once is reported once per pass.
               if Landin.Checking.Type_Of (Types.all, Of_Tree, Written)
                  /= Ty.Undecided
               then
                  return Ty.Ill_Typed;
               end if;

               Landin.Checking.Note (Types.all, Of_Tree, Written,
                                     Ty.Ill_Typed);
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Written),
                  Message => "`"
                             & Spelled (Syn.Name (Of_Tree, Written))
                             & "` names something that is not a type",
                  Note    => "[1795]: a type position names one of the"
                             & " scalar types or a `type` declaration",
                  Into    => Found);
               return Ty.Ill_Typed;
            end if;

            return Settled_Type (Means);
         end;
      end Type_At;

      function Declared_As_Node
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind
      is
         Written : constant Syn.Node_Id := Syn.Declared_Type (Of_Tree, Node);
      begin
         if Written = Syn.No_Node then
            return Ty.Undecided;
         end if;

         return Type_At (Of_Tree, Written);
      end Declared_As_Node;

      function Declared_As (Id : Res.Declaration_Id) return Ty.Type_Kind is
         Of_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Id));
         Node    : constant Syn.Node_Id := Res.Node_Of (Meanings.all, Id);
      begin
         if Syn.Kind (Of_Tree.all, Node) = Syn.Function_Declaration then
            --  [1920]: a function is not a value the kernel can spell.
            return Ty.Not_Typed;
         end if;

         return Declared_As_Node (Of_Tree.all, Node);
      end Declared_As;

      function Settled_Type (Id : Res.Declaration_Id) return Ty.Type_Kind is
      begin
         if Id = Res.No_Declaration then
            return Ty.Ill_Typed;
         end if;

         case Landin.Checking.State_Of (Types.all, Id) is
            when Landin.Checking.Settled =>
               return Landin.Checking.Type_Of (Types.all, Id);

            when Landin.Checking.Underway =>
               --  [1940]: a chain of module values that comes back to
               --  where it began names nothing at all, and this is the one
               --  place in it the reader is standing.
               declare
                  Of_Tree : constant not null access constant Syn.Tree :=
                    Tree_For (Res.Source_Of (Meanings.all, Id));
                  Node : constant Syn.Node_Id :=
                    Res.Node_Of (Meanings.all, Id);
               begin
                  Bad.Report
                    (Item    => Bad.Not_Known_At_Compile_Time,
                     Source  => Res.Source_Of (Meanings.all, Id),
                     Where   => Syn.Anchor (Of_Tree.all, Node),
                     Message => "the value of `"
                                & Spelled (Syn.Name (Of_Tree.all, Node))
                                & "` is worked out from itself",
                     Note    => "[1940]: a chain that comes back to where"
                                & " it began names nothing at all",
                     Into    => Found);
               end;

               return Ty.Ill_Typed;

            when Landin.Checking.Untouched =>
               Infer (Id);
               return (if Landin.Checking.State_Of (Types.all, Id)
                          = Landin.Checking.Settled
                       then Landin.Checking.Type_Of (Types.all, Id)
                       else Ty.Ill_Typed);
         end case;
      end Settled_Type;

      ------------------------------------------------------------
      --  A literal's value, and whether the type holds it
      ------------------------------------------------------------

      procedure Check_Literal
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wanted  : Ty.Scalar_Name;
         Negated : Boolean)
      is
         Snap  : constant Landin.Source.Snapshot :=
           Source (Context, Syn.Source_Of (Of_Tree));
         Text  : constant String :=
           Landin.Source.Slice (Snap, Syn.Digit_Span (Of_Tree, Node));
         Value      : Ty.Magnitude;
         Overflowed : Boolean;
      begin
         --  [1890]: a bool has no arithmetic, so a number is never one.
         if Wanted not in Ty.Integer_Name then
            Landin.Checking.Refuse (Types.all, Of_Tree, Node);
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "this is a number, and " & Shown (Wanted)
                          & " holds no number",
               Note    => "[1890]: a bool has no arithmetic and no"
                          & " bitwise set",
               Related => Syn.Origin (Of_Tree, Node),
               Because => "written here",
               Into    => Found);
            return;
         end if;

         Ty.Evaluate (Text, Syn.Base (Of_Tree, Node), Value, Overflowed);

         if Overflowed
           or else not Ty.Fits (Value, Wanted, Facts, Negated)
         then
            Landin.Checking.Refuse (Types.all, Of_Tree, Node);
            Bad.Report
              (Item    => Bad.Literal_Out_Of_Range,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "no " & Shown (Wanted) & " holds this value",
               Note    => "[1880]: a literal takes the type of its context"
                          & " and is checked there",
               Into    => Found);
         end if;
      end Check_Literal;

      --  [1880]: a context reaches inward through the arithmetic, bitwise,
      --  shift and unary levels.  The walk prunes at the first node that
      --  already has a type of its own, so a mixed expression stops at
      --  once.
      procedure Commit_To
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wanted  : Ty.Scalar_Name) is
      begin
         if Node = Syn.No_Node
           or else Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                   /= Ty.Untyped_Integer
         then
            return;
         end if;

         Landin.Checking.Commit (Types.all, Of_Tree, Node, Wanted);

         if Syn.Kind (Of_Tree, Node) = Syn.Integer_Literal then
            Check_Literal (Of_Tree, Node, Wanted, Negated => False);
            return;
         end if;

         --  [1880]: a unary minus is part of the value the range check
         --  reads, which is what makes -128 the smallest i8.
         if Syn.Kind (Of_Tree, Node) = Syn.Negation
           and then Syn.Kind (Of_Tree, Syn.Operand_Of (Of_Tree, Node))
                    = Syn.Integer_Literal
         then
            declare
               Under : constant Syn.Node_Id :=
                 Syn.Operand_Of (Of_Tree, Node);
            begin
               Landin.Checking.Commit (Types.all, Of_Tree, Under, Wanted);
               Check_Literal (Of_Tree, Under, Wanted, Negated => True);
            end;
            return;
         end if;

         for Position in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
            Commit_To (Of_Tree, Syn.Slot (Of_Tree, Node, Position), Wanted);
         end loop;
      end Commit_To;

      ------------------------------------------------------------
      --  Requiring a type of a position
      ------------------------------------------------------------

      procedure Require
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Wanted  : Ty.Type_Kind;
         Site    : Landin.Provenance.Origin;
         Because : String)
      is
         Got : Ty.Type_Kind;
      begin
         if Node = Syn.No_Node then
            return;
         end if;

         Got := Synthesise (Of_Tree, Node);

         if not Decidable (Wanted) or else not Decidable (Got) then
            return;
         end if;

         --  [1880]: this is the only way a literal ever gets a type.
         if Got = Ty.Untyped_Integer then
            if Wanted in Ty.Integer_Name then
               Commit_To (Of_Tree, Node, Wanted);
            else
               Commit_To (Of_Tree, Node, Ty.Bool);
            end if;

            return;
         end if;

         if Wanted = Ty.Untyped_Integer then
            return;
         end if;

         if Got /= Wanted then
            Landin.Checking.Refuse (Types.all, Of_Tree, Node);
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "this is " & Shown (Got) & " and "
                          & Shown (Wanted) & " belongs here",
               Note    => "[1890]: two types that must agree, and [0310]"
                          & " converts nothing between them",
               Related => Site,
               Because => Because,
               Into    => Found);
         end if;
      end Require;

      ------------------------------------------------------------
      --  Asking a node what type it has
      ------------------------------------------------------------

      --  [1890]: every binary operator takes two operands of one type.
      --  Which one is decided by whichever side already has a type; when
      --  neither does, the whole node is untyped and its context settles
      --  it, which is what makes `1 + 2` an i32 in a discard [0200] and a
      --  u8 in a u8 binding.
      function Synthesise_Binary
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind
      is
         Of_Kind    : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
         Comparing  : constant Boolean :=
           Of_Kind in Syn.Equal_To .. Syn.Greater_Or_Equal;
         Left       : constant Syn.Node_Id := Syn.Left_Of (Of_Tree, Node);
         Right      : constant Syn.Node_Id := Syn.Right_Of (Of_Tree, Node);
         Left_Type  : constant Ty.Type_Kind := Synthesise (Of_Tree, Left);
         Right_Type : constant Ty.Type_Kind := Synthesise (Of_Tree, Right);
         Decided    : Ty.Type_Kind;
      begin
         if not Decidable (Left_Type) or else not Decidable (Right_Type)
         then
            return Ty.Ill_Typed;
         end if;

         if Left_Type = Ty.Untyped_Integer
           and then Right_Type = Ty.Untyped_Integer
         then
            --  Nothing here has a type yet.  A comparison has one anyway,
            --  because [1890] says it gives a bool back, so its operands
            --  take [0200]'s default and the node is a bool.
            if not Comparing then
               return Ty.Untyped_Integer;
            end if;

            Commit_To (Of_Tree, Left, Ty.Default_Integer);
            Commit_To (Of_Tree, Right, Ty.Default_Integer);
            return Ty.Bool;
         end if;

         Decided :=
           (if Left_Type = Ty.Untyped_Integer then Right_Type
            else Left_Type);

         --  [1890]: only a comparison takes a bool, and it takes two.
         if not Comparing and then Decided not in Ty.Integer_Name then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Anchor (Of_Tree, Node),
               Message => "this operator wants numbers and was given "
                          & Shown (Decided),
               Note    => "[1890]: an integer has no logical words and a"
                          & " bool has no arithmetic",
               Related => Syn.Origin (Of_Tree, Node),
               Because => "here",
               Into    => Found);
            return Ty.Ill_Typed;
         end if;

         Require
           (Of_Tree, Left, Decided, Syn.Origin (Of_Tree, Node),
            "required by this operator");
         Require
           (Of_Tree, Right, Decided, Syn.Origin (Of_Tree, Node),
            "required by this operator");

         return (if Comparing then Ty.Bool else Decided);
      end Synthesise_Binary;

      --  [1920]: a call names every parameter exactly once and in order,
      --  each argument has its parameter's type, and the call has the type
      --  of the named return.
      function Check_Call
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Callee  : Res.Declaration_Id) return Ty.Type_Kind
      is
         Their_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Callee));
         Their_Node : constant Syn.Node_Id :=
           Res.Node_Of (Meanings.all, Callee);
         Wanted : constant Natural :=
           Syn.Parameter_Count (Their_Tree.all, Their_Node);
         Given  : constant Natural := Syn.Argument_Count (Of_Tree, Node);
         Result : constant Syn.Node_Id :=
           Syn.Return_Of (Their_Tree.all, Their_Node);
      begin
         if Given /= Wanted then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "this call gives " & Counted (Given, "argument")
                          & " and the function takes "
                          & Counted (Wanted, "argument"),
               Note    => "[1920]: a call names every parameter exactly"
                          & " once and in order",
               Related => Syn.Origin (Their_Tree.all, Their_Node),
               Because => "declared here",
               Into    => Found);
            return Ty.Ill_Typed;
         end if;

         for Which in 1 .. Wanted loop
            declare
               Parameter : constant Syn.Node_Id :=
                 Syn.Nth_Parameter (Their_Tree.all, Their_Node, Which);
               Wants : constant Ty.Type_Kind :=
                 Declared_As_Node (Their_Tree.all, Parameter);
            begin
               Require
                 (Of_Tree, Syn.Nth_Argument (Of_Tree, Node, Which), Wants,
                  Syn.Origin (Their_Tree.all, Parameter),
                  "this parameter");
            end;
         end loop;

         if Result = Syn.No_Node then
            return Ty.No_Value;
         end if;

         return Declared_As_Node (Their_Tree.all, Result);
      end Check_Call;

      function Synthesise
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind
      is
         Already : constant Ty.Type_Kind :=
           Landin.Checking.Type_Of (Types.all, Of_Tree, Node);

         function Kept (Item : Ty.Type_Kind) return Ty.Type_Kind;

         function Kept (Item : Ty.Type_Kind) return Ty.Type_Kind is
         begin
            if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
               = Ty.Undecided
            then
               Landin.Checking.Note (Types.all, Of_Tree, Node, Item);
            end if;

            return Landin.Checking.Type_Of (Types.all, Of_Tree, Node);
         end Kept;
      begin
         if Already /= Ty.Undecided then
            return Already;
         end if;

         --  A subtree with a hole in it is not checked: R1.40 already said
         --  what is wrong with it.
         if not Syn.Is_Sound (Of_Tree, Node) then
            return Kept (Ty.Ill_Typed);
         end if;

         case Syn.Kind (Of_Tree, Node) is
            when Syn.Integer_Literal =>
               return Kept (Ty.Untyped_Integer);

            when Syn.True_Literal | Syn.False_Literal =>
               return Kept (Ty.Bool);

            --  D14: a measurement is a `usize`.  The type it asks about
            --  is recorded on its own node, because the lowering reads it
            --  from there and a type name is not an expression that would
            --  otherwise be walked.
            when Syn.Size_Of | Syn.Align_Of =>
               declare
                  Asked : constant Syn.Node_Id :=
                    Syn.Measured_Type (Of_Tree, Node);
               begin
                  if Syn.Kind (Of_Tree, Asked) /= Syn.Type_Name then
                     --  An Error_Type: the parser refused what stood
                     --  there and named it.
                     return Kept (Ty.Ill_Typed);
                  end if;

                  Landin.Checking.Note
                    (Types.all, Of_Tree, Asked,
                     Landin.Checking.Named
                       (Types.all, Syn.Name (Of_Tree, Asked)));
                  return Kept (Ty.Usize);
               end;

            when Syn.Name_Reference =>
               if Res.Verdict_Of (Meanings.all, Of_Tree, Node)
                  /= Res.Bound
               then
                  return Kept (Ty.Ill_Typed);
               end if;

               declare
                  Means : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Node);
                  Held  : constant Ty.Type_Kind := Settled_Type (Means);
               begin
                  --  [1920]: a function's name anywhere but in front of a
                  --  `(` is a function value [1000], which [1790]'s type
                  --  rule does not spell.
                  if Held = Ty.Not_Typed then
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Node),
                        Message => "`" & Spelled (Syn.Name (Of_Tree, Node))
                                   & "` names a function, and a function"
                                   & " used as a value is not enabled yet",
                        Refused => Bad.Function_Value,
                        Into    => Found);
                     return Kept (Ty.Ill_Typed);
                  end if;

                  return Kept (Held);
               end;

            when Syn.Call =>
               declare
                  Callee : constant Syn.Node_Id :=
                    Syn.Callee_Of (Of_Tree, Node);
               begin
                  if Res.Verdict_Of (Meanings.all, Of_Tree, Callee)
                     /= Res.Bound
                  then
                     return Kept (Ty.Ill_Typed);
                  end if;

                  declare
                     Means : constant Res.Declaration_Id :=
                       Res.Bound_To (Meanings.all, Of_Tree, Callee);
                  begin
                     --  [1920]: a callee is a function.  A name bound to a
                     --  binding is not one.
                     if Settled_Type (Means) /= Ty.Not_Typed then
                        Bad.Report
                          (Item    => Bad.Unsupported_Use,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Callee),
                           Message => "`"
                                      & Spelled
                                          (Syn.Name (Of_Tree, Callee))
                                      & "` is not a function, so this is"
                                      & " not a call",
                           Refused => Bad.Call_Of_A_Binding,
                           Into    => Found);
                        return Kept (Ty.Ill_Typed);
                     end if;

                     return Kept (Check_Call (Of_Tree, Node, Means));
                  end;
               end;

            when Syn.Negation | Syn.Complement =>
               declare
                  Under : constant Ty.Type_Kind :=
                    Synthesise (Of_Tree, Syn.Operand_Of (Of_Tree, Node));
               begin
                  if Under = Ty.Untyped_Integer then
                     return Kept (Ty.Untyped_Integer);
                  end if;

                  if not Decidable (Under) then
                     return Kept (Ty.Ill_Typed);
                  end if;

                  if Under not in Ty.Integer_Name then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Anchor (Of_Tree, Node),
                        Message => "this operator wants a number and was"
                                   & " given " & Shown (Under),
                        Note    => "[1890]: a bool has no arithmetic and"
                                   & " no bitwise set",
                        Related => Syn.Origin (Of_Tree, Node),
                        Because => "here",
                        Into    => Found);
                     return Kept (Ty.Ill_Typed);
                  end if;

                  return Kept (Under);
               end;

            when Syn.Logical_Not =>
               Require
                 (Of_Tree, Syn.Operand_Of (Of_Tree, Node), Ty.Bool,
                  Syn.Origin (Of_Tree, Node), "required by `not`");
               return Kept (Ty.Bool);

            when Syn.Logical_And | Syn.Logical_Or =>
               Require
                 (Of_Tree, Syn.Left_Of (Of_Tree, Node), Ty.Bool,
                  Syn.Origin (Of_Tree, Node), "required by this operator");
               Require
                 (Of_Tree, Syn.Right_Of (Of_Tree, Node), Ty.Bool,
                  Syn.Origin (Of_Tree, Node), "required by this operator");
               return Kept (Ty.Bool);

            --  The binary band minus the logical words, which the arm
            --  above already answered: [1890] gives those a bool on both
            --  sides and everything here one integer type.
            when Syn.Multiply .. Syn.Greater_Or_Equal =>
               return Kept (Synthesise_Binary (Of_Tree, Node));

            when others =>
               return Kept (Ty.Not_Typed);
         end case;
      end Synthesise;

      ------------------------------------------------------------
      --  Statements
      ------------------------------------------------------------

      --  [1900]: of the four kinds of name the kernel has, two may be
      --  written and two may not.  Stepping says the place is an `inc` or a
      --  `dec`, which [0400] makes an addition and so wants a number too.
      procedure Check_Place
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Stepping : Boolean)
      is
         Held : Ty.Type_Kind;
      begin
         if Res.Verdict_Of (Meanings.all, Of_Tree, Node) /= Res.Bound then
            return;
         end if;

         declare
            Means : constant Res.Declaration_Id :=
              Res.Bound_To (Meanings.all, Of_Tree, Node);
            Sort  : constant Res.Declaration_Sort :=
              Res.Sort_Of (Meanings.all, Means);
            Their_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of (Meanings.all, Means));
            Their_Node : constant Syn.Node_Id :=
              Res.Node_Of (Meanings.all, Means);
            Writable : Boolean;
         begin
            Writable :=
              (case Sort is
                  when Res.Named_Return    => True,
                  when Res.Parameter       => False,
                  when Res.Module_Function => False,
                  --  [1795] names a type, and a type is not a place.
                  when Res.Module_Type     => False,
                  when Res.Module_Binding | Res.Local_Binding =>
                     Syn.Is_Mutable (Their_Tree.all, Their_Node));

            if not Writable then
               Bad.Report
                 (Item    => Bad.Immutable_Target,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Node),
                  Message =>
                    "`" & Spelled (Syn.Name (Of_Tree, Node)) & "` "
                    & (case Sort is
                          when Res.Parameter =>
                             "is a parameter, and a parameter is taken in",
                          when Res.Module_Function =>
                             "names a function, which is not a place",
                          when others =>
                             "is not mutable, so it may not be written"),
                  Note    => "[1900]: a mutable binding and a named return"
                             & " may be written, and nothing else may",
                  Related => Landin.Provenance.Origin'
                               (Source => Res.Source_Of
                                            (Meanings.all, Means),
                                Where  => Syn.Anchor
                                            (Their_Tree.all, Their_Node)),
                  Because => "declared here",
                  Into    => Found);
               Landin.Checking.Refuse (Types.all, Of_Tree, Node);
               return;
            end if;

            Held := Synthesise (Of_Tree, Node);

            --  [0400]: `inc` says what `x += 1` says, so it wants a number.
            if Stepping and then Decidable (Held)
              and then Held not in Ty.Integer_Name
            then
               Bad.Report
                 (Item    => Bad.Type_Mismatch,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Node),
                  Message => "this steps " & Shown (Held)
                             & ", and only a number can be stepped",
                  Note    => "[1900]: `inc` and `dec` say what `x += 1`"
                             & " says [0400]",
                  Related => Syn.Origin (Of_Tree, Node),
                  Because => "here",
                  Into    => Found);
            end if;
         end;
      end Check_Place;

      procedure Check_Statement
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Returns : Ty.Type_Kind) is
      begin
         case Syn.Kind (Of_Tree, Node) is
            when Syn.Binding =>
               declare
                  Value : constant Syn.Node_Id :=
                    Syn.Value_Of (Of_Tree, Node);
                  Wants : constant Ty.Type_Kind :=
                    Declared_As_Node (Of_Tree, Node);
               begin
                  if Value = Syn.No_Node then
                     null;
                  elsif Wants = Ty.Undecided then
                     --  [0050]: the inferred form takes the value's type,
                     --  and [0200] settles a literal that has none.
                     declare
                        Got : constant Ty.Type_Kind :=
                          Synthesise (Of_Tree, Value);
                     begin
                        if Got = Ty.Untyped_Integer then
                           Commit_To (Of_Tree, Value, Ty.Default_Integer);
                        elsif Got = Ty.No_Value then
                           Bad.Report
                             (Item    => Bad.Type_Mismatch,
                              Source  => Syn.Source_Of (Of_Tree),
                              Where   => Syn.Where (Of_Tree, Value),
                              Message => "this hands back nothing, so"
                                         & " there is no type to infer",
                              Note    => "[1920]: a call of a function"
                                         & " returning none has no type",
                              Related => Syn.Origin (Of_Tree, Node),
                              Because => "this binding",
                              Into    => Found);
                        end if;
                     end;
                  else
                     Require
                       (Of_Tree, Value, Wants, Syn.Origin (Of_Tree, Node),
                        "the type declared here");
                  end if;
               end;

            when Syn.Assignment =>
               Check_Place
                 (Of_Tree, Syn.Target_Of (Of_Tree, Node),
                  Stepping => False);
               Require
                 (Of_Tree, Syn.Value_Of (Of_Tree, Node),
                  Synthesise (Of_Tree, Syn.Target_Of (Of_Tree, Node)),
                  Syn.Origin (Of_Tree, Syn.Target_Of (Of_Tree, Node)),
                  "the place written here");

            when Syn.Increment | Syn.Decrement =>
               Check_Place
                 (Of_Tree, Syn.Target_Of (Of_Tree, Node), Stepping => True);

            when Syn.Discard =>
               --  [1930]: anything with a type may be thrown away, and a
               --  call that hands back nothing has none.
               declare
                  Value : constant Syn.Node_Id :=
                    Syn.Value_Of (Of_Tree, Node);
                  Got   : Ty.Type_Kind;
               begin
                  if Value = Syn.No_Node then
                     return;
                  end if;

                  Got := Synthesise (Of_Tree, Value);

                  if Got = Ty.Untyped_Integer then
                     Commit_To (Of_Tree, Value, Ty.Default_Integer);
                  elsif Got = Ty.No_Value then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Value),
                        Message => "this hands back nothing, so there is"
                                   & " no result to discard",
                        Note    => "[1930]: discarding is for a result,"
                                   & " and that call has none",
                        Related => Syn.Origin (Of_Tree, Node),
                        Because => "the discard",
                        Into    => Found);
                  end if;
               end;

            when Syn.Return_Statement =>
               --  [1890]: an exit's `when` is a condition, so it is a bool
               --  for [1050]'s reason asked where the exit is.
               Require
                 (Of_Tree, Syn.Condition_Of (Of_Tree, Node), Ty.Bool,
                  Syn.Origin (Of_Tree, Node), "the guard of this exit");

            when Syn.If_Statement =>
               for Arm in 1 .. Syn.Arm_Count (Of_Tree, Node) loop
                  declare
                     This : constant Syn.Node_Id :=
                       Syn.Nth_Arm (Of_Tree, Node, Arm);
                  begin
                     Require
                       (Of_Tree, Syn.Condition_Of (Of_Tree, This), Ty.Bool,
                        Syn.Origin (Of_Tree, This),
                        "the condition of this branch");
                     Check_Block
                       (Of_Tree, Syn.Body_Of (Of_Tree, This), Returns);
                  end;
               end loop;

               if Syn.Else_Body (Of_Tree, Node) /= Syn.No_Node then
                  Check_Block
                    (Of_Tree, Syn.Else_Body (Of_Tree, Node), Returns);
               end if;

            when Syn.Call =>
               --  [1920]: a call standing alone is a statement, and one
               --  that hands a value back is [1020]'s omitted discard --
               --  which R2 will refuse; the kernel accepts it because
               --  nothing in the tour refuses it yet.
               declare
                  Got : constant Ty.Type_Kind := Synthesise (Of_Tree, Node);
               begin
                  pragma Unreferenced (Got);
               end;

            when others =>
               null;
         end case;
      end Check_Statement;

      procedure Check_Block
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Returns : Ty.Type_Kind) is
      begin
         for Index in 1 .. Syn.Statement_Count (Of_Tree, Node) loop
            Check_Statement
              (Of_Tree, Syn.Nth_Statement (Of_Tree, Node, Index), Returns);
         end loop;
      end Check_Block;

      ------------------------------------------------------------
      --  [1940]: a module value is known when the compiler reads it
      ------------------------------------------------------------

      --  A literal, `true`, `false`, an operator of [1820] over those, and
      --  a name bound to a module binding.  Not a call: there is no
      --  compile-time execution in this language, so a call is not a value
      --  the compiler holds.
      function Is_Known (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
        return Boolean is
      begin
         if Node = Syn.No_Node then
            return True;
         end if;

         case Syn.Kind (Of_Tree, Node) is
            when Syn.Call =>
               return False;

            when Syn.Name_Reference =>
               if Res.Verdict_Of (Meanings.all, Of_Tree, Node)
                  /= Res.Bound
               then
                  --  Not resolved: the resolver said so and this declines
                  --  to say it again.
                  return True;
               end if;

               return Res.Sort_Of
                        (Meanings.all,
                         Res.Bound_To (Meanings.all, Of_Tree, Node))
                      = Res.Module_Binding;

            when others =>
               for Position in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
                  if not Is_Known
                           (Of_Tree, Syn.Slot (Of_Tree, Node, Position))
                  then
                     return False;
                  end if;
               end loop;

               return True;
         end case;
      end Is_Known;

      procedure Check_Module_Value
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         Value : constant Syn.Node_Id := Syn.Value_Of (Of_Tree, Node);
      begin
         if Value = Syn.No_Node or else Is_Known (Of_Tree, Value) then
            return;
         end if;

         Bad.Report
           (Item    => Bad.Not_Known_At_Compile_Time,
            Source  => Syn.Source_Of (Of_Tree),
            Where   => Syn.Where (Of_Tree, Value),
            Message => "a module value has to be one the compiler knows"
                       & " when it reads it, and this is a call",
            Note    => "[1940]: nothing runs before the entry point"
                       & " [1460], and there is no compile-time execution",
            Into    => Found);
         Landin.Checking.Refuse (Types.all, Of_Tree, Value);
      end Check_Module_Value;

      procedure Infer (Id : Res.Declaration_Id) is
         Of_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Id));
         Node    : constant Syn.Node_Id := Res.Node_Of (Meanings.all, Id);
         Value   : constant Syn.Node_Id := Syn.Value_Of (Of_Tree.all, Node);
      begin
         Landin.Checking.Begin_Inference (Types.all, Id);

         if Value = Syn.No_Node then
            Landin.Checking.Settle (Types.all, Id, Ty.Ill_Typed);
            return;
         end if;

         declare
            Got : constant Ty.Type_Kind := Synthesise (Of_Tree.all, Value);
         begin
            if Got = Ty.Untyped_Integer then
               Commit_To (Of_Tree.all, Value, Ty.Default_Integer);
               Landin.Checking.Settle
                 (Types.all, Id, Ty.Type_Kind (Ty.Default_Integer));
            else
               Landin.Checking.Settle (Types.all, Id, Got);
            end if;
         end;
      end Infer;

      ------------------------------------------------------------
      --  [1940]: a module value is folded, because it cannot trap
      ------------------------------------------------------------

      --  [0300] says overflow traps, and inside a body it does.  A module
      --  value has no body to trap in: [1460] says nothing runs before the
      --  entry point, so `over: u8 = 200 + 100` has no moment at which to
      --  trap and no value to stand for it.  So it is folded here and
      --  refused if no type holds the answer.
      --
      --  Known is False when the fold met something it cannot evaluate --
      --  a name that resolved to nothing, a subtree already refused, a
      --  chain [1940] reported, or a product too wide for Folded.  Silence
      --  is right in every one of those: each was reported where it was
      --  found, or is not this rule's business.
      procedure Fold
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Depth   : Natural;
         Value   : out Ty.Folded;
         Known   : out Boolean);

      --  Which module bindings this fold is standing inside.  [1940] says a
      --  chain that comes back to where it began names nothing at all, and
      --  the inference guard above catches only the chains that have a type
      --  to infer: `a: i32 = b + 1` beside `b: i32 = a + 1` writes both
      --  types down, so nothing is ever Underway and the cycle reached this
      --  walk unreported.  It was found by the backend meeting it, which is
      --  three stages too late for a rule the checker owns.
      Folding : array (Res.Declaration_Id'(1)
                       .. Res.Declaration_Id
                            (Res.Declaration_Count (Meanings.all)))
                  of Boolean := [others => False];

      procedure Fold
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Depth   : Natural;
         Value   : out Ty.Folded;
         Known   : out Boolean)
      is
         --  Guarded rather than caught, which is the rule
         --  Landin.Types.Evaluate already keeps: a sum too wide is
         --  entirely in the bytes being looked at.
         procedure Combine
           (Left, Right : Ty.Folded;
            Of_Kind     : Syn.Node_Kind;
            Answer      : out Ty.Folded;
            Fits        : out Boolean);

         procedure Combine
           (Left, Right : Ty.Folded;
            Of_Kind     : Syn.Node_Kind;
            Answer      : out Ty.Folded;
            Fits        : out Boolean) is
         begin
            Answer := 0;
            Fits   := True;

            case Of_Kind is
               when Syn.Add | Syn.Wrapping_Add =>
                  Fits := (if Right > 0
                           then Left <= Ty.Folded'Last - Right
                           else Left >= Ty.Folded'First - Right);

               when Syn.Subtract | Syn.Wrapping_Subtract =>
                  Fits := (if Right > 0
                           then Left >= Ty.Folded'First + Right
                           else Left <= Ty.Folded'Last + Right);

               when Syn.Multiply | Syn.Wrapping_Multiply =>
                  Fits := Left = 0
                          or else abs Right
                                  <= Ty.Folded'Last / abs Left;

               when Syn.Divide | Syn.Remainder =>
                  --  Declining rather than dividing, because there is
                  --  nothing to divide by.  Check_Operands is what turns
                  --  this into a diagnostic: [1950] refuses a divisor the
                  --  compiler knows is zero, and at module level [1940]'s
                  --  whole fold is what knowing means.  Before that rule
                  --  existed the decline was silent, and `d: u32 = 7 / 0`
                  --  was accepted.
                  Fits := Right /= 0;

               when others =>
                  Fits := True;
            end case;

            if not Fits then
               return;
            end if;

            case Of_Kind is
               when Syn.Add | Syn.Wrapping_Add =>
                  Answer := Left + Right;

               when Syn.Subtract | Syn.Wrapping_Subtract =>
                  Answer := Left - Right;

               when Syn.Multiply | Syn.Wrapping_Multiply =>
                  Answer := Left * Right;

               when Syn.Divide =>
                  Answer := Left / Right;

               when Syn.Remainder =>
                  Answer := Left rem Right;

               when others =>
                  --  The bitwise and shift levels are not folded: their
                  --  answer depends on the width [0320] [0330], and a
                  --  width belongs to Landin.Types.Width and to a target.
                  --  Declining is honest; guessing would not be.
                  Fits := False;
            end case;
         end Combine;
      begin
         Value := 0;
         Known := False;

         if Node = Syn.No_Node then
            return;
         end if;

         if not Syn.Is_Sound (Of_Tree, Node) then
            return;
         end if;

         case Syn.Kind (Of_Tree, Node) is
            when Syn.Integer_Literal =>
               declare
                  Snap : constant Landin.Source.Snapshot :=
                    Source (Context, Syn.Source_Of (Of_Tree));
                  Text : constant String :=
                    Landin.Source.Slice
                      (Snap, Syn.Digit_Span (Of_Tree, Node));
                  Held       : Ty.Magnitude;
                  Overflowed : Boolean;
               begin
                  Ty.Evaluate
                    (Text, Syn.Base (Of_Tree, Node), Held, Overflowed);

                  if not Overflowed then
                     Value := Ty.Folded (Held);
                     Known := True;
                  end if;
               end;

            when Syn.Negation =>
               declare
                  Under : Ty.Folded;
               begin
                  Fold (Of_Tree, Syn.Operand_Of (Of_Tree, Node),
                        Depth + 1, Under, Known);

                  if Known then
                     Value := -Under;
                  end if;
               end;

            when Syn.Name_Reference =>
               --  [1940]: a name bound to a module binding whose value is
               --  known is itself known.
               if Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound
               then
                  declare
                     Means : constant Res.Declaration_Id :=
                       Res.Bound_To (Meanings.all, Of_Tree, Node);
                  begin
                     if Res.Sort_Of (Meanings.all, Means)
                        = Res.Module_Binding
                     then
                        declare
                           Their_Tree : constant
                             not null access constant Syn.Tree :=
                               Tree_For
                                 (Res.Source_Of (Meanings.all, Means));
                           Theirs : constant Syn.Node_Id :=
                             Res.Node_Of (Meanings.all, Means);
                        begin
                           if Folding (Means) then
                              --  [1940]: the report names the declaration
                              --  the chain came back to, because that is
                              --  the one place in it the reader is
                              --  standing.
                              Bad.Report
                                (Item    =>
                                   Bad.Not_Known_At_Compile_Time,
                                 Source  =>
                                   Res.Source_Of (Meanings.all, Means),
                                 Where   =>
                                   Syn.Anchor (Their_Tree.all, Theirs),
                                 Message => "the value of `"
                                            & Spelled
                                                (Syn.Name
                                                   (Their_Tree.all,
                                                    Theirs))
                                            & "` is worked out from"
                                            & " itself",
                                 Note    => "[1940]: a chain that comes"
                                            & " back to where it began"
                                            & " names nothing at all",
                                 Into    => Found);
                              Known := False;
                              return;
                           end if;

                           Folding (Means) := True;
                           Fold
                             (Their_Tree.all,
                              Syn.Value_Of (Their_Tree.all, Theirs),
                              Depth + 1, Value, Known);
                           Folding (Means) := False;
                        end;
                     end if;
                  end;
               end if;

            when Syn.Add | Syn.Subtract | Syn.Multiply | Syn.Divide
               | Syn.Remainder | Syn.Wrapping_Add | Syn.Wrapping_Subtract
               | Syn.Wrapping_Multiply =>
               declare
                  Left, Right : Ty.Folded;
                  Left_Known, Right_Known, Fits : Boolean;
               begin
                  Fold (Of_Tree, Syn.Left_Of (Of_Tree, Node), Depth + 1,
                        Left, Left_Known);
                  Fold (Of_Tree, Syn.Right_Of (Of_Tree, Node), Depth + 1,
                        Right, Right_Known);

                  if Left_Known and then Right_Known then
                     Combine (Left, Right, Syn.Kind (Of_Tree, Node),
                              Value, Fits);
                     Known := Fits;
                  end if;
               end;

            when others =>
               null;
         end case;
      end Fold;

      --  [1940]'s refusal, applied to one module binding.
      procedure Check_Module_Fold
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id);

      procedure Check_Module_Fold
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id)
      is
         Value  : constant Syn.Node_Id := Syn.Value_Of (Of_Tree, Node);
         Wanted : Ty.Type_Kind;
         Held   : Ty.Folded;
         Known  : Boolean;
      begin
         if Value = Syn.No_Node then
            return;
         end if;

         Wanted := Declared_As_Node (Of_Tree, Node);

         --  [0050]'s inferred form has no declared type, so [0200]'s
         --  default is what the fold has to fit.
         if Wanted = Ty.Undecided then
            Wanted := Landin.Checking.Type_Of
                        (Types.all, Of_Tree, Value);
         end if;

         if Wanted not in Ty.Integer_Name then
            return;
         end if;

         Fold (Of_Tree, Value, 0, Held, Known);

         --  A literal on its own is already checked where its context gave
         --  it a type, so this only speaks about a fold the checker has
         --  not otherwise seen.
         if Syn.Kind (Of_Tree, Value) in Syn.Integer_Literal | Syn.Negation
         then
            return;
         end if;

         if Known and then not Ty.Holds (Held, Wanted, Facts) then
            Bad.Report
              (Item    => Bad.Literal_Out_Of_Range,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Value),
               Message => "this works out to " & Written (Held)
                          & ", and no " & Shown (Wanted) & " holds it",
               Note    => "[1940]: a module value has no moment in which"
                          & " to trap, so a fold no type holds is refused",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Value);
         end if;
      end Check_Module_Fold;

      ------------------------------------------------------------
      --  [1950]: an operand the operation cannot take
      ------------------------------------------------------------

      --  What [1880] calls known inside a body: a literal, or a unary
      --  minus over one, and nothing else.  Deliberately not Fold, which
      --  is [1940]'s and reaches through a module binding.  [1950] says
      --  the two knowns are different on purpose, and the difference is
      --  what keeps a program's legality still while an implementation
      --  gets better at folding -- D7's objection, asked about a value
      --  rather than about a condition.
      procedure Known_Literal
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Value   : out Ty.Folded;
         Known   : out Boolean);

      procedure Known_Literal
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Value   : out Ty.Folded;
         Known   : out Boolean) is
      begin
         Value := 0;
         Known := False;

         if Node = Syn.No_Node
           or else not Syn.Is_Sound (Of_Tree, Node)
         then
            return;
         end if;

         case Syn.Kind (Of_Tree, Node) is
            when Syn.Integer_Literal =>
               declare
                  Snap : constant Landin.Source.Snapshot :=
                    Source (Context, Syn.Source_Of (Of_Tree));
                  Text : constant String :=
                    Landin.Source.Slice
                      (Snap, Syn.Digit_Span (Of_Tree, Node));
                  Held       : Ty.Magnitude;
                  Overflowed : Boolean;
               begin
                  Ty.Evaluate
                    (Text, Syn.Base (Of_Tree, Node), Held, Overflowed);

                  if not Overflowed then
                     Value := Ty.Folded (Held);
                     Known := True;
                  end if;
               end;

            when Syn.Negation =>
               declare
                  Under : Ty.Folded;
               begin
                  Known_Literal
                    (Of_Tree, Syn.Operand_Of (Of_Tree, Node),
                     Under, Known);

                  if Known then
                     Value := -Under;
                  end if;
               end;

            when others =>
               null;
         end case;
      end Known_Literal;

      --  Whether [1880] or anything before it has already refused any part
      --  of this operand.  Recursive rather than a look at the root: a
      --  literal out of range is refused where the literal is, and a unary
      --  minus over it keeps the type it correctly had.
      function Refused_Already
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Refused_Already
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean is
      begin
         if Node = Syn.No_Node
           or else not Syn.Is_Sound (Of_Tree, Node)
         then
            return True;
         end if;

         if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
            = Ty.Ill_Typed
         then
            return True;
         end if;

         for Position in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
            if Refused_Already
                 (Of_Tree, Syn.Slot (Of_Tree, Node, Position))
            then
               return True;
            end if;
         end loop;

         return False;
      end Refused_Already;

      --  The walk.  Whole_Fold picks which paragraph decides what known
      --  means -- [1940]'s fold for a module value, [1880]'s literal
      --  inside a body -- and nothing else about the two differs.
      procedure Check_Operands
        (Of_Tree    : Syn.Tree;
         Node       : Syn.Node_Id;
         Whole_Fold : Boolean);

      procedure Check_Operands
        (Of_Tree    : Syn.Tree;
         Node       : Syn.Node_Id;
         Whole_Fold : Boolean)
      is
         Amount : Ty.Folded;
         Known  : Boolean;
      begin
         if Node = Syn.No_Node
           or else not Syn.Is_Sound (Of_Tree, Node)
         then
            return;
         end if;

         for Position in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
            Check_Operands
              (Of_Tree, Syn.Slot (Of_Tree, Node, Position), Whole_Fold);
         end loop;

         if Syn.Kind (Of_Tree, Node) not in
              Syn.Divide | Syn.Remainder | Syn.Shift_Left | Syn.Shift_Right
         then
            return;
         end if;

         declare
            Right : constant Syn.Node_Id := Syn.Right_Of (Of_Tree, Node);
         begin
            if Right = Syn.No_Node
              or else not Syn.Is_Sound (Of_Tree, Right)
            then
               return;
            end if;

            --  Already refused, and one mistake earns one diagnostic.
            --  `x: u8` shifted by -1 is [1880]'s refusal of a literal no
            --  u8 holds, and saying so twice would name two faults where
            --  a reader made one.  The whole operand and not its root:
            --  [1880] refuses the literal inside the unary minus, so the
            --  minus above it is still holding a settled type.
            if Refused_Already (Of_Tree, Right) then
               return;
            end if;

            if Whole_Fold then
               Fold (Of_Tree, Right, 0, Amount, Known);
            else
               Known_Literal (Of_Tree, Right, Amount, Known);
            end if;

            if not Known then
               return;
            end if;

            case Syn.Kind (Of_Tree, Node) is
               when Syn.Divide | Syn.Remainder =>
                  if Amount /= 0 then
                     return;
                  end if;

                  Bad.Report
                    (Item    => Bad.Impossible_Operand,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Right),
                     Message => "this divisor is zero, and there is no"
                                & " quotient for it to produce",
                     Note    => "[1950]: an operand the operation cannot"
                                & " take is refused where the compiler"
                                & " knows it",
                     Into    => Found);

               when others =>
                  if Amount >= 0 then
                     return;
                  end if;

                  Bad.Report
                    (Item    => Bad.Impossible_Operand,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Right),
                     Message => "this shift amount is negative, and"
                                & " [0320] gives a shift one form only",
                     Note    => "[1950]: an operand the operation cannot"
                                & " take is refused where the compiler"
                                & " knows it",
                     Into    => Found);
            end case;

            Landin.Checking.Refuse (Types.all, Of_Tree, Right);
         end;
      end Check_Operands;

      ------------------------------------------------------------
      --  [1910]: assigned before it is read
      ------------------------------------------------------------

      --  One Boolean per declaration, copied at a branch and merged after
      --  it.  A set and not a counter, because [1910] is about paths: a
      --  name assigned in one arm and not another is not assigned after
      --  the branch, and nothing but the per-declaration answer says that.
      subtype Tracked is Positive range
        1 .. Positive'Max (1, Res.Declaration_Count (Meanings.all));

      type Assigned_Set is array (Tracked) of Boolean;

      Nothing_Assigned : constant Assigned_Set := [others => False];

      --  Which declarations [1910] is about.  A parameter arrives assigned
      --  and a module binding is [1940]'s, so what is left is a local
      --  declared with no value and the named return.
      function Is_Tracked (Id : Res.Declaration_Id) return Boolean;
      function Declaration_At
        (Src : Landin.Source.Source_Id; Node : Syn.Node_Id)
        return Res.Declaration_Id;
      procedure Read_Names
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         State   : Assigned_Set);
      procedure Flow_Block
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Result  : Res.Declaration_Id;
         Owner   : Landin.Provenance.Origin;
         State   : in out Assigned_Set;
         Exits   : out Boolean);
      procedure Require_Assigned
        (At_Source : Landin.Source.Source_Id;
         At_Span   : Landin.Source.Span;
         Id        : Res.Declaration_Id;
         State     : Assigned_Set;
         Message   : String);

      --  Which declaration a declaring node is.  Landin.Resolution
      --  publishes the other direction only, so this is a scan: over a
      --  list that is short, in the order the source decided, and asked
      --  once per function rather than once per node.
      function Declaration_At
        (Src : Landin.Source.Source_Id; Node : Syn.Node_Id)
        return Res.Declaration_Id is
      begin
         for Id in Res.Declaration_Id'(1)
                   .. Res.Declaration_Id
                        (Res.Declaration_Count (Meanings.all))
         loop
            if Res.Source_Of (Meanings.all, Id) = Src
              and then Res.Node_Of (Meanings.all, Id) = Node
            then
               return Id;
            end if;
         end loop;

         return Res.No_Declaration;
      end Declaration_At;

      function Is_Tracked (Id : Res.Declaration_Id) return Boolean is
      begin
         if Id = Res.No_Declaration then
            return False;
         end if;

         case Res.Sort_Of (Meanings.all, Id) is
            when Res.Named_Return =>
               return True;

            when Res.Local_Binding =>
               declare
                  Of_Tree : constant not null access constant Syn.Tree :=
                    Tree_For (Res.Source_Of (Meanings.all, Id));
                  Node : constant Syn.Node_Id :=
                    Res.Node_Of (Meanings.all, Id);
               begin
                  return Syn.Value_Of (Of_Tree.all, Node) = Syn.No_Node;
               end;

            when others =>
               return False;
         end case;
      end Is_Tracked;

      procedure Require_Assigned
        (At_Source : Landin.Source.Source_Id;
         At_Span   : Landin.Source.Span;
         Id        : Res.Declaration_Id;
         State     : Assigned_Set;
         Message   : String) is
      begin
         if not Is_Tracked (Id) or else State (Positive (Id)) then
            return;
         end if;

         declare
            Their_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of (Meanings.all, Id));
            Their_Node : constant Syn.Node_Id :=
              Res.Node_Of (Meanings.all, Id);
         begin
            Bad.Report
              (Item    => Bad.Not_Definitely_Assigned,
               Source  => At_Source,
               Where   => At_Span,
               Message => Message,
               Note    => "[1910]: no condition is believed, so a name"
                          & " assigned in one arm of an `if` and not in"
                          & " another is not assigned after it",
               Related => Landin.Provenance.Origin'
                            (Source => Res.Source_Of (Meanings.all, Id),
                             Where  => Syn.Anchor
                                         (Their_Tree.all, Their_Node)),
               Because => "declared here with no value",
               Into    => Found);
         end;
      end Require_Assigned;

      --  Every read in an expression.  A place an assignment writes is not
      --  a read and is not walked here; `inc` is both and is walked.
      procedure Read_Names
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         State   : Assigned_Set) is
      begin
         if Node = Syn.No_Node then
            return;
         end if;

         if Syn.Kind (Of_Tree, Node) = Syn.Name_Reference then
            if Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound
            then
               Require_Assigned
                 (Syn.Source_Of (Of_Tree), Syn.Where (Of_Tree, Node),
                  Res.Bound_To (Meanings.all, Of_Tree, Node), State,
                  "`" & Spelled (Syn.Name (Of_Tree, Node))
                  & "` is read here and no path that arrives assigned it");
            end if;

            return;
         end if;

         for Position in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
            Read_Names (Of_Tree, Syn.Slot (Of_Tree, Node, Position), State);
         end loop;
      end Read_Names;

      procedure Flow_Block
        (Of_Tree : Syn.Tree;
         Block   : Syn.Node_Id;
         Result  : Res.Declaration_Id;
         Owner   : Landin.Provenance.Origin;
         State   : in out Assigned_Set;
         Exits   : out Boolean)
      is
         procedure Mark (Node : Syn.Node_Id);

         --  A place written is assigned from here on.
         procedure Mark (Node : Syn.Node_Id) is
         begin
            if Node /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Node) = Syn.Name_Reference
              and then Res.Verdict_Of (Meanings.all, Of_Tree, Node)
                       = Res.Bound
            then
               declare
                  Id : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Node);
               begin
                  if Is_Tracked (Id) then
                     State (Positive (Id)) := True;
                  end if;
               end;
            end if;
         end Mark;
      begin
         Exits := False;

         for Index in 1 .. Syn.Statement_Count (Of_Tree, Block) loop
            --  Nothing after an exit is reached, so nothing after one is
            --  asked about.
            exit when Exits;

            declare
               Item : constant Syn.Node_Id :=
                 Syn.Nth_Statement (Of_Tree, Block, Index);
            begin
               case Syn.Kind (Of_Tree, Item) is
                  when Syn.Binding =>
                     --  [0110]: the value is read before the name exists,
                     --  so the read is checked and then the name is
                     --  assigned -- or not, if there is no value.
                     --  A local declared *with* a value is not tracked at
                     --  all, so there is nothing to mark: [1910] is about
                     --  the form [0080] describes, which has none.
                     Read_Names (Of_Tree, Syn.Value_Of (Of_Tree, Item),
                                 State);

                  when Syn.Assignment =>
                     Read_Names (Of_Tree, Syn.Value_Of (Of_Tree, Item),
                                 State);
                     Mark (Syn.Target_Of (Of_Tree, Item));

                  when Syn.Increment | Syn.Decrement =>
                     --  [0400]: `inc x` is `x += 1`, so it reads x too.
                     Read_Names (Of_Tree, Syn.Target_Of (Of_Tree, Item),
                                 State);

                  when Syn.Discard | Syn.Call =>
                     Read_Names (Of_Tree, Item, State);

                  when Syn.Return_Statement =>
                     Read_Names (Of_Tree, Syn.Condition_Of (Of_Tree, Item),
                                 State);
                     Require_Assigned
                       (Syn.Source_Of (Of_Tree),
                        Syn.Anchor (Of_Tree, Item), Result, State,
                        "this returns and no path that arrives assigned"
                        & " the return");

                     --  [1910]: a `return when` is a return, and the flow
                     --  after it is reachable because the guard may be
                     --  false.  A bare one ends the block.
                     if Syn.Condition_Of (Of_Tree, Item) = Syn.No_Node then
                        Exits := True;
                     end if;

                  when Syn.If_Statement =>
                     declare
                        Merged   : Assigned_Set := [others => True];
                        Any_Path : Boolean := False;
                        All_Exit : Boolean := True;
                     begin
                        for Arm in 1 .. Syn.Arm_Count (Of_Tree, Item) loop
                           declare
                              This : constant Syn.Node_Id :=
                                Syn.Nth_Arm (Of_Tree, Item, Arm);
                              Branch : Assigned_Set := State;
                              Left   : Boolean;
                           begin
                              Read_Names
                                (Of_Tree,
                                 Syn.Condition_Of (Of_Tree, This), State);
                              Flow_Block
                                (Of_Tree, Syn.Body_Of (Of_Tree, This),
                                 Result, Owner, Branch, Left);

                              if not Left then
                                 Any_Path := True;
                                 All_Exit := False;

                                 for Which in Tracked loop
                                    Merged (Which) :=
                                      Merged (Which) and Branch (Which);
                                 end loop;
                              end if;
                           end;
                        end loop;

                        if Syn.Else_Body (Of_Tree, Item) /= Syn.No_Node
                        then
                           declare
                              Branch : Assigned_Set := State;
                              Left   : Boolean;
                           begin
                              Flow_Block
                                (Of_Tree, Syn.Else_Body (Of_Tree, Item),
                                 Result, Owner, Branch, Left);

                              if not Left then
                                 Any_Path := True;
                                 All_Exit := False;

                                 for Which in Tracked loop
                                    Merged (Which) :=
                                      Merged (Which) and Branch (Which);
                                 end loop;
                              end if;
                           end;
                        else
                           --  [1910]: no condition is believed, so a
                           --  branch with no `else` has a path that runs
                           --  none of its arms and changes nothing.
                           Any_Path := True;
                           All_Exit := False;

                           for Which in Tracked loop
                              Merged (Which) :=
                                Merged (Which) and State (Which);
                           end loop;
                        end if;

                        if Any_Path then
                           State := Merged;
                        end if;

                        Exits := All_Exit;
                     end;

                  when others =>
                     null;
               end case;
            end;
         end loop;
      end Flow_Block;

   begin
      Landin.Checking.Prepare
        (Types.all, Trees.all, Meanings.all, Spellings.all);

      --  Pass one: every declaration that writes its type down, over every
      --  tree, before any body is read.  [1840]'s module scope is a set and
      --  crosses files, so this cannot wait for the walk that meets it.
      for Id in Res.Declaration_Id'(1)
                .. Res.Declaration_Id (Res.Declaration_Count (Meanings.all))
      loop
         declare
            Written : constant Ty.Type_Kind := Declared_As (Id);
         begin
            if Written /= Ty.Undecided then
               Landin.Checking.Settle (Types.all, Id, Written);
            end if;
         end;
      end loop;

      --  Pass two: [1790]'s `:=` form, in declaration order so a cycle is
      --  reported at the same declaration every time.
      for Id in Res.Declaration_Id'(1)
                .. Res.Declaration_Id (Res.Declaration_Count (Meanings.all))
      loop
         if Landin.Checking.State_Of (Types.all, Id)
            = Landin.Checking.Untouched
         then
            Infer (Id);
         end if;
      end loop;

      --  Pass three: the bodies, one tree at a time in source order.
      for Index in 1 .. Source_Count (Context) loop
         declare
            Of_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Nth_Source (Context, Index));
         begin
            for Position in
              1 .. Syn.Declaration_Count (Of_Tree.all)
            loop
               declare
                  Node : constant Syn.Node_Id :=
                    Syn.Nth_Declaration (Of_Tree.all, Position);
               begin
                  case Syn.Kind (Of_Tree.all, Node) is
                     --  [1795] declares no value, so there is nothing
                     --  here to fold, to assign or to read.  Asking what
                     --  it names settles its type and reports a name that
                     --  is not a type, which is the whole of its check.
                     when Syn.Type_Declaration =>
                        declare
                           Ignored : constant Ty.Type_Kind :=
                             Settled_Type (Declaration_At
                                             (Syn.Source_Of (Of_Tree.all),
                                              Node));
                        begin
                           pragma Assert (Ignored = Ignored);
                        end;

                     when Syn.Binding =>
                        Check_Module_Value (Of_Tree.all, Node);
                        Check_Statement
                          (Of_Tree.all, Node, Ty.Not_Typed);
                        Check_Module_Fold (Of_Tree.all, Node);
                        Check_Operands
                          (Of_Tree.all,
                           Syn.Value_Of (Of_Tree.all, Node),
                           Whole_Fold => True);

                     when Syn.Function_Declaration =>
                        declare
                           Result : constant Syn.Node_Id :=
                             Syn.Return_Of (Of_Tree.all, Node);
                           Gives  : constant Ty.Type_Kind :=
                             (if Result = Syn.No_Node then Ty.No_Value
                              else Declared_As_Node (Of_Tree.all, Result));
                           Runs   : constant Syn.Node_Id :=
                             Syn.Body_Of (Of_Tree.all, Node);
                        begin
                           if Syn.Kind (Of_Tree.all, Runs) = Syn.Block then
                              Check_Block (Of_Tree.all, Runs, Gives);

                              --  [1910], over the same body: at every read,
                              --  at every `return`, and where the body
                              --  ends, the name has to have been assigned
                              --  by every path that arrives there.
                              declare
                                 Result_Id : constant Res.Declaration_Id :=
                                   (if Result = Syn.No_Node
                                    then Res.No_Declaration
                                    else Declaration_At
                                           (Syn.Source_Of (Of_Tree.all),
                                            Result));
                                 State : Assigned_Set := Nothing_Assigned;
                                 Exits : Boolean;
                              begin
                                 Flow_Block
                                   (Of_Tree.all, Runs, Result_Id,
                                    Syn.Origin (Of_Tree.all, Node),
                                    State, Exits);

                                 if not Exits then
                                    Require_Assigned
                                      (Syn.Source_Of (Of_Tree.all),
                                       Syn.Anchor (Of_Tree.all, Node),
                                       Result_Id, State,
                                       "this function can reach its `end`"
                                       & " without assigning the return");
                                 end if;
                              end;
                           else
                              --  [0880]: the expression fills the named
                              --  return, so it has the return's type.
                              Require
                                (Of_Tree.all, Runs, Gives,
                                 (if Result = Syn.No_Node
                                  then Syn.Origin (Of_Tree.all, Node)
                                  else Syn.Origin (Of_Tree.all, Result)),
                                 "the return this fills");
                           end if;

                           --  [1950], after the body is typed, so that an
                           --  operand already refused earns no second
                           --  diagnostic.
                           Check_Operands
                             (Of_Tree.all, Runs, Whole_Fold => False);
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

end Landin.Stages.Checking;
