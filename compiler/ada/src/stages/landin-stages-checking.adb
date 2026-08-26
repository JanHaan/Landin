with Ada.Containers.Ordered_Sets;
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
   use type Landin.Types.Magnitude;
   use type Landin.Checking.Progress;
   use type Landin.Checking.Element_Count;
   use type Res.Verdict;
   use type Res.Declaration_Sort;
   use type Landin.Source.Source_Id;
   use type Landin.Source.Names.Name_Id;

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
        (Of_Tree         : Syn.Tree;
         Node            : Syn.Node_Id;
         For_Declaration : Res.Declaration_Id := Res.No_Declaration;
         In_Local_Scope  : Boolean := False)
         return Ty.Type_Kind;
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
      function Type_At
        (Of_Tree        : Syn.Tree;
         Written        : Syn.Node_Id;
         For_Declaration : Res.Declaration_Id := Res.No_Declaration)
         return Ty.Type_Kind;

      function Type_At
        (Of_Tree        : Syn.Tree;
         Written        : Syn.Node_Id;
         For_Declaration : Res.Declaration_Id := Res.No_Declaration)
         return Ty.Type_Kind is
      begin
         --  [0670]'s block form.  Every field's type is checked here,
         --  because this is the walk that reaches them: a field is a
         --  binding without a value and nothing else visits one.
         if Syn.Kind (Of_Tree, Written) = Syn.Struct_Body then
            declare
               Fields : Landin.Checking.Field_Type_Array
                 (1 .. Syn.Field_Count (Of_Tree, Written)) :=
                   [others => Ty.U8];
               Can_Lay_Out : Boolean := True;
            begin
               for Index in 1 .. Syn.Field_Count (Of_Tree, Written) loop
                  declare
                     Each : constant Syn.Node_Id :=
                       Syn.Nth_Field (Of_Tree, Written, Index);
                     Held : constant Ty.Type_Kind :=
                       Type_At (Of_Tree, Syn.Declared_Type (Of_Tree, Each));
                  begin
                     if Held in Ty.Scalar_Name then
                        Fields (Index) := Held;
                     else
                        Can_Lay_Out := False;
                     end if;

                     --  Every field the kernel cannot lay out is named,
                     --  and not only the struct one: a field it accepted
                     --  silently would leave the struct with no layout
                     --  and the first value of it reaching a defect.
                     if Held = Ty.Aggregate then
                        Bad.Report
                          (Item    => Bad.Unsupported_Use,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Each),
                           Message => "a field of a struct type is not"
                                      & " enabled yet",
                           Refused => Bad.Struct_Value,
                           Into    => Found);
                     elsif Held = Ty.Fixed_Array then
                        Bad.Report
                          (Item    => Bad.Unsupported_Use,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Each),
                           Message => "a field of an array type is not"
                                      & " enabled yet",
                           Refused => Bad.Array_Value,
                           Into    => Found);
                     end if;
                  end;
               end loop;

               if Can_Lay_Out then
                  if For_Declaration = Res.No_Declaration then
                     raise Landin.Compiler_Defect with
                       "a struct body has no declaration identity";
                  end if;

                  Landin.Checking.Lay_Out
                    (Types.all, For_Declaration, Fields, Facts);
               end if;
            end;

            return Ty.Aggregate;
         end if;

         --  array_type ::= "[" integer "]" type              [1790]
         --
         --  D17 makes it structural, so what is recorded is the length and
         --  the element and never where it was written.  An element the
         --  kernel cannot lay out end to end is refused here rather than
         --  in the grammar, which derives `[2][3]u8` on purpose.
         if Syn.Kind (Of_Tree, Written) = Syn.Array_Type then
            declare
               Bound   : constant Syn.Node_Id :=
                 Syn.Bound_Of (Of_Tree, Written);
               Element : constant Syn.Node_Id :=
                 Syn.Element_Of (Of_Tree, Written);
               Held : constant Ty.Type_Kind := Type_At (Of_Tree, Element);
               Length : Landin.Checking.Element_Count := 0;
            begin
               if Held not in Ty.Scalar_Name then
                  if Held /= Ty.Ill_Typed then
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Element),
                        Message => "an array of this is not enabled yet",
                        Refused => Bad.Array_Element,
                        Into    => Found);
                  end if;

                  return Ty.Ill_Typed;
               end if;

               if Syn.Kind (Of_Tree, Bound) /= Syn.Integer_Literal then
                  return Ty.Ill_Typed;
               end if;

               declare
                  Snap : constant Landin.Source.Snapshot :=
                    Source (Context, Syn.Source_Of (Of_Tree));
                  Text : constant String :=
                    Landin.Source.Slice
                      (Snap, Syn.Digit_Span (Of_Tree, Bound));
                  Value      : Ty.Magnitude;
                  Overflowed : Boolean;
               begin
                  Ty.Evaluate
                    (Text, Syn.Base (Of_Tree, Bound), Value, Overflowed);

                  if Overflowed then
                     Bad.Report
                       (Item    => Bad.Literal_Out_Of_Range,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Bound),
                        Message => "this is more elements than an array"
                                   & " may have",
                        Note    => "D18: an array's byte extent must fit the"
                                   & " target's usize",
                        Into    => Found);
                     return Ty.Ill_Typed;
                  end if;

                  declare
                     Element_Bytes : constant Ty.Magnitude :=
                       Ty.Magnitude
                         (Landin.Targets.Bytes
                            (Ty.Storage_Size (Ty.Scalar_Name (Held), Facts)));
                     Maximum_Bytes : constant Ty.Magnitude :=
                       Ty.Magnitude
                         (Landin.Targets.Maximum_Object_Size (Facts));
                  begin
                     if Element_Bytes /= 0
                       and then Value > Maximum_Bytes / Element_Bytes
                     then
                        Bad.Report
                          (Item    => Bad.Literal_Out_Of_Range,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Bound),
                           Message => "this array is larger than the target"
                                      & " can address",
                           Note    => "D18: an array's byte extent must fit"
                                      & " the target's usize",
                           Into    => Found);
                        return Ty.Ill_Typed;
                     end if;
                  end;

                  Length := Landin.Checking.Element_Count (Value);
               end;

               Landin.Checking.Note_Array
                 (Types.all, Of_Tree, Written, Length, Held);
               return Ty.Fixed_Array;
            end;
         end if;

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

            declare
               Held : constant Ty.Type_Kind := Settled_Type (Means);
            begin
               --  [0710]: which aggregate this is, carried from the
               --  declaration that wrote it to every place that names it.
               if Held = Ty.Aggregate then
                  Landin.Checking.Note_Body
                    (Types.all, Of_Tree, Written,
                     Landin.Checking.Body_Of (Types.all, Means));
               end if;

               --  D17: and which array, which is its shape.
               if Held = Ty.Fixed_Array then
                  Landin.Checking.Note_Array
                    (Types.all, Of_Tree, Written,
                     Landin.Checking.Array_Length (Types.all, Means),
                     Landin.Checking.Array_Element (Types.all, Means));
               end if;

               return Held;
            end;
         end;
      end Type_At;

      function Declared_As_Node
        (Of_Tree         : Syn.Tree;
         Node            : Syn.Node_Id;
         For_Declaration : Res.Declaration_Id := Res.No_Declaration;
         In_Local_Scope  : Boolean := False)
         return Ty.Type_Kind
      is
         Written : constant Syn.Node_Id := Syn.Declared_Type (Of_Tree, Node);
      begin
         if Written = Syn.No_Node then
            return Ty.Undecided;
         end if;

         declare
            Held : constant Ty.Type_Kind :=
              Type_At (Of_Tree, Written, For_Declaration);
            --  [1740]'s module binding with no value is the one aggregate
            --  place that needs nothing this kernel cannot emit: D10 makes
            --  it zero, and zeroed storage is what a datum already is.  A
            --  parameter, a return, a local or a written value each need a
            --  rule this slice does not have, so each is still refused.
            --  [1740]'s module state and [1810]'s local binding, each
            --  without a value: D10 zeroes the first and D16 makes every
            --  field of the second assigned before it is read, so neither
            --  needs a value of a struct type to exist.  A parameter, a
            --  return and a written value each need a rule this slice
            --  does not have, so each is still refused.
            Is_Zeroed_State : constant Boolean :=
              Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Syn.Value_Of (Of_Tree, Node) = Syn.No_Node
              --  A name, or an array written where the type belongs.
              --  [0710]'s identity is a declaration, so an anonymous
              --  struct body declares none and cannot be state; D17
              --  makes an array's identity its shape, which `[3]usize`
              --  carries wherever it is written.
              and then Syn.Kind (Of_Tree, Written)
                       in Syn.Type_Reference | Syn.Array_Type;
            --  D21: a local array binding may be initialized directly from
            --  a whole-array storage name.  A module binding of one still
            --  needs no value at all -- D10 zeroes it -- so the caller must
            --  say the scope is local before this admits the initializer.
            --  Every other value form (an array literal, a call, `zeroed`,
            --  a slice, the inferred `:=`) is deferred: none of them is a
            --  Name_Reference.
            Is_Direct_Name_Init : constant Boolean :=
              In_Local_Scope
              and then Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Name_Reference;
         begin
            --  [1795] declares the type; most *values* of one wait for the
            --  rest of R2.20.  A declaration-only module array is zeroed by
            --  D10, a declaration-only local array is frame storage whose
            --  compiler-known elements D19 assigns independently, and D21
            --  admits the one initializer form that copies from a whole-array
            --  storage name.  Parameters, returns and every other written
            --  value each need a rule this slice does not have.
            if Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) /= Syn.Type_Declaration
              and then not Is_Zeroed_State
              and then not Is_Direct_Name_Init
            then
               if Landin.Checking.Type_Of (Types.all, Of_Tree, Written)
                  = Ty.Undecided
               then
                  Landin.Checking.Note
                    (Types.all, Of_Tree, Written, Ty.Ill_Typed);
                  Bad.Report
                    (Item    => Bad.Unsupported_Use,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Node),
                     Message => "a value of an array type is not enabled"
                                & " yet",
                     Refused => Bad.Array_Value,
                     Into    => Found);
               end if;

               return Ty.Ill_Typed;
            end if;

            if Held = Ty.Aggregate
              and then Syn.Kind (Of_Tree, Node) /= Syn.Type_Declaration
              and then not Is_Zeroed_State
            then
               if Landin.Checking.Type_Of (Types.all, Of_Tree, Written)
                  = Ty.Undecided
               then
                  Landin.Checking.Note
                    (Types.all, Of_Tree, Written, Ty.Ill_Typed);
                  Bad.Report
                    (Item    => Bad.Unsupported_Use,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Node),
                     Message => "a value of a struct type is not enabled"
                                & " yet",
                     Refused => Bad.Struct_Value,
                     Into    => Found);
               end if;

               return Ty.Ill_Typed;
            end if;

            return Held;
         end;
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

         declare
            Written : constant Syn.Node_Id :=
              Syn.Declared_Type (Of_Tree.all, Node);
            Is_Body : constant Boolean :=
              Written /= Syn.No_Node
              and then Syn.Kind (Of_Tree.all, Written) = Syn.Struct_Body;
         begin
            --  The identity exists before the body is checked because its
            --  layout is recorded against that identity during the walk.
            if Is_Body then
               Landin.Checking.Note_Body (Types.all, Id, Id);
               Landin.Checking.Note_Body
                 (Types.all, Of_Tree.all, Written, Id);
            end if;

            declare
               --  D21 admits the initializer only for a local binding, so
               --  pass 1's view of a module binding still refuses one:
               --  Sort_Of tells the two apart before Declared_As_Node sees
               --  them.  A Parameter or a Named_Return keeps its former
               --  refusal path because it is a Parameter or Named_Return
               --  node, not a Binding one.
               Local : constant Boolean :=
                 Res.Sort_Of (Meanings.all, Id) = Res.Local_Binding;
               Held : constant Ty.Type_Kind :=
                 Declared_As_Node
                   (Of_Tree.all, Node,
                    (if Is_Body then Id else Res.No_Declaration),
                    In_Local_Scope => Local);
            begin
               --  A declaration that names an existing aggregate is D15's
               --  alias and carries the identity the type position was given.
               if Held = Ty.Aggregate and then not Is_Body then
                  Landin.Checking.Note_Body
                    (Types.all, Id,
                     Landin.Checking.Body_Of
                       (Types.all, Of_Tree.all, Written));
               end if;

               --  D17: an array's identity is its shape, so the
               --  declaration carries the shape the type position was
               --  given -- and an alias of one carries the same shape,
               --  because that is all there is to carry.  A binding of
               --  one carries it for the same reason: what it holds is
               --  the shape and nothing else names it.
               if Held = Ty.Fixed_Array then
                  Landin.Checking.Note_Array
                    (Types.all, Id,
                     Landin.Checking.Array_Length
                       (Types.all, Of_Tree.all, Written),
                     Landin.Checking.Array_Element
                       (Types.all, Of_Tree.all, Written));
               end if;

               return Held;
            end;
         end;
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
               --  A chain came back to where it began.  [1940] says that
               --  for module values; [1795] says an alias has to reach a
               --  type rather than itself.
               declare
                  Of_Tree : constant not null access constant Syn.Tree :=
                    Tree_For (Res.Source_Of (Meanings.all, Id));
                  Node : constant Syn.Node_Id :=
                    Res.Node_Of (Meanings.all, Id);
               begin
                  if Res.Sort_Of (Meanings.all, Id) = Res.Module_Type then
                     Bad.Report
                       (Item    => Bad.Cyclic_Type_Alias,
                        Source  => Res.Source_Of (Meanings.all, Id),
                        Where   => Syn.Anchor (Of_Tree.all, Node),
                        Message => "the type alias `"
                                   & Spelled (Syn.Name (Of_Tree.all, Node))
                                   & "` eventually names itself",
                        Note    => "[1795]: an alias chain has to reach a"
                                   & " scalar or a struct body",
                        Into    => Found);
                  else
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
                  end if;
               end;

               return Ty.Ill_Typed;

            when Landin.Checking.Untouched =>
               if Res.Sort_Of (Meanings.all, Id) = Res.Module_Type then
                  --  A forward type alias reaches here before pass one's
                  --  outer walk reaches the declaration it names.  Settle
                  --  that written type now; Infer is only [1790]'s `:=`
                  --  binding and would ask a type declaration for a value.
                  Landin.Checking.Begin_Inference (Types.all, Id);

                  declare
                     Held : constant Ty.Type_Kind := Declared_As (Id);
                  begin
                     Landin.Checking.Settle (Types.all, Id, Held);
                     return Held;
                  end;
               end if;

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

      --  [1950]'s third row.  An index the compiler knows is refused when
      --  it is outside the length, and one it does not know is left to the
      --  trap the backend emits -- which is what the divisor and the shift
      --  amount already do, in the same paragraph and for the same reason.
      --  Known is [1880]'s: a literal, or a unary minus over one.
      function Is_Known_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;
      function Known_Index_Value
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Value   : out Ty.Magnitude) return Boolean;
      procedure Check_Index_Bound
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         From    : Syn.Node_Id;
         Where   : Syn.Node_Id);

      --  Which field of an aggregate a name selects, by [0750]'s order,
      --  or zero when the aggregate has no field of that name.  The names
      --  are read from the struct body the identity names rather than
      --  kept beside the layout: a field's name is a fact about the
      --  source and Landin.Checking holds what a thing's type is.
      function Field_At
        (Wrote : Res.Declaration_Id;
         Named : Landin.Source.Names.Name_Id) return Natural;

      --  How a field of that struct is spelt, by [0750]'s order.  The
      --  other direction of Field_At, and read from the same body.
      function Field_Named
        (Wrote : Res.Declaration_Id; Index : Positive) return String;

      function Field_At
        (Wrote : Res.Declaration_Id;
         Named : Landin.Source.Names.Name_Id) return Natural
      is
         Of_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Wrote));
         Node : constant Syn.Node_Id := Res.Node_Of (Meanings.all, Wrote);
         Written : constant Syn.Node_Id :=
           Syn.Declared_Type (Of_Tree.all, Node);
      begin
         if Written = Syn.No_Node
           or else Syn.Kind (Of_Tree.all, Written) /= Syn.Struct_Body
         then
            return 0;
         end if;

         for Index in 1 .. Syn.Field_Count (Of_Tree.all, Written) loop
            if Syn.Name
                 (Of_Tree.all,
                  Syn.Nth_Field (Of_Tree.all, Written, Index)) = Named
            then
               return Index;
            end if;
         end loop;

         return 0;
      end Field_At;

      function Field_Named
        (Wrote : Res.Declaration_Id; Index : Positive) return String
      is
         Of_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Wrote));
         Node : constant Syn.Node_Id := Res.Node_Of (Meanings.all, Wrote);
         Written : constant Syn.Node_Id :=
           Syn.Declared_Type (Of_Tree.all, Node);
      begin
         if Written = Syn.No_Node
           or else Syn.Kind (Of_Tree.all, Written) /= Syn.Struct_Body
           or else Index > Syn.Field_Count (Of_Tree.all, Written)
         then
            return "";
         end if;

         return Spelled
                  (Syn.Name
                     (Of_Tree.all,
                      Syn.Nth_Field (Of_Tree.all, Written, Index)));
      end Field_Named;

      --  [1880]'s compiler-known form is deliberately syntactic: a literal
      --  or unary minus over one, independent of later folding.
      function Is_Known_Index
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is (Syn.Kind (Of_Tree, Node) = Syn.Integer_Literal
          or else
            (Syn.Kind (Of_Tree, Node) = Syn.Negation
             and then Syn.Kind
                        (Of_Tree, Syn.Operand_Of (Of_Tree, Node))
                      = Syn.Integer_Literal));

      function Known_Index_Value
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Value   : out Ty.Magnitude) return Boolean
      is
         Negated : constant Boolean :=
           Syn.Kind (Of_Tree, Node) = Syn.Negation;
         Literal : constant Syn.Node_Id :=
           (if Negated then Syn.Operand_Of (Of_Tree, Node) else Node);
         Snap : constant Landin.Source.Snapshot :=
           Source (Context, Syn.Source_Of (Of_Tree));
         Overflowed : Boolean;
      begin
         if not Is_Known_Index (Of_Tree, Node) then
            Value := 0;
            return False;
         end if;

         Ty.Evaluate
           (Landin.Source.Slice
              (Snap, Syn.Digit_Span (Of_Tree, Literal)),
            Syn.Base (Of_Tree, Literal), Value, Overflowed);
         return not Overflowed and then (not Negated or else Value = 0);
      end Known_Index_Value;

      procedure Check_Index_Bound
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         From    : Syn.Node_Id;
         Where   : Syn.Node_Id)
      is
         Length : constant Landin.Checking.Element_Count :=
           Landin.Checking.Array_Length (Types.all, Of_Tree, From);
         Negated : constant Boolean :=
           Syn.Kind (Of_Tree, Where) = Syn.Negation;
         Literal : constant Syn.Node_Id :=
           (if Negated then Syn.Operand_Of (Of_Tree, Where) else Where);
      begin
         if Syn.Kind (Of_Tree, Literal) /= Syn.Integer_Literal then
            --  [1950] leaves this one to the runtime bounds check.  It is
            --  not folded here: [1880]'s known line stays a literal or a
            --  unary minus over one, independent of compiler cleverness.
            return;
         end if;

         declare
            Snap : constant Landin.Source.Snapshot :=
              Source (Context, Syn.Source_Of (Of_Tree));
            Text : constant String :=
              Landin.Source.Slice (Snap, Syn.Digit_Span (Of_Tree, Literal));
            Value      : Ty.Magnitude;
            Overflowed : Boolean;
         begin
            Ty.Evaluate
              (Text, Syn.Base (Of_Tree, Literal), Value, Overflowed);

            --  D18's `usize` context has already refused every negative
            --  value.  `-0` survives because its value is zero, which an
            --  array with any element at all has.
            if not Overflowed
              and then (not Negated or else Value = 0)
              and then Value < Ty.Magnitude (Length)
            then
               return;
            end if;

            Bad.Report
              (Item    => Bad.Impossible_Operand,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Where),
               Message => "this index is outside the "
                          & Written (Ty.Folded (Length))
                          & " this array has",
               Note    => "[1950]: an index the compiler knows is refused"
                          & " where it cannot be taken, and one it does"
                          & " not know traps",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Node);
         end;
      end Check_Index_Bound;

      --  The type of a place, and of what a selection selects from.
      --  Separate from Synthesise because a bare aggregate name is a
      --  value this kernel refuses in an expression, while the same name
      --  is how a field is reached and how a whole struct is copied.
      function Selected_From
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind;

      function Selected_From
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind is
      begin
         if Syn.Kind (Of_Tree, Node) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound
         then
            declare
               Means : constant Res.Declaration_Id :=
                 Res.Bound_To (Meanings.all, Of_Tree, Node);
               Held  : constant Ty.Type_Kind := Settled_Type (Means);
            begin
               if Held = Ty.Aggregate then
                  if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                     = Ty.Undecided
                  then
                     Landin.Checking.Note
                       (Types.all, Of_Tree, Node, Held);
                     Landin.Checking.Note_Body
                       (Types.all, Of_Tree, Node,
                        Landin.Checking.Body_Of (Types.all, Means));
                  end if;

                  return Held;
               end if;

               --  D17: an array's identity is its shape, so a name that
               --  holds one carries the shape to wherever it is indexed.
               if Held = Ty.Fixed_Array then
                  if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                     = Ty.Undecided
                  then
                     Landin.Checking.Note
                       (Types.all, Of_Tree, Node, Held);
                     Landin.Checking.Note_Array
                       (Types.all, Of_Tree, Node,
                        Landin.Checking.Array_Length (Types.all, Means),
                        Landin.Checking.Array_Element (Types.all, Means));
                  end if;

                  return Held;
               end if;
            end;
         end if;

         return Synthesise (Of_Tree, Node);
      end Selected_From;

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
                  --  D14 and D17: legality follows the resolved checked
                  --  type, not the syntax that happened to spell it.  Type_At
                  --  also carries an array's structural shape onto this node,
                  --  including through a chain of aliases.
                  declare
                     Held : constant Ty.Type_Kind := Type_At (Of_Tree, Asked);
                  begin
                     if Landin.Checking.Type_Of
                          (Types.all, Of_Tree, Asked) = Ty.Undecided
                     then
                        Landin.Checking.Note
                          (Types.all, Of_Tree, Asked, Held);
                     end if;

                     if Held in Ty.Scalar_Name or else Held = Ty.Fixed_Array
                     then
                        return Kept (Ty.Usize);
                     end if;

                     --  An unresolved or malformed type was already named by
                     --  its owning stage.  In particular, do not add a second
                     --  measurement report for it.
                     if Held = Ty.Ill_Typed then
                        return Kept (Ty.Ill_Typed);
                     end if;

                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Asked),
                        Message => "measuring this is not enabled yet",
                        Refused => Bad.Measured_Type,
                        Into    => Found);
                     return Kept (Ty.Ill_Typed);
                  end;
               end;

            --  [0370]: the length belongs to the fixed-array type, not to
            --  its storage.  Selected_From carries a named array's shape
            --  without treating the whole array as a value read.
            when Syn.Len_Of =>
               declare
                  Asked : constant Syn.Node_Id :=
                    Syn.Operand_Of (Of_Tree, Node);
                  Held  : constant Ty.Type_Kind :=
                    Selected_From (Of_Tree, Asked);
               begin
                  if Held = Ty.Ill_Typed then
                     --  In particular, an unresolved name was already
                     --  reported by resolution and remains resolution-owned.
                     return Kept (Ty.Ill_Typed);
                  end if;

                  if Held /= Ty.Fixed_Array then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Asked),
                        Message => "this is not a fixed array, so it has no"
                                   & " array length",
                        Note    => "[0370]: this kernel's `lenof` measures a"
                                   & " named fixed array",
                        Related => Syn.Origin (Of_Tree, Asked),
                        Because => "what it names",
                        Into    => Found);
                     return Kept (Ty.Ill_Typed);
                  end if;

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

                  --  [1740]'s state of [0670]'s type is storage a program
                  --  may declare and not yet reach: reading the whole of
                  --  one is a value, and carrying one waits for the rest
                  --  of R2.20 exactly as a binding of one does.
                  if Held = Ty.Aggregate then
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Node),
                        Message => "`" & Spelled (Syn.Name (Of_Tree, Node))
                                   & "` names a struct, and a value of one"
                                   & " is not enabled yet",
                        Refused => Bad.Struct_Value,
                        Into    => Found);
                     return Kept (Ty.Ill_Typed);
                  end if;

                  if Held = Ty.Fixed_Array then
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Node),
                        Message => "`" & Spelled (Syn.Name (Of_Tree, Node))
                                   & "` names an array, and a value of one"
                                   & " is not enabled yet",
                        Refused => Bad.Array_Value,
                        Into    => Found);
                     return Kept (Ty.Ill_Typed);
                  end if;

                  return Kept (Held);
               end;

            when Syn.Element_Index =>
               declare
                  From : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
                  Where : constant Syn.Node_Id := Syn.Index_Of (Of_Tree, Node);
                  Held : constant Ty.Type_Kind :=
                    Selected_From (Of_Tree, From);
               begin
                  if Held = Ty.Ill_Typed then
                     return Kept (Ty.Ill_Typed);
                  end if;

                  --  [1820] indexes an array, and the kernel has one kind
                  --  of indexable thing: [0570]'s slice is not enabled and
                  --  [0610]'s text is not either.
                  if Held /= Ty.Fixed_Array then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, From),
                        Message => "this is not an array, so it has no"
                                   & " element to index",
                        Note    => "[1820]: the kernel indexes an array"
                                   & " [0520] and nothing else",
                        Related => Syn.Origin (Of_Tree, From),
                        Because => "what it names",
                        Into    => Found);
                     return Kept (Ty.Ill_Typed);
                  end if;

                  --  D18: the index is exactly `usize`; accepting every
                  --  integer here would be an implicit conversion.  An
                  --  untyped literal receives that context rather than
                  --  [0200]'s context-free default.
                  declare
                     Got : constant Ty.Type_Kind :=
                       Synthesise (Of_Tree, Where);
                  begin
                     if Got = Ty.Untyped_Integer then
                        Commit_To (Of_Tree, Where, Ty.Usize);
                     elsif Decidable (Got) and then Got /= Ty.Usize then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Where),
                           Message => "this indexes with " & Shown (Got)
                                      & ", and an index is a usize",
                           Note    => "D18: indexing accepts exactly usize"
                                      & " and performs no implicit conversion",
                           Related => Syn.Origin (Of_Tree, From),
                           Because => "the array indexed here",
                           Into    => Found);
                        return Kept (Ty.Ill_Typed);
                     end if;
                  end;

                  if Landin.Checking.Type_Of (Types.all, Of_Tree, Where)
                       = Ty.Ill_Typed
                    or else
                      (Syn.Kind (Of_Tree, Where) = Syn.Negation
                       and then Landin.Checking.Type_Of
                                  (Types.all, Of_Tree,
                                   Syn.Operand_Of (Of_Tree, Where))
                                  = Ty.Ill_Typed)
                  then
                     return Kept (Ty.Ill_Typed);
                  end if;

                  Check_Index_Bound (Of_Tree, Node, From, Where);
                  if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                       = Ty.Ill_Typed
                  then
                     return Kept (Ty.Ill_Typed);
                  end if;

                  --  D19 gives a local array one definite-assignment fact per
                  --  compiler-known element.  D22 leaves the read of a
                  --  computed local element to the flow walk below, which
                  --  requires the whole-array fact D20 records; a computed
                  --  write is a place operation and establishes no element
                  --  fact of its own.  Module arrays keep D10's complete
                  --  state and their runtime-index path is unchanged.
                  return Kept
                    (Landin.Checking.Array_Element
                       (Types.all, Of_Tree, From));
               end;

            when Syn.Member_Selection =>
               declare
                  From : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
                  Held : constant Ty.Type_Kind :=
                    Selected_From (Of_Tree, From);
               begin
                  if Held = Ty.Ill_Typed then
                     return Kept (Ty.Ill_Typed);
                  end if;

                  --  [0420] names four kinds of member and [1820] enables
                  --  one, so anything but a struct to the left of the dot
                  --  is a selection this kernel cannot make.
                  if Held /= Ty.Aggregate then
                     declare
                        Means : constant Res.Declaration_Id :=
                          (if Syn.Kind (Of_Tree, From) = Syn.Name_Reference
                             and then Res.Verdict_Of
                                        (Meanings.all, Of_Tree, From)
                                      = Res.Bound
                           then Res.Bound_To (Meanings.all, Of_Tree, From)
                           else Res.No_Declaration);
                     begin
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, From),
                           Message => "this is not a struct, so it has no"
                                      & " field to select",
                           Note    => "[1820]: the kernel selects a field"
                                      & " of a struct [0670] and nothing"
                                      & " else",
                           Related =>
                             (if Means = Res.No_Declaration
                              then Syn.Origin (Of_Tree, From)
                              else Syn.Origin
                                     (Tree_For
                                        (Res.Source_Of
                                           (Meanings.all, Means)).all,
                                      Res.Node_Of (Meanings.all, Means))),
                           Because => "what it names",
                           Into    => Found);
                     end;

                     return Kept (Ty.Ill_Typed);
                  end if;

                  declare
                     Wrote : constant Res.Declaration_Id :=
                       Landin.Checking.Body_Of (Types.all, Of_Tree, From);
                     Which : constant Natural :=
                       (if Wrote = Res.No_Declaration then 0
                        else Field_At (Wrote, Syn.Name (Of_Tree, Node)));
                  begin
                     if Which = 0 then
                        Bad.Report
                          (Item    => Bad.Unresolved_Field,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Anchor (Of_Tree, Node),
                           Message => "this struct has no field called `"
                                      & Spelled (Syn.Name (Of_Tree, Node))
                                      & "`",
                           Note    => "[0750]: a struct has the fields it"
                                      & " was declared with, and no others",
                           Into    => Found);
                        return Kept (Ty.Ill_Typed);
                     end if;

                     --  A struct one of whose fields was refused has no
                     --  layout, so it has no field types either.  The
                     --  refusal already named the field that stopped it,
                     --  and a second report about a field that is fine
                     --  would send a reader to the wrong line.
                     if not Landin.Checking.Has_Layout (Types.all, Wrote)
                     then
                        return Kept (Ty.Ill_Typed);
                     end if;

                     Landin.Checking.Note_Field
                       (Types.all, Of_Tree, Node, Which);
                     return Kept
                       (Landin.Checking.Field_Type
                          (Types.all, Wrote, Which));
                  end;
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

         --  What a place is a place *in*.  A field and an element are
         --  written exactly as the binding holding them is [1810], so
         --  which binding that is is the question [1900] answers about,
         --  and it is the name at the left of however many dots and
         --  brackets were written.
         Base : Syn.Node_Id := Node;
      begin
         while Syn.Kind (Of_Tree, Base)
               in Syn.Member_Selection | Syn.Element_Index
         loop
            Base := Syn.Target_Of (Of_Tree, Base);
         end loop;

         if Res.Verdict_Of (Meanings.all, Of_Tree, Base) /= Res.Bound then
            return;
         end if;

         declare
            Means : constant Res.Declaration_Id :=
              Res.Bound_To (Meanings.all, Of_Tree, Base);
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
                    "`" & Spelled (Syn.Name (Of_Tree, Base)) & "` "
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
               Landin.Checking.Refuse (Types.all, Of_Tree, Base);

               if Base /= Node then
                  Landin.Checking.Refuse (Types.all, Of_Tree, Node);
               end if;

               return;
            end if;

            Held := Selected_From (Of_Tree, Node);

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
                  --  D21: a body's binding is always a local, so this is
                  --  where the initializer form is admitted.  Declared_As
                  --  passes False for a module binding.
                  Wants : constant Ty.Type_Kind :=
                    Declared_As_Node
                      (Of_Tree, Node, In_Local_Scope => True);
               begin
                  if Value = Syn.No_Node or else Wants = Ty.Ill_Typed then
                     --  The declaration has already explained why this value
                     --  form is refused; checking the initializer as another
                     --  whole-array value would only repeat L0304.
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
                  elsif Wants = Ty.Fixed_Array then
                     --  D21: the one initializer form is a whole-array copy
                     --  from a storage name, so the identity check is D17's
                     --  as an assignment's is.  The Selected_From short-cut
                     --  keeps a Name_Reference to an array from tripping the
                     --  "not enabled yet" refusal Synthesise raises for the
                     --  general expression forms this slice defers.
                     declare
                        Written : constant Syn.Node_Id :=
                          Syn.Declared_Type (Of_Tree, Node);
                        Got : constant Ty.Type_Kind :=
                          Selected_From (Of_Tree, Value);
                     begin
                        if Got = Ty.Ill_Typed then
                           null;
                        elsif Got /= Ty.Fixed_Array
                          or else Landin.Checking.Array_Length
                                    (Types.all, Of_Tree, Value)
                                  /= Landin.Checking.Array_Length
                                       (Types.all, Of_Tree, Written)
                          or else Landin.Checking.Array_Element
                                    (Types.all, Of_Tree, Value)
                                  /= Landin.Checking.Array_Element
                                       (Types.all, Of_Tree, Written)
                        then
                           Bad.Report
                             (Item    => Bad.Type_Mismatch,
                              Source  => Syn.Source_Of (Of_Tree),
                              Where   => Syn.Where (Of_Tree, Value),
                              Message => "this is not an array of the type"
                                         & " written here",
                              Note    => "D17: an array's length and element"
                                         & " type are its identity",
                              Related => Syn.Origin (Of_Tree, Node),
                              Because => "the type declared here",
                              Into    => Found);
                           Landin.Checking.Refuse
                             (Types.all, Of_Tree, Value);
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

               --  The place has already explained why no assignment can be
               --  made.  Do not compare stale aggregate shape metadata and
               --  add a type mismatch to the mutability report.
               if Landin.Checking.Type_Of
                    (Types.all, Of_Tree, Syn.Target_Of (Of_Tree, Node))
                    = Ty.Ill_Typed
               then
                  return;
               end if;

               declare
                  Place : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
                  Value : constant Syn.Node_Id :=
                    Syn.Value_Of (Of_Tree, Node);
                  Wants : constant Ty.Type_Kind :=
                    Selected_From (Of_Tree, Place);
               begin
                  --  [0710]: a whole struct is copied into a place of the
                  --  same type, and two are the same type exactly when one
                  --  declaration wrote both.  A copy is the one expression
                  --  position a struct may stand in, because the bytes go
                  --  straight from one place to another and nothing has to
                  --  carry them anywhere.
                  if Wants = Ty.Aggregate then
                     declare
                        Got : constant Ty.Type_Kind :=
                          Selected_From (Of_Tree, Value);
                     begin
                        if Got = Ty.Ill_Typed then
                           null;
                        elsif Got /= Ty.Aggregate
                          or else Landin.Checking.Body_Of
                                    (Types.all, Of_Tree, Place)
                                  /= Landin.Checking.Body_Of
                                       (Types.all, Of_Tree, Value)
                        then
                           Bad.Report
                             (Item    => Bad.Type_Mismatch,
                              Source  => Syn.Source_Of (Of_Tree),
                              Where   => Syn.Where (Of_Tree, Value),
                              Message => "this is not a value of the"
                                         & " struct type written here",
                              Note    => "[0710]: two structs are one type"
                                         & " when one declaration wrote"
                                         & " both, and never otherwise",
                              Related => Syn.Origin (Of_Tree, Place),
                              Because => "the place written here",
                              Into    => Found);
                           Landin.Checking.Refuse
                             (Types.all, Of_Tree, Value);
                        end if;
                     end;

                     return;
                  end if;

                  --  D20: an array copy also moves straight from one storage
                  --  place to another.  D17 makes its length and element type
                  --  its identity; no general array value is enabled by this
                  --  one expression position.
                  if Wants = Ty.Fixed_Array then
                     declare
                        Got : constant Ty.Type_Kind :=
                          Selected_From (Of_Tree, Value);
                     begin
                        if Got = Ty.Ill_Typed then
                           null;
                        elsif Got /= Ty.Fixed_Array
                          or else Landin.Checking.Array_Length
                                    (Types.all, Of_Tree, Place)
                                  /= Landin.Checking.Array_Length
                                       (Types.all, Of_Tree, Value)
                          or else Landin.Checking.Array_Element
                                    (Types.all, Of_Tree, Place)
                                  /= Landin.Checking.Array_Element
                                       (Types.all, Of_Tree, Value)
                        then
                           Bad.Report
                             (Item    => Bad.Type_Mismatch,
                              Source  => Syn.Source_Of (Of_Tree),
                              Where   => Syn.Where (Of_Tree, Value),
                              Message => "this is not an array of the type"
                                         & " written here",
                              Note    => "D17: an array's length and element"
                                         & " type are its identity",
                              Related => Syn.Origin (Of_Tree, Place),
                              Because => "the place written here",
                              Into    => Found);
                           Landin.Checking.Refuse
                             (Types.all, Of_Tree, Value);
                        end if;
                     end;

                     return;
                  end if;

                  Require
                    (Of_Tree, Value, Wants, Syn.Origin (Of_Tree, Place),
                     "the place written here");
               end;

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

      --  The widest struct the program writes, which is how many field
      --  bits a row of the set below needs.  Read from the trees rather
      --  than from the layouts, because this sizes a type and so is
      --  elaborated before the pass that lays anything out; a struct body
      --  is [0750]'s field list either way.
      function Widest_Struct return Natural;

      function Widest_Struct return Natural is
         Most : Natural := 0;
      begin
         for Index in 1 .. Source_Count (Context) loop
            declare
               Of_Tree : constant not null access constant Syn.Tree :=
                 Tree_For (Nth_Source (Context, Index));
            begin
               for Node in Syn.Node_Id'(1)
                           .. Syn.Node_Id (Syn.Node_Count (Of_Tree.all))
               loop
                  if Syn.Kind (Of_Tree.all, Node) = Syn.Struct_Body then
                     Most :=
                       Natural'Max
                         (Most, Syn.Field_Count (Of_Tree.all, Node));
                  end if;
               end loop;
            end;
         end loop;

         return Most;
      end Widest_Struct;

      --  One Boolean per declaration, copied at a branch and merged after
      --  it.  A set and not a counter, because [1910] is about paths: a
      --  name assigned in one arm and not another is not assigned after
      --  the branch, and nothing but the per-declaration answer says that.
      --
      --  D16 makes a field of a struct local its own answer, so a row is
      --  the name at column zero and its fields at the columns after it.
      --  A scalar uses column zero alone; a struct never uses it, because
      --  a value of one is not a thing this kernel can read.
      subtype Tracked is Positive range
        1 .. Positive'Max (1, Res.Declaration_Count (Meanings.all));

      subtype Tracked_Field is Natural range 0 .. Widest_Struct;

      type Assigned_Fields is array (Tracked, Tracked_Field) of Boolean;

      type Element_Fact is record
         Declaration : Res.Declaration_Id;
         Position    : Ty.Magnitude;
      end record;

      function "<" (Left, Right : Element_Fact) return Boolean
      is (Left.Declaration < Right.Declaration
          or else
            (Left.Declaration = Right.Declaration
             and then Left.Position < Right.Position));

      package Element_Sets is new Ada.Containers.Ordered_Sets
        (Element_Type => Element_Fact);

      package Declaration_Sets is new Ada.Containers.Ordered_Sets
        (Element_Type => Res.Declaration_Id);

      type Assigned_Set is record
         Fields      : Assigned_Fields := [others => [others => False]];
         Elements    : Element_Sets.Set;
         Whole_Arrays : Declaration_Sets.Set;
      end record;

      Nothing_Assigned : constant Assigned_Set :=
        (Fields       => [others => [others => False]],
         Elements     => Element_Sets.Empty_Set,
         Whole_Arrays => Declaration_Sets.Empty_Set);

      --  Which declarations [1910] is about.  A parameter arrives assigned
      --  and a module binding is [1940]'s, so what is left is a local
      --  declared with no value and the named return.
      function Is_Tracked (Id : Res.Declaration_Id) return Boolean;
      function Declaration_At
        (Src : Landin.Source.Source_Id; Node : Syn.Node_Id)
        return Res.Declaration_Id;
      --  Whether the whole-array read is a D20 assignment source or a D21
      --  binding initializer.  Only Require_Array threads through, since
      --  every other whole-name read (a discard, an `inc`) is neither.
      type Whole_Array_Read is (Assignment_Source, Initializer_Source);
      procedure Read_Names
        (Of_Tree  : Syn.Tree;
         Node     : Syn.Node_Id;
         State    : Assigned_Set;
         Whole_As : Whole_Array_Read := Assignment_Source);
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
         Message   : String;
         Field     : Tracked_Field := 0);
      procedure Require_Element
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : Res.Declaration_Id;
         Position : Ty.Magnitude;
         State   : Assigned_Set);
      procedure Require_Computed_Element
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : Res.Declaration_Id;
         State   : Assigned_Set);
      function Array_Is_Assigned
        (Id : Res.Declaration_Id; State : Assigned_Set) return Boolean;
      procedure Require_Array
        (Of_Tree  : Syn.Tree;
         Node     : Syn.Node_Id;
         Id       : Res.Declaration_Id;
         State    : Assigned_Set;
         Whole_As : Whole_Array_Read := Assignment_Source);

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
         Message   : String;
         Field     : Tracked_Field := 0) is
      begin
         --  D16 assigns a struct a field at a time, so reading the whole
         --  of one wants every field: the first one no path assigned is
         --  the one to name, because a reader fixes them one at a time.
         if Field = 0
           and then Is_Tracked (Id)
           and then Landin.Checking.Has_Layout (Types.all, Id)
         then
            for Each in
              1 .. Landin.Checking.Layout_Field_Count (Types.all, Id)
            loop
               if Each in 1 .. Widest_Struct
                 and then not State.Fields (Positive (Id), Each)
               then
                  Require_Assigned
                    (At_Source, At_Span, Id, State,
                     "the whole of `"
                     & Spelled (Res.Name_Of (Meanings.all, Id))
                     & "` is read here and no path that arrives assigned"
                     & " its `"
                     & Field_Named
                         (Landin.Checking.Body_Of (Types.all, Id), Each)
                     & "`",
                     Each);
                  return;
               end if;
            end loop;

            return;
         end if;

         if not Is_Tracked (Id)
           or else State.Fields (Positive (Id), Field)
         then
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

      function Array_Is_Assigned
        (Id : Res.Declaration_Id; State : Assigned_Set) return Boolean
      is
         Assigned : Landin.Checking.Element_Count := 0;
      begin
         if not Is_Tracked (Id)
           or else Declaration_Sets.Contains (State.Whole_Arrays, Id)
           or else Landin.Checking.Array_Length (Types.all, Id) = 0
         then
            return True;
         end if;

         --  D20: completeness is a count over the sparse facts that exist,
         --  never a walk over an array whose D18 length may fill the target.
         for Fact of State.Elements loop
            if Fact.Declaration = Id then
               Assigned := Assigned + 1;
            end if;
         end loop;

         return Assigned = Landin.Checking.Array_Length (Types.all, Id);
      end Array_Is_Assigned;

      procedure Require_Array
        (Of_Tree  : Syn.Tree;
         Node     : Syn.Node_Id;
         Id       : Res.Declaration_Id;
         State    : Assigned_Set;
         Whole_As : Whole_Array_Read := Assignment_Source) is
      begin
         if Array_Is_Assigned (Id, State) then
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
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "the whole of `"
                          & Spelled (Res.Name_Of (Meanings.all, Id))
                          & "` is read here and no path that arrives assigned"
                          & " every element",
               Note    =>
                 (case Whole_As is
                     when Assignment_Source =>
                       "D20: copying a local array reads every element",
                     when Initializer_Source =>
                       "D21: a local array initializer reads every element"
                       & " of its source"),
               Related => Landin.Provenance.Origin'
                            (Source => Res.Source_Of (Meanings.all, Id),
                             Where  => Syn.Anchor
                                         (Their_Tree.all, Their_Node)),
               Because => "declared here with no value",
               Into    => Found);
         end;
      end Require_Array;

      procedure Require_Computed_Element
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Id      : Res.Declaration_Id;
         State   : Assigned_Set) is
      begin
         --  D22: a computed local index cannot be covered by D19's sparse
         --  facts, so the array must be assigned as a whole -- either by
         --  D20's copy or by D21's initializer, or by having as many sparse
         --  D19 facts as the array's declared length.  Only the local
         --  declared without a value is tracked; a parameter and a module
         --  binding fall through here as not tracked, and no tracked
         --  entity of an array type is anything else this kernel admits.
         if not Is_Tracked (Id)
           or else Array_Is_Assigned (Id, State)
         then
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
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "`" & Spelled (Res.Name_Of (Meanings.all, Id))
                          & "` is read at a computed index and no path"
                          & " that arrives assigned it as a whole",
               Note    => "D22: a computed local array read requires the"
                          & " whole-array fact, because D19's element facts"
                          & " are compiler-known positions",
               Related => Landin.Provenance.Origin'
                            (Source => Res.Source_Of (Meanings.all, Id),
                             Where  => Syn.Anchor
                                         (Their_Tree.all, Their_Node)),
               Because => "declared here with no value",
               Into    => Found);
         end;
      end Require_Computed_Element;

      procedure Require_Element
        (Of_Tree  : Syn.Tree;
         Node     : Syn.Node_Id;
         Id       : Res.Declaration_Id;
         Position : Ty.Magnitude;
         State    : Assigned_Set) is
      begin
         if not Is_Tracked (Id)
           or else Declaration_Sets.Contains (State.Whole_Arrays, Id)
           or else Element_Sets.Contains
                     (State.Elements, (Id, Position))
         then
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
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Node),
               Message => "`" & Spelled (Res.Name_Of (Meanings.all, Id))
                          & "[" & Written (Ty.Folded (Position))
                          & "]` is read here and no path that arrives"
                          & " assigned it",
               Note    => "D19: compiler-known elements of a local array"
                          & " are assigned independently",
               Related => Landin.Provenance.Origin'
                            (Source => Res.Source_Of (Meanings.all, Id),
                             Where  => Syn.Anchor
                                         (Their_Tree.all, Their_Node)),
               Because => "declared here with no value",
               Into    => Found);
         end;
      end Require_Element;

      --  Every read in an expression.  A place an assignment writes is not
      --  a read and is not walked here; `inc` is both and is walked.
      procedure Read_Names
        (Of_Tree  : Syn.Tree;
         Node     : Syn.Node_Id;
         State    : Assigned_Set;
         Whole_As : Whole_Array_Read := Assignment_Source) is
      begin
         if Node = Syn.No_Node then
            return;
         end if;

         --  D19: reaching a known element is not a read of the whole array.
         --  D22: reaching a computed element of a tracked local *does*
         --  require the whole-array fact, because element facts are D19's
         --  compiler-known ones and no sparse fact covers a runtime index.
         --  The index is still an expression and is read first.  A refused
         --  or out-of-bounds selection establishes no additional diagnostic.
         if Syn.Kind (Of_Tree, Node) = Syn.Element_Index then
            declare
               From  : constant Syn.Node_Id :=
                 Syn.Target_Of (Of_Tree, Node);
               Where : constant Syn.Node_Id := Syn.Index_Of (Of_Tree, Node);
               Position : Ty.Magnitude;
            begin
               Read_Names (Of_Tree, Where, State);
               if Syn.Kind (Of_Tree, From) = Syn.Name_Reference
                 and then Res.Verdict_Of (Meanings.all, Of_Tree, From)
                          = Res.Bound
                 and then Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                          /= Ty.Ill_Typed
               then
                  if Known_Index_Value (Of_Tree, Where, Position) then
                     Require_Element
                       (Of_Tree, Node,
                        Res.Bound_To (Meanings.all, Of_Tree, From),
                        Position, State);
                  else
                     Require_Computed_Element
                       (Of_Tree, Node,
                        Res.Bound_To (Meanings.all, Of_Tree, From),
                        State);
                  end if;
               elsif Syn.Kind (Of_Tree, From) /= Syn.Name_Reference then
                  Read_Names (Of_Tree, From, State);
               end if;
            end;

            return;
         end if;

         --  `lenof name` asks the name's fixed-array type for a constant;
         --  it neither reads nor reaches the array's storage.
         if Syn.Kind (Of_Tree, Node) = Syn.Len_Of then
            return;
         end if;

         if Syn.Kind (Of_Tree, Node) = Syn.Name_Reference then
            if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                 /= Ty.Ill_Typed
              and then Res.Verdict_Of (Meanings.all, Of_Tree, Node)
                         = Res.Bound
            then
               declare
                  Id : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Node);
               begin
                  if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                       = Ty.Fixed_Array
                  then
                     Require_Array (Of_Tree, Node, Id, State, Whole_As);
                  else
                     Require_Assigned
                       (Syn.Source_Of (Of_Tree), Syn.Where (Of_Tree, Node),
                        Id, State,
                        "`" & Spelled (Syn.Name (Of_Tree, Node))
                        & "` is read here and no path that arrives assigned"
                        & " it");
                  end if;
               end;
            end if;

            return;
         end if;

         --  D16: a field is assigned on its own, so reading one asks
         --  about that field and not about the name it is selected from.
         --  Reaching the field is not a read of the whole struct, which
         --  is why this does not walk into the base.
         if Syn.Kind (Of_Tree, Node) = Syn.Member_Selection then
            declare
               From : constant Syn.Node_Id := Syn.Target_Of (Of_Tree, Node);
               Which : constant Natural :=
                 Landin.Checking.Field_Index (Types.all, Of_Tree, Node);
            begin
               if Which in 1 .. Widest_Struct
                 and then Syn.Kind (Of_Tree, From) = Syn.Name_Reference
                 and then Res.Verdict_Of (Meanings.all, Of_Tree, From)
                          = Res.Bound
               then
                  Require_Assigned
                    (Syn.Source_Of (Of_Tree), Syn.Where (Of_Tree, Node),
                     Res.Bound_To (Meanings.all, Of_Tree, From), State,
                     "`" & Spelled (Syn.Name (Of_Tree, From)) & "."
                     & Spelled (Syn.Name (Of_Tree, Node))
                     & "` is read here and no path that arrives assigned"
                     & " it",
                     Field => Which);
               else
                  Read_Names (Of_Tree, From, State);
               end if;
            end;

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
         procedure Merge
           (Into   : in out Assigned_Set;
            First  : Boolean;
            Branch : Assigned_Set);

         procedure Merge
           (Into   : in out Assigned_Set;
            First  : Boolean;
            Branch : Assigned_Set) is
         begin
            if First then
               Into := Branch;
               return;
            end if;

            declare
               Left   : constant Assigned_Set := Into;
               Merged : Assigned_Set :=
                 (Fields       => Left.Fields,
                  Elements     => Element_Sets.Intersection
                                    (Left.Elements, Branch.Elements),
                  Whole_Arrays => Declaration_Sets.Intersection
                                    (Left.Whole_Arrays,
                                     Branch.Whole_Arrays));
            begin
               for Which in Tracked loop
                  for Part in Tracked_Field loop
                     Merged.Fields (Which, Part) :=
                       Left.Fields (Which, Part)
                       and Branch.Fields (Which, Part);
                  end loop;
               end loop;

               --  D20 gives a whole-array fact the meaning of every sparse
               --  element fact.  Intersecting whole with sparse therefore
               --  keeps the sparse side; intersecting two sparse states is
               --  the ordinary set intersection above.
               for Which in Tracked loop
                  declare
                     Id : constant Res.Declaration_Id :=
                       Res.Declaration_Id (Which);
                     Left_Whole : constant Boolean :=
                       Declaration_Sets.Contains (Left.Whole_Arrays, Id);
                     Right_Whole : constant Boolean :=
                       Declaration_Sets.Contains
                         (Branch.Whole_Arrays, Id);
                  begin
                     if Left_Whole and then not Right_Whole then
                        for Fact of Branch.Elements loop
                           if Fact.Declaration = Id then
                              Element_Sets.Include (Merged.Elements, Fact);
                           end if;
                        end loop;
                     elsif Right_Whole and then not Left_Whole then
                        for Fact of Left.Elements loop
                           if Fact.Declaration = Id then
                              Element_Sets.Include (Merged.Elements, Fact);
                           end if;
                        end loop;
                     end if;
                  end;
               end loop;

               Into := Merged;
            end;
         end Merge;

         --  A place written is assigned from here on.
         procedure Mark (Node : Syn.Node_Id) is
         begin
            if Node /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Node) = Syn.Element_Index
            then
               declare
                  From  : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
                  Where : constant Syn.Node_Id :=
                    Syn.Index_Of (Of_Tree, Node);
                  Position : Ty.Magnitude;
               begin
                  --  Reaching an element destination reads its index even
                  --  though it does not read the element being selected.
                  Read_Names (Of_Tree, Where, State);
                  if Syn.Kind (Of_Tree, From) = Syn.Name_Reference
                    and then Res.Verdict_Of (Meanings.all, Of_Tree, From)
                             = Res.Bound
                    and then Landin.Checking.Type_Of
                               (Types.all, Of_Tree, Node) /= Ty.Ill_Typed
                    and then Known_Index_Value
                               (Of_Tree, Where, Position)
                  then
                     declare
                        Id : constant Res.Declaration_Id :=
                          Res.Bound_To (Meanings.all, Of_Tree, From);
                     begin
                        if Is_Tracked (Id) then
                           Element_Sets.Include
                             (State.Elements, (Id, Position));
                        end if;
                     end;
                  elsif Syn.Kind (Of_Tree, From) /= Syn.Name_Reference then
                     Read_Names (Of_Tree, From, State);
                  end if;
               end;

               return;
            end if;

            if Node /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Node) = Syn.Member_Selection
            then
               declare
                  From : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
                  Which : constant Natural :=
                    Landin.Checking.Field_Index (Types.all, Of_Tree, Node);
               begin
                  if Which in 1 .. Widest_Struct
                    and then Syn.Kind (Of_Tree, From) = Syn.Name_Reference
                    and then Res.Verdict_Of (Meanings.all, Of_Tree, From)
                             = Res.Bound
                  then
                     declare
                        Id : constant Res.Declaration_Id :=
                          Res.Bound_To (Meanings.all, Of_Tree, From);
                     begin
                        if Is_Tracked (Id) then
                           State.Fields (Positive (Id), Which) := True;
                        end if;
                     end;
                  end if;
               end;

               return;
            end if;

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
                     if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                          = Ty.Fixed_Array
                     then
                        --  One fact stands for an extent D18 permits to be
                        --  too large for either the IR or the host to list.
                        Declaration_Sets.Include (State.Whole_Arrays, Id);
                     else
                        State.Fields (Positive (Id), 0) := True;
                     end if;

                     --  A whole struct copied into a place assigns every
                     --  field of it at once, which is the one way a
                     --  struct becomes assigned other than a field at a
                     --  time.
                     if Landin.Checking.Has_Layout (Types.all, Id) then
                        for Each in
                          1 .. Landin.Checking.Layout_Field_Count
                                 (Types.all, Id)
                        loop
                           if Each in 1 .. Widest_Struct then
                              State.Fields (Positive (Id), Each) := True;
                           end if;
                        end loop;
                     end if;
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
                     --  the form [0080] describes, which has none.  D21
                     --  cites itself when a whole-array source is not
                     --  assigned, because that is what the reader is doing.
                     Read_Names (Of_Tree, Syn.Value_Of (Of_Tree, Item),
                                 State,
                                 Whole_As => Initializer_Source);

                  when Syn.Assignment =>
                     Read_Names (Of_Tree, Syn.Value_Of (Of_Tree, Item),
                                 State);

                     --  D16: writing one field assigns that field and
                     --  says nothing about the others, and reaching it is
                     --  not a read of the struct it is in.
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
                        Merged   : Assigned_Set := Nothing_Assigned;
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
                                 Merge (Merged, not Any_Path, Branch);
                                 Any_Path := True;
                                 All_Exit := False;
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
                                 Merge (Merged, not Any_Path, Branch);
                                 Any_Path := True;
                                 All_Exit := False;
                              end if;
                           end;
                        else
                           --  [1910]: no condition is believed, so a
                           --  branch with no `else` has a path that runs
                           --  none of its arms and changes nothing.
                           Merge (Merged, not Any_Path, State);
                           Any_Path := True;
                           All_Exit := False;
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
         if Landin.Checking.State_Of (Types.all, Id)
            = Landin.Checking.Untouched
         then
            if Res.Sort_Of (Meanings.all, Id) = Res.Module_Type then
               --  Settled_Type marks an alias before following it, so a
               --  cycle returns to an Underway declaration rather than
               --  recursively settling the declaration the outer pass is
               --  still visiting.
               declare
                  Written : constant Ty.Type_Kind := Settled_Type (Id);
               begin
                  pragma Unreferenced (Written);
               end;
            else
               declare
                  Written : constant Ty.Type_Kind := Declared_As (Id);
               begin
                  if Written /= Ty.Undecided then
                     Landin.Checking.Settle (Types.all, Id, Written);
                  end if;
               end;
            end if;
         end if;
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
